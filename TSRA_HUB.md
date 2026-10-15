# T.S.R.A. Hub — plan and model list

The T.S.R.A. (Threshold Spatial Research Agency) hub is the agency's hideout inside the Backrooms. For now it is the
place the game starts: the players stand in the **launch bay**, work the terminal, pull the lever, a portal opens with
a smooth animation and they step through into the first level. From there it is level → exit → next level.

**Later:** more hubs and annexes (other wings of the same facility). Rare portals inside the levels lead back into
them, each one into a different place, so the agency feels huge.

Scale stays the game's: 4.5 m cells, 5.4 m walls, 2.15 m doors.

---

## Done

- [x] **ASRA → T.S.R.A. rename** everywhere in code and data (`tsra_archive.gd`, `tsra_clearance.gd`,
      `levels/tsra_*.json`, `tsra_id` meta). Old clearance saves (`user://asra_clearance.cfg`) still load.
- [x] **T.S.R.A. emblem** — the one the field terminal shows: two crystal shards split down the middle, ringed by an
      orbit (`godot-backrooms/textures/ui/tsra_logo.png`, drawn by `godot-backrooms/tools/gen_tsra_logo.py`).
- [x] **Emergency lever panel** (Sketchfab, CC-BY: `models/CREDITS.txt`) retextured: "ONLY USE IN AN EMERGENCY" →
      "T.S.R.A.", Helix screen → the emblem (`tools/make_tsra_branding.py`)
  - animated screen: `shaders/tsra_panel_screen.gdshader` (boot, STANDBY, PULL LEVER, CHARGING bar, OPEN flash)
  - `scripts/World/props/tsra_emergency_panel.gd`: [E] to pull, `pulled` / `charged` signals
- [x] **Blender props** (`tools/blender/build_tsra_*.py`, shared helpers in `tsra_common.py`; run headless, the
      `.blend` sources go to `assetsimported/tsra/`):
  - `tsra_sign.glb` — the emblem in 3D (amber glass shards, brass frames, a real orbit ring) over "T.S.R.A." and the
    agency's name on a gunmetal plate with an amber light strip. 9.9k tris.
  - `tsra_console.glb` — the launch console: terminal bay, sloped switch desk, lever bay with a chevron hazard plate,
    gauges and lamps on the backboard, `MOUNT_terminal` / `MOUNT_lever` markers, collision. 14k tris.
  - `tsra_portal_frame.glb` — the Sketchfab portal frame (CC-BY) decimated 587k → 59k tris, scaled to game size,
    doorway measured, collision.
  - `tsra_gate.glb` — the gate's base: hazard-ringed platform, two charge coils, the orbit ring. 15.7k tris.
- [x] **The launch bay room** — `levels/tsra_hub.lvl` (made by `godot-backrooms/tools/gen_tsra_hub.py`), first in
      `levels/levels.json`: a tall steel hall, safe, no monsters (the event director stays quiet in a hub).
  - `scripts/World/props/tsra_launch_bay.gd` stands the gate, the console (with the field terminal and the lever
    panel on it) and the signs up from the .lvl's `"hub"` block.
  - `scripts/World/props/tsra_portal_gate.gd` + `shaders/tsra_portal.gdshader`: the threshold in the frame's doorway.
  - **The sequence works**: [E] on the lever → it swings down → panel + gate charge (coils brighten, orbit whirls,
    the hairline flickers) → the threshold tears open → walk into the doorway → Level 0.
  - **Cables**: the game's own cable system — four cables (coils and gate to the console) in
    `levels/marks/tsra_hub.json`, written by `gen_tsra_hub.py`.
  - **Hazard plate**: the chevron hazard tape texture, on the gate platform's ring and behind the lever.
  - Briefing: `tsra_hub` block in `levels/tsra_briefings.json` (Level 0's deployment file + "report to Launch Bay 1").

## Next — build in Blender

| Model | Notes |
|---|---|
| Rotating amber beacon | Separate reflector so it can spin with the charge. |
| Blast door | ~3 m wide, stenciled with a sector name. Never opens — says the facility goes on. |
| Wing signs / "THRESHOLD ACTIVE" lightbox | One sign mesh, swappable textures. |
| Flashlight charging rack | Holds the existing `models/flashlight.glb`. |
| Decon shower booth | Simple box + nozzles. |
| Observation window frame | Steel frame between the control room and the bay. |

## Next — use what the game already has

| Thing | How |
|---|---|
| Door lock | `asetsuimprot/tsraroom/door_lock.glb` — badge reader / keypad beside the hub doors. |
| Crates, water cooler, pipes, electrical cabinets, fuel tank | Already in `models/props/` (`case_boxes`, `water_dispenser`, `rusty_tubes`, `electrical_cabinet`, `horizontal_fuel_tank`). |
| Hazmat suit on a hook | The player hazmat model, posed. |

## Next — download

Server racks · reel-to-reel tape machine · oscilloscope / analog meters · metal lockers · gas masks · first-aid
cabinet · fire extinguisher · metal shelving · coffee machine · wall clock · rotary phone / intercom · PA speaker horn ·
security camera.

Sources: Poly Haven (CC0), Poly Pizza, Quaternius, Kenney, Sketchfab (check each license, add it to `models/CREDITS.txt`).

## Next — code

- [ ] **Co-op**: the lever and the gate are local only; sync `pull()` / the open portal through `scripts/Net`.
- [ ] **Sounds** for the lever, the charge-up and the portal (say "claude opus layer" for those).
- [ ] **The doorway's sill** is 0.46 m high with no collision, so the player walks through it into the threshold;
      give it a step or a ramp if it reads badly.
- [ ] **Lighting pass** on the hall: it reads dark; more troffers or a few practical lamps.
- [ ] Portal destinations beyond "next level": `{"to": "level", "id": ...}` / `{"to": "hub", "arrive": ...}`.

## Later — more hubs and annexes

- [ ] Other wings: control room, labs, living quarters / cafeteria, storage, decon, maintenance.
- [ ] Named arrival points in each wing; rare portals in levels lead to one of them.
- [ ] Wings that start sealed (blast doors, dead badge readers) so each return shows somewhere new.
- [ ] Directional signage pointing to wings the player has not reached.
