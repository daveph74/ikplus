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
var _score_changed_events: Array = []
var _match_ended_events: Array = []


func _initialize() -> void:
	seed(0)
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var main := packed.instantiate() as Main
	# Step 8: shrink MatchManager's timers for a fast, deterministic suite
	# (docs/plan.md smoke.gd contract: "shrink long scenarios via an exported
	# debug property"). Must be set BEFORE add_child — MatchManager._ready()
	# (which reads match_seconds) fires as part of the add_child ready cascade.
	var match_manager := main.get_node("MatchManager") as MatchManager
	match_manager.intro_seconds = 0.1
	match_manager.match_seconds = 20.0
	root.add_child(main)
	# Required for reload_current_scene() asserts (step 8): the setter demands the
	# node already be a child of root, hence add_child first.
	current_scene = main
	_watchdog()
	_run(main)


func _watchdog() -> void:
	# 120 simulated seconds for the step 2-6 scenarios (generous headroom over
	# their actual runtime) + the step 8 match-manager scenarios (scoring,
	# round-lock, win, restart) + a second ~1800-tick (30 s) AI soak run after
	# the restart, plus margin, so the watchdog stays ahead of total length.
	await _ticks(16000)
	if not _done:
		_fail("watchdog: scenarios did not complete in 16000 ticks")


func _run(main: Main) -> void:
	root.get_node("GameEvents").fighter_hit.connect(_on_hit)
	root.get_node("GameEvents").target_changed.connect(_on_target_changed)
	root.get_node("GameEvents").score_changed.connect(_on_score_changed)
	root.get_node("GameEvents").match_ended.connect(_on_match_ended)
	# Fighters are spawned in Main._ready() (build step 6) rather than baked
	# statically into main.tscn, so they don't exist until the tree's first
	# frame runs _ready — one tick's wait before the first get_node.
	await physics_frame
	var player: Fighter = main.get_node("PlayerFighter")
	var match_manager := main.get_node("MatchManager") as MatchManager

	# --- step 8: MatchManager starts in INTRO — wait for "Fight!" before any
	# scenario below touches combat (intro_seconds was shrunk to 0.1s at boot).
	await _until(
		func() -> bool: return match_manager.phase == MatchManager.Phase.FIGHTING, 60,
		"match reaches FIGHTING before the scenario sequence starts"
	)

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

	# --- GLB adapter: foreign skeleton/clip-name rig (docs/architecture.md) ---
	# A Mixamo-style fixture with foreign bone and clip names, packed like an
	# imported GLB: the adapter must auto-create the attachment nodes, resolve
	# canonical clips through CLIP_ALIASES, normalize the oversized rig, and the
	# fighter must remain a fully functional combat victim.
	var glb_dummy := _spawn_glb_dummy(main, player.position.x + 0.9)
	await _ticks(3)
	var glb_visual := glb_dummy.get_node("Visual") as FighterVisual
	_check(
		glb_visual.find_child("AttachHandR", true, false) is BoneAttachment3D,
		"foreign rig: AttachHandR auto-created on the skeleton"
	)
	_check(
		glb_visual.find_child("AttachFootR", true, false) is BoneAttachment3D,
		"foreign rig: AttachFootR auto-created on the skeleton"
	)
	_check(
		glb_visual.resolve_clip(&"punch_high") == &"Punching",
		"foreign rig: punch_high resolves to Punching"
	)
	_check(
		glb_visual.resolve_clip(&"walk_back") == &"Walking_Backwards",
		"foreign rig: walk_back resolves to Walking_Backwards"
	)
	_check(
		glb_visual.resolve_clip(&"victory") == &"Victory_Cheer",
		"foreign rig: victory resolves to Victory_Cheer"
	)
	_check(
		glb_visual.resolve_clip(&"sweep") == &"",
		"foreign rig: unmatched canonical resolves empty (graceful no-anim)"
	)
	var glb_rig := glb_visual.get_node("Rig") as Node3D
	_check(glb_rig.scale.x < 0.99, "foreign rig: oversized rig auto-scaled toward target height")
	_hit_events.clear()
	Input.action_press(&"punch")
	await _ticks(2)
	Input.action_release(&"punch")
	await _until(
		func() -> bool: return _hit_events.size() > 0, 30, "punch registers on the GLB-rigged dummy"
	)
	if _hit_events.size() > 0:
		_check(_hit_events[0][1] == glb_dummy, "foreign rig: victim is the GLB dummy")
		_check(int(_hit_events[0][2]) == CombatResolver.HitResult.HIT, "foreign rig: result is HIT")
	await _until(
		func() -> bool: return glb_dummy.state == Fighter.State.IDLE and glb_dummy.hitstop_frames == 0,
		180, "GLB dummy recovers to IDLE"
	)
	await _until(
		func() -> bool: return player.state == Fighter.State.IDLE, 60,
		"attacker recovers after the GLB-dummy hit"
	)
	glb_dummy.queue_free()
	await _ticks(2)

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

	# --- step 8: MatchManager — scoring, round-lock, win, restart -------------
	# FighterP2 is already a MANAGED fighter (config != null, spawned by Main)
	# parked as a passive stub — reused here as a punching bag the match
	# machinery actually scores/locks/wins on (same swap-controller pattern).
	# The step 5 stun-lock-breaker dummy is done being useful; free it now so
	# it can't be mistaken for the scoring target or steal AI focus later.
	dummy.queue_free()

	# --- 8a: scoring ---
	player.target = null # avoid a stale reference to the dummy we just freed
	fighter_p2.target = null
	fighter_p2.position = Vector3(player.position.x + 0.9, 0.0, 0.0)
	fighter_p2.velocity = Vector3.ZERO
	player.facing = 1
	player._apply_facing()
	await _ticks(3)

	_score_changed_events.clear()
	Input.action_press(&"punch")
	await _ticks(2)
	Input.action_release(&"punch")
	await _until(
		func() -> bool: return int(match_manager.scores.get(player, 0)) >= 1, 40,
		"MatchManager scores the player's punch on FighterP2"
	)
	_check(int(match_manager.scores.get(player, 0)) == 1, "player's MatchManager score is exactly 1")
	_check(_score_changed_events.size() > 0, "score_changed fired for the scoring punch")
	await _until(
		func() -> bool: return player.state == Fighter.State.IDLE, 60,
		"attacker recovers after the scoring punch"
	)

	# --- 8b: knockdown -> ROUND_LOCK ---
	_check(match_manager.phase == MatchManager.Phase.FIGHTING, "still FIGHTING going into the sweep")
	Input.action_press(&"down")
	Input.action_press(&"kick")
	await _ticks(2)
	Input.action_release(&"down")
	Input.action_release(&"kick")
	await _until(
		func() -> bool: return match_manager.phase == MatchManager.Phase.ROUND_LOCK, 40,
		"sweep knockdown triggers ROUND_LOCK"
	)
	var lock_time_start := match_manager.remaining_time
	await _until(
		func() -> bool:
			for f in main.fighters:
				if (f as Fighter).state != Fighter.State.ROUND_LOCKED:
					return false
			return true,
		120, "every managed fighter ends up ROUND_LOCKED during the lock"
	)
	await _until(
		func() -> bool: return match_manager.phase == MatchManager.Phase.FIGHTING, 200,
		"phase returns to FIGHTING once the round-lock sequence finishes"
	)
	var lock_time_end := match_manager.remaining_time
	_check(lock_time_end >= lock_time_start, "match timer does not decrease during ROUND_LOCK")
	for f: Fighter in main.fighters:
		_check(
			absf(f.position.x - f.config.spawn_x) < 0.3,
			"%s ends near its spawn mark after the round-lock" % f.config.display_name
		)
	_check(player.state == Fighter.State.IDLE, "player is IDLE after the round-lock sequence")

	# --- 8c: win ---  plain punches never lock (only knockdowns do), so this is
	# just repeated punches with mutual recovery waits until target_score.
	fighter_p2.position = Vector3(player.position.x + 0.9, 0.0, 0.0)
	fighter_p2.velocity = Vector3.ZERO
	player.target = null
	fighter_p2.target = null
	await _ticks(3)
	_check(player.facing == 1, "player faces FighterP2 again after the round-lock reposition")

	var punches_needed: int = match_manager.target_score - int(match_manager.scores.get(player, 0))
	for i in punches_needed:
		# A landed (non-knockdown) HIT still applies knockback per docs/plan.md
		# ("Re-hit during HIT_STUN ... RESETS stun/knockback"), which pushes
		# FighterP2 away from the player each time — re-pin it into range before
		# every punch rather than relying on it staying put.
		fighter_p2.position = Vector3(player.position.x + 0.9, 0.0, 0.0)
		fighter_p2.velocity = Vector3.ZERO
		Input.action_press(&"punch")
		await _ticks(2)
		Input.action_release(&"punch")
		# The winning punch can force the player straight to VICTORY (skipping
		# IDLE entirely) the instant its score crosses target_score, well before
		# its own attack recovery would otherwise finish — accept either.
		await _until(
			func() -> bool:
				return player.state == Fighter.State.IDLE or match_manager.phase == MatchManager.Phase.ENDED,
			60, "attacker recovers (or the match ends) after scoring punch %d/%d" % [i + 1, punches_needed]
		)
		if match_manager.phase == MatchManager.Phase.ENDED:
			break
		# Wait for FighterP2 to fully reset to neutral before the next punch —
		# otherwise a rapid re-press could trip the stun-lock breaker (3
		# consecutive hits while still in HIT_STUN auto-converts to KNOCKDOWN,
		# which would round-lock instead of the plain scoring this scenario
		# wants).
		await _until(
			func() -> bool: return fighter_p2.state == Fighter.State.IDLE, 60,
			"FighterP2 resets to neutral before the next scoring punch"
		)

	await _until(
		func() -> bool: return match_manager.phase == MatchManager.Phase.ENDED, 60,
		"match ends once the player reaches target_score"
	)
	_check(match_manager.winner == player, "MatchManager's winner is the player")
	_check(
		_match_ended_events.size() > 0 and _match_ended_events[-1] == player,
		"match_ended fired with the player as winner"
	)
	_check(player.state == Fighter.State.VICTORY, "player enters VICTORY")
	_check(fighter_p2.state == Fighter.State.ROUND_LOCKED, "FighterP2 (loser) ends ROUND_LOCKED")
	_check(fighter_p3.state == Fighter.State.ROUND_LOCKED, "FighterP3 (loser) ends ROUND_LOCKED")

	# --- 8d: restart ---
	# Capture the instance ID rather than `main` itself: reload_current_scene()
	# frees the old node, and a lambda that captures a since-freed Object
	# errors when called ("Lambda capture ... was freed") — a plain int avoids
	# that entirely.
	var old_main_id := main.get_instance_id()
	Input.action_press(&"restart")
	await _ticks(2)
	Input.action_release(&"restart")
	await _until(
		func() -> bool: return current_scene == null or current_scene.get_instance_id() != old_main_id, 90,
		"restart (R) reloads the scene"
	)

	# --- post-restart: re-acquire everything (reload_current_scene() frees the
	# whole previous tree — main/player/fighter_p2/fighter_p3/match_manager are
	# all stale references now) ---
	main = current_scene as Main
	await _ticks(1)
	match_manager = main.get_node("MatchManager") as MatchManager
	match_manager.intro_seconds = 0.1
	match_manager.match_seconds = 20.0
	player = main.get_node("PlayerFighter")
	fighter_p2 = main.get_node("FighterP2")
	fighter_p3 = main.get_node("FighterP3")
	_check(main.fighters.size() == 3, "restart: main re-spawns exactly 3 fighters")
	_check(int(match_manager.scores.get(player, 0)) == 0, "restart: scores are reset to 0")
	_check(
		match_manager.phase == MatchManager.Phase.INTRO or match_manager.phase == MatchManager.Phase.FIGHTING,
		"restart: phase is back to INTRO/FIGHTING"
	)

	# The player keeps reading the global Input singleton — make sure nothing
	# injected by the scenarios above is still held down.
	for action: StringName in [
		&"move_left", &"move_right", &"down", &"jump", &"punch", &"kick", &"block", &"restart"
	]:
		Input.action_release(action)

	await _until(
		func() -> bool: return match_manager.phase == MatchManager.Phase.FIGHTING, 120,
		"post-restart: match reaches FIGHTING before the AI soak"
	)

	# --- step 7/8: AI soak — the freshly spawned FighterP2/P3 already carry
	# live AIControllers straight out of Main._spawn_fighters() (no restore
	# needed post-reload); run ~30 simulated seconds of full 3-fighter AI
	# combat with the match flow live, and assert liveness + real behaviour.
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

	# Run up to SOAK_TICKS or until the (now-live) match reaches ENDED —
	# match_seconds = 20 s + AI aggression means it may genuinely end early via
	# timeout/sudden-death/score, which is expected: once ENDED, every
	# non-winner is deliberately parked ROUND_LOCKED forever, so continuing to
	# demand a fresh IDLE/BLOCKING sample past that point would be asserting
	# against the match machinery's own by-design end state, not liveness.
	const SOAK_TICKS := 1800 # ~30 simulated seconds at 60 tps
	for _i in SOAK_TICKS:
		if match_manager.phase == MatchManager.Phase.ENDED:
			break
		await physics_frame

	var scoring_hits := 0
	var ai_vs_ai := false
	for ev in _hit_events:
		var attacker := ev[0] as Fighter
		var victim := ev[1] as Fighter
		var result: int = ev[2]
		if result == CombatResolver.HitResult.HIT or result == CombatResolver.HitResult.KNOCKDOWN:
			scoring_hits += 1
		if attacker != null and victim != null and attacker != player and victim != player:
			ai_vs_ai = true # neither side is the player -> the two AI fighters fought each other

	_check(not _failed, "AI soak: reached the end without a watchdog/assert failure (no crash)")
	_check(scoring_hits >= 5, "AI soak: at least 5 HIT/KNOCKDOWN events occurred (got %d)" % scoring_hits)
	_check(ai_vs_ai, "AI soak: at least one hit event was between the two AI fighters")
	_check(
		(
			match_manager.phase == MatchManager.Phase.FIGHTING
			or match_manager.phase == MatchManager.Phase.SUDDEN_DEATH
			or match_manager.phase == MatchManager.Phase.ENDED
		),
		"post-restart AI soak: phase is FIGHTING/SUDDEN_DEATH/ENDED at exit (never wedged in INTRO/ROUND_LOCK)"
	)

	_finish()


# --- helpers ----------------------------------------------------------------


## Same passive-stub pattern as _spawn_dummy, but the Visual mounts the foreign
## fixture rig (test/fixtures/foreign_rig.tscn — Mixamo-style bone names,
## foreign clip names, no attachments, oversized mesh; a file-based scene
## because PackedScene.pack() does NOT serialize programmatic Skeleton3D bones,
## while imported/saved scenes carry them as bones/N/* properties) through the
## same rig_scene path a real GLB would use.
func _spawn_glb_dummy(parent: Node, x: float) -> Fighter:
	var dummy: Fighter = FighterScene.instantiate()
	var player_ctrl: Node = dummy.get_node("Controller")
	player_ctrl.free()
	var stub := FighterController.new()
	stub.name = "Controller"
	dummy.add_child(stub)
	(dummy.get_node("Visual") as FighterVisual).rig_scene = preload("res://test/fixtures/foreign_rig.tscn")
	parent.add_child(dummy)
	dummy.position = Vector3(x, 0, 0)
	return dummy


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


func _on_score_changed(fighter: Node, new_score: int) -> void:
	_score_changed_events.append([fighter, new_score])


func _on_match_ended(winner: Node) -> void:
	_match_ended_events.append(winner)
