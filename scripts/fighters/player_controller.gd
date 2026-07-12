class_name PlayerController
extends FighterController
## Fills intent from the global Input singleton. Attack chord resolution and the
## ~130 ms InputBuffer arrive in build step 4. AIController must NEVER inject via
## Input.action_press — that singleton is global (reserved for the smoke harness,
## where exactly one fighter reads Input).


func compute_intent(_delta: float) -> void:
	intent.clear()
	intent.move_x = Input.get_axis(&"move_left", &"move_right")
	intent.jump = Input.is_action_just_pressed(&"jump")
	intent.block = Input.is_action_pressed(&"block")
