extends Node
## Autoload stub: safe no-op audio API so every boot from step 1 onward is clean.
## Build step 10 replaces this with assets/audio/*.wav loading and synthesized
## 16-bit PCM fallbacks (see docs/plan.md).


func play(_sfx_name: StringName) -> void:
	pass


func start_ambience() -> void:
	pass
