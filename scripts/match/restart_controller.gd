extends Node
## R (&"restart") reload listener (build step 8, docs/plan.md ENDED: "R
## restarts"). process_mode is set to PROCESS_MODE_ALWAYS on this node in
## main.tscn so it works after match end (fighters are inert but the tree is
## NOT paused in ENDED) and even while Esc-paused. Polls rather than relying
## on _unhandled_input so it stays consistent with how the smoke harness
## drives every other action (Input.action_press only guarantees the pollable
## is_action_just_pressed state, not that a synthetic InputEvent walks the
## input-handling callbacks).


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed(&"restart"):
		get_tree().reload_current_scene()
