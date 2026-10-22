# The Backrooms: Nullspace — Unreal Engine 5 Port Plan

> **Audience:** the AI coding agent doing the port. Read this first, every session.
> **Source of truth for behaviour:** the Godot project in `godot-backrooms/` (Godot 4.7, Forward+, Jolt, ~75k lines of GDScript).
> Every Godot path below is relative to `godot-backrooms/`. When a feature is ported, open the Godot script named
> in its row and port its *behaviour and tuning numbers*, not its structure. Godot workarounds (light pools, CPU GI,
> hand-written snapshot interpolation, ADPCM) mostly disappear because UE5 has a native system for them.

---

## 0. Ground rules for the agent

1. **One phase at a time.** Do not start a later phase until the current one is accepted by the user. The current
   phase is **Phase 1 (first-person body)**. Movement and camera already exist in the UE project: verify them, do not
   rebuild them.
2. **Keep the game's scale.** Grid cell = **4.5 m**, wall height = **5.4 m**, wall thickness = **0.3 m**, storey = **9 m**,
   standing eye = **1.7 m**, crouched = **1.0 m**. UE units are cm: cell = 450 uu, wall = 540 uu. Never rescale to
   "real-world" proportions.
3. **Mannequin rule:** a mannequin never moves while any player can see it. Pose changes only happen unseen or behind
   a forced blink. This is a hard design invariant.
4. **C++ for systems, Blueprint for content.** Core systems (level builder, entity brains, event director, net) in C++
   classes with `UPROPERTY` tuning exposed; Blueprint subclasses for assets, timings and art hookup. Use **StateTree**
   for AI, **GAS is not needed**.
5. **Port tuning numbers verbatim** (speeds, timers, ranges, cooldowns). They are in `const` blocks at the top of each
   Godot script and were tuned by playtesting.
6. **Lore branding:** the agency is **T.S.R.A.** (Threshold Spatial Research Agency) on every label, HUD log and terminal.
7. Assets: models are `.glb` under `models/`. Import with UE's glTF/Interchange importer or re-export FBX from Blender
   (Blender build scripts live in `tools/blender/`). Audio under `audio/` imports directly (WAV/MP3/OGG).
8. The `unreal-mcp` server was configured but not reachable when this plan was written; if it is up, prefer it to
   inspect the UE project.

---

## 1. Phase map

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Movement, mouse look, camera | **Done in UE** (verify against §3.1 numbers) |
| **1** | **First-person body: arms + torch, visible legs, own shadow, animation system, camera feel** | **CURRENT** |
| 2 | Player systems: stamina / sanity / health / adrenaline / battery, heart, breathing, footsteps, blink | next |
| 3 | Tools in hand: torch, flash, scanner, camcorder zoom, hazard tape, marker, interact + pickups, inventory | |
| 4 | Level pipeline: `.lvl` import, walls graph, geometry, trim, fixtures, lighting, floors / stairs / pits | |
| 5 | Render look: camera post shader, atmospheres, fear FX channels, VHS / death FX | |
| 6 | Entities: Bacteria, Mannequin, Mimic, Eyes, Grabber, Burnt, Tall One (+ model-only roster) | |
| 7 | Event director + audio (ambience, scares, acoustics, machine voice) | |
| 8 | UI: HUD, TAB terminal, menus, lobby, briefing, death screen, debug console | |
| 9 | Co-op (8 players) + proximity voice | |
| 10 | Meta: archive, clearance XP, saves, settings, crash reports, perf overlay, hub level | |

---

## 2. Godot → UE5 architecture map

| Godot | UE5 replacement |
| --- | --- |
| Autoloads (`project.godot [autoload]`: Crash, Game, Keybinds, Death, Net, Gfx, Stability, Render, EntityLOD, Perf, Voice, Archive, Clearance, Saves) | `UGameInstanceSubsystem` for cross-level state (Archive, Clearance, Saves, Keybinds, Gfx); `UWorldSubsystem` for per-run state (Game run state, EntityLOD, Render, Events) |
| `Game` (`scripts/GameLogicEngine/game_state.gd`) fear channels `fx_*`, `fear`, `terror`, `presence`, `pulse` | `AGameStateBase` for replicated run state + a **Material Parameter Collection** `MPC_Fear` for every `fx_*` value the post shader reads |
| Player layers `player_state.gd` → `player_body.gd` → `player.gd` | `ABRCharacter : ACharacter` + components: `UBRVitalsComponent`, `UBRTorchComponent`, `UBRCameraFeelComponent`, `UBRPeekComponent`, `UBRInteractComponent` |
| `CharacterBody3D` + hand-rolled accel / coyote / jump buffer | `UCharacterMovementComponent` (subclass for coyote time, jump buffer, custom accel) |
| `InputMap` + `keybinds.gd` (AZERTY/QWERTY, physical keys) | **Enhanced Input** (Input Actions + Mapping Contexts, *Player Mappable Keys* for rebinding) |
| `AnimationPlayer` / `AnimationTree` + code-posed bones | **Animation Blueprint**, Blend Spaces, **Control Rig**, IK Rig / Full Body IK, Animation Warping (stride/orientation), optionally **Motion Matching** (Pose Search) |
| `SkeletonModifier3D` (`wall_hand.gd`) | Control Rig node in the arms AnimBP (two-bone IK + finger pose blending) |
| MultiMesh (`mm_buffer.gd`, fixtures, walls, mannequin crowd) | `UInstancedStaticMeshComponent` / `UHierarchicalInstancedStaticMeshComponent`, Nanite meshes |
| Runtime `ArrayMesh`/`SurfaceTool` geometry (walls, trim, pipes) | **Geometry Script** / `UDynamicMeshComponent` (runtime) or bake to Static Mesh at import |
| Light pool (`level_light_pool.gd`) + CPU GI (`grid_gi.gd`) | **Lumen** GI + reflections, **MegaLights** for many shadowed tube lights; the pool is no longer needed |
| Depth/horizon fog (volumetric fog was removed for AMD crashes) | Exponential Height Fog + **Volumetric Fog** back on |
| Post shader `shaders/render/camera.gdshader` | Post Process Material(s) on a global Post Process Volume, driven by `MPC_Fear` |
| `grid_nav.gd` BFS flow fields + grid LOS | **NavMesh (Recast)** for paths; keep a grid LOS helper for cheap sight checks; **EQS** for "where to go next" |
| Entity senses | **AI Perception** (Sight, Hearing, custom Torch sense) |
| Entity state machines | **StateTree** per entity (one tree per brain layer) |
| `entity_lod.gd` | **Significance Manager** + Animation Budget Allocator + URO |
| Hide spots (`hide_spot.gd`) | **Smart Objects** |
| Audio buses (`audio.gd`) | **Submixes** + Audio Modulation (Control Buses), submix effects |
| Synth scares (`scare_synth.gd`, `zoom_sounds.gd`) | **MetaSounds** |
| `acoustics.gd` (per-cell reverb) | Audio Gameplay Volumes / reverb by trace, or port per-cell result into Submix Send |
| Wall occlusion lowpass on voices/entity | Sound Attenuation → Occlusion (trace) + lowpass |
| `net.gd` WebSocket + cloudflared + ntfy room code | UE **replication** on a listen server; **EOS** (Epic Online Services) lobbies + P2P relay for room codes and NAT, no tunnel |
| `snap_buffer.gd` interpolation | Built-in `CharacterMovementComponent` network smoothing; custom actors use replicated movement + smoothing |
| `voice.gd` + `adpcm.gd` + `voice_speaker.gd` | EOS Voice or Online Subsystem VOIP with `UVOIPTalker` attenuation (spatialised, occluded) |
| UI Control nodes, CRT SubViewports | **UMG** + **CommonUI**; CRT look via Retainer Box + UI material |
| `save_game.gd` | `USaveGame` + `UGameplayStatics::SaveGameToSlot` |
| `graphics.gd` presets | `UGameUserSettings` + Scalability groups + custom settings |
| Debug console | `UCheatManager` exec functions + CommonUI debug menu |
| Level editor (`level-editor/`, Godot app) | **Keep it.** `.lvl` stays the authoring format; UE gets an importer (Phase 4) |

---

## 3. Feature inventory

Each row: what the feature is, Godot source, UE5 approach. Tuning lives in the Godot file.

### 3.1 Movement & camera (Phase 0, verify)

Source: `scripts/Player/player.gd`, `player_state.gd`, `camera_feel.gd`, `camera_gait.gd`, `handheld.gd`, `peek.gd`, `corner_grab.gd`.

| Value | Godot | Notes |
| --- | --- | --- |
| Walk | 2.6 m/s | `SPEED` |
| Sprint | ×1.75 (~4.5 m/s), 30 s stamina, regen 18/s | `SPRINT_MULT`, `SPRINT_SECONDS`, `STAMINA_REGEN` |
| Crouch | ×0.52, capsule 1.7 → 1.0 m | `CROUCH_MULT` |
| Jump / gravity | 5.0 m/s / 20 m/s² | |
| Accel / decel ground, air | 16 / 22 / 5 | not instant |
| Coyote / jump buffer | 0.10 s / 0.12 s | |
| Max fall | 30 m/s (raised in bottomless pits) | |
| FOV | 75°; sprint/adrenaline +9°, fall +13° | |
| Mouse sens | 0.0022 rad/px | |
| Adrenaline | +50 % speed when chased within 22 m, ≤10 s, 22 s cooldown, crash to 25 stamina | |

Movement reads **physical keys** (WASD = ZQSD on AZERTY). In UE, check Enhanced Input handles AZERTY; otherwise ship
AZERTY/QWERTY presets as `keybinds.gd` does.

Camera feel (port into a `UCameraModifier` subclass, not into the character tick):
- Strafe roll, quick-turn bank, pitch with speed/accel, jump tip, landing dip + spring (`camera_feel.gd`).
- Idle Perlin figure-eight sway after standing still; trauma shake (`add_trauma`) → `UCameraShakeBase` (Perlin pattern).
- Randomised gait carry: per-step variation and drifting carry styles (`camera_gait.gd`), handheld camcorder tremor
  layered on top of aim, never delaying the aim itself (`handheld.gd`).
- Stair stepping: view snaps per tread on flights (`stair_snap`, `step_ease`).
- **Auto corner peek** (`peek.gd`): facing a wall edge close beside you, the view leans past it with no key. Outputs
  `offset`, `amount`, `side`, `edge`, `normal` (fed to the hands, see §3.2).
- **Corner grab** (`corner_grab.gd`): walking along a wall ending at a corner, the near hand takes the edge and pulls
  you round.
- Head bob / camera variation / shake are user settings (0..1).

### 3.2 First-person body (PHASE 1 — current target)

What the Godot game has today (all must exist in UE at the end of Phase 1):

**A. Arms + torch (view model)** — `scripts/Player/torch_model.gd`, `wall_hand.gd`
- Model: `models/player/playerarms.glb` (whole arms, shoulder to fingertips, built ~1.7× life size, scaled 0.6) holding
  `models/flashlight.glb` low-right (`POS (0.2,-0.2,-0.38)`). Built by `tools/build_player_arms.py`.
- Clips on the right arm: `TorchPickup` (raise; played backwards to lower), `TorchHold` (breathing hold),
  `TorchFlinch` (thrown across the face when something is right in front), fidgets `TorchSqueeze` / `TorchFingers` /
  `TorchRegrip` every 6–14 s, `TorchSmack` (knocks a flickering torch, 4–8 s gap), `TorchReload` (two-hand battery
  swap ~7 s: light dies at 1.5 s, back at 5.5 s, new cells in left hand 3.1–4.18 s, `models/aa_batteries.glb`).
- Left hand clips from `models/player/playerarms_idle.glb` (`tools/blender/build_idle_hands.py`), layered after the
  right arm so they only move the left arm: `IDLE_REST` (held low), `IDLE_GROPE` (feels ahead in the dark with the torch
  off), sprint swing, idle one-shots (looks at itself, flexes, rubs fingertips), door poses `DoorKnob` / `DoorLever` /
  `DoorPush`, `WallPalm`.
- Hand modes (`wall_hand.gd`): `ANIM`, `HIDE`, `CARRY`, `WALL` (palm flat on the peeked wall edge, fingers pressing
  flat one by one, real shoulder→elbow reach, lets go past arm length), `SLIDE` (palm on wall in a squeeze gap),
  `DOOR` (hand on handle/leaf as the door swings). Mode changes ease on springs (snappy onto the wall with overshoot).
  Peeking left passes the torch to the left hand first.
- Arms sway with stride, dip when sprinting/crouching.

**B. Visible legs ("look down and see your legs")** — `scripts/Player/player_shadow.gd`
- `models/player/survivor_legs.glb`: same hazmat rig cut below the shoulders, torso folded away by scaling the
  `Waist` bone to zero (`LEGS_PINCH_BONE`).
- Hips kept `LEGS_WAIST_BEHIND = 0.38 m` behind the eye along the look, sliding up to `LEGS_PUSH_MAX = 0.8 m` to
  counter root motion in the clips.
- Turn in place: feet step round after the view swings `LEGS_TURN_START = 20°` (the shadow body waits for 70°).
- Crouched: knees kept clear behind the hands (`LEGS_KNEE_CLEAR`) when looking down.
- Legs cast no shadow (the full body does).

**C. Own shadow** — `player_shadow.gd`
- Full `models/player/survivor.glb` hazmat rig, invisible to the camera, rendered into shadow maps only, animated by
  the same locomotion as teammates. Kept off the flashlight's light layer (bit 19) so the torch doesn't throw a broken
  self-shadow underfoot; only ceiling tubes shadow it.

**D. Locomotion set (shared by legs, shadow, teammates, Mimic)** — `scripts/Entities/survivor_anim.gd`
- Clips (`tools/blender/build_player_hazmat.py`, `add_survivor_directions.py`, `add_survivor_lobby_idles.py`,
  `add_survivor_neck_snap.py`): `idle_lookaround`, `walk`, `run`, `crouch_idle`, `crouch_walk`, `walk_back`, `run_back`,
  `crouch_walk_back`, `strafe_l/_r`, `run_strafe_l/_r`, `crouch_strafe_l/_r`, `death`, `death_neck_snap`,
  `lobby_idle_*` (shift, hips, hood, slump, glance, crossed, wrist, lookup, straps).
- Cross-fade 0.22 s; playback rate follows real speed (`NATIVE`: walk 1.2, run 4.2, crouch_walk 1.4 m/s at scale 1,
  clamped by `SCALE_RANGE`) so feet don't slide. Moving above 0.1 m/s, sprint above 3.2 m/s.

**E. Scripted door scene** — `player_body.gd` (`_ds_*` fields): through a door the camera, body and left hand play a
scripted open (knob turn / lever / push, which side, latched or not); the leaf gets one collision exception while you
pass. Doors themselves: `scripts/World/props/door.gd`, `outpost_door.gd` (auto sliding).

**F. Tight spaces** — `player_body.gd`: squeeze gap (both hands on a slit, SLIDE mode), crawling.

#### UE5 implementation for Phase 1

1. **Skeleton & import.** Import `survivor.glb`, `survivor_legs.glb`, `playerarms.glb`, `playerarms_idle.glb` (or
   re-export FBX from the Blender scripts). Create an **IK Rig** for the hazmat skeleton and for the arms, and an
   **IK Retargeter** to the UE5 Manny skeleton so marketplace / Game Animation Sample locomotion can be used later.
   Keep the original clips as the reference look.
2. **Character mesh layout** on `ABRCharacter`:
   - `FullBodyMesh` (survivor): `bOwnerNoSee = true`, `bCastHiddenShadow = true` → own shadow (C). Teammates see it.
   - `LegsMesh` (survivor_legs or the full mesh with head/torso hidden via `HideBoneByName`/a Waist scale in the
     AnimBP): `bOnlyOwnerSee = true`, `CastShadow = false`, attached to the capsule and offset so the waist sits
     38 cm behind the eye (B). Use **Copy Pose / Leader Pose** from `FullBodyMesh` so legs and shadow move together.
   - `ArmsMesh` (playerarms) attached to the camera, `bOnlyOwnerSee = true`, using **First Person Rendering**
     (UE 5.6+: `FirstPersonPrimitiveType = FirstPerson`, camera `FirstPersonFieldOfView` / `FirstPersonScale`) so the
     arms never clip into walls. On older 5.x use a separate FOV material trick or a short near-plane offset.
   - Torch mesh on a hand socket; the spotlight on the torch (see Phase 3).
3. **Body AnimBP (`ABP_Survivor`)**, one for the full body; legs copy it:
   - 2D Blend Space (direction × speed) for stand and crouch sets built from §D clips, or Motion Matching later.
   - **Stride Warping + Orientation Warping** (Animation Warping plugin) instead of the speed-scale hack; keep the
     0.22 s blend.
   - **Turn in place**: root yaw offset, step after 20° (legs) / 70° (shadow-only body if separate).
   - Foot IK (two-bone IK + traces) for stairs and slopes.
   - Waist pinch for the owner legs view (Transform (Modify) Bone scale 0 on `Waist`, only on the owner's LegsMesh).
   - Crouch knee clearance: additive pose or IK push back when pitch is low.
4. **Arms AnimBP (`ABP_FPArms`)**:
   - State machine: TorchOff/Lowered ↔ Pickup ↔ Hold (+ fidget montages on a timer) ↔ Flinch, Smack, Reload as
     **Anim Montages** with **Anim Notifies** (`SwapOut` 1.5 s, `CellsIn` 3.1 s, `CellsOut` 4.18 s, `SwapIn` 5.5 s) that the
     torch component listens to.
   - Left arm as a separate layer (Layered Blend per Bone from the clavicle/upperarm) playing idle-hand clips.
   - **Control Rig** for `WALL` / `SLIDE` / `DOOR` modes: two-bone IK to a target transform (wall edge point + normal
     from the peek component, door handle socket), finger curl blending to `WallPalm` / door poses, reach limit
     from the arm length, spring-damped alpha per mode (snappy with overshoot onto walls).
   - Procedural sway: arms lag look and bob with stride (spring in the AnimBP or a lag on the camera-attached arm
     root).
5. **Camera**: keep the camera on the capsule (not on the head bone) — the Godot game separates aim from body. The
   camera modifier (§3.1) drives bob / feel; the legs follow the body animation.
6. **Door scene**: a Montage per door way (knob/lever/push × side) + a short camera blend; the door actor exposes a
   handle socket.

**Phase 1 acceptance:**
- Looking straight down standing, walking, running, strafing, backpedalling and crouching: legs visible, no torso
  or chest clipping, feet don't slide, no hips seen in front of the camera.
- Shadow of a full humanoid on the floor under ceiling lights, matching the stride; no self-shadow from the torch.
- Torch raise/lower on F, hold breathing, fidgets, flinch, smack, battery swap with notifies.
- Left hand rest / grope-in-the-dark / idle one-shots.
- Peek at a wall edge: hand goes flat on the edge with real reach, lets go when stretched.
- Arms never clip into walls.
- Other players (once Phase 9 exists) see the full body using the same AnimBP.

### 3.3 Player systems (Phase 2)

| Feature | Godot | UE5 |
| --- | --- | --- |
| Health / sanity / insanity: sanity drains in dark & Drain zones (4.5/s), lit rooms give back 2.2/s; insanity below 60 (blur, double vision, Eyes), health drains below 30, recovers above 60; `unnerved` blocks calming | `player_body.gd`, `player_state.gd` | `UBRVitalsComponent`, replicated, values → `MPC_Fear` |
| Stamina, exhaustion, rest | `player.gd` | same component |
| Adrenaline burst | `player_state.gd` ADR_* | same component, FOV via camera modifier |
| Heart: one pulse fed by every threat (`Game.heart.feed(name, level)`) | `scripts/Player/heart.gd` | `UBRHeartComponent` with a TMap of feeders; drives heartbeat MetaSound + `pulse` tunnel vision |
| Breathing: exertion, stamina debt, anxiety, terror → inhale/exhale, gasp, hold breath, sigh; loudness read by entities | `scripts/Audio/breathing.gd` | component + MetaSound picking clips; loudness fed to AI hearing |
| Footsteps: shuffle-bag carpet takes + synthesized heel knock; surface underfoot changes sound and how far monsters hear | `scripts/Player/footsteps.gd` | Anim Notifies on the legs + Physical Materials per surface + `ReportNoiseEvent` for AI hearing |
| Blink: lids sweep shut/hold/open, `closed` signal swaps out things that must not survive a blink | `scripts/Player/blink.gd` | post-process param + delegate `OnEyesClosed` |
| Fall FX: FOV, streaks, lens warp, buffet scaled from 9 → 50 m/s | `player_state.gd` FALL_* | camera modifier + MPC |
| Hiding (`hidden`, `hiding_in`) | `player_state.gd`, `props/hide_spot.gd` | Smart Object interaction |

### 3.4 Tools in hand (Phase 3)

| Tool | Key | Godot | UE5 notes |
| --- | --- | --- | --- |
| Torch: on/off, battery 75 s (low 25 %, crit 10 %), flicker, slow drain during power cut, dead click, battery swap (R) | F / R | `player_body.gd`, `torch_model.gd`, `props/battery_pickup.gd` | SpotLight with IES + light function for the hotspot/spill (energies 6.5 / 2.0), Lumen-lit; Montage notifies from Phase 1 |
| Camera flash: 2 per run, blinds Bacteria if close and centred, a miss is loud | G / RMB | `Player/flash_tool.gd`, `props/flash_pickup.gd` | short high-intensity point light + bloom spike + AI stimulus |
| T.S.R.A. field scanner: hold on an entity in a view cone, in range, line of sight for SCAN_TIME → Archive discovery + XP; tiers unlock range-finder (C-3), deep scan (C-4) | Q | `Player/scanner.gd`, `scanner_model.gd`, `UI/hud/scan_readout.gd`, `shaders/scan_grade.gdshader` | cone trace + `UBRArchiveSubsystem`; scan grade as post material |
| Camcorder zoom up to 4×: autofocus hunts, aim slows, shake grows; locks other tools; sprint/fall lowers it | X + wheel | `Player/zoom_tool.gd`, `zoom_sounds.gd`, `UI/hud/zoom_readout.gd`, `shaders/cam_zoom.gdshader` | camera FOV + DOF (autofocus with Cine Camera focus settings), MetaSound servo |
| Reflective hazard tape: hold to pull a strip along a surface, release to stick, hold on strip to peel; Q shows who/when; saved per level; shared in co-op | T | `Player/tape_tool.gd`, `props/tape_marks.gd`, `tape_roll.gd`, `tape_pickup.gd`, `mark_store.gd`, `UI/hud/tape_readout.gd`, `shaders/reflective_tape.gdshader` | Spline mesh or decals; retroreflective material; replicated array |
| Freehand marker / eraser / stamps | B, N, H | `Player/sketch_tool.gd`, `props/sketch_marks.gd`, `scary_stamps.gd`, `shaders/sketch_marker.gdshader` | Runtime virtual texture or decal strokes |
| Dev tools: cable tool, portal tool, draw panel (Y) | U, Y | `cable_tool.gd`, `portal_tool.gd`, `UI/hud/draw_ui.gd`, `props/cable_marks.gd`, `portal_marks.gd` | dev-only, low priority |
| Interact + world tooltips "[E] OPEN" | E | `props/interact_tooltip.gd`, `pickup_prompt.gd` | `UBRInteractComponent` + interface `IBRInteractable` + widget component |
| Inventory (stacks, hotbar, battery/flash/tape counts) | Tab | `UI/inventory/inventory.gd`, `UI/hud/item_strip.gd`, `item_icon.gd` | inventory component; icons via scene capture once |

### 3.5 Level pipeline (Phase 4)

Data: `levels/levels.json` (playlist), `levels/*.lvl` (JSON: per floor ASCII grid rows = z, chars = x: `#` wall,
`.` floor, `O` pit, zones, objects, `walls` graph, stairs, triggers, `abyss_secs`), `levels/object_types.json`
(object types + per-object fields), `levels/marks/<id>.json` (tape/sketch). Maps up to 256×256 cells, any number of
floors 9 m apart. Authored in `level-editor/` (keep using it).

Godot layers (`scripts/World/level/`): `level_data.gd` (grid) → `level_geometry.gd` + `level_geometry_surfaces.gd`
(walls, floors, ceilings, pits, grime) → `level_trim.gd` (skirting, wear) → `level_fixtures.gd` (troffers, burnt-out
and flickering tubes) → `level_light_pool.gd` + `level_lighting.gd` + `grid_gi.gd` → `level_builder.gd` (runs it).

Walls graph (`scripts/World/level/walls/`): `wall_geom.gd` (straight + arc), `wall_graph.gd` (nodes/walls/openings),
`wall_joints.gd` (mitred T/X joints, watertight), `wall_mesh.gd`, `wall_openings.gd` (doors, doorways, arches, windows,
outpost glazing), `wall_snap.gd` (editor only). Tests: `tools/test_walls.gd`.

| Feature | UE5 |
| --- | --- |
| `.lvl` → world | C++ `UBRLevelImporter`. Two modes: **editor import** (Editor Utility / commandlet builds Static Meshes + ISMs into a `.umap` per floor, Nanite on, lighting authored) — recommended for looks; **runtime build** (Geometry Script dynamic meshes) only if levels must stay data-driven at runtime. Port `wall_joints.gd` math 1:1 in C++ and re-run its watertight tests |
| Grid walls, carpet, tile, ceiling with height drops | ISM / Nanite modules per cell type; PCG framework can place modules from the grid |
| Trim (skirting cove, wear), grime | Spline meshes along wall plans + decals / RVT blend |
| Troffers: some dead, some flickering (long stable stretches then bursts) | ISM fixtures + rect lights with **MegaLights**; flicker by Light Function or a small C++ flicker manager |
| Zones: tall/low ceiling, tiles, bright/dark/dim/flicker/grime/classic/liminal, Safe, Drain, Loot, Open ceiling, Echo, Loop (endless corridor), Noclip, Abyss, Endless ceiling | per-cell zone grid stored on a `ABRLevel` actor; volumes generated for gameplay zones |
| Floors stacked 9 m, look-only shells of other floors, swap mid-stairwell landing | **Level streaming** (one sub-level per floor, or Level Instances); stream adjacent floors as low-detail; swap on the landing (`props/stairs.gd`) |
| Pits through slabs, falling to the floor below | holes in the slab mesh + trigger |
| Bottomless pit (Abyss): endless shaft, speed streaks, floating-origin wrap, death after `abyss_secs` | `pit_fall.gd`, `shaders/pit_shaft.gdshader`, `shaft_lamps.gd`: repeating shaft module + teleport-wrap; UE5 Large World Coordinates removes the precision concern |
| Endless ceiling | `endless_shaft.gd`: same repeating shaft upward |
| Noclip slip / noclip death / wake in new level | `noclip_slip.gd`, `noclip_death.gd`, `noclip_wake.gd` |
| Loop corridor | trigger-based seamless teleport (unseen) |
| Props: doors, outpost sliding doors, glazing (bulletproof glass), windows (sky/night shaders), stairs, platforms, spiral stairs, pipes network, pools, water + underwater view, lamps, industrial props (runtime PBR from loose textures), pillars/columns, hide spots, terminal machine (PVM CRT running `UI/terminal_os.gd`), exit fire door, event triggers, survey clipboard, TSRA hub launch bay / portal gate / emergency panel | `scripts/World/props/*` → Blueprint actors; water via Single Layer Water material; terminal screen via UMG widget on a mesh + CRT material |
| Dust motes in light cones | `dust_motes.gd` → Niagara |
| Acoustics per cell (ray-measured room size) | `acoustics.gd` → precompute at import into reverb volumes |
| Hills outdoor level (procedural terrain, road, sky, houses, castle; F2 portal) | `scripts/World/hills/*` → UE Landscape + Sky Atmosphere + Volumetric Clouds (separate map) |
| Grid navigation | `grid_nav.gd` → NavMesh; Safe zones as Nav Modifier (null area) + push-out |

### 3.6 Render look (Phase 5)

| Feature | Godot | UE5 |
| --- | --- | --- |
| Simulated camera: barrel fish-eye lens, motion blur, sensor noise, VHS damage on scares, bodycam vs camcorder | `scripts/Render/render_engine.gd`, `shaders/render/camera.gdshader` | Post Process Materials (lens distortion, chromatic aberration, grain, VHS tracking), native motion blur, **Lens Distortion** plugin optional |
| Atmospheres (Dim, Liminal, Classic, Pool...) blended as you walk | `scripts/Render/atmospheres.gd`, `level_lighting.gd` | Post Process Volumes with blend radius per zone + fog settings |
| Fear FX channels: blur, contrast, sat, hue, zoom, skew, fade, flash, shock, blood, static, warp, corrupt, classic, tubes (fluorescent banding), blink | `game_state.gd` `fx_*` | `MPC_Fear` scalars read by the post materials |
| Graphics presets (auto-picked from GPU), SSAO, shadows, TAA, glow, FSR scale | `GameLogicEngine/graphics.gd` | Scalability + `UGameUserSettings`, TSR instead of FSR |
| Carpet POM, acoustic/drop/panel ceilings, aged skirting, mannequin wear | `shaders/*.gdshader` | Material graph (POM node / Nanite displacement), material instances |
| Mouse cursor through bent lens | `UI/hud/lens_pointer.gd` | invert lens distortion for UI picking (dev tools only) |

### 3.7 Entities (Phase 6)

All entities: host-authoritative brain, puppets on clients (`*_net.gd`), placed by editor "entity" marks
(`Entities/entity_marks.gd`, kind + behaviour roam/lurk), LOD tiered (`entity_lod.gd`: FULL / SLOW / ...).
Lore: `levels/tsra_entities.json`.

| Entity | Behaviour (port exactly) | Godot | UE5 |
| --- | --- | --- | --- |
| **The Bacteria (Howler)** | roam → investigate (noise/glimpse) → screech on first sighting → chase → search; stalks corners and leans out (pulls back when looked at), flees, lurks; stunned/blinded by flash; sight cone + grid LOS, range grows with torch & lit rooms, shrinks crouched, near-zero still in dark; hears footsteps (further on hard floors); grab: hauls you up and eats you while you watch | `Entities/bacteria/*` (base, nav, senses, stalk, rig, skeleton, grab, net), `models/entities/howler.glb`, `Audio/scares/creature_voice.gd` | StateTree (Roam/Investigate/Screech/Chase/Search/Stalk/Flee/Lurk), AI Perception (Sight + Hearing + custom Torch-light sense), EQS for stalk corners; procedural gait → Control Rig with leg IK & planted feet, ceiling squeeze; grab as Level Sequence with camera |
| **The Mannequin** | room of still decoys + one real one; moves only unseen (Weeping Angel), stop-motion steps; hunts 30 s, rests, every 3rd rest freezes 5 min; decoys shift only when unseen; neck-snap kill | `Entities/mannequin/*`, `levels/mannequin_poses.json`, `creepy_mannequin.glb` + variants | per-player visibility test (frustum + occlusion via `WasRecentlyRendered` is NOT enough — do explicit view-cone + trace per player, every player); poses as Pose Assets; crowd as ISM per part; kill as Sequence |
| **The Mimic** | walks a survivor's recorded route from minutes ago (feet, facing, look, crouch, torch), wears their colour/name tag, replays their voice clips and their own sounds (torch click, tape tear, footsteps) from round a corner; only the scanner identifies it | `Entities/mimic/*` (mimic, mimic_echo, mimic_sounds) | ring buffer of player snapshots on the server; uses `ABP_Survivor` |
| **The Eyes** | at very low sanity one pair opens far down a visible corridor, pupils follow, looks away if looked at, removed only by a blink | `Entities/eyes/eyes.gd`, `shaders/eye.gdshader` | bound to `OnEyesClosed` |
| **The Grabber** | 2.3 m, hunched upside down on dark ceilings, grabs ankle, drags victim (escape QTE) | `Entities/grabber/*`, `grabber.glb` | StateTree + drag Sequence on victim's machine |
| **The Burnt** | 2× height, kills every tube near it while present, moves only unseen, head twitches when watched; take: hug, lift, stare, corrupt; firmware-error death tape | `Entities/burnt/*` | light manager hook; `fx_corrupt` |
| **The Tall One** | 4.45 m, roams, spots from far (head snaps, recoils), flees, screams, hunts, leaps; can't see hidden players; lens blood on kill | `Entities/tall/*`, `UI/death/lens_blood.gd` | StateTree + Smart Object awareness of hide spots |
| Model-only roster: Killer, SkinStealer, extras | `Entities/model_entity.gd`, `entity_roster.gd`, `entity_mount.gd` (wall/ceiling mounts) | simple actors spawned from debug |

### 3.8 Event director & audio (Phase 7)

Director (`scripts/Events/events*.gd`): tension builds while quiet (faster standing still, in the dark, low sanity),
then a weighted pick among events off cooldown that pass `when()`/`score()`. Port as `UBREventDirectorSubsystem`
(server only) with one `UBREvent` subclass/DataAsset per event. Events (weight, cooldown s):

powerCut (1.5, 1440), preacherWhisper (2.0, 360), wallKnock (1.6, 240), breathBehind (1.0, 420), redAlert (1.8, 420),
emergencyPulse (1.4, 360), lightsOut (1.5, 300), oneLamp (1.4, 400), deadAir (1.3, 420), machineVoice (1.4, 240),
ghostRoster (0.9, 600), humRises (1.1, 420), partyWall (1.0, 600), phoneRing (1.1, 540), houndPacing (1.1, 480),
stalkerTell (0.9, 600, not random), wallFootsteps (1.2, 360), run (0.8, 720), itHeardYou (1.1, 480),
sayYourName (0.8, 900), answerBack (1.0, 420), yourOwnVoice (1.0, 600), doorbell (1.0, 480), lookTogether (0.8, 900),
soundsToAvoid (1.0, 600), countdown (0.7, 900). Placed **event triggers** (`props/event_trigger.gd`) run events or
captions/tube death/silence/thump/drone on entry.

Audio (`scripts/Audio/*`): bus layout World (trim, lowpass, follow-room reverb), Steps, Body, Entity, Preacher...
→ Submix graph. Ambience director picks beds by tension (`ambience.gd`). Scares synthesised (`scare_synth.gd`) →
MetaSounds. Clip loudness normalisation table `audio/clip_levels.json` (`clip_levels.gd`) → apply as per-asset volume
at import. SFX preload pool (`sfx_pool.gd`) → not needed (UE streaming/caching). Machine voice lines
(`machine_voice_lines.gd`) → SoundWaves + subtitles typed on screen. Outdoor bed (`outdoor_audio.gd`). Spatial tube hum
per light.

### 3.9 UI (Phase 8)

All in UMG/CommonUI with a shared CRT material (phosphor bloom `UI/crt/crt_bloom.gd`, flicker `crt_flicker.gd`, VHS
overlay `shaders/ui_vhs_overlay.gdshader`):
- Camcorder HUD: REC dot, timer, viewfinder brackets, crosshair dot, amber CRT vitals (`UI/hud/vitals_panel.gd`),
  hotbar (`item_strip.gd`), toasts (`terminal_toast.gd`), XP popup (`xp_popup.gd`), scan/tape/zoom readouts.
- TAB terminal (`UI/inventory/*`): pages ITEMS, SITE (dossier), ARCHIVE (entries), FILES (lore), RECORD (clearance),
  CREW (co-op roster with signal strength).
- Menus: boot sequence (warnings, credits, logo), title with drifting stills, settings/graphics/voice/controls panels,
  lobby screen with live 3D corridor + survivors (`lobby_corridor.gd` → a separate map or render target), mission
  briefing typed out (`levels/tsra_briefings.json`), async loading screen.
- Death: death camera, blood (droplets, metaball decals, sprays) and fallen body (`UI/death/*`) → Niagara + decals +
  ragdoll/physics asset; death overlay (SIGNAL LOST / YOU DIED / killer); respawn blur-to-black fade.
- Debug console (F1/~/F3, `UI/debug/*`): spawn/despawn entities, god mode, noclip, fullbright, infinite stats, freeze
  AI, speed/jump mult, archive/clearance commands, animation test walker → `UCheatManager` + debug widget.

### 3.10 Co-op & voice (Phase 9)

`scripts/Net/net.gd` (PROTOCOL 11): up to 8 players, host runs monsters + events, guests follow host's level;
version-mismatch refusal; room codes; entity snapshots 20 Hz; RPCs for tape, triggers, kills, mannequin seeds/views,
grabber/burnt/tall take + result. `remote_player.gd`: teammates in hazmat suit with colour, name tag.
→ UE listen server, `ABRPlayerState` (callsign, colour, alive/menu/flatlined), replicated entity actors, EOS lobbies
for codes. Voice → EOS voice / VOIP talker with attenuation and wall occlusion lowpass (as `voice_speaker.gd`).
Spectate/invisible flag for debug. CLI flags `--host`, `--join=`, `--player-name=`, `--port=` → UE command line parsing.

### 3.11 Meta & infrastructure (Phase 10)

- Archive (entity discovery, dossiers) `GameLogicEngine/tsra_archive.gd`, `levels/tsra_dossiers.json`,
  `levels/tsra_entities.json` → DataTables/DataAssets + subsystem.
- Clearance XP / Research Yield tiers `tsra_clearance.gd`, `levels/tsra_clearance.json`.
- Save tapes (slots: level, floor, position) `save_game.gd` → `USaveGame`.
- Settings (sens, FOV, head bob, volumes, callsign) `UI/menu/menu_widgets.gd` → `UGameUserSettings`.
- Crash flag + reports `crash_guard.gd`, `stability.gd` → UE CrashReporter; keep the "last run died → safe preset" logic.
- Perf overlay F12 `perf.gd` → `stat unit`, `stat gpu`, Unreal Insights.
- Load manifest prefetch `load_manifest.gd` → not needed (Asset Manager / async loading).
- TSRA hub level (`levels/tsra_hub.lvl`, `TSRA_HUB.md`).
- Launcher + publish scripts (`launcher/`, `tools/publish.ps1`) → later; UE packaging replaces Godot export.

---

## 4. Suggested UE5 project layout

```
Source/Backrooms/
  Player/      BRCharacter, BRCharacterMovement, BRCameraModifier, BRVitalsComponent, BRHeartComponent,
               BRTorchComponent, BRPeekComponent, BRInteractComponent
  Anim/        BRSurvivorAnimInstance, BRArmsAnimInstance (C++ bases for the AnimBPs)
  Level/       BRLevelImporter, BRWallGraph, BRWallJoints, BRWallMesh, BRLevelActor
  AI/          BRBacteria, BRMannequin, ... (+ StateTree tasks/conditions)
  Events/      BREventDirectorSubsystem, BREvent
  Meta/        BRArchiveSubsystem, BRClearanceSubsystem, BRSaveGame
  Net/         BRGameMode, BRGameState, BRPlayerState
Content/
  Characters/Survivor, Characters/FPArms, Entities/*, Levels/*, Materials/PostProcess, Audio/MetaSounds, UI/
```

## 5. Open decisions for the user (ask before the relevant phase)

1. Levels: editor-time import to `.umap` (best visuals, Lumen/Nanite authored) vs runtime build from `.lvl`.
2. Locomotion: keep the hazmat clips + Animation Warping, or adopt Motion Matching with the Game Animation Sample.
3. Online backend: EOS (free, cross-store) vs Steam.
4. UE version (5.6+ recommended for First Person Rendering and MegaLights).
