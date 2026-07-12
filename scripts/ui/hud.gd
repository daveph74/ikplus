class_name HUD
extends CanvasLayer
## Top-strip HUD (build step 8) — docs/art-direction.md "HUD". Built entirely
## from Control nodes + StyleBoxFlat (no image assets), procedurally in
## _ready(), the same placeholder-first philosophy fighter_visual.gd uses for
## its rig — hud.tscn itself stays a near-empty scene with just this script.
##
## Self-locates MatchManager via the "match_manager" group (polled lazily,
## self-healing across a scene reload) rather than a _ready()-time node
## reference, since sibling _ready() order between HUD and MatchManager under
## Main is not guaranteed. Panel slots (left/center/right) are assigned by
## sorting the managed "fighters" group on FighterConfig.spawn_x each frame —
## robust to node name and independent of spawn order in the scene tree.
## Everything here null-checks MatchManager/fighters defensively; main.tscn
## always carries a MatchManager, so this is a robustness habit, not a real
## no-match code path.

const SEGMENT_COUNT := 6
const FIGHT_CUE_SECONDS := 1.0
const SUDDEN_DEATH_CUE_SECONDS := 1.5
const FLASH_PERIOD := 0.5 ## seconds; sudden-death secondary-strip flash

const RING_COLOR := Color(1.0, 0.85, 0.2, 0.9)
const DEFAULT_BORDER_COLOR := Color(1, 1, 1, 0.15)
const SEGMENT_EMPTY := Color(0.25, 0.05, 0.05, 0.85)
const SEGMENT_FILLED := Color(0.85, 0.1, 0.1, 0.95)
const STRIP_IDLE := Color(0.6, 0.65, 0.75, 0.6)
const STRIP_FLASH_ON := Color(1.0, 0.2, 0.2, 0.95)
const STRIP_FLASH_OFF := Color(0.3, 0.05, 0.05, 0.3)
const EXCLUDED_MODULATE := Color(1, 1, 1, 0.4)

var _match_manager: MatchManager = null
var _sorted_fighters: Array[Fighter] = []
var _player_target: Fighter = null

var _clock := 0.0
var _cue_hide_at := -1.0

# Parallel arrays, one entry per panel slot (0 = left/P1, 1 = center/P2, 2 = right/P3).
var _panel_boxes: Array[PanelContainer] = []
var _panel_styles: Array[StyleBoxFlat] = []
var _name_labels: Array[Label] = []
var _you_tags: Array[Label] = []
var _score_labels: Array[Label] = []
var _segments: Array = [] # each entry: Array[ColorRect], 6 long
var _secondary_strips: Array[ColorRect] = []
var _portraits: Array[ColorRect] = []

var _cue_label: Label
var _time_value_label: Label


func _ready() -> void:
	_build_ui()
	var events := get_node(^"/root/GameEvents")
	events.round_state_changed.connect(_on_round_state_changed)
	events.match_ended.connect(_on_match_ended)
	events.target_changed.connect(_on_target_changed)


func _process(delta: float) -> void:
	_clock += delta
	if _cue_hide_at > 0.0 and _clock >= _cue_hide_at:
		_hide_cue()
	_refresh_match_manager()
	_refresh_fighters()
	_update_timer()
	_update_panels()
	_update_sudden_death_flash()


# --- signal handlers -------------------------------------------------------


func _on_round_state_changed(new_state: int) -> void:
	match new_state:
		MatchManager.Phase.INTRO:
			_show_cue("READY...")
		MatchManager.Phase.FIGHTING:
			_show_cue("FIGHT!", FIGHT_CUE_SECONDS)
		MatchManager.Phase.SUDDEN_DEATH:
			_show_cue("SUDDEN DEATH", SUDDEN_DEATH_CUE_SECONDS)
		MatchManager.Phase.ROUND_LOCK:
			_hide_cue()
		MatchManager.Phase.ENDED:
			pass # _on_match_ended supplies the winner text


func _on_match_ended(winner: Node) -> void:
	var f := winner as Fighter
	var name := (f.config.display_name if f != null and f.config != null else "?")
	_cue_label.text = "%s WINS — R to restart" % name
	_cue_label.visible = true
	_cue_hide_at = -1.0 # persists until restart


func _on_target_changed(fighter: Node, new_target: Node) -> void:
	var f := fighter as Fighter
	if f == null or f.config == null or not f.config.is_player:
		return # only the player's own current target drives the highlight ring
	_player_target = new_target as Fighter


# --- per-frame refresh ------------------------------------------------------


func _refresh_match_manager() -> void:
	if _match_manager == null or not is_instance_valid(_match_manager):
		_match_manager = get_tree().get_first_node_in_group(&"match_manager") as MatchManager


func _refresh_fighters() -> void:
	var managed: Array[Fighter] = []
	for node in get_tree().get_nodes_in_group(&"fighters"):
		var f := node as Fighter
		if f != null and is_instance_valid(f) and f.config != null:
			managed.append(f)
	managed.sort_custom(func(a: Fighter, b: Fighter) -> bool: return a.config.spawn_x < b.config.spawn_x)
	_sorted_fighters = managed


func _update_timer() -> void:
	if _match_manager == null:
		_time_value_label.text = "--"
		return
	_time_value_label.text = str(int(ceil(maxf(_match_manager.remaining_time, 0.0))))


func _update_panels() -> void:
	for i in 3:
		var has_fighter := i < _sorted_fighters.size()
		_panel_boxes[i].visible = has_fighter
		if not has_fighter:
			continue
		var f := _sorted_fighters[i]
		var cfg := f.config

		_name_labels[i].text = cfg.display_name
		_name_labels[i].add_theme_color_override("font_color", cfg.gi_color)
		_you_tags[i].visible = cfg.is_player
		if _portraits[i] != null:
			_portraits[i].color = cfg.gi_color

		var score := int(_match_manager.scores.get(f, 0)) if _match_manager != null else 0
		_score_labels[i].text = str(score)
		var filled := mini(score, SEGMENT_COUNT)
		var row: Array = _segments[i]
		for s in SEGMENT_COUNT:
			(row[s] as ColorRect).color = SEGMENT_FILLED if s < filled else SEGMENT_EMPTY

		var is_target := _player_target != null and f == _player_target
		_panel_styles[i].border_color = RING_COLOR if is_target else DEFAULT_BORDER_COLOR
		_panel_styles[i].set_border_width_all(3 if is_target else 2)

		var excluded := (
			_match_manager != null
			and _match_manager.phase == MatchManager.Phase.SUDDEN_DEATH
			and not _match_manager.sudden_death_leaders.has(f)
		)
		_panel_boxes[i].modulate = EXCLUDED_MODULATE if excluded else Color.WHITE


func _update_sudden_death_flash() -> void:
	var sudden_death := _match_manager != null and _match_manager.phase == MatchManager.Phase.SUDDEN_DEATH
	var on := fmod(_clock, FLASH_PERIOD) < FLASH_PERIOD * 0.5
	for i in 3:
		if i >= _sorted_fighters.size():
			continue
		_secondary_strips[i].color = (
			(STRIP_FLASH_ON if on else STRIP_FLASH_OFF) if sudden_death else STRIP_IDLE
		)


# --- cue overlay -------------------------------------------------------------


func _show_cue(text: String, auto_hide_after := -1.0) -> void:
	_cue_label.text = text
	_cue_label.visible = true
	_cue_hide_at = (_clock + auto_hide_after) if auto_hide_after > 0.0 else -1.0


func _hide_cue() -> void:
	_cue_label.visible = false
	_cue_hide_at = -1.0


# --- procedural UI construction ---------------------------------------------


func _outlined_settings(font_size: int) -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font_size = font_size
	ls.font_color = Color.WHITE
	ls.outline_size = maxi(4, font_size / 8)
	ls.outline_color = Color(0, 0, 0, 0.9)
	return ls


func _build_ui() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var top := VBoxContainer.new()
	top.name = "Top"
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_theme_constant_override("separation", 4)
	root.add_child(top)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top"]:
		margin.add_theme_constant_override("margin_%s" % side, 16)
	top.add_child(margin)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	var panel_left := _build_panel(true)
	var spacer_l := Control.new()
	spacer_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var panel_center := _build_panel(false)
	var spacer_r := Control.new()
	spacer_r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var panel_right := _build_panel(true)
	row.add_child(panel_left)
	row.add_child(spacer_l)
	row.add_child(panel_center)
	row.add_child(spacer_r)
	row.add_child(panel_right)

	var time_wrap := CenterContainer.new()
	time_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(time_wrap)
	var time_box := VBoxContainer.new()
	time_box.alignment = BoxContainer.ALIGNMENT_CENTER
	time_wrap.add_child(time_box)
	var time_label := Label.new()
	time_label.text = "TIME"
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_label.label_settings = _outlined_settings(16)
	time_box.add_child(time_label)
	_time_value_label = Label.new()
	_time_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_time_value_label.label_settings = _outlined_settings(40)
	_time_value_label.text = "--"
	time_box.add_child(_time_value_label)

	var overlay := CenterContainer.new()
	overlay.name = "CenterOverlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(overlay)
	_cue_label = Label.new()
	_cue_label.label_settings = _outlined_settings(56)
	_cue_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cue_label.visible = false
	overlay.add_child(_cue_label)


## Builds one fighter panel and appends its live sub-node references to the
## parallel arrays above (build order fixes the panel index: left=0, center=1,
## right=2).
func _build_panel(with_portrait: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(220, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.07, 0.55)
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(2)
	sb.border_color = DEFAULT_BORDER_COLOR
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", sb)
	_panel_boxes.append(panel)
	_panel_styles.append(sb)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	var portrait: ColorRect = null
	if with_portrait:
		portrait = ColorRect.new()
		portrait.custom_minimum_size = Vector2(28, 28)
		portrait.color = Color(0.5, 0.5, 0.5)
		header.add_child(portrait)
	_portraits.append(portrait)

	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_col)

	var name_row := HBoxContainer.new()
	name_col.add_child(name_row)
	var name_label := Label.new()
	name_label.add_theme_font_size_override("font_size", 18)
	name_row.add_child(name_label)
	_name_labels.append(name_label)
	var you_tag := Label.new()
	you_tag.text = " YOU"
	you_tag.add_theme_color_override("font_color", Color(1, 0.85, 0.2))
	you_tag.add_theme_font_size_override("font_size", 14)
	you_tag.visible = false
	name_row.add_child(you_tag)
	_you_tags.append(you_tag)

	var score_label := Label.new()
	score_label.text = "0"
	score_label.add_theme_font_size_override("font_size", 22)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	name_col.add_child(score_label)
	_score_labels.append(score_label)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 3)
	vbox.add_child(bar)
	var seg_row: Array[ColorRect] = []
	for i in SEGMENT_COUNT:
		var seg := ColorRect.new()
		seg.custom_minimum_size = Vector2(24, 10)
		seg.color = SEGMENT_EMPTY
		bar.add_child(seg)
		seg_row.append(seg)
	_segments.append(seg_row)

	var strip := ColorRect.new()
	strip.custom_minimum_size = Vector2(0, 4)
	strip.color = STRIP_IDLE
	vbox.add_child(strip)
	_secondary_strips.append(strip)

	return panel
