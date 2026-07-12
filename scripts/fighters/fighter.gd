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
const KNOCKBACK_DECAY := 12.0 ## m/s^2 ground friction on hit-stun knockback

var state := State.IDLE
var facing := 1 ## +1 faces +X; flips Visual, never the body
var target: Fighter = null ## set by TargetingSystem (build step 6)

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

@onready var controller: FighterController = $Controller
@onready var visual: Node3D = $Visual
@onready var hitbox: Hitbox = $Hitbox

var _attach_hand: Node3D
var _attach_foot: Node3D


func _ready() -> void:
	_apply_facing()
	# Attachments are built by FighterVisual._ready (children ready before parents).
	_attach_hand = visual.find_child("AttachHandR", true, false) as Node3D
	_attach_foot = visual.find_child("AttachFootR", true, false) as Node3D
	resolver = get_tree().get_first_node_in_group(&"combat_resolver") as CombatResolver


func _physics_process(delta: float) -> void:
	controller.compute_intent(delta)
	if hitstop_frames > 0:
		hitstop_frames -= 1
		if hitstop_frames == 0:
			velocity = _cached_velocity
			_set_frozen(false)
		return
	_state_physics(controller.intent, delta)
	move_and_slide()
	# Defensive clamps: Z drift is mostly moot (no fighter-fighter body collision)
	# but stays as backup; X clamps to arena bounds — no ring-outs in the POC.
	position.z = 0.0
	position.x = clampf(position.x, -ARENA_HALF_W, ARENA_HALF_W)


func can_start_attack() -> bool:
	# Grounded attacks only until step 5 adds the air-attack path.
	return state == State.IDLE or state == State.MOVING


# --- reactions (called by CombatResolver during its batched flush) ----------


func apply_hit(attack: AttackData, from_dir: int, _result: int) -> void:
	# KNOCKDOWN result falls back to hit-stun until step 5 adds KNOCKED_DOWN.
	stun_frames = attack.hit_stun_frames
	consecutive_stun_hits += 1
	var kb := Vector3(from_dir * attack.knockback.x, attack.knockback.y, 0)
	if hitstop_frames > 0:
		_cached_velocity = kb # frozen mid-trade: knockback must survive the freeze
	else:
		velocity = kb
	_enter_state(State.HIT_STUN)


func apply_hitstop(frames: int) -> void:
	if hitstop_frames <= 0:
		_cached_velocity = velocity
		velocity = Vector3.ZERO
		_set_frozen(true)
	hitstop_frames = maxi(hitstop_frames, frames)


# --- FSM --------------------------------------------------------------------


func _state_physics(intent: FighterIntent, delta: float) -> void:
	match state:
		State.IDLE:
			_apply_gravity(delta)
			velocity.x = 0.0
			_update_facing(intent.move_x)
			if intent.attack_id != &"":
				_try_start_attack(intent.attack_id)
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
			if is_on_floor() and velocity.y <= 0.0:
				velocity.x = 0.0
				_enter_state(State.IDLE)
		State.ATTACKING:
			_apply_gravity(delta)
			velocity.x = 0.0 # grounded attacks root the fighter (air attacks: step 5)
			_attack_tick_update()
		State.HIT_STUN:
			_apply_gravity(delta)
			velocity.x = move_toward(velocity.x, 0.0, KNOCKBACK_DECAY * delta)
			stun_frames -= 1
			if stun_frames <= 0 and is_on_floor():
				velocity.x = 0.0
				consecutive_stun_hits = 0
				_enter_state(State.IDLE)
		_:
			# BLOCKING / KNOCKED_DOWN / RECOVERING / ROUND_LOCKED / VICTORY: steps 5-8.
			_apply_gravity(delta)


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
		hitbox.snap_to(_attach_for(a).global_position)
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
	current_attack = attack
	attack_tick = 0
	victims_hit.clear()
	velocity.x = 0.0
	_enter_state(State.ATTACKING)
	if visual.has_method(&"play_attack"):
		visual.call(&"play_attack", attack)


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
		_:
			pass
	state = new_state
	match state:
		State.IDLE:
			_play_anim(&"idle")
		State.JUMPING:
			_play_anim(&"jump")
		State.HIT_STUN:
			_play_anim(&"hit_react")
		_:
			pass # MOVING picks walk_fwd/walk_back per tick; ATTACKING uses play_attack


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


func _attach_for(attack: AttackData) -> Node3D:
	var n := _attach_hand if attack.hitbox_type == AttackData.HitboxType.HAND else _attach_foot
	return n if n != null else visual


func _play_anim(anim_name: StringName) -> void:
	if visual.has_method(&"play_anim"):
		visual.call(&"play_anim", anim_name)


func _set_frozen(frozen: bool) -> void:
	if visual.has_method(&"set_frozen"):
		visual.call(&"set_frozen", frozen)
