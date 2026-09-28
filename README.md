# Backrooms

A first-person co-op horror game set in the Backrooms, built with **Godot 4.7** (Forward+, Jolt Physics).
Walk the yellow halls with a failing torch, listen for what's walking with you, and don't look away from
the things that only move when nobody is watching.

## Repository layout

| Path | What it is |
| --- | --- |
| `godot-backrooms/` | **The game** (Godot project). Open this folder in Godot. |
| `launcher/` | Small Godot app that installs/updates the game from GitHub Releases and starts it. See [launcher/README.md](launcher/README.md). |
| `level-editor/` | Standalone Godot app that edits `godot-backrooms/levels/*.lvl` and `levels.json` in place. |
| `tools/` | PowerShell scripts: `pack.ps1` (export + zip), `publish.ps1` / `publish_gui.ps1` (export + GitHub Release). |
| `Publish.bat` | Double-click to open the one-click publisher window. |

Inside the game project:

| Path | What it is |
| --- | --- |
| `scripts/GameLogicEngine/` | `Game` and `Gfx` autoloads (game state, level flow, graphics settings), `main.gd` (scene root). |
| `scripts/Player/` | First-person controller, footsteps, breathing/heart, torch, blink. |
| `scripts/Entities/` | Monsters: the Bacteria (layered AI + procedural rig), Mannequin, Mimic, Eyes. |
| `scripts/World/` | Level loading from `.lvl` grids, geometry and lighting builders, grid navigation, the outdoor Hills. |
| `scripts/Audio/` | Ambience, scare director and synthesized scare sounds. |
| `scripts/Events/` | The event director (power cuts, whispers, ...). |
| `scripts/Net/`, `scripts/Voice/` | Co-op over WebSocket and proximity voice chat (ADPCM). |
| `scripts/UI/` | Menus, HUD, inventory, death screen, debug console. |
| `levels/` | Level grids (`*.lvl`), the level list (`levels.json`), object types and baked GI. |
| `tools/` | Editor/headless helper scripts (smoke test, level bake, asset generators). Not exported. |

## Running the game

1. Install [Godot 4.7](https://godotengine.org/download) (standard build, not .NET).
2. Open `godot-backrooms/project.godot` and press **F5**.

Headless smoke test (loads the main scene, fires a few events and summons the entity):

```sh
godot --path godot-backrooms --headless --fixed-fps 60 --script res://tools/smoke.gd
```

## Controls

| Key | Action |
| --- | --- |
| WASD / arrows | Move |
| Shift | Sprint (uses stamina) |
| C / Ctrl | Crouch |
| Space | Jump |
| F | Torch on/off |
| Q (hold) | A.S.R.A. field scanner: hold on an entity near the crosshair to log it |
| Tab | Inventory (A.S.R.A. field terminal) |
| ↑ ↓ / F1–F4 or ← → / PgUp PgDn | In the terminal: select item or entry / switch page / scroll |
| V | Push-to-talk (when voice is set to push-to-talk) |
| Esc | Pause / settings |
| F11 or Alt+Enter | Fullscreen |
| 1 | Debug console (debug builds or `--dev` only) |

## Co-op

Up to 8 players. One PC hosts a WebSocket server on port **8910**.

- **Host:** press HOST in the menu. If [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
  is installed (`winget install Cloudflare.cloudflared`), the game opens a quick tunnel and shows a
  `https://….trycloudflare.com` link to share. Without it, share your IP and forward port 8910.
- **Join:** paste the link (or `ip[:port]`) into JOIN.
- The host runs the monsters and the event director; everyone else follows the host's level.
- Everyone must run the same release. Mismatched builds are refused with a *VERSION MISMATCH* message.
  If you change any RPC in `scripts/Net/net.gd`, bump `PROTOCOL` there.

Command-line options (also passed by the launcher):

```
--host / --host-local     open a lobby immediately (-local: no tunnel)
--join=<address>          join a lobby on start
--player-name=<name>      callsign shown above your head
--port=<n>                use another port (two copies on one PC)
--net-debug               log what the entity is doing on this machine
--dev                     enable dev keys in a release build
```

## Levels

Levels are ASCII grids in `godot-backrooms/levels/*.lvl`, listed in `levels.json`. Edit them with the level
editor: open `level-editor/` in Godot and run it (set `BACKROOMS_GAME_DIR` if the game folder isn't the
sibling `godot-backrooms/`). After changing a level, re-bake its lighting with `tools/bake_level.gd`.

Each level's page in the TAB terminal ([F2] THRESHOLD DOSSIER: zone, threat, metrics, mandates, and which
entities appear there) comes from `levels/asra_dossiers.json`, keyed by the level's `id` in `levels.json`;
the fields are described in that file's `_about`. Entity entries live in `levels/asra_entities.json` and
unlock once the player scans the entity with the field scanner; they are read on the terminal's [F3] ENTRIES page
(debug console: `archive list` / `archive reset`).

## Releasing

Needs Godot 4.7 with Windows export templates (`$env:GODOT`, `godot` on PATH, or a `Godot_v4*.exe` on the
Desktop) and, for publishing, the GitHub CLI signed in (`gh auth login`).

```powershell
.\tools\pack.ps1                                   # build\backrooms-windows.zip, to send to a friend
.\tools\publish.ps1 v0.3.0 -Notes "What changed"   # export + GitHub Release; the launcher picks it up
```

Or double-click `Publish.bat`.

## Assets

Only processed, in-game assets live in this repo. Raw source packs (sound libraries, source `.glb`/`.zip`)
go in `assetsimported/`, which is git-ignored. Keep those on a drive or attach them to a release.
Third-party sound credits are in `godot-backrooms/audio/footsteps/CREDITS.txt`.

The `addons/godot_ai` and `addons/godot_mcp` plugins are editor tooling for AI assistants. They are
stripped from or disabled in exported builds.
