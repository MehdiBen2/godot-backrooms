"""The Poolrooms (Level 37) in the pool look: white tile, flooded halls, a grid of bright round downlights.
Built after three reference photos, one area each:
  the colonnade hall   tall white hall, two rows of thick round columns, a parapet gallery along one side with
                       steps rising out of the water to it, flooded (the yellow-duck photo)
  the arch tunnel      a narrow flooded passage through ring after ring of round arches (the tunnel photo)
  the cube rooms       tall square rooms joined by big square openings, all flooded
                       (the photo of the white cubes)
and a dry lap-pool hall and a dry entrance landing, reached over a low step out of the water.
Writes levels/level_37_poolrooms.lvl and adds it to levels/levels.json (the other entries are left alone).
usage: python tools/gen_poolrooms.py [<godot-backrooms project dir>]"""
import json, math, os, random, sys

PROJ = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LV = os.path.join(PROJ, "levels")
LEVEL_ID = "level_37_poolrooms"
NAME = "Level 37: The Poolrooms"
N = 56
WATER = 0.5                 # m: how deep the flooded halls stand (shin to knee)
STEP = 0.6                  # m: the dry landings' step, just over the water so its glassy edge hides behind it

r = random.Random(1037)
grid = [["#"] * N for _ in range(N)]
zones = {k: set() for k in ("tall", "tiles", "hall_reverb", "safe")}
paint = {"floor": {}, "wall": {}, "ceiling": {}}
objs = []


def carve(x0, y0, x1, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            grid[y][x] = "."


def cells(x0, y0, x1, y1):
    return [(x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]


def obj(t, x, y, rot=0.0, scale=1.0, **kw):
    o = {"type": t, "pos_x": round(float(x), 3), "pos_y": round(float(y), 3), "rotation": round(float(rot) % 360.0, 2),
         "scale": round(float(scale), 3)}
    o.update(kw)
    objs.append(o)
    return o


def water(x0, y0, x1, y1, level=WATER):
    """a water surface over cells x0..x1, y0..y1 (wall cells inside it are solid blocks: it never shows in them)"""
    obj("water", (x0 + x1) / 2, (y0 + y1) / 2, 0.0, float(y1 - y0 + 1), depth=float(x1 - x0 + 1), level=level,
        tint="teal", caustics=True)


def landing(x, y, into_dry, into_wet):
    """a low dry step through the 1-cell opening (x, y): a slab STEP m up filling it, a short flight down each side.
    `into_dry` / `into_wet`: the (dx, dy) from the opening toward the dry room and the flooded one"""
    along = (abs(into_wet[0]), abs(into_wet[1]))
    obj("platform", x, y, 0.0 if along[0] else 90.0, 1.0, depth=1.0, elev=STEP, slab=STEP, edge="none", posts=False, surface="tile")
    rot = {(1, 0): 0.0, (0, 1): 90.0, (-1, 0): 180.0, (0, -1): 270.0}
    for d in (into_dry, into_wet):
        # the flight stands just outside the opening and climbs back toward it: its top edge meets the slab's
        obj("stair_flight", x + d[0] * 0.8, y + d[1] * 0.8, rot[(-d[0], -d[1])], 0.8, depth=0.6, elev=0.0, rise=STEP,
            railing="none", surface="tile")


def oct_pts(rx, ry, cut=0.35):
    cx, cy = rx * cut, ry * cut
    return [(-rx + cx, -ry), (rx - cx, -ry), (rx, -ry + cy), (rx, ry - cy), (rx - cx, ry), (-rx + cx, ry), (-rx, ry - cy), (-rx, -ry + cy)]


# ---------------------------------------------------------------- the entrance landing (dry): you start here
ENTRY = (2, 24, 6, 29)
carve(*ENTRY)
zones["safe"].update(cells(*ENTRY))

# ---------------------------------------------------------------- the colonnade hall (photo 1)
HALL = (8, 18, 29, 33)
carve(*HALL)
zones["tall"].update(cells(*HALL))
carve(7, 26, 7, 26)
landing(7, 26, (-1, 0), (1, 0))
for row in (23, 28):                                     # two rows of thick columns up to the ceiling
    for x in range(10, 29, 3):
        obj("column", x, row, 0.0, 1.0, thick=1.8, height=0.0)
# the gallery: a tiled balcony along the north wall, a parapet round it, steps up out of the water at its east end
obj("platform", (HALL[0] + HALL[2]) / 2, 18.5, 0.0, 2.0, depth=float(HALL[2] - HALL[0] + 1), elev=5.4, slab=0.45,
    edge="parapet", posts=True, surface="tile")
obj("stair_flight", 27, 19.5 + 0.8, 270.0, 0.9, depth=1.6, elev=0.0, rise=5.4, railing="both", surface="tile")

# ---------------------------------------------------------------- the lap-pool hall (dry deck), north of the gallery
POOLS = (8, 4, 29, 14)
carve(*POOLS)
zones["tall"].update(cells(*POOLS))
carve(18, 15, 18, 17)                                    # a passage under the gallery, over a low step
obj("platform", 18, 16, 90.0, 1.0, depth=3.0, elev=STEP, slab=STEP, edge="none", posts=False, surface="tile")
obj("stair_flight", 18, 17.5 + 0.3, 270.0, 0.8, depth=0.6, elev=0.0, rise=STEP, railing="none", surface="tile")
obj("stair_flight", 18, 14.5 - 0.3, 90.0, 0.8, depth=0.6, elev=0.0, rise=STEP, railing="none", surface="tile")
obj("pool", 18.5, 9, 0.0, 1.0, points=[[round(p[0], 3), round(p[1], 3)] for p in oct_pts(8.0, 2.2, 0.15)],
    shallow=1.0, deep=2.6, lip=0.15, tint="teal", steps=True, ladder=True)
for row in (5, 13):
    for x in range(10, 29, 3):
        obj("column", x, row, 0.0, 1.0, thick=1.2, height=0.0)

# ---------------------------------------------------------------- the arch tunnel (photo 2)
TY = 28
carve(31, TY, 41, TY)
obj("arch", 30, TY, 0.0, 1.0)                            # punched through the hall's east wall
for x in range(32, 41, 2):                               # an arch is a cell thick: one every other cell, so they read as
    obj("arch", x, TY, 0.0, 1.0)                         # ring after ring receding, not one long vault

# ---------------------------------------------------------------- the cube rooms (photo 3)
COLS = (42, 48)                                          # 5 x 5 rooms, one wall cell between
ROWS = (15, 21, 27, 33)
for cx in COLS:
    for ry in ROWS:
        room = (cx, ry, cx + 4, ry + 4)
        carve(*room)
        zones["tall"].update(cells(*room))
# square openings (the cut cells keep the ordinary 5.4 m ceiling: a lintel under the tall rooms), off-centre
for ry in ROWS:
    y = ry + r.randint(1, 3)
    carve(47, y, 47, y)
for cx in COLS:
    for wy in (20, 26, 32):
        x = cx + r.randint(1, 3)
        carve(x, wy, x, wy)

# ---------------------------------------------------------------- water, paint, zones
water(HALL[0], HALL[1], 41, HALL[3])                     # the hall and the tunnel (the walls between hide it)
water(42, ROWS[0], 52, ROWS[-1] + 4)                     # the cube rooms
open_cells = [(x, y) for y in range(N) for x in range(N) if grid[y][x] == "."]
zones["tiles"].update(open_cells)
zones["hall_reverb"].update(open_cells)
flooded = [c for c in open_cells if (HALL[0] <= c[0] <= 41 and HALL[1] <= c[1] <= HALL[3]) or c[0] >= 42]
paint["floor"]["Tile_Aqua_Mosaic"] = flooded             # (white tile reads grey through the water: aqua reads as pool)

# ---------------------------------------------------------------- spawn, exit, a quiet intro
SPAWN = (3, 26)
EXIT = (52, 37)                                          # the far corner of the last cube room
assert grid[SPAWN[1]][SPAWN[0]] == "." and grid[EXIT[1]][EXIT[0]] == "."
obj("trigger", 5, 26, 0.0, 3.0, event="message", custom_event="", events_list=[], once=True, delay=0.0, duration=20.0, depth=3.0,
    text="LEVEL 37 - THE POOLROOMS. White tile, warm water, every light on. It is peaceful here. That is what makes it wrong.")
for (x, y), ev in zip([(20, 30), (36, 28), (44, 23), (50, 30)], ["silence", "drone", "silence", "hallucination"]):
    obj("trigger", x, y, 0.0, 2.5, event=ev, custom_event="", events_list=[], text="", once=True, delay=0.0, duration=14.0, depth=2.0)

out = {
    "format": "backrooms_level", "version": 2, "name": NAME, "size": N,
    "atmosphere": "liminal", "lights": "panels",      # (a tiled ceiling: round downlights in it)
    "materials": {"wall": "Tile_White_Grid", "floor": "Tile_White_Grid", "ceiling": "Tile_White_Grid", "tiles": "Tile_White_Grid"},
    "drop_hole": None,
    "grid": ["".join(row) for row in grid],
    "zones": {k: sorted([list(c) for c in v]) for k, v in zones.items()},
    "paint": {slot: {m: sorted([list(c) for c in cs]) for m, cs in mp.items()} for slot, mp in paint.items() if mp},
    "objects": objs,
    "spawn": list(SPAWN), "spawn_rot": 0.0,
    "exit": list(EXIT), "entity": None, "tv": None,
}
with open(os.path.join(LV, LEVEL_ID + ".lvl"), "w", encoding="utf-8", newline="\n") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")

lj = os.path.join(LV, "levels.json")
playlist = json.load(open(lj, encoding="utf-8"))
if not any(e["id"] == LEVEL_ID for e in playlist):
    playlist.append({"file": LEVEL_ID + ".lvl", "id": LEVEL_ID, "name": NAME})
    with open(lj, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(playlist, fh, indent=2)
        fh.write("\n")
print("wrote", LEVEL_ID + ".lvl:", len(objs), "objects,", len(open_cells), "open cells")
