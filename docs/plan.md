# Triple Strike POC — Godot 4.7 Three-Fighter Karate Game (Plan v2)

## What changed from v1 (summary)

Reviewed by a 15-agent workflow (4 domain reviewers + adversarial verification of every load-bearing claim against the Godot 4.7-era engine source). 51 refinements folded in; 2 candidate findings were refuted and NOT applied (the `set_deferred` monitoring toggle does **not** eat active-window ticks — deferred calls flush before the same tick's physics step; and the Esc-pause design was fine as written). The big ones:

1. **The old verification gate did not gate.** Godot exits 0 on GDScript parse errors and `_ready()` script errors (verified in `main.cpp` / `gdscript_resource_format.cpp`: "Don't fail loading because of parsing error"). Replaced with an output-grep + exit-code + timeout gate, plus `--check-only` per-file parse checks.
2. **Environment reality.** This plan previously assumed `/home/dev/ikplus` + a preinstalled Godot 4.7. The current session is a cloud container: repo at `/workspace/ikplus` (empty), no Godot anywhere, GitHub release downloads blocked. Added **Step 0: toolchain bootstrap** (source build at tag `4.7-stable` — verified reachable; every dependency verified installable) and parameterized all paths. Both execution lanes (container / user machine) spelled out.
3. **Combat rules that were unspecified and would have been improvised mid-build** are now pinned: FSM transition matrix, controller→fighter intent contract (the old "same intent API" referenced an API that didn't exist), two-phase batched hit resolution (fixes scene-tree-order deciding trades), 9-attack table (was: "9 attacks" with 7 inputs and 6 anims), block input binding (was: none!), jump-kick/airborne rules, stun-lock breaker, facing/targeting rules, arena bounds, sudden-death rules for 3-way partial ties.
4. **Hitbox timing corrected:** Area3D overlap lists report the *previous* physics step, so polls consume the window at ticks `[active_start+1 .. active_end+1]` — polling only during active ticks reliably whiffs 2–4-tick windows point-blank.
5. **Verification is now fast and deterministic:** `--fixed-fps 60` (headless runs at CPU speed, not wall clock — a 60 s scenario no longer takes 60 s), seeded RNG + scripted stub opponents for combat asserts, one separate liveness-only AI soak. `reload_current_scene()` requires `current_scene` to be set manually in the harness.
6. **Git safety for an ephemeral container:** `.gitignore` (`.godot/`) is the first file committed; commit **and push** at the end of every green step (was: one commit at step 12). First push creates `main` (repo is empty; no PR possible for the initial commit). Never commit the built Godot binary.

---

## Context

Build a complete, playable desktop POC of a modern 2.5D karate fighter inspired by the three-fighter structure of classic 1980s karate games (original spiritual successor — no copyrighted names/assets). Three simultaneous fighters (1 human, 2 AI) fight on a 2D plane in a 3D sunset-dojo arena, with point-based arcade scoring (first to reach ≥ 6, 60 s timer, sudden death), knockdowns with repositioning, and responsive combat feel (hit-stop, shake, particles, input buffering).

**Environments.** Two execution lanes; all commands below use `$REPO` and `$GODOT`:

| | `$REPO` | `$GODOT` |
|---|---|---|
| **This cloud session** | `/workspace/ikplus` (cloned, empty, remote wired to `github.com/daveph74/ikplus`) | built in Step 0 → `~/godot-src/bin/godot.linuxbsd.editor.x86_64` |
| **User's machine** | `/home/dev/ikplus` | `/home/dev/bin/godot` (4.7.stable, confirmed) |

The container has: Ubuntu 24.04, 4 cores, ~30 GB free, root, `xvfb-run` + Mesa (llvmpipe GL), `mesa-vulkan-drivers` (lavapipe, software Vulkan) installable via apt, **no display / no GPU**. Network: pypi, npm, apt archive, `raw.githubusercontent.com` open; git smart-HTTP to `godotengine/godot` open; GitHub release assets/codeload **blocked** (hence source build). The container is **ephemeral** — anything unpushed can be lost.

Note: `daveph74/ikplus` is currently a **public** repo — fine for this clean-room game; flip to private first if that's not intended.

## Step 0 — Toolchain bootstrap (container lane only; skip on user machine)

```bash
git clone --depth 1 --branch 4.7-stable https://github.com/godotengine/godot ~/godot-src   # tag verified to exist
pip install scons gdtoolkit          # scons 4.10.x; gdtoolkit gives `gdparse` for interim syntax checks
apt-get install -y build-essential pkg-config libx11-dev libxcursor-dev libxinerama-dev \
  libgl1-mesa-dev libglu1-mesa-dev libasound2-dev libpulse-dev libudev-dev libxi-dev \
  libxrandr-dev libwayland-dev mesa-vulkan-drivers
cd ~/godot-src && scons -j4 platform=linuxbsd target=editor   # background; ~1.5–3 h on 4 cloud cores, ~10 GB
bin/godot.linuxbsd.editor.x86_64 --version && bin/godot.linuxbsd.editor.x86_64 --headless --quit
```

- `target=editor` is **required**, not a convenience: `--import` is an editor-only CLI option, and a fresh clone can't even boot headless until an editor binary has imported it. No `production=yes`/LTO (wasted hours on 4 cores).
- `mesa-vulkan-drivers` = lavapipe → Forward+ can render **in software** under Xvfb (see Verification).
- Start the build in the background and author Step 1–2 files while it compiles, gating their syntax with `gdparse` until the binary exists.
- **Never commit the built binary** to the game repo. A fresh container re-runs Step 0.

## Key architecture decisions

- **One scene boots everything:** `scenes/main/main.tscn` → Main spawns 3 identical `fighter.tscn` instances from `FighterConfig` resources (name, gi/belt colour, is_player, AI profile, spawn X). Player and AI differ only by which Controller node is attached.

- **Controller→fighter intent contract** (new — this is what "player and AI differ only by controller" actually means): every fighter has one controller child exposing `compute_intent(delta)` and an `intent` field — `FighterIntent { move_x: float −1..1, jump: bool (edge), attack_id: StringName (already modifier-resolved, e.g. &"sweep"; empty = none), block: bool (held) }`. `fighter.gd` calls `controller.compute_intent(delta)` at the top of its own `_physics_process` (explicit pull — no tree-order frame lag), then feeds intent to the FSM. State gates (no acting in HIT_STUN/KNOCKED_DOWN/ROUND_LOCKED) live in `fighter.gd`, so they bind player and AI identically. PlayerController fills intent from Input polling + InputBuffer + modifier resolution; AIController fills it from its decision FSM and **never** touches `Input.action_press` (that global-singleton injection is reserved for the smoke harness, where exactly one fighter consumes Input).

- **Fighter = CharacterBody3D** with `axis_lock_linear_z = true` plus defensive `position.z = 0.0` and `position.x = clampf(position.x, −ARENA_HALF_W, ARENA_HALF_W)` after `move_and_slide()` (`ARENA_HALF_W ≈ 7.0`, exported const shared with the arena builder, camera, and reposition marks — no ring-outs in this POC; the floor collider extends past the visual edge as backup). Body never rotates; `facing: int (±1)` flips the `Visual` node (`rotation.y = 0/PI`).
  - **Fighter bodies do not collide with each other:** the fighters collision mask includes world only (jump-overs pass through cleanly; also removes the main Z-drift source, demoting the z-clamp to pure defense). Spacing comes from a soft **separation push**: when two grounded fighters' capsules overlap on X, push both apart along X at a capped rate; suspended while either is KNOCKED_DOWN or during ROUND_LOCKED tweens.
  - **Facing rules:** re-evaluated toward the current target only in IDLE and MOVING, with hysteresis (no flip until |Δx| > 0.2 m); LOCKED during ATTACKING, JUMPING, BLOCKING, HIT_STUN, KNOCKED_DOWN, RECOVERING (a blocker keeps entry facing, so the third fighter's back-hits meaningfully bypass the block-facing check); ROUND_LOCKED sets facing once at the marks.

- **FSM inside `fighter.gd`** as a state enum + match-block enter/exit/physics handlers (10 states: IDLE, MOVING, JUMPING, ATTACKING, BLOCKING, HIT_STUN, KNOCKED_DOWN, RECOVERING, ROUND_LOCKED, VICTORY). Node-per-state is overkill for a POC. **Transition matrix** (the part that defines the game):
  - Forced interrupts, priority ROUND_LOCKED > KNOCKED_DOWN > HIT_STUN, may interrupt ANY state at any tick — so **trades are legal**: HIT_STUN cancels ATTACKING even mid-active-frames.
  - ATTACKING is never voluntarily cancellable — no block/move/jump until recovery ends; buffered inputs consume on the recovery→IDLE transition.
  - BLOCKING ↔ IDLE/MOVING freely on press/release (0 startup, 0 recovery — POC simplicity); grounded only, never from ATTACKING; an attack pressed while blocking is buffered and fires on release.
  - JUMPING→ATTACKING only via the air-attack path below; JUMPING→IDLE on landing.
  - **Every state's exit handler must be interrupt-safe**: ATTACKING's exit always disables the hitbox, clears `victims_hit`, frame counters, and hit-stop, regardless of exit reason.
  - **Air attacks** run in ATTACKING with an `is_airborne` flag: gravity and X-velocity keep integrating (its physics handler runs `move_and_slide` when airborne); enterable from JUMPING at any arc point, once per airborne period; touching the floor immediately ends the attack (hitbox off, remaining frames skipped, ~6-tick landing recovery, then IDLE).
  - **Airborne victims:** any successful hit with `hits_airborne == true` on a JUMPING / airborne-ATTACKING victim resolves as KNOCKDOWN regardless of `causes_knockdown` — the victim falls under gravity into KNOCKED_DOWN. No air hit-stun, no juggles. Attacks with `hits_airborne == false` WHIFF against airborne victims.
  - **RECOVERING** exists solely as the get-up phase inside the round-lock sequence (and for the GLB anim contract) — see match flow.

- **Data-driven attacks:** `AttackData` custom Resource (`id, startup/active/recovery frames, score value, hit-stun frames, knockback Vector2, height HIGH/MID/LOW/AIR, causes_knockdown, hits_airborne, hit_stop_ms, hitbox HAND/FOOT, anim_name`) — 9 `.tres` files in `resources/attacks/`. Combat timing is always tick-counter-driven from AttackData, never from animation callbacks. **The 9 attacks** (3 deliberately reuse anims — legal because `play_attack()` rescales clips):

  | id | input | height | score | knockdown | hits_airborne | anim |
  |---|---|---|---|---|---|---|
  | punch_high | J | HIGH | 1 | no | no | punch_high |
  | punch_body | fwd+J | MID | 1 | no | no | punch_low *(reuse)* |
  | punch_low | S+J | MID (crouching — does **not** bypass block) | 1 | no | no | punch_low |
  | kick_high | K | HIGH | 1 | no | yes | kick_front *(reuse)* |
  | kick_front | fwd+K | MID | 1 | no | no | kick_front |
  | kick_round | back+K | HIGH | **2 (strong)** | yes | yes | kick_round |
  | sweep | S+K | **LOW (the only low — bypasses block)** | 1 | yes | no | sweep |
  | kick_jump | air+K | AIR (blocks as HIGH) | **2 (strong)** | yes | yes | kick_jump |
  | punch_jump | air+J | AIR (blocks as HIGH) | 1 | no | yes | punch_high *(reuse)* |

- **Hitboxes/Hurtboxes = Area3D.** Hurtboxes are children of the CharacterBody3D (unaffected by Visual rotation) and mirror their CollisionShape3D local X offsets on facing change; the hitbox Area3D takes its global position **solely** from the `AttachHandR`/`AttachFootR` attachment's global transform each active tick (zero local offset, no facing mirroring — the Visual rotation already mirrors the attachments; applying both would double-flip). All shapes are X-symmetric primitives, so no shape-level mirroring exists anywhere.
  - **Timing (engine-verified):** enable `monitoring` via `set_deferred` on entering active frames (from `_physics_process` this flushes before the same tick's physics step). Area3D overlap lists always report the **previous** physics step, so poll `get_overlapping_areas()` on ticks `active_start+1 .. active_end+1` — never on the geometric active ticks themselves — and disable monitoring (deferred) only at `active_end+1`, after the final poll (`set_monitoring(false)` clears unread results). Consequence to encode in tests: a hit registers one tick after geometric overlap; `active_frames = 1` works (single poll at N+1). Do NOT "optimize" to always-on monitoring gated at poll time — that consumes overlaps computed at the previous tick's chambered hitbox position (false hits).
  - Track `victims_hit` for one-hit-per-attack. **Self-hit exclusion:** hurtboxes expose `owner_fighter`; the poll skips overlaps owned by the attacker (a chambered fist starts inside your own chest hurtbox), and CombatResolver rejects attacker == defender defensively.

- **CombatResolver — two-phase, batched** (kills scene-tree order as a hidden combat rule): during a physics tick, hitboxes only ENQUEUE contact records (attacker, victim, AttackData, victim-state snapshot for block/invuln checks sampled at enqueue). After all fighters tick, Main flushes the batch atomically: every valid attacker scores (double-team = 2 separate points); a victim hit twice takes the single strongest reaction (KNOCKDOWN > HIT_STUN; max stun; stronger knockback); mutual same-tick hits both apply — both score, both react. Block check = facing + height (HIGH/MID/AIR blockable, LOW bypasses). Result enum: WHIFF / BLOCKED / HIT / KNOCKDOWN.
  - **BLOCKED:** 0 points, block sfx, ~8-tick block-stun (defender holds pose) + ~0.4 m pushback on the defender; attacker completes normal recovery. No chip (points, not health).
  - **Re-hit during HIT_STUN:** allowed — new hit scores and RESETS stun/knockback; but `consecutive_stun_hits` is tracked and the 3rd hit without an intervening neutral state auto-converts to KNOCKDOWN (normal score) → round-lock reposition. This is the anti-two-on-one-stun-lock rule; counter resets on leaving HIT_STUN.
  - MatchManager checks wins once per batch: first to reach **≥ 6** (2-pt moves overshoot); two crossing in the same batch → higher total wins, equal totals → sudden death.

- **Hit-stop = per-fighter frame freeze**, applied to **both attacker and victim** (same `hit_stop_ms`): `hitstop_frames > 0` gates the fighter's entire combat tick — FSM handler, attack frame counters, hitbox snap/poll — all driven from `fighter.gd`'s `_physics_process` so one gate covers them (active windows cannot silently expire mid-freeze). On freeze entry cache velocity and zero it; restore on exit (an airborne jump-kicker keeps its arc). Controllers and the InputBuffer keep collecting during hit-stop and hit-stun (buffering through freezes is what makes follow-ups feel good). The frozen fighter's hurtbox stays live — a third-fighter hit lands through the batch resolver and overwrites stun/hitstop counters. NOT `Engine.time_scale` (freezes the uninvolved third fighter, camera, HUD), NOT `get_tree().paused` (collides with Esc pause). Anim freeze via `speed_scale = 0` — see next bullet.

- **Two speed knobs, never shared:** `play_attack()` retimes clips via the `custom_speed` argument of `play()` (`clip_length / attack.total_seconds()`); `speed_scale` is reserved exclusively for hit-stop (0 frozen / 1 running). The engine multiplies them, so freeze/unfreeze never needs to know the retime factor.

- **GLB-swap contract** (documented in `docs/architecture.md`) — discovery-based, not fixed-path (BoneAttachment3D must live under the imported rig's Skeleton3D, and an imported AnimationPlayer cannot be re-parented without breaking track paths): the replacement rig mounts at `Fighter/Visual/Rig`; `fighter.gd` resolves the AnimationPlayer and `AttachHandR`/`AttachFootR` by `find_child(name, true)` anywhere under `Visual`. Fixed are only the mount point, the two attachment names, and the 15 canonical animation names (`idle, walk_fwd, walk_back, jump, punch_high, punch_low, kick_front, kick_round, sweep, kick_jump, block, hit_react, knockdown, recovery, victory`). No defeat clip by design — losers reuse idle / hold the knockdown end pose. `play_attack()`'s retiming means combat survives mismatched clip lengths.

- **Placeholder animations:** built procedurally in `fighter_visual.gd` at load as `Animation` resources (ROTATION_3D/POSITION_3D tracks on the primitive-mesh rig) in an `AnimationLibrary`, played through a real AnimationPlayer — attack clips generated at exactly `attack.total_seconds()` with the strike pose at `startup_frames/60.0`. Not tweens (breaks the GLB contract), not hand-authored .tres (unmaintainable quaternion soup).

- **Autoloads (2 only), stubbed from Step 1** (registering an autoload whose script doesn't exist yet logs "Failed to instantiate an autoload" on every boot — which trips the error-grep gate): `game_events.gd` ships in Step 1 with all signal declarations; `audio_manager.gd` ships in Step 1 as a no-op `play()` API, replaced by real synthesis in Step 10.
  - `GameEvents` signals: `fighter_hit, knockdown_started, score_changed, round_state_changed, match_ended, target_changed`.
  - `AudioManager`: loads `assets/audio/*.wav` if present, else synthesizes 16-bit PCM `AudioStreamWAV` placeholders at boot (punch/kick/block/knockdown/round-start/victory/looped ambience; never crashes on missing files). **Looping ambience requires explicit loop points:** `loop_mode = LOOP_FORWARD, loop_begin = 0, loop_end = total sample frames` (`loop_end` defaults to 0 → silent no-loop). One-shots keep LOOP_DISABLED.

- **FXManager = plain node under Main** (not an autoload): subscribes to GameEvents (`fighter_hit`, `knockdown_started`); spawns one-shot `impact_particles.tscn` at contact points (free on finished); requests CameraRig shake; forwards sfx names to AudioManager. It owns world-space FX only — HUD owns text cues, AudioManager owns playback.

- **Input Map (enumerated — Step 1 writes project.godot):** `move_left` (A, ←, lstick −X) · `move_right` (D, →, lstick +X) · `down` (S, ↓, lstick +Y — modifier only, no crouch state) · `jump` (W, Space, joy bottom/Cross-A) · `punch` (J, joy left/Square-X) · `kick` (K, joy top/Triangle-Y) · `block` (**L held**, joy right/Circle-B) · `pause` (Esc, Start) · `restart` (R, Select) · `debug_toggle` (F3, keyboard only). Arrows dual-bound beside WASD. PlayerController polls in `_physics_process` (60 tps) into a ~130 ms `InputBuffer` (RefCounted ring buffer); directional modifiers resolved at consume time per the attack table.

- **AI:** `AIController` FSM (OBSERVE/APPROACH/ATTACK/DEFEND/RETREAT/PUNISH) writing the FighterIntent contract, parameterized by `AIProfile` Resource — easy/normal/hard `.tres`, Normal default. **Perception model (fairness):** the AI may react to an opponent state change only after `reaction_delay` seconds since that change (per-event timestamps — no continuous frame-perfect reads); `block_chance` rolls once per perceived incoming attack; `mistake_chance` = probability the chosen response is deliberately wrong (wrong block height, out-of-range attack, or no reaction); the AI never reads the player's InputBuffer or pending intents. Same-constraints fairness (no acting in stun/knockdown) falls out of the intent gates in `fighter.gd`.

- **Targeting:** `TargetingSystem` node under Main. Rule (non-circular): target = closest living opponent, with hysteresis — a challenger must be ≥ 0.5 m closer to steal the slot, min 0.3 s between player target switches; facing = `sign(target.x − self.x)` under the facing rules above. No manual target-switch input in the POC — hysteresis IS the flanked-player behavior. AI reconsiders every 1.5–3 s with weighting so the two AIs sometimes fight each other; **forced retarget events** (rate-limited by the 0.8 s switch cooldown): ROUND_LOCK exit (all AIs re-evaluate), current target removed from play (sudden death), and being hit by a non-target (roll aggression to switch to the aggressor).

- **Match flow** (`MatchManager`, graph — not a linear chain):
  - **INTRO** (fixed ~1.5 s, fighters ROUND_LOCKED, "Ready… Fight!" cue + round-start sfx, ends on timer) → **FIGHTING**.
  - The 60 s timer counts down **only during FIGHTING**.
  - Scoring: 1 pt normal / 2 pt strong (kick_round, kick_jump). *Deliberate deviation from the inspiration:* only knockdowns trigger the reposition lock; normal points score in continuous play (HUD flash + sfx) to keep three-fighter scrambles flowing.
  - Knockdown in FIGHTING: win-check first — if the scoring hit reached ≥ 6, straight to ENDED (skip the lock); else **ROUND_LOCK** → FIGHTING with a fresh "Fight!" cue.
  - **ROUND_LOCK entry contract:** every fighter force-exits its state through the interrupt-safe exit handler (attacks cancelled, hitboxes off, hit-stop cleared), velocity zeroed, gravity suspended, all fighters invulnerable until "Fight!"; the reposition tween is sole authority over position (airborne fighters tween to their ground mark). Sequence: victim plays knockdown anim during the ~0.7 s hold (others frozen in place) → all tween to separated marks (victim prone) → victim plays `recovery` (get-up) as its lock-exit anim → "Fight!" when all are IDLE. Knockdown events arriving during the lock still award their batch-resolved point but never restart the hold. MatchManager's handler is idempotent.
  - Timeout → highest score wins; tie → **SUDDEN_DEATH: leaders only.** Non-leaders are removed from play (ROUND_LOCKED at an edge mark, boxes disabled, excluded from TargetingSystem). First clean scoring HIT or KNOCKDOWN between participants ends it — BLOCKED/WHIFF never do; a knockdown here goes straight to ENDED (no lock). Same-batch trade between leaders: higher score-value attack wins; equal → continue. If the two AIs are the tied leaders, the player spectates (accepted POC behavior). All-three tie → all participate.
  - **ENDED:** winner → VICTORY anim + overlay; all non-winners → ROUND_LOCKED (standing losers idle; a downed loser holds the knockdown pose, skipping RECOVERING); in-flight attacks cancelled, input disabled, R restarts (`reload_current_scene`).

- **Esc pause:** `get_tree().paused` with gameplay PROCESS_MODE_PAUSABLE and PauseLayer WHEN_PAUSED; the Esc *listener* lives on a PROCESS_MODE_ALWAYS node so it can both open and close the menu. Independent of hit-stop.

- **Camera:** CameraRig → ShakePivot → Camera3D (fov ~25° **vertical** ≈ 43° horizontal at 16:9; long-lens flattened look). Frames **all three fighters** via a player-biased centroid (weights 2/1/1); because fighter X is clamped to ±ARENA_HALF_W, worst-case spread is bounded and the max camera distance derives from it (~1.26 × max spread + margin) — "all three visible" is a hard guarantee, not a hope. Distance-based zoom with hysteresis on zoom-in only; decaying-noise shake on impacts — full amplitude only when the player is attacker or victim, ~40% for AI-vs-AI exchanges. Never rotates around the arena.

- **Arena:** primitive-built coastal dojo at sunset, constructed by `scripts/arena/arena_builder.gd` in `_ready()` (programmatic set-dressing matches the procedural-placeholder philosophy and keeps `arena.tscn` tiny): wooden platform, dojo building, ocean plane, distant mountains, red maple, stone lanterns, banner quads with abstract symbols, spectator capsules. WorldEnvironment: ProceduralSkyMaterial sunset, directional light + soft shadows, SSAO + SSIL (half-res), AgX tonemapping, sparing glow, subtle volumetric fog, debanding, screen-space AA. (Renderer caveats → Verification.)

- **Debug:** `DebugDraw` node under Main (added Step 5), guarded by `OS.is_debug_build()`: F3 toggles hitbox/hurtbox wireframes (green hurt / red active hit) — boxes self-register with it — plus a private CanvasLayer FPS label independent of the HUD.

- **HUD:** 3 score panels — each shows fighter name + gi-colour swatch from FighterConfig + a "YOU" tag on the player's panel — 60 s timer, sudden-death banner (greys eliminated fighters' panels), Ready/Fight!/winner overlays, control guide. The player's current target is indicated (highlight ring on that opponent's panel + small marker above the fighter), driven by `GameEvents.target_changed`. Cue ownership: MatchManager emits state; HUD renders all text cues; AudioManager plays cue sounds off GameEvents; FXManager owns world FX only.

## File inventory

```
$REPO/
  .gitignore                     # FIRST file committed: .godot/  (keep *.import sidecars tracked)
  project.godot                  # Forward+, 1920×1080, physics tps 60, full Input Map (above), layers
                                 #   (world/fighters/hitbox/hurtbox), debanding, autoloads, config/icon
  icon.svg                       # trivial placeholder (a referenced-but-missing icon errors every boot)
  README.md                      # controls, how to run (godot --path . — no export presets by design),
                                 #   how to replace placeholders (audio + GLB)
  docs/architecture.md           # GLB-swap contract + system overview
  assets/audio/.gitkeep          # empty (synthesized fallbacks); naming doc in README
  assets/materials/              # shared gi/arena StandardMaterial3D .tres
  scenes/main/main.tscn          scripts/match/main.gd
  scenes/arena/arena.tscn        scripts/arena/arena_builder.gd
  scenes/fighters/fighter.tscn   scripts/fighters/{fighter.gd, fighter_visual.gd, player_controller.gd,
                                                   input_buffer.gd, fighter_config.gd, fighter_intent.gd}
  scenes/ui/hud.tscn             scripts/ui/hud.gd
  scenes/effects/impact_particles.tscn
  scripts/combat/{attack_data.gd, hitbox.gd, hurtbox.gd, combat_resolver.gd, debug_draw.gd}
  scripts/ai/{ai_controller.gd, ai_profile.gd, targeting_system.gd}
  scripts/camera/camera_rig.gd
  scripts/match/{match_manager.gd, game_events.gd, audio_manager.gd, fx_manager.gd}
  resources/attacks/*.tres       # 9 attacks (table above)
  resources/fighters/*.tres      # 3 FighterConfigs + 3 AIProfiles
  test/smoke.gd                  # headless SceneTree test harness (contract below)
```

22 small typed-GDScript scripts (5 match + 6 fighters + 5 combat + 3 ai + 1 camera + 1 ui + 1 arena) + smoke.gd. No addons, no external assets, no deprecated APIs (no `yield`, string-form `connect`, `instance()`, Tween node, etc.).

## Build order (each step ends runnable, committed, AND pushed)

0. **Toolchain bootstrap** (container lane) — as above; runs in background from minute 0.
1. **Scaffold** — `.gitignore` first; project.godot (renderer, resolution, physics tps 60, full Input Map incl. gamepad, collision layer names, autoloads), **autoload stubs** (`game_events.gd` with all 6 signals; no-op `audio_manager.gd`), icon.svg, minimal main.tscn (ground + camera + light), README. First `--import` run un-gated (fresh-cache bootstrap noise), gated re-run must be clean. **First push creates `main`** (empty repo — no PR possible for the initial commit; linear commits to main thereafter).
2. **Fighter shell + movement** — capsule fighter, FSM (IDLE/MOVING/JUMPING), FighterIntent + PlayerController, Z lock + X arena clamp, facing rules.
3. **Visual rig + procedural animations** — primitive humanoid under Visual/Rig, animation generation for idle/walk/jump.
4. **One attack end-to-end** — AttackData + punch_high, InputBuffer, ATTACKING timers, Hitbox/Hurtbox (shifted poll window, self-hit exclusion), batched CombatResolver, HIT_STUN, hit-stop, vs a **stub-controller dummy** second fighter. Combat emits GameEvents from here. ← core-feel milestone; tune here. Start `test/smoke.gd` (asserts: hit registers within active+1 ticks, HIT_STUN entered, hit-stop counters tick).
5. **Full move set** — remaining 8 attacks per the table, block (input + rules + stun/pushback), knockdown/recovery + invulnerability, stun-lock breaker, airborne rules, all 15 anims, DebugDraw + F3. (+ smoke asserts: block-facing, low bypass, blocked-scores-zero, knockdown+invuln, 3-hit stun conversion.)
6. **Three fighters + targeting** — FighterConfig spawning, TargetingSystem (hysteresis + events), separation push, auto-facing. (+ smoke asserts: targeting/hysteresis.)
7. **AI** — AIController + 3 AIProfiles; verify AIs sometimes fight each other and make mistakes (mistake_chance is observable via forced-seed runs). (+ AI soak scenario, liveness only.)
8. **Match rules + HUD** — MatchManager (full graph incl. sudden-death rules), wire HUD to the existing bus, pause, R restart. (+ smoke asserts: scoring, ≥6 ends, timeout, sudden death, restart.)
9. **FX polish** — FXManager (particles, shake routing, flash), camera framing/zoom/shake tuning.
10. **Audio** — replace AudioManager stub with WAV synthesis + looped ambience (loop_end!).
11. **Arena + environment** — arena_builder set-dressing + WorldEnvironment tuning; in-container screenshot lane (below); FPS check deferred to user machine.
12. **Docs + final pass** — README, docs/architecture.md, full smoke suite green, final push.

## Verification

**Per-step gate** (stated once, used after every step; `godot` exits 0 even when every script is broken — parse errors deliberately don't fail resource loads, and `--quit`/`--import` never touch the exit code, so gate on exit code AND log AND a timeout — a native crash prints no `ERROR:` line while a hung harness never exits):

```bash
check() {  # usage: check <logname> <godot args...>
  local log="/tmp/$1.log"; shift
  timeout 120 $GODOT --headless --path "$REPO" "$@" >"$log" 2>&1
  local code=$?; cat "$log"
  [ "$code" -eq 0 ] || { echo "FAIL: exit $code (124 = hang)"; return 1; }
  ! grep -qE 'SCRIPT ERROR:|ERROR:' "$log" || { echo "FAIL: errors in log"; return 1; }
}
check import --import
# per-file parse gate — the one mode where Godot natively exits non-zero on a broken script:
(cd "$REPO" && find scripts test -name '*.gd' -print0) \
  | xargs -0 -I{} $GODOT --headless --path "$REPO" --check-only --script "res://{}" || exit 1
check boot  --quit
check smoke --fixed-fps 60 --script res://test/smoke.gd     # from step 4 on
```

**smoke.gd contract** (`extends SceneTree`):
- `--fixed-fps 60` makes every iteration advance exactly one 60 Hz tick at CPU speed (no real-time sync) — a full match asserts in seconds, not minutes. Sequence assertions from `_process` by watching `Engine.get_physics_frames()` / game state ("wait N ticks", not "step N frames" — stepping isn't an API). Shrink long scenarios via an exported debug property on MatchManager (e.g. 3 s timer) rather than simulating 60 s.
- After `root.add_child(main_instance)`, set `current_scene = main_instance` (in that order — the setter requires the node already parented to root). Without it, `reload_current_scene()` returns ERR_UNCONFIGURED and the R-restart assert fails only in the harness.
- **Determinism:** `seed(0)` at start; combat-rule scenarios spawn fighters from test FighterConfigs with scripted/passive stub controllers at fixed positions (no live AI), asserting via GameEvents signals. Exactly one full-AI soak scenario, asserting liveness only (no errors; match reaches ENDED).
- **Input injection:** `Input.action_press` registers on the NEXT physics tick, stays just-pressed for exactly one tick, and never re-fires while held — so: press → wait ≥ 1 tick → assert; `action_release` before re-pressing; sustained movement = press once, release when done. (Injection drives the global singleton — valid here because exactly one fighter reads Input.)
- **Failure paths must be reachable:** use `if not cond: push_error(...); quit(1)` — never bare `assert()` (a tripped assert aborts the method before any quit, leaving the tree idling; the `timeout` converts that hang to a red) — plus a frame-count watchdog that `quit(1)`s on stall. Scenario list (staged per build order): fighter moves/jumps → punch lands within active+1 ticks & scores 1 → block prevents score → sweep bypasses block → knockdown triggers lock + reposition → reaching ≥ 6 ends match → timeout/sudden-death rules → R restarts.

**Visual lanes** (replaces "final manual check — display available on this machine", which is false for the container):
1. **In-container screenshots:** `xvfb-run $GODOT --path $REPO` with lavapipe installed renders genuine **Forward+** frames in software. Capture via a debug hook that waits N frames, `await RenderingServer.frame_post_draw`, then `get_viewport().get_texture().get_image().save_png(...)`. The hook must print/assert `RenderingServer.get_current_rendering_method()` — without lavapipe, `fallback_to_opengl3=true` silently downgrades to Compatibility and the screenshot lies about what it validates. Deterministic fallback lane: `--rendering-method gl_compatibility --rendering-driver opengl3` — composition/materials/sky only (SSIL, volumetric fog, debanding, screen-space AA are silent no-ops there; glow simplified; SSAO + AgX work).
2. **User's machine:** windowed run for 60 FPS (F3), input feel, gamepad. Software-renderer FPS numbers are meaningless — never tune performance against them.

## Known gotchas being designed around

- Godot's exit code lies: parse errors and `_ready()` script errors exit 0 (`--check-only` and `SceneTree.quit(1)` are the only script-error-reliable codes) — hence the grep+timeout gate.
- Area3D overlap lists are one physics step stale; monitoring toggles via `set_deferred` flush before the same tick's physics step — poll window is `[active+1 .. end+1]`, disable after the final poll. Hits register one tick after geometric contact (asserts must allow it).
- `Input.action_press` lands next-tick, once, no auto-repeat (harness contract above).
- `reload_current_scene()` needs `current_scene` set when the harness instantiated the scene manually.
- `AnimationPlayer`: `custom_speed` (retiming) and `speed_scale` (hit-stop) multiply — never share one knob.
- `AudioStreamWAV.loop_end` defaults to 0 → looping ambience must set it explicitly.
- Registered-but-missing autoloads and a missing `config/icon` file error on every boot → stubs + icon.svg ship in Step 1.
- Typed arrays non-covariant; typed Dictionaries OK on 4.7; enum-typed state vars.
- `--headless` uses the dummy renderer — rendering exists only via the xvfb lanes; `fallback_to_opengl3` can silently swap renderers, so screenshot hooks must label the active method.
- Fighter capsule collisions can inject Z drift — moot once fighter-fighter body collision is masked off, but the `position.z = 0` clamp stays as defense; `position.x` clamps to arena bounds.
