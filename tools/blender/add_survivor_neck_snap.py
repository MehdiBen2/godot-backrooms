"""Add THE MANNEQUIN's kill, seen from outside, to the survivor suit (models/player/survivor.glb), so the
others see a friend's neck snapped instead of the generic fall.

    blender --background --python tools/blender/add_survivor_neck_snap.py -- <in.glb> <out.glb>
    e.g. ... -- godot-backrooms/models/player/survivor.glb godot-backrooms/models/player/survivor.glb

Run it after tools/blender/add_survivor_directions.py. It keeps every clip in the file as it is and adds:

    death_neck_snap   ~6 s, holds its last frame. Timed to mannequin_snap.gd (SNAP_AT 2.3 s, the fade from
                      3.7 s): the start (hands fly up, the torch is flung), frozen dread (trembling, breathing
                      hard, the head half turning to look behind), the hands reaching up as its grip closes
                      on the head, the whip (head wrenched ~150 deg round to face it, the body yanked round
                      and twisting back under it, the arms thrown out), hanging limp in its grip, and from
                      3.7 s let go: the legs give way and it drops onto its knees (~4.0 s), goes over them
                      like a felled post and lands face down (~4.8 s), rolled a little onto its left side,
                      the head still turned the wrong way.

Every bone is posed as its idle_still pose with a rotation on top, in armature axes (x = its left, -y =
forward, z = up), each bone carrying its parent's. The legs are IK: feet planted standing, knees on the floor
kneeling and lying. The fall is physics (gravity onto the knees, then theta'' = g/L sin theta over them, a
small bounce). On top, the chest, neck, head and arms are damped springs (the springs section): they lag,
overshoot and swing when the body jolts, tense while alive; dead, the arms are dead weight under gravity
and lie where the floor stops them. Nothing goes more than ~1.5 cm into the floor on any frame.
Inside a live Blender (the MCP), exec the file with BUILD_ONLY = True set to build without exporting.
"""
import sys
import math

import bpy
from mathutils import Vector, Matrix, Quaternion

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
IN_GLB = globals().get("IN_GLB") or (args[0] if args else None)
OUT_GLB = globals().get("OUT_GLB") or (args[1] if len(args) > 1 else None)
BUILD_ONLY = globals().get("BUILD_ONLY", False)

CLIP = "death_neck_snap"
LENGTH = 5.0               # s at least (it runs on until the springs have settled after the fall)
SNAP_AT = 2.3              # mannequin_snap.gd: the crack
RELEASE = 3.7              # ... where the first-person view starts to fade: it lets go
TWIST = math.radians(150)  # how far round the head ends up
GAME_HEIGHT = 2.0          # m: what the game fits the suit to (MODEL_HEIGHT in the scripts)

# =============================================================== load (clearing the scene, keeping prefs)
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
for coll in (bpy.data.actions, bpy.data.meshes, bpy.data.armatures, bpy.data.materials, bpy.data.images):
    for d in list(coll):
        coll.remove(d)
scene = bpy.context.scene
scene.render.fps = 24
FPS = scene.render.fps
bpy.ops.import_scene.gltf(filepath=IN_GLB)
for o in [o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("Icosphere")]:
    bpy.data.objects.remove(o, do_unlink=True)            # the importer's bone-shape sphere
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
body = next(o for o in bpy.data.objects if o.type == "MESH")
ad = arm.animation_data_create()
for t in list(ad.nla_tracks):
    ad.nla_tracks.remove(t)
SOURCE = {a.name: a for a in bpy.data.actions}
print("clips in", IN_GLB, sorted(SOURCE))


def bind(act):
    ad.action = act
    if getattr(ad, "action_slot", None) is None and getattr(act, "slots", None):
        ad.action_slot = act.slots[0]


# =============================================================== the rig (as add_survivor_directions.py)
def rot3(m):
    return m.to_3x3().normalized()


def _depth(b):
    d = 0
    while b.parent:
        b, d = b.parent, d + 1
    return d


BONES = sorted(arm.data.bones, key=_depth)               # parents before children
REST = {b.name: b.matrix_local.copy() for b in BONES}
PARENT = {b.name: (b.parent.name if b.parent else None) for b in BONES}
REL = {n: (REST[p].inverted() @ REST[n]) if p else REST[n] for n, p in PARENT.items()}
# the legs are solved once the pelvis is placed: before the first thigh, after everything above it
FIRST_THIGH = next(b.name for b in BONES if b.name.endswith("_Thigh"))


def sample(act, frame):
    """bone -> (local basis, armature-space matrix) at `frame`"""
    bind(act)
    scene.frame_set(int(math.floor(frame)), subframe=frame - math.floor(frame))
    return {pb.name: (pb.matrix_basis.copy(), pb.matrix.copy()) for pb in arm.pose.bones}


def solve(goals, local, hip_pos=None, legs=None):
    """goals: bone -> armature-space 3x3 rotation; every other bone keeps its `local` basis. legs(M) is
    called once the pelvis is placed and returns more goals (the IK). Returns bases."""
    M, basis = {}, {}
    for b in BONES:
        n = b.name
        p = PARENT[n]
        chain = (M[p] @ REL[n]) if p else REL[n].copy()
        if n == FIRST_THIGH and legs:
            goals = dict(goals)
            goals.update(legs(M))
        if n in goals:
            pos = hip_pos if (n == "Hip" and hip_pos is not None) else chain.translation
            want = Matrix.Translation(pos) @ goals[n].to_4x4()
            bas = chain.inverted() @ want
            bas = Matrix.LocRotScale(bas.translation, bas.to_quaternion(), None)
        else:
            bas = local.get(n, Matrix())
        M[n] = chain @ bas
        basis[n] = bas
    return basis, M


def key_pose(basis, frame, prev):
    for n, bas in basis.items():
        pb = arm.pose.bones[n]
        loc, q, _ = bas.decompose()
        if n in prev and prev[n].dot(q) < 0:
            q.negate()
        prev[n] = q
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = q
        pb.location = loc
        pb.scale = (1, 1, 1)
        for path in ("rotation_quaternion", "location", "scale"):
            pb.keyframe_insert(path, frame=frame)


def new_action(name):
    old = bpy.data.actions.get(name)
    if old:
        bpy.data.actions.remove(old)
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    bind(act)
    return act


def frames(act):
    f0, f1 = act.frame_range
    return int(round(f0)), int(round(f1))


def fcurves(act):
    try:
        return list(act.fcurves)
    except AttributeError:
        return [fc for layer in act.layers for st in layer.strips for cb in st.channelbags for fc in cb.fcurves]


# =============================================================== leg IK (as add_survivor_directions.py)
def frame_of(u, n):
    u = u.normalized()
    n = (n - u * n.dot(u)).normalized()
    return Matrix((u, n, u.cross(n))).transposed()


class Leg:
    def __init__(self, side):
        self.side = side
        self.H0 = REST[side + "Thigh"].translation.copy()
        self.K0 = REST[side + "Calf"].translation.copy()
        self.A0 = REST[side + "Foot"].translation.copy()
        self.l1 = (self.K0 - self.H0).length
        self.l2 = (self.A0 - self.K0).length
        self.u0t = (self.K0 - self.H0).normalized()
        self.u0c = (self.A0 - self.K0).normalized()
        self.n0 = Vector((0, -1, 0)).cross(self.u0t).normalized()

    def hip_joint(self, M):
        return M["Pelvis"] @ (REST["Pelvis"].inverted() @ REST[self.side + "Thigh"]).translation

    def solve(self, H, A, pole):
        d = A - H
        dl = min(d.length, (self.l1 + self.l2) * 0.999)
        u = d.normalized()
        a = (self.l1 ** 2 - self.l2 ** 2 + dl ** 2) / (2 * dl)
        h = math.sqrt(max(self.l1 ** 2 - a * a, 0.0))
        v = (pole - u * pole.dot(u)).normalized()
        K = H + u * a + v * h
        ut, uc = (K - H).normalized(), (A - K).normalized()
        n = ut.cross(uc)
        n = n.normalized() if n.length > 1e-6 else pole.cross(u).normalized()
        Rt = frame_of(ut, n) @ frame_of(self.u0t, self.n0).transposed()
        Rc = frame_of(uc, n) @ frame_of(self.u0c, self.n0).transposed()
        return (Rt @ rot3(REST[self.side + "Thigh"])).normalized(), (Rc @ rot3(REST[self.side + "Calf"])).normalized()


LEGS = [Leg("L_"), Leg("R_")]


# =============================================================== easing
def clamp01(x):
    return max(0.0, min(1.0, x))


def smooth(x):
    x = clamp01(x)
    return x * x * (3.0 - 2.0 * x)


def ease_in(x):                     # falling: gravity
    x = clamp01(x)
    return x * x


def ease_out(x):
    x = clamp01(x)
    return 1.0 - (1.0 - x) ** 3


def whip(x):                        # mannequin_snap.gd's turn: fast out, overshoot, settle
    x = clamp01(x)
    c1 = 2.2
    return 1.0 + (c1 + 1.0) * (x - 1.0) ** 3 + c1 * (x - 1.0) ** 2


def bump(t, at, width):             # 0 -> 1 -> 0 round `at`
    return math.exp(-((t - at) / width) ** 2)


# =============================================================== the pose
BASE = sample(SOURCE.get("idle_still") or SOURCE["idle_lookaround"], 0)
BASE_ROT = {k: rot3(v[1]) for k, v in BASE.items()}
THIGH = LEGS[0].l1
SHIN = LEGS[0].l2
HIP0 = BASE["Hip"][1].translation.copy()
JOINT_UP = HIP0.z - REST["L_Thigh"].translation.z         # the hip bone sits this far above the thigh joints
KNEE_PAD = 0.062           # the knee joint's height off the floor, kneeling
ANKLE_PAD = 0.065          # ... the ankle's, the foot lying on its top
CHEST = 0.072              # lying face down, the hips come up this much more (the chest and thighs under it)
KNEE_Y = HIP0.y - 0.02     # kneeling, the knees end up just in front of where the hips were
_TOP = max((body.matrix_world @ Vector(c)).z for c in body.bound_box)
G = 9.81 / (GAME_HEIGHT / _TOP)       # gravity in model units (the game fits the suit GAME_HEIGHT m tall)
HANG_DROP = 0.054          # how far the hips have sunk while it holds them up by the head


def lerp(a, b, k):
    return a + (b - a) * k


def e(x=0.0, y=0.0, z=0.0):
    """rotation about armature x (+ bows forward), then y (+ tips to its left), then z (+ turns to its left)"""
    return Quaternion((0, 0, 1), z) @ Quaternion((0, 1, 0), y) @ Quaternion((1, 0, 0), x)


def ring(t, at, amp, hz, decay):
    """a damped wobble set off at `at`: 0 before it"""
    s = t - at
    if s <= 0.0:
        return 0.0
    return amp * math.exp(-decay * s) * math.sin(2.0 * math.pi * hz * s)


# ---- the fall, as physics: the legs give way and the hips drop onto the knees (gravity, a little held back by
# the knees folding); then it goes over them like a felled post, theta'' = g / L sin(theta), from the lean and
# speed the slump gave it, until the chest hits: a small bounce or two, and still.
def _kneel_hip(theta, lie):
    knee = Vector((HIP0.x, KNEE_Y, KNEE_PAD))
    return knee + Vector((0.0, -THIGH * math.sin(theta), THIGH * math.cos(theta) + JOINT_UP + CHEST * lie))


DROP_H = (HIP0.z - HANG_DROP) - _kneel_hip(0.0, 0.0).z
DROP_T = math.sqrt(2.0 * DROP_H / (0.8 * G))
KNEES_AT = RELEASE + DROP_T
THETA_MAX = math.pi / 2.0 - 0.1
TOPPLE_L = 0.42            # knee to the body's middle, model units
TOPPLE_HZ = 480.0


def _topple():
    h = 1.0 / TOPPLE_HZ
    th, w, t = 0.09, 0.55, 0.0
    out, flat_at, hits = [(0.0, th)], None, 0
    while t < 3.0:
        a = G / TOPPLE_L * math.sin(th) - 0.4 * w
        w += a * h
        th += w * h
        t += h
        if th >= THETA_MAX and w > 0.0:
            th = THETA_MAX
            if flat_at is None:
                flat_at = t
            hits += 1
            w = -w * (0.22 if hits == 1 else 0.1) if hits < 3 else 0.0
        out.append((t, th))
    return out, flat_at


TOPPLE, FLAT_IN = _topple()
FLAT_AT = KNEES_AT + FLAT_IN
LENGTH = max(LENGTH, FLAT_AT + 1.3)    # the springs settle before the last (held) frame


def theta_at(t):
    s = t - KNEES_AT
    if s <= 0.0:
        return 0.0
    i = min(int(s * TOPPLE_HZ), len(TOPPLE) - 2)
    (t0, a), (t1, b) = TOPPLE[i], TOPPLE[i + 1]
    return a + (b - a) * clamp01((s - t0) / max(t1 - t0, 1e-6))


class Pose:
    def __init__(self):
        self.d = {}                 # bone -> delta quaternion, in armature axes, carried to its children
        self.post = {}              # ... a tremor laid on after the springs (they would smooth it away)
        self.hip = HIP0.copy()      # where the hip bone is
        self.feet = {}              # side -> (ankle, foot delta, knee pole)
        self.limp = 0.0             # 0 alive (tense) .. 1 dead (slack): how loose the springs are
        self.free = 0.0             # 0 while it holds them up by the head .. 1 let go (the head falls too)

    def turn(self, bone, x=0.0, y=0.0, z=0.0):
        self.d[bone] = e(x, y, z) @ self.d.get(bone, Quaternion())


def arms(p, side, up, out, elbow):
    """Upper arm `up` forward (rad, from hanging), `out` away from the body, forearm bent `elbow` up."""
    sx = 1.0 if side == "L_" else -1.0
    p.turn(side + "Upperarm", x=-up, y=-sx * out)
    p.turn(side + "Forearm", x=-elbow)


def pose_at(t):
    p = Pose()
    snap = clamp01((t - SNAP_AT) / 0.2)
    turned = whip(snap) if t >= SNAP_AT else 0.0
    startle = ease_out(t / 0.22)
    dread = smooth(t / SNAP_AT)
    reach = smooth((t - (SNAP_AT - 0.45)) / 0.35) * (1.0 - smooth((t - SNAP_AT) / 0.12))
    limp = smooth((t - SNAP_AT - 0.05) / 0.3)
    alive = 1.0 - limp
    held = 1.0 - smooth((t - RELEASE) / 0.08)              # still hanging from its hands
    kneel = clamp01((t - RELEASE) / DROP_T) ** 2           # free fall onto the knees
    th = theta_at(t)
    fall = th / THETA_MAX
    p.limp = limp
    p.free = 1.0 - held

    # ---- arms: flung up at the start, held trembling before the chest, reaching up to the hands on its
    # head, jolted out by the crack, then dead weight (the springs swing them from here)
    for s, ph in (("L_", 0.0), ("R_", 1.7)):
        sx = 1.0 if s == "L_" else -1.0
        tr = (math.sin(t * 41.0 + ph) + 0.5 * math.sin(t * 67.0 + ph)) * 0.05 * dread * alive
        jerk = bump(t, SNAP_AT + 0.05, 0.05)
        up = (0.75 * startle + 0.75 * reach) * alive + 0.3 * jerk
        out = (0.3 * startle - 0.25 * reach) * alive + 0.45 * jerk + 0.12 * limp
        elbow = (1.55 * startle + 0.55 * reach) * alive + 0.2 * limp
        arms(p, s, up, out, elbow)
        p.post[s + "Forearm"] = e(x=-tr * 0.7, y=tr * 0.4)
        p.turn(s + "Hand", x=0.35 * limp)
        p.turn(s + "Clavicle", y=-sx * (0.12 * startle + 0.1 * reach) * alive)

    # ---- trunk: a start back from it, breathing hard; at the crack yanked round with the head and swinging
    # on it while it holds them up; slack
    breath = math.sin(t * 2.0 * math.pi * (0.9 + 0.8 * dread)) * 0.03 * alive
    p.turn("Spine01", x=-0.04 * startle * alive + 0.08 * limp)
    p.turn("Spine02", x=breath - 0.06 * startle * alive + 0.1 * limp, z=0.18 * turned * held)
    p.post["Spine02"] = e(x=0.008 * math.sin(t * 29.0) * dread * alive)

    # ---- the head: half turning to look behind (it can't), pulled back as the grip closes, then wrenched
    # round to face it, tipped over; once it lets go it drops forward, and face down the neck bends back so
    # the head lies on its side on the floor, not through it
    peek = 0.35 * smooth((t - 0.6) / 0.5) * (1.0 - smooth((t - 1.7) / 0.4))
    pulled = 0.18 * reach
    yaw = TWIST * turned + peek
    roll = 0.45 * turned + 0.08 * limp
    let_go = 1.0 - held
    p.turn("NeckTwist01", x=-pulled * 0.5 + 0.15 * let_go * (1.0 - fall) - 0.35 * fall, z=yaw * 0.4)
    p.turn("NeckTwist02", x=-pulled * 0.5 + 0.1 * let_go * (1.0 - fall) - 0.35 * fall, z=yaw * 0.3)
    p.turn("Head", x=0.25 * limp - 0.35 * fall, y=roll, z=yaw * 0.3)

    # ---- the hips. Standing: down a little in fright; at the crack the knees go and it hangs from the hands
    # on its head, the body twisting back and forth under it after the wrench (the IK keeps the feet put).
    # Let go: straight down onto the knees (they hit: a jolt), then over them, rolling onto its left side.
    stand_drop = 0.014 * startle + 0.01 * dread + (HANG_DROP - 0.024) * limp
    stand_drop += ring(t, SNAP_AT + 0.05, 0.012, 1.6, 3.0) * held
    stand_hip = HIP0 + Vector((0.0, 0.0, -stand_drop))
    p.hip = stand_hip.lerp(_kneel_hip(th, fall), kneel)
    p.hip.x = HIP0.x
    p.hip.z += ring(t, KNEES_AT, -0.008, 3.2, 7.0)
    twist = ring(t, SNAP_AT + 0.03, 0.2, 0.85, 1.4) * held
    sway = ring(t, SNAP_AT + 0.1, 0.05, 0.6, 1.1) * held
    p.turn("Hip", x=sway + th, z=twist)
    p.turn("Hip", y=0.32 * fall * fall)
    slump = 0.3 + 0.12 * math.sin(math.pi * clamp01((t - KNEES_AT) / 0.25))   # the knees hit: it folds on
    p.turn("Waist", x=slump * kneel * (1.0 - fall))
    p.turn("Spine01", x=0.15 * kneel * (1.0 - fall))
    p.turn("Spine02", x=-0.22 * fall)                  # face down, the chest (and the hoses on it) rides up

    # ---- the feet: planted where they stood; kneeling, laid on their tops behind the knees; lying, the toes
    # roll in
    for s in ("L_", "R_"):
        sx = 1.0 if s == "L_" else -1.0
        a0 = BASE[s + "Foot"][1].translation
        lie = Vector((a0.x, KNEE_Y + SHIN * 0.98, ANKLE_PAD))
        ankle = a0.lerp(lie, kneel) + Vector((0.0, 0.0, 0.07 * math.sin(math.pi * kneel)))   # over, not through, the floor
        pole = Vector((0.0, -1.0, -1.4 * kneel)).normalized()
        p.feet[s] = (ankle, e(x=2.5 * kneel, z=sx * 0.35 * fall), pole)
    return p


# =============================================================== the springs
# Everything above the waist that can swing is a damped spring chasing the posed rotation, in armature space.
# Each is a weight on its joint: shoved by the joint's acceleration (the body jolts, drops, hits the floor:
# the head nods, the arms swing on) and pulled down by gravity. Alive, the muscles hold the pose (stiff
# springs, gravity barely shows); dead, the arms have no tone at all: they hang, swing and fall as dead weight,
# and the floor stops them (they lie where they land, friction holding them). Each carries its sprung parent,
# so the motion runs down the chain (overlapping action).
# bone: (Hz alive, Hz dead, damping alive, dead, ~1.5 / length: how hard a jolt or gravity swings it,
#        gravity: 1 always, "free" only once it lets go of the head, floor: the limb's length and thickness)
SPRINGS = {
    "Spine02": (5.0, 3.0, 0.8, 0.5, 2.0, 0.0, None),
    "L_Clavicle": (6.0, 3.5, 0.75, 0.45, 2.0, 0.0, None), "R_Clavicle": (6.0, 3.5, 0.75, 0.45, 2.0, 0.0, None),
    "NeckTwist01": (6.5, 3.0, 0.7, 0.4, 6.0, "free", None),
    "NeckTwist02": (6.5, 3.0, 0.7, 0.4, 6.0, "free", None),
    "Head": (6.5, 2.6, 0.65, 0.35, 10.0, "free", None),
    "L_Upperarm": (4.5, 0.45, 0.6, 0.35, 5.0, 1.0, ("L_Forearm", 0.04)),
    "R_Upperarm": (4.5, 0.45, 0.6, 0.35, 5.0, 1.0, ("R_Forearm", 0.04)),
    "L_Forearm": (5.0, 1.1, 0.55, 0.45, 6.0, 1.0, ("L_Hand", 0.034)),
    "R_Forearm": (5.0, 1.1, 0.55, 0.45, 6.0, 1.0, ("R_Hand", 0.034)),
    "L_Hand": (7.0, 1.6, 0.5, 0.45, 12.0, 1.0, (0.07, 0.04)),
    "R_Hand": (7.0, 1.6, 0.5, 0.45, 12.0, 1.0, (0.07, 0.04)),
}
DOWN = Vector((0.0, 0.0, -1.0))
FRICTION = 0.6             # of the swing a limb keeps each substep it lies on the floor
SUBSTEPS = 12
JOLT_MAX = 14.0            # model units / s^2: one frame's impact can't throw a limb about more than this


def rotvec(q):
    if q.w < 0.0:
        q = -q
    axis, ang = q.to_axis_angle()
    return axis * ang


def world_deltas(p, sim=None):
    """Each bone's armature-space delta from its idle, carried down the chain: `p`'s own, with the sprung
    bones taken from `sim` (bone -> quaternion) where it has them"""
    D = {}
    for b in BONES:
        nm = b.name
        par = PARENT[nm]
        dq = (D[par] if par else Quaternion()) @ p.d.get(nm, Quaternion())
        if sim is not None and nm in sim:
            dq = sim[nm]
        D[nm] = dq @ p.post[nm] if nm in p.post else dq
    return D


def goals_of(D):
    return {nm: D[nm].to_matrix() @ BASE_ROT[nm] for nm in D if nm != "BoneRoot" and nm not in LEG_BONES}


def leg_ik(p):
    def legs(M):
        out = {}
        for leg in LEGS:
            ankle, fq, pole = p.feet[leg.side]
            th_, ca = leg.solve(leg.hip_joint(M), ankle, pole)
            out[leg.side + "Thigh"] = th_
            out[leg.side + "Calf"] = ca
            out[leg.side + "Foot"] = fq.to_matrix() @ BASE_ROT[leg.side + "Foot"]
            out[leg.side + "ToeBase"] = fq.to_matrix() @ BASE_ROT[leg.side + "ToeBase"]
        return out
    return legs


def _below(name):
    out = []
    for b in BONES:
        q = b
        while q.parent and q.parent.name != name:
            q = q.parent
        if q.parent:
            out.append(b.name)
    return out


# the legs come from the IK; the twist and share bones under them keep their idle pose on top of it
LEG_BONES = set(_below("L_Thigh") + _below("R_Thigh") + ["L_Thigh", "R_Thigh"])


def build():
    new_action(CLIP)
    local = {k: v[0] for k, v in BASE.items()}
    n = int(round(LENGTH * FPS))
    poses = [pose_at(i / FPS) for i in range(n + 1)]
    # 1. where each sprung joint is in the posed (unsprung) motion: their accelerations are the jolts
    joints = []
    for p in poses:
        _, M = solve(goals_of(world_deltas(p)), local, p.hip, leg_ik(p))
        joints.append({nm: (M[nm].translation.copy(), M[nm].col[1].xyz.normalized()) for nm in SPRINGS})
    # 2. the springs, frame by frame
    order = [b.name for b in BONES if b.name in SPRINGS]
    reach = {}                                        # how far each limb reaches from its joint
    for nm in order:
        fl = SPRINGS[nm][6]
        if fl is not None:
            reach[nm] = (REST[fl[0]].translation - REST[nm].translation).length if isinstance(fl[0], str) else fl[0]
    state = {}
    sims = []
    h = 1.0 / (FPS * SUBSTEPS)
    for i, p in enumerate(poses):
        sim = {}
        heads = {}
        for nm in order:
            a = Vector()
            if 0 < i < n:
                a = (joints[i + 1][nm][0] - 2.0 * joints[i][nm][0] + joints[i - 1][nm][0]) * (FPS * FPS)
                if a.length > JOLT_MAX:
                    a = a.normalized() * JOLT_MAX
            f0, f1, z0, z1, swing, grav, floor = SPRINGS[nm]
            g = p.free if grav == "free" else float(grav)
            # where its joint is: down the sprung chain as it really hangs, else as posed
            par = PARENT[nm]
            if par in sim:
                heads[nm] = heads[par] + (sim[par].to_matrix() @ BASE_ROT[par]) @ REL[nm].translation
            else:
                heads[nm] = joints[i][nm][0]
            # its goal: its own posed turn, carried by its parent as the parent really is (sprung or not)
            D = world_deltas(p, sim)
            target = D[par] @ p.d.get(nm, Quaternion())
            w0 = 2.0 * math.pi * lerp(f0, f1, p.limp)
            zeta = lerp(z0, z1, p.limp)
            if nm not in state:
                state[nm] = [target.copy(), Vector()]
            q, w = state[nm]
            for _ in range(SUBSTEPS):
                d = (q.to_matrix() @ BASE_ROT[nm]).col[1].normalized()
                push = d.cross(-a) + d.cross(DOWN) * (G * g)
                err = rotvec(target @ q.inverted())
                acc = err * (w0 * w0) - w * (2.0 * zeta * w0) + push * swing
                w = w + acc * h
                if w.length > 1e-9:
                    q = Quaternion(w.normalized(), w.length * h) @ q
                q.normalize()
                # the floor: a limb that reaches into it is stopped on it, and drags
                if floor is not None:
                    d = (q.to_matrix() @ BASE_ROT[nm]).col[1].normalized()
                    tip = heads[nm] + d * reach[nm]
                    lowest = floor[1]
                    if tip.z < lowest:
                        to = Vector((tip.x, tip.y, lowest)) - heads[nm]
                        if to.length > 1e-6:
                            q = d.rotation_difference(to.normalized()) @ q
                            q.normalize()
                        w = w * FRICTION
            state[nm] = [q, w]
            sim[nm] = q.copy()
        sims.append(sim)
    # 3. the frames
    prev = {}
    for i, p in enumerate(poses):
        basis, _ = solve(goals_of(world_deltas(p, sims[i])), local, p.hip, leg_ik(p))
        key_pose(basis, i, prev)
    for fc in fcurves(bpy.data.actions[CLIP]):
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    print("%s: %d frames; knees hit %.2f s, face down %.2f s" % (CLIP, n + 1, KNEES_AT, FLAT_AT))


build()


# =============================================================== export: every clip, one NLA track each
def export():
    ad.action = None
    for pb in arm.pose.bones:
        pb.matrix_basis = Matrix()
    for t in list(ad.nla_tracks):
        ad.nla_tracks.remove(t)
    for name in sorted(a.name for a in bpy.data.actions):
        act = bpy.data.actions[name]
        bind(act)
        slot = getattr(ad, "action_slot", None)
        ad.action = None
        track = ad.nla_tracks.new()
        track.name = name
        strip = track.strips.new(name, frames(act)[0], act)
        if slot is not None and hasattr(strip, "action_slot"):
            strip.action_slot = slot
    for o in bpy.data.objects:
        o.select_set(o in (arm, body))
    bpy.context.view_layer.objects.active = arm
    bpy.ops.export_scene.gltf(
        filepath=OUT_GLB, export_format="GLB", use_selection=True,
        export_animations=True, export_animation_mode="NLA_TRACKS", export_force_sampling=True,
        export_frame_step=1, export_anim_slide_to_zero=True, export_skins=True, export_all_influences=False,
        export_yup=True, export_apply=False)
    print("wrote", OUT_GLB, "clips", sorted(a.name for a in bpy.data.actions))


if not BUILD_ONLY and OUT_GLB:
    export()
else:                                                 # live Blender: show the new clip
    bind(bpy.data.actions[CLIP])
    scene.frame_start, scene.frame_end = 0, int(round(LENGTH * FPS))
    arm.update_tag(refresh={"OBJECT", "DATA", "TIME"})
    bpy.context.view_layer.update()
