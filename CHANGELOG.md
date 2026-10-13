# Changelog

Last 20 commits (2026-10-10 to 2026-10-13). Most commits are titled "ed", so entries are inferred from the files each commit changed. Newest first.

## 2026-10-13

**Wall system and level editor**
- Wall rebuild in progress: new openings and trim handling, door and window updates, and a wall-release test shot (a2b2b2c, b7d67d3)
- Level editor gained wall editing, a file-handling update, and a wall-editor test (a2b2b2c, b7d67d3)
- Wall test levels and a test harness added (7bdbc4c)

**Player and animation**
- Idle hands model rebuilt, with a new wall-hand release behaviour and torch model changes (a2b2b2c, b7d67d3, 7bdbc4c)
- Animation walker debug tool, plus footstep and shadow tweaks (1952431)

**Entities**
- Bacteria grab behaviour reworked (a2b2b2c)

**Levels**
- New lobby level file (`level_1_the_lobby.lvl`) and a larger update to `level0.lvl` (a2b2b2c, b7d67d3)
- Debug and test level files added and removed across commits (b7d67d3, 7bdbc4c)

**Briefing and HUD**
- Mission briefing screen gained wording and layout changes (a1532e7, b77bf0f)
- Briefing text file updated (a1532e7)

## 2026-10-12

**Mission briefing and CRT look**
- Mission briefing screen added, with a CRT shader for it and a shared CRT screen update (1ba63b9)
- HUD and main menu tweaks (1ba63b9)

**Terminal and menus**
- Terminal OS, boot sequence, and terminal machine props added (26d5c61, f9c8387)
- Terminal toast notifications added (f9c8387)
- Main menu updates (26d5c61, 1e6c7f9, b3827c0)
- Interact tooltip and pickup prompt added (b3827c0, 74d9499)

**Audio**
- Carpet footstep recordings added, replacing the old carpet `.ogg` files (1952431)
- Audio manager, breathing, scare, and creature-step scripts added (46b0cc7)

**Scenes and engine**
- Main scene and main menu scene restructured (46b0cc7)
- Game logic engine gained stability, performance, and load-manifest scripts (9af72ef)
- Render engine and atmospheres added (e8b7c63, 9af72ef)

**Entities**
- Mannequin crowd and mannequin hint generation (5e2f703, 74d9499)
- Death overlay and blood effects added (5e2f703, 9af72ef)
- Mimic, burnt, eyes, and grabber entities updated (beb84c1)

**Pickups**
- Battery, flash, and tape pickups added, plus a generated battery audio file (e8b7c63, 243bfcf)

**Level editor**
- Pose editor and editor icons added (5e2f703)

## 2026-10-10

- Project settings updated in `project.godot` (3f8380b)
- Early edits to player, menu, and battery pickup scripts (243bfcf, e0a0c09, beb84c1)

## Repository

- A Claude Blender skill pack was added under `.claude/skills/` (46b0cc7)
- Site copy added for the itch page (b3827c0, 74d9499)
- README updated (7bdbc4c, 9af72ef)
