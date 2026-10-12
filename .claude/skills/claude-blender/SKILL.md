---
name: claude-blender
description: 3D modeling, rigging and animation in Blender via the Blender MCP (blender-skills pack by arjun988). Use ONLY when the user's message contains the trigger phrase "claude blender" or "/claude-blender" anywhere, even mid-sentence. Never use it otherwise, even for 3D, model, rigging or animation requests. Builds, textures, rigs, animates and exports GLB assets for godot-backrooms/models/.
argument-hint: "<what to make, e.g. 'a water-stained ceiling tile kit' or 'rig the mannequin'>"
---

# Role

You are a technical art director driving Blender through the `blender` MCP server. Task: whatever the
user asked for in their message (the text around the "claude blender" trigger, or $ARGUMENTS).

You can't see the viewport directly. Build in small steps, take a viewport screenshot or render after
each phase, look at it, and fix what is wrong before going on. The user does the final eye check.

Upstream: https://github.com/arjun988/blender-skills (MIT, v1.3.0), installed at commit 8f778d2.
Its 94 specialist skills live in [pack/](pack/) as `pack/<name>/GUIDE.md` (renamed from SKILL.md so
they don't load as separate skills). Shared references are in [pack/references/](pack/references/).
Decision trees: [pack/SKILLS_GUIDE.md](pack/SKILLS_GUIDE.md).

# Setup (already done on this machine)

- Blender 5.2 LTS: `C:\Program Files\Blender Foundation\Blender 5.2\blender.exe`.
- Addon "MCP for Blender" (`blender_mcp.py`) is installed and enabled in Blender's user prefs. It
  auto-starts its socket server on port 9876 when Blender opens. Telemetry is off (default).
- MCP server `blender` is in the project `.mcp.json` (`uvx mcp-for-blender`).
- **Blender must be open** for the MCP tools to work. If a call fails to connect, launch it:
  `"/c/Program Files/Blender Foundation/Blender 5.2/blender.exe" &` (Bash, background) and retry.
  If the server still isn't up: in the viewport press N → "MCP for Blender" tab → Start MCP Server.
- If uv fails with `invalid peer certificate`, set `UV_SYSTEM_CERTS=1`.
- Headless batch work (export, re-import checks) can also run without the MCP:
  `blender.exe -b file.blend --python script.py`.

# Workflow

1. **Read [pack/blender-director/GUIDE.md](pack/blender-director/GUIDE.md) first.** It routes the
   request to specialist guides (see its `references/skill-routing.md`). When it says "activate
   skill X", read `pack/X/GUIDE.md`.
2. **Look at what exists** before making anything new. Game models live in `godot-backrooms/models/`
   (`ceiling/`, `entities/`, `lights/`, `player/`, `props/`). Find who loads the model (grep its file
   name in `godot-backrooms/scripts` and `godot-backrooms/scenes`) and match its scale, origin and
   node names so the scripts keep working.
3. **Style**: for this game, start from [pack/liminal-space-style/GUIDE.md](pack/liminal-space-style/GUIDE.md)
   and [pack/indie-horror-aesthetics/GUIDE.md](pack/indie-horror-aesthetics/GUIDE.md). Add
   `psx-horror-style`, `analog-found-footage-horror` or `mascot-puppet-horror` only if the user asks
   for that look.
4. **Build via MCP**, following [pack/references/asset-pipeline.md](pack/references/asset-pipeline.md)
   and [pack/references/mcp-tools.md](pack/references/mcp-tools.md). Read the tool schemas before
   calling. Save the `.blend` before running code. Screenshot after every phase.
5. **Rig / animate** with `pack/rigging/GUIDE.md` and `pack/animation/GUIDE.md` for clips baked into
   the GLB (walk, idle, attack). In-engine procedural motion (head bob, view-model sway, camera
   feel) is the `claude-animate` skill's job, not this one. Tell the user to say "claude animate"
   for that.
6. **Validate** with [pack/references/validation-checklist.md](pack/references/validation-checklist.md)
   and the budgets in [pack/references/polycount-budgets.md](pack/references/polycount-budgets.md).
   For a reference image, also run `visual-match-checklist.md`.
7. **Export** with [pack/godot-export/GUIDE.md](pack/godot-export/GUIDE.md): GLB, +Y up, transforms
   applied. Write into `godot-backrooms/models/<folder>/`. Keep `.blend` source files out of
   `godot-backrooms/` (put them in `assetsimported/`, which is gitignored).
8. **Check in Godot**: open or run the project (godot MCP) and confirm the import works: scale,
   materials, animation names. Report polycount, texture sizes and clip names to the user.

# Rules

- Never overwrite an existing `.glb` without telling the user first. Back it up or export under a
  new name unless they said to replace it.
- AI generation (Hyper3D Rodin, Hunyuan3D, Tripo) and Sketchfab need API keys that are not set up.
  Poly Haven works without a key. Ask before using paid generation.
- Respect asset licenses: note the source and license of any downloaded asset in
  `godot-backrooms/models/CREDITS.txt` (create it if missing).
