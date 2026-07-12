class_name AIProfile
extends Resource
## Tunable AI decision parameters consumed by AIController (docs/plan.md "AI").
## Fairness/perception model: reaction_delay gates how soon a perceived target
## state change becomes actable; block_chance is rolled ONCE per perceived
## incoming attack (stored with that perceived event, not re-rolled per tick);
## mistake_chance is the probability the chosen response is deliberately wrong
## (skip blocking, attack out of range, or block when nothing is coming).

@export var reaction_delay := 0.24 ## seconds between a perceived target state change and acting on it
@export var aggression := 0.55 ## 0-1: drives OBSERVE's approach/attack roll tempo
@export var block_chance := 0.5 ## rolled ONCE per perceived incoming attack
@export var punish_chance := 0.45 ## roll to counter-attack a perceived recovery/stun/wake-up window
@export var mistake_chance := 0.15 ## chosen response is deliberately wrong
@export var retreat_chance := 0.1 ## OBSERVE roll to back off instead of engaging
@export var jump_attack_chance := 0.1 ## ATTACK roll: jump then air-kick instead of a grounded attack
@export var attack_weights: Dictionary = {} ## grounded attack_id (StringName) -> weight; jump attacks use jump_attack_chance
