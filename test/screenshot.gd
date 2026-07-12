extends SceneTree
## Screenshot lane (docs/plan.md "Visual lanes"): run WITHOUT --headless under
## Xvfb so real frames render — Forward+ via lavapipe when mesa-vulkan-drivers
## is present, else Godot silently falls back to GL Compatibility, which is why
## the ACTIVE rendering method is printed and stamped into the filename: a
## fallback must never be mistaken for Forward+ validation.
##   xvfb-run -a -s "-screen 0 1920x1080x24" $GODOT --path . --script res://test/screenshot.gd
## Output dir: $SHOT_DIR (default /tmp). Frames: boot/fighting + mid-action.

var _out_dir := "/tmp"


func _initialize() -> void:
	var env_dir := OS.get_environment("SHOT_DIR")
	if env_dir != "":
		_out_dir = env_dir
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var main := packed.instantiate()
	root.add_child(main)
	current_scene = main
	_run()


func _run() -> void:
	# Let the intro play out and the match reach FIGHTING (real-time here, not
	# fixed-fps; software rendering is slow but physics catches up per frame).
	await _frames(90)
	var method := RenderingServer.get_current_rendering_method()
	print("rendering_method=", method)
	await _shot("%s/shot1_%s.png" % [_out_dir, method])
	await _frames(180)
	await _shot("%s/shot2_%s.png" % [_out_dir, method])
	quit(0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(path)
	print("saved ", path)
