# Triple Strike — architecture overview & GLB-swap contract

Godot 4.7 (Forward+). Full build rationale: [`plan.md`](plan.md) · visual spec: [`art-direction.md`](art-direction.md).

## System map

```
Main (Node3D, physics priority 50 — separation push)
├─ Arena (arena.tscn — arena_builder.gd set-dressing + WorldEnvironment + sun + ground collider)
├─ Fighter ×3 (fighter.tscn, spawned from FighterConfig .tres; "fighters" group)
│  ├─ Controller (PlayerController | AIController — writes a FighterIntent per tick)
│  ├─ Visual (FighterVisual — procedural rig + AnimationLibrary; GLB mount point below)
│  ├─ Hurtbox (Area3D, layer hurtbox, monitorable)  ├─ Hitbox (Area3D, layer hitbox, monitoring toggled)
├─ TargetingSystem (priority -10 — targets assigned before fighters tick)
├─ CombatResolver (priority 100 — batched two-phase hit resolution)
├─ MatchManager (priority 110 — batch-atomic scoring/phase machine)
├─ FXManager (particles, victim flash, shake routing, per-hit sfx forwarding)
├─ CameraRig → ShakePivot → Camera3D (player-biased centroid framing, fov 25)
├─ HUD (CanvasLayer; all text cues) · PauseController/PauseLayer · RestartController · DebugDraw (F3)
Autoloads: GameEvents (signal bus) · AudioManager (synthesized-WAV playback)
```

**Physics-tick ordering is load-bearing:** TargetingSystem (-10) → fighters (0, enqueue contacts)
→ Main separation (50) → CombatResolver flush (100, applies the whole batch atomically so
scene-tree order never decides trades) → MatchManager (110, sees the complete batch for
win/knockdown decisions).

Combat timing is tick-counted at 60 physics tps from `AttackData` frame fields — never from
animation callbacks. Area3D overlap lists lag one physics step, so hitboxes poll on ticks
`[active_start+1 .. active_end+1]` and a hit registers one tick after geometric contact.
Autoloads are always fetched via `get_node(^"/root/GameEvents")` — bare autoload identifiers
fail the `--check-only` parse gate (project convention, see `tools/verify.sh`).

## GLB-swap contract (replacing the placeholder fighter)

**Preferred path (adapter does the heavy lifting):** set `rig_scene` on a `FighterConfig` (or on
`FighterVisual` directly) to the imported character scene. At spawn the adapter mounts it as
`Rig`, yaws it by `rig_facing_deg` (default 90° — glTF characters typically face +Z, the contract
is +X), uniformly scales it to `target_height` (1.75 m) with feet on the floor, resolves foreign
clip names through `CLIP_ALIASES` (e.g. `Punching` → `punch_high`, `Walking_Backwards` →
`walk_back`; unmatched moves simply play without animation), and auto-creates missing
`AttachHandR`/`AttachFootR` as `BoneAttachment3D` by bone-name heuristics (`RightHand`,
`Hand_R`, `mixamorig_RightHand`, …). The whole path is regression-tested against
`test/fixtures/foreign_rig.tscn`, a Mixamo-style fixture. Note: Godot forbids `:` in bone
names — the glTF importer sanitizes `mixamorig:Hips` to `mixamorig_Hips`; the heuristics
ignore punctuation entirely.

**Manual path** — mount a rig scene at **`Fighter/Visual/Rig`**, replacing the node. Rules:

- **Discovery, not fixed paths:** `fighter.gd` and `fighter_visual.gd` resolve the
  `AnimationPlayer` and the `AttachHandR` / `AttachFootR` attachment nodes via
  `find_child(name, true)` anywhere under `Visual`. The imported AnimationPlayer is never
  re-parented (its track paths stay valid); on a skeletal rig the attachments should be
  `BoneAttachment3D` nodes under the rig's `Skeleton3D`, named exactly `AttachHandR` and
  `AttachFootR`.
- **15 canonical animation names** (in the default library): `idle, walk_fwd, walk_back, jump,
  punch_high, punch_low, kick_front, kick_round, sweep, kick_jump, block, hit_react, knockdown,
  recovery, victory`. Loops: idle/walk_fwd/walk_back/block. `knockdown` must END in the prone
  pose (ENDED-state losers hold its last frame). There is deliberately **no defeat clip** —
  losers reuse idle or hold the knockdown end pose.
- **Clip lengths don't matter:** `play_attack()` retimes every strike clip to the attack's
  tick-driven duration via `play()`'s `custom_speed`. `speed_scale` is reserved exclusively for
  hit-stop freezes — the two multiply, so never bake either into the rig.
- Facing is applied by rotating `Visual` (`rotation.y = 0 / PI`); the rig must be authored
  facing **+X**.

## Replacing placeholder art & audio

Every hook below prefers a file when it exists and falls back to the procedural placeholder
when it doesn't — no code changes to swap assets in:

| Asset | Drop file at |
|---|---|
| Sound effects | `assets/audio/{punch,kick,block,knockdown,round_start,victory}.wav` |
| Looped ambience | `assets/audio/ambience.wav` (loop points are forced on at load) |
| HUD portraits | `assets/ui/portraits/{p1,p2,p3}.png` (keyed by FighterConfig display_name, lowercased) |
| Deck wood grain | `assets/textures/deck_planks.png` (tileable; applied triplanar, tone-tinted per plank) |
| Banner cloth | `assets/textures/banner.png` (vertical design incl. glyphs; replaces the glyph block) |
| Paper lantern | `assets/textures/lantern_paper.png` |
| Sky | `assets/textures/sky_panorama.png` (equirectangular; swaps ProceduralSky → PanoramaSky) |

Synthesized-audio loop trap: an `AudioStreamWAV` with `loop_end = 0` (the default) silently
plays once — looping streams must set `loop_begin`/`loop_end` explicitly.

## Verification lanes

- `GODOT=<binary> tools/verify.sh` — import gate, per-file `--check-only` parse gate, boot gate
  (exit code AND error-grep AND timeout — Godot exits 0 on script errors), and the
  `test/smoke.gd` functional suite at `--fixed-fps 60` (55+ staged asserts, seeded, stub-driven).
- `SHOT_DIR=... xvfb-run -a -s "-screen 0 1920x1080x24" $GODOT --path . --script res://test/screenshot.gd`
  — renders real Forward+ frames (software Vulkan) and stamps the ACTIVE rendering method into
  the filename so a silent GL-compatibility fallback is never mistaken for Forward+ validation.
- Performance/feel (60 FPS, input latency, gamepad) is only meaningful on real hardware:
  `godot --path .` windowed, F3 for the FPS overlay.
