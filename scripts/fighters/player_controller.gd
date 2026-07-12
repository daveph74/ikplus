class_name PlayerController
extends FighterController
## Fills intent from the global Input singleton, through an 8-tick InputBuffer.
## Presses are recorded every tick (even during hit-stop/stun); the buffer is
## consumed only when the fighter can act, so a press just before recovery ends
## comes out on the recovery→IDLE transition. AIController must NEVER inject via
## Input.action_press — that singleton is global (reserved for the smoke harness,
## where exactly one fighter reads Input).

var _buffer := InputBuffer.new()


func compute_intent(_delta: float) -> void:
	intent.clear()
	intent.move_x = Input.get_axis(&"move_left", &"move_right")
	intent.jump = Input.is_action_just_pressed(&"jump")
	intent.block = Input.is_action_pressed(&"block")

	var tick := Engine.get_physics_frames()
	if Input.is_action_just_pressed(&"punch"):
		_buffer.push(&"punch", tick)
	if Input.is_action_just_pressed(&"kick"):
		_buffer.push(&"kick", tick)

	var fighter := get_parent() as Fighter
	if fighter != null and fighter.can_start_attack():
		var button := _buffer.pop_valid(tick)
		if button != &"":
			intent.attack_id = _resolve_chord(button, fighter)


## Directional modifiers resolve at consume time (docs/plan.md attack table):
## down+punch = punch_low, fwd+punch = punch_body, punch alone = punch_high;
## kick alone = kick_high, fwd+kick = kick_front, back+kick = kick_round,
## down+kick = sweep; airborne (JUMPING) swaps to the air variants.
func _resolve_chord(button: StringName, fighter: Fighter) -> StringName:
	if fighter.state == Fighter.State.JUMPING:
		return &"punch_jump" if button == &"punch" else &"kick_jump"

	var down := Input.is_action_pressed(&"down")
	var axis := Input.get_axis(&"move_left", &"move_right")
	var fwd := not is_zero_approx(axis) and signf(axis) == float(fighter.facing)
	var back := not is_zero_approx(axis) and signf(axis) == float(-fighter.facing)

	if button == &"punch":
		if down:
			return &"punch_low"
		if fwd:
			return &"punch_body"
		return &"punch_high"

	# kick
	if down:
		return &"sweep"
	if fwd:
		return &"kick_front"
	if back:
		return &"kick_round"
	return &"kick_high"
