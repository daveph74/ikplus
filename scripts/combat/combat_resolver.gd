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


var _queue: Array[Contact] = []


func enqueue(attacker: Fighter, victim: Fighter, attack: AttackData) -> void:
	if attacker == victim:
		return # defensive: hitbox poll already excludes self
	var c := Contact.new()
	c.attacker = attacker
	c.victim = victim
	c.attack = attack
	c.victim_state = victim.state
	_queue.append(c)


func _physics_process(_delta: float) -> void:
	if _queue.is_empty():
		return
	var batch := _queue
	_queue = []
	var reactions := {} # victim (Fighter) -> [Contact, HitResult]
	for c in batch:
		var result := resolve_contact(c.attacker, c.victim, c.attack, c.victim_state)
		GameEvents.fighter_hit.emit(c.attacker, c.victim, result, c.attack)
		if result == HitResult.HIT or result == HitResult.KNOCKDOWN:
			c.attacker.apply_hitstop(c.attack.hit_stop_frames())
			var prev: Array = reactions.get(c.victim, [])
			if prev.is_empty() or _stronger(c, result, prev[0], prev[1]):
				reactions[c.victim] = [c, result]
	for victim: Fighter in reactions:
		var c: Contact = reactions[victim][0]
		var result: int = reactions[victim][1]
		var dx := victim.position.x - c.attacker.position.x
		var from_dir := 1 if dx > 0.0 else (-1 if dx < 0.0 else c.attacker.facing)
		victim.apply_hit(c.attack, from_dir, result)
		victim.apply_hitstop(c.attack.hit_stop_frames())


## Rules — single authority for block/invuln/airborne decisions. Static so the
## smoke harness can exercise them directly.
static func resolve_contact(
	attacker: Fighter, victim: Fighter, attack: AttackData, victim_state: int
) -> HitResult:
	match victim_state:
		Fighter.State.KNOCKED_DOWN, Fighter.State.RECOVERING, \
		Fighter.State.ROUND_LOCKED, Fighter.State.VICTORY:
			return HitResult.WHIFF # invulnerable
		Fighter.State.JUMPING:
			# Airborne victims: knockdown regardless of causes_knockdown, or whiff.
			return HitResult.KNOCKDOWN if attack.hits_airborne else HitResult.WHIFF
		Fighter.State.BLOCKING:
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
