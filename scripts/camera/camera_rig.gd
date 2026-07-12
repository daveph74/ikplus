class_name CameraRig
extends Node3D
## CameraRig -> ShakePivot -> Camera3D (build step 9, docs/plan.md "Camera").
## Frames all three fighters via a player-biased centroid (weights 2/1/1),
## lerped follow, and distance-based zoom with zoom-in hysteresis. Never
## rotates around the arena — only translates (X follow on this node, Z
## distance on the Camera3D child, small shake offsets on ShakePivot).
##
## Fighters are pulled fresh from the "fighters" group every physics tick
## (never cached across ticks or scenes) — this script is a child of Main and
## dies with the scene on restart same as everything else, so there is no
## stale-reference hazard to guard beyond the usual is_instance_valid() checks
## already implied by a fresh group query each tick.

const VFOV_DEG := 25.0 ## matches Camera3D.fov; kept in sync in _ready()
const ASPECT := 16.0 / 9.0
const DISTANCE_MARGIN := 3.5 ## metres of breathing room beyond the tight geometric fit
const MIN_DISTANCE := 9.0
const ZOOM_IN_DELAY := 0.5 ## seconds the spread must be shrinking before zoom-in is allowed
const FOLLOW_LERP_RATE := 4.0 ## per plan.md "lerped follow (~4.0/s)"
const PLAYER_WEIGHT := 2.0
const OTHER_WEIGHT := 1.0

const SHAKE_DECAY := 2.5 ## trauma units/sec
const SHAKE_MAX_OFFSET := 0.18 ## metres
const SHAKE_NOISE_SPEED := 26.0 ## noise-sample units/sec

@onready var _shake_pivot: Node3D = $ShakePivot
@onready var _camera: Camera3D = $ShakePivot/Camera3D

var _dist_coef: float
var _max_distance: float
var _target_distance := MIN_DISTANCE
var _current_distance := MIN_DISTANCE
var _shrink_timer := 0.0
var _follow_x := 0.0
var _base_height := 2.2

var _trauma := 0.0
var _noise_t := 0.0
var _noise_x := FastNoiseLite.new()
var _noise_y := FastNoiseLite.new()


func _ready() -> void:
	add_to_group(&"camera_rig") # FXManager locates this node to request shake
	_camera.fov = VFOV_DEG
	_base_height = _camera.position.y
	# Geometric fit: visible half-width at distance d is d*tan(vfov/2)*aspect;
	# solving for d against a target spread gives d = spread / (2*tan*aspect).
	_dist_coef = 1.0 / (2.0 * tan(deg_to_rad(VFOV_DEG * 0.5)) * ASPECT)
	_max_distance = _dist_coef * (2.0 * Fighter.ARENA_HALF_W) + DISTANCE_MARGIN
	_current_distance = _max_distance
	_target_distance = _max_distance
	_noise_x.seed = 1
	_noise_y.seed = 2
	_noise_x.frequency = 1.0
	_noise_y.frequency = 1.0
	# Start centred and framed wide so the very first rendered frame (before any
	# fighter has moved) already shows all three, rather than snapping in.
	var fighters := _managed_fighters()
	if not fighters.is_empty():
		_follow_x = _weighted_centroid_x(fighters)
		position.x = _follow_x


func _physics_process(delta: float) -> void:
	var fighters := _managed_fighters()
	if not fighters.is_empty():
		var centroid_x := _weighted_centroid_x(fighters)
		var spread := _spread_x(fighters)
		_update_distance(delta, spread)
		_follow_x = lerp(_follow_x, centroid_x, clampf(FOLLOW_LERP_RATE * delta, 0.0, 1.0))
	position.x = _follow_x
	position.z = 0.0 # never rotates/orbits the arena — pure X translation
	_camera.position = Vector3(0.0, _base_height, _current_distance)
	_update_shake(delta)


## Called by FXManager on fighter_hit/knockdown_started. `trauma_amount` should
## already be scaled by the caller (full for player-involved contacts, ~40% for
## AI-vs-AI, per docs/plan.md).
func add_shake(trauma_amount: float) -> void:
	_trauma = clampf(_trauma + trauma_amount, 0.0, 1.0)


func _update_distance(delta: float, spread: float) -> void:
	var raw := clampf(_dist_coef * spread + DISTANCE_MARGIN, MIN_DISTANCE, _max_distance)
	if raw < _target_distance - 0.01:
		# Candidate zoom-IN: only commit once the spread has stayed tighter than
		# the current target for ZOOM_IN_DELAY straight seconds.
		_shrink_timer += delta
		if _shrink_timer >= ZOOM_IN_DELAY:
			_target_distance = raw
	else:
		# Zoom-OUT (or steady): immediate — visibility is the hard guarantee.
		_shrink_timer = 0.0
		_target_distance = raw
	_current_distance = lerp(_current_distance, _target_distance, clampf(FOLLOW_LERP_RATE * delta, 0.0, 1.0))


func _update_shake(delta: float) -> void:
	if _trauma <= 0.0:
		_shake_pivot.position = Vector3.ZERO
		_trauma = 0.0
		return
	_noise_t += delta * SHAKE_NOISE_SPEED
	var amount := _trauma * _trauma # decaying-noise: square falloff reads as a sharp hit, not a wobble
	var ox := _noise_x.get_noise_1d(_noise_t) * SHAKE_MAX_OFFSET * amount
	var oy := _noise_y.get_noise_1d(_noise_t + 100.0) * SHAKE_MAX_OFFSET * 0.6 * amount
	_shake_pivot.position = Vector3(ox, oy, 0.0)
	_trauma = maxf(_trauma - SHAKE_DECAY * delta, 0.0)


func _managed_fighters() -> Array[Fighter]:
	var out: Array[Fighter] = []
	for node in get_tree().get_nodes_in_group(&"fighters"):
		var f := node as Fighter
		if f != null and is_instance_valid(f) and f.config != null:
			out.append(f)
	return out


func _weighted_centroid_x(fighters: Array[Fighter]) -> float:
	var total := 0.0
	var weight_sum := 0.0
	for f in fighters:
		var w := PLAYER_WEIGHT if f.config.is_player else OTHER_WEIGHT
		total += f.position.x * w
		weight_sum += w
	return total / weight_sum if weight_sum > 0.0 else 0.0


func _spread_x(fighters: Array[Fighter]) -> float:
	if fighters.size() < 2:
		return 0.0
	var min_x := INF
	var max_x := -INF
	for f in fighters:
		min_x = minf(min_x, f.position.x)
		max_x = maxf(max_x, f.position.x)
	return max_x - min_x
