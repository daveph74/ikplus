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

var state := State.IDLE
var facing := 1 ## +1 faces +X; flips Visual, never the body
var target: Fighter = null ## set by TargetingSystem (build step 6)
var hitstop_frames := 0 ## > 0 gates the ENTIRE combat tick (FSM, counters, boxes)

@onready var controller: FighterController = $Controller
@onready var visual: Node3D = $Visual


func _ready() -> void:
	_apply_facing()


func _physics_process(delta: float) -> void:
	controller.compute_intent(delta)
	if hitstop_frames > 0:
		# Frozen: one gate covers FSM handler, attack frame counters, and hitbox
		# snap/poll so active windows can't silently expire mid-freeze (velocity
		# is cached/restored by the combat code that sets hitstop_frames, step 4).
		hitstop_frames -= 1
		return
	_state_physics(controller.intent, delta)
	move_and_slide()
	# Defensive clamps: Z drift is mostly moot (no fighter-fighter body collision)
	# but stays as backup; X clamps to arena bounds — no ring-outs in the POC.
	position.z = 0.0
	position.x = clampf(position.x, -ARENA_HALF_W, ARENA_HALF_W)


func _state_physics(intent: FighterIntent, delta: float) -> void:
	match state:
		State.IDLE:
			_apply_gravity(delta)
			velocity.x = 0.0
			_update_facing(intent.move_x)
			if intent.jump and is_on_floor():
				_start_jump(intent.move_x)
			elif not is_zero_approx(intent.move_x):
				_enter_state(State.MOVING)
		State.MOVING:
			_apply_gravity(delta)
			_update_facing(intent.move_x)
			if intent.jump and is_on_floor():
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
		_:
			# Combat states (ATTACKING/BLOCKING/HIT_STUN/...) arrive in steps 4-8.
			_apply_gravity(delta)


func _enter_state(new_state: State) -> void:
	if new_state == state:
		return
	# Interrupt-safe exits: every state's cleanup runs regardless of exit reason
	# (forced interrupts ROUND_LOCKED > KNOCKED_DOWN > HIT_STUN may fire any tick).
	match state:
		State.ATTACKING:
			pass # step 4: disable hitbox, clear victims_hit, frame counters, hit-stop
		_:
			pass
	state = new_state
	match state:
		State.IDLE:
			_play_anim(&"idle")
		State.JUMPING:
			_play_anim(&"jump")
		_:
			pass # MOVING picks walk_fwd/walk_back per tick; combat anims in later steps


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


func _play_anim(anim_name: StringName) -> void:
	if visual.has_method(&"play_anim"):
		visual.call(&"play_anim", anim_name)
