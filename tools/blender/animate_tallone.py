"""Author THE TALL ONE's clips (models/entities/tall/tall_one.glb) on the rig built in tall_one.blend.

    blender -b models/entities/tall/tall_one.blend --python tools/blender/animate_tallone.py
    (or exec() it in a live Blender over the MCP, with the tall_one scene open)

The rig is a 66-bone Mixamo-style skeleton stretched to 4.45 m. Bones are renamed to plain names (Hips, Spine,
LeftArm...) and the two tip bones are put right. Every clip is then solved here by hand, frame by frame:
forward kinematics for the spine, head and fingers (a turn about a world axis, taken about the bone's own head),
two-bone IK for the legs and, where the hands must land on something, the arms. The result is keyed as plain
bone rotations (plus the hips' translation) and every clip goes into one GLB.

Model space: it faces -Y (+Z once exported), its left side is +X, it stands 4.45 high on z = 0, 1 unit = 1 m
(tall_one.gd shows it at scale 1). Clips (30 fps; walk / run are in place, tall_one.gd moves it):
    idle      4 s loop     stood, head cocked, fingers working, breath you can barely see
    walk      2.0 s loop   the roam: slow, long strides, arms hanging to the knees (1.7 m/s)
    run       0.8 s loop   the flee and the hunt: folded forward, long strides, arms pumping (10 m/s)
    spot      0.9 s        it sees you: the head snaps round, the body recoils, hands come up
    scream    3.6 s        head thrown back, arms flung wide, the whole body shaking (holds its last frame)
    kill      9.0 s        pounce 0-1.05 (hips fly in from 6 m behind the root), land and sit astride you 1.05-1.7,
                           then tear at your face to the end. The root is where your chest ends up; "KillEye" is
                           where your eyes are, lying under it looking up. tall_one.gd rides the camera there.
"""
import bpy
import math
from mathutils import Matrix, Quaternion, Vector

OUT = r"C:\Users\alhyu\Documents\GitHub\godot-backrooms\godot-backrooms\models\entities\tall\tall_one.glb"
BLEND = r"C:\Users\alhyu\Documents\GitHub\godot-backrooms\godot-backrooms\models\entities\tall\tall_one.blend"
FPS = 30
X = Vector((1, 0, 0))               # pitch: + folds forward (top toward -Y)
Y = Vector((0, 1, 0))               # roll: + tips the top toward its left (+X)
Z = Vector((0, 0, 1))               # yaw: + turns its face toward +X (its left)
FWD = Vector((0, -1, 0))
LEG_REACH = 2.34

arm = None
REST = {}                           # bone -> armature-space rest matrix
PARENT = {}
ORDER = []
LEN = {}
CHAIN = {"armL": ("LeftArm", "LeftForeArm", "LeftHand"), "armR": ("RightArm", "RightForeArm", "RightHand"),
         "legL": ("LeftUpLeg", "LeftLeg", "LeftFoot"), "legR": ("RightUpLeg", "RightLeg", "RightFoot")}
FINGERS = ("Thumb", "Index", "Middle", "Ring", "Pinky")
FOOT_REST = {}


def rad(d):
    return math.radians(d)


def lerp(a, b, t):
    return a + (b - a) * t


def ease(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def ease5(x):
    x = min(1.0, max(0.0, x))
    return x * x * x * (x * (x * 6 - 15) + 10)


def ramp(t, a, b):
    return ease((t - a) / (b - a))


def q(axis, deg):
    return Quaternion(axis, rad(deg))


# ---------------------------------------------------------------- the rig
def clean(name):
    n = name.replace("mixamorig1:", "")
    if "_" in n and n.rsplit("_", 1)[1].isdigit():
        n = n.rsplit("_", 1)[0]
    return n


def prepare():
    """Plain bone names, tip bones where they belong, the eyes on the Head bone"""
    global arm
    scn = bpy.data.scenes.get("TallOne") or bpy.context.scene
    bpy.context.window.scene = scn
    arm = bpy.data.objects["TallOne_Rig"]
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for b in arm.data.bones:
        n = clean(b.name)
        if n != b.name:
            b.name = n
    for o in bpy.data.objects:
        if o.parent == arm and o.parent_type == 'BONE':
            o.parent_bone = "Head"
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.data.edit_bones
    top = eb["Head"].head.z + 0.50
    eb["Head"].tail = (eb["Head"].head.x, eb["Head"].head.y, top)
    eb["HeadTop_End"].head = (eb["Head"].head.x, eb["Head"].head.y, top)
    eb["HeadTop_End"].tail = (eb["Head"].head.x, eb["Head"].head.y, top + 0.1)
    for s in ("Left", "Right"):
        tb = eb[s + "ToeBase"]
        te = eb[s + "Toe_End"]
        te.head = tb.tail
        te.tail = tb.tail + Vector((0, -0.12, 0))
    bpy.ops.object.mode_set(mode='OBJECT')
    for pb in arm.pose.bones:
        pb.rotation_mode = 'QUATERNION'
    load_rest()


def load_rest():
    REST.clear()
    PARENT.clear()
    LEN.clear()
    del ORDER[:]
    for b in arm.data.bones:
        REST[b.name] = b.matrix_local.copy()
        PARENT[b.name] = b.parent.name if b.parent else None
        LEN[b.name] = b.length
        ORDER.append(b.name)
    for s in ("Left", "Right"):
        FOOT_REST[s] = (REST[s + "Foot"].to_3x3() @ Vector((0, 1, 0))).normalized()


# ---------------------------------------------------------------- the solver
class Pose:
    """One frame's wish: hips offset, turns, aims, IK targets, finger curls"""

    def __init__(s):
        s.hip = Vector()
        s.rot = {}
        s.aim = {}
        s.ik = {}                    # chain -> (target, pole direction)
        s.curl = {"L": [0.3] * 5, "R": [0.3] * 5}
        s.spread = {"L": 0.0, "R": 0.0}
        s.foot_pitch = {"L": 0.0, "R": 0.0}   # + toes down

    def turn(s, bone, *pairs):
        """pairs of (world axis, degrees), applied in order"""
        r = s.rot.get(bone, Quaternion())
        for axis, deg in pairs:
            r = q(axis, deg) @ r
        s.rot[bone] = r
        return s


def solve(p):
    """-> ({bone: matrix_basis}, {bone: armature-space pose matrix})"""
    P = {}
    B = {}
    for b in ORDER:
        par = PARENT[b]
        rb = REST[b]
        pre = rb.copy() if par is None else P[par] @ REST[par].inverted() @ rb
        if b == "Hips":
            pre = Matrix.Translation(p.hip) @ pre
        h = pre.translation.copy()
        yaxis = (pre.to_3x3() @ Vector((0, 1, 0))).normalized()
        want = p.aim.get(b)
        for ch, (target, pole) in p.ik.items():
            up, lo, end = CHAIN[ch]
            if b not in (up, lo):
                continue
            if b == up:
                p._root = h
                L1, L2 = LEN[up], LEN[lo]
                d = target - h
                dist = min(max(d.length, 0.05), (L1 + L2) * 0.9995)
                dn = d.normalized()
                a = (L1 * L1 - L2 * L2 + dist * dist) / (2 * dist)
                hh = math.sqrt(max(L1 * L1 - a * a, 0.0))
                pv = pole - dn * pole.dot(dn)
                pv = pv.normalized() if pv.length > 1e-6 else Vector((0, -1, 0))
                joint = h + dn * a + pv * hh
                p._joint = joint
                p._tgt = h + dn * dist
                want = joint - h
            else:
                want = p._tgt - h
        D = Quaternion()
        if want is not None and want.length > 1e-6:
            D = yaxis.rotation_difference(want.normalized())
        if b in p.rot:
            D = p.rot[b] @ D
        M = Matrix.Translation(h) @ D.to_matrix().to_4x4() @ Matrix.Translation(-h) @ pre
        # feet stay as they were at rest, in the world, unless pitched: the leg turns under them
        for s_, side in (("Left", "L"), ("Right", "R")):
            if b == s_ + "Foot" and "foot" + side not in p.aim:
                fd = FOOT_REST[s_].copy()
                fd = q(X, p.foot_pitch[side]) @ fd
                cur = (M.to_3x3() @ Vector((0, 1, 0))).normalized()
                F = cur.rotation_difference(fd)
                M = Matrix.Translation(h) @ F.to_matrix().to_4x4() @ Matrix.Translation(-h) @ M
        # fingers: a curl about the bone's own X
        for side, sname in (("L", "Left"), ("R", "Right")):
            for i, f in enumerate(FINGERS):
                for k in (1, 2, 3, 4):
                    if b == "%sHand%s%d" % (sname, f, k):
                        c = p.curl[side][i]
                        w = (0.8, 1.0, 0.9, 0.0)[k - 1] if f != "Thumb" else (0.5, 0.7, 0.6, 0.0)[k - 1]
                        sp = p.spread[side] * (i - 2) * 0.12 if k == 1 and f != "Thumb" else 0.0
                        M = M @ Matrix.Rotation(c * w * 1.35, 4, 'X')
                        if sp:
                            M = M @ Matrix.Rotation(sp, 4, 'Z')
        P[b] = M
        if par is None:
            B[b] = rb.inverted() @ M
        else:
            B[b] = rb.inverted() @ REST[par] @ P[par].inverted() @ M
    return B, P


def key(p, frame):
    B, P = solve(p)
    for b, m in B.items():
        pb = arm.pose.bones[b]
        pb.rotation_quaternion = m.to_quaternion()
        pb.keyframe_insert("rotation_quaternion", frame=frame)
        if b == "Hips":
            pb.location = m.to_translation()
            pb.keyframe_insert("location", frame=frame)
    return P


def show(p):
    """Put the pose on the bones without keying it (to look at)"""
    B, P = solve(p)
    for b, m in B.items():
        pb = arm.pose.bones[b]
        pb.rotation_quaternion = m.to_quaternion()
        pb.location = m.to_translation() if b == "Hips" else (0, 0, 0)
    bpy.context.view_layer.update()
    return P


def begin(name, frames):
    scn = bpy.context.scene
    scn.render.fps = FPS
    scn.frame_start = 0
    scn.frame_end = frames
    arm.animation_data_create()
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm.animation_data.action = act
    if hasattr(arm.animation_data, "action_slot") and arm.animation_data.action_suitable_slots:
        arm.animation_data.action_slot = arm.animation_data.action_suitable_slots[0]
    return act


def end():
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = Quaternion()
        pb.location = Vector()


# ---------------------------------------------------------------- the stance
def dirn(fwd=0.0, out=0.0, side=1):
    """A limb direction hanging down, swung `fwd` degrees forward and `out` degrees away from the body"""
    return Vector((side * math.sin(rad(out)), -math.sin(rad(fwd)), -math.cos(rad(fwd)) * math.cos(rad(out)))).normalized()


def arms_fk(p, fwd_l, out_l, elbow_l, fwd_r=None, out_r=None, elbow_r=None):
    """Both arms hung by FK: the upper arm swung (fwd, out), the forearm folded on forward by `elbow`"""
    if fwd_r is None:
        fwd_r, out_r, elbow_r = fwd_l, out_l, elbow_l
    for side, sn, f, o, e in ((1, "Left", fwd_l, out_l, elbow_l), (-1, "Right", fwd_r, out_r, elbow_r)):
        p.aim[sn + "Arm"] = dirn(f, o, side)
        p.aim[sn + "ForeArm"] = dirn(f + e, o * 0.6, side)


def legs(p, hip, feet, knees=0.15, pitch=(0.0, 0.0)):
    """Two-bone IK legs: `feet` = ((x, y, z) ankle left, ankle right), knees pointing forward and a little out"""
    for side, sn, f in ((1, "L", feet[0]), (-1, "R", feet[1])):
        p.ik["leg" + sn] = (Vector(f), Vector((side * knees, -1.0, 0.0)))
    p.foot_pitch["L"], p.foot_pitch["R"] = pitch


HIP_JOINT_DZ = -0.10                # the hip joints hang this far under the Hips bone's head
HIPS0 = Vector((0.0, -0.06, 2.63))


def hips_at(p, x, y, z):
    """Put the Hips bone's head at (x, y, z)"""
    p.hip = Vector((x, y, z)) - HIPS0


# ---------------------------------------------------------------- idle
def idle(u):
    p = Pose()
    t = u * 4.0
    br = math.sin(u * math.tau)
    hips_at(p, 0.0, -0.06, 2.60 - 0.015 * br)
    legs(p, None, ((0.30, 0.02, 0.20), (-0.30, 0.0, 0.20)), knees=0.1)
    p.turn("Hips", (Z, 1.5 * math.sin(u * math.tau)), (Y, 1.2))
    p.turn("Spine", (X, 5.0 + 0.4 * br))
    p.turn("Spine1", (X, 4.0 + 0.5 * br), (Z, -1.0 * math.sin(u * math.tau)))
    p.turn("Spine2", (X, 3.0 + 0.6 * br))
    p.turn("LeftShoulder", (X, -1.0 * br))
    p.turn("RightShoulder", (X, -1.0 * br))
    p.turn("Neck", (X, 10.0), (Y, 3.0))
    # the head: cocked, drifting; a slow tick over to one side and back
    tick = ramp(t, 1.6, 1.7) * (1.0 - ramp(t, 2.6, 3.7))
    p.turn("Head", (X, 8.0 + 2.0 * math.sin(u * math.tau)), (Y, 13.0 + 7.0 * tick), (Z, -6.0 * tick + 4.0 * math.sin(u * math.tau * 2.0)))
    arms_fk(p, 4.0 + 1.5 * br, 5.0, 9.0, 3.0 - 1.5 * br, 6.0, 12.0)
    flex = 0.5 + 0.5 * math.sin(u * math.tau * 3.0)
    p.curl["L"] = [0.3, 0.4 + 0.25 * flex, 0.35, 0.5 - 0.2 * flex, 0.45]
    p.curl["R"] = [0.3, 0.35, 0.4 + 0.3 * (1 - flex), 0.4, 0.5]
    p.spread["L"] = 0.4
    p.spread["R"] = 0.4
    return p


# ---------------------------------------------------------------- the gait
def gait(ph, stride, duty, lift, rise):
    """One foot's (forward offset, height) at phase ph 0..1 (stance for `duty` of it, then the swing)"""
    if ph < duty:
        u = ph / duty
        return lerp(stride / 2, -stride / 2, u), 0.0
    u = (ph - duty) / (1.0 - duty)
    e = ease5(u)
    return lerp(-stride / 2, stride / 2, e), lift * math.sin(math.pi * u) ** 0.8 + rise * math.sin(math.pi * u) * u


WALK_T = 2.0
WALK_V = 1.7                         # m/s: the clip's own speed (tall_one.gd scales the playback to its pace)
WALK_DUTY = 0.62
WALK_STRIDE = WALK_V * WALK_T * WALK_DUTY * 0.5        # a foot's travel along the ground in its stance


def walk(u):
    p = Pose()
    w = math.tau * u
    fl = gait(u % 1.0, WALK_STRIDE * 2, WALK_DUTY, 0.55, 0.12)
    fr = gait((u + 0.5) % 1.0, WALK_STRIDE * 2, WALK_DUTY, 0.55, 0.12)
    # the hips ride on the stance leg: highest over it, lowest as the feet pass the other way
    hz = 2.50 - 0.09 * (0.5 - 0.5 * math.cos(2 * w - math.pi * WALK_DUTY))
    sway = 0.07 * math.sin(w)
    hips_at(p, -sway, -0.06, hz)
    legs(p, None, ((0.30, -0.06 - fl[0], 0.2 + fl[1]), (-0.30, -0.06 - fr[0], 0.2 + fr[1])), knees=0.18,
         pitch=(-18.0 * math.sin(math.pi * max(0.0, (u % 1.0 - WALK_DUTY) / (1 - WALK_DUTY))) if u % 1.0 > WALK_DUTY else 0.0,
                -18.0 * math.sin(math.pi * max(0.0, (((u + 0.5) % 1.0) - WALK_DUTY) / (1 - WALK_DUTY))) if (u + 0.5) % 1.0 > WALK_DUTY else 0.0))
    p.turn("Hips", (Z, 7.0 * math.sin(w)), (Y, -4.0 * math.sin(w)), (X, 3.0))
    p.turn("Spine", (X, 4.0), (Z, -4.0 * math.sin(w)))
    p.turn("Spine1", (X, 5.0), (Z, -3.0 * math.sin(w)))
    p.turn("Spine2", (X, 4.0), (Z, -2.0 * math.sin(w)))
    p.turn("Neck", (X, 12.0))
    # the head goes on looking where it was looking: it does not agree with the body
    p.turn("Head", (X, 6.0 + 3.0 * math.cos(2 * w)), (Y, 12.0 + 4.0 * math.sin(w * 0.5)), (Z, 6.0 * math.sin(w) + 5.0))
    sw = math.sin(w)
    arms_fk(p, 12.0 * sw + 6.0, 5.0 + 2.0 * sw, 14.0 + 6.0 * sw, -12.0 * sw + 6.0, 6.0 - 2.0 * sw, 18.0 - 6.0 * sw)
    p.curl["L"] = [0.35, 0.5, 0.45, 0.55, 0.5]
    p.curl["R"] = [0.3, 0.45, 0.5, 0.45, 0.55]
    p.spread["L"] = 0.5
    p.spread["R"] = 0.5
    return p


RUN_T = 0.8
RUN_V = 10.0
RUN_DUTY = 0.36
RUN_STRIDE = RUN_V * RUN_T * RUN_DUTY * 0.5


def run(u):
    p = Pose()
    w = math.tau * u
    fl = gait(u % 1.0, RUN_STRIDE * 2, RUN_DUTY, 1.1, 0.35)
    fr = gait((u + 0.5) % 1.0, RUN_STRIDE * 2, RUN_DUTY, 1.1, 0.35)
    lean = 24.0
    # up in the flight, down on the landing
    hz = 2.02 + 0.20 * (0.5 + 0.5 * math.cos(2 * w - 2 * math.pi * RUN_DUTY / 2 + math.pi)) - 0.05
    hips_at(p, -0.05 * math.sin(w), -0.06 - 0.45, hz)
    legs(p, None, ((0.28, -0.55 - fl[0], 0.2 + fl[1]), (-0.28, -0.55 - fr[0], 0.2 + fr[1])), knees=0.12,
         pitch=(-30.0 * ramp(fl[1], 0.0, 0.8) + 25.0 * (1 - ramp(fl[1], 0.0, 0.2)), -30.0 * ramp(fr[1], 0.0, 0.8) + 25.0 * (1 - ramp(fr[1], 0.0, 0.2))))
    p.turn("Hips", (X, 6.0), (Z, 9.0 * math.sin(w)), (Y, -3.0 * math.sin(w)))
    p.turn("Spine", (X, lean * 0.35), (Z, -7.0 * math.sin(w)))
    p.turn("Spine1", (X, lean * 0.35), (Z, -6.0 * math.sin(w)))
    p.turn("Spine2", (X, lean * 0.3), (Z, -4.0 * math.sin(w)))
    p.turn("Neck", (X, -8.0))
    p.turn("Head", (X, -14.0 + 4.0 * math.cos(2 * w)), (Y, 10.0 * math.sin(w * 2.0 + 1.0)), (Z, 9.0 * math.sin(w) + 7.0))
    sw = math.sin(w)
    # arms drive: upper arms thrown back and forward, forearms folded hard, the hands trailing and clawed
    arms_fk(p, 38.0 * sw + 8.0, 12.0, 78.0 - 22.0 * sw, -38.0 * sw + 8.0, 14.0, 78.0 + 22.0 * sw)
    p.curl["L"] = [0.5, 0.7, 0.8, 0.7, 0.75]
    p.curl["R"] = [0.5, 0.75, 0.7, 0.8, 0.7]
    p.spread["L"] = 1.0
    p.spread["R"] = 1.0
    return p


# ---------------------------------------------------------------- spot / scream
def spot(t):
    p = idle(0.0)
    k = ramp(t, 0.0, 0.14)                    # the jolt: 4 frames
    back = k * (1.0 - 0.5 * ramp(t, 0.3, 0.9))
    hips_at(p, 0.0, -0.06 + 0.35 * back, 2.60 - 0.08 * back)
    legs(p, None, ((0.30, 0.02 + 0.55 * back, 0.20), (-0.30, 0.0 - 0.3 * ramp(t, 0.1, 0.4), 0.20 + 0.12 * math.sin(math.pi * ramp(t, 0.1, 0.5)))), knees=0.1)
    p.rot.clear()
    p.turn("Hips", (X, -8.0 * back), (Z, 10.0 * back))
    p.turn("Spine", (X, -10.0 * back + 5.0 * (1 - back)))
    p.turn("Spine1", (X, -12.0 * back + 3.0 * (1 - back)))
    p.turn("Spine2", (X, -8.0 * back))
    p.turn("Neck", (X, lerp(10.0, 22.0, k)))
    shake = 0.5 * math.sin(t * 70.0) * math.exp(-t * 5.0)
    p.turn("Head", (X, lerp(8.0, 18.0, k) + 5 * shake), (Y, lerp(13.0, 0.0, k) + 4 * shake), (Z, lerp(-4.0, 0.0, k)))
    lift = ramp(t, 0.05, 0.35)
    arms_fk(p, 4.0 + 50.0 * lift, 5.0 + 38.0 * lift, 9.0 + 60.0 * lift)
    c = 0.3 + 0.6 * lift
    p.curl["L"] = [c] * 5
    p.curl["R"] = [c] * 5
    p.spread["L"] = 1.0
    p.spread["R"] = 1.0
    return p


def scream(t):
    """Stood where it is, 3.6 s: it folds up, throws its head back and everything goes wide; it shakes through all of it"""
    p = idle(0.0)
    a = ramp(t, 0.0, 0.55)                    # the draw in: folds forward over its belly
    b = ramp(t, 0.55, 0.85)                   # the release: head thrown back, arms out
    hold = ramp(t, 0.85, 1.2)
    fade = 1.0 - ramp(t, 3.0, 3.6)
    shk = math.sin(t * 53.0) * (0.35 + 0.65 * math.sin(t * 7.0) ** 2) * hold * fade
    shk2 = math.sin(t * 41.0 + 1.0) * hold * fade
    hips_at(p, 0.0, -0.06, 2.60 - 0.12 * a + 0.04 * b + 0.015 * shk)
    legs(p, None, ((0.34, 0.0, 0.20), (-0.34, -0.02, 0.20)), knees=0.2)
    p.rot.clear()
    arch = -26.0 * b * fade - 10.0 * (1 - fade) * 0
    p.turn("Hips", (X, 8.0 * a * (1 - b)), (Z, 2.0 * shk))
    p.turn("Spine", (X, 16.0 * a * (1 - b) + arch * 0.3 + 3.0 * (1 - a)))
    p.turn("Spine1", (X, 18.0 * a * (1 - b) + arch * 0.35), (Z, 2.5 * shk2))
    p.turn("Spine2", (X, 12.0 * a * (1 - b) + arch * 0.35), (Z, -2.0 * shk))
    p.turn("Neck", (X, lerp(10.0, 25.0, a) * (1 - b) - 28.0 * b * fade + 10.0 * (1 - fade) * b), (Z, 3.0 * shk))
    p.turn("Head", (X, -26.0 * b * fade + 5.0 * a * (1 - b)), (Y, lerp(13.0, 0.0, a) * (1 - b)), (Z, 7.0 * shk + 4.0 * shk2))
    out = 80.0 * b
    arms_fk(p, 10.0 * b + 4.0 * (1 - b) - 22.0 * a * (1 - b), 5.0 + (out - 5.0) * b, 9.0 + 30.0 * b + 20.0 * shk * hold,
            10.0 * b + 4.0 * (1 - b) - 22.0 * a * (1 - b), 5.0 + (out - 5.0) * b, 9.0 + 30.0 * b - 20.0 * shk * hold)
    c = lerp(0.3, 0.95, b) + 0.1 * shk2 * hold
    p.curl["L"] = [c] * 5
    p.curl["R"] = [c] * 5
    p.spread["L"] = 1.4 * b
    p.spread["R"] = 1.4 * b
    return p


# ---------------------------------------------------------------- the kill
KILL_T = (1.05, 0.65, 7.3)                      # pounce, settle, tear
KILL_N = int(round(sum(KILL_T) * FPS))
EYE = Vector((0.0, -0.62, 0.18))                # your eyes, lying on your back with your head toward its front
SIT = Vector((0.0, 0.02, 0.78))                 # its hips, sat astride your chest
POUNCE_FROM = 6.0                               # m behind the root its hips start (tall_one.gd starts the clip that far out)


def kill(t):
    """Pounce, land astride you, then tear. Root = your chest on the floor; it faces -Y; you lie along -Y"""
    t1 = KILL_T[0]
    t2 = t1 + KILL_T[1]
    p = Pose()
    fly = min(1.0, t / t1)
    # hips fly in on a rising then falling arc from 4.5 m behind
    fy = lerp(POUNCE_FROM, SIT.y, 1.0 - (1.0 - fly) ** 2)      # out of the run at its own speed, braking into you
    arc = math.sin(math.pi * min(1.0, fly * 1.0)) ** 1.0
    # run height at the start -> thrown up -> down on you
    fz = lerp(2.0, SIT.z, ease(fly)) + 0.9 * math.sin(math.pi * fly) ** 1.2
    land = ramp(t, t1 - 0.12, t1 + 0.15)         # the hit: the weight drops into the squat
    sq = ramp(t, t1 - 0.2, t1 + 0.3)
    bounce = -0.10 * math.exp(-((t - (t1 + 0.12)) / 0.09) ** 2)
    settle = ramp(t, t1, t2)
    tear = ramp(t, t2 - 0.1, t2 + 0.4)
    k = max(0.0, t - t2)
    heave = math.sin(k * 6.0) * 0.5 + math.sin(k * 11.0 + 1.0) * 0.3
    hips_at(p, 0.0, fy, fz + bounce + 0.03 * heave * tear)
    # feet: trailing behind in the air, then planted either side of your ribs, knees out like a spider's
    air = 1.0 - sq
    ay = lerp(0.9, 0.25, sq)
    fl = Vector((lerp(0.30, 0.78, sq), fy + ay + 0.9 * air * (0.6 if fly < 1 else 0.0), lerp(0.2 + 0.5 * math.sin(math.pi * fly), 0.2, sq)))
    fr = Vector((-lerp(0.30, 0.78, sq), fy + ay + 1.1 * air * (0.6 if fly < 1 else 0.0), lerp(0.2 + 0.2 * math.sin(math.pi * fly), 0.2, sq)))
    p.ik["legL"] = (fl, Vector((1.0 + 0.8 * sq, -0.4 * (1 - sq) - 0.1, 0.2 + 1.2 * sq)))
    p.ik["legR"] = (fr, Vector((-1.0 - 0.8 * sq, -0.4 * (1 - sq) - 0.1, 0.2 + 1.2 * sq)))
    p.foot_pitch["L"], p.foot_pitch["R"] = (-10.0 * air, -10.0 * air)
    # the body: stooped over the run, thrown out flat in the leap, then bent right over you
    lean = lerp(lerp(24.0, 58.0, ease(fly)), 78.0, settle)
    p.turn("Hips", (X, 6.0 + 18.0 * ease(fly) - 14.0 * settle))
    p.turn("Spine", (X, lean * 0.30 - 4.0 * settle))
    p.turn("Spine1", (X, lean * 0.34), (Z, 4.0 * heave * tear))
    p.turn("Spine2", (X, lean * 0.36 + 6.0 * settle), (Z, -3.0 * heave * tear))
    p.turn("Neck", (X, lerp(-8.0, 20.0, settle) + 12.0 * tear * heave))
    # the head: on you the whole way; once sat it cocks and ticks over your face
    cock = 16.0 * math.sin(k * 1.9) + 9.0 * math.sin(k * 5.3 + 2.0)
    p.turn("Head", (X, lerp(-20.0, 30.0, settle)), (Y, cock * tear), (Z, 6.0 * math.sin(k * 3.1) * tear))
    # arms: out in front, reaching for you through the leap; once sat, both hands on your face, raking
    reach = ease(fly)
    shoulder = lambda sx: Vector((sx * 0.45, lerp(fy - 0.15, fy - 0.1, 1) - 0.0, 0.0))
    hand_l = Vector((0.35, fy - 2.2, fz + 0.25)).lerp(Vector((0.26, EYE.y - 0.15, EYE.z + 0.36)), settle)
    hand_r = Vector((-0.35, fy - 2.2, fz + 0.1)).lerp(Vector((-0.26, EYE.y - 0.15, EYE.z + 0.36)), settle)
    # the raking: each hand drags down across your face (toward you, then back up and away), alternating, faster as it goes
    rate = 3.4 + 1.8 * ramp(k, 0.0, 4.0)
    for sgn, hand in ((1, hand_l), (-1, hand_r)):
        ph = rate * k + (0.0 if sgn > 0 else 0.5)
        sweep = math.sin(math.tau * ph)
        down = max(0.0, math.sin(math.tau * ph + 0.5))
        hand.y += 0.10 * sweep * tear
        hand.z += 0.14 * (down - 0.5) * tear * (1.0 - 0.4 * math.cos(math.tau * ph))
        hand.x += sgn * (-0.08 * sweep) * tear
    p.ik["armL"] = (hand_l, Vector((1.0, 0.2, 0.6)))
    p.ik["armR"] = (hand_r, Vector((-1.0, 0.2, 0.6)))
    c = lerp(0.35, 0.9, ease(fly)) + 0.1 * math.sin(k * 14.0) * tear
    p.curl["L"] = [c * 0.9, c, c, c, c * 0.95]
    p.curl["R"] = [c * 0.9, c, c, c, c * 0.95]
    p.spread["L"] = lerp(1.2, 0.3, tear)
    p.spread["R"] = lerp(1.2, 0.3, tear)
    return p


def kill_eye_clear():
    for o in list(bpy.data.objects):
        if o.name == "KillEye":
            bpy.data.objects.remove(o, do_unlink=True)


def kill_eye():
    """An empty where your eyes are, lying under it looking up (-Z of the empty points the way you look)"""
    kill_eye_clear()
    e = bpy.data.objects.new("KillEye", None)
    e.empty_display_type = 'ARROWS'
    e.empty_display_size = 0.2
    bpy.context.scene.collection.objects.link(e)
    f = Vector((0, 0, 1))
    u = Vector((0, 1, 0))
    r = f.cross(u)
    e.matrix_world = Matrix(((r.x, u.x, -f.x, EYE.x), (r.y, u.y, -f.y, EYE.y), (r.z, u.z, -f.z, EYE.z), (0, 0, 0, 1)))
    return e


# ---------------------------------------------------------------- build
def make_loop(name, n, fn):
    begin(name, n)
    for f in range(n + 1):
        key(fn((f % n) / n), f)
    end()


def make_once(name, seconds, fn):
    n = int(round(seconds * FPS))
    begin(name, n)
    for f in range(n + 1):
        key(fn(f / FPS), f)
    end()


def build_all():
    prepare()
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)
    make_loop("idle", 120, idle)
    make_loop("walk", int(WALK_T * FPS), walk)
    make_loop("run", int(RUN_T * FPS), run)
    make_once("spot", 0.9, spot)
    make_once("scream", 3.6, scream)
    make_once("kill", sum(KILL_T), kill)
    kill_eye()


def export():
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for pb in arm.pose.bones:
        pb.rotation_quaternion = Quaternion()
        pb.location = Vector()
    if arm.animation_data:
        arm.animation_data.action = None
    arm.animation_data_create()
    for tr in list(arm.animation_data.nla_tracks):
        arm.animation_data.nla_tracks.remove(tr)
    for a in bpy.data.actions:
        tr = arm.animation_data.nla_tracks.new()
        tr.name = a.name
        tr.strips.new(a.name, int(a.frame_range[0]), a)
        tr.mute = True
    bpy.ops.object.select_all(action='DESELECT')
    for n in ("TallOne_Rig", "TallOne_Body", "TallOne_Eyes_Mesh", "KillEye"):
        o = bpy.data.objects.get(n)
        if o is not None:
            o.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', use_selection=True, export_animations=True,
                              export_animation_mode='NLA_TRACKS', export_force_sampling=True,
                              export_frame_range=False, export_anim_single_armature=True,
                              export_def_bones=False, export_yup=True, export_apply=False,
                              export_image_format='AUTO')
    print("wrote", OUT)


if __name__ == "__main__":
    build_all()
    export()
