"""The T.S.R.A. hub: writes levels/tsra_hub.lvl and its floor cables (levels/marks/tsra_hub.json).

    python tools/gen_tsra_hub.py

A facility hall after Kane Pixels' Async footage, the first entry of levels/levels.json: the game starts here.
6 x 4 cells (27 x 18 m, 5.4 m to the drop ceiling), cast concrete-panel walls (Concrete_Panels), a raised-floor
tile floor (Tile_Raised_Floor), a drop ceiling with its light panels, bright and steady. Dead quiet: no reverb
zone is painted, and audio.gd / ambience.gd go dry and silent in a hub.

    z1   #  office  office  #  #  alcove  #  #         (the back wall, north)
    z2.. #  hall ........................ #
         spawn at the south end, looking north

Its "hub" block is read by scripts/World/props/tsra_launch_bay.gd (level_builder.gd hands it over instead of
building an exit door and scattering pickups):
  gate       the threshold (tsra_portal_gate.gd, bare: no platform, no frame model) in the back-wall alcove:
             [x, z, yaw]; the launch bay frames the opening and hangs the shutter that slides up on the lever
  threshold  the opening: w, h (metres)
  office     the window partition along the office's front: x [from, to] and z (cells), the window and door
             spans (cells along x), sill / head heights (metres), its warm lamp [x, z] (cells)
  linings    wallpaper hung on the inside of the office's and the alcove's walls (wall paint is per wall cell,
             and those cells also face the hall): [{pbr, faces: [[cell x, cell z, dx, dz], ...]}]
  console    the launch console (models/props/tsra/tsra_console.glb) against the east wall; the field terminal
             and the emergency lever panel go on its MOUNT_ markers
  signs      T.S.R.A. wall signs: [x, z, yaw, height above the floor, scale]
Positions are in cells (x, z; a cell's middle is a whole number). In the hub block yaw 0 faces +Z (south), 90
faces +X; the "objects" use the editor's rotation (0 faces +X, clockwise on the map: 90 faces +Z).
"""
import json
import math
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
LV = os.path.join(HERE, "..", "levels")
CELL = 4.5
N = 8
GRID = [
    "########",
    "#..##.##",      # office (1,1)-(2,1), the threshold alcove (5,1)
    "#......#",
    "#......#",
    "#......#",
    "#......#",
    "########",
    "########",
]
OFFICE = [(1, 1), (2, 1)]
ALCOVE = [(5, 1)]
BACK = 1.5                               # the back wall's face (cells)
EAST = 6.5                               # the east wall's face

GATE = (5.0, BACK, 0.0)
THRESHOLD = {"w": 3.4, "h": 3.3}
CONSOLE = (EAST - 0.42 / CELL, 2.55, -90.0)
SIGNS = [
    [5.0, BACK + 0.001, 0.0, 4.45, 1.0],         # over the threshold
    [EAST - 0.001, 3.55, -90.0, 2.1, 0.8],       # over the console
]
OFFICE_PART = {"x": [0.5, 2.5], "z": BACK, "window": [0.66, 2.02], "door": [2.14, 2.38], "sill": 1.0, "head": 2.45,
               "light": [1.5, 1.0]}
SPAWN = [4, 5]
SPAWN_ROT = 270.0                        # the editor's arrow: degrees clockwise on the map, 0 = +x; 270 = north

DESK_H = 0.76                            # prop_old_desk surface_h


def obj(t, x, z, rot=0.0, scale=1.0, **kw):
    o = {"type": t, "pos_x": round(x, 3), "pos_y": round(z, 3), "rotation": round(rot % 360.0, 2), "scale": scale}
    o.update(kw)
    return o


def back(depth):
    """cells z for a piece `depth` m deep standing against the back wall"""
    return BACK + (depth * 0.5 + 0.03) / CELL


def objects():
    m = 1.0 / CELL
    out = [
        # the switchgear row against the back wall, the scaffold tower at its west end
        obj("prop_scaffold_tower", 12.35 * m, back(1.99), 90),
        obj("prop_switchgear", 14.75 * m, back(0.62), 90),
        obj("prop_switchgear_b", 17.35 * m, back(0.60), 90),
        obj("prop_electrical_cabinet", 19.45 * m, back(0.48), 0),
        # either side of the threshold's east jamb
        obj("prop_electrical_cabinet", 26.1 * m, back(0.48), 0),
        obj("prop_electrical_cabinet", 27.6 * m, back(0.48), 0),
        obj("prop_box_pile", 28.2 * m, 24.0 * m, 0),
        obj("prop_water_cooler", 2.75 * m, 9.2 * m, 0),
    ]
    # the office: a desk on its back wall, the CRT looking out through the window, the chair at it
    dx, dz = 6.2 * m, (2.25 + 0.47) * m
    out += [
        obj("prop_old_desk", dx, dz, 90),
        obj("prop_crt_monitor", dx - 0.25 * m, dz + 0.05 * m, 90, elev=DESK_H),
        obj("prop_desk_lamp", dx + 0.6 * m, dz - 0.1 * m, 120, elev=DESK_H),
        obj("prop_paper_pile", dx + 0.35 * m, dz + 0.18 * m, 80, elev=DESK_H),
        obj("prop_midcentury_chair", dx - 0.1 * m, dz + 0.95 * m, 270),
        obj("prop_box_pile", 3.2 * m, 3.4 * m, 90),
        obj("prop_office_cubicle", 9.6 * m, 3.6 * m, 180),
    ]
    # the foreground desks, chairs on their far side facing the spawn
    for (x, z, r) in [(14.6, 20.4, 90), (21.6, 19.8, 90)]:
        x, z = x * m, z * m
        out += [
            obj("prop_old_desk", x, z, r),
            obj("prop_midcentury_chair", x - 0.25 * m, z - 0.85 * m, 90),
            obj("prop_paper_pile", x - 0.3 * m, z + 0.1 * m, 15, elev=DESK_H),
            obj("prop_paper_pile", x + 0.2 * m, z - 0.05 * m, 200, elev=DESK_H),
            obj("prop_notepad", x + 0.5 * m, z + 0.15 * m, 100, elev=DESK_H),
        ]
    out.append(obj("prop_rotary_phone", 13.95 * m, 20.3 * m, 80, elev=DESK_H))
    out.append(obj("prop_midcentury_chair", 16.4 * m, 21.6 * m, 30))
    return out


def linings():
    """the faces of the given open cells that meet a wall cell"""
    grid = GRID

    def faces(cells):
        f = []
        for (x, z) in cells:
            for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                if grid[z + dz][x + dx] == "#":
                    f.append([x, z, dx, dz])
        return f
    return [{"pbr": "Wallpaper_Yellow_Stripe", "faces": faces(OFFICE)},
            {"pbr": "Wallpaper_Yellow_Chevron", "faces": faces(ALCOVE)}]


def cable(pts_xz, kind, r, seed):
    """A cable lying on the floor through the given waypoints (metres), sampled every 4 cm with a little sway"""
    rnd = random.Random(seed)
    out = []
    for (x0, z0), (x1, z1) in zip(pts_xz, pts_xz[1:]):
        L = math.hypot(x1 - x0, z1 - z0)
        n = max(2, int(L / 0.04))
        nx, nz = -(z1 - z0) / L, (x1 - x0) / L
        ph = rnd.uniform(0, 6.28)
        for i in range(n):
            t = i / n
            sway = math.sin(t * L * 0.9 + ph) * 0.05 * math.sin(math.pi * t)
            out.append([round(x0 + (x1 - x0) * t + nx * sway, 3), round(r + 0.002, 3), round(z0 + (z1 - z0) * t + nz * sway, 3)])
    x, z = pts_xz[-1]
    out.append([round(x, 3), round(r + 0.002, 3), round(z, 3)])
    return {"id": "hub%04d" % seed, "n": [0.0, 1.0, 0.0], "pts": out, "r": r, "roll": 0.5, "stack": 0, "t": 0.0, "type": kind}


def main():
    open_cells = [[x, z] for z in range(N) for x in range(N) if GRID[z][x] == "."]
    lvl = {
        "format": "backrooms_level", "version": 2, "name": "T.S.R.A. Hub: Facility Hall", "size": N,
        "atmosphere": "classic", "lights": "panels",
        "materials": {"wall": "Concrete_Panels", "floor": "Tile_Raised_Floor", "ceiling": "Ceiling_Drop_Square"},
        "paint": {"floor": {"Carpet_Yellow_Green": [list(c) for c in OFFICE + ALCOVE]}},
        "drop_hole": None, "grid": GRID,
        "zones": {"safe": open_cells},
        "objects": objects(), "walls": {},
        "spawn": SPAWN, "spawn_rot": SPAWN_ROT, "exit": None, "entity": None, "tv": None,
        "hub": {"gate": list(GATE), "threshold": THRESHOLD, "office": OFFICE_PART, "linings": linings(),
                "console": [round(v, 4) for v in CONSOLE], "signs": SIGNS},
    }
    with open(os.path.join(LV, "tsra_hub.lvl"), "w") as fh:
        json.dump(lvl, fh, indent=1)

    # cables (metres): from the threshold's east jamb and the switchgear to the console, one out to the desks
    con_x, con_z = CONSOLE[0] * CELL, CONSOLE[1] * CELL
    jamb_x = GATE[0] * CELL + THRESHOLD["w"] * 0.5 + 0.35
    wall_n = BACK * CELL
    cables = [
        cable([(jamb_x, wall_n + 0.3), (jamb_x + 1.0, wall_n + 0.9), (con_x - 0.3, wall_n + 1.5), (con_x - 0.55, con_z - 1.2)],
              "hi_volt_orange", 0.045, 1),
        cable([(18.4, wall_n + 0.4), (20.2, wall_n + 1.3), (jamb_x + 0.6, wall_n + 1.7), (con_x - 0.75, con_z - 1.0)],
              "heavy_black", 0.05, 2),
        cable([(con_x - 0.6, con_z + 1.0), (25.5, 15.5), (22.4, 19.0)], "yellow_ext", 0.03, 3),
    ]
    with open(os.path.join(LV, "marks", "tsra_hub.json"), "w") as fh:
        json.dump({"cables": cables}, fh, indent=1)
    print("levels/tsra_hub.lvl (%d objects), levels/marks/tsra_hub.json: %d cables" % (len(lvl["objects"]), len(cables)))


if __name__ == "__main__":
    main()
