class_name FighterConfig
extends Resource
## Spawn-time fighter parameterization; consumed by Main at build step 6.

@export var display_name := "Fighter"
@export var gi_color := Color(0.92, 0.9, 0.85)
@export var belt_color := Color(0.15, 0.15, 0.15)
@export var is_player := false
@export var ai_profile: AIProfile = null
@export var spawn_x := 0.0
@export var rig_scene: PackedScene = null ## imported GLB character; null = procedural placeholder
