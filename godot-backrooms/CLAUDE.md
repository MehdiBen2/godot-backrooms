# Godot Project: The Backrooms Recreation

> **CRITICAL CONTEXT FOR CLAUDE & AI ASSISTANTS**

This is the **Godot Engine recreation** of the Backrooms game.

---

## Project Structure & Paths

- **Current Active Project (Godot):**
  - **Path:** `c:/Users/alhyu/Documents/GitHub/godot-backrooms/godot-backrooms`
  - **Engine:** Godot Engine 4.x (`project.godot`)
  - **Key Directories:** `scenes/`, `scripts/`, `levels/`, `models/`, `textures/`, `audio/`
  - **Purpose:** Primary active development target for all gameplay, scenes, nodes, shaders, and GDScript code.

- **Legacy Reference Project (Three.js / Web):**
  - **Path:** `c:/Users/alhyu/Documents/GitHub/backrooms`
  - **Stack:** JavaScript, Three.js, Node.js (`server.js`)
  - **Purpose:** Reference repository containing the original gameplay logic, entity AI patterns, weapon systems (e.g. `crowbar.js`), level designs, and source assets.

---

## Code Layout (`scripts/`)

One folder per system; a script that grew long is split into files beside it.

- `core/` - `main.gd` (scene root), `game_state.gd` (autoload `Game`: run state, fear channels, kill/respawn), `graphics.gd` (autoload `Gfx`: quality presets).
- `player/` - `player.gd` (controller, flashlight, stamina, adrenaline, sanity) with `footsteps.gd`, `torch_model.gd`, `blink.gd`; `heart.gd` (the shared heartbeat every threat feeds).
- `entities/bacteria/` - THE BACTERIA. Layered scripts, each extending the one before: `bacteria_base.gd` (config, state) -> `bacteria_nav.gd` -> `bacteria_senses.gd` -> `bacteria_stalk.gd` (stalk / flee / lurk) -> `bacteria.gd` (the node's script: brain, movement, voice, kill). Plus `bacteria_rig.gd` (procedural animation), `bacteria_grab.gd` (the kill sequence), `bacteria_net.gd` (co-op).
- `entities/mannequin/` - `mannequin.gd` with `mannequin_model.gd` (posable parts), `mannequin_crowd.gd` (decoys), `mannequin_snap.gd` (the neck snap).
- `entities/mimic/` (`mimic.gd`, `mimic_peek.gd`), `entities/watcher/`, `entities/eyes/`.
- `audio/` - `audio.gd` (builds every game bus, hum, room reverb, wall occlusion), `ambience.gd`, `breathing.gd`, `clip_levels.gd` (loudness matching from `audio/clip_levels.json`); `audio/scares/` - `scares.gd` (one-shots, heart, flatline, gasps) with `scare_synth.gd` (procedural sounds), `creature_voice.gd`, `creature_steps.gd`, `preacher.gd`.
- `world/level/` - layered like the bacteria: `level_data.gd` -> `level_geometry.gd` -> `level_lighting.gd` -> `level_builder.gd`. `world/props/` (battery pickup, exit), `world/grid_nav.gd`.
- `events/` - the event director. `net/`, `voice/` - co-op and proximity voice chat.
- `ui/hud/`, `ui/menu/`, `ui/death/` (death camera, blood, death screen, respawn fade), `ui/debug/` (console).

## Tools & Checks

- `godot --headless --path . --script res://tools/check_scripts.gd` compiles every script.
- `godot --headless --path . --fixed-fps 60 --script res://tools/smoke.gd` plays through the chase, grab, mannequin snap, stalk, lurk, events and presets.
- `python tools/measure_audio.py` re-measures recorded clips into `audio/clip_levels.json` after adding or replacing a recording.
- Dev keys (F1-F12, PageUp/PageDown, the `1` console) only work in the editor, debug builds, or a release started with `--dev`.

---

## Guidelines for Development

1. **Recreation Target**: Implement gameplay, player controllers, camera mechanics, physics, and interactions using standard Godot 4 best practices and GDScript (`.gd`).
2. **Referencing Original Logic**: When porting features from the original web version, inspect `c:/Users/alhyu/Documents/GitHub/backrooms/` for the original logic, parameters, and asset files.
