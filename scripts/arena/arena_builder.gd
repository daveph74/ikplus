class_name ArenaBuilder
extends Node3D
## Procedural coastal-dojo-at-sunset set dressing (build step 11,
## docs/art-direction.md "Arena composition"). Same placeholder philosophy as
## fighter_visual.gd: primitive meshes + StandardMaterial3D, built once in
## _ready(). The Ground StaticBody3D is declared statically in arena.tscn
## (unchanged from the old main.tscn placeholder) so its collision behaviour
## stays byte-for-byte identical; everything below is pure decoration.
##
## Camera faces roughly north down -Z; the fight axis is X. Composition is
## read left-to-right in camera space as -X (ocean/rocks) -> center (distant
## mountains) -> +X (dojo, maple, spectators). Everything here sits behind
## the fight plane (z < 0) or outside ±ARENA_HALF_W so nothing occludes the
## fighters (docs/plan.md).

const ARENA_HALF_W := 7.0 ## kept in sync with Fighter.ARENA_HALF_W

# Optional generated-texture hooks (docs/architecture.md "Replacing placeholder
# art & audio"): when a file is absent the procedural flat-color look below
# remains — drop PNGs into assets/textures/ without code changes.
const TEX_DECK := "res://assets/textures/deck_planks.png"
const TEX_BANNER := "res://assets/textures/banner.png"
const TEX_LANTERN := "res://assets/textures/lantern_paper.png"
const TEX_SKY := "res://assets/textures/sky_panorama.png"

# --- deck ------------------------------------------------------------------
const DECK_TONES := [
	Color(0.55, 0.37, 0.22), Color(0.47, 0.31, 0.18), Color(0.60, 0.42, 0.26)
]
const DECK_LENGTH := 19.4
const DECK_PLANKS := 9
const DECK_PLANK_WIDTH := 0.62
const DECK_GAP := 0.06
const DECK_Z0 := -2.85


func _ready() -> void:
	_build_deck()
	_build_ocean()
	_build_rocks()
	_build_mountains()
	_build_dojo()
	_build_spectators()
	_build_maple()
	_build_lanterns_and_monuments()
	_build_banners()
	_build_railing()
	_apply_sky_panorama()


func _tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


## Swaps the ProceduralSkyMaterial for a PanoramaSkyMaterial when a generated
## equirectangular panorama exists; the DirectionalLight sun is unaffected.
func _apply_sky_panorama() -> void:
	var pano := _tex(TEX_SKY)
	if pano == null:
		return
	var we := get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null or we.environment.sky == null:
		return
	var mat := PanoramaSkyMaterial.new()
	mat.panorama = pano
	we.environment.sky.sky_material = mat


# --- deck: individual long planks, alternating warm tones, subtle gaps -----


func _build_deck() -> void:
	var deck := Node3D.new()
	deck.name = "Deck"
	add_child(deck)
	# Wood grain rides triplanar mapping so every plank box samples the texture
	# continuously in world space; the per-plank albedo_color tones multiply the
	# texture, so the alternating boards stay visible.
	var wood := _tex(TEX_DECK)
	for i in DECK_PLANKS:
		var z := DECK_Z0 + i * (DECK_PLANK_WIDTH + DECK_GAP)
		var mat := _mat(DECK_TONES[i % DECK_TONES.size()], false, Color.BLACK, 0.0, 0.05, 0.55)
		_apply_wood(mat, wood)
		_box(deck, Vector3(DECK_LENGTH, 0.08, DECK_PLANK_WIDTH), Vector3(0, -0.04, z), mat)

	# Foreground filler: the camera roams well past the last plank's front
	# edge toward +Z as it zooms out, so a single plain-toned slab continues
	# the deck out to the camera's max range — otherwise those look-down rays
	# miss all geometry and show the sky's bare "ground" gradient instead.
	var z_front := DECK_Z0 + DECK_PLANKS * (DECK_PLANK_WIDTH + DECK_GAP)
	var filler_len := 40.0
	var filler_mat := _mat(DECK_TONES[0], false, Color.BLACK, 0.0, 0.05, 0.55)
	_apply_wood(filler_mat, wood)
	_box(
		deck, Vector3(DECK_LENGTH, 0.08, filler_len),
		Vector3(0, -0.04, z_front + filler_len * 0.5), filler_mat
	)


func _apply_wood(mat: StandardMaterial3D, wood: Texture2D) -> void:
	if wood == null:
		return
	mat.albedo_texture = wood
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(0.45, 0.45, 0.45)


# --- ocean: far left/behind, low sun glint path, rock outcrops ------------


func _build_ocean() -> void:
	var ocean := Node3D.new()
	ocean.name = "Ocean"
	add_child(ocean)
	# A dark, highly metallic/glossy material would mostly reflect the warm
	# sunset ambient and read as brown, not blue — a modest emission anchors
	# the "ocean blue" regardless of the key light's color.
	var water_mat := _mat(Color(0.05, 0.22, 0.5), false, Color(0.04, 0.18, 0.4), 0.9, 0.3, 0.2)
	# Near edge overlaps the deck's back edge (DECK_Z0) so no gap of bare sky
	# "ground" gradient shows between the platform and the water.
	_box(ocean, Vector3(90, 0.05, 52), Vector3(-8, -0.35, -28), water_mat)

	# Sun-glint specular path: narrow far, widening toward the camera —
	# reads as a bright reflection lane on the water without needing real
	# screen-space specular from the low sun.
	var glint_mat := _mat(Color(1.0, 0.85, 0.5), true, Color(1.0, 0.75, 0.35), 1.4)
	var glint_defs := [
		[Vector3(-13.0, -0.32, -42.0), Vector2(0.7, 3.0)],
		[Vector3(-11.0, -0.32, -32.0), Vector2(1.3, 3.2)],
		[Vector3(-9.0, -0.32, -22.0), Vector2(2.0, 3.4)],
		[Vector3(-6.5, -0.32, -11.0), Vector2(2.8, 4.0)],
	]
	for d: Array in glint_defs:
		var pos: Vector3 = d[0]
		var wl: Vector2 = d[1]
		_box(ocean, Vector3(wl.x, 0.02, wl.y), pos, glint_mat)


func _build_rocks() -> void:
	var rocks := Node3D.new()
	rocks.name = "Rocks"
	add_child(rocks)
	var mat := _mat(Color(0.16, 0.16, 0.18), false, Color.BLACK, 0.0, 0.0, 0.95)
	var defs := [
		Vector3(-11.5, 0.0, -6.5), Vector3(-14.0, 0.0, -9.0),
		Vector3(-10.0, 0.0, -10.5), Vector3(-15.5, 0.0, -5.0),
	]
	for i in defs.size():
		var p: Vector3 = defs[i]
		var s := 0.5 + 0.3 * (i % 3)
		_box(rocks, Vector3(s * 1.4, s, s * 1.1), p + Vector3(0, s * 0.5 - 0.3, 0), mat)
		_sphere(rocks, s * 0.5, p + Vector3(s * 0.6, s * 0.3, s * 0.3), mat)


# --- mountains: layered, hazy, unshaded (reads flat regardless of sun) -----


func _build_mountains() -> void:
	var mountains := Node3D.new()
	mountains.name = "Mountains"
	add_child(mountains)
	var layers := [
		{"z": -45.0, "color": Color(0.30, 0.34, 0.46), "x": 1.0, "r": 6.0, "h": 2.6},
		{"z": -55.0, "color": Color(0.45, 0.47, 0.58), "x": -4.0, "r": 7.0, "h": 3.0},
		{"z": -65.0, "color": Color(0.63, 0.63, 0.72), "x": 4.0, "r": 8.0, "h": 3.4},
	]
	for layer: Dictionary in layers:
		var mat := _mat(layer["color"], true)
		var mesh := CylinderMesh.new()
		mesh.bottom_radius = layer["r"]
		mesh.top_radius = layer["r"] * 0.08
		mesh.height = layer["h"]
		mesh.material = mat
		_mesh_instance(mountains, mesh, Vector3(layer["x"], layer["h"] * 0.5 - 0.4, layer["z"]))


# --- dojo: timber walls, tiled roof, glowing paper lantern -----------------


func _build_dojo() -> void:
	var dojo := Node3D.new()
	dojo.name = "Dojo"
	add_child(dojo)
	var wall_mat := _mat(Color(0.22, 0.16, 0.11), false, Color.BLACK, 0.0, 0.0, 0.85)
	var panel_mat := _mat(Color(0.30, 0.23, 0.16), false, Color.BLACK, 0.0, 0.0, 0.85)
	var roof_mat := _mat(Color(0.15, 0.10, 0.09), false, Color.BLACK, 0.0, 0.05, 0.7)

	_box(dojo, Vector3(4.6, 3.2, 3.8), Vector3(7.2, 1.6, -5.5), wall_mat)
	_box(dojo, Vector3(4.8, 0.5, 4.0), Vector3(7.2, 2.9, -5.5), panel_mat) # weathered upper band
	_box(dojo, Vector3(5.8, 0.4, 4.8), Vector3(7.2, 3.35, -5.5), roof_mat, Vector3(0, 0, 4))
	_box(dojo, Vector3(5.4, 0.4, 4.4), Vector3(7.2, 3.65, -5.5), roof_mat, Vector3(0, 0, -3))

	# Big paper lantern near the front-left eave corner, facing the fight.
	# Kept LIT (not unshaded) with a modest emission so bloom doesn't blow it
	# into a giant blob at this software-rendered resolution.
	var lantern_mat := _mat(Color(0.95, 0.6, 0.25), false, Color(1.0, 0.55, 0.15), 1.2)
	var paper := _tex(TEX_LANTERN)
	if paper != null:
		lantern_mat.albedo_texture = paper
		lantern_mat.albedo_color = Color(1.0, 0.92, 0.8) # near-white: let the paper texture carry the hue
	var cord_mat := _mat(Color(0.1, 0.1, 0.1))
	_capsule(dojo, 0.06, 0.4, Vector3(5.0, 2.9, -3.6), cord_mat)
	var lantern := SphereMesh.new()
	lantern.radius = 0.4
	lantern.height = 0.8
	lantern.material = lantern_mat
	_mesh_instance(dojo, lantern, Vector3(5.0, 2.4, -3.6))


# --- spectators: 5-6 muted-gi figures at the deck's far right edge ---------


func _build_spectators() -> void:
	var group := Node3D.new()
	group.name = "Spectators"
	add_child(group)
	var tones := [
		Color(0.52, 0.50, 0.47), Color(0.40, 0.42, 0.44), Color(0.47, 0.44, 0.38),
		Color(0.35, 0.35, 0.37), Color(0.55, 0.53, 0.48), Color(0.42, 0.40, 0.42),
	]
	var skin := _mat(Color(0.8, 0.62, 0.48))
	for i in 6:
		var x := 7.2 + float(i) * 0.55
		var z := 0.6 - 0.35 * (i % 2)
		var mat := _mat(tones[i])
		_capsule(group, 0.16, 0.9, Vector3(x, 0.78, z), mat)
		_sphere(group, 0.12, Vector3(x, 1.42, z), skin)


# --- red maple canopy overhanging right + mid, well above head height ------


func _build_maple() -> void:
	var maple := Node3D.new()
	maple.name = "Maple"
	add_child(maple)
	var trunk_mat := _mat(Color(0.22, 0.14, 0.1), false, Color.BLACK, 0.0, 0.0, 0.9)
	_capsule(maple, 0.2, 2.6, Vector3(5.6, 1.6, -4.2), trunk_mat)
	_capsule(maple, 0.13, 1.3, Vector3(5.0, 2.6, -4.4), trunk_mat, Vector3(0, 0, -0.4))

	var leaf_tones := [
		Color(0.5, 0.09, 0.08), Color(0.42, 0.07, 0.09), Color(0.58, 0.14, 0.1)
	]
	var foliage_defs := [
		Vector3(5.9, 3.4, -4.0), Vector3(5.1, 3.6, -3.7), Vector3(4.4, 3.35, -4.2),
		Vector3(3.7, 3.15, -4.6), Vector3(5.4, 3.05, -4.9), Vector3(4.9, 3.75, -4.6),
	]
	for i in foliage_defs.size():
		var mat := _mat(leaf_tones[i % leaf_tones.size()])
		_sphere(maple, 0.5 + 0.12 * (i % 3), foliage_defs[i], mat)


# --- 2-3 stone lanterns + low stone monuments, mid-deck behind fight line --


func _build_lanterns_and_monuments() -> void:
	var group := Node3D.new()
	group.name = "LanternsAndMonuments"
	add_child(group)
	var stone_mat := _mat(Color(0.46, 0.46, 0.44), false, Color.BLACK, 0.0, 0.0, 0.9)
	var glow_mat := _mat(Color(0.95, 0.75, 0.4), false, Color(0.9, 0.65, 0.25), 0.7)
	for x in [-4.0, 0.0, 4.0]:
		_cylinder(group, 0.18, 0.5, Vector3(x, 0.25, -2.3), stone_mat)
		_box(group, Vector3(0.34, 0.3, 0.34), Vector3(x, 0.65, -2.3), glow_mat)
		_cylinder(group, 0.24, 0.22, Vector3(x, 0.91, -2.3), stone_mat, Vector3.ZERO, 0.02)

	for x in [-6.2, 6.2]:
		_box(group, Vector3(0.55, 0.7, 0.45), Vector3(x, 0.35, -2.5), stone_mat)


# --- tall vertical banners, abstract glyph blocks --------------------------


func _build_banners() -> void:
	var group := Node3D.new()
	group.name = "Banners"
	add_child(group)
	var pole_mat := _mat(Color(0.12, 0.11, 0.1), false, Color.BLACK, 0.0, 0.1, 0.6)
	# Unshaded: printed banner cloth reads as flat indigo regardless of the
	# warm sunset key light (a lit material desaturated toward brown here).
	var cloth_mat := _mat(Color(0.14, 0.11, 0.32), true)
	var glyph_mat := _mat(Color(0.85, 0.83, 0.78), true)
	# A generated banner design carries its own glyph column — skip the
	# procedural glyph block and let the texture cover the cloth face.
	var banner_tex := _tex(TEX_BANNER)
	if banner_tex != null:
		cloth_mat.albedo_color = Color.WHITE
		cloth_mat.albedo_texture = banner_tex
	for x in [-6.5, -2.2, 2.2, 6.5]:
		_cylinder(group, 0.05, 3.4, Vector3(x, 1.7, -7.0), pole_mat)
		_box(group, Vector3(0.55, 2.5, 0.04), Vector3(x + 0.3, 1.9, -7.0), cloth_mat)
		if banner_tex == null:
			_box(group, Vector3(0.26, 0.42, 0.05), Vector3(x + 0.3, 1.75, -6.98), glyph_mat)


# --- railing along the deck's back edge ------------------------------------


func _build_railing() -> void:
	var group := Node3D.new()
	group.name = "Railing"
	add_child(group)
	var wood_mat := _mat(Color(0.24, 0.17, 0.11), false, Color.BLACK, 0.0, 0.0, 0.85)
	var rail_z := -2.92
	_box(group, Vector3(DECK_LENGTH, 0.06, 0.06), Vector3(0, 0.75, rail_z), wood_mat)
	var post_count := 11
	for i in post_count:
		var x := lerpf(-9.2, 9.2, float(i) / float(post_count - 1))
		_cylinder(group, 0.05, 0.9, Vector3(x, 0.45, rail_z), wood_mat)


# --- mesh helpers (mirrors fighter_visual.gd's style) ----------------------


func _mat(
	color: Color,
	unshaded := false,
	emission := Color.BLACK,
	emission_energy := 0.0,
	metallic := 0.0,
	roughness := 0.9
) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if emission_energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = emission_energy
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, rot_deg := Vector3.ZERO) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat
	_mesh_instance(parent, mesh, pos, rot_deg)


func _sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.material = mat
	_mesh_instance(parent, mesh, pos)


func _capsule(
	parent: Node3D, radius: float, total_height: float, pos: Vector3, mat: Material, rot_deg := Vector3.ZERO
) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = total_height + 2.0 * radius
	mesh.material = mat
	_mesh_instance(parent, mesh, pos, rot_deg)


func _cylinder(
	parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material,
	rot_deg := Vector3.ZERO, top_radius := -1.0
) -> void:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top_radius < 0.0 else top_radius
	mesh.height = height
	mesh.material = mat
	_mesh_instance(parent, mesh, pos, rot_deg)


func _mesh_instance(parent: Node3D, mesh: Mesh, pos: Vector3, rot_deg := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	if rot_deg != Vector3.ZERO:
		mi.rotation_degrees = rot_deg
	parent.add_child(mi)
