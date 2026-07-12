extends SceneTree
## Headless verification harness. Run with:
##   godot --headless --fixed-fps 60 --path . --script res://test/smoke.gd
## --fixed-fps makes each iteration one 60 Hz tick at CPU speed (no wall-clock).
## Failure paths call quit(1) explicitly — a bare assert() would abort the method
## before any quit line and leave the tree idling (the shell timeout catches that
## as a backstop). Asserts are staged per build step (docs/plan.md).
##
## Input-injection contract: Input.action_press registers on the NEXT physics
## tick, stays just-pressed for exactly one tick, and never re-fires while held —
## press, wait >= 1 tick, assert; action_release before re-pressing. Injection
## drives the global Input singleton, valid here because exactly one fighter
## (the scene's PlayerFighter) reads Input.

const FighterScene := preload("res://scenes/fighters/fighter.tscn")

## Deterministic stub: holds block the entire time. Swapped onto a dummy the
## same way _spawn_dummy() swaps on the passive stub.
class BlockController extends FighterController:
	func compute_intent(_delta: float) -> void:
		intent.clear()
		intent.block = true


var _failed := false
var _done := false
var _hit_events: Array = []
var _target_changed_events: Array = []


func _initialize() -> void:
	seed(0)
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var main := packed.instantiate() as Main
	root.add_child(main)
	# Required for reload_current_scene() asserts (step 8): the setter demands the
	# node already be a child of root, hence add_child first.
	current_scene = main
	_watchdog()
	_run(main)


func _watchdog() -> void:
	# 120 simulated seconds for the step 2-6 scenarios (generous headroom over
	# their actual runtime) + the step 7 AI soak's own ~1800-tick (30 s) budget
	# plus margin, so the watchdog stays ahead of total scenario length.
	await _ticks(9600)
	if not _done:
		_fail("watchdog: scenarios did not complete in 9600 ticks")


func _run(main: Main) -> void:
	root.get_node("GameEvents").fighter_hit.connect(_on_hit)
	root.get_node("GameEvents").target_changed.connect(_on_target_changed)
	# Fighters are spawned in Main._ready() (build step 6) rather than baked
	# statically into main.tscn, so they don't exist until the tree's first
	# frame runs _ready — one tick's wait before the first get_node.
	await physics_frame
	var player: Fighter = main.get_node("PlayerFighter")

	# --- step 6: three-fighter spawn ---
	_check(main.fighters.size() == 3, "main spawns exactly 3 fighters")
	var names := {}
	var player_controller_count := 0
	for f: Fighter in main.fighters:
		names[f.config.display_name] = true
		if f.get_node("Controller") is PlayerController:
			player_controller_count += 1
			_check(f.name == "PlayerFighter", "the PlayerController fighter is named PlayerFighter")
	_check(names.size() == 3, "fighters have distinct display_names")
	_check(player_controller_count == 1, "exactly one PlayerController")

	var fighter_p2: Fighter = main.get_node("FighterP2")
	var fighter_p3: Fighter = main.get_node("FighterP3")
	# Step 7: FighterP2/P3 now carry live AIControllers out of Main's spawn.
	# Immediately swap them for passive FighterController stubs (same
	# free/rename/add pattern as _spawn_dummy/_restore_ai below) so every
	# existing step 2-6 scenario keeps its deterministic passive dummies —
	# real AI is only exercised in the dedicated soak scenario at the end.
	_park_as_passive(fighter_p2)
	_park_as_passive(fighter_p3)
	# Park the AI fighters out of the way of the existing (step 2-5) combat
	# scenarios below — parking just removes them as the closest target
	# candidate; TargetingSystem may immediately reassign their own .target
	# (harmless — passive stubs never move).
	fighter_p2.position.x = -6.5
	fighter_p3.position.x = -5.5
	fighter_p2.target = null
	fighter_p3.target = null

	# --- step 2: movement ---
	await _ticks(5)
	var x0: float = player.position.x
	Input.action_press(&"move_right")
	await _ticks(30)
	Input.action_release(&"move_right")
	_check(player.position.x > x0 + 0.5, "fighter moves right")
	_check(is_zero_approx(player.position.z), "no Z drift")
	await _ticks(5)

	# --- step 2: jump ---
	_check(player.is_on_floor(), "grounded before jump")
	Input.action_press(&"jump")
	await _ticks(3)
	Input.action_release(&"jump")
	_check(player.state == Fighter.State.JUMPING, "jump enters JUMPING")
	await _until(func() -> bool: return player.state == Fighter.State.IDLE, 120, "lands to IDLE")

	# --- step 4: punch lands on a passive stub dummy ---
	var dummy := _spawn_dummy(main, player.position.x + 0.9)
	await _ticks(3)
	_check(player.facing == 1, "player faces the dummy")
	_hit_events.clear()
	Input.action_press(&"punch")
	await _ticks(2)
	Input.action_release(&"punch")
	# Hit must register within startup + active + 1 (overlap lists lag one tick)
	# + injection latency + resolver flush — 30 ticks is generous headroom.
	await _until(func() -> bool: return _hit_events.size() > 0, 30, "punch registers a hit")
	if _hit_events.size() > 0:
		var ev: Array = _hit_events[0]
		_check(ev[0] == player, "attacker is the player")
		_check(ev[1] == dummy, "victim is the dummy (self-hit excluded)")
		_check(int(ev[2]) == CombatResolver.HitResult.HIT, "result is HIT")
		_check(player.hitstop_frames > 0, "attacker hit-stop applied")
		_check(
			dummy.state == Fighter.State.HIT_STUN or dummy.hitstop_frames > 0,
			"dummy reacts (hit-stun/hit-stop)"
		)
	await _until(
		func() -> bool: return dummy.state == Fighter.State.IDLE and dummy.hitstop_frames == 0,
		180, "dummy recovers to IDLE"
	)
	_check(player.state == Fighter.State.IDLE, "attacker back to IDLE after recovery")

	# Whiff at range: no contact event may fire.
	dummy.position.x = player.position.x + 4.0
	await _ticks(2)
	_hit_events.clear()
	Input.action_press(&"punch")
	await _ticks(2)
	Input.action_release(&"punch")
	await _ticks(30)
	_check(_hit_events.is_empty(), "out-of-range punch whiffs (no event)")

	# --- step 5a: facing block ---
	# Dummy's own facing never updates: TargetingSystem only manages fighters with
	# a non-null config (Main's spawned FighterConfigs), so this config-less test
	# fixture is a valid target CANDIDATE for others but never gets its own
	# .target assigned — and the passive/block stubs never set move_x either — so
	# it stays at its spawn default of +1. Position the dummy to the player's
	# RIGHT (as scenario 1 already did) so
	# the attacker's punch travels the dummy's +X — same side the dummy's default
	# facing looks toward — and the block-facing check actually engages.
	# dummy.controller is an @onready reference already resolved by _ready() —
	# freeing the live Controller node without also reassigning it leaves a
	# dangling pointer the fighter calls into next tick (crash).
	dummy.get_node("Controller").free()
	var block_ctrl := BlockController.new()
	block_ctrl.name = "Controller"
	dummy.add_child(block_ctrl)
	dummy.controller = block_ctrl
	dummy.position = Vector3(player.position.x + 0.9, 0, 0)
	# Facing is LOCKED in BLOCKING and never auto-updates for a stub with no
	# target/move_x, so point it at the attacker (to its left) explicitly —
	# _facing_blocks() requires victim.facing to match sign(attacker.x - victim.x).
	dummy.facing = -1
	dummy._apply_facing()
	await _ticks(10) # settle: dummy enters BLOCKING on held block intent
	_check(dummy.state == Fighter.State.BLOCKING, "dummy enters BLOCKING on block hold")
	_check(player.facing == 1, "player still faces the dummy")
	_hit_events.clear()
	Input.action_press(&"punch")
	await _ticks(2)
	Input.action_release(&"punch")
	await _until(
		func() -> bool: return _hit_events.size() > 0, 30, "punch vs. blocker registers a hit event"
	)
	if _hit_events.size() > 0:
		var ev: Array = _hit_events[0]
		_check(int(ev[2]) == CombatResolver.HitResult.BLOCKED, "facing block returns BLOCKED")
	await _ticks(5)
	_check(dummy.state == Fighter.State.BLOCKING, "dummy stays BLOCKING (not HIT_STUN)")
	await _until(
		func() -> bool: return player.state == Fighter.State.IDLE, 60,
		"attacker completes normal recovery after a blocked hit"
	)

	# --- step 5b: low bypass (sweep) ---
	_hit_events.clear()
	Input.action_press(&"down")
	Input.action_press(&"kick")
	await _ticks(2)
	Input.action_release(&"down")
	Input.action_release(&"kick")
	await _until(
		func() -> bool: return _hit_events.size() > 0, 40, "sweep vs. blocker registers a hit event"
	)
	if _hit_events.size() > 0:
		var ev: Array = _hit_events[0]
		_check(int(ev[2]) == CombatResolver.HitResult.KNOCKDOWN, "sweep bypasses block: KNOCKDOWN")
	await _until(
		func() -> bool: return dummy.state == Fighter.State.KNOCKED_DOWN, 30,
		"dummy enters KNOCKED_DOWN"
	)
	await _until(
		func() -> bool: return player.state == Fighter.State.IDLE, 60,
		"attacker recovers after the sweep"
	)

	# --- step 5c: invulnerability while knocked down ---
	_hit_events.clear()
	Input.action_press(&"punch")
	await _ticks(2)
	Input.action_release(&"punch")
	await _ticks(15)
	if _hit_events.size() > 0:
		var ev: Array = _hit_events[0]
		_check(int(ev[2]) == CombatResolver.HitResult.WHIFF, "punching a knocked-down dummy whiffs")
	_check(dummy.state == Fighter.State.KNOCKED_DOWN, "dummy still KNOCKED_DOWN (invulnerable)")
	await _until(
		func() -> bool: return player.state == Fighter.State.IDLE, 30,
		"attacker's whiffed punch still completes its own cycle"
	)

	# --- step 5d: recovery ---
	# Dummy's stub still holds block, so once its KNOCKED_DOWN/RECOVERING lock
	# ends it re-enters BLOCKING the instant it can act again — accept either,
	# per the stub's own dictated behaviour.
	await _until(
		func() -> bool: return (
			dummy.state == Fighter.State.BLOCKING or dummy.state == Fighter.State.IDLE
		), 200, "dummy recovers out of the knockdown"
	)

	# --- step 5e: stun-lock breaker (3rd consecutive hit forces KNOCKDOWN) ---
	# punch_high's own recovery (18 ticks) outlasts its hit_stun_frames (16), so
	# even the fastest possible solo re-press cadence lets the dummy fully
	# recover to neutral between attacks — consecutive_stun_hits would reset
	# every time and 3 solo punches could never chain. CombatResolver.enqueue()
	# is documented as public specifically "so the smoke harness can exercise
	# [the rules] directly" — this exercises the exact rule under test (3
	# same-attack hits landing while the victim is still in HIT_STUN) the way a
	# real two-on-one overlap would, without touching any verified core file.
	block_ctrl.free()
	var passive_ctrl := FighterController.new()
	passive_ctrl.name = "Controller"
	dummy.add_child(passive_ctrl)
	dummy.controller = passive_ctrl
	await _until(
		func() -> bool: return dummy.state == Fighter.State.IDLE, 60,
		"dummy settles to IDLE as a passive (non-blocking) target"
	)
	dummy.position = Vector3(player.position.x + 0.9, 0, 0)
	await _ticks(5)
	var resolver: CombatResolver = main.get_node("CombatResolver")
	var punch_attack := AttackRegistry.get_attack(&"punch_high")
	_hit_events.clear()
	resolver.enqueue(player, dummy, punch_attack)
	await _ticks(3)
	_check(dummy.state == Fighter.State.HIT_STUN, "1st punch stuns the passive dummy")
	resolver.enqueue(player, dummy, punch_attack)
	await _ticks(3)
	_check(dummy.state == Fighter.State.HIT_STUN, "2nd punch re-stuns before recovery")
	resolver.enqueue(player, dummy, punch_attack)
	await _ticks(3)
	_check(_hit_events.size() >= 3, "3 hit events were recorded")
	if _hit_events.size() >= 3:
		var ev3: Array = _hit_events[2]
		_check(
			int(ev3[2]) == CombatResolver.HitResult.KNOCKDOWN,
			"3rd consecutive stun hit auto-converts to KNOCKDOWN"
		)
	_check(dummy.state == Fighter.State.KNOCKED_DOWN, "stun-lock breaker knocks the dummy down")

	# --- step 6: targeting — closest wins with hysteresis + rate limit ---
	_target_changed_events.clear()
	fighter_p2.position.x = player.position.x + 1.5
	dummy.position.x = player.position.x + 4.0
	await _ticks(21) # >= 0.35 s: past the 0.3 s player switch cooldown
	_check(player.target == fighter_p2, "closest wins with hysteresis + rate limit (FighterP2)")

	dummy.position.x = player.position.x + 0.7 # >= 0.5 m closer than FighterP2 (1.5 m away)
	await _ticks(21)
	_check(player.target == dummy, "target switches to the now-closer dummy")

	_check(
		_target_changed_events.size() > 0, "at least one target_changed event during the retarget scenario"
	)

	# --- step 6: separation push ---
	fighter_p2.position.x = player.position.x + 0.2 # overlapping; both idle/grounded
	await _ticks(60)
	_check(
		absf(fighter_p2.position.x - player.position.x) > 0.5,
		"separation push spaces the overlapping pair apart"
	)
	_check(
		absf(fighter_p2.position.x) <= 7.0 and absf(player.position.x) <= 7.0,
		"both fighters stay inside the arena bounds"
	)

	# --- step 7: AI soak — restore real AIControllers, run ~30 simulated
	# seconds of full 3-fighter AI combat, assert liveness + real behaviour.
	# The step 5 stun-lock-breaker dummy is a config-less fixture that would
	# otherwise remain a valid TargetingSystem candidate and steal AI focus —
	# remove it before restoring AI so P2/P3 can only target the player or
	# each other.
	dummy.queue_free()

	# The player keeps reading the global Input singleton — make sure nothing
	# injected by the scenarios above is still held down.
	for action: StringName in [
		&"move_left", &"move_right", &"down", &"jump", &"punch", &"kick", &"block"
	]:
		Input.action_release(action)

	var ai_normal: AIProfile = load("res://resources/fighters/ai_normal.tres")
	_restore_ai(fighter_p2, ai_normal)
	_restore_ai(fighter_p3, ai_normal)

	# Reposition all three fighters to their spawn marks (FighterConfig.spawn_x).
	player.position = Vector3(-2.5, 0.0, 0.0)
	fighter_p2.position = Vector3(0.0, 0.0, 0.0)
	fighter_p3.position = Vector3(2.5, 0.0, 0.0)
	player.target = null
	fighter_p2.target = null
	fighter_p3.target = null
	player.velocity = Vector3.ZERO
	fighter_p2.velocity = Vector3.ZERO
	fighter_p3.velocity = Vector3.ZERO

	_hit_events.clear()
	_target_changed_events.clear()

	# Sample AI states every 30 ticks into sets: every AI must pass through IDLE
	# at some sampled point (nobody wedged in a stuck state), and blocks are
	# stochastic so a directly-observed BLOCKING state is an acceptable
	# alternative to a resolver BLOCKED event for assert (d) below.
	var idle_seen := {} # Fighter -> true
	var blocking_seen := false
	const SOAK_TICKS := 1800 # ~30 simulated seconds at 60 tps
	const SAMPLE_EVERY := 30
	for i in SOAK_TICKS:
		await physics_frame
		if i % SAMPLE_EVERY == 0:
			for f in [fighter_p2, fighter_p3]:
				if f.state == Fighter.State.IDLE:
					idle_seen[f] = true
				elif f.state == Fighter.State.BLOCKING:
					blocking_seen = true

	var scoring_hits := 0
	var ai_vs_ai := false
	var blocked_seen := false
	for ev in _hit_events:
		var attacker := ev[0] as Fighter
		var victim := ev[1] as Fighter
		var result: int = ev[2]
		match result:
			CombatResolver.HitResult.HIT, CombatResolver.HitResult.KNOCKDOWN:
				scoring_hits += 1
			CombatResolver.HitResult.BLOCKED:
				blocked_seen = true
		if attacker != null and victim != null and attacker != player and victim != player:
			ai_vs_ai = true # neither side is the player -> the two AI fighters fought each other

	_check(not _failed, "AI soak: reached the end without a watchdog/assert failure (no crash)")
	_check(scoring_hits >= 5, "AI soak: at least 5 HIT/KNOCKDOWN events occurred (got %d)" % scoring_hits)
	_check(ai_vs_ai, "AI soak: at least one hit event was between the two AI fighters")
	_check(
		blocked_seen or blocking_seen,
		"AI soak: at least one BLOCKED event or an observed AI BLOCKING state occurred"
	)
	_check(
		idle_seen.has(fighter_p2) and idle_seen.has(fighter_p3),
		"AI soak: both AI fighters passed through IDLE at some sampled point (nobody stuck)"
	)

	_finish()


# --- helpers ----------------------------------------------------------------


func _spawn_dummy(parent: Node, x: float) -> Fighter:
	# Passive stub: the base FighterController emits an empty intent every tick,
	# so combat-rule asserts never race a live AI (determinism per docs/plan.md).
	var dummy: Fighter = FighterScene.instantiate()
	var player_ctrl: Node = dummy.get_node("Controller")
	player_ctrl.free()
	var stub := FighterController.new()
	stub.name = "Controller"
	dummy.add_child(stub)
	parent.add_child(dummy)
	dummy.position = Vector3(x, 0, 0)
	return dummy


## Step 7: swap out a spawned fighter's live AIController for a passive
## FighterController stub — same free/rename/add pattern as _spawn_dummy,
## reassigning fighter.controller since it's an @onready reference already
## resolved by _ready() (a dangling pointer would crash the next tick).
func _park_as_passive(fighter: Fighter) -> void:
	fighter.get_node("Controller").free()
	var stub := FighterController.new()
	stub.name = "Controller"
	fighter.add_child(stub)
	fighter.controller = stub


## Step 7: swap a passive stub back out for a fresh, real AIController.
func _restore_ai(fighter: Fighter, profile: AIProfile) -> void:
	fighter.get_node("Controller").free()
	var ai := AIController.new()
	ai.name = "Controller"
	ai.profile = profile
	fighter.add_child(ai)
	fighter.controller = ai


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _until(cond: Callable, max_ticks: int, what: String) -> void:
	for i in max_ticks:
		if cond.call():
			return
		await physics_frame
	_fail("timeout waiting for: " + what)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("SMOKE ok: ", what)
	else:
		_fail("check failed: " + what)


func _fail(msg: String) -> void:
	push_error("SMOKE FAIL: " + msg)
	_failed = true
	_done = true
	quit(1)


func _finish() -> void:
	_done = true
	if not _failed:
		print("SMOKE OK — all scenarios passed")
		quit(0)


func _on_hit(attacker: Node, victim: Node, result: int, attack: Resource) -> void:
	_hit_events.append([attacker, victim, result, attack])


func _on_target_changed(fighter: Node, new_target: Node) -> void:
	_target_changed_events.append([fighter, new_target])
