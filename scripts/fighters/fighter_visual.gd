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

var _player: AnimationPlayer


func _ready() -> void:
	_player = find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _player == null:
		_build_placeholder_rig()
		_build_animation_player()
	play_anim(&"idle")


func play_anim(anim_name: StringName, custom_speed := 1.0) -> void:
	if _player == null or not _player.has_animation(anim_name):
		return
	if _player.current_animation != String(anim_name):
		_player.play(anim_name, -1.0, custom_speed)


func set_frozen(frozen: bool) -> void:
	## Hit-stop freeze only — attack retiming rides play()'s custom_speed.
	if _player != null:
		_player.speed_scale = 0.0 if frozen else 1.0


# --- placeholder rig -------------------------------------------------------


func _build_placeholder_rig() -> void:
	var rig := get_node("Rig") as Node3D
	var gi := _mat(gi_color)
	var belt := _mat(belt_color)
	var skin := _mat(skin_color)

	var hips := _pivot(rig, "Hips", REST_HIPS_POS)
	_box(hips, Vector3(0.3, 0.16, 0.24), Vector3.ZERO, gi)

	var torso := _pivot(hips, "Torso", Vector3(0, 0.09, 0))
	_box(torso, Vector3(0.4, 0.5, 0.26), Vector3(0, 0.3, 0), gi)
	_box(torso, Vector3(0.34, 0.07, 0.22), Vector3(0, 0.03, 0), belt)

	var head := _pivot(torso, "Head", Vector3(0, 0.62, 0))
	_sphere(head, 0.13, Vector3(0, 0.08, 0), skin)

	var shoulder_r := _pivot(torso, "ShoulderR", Vector3(0, 0.5, 0.26))
	_capsule(shoulder_r, 0.065, 0.5, Vector3(0, -0.24, 0), gi)
	var hand_r := _pivot(shoulder_r, "AttachHandR", Vector3(0, -0.52, 0))
	_sphere(hand_r, 0.07, Vector3.ZERO, skin)

	var shoulder_l := _pivot(torso, "ShoulderL", Vector3(0, 0.5, -0.26))
	_capsule(shoulder_l, 0.065, 0.5, Vector3(0, -0.24, 0), gi)
	var hand_l := _pivot(shoulder_l, "HandL", Vector3(0, -0.52, 0))
	_sphere(hand_l, 0.07, Vector3.ZERO, skin)

	var hip_r := _pivot(hips, "HipR", Vector3(0, -0.06, 0.1))
	_capsule(hip_r, 0.075, 0.42, Vector3(0, -0.2, 0), gi)
	var knee_r := _pivot(hip_r, "KneeR", Vector3(0, -0.42, 0))
	_capsule(knee_r, 0.065, 0.4, Vector3(0, -0.19, 0), gi)
	var foot_r := _pivot(knee_r, "AttachFootR", Vector3(0, -0.42, 0))
	_box(foot_r, Vector3(0.22, 0.07, 0.1), Vector3(0.05, 0.03, 0), skin)

	var hip_l := _pivot(hips, "HipL", Vector3(0, -0.06, -0.1))
	_capsule(hip_l, 0.075, 0.42, Vector3(0, -0.2, 0), gi)
	var knee_l := _pivot(hip_l, "KneeL", Vector3(0, -0.42, 0))
	_capsule(knee_l, 0.065, 0.4, Vector3(0, -0.19, 0), gi)
	var foot_l := _pivot(knee_l, "FootL", Vector3(0, -0.42, 0))
	_box(foot_l, Vector3(0.22, 0.07, 0.1), Vector3(0.05, 0.03, 0), skin)


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


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat
	_mesh_instance(parent, mesh, pos)


func _capsule(parent: Node3D, radius: float, total_height: float, pos: Vector3, mat: Material) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = total_height + 2.0 * radius
	mesh.material = mat
	_mesh_instance(parent, mesh, pos)


func _sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.material = mat
	_mesh_instance(parent, mesh, pos)


func _mesh_instance(parent: Node3D, mesh: Mesh, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	parent.add_child(mi)
