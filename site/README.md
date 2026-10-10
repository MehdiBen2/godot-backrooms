# Download page

Static page for the Backrooms launcher, hosted on Netlify (free). It lives in this repo, so no separate repository is needed.

## Where the downloads come from
- **Launcher:** a GitHub release tagged `launcher`, with the file `Backrooms-Launcher.exe`. The button links straight to it, and the page reads its size from the GitHub API.
- **Game:** the zip on the latest game release (`backrooms-windows.zip`, uploaded by `tools/publish.ps1`). The page links to GitHub's "latest" URL, so it always points at the newest game.

Nothing binary is stored in git or on Netlify.

## Publishing the site
Netlify reads `netlify.toml` at the repo root (`publish = "site"`, no build). Once Netlify is linked to this repo, every push to `main` redeploys the page.

One-time setup: **Add new project > Import an existing project > GitHub**, pick `MehdiBen2/godot-backrooms`, leave the build settings empty, deploy.

## Publishing a new launcher
```powershell
.\tools\publish_launcher.ps1
```
This exports `launcher/` with Godot and uploads it to the `launcher` release. It replaces the file in place, so the download link never changes. Needs the GitHub CLI signed in (`gh auth login`) and Godot 4 (`$env:GODOT`, on PATH, or on the Desktop).

## Files
- `index.html`: the page. Styling copies the launcher's palette, VCR font and background (`launcher/launcher.gd`).
- `assets/`: font, icon and background copied from `launcher/`.
