extends SceneTree
## Merges Meshy's one-GLB-per-animation exports into a single canonical
## AnimationLibrary (assets/fighters/p1_red_anims.res). Run after dropping
## sources into assets/fighters/src/ (gitignored except the committed base):
##   godot --headless --path . --script res://tools/build_fighter_rig.gd
##
## Per clip: bakes tracks at 30 Hz over a slice window (aligning the strike
## with the attack's startup fraction is done by choosing the slice), strips
## horizontal root motion from Hips/root position tracks (physics owns fighter
## position — clips that wander would slide the visual off the collision
## capsule), and optionally reverses (walk_back = Walking backwards).

const OUT := "res://assets/fighters/p1_red_anims.res"
const BAKE_FPS := 30.0

## canonical -> [src glb (assets/fighters/src/<name>.glb), start s, end s (-1 = clip end), loop, reverse]
## Interim duplicates (marked) hold the slot until the remaining Meshy batches arrive.
const MAP := {
	&"walk_fwd": ["walking", 0.0, -1.0, true, false],
	&"walk_back": ["walking", 0.0, -1.0, true, true],
	&"idle": ["guard_punch", 0.0, 1.2, true, false],
	&"block": ["guard_punch", 0.2, 0.9, true, false],
	&"jump": ["backflip_jump", 0.8, 3.3, false, false],
	&"victory": ["backflip_jump", 0.0, -1.0, false, false],
	&"hit_react": ["hit_reaction", 0.3, 1.6, false, false],
	&"kick_high": ["high_kick", 0.55, 1.75, false, false],
	&"punch_high": ["guard_punch", 1.62, 2.52, false, false], # right straight: peak reach 0.77m @ t=1.95 -> 37% of slice
	&"punch_body": ["guard_punch", 1.62, 2.52, false, false], # interim dup
	&"punch_low": ["guard_punch", 1.62, 2.52, false, false], # interim dup
	&"kick_front": ["high_kick", 0.55, 1.75, false, false], # interim dup
	&"kick_round": ["high_kick", 0.55, 1.75, false, false], # interim dup
	&"kick_jump": ["high_kick", 0.55, 1.75, false, false], # interim dup
	&"punch_jump": ["guard_punch", 1.62, 2.52, false, false], # interim dup
	&"sweep": ["high_kick", 0.55, 1.75, false, false], # interim dup: awaiting sweeping_kick.glb
	# &"knockdown"/&"recovery": no source clips in this pack yet
}


func _initialize() -> void:
	var lib := AnimationLibrary.new()
	var cache := {} # src name -> Animation (the single imported clip)
	for canonical: StringName in MAP:
		var spec: Array = MAP[canonical]
		var src: String = spec[0]
		if not cache.has(src):
			cache[src] = _load_clip(src)
		var anim: Animation = cache[src]
		if anim == null:
			print("BUILD skip ", canonical, " (missing source ", src, ")")
			continue
		var end: float = spec[2] if spec[2] > 0.0 else anim.length
		var baked := _bake_slice(anim, spec[1], end, spec[4])
		baked.loop_mode = Animation.LOOP_LINEAR if spec[3] else Animation.LOOP_NONE
		lib.add_animation(canonical, baked)
		print("BUILD ", canonical, " <- ", src, " [", spec[1], ", ", end, "]",
				" reversed" if spec[4] else "", " len=", baked.length)
	var err := ResourceSaver.save(lib, OUT)
	print("BUILD saved ", OUT, " err=", err, " clips=", lib.get_animation_list().size())
	quit(0 if err == OK else 1)


func _load_clip(src: String) -> Animation:
	var path := "res://assets/fighters/src/%s.glb" % src
	if not ResourceLoader.exists(path):
		return null
	var inst := (load(path) as PackedScene).instantiate()
	var ap := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var clips := ap.get_animation_list()
	var anim := ap.get_animation(clips[0]).duplicate(true) as Animation
	inst.free()
	return anim


## Bakes POSITION/ROTATION/SCALE tracks at BAKE_FPS over [start, end], zeroing
## horizontal drift on root-ish position tracks (Hips bone / bare node paths).
func _bake_slice(src: Animation, start: float, end: float, reverse: bool) -> Animation:
	var out := Animation.new()
	var length := end - start
	out.length = length
	var steps := int(ceil(length * BAKE_FPS)) + 1
	for ti in src.get_track_count():
		var type := src.track_get_type(ti)
		if type != Animation.TYPE_POSITION_3D and type != Animation.TYPE_ROTATION_3D \
				and type != Animation.TYPE_SCALE_3D:
			continue
		var path := src.track_get_path(ti)
		var oi := out.add_track(type)
		out.track_set_path(oi, path)
		var strip_xz := type == Animation.TYPE_POSITION_3D and _is_root_path(path)
		var origin := Vector3.ZERO
		if strip_xz:
			origin = src.position_track_interpolate(ti, start)
		for s in steps:
			var t := minf(start + s / BAKE_FPS, end)
			var src_t := (end - (t - start)) if reverse else t
			var key_t := t - start
			match type:
				Animation.TYPE_POSITION_3D:
					var p := src.position_track_interpolate(ti, src_t)
					if strip_xz:
						p.x -= origin.x
						p.z -= origin.z
					out.position_track_insert_key(oi, key_t, p)
				Animation.TYPE_ROTATION_3D:
					out.rotation_track_insert_key(oi, key_t, src.rotation_track_interpolate(ti, src_t))
				Animation.TYPE_SCALE_3D:
					out.scale_track_insert_key(oi, key_t, src.scale_track_interpolate(ti, src_t))
	return out


func _is_root_path(path: NodePath) -> bool:
	var s := String(path)
	if not s.contains(":"):
		return true # node-level transform track on the armature root
	var bone := s.get_slice(":", 1).to_lower()
	return bone == "hips" or bone.contains("root")
