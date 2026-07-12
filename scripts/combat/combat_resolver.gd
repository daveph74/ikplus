class_name CombatResolver
extends Node
## Two-phase batched hit resolution — kills scene-tree order as a hidden combat
## rule. Phase 1: hitboxes ENQUEUE contacts during fighter ticks (victim state
## snapshotted at enqueue). Phase 2: this node's _physics_process runs AFTER all
## fighters (process_physics_priority = 100 in main.tscn) and applies the whole
## batch atomically: every valid attacker scores, a victim hit twice takes the
## single strongest reaction, mutual same-tick hits both apply (trades are legal).

enum HitResult { WHIFF, BLOCKED, HIT, KNOCKDOWN }


class Contact:
	var attacker: Fighter
	var victim: Fighter
	var attack: AttackData
	var victim_state: int ## Fighter.State snapshot at enqueue time
	var victim_airborne: bool ## JUMPING, or ATTACKING with is_airborne — at enqueue time


var _queue: Array[Contact] = []

# Autoloads are fetched via the tree, never as bare identifiers — bare autoload
# globals only exist once a game boot registers them, so they fail the
# --check-only parse gate (project convention; see tools/verify.sh).
@onready var _events: Node = get_node(^"/root/GameEvents")


func enqueue(attacker: Fighter, victim: Fighter, attack: AttackData) -> void:
	if attacker == victim:
		return # defensive: hitbox poll already excludes self
	var c := Contact.new()
	c.attacker = attacker
	c.victim = victim
	c.attack = attack
	c.victim_state = victim.state
	c.victim_airborne = (
		victim.state == Fighter.State.JUMPING
		or (victim.state == Fighter.State.ATTACKING and victim.is_airborne)
	)
	_queue.append(c)


func _physics_process(_delta: float) -> void:
	if _queue.is_empty():
		return
	var batch := _queue
	_queue = []
	var results := {} # Contact -> HitResult, from resolve_contact (pre-application)
	var reactions := {} # victim (Fighter) -> Contact — the single strongest reaction
	for c in batch:
		var result := resolve_contact(c.attacker, c.victim, c.attack, c.victim_state, c.victim_airborne)
		results[c] = result
		if result == HitResult.BLOCKED:
			# No escalation is possible for BLOCKED/WHIFF, so these emit immediately.
			# Attacker gets NO hit-stop on a blocked hit; defender holds pose + pushback.
			_events.fighter_hit.emit(c.attacker, c.victim, result, c.attack)
			var dx := c.victim.position.x - c.attacker.position.x
			var pushback_dir := 1 if dx >= 0.0 else -1
			c.victim.apply_blocked(pushback_dir)
		elif result == HitResult.WHIFF:
			_events.fighter_hit.emit(c.attacker, c.victim, result, c.attack)
		else: # HIT or KNOCKDOWN — event emission is deferred below: apply_hit's
			# stun-lock breaker (fighter.gd) may internally upgrade HIT to
			# KNOCKDOWN, and the emitted event must reflect what actually
			# happened to the victim, not this pre-application classification.
			c.attacker.apply_hitstop(c.attack.hit_stop_frames())
			var prev: Contact = reactions.get(c.victim)
			if prev == null or _stronger(c, result, prev, results[prev]):
				reactions[c.victim] = c

	var reacting_contacts := {} # Contact -> true; skips these in the trailing pass
	for victim: Fighter in reactions:
		var c: Contact = reactions[victim]
		reacting_contacts[c] = true
		var dx := victim.position.x - c.attacker.position.x
		var from_dir := 1 if dx > 0.0 else (-1 if dx < 0.0 else c.attacker.facing)
		victim.apply_hit(c.attack, from_dir, results[c])
		victim.apply_hitstop(c.attack.hit_stop_frames())
		var applied_result: int = HitResult.KNOCKDOWN if victim.state == Fighter.State.KNOCKED_DOWN \
			else results[c]
		_events.fighter_hit.emit(c.attacker, c.victim, applied_result, c.attack)
		if victim.state == Fighter.State.KNOCKED_DOWN:
			_events.knockdown_started.emit(victim)

	# Non-winning HIT/KNOCKDOWN contacts (a victim hit twice takes only the
	# single strongest reaction) never touch victim state, so no escalation
	# applies — they still score their own event per "every valid attacker
	# scores; double-team = 2 separate points".
	for c in batch:
		var result: int = results[c]
		if (result == HitResult.HIT or result == HitResult.KNOCKDOWN) and not reacting_contacts.has(c):
			_events.fighter_hit.emit(c.attacker, c.victim, result, c.attack)


## Rules — single authority for block/invuln/airborne decisions. Static so the
## smoke harness can exercise them directly.
static func resolve_contact(
	attacker: Fighter, victim: Fighter, attack: AttackData, victim_state: int, victim_airborne: bool
) -> HitResult:
	match victim_state:
		Fighter.State.KNOCKED_DOWN, Fighter.State.RECOVERING, \
		Fighter.State.ROUND_LOCKED, Fighter.State.VICTORY:
			return HitResult.WHIFF # invulnerable
	if victim_airborne:
		# Airborne victims: knockdown regardless of causes_knockdown, or whiff.
		return HitResult.KNOCKDOWN if attack.hits_airborne else HitResult.WHIFF
	if victim_state == Fighter.State.BLOCKING:
		if attack.height != AttackData.Height.LOW and _facing_blocks(attacker, victim):
			return HitResult.BLOCKED
	return HitResult.KNOCKDOWN if attack.causes_knockdown else HitResult.HIT


static func _facing_blocks(attacker: Fighter, victim: Fighter) -> bool:
	var dx := attacker.position.x - victim.position.x
	if is_zero_approx(dx):
		return true
	return signf(dx) == float(victim.facing)


static func _stronger(c: Contact, result: int, prev_c: Contact, prev_result: int) -> bool:
	if result != prev_result:
		return result == HitResult.KNOCKDOWN
	return c.attack.hit_stun_frames > prev_c.attack.hit_stun_frames
