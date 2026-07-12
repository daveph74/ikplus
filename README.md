# Triple Strike

A 2.5D three-fighter karate POC in Godot 4.7 — one human and two AI fighters on a
2D plane inside a 3D sunset-dojo arena. Point-based arcade scoring: first to reach
6 points, 60 s timer, sudden death on ties. An original spiritual successor to the
classic 1980s three-fighter karate games (no copyrighted names or assets).

Build plan and architecture rationale: [`docs/plan.md`](docs/plan.md).

## Run

```bash
godot --path .        # requires Godot 4.7 (Forward+); no export presets by design (POC)
```

## Controls

| Action | Keyboard | Gamepad |
|---|---|---|
| Move | A / D (or ← / →) | Left stick |
| Modifier (low/crouch) | S (or ↓) | Left stick down |
| Jump | W or Space | Bottom button (Cross/A) |
| Punch | J | Left button (Square/X) |
| Kick | K | Top button (Triangle/Y) |
| Block (hold) | L | Right button (Circle/B) |
| Pause | Esc | Start |
| Restart (after match) | R | Select/Back |
| Debug hit/hurtbox + FPS | F3 (debug builds) | — |

Attack chords: `fwd+J` body punch · `S+J` low punch · `K` high kick · `fwd+K` front kick ·
`back+K` roundhouse (2 pt) · `S+K` sweep (only low attack — bypasses block) ·
air `J`/`K` jump punch / jump kick.

## Verification

```bash
GODOT=/path/to/godot tools/verify.sh
```

Runs the import gate, per-file `--check-only` parse checks, a boot check, and the
`test/smoke.gd` headless harness (at `--fixed-fps 60`, so simulated time runs at CPU
speed). Godot's exit code alone is NOT a reliable gate — the script also greps for
`SCRIPT ERROR:` / `ERROR:` output.

## Replacing placeholders

- **Audio:** drop WAV files into `assets/audio/` using the names documented in
  `scripts/match/audio_manager.gd`; synthesized placeholders are used when absent.
- **Fighter model:** swap a GLB rig in at `Fighter/Visual/Rig` — the contract
  (15 canonical animation names, `AttachHandR`/`AttachFootR` attachment nodes,
  discovery rules) is documented in `docs/architecture.md`.
