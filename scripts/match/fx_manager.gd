class_name FXManager
extends Node
## Plain node under Main (build step 9, docs/plan.md "FXManager = plain node
## under Main" / "Visual lanes"): subscribes to GameEvents (fighter_hit,
## knockdown_started), spawns one-shot world-space impact particles + a brief
## victim flash, requests CameraRig shake, and forwards sfx names to
## AudioManager. Owns world-space FX only — HUD owns all text cues,
## AudioManager owns actual sample playback.

const ImpactParticles := preload("res://scenes/effects/impact_particles.tscn")
const CHEST_OFFSET := Vector3(0, 1.2, 0)
const FLASH_SCALE := 1.06
const FLASH_SECONDS := 0.12
const PARTICLE_FREE_MARGIN := 0.1 ## extra seconds beyond lifetime before queue_free

const SHAKE_HIT := 0.35
const SHAKE_KNOCKDOWN := 0.65
const SHAKE_BLOCKED := 0.15
const SHAKE_AI_FACTOR := 0.4 ## docs/plan.md: "~40% for AI-vs-AI"

@onready var _events: Node = get_node(^"/root/GameEvents")
@onready var _audio: Node = get_node(^"/root/AudioManager")

var _camera_rig: CameraRig = null


func _ready() -> void:
	_events.fighter_hit.connect(_on_fighter_hit)
	_events.knockdown_started.connect(_on_knockdown_started)


func _on_fighter_hit(attacker: Node, victim: Node, result: int, attack: Resource) -> void:
	var a := attacker as Fighter
	var v := victim as Fighter
	var atk := attack as AttackData
	if a == null or v == null or atk == null:
		return
	match result:
		CombatResolver.HitResult.HIT, CombatResolver.HitResult.KNOCKDOWN:
			_spawn_impact(v)
			_flash(v)
			_audio.call(&"play", &"kick" if atk.hitbox_type == AttackData.HitboxType.FOOT else &"punch")
			_shake(a, v, SHAKE_KNOCKDOWN if result == CombatResolver.HitResult.KNOCKDOWN else SHAKE_HIT)
		CombatResolver.HitResult.BLOCKED:
			_audio.call(&"play", &"block")
			_shake(a, v, SHAKE_BLOCKED)
		_: # WHIFF: no FX, no sfx, no shake
			pass


func _on_knockdown_started(_victim: Node) -> void:
	_audio.call(&"play", &"knockdown")


func _spawn_impact(victim: Fighter) -> void:
	var fx := ImpactParticles.instantiate() as GPUParticles3D
	get_parent().add_child(fx) # world-space sibling under Main, not under the victim
	fx.global_position = victim.position + CHEST_OFFSET
	fx.emitting = true
	# Timer-based cleanup (not the "finished" signal): GPUParticles3D simulation
	# rides the rendering server, which no-ops under --headless, so "finished"
	# would never fire there and leak the node across the smoke suite's many
	# hit events. A plain SceneTreeTimer is engine-time based and fires either way.
	get_tree().create_timer(fx.lifetime + PARTICLE_FREE_MARGIN).timeout.connect(
		fx.queue_free, CONNECT_ONE_SHOT
	)


func _flash(victim: Fighter) -> void:
	var vis := victim.visual
	if vis == null:
		return
	var tw := create_tween()
	tw.tween_property(vis, "scale", Vector3.ONE * FLASH_SCALE, FLASH_SECONDS * 0.5)
	tw.tween_property(vis, "scale", Vector3.ONE, FLASH_SECONDS * 0.5)


func _shake(attacker: Fighter, victim: Fighter, base_trauma: float) -> void:
	var rig := _get_camera_rig()
	if rig == null:
		return
	var player_involved := (
		(attacker.config != null and attacker.config.is_player)
		or (victim.config != null and victim.config.is_player)
	)
	rig.add_shake(base_trauma if player_involved else base_trauma * SHAKE_AI_FACTOR)


func _get_camera_rig() -> CameraRig:
	if _camera_rig == null or not is_instance_valid(_camera_rig):
		_camera_rig = get_tree().get_first_node_in_group(&"camera_rig") as CameraRig
	return _camera_rig
