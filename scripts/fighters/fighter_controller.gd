class_name FighterController
extends Node
## Base controller: owns the FighterIntent the fighter consumes. fighter.gd pulls
## compute_intent() explicitly at the top of its own _physics_process, so there is
## no tree-order frame lag. State gates (can't act in HIT_STUN etc.) live in
## fighter.gd and therefore bind player and AI identically.

var intent := FighterIntent.new()


func compute_intent(_delta: float) -> void:
	intent.clear()
