extends SceneTree
## Merges Meshy's one-GLB-per-animation exports into per-fighter canonical
## AnimationLibraries. Run after dropping sources into a variant's src dir
## (gitignored except each fighter's committed base GLB):
##   godot --headless --path . --script res://tools/build_fighter_rig.gd
##
## Per clip: bakes tracks at 30 Hz over a slice window (aligning the strike
## with the attack's startup fraction is done by choosing the slice), strips
## horizontal root motion from Hips/root position tracks (physics owns fighter
## position — clips that wander would slide the visual off the collision
## capsule), and optionally reverses (walk_back = Walking backwards).
##
## Meshy retargets the same library animation onto every character, so MAP's
## slice timings are shared by all variants; a variant is just a source dir +
## output path. Variants with no source dir yet are skipped; missing sources
## within a variant skip just that clip (partial batches are normal).

const VARIANTS := {
	&"red": ["res://assets/fighters/src", "res://assets/fighters/p1_red_anims.res"],
	&"white": ["res://assets/fighters/src/white", "res://assets/fighters/p2_white_anims.res"],
	&"blue": ["res://assets/fighters/src/blue", "res://assets/fighters/p3_blue_anims.res"],
}
const BAKE_FPS := 30.0

## canonical -> [src, start s, end s (-1 = clip end), loop, reverse, pin_root_y?, retime_to_s?]
## retime_to_s: bake the slice compressed/stretched to this duration (recovery
## clips must fit the FSM's fixed get-up window; attacks instead retime at play()).
## pin_root_y: for airborne clips — physics owns the jump arc, so the clip's own
## baked hip rise is pinned to its slice-start height (limbs still animate).
const MAP := {
	&"walk_fwd": ["walking", 0.0, -1.0, true, false],
	&"walk_back": ["walking", 0.0, -1.0, true, true],
	&"idle": ["guard_punch", 0.0, 1.2, true, false],
	&"block": ["guard_punch", 0.2, 0.9, true, false],
	&"jump": ["backflip_jump", 0.8, 3.3, false, false],
	&"victory": ["backflip_jump", 0.0, -1.0, false, false],
	&"hit_react": ["hit_reaction", 0.3, 1.6, false, false],
	&"kick_high": ["high_kick", 0.55, 1.75, false, false],
	&"punch_high": ["punch_combo", 1.2, 2.0, false, false], # right straight, peak 0.60m @ t=1.5
	&"punch_body": ["punch_combo_3", 0.75, 1.55, false, false], # LEFT jab, peak 0.73m @ t=1.05 (hitbox_type HAND_L)
	&"punch_low": ["punch_combo_4", 3.35, 4.1, false, false], # right punch, peak 0.94m @ t=3.6
	&"kick_front": ["step_in_kick", 0.3, 1.1, false, false], # LEFT step-in kick, peak 0.77m @ t=0.6 (hitbox FOOT_L)
	&"kick_round": ["roundhouse", 1.95, 2.85, false, false], # LEFT roundhouse, peak y1.3 @ t=2.25 (hitbox_type FOOT_L)
	&"kick_jump": ["step_turn_kick", 1.25, 1.9, false, false, true], # RIGHT turning kick, peak 0.74m @ t=1.5; root-Y pinned (aerial)
	&"punch_jump": ["jumping_punch", 0.9, 1.8, false, false, true], # aerial overhead punch, root-Y pinned
	&"sweep": ["sweeping_kick", 1.05, 1.95, false, false], # crouching RIGHT-leg sweep @ t=1.35
	&"knockdown": ["falling_down", 0.3, 1.5, false, false], # backward fall onto back, settles prone
	&"recovery": ["stand_up7", 0.3, 1.9, false, false, false, 0.45], # matching get-up, compressed to the FSM window
}


func _initialize() -> void:
	var any_err := false
	for variant: StringName in VARIANTS:
		var src_dir: String = VARIANTS[variant][0]
		var out: String = VARIANTS[variant][1]
		if not DirAccess.dir_exists_absolute(src_dir):
			print("BUILD [", variant, "] skipped (no ", src_dir, ")")
			continue
		if not _build_variant(variant, src_dir, out):
			any_err = true
	quit(1 if any_err else 0)


func _build_variant(variant: StringName, src_dir: String, out: String) -> bool:
	var lib := AnimationLibrary.new()
	var cache := {} # src name -> Animation (the single imported clip)
	for canonical: StringName in MAP:
		var spec: Array = MAP[canonical]
		var src: String = spec[0]
		if not cache.has(src):
			cache[src] = _load_clip(src_dir, src)
		var anim: Animation = cache[src]
		if anim == null:
			print("BUILD [", variant, "] skip ", canonical, " (missing source ", src, ")")
			continue
		var end: float = spec[2] if spec[2] > 0.0 else anim.length
		var pin_y: bool = spec[5] if spec.size() > 5 else false
		var retime: float = spec[6] if spec.size() > 6 else 0.0
		var baked := _bake_slice(anim, spec[1], end, spec[4], pin_y, retime)
		baked.loop_mode = Animation.LOOP_LINEAR if spec[3] else Animation.LOOP_NONE
		lib.add_animation(canonical, baked)
		print("BUILD [", variant, "] ", canonical, " <- ", src, " [", spec[1], ", ", end, "]",
				" reversed" if spec[4] else "", " len=", baked.length)
	if lib.get_animation_list().is_empty():
		print("BUILD [", variant, "] nothing to save (no sources in ", src_dir, ")")
		return true
	var err := ResourceSaver.save(lib, out)
	print("BUILD [", variant, "] saved ", out, " err=", err, " clips=", lib.get_animation_list().size())
	return err == OK


func _load_clip(src_dir: String, src: String) -> Animation:
	var path := "%s/%s.glb" % [src_dir, src]
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
func _bake_slice(src: Animation, start: float, end: float, reverse: bool, pin_root_y := false, retime_to := 0.0) -> Animation:
	var out := Animation.new()
	var length := end - start
	var time_scale := (retime_to / length) if retime_to > 0.0 else 1.0
	out.length = length * time_scale
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
			var key_t := (t - start) * time_scale
			match type:
				Animation.TYPE_POSITION_3D:
					var p := src.position_track_interpolate(ti, src_t)
					if strip_xz:
						p.x -= origin.x
						p.z -= origin.z
						if pin_root_y:
							p.y = origin.y
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
