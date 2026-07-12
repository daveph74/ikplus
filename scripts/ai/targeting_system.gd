class_name TargetingSystem
extends Node
## Owns all target assignment (writes fighter.target — facing already follows
## target in fighter.gd, locked outside IDLE/MOVING). Pulls the "fighters"
## group live every tick (fighter.gd self-registers on _ready), so fighters
## spawned by Main after this node's own _ready are picked up automatically —
## no registration call needed.
##
## Player rule: target = closest living opponent, hysteresis (challenger must
## be >= 0.5 m closer to steal the slot) + a 0.3 s switch cooldown.
## AI rule: reconsiders every 1.5-3.0 s (randomized per fighter) with a
## closest-favoring weighted random pick (so the two AIs sometimes fight each
## other); forced retargets (current target null/freed, or hit by a
## non-target aggressor) are rate-limited by a separate 0.8 s cooldown.
##
## Runs BEFORE fighters (process_physics_priority set below fighters' default
## 0 in main.tscn) so a same-tick target change is reflected in that tick's
## facing update.

const PLAYER_HYSTERESIS := 0.5 ## metres a challenger must beat the current target by
const PLAYER_SWITCH_COOLDOWN := 0.3 ## seconds between player target switches
const AI_RECONSIDER_MIN := 1.5 ## seconds
const AI_RECONSIDER_MAX := 3.0 ## seconds
const AI_SWITCH_COOLDOWN := 0.8 ## seconds between AI target switches (event-driven retargets)
const AGGRESSOR_SWITCH_CHANCE := 0.5 ## roll when hit by a non-target

class _TargetState:
	var last_switch_time := -1000.0
	var next_reconsider_time := 0.0


var _elapsed := 0.0
var _state := {} # Fighter -> _TargetState

# Autoloads fetched via the tree, never as bare identifiers (project convention).
@onready var _events: Node = get_node(^"/root/GameEvents")


func _ready() -> void:
	_events.fighter_hit.connect(_on_fighter_hit)


func _physics_process(delta: float) -> void:
	_elapsed += delta
	var fighters := get_tree().get_nodes_in_group(&"fighters")
	for node in fighters:
		var fighter := node as Fighter
		# config == null means a test-harness fixture (e.g. smoke.gd's dummy), not
		# one of Main's spawned FighterConfigs — it stays a valid target CANDIDATE
		# for others (still in the `fighters` group) but TargetingSystem never
		# manages its own .target.
		if fighter == null or not is_instance_valid(fighter) or fighter.config == null:
			continue
		var st := _ensure_state(fighter)
		if fighter.config.is_player:
			_update_player_target(fighter, fighters, st)
		else:
			_update_ai_target(fighter, fighters, st)


# --- ROUND_LOCK-exit retargeting hook (step 8): MatchManager will call an
# entry point here (all AIs re-evaluate on "Fight!") once ROUND_LOCKED exists.
# No-op today because the state is never entered.


func _update_player_target(fighter: Fighter, fighters: Array, st: _TargetState) -> void:
	var current := fighter.target
	var current_valid := current != null and is_instance_valid(current)
	var best: Fighter = null
	var best_dist := INF
	for node in fighters:
		var other := node as Fighter
		if other == null or other == fighter or not is_instance_valid(other):
			continue
		var d := absf(other.position.x - fighter.position.x)
		if d < best_dist:
			best_dist = d
			best = other
	if best == null:
		return
	if not current_valid:
		_set_target(fighter, best, st) # no rate limit: filling an empty/invalid slot
		return
	if best == current:
		return
	var current_dist := absf(current.position.x - fighter.position.x)
	if best_dist <= current_dist - PLAYER_HYSTERESIS and _elapsed - st.last_switch_time >= PLAYER_SWITCH_COOLDOWN:
		_set_target(fighter, best, st)


func _update_ai_target(fighter: Fighter, fighters: Array, st: _TargetState) -> void:
	var current := fighter.target
	var current_valid := current != null and is_instance_valid(current)
	if not current_valid:
		# Forced retarget: current target invalid/eliminated (null or freed).
		if _elapsed - st.last_switch_time >= AI_SWITCH_COOLDOWN:
			_reconsider(fighter, fighters, st)
		return
	if _elapsed >= st.next_reconsider_time:
		_reconsider(fighter, fighters, st)


func _reconsider(fighter: Fighter, fighters: Array, st: _TargetState) -> void:
	st.next_reconsider_time = _elapsed + randf_range(AI_RECONSIDER_MIN, AI_RECONSIDER_MAX)
	var opponents: Array[Fighter] = []
	for node in fighters:
		var other := node as Fighter
		if other == null or other == fighter or not is_instance_valid(other):
			continue
		opponents.append(other)
	var pick := _weighted_pick(fighter, opponents)
	if pick != null:
		_set_target(fighter, pick, st)


## Weighted random target: favors the closest opponent but leaves the other(s)
## a real chance, so the two AIs sometimes fight each other instead of both
## always dogpiling the player.
func _weighted_pick(fighter: Fighter, opponents: Array[Fighter]) -> Fighter:
	if opponents.is_empty():
		return null
	var weights: Array[float] = []
	var total := 0.0
	for o in opponents:
		var d := absf(o.position.x - fighter.position.x)
		var w := 1.0 / (d + 1.0) # closer -> higher weight; +1 keeps a distant opponent's weight nonzero
		weights.append(w)
		total += w
	var roll := randf() * total
	var acc := 0.0
	for i in opponents.size():
		acc += weights[i]
		if roll <= acc:
			return opponents[i]
	return opponents[opponents.size() - 1]


## Forced retarget: being hit by a non-target aggressor rolls a chance to
## switch onto them, rate-limited by the AI switch cooldown. Player targeting
## re-evaluates every tick already (closest-with-hysteresis), so this hook
## only applies to AI-configured fighters.
func _on_fighter_hit(attacker: Node, victim: Node, result: int, _attack: Resource) -> void:
	if result == CombatResolver.HitResult.WHIFF:
		return
	var v := victim as Fighter
	var a := attacker as Fighter
	if v == null or a == null or not is_instance_valid(v) or not is_instance_valid(a):
		return
	if v.config == null or v.config.is_player:
		return # dummy fixture, or the player rule (which re-evaluates every tick already)
	if v.target == a:
		return
	var st := _ensure_state(v)
	if _elapsed - st.last_switch_time < AI_SWITCH_COOLDOWN:
		return
	if randf() < AGGRESSOR_SWITCH_CHANCE:
		_set_target(v, a, st)


func _set_target(fighter: Fighter, new_target: Fighter, st: _TargetState) -> void:
	if fighter.target == new_target:
		return
	fighter.target = new_target
	st.last_switch_time = _elapsed
	_events.target_changed.emit(fighter, new_target)


func _ensure_state(fighter: Fighter) -> _TargetState:
	var st: _TargetState = _state.get(fighter)
	if st == null:
		st = _TargetState.new()
		st.next_reconsider_time = _elapsed + randf_range(AI_RECONSIDER_MIN, AI_RECONSIDER_MAX)
		_state[fighter] = st
	return st
