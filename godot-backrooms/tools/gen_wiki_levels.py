"""Backrooms wiki levels for godot-backrooms, v2: 20 levels using every build feature the editor has
(windows, stairwells between floors, endless stacks, platforms + flights, spirals, pools, water, spline / curved /
corner walls, half walls, arches, doors, squeeze gaps, material paint, wall-mounted signs, event triggers).
usage: python gen_levels2.py <godot-backrooms project dir>"""
import json, math, random, sys, os
from collections import deque

PROJ = sys.argv[1]
LV = os.path.join(PROJ, "levels")
ZONES = ["abyss", "bright", "classic", "crawl", "dark", "dim", "drain", "echo", "endless_ceiling", "flicker", "grand",
         "grime", "hall_reverb", "liminal", "loop", "loot", "low", "mannequin", "muffled", "noclip", "noclip_floor",
         "open_ceiling", "safe", "tall", "tiles"]
DIRS = ((1, 0), (-1, 0), (0, 1), (0, -1))
PASS = ".DA"
MOUNTED = {"prop_exit_sign", "prop_exit_sign_medium", "prop_exit_sign_big", "wall_sconce"}
FREE_LAMPS = ("lamp_floor", "chandelier", "emergency_strip", "candle", "string_lights", "streetlamp", "vent_glow")
ROT = {(1, 0): 0.0, (0, 1): 90.0, (-1, 0): 180.0, (0, -1): 270.0}
DIR = {0: (1, 0), 90: (0, 1), 180: (-1, 0), 270: (0, -1)}


MAX_WINDOWS = 26     # each one throws real sunlight: keep a floor to a sane number


def rot_of(dx, dy): return ROT[(dx, dy)]


class F:
    """one floor of a level"""

    def __init__(s, n, r):
        s.n, s.r = n, r
        s.g = [["#"] * n for _ in range(n)]
        s.z = {k: set() for k in ZONES}
        s.objs = []
        s.paint = {"wall": {}, "floor": {}, "ceiling": {}}
        s.rooms = []
        s.stair_cells = set()
        s.reserved = set()      # no props here (stair doorways, pools)
        s.noexit = set()
        s.used_faces = []
        s.starts = []
        s.windows_made = 0

    # ------------------------------------------------ grid
    def ok(s, x, y): return 1 <= x < s.n - 1 and 1 <= y < s.n - 1
    def put(s, x, y, c="."):
        if s.ok(x, y): s.g[y][x] = c
    def at(s, x, y): return s.g[y][x] if 0 <= x < s.n and 0 <= y < s.n else "#"
    def wallc(s, x, y): return s.at(x, y) == "#"
    def open(s, x, y): return s.ok(x, y) and s.g[y][x] in PASS
    def rect(s, x0, y0, x1, y1, c="."):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            for x in range(min(x0, x1), max(x0, x1) + 1): s.put(x, y, c)
    def room(s, x0, y0, w, h, tag=""):
        s.rect(x0, y0, x0 + w - 1, y0 + h - 1)
        s.rooms.append((x0, y0, w, h, tag))
        return s.rooms[-1]
    def in_room(s, rm, pad=0):
        x0, y0, w, h, _ = rm
        return lambda x, y: x0 + pad <= x < x0 + w - pad and y0 + pad <= y < y0 + h - pad
    def hall(s, x0, y0, x1, y1, w=1):
        x, y = x0, y0
        s.rect(x, y, x + w - 1, y + w - 1)
        for (a, b) in ((x1, y0), (x1, y1)):
            while (x, y) != (a, b):
                if x != a: x += 1 if a > x else -1
                elif y != b: y += 1 if b > y else -1
                s.rect(x, y, x + w - 1, y + w - 1)
    def disk(s, cx, cy, r, c="."):
        for y in range(int(cy - r) - 1, int(cy + r) + 2):
            for x in range(int(cx - r) - 1, int(cx + r) + 2):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r: s.put(x, y, c)
    def cells(s, pred=None):
        return [(x, y) for y in range(1, s.n - 1) for x in range(1, s.n - 1)
                if s.g[y][x] == "." and (pred is None or pred(x, y))]
    def nwalls(s, x, y): return sum(1 for d in DIRS if s.wallc(x + d[0], y + d[1]))
    def tag(s, zone, cs): s.z[zone].update(cs)
    def tag_rect(s, zone, x0, y0, w, h): s.tag(zone, [(x, y) for y in range(y0, y0 + h) for x in range(x0, x0 + w)])
    def tag_room(s, zone, rm, pad=0): s.tag_rect(zone, rm[0] + pad, rm[1] + pad, rm[2] - 2 * pad, rm[3] - 2 * pad)
    def tag_all(s, zone, pred=None): s.tag(zone, s.cells(pred))
    def tag_some(s, zone, p, pred=None): s.tag(zone, [c for c in s.cells(pred) if s.r.random() < p])
    def paint_cells(s, slot, mat, cs): s.paint[slot].setdefault(mat, set()).update(cs)
    def paint_room(s, slot, mat, rm, walls=False):
        x0, y0, w, h, _ = rm
        if walls: s.paint_cells("wall", mat, [(x, y) for y in range(y0 - 1, y0 + h + 1) for x in range(x0 - 1, x0 + w + 1)])
        else: s.paint_cells(slot, mat, [(x, y) for y in range(y0, y0 + h) for x in range(x0, x0 + w)])

    # ------------------------------------------------ openings
    def is_mouth(s, x, y):
        """a wall cell with open cells on two opposite sides and walls on the other two: a doorway spot"""
        if s.at(x, y) != "#": return None
        for (a, b) in (((1, 0), (0, 1)), ((0, 1), (1, 0))):
            if s.open(x + a[0], y + a[1]) and s.open(x - a[0], y - a[1]) and s.wallc(x + b[0], y + b[1]) and s.wallc(x - b[0], y - b[1]):
                return a
        return None
    def door_at(s, x, y, ch="D"):
        if s.ok(x, y): s.g[y][x] = ch
    def corridor_doors(s, p=0.5, ch="D", gap=3):
        """doors on 1-wide corridor cells where they open into a room"""
        done = []
        for (x, y) in s.cells():
            for (a, b) in (((1, 0), (0, 1)), ((0, 1), (1, 0))):
                if (s.open(x + a[0], y + a[1]) and s.open(x - a[0], y - a[1])
                        and s.wallc(x + b[0], y + b[1]) and s.wallc(x - b[0], y - b[1])):
                    roomy = [sum(1 for dx in (-1, 0, 1) for dy in (-1, 0, 1) if s.open(cx + dx, cy + dy)) >= 8
                             for cx, cy in ((x + 2 * a[0], y + 2 * a[1]), (x - 2 * a[0], y - 2 * a[1]))]
                    if any(roomy) and s.r.random() < p and all(abs(x - d[0]) + abs(y - d[1]) >= gap for d in done):
                        s.g[y][x] = ch; done.append((x, y))
        return done
    def squeeze_gaps(s, n, pred=None):
        cand = []
        for (x, y) in s.cells(pred):
            for (a, b) in (((1, 0), (0, 1)), ((0, 1), (1, 0))):
                if (s.at(x + a[0], y + a[1]) == "." and s.at(x - a[0], y - a[1]) == "."
                        and s.wallc(x + b[0], y + b[1]) and s.wallc(x - b[0], y - b[1])):
                    cand.append((x, y, rot_of(*a)))
        s.r.shuffle(cand)
        put = []
        for (x, y, rt) in cand:
            if len(put) >= n: break
            if all(abs(x - p[0]) + abs(y - p[1]) > 8 for p in put):
                s.obj("squeeze_gap", x, y, rt, 1.0, gap=0.55); put.append((x, y)); s.reserved.add((x, y))

    # ------------------------------------------------ objects
    def obj(s, t, x, y, rot=0.0, scale=1.0, **kw):
        o = {"type": t, "pos_x": round(float(x), 3), "pos_y": round(float(y), 3), "rotation": round(float(rot) % 360.0, 2), "scale": round(float(scale), 3)}
        o.update(kw)
        s.objs.append(o)
        return o
    def trigger(s, x, y, event, text="", scale=3.0, depth=2.0, duration=20.0, once=True, delay=0.0, rot=0.0):
        s.obj("trigger", x, y, rot, scale, event=event, custom_event="", events_list=[], text=text, once=once,
              delay=delay, duration=duration, depth=depth)
    def scares(s, n, events, pred=None, scale=2.5):
        cs = s.cells(pred)
        for c in s.r.sample(cs, min(n, len(cs))):
            s.trigger(c[0], c[1], s.r.choice(events), scale=scale, duration=s.r.choice([8.0, 14.0, 20.0]))
    def near(s, x, y, d, kinds=("prop_", "pillar", "column")):
        return any(abs(o["pos_x"] - x) < d and abs(o["pos_y"] - y) < d for o in s.objs if o["type"].startswith(kinds))

    def faces(s, pred=None, exterior=False, straight=True, avoid_low=True):
        out = []
        for (x, y) in s.cells(pred):
            if avoid_low and ((x, y) in s.z["low"] or (x, y) in s.z["crawl"]): continue
            for dx, dy in DIRS:
                wx, wy = x + dx, y + dy
                if s.at(wx, wy) != "#" or (wx, wy) in s.stair_cells: continue
                if exterior and not s.wallc(x + 2 * dx, y + 2 * dy): continue
                if straight:
                    px, py = dy, dx
                    if not all(s.at(x + px * k, y + py * k) == "." and s.wallc(x + px * k + dx, y + py * k + dy)
                               and (x + px * k + dx, y + py * k + dy) not in s.stair_cells for k in (1, -1)):
                        continue
                out.append((x + dx * 0.5, y + dy * 0.5, rot_of(-dx, -dy), (x, y)))
        s.r.shuffle(out)
        return out
    def _take(s, faces, n, spacing):
        got = []
        for f in faces:
            if len(got) >= n: break
            if all(abs(f[0] - u[0]) + abs(f[1] - u[1]) >= spacing for u in s.used_faces):
                s.used_faces.append(f); got.append(f)
        return got
    def windows(s, n, pred=None, exterior=True, spacing=4.0, straight=True, frame="pane", sky="noon", scale=0.5,
                elev=0.9, height=2.2, sun=6.0, panes=3.0, sun_angle=32.0):
        made = 0
        n = min(n, MAX_WINDOWS - s.windows_made)
        if n <= 0: return 0
        for (x, y, rt, c) in s._take(s.faces(pred, exterior, straight), n, spacing):
            shadows = s.windows_made < 5
            s.obj("window", x, y, rt, scale, elev=elev, height=height, frame=frame, panes=float(panes), sun=float(sun),
                  sun_angle=float(sun_angle), sky=sky, shadows=shadows)
            s.windows_made += 1; made += 1
        return made
    def mount(s, types, n, pred=None, spacing=6.0, elev=None, exterior=False):
        for (x, y, rt, c) in s._take(s.faces(pred, exterior), n, spacing):
            o = s.obj(s.r.choice(types), x, y, rt, 1.0)
            if elev is not None: o["elev"] = elev
    def props(s, types, n, pred=None, wall=True, spacing=2.2, scale=1.0):
        cs = s.cells(pred)
        s.r.shuffle(cs)
        k = 0
        for (x, y) in cs:
            if k >= n: break
            if (x, y) in s.reserved or s.near(x, y, spacing): continue
            ws = [d for d in DIRS if s.wallc(x + d[0], y + d[1])]
            if wall and not ws: continue
            if wall:
                d = s.r.choice(ws)
                s.obj(s.r.choice(types), x + d[0] * 0.28 + s.r.uniform(-.15, .15) * (d[1] != 0),
                      y + d[1] * 0.28 + s.r.uniform(-.15, .15) * (d[0] != 0), rot_of(-d[0], -d[1]) + s.r.uniform(-15, 15), scale)
            else:
                s.obj(s.r.choice(types), x + s.r.uniform(-.25, .25), y + s.r.uniform(-.25, .25), s.r.uniform(0, 360), scale)
            k += 1
    # ---- lamps (props/lamp_fixture.gd)
    LAMPS = ("lamp_floor", "wall_sconce", "chandelier", "emergency_strip", "candle", "string_lights", "streetlamp", "vent_glow")
    def lamp(s, t, x, y, rot=0.0, scale=1.0, **kw):
        kw = {k: v for k, v in kw.items() if v is not None}
        return s.obj(t, x, y, rot, scale, **kw)
    def near_lamp(s, x, y, d, kinds=None):
        return any(abs(o["pos_x"] - x) < d and abs(o["pos_y"] - y) < d for o in s.objs if o["type"] in (kinds or s.LAMPS))
    def sconces(s, n, pred=None, tone="hotel", flicker=None, spacing=6.0, exterior=False, elev=None):
        for (x, y, rt, c) in s._take(s.faces(pred, exterior), n, spacing):
            s.lamp("wall_sconce", x, y, rt, 1.0, tone=tone, flicker=flicker, elev=elev)
    def centre_lamps(s, rooms, t="chandelier", min_w=6, min_h=6, tone="hotel", flicker=None, scale=None):
        for (x0, y0, w, h, _) in rooms:
            if w >= min_w and h >= min_h:
                s.lamp(t, x0 + (w - 1) / 2, y0 + (h - 1) / 2, 0.0, scale or min(2.2, max(0.9, min(w, h) / 7)), tone=tone, flicker=flicker)
    def lamps(s, t, n, pred=None, wall=True, tone=None, flicker=None, elev=None, spacing=3.0, scale=1.0, corner=False):
        cs = s.cells(pred)
        s.r.shuffle(cs)
        k = 0
        for (x, y) in cs:
            if k >= n: break
            if (x, y) in s.reserved or s.near_lamp(x, y, spacing, (t,)) or s.near(x, y, 1.2): continue
            ws = [d for d in DIRS if s.wallc(x + d[0], y + d[1])]
            if corner and len(ws) < 2: continue
            if wall and not ws: continue
            if ws:
                d = s.r.choice(ws)
                px, py = x + d[0] * 0.3, y + d[1] * 0.3
            else: px, py = x + s.r.uniform(-.2, .2), y + s.r.uniform(-.2, .2)
            s.lamp(t, px, py, s.r.uniform(0, 360), scale, tone=tone, flicker=flicker, elev=elev); k += 1
    def strings(s, n, pred=None, tone="warm", min_len=4, max_len=9, ceiling=None):
        cands = []
        for y in range(1, s.n - 1):
            x = 1
            while x < s.n - 1:
                if s.g[y][x] == "." and (pred is None or pred(x, y)):
                    x1 = x
                    while x1 + 1 < s.n - 1 and s.g[y][x1 + 1] == "." and (pred is None or pred(x1 + 1, y)): x1 += 1
                    if x1 - x + 1 >= min_len: cands.append((0.0, (x + x1) / 2, y, min(x1 - x + 1, max_len)))
                    x = x1 + 1
                else: x += 1
        for x in range(1, s.n - 1):
            y = 1
            while y < s.n - 1:
                if s.g[y][x] == "." and (pred is None or pred(x, y)):
                    y1 = y
                    while y1 + 1 < s.n - 1 and s.g[y1 + 1][x] == "." and (pred is None or pred(x, y1 + 1)): y1 += 1
                    if y1 - y + 1 >= min_len: cands.append((90.0, x, (y + y1) / 2, min(y1 - y + 1, max_len)))
                    y = y1 + 1
                else: y += 1
        s.r.shuffle(cands)
        got = []
        for (rt, x, y, ln) in cands:
            if len(got) >= n: break
            if all(abs(x - g[0]) + abs(y - g[1]) > 6 for g in got):
                s.lamp("string_lights", x, y, rt, float(ln - 1), tone=tone, elev=ceiling); got.append((x, y))
    def streetlamps(s, n, pred=None, spacing=9.0):
        cs = [c for c in s.cells(pred) if s.nwalls(*c) == 0 and any(s.wallc(c[0] + dx, c[1] + dy) for dx in (-2, -1, 0, 1, 2) for dy in (-2, -1, 0, 1, 2) if (dx, dy) != (0, 0))]
        s.r.shuffle(cs)
        got = []
        for (x, y) in cs:
            if len(got) >= n: break
            if all(abs(x - g[0]) + abs(y - g[1]) >= spacing for g in got):
                near = [(dx, dy) for dx, dy in DIRS if s.wallc(x + 2 * dx, y + 2 * dy) or s.wallc(x + dx, y + dy)]
                away = (-near[0][0], -near[0][1]) if near else (1, 0)
                s.lamp("streetlamp", x - away[0] * 0.2, y - away[1] * 0.2, rot_of(*away), 1.0)
                got.append((x, y))
    def emergency(s, n, pred=None, spacing=5.0, tone="red", flicker="pulse"):
        cs = s.cells(pred)
        s.r.shuffle(cs)
        got = []
        for (x, y) in cs:
            if len(got) >= n: break
            ew = s.wallc(x, y - 1) and s.wallc(x, y + 1)
            ns = s.wallc(x - 1, y) and s.wallc(x + 1, y)
            ox = oy = 0.0
            if ew: rt = 0.0
            elif ns: rt = 90.0
            else:                                    # in a wide hall: along the one wall beside it
                w1 = [d for d in DIRS if s.wallc(x + d[0], y + d[1])]
                if len(w1) != 1: continue
                rt = 0.0 if w1[0][1] != 0 else 90.0
                ox, oy = w1[0][0] * 0.3, w1[0][1] * 0.3
            if all(abs(x - g[0]) + abs(y - g[1]) >= spacing for g in got):
                s.lamp("emergency_strip", x + ox, y + oy, rt, 1.0, tone=tone, flicker=flicker); got.append((x, y))
    def puddles(s, n, pred=None, level=0.06, tint="murky", size=(1, 3)):
        cs = s.cells(pred)
        for c in s.r.sample(cs, min(n, len(cs))):
            w, d = s.r.randint(*size), s.r.randint(*size)
            s.obj("water", c[0], c[1], s.r.choice([0.0, 90.0]), w, depth=float(d), level=level, tint=tint, caustics=level > 0.2)
    def water_map(s, level_of):
        """water boxes over every cell level_of(x, y) gives a level for (None = dry), merged into rectangles"""
        lv = {}
        for (x, y) in s.cells():
            v = level_of(x, y)
            if v is not None: lv[(x, y)] = v
        done = set()
        for y in range(s.n):
            for x in range(s.n):
                if (x, y) not in lv or (x, y) in done: continue
                v = lv[(x, y)]
                x1 = x
                while (x1 + 1, y) in lv and lv[(x1 + 1, y)] == v and (x1 + 1, y) not in done: x1 += 1
                y1 = y
                while all((xx, y1 + 1) in lv and lv[(xx, y1 + 1)] == v and (xx, y1 + 1) not in done for xx in range(x, x1 + 1)): y1 += 1
                for yy in range(y, y1 + 1):
                    for xx in range(x, x1 + 1): done.add((xx, yy))
                s.obj("water", (x + x1) / 2, (y + y1) / 2, 0.0, float(y1 - y + 1), depth=float(x1 - x + 1), level=v,
                      tint="murky" if v > 1.0 else "teal", caustics=True)
                if v > 1.0: s.noexit.update((xx, yy) for yy in range(y, y1 + 1) for xx in range(x, x1 + 1))
    def pool(s, cx, cy, pts, rot=0.0, shallow=1.1, deep=3.0, tint="clear"):
        s.obj("pool", cx, cy, rot, 1.0, points=[[round(p[0], 3), round(p[1], 3)] for p in pts], shallow=shallow, deep=deep,
              lip=0.15, tint=tint, steps=True, ladder=True)
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
        for y in range(math.floor(cy + min(ys)) - 1, math.ceil(cy + max(ys)) + 2):
            for x in range(math.floor(cx + min(xs)) - 1, math.ceil(cx + max(xs)) + 2):
                s.reserved.add((x, y)); s.noexit.add((x, y))
    def mezzanine(s, rm, elev=4.5, surface="concrete", edge="parapet", side="w"):
        """a raised walkway along a room's west (or east) wall, a straight flight up to its south end"""
        x0, y0, w, h, _ = rm
        if h < 10 or w < 6: return False
        span = h - 6
        cy = y0 + (h - 1) / 2 - 1
        px = x0 + 0.5 if side == "w" else x0 + w - 1.5
        s.obj("platform", px, cy, 0.0, span, depth=2.0, elev=elev, slab=0.35, edge=edge, posts=True, surface=surface)
        s.obj("stair_flight", px, cy + span / 2 + 1.5, 270.0, 1.0, depth=3.0, elev=0.0, rise=elev, railing="both", surface=surface)
        for yy in range(int(cy + span / 2), int(cy + span / 2) + 4):
            s.reserved.update({(x0, yy), (x0 + 1, yy), (x0 + w - 1, yy), (x0 + w - 2, yy)})
        return True

    # ------------------------------------------------ finishing
    def bfs(s, starts):
        dist = {}
        q = deque()
        for c in starts:
            if s.open(*c): dist[c] = 0; q.append(c)
        while q:
            x, y = q.popleft()
            for d in DIRS:
                n = (x + d[0], y + d[1])
                if n not in dist and s.open(*n):
                    dist[n] = dist[(x, y)] + 1; q.append(n)
        return dist
    def cull(s):
        dist = s.bfs(s.starts)
        gone = set()
        for y in range(s.n):
            for x in range(s.n):
                if s.g[y][x] in PASS and (x, y) not in dist: s.g[y][x] = "#"; gone.add((x, y))
        # whatever stood in, or hung on a wall facing into, a pocket that was walled up goes with it
        keep = []
        for o in s.objs:
            c = (round(o["pos_x"]), round(o["pos_y"]))
            if o["type"] == "window" or o["type"] in MOUNTED:
                d = DIR[int(round(o["rotation"]) % 360)] if int(round(o["rotation"]) % 360) in DIR else (0, 0)
                front = (math.floor(o["pos_x"] + d[0] * 0.5 + 0.5), math.floor(o["pos_y"] + d[1] * 0.5 + 0.5))
                if s.at(*front) != "." or s.at(front[0] - d[0], front[1] - d[1]) != "#": continue
            elif o["type"].startswith(("prop_", "trigger", "column", "pillar", "half_wall") + FREE_LAMPS) and (c in gone or s.at(*c) == "#"):
                continue
            keep.append(o)
        s.objs = keep
        return dist


class Level:
    def __init__(s, fid, name, n, seed, floors=(0,)):
        s.fid, s.name, s.n = fid, name, n
        s.r = random.Random(seed)
        s.f = {k: F(n, s.r) for k in floors}

    def stairs(s, a, b, x, y, rot, style="carpet", light="on", front_room=True):
        """a stairwell from floor a up to floor b (b = a + 1), the same cells on both"""
        d = DIR[int(rot)]
        left = (d[1], -d[0])
        fp = [(x + d[0] * i + left[0] * j, y + d[1] * i + left[1] * j) for i in range(3) for j in range(2)]
        front = (x - d[0], y - d[1])
        for k, typ in ((a, "stairs_up"), (b, "stairs_down")):
            f = s.f[k]
            for c in fp:
                assert f.ok(*c), (s.fid, c)
                f.g[c[1]][c[0]] = "#"
            f.stair_cells.update(fp)
            if front_room:
                for i in range(1, 3):
                    for j in (-1, 0, 1):
                        c = (front[0] - d[0] * (i - 1) + left[0] * j, front[1] - d[1] * (i - 1) + left[1] * j)
                        if c not in fp: f.put(*c)
            f.put(*front)
            f.reserved.update({front, (front[0] - d[0], front[1] - d[1])}); f.noexit.add(front)
            f.starts.append(front)
            f.obj(typ, x, y, rot, 1.0, style=style, light=light, rail=True, sign=True)

    def build(s, spawn, atmosphere="dim", lights="panels", materials=None, exit_floor=0, extra=None,
              entity=True, intro="", spawn_rot=None):
        LIGHTING.get(s.fid, lambda L: None)(s)
        lights = LIGHT_MODE.get(s.fid, lights)
        f0 = s.f[0]
        f0.starts.insert(0, spawn)
        dists = {}
        for k, f in s.f.items():
            dists[k] = f.cull()
            for k2 in f.z: f.z[k2] = {c for c in f.z[k2] if f.ok(*c) and f.g[c[1]][c[0]] != "#"}
        assert f0.open(*spawn), (s.fid, "spawn walled")
        # exit: the far end of its floor, on a cell with a wall to hang the door on
        fe = s.f[exit_floor]
        de = dists[exit_floor]
        far = sorted([c for c in de if fe.g[c[1]][c[0]] == "." and c not in fe.reserved and c not in fe.noexit
                      and c not in fe.z["safe"]], key=lambda c: -de[c])
        exitc = next((c for c in far if fe.nwalls(*c) >= 2), None) or next((c for c in far if fe.nwalls(*c) >= 1), None) or far[0]
        fe.objs = [o for o in fe.objs if not (o["type"].startswith("prop_") and abs(o["pos_x"] - exitc[0]) < 1.2 and abs(o["pos_y"] - exitc[1]) < 1.2)]
        # spawn: no props on it, facing down the longest way out
        f0.objs = [o for o in f0.objs if not (o["type"].startswith(("prop_", "pillar", "column") + FREE_LAMPS) and abs(o["pos_x"] - spawn[0]) < 1.0 and abs(o["pos_y"] - spawn[1]) < 1.0)]
        if spawn_rot is None:
            best = (0, 0.0)
            for d in DIRS:
                k = 0
                while f0.open(spawn[0] + d[0] * (k + 1), spawn[1] + d[1] * (k + 1)): k += 1
                if k > best[0]: best = (k, rot_of(*d))
            spawn_rot = best[1]
        # intro caption a step or two in
        if intro:
            d0 = dists[0]
            near = [c for c in d0 if 1 <= d0[c] <= 2] or [spawn]
            c = near[0]
            f0.trigger(c[0], c[1], "message", intro, scale=3.0, depth=3.0)
        out = {"format": "backrooms_level", "version": 2, "name": s.name, "size": s.n,
               "atmosphere": atmosphere, "lights": lights, "materials": materials or {}, "drop_hole": None}
        for k, f in s.f.items():
            d = dists[k]
            ent = None
            if entity:
                mx = max(d.values())
                mid = [c for c in d if mx * 0.4 < d[c] < mx * 0.8 and c not in f.z["safe"] and f.g[c[1]][c[0]] == "."]
                if mid: ent = list(s.r.choice(mid))
            fd = {"grid": ["".join(r) for r in f.g],
                  "zones": {z: sorted([list(c) for c in v]) for z, v in f.z.items()},
                  "paint": {sl: {m: sorted([list(c) for c in cs if 0 <= c[0] < s.n and 0 <= c[1] < s.n]) for m, cs in mp.items()} for sl, mp in f.paint.items() if mp},
                  "objects": [o for o in f.objs if 0 < o["pos_x"] < s.n - 1 and 0 < o["pos_y"] < s.n - 1],
                  "spawn": list(spawn) if k == 0 else None,
                  "exit": list(exitc) if k == exit_floor else None,
                  "entity": ent, "tv": None}
            if k == 0:
                out.update(fd)
                out["spawn_rot"] = spawn_rot
            else:
                out.setdefault("floors", {})[str(k)] = fd
        if extra: out.update(extra)
        with open(os.path.join(LV, s.fid + ".lvl"), "w") as fh:
            json.dump(out, fh, indent=1)
        OUT.append({"file": s.fid + ".lvl", "id": s.fid, "name": s.name})
        return out


OUT = []


# ------------------------------------------------------------ layout helpers
def maze(f, x0, y0, x1, y1, braid=0.0, step=2):
    cols = list(range(x0, x1 + 1, step)); rows = list(range(y0, y1 + 1, step))
    start = (cols[0], rows[0])
    seen = {start}; stack = [start]
    f.put(*start)
    while stack:
        x, y = stack[-1]
        nb = [(x + dx * step, y + dy * step) for dx, dy in DIRS
              if x0 <= x + dx * step <= x1 and y0 <= y + dy * step <= y1 and (x + dx * step, y + dy * step) not in seen]
        if not nb: stack.pop(); continue
        n = f.r.choice(nb); seen.add(n)
        for t in range(step + 1):
            f.put(x + (n[0] - x) * t // step, y + (n[1] - y) * t // step)
        stack.append(n)
    for x in cols:
        for y in rows:
            for dx, dy in ((1, 0), (0, 1)):
                if x + dx * step <= x1 and y + dy * step <= y1 and f.r.random() < braid:
                    for t in range(step + 1): f.put(x + dx * t, y + dy * t)


def rooms_and_halls(f, n, wmin, wmax, hmin, hmax, hw=1, tries=600, gap=2, margin=2, tag=""):
    for _ in range(tries):
        if len(f.rooms) >= n: break
        w, h = f.r.randint(wmin, wmax), f.r.randint(hmin, hmax)
        x, y = f.r.randint(margin, f.n - w - margin - 1), f.r.randint(margin, f.n - h - margin - 1)
        if any(x < rx + rw + gap and rx < x + w + gap and y < ry + rh + gap and ry < y + h + gap for rx, ry, rw, rh, _ in f.rooms): continue
        f.room(x, y, w, h, tag)
    rs = f.rooms[:]
    order = sorted(rs, key=lambda r: (r[0] // 12, r[1]))
    for a, b in zip(order, order[1:]):
        f.hall(a[0] + a[2] // 2, a[1] + a[3] // 2, b[0] + b[2] // 2, b[1] + b[3] // 2, hw)
    for _ in range(max(2, len(rs) // 3)):
        a, b = f.r.sample(rs, 2)
        f.hall(a[0] + a[2] // 2, a[1] + a[3] // 2, b[0] + b[2] // 2, b[1] + b[3] // 2, hw)


def oct_pts(rx, ry, cut=0.35):
    """an octagon (a rectangle with its corners cut) round the origin, cells"""
    cx, cy = rx * cut, ry * cut
    return [(-rx + cx, -ry), (rx - cx, -ry), (rx, -ry + cy), (rx, ry - cy), (rx - cx, ry), (-rx + cx, ry), (-rx, ry - cy), (-rx, -ry + cy)]


def blob(r, rx, ry, n=10, wobble=0.25):
    return [(math.cos(2 * math.pi * i / n) * rx * (1 + r.uniform(-wobble, wobble)),
             math.sin(2 * math.pi * i / n) * ry * (1 + r.uniform(-wobble, wobble))) for i in range(n)]


# ============================================================ LEVEL 0.2: RENOVATED LOBBY
def level_0_2():
    L = Level("level_0_2_renovated_lobby", "Level 0.2: Renovated Lobby", 51, 2002)
    f = L.f[0]
    f.rect(1, 1, 49, 49)
    # the Lobby's mono-yellow maze, but denser and darker: wall stubs, broken partitions, pillars
    for _ in range(260):
        x, y = f.r.randint(2, 48), f.r.randint(2, 48)
        if f.r.random() < 0.5: f.rect(x, y, min(48, x + f.r.randint(1, 5)), y, "#")
        else: f.rect(x, y, x, min(48, y + f.r.randint(1, 5)), "#")
    for _ in range(60):   # thin partitions on the cell lines
        x, y = f.r.randint(2, 48), f.r.randint(2, 48)
        if f.r.random() < 0.5: f.obj("thin_wall", x + 0.5, y, 0.0, f.r.choice([1.0, 2.0]), thick=0.2, height=0.0)
        else: f.obj("thin_wall", x, y + 0.5, 90.0, f.r.choice([1.0, 2.0]), thick=0.2, height=0.0)
    for _ in range(14):
        x, y = f.r.randint(3, 47), f.r.randint(3, 47)
        f.obj("wall_corner", x + 0.5, y + 0.5, f.r.choice([0, 90, 180, 270]), 1.5, thick=0.25, height=0.0)
    for c in f.r.sample(f.cells(), 30): f.obj("column", c[0], c[1], 0.0, 1.0, thick=0.45, height=0.0)
    f.tag_some("dim", 0.45); f.tag_some("flicker", 0.25); f.tag_some("dark", 0.08); f.tag_some("grime", 0.3)
    f.tag_some("low", 0.06)
    f.paint_cells("floor", "Carpet_Grey", f.r.sample(f.cells(), 200))
    f.mount(["prop_exit_sign"], 4, spacing=14)
    f.props(["prop_electrical_box2", "prop_work_light"], 6)
    f.scares(8, ["flicker", "thump", "lights_out", "wallKnock", "breathBehind", "machineVoice"])
    L.build((3, 3), atmosphere="dim", lights="panels",
            materials={"wall": "Wallpaper_Yellow_Chevron_03", "floor": "Carpet_Yellow_Green", "ceiling": "Ceiling_Drop_Long"},
            intro="LEVEL 0.2 - THE RENOVATED LOBBY. Someone has been working on the Lobby. The lights are fewer, the walls closer. Keep your head down.")


# ============================================================ LEVEL 1: HABITABLE ZONE
def level_1():
    L = Level("level_1_habitable_zone", "Level 1: The Habitable Zone", 61, 1001)
    f = L.f[0]
    rooms_and_halls(f, 9, 12, 18, 11, 16, hw=2)
    for i, rm in enumerate(f.rooms):
        x0, y0, w, h, _ = rm
        f.tag_room("grand", rm); f.tag_room("hall_reverb", rm, 2)
        f.mezzanine(rm, elev=5.4, surface="concrete", edge="parapet", side="w" if i % 2 else "e") if i % 3 != 2 else None
        # storage racks: tall shelving rows with aisles between, concrete columns on a grid
        for ry in range(y0 + 3, y0 + h - 3, 3):
            if f.r.random() < 0.7:
                f.obj("thin_wall", x0 + w / 2 - 0.5, ry, 90.0, max(2.0, w - 7), thick=0.7, height=3.2)
        for px in range(x0 + 2, x0 + w - 1, 5):
            for py in (y0 + 1, y0 + h - 2):
                f.obj("pillar", px, py + (0.4 if py == y0 + 1 else -0.4) * 0, 0.0, 1.0, thick=0.8, height=0.0)
        f.props(["prop_pallet_truck", "prop_platform_trolley", "prop_water_barrel", "prop_gas_can", "prop_cable_drum",
                 "prop_explosive_barrel", "prop_gas_cylinder", "prop_car_jack"], 6, pred=f.in_room(rm))
        if i % 3 == 0: f.tag_room("loot", rm, 2)
        # clerestory windows high up the grand walls, grey daylight that comes from nowhere
        f.windows(2, pred=f.in_room(rm), frame="pane", sky="overcast", scale=0.8, elev=9.0, height=3.0, sun=4.0, panes=4, spacing=6)
    f.corridor_doors(0.35)
    f.tag_some("flicker", 0.2); f.tag_some("dim", 0.15); f.tag_some("grime", 0.4)
    f.puddles(14, level=0.05)
    f.paint_cells("floor", "Asphalt_Dark", [c for c in f.cells() if not any(f.in_room(r)(*c) for r in f.rooms)])
    f.mount(["prop_exit_sign_medium", "prop_exit_sign"], 7, spacing=12)
    f.props(["prop_work_light2", "prop_work_light"], 10)
    s = f.rooms[0]
    f.tag_rect("safe", s[0], s[1], 4, 4)
    f.scares(7, ["thump", "lights_out", "drone", "wallKnock", "flicker", "static"])
    L.build((s[0] + 1, s[1] + 1), atmosphere="dim", lights="troffers",
            materials={"wall": "Brick_Stone_Wall", "floor": "Metal_Grey_Plate", "ceiling": "Metal_Dark_Plate"},
            intro="LEVEL 1 - THE HABITABLE ZONE. Concrete, fog and fluorescent light. Crates of supplies turn up here. It is as close to safe as the Backrooms get.")


# ============================================================ LEVEL 2: PIPE DREAMS
def level_2():
    L = Level("level_2_pipe_dreams", "Level 2: Pipe Dreams", 51, 1002)
    f = L.f[0]
    maze(f, 1, 1, 49, 49, braid=0.14, step=2)
    for _ in range(4):   # boiler rooms: the only places to stand up straight
        x, y = f.r.randrange(5, 40, 2), f.r.randrange(5, 40, 2)
        rm = f.room(x, y, 5, 5, "boiler")
        f.tag_room("tall", rm)
        f.obj("column", x + 2, y + 2, 0.0, 1.0, thick=1.6, height=0.0)   # the boiler drum
    cs = f.cells(lambda x, y: (x, y) not in f.z["tall"])
    f.tag("low", [c for c in cs if f.r.random() < 0.55])
    for _ in range(8):
        c = f.r.choice(cs)
        f.tag("crawl", [(c[0] + k, c[1]) for k in range(-2, 3)] + [(c[0], c[1] + k) for k in range(-2, 3)])
    f.tag_all("grime"); f.tag_some("flicker", 0.35); f.tag_some("dark", 0.25); f.tag_some("muffled", 0.1); f.tag_some("echo", 0.06)
    # pipes: thin vertical runs hugging the walls, in clusters
    for (x, y) in f.cells():
        if f.r.random() < 0.16:
            ws = [d for d in DIRS if f.wallc(x + d[0], y + d[1])]
            if ws:
                d = f.r.choice(ws)
                for k in range(f.r.randint(1, 3)):
                    off = (k - 1) * 0.18
                    f.obj("column", x + d[0] * 0.38 + d[1] * off, y + d[1] * 0.38 + d[0] * off, 0.0, 1.0, thick=0.16 + 0.06 * f.r.random(), height=0.0)
    f.squeeze_gaps(6)
    f.puddles(12, level=0.08, tint="murky")
    f.paint_cells("wall", "Metal_Dark_Plate", [(x, y) for y in range(f.n) for x in range(f.n) if f.r.random() < 0.3])
    f.paint_cells("floor", "Metal_Rusted", f.r.sample(f.cells(), 150))
    f.props(["prop_electrical_box", "prop_electrical_box2", "prop_gas_cylinder", "prop_cable_drum"], 16)
    f.scares(8, ["wallKnock", "thump", "drone", "breathBehind", "camera_shake", "silence"])
    L.build((1, 1), atmosphere="dim", lights="troffers",
            materials={"wall": "Metal_Rusted", "floor": "Metal_Dark_Plate", "ceiling": "Metal_Rusted"},
            intro="LEVEL 2 - PIPE DREAMS. Hot, narrow maintenance tunnels. Pipes hiss and knock in the walls. The heat is the least of your problems.")


# ============================================================ LEVEL 3: ELECTRICAL STATION (2 floors)
def level_3():
    L = Level("level_3_electrical_station", "Level 3: Electrical Station", 51, 1003, floors=(0, 1))
    f, u = L.f[0], L.f[1]
    rooms_and_halls(f, 7, 9, 14, 8, 12, hw=1)
    for rm in f.rooms:
        x0, y0, w, h, _ = rm
        for px in range(x0 + 2, x0 + w - 2, 3):          # transformer banks with a service aisle between
            f.obj("pillar", px, y0 + 2, 0.0, 1.0, thick=1.4, height=3.0)
            f.obj("pillar", px, y0 + h - 3, 0.0, 1.0, thick=1.4, height=3.0)
        f.props(["prop_electrical_box", "prop_electrical_box2", "prop_cable_drum"], 4, pred=f.in_room(rm))
        f.tag_room("tall", rm); f.tag_room("hall_reverb", rm, 1)
        if f.r.random() < 0.4: f.tag_room("dark", rm)
    f.corridor_doors(0.6)
    f.tag_some("flicker", 0.45); f.tag_some("grime", 0.3)
    # upstairs: the control level, a tight catwalk maze round a control room with a view
    maze(u, 3, 3, 47, 47, braid=0.2, step=4)
    ctrl = u.room(30, 30, 9, 7, "control")
    u.tag_room("liminal", ctrl)
    u.windows(4, pred=u.in_room(ctrl), exterior=False, frame="panorama", sky="overcast", scale=0.9, elev=1.0, height=3.2, sun=3.0, panes=5)
    for k in range(3): u.obj("half_wall", 32 + 2 * k, 33, 0.0, 1.5, thick=0.6, height=1.1)   # consoles
    u.tag_some("flicker", 0.4); u.tag_some("dark", 0.2); u.tag_some("drain", 0.08)
    r0 = f.rooms[0]
    L.stairs(0, 1, r0[0] + r0[2] - 4, r0[1] + 2, 180, style="concrete", light="flicker")
    u.hall(r0[0] + r0[2] - 4, r0[1] + 2, 35, 33, 1)
    for fl in (f, u):
        fl.mount(["prop_exit_sign"], 4, spacing=12)
        fl.props(["prop_work_light2"], 5)
    f.scares(5, ["powerCut", "lights_out", "flicker", "emergencyPulse", "static"])
    u.scares(5, ["powerCut", "redAlert", "deadAir", "machineVoice"])
    L.build((r0[0] + 1, r0[1] + 1), atmosphere="dim", lights="troffers", exit_floor=1,
            materials={"wall": "Metal_Grey_Plate", "floor": "Metal_Dark_Plate", "ceiling": "Ceiling_Light_Panels"},
            intro="LEVEL 3 - ELECTRICAL STATION. The machinery here powers more of the Backrooms than it should. When the power goes, so does everything else. Get to the control room upstairs.")


# ============================================================ LEVEL 4: ABANDONED OFFICE (2 floors)
def office_floor(f, seed_shift=0):
    n = f.n
    # north + south bands of private offices with windows to the outside, corridors, an open-plan floor between
    for k in range(7):
        x0 = 2 + 6 * k
        f.room(x0, 2, 5, 4, "office"); f.door_at(x0 + 2, 6)
        f.room(x0, n - 6, 5, 4, "office"); f.door_at(x0 + 2, n - 7)
    f.rect(2, 7, n - 3, 8); f.rect(2, n - 9, n - 3, n - 8)
    farm = f.room(2, 10, n - 4, n - 20, "farm")
    for x in range(2, n - 2):
        if x % 8 not in (0, 1): f.put(x, 9, "#"); f.put(x, n - 10, "#")
        else: f.put(x, 9); f.put(x, n - 10)
    return farm


def level_4():
    L = Level("level_4_abandoned_office", "Level 4: Abandoned Office", 45, 1004, floors=(0, 1))
    for k, f in L.f.items():
        farm = office_floor(f)
        x0, y0, w, h, _ = farm
        # cubicle pods: low partitions you see over, desks inside
        for cy in range(y0 + 2, y0 + h - 2, 5):
            for cx in range(x0 + 6, x0 + w - 3, 6):
                f.obj("half_wall", cx, cy + 1.0, 0.0, 3.0, thick=0.12, height=1.4)
                f.obj("half_wall", cx + 1.5, cy, 90.0, 3.0, thick=0.12, height=1.4)
                f.obj("half_wall", cx - 0.8, cy - 0.6, 90.0, 0.6, thick=0.7, height=0.75)    # desk
        for px in range(x0 + 4, x0 + w, 9):
            for py in range(y0 + 4, y0 + h, 8): f.obj("pillar", px, py, 0.0, 1.0, thick=0.7, height=0.0)
        if k == 0:
            br = (x0 + w - 8, y0 + h - 6, 7, 5, "break")
            f.paint_room("floor", "Tile_Checker_Marble", br); f.tag_room("tiles", br)
            f.obj("half_wall", br[0] + 3, br[1] + 2, 90.0, 3.0, thick=0.7, height=0.95)   # break-room counter
        else:
            conf = (x0 + w - 12, y0 + 2, 10, 6, "conference")
            f.obj("thin_wall", conf[0] - 0.5, conf[1] + 2.5, 0.0, 6.0, thick=0.15, height=0.0)
            f.obj("half_wall", conf[0] + 4.5, conf[1] + 2.5, 90.0, 5.0, thick=1.1, height=0.78)   # boardroom table
            f.paint_room("floor", "Wood_Floor_Parquet_Dark", conf)
        for rm in f.rooms:
            if rm[4] == "office":
                f.paint_room("floor", "Carpet_Yellow_Green" if k else "Fabric_Blue", rm)
                f.obj("half_wall", rm[0] + 2, rm[1] + 1.6, 90.0, 0.7, thick=0.8, height=0.76)   # office desk
        f.windows(14, pred=lambda x, y, f=f: y < 6 or y > f.n - 7, frame="pane", sky="overcast", scale=0.6, elev=0.9, height=2.2, sun=3.0, panes=3, spacing=5)
        f.windows(4, pred=lambda x, y: x <= 3 or x >= 41, frame="panorama", sky="overcast", scale=0.8, elev=0.4, height=3.4, sun=3.0, panes=4, spacing=8)
        f.tag_some("flicker", 0.18); f.tag_some("dim", 0.12); f.tag_some("drain", 0.04)
        f.mount(["prop_exit_sign"], 4, spacing=12)
        f.props(["prop_platform_trolley", "prop_electrical_box2", "prop_work_light"], 5)
        f.scares(4, ["static", "oneLamp", "machineVoice", "hallucination", "flicker"])
    L.stairs(0, 1, 4, 13, 0, style="carpet")
    L.stairs(0, 1, 38, 31, 180, style="carpet", light="flicker")
    L.build((4, 7), atmosphere="liminal", lights="panels", exit_floor=1,
            materials={"wall": "Wallpaper_Pale_Green", "floor": "Carpet_Grey", "ceiling": "Ceiling_Drop_Square"},
            intro="LEVEL 4 - ABANDONED OFFICE. Cubicles, water coolers, grey daylight in the windows. No one has worked here for a long time. The exit is upstairs.")


# ============================================================ LEVEL 5: TERROR HOTEL (endless)
def level_5():
    n = 51
    L = Level("level_5_terror_hotel", "Level 5: Terror Hotel", n, 1005, floors=(0, 1))
    f, u = L.f[0], L.f[1]
    # ground floor: a grand lobby with a gallery, a reception desk and corridors off it
    lobby = f.room(15, 15, 21, 15, "lobby")
    f.tag_room("grand", lobby); f.tag_room("hall_reverb", lobby)
    f.mezzanine(lobby, elev=5.4, surface="floor", edge="chrome", side="w")
    f.mezzanine(lobby, elev=5.4, surface="floor", edge="chrome", side="e")
    f.obj("half_wall", 25, 18, 90.0, 6.0, thick=0.9, height=1.15)        # the reception desk
    for py in (20, 25):
        for px in (20, 30): f.obj("column", px, py, 0.0, 1.0, thick=0.9, height=0.0)
    f.paint_cells("floor", "Tile_Checker_Marble", [(x, y) for x in range(15, 36) for y in range(15, 30)])
    f.tag_rect("tiles", 15, 15, 21, 15)
    f.windows(6, pred=f.in_room(lobby), exterior=False, frame="arched", sky="golden", scale=0.6, elev=1.2, height=4.5, sun=5.0, panes=3, spacing=5)
    f.rect(25, 30, 26, 40); f.rect(4, 40, 46, 41); f.rect(25, 5, 26, 15); f.rect(4, 5, 46, 6)
    f.rect(4, 5, 5, 41); f.rect(45, 5, 46, 41)
    # guest floor (repeats upward forever): three corridors, rooms off both sides
    for cx in (8, 25, 42):
        u.rect(cx - 1, 3, cx + 1, n - 4)
    u.rect(3, 3, n - 4, 5); u.rect(3, n - 6, n - 4, n - 4)
    rooms = []
    for cx in (8, 25, 42):
        for y in range(7, n - 10, 5):
            for side in (-1, 1):
                rx = cx + 3 if side > 0 else cx - 7
                if not (1 < rx and rx + 4 < n - 1): continue
                if any(u.at(xx, yy) != "#" for yy in range(y - 1, y + 5) for xx in range(rx - 1, rx + 6) if not (cx - 1 <= xx <= cx + 1)): continue
                rm = u.room(rx, y, 5, 4, "guest")
                u.door_at(cx + 2 if side > 0 else cx - 2, y + 1)
                rooms.append(rm)
    for i, rm in enumerate(rooms):
        u.paint_room("floor", "Carpet_Grey" if i % 3 else "Wood_Floor_Planks", rm)
        u.obj("half_wall", rm[0] + 2, rm[1] + 2, 0.0, 1.1, thick=1.6, height=0.6)       # the bed
        u.windows(1, pred=u.in_room(rm), exterior=False, frame="pane", sky="golden", scale=0.45, elev=0.9, height=2.0, sun=4.0, panes=2, spacing=3)
        if i % 4 == 0: u.tag_room("dim", rm)
        if i % 7 == 3: u.tag_room("mannequin", rm)
        if i % 5 == 1: u.tag_room("loot", rm)
    u.tag_some("flicker", 0.18); u.tag_some("muffled", 0.2)
    L.stairs(0, 1, 6, 9, 90, style="carpet")
    L.stairs(0, 1, 44, 9, 90, style="carpet", light="flicker")
    for fl in (f, u):
        fl.mount(["prop_exit_sign"], 3, spacing=14)
        fl.props(["prop_platform_trolley"], 3)
    u.scares(8, ["wallKnock", "preacherWhisper", "breathBehind", "thump", "flicker", "hallucination"])
    f.scares(3, ["silence", "drone"])
    L.build((25, 27), atmosphere="dim", lights="panels", exit_floor=1, extra={"endless": True},
            materials={"wall": "Wallpaper_Yellow_Stripe", "floor": "Carpet_Yellow_Green", "ceiling": "Wood_Dark_Brown"},
            intro="LEVEL 5 - TERROR HOTEL. A grand hotel whose stairs never end. The rooms are not empty. Don't open a door that knocks back.")


# ============================================================ LEVEL 6: LIGHTS OUT
def level_6():
    L = Level("level_6_lights_out", "Level 6: Lights Out", 51, 1006)
    f = L.f[0]
    maze(f, 1, 1, 49, 49, braid=0.2, step=2)
    for _ in range(6):
        x, y = f.r.randrange(4, 42, 2), f.r.randrange(4, 42, 2)
        rm = f.room(x, y, 5, 5)
        f.obj("wall_curve", x + 2, y + 2, f.r.choice([0, 90, 180, 270]), 2.4, thick=0.25, height=0.0, arc=200.0)
    f.tag_all("dark"); f.tag_some("muffled", 0.08); f.tag_some("echo", 0.06)
    lit = f.r.sample(f.cells(), 6)
    for c in lit:
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                f.z["dark"].discard((c[0] + dx, c[1] + dy)); f.z["dim"].add((c[0] + dx, c[1] + dy))
        f.z["safe"].add(c); f.z["loot"].add(c)
    f.paint_cells("wall", "Tile_Black_Grid", [(x, y) for y in range(f.n) for x in range(f.n) if f.r.random() < 0.25])
    f.props(["prop_work_light2"], 6, pred=lambda x, y: (x, y) in f.z["dim"])
    f.squeeze_gaps(3)
    f.scares(10, ["lightsOut", "oneLamp", "deadAir", "breathBehind", "hallucination", "machineVoice", "sanity_drain"])
    L.build((1, 1), atmosphere="dim", lights="none",
            materials={"wall": "Tile_Grimy_Grey", "floor": "Tile_Dark_Slate", "ceiling": "Tile_Black_Dotted"},
            intro="LEVEL 6 - LIGHTS OUT. No light at all. Your torch is everything. Things move in the dark here that do not like being seen.")


# ============================================================ LEVEL 7: THALASSOPHOBIA
def level_7():
    n = 51
    L = Level("level_7_thalassophobia", "Level 7: Thalassophobia", n, 1007)
    f = L.f[0]
    # a lone dry room with a door, and beyond it the sea
    start = f.room(3, 3, 6, 5, "room")
    f.door_at(9, 5)
    sea = f.room(10, 2, n - 12, n - 4, "sea")
    f.tag_room("grand", sea); f.tag_room("hall_reverb", sea); f.tag_room("echo", sea)
    f.windows(3, pred=f.in_room(start), exterior=False, frame="porthole", sky="noon", scale=0.4, elev=1.4, height=1.8, sun=5.0, panes=1)
    f.paint_room("floor", "Wood_Dark_Grain", start)
    f.paint_cells("wall", "Wallpaper_Pale_Green", [(x, y) for x in range(2, 10) for y in range(2, 9)])
    islands = [(13, 4, 5, 4), (24, 9, 6, 5), (38, 4, 7, 6), (14, 22, 6, 6), (30, 24, 7, 7), (41, 34, 6, 7), (19, 40, 7, 5)]
    shoal = set()
    for a, b in zip(islands, islands[1:]):
        ax, ay = a[0] + a[2] // 2, a[1] + a[3] // 2; bx, by = b[0] + b[2] // 2, b[1] + b[3] // 2
        x, y = ax, ay
        while (x, y) != (bx, by):
            if x != bx and (y == by or f.r.random() < 0.5): x += 1 if bx > x else -1
            else: y += 1 if by > y else -1
            shoal.add((x, y))
    shoal |= {(x, 5) for x in range(10, 14)}
    dry = {(x, y) for (ix, iy, w, h) in islands for x in range(ix, ix + w) for y in range(iy, iy + h)}
    def level_of(x, y):
        if not sea_in(x, y) or (x, y) in dry: return None
        return 0.55 if (x, y) in shoal else 3.6
    sea_in = f.in_room(sea)
    f.water_map(level_of)
    for (ix, iy, w, h) in islands:
        f.obj("platform", ix + (w - 1) / 2, iy + (h - 1) / 2, 0.0, h - 1.0, depth=w - 1.0, elev=0.45, slab=0.45, edge="none", posts=False, surface="concrete")
        f.obj("column", ix, iy, 0.0, 1.0, thick=0.35, height=0.0)
    f.obj("stair_spiral", 33, 27, 0.0, 2.0, elev=0.45, rise=8.0, sweep=540.0, core=0.6, turn="left", rail=True, surface="concrete")
    f.obj("platform", 31, 27, 0.0, 2.0, depth=2.0, elev=8.45, slab=0.35, edge="chrome", posts=True, surface="concrete")   # lookout
    f.props(["prop_water_barrel", "prop_gas_can"], 6, pred=lambda x, y: (x, y) in dry, wall=False)
    f.tag("loot", [c for c in dry if f.r.random() < 0.05]); f.tag_room("safe", start)
    for (ix, iy, w, h) in islands[1:]:
        f.trigger(ix + w // 2, iy + h // 2, f.r.choice(["drone", "sanity_drain", "silence", "camera_shake", "hallucination"]), scale=3.0)
    L.build((5, 5), atmosphere="liminal", lights="none",
            materials={"wall": "Tile_Aqua_Mosaic", "floor": "Ground_Sand", "ceiling": "Tile_Blue_Grime_Grid"},
            intro="LEVEL 7 - THALASSOPHOBIA. A small room, a door, and an ocean with no far shore. Keep to the shallows. Do not think about what is under you.")


# ============================================================ LEVEL 8: CAVE SYSTEM
def level_8():
    n = 61
    L = Level("level_8_cave_system", "Level 8: Cave System", n, 1008)
    f = L.f[0]
    cells = {(x, y) for x in range(1, n - 1) for y in range(1, n - 1) if f.r.random() < 0.53}
    for _ in range(5):
        cells = {(x, y) for x in range(1, n - 1) for y in range(1, n - 1)
                 if sum(1 for dx in (-1, 0, 1) for dy in (-1, 0, 1) if (x + dx, y + dy) in cells) >= 5}
    for (x, y) in cells: f.g[y][x] = "."
    best, seen = [], set()
    for c in sorted(cells):
        if c in seen: continue
        comp = f.bfs([c]); seen |= set(comp)
        if len(comp) > len(best): best = list(comp)
    keep = set(best)
    for (x, y) in cells:
        if (x, y) not in keep: f.g[y][x] = "#"
    cs = f.cells()
    for c in cs:
        k = sum(1 for dx in range(-2, 3) for dy in range(-2, 3) if f.open(c[0] + dx, c[1] + dy))
        if k >= 24: f.z["grand"].add(c)
        elif k >= 18: f.z["tall"].add(c)
        elif k <= 11: f.z["low"].add(c)
    f.tag_all("echo"); f.tag_all("grime"); f.tag_some("crawl", 0.02)
    f.tag("dark", [c for c in cs if c[0] + c[1] > 45])
    # rock: boulders (closed spline walls), stalagmites, sinter pools
    for c in f.r.sample([c for c in cs if c in f.z["grand"]], 10):
        pts = blob(f.r, 0.9, 0.7, 7, 0.3)
        f.obj("wall_spline", c[0], c[1], f.r.uniform(0, 360), 1.0, thick=0.5, height=f.r.choice([1.2, 2.0, 0.0]), smooth=True, closed=True, points=[[round(a, 2), round(b, 2)] for a, b in pts])
    for c in f.r.sample(cs, 40):
        f.obj("column", c[0] + f.r.uniform(-.3, .3), c[1] + f.r.uniform(-.3, .3), 0.0, 1.0, thick=f.r.uniform(0.25, 0.7), height=f.r.choice([0.0, 0.0, 1.4, 2.5]))
    f.puddles(10, pred=lambda x, y: (x, y) in f.z["tall"] or (x, y) in f.z["grand"], level=0.3, tint="clear", size=(2, 4))
    f.paint_cells("wall", "Ground_Dirt_Gravel", [(x, y) for y in range(n) for x in range(n) if f.r.random() < 0.35])
    f.props(["prop_work_light2", "prop_gas_can", "prop_cable_drum"], 6)
    f.tag("loot", f.r.sample(cs, 14))
    f.scares(9, ["silence", "thump", "drone", "breathBehind", "hallucination", "wallKnock", "camera_shake"])
    sp = min(cs, key=lambda c: c[0] + c[1])
    L.build(sp, atmosphere="dim", lights="none",
            materials={"wall": "Brick_Stone_Wall", "floor": "Ground_Sand", "ceiling": "Ground_Dirt_Gravel"},
            intro="LEVEL 8 - CAVE SYSTEM. Cold stone, dripping water and the dark. The caves go deeper than they should. Listen before you move.")


# ============================================================ LEVEL 9: THE SUBURBS
def level_9():
    n = 61
    L = Level("level_9_the_suburbs", "Level 9: The Suburbs", n, 1009)
    f = L.f[0]
    f.rect(1, 1, n - 2, n - 2)
    houses = []
    for bx in range(4, n - 10, 12):
        for by in range(4, n - 10, 12):
            for hx, hy in ((bx, by), (bx + 5, by), (bx, by + 5), (bx + 5, by + 5)):
                if f.r.random() < 0.85:
                    f.rect(hx, hy, hx + 4, hy + 4, "#"); f.rect(hx + 1, hy + 1, hx + 3, hy + 3)
                    door = f.r.choice([(hx + 2, hy), (hx + 2, hy + 4), (hx, hy + 2), (hx + 4, hy + 2)])
                    f.door_at(*door)
                    houses.append((hx + 1, hy + 1, 3, 3, "house"))
    street = set(f.cells())
    side = {c for c in street if any(f.wallc(c[0] + dx, c[1] + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1))}
    f.paint_cells("floor", "Road_Asphalt_Lines", street - side)
    f.paint_cells("floor", "Paving_Cobble_Sage", side)
    for i, h in enumerate(houses):
        f.paint_room("floor", "Wood_Floor_Planks" if i % 2 else "Carpet_Grey", h)
        f.paint_room("wall", ["Brick_Red_Wall", "Brick_Tan_Wall", "Wood_Light_Planks"][i % 3], h, walls=True)
        f.tag_room("dim", h); f.tag_room("muffled", h)
        if i % 3 == 0: f.tag_room("flicker", h)
        if i % 6 == 0: f.tag_room("loot", h)
        f.obj("thin_wall", h[0] + 1.5, h[1] + 0.5, 0.0, 1.0, thick=0.15, height=0.0)   # a partition, half a room
        f.windows(1, pred=f.in_room(h), exterior=False, frame="pane", sky="golden", scale=0.45, elev=0.9, height=1.8, sun=4.0, panes=2, sun_angle=12.0, spacing=3)
    f.tag("open_ceiling", street)
    for x in range(3, n - 2, 12):     # street corners: stop signs, lamps
        for y in range(3, n - 2, 12):
            if f.open(x, y):
                f.obj(f.r.choice(["prop_stop_sign", "prop_stop_sign_worn"]), x + 0.3, y + 0.3, f.r.choice([0, 90, 180, 270]))
                f.obj("prop_work_light", x - 0.3, y - 0.3, f.r.uniform(0, 360))
    f.tag_some("flicker", 0.04, pred=lambda x, y: (x, y) in street)
    f.scares(7, ["silence", "thump", "drone", "preacherWhisper", "breathBehind", "hallucination"], pred=lambda x, y: (x, y) in street)
    L.build((2, 2), atmosphere="dim", lights="panels", extra={"wrap": True},
            materials={"wall": "Brick_Red_Wall", "floor": "Road_Asphalt_Yellow_Lines", "ceiling": "Ceiling_Drop_Square"},
            intro="LEVEL 9 - THE SUBURBS. A town stuck at dusk, every house dark. The streets go round and round. Something watches from the windows. Don't go inside unless you must.")


# ============================================================ LEVEL 10: BUMPER CROPS
def level_10():
    n = 61
    L = Level("level_10_bumper_crops", "Level 10: Bumper Crops", n, 1010)
    f = L.f[0]
    maze(f, 2, 2, 58, 58, braid=0.3, step=3)
    snap = [r[:] for r in f.g]
    for y in range(1, n - 1):
        for x in range(1, n - 1):
            if snap[y][x] == ".": f.put(x + 1, y); f.put(x, y + 1)
    bx, by = 24, 24
    f.rect(bx - 1, by - 1, bx + 12, by + 10, "#"); f.rect(bx, by, bx + 11, by + 9)
    barn = (bx, by, 12, 10, "barn")
    f.door_at(bx + 5, by - 1); f.door_at(bx + 5, by + 10); f.door_at(bx - 1, by + 4)
    f.hall(bx + 5, 1, bx + 5, by - 2, 2); f.hall(bx + 5, by + 11, bx + 5, n - 3, 2); f.hall(1, by + 4, bx - 2, by + 4, 1)
    f.tag_room("grand", barn); f.tag_room("loot", (bx + 1, by + 1, 10, 3, "")); f.tag_room("safe", (bx, by + 6, 3, 3, ""))
    f.paint_room("floor", "Wood_Brown_Planks", barn); f.paint_room("wall", "Wood_Brown_Planks", barn, walls=True)
    f.mezzanine(barn, elev=4.5, surface="floor", edge="none", side="e")     # the hay loft
    f.windows(4, pred=f.in_room(barn), exterior=False, frame="pane", sky="noon", scale=0.5, elev=2.0, height=2.0, sun=8.0, panes=2)
    for px in range(bx + 2, bx + 9, 3): f.obj("column", px, by + 5, 0.0, 1.0, thick=0.4, height=0.0)
    f.props(["prop_platform_trolley", "prop_gas_cylinder", "prop_water_barrel", "prop_car_jack"], 6, pred=f.in_room(barn))
    field = [c for c in f.cells() if not f.in_room(barn)(*c)]
    f.tag("open_ceiling", field)
    f.tag("classic", f.cells())
    f.paint_cells("floor", "Ground_Dirt_Gravel", field)
    f.props(["prop_stop_sign_worn"], 3, pred=lambda x, y: (x, y) in set(field))
    f.scares(7, ["silence", "thump", "static", "breathBehind", "wallKnock"], pred=lambda x, y: not f.in_room(barn)(x, y))
    L.build((2, 2), atmosphere="classic", lights="none", extra={"wrap": True},
            materials={"wall": "Grass_Green", "floor": "Ground_Dirt_Gravel", "ceiling": "Wood_Brown_Planks"},
            intro="LEVEL 10 - BUMPER CROPS. Endless fields of wheat under a noon that never moves. Stay on the lanes. The barn in the middle is the only landmark.")


# ============================================================ LEVEL 11: THE ENDLESS CITY
def level_11():
    n = 61
    L = Level("level_11_endless_city", "Level 11: The Endless City", n, 1011)
    f = L.f[0]
    f.rect(1, 1, n - 2, n - 2)
    lobbies, plazas = [], []
    for bx in range(4, n - 4, 14):
        for by in range(4, n - 4, 14):
            if f.r.random() < 0.18:
                plazas.append((bx, by)); continue
            f.rect(bx, by, bx + 9, by + 9, "#")
            if f.r.random() < 0.6:     # an open lobby on the ground floor, glass to the street
                lb = f.room(bx + 1, by + 1, 8, 8, "lobby")
                f.door_at(bx + 4, by + 9); f.door_at(bx, by + 4)
                lobbies.append(lb)
    street = set(f.cells(lambda x, y: not any(f.in_room(r)(x, y) for r in lobbies)))
    curb = {c for c in street if any(f.wallc(c[0] + dx, c[1] + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1))}
    f.paint_cells("floor", "Road_Asphalt_Lines", street - curb); f.paint_cells("floor", "Paving_Mosaic_Brown", curb)
    f.tag("open_ceiling", street); f.tag("hall_reverb", street)
    for i, lb in enumerate(lobbies):
        f.tag_room("grand", lb); f.paint_room("floor", "Tile_Checker_Marble", lb); f.tag_room("tiles", lb)
        f.windows(3, pred=f.in_room(lb), exterior=False, frame="panorama", sky="overcast", scale=0.8, elev=0.3, height=5.0, sun=3.0, panes=4, spacing=4)
        f.obj("half_wall", lb[0] + 4, lb[1] + 2, 90.0, 3.0, thick=0.8, height=1.1)        # front desk
        if i % 2: f.obj("stair_spiral", lb[0] + 6, lb[1] + 5, 0.0, 2.0, elev=0.0, rise=9.0, sweep=540.0, core=0.6, turn="right", rail=True, surface="tile")
        f.tag_room("liminal", lb)
    for (px, py) in plazas:
        f.pool(px + 4.5, py + 4.5, oct_pts(2.2, 2.2), shallow=0.6, deep=1.0, tint="teal")   # fountain
        f.paint_cells("floor", "Paving_Cobble_Sage", [(x, y) for x in range(px, px + 10) for y in range(py, py + 10)])
        for k in range(4): f.obj("column", px + 4.5 + 3.6 * math.cos(k * math.pi / 2 + .78), py + 4.5 + 3.6 * math.sin(k * math.pi / 2 + .78), 0.0, 1.0, thick=0.5, height=0.0)
    f.mount(["prop_exit_sign_big", "prop_exit_sign_medium"], 3, spacing=20)
    for x in range(2, n - 2, 14):
        for y in range(2, n - 2, 14):
            if f.open(x, y): f.obj(f.r.choice(["prop_stop_sign", "prop_stop_sign_tyro"]), x, y, f.r.choice([0, 90, 180, 270]))
    f.props(["prop_work_light", "prop_gas_can", "prop_platform_trolley"], 8, pred=lambda x, y: (x, y) in street)
    f.scares(7, ["silence", "drone", "preacherWhisper", "thump", "machineVoice"])
    L.build((2, 2), atmosphere="liminal", lights="panels", extra={"wrap": True},
            materials={"wall": "Brick_Stone_Wall", "floor": "Road_Asphalt_Lines", "ceiling": "Ceiling_Light_Panels"},
            intro="LEVEL 11 - THE ENDLESS CITY. Towers without end, streets without people. The lobbies are lit for no one. The city goes on in every direction.")


# ============================================================ LEVEL 13: THE INFINITE APARTMENTS (endless)
def apartment_floor(f):
    n = f.n
    f.rect(3, 10, n - 4, 12); f.rect(3, n - 13, n - 4, n - 11)    # two long corridors ...
    f.rect(3, 10, 5, n - 11); f.rect(n - 6, 10, n - 4, n - 11)     # ... joined at the ends into a loop
    units = []
    for cy, side in ((10, -1), (12, 1), (n - 13, -1), (n - 11, 1)):
        for x0 in range(7, n - 12, 7):
            y0 = cy - 7 if side < 0 else cy + 2
            if not (1 < y0 and y0 + 5 < n - 1): continue
            if any(f.at(xx, yy) != "#" for xx in range(x0 - 1, x0 + 7) for yy in range(y0 - 1, y0 + 6)): continue
            rm = f.room(x0, y0, 6, 5, "unit")
            f.door_at(x0 + 1, cy - 1 if side < 0 else cy + 1)
            units.append((rm, side))
    for i, (rm, side) in enumerate(units):
        x0, y0, w, h, _ = rm
        # living room + kitchen split by a thin wall with a gap, bedroom through an arch
        f.obj("thin_wall", x0 + 2.5, y0 + 1.0 if side > 0 else y0 + 3.0, 0.0, 3.0, thick=0.15, height=0.0)
        kitchen = [(x, y) for x in range(x0 + 3, x0 + 6) for y in range(y0, y0 + h)]
        f.paint_cells("floor", "Tile_Hex_Terracotta" if i % 2 else "Tile_Checker_Marble", kitchen); f.tag("tiles", kitchen)
        f.paint_cells("floor", "Wood_Floor_Parquet_Dark", [(x, y) for x in range(x0, x0 + 3) for y in range(y0, y0 + h)])
        f.obj("half_wall", x0 + 4.5, y0 + 2, 0.0, 2.0, thick=0.7, height=0.95)          # kitchen counter
        f.windows(2, pred=f.in_room(rm), exterior=False, frame="pane", sky=["golden", "overcast"][i % 2], scale=0.5, elev=0.9, height=2.0, sun=4.0, panes=2, spacing=3)
        if i % 3 == 0: f.tag_room("dim", rm)
        if i % 5 == 0: f.tag_room("loot", rm, 1)
        f.tag_room("muffled", rm)
    corridor = [c for c in f.cells() if not any(f.in_room(r[0])(*c) for r in units)]
    f.paint_cells("floor", "Carpet_Grey", corridor)
    f.tag("flicker", [c for c in corridor if f.r.random() < 0.2])
    return units


def level_13():
    n = 51
    L = Level("level_13_infinite_apartments", "Level 13: The Infinite Apartments", n, 1013, floors=(0, 1))
    for f in L.f.values():
        apartment_floor(f)
        f.mount(["prop_exit_sign"], 3, spacing=14)
        f.props(["prop_platform_trolley", "prop_electrical_box2"], 3)
        f.scares(5, ["wallKnock", "thump", "breathBehind", "preacherWhisper", "hallucination"])
    L.stairs(0, 1, 4, 20, 90, style="carpet")
    L.stairs(0, 1, n - 5, 26, 270, style="carpet", light="flicker")
    L.build((4, 11), atmosphere="dim", lights="panels", exit_floor=1, extra={"endless": True},
            materials={"wall": "Wallpaper_Pale_Green", "floor": "Carpet_Grey", "ceiling": "Ceiling_Drop_Square"},
            intro="LEVEL 13 - THE INFINITE APARTMENTS. Hallway after hallway of identical flats, floor after floor. Some doors are unlocked. Some of the tenants are still home.")


# ============================================================ LEVEL 37: THE POOLROOMS
def level_37():
    n = 55
    L = Level("level_37_poolrooms", "Level 37: The Poolrooms", n, 1037)
    f = L.f[0]
    halls = [(3, 3, 14, 10), (21, 3, 12, 8), (37, 3, 15, 12), (3, 17, 10, 14), (17, 15, 18, 16), (39, 19, 12, 10),
             (3, 35, 16, 16), (23, 35, 10, 8), (23, 45, 12, 6), (37, 33, 15, 18)]
    rms = [f.room(*h, "hall") for h in halls]
    # arched openings between neighbouring halls
    for a in rms:
        for b in rms:
            if a is b: continue
            for (x, y) in [(x, y) for x in range(1, n - 1) for y in range(1, n - 1) if f.at(x, y) == "#"]:
                pass
    links = [(17, 6, 20, 6), (33, 6, 36, 6), (8, 13, 8, 16), (13, 22, 16, 22), (35, 22, 38, 22), (44, 15, 44, 18),
             (10, 31, 10, 34), (19, 40, 22, 40), (28, 31, 28, 34), (28, 43, 28, 44), (33, 40, 36, 40), (44, 29, 44, 32)]
    for (x0, y0, x1, y1) in links:
        f.rect(x0, y0, x1, y1)
        mid = ((x0 + x1) // 2, (y0 + y1) // 2)
        if f.is_mouth(*mid) is None: f.put(*mid, "A")
    for (x0, y0, x1, y1) in links:
        for x in range(min(x0, x1), max(x0, x1) + 1):
            for y in range(min(y0, y1), max(y0, y1) + 1):
                if f.at(x, y) == "." and f.is_mouth(x, y) is None:
                    a = (1, 0) if x0 != x1 else (0, 1)
                    if f.wallc(x + a[1], y + a[0]) and f.wallc(x - a[1], y - a[0]) and (x, y) == ((x0 + x1) // 2, (y0 + y1) // 2):
                        f.put(x, y, "A")
    f.tag_all("tiles"); f.tag_all("hall_reverb"); f.tag_all("liminal")
    big = rms[4]
    f.tag_room("grand", big); f.tag_room("tall", rms[2]); f.tag_room("tall", rms[6]); f.tag_room("tall", rms[9])
    # pools: a long lap pool, a round one, a kidney under the dome; shallow flooded halls
    f.pool(26, 23, oct_pts(5.5, 3.0, 0.2), rot=0.0, shallow=1.1, deep=3.2, tint="clear")
    f.pool(44.5, 9, oct_pts(3.0, 3.0, 0.42), shallow=0.9, deep=2.2, tint="teal")
    f.pool(10.5, 43, blob(f.r, 3.6, 3.0, 9, 0.15), shallow=1.0, deep=2.6, tint="clear")
    f.pool(44.5, 42, oct_pts(4.0, 2.5, 0.3), rot=90.0, shallow=1.2, deep=3.5, tint="teal")
    for rm in (rms[1], rms[3], rms[7], rms[8]):
        f.obj("water", rm[0] + (rm[2] - 1) / 2, rm[1] + (rm[3] - 1) / 2, 0.0, float(rm[3]), depth=float(rm[2]), level=0.22, tint="clear", caustics=True)
    # architecture: colonnades, a curved screen wall, a diving platform, a spiral to a gallery
    for px in range(19, 34, 3):
        f.obj("column", px, 16.2, 0.0, 1.0, thick=0.6, height=0.0); f.obj("column", px, 29.8, 0.0, 1.0, thick=0.6, height=0.0)
    f.obj("wall_curve", 44.5, 24, 180.0, 6.0, thick=0.3, height=2.2, arc=150.0)
    f.obj("platform", 33.4, 23, 0.0, 2.0, depth=1.0, elev=3.0, slab=0.3, edge="chrome", posts=True, surface="tile")   # diving board
    f.obj("stair_flight", 33.4, 26.5, 270.0, 0.8, depth=2.0, elev=0.0, rise=3.0, railing="both", surface="tile")
    f.obj("stair_spiral", 5.5, 20, 0.0, 2.0, elev=0.0, rise=6.0, sweep=450.0, core=0.6, turn="left", rail=True, surface="tile")
    f.obj("platform", 5.5, 25.5, 90.0, 3.0, depth=7.0, elev=6.0, slab=0.35, edge="chrome", posts=True, surface="tile")
    for i, rm in enumerate(rms):
        f.windows(2 if i in (2, 4, 6, 9) else 1, pred=f.in_room(rm), exterior=False,
                  frame=["panorama", "porthole", "arched"][i % 3], sky="noon", scale=0.9 if i % 3 == 0 else 0.5,
                  elev=0.6 if i % 3 == 0 else 1.6, height=4.0 if i % 3 == 0 else 1.8, sun=9.0, panes=4 if i % 3 == 0 else 1, sun_angle=45.0, spacing=5)
    f.paint_cells("floor", "Tile_Aqua_Mosaic", [c for c in f.cells() if f.in_room(rms[6])(*c) or f.in_room(rms[9])(*c)])
    f.paint_cells("wall", "Tile_Blue_White_Ornate", [(x, y) for x in range(16, 37) for y in range(14, 33) if f.at(x, y) == "#"])
    f.tag_room("safe", rms[0], 2)
    f.scares(5, ["silence", "drone", "hallucination", "machineVoice"], scale=3.0)
    L.build((5, 5), atmosphere="liminal", lights="panels",
            materials={"wall": "Tile_White_Grid", "floor": "Tile_White_Grid", "ceiling": "Tile_White_Grid_Lit", "tiles": "Tile_White_Grid"},
            intro="LEVEL 37 - THE POOLROOMS. White tile, warm water, light from nowhere. It is peaceful here. That is what makes it wrong.")


# ============================================================ LEVEL 52: SCHOOL ROOMS
def level_52():
    n = 51
    L = Level("level_52_school_rooms", "Level 52: School Rooms", n, 1052)
    f = L.f[0]
    f.rect(2, 12, n - 3, 14); f.rect(2, 34, n - 3, 36); f.rect(24, 12, 26, 36)    # H of hallways
    classes = []
    for x0 in range(3, n - 8, 8):
        for (y0, dy) in ((4, 11), (37, 37)):
            if 22 <= x0 <= 27: continue
            rm = f.room(x0, y0, 7, 7, "class")
            f.door_at(x0 + 1, dy); f.door_at(x0 + 5, dy)
            classes.append(rm)
    gym = f.room(3, 16, 19, 16, "gym"); f.door_at(10, 15); f.door_at(10, 32); f.door_at(22, 24)
    caf = f.room(29, 16, 19, 16, "cafeteria"); f.door_at(36, 15); f.door_at(36, 32); f.door_at(28, 20)
    hallway = [c for c in f.cells() if not any(f.in_room(r)(*c) for r in f.rooms)]
    f.paint_cells("floor", "Tile_Checker_Dark", hallway); f.tag("tiles", hallway); f.tag("hall_reverb", hallway)
    # lockers along the hallway walls
    for (x, y) in hallway:
        for dy in (-1, 1):
            if f.wallc(x, y + dy) and f.at(x - 1, y) == "." and f.at(x + 1, y) == "." and x % 2 == 0 and f.r.random() < 0.8:
                f.obj("thin_wall", x, y + dy * 0.36, 90.0, 1.9, thick=0.38, height=1.9)
    for i, rm in enumerate(classes):
        x0, y0, w, h, _ = rm
        f.paint_room("floor", "Tile_Beige_Square", rm); f.tag_room("tiles", rm)
        for dx in range(1, 6, 2):            # rows of desks, the teacher's desk at the front
            for dy in range(2, 6, 2):
                f.obj("half_wall", x0 + dx, y0 + dy, 90.0, 0.35, thick=0.35, height=0.75)
        f.obj("half_wall", x0 + 3, y0 + (0.6 if y0 > 20 else 5.4), 90.0, 0.9, thick=0.45, height=0.8)
        f.windows(2, pred=f.in_room(rm), exterior=True, frame="pane", sky="noon" if i % 3 else "golden", scale=0.6, elev=0.9, height=2.3, sun=7.0, panes=3, spacing=3)
        if i % 4 == 2: f.tag_room("dim", rm)
        if i % 5 == 0: f.tag_room("loot", rm, 1)
    f.tag_room("grand", gym); f.paint_room("floor", "Wood_Floor_Parquet_Dark", gym); f.tag_room("hall_reverb", gym)
    f.obj("platform", 4.5, 24, 0.0, 6.0, depth=2.0, elev=1.1, slab=0.4, edge="none", posts=False, surface="floor")   # the stage
    f.obj("stair_flight", 6.5, 20.0, 180.0, 1.0, depth=1.0, elev=0.0, rise=1.1, railing="none", surface="floor")
    f.windows(4, pred=f.in_room(gym), exterior=False, frame="pane", sky="noon", scale=0.9, elev=8.0, height=3.0, sun=6.0, panes=5, spacing=6)
    f.paint_room("floor", "Tile_Cream_Beige", caf); f.tag_room("tiles", caf); f.tag_room("tall", caf)
    for ty in range(caf[1] + 3, caf[1] + caf[3] - 2, 3):
        f.obj("half_wall", caf[0] + caf[2] / 2, ty, 90.0, 12.0, thick=0.8, height=0.76)   # long lunch tables
    f.windows(3, pred=f.in_room(caf), exterior=True, frame="panorama", sky="noon", scale=0.8, elev=0.6, height=3.4, sun=7.0, panes=4)
    f.mount(["prop_exit_sign", "prop_exit_sign_medium"], 6, spacing=10)
    f.tag_some("flicker", 0.1)
    f.scares(6, ["static", "silence", "machineVoice", "preacherWhisper", "thump", "wallKnock"])
    L.build((25, 13), atmosphere="liminal", lights="troffers",
            materials={"wall": "Tile_Pale_Grid", "floor": "Tile_Checker_Dark", "ceiling": "Ceiling_Drop_Square", "tiles": "Tile_Checker_Dark"},
            intro="LEVEL 52 - SCHOOL ROOMS. Classrooms, lockers and a bell that never rings. Sunlight in the windows, but no one in the desks. Don't stay after class.")


# ============================================================ LEVEL 94: MOTION
def level_94():
    n = 55
    L = Level("level_94_motion", "Level 94: Motion", n, 1094)
    f = L.f[0]
    f.rect(1, 1, n - 2, n - 2)
    houses = []
    for (hx, hy) in ((8, 8), (34, 10), (14, 34), (38, 36), (24, 22)):
        f.rect(hx, hy, hx + 6, hy + 5, "#"); rm = f.room(hx + 1, hy + 1, 5, 4, "house"); f.door_at(hx + 3, hy + 5)
        houses.append(rm)
        f.windows(2, pred=f.in_room(rm), exterior=False, frame="pane", sky="golden", scale=0.5, elev=0.9, height=1.9, sun=6.0, panes=2, spacing=3)
        f.paint_room("floor", "Wood_Light_Planks", rm); f.paint_room("wall", "Wood_Light_Planks", rm, walls=True)
        f.tag_room("muffled", rm)
    outside = [c for c in f.cells() if not any(f.in_room(h)(*c) for h in houses)]
    f.tag("open_ceiling", outside)
    f.paint_cells("floor", "Grass_Green", outside)
    # rolling hills: stepped raised terraces with stairs up, picket fences, round trees
    for (hx, hy, w, d, e) in ((20, 4, 8, 5, 1.2), (44, 22, 6, 9, 1.6), (4, 22, 7, 6, 0.9), (28, 44, 9, 5, 1.4)):
        f.obj("platform", hx, hy, 0.0, float(d), depth=float(w), elev=e, slab=e, edge="none", posts=False, surface="floor")
        f.obj("platform", hx, hy, 0.0, float(d) - 2, depth=float(w) - 2, elev=e * 2, slab=e, edge="none", posts=False, surface="floor")
        f.obj("stair_flight", hx - w / 2 - 1.0, hy, 0.0, 1.0, depth=2.0, elev=0.0, rise=e, railing="none", surface="floor")
        f.reserved.update((x, y) for x in range(int(hx - w / 2) - 3, int(hx + w / 2) + 2) for y in range(int(hy - d / 2) - 1, int(hy + d / 2) + 2))
    for (x0, y0, length, rt) in ((5, 16, 10, 90.0), (30, 30, 8, 0.0), (46, 6, 9, 0.0), (12, 48, 12, 90.0)):
        f.obj("half_wall", x0, y0, rt, float(length), thick=0.08, height=1.0)
    for c in f.r.sample([c for c in outside if c not in f.reserved], 26):
        f.obj("column", c[0] + f.r.uniform(-.3, .3), c[1] + f.r.uniform(-.3, .3), 0.0, 1.0, thick=f.r.uniform(0.35, 0.6), height=0.0)
    f.pool(28, 38, blob(f.r, 2.5, 1.6, 8, 0.15), shallow=0.5, deep=1.2, tint="teal")   # the pond
    f.scares(6, ["hallucination", "static", "silence", "camera_shake", "machineVoice"], pred=lambda x, y: (x, y) in set(outside))
    L.build((3, 3), atmosphere="liminal", lights="panels", extra={"wrap": True},
            materials={"wall": "Wallpaper_Yellow_Stripe_Dots", "floor": "Grass_Green", "ceiling": "Ceiling_Drop_Square"},
            intro="LEVEL 94 - MOTION. Green hills and little houses, like a film for children. Everything here moves a little when you are not looking. Do not watch the houses for too long.")


# ============================================================ LEVEL 188: THE COURTYARD OF WINDOWS
def level_188():
    n = 45
    L = Level("level_188_courtyard_of_windows", "Level 188: The Courtyard of Windows", n, 1188, floors=(0, 1))
    f, u = L.f[0], L.f[1]
    for fl in (f, u):
        fl.rect(3, 3, n - 4, 5); fl.rect(3, n - 6, n - 4, n - 4); fl.rect(3, 3, 5, n - 4); fl.rect(n - 6, 3, n - 4, n - 4)   # the ring corridor
    court = f.room(12, 12, 21, 21, "court")
    f.tag_room("open_ceiling", court); f.paint_room("floor", "Paving_Cobble_Sage", court)
    f.paint_cells("floor", "Grass_Green", [(x, y) for x in range(15, 30) for y in range(15, 30)])
    f.pool(22, 22, oct_pts(2.0, 2.0, 0.42), shallow=0.6, deep=0.9, tint="clear")      # the dry-ish fountain
    for k in range(8): f.obj("column", 22 + 5 * math.cos(k * math.pi / 4), 22 + 5 * math.sin(k * math.pi / 4), 0.0, 1.0, thick=0.4, height=2.2)
    for (x, y) in ((22, 6), (22, 38), (6, 22), (38, 22)):   # passages from the ring into the court
        if x == 22: f.rect(x, min(y, 11), x, max(y, 11) if y < 22 else 33)
        else: f.rect(min(x, 11) if x < 22 else 33, y, max(x, 11) if x < 22 else x, y)
    for (x, y) in ((22, 11), (22, 33), (11, 22), (33, 22)): f.door_at(x, y)
    # the windows: the court's walls are covered in them, and every one looks out on a sky that can't be there
    f.windows(28, pred=f.in_room(court), exterior=False, straight=True, frame="pane", sky="overcast", scale=0.5, elev=0.9, height=2.2, sun=2.0, panes=3, spacing=2.4)
    f.windows(12, pred=lambda x, y: (x, y) not in court, exterior=False, frame="pane", sky="overcast", scale=0.5, elev=0.9, height=2.2, sun=2.0, panes=3, spacing=3)
    u.windows(24, exterior=False, frame="arched", sky="overcast", scale=0.5, elev=1.0, height=2.6, sun=2.0, panes=3, spacing=2.6)
    for fl in (f, u):
        fl.paint_cells("floor", "Wood_Floor_Dark_Strips", [c for c in fl.cells() if c not in court])
        fl.tag_some("dim", 0.15); fl.tag_some("muffled", 0.2)
        fl.mount(["prop_exit_sign"], 2, spacing=20)
    f.tag_room("liminal", court); f.tag_room("safe", (20, 13, 5, 3, ""))
    L.stairs(0, 1, 4, 30, 270, style="carpet")
    f.scares(5, ["silence", "hallucination", "breathBehind", "drone"])
    u.scares(5, ["wallKnock", "machineVoice", "silence", "deadAir"])
    L.build((22, 14), atmosphere="liminal", lights="panels", exit_floor=1, entity=False,
            materials={"wall": "Brick_Tan_Wall", "floor": "Paving_Cobble_Sage", "ceiling": "Ceiling_Drop_Square"},
            intro="LEVEL 188 - THE COURTYARD OF WINDOWS. A quiet courtyard walled in by windows. You are being watched from every one of them. Nothing in them ever moves.")


# ============================================================ LEVEL FUN =)
def level_fun():
    n = 51
    L = Level("level_fun", "Level Fun =)", n, 1777)
    f = L.f[0]
    rooms_and_halls(f, 11, 6, 11, 6, 10, hw=1, gap=2)
    f.corridor_doors(0.7)
    f.tag_all("classic"); f.tag_some("drain", 0.25)
    for i, rm in enumerate(f.rooms):
        x0, y0, w, h, _ = rm
        f.obj("half_wall", x0 + w / 2 - 0.5, y0 + h / 2 - 0.5, 90.0, max(1.0, w - 4), thick=0.9, height=0.76)   # party table
        f.paint_room("floor", ["Carpet_Yellow_Green", "Fabric_Blue", "Carpet_Grey"][i % 3], rm)
        f.paint_room("wall", ["Wallpaper_Yellow_Dots_A", "Wallpaper_Yellow_Dots_B", "Wallpaper_Yellow_Stripe_Dots"][i % 3], rm, walls=True)
        if i % 3 == 0: f.tag_room("mannequin", rm, 1)
        if i % 4 == 1: f.tag_room("loot", rm, 1)
    f.props(["prop_gas_cylinder"], 10)      # the helium tanks
    f.mount(["prop_exit_sign"], 4, spacing=12)
    cs = f.cells()
    for c, line in zip(f.r.sample(cs, 6), ["=)", "DON'T LEAVE THE PARTY =)", "everyone is here! =)", "HAPPY BIRTHDAY =)", "we've been waiting for you =)", "Why aren't you smiling? =)"]):
        f.trigger(c[0], c[1], "message", line, scale=2.5)
    f.scares(5, ["machineVoice", "spawn_mannequin", "breathBehind", "hallucination", "sanity_drain"])
    L.build(f.cells()[0], atmosphere="classic", lights="panels",
            materials={"wall": "Wallpaper_Yellow_Dots_A", "floor": "Carpet_Yellow_Green", "ceiling": "Ceiling_Drop_Square"},
            intro="LEVEL FUN =) - A party that never ends. Streamers, cake and balloons. If someone offers you cake, do not eat it. If a Partygoer smiles at you, run.")


# ============================================================ LEVEL !: RUN FOR YOUR LIFE
def level_run():
    n = 61
    L = Level("level_run_for_your_life", "Level !: RUN FOR YOUR LIFE", n, 1666)
    f = L.f[0]
    # one long corridor folded back and forth over the map: no turning off it, only on
    rows = list(range(3, n - 4, 6))
    for i, y in enumerate(rows):
        f.rect(3, y, n - 4, y + 2)
        if i + 1 < len(rows):
            x = n - 6 if i % 2 == 0 else 3
            f.rect(x, y, x + 2, rows[i + 1] + 2)
    f.tag_all("flicker"); f.tag_some("dark", 0.15); f.tag_all("hall_reverb")
    cs = f.cells()
    # obstacles: half walls to vault round, pillars, fallen panels, a few squeezes
    for (x, y) in cs:
        if f.r.random() < 0.03 and 6 < x < n - 7:
            f.obj("half_wall", x, y, 90.0 if f.r.random() < 0.5 else 0.0, f.r.choice([1.0, 1.5]), thick=0.3, height=f.r.choice([0.9, 1.2]))
        elif f.r.random() < 0.02:
            f.obj("pillar", x, y, 0.0, 1.0, thick=0.7, height=0.0)
    f.props(["prop_explosive_barrel", "prop_pallet_truck", "prop_cable_drum", "prop_platform_trolley"], 18)
    f.mount(["prop_exit_sign_big"], 8, spacing=10)
    for y in rows[1::2]:
        f.trigger(30, y + 1, f.r.choice(["redAlert", "emergencyPulse", "camera_shake", "thump"]), scale=3.0, depth=1.0)
    f.trigger(5, 4, "redAlert", scale=3.0, depth=1.0, duration=120.0)
    L.build((4, 4), atmosphere="dim", lights="panels",
            materials={"wall": "Tile_Grimy_Grey", "floor": "Tile_Dark_Slate", "ceiling": "Ceiling_Light_Panels"},
            intro="LEVEL ! - RUN FOR YOUR LIFE. The lights are red. Something is coming down the corridor behind you. Do not stop. Do not look back. RUN.")


# ============================================================ THE HUB
def level_hub():
    n = 51
    L = Level("the_hub", "The Hub", n, 1999)
    f = L.f[0]
    c = 25
    f.disk(c, c, 8.6)
    f.tag_all("grand"); f.tag_all("hall_reverb"); f.tag_all("safe"); f.tag_all("liminal")
    f.paint_cells("floor", "Tile_Checker_Marble", f.cells())
    f.obj("wall_curve", c, c, 0.0, 19.0, thick=0.3, height=0.0, arc=360.0)
    f.pool(c, c, oct_pts(2.2, 2.2, 0.42), shallow=0.5, deep=0.8, tint="clear")
    for k in range(8): f.obj("column", c + 5.2 * math.cos(k * math.pi / 4 + .39), c + 5.2 * math.sin(k * math.pi / 4 + .39), 0.0, 1.0, thick=0.7, height=0.0)
    # doors all round the hall, each to a corridor and a vestibule naming a level
    labels = ["LEVEL 0", "LEVEL 1", "LEVEL 2", "LEVEL 4", "LEVEL 5", "LEVEL 6", "LEVEL 9", "LEVEL 11", "LEVEL 37", "LEVEL 52", "LEVEL 188", "LEVEL FUN =)"]
    spokes = []
    for (dx, dy) in DIRS:
        for off in (-4, 0, 4):
            px, py = (-dy * off, dx * off)
            x, y = c + px, c + py
            while f.at(x, y) == ".": x += dx; y += dy
            door = (x, y)
            ex, ey = x + dx * 7, y + dy * 7
            f.rect(x + dx, y + dy, ex, ey)
            vx0, vy0 = min(ex, ex + dx * 3) - (1 if dx == 0 else 0), min(ey, ey + dy * 3) - (1 if dy == 0 else 0)
            f.rect(vx0, vy0, vx0 + (2 if dx == 0 else 3), vy0 + (2 if dy == 0 else 3))
            f.door_at(*door)
            spokes.append(((ex + dx * 2, ey + dy * 2), (dx, dy)))
    f.windows(8, pred=lambda x, y: (x - c) ** 2 + (y - c) ** 2 < 80, exterior=False, straight=False, frame="porthole", sky="overcast", scale=0.4, elev=3.5, height=1.6, sun=2.0, panes=1, spacing=4)
    for (pos, d), lab in zip(spokes, labels):
        f.trigger(pos[0], pos[1], "message", "THIS WAY: " + lab + "  (the door does not open from this side)", scale=2.0, depth=2.0)
    for (x, y) in f.cells():
        if (x - c) ** 2 + (y - c) ** 2 > 81: f.z["safe"].discard((x, y)); f.z["dim"].add((x, y)); f.z["grand"].discard((x, y)); f.z["liminal"].discard((x, y))
    f.mount(["prop_exit_sign_big"], 4, spacing=8, pred=lambda x, y: (x - c) ** 2 + (y - c) ** 2 > 81)
    L.build((c, c - 6), atmosphere="liminal", lights="panels", entity=False,
            materials={"wall": "Wallpaper_Pale_Green", "floor": "Tile_Checker_Marble", "ceiling": "Ceiling_Drop_Square"},
            intro="THE HUB. A round hall of doors, every one to somewhere else. Wanderers say it is safe here. Most of the doors lead nowhere you want to go.")



# ============================================================ LIGHTING PLANS (lamp_fixture.gd + room-aware tubes)
LIGHT_MODE = {
    "level_0_2_renovated_lobby": "troffers", "level_1_habitable_zone": "troffers", "level_2_pipe_dreams": "none",
    "level_3_electrical_station": "troffers", "level_4_abandoned_office": "troffers", "level_5_terror_hotel": "none",
    "level_6_lights_out": "none", "level_7_thalassophobia": "none", "level_8_cave_system": "none",
    "level_9_the_suburbs": "none", "level_10_bumper_crops": "none", "level_11_endless_city": "none",
    "level_13_infinite_apartments": "troffers", "level_52_school_rooms": "troffers", "level_94_motion": "none",
    "level_188_courtyard_of_windows": "none", "level_fun": "none", "level_run_for_your_life": "troffers",
    "the_hub": "none",
}


def rooms_of(f, tag): return [r for r in f.rooms if r[4] == tag]


def lt_lobby2(L):
    f = L.f[0]
    f.emergency(6, spacing=14); f.lamps("candle", 7, tone="candle"); f.sconces(5, tone="cool", flicker="faulty", spacing=12)
    f.lamps("vent_glow", 3, tone="sodium")


def lt_1(L):
    f = L.f[0]
    f.emergency(10, spacing=10)
    for rm in f.rooms:
        f.lamps("vent_glow", 1, f.in_room(rm), tone="sodium", flicker="buzz")
        f.sconces(2, f.in_room(rm), tone="cool", flicker="buzz", spacing=10, elev=3.2)
    f.lamps("lamp_floor", 3, f.in_room(f.rooms[0]), tone="warm")        # the safe corner: someone's camp
    f.lamps("candle", 4, f.in_room(f.rooms[0]), tone="candle", wall=False)


def lt_2(L):
    f = L.f[0]
    f.emergency(14, spacing=7)
    f.sconces(18, tone="cool", flicker="faulty", spacing=6, elev=2.2)
    f.lamps("vent_glow", 14, tone="sodium", flicker="pulse", spacing=6)
    for rm in rooms_of(f, "boiler"): f.lamp("vent_glow", rm[0] + 2, rm[1] + 3, 0.0, 1.5, tone="sodium", flicker="pulse")


def lt_3(L):
    f, u = L.f[0], L.f[1]
    for fl in (f, u):
        fl.emergency(8, spacing=9); fl.sconces(8, tone="cool", flicker="faulty", spacing=8, elev=2.4)
    f.lamps("vent_glow", 8, tone="green", flicker="buzz", spacing=6)
    for rm in rooms_of(u, "control"): u.lamps("lamp_floor", 2, u.in_room(rm), tone="cool", flicker="buzz")
    u.lamps("vent_glow", 5, tone="green", flicker="pulse")


def lt_4(L):
    for k, f in L.f.items():
        for rm in f.rooms:
            if rm[4] == "office": f.lamps("lamp_floor", 1, f.in_room(rm), tone="warm", corner=True)
        f.lamps("lamp_floor", 8, None, tone="warm", spacing=6, corner=True)
        f.emergency(5, spacing=12); f.sconces(6, tone="warm", flicker="faulty", spacing=10)
    L.f[0].lamps("candle", 3, tone="candle", spacing=8)


def lt_5(L):
    f, u = L.f[0], L.f[1]
    lobby = rooms_of(f, "lobby")[0]
    f.centre_lamps([lobby], "chandelier", 6, 6, tone="hotel", scale=2.3)
    f.lamp("chandelier", 20.5, 22.5, 0.0, 1.3, tone="hotel"); f.lamp("chandelier", 30.5, 22.5, 0.0, 1.3, tone="hotel")
    f.sconces(10, f.in_room(lobby), tone="hotel", spacing=3.5, elev=2.6)
    f.lamps("candle", 6, f.in_room(lobby), tone="candle", wall=False)
    u.sconces(46, tone="hotel", flicker="faulty", spacing=4.2, elev=2.0)
    for rm in u.rooms:
        if rm[4] == "guest": u.lamps("lamp_floor", 1, u.in_room(rm), tone="warm", corner=True)
    for _ in range(6): u.lamps("candle", 1, tone="candle", spacing=14)
    u.emergency(8, spacing=10)


def lt_6(L):
    f = L.f[0]
    f.lamps("candle", 18, tone="candle", spacing=7, wall=False)
    f.sconces(8, tone="cool", flicker="faulty", spacing=10)
    for c in sorted(f.z["safe"]): f.lamp("lamp_floor", c[0] + 0.3, c[1] + 0.3, 0.0, 1.0, tone="warm", flicker="candle")
    f.emergency(5, spacing=16)


def lt_7(L):
    f = L.f[0]
    f.lamp("lamp_floor", 4.5, 4.5, 0.0, 1.2, tone="warm"); f.lamps("candle", 3, f.in_room((3, 3, 6, 5, "")), tone="candle", wall=False)
    for (ix, iy, w, h) in [(24, 9, 6, 5), (30, 24, 7, 7), (41, 34, 6, 7), (19, 40, 7, 5)]:
        f.lamp("streetlamp", ix + w // 2, iy + h // 2, f.r.choice([0, 90, 180, 270]), 1.1, flicker="sway")
    f.strings(6, pred=lambda x, y: 10 < x < 50, min_len=6, max_len=12, tone="cool")
    f.emergency(4, f.in_room((3, 3, 6, 5, "")))


def lt_8(L):
    f = L.f[0]
    f.lamps("vent_glow", 26, tone="green", flicker="pulse", spacing=5, wall=True)
    f.lamps("candle", 9, tone="candle", wall=False, spacing=9)
    f.lamps("lamp_floor", 2, tone="warm", wall=False, spacing=30)           # a lost explorer's camp lantern


def lt_9(L):
    f = L.f[0]
    f.streetlamps(20, pred=lambda x, y: (x, y) in f.z["open_ceiling"], spacing=8.0)
    for rm in f.rooms:
        if rm[4] == "house": f.lamps("lamp_floor", 1, f.in_room(rm), tone="warm", corner=True)
    f.strings(8, pred=lambda x, y: (x, y) in f.z["open_ceiling"], tone="warm", min_len=5, max_len=10, ceiling=3.4)
    f.sconces(10, pred=lambda x, y: (x, y) in f.z["open_ceiling"], tone="warm", spacing=9, elev=2.3)


def lt_10(L):
    f = L.f[0]
    barn = (24, 24, 12, 10, "barn")
    f.strings(3, pred=f.in_room(barn), tone="warm", min_len=4, max_len=10, ceiling=4.0)
    f.sconces(4, pred=f.in_room(barn), tone="warm", flicker="candle", spacing=5, elev=2.3)
    f.lamps("candle", 5, pred=f.in_room(barn), tone="candle", wall=False)
    f.streetlamps(3, pred=lambda x, y: x in (30, 31, 32) or y in (30, 31, 32), spacing=14)


def lt_11(L):
    f = L.f[0]
    f.streetlamps(22, pred=lambda x, y: (x, y) in f.z["open_ceiling"], spacing=9.0)
    lobs = rooms_of(f, "lobby")
    f.centre_lamps(lobs, "chandelier", 6, 6, tone="hotel", scale=1.3)
    f.sconces(14, pred=lambda x, y: any(f.in_room(r)(x, y) for r in lobs), tone="cool", spacing=4, elev=2.6)
    f.emergency(3, pred=lambda x, y: any(f.in_room(r)(x, y) for r in lobs))


def lt_13(L):
    for k, f in L.f.items():
        f.sconces(18, tone="hotel", flicker="faulty", spacing=4.5, elev=2.0)
        for rm in f.rooms:
            if rm[4] == "unit":
                f.lamps("lamp_floor", 1, f.in_room(rm), tone="warm", corner=True)
                if f.r.random() < 0.3: f.lamps("candle", 1, f.in_room(rm), tone="candle", wall=False)
        f.emergency(4, spacing=14)


def lt_37(L):
    f = L.f[0]
    f.sconces(10, tone="cool", spacing=8, elev=2.4)
    f.lamps("vent_glow", 6, tone="cool", flicker="sway", spacing=9)


def lt_52(L):
    f = L.f[0]
    f.emergency(14, spacing=7, tone="red", flicker="pulse")
    gym = rooms_of(f, "gym")
    if gym: f.sconces(8, pred=f.in_room(gym[0]), tone="warm", spacing=5, elev=3.0)
    for rm in f.rooms:
        if rm[4] == "class" and f.r.random() < 0.4: f.lamps("lamp_floor", 1, f.in_room(rm), tone="warm", corner=True)
    f.lamps("candle", 2, tone="candle", spacing=18)


def lt_94(L):
    f = L.f[0]
    for rm in f.rooms:
        if rm[4] == "house":
            f.lamps("lamp_floor", 1, f.in_room(rm), tone="warm", corner=True)
            f.strings(1, pred=f.in_room(rm), tone="warm", min_len=4, max_len=5, ceiling=3.0)
            f.lamps("candle", 1, f.in_room(rm), tone="candle", wall=False)
    f.streetlamps(8, pred=lambda x, y: (x, y) in f.z["open_ceiling"], spacing=11.0)


def lt_188(L):
    f, u = L.f[0], L.f[1]
    f.strings(10, pred=lambda x, y: 12 <= x <= 32 and 12 <= y <= 32, tone="warm", min_len=6, max_len=12, ceiling=4.0)
    f.sconces(18, tone="hotel", flicker="candle", spacing=5, elev=2.0)
    f.lamps("candle", 8, f.in_room((12, 12, 21, 21, "")), tone="candle", wall=False, spacing=4)
    u.sconces(22, tone="hotel", spacing=4.5, elev=2.0)
    for fl in (f, u): fl.emergency(3, spacing=18)


def lt_fun(L):
    f = L.f[0]
    f.strings(14, tone="party", min_len=4, max_len=9)
    for rm in f.rooms:
        f.lamps("lamp_floor", 1, f.in_room(rm), tone="party", corner=True)
        f.lamps("candle", 2, f.in_room(rm), tone="party", wall=False)
    f.sconces(10, tone="party", flicker="faulty", spacing=6)


def lt_run(L):
    f = L.f[0]
    f.emergency(40, spacing=3.5, tone="red", flicker="pulse")
    f.sconces(10, tone="red", flicker="faulty", spacing=9)
    f.lamps("vent_glow", 8, tone="red", flicker="pulse")


def lt_hub(L):
    f = L.f[0]
    f.lamp("chandelier", 25, 25, 0.0, 2.4, tone="hotel")
    f.sconces(16, pred=lambda x, y: (x - 25) ** 2 + (y - 25) ** 2 < 90, tone="hotel", spacing=3.5, elev=2.6)
    f.lamps("candle", 8, pred=lambda x, y: (x - 25) ** 2 + (y - 25) ** 2 < 70, tone="candle", wall=False, spacing=4)


LIGHTING = {"level_0_2_renovated_lobby": lt_lobby2, "level_1_habitable_zone": lt_1, "level_2_pipe_dreams": lt_2,
            "level_3_electrical_station": lt_3, "level_4_abandoned_office": lt_4, "level_5_terror_hotel": lt_5,
            "level_6_lights_out": lt_6, "level_7_thalassophobia": lt_7, "level_8_cave_system": lt_8,
            "level_9_the_suburbs": lt_9, "level_10_bumper_crops": lt_10, "level_11_endless_city": lt_11,
            "level_13_infinite_apartments": lt_13, "level_37_poolrooms": lt_37, "level_52_school_rooms": lt_52,
            "level_94_motion": lt_94, "level_188_courtyard_of_windows": lt_188, "level_fun": lt_fun,
            "level_run_for_your_life": lt_run, "the_hub": lt_hub}


for fn in (level_0_2, level_1, level_2, level_3, level_4, level_5, level_6, level_7, level_8, level_9, level_10,
           level_11, level_13, level_37, level_52, level_94, level_188, level_fun, level_run, level_hub):
    fn()

lj = os.path.join(LV, "levels.json")
cur = json.load(open(lj))
mine = {e["id"] for e in OUT}
keep = [e for e in cur if e["id"] not in mine]
lobby = [e for e in keep if e["id"] == "level0"]
others = [e for e in keep if e["id"] != "level0"]
by = {e["id"]: e for e in OUT}
order = lobby + [by["level_0_2_renovated_lobby"]] + [e for e in OUT if e["id"] != "level_0_2_renovated_lobby"] + others
json.dump(order, open(lj, "w"), indent=2)
print("wrote", len(OUT), "levels")
