# Backrooms Launcher

Godot app that installs and updates the game from GitHub Releases, then launches it.

## Ship an update
1. `.\tools\publish.ps1 v0.2.0 "notes"` (exports the game, zips it as `backrooms-windows.zip`, creates the release).
2. Players open the launcher; it sees the new tag, shows **Update**, downloads and installs it.

## Build the launcher itself (once)
Open `launcher/` in Godot, add a Windows export preset, export to `launcher.exe`, and give players that file.
It creates a `game/` folder beside itself. Testing in the editor installs into `launcher/_dev_install/`.

## Notes
- The repo must be **public** (or the launcher needs a token) for the unauthenticated releases API to work.
- Tags are compared as plain strings: any different tag counts as an update.
- Multiplayer: the launcher passes `--player-name=` and `--join=host:port` to the game (read by `scripts/Net/net.gd`).
