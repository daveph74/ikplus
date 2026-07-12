class_name MatchManager
extends Node
## Match phase machine (build step 8) — docs/plan.md "Match flow". Runs AFTER
## CombatResolver (process_physics_priority = 110 in main.tscn, vs. the
## resolver's 100) so every win/knockdown check sees that tick's WHOLE
## resolved batch atomically, never a partial one.
##
## Scope: only fighters spawned by Main (fighter.config != null) are managed —
## scored, locked, repositioned, win-checked. fighter_hit events whose attacker
## or victim is unmanaged (the smoke harness's dummies) never move the phase
## machine or scores — this keeps the step 2-7 free-play scenarios valid
## unchanged. Managed fighters are pulled fresh from the "fighters" group each
## tick (never cached) so this script never depends on Main._ready() having
## run yet relative to its own _ready() (children ready before their parent —
## Main hasn't spawned anything when THIS node's _ready() runs).

enum Phase { INTRO, FIGHTING, ROUND_LOCK, SUDDEN_DEATH, ENDED }
enum _LockStage { HOLD, TWEEN, RELEASING }

const SUDDEN_DEATH_EDGE_X := 6.5 ## docs/plan.md: non-leaders parked here, excluded from targeting

@export var intro_seconds := 1.5
@export var match_seconds := 60.0
@export var target_score := 6
@export var hold_seconds := 0.7
@export var reposition_seconds := 0.9

var phase: Phase = Phase.INTRO
var remaining_time: float = 0.0
var scores: Dictionary = {} # Fighter -> int
var winner: Fighter = null
var sudden_death_leaders: Array[Fighter] = []

var _targeting: TargetingSystem = null

# Per-tick accumulators, populated by _on_fighter_hit (fired synchronously by
# CombatResolver's _physics_process, priority 100, which fully completes
# before this node's own _physics_process, priority 110, runs THE SAME tick)
# and cleared at the end of this node's _physics_process.
var _knockdown_this_tick: Array[Fighter] = []
var _sd_hits_this_tick: Array = [] # Array[Dictionary{attacker: Fighter, attack: AttackData}]

var _intro_started := false
var _intro_timer := 0.0

var _lock_stage: _LockStage = _LockStage.HOLD
var _lock_hold_timer := 0.0
var _lock_needs_recovery: Dictionary = {} # Fighter -> bool

@onready var _events: Node = get_node(^"/root/GameEvents")


func _ready() -> void:
	add_to_group(&"match_manager") # HUD self-locates via this (build step 8)
	_targeting = get_parent().get_node(^"TargetingSystem") as TargetingSystem
	phase = Phase.INTRO
	remaining_time = match_seconds
	_events.fighter_hit.connect(_on_fighter_hit)
	_events.round_state_changed.emit(Phase.INTRO)


func _physics_process(delta: float) -> void:
	match phase:
		Phase.INTRO:
			_tick_intro(delta)
		Phase.FIGHTING:
			_tick_fighting(delta)
		Phase.ROUND_LOCK:
			_tick_round_lock(delta)
		Phase.SUDDEN_DEATH:
			_tick_sudden_death()
		Phase.ENDED:
			pass
	_knockdown_this_tick.clear()
	_sd_hits_this_tick.clear()


# --- INTRO --------------------------------------------------------------


func _tick_intro(delta: float) -> void:
	if not _intro_started:
		_intro_started = true
		for f in _get_managed():
			f.force_round_lock()
		_intro_timer = intro_seconds
		return
	_intro_timer -= delta
	if _intro_timer <= 0.0:
		for f in _get_managed():
			f.release_round_lock(false)
		remaining_time = match_seconds
		_set_phase(Phase.FIGHTING)


# --- FIGHTING -------------------------------------------------------------


func _tick_fighting(delta: float) -> void:
	remaining_time -= delta
	var managed := _get_managed()
	var top := _top_scorers(managed)
	if not top.is_empty() and int(scores.get(top[0], 0)) >= target_score:
		if top.size() == 1:
			_end_match(top[0])
		else:
			_enter_sudden_death(top) # same-tick multi-cross exact tie
		return
	if not _knockdown_this_tick.is_empty():
		_start_round_lock()
		return
	if remaining_time <= 0.0:
		_handle_timeout(managed)


func _handle_timeout(managed: Array[Fighter]) -> void:
	var top := _top_scorers(managed)
	if top.size() == 1:
		_end_match(top[0])
	elif top.size() > 1:
		_enter_sudden_death(top)
	# top.is_empty() only if there are no managed fighters at all — inert.


# --- ROUND_LOCK -------------------------------------------------------------
# Sequence (docs/plan.md): hold_seconds (victim plays its own KNOCKED_DOWN
# fall; everyone else force_round_lock immediately) -> tween ALL managed
# fighters to their spawn marks -> release (victim's release plays a brief
# RECOVERING pass; everyone else goes straight IDLE) -> "Fight!"/FIGHTING once
# every managed fighter reads IDLE. Idempotent: only reachable from FIGHTING,
# so a second knockdown mid-lock (impossible anyway — every managed fighter is
# either ROUND_LOCKED or invulnerable KNOCKED_DOWN/RECOVERING during it, so
# none can land or take a hit) can never restart the sequence; a same-tick
# double knockdown that starts it still scores both attackers, since scoring
# happens in _on_fighter_hit before this tick's phase transition runs.


func _start_round_lock() -> void:
	_set_phase(Phase.ROUND_LOCK)
	for f in _get_managed():
		if f.state == Fighter.State.KNOCKED_DOWN or f.state == Fighter.State.RECOVERING:
			continue # left alone to play out its fall for the hold
		f.force_round_lock()
	_lock_stage = _LockStage.HOLD
	_lock_hold_timer = hold_seconds


func _tick_round_lock(delta: float) -> void:
	match _lock_stage:
		_LockStage.HOLD:
			_lock_hold_timer -= delta
			if _lock_hold_timer <= 0.0:
				_advance_to_tween()
		_LockStage.TWEEN:
			pass # _on_lock_tween_done (Tween.finished) drives the next stage
		_LockStage.RELEASING:
			if _all_managed_idle(_get_managed()):
				_set_phase(Phase.FIGHTING)


func _advance_to_tween() -> void:
	var managed := _get_managed()
	_lock_needs_recovery.clear()
	for f in managed:
		_lock_needs_recovery[f] = (
			f.state == Fighter.State.KNOCKED_DOWN or f.state == Fighter.State.RECOVERING
		)
		f.force_round_lock() # remaining managed fighters (the victim(s)) lock now too
	_lock_stage = _LockStage.TWEEN
	var tw := create_tween()
	tw.set_parallel(true)
	for f in managed:
		var mark := Vector3(f.config.spawn_x, 0.0, 0.0)
		tw.tween_property(f, "position", mark, reposition_seconds)
	tw.finished.connect(_on_lock_tween_done, CONNECT_ONE_SHOT)


func _on_lock_tween_done() -> void:
	var managed := _get_managed()
	for f in managed:
		f.release_round_lock(_lock_needs_recovery.get(f, false))
	if _targeting != null:
		_targeting.retarget_all()
	_lock_stage = _LockStage.RELEASING


# --- SUDDEN_DEATH -----------------------------------------------------------


func _enter_sudden_death(leaders: Array[Fighter]) -> void:
	sudden_death_leaders = leaders.duplicate()
	for f in _get_managed():
		if sudden_death_leaders.has(f):
			continue
		var edge_sign := 1.0 if f.config.spawn_x >= 0.0 else -1.0
		f.force_round_lock()
		f.position = Vector3(edge_sign * SUDDEN_DEATH_EDGE_X, 0.0, 0.0)
		if _targeting != null:
			_targeting.exclude_fighter(f)
	_set_phase(Phase.SUDDEN_DEATH)


## First clean HIT/KNOCKDOWN between leaders ends it outright (a knockdown here
## never triggers ROUND_LOCK — sudden death has no lock stage at all). A
## same-tick trade compares attack.score_value: strictly higher wins, an exact
## tie continues (generalizes past the 2-leader case for an all-three tie).
func _tick_sudden_death() -> void:
	if _sd_hits_this_tick.is_empty():
		return
	var best_value := -1
	var best_attackers: Array[Fighter] = []
	for hit: Dictionary in _sd_hits_this_tick:
		var value: int = (hit["attack"] as AttackData).score_value
		var attacker: Fighter = hit["attacker"]
		if value > best_value:
			best_value = value
			best_attackers = [attacker]
		elif value == best_value and not best_attackers.has(attacker):
			best_attackers.append(attacker)
	if best_attackers.size() == 1:
		_end_match(best_attackers[0])
	# else: tied top score_value this tick -> sudden death continues.


# --- ENDED -------------------------------------------------------------


func _end_match(winner_fighter: Fighter) -> void:
	winner = winner_fighter
	for f in _get_managed():
		if f == winner_fighter:
			f.set_victory()
		else:
			# force_round_lock from KNOCKED_DOWN/RECOVERING never plays recovery
			# (that only happens via release_round_lock(true)) — a currently-
			# down loser correctly holds its knockdown end pose.
			f.force_round_lock()
	_set_phase(Phase.ENDED)
	_events.match_ended.emit(winner)


# --- scoring / knockdown bookkeeping -----------------------------------


func _on_fighter_hit(attacker: Node, victim: Node, result: int, attack: Resource) -> void:
	var a := attacker as Fighter
	var v := victim as Fighter
	if a == null or v == null or a.config == null or v.config == null:
		return # unmanaged (smoke harness dummy) attacker/victim: never scores, never moves the phase machine
	match phase:
		Phase.FIGHTING:
			if result == CombatResolver.HitResult.HIT or result == CombatResolver.HitResult.KNOCKDOWN:
				_add_score(a, (attack as AttackData).score_value)
				if result == CombatResolver.HitResult.KNOCKDOWN:
					_knockdown_this_tick.append(v)
		Phase.SUDDEN_DEATH:
			if (
				(result == CombatResolver.HitResult.HIT or result == CombatResolver.HitResult.KNOCKDOWN)
				and sudden_death_leaders.has(a) and sudden_death_leaders.has(v)
			):
				_sd_hits_this_tick.append({"attacker": a, "attack": attack as AttackData})
		_:
			pass # INTRO/ROUND_LOCK/ENDED: managed fighters are inert; nothing to score


func _add_score(fighter: Fighter, amount: int) -> void:
	scores[fighter] = int(scores.get(fighter, 0)) + amount
	_events.score_changed.emit(fighter, scores[fighter])


# --- helpers -------------------------------------------------------------


func _get_managed() -> Array[Fighter]:
	var out: Array[Fighter] = []
	for node in get_tree().get_nodes_in_group(&"fighters"):
		var f := node as Fighter
		if f != null and is_instance_valid(f) and f.config != null:
			out.append(f)
	return out


func _top_scorers(managed: Array[Fighter]) -> Array[Fighter]:
	var best := -1
	var out: Array[Fighter] = []
	for f in managed:
		var s := int(scores.get(f, 0))
		if s > best:
			best = s
			out = [f]
		elif s == best:
			out.append(f)
	return out


func _all_managed_idle(managed: Array[Fighter]) -> bool:
	for f in managed:
		if f.state != Fighter.State.IDLE:
			return false
	return true


func _set_phase(new_phase: Phase) -> void:
	phase = new_phase
	_events.round_state_changed.emit(phase)
