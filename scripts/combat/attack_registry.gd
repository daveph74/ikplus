class_name AttackRegistry
extends RefCounted
## Single source of truth for the attack set (build step 5 completes the 9-row
## table from docs/plan.md). Used by fighters (lookup) and FighterVisual (clip
## generation for every distinct anim_name).

const ATTACKS := {
	&"punch_high": preload("res://resources/attacks/punch_high.tres"),
	&"punch_body": preload("res://resources/attacks/punch_body.tres"),
	&"punch_low": preload("res://resources/attacks/punch_low.tres"),
	&"kick_high": preload("res://resources/attacks/kick_high.tres"),
	&"kick_front": preload("res://resources/attacks/kick_front.tres"),
	&"kick_round": preload("res://resources/attacks/kick_round.tres"),
	&"sweep": preload("res://resources/attacks/sweep.tres"),
	&"kick_jump": preload("res://resources/attacks/kick_jump.tres"),
	&"punch_jump": preload("res://resources/attacks/punch_jump.tres"),
}


static func get_attack(attack_id: StringName) -> AttackData:
	return ATTACKS.get(attack_id) as AttackData


static func all() -> Array:
	return ATTACKS.values()
