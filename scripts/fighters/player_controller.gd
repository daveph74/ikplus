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


## Directional modifiers resolve at consume time (docs/plan.md attack table).
## Step 4 wires punch_high only; step 5 completes the 9-attack table.
func _resolve_chord(button: StringName, _fighter: Fighter) -> StringName:
	if button == &"punch":
		return &"punch_high"
	return &""
