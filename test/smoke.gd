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


func _initialize() -> void:
	seed(0)
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var main := packed.instantiate()
	root.add_child(main)
	# Required for reload_current_scene() asserts (step 8): the setter demands the
	# node already be a child of root, hence add_child first.
	current_scene = main
	_watchdog()
	_run(main)


func _watchdog() -> void:
	await _ticks(7200) # 120 simulated seconds — step 5 adds several wait-heavy scenarios
	if not _done:
		_fail("watchdog: scenarios did not complete in 7200 ticks")


func _run(main: Node) -> void:
	root.get_node("GameEvents").fighter_hit.connect(_on_hit)
	var player: Fighter = main.get_node("PlayerFighter")

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
	# Dummy's own facing never updates (no TargetingSystem until step 6, and the
	# passive/block stubs never set move_x), so it stays at its spawn default of
	# +1. Position the dummy to the player's RIGHT (as scenario 1 already did) so
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
