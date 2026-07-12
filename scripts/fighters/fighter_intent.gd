class_name FighterIntent
extends RefCounted
## One tick of controller output — the only interface between a controller
## (human or AI) and fighter.gd's FSM. See docs/plan.md "intent contract".

var move_x := 0.0 ## -1..1, world direction (negative = -X)
var jump := false ## edge-triggered
var attack_id := &"" ## resolved attack id (e.g. &"sweep"); empty = none
var block := false ## held


func clear() -> void:
	move_x = 0.0
	jump = false
	attack_id = &""
	block = false
