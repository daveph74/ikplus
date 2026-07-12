class_name AIController
extends FighterController
## Decision FSM (OBSERVE/APPROACH/ATTACK/DEFEND/RETREAT/PUNISH) that writes the
## FighterIntent contract every compute_intent(delta) tick. NEVER touches the
## Input singleton (reserved for the smoke harness/PlayerController) and NEVER
## reads the player's InputBuffer or intents — only fighter.target's own state,
## through the perception model below (docs/plan.md "AI").
##
## Perception model (fairness): every tick this samples fighter.target.state and
## timestamps changes against an internal clock accumulated from delta (not
## Engine.get_physics_frames(), so behavior is agnostic to when compute_intent
## happens to run). A target-state change becomes a "perceived event" the
## instant it happens, but the AI may only ACT on it once
## (clock - event.timestamp) >= profile.reaction_delay — i.e. the event is
## "perceived" only once it's stale enough. block_chance/mistake_chance are
## rolled ONCE at event-creation time and stored on the event, not re-rolled
## every tick it stays pending.
##
## Re-decision cadence: OBSERVE's probabilistic transitions (approach/retreat/
## spontaneous mistake-block) are rolled only every DECIDE_MIN..MAX_TICKS ticks
## (or immediately when a perceived event ripens) so behavior reads clearly
## instead of twitching every tick. The other states (APPROACH/ATTACK/DEFEND/
## RETREAT/PUNISH) each have a concrete, continuously-checked exit condition
## instead of a cadence — they resolve as soon as their condition is met.

enum DecisionState { OBSERVE, APPROACH, ATTACK, DEFEND, RETREAT, PUNISH }

const STRIKING_RANGE := 0.95 ## metres; APPROACH closes to this gap before attacking
const DEFEND_RESOLVE_GRACE := 0.15 ## seconds after target leaves ATTACKING before DEFEND releases
const RETREAT_MIN := 0.4
const RETREAT_MAX := 0.8
const DECIDE_MIN_TICKS := 6
const DECIDE_MAX_TICKS := 10
const PUNISH_TIMEOUT := 2.5 ## safety valve: give up a punish window if it never resolves
const NEUTRAL_RANGE_MULT := 2.5 ## OBSERVE only considers retreating if roughly this close

class _PerceivedEvent:
	var kind: StringName ## &"attack", &"hit_stun", &"knocked_down"
	var timestamp: float
	var mistake_roll: float
	var block_roll: float ## only meaningful for kind == &"attack"
	var consumed := false

var profile: AIProfile = null

var decision_state: DecisionState = DecisionState.OBSERVE

var _clock := 0.0
var _decide_in := 0
var _last_target_state := -1
var _pending_event: _PerceivedEvent = null
var _awaiting_air_attack := false

var _retreat_until := 0.0
var _defend_resolve_at := -1.0
var _punish_deadline := 0.0


func compute_intent(delta: float) -> void:
	intent.clear()
	var fighter := get_parent() as Fighter
	if fighter == null:
		return
	_clock += delta

	var target := fighter.target
	if target == null or not is_instance_valid(target):
		decision_state = DecisionState.OBSERVE
		_pending_event = null
		return

	_perceive(target)

	match decision_state:
		DecisionState.OBSERVE:
			_tick_observe(fighter, target)
		DecisionState.APPROACH:
			_tick_approach(fighter, target)
		DecisionState.ATTACK:
			_tick_attack(fighter, target)
		DecisionState.DEFEND:
			_tick_defend(fighter, target)
		DecisionState.RETREAT:
			_tick_retreat(fighter, target)
		DecisionState.PUNISH:
			_tick_punish(fighter, target)


# --- perception ---------------------------------------------------------


func _perceive(target: Fighter) -> void:
	if target.state == _last_target_state:
		return
	_last_target_state = target.state
	match target.state:
		Fighter.State.ATTACKING, Fighter.State.HIT_STUN, Fighter.State.KNOCKED_DOWN:
			var kind := &"attack"
			if target.state == Fighter.State.HIT_STUN:
				kind = &"hit_stun"
			elif target.state == Fighter.State.KNOCKED_DOWN:
				kind = &"knocked_down"
			var e := _PerceivedEvent.new()
			e.kind = kind
			e.timestamp = _clock
			e.mistake_roll = randf()
			e.block_roll = randf() if kind == &"attack" else 0.0
			_pending_event = e # most recent perceivable event supersedes any unconsumed one
		_:
			pass


## Returns the pending event once it has aged past reaction_delay, else null.
## Does NOT mark it consumed — callers that act on it must do so themselves.
func _ripe_event() -> _PerceivedEvent:
	if _pending_event == null or _pending_event.consumed:
		return null
	if _clock - _pending_event.timestamp < profile.reaction_delay:
		return null
	return _pending_event


# --- OBSERVE -------------------------------------------------------------


func _tick_observe(fighter: Fighter, target: Fighter) -> void:
	var ev := _ripe_event()
	if ev != null:
		ev.consumed = true
		_pending_event = null
		_react_to_event(fighter, target, ev)
		return

	_decide_in -= 1
	if _decide_in > 0:
		return
	_decide_in = randi_range(DECIDE_MIN_TICKS, DECIDE_MAX_TICKS)
	_roll_neutral_transition(fighter, target)


func _react_to_event(fighter: Fighter, target: Fighter, ev: _PerceivedEvent) -> void:
	var mistake := ev.mistake_roll < profile.mistake_chance
	match ev.kind:
		&"attack":
			if mistake:
				# Wrong-response menu: don't block, or swing at an attacker who may
				# still be out of range (both are "deliberately wrong" outcomes).
				if randf() < 0.5:
					return # don't block: eat the hit if it lands
				_enter_attack(fighter, target)
				return
			if ev.block_roll < profile.block_chance:
				_enter_defend(fighter)
			# else: correctly perceived, chooses not to block — stays OBSERVE.
		&"hit_stun", &"knocked_down":
			if mistake:
				return # miss the opening
			if randf() < profile.punish_chance:
				_enter_punish(fighter)


## Neutral guard rolls: aggression drives closing distance / attacking,
## retreat_chance drives backing off, and a small mistake-driven roll
## occasionally blocks with nothing incoming (the 3rd wrong-response case).
func _roll_neutral_transition(fighter: Fighter, target: Fighter) -> void:
	if randf() < profile.mistake_chance:
		_enter_defend(fighter) # "block when nothing is coming"
		return

	var gap := target.position.x - fighter.position.x
	var dist := absf(gap)

	if randf() < profile.retreat_chance and dist < STRIKING_RANGE * NEUTRAL_RANGE_MULT:
		_enter_retreat(fighter, target)
		return

	if randf() >= profile.aggression:
		return # stays put, neutral guard

	if dist <= STRIKING_RANGE:
		_enter_attack(fighter, target)
	else:
		decision_state = DecisionState.APPROACH


# --- APPROACH -------------------------------------------------------------


func _tick_approach(fighter: Fighter, target: Fighter) -> void:
	var gap := target.position.x - fighter.position.x
	if absf(gap) <= STRIKING_RANGE:
		intent.move_x = 0.0
		_enter_attack(fighter, target)
		return
	intent.move_x = signf(gap)


# --- ATTACK ---------------------------------------------------------------
# Transient in the grounded case (one tick: pick + write attack_id + back to
# OBSERVE). The jump-attack path needs to persist across ticks to catch the
# moment the fighter actually becomes airborne.


func _enter_attack(fighter: Fighter, target: Fighter) -> void:
	decision_state = DecisionState.ATTACK
	if not fighter.can_start_attack():
		decision_state = DecisionState.OBSERVE
		return
	if fighter.state == Fighter.State.JUMPING:
		intent.attack_id = _pick_air_attack()
		decision_state = DecisionState.OBSERVE
		return
	if randf() < profile.jump_attack_chance:
		intent.jump = true
		_awaiting_air_attack = true
		return
	intent.attack_id = _pick_ground_attack()
	decision_state = DecisionState.OBSERVE


func _tick_attack(fighter: Fighter, _target: Fighter) -> void:
	if _awaiting_air_attack:
		if fighter.state == Fighter.State.JUMPING:
			intent.attack_id = _pick_air_attack()
			_awaiting_air_attack = false
			decision_state = DecisionState.OBSERVE
		return # still waiting for the jump to register / apex
	decision_state = DecisionState.OBSERVE # defensive: ATTACK should never idle here otherwise


func _pick_ground_attack() -> StringName:
	var weights: Dictionary = profile.attack_weights
	var total := 0.0
	for w in weights.values():
		total += float(w)
	if weights.is_empty() or total <= 0.0:
		return &"punch_high"
	var roll := randf() * total
	var acc := 0.0
	for key in weights.keys():
		acc += float(weights[key])
		if roll <= acc:
			return StringName(key)
	return StringName(weights.keys().back())


func _pick_air_attack() -> StringName:
	return &"kick_jump" if randf() < 0.5 else &"punch_jump"


# --- DEFEND ---------------------------------------------------------------


func _enter_defend(fighter: Fighter) -> void:
	decision_state = DecisionState.DEFEND
	_defend_resolve_at = -1.0
	intent.block = true # take effect the same tick the roll fires


func _tick_defend(_fighter: Fighter, target: Fighter) -> void:
	intent.block = true
	if target.state != Fighter.State.ATTACKING:
		if _defend_resolve_at < 0.0:
			_defend_resolve_at = _clock + DEFEND_RESOLVE_GRACE
		if _clock >= _defend_resolve_at:
			decision_state = DecisionState.OBSERVE
	else:
		_defend_resolve_at = -1.0 # still attacking (or attacked again) — keep blocking


# --- RETREAT ---------------------------------------------------------------


func _enter_retreat(_fighter: Fighter, _target: Fighter) -> void:
	decision_state = DecisionState.RETREAT
	_retreat_until = _clock + randf_range(RETREAT_MIN, RETREAT_MAX)


func _tick_retreat(fighter: Fighter, target: Fighter) -> void:
	if _clock >= _retreat_until:
		decision_state = DecisionState.OBSERVE
		return
	var gap := target.position.x - fighter.position.x
	var dir := signf(gap) if not is_zero_approx(gap) else 1.0
	intent.move_x = -dir


# --- PUNISH -----------------------------------------------------------------
# Dash in and attack the instant it's safe: ATTACKING/HIT_STUN victims are not
# invulnerable (resolve_contact only exempts KNOCKED_DOWN/RECOVERING/
# ROUND_LOCKED/VICTORY), so closing distance while the target is still
# ATTACKING (recovery) or HIT_STUN lands a normal hit. A perceived
# KNOCKED_DOWN instead waits at range — respecting invulnerability — and
# strikes the moment the target is vulnerable again (the "wake-up" punish).


func _enter_punish(_fighter: Fighter) -> void:
	decision_state = DecisionState.PUNISH
	_punish_deadline = _clock + PUNISH_TIMEOUT


func _tick_punish(fighter: Fighter, target: Fighter) -> void:
	if _clock >= _punish_deadline:
		decision_state = DecisionState.OBSERVE
		return
	var gap := target.position.x - fighter.position.x
	var dist := absf(gap)
	var invulnerable := (
		target.state == Fighter.State.KNOCKED_DOWN
		or target.state == Fighter.State.RECOVERING
		or target.state == Fighter.State.ROUND_LOCKED
		or target.state == Fighter.State.VICTORY
	)
	if dist > STRIKING_RANGE:
		intent.move_x = signf(gap) if not is_zero_approx(gap) else 0.0
		return
	intent.move_x = 0.0
	if invulnerable:
		return # in range, ready to strike the instant they're vulnerable again
	if fighter.can_start_attack():
		intent.attack_id = _pick_ground_attack()
		decision_state = DecisionState.OBSERVE
