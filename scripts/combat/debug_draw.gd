class_name DebugDraw
extends Node
## Debug-build-only combat visualizer (docs/plan.md "Debug"). F3 (&"debug_toggle")
## toggles translucent overlay meshes for every Hitbox (red) and Hurtbox (green) —
## boxes self-register in the "combat_boxes" group (hitbox.gd / hurtbox.gd); this
## node builds one MeshInstance3D overlay per box, as a child of that box's own
## Area3D, on the first toggle. Also owns a private CanvasLayer FPS label,
## independent of the future HUD. Everything here is a no-op outside
## OS.is_debug_build() — never ships in a release export template.

var _debug_enabled := false
var _boxes_visible := false
var _overlays_built := false

var _fps_label: Label
var _fps_accum := 0.0
var _fps_frames := 0


func _ready() -> void:
	_debug_enabled = OS.is_debug_build()
	if not _debug_enabled:
		return
	_build_fps_label()


func _unhandled_input(event: InputEvent) -> void:
	if not _debug_enabled:
		return
	if event.is_action_pressed(&"debug_toggle"):
		_toggle_boxes()


func _process(delta: float) -> void:
	if not _debug_enabled:
		return
	_fps_accum += delta
	_fps_frames += 1
	if _fps_accum >= 1.0:
		_fps_label.text = "FPS: %d" % _fps_frames
		_fps_accum = 0.0
		_fps_frames = 0


func _toggle_boxes() -> void:
	if not _overlays_built:
		_build_overlays()
		_overlays_built = true
	_boxes_visible = not _boxes_visible
	for box in get_tree().get_nodes_in_group(&"combat_boxes"):
		var overlay := (box as Node).get_node_or_null("DebugOverlay") as MeshInstance3D
		if overlay != null:
			overlay.visible = _boxes_visible


func _build_overlays() -> void:
	for box in get_tree().get_nodes_in_group(&"combat_boxes"):
		var area := box as Area3D
		if area == null or area.get_node_or_null("DebugOverlay") != null:
			continue
		var shape_node := _find_collision_shape(area)
		if shape_node == null or shape_node.shape == null:
			continue
		var mesh := _mesh_for_shape(shape_node.shape)
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "DebugOverlay"
		mi.mesh = mesh
		mi.transform = shape_node.transform
		mi.visible = false
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.15, 0.15, 0.35) if area is Hitbox else Color(0.15, 1.0, 0.15, 0.35)
		mi.material_override = mat
		area.add_child(mi)


func _find_collision_shape(area: Area3D) -> CollisionShape3D:
	for child in area.get_children():
		if child is CollisionShape3D:
			return child
	return null


func _mesh_for_shape(shape: Shape3D) -> Mesh:
	if shape is SphereShape3D:
		var m := SphereMesh.new()
		m.radius = shape.radius
		m.height = shape.radius * 2.0
		return m
	if shape is CapsuleShape3D:
		var m := CapsuleMesh.new()
		m.radius = shape.radius
		m.height = shape.height
		return m
	if shape is BoxShape3D:
		var m := BoxMesh.new()
		m.size = shape.size
		return m
	return null


func _build_fps_label() -> void:
	var layer := CanvasLayer.new()
	layer.name = "DebugFpsLayer"
	add_child(layer)
	_fps_label = Label.new()
	_fps_label.position = Vector2(8, 8)
	_fps_label.text = "FPS: --"
	layer.add_child(_fps_label)
