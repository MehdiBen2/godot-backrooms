"""Build the first-person arms the game loads (models/player/playerarms.glb).

    python tools/build_player_arms.py [new.glb] [old.glb] [out.glb]      (needs numpy, nothing else)

    new.glb  asetsuimprot/playerpov.glb        the Tripo arms: shoulder to fingertips, both sides one mesh.
                                               Its own rig (13 bones down the left arm only) is thrown away
    old.glb  asetsuimprot/playerarms_old.glb   the arms this replaces: forearms only. Read for its skeleton's
                                               conventions, its ten clips, TorchGrip and its material
    out.glb  godot-backrooms/models/player/playerarms.glb

What it does:

1. Skeleton. The same bones as the old arms, under the same names (scripts/Player/torch_model.gd and
   wall_hand.gd find them by name), fitted to the new mesh. The mesh is an exact mirror, so the right arm
   is fitted and the left mirrored from it.
     shoulder, elbow, wrist  off the sleeve's centreline: the elbow is where it bends, just above the pouch
     fingers                 each fingertip is the far end of a walk over the surface from the sleeve; rings
                             at even distances from the tip give the finger's centreline, the joints go on it
                             at a hand's proportions, and the knuckle carries on back into the palm
   Every bone has +Y along it. A finger bone's +X is the axis its finger curls about (so a joint is one
   angle about X, which is what wall_hand.gd turns), the palm is on the hand's +Z. Forearm and thumb take
   their roll from the old bones, through the two hands' frames.
   New: Left/RightUpperArm, a child of the forearm that points back from the elbow to the shoulder. Hung
   that way round the old clips (which place the forearm under Root) need no change, and wall_hand.gd can
   bend the elbow by turning that one bone.
2. Skin. Sleeve: by distance along the arm, blending over the elbow (above the pouch, which stays rigid on
   the upper arm) and the wrist. Hand: each vertex to the nearest bone of its own finger (a finger owns
   what the walk from its tip reaches before the palm), the rest of the hand to the nearest of palm, thumb
   base and knuckles, then smoothed over the surface. Two halves: LeftArm, RightArm (torch_model.gd shows
   and hides them separately).
3. Clips. Every bone points where the old one did, in the hand's space (the old finger bones were rolled
   any which way, so their rotations are re-expressed for the new axes). The forearm's position is moved
   along the forearm by the difference in forearm length, so the wrist is where it was.
4. The torch grip. The old clips held the torch in a loose, open hand, the barrel through the knuckles. The
   torch (models/flashlight.glb, as torch_model.gd fits it) is seated against this palm, at the old angle
   across it, and the hand closed on it: each finger joint in turn bends until that bone lies on the barrel,
   and the thumb is laid along the top of it, pointing at the head. That pose replaces the right hand's
   fingers in the Torch* clips; TorchGrip moves to the seat and TorchAnchor to where it is in TorchHold.
5. WallPalm, a new one-pose clip: the thumbs laid out flat beside the palm, for a hand pressed on a wall
   (wall_hand.gd reads it; at rest this glove's thumb points out of the palm, into the wall).
6. Four one-shot clips on the torch hold, each starting and ending on its first pose (torch_model.gd plays
   them over the hold and goes back to it):
   TorchSqueeze   the fist tightens on the barrel, trembles a little, lets go a touch past normal, settles
   TorchFingers   the fingers lift off the barrel and come back one after another, little finger first
   TorchRegrip    the hand opens a moment, all four fingers and the thumb off the barrel, and takes a
                  fresh, firm hold (the thumb alone is no use: from your eye the barrel hides it)
   TorchSmack     two sharp hammer strokes of the wrist, the fist clamped: knocking a flickering torch
7. TorchReload, the battery swap, both arms (torch_model.gd plays it; tools/gen_battery_audio.py is the
   sound, cut to the same times). The right arm turns the torch level across the view, tail to the left.
   The left hand comes up from below, takes the tail cap and unscrews it in two twists with a fresh hold
   between them (the light dies), pulls it off; the torch tips tail-down, gets a shake and the old cells
   slide out; the hand goes down for the new pair (BatteryGrip, a new node in the left fist, is where
   torch_model.gd shows them), pushes them in one after the other, sets the cap back, screws it down in two
   twists (the light comes back) and drops away as the right arm goes back to the hold. Authored in the
   camera's space, so VIEW_POS / VIEW_ROT have to be torch_model.gd's POS / ROT.
   What keeps it from looking like a machine: every move is an intention followed by a damped spring
   (sprung()), each with its own stiffness, so things ease in, run a little past, settle, and never all
   arrive on the same frame; the hands wander a little while they work (drift()); the hand comes in on a
   curve with a loose wrist that cocks into the grip as it lands; and the torch answers what's done to it:
   it rolls with each twist of the cap, is shoved by each cell going in, and the fist on it tightens.

"""
import heapq
import json
import struct
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
NEW = REPO / "asetsuimprot/playerpov.glb"
OLD = REPO / "asetsuimprot/playerarms_old.glb"
OUT = REPO / "godot-backrooms/models/player/playerarms.glb"

FINGERS = ["Index", "Middle", "Ring", "Little"]
JOINTS = ["Proximal", "Intermediate", "Distal"]
THUMB = ["ThumbMetacarpal", "ThumbProximal", "ThumbDistal"]
SLEEVE_BELOW = 0.70               # everything under this height is sleeve (the walk to the fingertips starts here)
ELBOW_AT = 0.41                   # height (mesh units) of the sleeve's bend, just above the pouch
WRIST_AT = 0.715                  # and of the wrist, inside the sleeve's end
PHALANX = (0.46, 0.27, 0.27)      # proximal, intermediate, distal as parts of knuckle-to-tip
FREE = 0.8                        # how much of knuckle-to-tip stands clear of the palm
THUMB_IP = 0.047                  # along the thumb from its tip: the joint, and where it meets the palm
THUMB_MCP = 0.102
THUMB_CMC = 0.15                  # the thumb's base sits this much of the way from the wrist to that
ELBOW_BLEND = (-0.04, 0.07)       # along the arm about the elbow: upper arm below, forearm above
WRIST_BLEND = (-0.03, 0.03)
SMOOTH = 3                        # passes of smoothing over the hand's weights
HOLD = "TorchHold-loop"
PALM = "WallPalm"
PALM_THUMB = (52.0, 42.0, 36.0)   # degrees off the fingers each thumb bone lies, flat on a wall, base first
PALM_LIFT = 0.04                  # and this much back off the wall, so the thumb's thickness clears it
ARMS_SCALE = 0.6                  # torch_model.gd: metres per armature unit
TORCH = REPO / "godot-backrooms/models/flashlight.glb"
TORCH_LENGTH = 0.27               # torch_model.gd LENGTH and GRIP_BACK, metres
TORCH_BACK = 0.018
SQUEEZE = 0.85                    # a finger sinks this much of its own radius short of touching the barrel
FLEX = ((-15.0, 95.0), (0.0, 110.0), (0.0, 75.0))     # degrees each finger joint can bend, knuckle first
VIEW_POS = (0.2, -0.2, -0.38)     # torch_model.gd POS and ROT (x, y): where the grip sits in the camera's space
VIEW_ROT = (0.16, 0.14)
TORCH_TAIL = 0.153                # m from the grip back to the torch's tail end (half its length + TORCH_BACK)
# the swap, in the camera's space (m; x right, y up, -z ahead)
SWAP_AIM = (0.92, 0.12, -0.37)    # the way the torch points while it's worked on: level, head to the right
SWAP_FOREARM = (0.2, 0.6, -0.77)  # the way the right forearm then runs, elbow to wrist: up from below
SWAP_AT = (0.10, -0.19, -0.36)    # where the grip is then
SWAP_LEFT_ELBOW = (-0.14, -0.46, -0.10)   # about where the left elbow hangs: under the tail, so the wrist stays straight
SWAP_AWAY = (-0.10, -0.24, 0.06)  # from the tail to where the left hand waits, below the view
SWAP_SWING = (-0.05, 0.02, 0.03)  # how far the hand's way there and back bows out from the straight line
SWAP_RELAX = 0.65                 # how much of the wrist's angle on the cap the hand lets go of, off the torch
SWAP_DIP = 0.025                  # the torch hand's way to the working pose sags this much in the middle
SWAP_TWIST = 45.0                 # degrees a turn of the cap
SWAP_TIP = 48.0                   # degrees the tail dips to let the old cells out
SWAP_GIVE = 4.0                   # degrees the torch rolls in the right hand with a twist of the cap
SWAP_LENGTH = 6.8

# ---------------------------------------------------------------------------------------------- glb

CT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load_glb(path):
    with open(path, "rb") as f:
        f.read(12)
        n, _ = struct.unpack("<I4s", f.read(8))
        doc = json.loads(f.read(n))
        n, _ = struct.unpack("<I4s", f.read(8))
        return doc, f.read(n)


def accessor(doc, blob, i):
    a = doc["accessors"][i]
    view = doc["bufferViews"][a["bufferView"]]
    dt = np.dtype(CT[a["componentType"]])
    n = NC[a["type"]]
    off = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = view.get("byteStride", 0)
    if stride and stride != dt.itemsize * n:
        raw = np.frombuffer(blob, np.uint8, stride * (a["count"] - 1) + dt.itemsize * n, off)
        pick = (np.arange(a["count"])[:, None] * stride + np.arange(dt.itemsize * n)[None, :]).ravel()
        arr = np.frombuffer(raw[pick].tobytes(), dt)
    else:
        arr = np.frombuffer(blob, dt, a["count"] * n, off)
    return arr.reshape(a["count"], n) if n > 1 else arr


class Writer:
    """Collects accessors into one buffer"""

    def __init__(self):
        self.blob = bytearray()
        self.views = []
        self.accessors = []

    def view(self, data, target=None):
        while len(self.blob) % 4:
            self.blob.append(0)
        v = {"buffer": 0, "byteOffset": len(self.blob), "byteLength": len(data)}
        if target:
            v["target"] = target
        self.blob += data
        self.views.append(v)
        return len(self.views) - 1

    def add(self, arr, kind, target=None, bounds=False):
        arr = np.ascontiguousarray(arr)
        ctype = {v: k for k, v in CT.items()}[arr.dtype.type]
        a = {"bufferView": self.view(arr.tobytes(), target), "componentType": ctype, "count": len(arr), "type": kind}
        if bounds:
            flat = arr.reshape(len(arr), -1)
            a["min"] = flat.min(0).tolist()
            a["max"] = flat.max(0).tolist()
        self.accessors.append(a)
        return len(self.accessors) - 1


# ------------------------------------------------------------------------------------- quaternions (x, y, z, w)

def q_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return np.array([aw * bx + ax * bw + ay * bz - az * by,
                     aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw,
                     aw * bw - ax * bx - ay * by - az * bz])


def q_mat(q):
    x, y, z, w = q / np.linalg.norm(q)
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def mat_q(m):
    t = m[0, 0] + m[1, 1] + m[2, 2]
    if t > 0:
        s = np.sqrt(t + 1.0) * 2
        q = [(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, 0.25 * s]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = [0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s]
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = [(m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s]
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = [(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s, (m[1, 0] - m[0, 1]) / s]
    q = np.array(q)
    return q / np.linalg.norm(q)


def unit(v):
    return v / np.linalg.norm(v)


MIRROR = np.diag([-1.0, 1.0, 1.0])


# --------------------------------------------------------------------------------------------- fitting

class Surface:
    """One arm's mesh, welded: walks over it, rings round a finger"""

    def __init__(self, points, tris):
        self.p = points
        self.t = tris
        self.adj = [[] for _ in points]
        for tri in tris:
            for a, b in ((tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])):
                w = float(np.linalg.norm(points[a] - points[b]))
                self.adj[a].append((b, w))
                self.adj[b].append((a, w))

    def walk(self, sources, limit=1e9):
        """Distance over the surface from `sources` to every vertex (inf past `limit`)"""
        dist = np.full(len(self.p), np.inf)
        heap = [(0.0, s) for s in sources]
        for s in sources:
            dist[s] = 0.0
        while heap:
            d, u = heapq.heappop(heap)
            if d > dist[u] or d > limit:
                continue
            for v, w in self.adj[u]:
                if d + w < dist[v]:
                    dist[v] = d + w
                    heapq.heappush(heap, (d + w, v))
        return dist

    def rings(self, from_tip, upto=0.2, step=0.004, half=0.006):
        """[distance from the tip, centre xyz, mean radius] of the band of surface at each distance"""
        rows = []
        for at in np.arange(step, upto, step):
            m = (from_tip >= at - half) & (from_tip < at + half)
            if m.sum() >= 4:
                c = self.p[m].mean(0)
                rows.append([at, *c, np.linalg.norm(self.p[m] - c, axis=1).mean()])
        return np.array(rows)


def on_line(rows, at, win=0.016):
    """The centreline at distance `at` from the tip: the ring centres about it, straightened"""
    w = np.exp(-0.5 * ((rows[:, 0] - at) / (win / 2)) ** 2)
    w[np.abs(rows[:, 0] - at) > win * 1.5] = 0
    a = np.stack([np.ones(len(rows)), rows[:, 0] - at], 1) * w[:, None]
    return np.linalg.lstsq(a, rows[:, 1:4] * w[:, None], rcond=None)[0][0]


def fit_right_arm(surf):
    """The right arm's joints (mesh units): shoulder, elbow, wrist, and per finger its chain of joints"""
    p = surf.p
    # the arm: shoulder end, elbow, wrist off the sleeve's centreline (area-weighted, so the pouch's dense
    # triangles don't drag it)
    tri_c = p[surf.t].mean(1)
    tri_a = 0.5 * np.linalg.norm(np.cross(p[surf.t[:, 1]] - p[surf.t[:, 0]], p[surf.t[:, 2]] - p[surf.t[:, 0]]), axis=1)
    sleeve = tri_c[:, 1] < 0.80
    start = tri_c[tri_c[:, 1] < 0.06].mean(0)
    axis = unit(tri_c[(tri_c[:, 1] > 0.70) & sleeve].mean(0) - start)
    along = (tri_c - start) @ axis

    def centre_at(at, half=0.025):
        m = sleeve & (np.abs(along - at) < half)
        return (tri_c[m] * tri_a[m, None]).sum(0) / tri_a[m].sum()

    line = [centre_at(at) for at in np.arange(0.02, along[sleeve].max(), 0.005)]

    def at_height(y):
        return min(line, key=lambda c: abs(c[1] - y))

    shoulder, elbow, wrist = line[0], at_height(ELBOW_AT), at_height(WRIST_AT)
    fore = unit(wrist - elbow)

    from_sleeve = surf.walk(np.where(p[:, 1] < SLEEVE_BELOW)[0])
    # fingertips: the far ends of the walk, thin all the way down (a knuckle pad is a far end too, but fat)
    tips = []
    for i in np.argsort(-from_sleeve):
        if from_sleeve[i] < 0.08:
            break
        if any(np.linalg.norm(p[i] - p[t["at"]]) < 0.035 for t in tips):
            continue
        near = surf.walk([i], 0.03) < 0.03
        if from_sleeve[i] < from_sleeve[near].max() - 1e-9:
            continue
        from_tip = surf.walk([i], 0.25)
        rows = surf.rings(from_tip)
        r0 = np.median(rows[(rows[:, 0] > 0.03) & (rows[:, 0] < 0.075), 4])
        if r0 < 0.027:
            fat = np.where((rows[:, 0] > 0.06) & (rows[:, 4] > 1.4 * r0))[0]
            tips.append({"at": i, "tip": p[i], "from_tip": from_tip, "rows": rows, "r": r0,
                         "free": rows[fat[0], 0] if len(fat) else rows[-1, 0]})
    if len(tips) != 5:
        raise SystemExit("expected 5 fingertips on the right hand, found %d" % len(tips))
    tips.sort(key=lambda t: from_sleeve[t["at"]])
    thumb, rest = tips[0], tips[1:]                     # the thumb's tip is the nearest the sleeve

    # the palm's normal: the hand between the wrist and the fingers is flat, so most of its surface faces
    # one way or the other along it. Signed to point out of the palm, the way the fingers curl
    past = (p - wrist) @ fore
    flat_of = (past > 0.01) & (thumb["from_tip"] > THUMB_MCP)
    for f in rest:
        flat_of &= f["from_tip"] > f["free"]
    t = surf.t[flat_of[surf.t].all(1)]
    faces = np.cross(p[t[:, 1]] - p[t[:, 0]], p[t[:, 2]] - p[t[:, 0]])
    area = np.linalg.norm(faces, axis=1)
    faces /= np.maximum(area, 1e-12)[:, None]
    palm = np.linalg.eigh((faces * area[:, None]).T @ faces)[1][:, 2]
    curl = sum(f["tip"] - on_line(f["rows"], f["free"] * 0.6) for f in rest)
    palm = palm if palm @ curl > 0 else -palm

    hand = {"Thumb": thumb}
    thumb["j"] = [None, on_line(thumb["rows"], THUMB_MCP), on_line(thumb["rows"], THUMB_IP)]
    thumb["j"][0] = wrist + (thumb["j"][1] - wrist) * THUMB_CMC
    for f in rest:
        length = f["free"] / FREE
        clear = f["rows"][(f["rows"][:, 0] < f["free"] - 0.006) & (f["rows"][:, 4] < 1.25 * f["r"])]
        pts = np.vstack([clear[:, 1:4], f["tip"][None]])
        centre = pts.mean(0)
        # a finger curls in a plane that stands on the palm: seen from the back of the hand it is a straight
        # strip, and its knuckle lies on that strip's line however the rings near the web pull
        level = (pts - centre) - np.outer((pts - centre) @ palm, palm)
        strip = np.linalg.svd(level)[2][0]
        side = np.cross(palm, strip)

        def flat(q, centre=centre, side=side):
            return q - side * np.dot(q - centre, side)

        dip = flat(on_line(f["rows"], PHALANX[2] * length))
        pip_ = flat(on_line(f["rows"], (PHALANX[2] + PHALANX[1]) * length))
        base = flat(on_line(f["rows"], f["free"] - 0.012))
        f["j"] = [pip_ + unit(base - pip_) * PHALANX[0] * length, pip_, dip]
        f["side"] = side
        f["end"] = flat(f["tip"])
    # the knuckles lie in a row under the back of the hand: all as deep as the second shallowest was found
    depth = sorted(f["j"][0] @ palm for f in rest)[1]
    for f in rest:
        f["j"][0] = f["j"][0] + palm * (depth - f["j"][0] @ palm)
    # index to little: by how far each knuckle is from the thumb's
    rest.sort(key=lambda f: np.linalg.norm(f["j"][0] - thumb["j"][1]))
    for name, f in zip(FINGERS, rest):
        hand[name] = f
    return hand, {"shoulder": shoulder, "elbow": elbow, "wrist": wrist, "palm": palm}


def frame(y, x_hint):
    """Basis with +Y along `y` and +X as near `x_hint` as that allows (columns x, y, z)"""
    y = unit(y)
    x = unit(x_hint - y * np.dot(x_hint, y))
    return np.stack([x, y, np.cross(x, y)], 1)


def torch_radius(path):
    """The barrel's radius (metres) where the hand takes it, with the torch fitted the way torch_model.gd does"""
    doc, blob = load_glb(path)
    pts = []

    def walk(i, above):
        n = doc["nodes"][i]
        m = np.eye(4)
        if "matrix" in n:
            m = np.array(n["matrix"], float).reshape(4, 4).T
        else:
            m[:3, :3] = q_mat(np.array(n.get("rotation", [0, 0, 0, 1]), float)) * np.array(n.get("scale", [1, 1, 1]), float)
            m[:3, 3] = n.get("translation", [0, 0, 0])
        m = above @ m
        if "mesh" in n:
            for prim in doc["meshes"][n["mesh"]]["primitives"]:
                v = accessor(doc, blob, prim["attributes"]["POSITION"]).astype(float)
                pts.append(v @ m[:3, :3].T + m[:3, 3])
        for c in n.get("children", []):
            walk(c, m)

    for root in doc["scenes"][doc.get("scene", 0)]["nodes"]:
        walk(root, np.eye(4))
    pts = np.vstack(pts)
    size = pts.max(0) - pts.min(0)
    long = int(np.argmax(size))
    pts = (pts - (pts.max(0) + pts.min(0)) / 2) * (TORCH_LENGTH / size[long])
    along = pts[:, long]
    off = np.linalg.norm(np.delete(pts, long, 1), axis=1)
    # the head is the fat end; the hand is TORCH_BACK behind the middle, a palm's width of barrel
    head = 1.0 if off[along > 0].max() > off[along < 0].max() else -1.0
    under = np.abs(along + head * TORCH_BACK) < 0.045
    return float(off[under].max())


def to_line(points, at, axis):
    """How far each point is from the line through `at` along `axis`"""
    d = np.atleast_2d(points) - at
    return np.linalg.norm(d - np.outer(d @ axis, axis), axis=1)


def about(axis, angle):
    """Rotation matrix: `angle` (rad) about `axis`"""
    x, y, z = unit(axis) * np.sin(angle / 2)
    return q_mat(np.array([x, y, z, np.cos(angle / 2)]))


def solve_grip(axis, radius, palm, fingers, thumb, row, across_old):
    """The right hand closed on the torch, all in the hand's space (+X index side, +Y fingers, +Z out of the palm).
    `axis`: the way the torch points; `palm`: the palm's skin; `fingers`: index..little, each its joints +
    tip, curl axis and thickness; `thumb` likewise; `row`: the middle of the knuckle row.
    Returns the seat (where TorchGrip goes), each finger joint's bend and its bend at rest (degrees), and the
    thumb bones' swings from rest (matrices, in the hand's space)."""
    axis = unit(axis)
    # seat it: the barrel across the palm under the knuckles, pressed in until it touches skin. Of the
    # places it can lie, the one it sinks deepest into (the hollow of the palm) holds it
    best = None
    for back in np.arange(0.015, 0.09, 0.005):
        at = np.array([row[0], row[1] - back, 0.25])
        while at[2] > 0.0 and (to_line(palm, at, axis) > radius * 0.95).all():
            at = at - [0, 0, 0.002]
        at = at + [0, 0, 0.002]
        # the knuckle bones have to get round it: not so near the knuckles that they would start inside
        clear = min(to_line(f["at"][0], at, axis)[0] - radius - f["r"] * SQUEEZE for f in fingers)
        if clear > 0 and (best is None or at[2] < best[2]):
            best = at
    seat = best + axis * ((row[0] + across_old - best[0]) / axis[0])   # as far across the palm as it was

    bends, rests = [], []
    for f in fingers:
        pts = [np.array(q) for q in f["at"]]
        x = unit(f["x"])
        dirs = [unit(pts[k + 1] - pts[k]) for k in range(3)]
        lens = [np.linalg.norm(pts[k + 1] - pts[k]) for k in range(3)]
        level = unit(np.cross([0, 0, 1.0], x))                       # the finger straight out, flat with the palm
        up = np.cross(x, level)
        angle = lambda d: np.degrees(np.arctan2(d @ up, d @ level))  # how far a bone points into the palm
        rest = [angle(dirs[0]), angle(dirs[1]) - angle(dirs[0]), angle(dirs[2]) - angle(dirs[1])]
        bend = []
        at, heading = pts[0], 0.0
        for k in range(3):
            lo, hi = FLEX[k]
            got = hi
            for deg in np.arange(lo, hi + 0.5, 1.0):
                total = np.radians(heading + deg)
                d = level * np.cos(total) + up * np.sin(total)
                # (its far half: the near end starts out where the bone before it came to rest)
                along = at + np.outer(np.linspace(0.3 if k == 0 else 0.5, 1.0, 7), d) * lens[k]
                if to_line(along, seat, axis).min() <= radius + f["r"] * SQUEEZE:
                    got = deg
                    break
            bend.append(float(got))
            heading += got
            total = np.radians(heading)
            at = at + (level * np.cos(total) + up * np.sin(total)) * lens[k]
        bends.append(bend)
        rests.append([float(r) for r in rest])

    # the thumb: laid along the top of the barrel, pointing at the head. Each bone swings from where it
    # rests (no twist); a search over the three swings for the pose that lies on the barrel without sinking
    # in, as near along it and as near rest as that allows
    pts = [np.array(q) for q in thumb["at"]]
    dirs = [unit(pts[k + 1] - pts[k]) for k in range(3)]
    lens = [np.linalg.norm(pts[k + 1] - pts[k]) for k in range(3)]
    reach = radius + thumb["r"] * SQUEEZE
    limit = np.radians([55.0, 60.0, 70.0])

    def laid(v):
        swings, at, total, joints = [], pts[0], np.eye(3), [pts[0]]
        for k in range(3):
            d = total @ dirs[k]
            side = unit(np.cross(d, [0.3, 0.2, 1.0]))
            swing = about(side, v[2 * k]) @ about(np.cross(d, side), v[2 * k + 1])
            total = swing @ total
            swings.append(total.copy())
            at = at + (total @ dirs[k]) * lens[k]
            joints.append(at)
        return swings, joints

    def cost(v):
        swings, joints = laid(v)
        c = 0.0
        for k in range(3):
            along = joints[k] + np.outer(np.linspace(0.2 if k == 0 else 0.0, 1.0, 6), joints[k + 1] - joints[k])
            sunk = np.maximum(0.0, reach - to_line(along, seat, axis))
            c += 4000.0 * (sunk ** 2).sum()
            c += 3.0 * max(0.0, np.hypot(v[2 * k], v[2 * k + 1]) - limit[k]) ** 2
        c += 300.0 * ((to_line(joints[3], seat, axis)[0] - reach) ** 2 + (to_line(joints[2], seat, axis)[0] - reach) ** 2)
        c += 0.05 * (1.0 - unit(joints[3] - joints[2]) @ axis) + 0.03 * (1.0 - unit(joints[2] - joints[1]) @ axis)
        c += 0.004 * float(v @ v)
        c += 2.0 * max(0.0, 0.01 - joints[3][2]) ** 2               # over the top, not round under the palm
        return c

    rng = np.random.default_rng(7)
    v = np.zeros(6)
    best_c = cost(v)
    spread = 0.4
    for i in range(6000):
        trial = v + rng.normal(0.0, spread, 6)
        c = cost(trial)
        if c < best_c:
            v, best_c = trial, c
        if i % 500 == 499:
            spread *= 0.6
    swings, joints = laid(v)
    return {"seat": seat, "bend": bends, "rest_bend": rests, "thumb": swings, "thumb_at": joints}


# ------------------------------------------------------------------------------------------------ main

def main():
    args = sys.argv[1:]
    new_path = Path(args[0]) if len(args) > 0 else NEW
    old_path = Path(args[1]) if len(args) > 1 else OLD
    out_path = Path(args[2]) if len(args) > 2 else OUT

    # ---- the new mesh
    doc, blob = load_glb(new_path)
    prim = doc["meshes"][0]["primitives"][0]
    pos = accessor(doc, blob, prim["attributes"]["POSITION"]).astype(np.float64)
    nrm = accessor(doc, blob, prim["attributes"]["NORMAL"]).astype(np.float32)
    uv = accessor(doc, blob, prim["attributes"]["TEXCOORD_0"]).astype(np.float32)
    tris = accessor(doc, blob, prim["indices"]).reshape(-1, 3).astype(np.int64)
    img = doc["images"][doc["textures"][doc["materials"][prim["material"]]["pbrMetallicRoughness"]["baseColorTexture"]["index"]]["source"]]
    img_view = doc["bufferViews"][img["bufferView"]]
    image = blob[img_view.get("byteOffset", 0):img_view.get("byteOffset", 0) + img_view["byteLength"]]

    right = pos[:, 0] > 0
    welded, weld = np.unique(np.round(pos[right], 5), axis=0, return_inverse=True)
    weld = weld.ravel()
    to_right = -np.ones(len(pos), np.int64)
    to_right[right] = weld
    r_tris = to_right[tris]
    r_tris = r_tris[(r_tris >= 0).all(1)]
    surf = Surface(welded, r_tris)
    hand, arm = fit_right_arm(surf)

    # ---- the old rig
    odoc, oblob = load_glb(old_path)
    onodes = odoc["nodes"]
    oid = {n["name"]: i for i, n in enumerate(onodes)}
    oparent = {c: i for i, n in enumerate(onodes) for c in n.get("children", [])}

    def old_local(name):
        n = onodes[oid[name]]
        return np.array(n.get("translation", [0, 0, 0]), float), np.array(n.get("rotation", [0, 0, 0, 1]), float)

    def old_global(name):
        t, q = old_local(name)
        m = q_mat(q)
        i = oid[name]
        while i in oparent and onodes[oparent[i]].get("name") in oid and "rotation" in onodes[oparent[i]]:
            i = oparent[i]
            pt, pq = old_local(onodes[i]["name"])
            t = q_mat(pq) @ t + pt
            m = q_mat(pq) @ m
        return t, m

    old_hand = old_global("RightHand")[1]

    # ---- joints: the hand's frame, then every bone's
    shoulder, elbow, wrist = arm["shoulder"], arm["elbow"], arm["wrist"]
    # the hand: +X along the knuckle row towards the index, +Z out of the palm, +Y the way the fingers head.
    # (On the old arms that was also the line from the wrist to the middle knuckle. Here the sleeve's
    # centreline comes into the glove on the thumb's side of the palm, so that line is 30 degrees off the
    # fingers; a frame built on it has every clip bend the fingers sideways at the knuckles.)
    across = unit(hand["Index"]["j"][0] - hand["Little"]["j"][0])
    out_of_palm = unit(arm["palm"] - across * (arm["palm"] @ across))
    new_hand = np.stack([across, np.cross(out_of_palm, across), out_of_palm], 1)
    carry = new_hand @ old_hand.T                                    # old rig space -> new, through the hands

    def like(name, y):
        """The new frame for old bone `name`: +Y along `y`, rolled the way the old bone was"""
        return frame(y, carry @ old_global(name)[1][:, 0])

    bones = {}                                                       # name (no side) -> (origin, basis), right arm
    bones["LowerArm"] = (elbow, like("RightLowerArm", wrist - elbow))
    bones["Hand"] = (wrist, new_hand)
    bones["UpperArm"] = (elbow, frame(shoulder - elbow, bones["LowerArm"][1][:, 0]))
    chains = {}
    turn = {}                                                        # old bone -> new axes, about the bone
    for f in FINGERS + ["Thumb"]:
        names = THUMB if f == "Thumb" else [f + j for j in JOINTS]
        pts = hand[f]["j"] + [hand[f]["tip"] if f == "Thumb" else hand[f]["end"]]
        chains[f] = pts
        for k, n in enumerate(names):
            if f == "Thumb":
                bones[n] = (pts[k], like("Right" + n, pts[k + 1] - pts[k]))
            else:
                side = hand[f]["side"] if hand[f]["side"] @ across > 0 else -hand[f]["side"]
                bones[n] = (pts[k], frame(pts[k + 1] - pts[k], side))
                was = old_global("Right" + n)[1]
                turn[n] = was.T @ frame(was[:, 1], old_hand[:, 0])
    parent = {"LowerArm": None, "Hand": "LowerArm", "UpperArm": "LowerArm"}
    for f in FINGERS + ["Thumb"]:
        names = THUMB if f == "Thumb" else [f + j for j in JOINTS]
        for k, n in enumerate(names):
            parent[n] = "Hand" if k == 0 else names[k - 1]

    # ---- weights, right arm (welded)
    order = ["LowerArm", "Hand"] + THUMB + [f + j for f in FINGERS for j in JOINTS] + ["UpperArm"]
    col = {n: i for i, n in enumerate(order)}
    w = np.zeros((len(welded), len(order)))
    fore = unit(wrist - elbow)
    past_wrist = (welded - wrist) @ fore
    through = unit(fore - unit(shoulder - elbow))                    # along the arm through the elbow
    past_elbow = (welded - elbow) @ through

    def seg_dist(a, b):
        d = b - a
        t = np.clip(((welded - a) @ d) / (d @ d), 0, 1)
        return np.linalg.norm(welded - (a + t[:, None] * d), axis=1)

    def step(x, lo, hi):
        t = np.clip((x - lo) / (hi - lo), 0, 1)
        return t * t * (3 - 2 * t)

    # the hand, hard: free fingers first, then the rest by the nearest of palm / thumb base / knuckles
    owner = np.full(len(welded), -1)
    claim = np.full(len(welded), np.inf)
    for f in FINGERS + ["Thumb"]:
        reach = THUMB_MCP if f == "Thumb" else hand[f]["free"]
        share = hand[f]["from_tip"] / reach
        take = (share < 1.0) & (share < claim)
        names = THUMB if f == "Thumb" else [f + j for j in JOINTS]
        pts = chains[f]
        d = np.stack([seg_dist(pts[k], pts[k + 1]) for k in range(3)], 1)
        owner[take] = np.array([col[n] for n in names])[d.argmin(1)][take]
        claim[take] = share[take]
    cands = [(col["Hand"], wrist, hand[f]["j"][0]) for f in FINGERS]
    cands.append((col[THUMB[0]], chains["Thumb"][0], chains["Thumb"][1]))
    cands += [(col[f + JOINTS[0]], chains[f][0], chains[f][1]) for f in FINGERS]
    d = np.stack([seg_dist(a, b) for _, a, b in cands], 1)
    nearest = np.array([c[0] for c in cands])[d.argmin(1)]
    owner = np.where(owner < 0, nearest, owner)
    hard = np.zeros_like(w)
    hard[np.arange(len(welded)), owner] = 1.0
    in_hand = past_wrist > WRIST_BLEND[0]
    nbrs = [sorted({v for v, _ in surf.adj[i] if in_hand[v]}) for i in range(len(welded))]
    for _ in range(SMOOTH):
        nxt = hard.copy()
        for i in np.where(in_hand)[0]:
            if nbrs[i]:
                nxt[i] = 0.5 * hard[i] + 0.5 * hard[nbrs[i]].mean(0)
        hard = nxt
    to_hand = step(past_wrist, *WRIST_BLEND)
    to_fore = step(past_elbow, *ELBOW_BLEND)
    w = hard * to_hand[:, None]
    w[:, col["LowerArm"]] += (1 - to_hand) * to_fore
    w[:, col["UpperArm"]] += (1 - to_hand) * (1 - to_fore)
    # four bones a vertex at most
    keep = np.argsort(-w, axis=1)[:, :4]
    w4 = np.take_along_axis(w, keep, 1)
    w4 /= w4.sum(1, keepdims=True)

    # ---- nodes: the old file's, with the two upper arms added
    nodes = json.loads(json.dumps(onodes))
    for side in ("Left", "Right"):
        nodes.append({"name": side + "UpperArm"})
        nodes[oid[side + "LowerArm"]].setdefault("children", []).append(len(nodes) - 1)
    nid = {n["name"]: i for i, n in enumerate(nodes)}
    skin_joints = list(odoc["skins"][0]["joints"]) + [nid["LeftUpperArm"], nid["RightUpperArm"]]
    slot = {j: k for k, j in enumerate(skin_joints)}
    globals_ = {"Root": (np.zeros(3), np.eye(3))}
    for side in ("Left", "Right"):
        for n in order:
            o, b = bones[n]
            globals_[side + n] = (o, b) if side == "Right" else (MIRROR @ o, MIRROR @ b @ MIRROR)
    for side in ("Left", "Right"):
        for n in order:
            o, b = globals_[side + n]
            po, pb = globals_[side + parent[n]] if parent[n] else globals_["Root"]
            node = nodes[nid[side + n]]
            node["translation"] = (pb.T @ (o - po)).tolist()
            node["rotation"] = mat_q(pb.T @ b).tolist()

    # ---- the torch grip (right hand, in the hand's space)
    in_hand_space = lambda q: new_hand.T @ (np.asarray(q) - wrist)
    grip = nodes[nid["TorchGrip"]]
    grip_rot = q_mat(np.array(grip["rotation"]))
    barrel = torch_radius(TORCH) / ARMS_SCALE
    soft = w[:, col["Hand"]] > 0.6                                   # the palm proper: not the fingers, not the thumb's mound
    grasp = solve_grip(
        axis=-grip_rot[:, 2], radius=barrel, palm=(welded[soft] - wrist) @ new_hand,
        fingers=[{"at": [in_hand_space(q) for q in chains[f]], "x": new_hand.T @ bones[f + JOINTS[0]][1][:, 0],
                  "r": hand[f]["r"]} for f in FINGERS],
        thumb={"at": [in_hand_space(q) for q in chains["Thumb"]], "r": hand["Thumb"]["r"]},
        row=(in_hand_space(hand["Index"]["j"][0]) + in_hand_space(hand["Little"]["j"][0])) / 2,
        across_old=old_local("TorchGrip")[0][0] - (old_local("RightIndexProximal")[0][0] + old_local("RightLittleProximal")[0][0]) / 2)
    grip["translation"] = grasp["seat"].tolist()
    held = {}                                                        # bone -> local rotation in the grip
    for k, f in enumerate(FINGERS):
        for j, n in enumerate(JOINTS):
            rest = np.array(nodes[nid["Right" + f + n]]["rotation"])
            bend = np.radians(grasp["bend"][k][j] - grasp["rest_bend"][k][j])
            held[f + n] = q_mul(rest, np.array([np.sin(bend / 2), 0.0, 0.0, np.cos(bend / 2)]))

    def thumb_turns(swings):
        """The thumb bones' local rotations for swings from rest given in the hand's space"""
        turns, was_in_hand, now_in_hand = {}, np.eye(3), np.eye(3)
        for j, n in enumerate(THUMB):
            was_in_hand = was_in_hand @ q_mat(np.array(nodes[nid["Right" + n]]["rotation"]))
            goal = swings[j] @ was_in_hand
            turns[n] = mat_q(now_in_hand.T @ goal)
            now_in_hand = goal
        return turns

    held.update(thumb_turns(grasp["thumb"]))
    # flat on a wall: each thumb bone swung (no twist) to lie beside the palm, splayed off the fingers
    thumb_dirs = [unit(in_hand_space(chains["Thumb"][k + 1]) - in_hand_space(chains["Thumb"][k])) for k in range(3)]
    swings, total = [], np.eye(3)
    for k, deg in enumerate(PALM_THUMB):
        goal = unit(np.array([np.sin(np.radians(deg)), np.cos(np.radians(deg)), -PALM_LIFT]))
        now = total @ thumb_dirs[k]
        axis = np.cross(now, goal)
        total = about(axis, np.arctan2(np.linalg.norm(axis), now @ goal)) @ total
        swings.append(total)
    flat_thumb = thumb_turns(swings)

    ibm = np.zeros((len(skin_joints), 16), np.float32)
    for k, j in enumerate(skin_joints):
        o, b = globals_[nodes[j]["name"]]
        m = np.eye(4)
        m[:3, :3] = b.T
        m[:3, 3] = -b.T @ o
        ibm[k] = m.T.ravel()                                         # column-major

    # ---- the two meshes
    out = Writer()
    left_of = np.empty(0)
    meshes = []
    for side in ("Left", "Right"):
        mine = right if side == "Right" else ~right
        index = np.where(mine)[0]
        if side == "Right":
            src = weld
        else:                                                        # each left vertex takes its mirror's weights
            flipped = pos[index] * [-1, 1, 1]
            src = np.array([np.argmin(((welded - v) ** 2).sum(1)) for v in flipped])
            left_of = np.linalg.norm(welded[src] - flipped, axis=1)
        joints = np.array([[slot[nid[side + order[c]]] for c in row] for row in keep[src]], np.uint8)
        weights = w4[src].astype(np.float32)
        joints[weights == 0] = 0
        renum = -np.ones(len(pos), np.int64)
        renum[index] = np.arange(len(index))
        t = renum[tris]
        t = t[(t >= 0).all(1)]
        attrs = {"POSITION": out.add(pos[index].astype(np.float32), "VEC3", 34962, True),
                 "NORMAL": out.add(nrm[index], "VEC3", 34962),
                 "TEXCOORD_0": out.add(uv[index], "VEC2", 34962),
                 "JOINTS_0": out.add(joints, "VEC4", 34962),
                 "WEIGHTS_0": out.add(weights, "VEC4", 34962)}
        meshes.append({"name": side + "Arm", "primitives": [{"mode": 4, "material": 0, "attributes": attrs,
                                                               "indices": out.add(t.astype(np.uint16).ravel(), "SCALAR", 34963)}]})
    ibm_acc = out.add(ibm, "MAT4")

    # ---- the clips
    old_len = old_local("RightHand")[0][1]
    new_len = float(np.linalg.norm(wrist - elbow))
    anims = []
    hold_pose = {}
    for a in odoc["animations"]:
        tracks = {}
        for ch in a["channels"]:
            s = a["samplers"][ch["sampler"]]
            tracks[(onodes[ch["target"]["node"]]["name"], ch["target"]["path"])] = (
                accessor(odoc, oblob, s["input"]).astype(np.float32), accessor(odoc, oblob, s["output"]).astype(np.float32),
                s.get("interpolation", "LINEAR"))
        times = {}
        samplers = []
        channels = []
        for (name, path), (t_in, val, interp) in tracks.items():
            bone = name[4:] if name.startswith("Left") else name[5:]
            if path == "rotation" and name.startswith("Right") and bone in held and a["name"].startswith("Torch"):
                val = np.repeat(held[bone][None], len(val), 0).astype(np.float32)
            elif path == "rotation" and bone in turn:
                # the same pose in the hand's space, for a bone (and a parent) whose axes are rolled differently
                flip = MIRROR if name.startswith("Left") else np.eye(3)
                mine = flip @ turn[bone] @ flip
                above = flip @ turn[parent[bone]] @ flip if parent[bone] in turn else np.eye(3)
                val = np.array([mat_q(above.T @ q_mat(q.astype(np.float64)) @ mine) for q in val], np.float32)
            if path == "translation" and name.endswith("LowerArm"):
                rt, rv, _ = tracks[(name, "rotation")]
                moved = val.astype(np.float64).copy()
                for k, at in enumerate(t_in):
                    i = min(np.searchsorted(rt, at), len(rt) - 1)
                    moved[k] += q_mat(rv[i].astype(np.float64)) @ np.array([0.0, old_len - new_len, 0.0])
                val = moved.astype(np.float32)
            if a["name"] == HOLD:
                hold_pose[(name, path)] = val[0].astype(np.float64)
            key = t_in.tobytes()
            if key not in times:
                times[key] = out.add(t_in, "SCALAR", bounds=True)
            samplers.append({"input": times[key], "output": out.add(val, "VEC3" if path != "rotation" else "VEC4"),
                             "interpolation": interp})
            channels.append({"sampler": len(samplers) - 1, "target": {"node": nid[name], "path": path}})
        anims.append({"name": a["name"], "samplers": samplers, "channels": channels})

    # the wall pose: two keys of the same thing
    samplers, channels = [], []
    moment = out.add(np.array([0.0, 0.1], np.float32), "SCALAR", bounds=True)
    for side in ("Left", "Right"):
        for n in THUMB:
            q = flat_thumb[n] if side == "Right" else flat_thumb[n] * [1, -1, -1, 1]
            samplers.append({"input": moment, "output": out.add(np.repeat(q[None], 2, 0).astype(np.float32), "VEC4"),
                             "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers) - 1, "target": {"node": nid[side + n], "path": "rotation"}})
    anims.append({"name": PALM, "samplers": samplers, "channels": channels})

    # ---- the fidgets: the hold's first pose, with a few bones moved over it
    def curve(*keys):
        """f(t) through (time, value) keys, eased from each to the next; flat before the first and after the last"""
        ts = np.array([k[0] for k in keys])
        vs = np.array([k[1] for k in keys])

        def f(t):
            i = int(np.clip(np.searchsorted(ts, t, side="right") - 1, 0, len(ts) - 2))
            u = float(np.clip((t - ts[i]) / (ts[i + 1] - ts[i]), 0.0, 1.0))
            return vs[i] + (vs[i + 1] - vs[i]) * u * u * (3.0 - 2.0 * u)
        return f

    def spun(bone, axis, degrees):
        """The hold's rotation of `bone`, turned `degrees(t)` about its own `axis` (0 x, 1 y, 2 z)"""
        base = hold_pose[("Right" + bone, "rotation")]

        def f(t):
            half = np.radians(degrees(t)) / 2
            q = np.zeros(4)
            q[axis], q[3] = np.sin(half), np.cos(half)
            return q_mul(base, q)
        return f

    def curled(amount, degrees, delay=0.0, fingers=FINGERS):
        """Every joint of `fingers` bent `degrees` (knuckle, middle, tip) x `amount(t)` more than in the hold,
        each finger `delay` after the one before"""
        turns = {}
        for k, name in enumerate(fingers):
            for j, deg in enumerate(degrees):
                turns["Right" + name + JOINTS[j]] = spun(name + JOINTS[j], 0, lambda t, k=k, deg=deg: deg * amount(t - delay * k))
        return turns

    # the thumb off the barrel: its last two bones swung about the knuckle, straight away from the barrel
    thumb_at = grasp["thumb_at"]
    along_thumb = unit(thumb_at[2] - thumb_at[1])
    off = thumb_at[2] - grasp["seat"]
    barrel_axis = unit(-grip_rot[:, 2])
    lift_about = unit(np.cross(along_thumb, off - barrel_axis * (off @ barrel_axis)))

    def thumb_lifted(degrees):
        def bone(n):
            def f(t):
                lift = about(lift_about, np.radians(degrees(t)))
                return thumb_turns([grasp["thumb"][0], lift @ grasp["thumb"][1], lift @ grasp["thumb"][2]])[n]
            return f
        return {"Right" + n: bone(n) for n in THUMB}

    def clip(name, length, turns, moves=None):
        times = np.arange(0.0, length + 1e-6, 1.0 / 30.0).astype(np.float32)
        when = out.add(times, "SCALAR", bounds=True)
        samplers, channels = [], []
        for (node, path), base in hold_pose.items():
            f = (turns if path == "rotation" else moves or {}).get(node)
            val = np.array([f(float(t)) for t in times]) if f else np.repeat(base[None], len(times), 0)
            samplers.append({"input": when, "output": out.add(val.astype(np.float32), "VEC4" if path == "rotation" else "VEC3"),
                             "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers) - 1, "target": {"node": nid[node], "path": path}})
        anims.append({"name": name, "samplers": samplers, "channels": channels})

    grip_on = curve((0.0, 0.0), (0.22, 1.0), (0.70, 1.0), (0.98, -0.3), (1.40, 0.0), (1.50, 0.0))
    shaking = curve((0.0, 0.0), (0.22, 1.0), (0.70, 1.0), (0.85, 0.0), (1.50, 0.0))
    turns = curled(grip_on, (4.0, 8.0, 8.0), delay=0.025)
    turns.update(thumb_lifted(lambda t: -4.0 * grip_on(t)))
    turns["RightHand"] = spun("Hand", 0, lambda t: 4.0 * grip_on(t) + 0.4 * np.sin(2 * np.pi * 9.0 * t) * shaking(t))
    clip("TorchSqueeze", 1.5, turns)

    turns = {}
    for i, name in enumerate(reversed(FINGERS)):
        at = 0.1 + 0.2 * i
        up = curve((0.0, 0.0), (at, 0.0), (at + 0.22, 1.0), (at + 0.45, -0.15), (at + 0.70, 0.0), (1.65, 0.0))
        turns.update(curled(up, (-14.0, -20.0, -10.0), fingers=[name]))
    clip("TorchFingers", 1.65, turns)

    loose = curve((0.0, 0.0), (0.08, 0.0), (0.26, 1.0), (0.40, 1.0), (0.56, -0.35), (0.85, 0.05), (1.05, 0.0), (1.20, 0.0))
    turns = curled(loose, (-16.0, -22.0, -10.0), delay=0.02)
    turns.update(thumb_lifted(lambda t: 10.0 * loose(t)))
    turns["RightHand"] = spun("Hand", 0, lambda t: -3.0 * loose(t))
    clip("TorchRegrip", 1.2, turns)

    knock = curve((0.0, 0.0), (0.08, -5.0), (0.17, 14.0), (0.30, -1.0), (0.38, -4.0), (0.47, 9.0), (0.62, -1.0), (0.80, 0.0), (0.90, 0.0))
    clamp = curve((0.0, 0.0), (0.08, 1.0), (0.55, 1.0), (0.80, 0.0), (0.90, 0.0))
    turns = curled(clamp, (2.0, 4.0, 5.0))
    turns["RightHand"] = spun("Hand", 2, knock)
    fore_base = hold_pose[("RightLowerArm", "translation")]
    fore_along = q_mat(hold_pose[("RightLowerArm", "rotation")])[:, 1]
    clip("TorchSmack", 0.9, turns, {"RightLowerArm": lambda t: fore_base + fore_along * 0.0012 * knock(t)})

    # TorchAnchor: where TorchGrip is in the hold
    fore_q = hold_pose[("RightLowerArm", "rotation")]
    fore_at = hold_pose[("RightLowerArm", "translation")]
    hand_q = q_mul(fore_q, hold_pose[("RightHand", "rotation")])
    hand_at = fore_at + q_mat(fore_q) @ np.array(nodes[nid["RightHand"]]["translation"])
    nodes[nid["TorchAnchor"]]["translation"] = (hand_at + q_mat(hand_q) @ np.array(grip["translation"])).tolist()

    # ---- the battery swap
    spin_y = about([0, 1, 0], VIEW_ROT[1]) @ about([1, 0, 0], VIEW_ROT[0])
    from_view = lambda q: np.array(nodes[nid["TorchAnchor"]]["translation"]) + spin_y.T @ (np.asarray(q) - VIEW_POS) / ARMS_SCALE
    way = lambda d: spin_y.T @ np.asarray(d, float)                  # a direction, camera -> rig
    L = SWAP_LENGTH
    u = 1.0 / ARMS_SCALE                                             # units per metre

    def arc(a, b, part=1.0):
        """The shortest turn that takes direction `a` to `b`, or `part` of it"""
        axis = np.cross(unit(a), unit(b))
        return about(axis, part * np.arctan2(np.linalg.norm(axis), unit(a) @ unit(b))) if np.linalg.norm(axis) > 1e-9 else np.eye(3)

    def squared(a, f):
        f = unit(f - a * (f @ a))
        return np.stack([a, f, np.cross(a, f)], 1)

    def sprung(target, stiff, damp=0.7):
        """`target(t)` the way a hand follows an intention: through a damped spring (`stiff` rad/s; `damp`
        under 1 runs a little past and settles). The spring runs 2 damp / stiff s late, so the target is
        read that much early; over the last 0.2 s it's brought onto the target's last value exactly."""
        step = 1.0 / 240.0
        lead = 2.0 * damp / stiff
        ts = np.arange(0.0, L + step, step)
        ys = np.zeros(len(ts))
        y, v = float(target(0.0)), 0.0
        for i, t in enumerate(ts):
            ys[i] = y
            v += (stiff * stiff * (float(target(min(L, t + lead))) - y) - 2.0 * damp * stiff * v) * step
            y += v * step
        last = float(target(L))
        fade = np.clip((L - ts) / 0.2, 0.0, 1.0)
        ys = last + (ys - last) * fade * fade * (3.0 - 2.0 * fade)
        return lambda t: float(np.interp(t, ts, ys))

    def drift(seed, rate):
        """A slow wander in -1..1, a few sines that never line up: a hand held in the air isn't still"""
        r = np.random.default_rng(seed)
        f, ph, a = rate * r.uniform(0.6, 1.7, 4), r.uniform(0.0, 2 * np.pi, 4), r.uniform(0.5, 1.0, 4)
        return lambda t: float((a * np.sin(2 * np.pi * f * t + ph)).sum() / a.sum())

    fore_rot, hand_rot = q_mat(fore_q), q_mat(hand_q)
    grip_at = hand_at + hand_rot @ np.array(grip["translation"])
    aim = -(hand_rot @ grip_rot)[:, 2]
    # the right arm moves as one piece, turning about the grip: from the hold to the working pose
    whole = squared(unit(way(SWAP_AIM)), way(SWAP_FOREARM)) @ squared(aim, fore_rot[:, 1]).T
    whole_angle = np.arccos(np.clip((np.trace(whole) - 1) / 2, -1, 1))
    whole_axis = unit(np.array([whole[2, 1] - whole[1, 2], whole[0, 2] - whole[2, 0], whole[1, 0] - whole[0, 1]]))
    work_at = from_view(SWAP_AT)

    # the times things happen at (s). torch_model.gd SWAP_OUT / SWAP_IN / SWAP_CELLS and gen_battery_audio.py
    # are keyed on the same.
    UNSCREW = ((1.20, 1.50), (1.84, 2.12))                           # the two twists off, each from, to
    PULL = (2.18, 2.42)                                              # the cap drawn off
    TIP = (2.38, 2.73, 3.30, 3.72)                                   # the tail going down, down, coming back, level
    FETCH = (2.43, 2.88, 3.25, 3.70)                                 # the left hand leaving, gone, coming back, back
    PUSH = (3.86, 4.16)                                              # each new cell home
    CAP_ON = 4.52
    SCREW = ((4.62, 4.90), (5.22, 5.50))                             # and the two twists back on
    U0, U1, S0, S1 = UNSCREW + SCREW
    DONE = S1[1]

    # the right arm: the turn leads, the hand's place follows it in
    turned = sprung(curve((0.0, 0.0), (0.06, 0.0), (0.76, 1.0), (DONE + 0.12, 1.0), (DONE + 0.77, 0.0), (L, 0.0)), 16.0, 0.62)
    placed = sprung(curve((0.0, 0.0), (0.10, 0.0), (0.86, 1.0), (DONE + 0.16, 1.0), (DONE + 0.84, 0.0), (L, 0.0)), 12.0, 0.72)
    tipped = sprung(curve((0.0, 0.0), (TIP[0], 0.0), (TIP[1], 1.0), (TIP[2], 1.0), (TIP[3], 0.0), (L, 0.0)), 14.0, 0.65)
    shaken = curve((0.0, 0.0), (TIP[1] + 0.03, 0.0), (TIP[1] + 0.10, 0.20), (TIP[1] + 0.17, -0.06), (TIP[1] + 0.25, 0.15),
                   (TIP[1] + 0.34, 0.0), (L, 0.0))
    # what the left hand does to the torch: it rolls with a twist of the cap (the last one, tight, most),
    # and is shoved along itself by the cap coming off, each cell going home and the cap going back
    give = sprung(curve((0.0, 0.0), *[key for (a, b), most in ((U0, 1.0), (U1, 1.0), (S0, -1.0), (S1, -1.5))
                                      for key in ((a, 0.0), (a + 0.12, most), (b - 0.02, most), (b + 0.06, 0.0))], (L, 0.0)), 22.0, 0.5)
    shove = sprung(curve((0.0, 0.0), (PULL[1] - 0.08, 0.0), (PULL[1] - 0.02, -0.005), (PULL[1] + 0.08, 0.0), (PUSH[0] - 0.03, 0.0),
                         (PUSH[0] + 0.01, 0.008), (PUSH[0] + 0.12, 0.0), (PUSH[1] - 0.03, 0.0), (PUSH[1] + 0.01, 0.010),
                         (PUSH[1] + 0.12, 0.0), (CAP_ON - 0.03, 0.0), (CAP_ON + 0.02, 0.004), (CAP_ON + 0.11, 0.0), (L, 0.0)), 30.0, 0.45)
    clamp = sprung(curve((0.0, 0.0), (U0[0] - 0.10, 0.0), (U0[0] + 0.05, 1.0), (U1[1] + 0.02, 1.0), (U1[1] + 0.20, 0.3), (PUSH[0] - 0.10, 0.3),
                         (PUSH[0] - 0.02, 1.0), (DONE + 0.01, 1.0), (DONE + 0.17, 0.0), (L, 0.0)), 14.0, 0.7)
    sway = [drift(11 + k, 0.45) for k in range(5)]

    def right_arm(t):
        """The right forearm (rotation, origin), the grip and the way the torch points at `t`"""
        there = float(np.clip(placed(t), 0.0, 1.0))
        turn = about(way([0, 0, 1]), np.radians(SWAP_TIP) * (tipped(t) + shaken(t))) @ about(whole_axis, whole_angle * turned(t))
        turn = (about(way([1, 0, 0]), np.radians(0.9) * there * sway[0](t))
                @ about(way([0, 1, 0]), np.radians(0.9) * there * sway[1](t)) @ turn)
        points = turn @ aim
        turn = about(points, np.radians(SWAP_GIVE) * sense * give(t)) @ turn
        at = (grip_at + (work_at - grip_at) * placed(t) + points * shove(t) * u
              + way([0.0, -SWAP_DIP, 0.0]) * u * np.sin(np.pi * there)
              + way([sway[2](t), sway[3](t), sway[4](t)]) * 0.003 * u * there)
        return turn @ fore_rot, at + turn @ (fore_at - grip_at), at, points

    # the left hand holds the tail the way the right holds the barrel, mirrored: its grip's axis on the torch's
    left_grip_at = MIRROR @ np.array(grip["translation"])
    left_grip = MIRROR @ grip_rot @ MIRROR
    elbow_hint = from_view(SWAP_LEFT_ELBOW)
    work_points = unit(way(SWAP_AIM))
    stray = [drift(31 + k, 0.6) for k in range(3)]

    def left_arm(t, along, away, twist, sense, roll):
        """The left forearm (rotation, origin) and hand (local rotation) with its grip `along` the torch from
        the cap (units, + towards the head), `away` (0..1) to where it waits, turned `twist` about the torch.
        Its way there bows out (SWAP_SWING), and off the torch the wrist lets go of the angle it holds the
        cap at (SWAP_RELAX), so it cocks into the grip as it lands."""
        _, _, at, points = right_arm(t)
        off = float(np.clip(away, 0.0, 1.0))
        # off the torch it keeps to the place the torch is worked on, not to the torch: it isn't swung about
        # by the torch turning into place or tipping
        at = at + (work_at - at) * off
        points = unit(points + (work_points - points) * off)
        z = points * sense
        x = unit(np.cross(z, way([0, 1, 0])))
        x = x * np.cos(roll + twist) + np.cross(z, x) * np.sin(roll + twist)
        hand_l = np.stack([x, np.cross(z, x), z], 1) @ left_grip.T
        centre = (at - points * (TORCH_TAIL - 0.025) * u + points * along
                  + (way(SWAP_AWAY) * away + way(SWAP_SWING) * np.sin(np.pi * off)) * u
                  + way([stray[0](t), stray[1](t), stray[2](t)]) * 0.005 * u * off)
        run = unit(centre - hand_l @ left_grip_at - elbow_hint)
        hand_l = arc(hand_l[:, 1], run, SWAP_RELAX * off) @ hand_l
        wrist_l = centre - hand_l @ left_grip_at
        run = unit(wrist_l - elbow_hint)
        fore_l = arc(hand_l[:, 1], run) @ hand_l
        return fore_l, wrist_l - run * new_len, fore_l.T @ hand_l, np.degrees(np.arccos(np.clip(hand_l[:, 1] @ run, -1, 1)))

    # which way round the hand takes the cap: the way that bends the wrist least
    sense = 1.0
    sense, roll = min(((sn, r) for sn in (1.0, -1.0) for r in np.radians(np.arange(0, 360, 5))),
                      key=lambda c: left_arm(1.15, 0.0, 0.0, 0.0, *c)[3])
    # the new cells stick out of the fist towards the torch
    nodes.append({"name": "BatteryGrip", "rotation": mat_q(left_grip).tolist(),
                  "translation": (left_grip_at + left_grip[:, 2] * sense * 0.035 / ARMS_SCALE).tolist()})
    nodes[nid["LeftHand"]].setdefault("children", []).append(len(nodes) - 1)
    twist_at = np.radians(SWAP_TWIST)
    reach = {                                                        # the left hand's moves, each its own spring
        # along the torch: the cap drawn off, then (out of view) back behind the tail with the new pair,
        # one pushed home, a breath, the other, and up onto the tail with the cap
        "along": sprung(curve((0.0, 0.0), (PULL[0], 0.0), (PULL[1], -0.06 * u), (FETCH[1], -0.06 * u), (FETCH[2], -0.085 * u),
                              (PUSH[0] - 0.12, -0.085 * u), (PUSH[0], -0.045 * u), (PUSH[0] + 0.05, -0.045 * u), (PUSH[0] + 0.17, -0.075 * u),
                              (PUSH[1] - 0.11, -0.075 * u), (PUSH[1], -0.03 * u), (PUSH[1] + 0.08, -0.03 * u), (CAP_ON, 0.0), (L, 0.0)), 48.0, 0.85),
        # 1 waiting below the view, 0 on the torch: up to the cap, down for the new pair, back, and away
        "away": sprung(curve((0.0, 1.0), (0.38, 1.0), (1.04, 0.0), (FETCH[0], 0.0), (FETCH[1], 1.0), (FETCH[2], 1.0), (FETCH[3], 0.0),
                             (DONE + 0.08, 0.0), (DONE + 0.60, 1.0), (L, 1.0)), 15.0, 0.8),
        # about the torch, in turns of the cap either side of the easy angle: it takes hold wound back,
        # turns, lets go, winds back (unhurried: a quarter of a second), turns again
        "twist": sprung(curve((0.0, 0.0), (0.70, 0.0), (1.04, -0.5), (U0[0], -0.5), (U0[1], 0.5), (U0[1] + 0.07, 0.5), (U1[0] - 0.03, -0.5),
                              (U1[0], -0.5), (U1[1], 0.5), (FETCH[0], 0.5), (FETCH[1], 0.0), (PUSH[1] + 0.08, 0.0), (CAP_ON, 0.5),
                              (S0[0], 0.5), (S0[1], -0.5), (S0[1] + 0.06, -0.5), (S1[0] - 0.02, 0.5), (S1[0], 0.5), (S1[1], -0.5),
                              (DONE + 0.10, -0.5), (DONE + 0.45, 0.0), (L, 0.0)), 24.0, 0.8),
        # 1 the hand hanging open, 0 shut on the cap: it lets go between twists, keeps the cap and then
        # the cells in a loose fist
        "open": sprung(curve((0.0, 1.0), (0.75, 1.0), (0.98, 0.7), (U0[0] - 0.03, 0.0), (U0[1], 0.0), (U0[1] + 0.07, 0.45), (U1[0] - 0.09, 0.45),
                             (U1[0] - 0.02, 0.0), (FETCH[0], 0.0), (FETCH[1], 0.12), (PUSH[1], 0.12), (PUSH[1] + 0.08, 0.3),
                             (CAP_ON - 0.07, 0.3), (CAP_ON + 0.03, 0.0), (S0[1], 0.0), (S0[1] + 0.07, 0.45), (S1[0] - 0.09, 0.45),
                             (S1[0] - 0.02, 0.0), (DONE + 0.02, 0.0), (DONE + 0.17, 0.6), (DONE + 0.55, 1.0), (L, 1.0)), 24.0, 0.75),
    }
    left_at = lambda t: left_arm(t, reach["along"](t), reach["away"](t), twist_at * reach["twist"](t), sense, roll)
    turns = curled(clamp, (2.0, 4.0, 5.0))                           # the fist on the barrel tightens against the work
    turns.update({"RightLowerArm": lambda t: mat_q(right_arm(t)[0]), "LeftLowerArm": lambda t: mat_q(left_at(t)[0]),
                  "LeftHand": lambda t: mat_q(left_at(t)[2])})
    moves = {"RightLowerArm": lambda t: right_arm(t)[1], "LeftLowerArm": lambda t: left_at(t)[1]}
    for bone, q in held.items():                                     # the left fist: the right's, mirrored, opened a little
        thumb = "Thumb" in bone
        slack = 0.0 if thumb else (-24.0, -26.0, -14.0)[JOINTS.index(next(j for j in JOINTS if bone.endswith(j)))]
        late = 0.0 if thumb else 0.03 * next(k for k, name in enumerate(FINGERS) if bone.startswith(name))

        def finger(t, q=q * np.array([1.0, -1.0, -1.0, 1.0]), slack=slack, late=late):     # index first, little finger last
            half = np.radians(slack * reach["open"](min(max(t - late, 0.0), L))) / 2
            return q_mul(q, np.array([np.sin(half), 0.0, 0.0, np.cos(half)]))
        turns["Left" + bone] = finger
    clip("TorchReload", SWAP_LENGTH, turns, moves)
    wrist_bend = max(left_at(t)[3] for t in np.arange(U0[0], DONE, 0.05))
    home = lambda at, to: round(float(next(t for t in np.arange(at - 0.2, at + 0.3, 0.005) if reach["along"](t) >= (to - 0.001) * u)), 2)
    swap_times = {"unscrew": UNSCREW, "cap off": PULL, "tip": TIP, "fetch": FETCH, "pushed home": (home(PUSH[0], -0.045), home(PUSH[1], -0.03)),
                  "cap on": CAP_ON, "screw": SCREW}

    # ---- write
    material = json.loads(json.dumps(odoc["materials"][0]))
    material["name"] = "playerarms"
    material["doubleSided"] = True                                   # the sleeve is open at the shoulder
    image_name = odoc["images"][0].get("name", "playerarms_basecolor.jpg")
    result = {
        "asset": {"version": "2.0", "generator": "tools/build_player_arms.py"},
        "scene": 0,
        "scenes": [{"nodes": odoc["scenes"][odoc.get("scene", 0)]["nodes"]}],
        "nodes": nodes,
        "meshes": meshes,
        "skins": [{"name": odoc["skins"][0].get("name", "PlayerArmsSkin"), "joints": skin_joints,
                   "inverseBindMatrices": ibm_acc, "skeleton": odoc["skins"][0].get("skeleton", nid["Root"])}],
        "materials": [material],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "images": [{"name": image_name, "mimeType": img.get("mimeType", "image/jpeg"), "bufferView": out.view(image)}],
        "animations": anims,
        "extensionsUsed": sorted(material.get("extensions", {}).keys()),
    }
    if not result["extensionsUsed"]:
        del result["extensionsUsed"]
    result["accessors"] = out.accessors
    result["bufferViews"] = out.views
    while len(out.blob) % 4:
        out.blob.append(0)
    result["buffers"] = [{"byteLength": len(out.blob)}]
    text = json.dumps(result, separators=(",", ":")).encode()
    text += b" " * (-len(text) % 4)
    with open(out_path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(text) + 8 + len(out.blob)))
        f.write(struct.pack("<I4s", len(text), b"JSON"))
        f.write(text)
        f.write(struct.pack("<I4s", len(out.blob), b"BIN\0"))
        f.write(out.blob)
    # Godot writes the texture out beside the model; keep that copy the one this model was made with
    beside = out_path.with_name(out_path.stem + "_" + Path(image_name).stem + ".jpg")
    if beside.exists():
        beside.write_bytes(image)

    np.set_printoptions(precision=4, suppress=True)
    print("wrote", out_path, "(%d bytes)" % out_path.stat().st_size)
    print("shoulder", shoulder, "elbow", elbow, "wrist", wrist)
    print("upper arm %.3f  forearm %.3f (was %.3f)" % (np.linalg.norm(shoulder - elbow), new_len, old_len))
    for f in FINGERS + ["Thumb"]:
        pts = chains[f]
        print("%-7s" % f, " ".join("%.3f" % np.linalg.norm(pts[k + 1] - pts[k]) for k in range(3)), " knuckle", pts[0])
    mid = chains["Middle"]
    print("middle knuckle in the hand's space", new_hand.T @ (mid[0] - wrist),
          " finger %.3f" % sum(np.linalg.norm(mid[k + 1] - mid[k]) for k in range(3)))
    print("mirror: left vertices off their right twin by at most %.5f" % left_of.max())
    print("swap: the left hand takes the cap %s, rolled %.0f deg; its wrist bends up to %.0f deg"
          % ("thumb to the head" if sense > 0 else "thumb to the tail", np.degrees(roll), wrist_bend))
    print("swap: %s" % swap_times)
    print("TorchGrip", np.array(grip["translation"]), "TorchAnchor", np.array(nodes[nid["TorchAnchor"]]["translation"]),
          " barrel radius %.4f" % barrel)
    for f, bend, rest in zip(FINGERS, grasp["bend"], grasp["rest_bend"]):
        print("grip %-7s" % f, "bends", np.array(bend), " at rest", np.array(rest))
    return {"arm": {"shoulder": shoulder.tolist(), "elbow": elbow.tolist(), "wrist": wrist.tolist()},
            "fingers": {f: dict(zip(["j0" if f == "Thumb" else "j1", "j1" if f == "Thumb" else "j2", "j2" if f == "Thumb" else "j3", "tip"],
                                    [np.asarray(q).tolist() for q in chains[f]])) for f in chains}}


if __name__ == "__main__":
    main()
