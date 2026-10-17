"""Add idle variants to the survivor suit (models/player/survivor.glb), so the people standing in the lobby
corridor (lobby_corridor.gd) don't all breathe the same breath in step, or stand the same way.

    blender --background --python tools/blender/add_survivor_lobby_idles.py -- <in.glb> <out.glb>
    e.g. ... -- godot-backrooms/models/player/survivor.glb godot-backrooms/models/player/survivor.glb

Run it after build_player_hazmat.py and add_survivor_directions.py (it starts from idle_still, so the breathing is
the suit's own). Every clip already in the file is kept. Each new clip is two loops long (11.75 s, so what
happens in it doesn't come round every few seconds), the feet stay planted exactly where idle_still has them
(IK, as add_survivor_directions.py), and the last frame is the first:

    lobby_idle_shift    weight rolling from one leg to the other, the pelvis, chest and head riding it; a slow look round
    lobby_idle_hips     hands on the hips, the head scanning the room, the weight settling
    lobby_idle_hood     a hand comes up to settle the hood, pats it, drops
    lobby_idle_slump    tired: the head and chest sag over the loop, one long sigh, then it pulls itself up
    lobby_idle_glance   jumpy: the head flicks to a sound and the shoulders start with it
    lobby_idle_crossed  arms folded, shifting now and then
    lobby_idle_wrist    looks at something on its left forearm, and back up
    lobby_idle_lookup   head back, watching the tubes overhead
    lobby_idle_straps   thumbs in the vest straps

How it looks real: nothing is a bare sine. Poses are held and eased between (keyed), the head leads and the chest
follows a beat later, weight moves through the pelvis (hip over the support leg, the other knee relaxed, the
chest leaning back over it), and a faint always-on drift in the head and chest keeps a held pose alive.
Arms are posed by aiming each bone at a direction (aim), not by guessed angles.

Axes in the armature (the suit faces -Y here, +Z once exported): +X is its left, +Z up. Rotating +a about X
tips something upright forward; about Z turns it to its left; about Y tips its top to its left.
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

LOOPS = 2                  # idle_still's breath, this many times over: one clip
FPS_OUT = 24

# =============================================================== load (clearing the scene, keeping prefs)
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
for coll in (bpy.data.actions, bpy.data.meshes, bpy.data.armatures, bpy.data.materials, bpy.data.images):
    for d in list(coll):
        coll.remove(d)
scene = bpy.context.scene
scene.render.fps = FPS_OUT
bpy.ops.import_scene.gltf(filepath=IN_GLB)
for o in [o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("Icosphere")]:
    bpy.data.objects.remove(o, do_unlink=True)            # the importer's bone-shape sphere
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
body = next(o for o in bpy.data.objects if o.type == "MESH")
ad = arm.animation_data_create()
for t in list(ad.nla_tracks):
    ad.nla_tracks.remove(t)
SOURCE = {a.name: a for a in bpy.data.actions}
for a in list(SOURCE):
    if a.startswith("lobby_idle"):                        # a rerun replaces its own clips
        bpy.data.actions.remove(SOURCE.pop(a))
print("clips in", IN_GLB, sorted(SOURCE))


def bind(act):
    ad.action = act
    if getattr(ad, "action_slot", None) is None and getattr(act, "slots", None):
        ad.action_slot = act.slots[0]


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
FIRST_THIGH = next(b.name for b in BONES if b.name.endswith("_Thigh"))


def sample(act, frame):
    """bone -> (local basis, armature-space matrix) at `frame`"""
    bind(act)
    scene.frame_set(int(math.floor(frame)), subframe=frame - math.floor(frame))
    return {pb.name: (pb.matrix_basis.copy(), pb.matrix.copy()) for pb in arm.pose.bones}


def solve(goals, local, hip_pos=None, legs=None):
    """goals: bone -> armature-space 3x3 rotation; every other bone keeps its `local` basis. legs(M) is called
    once the pelvis is placed and returns more goals (the IK). Returns (bases, armature matrices)."""
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


def subtree(name):
    out = [name]
    for b in BONES:
        if PARENT[b.name] == name:
            out += subtree(b.name)
    return out


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


def leg_goals(M, feet):
    """feet: side -> (ankle position, foot rotation, toe rotation, knee pole direction)."""
    out = {}
    for leg in LEGS:
        A, rfoot, rtoe, pole = feet[leg.side]
        t, c = leg.solve(leg.hip_joint(M), A, pole)
        out[leg.side + "Thigh"] = t
        out[leg.side + "Calf"] = c
        out[leg.side + "Foot"] = rfoot
        out[leg.side + "ToeBase"] = rtoe
    return out


# =============================================================== motion vocabulary
def R(axis, deg):
    return Matrix.Rotation(math.radians(deg), 3, axis)


X, Y, Z = "X", "Y", "Z"


def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def bump(t, a, b, c, d):
    """0 -> 1 over a..b, held to c, back to 0 by d (seconds)"""
    return smoothstep(a, b, t) * (1.0 - smoothstep(c, d, t))


def keyed(t, keys):
    """held poses eased between: (seconds, value) keys, the first value = the last so it loops"""
    for (ta, va), (tb, vb) in zip(keys, keys[1:]):
        if t <= tb:
            return va + (vb - va) * smoothstep(ta, tb, t)
    return keys[-1][1]


def aim(bone, direction, w=1.0):
    """op: swing `bone` (and all under it) from where it points to `direction` (armature space), by `w`"""
    return (bone, Vector(direction).normalized(), w)


def alive(t, T):
    """A faint, never-repeating drift (whole cycles per clip, so it loops): nobody holds a pose dead still"""
    u = t / T
    p = 2 * math.pi * u
    return [
        ("Head", R(Z, 0.9 * math.sin(p * 5 + 0.3) + 0.5 * math.sin(p * 9 + 2.0)) @ R(X, 0.7 * math.sin(p * 7 + 1.1))
         @ R(Y, 0.6 * math.sin(p * 4 + 2.2))),
        ("Spine02", R(Z, 0.5 * math.sin(p * 3 + 0.7)) @ R(Y, 0.5 * math.sin(p * 6 + 1.9))),
        ("L_Upperarm", R(X, 0.8 * math.sin(p * 5 + 0.4))),
        ("R_Upperarm", R(X, 0.8 * math.sin(p * 5 + 2.6))),
    ]


def stance(s, amount=1.0, free_arms=True):
    """The weight on the suit's left leg for s > 0, its right for s < 0 (-1..1): the pelvis over the support
    foot with that hip up, the other knee soft, the chest leaning back over the support hip and the head
    level on top. Returns (hip offset, pelvis rotation, ops)."""
    a = amount
    hip = Vector((0.026 * a * s, 0.0, -0.005 * a * (1.0 - s * s) - 0.003 * a * abs(s)))
    pelvis = R(Y, -4.5 * a * s) @ R(Z, 3.0 * a * s)
    ops = [
        ("Waist", R(Y, 3.2 * a * s) @ R(Z, -2.0 * a * s)),
        ("Spine01", R(Y, 1.4 * a * s)),
        ("Spine02", R(Y, 1.0 * a * s)),
        ("Head", R(Y, -1.0 * a * s)),
    ]
    if free_arms:                         # the arm on the free side hangs a touch looser
        ops += [("L_Upperarm", R(Y, -2.2 * a * max(-s, 0.0))), ("R_Upperarm", R(Y, 2.2 * a * max(s, 0.0)))]
    return hip, pelvis, ops


def look(yaw, pitch=0.0, share=(0.25, 0.3, 0.45)):
    """A look of `yaw` degrees (+ = to its left) and `pitch` (+ = down), shared up the spine (chest, neck, head)"""
    return [
        ("Spine02", R(Z, yaw * share[0]) @ R(X, pitch * 0.15)),
        ("NeckTwist01", R(Z, yaw * share[1]) @ R(X, pitch * 0.35)),
        ("Head", R(Z, yaw * share[2]) @ R(X, pitch * 0.5)),
    ]


# ---- the clips: each is f(t) -> (hip offset, pelvis rotation, ops), t in seconds over the clip
def clip_shift(t, T):
    s = keyed(t, [(0, -1), (1.4, -1), (3.2, 1), (6.9, 1), (8.6, -1), (T, -1)])
    yaw = keyed(t, [(0, 0), (3.6, 0), (4.6, 20), (6.2, 20), (7.4, -8), (8.6, 0), (T, 0)])
    hip, pel, ops = stance(s)
    return hip, pel, ops + look(yaw, 2.0 * bump(t, 4.4, 5.0, 6.0, 6.8))


def clip_hips(t, T):
    s = keyed(t, [(0, 0.5), (3.0, 0.5), (4.8, -0.6), (8.8, -0.6), (T, 0.5)])
    yaw = keyed(t, [(0, 0), (1.6, 0), (2.8, 30), (4.4, 30), (5.8, -32), (7.2, -32), (8.8, 0), (T, 0)])
    sigh = bump(t, 6.8, 7.6, 7.9, 9.2)
    hip, pel, ops = stance(s, 0.8, free_arms=False)
    ops += look(yaw, 1.5)
    ops += [("Spine02", R(X, -2.5 * sigh)), ("L_Clavicle", R(Z, 2.0 * sigh)), ("R_Clavicle", R(Z, -2.0 * sigh)),
            aim("L_Upperarm", (0.74, 0.08, -0.67)), aim("R_Upperarm", (-0.74, 0.08, -0.67)),
            aim("L_Forearm", (-0.55, 0.45, -0.70)), aim("R_Forearm", (0.55, 0.45, -0.70))]
    return hip, pel, ops


def clip_hood(t, T):
    s = keyed(t, [(0, 0.3), (2.0, 0.3), (4.0, 0.7), (8.5, -0.4), (T, 0.3)])
    up = bump(t, 1.6, 2.9, 6.2, 7.6)
    pat = bump(t, 3.2, 3.5, 5.2, 5.6) * 0.5 * (1.0 + math.sin(2 * math.pi * 1.7 * (t - 3.2)))
    glance = bump(t, 2.2, 2.9, 3.0, 3.8) * 6.0
    hip, pel, ops = stance(s, 0.7)
    ops += [aim("R_Upperarm", (-0.34, -0.55, -0.45 - 0.1 * pat), up),
            aim("R_Forearm", (0.50, -0.30, 0.80), up),
            ("R_Hand", R(Z, 18 * up) @ R(X, -6 * pat * up)),
            ("R_Clavicle", R(Z, -5 * up)),
            ("Head", R(Y, -7 * up) @ R(Z, 5 * up) @ R(X, glance - 3 * pat * up))]
    return hip, pel, ops


def clip_slump(t, T):
    d = keyed(t, [(0, 0.55), (4.8, 1.0), (7.4, 1.0), (8.6, 0.05), (10.4, 0.05), (T, 0.55)])
    s = keyed(t, [(0, 0.7), (4.0, 0.9), (6.0, 0.3), (8.4, -0.6), (T, 0.7)])
    sigh = bump(t, 5.6, 6.4, 6.6, 7.8)
    hip, pel, ops = stance(s, 0.6)
    ops += [("Waist", R(X, 2.5 * d)), ("Spine01", R(X, 5.0 * d + 1.0 * sigh)), ("Spine02", R(X, 6.0 * d + 2.0 * sigh)),
            ("NeckTwist01", R(X, 7.0 * d)), ("Head", R(X, 9.0 * d + 4.0 * sigh) @ R(Z, 4.0 * math.sin(math.pi * 2 * t / T))),
            ("L_Clavicle", R(Z, 4.5 * d + 2.0 * sigh)), ("R_Clavicle", R(Z, -4.5 * d - 2.0 * sigh)),
            ("L_Upperarm", R(X, -8 * d)), ("R_Upperarm", R(X, -9 * d)),
            ("L_Forearm", R(X, -5 * d)), ("R_Forearm", R(X, -4 * d))]
    return hip, pel, ops


def clip_glance(t, T):
    keys = [(0, 0), (0.9, 0), (1.15, 40), (2.3, 40), (2.6, -6), (3.4, -6), (3.65, -48), (5.0, -48), (5.5, 0),
            (7.3, 0), (7.5, 20), (8.1, 20), (8.4, -12), (9.4, -12), (9.8, 0), (T, 0)]
    yaw = keyed(t, keys)
    lagged = keyed((t - 0.28) % T, keys)                           # the chest follows the head a beat later
    start = min(1.0, abs(yaw - keyed((t - 0.16) % T, keys)) / 22.0)
    s = keyed(t, [(0, 0.2), (3.0, 0.2), (3.7, -0.5), (7.5, -0.5), (8.3, 0.2), (T, 0.2)])
    hip, pel, ops = stance(s, 0.7)
    ops += [("Spine02", R(Z, lagged * 0.3) @ R(X, 1.5 * start)), ("NeckTwist01", R(Z, yaw * 0.25)),
            ("Head", R(Z, yaw * 0.6 - lagged * 0.15) @ R(X, -3.0 - 3.0 * start) @ R(Y, -5 * math.sin(math.radians(yaw)))),
            ("L_Clavicle", R(Z, -4.0 * start - 2)), ("R_Clavicle", R(Z, 4.0 * start + 2)),
            ("L_Upperarm", R(X, -4)), ("R_Upperarm", R(X, -4)),
            ("L_Forearm", R(X, -14 - 8 * start)), ("R_Forearm", R(X, -12 - 8 * start))]
    hip.z += 0.003 * start
    return hip, pel, ops


def clip_crossed(t, T):
    s = keyed(t, [(0, -0.5), (3.5, -0.5), (5.0, 0.6), (9.0, 0.6), (10.2, -0.5), (T, -0.5)])
    yaw = keyed(t, [(0, 0), (2.2, 0), (3.2, -22), (4.4, -22), (5.4, 6), (8.0, 6), (9.0, 26), (10.0, 26), (11.0, 0), (T, 0)])
    squeeze = bump(t, 6.0, 6.5, 6.8, 7.4)
    hip, pel, ops = stance(s, 0.8, free_arms=False)
    ops += look(yaw, 2.0)
    ops += [aim("L_Upperarm", (0.20, -0.30, -0.93)), aim("R_Upperarm", (-0.20, -0.30, -0.93)),
            aim("L_Forearm", (-0.88 + 0.05 * squeeze, -0.42, 0.18)), aim("R_Forearm", (0.88 - 0.05 * squeeze, -0.55, 0.22)),
            ("L_Clavicle", R(Z, -3.0 + 2.0 * squeeze)), ("R_Clavicle", R(Z, 3.0 - 2.0 * squeeze)),
            ("Spine02", R(X, 2.0 + 1.0 * squeeze))]
    return hip, pel, ops


def clip_wrist(t, T):
    w = bump(t, 1.2, 2.5, 6.0, 7.4)
    flick = bump(t, 4.2, 4.5, 4.6, 5.0)                          # a small turn of the wrist, a second look
    s = keyed(t, [(0, 0.4), (3.0, 0.4), (4.5, -0.3), (8.0, -0.3), (9.4, 0.4), (T, 0.4)])
    hip, pel, ops = stance(s, 0.7)
    ops += [aim("L_Upperarm", (0.18, -0.22, -0.96), w),
            aim("L_Forearm", (-0.30, -0.93, 0.18 + 0.08 * flick), w),
            ("L_Hand", R(Z, 8 * w) @ R(X, -12 * w)),
            ("Spine02", R(X, 3.0 * w)), ("NeckTwist01", R(X, 8.0 * w)),
            ("Head", R(X, 16.0 * w + 3.0 * flick) @ R(Z, 7.0 * w))]
    ops += look(keyed(t, [(0, 0), (8.0, 0), (9.0, -16), (10.2, -16), (11.2, 0), (T, 0)]))
    return hip, pel, ops


def clip_lookup(t, T):
    w = keyed(t, [(0, 0), (1.4, 0), (3.0, 1), (7.4, 1), (9.0, 0.25), (10.0, 0.9), (T, 0)])
    sweep = keyed(t, [(0, 0), (3.0, -22), (5.2, 24), (7.4, -6), (9.0, 0), (T, 0)])
    s = keyed(t, [(0, 0), (4.0, 0.4), (8.0, -0.4), (T, 0)])
    hip, pel, ops = stance(s, 0.6)
    ops += [("Spine01", R(X, -2.0 * w)), ("Spine02", R(X, -4.0 * w)), ("NeckTwist01", R(X, -9.0 * w)),
            ("Head", R(X, -16.0 * w)), ("L_Clavicle", R(Z, -2 * w)), ("R_Clavicle", R(Z, 2 * w))]
    ops += look(sweep * w, 0.0)
    hip.z += 0.003 * w
    return hip, pel, ops


def clip_straps(t, T):
    s = keyed(t, [(0, 0.6), (3.2, 0.6), (4.6, -0.5), (8.4, -0.5), (T, 0.6)])
    yaw = keyed(t, [(0, 0), (2.4, 0), (3.4, 14), (5.0, 14), (6.2, -20), (8.0, -20), (9.0, 0), (T, 0)])
    tug = bump(t, 6.8, 7.0, 7.1, 7.6)                            # an absent-minded tug on the strap
    hip, pel, ops = stance(s, 0.8, free_arms=False)
    ops += look(yaw, 2.0)
    ops += [aim("L_Upperarm", (0.36, 0.0, -0.93)), aim("R_Upperarm", (-0.36, 0.0, -0.93)),
            aim("L_Forearm", (-0.42, -0.76, 0.40 - 0.1 * tug)), aim("R_Forearm", (0.42, -0.76, 0.40 - 0.1 * tug)),
            ("L_Clavicle", R(Z, -2.0)), ("R_Clavicle", R(Z, 2.0)), ("Spine02", R(X, 1.5))]
    return hip, pel, ops


VARIANTS = {
    "lobby_idle_shift": clip_shift, "lobby_idle_hips": clip_hips, "lobby_idle_hood": clip_hood,
    "lobby_idle_slump": clip_slump, "lobby_idle_glance": clip_glance, "lobby_idle_crossed": clip_crossed,
    "lobby_idle_wrist": clip_wrist, "lobby_idle_lookup": clip_lookup, "lobby_idle_straps": clip_straps,
}


def apply_ops(g, ops):
    """Turn the bones (and what hangs from them) in `g` (bone -> armature-space rotation), in order"""
    for op in ops:
        bone = op[0]
        if len(op) == 3:                                       # aim: from where it points now to the direction
            now = (g[bone] @ Vector((0, 1, 0))).normalized()
            q = now.rotation_difference(op[1])
            r = Quaternion().slerp(q, op[2]).to_matrix()
        else:
            r = op[1]
        for b in subtree(bone):
            g[b] = r @ g[b]


UPPER = subtree("Waist")


def build(name, fn, src="idle_still"):
    act = SOURCE[src]
    f0, f1 = frames(act)
    n_src = f1 - f0
    N = n_src * LOOPS
    T = N / FPS_OUT
    S = [sample(act, f0 + i) for i in range(n_src + 1)]       # sampling binds the source: all first
    # the feet stay where idle_still has them (the first frame)
    feet = {}
    for leg in LEGS:
        s0 = S[0]
        pole = s0[leg.side + "Calf"][1].translation - s0[leg.side + "Thigh"][1].translation
        feet[leg.side] = (s0[leg.side + "Foot"][1].translation.copy(), rot3(s0[leg.side + "Foot"][1]),
                          rot3(s0[leg.side + "ToeBase"][1]), pole)
    new_action(name)
    prev = {}
    for i in range(N + 1):
        s = S[i % n_src]
        t = (i % N) / FPS_OUT                                  # the last frame is the first again: it loops
        local = {k: v[0] for k, v in s.items()}
        g = {b: rot3(s[b][1]) for b in UPPER}
        hip_off, pelvis, ops = fn(t, T)
        apply_ops(g, ops + alive(t, T))
        goals = dict(g)
        goals["Hip"] = pelvis @ rot3(s["Hip"][1])
        hp = s["Hip"][1].translation + hip_off
        for _ in range(3):                                     # lower the hips as far as the legs need to reach
            _, M = solve(goals, local, hp)
            need = 0.0
            for leg in LEGS:
                d = feet[leg.side][0] - leg.hip_joint(M)
                lim = (leg.l1 + leg.l2) * 0.975
                flat = Vector((d.x, d.y)).length
                if d.length > lim:
                    need = max(need, -d.z - math.sqrt(max(lim * lim - flat * flat, 0.0)))
            if need <= 1e-5:
                break
            hp = hp.copy()
            hp.z -= need
        basis, _ = solve(goals, local, hp, lambda M: leg_goals(M, feet))
        key_pose(basis, f0 + i, prev)
    return name


made = [build(n, f) for n, f in VARIANTS.items()]


def fcurves(act):
    try:
        return list(act.fcurves)
    except AttributeError:
        return [fc for layer in act.layers for st in layer.strips for cb in st.channelbags for fc in cb.fcurves]


for name in made:                                         # linear keys: the clips are sampled every frame already
    for fc in fcurves(bpy.data.actions[name]):
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"


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
else:                                                     # live Blender: rebuild the rig's relations so it plays
    arm.update_tag(refresh={"OBJECT", "DATA", "TIME"})
    bpy.context.view_layer.update()
    print("built", made)
