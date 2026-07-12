extends Node
## Esc pause (build step 8, docs/plan.md "Esc pause"). process_mode is set to
## PROCESS_MODE_ALWAYS on this node in main.tscn so it keeps polling whether or
## not the tree is paused — a plain PAUSABLE listener could open the pause
## menu but would never see the input needed to close it again. This node
## drives PauseLayer's visibility directly at the exact moment of toggling
## (simpler and more robust than a second poller living on PauseLayer itself,
## which is PROCESS_MODE_WHEN_PAUSED and so would never run while UNpaused —
## it could never notice the unpause and hide itself). Independent of
## hit-stop, which is a per-fighter freeze, not a tree pause.

@onready var _pause_layer: CanvasLayer = get_parent().get_node(^"PauseLayer")


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed(&"pause"):
		get_tree().paused = not get_tree().paused
		_pause_layer.visible = get_tree().paused
