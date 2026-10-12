"""Add directional locomotion to the survivor suit (models/player/survivor.glb), so a body moving backwards
or sideways plays a clip that goes that way instead of the forward walk / run.

    blender --background --python tools/blender/add_survivor_directions.py -- <in.glb> <out.glb>
    e.g. ... -- godot-backrooms/models/player/survivor.glb godot-backrooms/models/player/survivor.glb

Run it after tools/blender/build_player_hazmat.py (which writes the forward clips). It keeps every clip in
the file as it is and adds, all looping cleanly (last frame = first):

    walk_back         the walk played backwards: toe strikes first, heel rolls down. Chest a touch upright.
    run_back          a backpedal: the run reversed, with its forward lean taken out of the chest (a runner
                      leans into the way he goes; going backwards that reads as falling over)
    crouch_walk_back  the crouch walk reversed
    strafe_l/_r       a side-step: the lead foot steps out wide, the other closes in behind it, never crossing.
                      Four quick steps per walk loop (same length as walk, so a blend space keeps them in step)
    run_strafe_l/_r   a side shuffle (chasse): lead foot, the other skips in to meet it, a short hop.
                      Three per run loop (same length as run)
    crouch_strafe_l/_r  the side-step low, two per crouch-walk loop
    idle_still        idle_lookaround with its scripted head scan taken out (the game turns the head itself)

Strafes keep the forward clip's upper body at the same time (so the breathing and the hands match), with
the arm swing and chest twist mostly damped out, and rebuild the legs with IK. Left is the suit's own left
(+X here, facing -Y; the file faces +Z once exported).

The native speeds printed at the end (m/s with the suit fitted 2 m tall) are what survivor_anim.gd uses.
Inside a live Blender (the MCP), exec the file with BUILD_ONLY = True set to build without exporting.
"""
import sys
import math

import bpy
from mathutils import Vector, Matrix, Quaternion

GAME_HEIGHT = 2.0          # m: what the game fits the suit to (MODEL_HEIGHT in the scripts)
TOE_OUT = math.radians(8)

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
IN_GLB = globals().get("IN_GLB") or (args[0] if args else None)
OUT_GLB = globals().get("OUT_GLB") or (args[1] if len(args) > 1 else None)
BUILD_ONLY = globals().get("BUILD_ONLY", False)

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
for t in list(ad.nla_tracks):                            # sample one clip at a time, nothing stacked
    ad.nla_tracks.remove(t)
SOURCE = {a.name: a for a in bpy.data.actions}
print("clips in", IN_GLB, sorted(SOURCE))


def bind(act):
    ad.action = act
    if getattr(ad, "action_slot", None) is None and getattr(act, "slots", None):
        ad.action_slot = act.slots[0]


# =============================================================== the rig
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
    """goals: bone -> armature-space 3x3 rotation; every other bone keeps its `local` basis (rest if
    absent). legs(M) is called once the pelvis is placed and returns more goals (the IK). Returns bases."""
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


def mean_quat(qs):
    acc = Quaternion((0, 0, 0, 0))
    ref = qs[0]
    for q in qs:
        acc = acc + (q if ref.dot(q) >= 0 else -q)
    return acc.normalized()


def facing(r, bone):
    """Yaw (radians, + = to its left) of where `bone` faces with armature-space rotation r: its rest
    forward (-Y) carried round."""
    f = r @ rot3(REST[bone]).inverted() @ Vector((0, -1, 0))
    return math.atan2(f.x, -f.y)


def lean_of(samples):
    """Mean forward lean (degrees) of the chest: waist -> neck, in armature space (forward is -Y)."""
    out = []
    for s in samples:
        d = s["NeckTwist01"][1].translation - s["Waist"][1].translation
        out.append(math.degrees(math.atan2(-d.y, d.z)))
    return sum(out) / len(out)


# =============================================================== leg IK (as build_player_hazmat.py)
def frame_of(u, n):
    u = u.normalized()
    n = (n - u * n.dot(u)).normalized()
    return Matrix((u, n, u.cross(n))).transposed()


class Leg:
    def __init__(self, side):
        self.side = side
        self.sx = 1 if side == "L_" else -1
        self.H0 = REST[side + "Thigh"].translation.copy()
        self.K0 = REST[side + "Calf"].translation.copy()
        self.A0 = REST[side + "Foot"].translation.copy()
        self.T0 = REST[side + "ToeBase"].translation.copy()
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


def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


# =============================================================== measuring
def foot_track(act):
    f0, f1 = frames(act)
    out = []
    for f in range(f0, f1 + 1):
        s = sample(act, f)
        out.append((s["L_Foot"][1].translation.copy(), s["R_Foot"][1].translation.copy()))
    return out


def planted_speed(track, axis):
    """Native ground speed (m/s in game) along `axis` (0 x, 1 y): how fast a foot on the floor slides
    under the body. Positive = the body moves towards -axis... reported as a magnitude."""
    vs = []
    for side in (0, 1):
        floor = min(p[side].z for p in track)
        for i in range(len(track) - 1):
            if track[i][side].z < floor + 0.008 and track[i + 1][side].z < floor + 0.008:
                vs.append(abs(track[i + 1][side][axis] - track[i][side][axis]) * FPS)
    vs.sort()
    return (vs[len(vs) // 2] if vs else 0.0) * GAME_HEIGHT


# =============================================================== backwards: a clip reversed
def backward(src_name, name, lean_change=0.0, stride=1.0, lift=1.0, flatten=0.0):
    """`src_name` played in reverse, its chest leaned back by `lean_change` degrees about the waist, the head
    keeping the source's aim (eyes level, not tipped back with the chest). stride / lift < 1 shorten the steps
    and keep the feet lower (a backpedal doesn't kick up behind like a run), re-solving the legs with IK;
    flatten (0..1) turns the feet towards flat."""
    src = SOURCE[src_name]
    f0, f1 = frames(src)
    n = f1 - f0
    S = [sample(src, f1 - i) for i in range(n + 1)]                  # sampling binds the source: all first
    reshape = stride != 1.0 or lift != 1.0 or flatten
    centre = {}
    for leg in LEGS:
        ys = [s[leg.side + "Foot"][1].translation.y for s in S[:-1]]
        centre[leg.side] = sum(ys) / len(ys)
    floor = min(s[leg.side + "Foot"][1].translation.z for s in S for leg in LEGS)
    new_action(name)
    prev = {}
    lean = Matrix.Rotation(math.radians(-lean_change), 3, "X")       # +X tips forward; back is negative
    for i in range(n + 1):
        s = S[i]
        local = {k: v[0] for k, v in s.items()}
        goals = {}
        if lean_change:
            goals["Waist"] = lean @ rot3(s["Waist"][1])
            goals["Head"] = rot3(s["Head"][1])
        legs = None
        if reshape:
            feet = {}
            for leg in LEGS:
                A = s[leg.side + "Foot"][1].translation.copy()
                A.y = centre[leg.side] + (A.y - centre[leg.side]) * stride
                A.z = floor + (A.z - floor) * lift
                flat = rot3(REST[leg.side + "Foot"]).to_quaternion()
                rf = rot3(s[leg.side + "Foot"][1]).to_quaternion()
                rt = rot3(s[leg.side + "ToeBase"][1]).to_quaternion()
                dq = rf.slerp(flat, flatten) @ rf.inverted()                 # same turn for the toes
                pole = s[leg.side + "Calf"][1].translation - s[leg.side + "Thigh"][1].translation
                feet[leg.side] = (A, rf.slerp(flat, flatten).to_matrix(), (dq @ rt).to_matrix(), pole)
            legs = lambda M, feet=feet: leg_goals(M, feet)
        basis, _ = solve(goals, local, None, legs)
        key_pose(basis, f0 + i, prev)
    return name


# =============================================================== sideways: a side-step with IK legs
def strafe(src_name, name, side, cycles, duty, w, r, lift, bob, lean_change=0.0, arm_damp=0.75,
           gallop=False, overlap=0.04, drop=0.0, roll=3.0):
    """side +1 = to the suit's left (+X), -1 = right. One loop of `src_name` holds `cycles` side-steps.
    Each foot keeps to its own lane (centre +-w) and slides +-r in it: the lead foot lands wide, the other
    closes to 2(w - r) of it. gallop: the trailing foot follows the lead one at once (offset duty - overlap)
    and both are in the air for the rest: a chasse, for running. Otherwise the feet alternate."""
    src = SOURCE[src_name]
    f0, f1 = frames(src)
    N = f1 - f0
    S = [sample(src, f0 + i) for i in range(N)]
    hip_rot = mean_quat([rot3(s["Hip"][1]).to_quaternion() for s in S]).to_matrix()
    hip_pos = sum((s["Hip"][1].translation for s in S), Vector()) / N
    head_rot = mean_quat([rot3(s["Head"][1]).to_quaternion() for s in S]).to_matrix()
    # damp the forward clip's arm swing and chest twist towards their average pose
    damp = {}
    for b, k in [("Waist", 0.8), ("Spine01", 0.8), ("Spine02", 0.8), ("NeckTwist01", 0.6), ("NeckTwist02", 0.6)]:
        damp[b] = k
    for sd in ("L_", "R_"):
        for b in (sd + "Clavicle", sd + "Upperarm", sd + "Forearm", sd + "Hand"):
            damp[b] = arm_damp
    mean_local = {b: mean_quat([S[i][b][0].to_quaternion() for i in range(N)]) for b in damp}
    lean = Matrix.Rotation(math.radians(-lean_change), 3, "X")
    tilt = Matrix.Rotation(math.radians(roll * side), 3, "Y")           # top leans into the move
    reach = 2 * r
    flight0 = (2 * duty - overlap) if gallop else 1.0                    # gallop: both feet up from here

    def foot(leg, ph):
        lead = leg.sx == side
        off = 0.0 if lead else ((duty - overlap) if gallop else 0.5)
        q = (ph - off) % 1.0
        cx = leg.sx * w
        yaw = Matrix.Rotation(TOE_OUT * leg.sx, 3, "Z")
        y = leg.A0.y + (-0.012 if lead else 0.012)                       # the lead foot a touch ahead
        if q < duty:                                                     # planted: slides against the move
            u = q / duty
            x = cx + side * r - side * reach * u
            z = leg.A0.z
            pitch = 0.0
        else:                                                            # swing, leaving / landing at stance speed
            v = (q - duty) / (1 - duty)
            m = -side * reach * (1 - duty) / duty
            p0, p1 = cx - side * r, cx + side * r
            h00, h10, h01, h11 = 2 * v ** 3 - 3 * v ** 2 + 1, v ** 3 - 2 * v ** 2 + v, -2 * v ** 3 + 3 * v ** 2, v ** 3 - v ** 2
            x = h00 * p0 + h10 * m + h01 * p1 + h11 * m
            z = leg.A0.z + lift * math.sin(math.pi * min(1.0, v ** 0.85))
            pitch = math.radians(-7) * math.sin(math.pi * v)             # toes up a little as it lifts across
        R = yaw @ Matrix.Rotation(pitch, 3, "X")
        rfoot = R @ rot3(REST[leg.side + "Foot"])
        rtoe = R @ rot3(REST[leg.side + "ToeBase"])
        knee = (yaw @ Vector((0.25 * leg.sx, -1.0, 0.0))).normalized()
        return Vector((x, y, z)), rfoot, rtoe, knee

    def hip_bob(ph):
        if gallop:                                                       # up in the hop, down on the landings
            if ph >= flight0:
                return bob * math.sin(math.pi * (ph - flight0) / (1 - flight0))
            return -0.35 * bob * math.sin(math.pi * ph / flight0)
        return -bob * math.cos(2 * math.pi * ph)                         # low with the feet wide, up as they close

    new_action(name)
    prev = {}
    for i in range(N + 1):
        ph = (i / N * cycles) % 1.0
        s = S[i % N]
        local = {k: v[0] for k, v in s.items()}
        for b, k in damp.items():
            loc, q, _ = local[b].decompose()
            local[b] = Matrix.LocRotScale(loc, q.slerp(mean_local[b], k), None)
        goals = {"Hip": tilt @ lean @ hip_rot, "Head": head_rot}
        feet = {leg.side: foot(leg, ph) for leg in LEGS}
        hp = Vector((hip_pos.x + 0.008 * side, hip_pos.y, hip_pos.z - drop + hip_bob(ph)))
        # lower the hips as far as the legs need to reach their feet with the knees still a touch bent
        for _ in range(3):
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
            hp.z -= need
        basis, _ = solve(goals, local, hp, lambda M: leg_goals(M, feet))
        key_pose(basis, f0 + i, prev)
    return name


# =============================================================== idle without the scripted look-around
def scan(t):
    """build_player_hazmat.py's look-around yaw (radians) over the whole clip, t in 0..1"""
    keys = [(0.0, 0.0), (0.08, 0.0), (0.22, 50.0), (0.40, 50.0), (0.60, -45.0), (0.78, -45.0), (0.92, 0.0), (1.0, 0.0)]
    for (ta, ya), (tb, yb) in zip(keys, keys[1:]):
        if t <= tb:
            return math.radians(ya + (yb - ya) * smoothstep(ta, tb, t))
    return 0.0


def idle_still(src_name="idle_lookaround", name="idle_still"):
    """idle_lookaround with its head / neck / chest scan taken back out: the same breathing, eyes ahead. A body
    whose look is known (Locomotion's HeadLook) turns its head where the player really looks instead.
    The build turned Spine02, then NeckTwist01, then Head (and everything under each) about Z, and tipped the
    head down at the sides; this undoes them in the reverse order."""
    src = SOURCE[src_name]
    f0, f1 = frames(src)
    total = f1 - f0
    S = [sample(src, f0 + i) for i in range(total + 1)]
    G = []
    for i in range(total + 1):
        g = {b: rot3(m[1]) for b, m in S[i].items()}
        y = scan(i / total)
        tilt = -math.radians(6) * abs(math.sin(y))
        for root, share in (("Head", 0.5), ("NeckTwist01", 0.3), ("Spine02", 0.2)):
            R = Matrix.Rotation(y * share, 3, "Z")
            if root == "Head":
                R = R @ Matrix.Rotation(tilt, 3, "X")
            Ri = R.inverted()
            for b in subtree(root):
                g[b] = Ri @ g[b]
        G.append(g)
    # the old suit's idle stands with its chest and head turned off to its left even with the scan out:
    # square both up to face where the hips do (the game turns the head to the real look)
    def mean_yaw(bone):
        return sum(facing(g[bone], bone) - facing(g["Hip"], "Hip") for g in G) / len(G)
    chest = mean_yaw("Spine02")
    Rc = Matrix.Rotation(-chest, 3, "Z")
    for g in G:
        for b in subtree("Spine02"):
            g[b] = Rc @ g[b]
    head = mean_yaw("Head")
    Rh = Matrix.Rotation(-head, 3, "Z")
    for g in G:
        for b in subtree("Head"):
            g[b] = Rh @ g[b]
    print("%s: chest squared %.1f deg, head %.1f deg" % (name, math.degrees(chest), math.degrees(head)))
    new_action(name)
    prev = {}
    for i in range(total + 1):
        local = {k: v[0] for k, v in S[i].items()}
        goals = {b: G[i][b] for b in subtree("Spine02")}
        basis, _ = solve(goals, local)
        key_pose(basis, f0 + i, prev)
    return name


# =============================================================== build
walk_lean = lean_of([sample(SOURCE["walk"], f) for f in range(*frames(SOURCE["walk"]))])
run_lean = lean_of([sample(SOURCE["run"], f) for f in range(*frames(SOURCE["run"]))])
print("chest lean: walk %.1f deg, run %.1f deg" % (walk_lean, run_lean))
BACK_RUN_LEAN = run_lean - (walk_lean + 5.0)          # a backpedal keeps the chest a little over the toes

made = [
    idle_still(),
    backward("walk", "walk_back", lean_change=2.0),
    backward("run", "run_back", lean_change=BACK_RUN_LEAN, stride=0.7, lift=0.5, flatten=0.4),
    backward("crouch_walk", "crouch_walk_back"),
]
for sd, tag in ((1, "l"), (-1, "r")):
    made.append(strafe("walk", "strafe_" + tag, sd, cycles=4, duty=0.55, w=0.13, r=0.075, lift=0.05, bob=0.010))
    made.append(strafe("run", "run_strafe_" + tag, sd, cycles=3, duty=0.32, w=0.13, r=0.08, lift=0.07, bob=0.022,
                       lean_change=0.5 * (run_lean - walk_lean), gallop=True, arm_damp=0.6))
    made.append(strafe("crouch_walk", "crouch_strafe_" + tag, sd, cycles=2, duty=0.55, w=0.13, r=0.07, lift=0.04,
                       bob=0.007))

def fcurves(act):
    try:
        return list(act.fcurves)
    except AttributeError:
        return [fc for layer in act.layers for st in layer.strips for cb in st.channelbags for fc in cb.fcurves]


for name in made:                                     # linear keys: the clips are sampled every frame already
    for fc in fcurves(bpy.data.actions[name]):
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"

print("native speeds (m/s, suit 2 m tall):")
for name in ["walk", "run", "crouch_walk"] + made:
    tr = foot_track(bpy.data.actions[name])
    axis = 0 if "strafe" in name else 1
    print("  %-18s %3d frames  %.2f" % (name, frames(bpy.data.actions[name])[1] - frames(bpy.data.actions[name])[0], planted_speed(tr, axis)))

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
else:                                                 # live Blender: rebuild the rig's relations so it plays
    arm.update_tag(refresh={"OBJECT", "DATA", "TIME"})
    bpy.context.view_layer.update()
