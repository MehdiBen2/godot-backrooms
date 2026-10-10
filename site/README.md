# Download page

Static page for the Backrooms launcher. Hosted on Netlify (free). It lives in this repo, so no separate repository is needed.

## How Netlify finds it
The repo root has `netlify.toml`, which sets `publish = "site"` and no build command. When Netlify is linked to this repo, it deploys the `site/` folder on every push to `main`.

## One-time setup
1. In Netlify: **Add new project > Import an existing project > GitHub**, then pick `MehdiBen2/godot-backrooms`.
2. Leave build settings empty. Netlify reads them from `netlify.toml`.
3. Deploy. The site URL appears in the project page.

## Putting the launcher on the site
`site/launcher.exe` is gitignored (it is too large for git), so a Git deploy does not include it. Two options:

- **Netlify CLI (once per launcher build):**
  ```sh
  npx netlify-cli deploy --prod --dir site
  ```
  Log in with `npx netlify-cli login` first. This uploads the whole `site/` folder, exe included.
- **Drag and drop:** drag the `site/` folder onto the project's Deploys page. Same result, no CLI.

Until the exe is uploaded, the download button shows "Not available yet".

## Files
- `index.html`: the page. Styling copies the launcher's palette, VCR font and background (`launcher/launcher.gd`).
- `assets/`: font, icon and background copied from `launcher/`.
