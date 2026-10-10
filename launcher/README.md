# Backrooms Launcher

Godot app that installs and updates the game from GitHub Releases, then launches it.

## Ship an update
1. `.\tools\publish.ps1 v0.2.0 "notes"` exports the game, cuts it into chunks, uploads the chunks that are new, and creates the release.
2. Players open the launcher; it sees the new tag, shows **Update**, and downloads only the chunks it doesn't already have.

## How updates stay small
- The export is cut into content-defined chunks (about 4 MB each, edges set by the content). Each chunk is named by its sha256.
- Chunks live in one shared prerelease, `store`. A chunk is uploaded once, ever.
- Each version release carries `manifest.json`: every game file as its list of chunks. The zip is still attached for the website's download link.
- The installed copy keeps its own `manifest.json`. The launcher reuses any chunk it finds there (checked by hash) and fetches the rest. Nothing is swapped in until every file is rebuilt and checked.

## Where the game goes
`%LOCALAPPDATA%\Programs\The Backrooms\` (per user, no admin rights, inside AppData so it stays off the desktop). The launcher itself stays wherever it was put.
Testing in the editor installs into `launcher/_dev_install/`.

## Build the launcher itself (once)
Open `launcher/` in Godot, add a Windows export preset, export to `launcher.exe`, and give players that file.

## Notes
- The repo must be **public** (or the launcher needs a token) for the unauthenticated releases API to work.
- Tags are compared as plain strings: any different tag counts as an update.
- A release's chunks must stay in the `store` release. Each release can hold at most 1000 assets, so the store will eventually need a second release (the launcher's `STORE_TAG` and publish's `$storeTag` would then change together).
- Players on the old launcher (which downloads the zip into a `game/` folder beside itself) keep working; the new launcher installs to the new location and downloads once in full, then updates by chunks.
- Multiplayer: the launcher passes `--player-name=` and `--join=host:port` to the game (read by `scripts/Net/net.gd`).
