"""Build THE GRABBER the game loads (models/entities/grabber/grabber.glb).

    blender --background --python tools/blender/build_grabber.py -- <in.glb> <out.glb> [preview_prefix]
    e.g. /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_grabber.py -- \
             asetsuimprot/grabber.glb godot-backrooms/models/entities/grabber/grabber.glb

    in.glb  asetsuimprot/grabber.glb   the Tripo sculpt (a gaunt grinning figure in black, arms hanging past its
                                       knees) rigged on Mixamo: 65 bones, arms down, 1 m tall, no clips

What it does:

1. Fits it to HEIGHT (feet on z = 0) and drops the "mixamorig:" prefix from the bone names (Godot would turn the
   colon into an underscore anyway, and the scripts name bones).
2. Poses every clip procedurally. A pose is a rotation per bone given in the body's own axes (bend = tip
   forward, turn = toward its left, tilt = top toward its left), carried by the parent's pose (FK), plus
   two-bone IK for the legs (planted feet, stepping) and the arms (a hand on a doorframe, on an ankle): the
   solver of build_player_hazmat.py. Looping clips end on their first frame; locomotion is in place (the game
   moves the node) and the ground speed each clip covers at speed 1 is printed for NATIVE in
   scripts/Entities/grabber/grabber_body.gd.
   idle     standing, stooped, one shoulder low, the head tilting slowly this way and that; a twitch
   hunch    folded in a deep crouch with the long arms raised and the neck wrung round: the game hangs it
            upside down from the ceiling, so the arms dangle to the floor and the face hangs under it
   land     after the drop: from a crouch with its hands on the floor it unfolds a joint at a time, the head
            snapping up last
   run      a long loping run, arms trailing
   chase    a frantic sprint bent forward with both arms reaching out in front
   peek_r / peek_l   (its right / left) a hand comes round the edge at head height and grips it, then the
            head and shoulder lean out, tilted on its side; it holds, taps a finger, and snaps back
   grab     wind up, lunge low, one arm shooting out to your ankle and closing
   drag     walking backwards bent over, one hand low gripping, a yank at every step
3. Exports one .glb with every clip (one NLA track each), facing +Z.
A third argument also renders a strip of frames per clip (Workbench) to <prefix>_<clip>.png, for a look.
"""
import sys
import math

import bpy
import numpy as np
from mathutils import Vector, Matrix

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
SRC_GLB, OUT_GLB = args[:2]
PREVIEW = args[2] if len(args) > 2 else ""

FPS = 30
HEIGHT = 2.3              # m: the game fits nothing, this is its size
TAU = math.tau

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = FPS

bpy.ops.import_scene.gltf(filepath=SRC_GLB)
for o in [o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("Icosphere")]:
    bpy.data.objects.remove(o, do_unlink=True)    # the importer's bone-shape sphere
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
body = next(o for o in bpy.data.objects if o.type == "MESH")


# =============================================================== 1. size and names
for b in arm.data.bones:
    b.name = b.name.replace("mixamorig:", "")     # renames the vertex groups with it
_lo = min((body.matrix_world @ v.co).z for v in body.data.vertices)
_hi = max((body.matrix_world @ v.co).z for v in body.data.vertices)
_k = HEIGHT / (_hi - _lo)
_fit = Matrix.Scale(_k, 4) @ Matrix.Translation((0.0, 0.0, -_lo))
arm.data.transform(_fit)
body.data.transform(_fit)
missing = [b.name for b in arm.data.bones if b.name not in body.vertex_groups and not b.name.endswith("_End")
           and not b.name.endswith("4")]
print("fitted to %.2f m (x%.3f); bones without a vertex group: %s" % (HEIGHT, _k, missing))


# =============================================================== 2. posing
def rot3(m):
    return m.to_3x3().normalized()


def _depth(b):
    d = 0
    while b.parent:
        b = b.parent
        d += 1
    return d


BONES = sorted(arm.data.bones, key=_depth)             # parents before children
REST = {b.name: b.matrix_local.copy() for b in BONES}
RROT = {n: rot3(m) for n, m in REST.items()}
RPOS = {n: m.translation.copy() for n, m in REST.items()}
PARENT = {b.name: (b.parent.name if b.parent else None) for b in BONES}
REL = {n: (REST[p].inverted() @ REST[n]) if p else REST[n] for n, p in PARENT.items()}

X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))
FWD = -Y                                   # it faces -Y in Blender (+Z once exported)
I3 = Matrix.Identity(3)


def rot(axis, deg):
    return Matrix.Rotation(math.radians(deg), 3, axis)


def bend(d):
    """Tip forward (an upright bone); a hanging bone (arm, leg) swings BACK for +d."""
    return rot(X, d)


def turn(d):
    """Turn toward its left."""
    return rot(Z, d)


def tilt(d):
    """The top toward its left."""
    return rot(Y, d)


def look(b=0.0, t=0.0, l=0.0):
    """Turn, then bend in the turned frame, then tilt: a head or a spine joint."""
    return turn(t) @ bend(b) @ tilt(l)


def frame_of(u, n):
    u = u.normalized()
    n = (n - u * n.dot(u)).normalized()
    return Matrix((u, n, u.cross(n))).transposed()


class Limb:
    """Two-bone IK (build_player_hazmat.py's Leg, for arms too). `hinge`: the joint's bend axis at rest, as
    the cross product of the upper and lower bone directions comes out when it bends the natural way."""
    def __init__(self, upper, lower, end, hinge):
        self.upper, self.lower, self.end = upper, lower, end
        h0, k0, a0 = RPOS[upper], RPOS[lower], RPOS[end]
        self.l1 = (k0 - h0).length
        self.l2 = (a0 - k0).length
        self.u0t = (k0 - h0).normalized()
        self.u0c = (a0 - k0).normalized()
        self.n0 = hinge

    def solve(self, h, a, pole):
        d = a - h
        dl = min(max(d.length, abs(self.l1 - self.l2) + 1e-3), (self.l1 + self.l2) * 0.999)
        u = d.normalized()
        along = (self.l1 ** 2 - self.l2 ** 2 + dl ** 2) / (2 * dl)
        off = math.sqrt(max(self.l1 ** 2 - along * along, 0.0))
        v = (pole - u * pole.dot(u)).normalized()
        k = h + u * along + v * off
        a2 = h + u * dl
        ut, uc = (k - h).normalized(), (a2 - k).normalized()
        n = ut.cross(uc)
        n = n.normalized() if n.length > 1e-5 else pole.cross(u).normalized()
        rt = frame_of(ut, n) @ frame_of(self.u0t, self.n0).transposed()
        rc = frame_of(uc, n) @ frame_of(self.u0c, self.n0).transposed()
        return (rt @ RROT[self.upper]).normalized(), (rc @ RROT[self.lower]).normalized()


LIMBS = {
    "legL": Limb("LeftUpLeg", "LeftLeg", "LeftFoot", X),          # knees bend forward: thigh x shin = +X
    "legR": Limb("RightUpLeg", "RightLeg", "RightFoot", X),
    "armL": Limb("LeftArm", "LeftForeArm", "LeftHand", -X),       # elbows bend the forearm forward: -X
    "armR": Limb("RightArm", "RightForeArm", "RightHand", -X),
}
LIMB_AT = {l.upper: key for key, l in LIMBS.items()}


def fk(pose):
    """pose: {"hip": Vector (Hips offset), "D": {bone: 3x3 in the body's axes, carried by the parent},
    "abs": {bone: 3x3 absolute}, "ik": {limb: (target, pole) or fn(pos, G) -> (target, pole)}}.
    Returns bone -> matrix_basis."""
    dd = pose.get("D", {})
    ab = dict(pose.get("abs", {}))
    ik = pose.get("ik", {})
    hip = pose.get("hip", Vector())
    g_acc, m_acc, basis = {}, {}, {}
    for b in BONES:
        n = b.name
        p = PARENT[n]
        if p is None:
            pos = RPOS[n] + hip
        else:
            pos = m_acc[p].translation + g_acc[p] @ (RPOS[n] - RPOS[p])
        key = LIMB_AT.get(n)
        if key in ik:
            spec = ik[key]
            target, pole = spec(pos, g_acc) if callable(spec) else spec
            ru, rl = LIMBS[key].solve(pos, target, pole)
            ab[LIMBS[key].upper] = ru
            ab[LIMBS[key].lower] = rl
        if n in ab:
            g = ab[n] @ RROT[n].inverted()
        else:
            g = (g_acc[p] if p else I3) @ dd.get(n, I3)
        g_acc[n] = g
        m_acc[n] = Matrix.Translation(pos) @ (g @ RROT[n]).to_4x4()
        par = m_acc[p] if p else Matrix()
        basis[n] = REL[n].inverted() @ par.inverted() @ m_acc[n]
    return basis


# --------------------------------------------------------------- small helpers
def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def ramp(t, a, b):
    """0 before a, 1 after b, smooth between."""
    return smooth((t - a) / (b - a)) if b > a else float(t >= a)


def lerp(a, b, k):
    return a + (b - a) * k


def spike(t, at, rise=0.05, fall=0.35):
    """A twitch: snaps up in `rise`, eases off over `fall`."""
    if t < at:
        return 0.0
    if t < at + rise:
        return (t - at) / rise
    return max(0.0, 1.0 - smooth((t - at - rise) / fall))


def pspike(t, period, at, rise=0.05, fall=0.35):
    """spike() that repeats every `period` (for loops: a twitch that wraps round the end)."""
    return max(spike(t % period, at, rise, fall), spike(t % period + period, at, rise, fall))


SIDES = (("L", "Left", 1.0), ("R", "Right", -1.0))       # its left is +X
FINGERS = ("Index", "Middle", "Ring", "Pinky")
ANKLE = {"L": RPOS["LeftFoot"].copy(), "R": RPOS["RightFoot"].copy()}
HAND0 = {"L": RPOS["LeftHand"].copy(), "R": RPOS["RightHand"].copy()}


def fingers(dd, side, curl, spread=0.0, index=None):
    """Curl a hand's fingers toward the palm (it hangs palm-in). `index` overrides the index finger."""
    word, sx = ("Left", 1.0) if side == "L" else ("Right", -1.0)
    for f in FINGERS:
        c = index if (f == "Index" and index is not None) else curl
        s = spread * {"Index": 1.0, "Middle": 0.3, "Ring": -0.3, "Pinky": -1.0}[f]
        dd[f"{word}Hand{f}1"] = tilt(sx * c * 0.8) @ bend(-s)
        dd[f"{word}Hand{f}2"] = tilt(sx * c)
        dd[f"{word}Hand{f}3"] = tilt(sx * c * 0.9)
    dd[f"{word}HandThumb1"] = tilt(sx * curl * 0.3)
    dd[f"{word}HandThumb2"] = tilt(sx * curl * 0.4)


def planted(pole_out=0.15, width=0.0, forward=None):
    """Feet where they stand at rest (or pushed apart / forward), knees forward."""
    ik = {}
    for s, _, sx in SIDES:
        a = ANKLE[s].copy()
        a.x += sx * width
        if forward and s in forward:
            a += forward[s]
        ik["leg" + s] = (a, FWD + X * sx * pole_out)
    return ik


def feet_abs(pitch):
    """Feet flat as at rest, pitched (toes down for +) per side."""
    return {word + "Foot": rot(X, pitch.get(s, 0.0)) @ RROT[word + "Foot"] for s, word, _ in SIDES}


def gait(p, speed, period, duty, lift, back=False, width=0.0):
    """Stepping, phase p in [0, 1): feet (ankle targets), foot pitch, and the hip bob phase. `back`: it walks
    backwards (the planted foot slides forward under it). Returns (ik, pitch)."""
    ik, pitch = {}, {}
    stance = speed * duty * period                     # how far the body travels over one foot's stance
    for s, word, sx in SIDES:
        q = (p + (0.0 if s == "L" else 0.5)) % 1.0
        a = ANKLE[s].copy()
        a.x += sx * width
        sign = -1.0 if back else 1.0                   # +Y is behind it
        if q < duty:                                   # on the ground, sliding back under it
            k = q / duty
            a.y += sign * (-stance / 2 + stance * k)
            pitch[s] = (-20.0 if back else 28.0) * ramp(k, 0.7, 1.0)
        else:                                          # in the air, swung through
            k = (q - duty) / (1 - duty)
            a.y += sign * (stance / 2 - stance * smooth(k))
            a.z += lift * math.sin(math.pi * k)
            pitch[s] = lerp(34.0 if not back else -15.0, -12.0 if not back else 8.0, smooth(k)) * (1 - ramp(k, 0.85, 1.0))
        ik["leg" + s] = (a, FWD + X * sx * 0.12)
    return ik, pitch


def chest_arm(side, off, pole):
    """IK for an arm with the hand at `off` from the shoulder in the chest's frame (moves with the torso)."""
    def fn(pos, g):
        c = g["Spine2"]
        return pos + c @ off, c @ pole
    return fn


# --------------------------------------------------------------- the clips
def idle(t):
    T = 4.0
    w = TAU * t / T
    twitch = pspike(t, T, 2.6, 0.04, 0.45)
    flick = pspike(t, T, 1.3, 0.03, 0.25)
    dd = {
        "Hips": tilt(2.0 * math.sin(w)),
        "Spine": bend(4.0) @ tilt(-1.5 * math.sin(w)),
        "Spine1": bend(5.0 + 1.2 * math.sin(2 * w)),
        "Spine2": bend(4.0) @ tilt(3.0),
        "Neck": bend(12.0),
        "Head": look(-8.0 + 3.0 * math.sin(2 * w), 9.0 * math.sin(w + 1.0), 11.0 * math.sin(w) + 17.0 * twitch),
        "LeftShoulder": turn(-2.0),
        "RightShoulder": turn(4.0) @ tilt(-4.0),
        "LeftArm": bend(-4.0 + 3.0 * math.sin(w)) @ tilt(-5.0),        # (hanging: -tilt swings it out)
        "RightArm": bend(-2.0 + 3.0 * math.sin(w + 2.0)) @ tilt(4.0),
        "LeftForeArm": bend(-10.0),
        "RightForeArm": bend(-6.0),
    }
    fingers(dd, "L", 22.0 + 14.0 * flick, index=8.0 + 40.0 * flick)
    fingers(dd, "R", 30.0 + 6.0 * math.sin(2 * w))
    ik = planted()
    return {"hip": Vector((0.03 * math.sin(w), 0.0, -0.03 + 0.008 * math.sin(2 * w))), "D": dd, "ik": ik,
            "abs": feet_abs({})}


def hunch(t):
    """Folded in a crouch, arms raised, neck wrung round. The game hangs it upside down from the ceiling."""
    T = 3.0
    w = TAU * t / T
    jerk1 = pspike(t, T, 0.55, 0.04, 0.3)
    jerk2 = pspike(t, T, 1.75, 0.03, 0.5)
    jerk3 = pspike(t, T, 2.35, 0.03, 0.2)
    dd = {
        "Hips": bend(22.0),
        "Spine": bend(20.0),
        "Spine1": bend(18.0 + 2.0 * math.sin(w)),
        "Spine2": bend(14.0) @ tilt(3.0 * math.sin(w + 0.5)),
        "Neck": look(-20.0, 70.0 + 22.0 * jerk1, 0.0),
        "Head": look(-45.0 + 12.0 * jerk3, 80.0, 8.0 * math.sin(w) - 22.0 * jerk2),
    }
    # the arms "up" here hang down once it is upside down, swaying a little
    sway = 0.06 * math.sin(w)
    for s, word, sx in SIDES:
        off = Vector((sx * 0.18 + sway * sx, -0.25 + 0.05 * math.sin(w + (0 if s == "L" else 1.3)), 1.15))
        dd[word + "Shoulder"] = tilt(-sx * 6.0)
        dd[word + "Hand"] = bend(-15.0)
    ik = planted(pole_out=0.45, width=0.14)
    ik["armL"] = (lambda pos, g: (pos + Vector((0.2 + sway, -0.3, 1.15)), Vector((1.0, 0.4, 0.0))))
    ik["armR"] = (lambda pos, g: (pos + Vector((-0.2 - sway, -0.3 + 0.05 * math.sin(w), 1.15)), Vector((-1.0, 0.4, 0.0))))
    fingers(dd, "L", 18.0 + 30.0 * pspike(t, T, 0.9, 0.05, 0.4), spread=10.0)
    fingers(dd, "R", 12.0 + 35.0 * pspike(t, T, 2.1, 0.05, 0.5), spread=10.0)
    return {"hip": Vector((0.0, 0.18, -0.64)), "D": dd, "ik": ik, "abs": feet_abs({})}


def land(t):
    """0..1.4 s: from a crouch with its hands on the floor, unfolding a joint at a time."""
    rise = ramp(t, 0.08, 0.75)
    dd = {
        "Hips": bend(lerp(38.0, 4.0, ramp(t, 0.12, 0.6))),
        "Spine": bend(lerp(24.0, 4.0, ramp(t, 0.3, 0.7))),
        "Spine1": bend(lerp(24.0, 5.0, ramp(t, 0.42, 0.82))),
        "Spine2": bend(lerp(22.0, 4.0, ramp(t, 0.54, 0.94))),
        "Neck": bend(lerp(34.0, 10.0, ramp(t, 0.8, 1.05))),
    }
    snap = ramp(t, 1.02, 1.14)
    settle = ramp(t, 1.14, 1.4)
    dd["Head"] = look(lerp(35.0, lerp(-16.0, -6.0, settle), snap), 0.0, lerp(0.0, lerp(14.0, 6.0, settle), snap))
    arms = ramp(t, 0.2, 0.85)
    for s, word, sx in SIDES:
        dd[word + "Arm"] = bend(lerp(-88.0, -3.0, arms)) @ tilt(sx * lerp(14.0, 2.0, arms))
        dd[word + "ForeArm"] = bend(lerp(-12.0, -8.0, arms))
        dd[word + "Hand"] = bend(lerp(-55.0, 0.0, arms))
    fingers(dd, "L", lerp(-5.0, 24.0, arms), spread=lerp(14.0, 0.0, arms))
    fingers(dd, "R", lerp(-5.0, 28.0, arms), spread=lerp(14.0, 0.0, arms))
    hip = Vector((0.0, lerp(0.28, 0.0, rise), lerp(-0.72, -0.03, rise)))
    return {"hip": hip, "D": dd, "ik": planted(pole_out=0.35, width=lerp(0.16, 0.0, ramp(t, 0.3, 0.9))),
            "abs": feet_abs({})}


RUN = {"period": 0.8, "speed": 3.2, "duty": 0.42, "lift": 0.24}
CHASE = {"period": 0.6, "speed": 5.4, "duty": 0.36, "lift": 0.34}
DRAG = {"period": 1.2, "speed": 1.6, "duty": 0.6, "lift": 0.12}


def run(t):
    c = RUN
    p = (t / c["period"]) % 1.0
    w = TAU * p
    ik, pitch = gait(p, c["speed"], c["period"], c["duty"], c["lift"])
    bob = -0.045 * math.cos(2 * w - TAU * c["duty"] / 2)
    swing = math.sin(w)                                 # left foot forward at p ~ 0.75: left arm back then
    dd = {
        "Hips": turn(7.0 * swing) @ bend(4.0),
        "Spine": bend(5.0) @ turn(-4.0 * swing),
        "Spine1": bend(6.0) @ turn(-4.0 * swing),
        "Spine2": bend(5.0),
        "Neck": bend(4.0),
        "Head": look(-12.0 + 3.0 * math.cos(2 * w), 0.0, 16.0),
        "LeftArm": bend(20.0 - 26.0 * swing) @ tilt(9.0),
        "RightArm": bend(20.0 + 26.0 * swing) @ tilt(-9.0),
        "LeftForeArm": bend(-12.0 - 8.0 * max(0.0, -swing)),
        "RightForeArm": bend(-12.0 - 8.0 * max(0.0, swing)),
        "LeftHand": bend(10.0 * swing),
        "RightHand": bend(-10.0 * swing),
    }
    fingers(dd, "L", 18.0 + 6.0 * swing)
    fingers(dd, "R", 18.0 - 6.0 * swing)
    return {"hip": Vector((0.0, 0.0, -0.1 + bob)), "D": dd, "ik": ik, "abs": feet_abs(pitch)}


def chase(t):
    c = CHASE
    p = (t / c["period"]) % 1.0
    w = TAU * p
    ik, pitch = gait(p, c["speed"], c["period"], c["duty"], c["lift"])
    bob = -0.06 * math.cos(2 * w - TAU * c["duty"] / 2)
    swing = math.sin(w)
    dd = {
        "Hips": turn(8.0 * swing) @ bend(10.0),
        "Spine": bend(10.0) @ turn(-5.0 * swing),
        "Spine1": bend(10.0) @ turn(-5.0 * swing),
        "Spine2": bend(8.0),
        "Neck": bend(-6.0),
        "Head": look(-28.0 + 4.0 * math.cos(2 * w), 5.0 * math.sin(w), 12.0 * math.sin(2 * w + 0.6)),
        # both arms thrown out in front, flailing out of step
        "LeftArm": bend(-58.0 + 26.0 * swing) @ tilt(16.0 + 8.0 * math.cos(w)),
        "RightArm": bend(-58.0 - 26.0 * swing) @ tilt(-16.0 - 8.0 * math.cos(w)),
        "LeftForeArm": bend(-8.0 - 10.0 * max(0.0, swing)),
        "RightForeArm": bend(-8.0 - 10.0 * max(0.0, -swing)),
        "LeftHand": bend(-20.0),
        "RightHand": bend(-20.0),
    }
    fingers(dd, "L", -6.0 + 20.0 * pspike(t, c["period"], 0.1, 0.03, 0.2), spread=14.0)
    fingers(dd, "R", -6.0 + 20.0 * pspike(t, c["period"], 0.4, 0.03, 0.2), spread=14.0)
    return {"hip": Vector((0.0, 0.0, -0.16 + bob)), "D": dd, "ik": ik, "abs": feet_abs(pitch)}


def peek(t, side):
    """side "r": the corner is on its right, it leans out to its right (and "l" to its left)."""
    sx = -1.0 if side == "r" else 1.0
    word = "Right" if side == "r" else "Left"
    other = "Left" if side == "r" else "Right"
    hand_up = ramp(t, 0.0, 0.45) * (1 - ramp(t, 3.25, 3.6))
    grip = ramp(t, 0.3, 0.6) * (1 - ramp(t, 3.2, 3.35))
    lean = ramp(t, 0.35, 0.95) * (1 - ramp(t, 3.2, 3.42))
    hold = ramp(t, 0.9, 1.3) * (1 - ramp(t, 3.1, 3.2))
    cock = spike(t, 2.7, 0.05, 0.4)
    taps = spike(t, 1.6, 0.05, 0.12) + spike(t, 2.02, 0.05, 0.12) + spike(t, 2.24, 0.05, 0.12)
    dd = {
        "Hips": tilt(-sx * 3.0 * lean),
        "Spine": tilt(sx * 9.0 * lean) @ bend(3.0),
        "Spine1": tilt(sx * 12.0 * lean) @ bend(3.0),
        "Spine2": tilt(sx * 10.0 * lean),
        "Neck": tilt(sx * 14.0 * lean) @ bend(8.0),
        "Head": look(-6.0 * lean, -sx * 12.0 * lean, sx * (32.0 * lean + 5.0 * math.sin(t * 2.3) * hold + 13.0 * cock)),
        other + "Arm": bend(-3.0),
        other + "ForeArm": bend(-8.0),
    }
    # the far hand on the edge: out to the side at head height, the elbow out
    edge = Vector((sx * 0.46, -0.2, 2.02))
    rest = HAND0["R" if side == "r" else "L"]
    target = rest.lerp(edge, hand_up)
    ik = planted()
    ik["arm" + ("R" if side == "r" else "L")] = (target, Vector((sx * 1.0, 0.3, -0.6)))
    dd[word + "Hand"] = tilt(sx * 25.0 * hand_up) @ bend(-10.0 * hand_up)
    fingers(dd, "R" if side == "r" else "L", lerp(15.0, 72.0, grip), index=lerp(15.0, 72.0, grip) - 40.0 * taps)
    fingers(dd, "L" if side == "r" else "R", 26.0)
    return {"hip": Vector((-sx * 0.04 * lean, 0.0, -0.03 * lean)), "D": dd, "ik": ik, "abs": feet_abs({})}


GRAB_REACH = Vector((-0.12, -1.4, 0.18))   # where its right hand closes: your ankle, in front of it


def grab(t):
    """0..0.8 s: wind up, lunge low, the right arm shooting out to your ankle and closing."""
    wind = ramp(t, 0.0, 0.22)
    lunge = ramp(t, 0.22, 0.48)
    pull = ramp(t, 0.55, 0.8)
    dd = {
        "Hips": bend(lerp(lerp(10.0, 4.0, wind), 26.0, lunge)),
        "Spine": bend(lerp(lerp(10.0, 6.0, wind), 16.0, lunge)),
        "Spine1": bend(lerp(8.0, 14.0, lunge)) @ turn(lerp(8.0 * wind, -6.0, lunge)),
        "Spine2": bend(lerp(6.0, 10.0, lunge)),
        "Neck": bend(lerp(-4.0, -10.0, lunge)),
        "Head": look(lerp(-18.0, -12.0, lunge), 0.0, lerp(0.0, 14.0, pull)),
        "LeftArm": bend(lerp(lerp(-40.0, -60.0, wind), 25.0, lunge)) @ tilt(10.0),
        "LeftForeArm": bend(-15.0),
        "RightHand": bend(lerp(0.0, -25.0, lunge)),
    }
    back = Vector((-0.38, 0.35, 1.25))
    target = back.lerp(GRAB_REACH, lunge) + Vector((0.0, 0.1 * pull, 0.03 * pull))
    ik = planted(forward={"L": Vector((0.0, -0.55 * lunge, 0.0))})
    ik["armR"] = (target, Vector((-0.6, 1.0, 0.4)))
    fingers(dd, "R", lerp(-8.0, 88.0, ramp(t, 0.48, 0.62)), spread=lerp(16.0, 0.0, ramp(t, 0.48, 0.62)))
    fingers(dd, "L", 10.0)
    hip = Vector((0.0, lerp(0.0, -0.3, lunge) + 0.05 * pull, lerp(-0.12, -0.42, lunge)))
    return {"hip": hip, "D": dd, "ik": ik, "abs": feet_abs({})}


def drag(t):
    c = DRAG
    p = (t / c["period"]) % 1.0
    w = TAU * p
    ik, pitch = gait(p, c["speed"], c["period"], c["duty"], c["lift"], back=True)
    yank = max(0.0, math.sin(2 * w)) ** 3                 # a tug on every step
    dd = {
        "Hips": bend(12.0) @ turn(4.0 * math.sin(w)),
        "Spine": bend(10.0),
        "Spine1": bend(9.0) @ turn(-6.0),
        "Spine2": bend(7.0),
        "Neck": bend(6.0),
        "Head": look(-4.0 + 4.0 * yank, -6.0, 24.0 + 3.0 * math.sin(w * 3.0)),
        "LeftArm": bend(6.0 + 14.0 * math.sin(w)) @ tilt(6.0),
        "LeftForeArm": bend(-14.0),
        "RightHand": bend(-30.0),
    }
    ik["armR"] = (Vector((-0.1, -0.98 + 0.14 * yank, 0.24 + 0.05 * yank)), Vector((-0.5, 1.0, 0.3)))
    fingers(dd, "R", 86.0)
    fingers(dd, "L", 20.0 + 10.0 * math.sin(w))
    return {"hip": Vector((0.0, 0.0, -0.14 - 0.02 * math.cos(2 * w))), "D": dd, "ik": ik, "abs": feet_abs(pitch)}


# name: (pose function, seconds, loops)
CLIPS = {
    "idle": (idle, 4.0, True),
    "hunch": (hunch, 3.0, True),
    "land": (land, 1.4, False),
    "run": (run, RUN["period"], True),
    "chase": (chase, CHASE["period"], True),
    "peek_r": (lambda t: peek(t, "r"), 4.0, False),
    "peek_l": (lambda t: peek(t, "l"), 4.0, False),
    "grab": (grab, 0.8, False),
    "drag": (drag, DRAG["period"], True),
}


def key_pose(basis, frame, prev):
    for n, bas in basis.items():
        pb = arm.pose.bones[n]
        loc, q, _ = bas.decompose()
        if n in prev and prev[n].dot(q) < 0:
            q.negate()
        prev[n] = q
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = q
        pb.keyframe_insert("rotation_quaternion", frame=frame)
        if n == "Hips":
            pb.location = loc
            pb.keyframe_insert("location", frame=frame)


def new_action(name):
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm.animation_data_create()
    arm.animation_data.action = act
    return act


for name, (fn, secs, loops) in CLIPS.items():
    new_action(name)
    frames = max(2, round(secs * FPS))
    prev = {}
    for f in range(frames + 1):
        t = f / FPS
        if loops and f == frames:
            t = 0.0                                     # the loop closes exactly
        key_pose(fk(fn(t)), f + 1, prev)
    print("clip %-7s %5.2f s%s" % (name, secs, "  loop" if loops else ""))
print("NATIVE ground speeds (m/s at speed 1): run %.2f  chase %.2f  drag %.2f" % (RUN["speed"], CHASE["speed"], DRAG["speed"]))


# =============================================================== preview strips
def render_strips(prefix):
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.light = "STUDIO"
    sc.display.shading.color_type = "TEXTURE"
    sc.render.resolution_x = 260
    sc.render.resolution_y = 380
    sc.world = bpy.data.worlds.new("preview")
    cam_data = bpy.data.cameras.new("preview")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 3.6
    cam = bpy.data.objects.new("preview", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    d = Vector((0.75, -1.0, 0.12)).normalized()
    for name, (fn, secs, loops) in CLIPS.items():
        arm.animation_data.action = bpy.data.actions[name]
        flip = name == "hunch"                          # the game hangs it from the ceiling
        arm.rotation_mode = "XYZ"
        arm.rotation_euler = (0.0, math.pi if flip else 0.0, 0.0)
        arm.location = (0.0, 0.0, 2.6 if flip else 0.0)
        centre = Vector((0.0, 0.0, 1.25 if not flip else 1.4))
        cam.location = centre + d * 6.0
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        frames = round(secs * FPS)
        picks = [round(frames * i / 6) for i in range(6)]
        tiles = []
        for f in picks:
            sc.frame_set(f + 1)
            sc.render.filepath = prefix + "_tmp.png"
            bpy.ops.render.render(write_still=True)
            img = bpy.data.images.load(prefix + "_tmp.png")
            px = np.array(img.pixels[:], dtype=np.float32).reshape(img.size[1], img.size[0], 4)
            tiles.append(px)
            bpy.data.images.remove(img)
        strip = np.concatenate(tiles, axis=1)
        out = bpy.data.images.new(name + "_strip", strip.shape[1], strip.shape[0], alpha=True)
        out.pixels = strip.ravel()
        out.filepath_raw = "%s_%s.png" % (prefix, name)
        out.file_format = "PNG"
        out.save()
        print("preview", out.filepath_raw)
    arm.rotation_euler = (0.0, 0.0, 0.0)
    arm.location = (0.0, 0.0, 0.0)


if PREVIEW:
    render_strips(PREVIEW)


# =============================================================== 3. export
arm.animation_data.action = None
for pb in arm.pose.bones:
    pb.matrix_basis = Matrix()
ad = arm.animation_data
for tr in list(ad.nla_tracks):
    ad.nla_tracks.remove(tr)
for name in CLIPS:
    act = bpy.data.actions[name]
    ad.action = act                     # binds the action's slot to the armature
    slot = ad.action_slot
    ad.action = None
    track = ad.nla_tracks.new()
    track.name = name
    strip = track.strips.new(name, int(act.frame_range[0]), act)
    if slot is not None and hasattr(strip, "action_slot"):
        strip.action_slot = slot
    track.mute = False
body.name, body.data.name, arm.name = "Grabber", "Grabber", "GrabberRig"
for slot in body.material_slots:            # readable names for the texture Godot extracts
    slot.material.name = "Grabber"
for img in bpy.data.images:
    if img.users and (img.source == "FILE" or img.packed_file):
        img.name = "grabber_basecolor"
for o in bpy.data.objects:
    o.select_set(o in (arm, body))
bpy.context.view_layer.objects.active = arm
bpy.ops.export_scene.gltf(
    filepath=OUT_GLB, export_format="GLB", use_selection=True,
    export_animations=True, export_animation_mode="NLA_TRACKS", export_force_sampling=True,
    export_frame_step=1, export_anim_slide_to_zero=True, export_skins=True, export_all_influences=False,
    export_yup=True, export_apply=False)
print("wrote", OUT_GLB, "clips", list(CLIPS))
