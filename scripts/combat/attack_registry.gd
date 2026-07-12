class_name AttackRegistry
extends RefCounted
## Single source of truth for the attack set (build step 5 completes the 9-row
## table from docs/plan.md). Used by fighters (lookup) and FighterVisual (clip
## generation for every distinct anim_name).

const ATTACKS := {
	&"punch_high": preload("res://resources/attacks/punch_high.tres"),
}


static func get_attack(attack_id: StringName) -> AttackData:
	return ATTACKS.get(attack_id) as AttackData


static func all() -> Array:
	return ATTACKS.values()
