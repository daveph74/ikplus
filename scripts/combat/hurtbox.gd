class_name Hurtbox
extends Area3D
## Passive contact target (monitorable, never monitoring). Centered on the body
## (local X = 0) so facing flips need no offset mirroring. owner_fighter enables
## self-hit exclusion and hit routing.

var owner_fighter: Fighter


func _ready() -> void:
	var n: Node = self
	while n != null and not n is Fighter:
		n = n.get_parent()
	owner_fighter = n as Fighter
