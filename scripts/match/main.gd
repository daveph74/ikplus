class_name Main
extends Node3D
## Match root. Spawns fighter.tscn instances from FighterConfig resources
## (build step 6) — the player config becomes "PlayerFighter" (keeps
## PlayerController), AI configs become "FighterP2"/"FighterP3" (get a plain
## FighterController passive stub until step 7's AIController). Also runs the
## soft separation push here (docs/plan.md): grounded, non-airborne, non-
## hitstopped overlapping pairs are nudged apart along X.
##
## Ordering (process_physics_priority, set in main.tscn): TargetingSystem
## (-10) runs before fighters (default 0) so a same-tick retarget is reflected
## in that tick's facing update; Main's own _physics_process (separation, 50)
## runs after fighters' move_and_slide; CombatResolver (100) flushes last.
## MatchManager, FXManager land in later steps.

const FighterScene := preload("res://scenes/fighters/fighter.tscn")
const SEPARATION_DISTANCE := 0.7 ## metres; below this, grounded pairs get pushed apart
const SEPARATION_SPEED := 1.2 ## m/s per fighter, capped rate

@export var fighter_configs: Array[FighterConfig] = [
	preload("res://resources/fighters/p1_red.tres"),
	preload("res://resources/fighters/p2_white.tres"),
	preload("res://resources/fighters/p3_indigo.tres"),
]

var fighters: Array[Fighter] = []


func _ready() -> void:
	_spawn_fighters()
	get_node(^"/root/AudioManager").call(&"start_ambience")


func _physics_process(delta: float) -> void:
	_apply_separation(delta)


func _spawn_fighters() -> void:
	var ai_index := 2 # first AI spawned is "FighterP2", next "FighterP3", ...
	for cfg in fighter_configs:
		var fighter := FighterScene.instantiate() as Fighter
		if cfg.is_player:
			fighter.name = "PlayerFighter"
		else:
			fighter.name = "FighterP%d" % ai_index
			ai_index += 1
		fighter.position = Vector3(cfg.spawn_x, 0.0, 0.0)

		# Visual gi/belt colors must be set on the exported fields BEFORE the
		# fighter enters the tree — FighterVisual._ready() builds the placeholder
		# rig's materials from them, and children ready before parents.
		var visual := fighter.get_node("Visual") as FighterVisual
		visual.gi_color = cfg.gi_color
		visual.belt_color = cfg.belt_color

		# Controller swap (same free/rename/add pattern as test/smoke.gd's
		# _spawn_dummy): non-player fighters get an AIController parameterized
		# by their FighterConfig's ai_profile; a null profile falls back to a
		# passive FighterController stub (the smoke harness relies on that
		# fallback staying available). Done pre-add_child so Fighter's @onready
		# controller reference resolves to whichever node ends up named
		# "Controller".
		if not cfg.is_player:
			fighter.get_node("Controller").free()
			var stub: FighterController
			if cfg.ai_profile != null:
				var ai := AIController.new()
				ai.profile = cfg.ai_profile
				stub = ai
			else:
				stub = FighterController.new()
			stub.name = "Controller"
			fighter.add_child(stub)

		fighter.config = cfg
		add_child(fighter)
		fighters.append(fighter)


## Soft spacing (docs/plan.md "separation push"): fighter bodies don't collide
## with each other, so grounded overlapping pairs are nudged apart along X at a
## capped rate instead. Suspended for airborne fighters (jump-overs pass
## through cleanly), KNOCKED_DOWN/RECOVERING/ROUND_LOCKED, and mid hit-stop.
func _apply_separation(delta: float) -> void:
	var live := get_tree().get_nodes_in_group(&"fighters")
	var push := SEPARATION_SPEED * delta
	for i in live.size():
		var a := live[i] as Fighter
		if a == null or not _separable(a):
			continue
		for j in range(i + 1, live.size()):
			var b := live[j] as Fighter
			if b == null or not _separable(b):
				continue
			var dx := b.position.x - a.position.x
			if absf(dx) >= SEPARATION_DISTANCE:
				continue
			# dx == 0: fall back to array order (a always the lower index) for a
			# deterministic push direction.
			var dir := signf(dx) if not is_zero_approx(dx) else 1.0
			a.position.x -= dir * push
			b.position.x += dir * push
			a.position.x = clampf(a.position.x, -Fighter.ARENA_HALF_W, Fighter.ARENA_HALF_W)
			b.position.x = clampf(b.position.x, -Fighter.ARENA_HALF_W, Fighter.ARENA_HALF_W)


func _separable(fighter: Fighter) -> bool:
	if not is_instance_valid(fighter) or not fighter.is_on_floor():
		return false
	if fighter.hitstop_frames > 0:
		return false
	match fighter.state:
		Fighter.State.KNOCKED_DOWN, Fighter.State.RECOVERING, Fighter.State.ROUND_LOCKED:
			return false
	return true
