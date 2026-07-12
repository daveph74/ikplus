class_name AttackData
extends Resource
## Data-driven attack definition. Combat timing is ALWAYS tick-counted from these
## frame fields at 60 physics tps — never from animation callbacks. Clips are
## retimed to total_seconds() via play()'s custom_speed, so mismatched clip
## lengths (e.g. after a GLB swap) never change combat timing.

enum Height { HIGH, MID, LOW, AIR } ## LOW bypasses block; AIR blocks as HIGH
enum HitboxType { HAND, FOOT }

@export var id := &""
@export var startup_frames := 6
@export var active_frames := 3
@export var recovery_frames := 12
@export var score_value := 1 ## 1 normal, 2 strong
@export var hit_stun_frames := 16
@export var knockback := Vector2(2.5, 0.0) ## x away from attacker, y vertical
@export var height := Height.HIGH
@export var causes_knockdown := false
@export var hits_airborne := false
@export var hit_stop_ms := 70
@export var hitbox_type := HitboxType.HAND
@export var anim_name := &"" ## several attacks may share one clip (retimed per attack)


func total_frames() -> int:
	return startup_frames + active_frames + recovery_frames


func total_seconds() -> float:
	return total_frames() / 60.0


func hit_stop_frames() -> int:
	return int(round(hit_stop_ms * 60.0 / 1000.0))
