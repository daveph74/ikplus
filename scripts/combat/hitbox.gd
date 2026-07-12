class_name Hitbox
extends Area3D
## Attack contact detector. Enabled via set_deferred on the first geometric
## active tick (the deferred queue flushes BEFORE that tick's physics step, so
## the step already sees it). Overlap lists always report the PREVIOUS physics
## step, so the owner polls on ticks [active_start+1 .. active_end+1] and
## disables only after the final poll — set_monitoring(false) clears unread
## results. Consequence: a hit registers one tick after geometric contact.

var owner_fighter: Fighter


func _ready() -> void:
	var n: Node = self
	while n != null and not n is Fighter:
		n = n.get_parent()
	owner_fighter = n as Fighter


func activate() -> void:
	set_deferred(&"monitoring", true)


func deactivate() -> void:
	set_deferred(&"monitoring", false)


func snap_to(world_pos: Vector3) -> void:
	global_position = world_pos
