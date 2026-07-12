extends Node
## Autoload: global signal bus decoupling HUD/FX/audio from combat.
## Emitters — combat: fighter_hit, knockdown_started; MatchManager: score_changed,
## round_state_changed, match_ended; TargetingSystem: target_changed.

@warning_ignore_start("unused_signal")

signal fighter_hit(attacker: Node, victim: Node, result: int, attack: Resource)
signal knockdown_started(victim: Node)
signal score_changed(fighter: Node, new_score: int)
signal round_state_changed(new_state: int)
signal match_ended(winner: Node)
signal target_changed(fighter: Node, new_target: Node)

@warning_ignore_restore("unused_signal")
