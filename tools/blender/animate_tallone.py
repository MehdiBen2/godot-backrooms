"""Author THE TALL ONE's clips (models/entities/tall/tall_one.glb) on the rig built in tall_one.blend.

    blender -b tools/blender/tall_one.blend --python tools/blender/animate_tallone.py
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
    run       0.8 s loop   the flee and the hunt: a low predatory sprint, torso driven forward, the head level on its target,
                           long low strides, the arms swept back and loose (10 m/s)
    spot      0.9 s        it sees you: the head snaps round, the body recoils, hands come up
    scream    3.6 s        head thrown back, arms flung wide, the whole body shaking (holds its last frame)
    peer      5.1 s        it saw you hide: it folds down into a wide squat in front of the door, its face level with the
                           vent, stares in for 3 s with the head cocking over, fingers laid on the door, then stands
    kill      9.6 s        pounce 0-1.05 (hips fly in from 6 m behind the root, hands driving into your chest), it lands
                           kneeling astride you with one long hand planted on the floor beside your head; then the tear
                           (kill_hands: wound-up claw blows, a pause to look at its fingers, both hands hooked in your
                           cheeks and pulled apart in jerks, a frenzy of blows out of step, and its face coming down to
                           yours, both hands slammed on the floor either side of your head). The root is where your chest
                           ends up; "KillEye" is where your eyes are, lying under it looking up. tall_one.gd rides the
                           camera there and reads the blows straight off the hands (their speed and nearness to KillEye).

Preview: blender -b tools/blender/tall_one.blend --python tools/blender/preview_tallone.py -- OUT.png clip=kill t=1,2,3 view=side
"""
import bpy
import math
from mathutils import Matrix, Quaternion, Vector

OUT = r"C:\Users\alhyu\Documents\GitHub\godot-backrooms\godot-backrooms\models\entities\tall\tall_one.glb"
BLEND = r"C:\Users\alhyu\Documents\GitHub\godot-backrooms\tools\blender\tall_one.blend"
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
        pb.rotation_quaternion = Quaternion()
        pb.location = Vector()
    build_eyes()
    load_rest()


EYE_CX = 0.072                      # the eyes' distance either side of the face's midline (a clear gap between them), and their height
EYE_CZ = 4.195
EYE_W = 0.068
EYE_H = 0.049
EYE_U = ((0.021, 0.351), (0.654, 0.976))   # tall_eyes.png: where each eye is in the picture (left to right)


def build_eyes():
    """The two eyes (tall_eyes.png) laid on the face and skinned to the Head bone, so they ride the head wherever it goes.
    (A bone-parented mesh sits off the bone's TAIL in Blender: lengthening the Head bone once sent them down to the chest.)"""
    old = bpy.data.objects.get("TallOne_Eyes_Mesh")
    mat = old.data.materials[0] if old is not None and old.data.materials else bpy.data.materials.get("TallOne_Eyes")
    if old is not None:
        bpy.data.objects.remove(old, do_unlink=True)
    body = bpy.data.objects["TallOne_Body"]
    verts, uvs, faces = [], [], []
    nx, nz = 12, 8
    for (u0, u1), side in zip(EYE_U, (-1, 1)):
        base = len(verts)
        for j in range(nz + 1):
            for i in range(nx + 1):
                fx, fz = i / nx, j / nz
                x = side * EYE_CX + (fx - 0.5) * EYE_W
                z = EYE_CZ + (fz - 0.5) * EYE_H
                ok, loc, nrm, _ = body.ray_cast(Vector((x, -1.0, z)), Vector((0, 1, 0)))
                if not ok:
                    loc = Vector((x, -0.18, z))
                verts.append(loc + Vector((0, -0.003, 0)))
                uvs.append((u0 + (u1 - u0) * fx, fz))
        for j in range(nz):
            for i in range(nx):
                a = base + j * (nx + 1) + i
                faces.append((a, a + 1, a + nx + 2, a + nx + 1))
    me = bpy.data.meshes.new("TallOne_Eyes")
    me.from_pydata(verts, [], faces)
    uvl = me.uv_layers.new(name="UVMap")
    for poly in me.polygons:
        poly.use_smooth = True
        for li in poly.loop_indices:
            uvl.data[li].uv = uvs[me.loops[li].vertex_index]
    if mat is not None:
        me.materials.append(mat)
    eo = bpy.data.objects.new("TallOne_Eyes_Mesh", me)
    bpy.context.scene.collection.objects.link(eo)
    eo.parent = arm
    vg = eo.vertex_groups.new(name="Head")
    vg.add(list(range(len(verts))), 1.0, 'REPLACE')
    m = eo.modifiers.new("Armature", 'ARMATURE')
    m.object = arm


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
    """A low predatory sprint: the torso driven forward over its feet, the head held level on whatever it is running at,
    long strides with the feet kept close to the floor, the arms swept back and swinging loose (never pumping)"""
    p = Pose()
    w = math.tau * u
    fl = gait(u % 1.0, RUN_STRIDE * 2, RUN_DUTY, 0.62, 0.0)
    fr = gait((u + 0.5) % 1.0, RUN_STRIDE * 2, RUN_DUTY, 0.62, 0.0)
    peak = 2 * w - math.tau * (RUN_DUTY + (0.5 - RUN_DUTY) / 2.0)          # highest in the middle of the flight
    hz = 2.02 + 0.08 * math.cos(peak)
    hips_at(p, -0.04 * math.sin(w), -0.55, hz)
    legs(p, None, ((0.27, -0.22 - fl[0], 0.2 + fl[1]), (-0.27, -0.22 - fr[0], 0.2 + fr[1])), knees=0.10,
         pitch=(-26.0 * ramp(fl[1], 0.05, 0.5), -26.0 * ramp(fr[1], 0.05, 0.5)))
    sw = math.sin(w)
    p.turn("Hips", (X, 10.0), (Z, 8.0 * sw), (Y, -2.5 * sw))
    p.turn("Spine", (X, 8.0), (Z, -6.0 * sw))
    p.turn("Spine1", (X, 8.0), (Z, -6.0 * sw))
    p.turn("Spine2", (X, 8.0), (Z, -4.0 * sw))
    p.turn("LeftShoulder", (X, -4.0 * sw))
    p.turn("RightShoulder", (X, 4.0 * sw))
    # the neck reaches out, the head stays level and keeps its eyes on the front: the body does not agree with it
    p.turn("Neck", (X, -4.0))
    p.turn("Head", (X, -28.0 + 2.0 * math.cos(2 * w)), (Y, 5.0 * math.sin(w * 2.0 + 1.0)), (Z, 3.0 * sw))
    arms_fk(p, -26.0 + 14.0 * sw, 9.0, 24.0 + 8.0 * sw, -26.0 - 14.0 * sw, 10.0, 24.0 - 8.0 * sw)
    p.curl["L"] = [0.35, 0.5, 0.55, 0.5, 0.55]
    p.curl["R"] = [0.35, 0.55, 0.5, 0.55, 0.5]
    p.spread["L"] = 0.8
    p.spread["R"] = 0.8
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


# ---------------------------------------------------------------- peer
PEER_T = (1.2, 3.0, 0.9)                        # folding down, the stare, back up
PEER_DOOR = 1.78                                # m in front of the root: the door it peers at (tall_one.gd PEER_DOOR)
PEER_FEET = ((0.66, -0.34, 0.20), (-0.66, -0.26, 0.20))    # wide: the knees thrown out either side of it
PEER_HAND = Vector((-0.66, -(PEER_DOOR - 0.42), 1.22))     # its right wrist, out to its side: the fingers laid on the door below the vent
_IDLE_HAND = []


def peer(t):
    """It watched you get in. It folds right down in front of the door, knees out wide like something about to jump,
    bends its long body over them and brings its face level with the vent, the head straightened to look in. It stares
    for three seconds, the head slowly cocking over, one tick at the middle of it; its right hand comes up and lays its
    fingers on the door beside the vent, tapping. Then it unfolds and stands (the root does not move)."""
    T0, T1, T2 = PEER_T
    d = ease5((t / T0)) * (1.0 - ease(((t - T0 - T1) / T2)))           # how far down it is
    stare = ramp(t, T0 * 0.7, T0 + 0.2) * (1.0 - ramp(t, T0 + T1 - 0.3, T0 + T1 + 0.1))
    reach = ramp(t, T0 + 0.3, T0 + 0.9) * (1.0 - ramp(t, T0 + T1 - 0.5, T0 + T1))
    tick = ramp(t, T0 + 1.55, T0 + 1.62) * (1.0 - ramp(t, T0 + 2.0, T0 + 2.4))
    cock = ramp(t, T0, T0 + T1) * stare
    br = math.sin(t * 2.4)
    if not _IDLE_HAND:
        _IDLE_HAND.append(solve(idle(0.0))[1]["RightHand"].translation.copy())
    p = Pose()
    hips_at(p, 0.0, lerp(-0.06, 0.22, d), lerp(2.60, 1.16, d) - 0.012 * br * d)
    legs(p, None, tuple(tuple(lerp(a, b, d) for a, b in zip(i0, i1)) for i0, i1 in
                        zip(((0.30, 0.02, 0.20), (-0.30, 0.0, 0.20)), PEER_FEET)), knees=lerp(0.1, 1.1, d))
    p.turn("Hips", (X, 31.0 * d), (Y, 1.2))
    p.turn("Spine", (X, lerp(5.0, 22.0, d) + 0.6 * br))
    p.turn("Spine1", (X, lerp(4.0, 20.0, d) + 0.6 * br))
    p.turn("Spine2", (X, lerp(3.0, 14.0, d)))
    p.turn("LeftShoulder", (X, -1.0 * br))
    p.turn("RightShoulder", (X, -6.0 * reach))
    # the head comes up level as the body goes down: it never takes its eyes off the vent
    p.turn("Neck", (X, lerp(10.0, -18.0, d)), (Y, 3.0))
    p.turn("Head", (X, lerp(8.0, -34.0, d) + 1.5 * math.sin(t * 1.3)),
           (Y, lerp(13.0, 6.0, d) + 22.0 * cock + 9.0 * tick), (Z, -4.0 * tick + 2.0 * math.sin(t * 0.9)))
    # the left arm hangs between its knees, the knuckles near the floor; the right reaches for the door
    p.aim["LeftArm"] = dirn(lerp(4.0, 38.0, d), lerp(5.0, 12.0, d), 1)
    p.aim["LeftForeArm"] = dirn(lerp(13.0, 30.0, d), 8.0, 1)
    hang = Vector((-0.42, -0.95, 0.42))
    p.ik["armR"] = (_IDLE_HAND[0].lerp(hang, d).lerp(PEER_HAND, reach), Vector((-1.0, 0.3, -0.6)))
    tap = [0.5 + 0.5 * math.sin(t * 9.0 - i * 0.9) for i in range(5)]
    p.curl["L"] = [0.35, 0.45, 0.5, 0.45, 0.5]
    p.curl["R"] = [lerp(0.4, 0.15 + 0.12 * tap[i] * reach, reach) for i in range(5)]
    p.spread["L"] = 0.4
    p.spread["R"] = lerp(0.4, 1.1, reach)
    return p


def peer_eye(t):
    """Where its eyes are at `t` (model space) and its right wrist: to check the stare lines up with the vent"""
    P = solve(peer(t))[1]
    eye = P["Head"] @ REST["Head"].inverted() @ Vector((0.0, -0.18, EYE_CZ))
    return eye, P["RightHand"].translation


# ---------------------------------------------------------------- the kill
KILL_T = (1.05, 0.65, 7.9)                      # pounce, settle, tear
KILL_N = int(round(sum(KILL_T) * FPS))
EYE = Vector((0.0, -0.62, 0.18))                # your eyes, lying on your back with your head toward its front
SIT = Vector((0.0, 0.30, 0.92))                 # its hips, kneeling astride your chest
POUNCE_FROM = 6.0                               # m behind the root its hips start (tall_one.gd starts the clip that far out)
KNEE_X = 0.50                                   # its knees either side of your ribs, its shins along the floor behind them
SHIN_Y = 1.25
FACE_Y = EYE.y                                  # your face; -Y from it is your brow and the top of your head, +Y your chin
CLAW_Z = 0.46                                   # wrist height with the claws in your face (the fingers are ~0.45 m long)
BRACE = Vector((0.58, -0.82, 0.07))             # the hand it plants on the floor beside your head
HOVER = Vector((-0.12, -0.55, 0.85))            # the other, held over your face, fingers hanging
LOOK = Vector((-0.30, -0.66, 1.30))             # raised to its own face: it looks at what is on its fingers
GRIP_L = Vector((0.17, FACE_Y - 0.02, 0.50))    # the rip: both hands hooked into your cheeks, either side of your eyes
GRIP_R = Vector((-0.17, FACE_Y + 0.03, 0.50))


def seg(k, a, b):
    return ease((k - a) / (b - a))


EASES = {"io": ease, "lin": lambda u: u, "in": lambda u: u * u, "in3": lambda u: u * u * u,
         "out": lambda u: 1.0 - (1.0 - u) ** 2, "out3": lambda u: 1.0 - (1.0 - u) ** 3}


class Track:
    """One hand's tear, keyed: (k, wrist position, finger curl, spread, drive, the ease INTO this key). `drive` is the
    shoulder's part in it: +1 cocked back for a blow, -1 thrown through it (the body twists and dips with it)."""

    def __init__(s, pos, curl, spread):
        s.keys = [(0.0, Vector(pos), curl, spread, 0.0, "io")]

    def add(s, k, pos, curl, spread, drive=0.0, ez="io"):
        assert k >= s.keys[-1][0] - 1e-6, (k, s.keys[-1][0])
        s.keys.append((k, Vector(pos), curl, spread, drive, ez))

    def around(s, k, pos, curl, spread, drive=0.0, ez="io"):
        """add(), but a hand crossing from one side of you to the other goes up over your face, not through it"""
        a = s.keys[-1]
        p0, p1 = a[1], Vector(pos)
        d = p1 - p0
        u = 0.0 if d.length_squared < 1e-9 else max(0.0, min(1.0, (EYE - p0).dot(d) / d.length_squared))
        c = p0 + d * u
        if (c - EYE).length < 0.62 and 0.05 < u < 0.95:
            w = Vector((c.x, c.y, max(c.z, EYE.z + 0.9)))
            s.add(a[0] + (k - a[0]) * max(0.35, min(0.65, u)), w, lerp(a[2], curl, 0.5), lerp(a[3], spread, 0.5),
                  lerp(a[4], drive, 0.5), "in" if ez in ("io", "in") else "lin")
            ez = "out" if ez in ("io", "out") else ez
        s.add(k, pos, curl, spread, drive, ez)

    def hold(s, k):
        """Stay where it is until k"""
        a = s.keys[-1]
        if k > a[0]:
            s.keys.append((k, a[1].copy(), a[2], a[3], a[4], "lin"))

    def end(s):
        return s.keys[-1][0]

    def at(s, k):
        ks = s.keys
        if k <= ks[0][0]:
            return ks[0][1:5]
        for a, b in zip(ks, ks[1:]):
            if k <= b[0]:
                e = EASES[b[5]]((k - a[0]) / max(1e-6, b[0] - a[0]))
                return a[1].lerp(b[1], e), lerp(a[2], b[2], e), lerp(a[3], b[3], e), lerp(a[4], b[4], e)
        return ks[-1][1:5]


def swipe(T, sx, at, wind=0.30, follow=0.36):
    """One claw stroke by the hand on side sx (+1 its left), its claws landing on your brow at k = `at`: cocked up by its
    shoulder (ease-out into a held beat), slammed down (ease-in: fastest as it lands), dragged down across your face to
    the far cheek with the claws in (slow, it is pulling through you), then flung out past you (ease-out)"""
    cocked = Vector((sx * 0.62, FACE_Y + 0.22, 1.30))
    hit = Vector((sx * 0.15, FACE_Y - 0.17, CLAW_Z))
    rake = Vector((-sx * 0.20, FACE_Y + 0.22, CLAW_Z - 0.03))
    mid = hit.lerp(rake, 0.5) + Vector((0.0, 0.0, 0.05))         # (over your eyes, not through them)
    out = Vector((-sx * 0.60, FACE_Y + 0.48, 0.70))
    T.hold(at - 0.12 - wind)
    T.around(at - 0.14, cocked, 0.5, 1.4, 1.0, "out")
    T.add(at - 0.11, cocked + Vector((sx * 0.03, 0.02, 0.05)), 0.5, 1.4, 1.0, "io")
    T.add(at, hit, 0.85, 0.9, -0.3, "in3")
    T.add(at + 0.09, mid, 0.95, 0.7, -0.6, "lin")
    T.add(at + 0.18, rake, 0.98, 0.6, -0.8, "lin")
    T.add(at + follow, out, 0.55, 1.1, -1.0, "out")


# k (seconds into the tear) of every blow, for tall_one.gd to cross-check against what it measures off the hands
KILL_BLOWS = []


def kill_hands():
    """The tear, beat by beat (k = seconds into it): it studies you, the right hand sinking over your face; a slow,
    wound-up rake with the right; the left lets go of the floor for one of its own; a pause, the right hand raised to
    its face to look at its fingers; then the rip: both hands hooked into your cheeks and pulled apart (out to the sides
    of your view) in three jerks that grow until it tears free and both arms fly up; then it can't stop, rakes out of step, faster and
    faster; and last it plants both hands on the floor either side of your head while its face comes down to yours"""
    del KILL_BLOWS[:]
    L = Track(BRACE, 0.25, 1.2)
    R = Track(HOVER, 0.45, 1.0)
    R.add(0.8, HOVER + Vector((0.02, -0.04, -0.18)), 0.55, 1.1)
    for T, sx, at, w in ((R, -1, 1.35, 0.35), (L, 1, 2.2, 0.32)):
        swipe(T, sx, at, w)
        KILL_BLOWS.append(at)
    R.around(2.75, LOOK, 0.35, 1.3)
    L.around(3.15, BRACE, 0.3, 1.2)
    R.hold(3.35)
    L.hold(3.45)
    R.add(3.75, GRIP_R, 0.8, 1.2, -0.3, "in")
    L.add(3.85, GRIP_L, 0.9, 1.1, -0.3, "in")
    R.hold(4.05)
    L.hold(4.05)
    gl, gr = GRIP_L.copy(), GRIP_R.copy()
    for at, d in ((4.15, 0.07), (4.5, 0.10), (4.8, 0.13)):
        gl += Vector((d, -0.2 * d, 0.5 * d))
        gr += Vector((-d, 0.2 * d, 0.5 * d))
        for T, to, home, c in ((R, gr, GRIP_R, 0.95), (L, gl, GRIP_L, 0.98)):
            T.hold(at - 0.07)
            T.add(at, to, c, 0.8, -0.7, "out")
            T.add(at + 0.12, to.lerp(home, 0.25 * d / 0.13), c, 0.8, -0.3, "io")
        KILL_BLOWS.append(at)
    for T, to in ((R, Vector((-0.55, FACE_Y - 0.40, 1.10))), (L, Vector((0.58, FACE_Y + 0.40, 1.05)))):
        T.hold(4.92)
        T.add(5.06, to, 0.6, 1.4, 1.0, "out")
    KILL_BLOWS.append(5.0)
    at, gap, sx = 5.45, 0.36, -1
    while at < 6.95:
        T = R if sx < 0 else L
        free = at - T.end() - 0.12
        swipe(T, sx, at, max(0.04, min(0.3, free - 0.02)), follow=0.26)
        KILL_BLOWS.append(at)
        at += gap
        gap = max(0.27, gap * 0.9)
        sx = -sx
    for T, sx in ((L, 1), (R, -1)):
        T.around(max(T.end(), 6.95) + 0.35, Vector((sx * 0.48, FACE_Y - 0.12, 0.10)), 0.3, 1.3)
    return {"L": L, "R": R}


HANDS = kill_hands()


def kill(t):
    """Pounce, land kneeling astride you, then take your face apart (kill_hands has the beats). Root = your chest on the
    floor; it faces -Y; you lie along -Y. The body works with the hands: each blow is cocked from the shoulder (the
    trunk twists back and rises) and thrown through (it twists the other way and dips into you); the head stays on
    your face the whole time but for the one pause where it looks at its fingers."""
    t1 = KILL_T[0]
    t2 = t1 + KILL_T[1]
    p = Pose()
    fly = min(1.0, t / t1)
    fy = lerp(POUNCE_FROM, SIT.y, 1.0 - (1.0 - fly) ** 2)                # out of the run at its own speed, braking into you
    arc = 0.62 * math.sin(math.pi * min(1.0, fly * 1.04)) ** 1.4
    fz = lerp(1.95, SIT.z, ease(fly)) + arc
    bounce = -0.07 * math.exp(-((t - (t1 + 0.1)) / 0.1) ** 2)
    settle = seg(t, t1, t2)
    k = max(0.0, t - t2)
    tear = seg(t, t2 - 0.1, t2 + 0.4)
    pos_l, cl, spl, dl = HANDS["L"].at(k)
    pos_r, cr, spr, dr = HANDS["R"].at(k)
    dip = min(1.0, max(0.0, -dl) + max(0.0, -dr)) * tear       # thrown into a blow: the body drops onto you
    cock = min(1.0, max(0.0, dl) + max(0.0, dr)) * tear        # wound up: it rises off you
    twist = (dr - dl) * tear                                     # + the right shoulder back
    look = seg(k, 2.4, 2.75) * (1.0 - seg(k, 3.3, 3.6))         # the pause: it looks at its fingers
    # effort: how hard it is working (the breathing, the rocking)
    effort = 0.3 + 0.7 * seg(k, 5.0, 6.8)
    rock = math.sin(k * (4.0 + 3.0 * effort)) * 0.35 * effort * tear
    dive = seg(k, 7.0, 7.75)                                             # the last moments: its face comes down to yours
    hips_at(p, 0.0, fy - 0.05 * rock + 0.05 * dip - 0.12 * dive,
            fz + bounce - 0.05 * dip + 0.04 * cock + 0.025 * math.sin(k * 5.0) * effort * tear - 0.32 * dive)
    # legs: trailing in the leap, the knees swung forward to land either side of your ribs, shins flat behind them
    kneel = seg(t, t1 - 0.30, t1 + 0.30)
    for sx, name in ((1, "L"), (-1, "R")):
        lag = 0.0 if sx > 0 else 0.15
        air = Vector((sx * 0.30, fy + 0.85 + lag, 0.30 + 0.30 * math.sin(math.pi * fly)))
        down = Vector((sx * KNEE_X, SHIN_Y, 0.11))
        p.ik["leg" + name] = (air.lerp(down, kneel), Vector((sx * 0.35, -1.0, 0.15 + 0.35 * kneel)))
        p.foot_pitch[name] = lerp(-12.0, 55.0, kneel)                    # toes tucked under, the shin along the floor
    # the body: stretched out in the leap, then folded right over you; each blow twists the trunk back with the cocked
    # shoulder and throws it through, dipping onto you
    lean = lerp(lerp(28.0, 52.0, ease(fly)), 60.0, settle) + 4.0 * rock + 9.0 * dip - 7.0 * cock + 24.0 * dive
    p.turn("Hips", (X, lerp(10.0 + 12.0 * ease(fly), 18.0, settle) + 2.0 * rock), (Z, 4.0 * twist))
    p.turn("Spine", (X, lean * 0.24), (Z, 3.0 * math.sin(k * 0.9) * tear + 6.0 * twist))
    p.turn("Spine1", (X, lean * 0.26), (Z, 8.0 * twist), (Y, -4.0 * twist))
    p.turn("Spine2", (X, lean * 0.22), (Z, 5.0 * twist))
    p.turn("LeftShoulder", (X, -6.0 * effort * tear), (Y, -12.0 * max(0.0, dl) * tear))
    p.turn("RightShoulder", (X, -6.0 * effort * tear), (Y, 12.0 * max(0.0, dr) * tear))
    # the head: on your face the whole way, cocking slowly, nodding into every blow; at the pause it turns to its hand
    tilt = 15.0 * math.sin(k * 0.8) * (1.0 - look) * (1.0 - 0.6 * dive)
    p.turn("Neck", (X, lerp(-6.0, 22.0, settle) + 4.0 * rock - 12.0 * look + 6.0 * dive), (Z, -10.0 * look))
    p.turn("Head", (X, lerp(-22.0, 46.0, settle) + 5.0 * dip - 20.0 * look + 16.0 * dive),
           (Y, (tilt + 10.0 * look) * tear), (Z, (5.0 * math.sin(k * 0.55 + 1.0) - 26.0 * look) * tear))
    # arms: reaching in the leap, driving into your chest as it lands, then the tear (kill_hands)
    reach = Vector((0.30, fy - 2.1, fz + 0.12))
    chest = Vector((0.27, 0.62, 0.27))
    drive = seg(t, 0.28, 0.42)
    hand_l = Vector((reach.x, reach.y, reach.z)).lerp(chest, drive)
    hand_r = Vector((-reach.x, reach.y, reach.z)).lerp(Vector((-chest.x, chest.y, chest.z)), drive)
    into = seg(t, t1 + 0.05, t2 + 0.25)
    shake = 0.006 + 0.01 * effort                                        # it trembles: worse as it goes on
    pos_l = pos_l + Vector((0.0, shake * math.sin(k * 19.0), shake * math.sin(k * 23.0 + 1.0)))
    pos_r = pos_r + Vector((0.0, shake * math.sin(k * 21.0 + 2.0), shake * math.sin(k * 17.0)))
    hand_l = hand_l.lerp(pos_l, into)
    hand_r = hand_r.lerp(pos_r, into)
    # elbows out and up; cocked, the elbow goes high and back behind the shoulder
    p.ik["armL"] = (hand_l, Vector((1.0, 0.25 + 0.5 * max(0.0, dl), 0.8 + 0.6 * max(0.0, dl))))
    p.ik["armR"] = (hand_r, Vector((-1.0, 0.25 + 0.5 * max(0.0, dr), 0.8 + 0.6 * max(0.0, dr))))
    # fingers: open in the reach, then the track's: spread flat on the floor, claws cocked open, hooked in the rake
    hook = lerp(0.4, 0.95, ease(fly))
    work = 0.06 * math.sin(k * 14.0) * effort
    cl = lerp(hook, cl + work, into)
    cr = lerp(hook, cr - work, into)
    p.curl["L"] = [cl * 0.9, cl, cl * 1.05, cl * 1.05, cl * 1.1]
    p.curl["R"] = [cr * 0.9, cr, cr * 1.05, cr * 1.05, cr * 1.1]
    p.spread["L"] = lerp(1.2, spl, into)
    p.spread["R"] = lerp(1.2, spr, into)
    return p


def kill_eye_clear():
    for o in list(bpy.data.objects):
        if o.name == "KillEye":
            bpy.data.objects.remove(o, do_unlink=True)


def kill_eye():
    """An empty where your eyes are, lying under it looking up. Godot re-expresses an empty's rotation in its own
    axes (x, z, -y), so this basis is the one that arrives there as: -Z = up (the way you look), +Y = its facing
    (the top of your head), +X = its left"""
    kill_eye_clear()
    e = bpy.data.objects.new("KillEye", None)
    e.empty_display_type = 'ARROWS'
    e.empty_display_size = 0.2
    bpy.context.scene.collection.objects.link(e)
    e.matrix_world = Matrix(((1, 0, 0, EYE.x), (0, 0, -1, EYE.y), (0, 1, 0, EYE.z), (0, 0, 0, 1)))
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
    make_once("peer", sum(PEER_T), peer)
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
    bpy.ops.wm.save_as_mainfile(filepath=BLEND)
