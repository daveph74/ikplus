class_name FighterVisual
extends Node3D
## Owns the fighter's look and animation. If no AnimationPlayer exists under this
## node (the GLB-swap case brings its own), a primitive-mesh humanoid is built
## under Rig and all placeholder clips are generated procedurally as Animation
## resources — attack clips are later retimed via play()'s custom_speed, never
## speed_scale (that knob is reserved for hit-stop; the two multiply).
##
## GLB-swap contract (docs/architecture.md): replacement rig mounts at Rig;
## AnimationPlayer and AttachHandR/AttachFootR are discovered by find_child
## anywhere under this node; 15 canonical animation names are required.

const JOINTS: Array[String] = [
	"Rig/Hips",
	"Rig/Hips/Torso",
	"Rig/Hips/Torso/Head",
	"Rig/Hips/Torso/ShoulderR",
	"Rig/Hips/Torso/ShoulderL",
	"Rig/Hips/HipR",
	"Rig/Hips/HipR/KneeR",
	"Rig/Hips/HipL",
	"Rig/Hips/HipL/KneeL",
]
const HIPS := "Rig/Hips"
const REST_HIPS_POS := Vector3(0, 0.95, 0)
const GUARD_R := 1.1 ## shoulder rot-Z: arm forward-up guard
const GUARD_L := 0.9

@export var gi_color := Color(0.92, 0.9, 0.85)
@export var belt_color := Color(0.16, 0.16, 0.16)
@export var skin_color := Color(0.85, 0.66, 0.5)

## GLB adapter knobs (docs/architecture.md "GLB-swap contract"): rig_scene is an
## imported character scene mounted as Rig at runtime (per-fighter via
## FighterConfig). Foreign rigs are auto-normalized: height scaled to
## target_height, yawed by rig_facing_deg (glTF characters usually face +Z; our
## contract is +X), clips resolved through CLIP_ALIASES, and missing
## AttachHandR/AttachFootR created as BoneAttachment3D by bone-name heuristics.
@export var rig_scene: PackedScene = null
@export var rig_facing_deg := 90.0
@export var target_height := 1.75
## Canonical merged clips (tools/build_fighter_rig.gd). When set, REPLACES the
## foreign rig's own libraries before clip mapping — the merged clips already
## use canonical names, and per-animation exports (Meshy) each carry only one
## stray clip anyway.
@export var anim_library: AnimationLibrary = null

## canonical clip -> candidate foreign names (normalized: lowercase alnum only),
## tried in order — exact match first across all clips, then containment.
const CLIP_ALIASES := {
	&"idle": ["idle", "fightidle", "fightingidle", "stance", "breathingidle"],
	&"walk_fwd": ["walkfwd", "walkforward", "walkingforward", "walking", "walk"],
	&"walk_back": ["walkback", "walkbackward", "walkingbackward", "walkingbackwards", "backwalk"],
	&"jump": ["jump", "jumping", "jumpup"],
	&"punch_high": ["punchhigh", "highpunch", "punching", "punch", "jab", "cross"],
	&"punch_low": ["punchlow", "lowpunch", "bodypunch", "hook", "uppercut"],
	&"kick_front": ["kickfront", "frontkick", "pushkick", "kicking", "kick"],
	&"kick_round": ["kickround", "roundhouse", "roundkick", "highkick", "spinkick"],
	&"sweep": ["sweep", "legsweep", "lowkick"],
	&"kick_jump": ["kickjump", "jumpkick", "flyingkick", "airkick"],
	&"block": ["block", "blocking", "guard", "defend"],
	&"hit_react": ["hitreact", "hitreaction", "gettinghit", "lighthit", "hit", "impact"],
	&"knockdown": ["knockdown", "knockeddown", "fallingback", "falldown", "death", "dying", "ko"],
	&"recovery": ["recovery", "getup", "gettingup", "standup", "standingup"],
	&"victory": ["victory", "victorycheer", "win", "cheer", "celebrate", "taunt"],
}

var _player: AnimationPlayer
var _clip_map: Dictionary = {} ## canonical StringName -> actual clip StringName (foreign rigs only)
var _foreign := false


func _ready() -> void:
	if rig_scene != null:
		var old := get_node_or_null("Rig")
		if old != null:
			old.free()
		var rig := rig_scene.instantiate()
		rig.name = "Rig"
		add_child(rig)
	_player = find_child("AnimationPlayer", true, false) as AnimationPlayer
	_foreign = rig_scene != null or _player != null
	if not _foreign:
		_build_placeholder_rig()
		_build_animation_player()
	elif _player != null:
		if anim_library != null:
			for lib_name in _player.get_animation_library_list():
				_player.remove_animation_library(lib_name)
			_player.add_animation_library(&"", anim_library)
		_normalize_foreign_rig()
		_build_clip_map()
		_ensure_attachments()
	else:
		push_warning("FighterVisual: rig_scene provided no AnimationPlayer — fighter will be static")
	play_anim(&"idle")


## Canonical name -> playable clip name. Procedural rigs are identity; foreign
## rigs go through the alias map (&"" when nothing matched — callers no-op).
func resolve_clip(canonical: StringName) -> StringName:
	if not _foreign:
		return canonical
	return _clip_map.get(canonical, &"")


func play_anim(anim_name: StringName, custom_speed := 1.0) -> void:
	var clip := resolve_clip(anim_name)
	if _player == null or clip == &"" or not _player.has_animation(clip):
		return
	if _player.current_animation != String(clip):
		_player.play(clip, -1.0, custom_speed)


func set_frozen(frozen: bool) -> void:
	## Hit-stop freeze only — attack retiming rides play()'s custom_speed.
	if _player != null:
		_player.speed_scale = 0.0 if frozen else 1.0


func play_attack(attack: AttackData) -> void:
	## Retimes the clip to the attack's tick-driven duration via custom_speed
	## (never speed_scale — that's hit-stop's knob; the two multiply). stop()
	## first so back-to-back attacks sharing a clip restart from pose zero.
	var clip := resolve_clip(attack.anim_name)
	if _player == null or clip == &"" or not _player.has_animation(clip):
		return
	var clip_len := _player.get_animation(clip).length
	_player.stop()
	_player.play(clip, -1.0, clip_len / attack.total_seconds())


# --- foreign (GLB) rig adaptation -------------------------------------------


func _normalize_foreign_rig() -> void:
	var rig := get_node_or_null("Rig") as Node3D
	if rig == null:
		return
	rig.rotation_degrees.y = rig_facing_deg
	var aabb := _combined_aabb(rig)
	if aabb.size.y > 0.05:
		var s := target_height / aabb.size.y
		rig.scale = Vector3.ONE * s
		rig.position.y = -aabb.position.y * s # feet on the floor


func _combined_aabb(rig: Node3D) -> AABB:
	var into_rig := rig.global_transform.affine_inverse()
	var merged := AABB()
	var first := true
	for mi: Node in rig.find_children("", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var local := (into_rig * m.global_transform) * m.get_aabb()
		merged = local if first else merged.merge(local)
		first = false
	return merged


func _build_clip_map() -> void:
	_clip_map.clear()
	var clips: Dictionary = {} # normalized -> actual StringName
	for clip_name in _player.get_animation_list():
		clips[_normalize_name(clip_name)] = StringName(clip_name)
	for canonical: StringName in CLIP_ALIASES:
		var found := &""
		for candidate: String in CLIP_ALIASES[canonical]:
			if clips.has(candidate): # exact normalized match wins
				found = clips[candidate]
				break
		if found == &"":
			for candidate: String in CLIP_ALIASES[canonical]:
				for norm: String in clips: # containment fallback
					if norm.contains(candidate):
						found = clips[norm]
						break
				if found != &"":
					break
		if found != &"":
			_clip_map[canonical] = found
		else:
			print("FighterVisual: no foreign clip matched '", canonical, "' — that move plays without animation")


func _normalize_name(clip_name: String) -> String:
	var lowered := clip_name.get_slice("/", clip_name.get_slice_count("/") - 1).to_lower()
	var out := ""
	for ch in lowered:
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out


## The combat contract needs AttachHandR/AttachFootR. A raw GLB won't have them,
## so create BoneAttachment3D nodes on the rig's skeleton by bone-name heuristics.
func _ensure_attachments() -> void:
	if find_child("AttachHandR", true, false) == null:
		_create_bone_attachment("AttachHandR", ["righthand", "handr", "rhand", "handright"])
	if find_child("AttachFootR", true, false) == null:
		_create_bone_attachment(
			"AttachFootR", ["rightfoot", "footr", "rfoot", "footright", "righttoebase"]
		)


func _create_bone_attachment(attach_name: String, candidates: Array) -> void:
	var skels := find_children("", "Skeleton3D", true, false)
	if skels.is_empty():
		push_warning("FighterVisual: no Skeleton3D — cannot create ", attach_name)
		return
	var skel := skels[0] as Skeleton3D
	var bone_idx := -1
	for candidate: String in candidates:
		for i in skel.get_bone_count():
			var norm := _normalize_name(skel.get_bone_name(i))
			if norm == candidate or norm.contains(candidate):
				bone_idx = i
				break
		if bone_idx >= 0:
			break
	if bone_idx < 0:
		push_warning("FighterVisual: no bone matched for ", attach_name)
		return
	var attachment := BoneAttachment3D.new()
	attachment.name = attach_name
	skel.add_child(attachment)
	attachment.bone_name = skel.get_bone_name(bone_idx)


# --- placeholder rig -------------------------------------------------------


## Joint pivots (names, parents, positions) are LOAD-BEARING — animations,
## attachment reach, and the combat smoke asserts all key off them. Everything
## hanging off a pivot is pure cosmetics and safe to restyle. Axes: the fighter
## faces +X, so box dims read (depth, height, width).
func _build_placeholder_rig() -> void:
	var rig := get_node("Rig") as Node3D
	var gi := _mat(gi_color)
	var gi_dark := _mat(gi_color.darkened(0.22))
	var trim := _mat(gi_color.lightened(0.35))
	var belt := _mat(belt_color)
	var skin := _mat(skin_color)
	var hair := _mat(Color(0.13, 0.1, 0.09))

	var hips := _pivot(rig, "Hips", REST_HIPS_POS)
	_box(hips, Vector3(0.22, 0.16, 0.30), Vector3.ZERO, gi_dark)

	var torso := _pivot(hips, "Torso", Vector3(0, 0.09, 0))
	_box(torso, Vector3(0.25, 0.36, 0.44), Vector3(0, 0.36, 0), gi) # chest — wider than deep
	_box(torso, Vector3(0.21, 0.22, 0.32), Vector3(0, 0.12, 0), gi) # waist taper
	# Gi lapels: a V crossing the chest's front (+X) face.
	_box(torso, Vector3(0.02, 0.36, 0.07), Vector3(0.135, 0.36, 0.08), trim, Vector3(25, 0, 0))
	_box(torso, Vector3(0.02, 0.36, 0.07), Vector3(0.135, 0.36, -0.08), trim, Vector3(-25, 0, 0))
	# Belt with front knot and hanging ends.
	_box(torso, Vector3(0.24, 0.08, 0.34), Vector3(0, 0.02, 0), belt)
	_box(torso, Vector3(0.08, 0.08, 0.10), Vector3(0.15, 0.02, 0), belt)
	_box(torso, Vector3(0.03, 0.20, 0.045), Vector3(0.15, -0.10, 0.035), belt)
	_box(torso, Vector3(0.03, 0.20, 0.045), Vector3(0.15, -0.10, -0.035), belt)
	# Shoulder pads where the sleeves meet the jacket.
	_sphere(torso, 0.085, Vector3(0, 0.5, 0.26), gi)
	_sphere(torso, 0.085, Vector3(0, 0.5, -0.26), gi)
	_cylinder(torso, 0.055, 0.10, Vector3(0, 0.56, 0), skin) # neck

	var head := _pivot(torso, "Head", Vector3(0, 0.62, 0))
	_sphere(head, 0.125, Vector3(0, 0.08, 0), skin)
	_hemisphere(head, 0.135, Vector3(0, 0.105, 0), hair) # hair cap
	_cylinder(head, 0.132, 0.05, Vector3(0, 0.085, 0), belt) # headband in belt color
	_box(head, Vector3(0.03, 0.035, 0.035), Vector3(0.125, 0.05, 0), skin) # nose hint

	var shoulder_r := _pivot(torso, "ShoulderR", Vector3(0, 0.5, 0.26))
	_capsule(shoulder_r, 0.07, 0.26, Vector3(0, -0.14, 0), gi) # gi sleeve (3/4 length)
	_capsule(shoulder_r, 0.055, 0.24, Vector3(0.025, -0.40, 0), skin, Vector3(0, 0, 8)) # bare forearm
	var hand_r := _pivot(shoulder_r, "AttachHandR", Vector3(0, -0.52, 0))
	_sphere(hand_r, 0.07, Vector3.ZERO, skin)

	var shoulder_l := _pivot(torso, "ShoulderL", Vector3(0, 0.5, -0.26))
	_capsule(shoulder_l, 0.07, 0.26, Vector3(0, -0.14, 0), gi)
	_capsule(shoulder_l, 0.055, 0.24, Vector3(0.025, -0.40, 0), skin, Vector3(0, 0, 8))
	var hand_l := _pivot(shoulder_l, "HandL", Vector3(0, -0.52, 0))
	_sphere(hand_l, 0.07, Vector3.ZERO, skin)

	var hip_r := _pivot(hips, "HipR", Vector3(0, -0.06, 0.1))
	_capsule(hip_r, 0.085, 0.40, Vector3(0, -0.19, 0), gi) # loose trouser thigh
	var knee_r := _pivot(hip_r, "KneeR", Vector3(0, -0.42, 0))
	_capsule(knee_r, 0.07, 0.30, Vector3(0, -0.155, 0), gi) # trouser shin
	_cylinder(knee_r, 0.075, 0.05, Vector3(0, -0.30, 0), gi_dark) # cuff
	_capsule(knee_r, 0.045, 0.10, Vector3(0, -0.37, 0), skin) # bare ankle
	var foot_r := _pivot(knee_r, "AttachFootR", Vector3(0, -0.42, 0))
	_box(foot_r, Vector3(0.22, 0.07, 0.10), Vector3(0.05, 0.03, 0), skin)

	var hip_l := _pivot(hips, "HipL", Vector3(0, -0.06, -0.1))
	_capsule(hip_l, 0.085, 0.40, Vector3(0, -0.19, 0), gi)
	var knee_l := _pivot(hip_l, "KneeL", Vector3(0, -0.42, 0))
	_capsule(knee_l, 0.07, 0.30, Vector3(0, -0.155, 0), gi)
	_cylinder(knee_l, 0.075, 0.05, Vector3(0, -0.30, 0), gi_dark)
	_capsule(knee_l, 0.045, 0.10, Vector3(0, -0.37, 0), skin)
	var foot_l := _pivot(knee_l, "FootL", Vector3(0, -0.42, 0))
	_box(foot_l, Vector3(0.22, 0.07, 0.10), Vector3(0.05, 0.03, 0), skin)


# --- procedural animations -------------------------------------------------


func _build_animation_player() -> void:
	_player = AnimationPlayer.new()
	_player.name = "AnimationPlayer"
	add_child(_player)
	var lib := AnimationLibrary.new()
	lib.add_animation(&"idle", _anim_idle())
	lib.add_animation(&"walk_fwd", _anim_walk(false))
	lib.add_animation(&"walk_back", _anim_walk(true))
	lib.add_animation(&"jump", _anim_jump())
	lib.add_animation(&"hit_react", _anim_hit_react())
	lib.add_animation(&"block", _anim_block())
	lib.add_animation(&"knockdown", _anim_knockdown())
	lib.add_animation(&"recovery", _anim_recovery())
	lib.add_animation(&"victory", _anim_victory())
	# One clip per DISTINCT anim_name; clips are generated at that attack's
	# total_seconds() with the strike pose exactly at startup_frames/60.
	# Attacks sharing a clip get retimed by play_attack()'s custom_speed.
	for attack: AttackData in AttackRegistry.all():
		if not lib.has_animation(attack.anim_name):
			lib.add_animation(attack.anim_name, _anim_strike(attack))
	_player.add_animation_library(&"", lib)


## rot_keys: { joint_path: [[time, euler Vector3], ...] }. Every joint in JOINTS
## is keyed in every clip (rest pose when absent) so switching clips never leaves
## a stale pose on an untracked joint.
func _make_anim(length: float, looped: bool, rot_keys: Dictionary, hips_pos_keys: Array) -> Animation:
	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = Animation.LOOP_LINEAR if looped else Animation.LOOP_NONE
	for joint in JOINTS:
		var idx := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(idx, NodePath(joint))
		var keys: Array = rot_keys.get(joint, [[0.0, Vector3.ZERO]])
		for k: Array in keys:
			anim.rotation_track_insert_key(idx, k[0], Quaternion.from_euler(k[1]))
	var pidx := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(pidx, NodePath(HIPS))
	var pkeys: Array = hips_pos_keys
	if pkeys.is_empty():
		pkeys = [[0.0, REST_HIPS_POS]]
	for k: Array in pkeys:
		anim.position_track_insert_key(pidx, k[0], k[1])
	return anim


func _anim_idle() -> Animation:
	return _make_anim(1.6, true, {
		"Rig/Hips/Torso": [[0.0, Vector3(0, 0, -0.06)]],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, GUARD_R)],
			[0.8, Vector3(0, 0, GUARD_R - 0.08)],
			[1.6, Vector3(0, 0, GUARD_R)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, GUARD_L)],
			[0.8, Vector3(0, 0, GUARD_L + 0.08)],
			[1.6, Vector3(0, 0, GUARD_L)],
		],
		"Rig/Hips/HipR": [[0.0, Vector3(0, 0, 0.06)]],
		"Rig/Hips/HipR/KneeR": [[0.0, Vector3(0, 0, -0.12)]],
		"Rig/Hips/HipL": [[0.0, Vector3(0, 0, -0.02)]],
		"Rig/Hips/HipL/KneeL": [[0.0, Vector3(0, 0, -0.08)]],
	}, [
		[0.0, REST_HIPS_POS],
		[0.8, REST_HIPS_POS + Vector3(0, -0.02, 0)],
		[1.6, REST_HIPS_POS],
	])


func _anim_walk(back: bool) -> Animation:
	var s := -1.0 if back else 1.0
	var t := 0.7
	var bob := REST_HIPS_POS + Vector3(0, -0.025, 0)
	return _make_anim(t, true, {
		"Rig/Hips/Torso": [[0.0, Vector3(0, 0, -0.08)]],
		"Rig/Hips/Torso/ShoulderR": [[0.0, Vector3(0, 0, GUARD_R)]],
		"Rig/Hips/Torso/ShoulderL": [[0.0, Vector3(0, 0, GUARD_L)]],
		"Rig/Hips/HipR": [
			[0.0, Vector3(0, 0, s * 0.45)],
			[t * 0.5, Vector3(0, 0, s * -0.35)],
			[t, Vector3(0, 0, s * 0.45)],
		],
		"Rig/Hips/HipR/KneeR": [
			[0.0, Vector3(0, 0, -0.15)],
			[t * 0.25, Vector3(0, 0, -0.5)],
			[t * 0.5, Vector3(0, 0, -0.1)],
			[t * 0.75, Vector3(0, 0, -0.5)],
			[t, Vector3(0, 0, -0.15)],
		],
		"Rig/Hips/HipL": [
			[0.0, Vector3(0, 0, s * -0.35)],
			[t * 0.5, Vector3(0, 0, s * 0.45)],
			[t, Vector3(0, 0, s * -0.35)],
		],
		"Rig/Hips/HipL/KneeL": [
			[0.0, Vector3(0, 0, -0.1)],
			[t * 0.25, Vector3(0, 0, -0.5)],
			[t * 0.5, Vector3(0, 0, -0.15)],
			[t * 0.75, Vector3(0, 0, -0.5)],
			[t, Vector3(0, 0, -0.1)],
		],
	}, [
		[0.0, REST_HIPS_POS],
		[t * 0.25, bob],
		[t * 0.5, REST_HIPS_POS],
		[t * 0.75, bob],
		[t, REST_HIPS_POS],
	])


func _anim_jump() -> Animation:
	return _make_anim(0.5, false, {
		"Rig/Hips/Torso": [
			[0.0, Vector3(0, 0, -0.08)],
			[0.15, Vector3(0, 0, -0.2)],
			[0.45, Vector3(0, 0, -0.05)],
		],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, GUARD_R)],
			[0.15, Vector3(0, 0, 1.7)],
			[0.45, Vector3(0, 0, 1.2)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, GUARD_L)],
			[0.15, Vector3(0, 0, 1.6)],
			[0.45, Vector3(0, 0, 1.0)],
		],
		"Rig/Hips/HipR": [
			[0.0, Vector3.ZERO],
			[0.15, Vector3(0, 0, 1.1)],
			[0.45, Vector3(0, 0, 0.15)],
		],
		"Rig/Hips/HipR/KneeR": [
			[0.0, Vector3.ZERO],
			[0.15, Vector3(0, 0, -1.7)],
			[0.45, Vector3(0, 0, -0.25)],
		],
		"Rig/Hips/HipL": [
			[0.0, Vector3.ZERO],
			[0.15, Vector3(0, 0, 1.0)],
			[0.45, Vector3(0, 0, 0.1)],
		],
		"Rig/Hips/HipL/KneeL": [
			[0.0, Vector3.ZERO],
			[0.15, Vector3(0, 0, -1.6)],
			[0.45, Vector3(0, 0, -0.2)],
		],
	}, [])


func _anim_hit_react() -> Animation:
	return _make_anim(0.35, false, {
		"Rig/Hips/Torso": [
			[0.0, Vector3(0, 0, 0.3)],
			[0.2, Vector3(0, 0, 0.12)],
			[0.35, Vector3(0, 0, -0.06)],
		],
		"Rig/Hips/Torso/Head": [
			[0.0, Vector3(0, 0, 0.25)],
			[0.35, Vector3.ZERO],
		],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, 0.4)],
			[0.35, Vector3(0, 0, GUARD_R)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, 0.3)],
			[0.35, Vector3(0, 0, GUARD_L)],
		],
		"Rig/Hips/HipR/KneeR": [[0.0, Vector3(0, 0, -0.25)]],
		"Rig/Hips/HipL/KneeL": [[0.0, Vector3(0, 0, -0.2)]],
	}, [])


func _anim_block() -> Animation:
	## Looping guard: arms crossed high, slight crouch.
	return _make_anim(0.8, true, {
		"Rig/Hips/Torso": [[0.0, Vector3(0, 0, 0.12)]],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, 1.3)],
			[0.4, Vector3(0, 0, 1.38)],
			[0.8, Vector3(0, 0, 1.3)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, 1.1)],
			[0.4, Vector3(0, 0, 1.18)],
			[0.8, Vector3(0, 0, 1.1)],
		],
		"Rig/Hips/HipR": [[0.0, Vector3(0, 0, 0.15)]],
		"Rig/Hips/HipR/KneeR": [[0.0, Vector3(0, 0, -0.3)]],
		"Rig/Hips/HipL": [[0.0, Vector3(0, 0, -0.05)]],
		"Rig/Hips/HipL/KneeL": [[0.0, Vector3(0, 0, -0.25)]],
	}, [
		[0.0, REST_HIPS_POS + Vector3(0, -0.08, 0)],
		[0.4, REST_HIPS_POS + Vector3(0, -0.1, 0)],
		[0.8, REST_HIPS_POS + Vector3(0, -0.08, 0)],
	])


func _anim_knockdown() -> Animation:
	## One-shot fall: torso rotates back, hips drop, legs splay — ends prone.
	return _make_anim(0.5, false, {
		"Rig/Hips/Torso": [
			[0.0, Vector3(0, 0, -0.06)],
			[0.25, Vector3(0, 0, -0.8)],
			[0.5, Vector3(0, 0, -1.3)],
		],
		"Rig/Hips/Torso/Head": [
			[0.0, Vector3.ZERO],
			[0.5, Vector3(0, 0, -0.3)],
		],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, GUARD_R)],
			[0.5, Vector3(0, 0, -0.4)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, GUARD_L)],
			[0.5, Vector3(0, 0, -0.3)],
		],
		"Rig/Hips/HipR": [
			[0.0, Vector3.ZERO],
			[0.5, Vector3(0, 0, -1.4)],
		],
		"Rig/Hips/HipR/KneeR": [
			[0.0, Vector3(0, 0, -0.15)],
			[0.5, Vector3(0, 0, -0.1)],
		],
		"Rig/Hips/HipL": [
			[0.0, Vector3(0, 0, -0.05)],
			[0.5, Vector3(0, 0, -1.35)],
		],
		"Rig/Hips/HipL/KneeL": [
			[0.0, Vector3(0, 0, -0.2)],
			[0.5, Vector3(0, 0, -0.1)],
		],
	}, [
		[0.0, REST_HIPS_POS],
		[0.5, Vector3(0, 0.25, 0)],
	])


func _anim_recovery() -> Animation:
	## One-shot get-up: reverse of knockdown, back to standing guard.
	return _make_anim(0.6, false, {
		"Rig/Hips/Torso": [
			[0.0, Vector3(0, 0, -1.3)],
			[0.35, Vector3(0, 0, -0.4)],
			[0.6, Vector3(0, 0, -0.06)],
		],
		"Rig/Hips/Torso/Head": [
			[0.0, Vector3(0, 0, -0.3)],
			[0.6, Vector3.ZERO],
		],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, -0.4)],
			[0.6, Vector3(0, 0, GUARD_R)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, -0.3)],
			[0.6, Vector3(0, 0, GUARD_L)],
		],
		"Rig/Hips/HipR": [
			[0.0, Vector3(0, 0, -1.4)],
			[0.6, Vector3(0, 0, 0.06)],
		],
		"Rig/Hips/HipR/KneeR": [
			[0.0, Vector3(0, 0, -0.1)],
			[0.6, Vector3(0, 0, -0.15)],
		],
		"Rig/Hips/HipL": [
			[0.0, Vector3(0, 0, -1.35)],
			[0.6, Vector3(0, 0, -0.02)],
		],
		"Rig/Hips/HipL/KneeL": [
			[0.0, Vector3(0, 0, -0.1)],
			[0.6, Vector3(0, 0, -0.08)],
		],
	}, [
		[0.0, Vector3(0, 0.25, 0)],
		[0.6, REST_HIPS_POS],
	])


func _anim_victory() -> Animation:
	## One-shot: both arms up, slight hop via hips position.
	return _make_anim(1.2, false, {
		"Rig/Hips/Torso": [
			[0.0, Vector3(0, 0, -0.06)],
			[0.3, Vector3(0, 0, 0.1)],
			[1.2, Vector3(0, 0, 0.05)],
		],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, GUARD_R)],
			[0.3, Vector3(0, 0, -2.6)],
			[1.2, Vector3(0, 0, -2.5)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, GUARD_L)],
			[0.3, Vector3(0, 0, -2.7)],
			[1.2, Vector3(0, 0, -2.6)],
		],
		"Rig/Hips/HipR": [[0.0, Vector3.ZERO]],
		"Rig/Hips/HipR/KneeR": [[0.0, Vector3(0, 0, -0.15)]],
		"Rig/Hips/HipL": [[0.0, Vector3.ZERO]],
		"Rig/Hips/HipL/KneeL": [[0.0, Vector3(0, 0, -0.15)]],
	}, [
		[0.0, REST_HIPS_POS],
		[0.3, REST_HIPS_POS + Vector3(0, 0.15, 0)],
		[0.5, REST_HIPS_POS],
		[1.2, REST_HIPS_POS],
	])


func _anim_sweep(attack: AttackData) -> Animation:
	## Deep crouch (hips drop) + spinning low leg extended + torso twist. The
	## dropped hips plus the extended leg put the strike reach near the floor.
	var total := attack.total_seconds()
	var t_hit := attack.startup_frames / 60.0
	var t_hold := (attack.startup_frames + attack.active_frames) / 60.0
	var crouch_hips := Vector3(0, 0.45, 0)
	return _make_anim(total, false, {
		"Rig/Hips/Torso": [
			[0.0, Vector3(0, 0, -0.06)],
			[t_hit * 0.5, Vector3(0, 0.25, 0.15)],
			[t_hit, Vector3(0, 0.55, 0.35)],
			[t_hold, Vector3(0, 0.55, 0.35)],
			[total, Vector3(0, 0, -0.06)],
		],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, GUARD_R)],
			[t_hit, Vector3(0, 0, 0.5)],
			[total, Vector3(0, 0, GUARD_R)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, GUARD_L)],
			[t_hit, Vector3(0, 0, 0.4)],
			[total, Vector3(0, 0, GUARD_L)],
		],
		"Rig/Hips/HipR": [
			[0.0, Vector3.ZERO],
			[t_hit * 0.5, Vector3(0, 0, 0.7)],
			[t_hit, Vector3(0, 0, 1.4)],
			[t_hold, Vector3(0, 0, 1.4)],
			[total, Vector3.ZERO],
		],
		"Rig/Hips/HipR/KneeR": [
			[0.0, Vector3(0, 0, -0.15)],
			[t_hit * 0.5, Vector3(0, 0, -0.6)],
			[t_hit, Vector3(0, 0, -0.05)],
			[t_hold, Vector3(0, 0, -0.05)],
			[total, Vector3(0, 0, -0.15)],
		],
		"Rig/Hips/HipL": [
			[0.0, Vector3(0, 0, -0.1)],
			[t_hit, Vector3(0, 0, -0.9)],
			[total, Vector3(0, 0, -0.1)],
		],
		"Rig/Hips/HipL/KneeL": [
			[0.0, Vector3(0, 0, -0.2)],
			[t_hit, Vector3(0, 0, -1.3)],
			[total, Vector3(0, 0, -0.2)],
		],
	}, [
		[0.0, REST_HIPS_POS],
		[t_hit * 0.5, REST_HIPS_POS.lerp(crouch_hips, 0.6)],
		[t_hit, crouch_hips],
		[t_hold, crouch_hips],
		[total, REST_HIPS_POS],
	])


func _anim_kick_round(attack: AttackData) -> Animation:
	## High roundhouse: leg arcs high with torso counter-rotation on Y.
	var total := attack.total_seconds()
	var t_hit := attack.startup_frames / 60.0
	var t_hold := (attack.startup_frames + attack.active_frames) / 60.0
	return _make_anim(total, false, {
		"Rig/Hips/Torso": [
			[0.0, Vector3(0, 0, -0.06)],
			[t_hit * 0.5, Vector3(0, -0.35, 0.1)],
			[t_hit, Vector3(0, -0.6, 0.2)],
			[t_hold, Vector3(0, -0.6, 0.2)],
			[total, Vector3(0, 0, -0.06)],
		],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, GUARD_R)],
			[t_hit, Vector3(0, 0, 0.9)],
			[total, Vector3(0, 0, GUARD_R)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, GUARD_L)],
			[t_hit, Vector3(0, 0, 1.5)],
			[total, Vector3(0, 0, GUARD_L)],
		],
		"Rig/Hips/HipR": [
			[0.0, Vector3.ZERO],
			[t_hit * 0.5, Vector3(0.3, 0, 0.9)],
			[t_hit, Vector3(0.6, 0, 1.55)],
			[t_hold, Vector3(0.6, 0, 1.55)],
			[total, Vector3.ZERO],
		],
		"Rig/Hips/HipR/KneeR": [
			[0.0, Vector3(0, 0, -0.15)],
			[t_hit * 0.5, Vector3(0, 0, -1.1)],
			[t_hit, Vector3(0, 0, -0.1)],
			[t_hold, Vector3(0, 0, -0.1)],
			[total, Vector3(0, 0, -0.15)],
		],
		"Rig/Hips/HipL": [[0.0, Vector3(0, 0, -0.05)]],
		"Rig/Hips/HipL/KneeL": [[0.0, Vector3(0, 0, -0.2)]],
	}, [
		[0.0, REST_HIPS_POS],
		[t_hit, REST_HIPS_POS + Vector3(0.05, 0.05, 0)],
		[total, REST_HIPS_POS],
	])


func _anim_kick_jump(attack: AttackData) -> Animation:
	## Flying side-kick: lead leg extended forward, trail leg tucked hard,
	## torso leaned back.
	var total := attack.total_seconds()
	var t_hit := attack.startup_frames / 60.0
	var t_hold := (attack.startup_frames + attack.active_frames) / 60.0
	return _make_anim(total, false, {
		"Rig/Hips/Torso": [
			[0.0, Vector3(0, 0, -0.1)],
			[t_hit, Vector3(0, 0, -0.5)],
			[t_hold, Vector3(0, 0, -0.5)],
			[total, Vector3(0, 0, -0.1)],
		],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, GUARD_R)],
			[t_hit, Vector3(0, 0, 0.9)],
			[total, Vector3(0, 0, GUARD_R)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, GUARD_L)],
			[t_hit, Vector3(0, 0, 1.4)],
			[total, Vector3(0, 0, GUARD_L)],
		],
		"Rig/Hips/HipR": [
			[0.0, Vector3.ZERO],
			[t_hit * 0.5, Vector3(0, 0, 0.9)],
			[t_hit, Vector3(0, 0, 1.5)],
			[t_hold, Vector3(0, 0, 1.5)],
			[total, Vector3.ZERO],
		],
		"Rig/Hips/HipR/KneeR": [
			[0.0, Vector3(0, 0, -0.15)],
			[t_hit * 0.5, Vector3(0, 0, -0.9)],
			[t_hit, Vector3(0, 0, -0.05)],
			[t_hold, Vector3(0, 0, -0.05)],
			[total, Vector3(0, 0, -0.15)],
		],
		"Rig/Hips/HipL": [
			[0.0, Vector3(0, 0, -1.1)],
			[t_hit, Vector3(0, 0, -1.4)],
			[total, Vector3(0, 0, -1.1)],
		],
		"Rig/Hips/HipL/KneeL": [
			[0.0, Vector3(0, 0, -1.6)],
			[t_hit, Vector3(0, 0, -1.8)],
			[total, Vector3(0, 0, -1.6)],
		],
	}, [])


func _anim_strike(attack: AttackData) -> Animation:
	match attack.anim_name:
		&"sweep":
			return _anim_sweep(attack)
		&"kick_round":
			return _anim_kick_round(attack)
		&"kick_jump":
			return _anim_kick_jump(attack)
		_:
			pass # fall through to the generic HAND/FOOT poses below
	var total := attack.total_seconds()
	var t_hit := attack.startup_frames / 60.0
	var t_hold := (attack.startup_frames + attack.active_frames) / 60.0
	if attack.hitbox_type == AttackData.HitboxType.HAND:
		return _make_anim(total, false, {
			"Rig/Hips/Torso": [
				[0.0, Vector3(0, 0, -0.06)],
				[t_hit * 0.5, Vector3(0, 0.15, -0.02)],
				[t_hit, Vector3(0, 0.35, -0.12)],
				[t_hold, Vector3(0, 0.35, -0.12)],
				[total, Vector3(0, 0, -0.06)],
			],
			"Rig/Hips/Torso/ShoulderR": [
				[0.0, Vector3(0, 0, GUARD_R)],
				[t_hit * 0.5, Vector3(0, 0, 0.7)],
				[t_hit, Vector3(0, 0, 1.62)],
				[t_hold, Vector3(0, 0, 1.62)],
				[total, Vector3(0, 0, GUARD_R)],
			],
			"Rig/Hips/Torso/ShoulderL": [
				[0.0, Vector3(0, 0, GUARD_L)],
				[t_hit, Vector3(0, 0, 0.6)],
				[total, Vector3(0, 0, GUARD_L)],
			],
			"Rig/Hips/HipR": [[0.0, Vector3(0, 0, 0.06)]],
			"Rig/Hips/HipR/KneeR": [[0.0, Vector3(0, 0, -0.15)]],
			"Rig/Hips/HipL": [[0.0, Vector3(0, 0, -0.02)]],
			"Rig/Hips/HipL/KneeL": [[0.0, Vector3(0, 0, -0.1)]],
		}, [
			[0.0, REST_HIPS_POS],
			[t_hit, REST_HIPS_POS + Vector3(0.06, -0.02, 0)],
			[total, REST_HIPS_POS],
		])
	# FOOT strikes (front kick family; sweep/roundhouse get bespoke poses in step 5)
	return _make_anim(total, false, {
		"Rig/Hips/Torso": [
			[0.0, Vector3(0, 0, -0.06)],
			[t_hit, Vector3(0, 0, 0.25)],
			[t_hold, Vector3(0, 0, 0.25)],
			[total, Vector3(0, 0, -0.06)],
		],
		"Rig/Hips/Torso/ShoulderR": [
			[0.0, Vector3(0, 0, GUARD_R)],
			[t_hit, Vector3(0, 0, 0.5)],
			[total, Vector3(0, 0, GUARD_R)],
		],
		"Rig/Hips/Torso/ShoulderL": [
			[0.0, Vector3(0, 0, GUARD_L)],
			[t_hit, Vector3(0, 0, 1.3)],
			[total, Vector3(0, 0, GUARD_L)],
		],
		"Rig/Hips/HipR": [
			[0.0, Vector3.ZERO],
			[t_hit * 0.5, Vector3(0, 0, -0.2)],
			[t_hit, Vector3(0, 0, 1.35)],
			[t_hold, Vector3(0, 0, 1.35)],
			[total, Vector3.ZERO],
		],
		"Rig/Hips/HipR/KneeR": [
			[0.0, Vector3(0, 0, -0.15)],
			[t_hit * 0.5, Vector3(0, 0, -1.2)],
			[t_hit, Vector3(0, 0, -0.05)],
			[t_hold, Vector3(0, 0, -0.05)],
			[total, Vector3(0, 0, -0.15)],
		],
		"Rig/Hips/HipL": [[0.0, Vector3(0, 0, -0.05)]],
		"Rig/Hips/HipL/KneeL": [[0.0, Vector3(0, 0, -0.2)]],
	}, [
		[0.0, REST_HIPS_POS],
		[t_hit, REST_HIPS_POS + Vector3(0.04, -0.03, 0)],
		[total, REST_HIPS_POS],
	])


# --- mesh helpers ----------------------------------------------------------


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	return m


func _pivot(parent: Node3D, pivot_name: String, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = pivot_name
	n.position = pos
	parent.add_child(n)
	return n


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, rot_deg := Vector3.ZERO) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat
	_mesh_instance(parent, mesh, pos, rot_deg)


func _capsule(
	parent: Node3D, radius: float, total_height: float, pos: Vector3, mat: Material,
	rot_deg := Vector3.ZERO
) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = total_height + 2.0 * radius
	mesh.material = mat
	_mesh_instance(parent, mesh, pos, rot_deg)


func _sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.material = mat
	_mesh_instance(parent, mesh, pos)


func _hemisphere(parent: Node3D, radius: float, pos: Vector3, mat: Material) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius # is_hemisphere halves the height
	mesh.is_hemisphere = true
	mesh.material = mat
	_mesh_instance(parent, mesh, pos)


func _cylinder(parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material) -> void:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius
	mesh.height = height
	mesh.material = mat
	_mesh_instance(parent, mesh, pos)


func _mesh_instance(parent: Node3D, mesh: Mesh, pos: Vector3, rot_deg := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	if rot_deg != Vector3.ZERO:
		mi.rotation_degrees = rot_deg
	parent.add_child(mi)
