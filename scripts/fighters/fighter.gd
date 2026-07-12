class_name Fighter
extends CharacterBody3D
## One karate fighter. The Controller child (player or AI) writes a FighterIntent
## each physics tick; the FSM consumes it. All combat timing is tick-counted at
## 60 physics tps. Fighter bodies collide with the WORLD layer only — spacing
## between fighters comes from the soft separation push (build step 6).

enum State {
	IDLE,
	MOVING,
	JUMPING,
	ATTACKING,
	BLOCKING,
	HIT_STUN,
	KNOCKED_DOWN,
	RECOVERING,
	ROUND_LOCKED,
	VICTORY,
}

const ARENA_HALF_W := 7.0 ## shared with arena builder, camera bound, reposition marks
const GRAVITY := 24.0
const WALK_FWD_SPEED := 3.2
const WALK_BACK_SPEED := 2.4
const AIR_STEER := 0.15 ## per-tick horizontal accel while airborne
const JUMP_VELOCITY := 8.5
const FACING_HYSTERESIS := 0.2 ## metres; stops crossup flip jitter
const KNOCKBACK_DECAY := 12.0 ## m/s^2 ground friction on hit-stun/block/knockdown knockback
const AIR_ATTACK_LANDING_RECOVERY_FRAMES := 6 ## touching the floor mid-air-attack skips to this
const BLOCK_STUN_FRAMES := 8
const BLOCK_PUSHBACK_SPEED := 2.4 ## m/s impulse, decays like knockback
const KNOCKDOWN_POP_VELOCITY := 3.0 ## upward pop added to a grounded knockdown hit
const KNOCKDOWN_PRONE_TICKS := 42 ## counted only while on the floor
const RECOVERY_TICKS := 24
const STUN_LOCK_BREAKER_HITS := 3 ## 3rd consecutive hit while still in HIT_STUN -> knockdown

var state := State.IDLE
var facing := 1 ## +1 faces +X; flips Visual, never the body
var target: Fighter = null ## set by TargetingSystem (build step 6)
var config: FighterConfig = null ## set by Main at spawn (build step 6); null for smoke dummies

# Combat bookkeeping. hitstop_frames > 0 gates the ENTIRE combat tick — FSM
# handler, attack frame counters, hitbox snap/poll — so active windows can't
# silently expire mid-freeze.
var hitstop_frames := 0
var stun_frames := 0
var consecutive_stun_hits := 0 ## 3rd hit without neutral auto-converts to knockdown (step 5)
var current_attack: AttackData = null
var attack_tick := 0
var victims_hit: Array[Fighter] = []
var resolver: CombatResolver = null
var _cached_velocity := Vector3.ZERO

var is_airborne := false ## true while the current ATTACKING was started from JUMPING
var has_air_attacked := false ## once per airborne period; reset on landing
var block_stun_frames := 0 ## BLOCKING holds pose + ignores release while > 0
var down_timer := 0 ## KNOCKED_DOWN prone ticks (floor-only) / RECOVERING get-up ticks

@onready var controller: FighterController = $Controller
@onready var visual: Node3D = $Visual
@onready var hitbox: Hitbox = $Hitbox

var _attach_hand: Node3D
var _attach_foot: Node3D
var _attach_hand_l: Node3D
var _attach_foot_l: Node3D


func _ready() -> void:
	_apply_facing()
	# Attachments are built by FighterVisual._ready (children ready before parents).
	_attach_hand = visual.find_child("AttachHandR", true, false) as Node3D
	_attach_foot = visual.find_child("AttachFootR", true, false) as Node3D
	_attach_hand_l = visual.find_child("AttachHandL", true, false) as Node3D
	_attach_foot_l = visual.find_child("AttachFootL", true, false) as Node3D
	resolver = get_tree().get_first_node_in_group(&"combat_resolver") as CombatResolver
	add_to_group(&"fighters") # TargetingSystem (step 6) and Main's separation push pull this group


func _physics_process(delta: float) -> void:
	controller.compute_intent(delta)
	if hitstop_frames > 0:
		hitstop_frames -= 1
		if hitstop_frames == 0:
			velocity = _cached_velocity
			_set_frozen(false)
		return
	_state_physics(controller.intent, delta)
	# ROUND_LOCKED/VICTORY are fully inert (build step 8): no gravity was applied
	# above (their _state_physics arm is a no-op) and no move_and_slide/clamp
	# runs here either — ROUND_LOCKED's external MatchManager tween is the SOLE
	# position authority while locked, and re-clamping mid-tween would fight it.
	if state == State.ROUND_LOCKED or state == State.VICTORY:
		return
	move_and_slide()
	# Defensive clamps: Z drift is mostly moot (no fighter-fighter body collision)
	# but stays as backup; X clamps to arena bounds — no ring-outs in the POC.
	position.z = 0.0
	position.x = clampf(position.x, -ARENA_HALF_W, ARENA_HALF_W)


func can_start_attack() -> bool:
	if state == State.IDLE or state == State.MOVING:
		return true
	# Air attacks: once per airborne period (has_air_attacked resets on landing).
	return state == State.JUMPING and not has_air_attacked


# --- reactions (called by CombatResolver during its batched flush) ----------


func apply_hit(attack: AttackData, from_dir: int, result: int) -> void:
	# Stun-lock breaker (anti two-on-one): the Nth consecutive hit landed while
	# the victim is ALREADY in HIT_STUN forces a knockdown regardless of
	# causes_knockdown — counter resets on entering KNOCKED_DOWN and on
	# HIT_STUN -> IDLE (neutral).
	var was_stunned := state == State.HIT_STUN
	consecutive_stun_hits += 1
	if was_stunned and consecutive_stun_hits >= STUN_LOCK_BREAKER_HITS:
		result = CombatResolver.HitResult.KNOCKDOWN

	var kb := Vector3(from_dir * attack.knockback.x, attack.knockback.y, 0)
	if result == CombatResolver.HitResult.KNOCKDOWN:
		consecutive_stun_hits = 0
		if is_on_floor():
			kb.y = maxf(kb.y, KNOCKDOWN_POP_VELOCITY)
		_apply_knockback(kb)
		_enter_state(State.KNOCKED_DOWN)
		return

	stun_frames = attack.hit_stun_frames
	_apply_knockback(kb)
	_enter_state(State.HIT_STUN)


## Defender-side BLOCKED reaction: holds the block pose (ignoring release) for
## ~8 ticks and applies a decaying X pushback impulse.
func apply_blocked(pushback_dir: int) -> void:
	block_stun_frames = BLOCK_STUN_FRAMES
	_apply_knockback(Vector3(pushback_dir * BLOCK_PUSHBACK_SPEED, 0, 0))


func apply_hitstop(frames: int) -> void:
	if hitstop_frames <= 0:
		_cached_velocity = velocity
		velocity = Vector3.ZERO
		_set_frozen(true)
	hitstop_frames = maxi(hitstop_frames, frames)


func _apply_knockback(kb: Vector3) -> void:
	if hitstop_frames > 0:
		_cached_velocity = kb # frozen mid-trade: knockback must survive the freeze
	else:
		velocity = kb


# --- match control (called by MatchManager, build step 8) -------------------


## Force-interrupts ANY state — including mid-attack — through _enter_state's
## interrupt-safe exit handler (hitbox off, victims_hit/attack counters
## cleared, block/down counters cleared per that state's own exit case),
## zeroes velocity, and clears hit-stop/unfreezes the visual so a frozen
## trade never leaves the fighter stuck mid-freeze while locked. Idempotent:
## calling it again while already ROUND_LOCKED just re-clears the above.
func force_round_lock() -> void:
	hitstop_frames = 0
	_set_frozen(false)
	velocity = Vector3.ZERO
	_enter_state(State.ROUND_LOCKED)


## Releases ROUND_LOCKED. play_recovery lets the caller (MatchManager) route
## the knockdown victim through a brief RECOVERING pass first — reusing
## down_timer/RECOVERY_TICKS exactly like a natural knockdown recovery — so it
## plays "recovery" as its lock-exit anim; every other released fighter goes
## straight to IDLE. No-op if not currently locked.
func release_round_lock(play_recovery := false) -> void:
	if state != State.ROUND_LOCKED:
		return
	_enter_state(State.RECOVERING if play_recovery else State.IDLE)


## Winner's inert victory pose — plays &"victory" once via _enter_state's
## normal entry-anim dispatch. Also force-clears hit-stop/velocity like
## force_round_lock, in case the winning hit itself just applied hit-stop.
func set_victory() -> void:
	hitstop_frames = 0
	_set_frozen(false)
	velocity = Vector3.ZERO
	_enter_state(State.VICTORY)


# --- FSM --------------------------------------------------------------------


func _state_physics(intent: FighterIntent, delta: float) -> void:
	match state:
		State.IDLE:
			_apply_gravity(delta)
			velocity.x = 0.0
			_update_facing(intent.move_x)
			if intent.attack_id != &"":
				_try_start_attack(intent.attack_id)
			elif intent.block:
				_enter_state(State.BLOCKING)
			elif intent.jump and is_on_floor():
				_start_jump(intent.move_x)
			elif not is_zero_approx(intent.move_x):
				_enter_state(State.MOVING)
		State.MOVING:
			_apply_gravity(delta)
			_update_facing(intent.move_x)
			if intent.attack_id != &"":
				velocity.x = 0.0
				_try_start_attack(intent.attack_id)
			elif intent.block:
				velocity.x = 0.0
				_enter_state(State.BLOCKING)
			elif intent.jump and is_on_floor():
				_start_jump(intent.move_x)
			elif is_zero_approx(intent.move_x):
				velocity.x = 0.0
				_enter_state(State.IDLE)
			else:
				var fwd := signf(intent.move_x) == float(facing)
				velocity.x = intent.move_x * (WALK_FWD_SPEED if fwd else WALK_BACK_SPEED)
				_play_anim(&"walk_fwd" if fwd else &"walk_back")
		State.JUMPING:
			_apply_gravity(delta)
			velocity.x = clampf(
				velocity.x + intent.move_x * AIR_STEER, -WALK_FWD_SPEED, WALK_FWD_SPEED
			)
			if intent.attack_id != &"":
				_try_start_attack(intent.attack_id)
			elif is_on_floor() and velocity.y <= 0.0:
				velocity.x = 0.0
				_enter_state(State.IDLE)
		State.ATTACKING:
			_apply_gravity(delta)
			if is_airborne:
				# Air attacks keep gravity and X velocity integrating (no rooting);
				# touching the floor mid-attack ends it early (plan: "Air attacks").
				if is_on_floor():
					_land_air_attack()
			else:
				velocity.x = 0.0 # grounded attacks root the fighter
			_attack_tick_update()
		State.HIT_STUN:
			_apply_gravity(delta)
			velocity.x = move_toward(velocity.x, 0.0, KNOCKBACK_DECAY * delta)
			stun_frames -= 1
			if stun_frames <= 0 and is_on_floor():
				velocity.x = 0.0
				consecutive_stun_hits = 0
				_enter_state(State.IDLE)
		State.BLOCKING:
			_apply_gravity(delta)
			velocity.x = move_toward(velocity.x, 0.0, KNOCKBACK_DECAY * delta)
			if block_stun_frames > 0:
				block_stun_frames -= 1
			elif not intent.block:
				velocity.x = 0.0
				_enter_state(State.IDLE)
		State.KNOCKED_DOWN:
			_apply_gravity(delta)
			velocity.x = move_toward(velocity.x, 0.0, KNOCKBACK_DECAY * delta)
			if is_on_floor():
				velocity.x = 0.0
				down_timer += 1
				if down_timer >= KNOCKDOWN_PRONE_TICKS:
					_enter_state(State.RECOVERING)
		State.RECOVERING:
			_apply_gravity(delta)
			down_timer += 1
			if down_timer >= RECOVERY_TICKS:
				_enter_state(State.IDLE)
		State.ROUND_LOCKED, State.VICTORY:
			pass # inert: consumes no intents; MatchManager alone drives transitions out


## Hitbox lifecycle per docs/plan.md: enable (deferred) on the first geometric
## active tick; snap to the attachment each active tick; POLL one tick late
## (overlap lists report the previous physics step) on [start+1 .. end+1];
## disable only after the final poll.
func _attack_tick_update() -> void:
	attack_tick += 1
	var a := current_attack
	var active_start := a.startup_frames + 1
	var active_end := a.startup_frames + a.active_frames
	if attack_tick == active_start:
		hitbox.activate()
	if attack_tick >= active_start and attack_tick <= active_end:
		hitbox.snap_to(_hitbox_anchor(a))
	if attack_tick >= active_start + 1 and attack_tick <= active_end + 1:
		_poll_hitbox(a)
	if attack_tick == active_end + 1:
		hitbox.deactivate()
	if attack_tick >= a.total_frames():
		_enter_state(State.IDLE)


func _poll_hitbox(attack: AttackData) -> void:
	if resolver == null or not hitbox.monitoring:
		return
	for area in hitbox.get_overlapping_areas():
		var hb := area as Hurtbox
		if hb == null:
			continue
		var victim := hb.owner_fighter
		if victim == null or victim == self or victims_hit.has(victim):
			continue
		victims_hit.append(victim)
		resolver.enqueue(self, victim, attack)


func _try_start_attack(attack_id: StringName) -> void:
	var attack := AttackRegistry.get_attack(attack_id)
	if attack == null:
		return
	var from_jump := state == State.JUMPING
	current_attack = attack
	attack_tick = 0
	victims_hit.clear()
	if from_jump:
		is_airborne = true
		has_air_attacked = true
	else:
		is_airborne = false
		velocity.x = 0.0
	_enter_state(State.ATTACKING)
	if visual.has_method(&"play_attack"):
		visual.call(&"play_attack", attack)


## Air attack touching the floor mid-swing: hitbox off, skip straight to the
## last AIR_ATTACK_LANDING_RECOVERY_FRAMES recovery frames, then IDLE as normal
## (via the regular _attack_tick_update total_frames() check).
func _land_air_attack() -> void:
	is_airborne = false
	velocity.x = 0.0
	hitbox.deactivate()
	attack_tick = maxi(attack_tick, current_attack.total_frames() - AIR_ATTACK_LANDING_RECOVERY_FRAMES)


func _enter_state(new_state: State) -> void:
	if new_state == state:
		return
	# Interrupt-safe exits: every state's cleanup runs regardless of exit reason
	# (forced interrupts ROUND_LOCKED > KNOCKED_DOWN > HIT_STUN may fire any tick,
	# so a trade must never leave a live hitbox or stale counters behind).
	match state:
		State.ATTACKING:
			hitbox.deactivate()
			victims_hit.clear()
			current_attack = null
			attack_tick = 0
			is_airborne = false
		State.BLOCKING:
			block_stun_frames = 0
		State.KNOCKED_DOWN, State.RECOVERING:
			down_timer = 0
		_:
			pass
	state = new_state
	match state:
		State.IDLE:
			_play_anim(&"idle")
			has_air_attacked = false # landing (JUMPING/air-ATTACKING -> IDLE) resets it
		State.JUMPING:
			_play_anim(&"jump")
		State.HIT_STUN:
			_play_anim(&"hit_react")
		State.BLOCKING:
			_play_anim(&"block")
		State.KNOCKED_DOWN:
			_play_anim(&"knockdown")
			down_timer = 0
		State.RECOVERING:
			_play_anim(&"recovery")
			down_timer = 0
		State.VICTORY:
			_play_anim(&"victory")
		_:
			pass # MOVING picks walk_fwd/walk_back per tick; ATTACKING uses play_attack;
			# ROUND_LOCKED plays nothing new — it holds whatever pose it was
			# interrupted from (a downed victim keeps its knockdown pose, an
			# idle/moving fighter keeps breathing/stepping in place).


func _start_jump(move_x: float) -> void:
	velocity.y = JUMP_VELOCITY
	velocity.x = move_x * WALK_FWD_SPEED
	_enter_state(State.JUMPING)


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta


func _update_facing(move_x: float) -> void:
	# Only called from IDLE/MOVING — facing is LOCKED in every other state (plan:
	# a mid-attack flip would teleport live hitboxes to the other side).
	var dir := 0
	if target != null:
		var dx := target.position.x - position.x
		if absf(dx) > FACING_HYSTERESIS:
			dir = 1 if dx > 0.0 else -1
	elif not is_zero_approx(move_x):
		dir = 1 if move_x > 0.0 else -1
	if dir != 0 and dir != facing:
		facing = dir
		_apply_facing()


func _apply_facing() -> void:
	visual.rotation.y = 0.0 if facing == 1 else PI


## Where the active hitbox snaps this tick. Normally the animated hand/foot
## attachment — but when the rig has no clip for this attack (foreign rigs may
## ship incomplete sets), the attachment never leaves its rest pose, which can
## sit BEHIND the fighter. Combat must degrade to invisible-but-correct, not
## broken: fall back to a synthetic forward strike point at the attack's height.
func _hitbox_anchor(attack: AttackData) -> Vector3:
	var n: Node3D = null
	match attack.hitbox_type:
		AttackData.HitboxType.HAND:
			n = _attach_hand
		AttackData.HitboxType.FOOT:
			n = _attach_foot
		AttackData.HitboxType.HAND_L:
			n = _attach_hand_l
		AttackData.HitboxType.FOOT_L:
			n = _attach_foot_l
	var animated := n != null
	if animated and visual.has_method(&"resolve_clip"):
		animated = visual.call(&"resolve_clip", attack.anim_name) != &""
	if animated:
		return n.global_position
	var strike_y := 1.4
	match attack.height:
		AttackData.Height.MID:
			strike_y = 1.0
		AttackData.Height.LOW:
			strike_y = 0.25
		AttackData.Height.AIR:
			strike_y = 1.2
	return global_position + Vector3(facing * 0.55, strike_y, 0)


func _play_anim(anim_name: StringName) -> void:
	if visual.has_method(&"play_anim"):
		visual.call(&"play_anim", anim_name)


func _set_frozen(frozen: bool) -> void:
	if visual.has_method(&"set_frozen"):
		visual.call(&"set_frozen", frozen)
