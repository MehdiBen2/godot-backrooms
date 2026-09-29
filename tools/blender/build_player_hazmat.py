"""Build the player / survivor hazmat model the game loads (models/player/survivor.glb).

    blender --background --python tools/blender/build_player_hazmat.py -- <new.glb> <old.glb> <out.glb>
    (or with the `bpy` module: python build_player_hazmat.py <new.glb> <old.glb> <out.glb>)

    new.glb  asetsuimprot/PlayerHazmatmodel.glb   the Tripo suit: mesh, rig, 'run' and an in-place 'walk'
    old.glb  asetsuimprot/hazmat_old.glb          the old Sketchfab suit, read for its idle / crouch / death clips
    e.g. python tools/blender/build_player_hazmat.py asetsuimprot/PlayerHazmatmodel.glb \
             asetsuimprot/hazmat_old.glb godot-backrooms/models/player/survivor.glb

What it does:

1. Hoses. Each breathing hose is one piece of the mesh (filter canister + hose, running from the mask over
   the shoulder and down the side of the pack). Tripo bound them ~40% to the upper arm, so every arm swing
   tore them off the mask. They are re-weighted by distance along the hose from the mask socket: the
   canister is 100% Head, the hose blends Head > NeckTwist02 > NeckTwist01 > Spine02 over the shoulder
   (with a little Clavicle where it lies on it) and ends on the chest, where it plugs into the pack. The
   pack and the hose plugs are made rigid on Spine02 so they no longer bend with the arms either.
   Seat: Tripo bound everything up to the belt ~80% to the thighs, so in a crouch the buttocks folded
   in between the legs. The seat now rides the Pelvis bone, handing over to the thighs below the crease.
   It is also padded out a little (fuller_seat): the suit was modelled flat there.
2. Clips, all looping cleanly (last frame = first):
   run              the Tripo run, recentred over the origin (it ran 0.5 m in front of it), loop gap closed
   walk             the Tripo in-place walk
   idle_lookaround  the old suit's breathing idle, feet planted with IK, turning head / neck / chest to look
                    left, then right, then back
   crouch_idle      the old suit's crouch idle, feet planted with IK
   crouch_walk      the old clip's upper body (smoothed, squared up to face forward, left arm mirrored onto
                    the right, head raised to look ahead) over legs rebuilt with IK: planted feet with
                    heel-strike / toe-off roll, knees over the toes, pelvis bob / sway / twist, a
                    counter-rotating chest and arm swing. Its stride is authored for the game: at speed 1.0 it
                    covers 1.4 m/s with the suit fitted 2 m tall, so the feet don't slide.
   death            the old suit's fall, retargeted
   Retargeting copies world-space rotation deltas from rest (both rigs are in a T pose); the hips move by
   the ratio of the rigs' standing hip heights.
3. Exports one .glb with every clip. It faces +Z like the old suit. The native speeds printed for run and
   walk are what scripts/Entities/survivor_anim.gd NATIVE uses.
"""
import sys
import math
import heapq
from collections import defaultdict

import bpy
from mathutils import Vector, Matrix, Quaternion

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
NEW_GLB, OLD_GLB, OUT_GLB = args[:3]

FPS = 24
GAME_HEIGHT = 2.0          # m: what the game fits the suit to (MODEL_HEIGHT in the scripts)
CROUCH_SPEED = 1.4         # m/s the crouch walk covers at speed 1.0 (the scripts divide by this)
CROUCH_FRAMES = 22         # one crouch-walk cycle (two steps)

bpy.ops.wm.read_factory_settings(use_empty=True)
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
scene = bpy.context.scene
scene.render.fps = FPS


def import_glb(path):
    before = set(bpy.data.objects)
    acts = set(bpy.data.actions)
    bpy.ops.import_scene.gltf(filepath=path)
    objs = [o for o in bpy.data.objects if o not in before]
    for o in [o for o in objs if o.type == "MESH" and o.name.startswith("Icosphere")]:
        bpy.data.objects.remove(o, do_unlink=True)    # the importer's bone-shape sphere
    return [o for o in bpy.data.objects if o not in before], set(bpy.data.actions) - acts


new_objs, new_acts = import_glb(NEW_GLB)
arm = next(o for o in new_objs if o.type == "ARMATURE")
body = next(o for o in new_objs if o.type == "MESH")
old_objs, old_acts = import_glb(OLD_GLB)
src_arm = next(o for o in old_objs if o.type == "ARMATURE")
old_by_name = {a.name: a for a in old_acts}
for a in old_acts:                          # keep their names clear of the new clips ('run', ...)
    a.name = "old_" + a.name


# =============================================================== 1. hose weights
def geo_islands(me):
    """Connected pieces, merged across UV seams (the importer splits vertices there)."""
    n = len(me.vertices)
    par = list(range(n))

    def find(x):
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x

    def union(a, b):
        a, b = find(a), find(b)
        if a != b:
            par[a] = b
    for e in me.edges:
        union(*e.vertices)
    at = defaultdict(list)
    for v in me.vertices:
        at[tuple(round(c, 5) for c in v.co)].append(v.index)
    for vs in at.values():
        for x in vs[1:]:
            union(vs[0], x)
    isl = defaultdict(list)
    for i in range(n):
        isl[find(i)].append(i)
    return list(isl.values())


def bounds(me, vs):
    co = [me.vertices[i].co for i in vs]
    return Vector([min(c[j] for c in co) for j in range(3)]), Vector([max(c[j] for c in co) for j in range(3)])


def set_weights(obj, vs, weights):
    groups = {g.name: g for g in obj.vertex_groups}
    for g in obj.vertex_groups:
        g.remove(vs)
    tot = sum(weights.values())
    for name, w in weights.items():
        if w > 1e-4:
            groups[name].add(vs, w / tot, "REPLACE")


def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def fix_hoses():
    me = body.data
    isl = geo_islands(me)
    hoses, pack, plugs = {}, None, []
    for vs in isl:
        lo, hi = bounds(me, vs)
        c = (lo + hi) * 0.5
        # canister at the mask (z ~0.87, in front) down to the pack side (z ~0.69, behind)
        if len(vs) > 150 and hi.z > 0.85 and lo.z < 0.72 and lo.y < -0.1 and hi.y > 0.05 and abs(c.x) > 0.05:
            hoses["L_" if c.x > 0 else "R_"] = vs
        elif len(vs) > 300 and lo.y > 0.04 and hi.y > 0.12 and 0.6 < lo.z < 0.7:
            pack = vs
        elif len(vs) < 80 and lo.y > -0.02 and 0.6 < lo.z < 0.7 and hi.z < 0.72 and abs(c.x) > 0.09:
            plugs.append(vs)
    assert set(hoses) == {"L_", "R_"} and pack is not None, "hose / pack pieces not found"
    for vs in plugs + [pack]:
        set_weights(body, vs, {"Spine02": 1.0})

    key = {v.index: tuple(round(c, 5) for c in v.co) for v in me.vertices}
    adj = defaultdict(set)
    for e in me.edges:
        a, b = key[e.vertices[0]], key[e.vertices[1]]
        adj[a].add(b)
        adj[b].add(a)
    for side, vs in hoses.items():
        sx = 1 if side == "L_" else -1
        socket = Vector((0.053 * sx, -0.108, 0.866))              # the mask's filter socket
        keys = set(key[i] for i in vs)
        seeds = sorted(keys, key=lambda k: (Vector(k) - socket).length)[:10]
        dist = {k: math.inf for k in keys}
        heap = []
        for k in seeds:
            dist[k] = 0.0
            heapq.heappush(heap, (0.0, k))
        while heap:
            d, k = heapq.heappop(heap)
            if d > dist[k]:
                continue
            for nb in adj[k]:
                nd = d + (Vector(nb) - Vector(k)).length
                if nd < dist.get(nb, -1.0):
                    dist[nb] = nd
                    heapq.heappush(heap, (nd, nb))
        far = max(dist.values())
        chain = ["Head", "NeckTwist02", "NeckTwist01", "Spine02"]
        by_s = defaultdict(list)
        for i in vs:
            by_s[dist[key[i]] / far].append(i)
        for s, ids in by_s.items():
            w = defaultdict(float)
            p = smoothstep(0.13, 0.62, s) * 3.0                # canister: Head only; then down the neck
            i0 = min(int(p), 2)
            f = p - i0
            w[chain[i0]] += 1 - f
            w[chain[i0 + 1]] += f
            clav = 0.25 * smoothstep(0.3, 0.5, s) * (1 - smoothstep(0.62, 0.85, s))   # lies on the shoulder
            for k in w:
                w[k] *= 1 - clav
            w[side + "Clavicle"] += clav
            set_weights(body, ids, dict(w))
    print("hoses re-weighted:", {k: len(v) for k, v in hoses.items()}, "pack", len(pack), "plugs", len(plugs))


fix_hoses()


def fix_seat():
    """Tripo bound the whole seat, up to the belt above the hip joints, ~80% to the thighs and next to
    nothing to the pelvis, so in a crouch (thighs folded past level) the buttocks folded forward with the
    legs and got sucked up between them. The seat now rides the Pelvis bone and hands over to the thighs
    only below the crease: lower at the back (under the buttocks) than at the front (the groin)."""
    me = body.data
    groups = {g.index: g.name for g in body.vertex_groups}
    legs = ("Thigh", "Calf", "Foot", "ToeBase", "KneeShareBone")
    changed = 0
    for v in me.vertices:
        c = v.co
        if not (0.36 < c.z < 0.62 and abs(c.x) < 0.16):
            continue
        w = {groups[g.group]: g.weight for g in v.groups if g.weight > 0}
        leg = {k: x for k, x in w.items() if k[2:].startswith(legs)}
        torso = {k: x for k, x in w.items() if k not in leg}
        if not leg:
            continue
        back = smoothstep(-0.07, 0.0, c.y)                     # 0 front .. 1 back
        top = 0.53
        bottom = 0.45 + (0.41 - 0.45) * back                   # the gluteal fold sits lower than the groin
        t = smoothstep(top, bottom, c.z)                       # share left on the legs
        tl = sum(leg.values())
        leg = {k: x / tl for k, x in leg.items()}
        tt = sum(torso.values())
        torso_n = {k: x / tt for k, x in torso.items()} if tt > 1e-4 else {}
        keep = smoothstep(0.50, 0.60, c.z)                     # up at the belt the old torso weights stand
        new = defaultdict(float)
        for k, x in leg.items():
            new[k] += t * x
        new["Pelvis"] += (1 - t) * (1 - keep if torso_n else 1.0)
        for k, x in torso_n.items():
            new[k] += (1 - t) * keep * x
        set_weights(body, [v.index], dict(new))
        changed += 1
    print("seat re-weighted:", changed, "vertices")


fix_seat()


def fuller_seat(amount=0.038):
    """The suit's seat was modelled flat; pad it out into two rounded cheeks (the cleft between them stays),
    pushing the back of the suit backwards and a little down. `amount` is the most it moves (model units;
    the suit is 1 tall, 2 m in the game)."""
    me = body.data
    main = max(geo_islands(me), key=len)                     # the suit itself, not the pouches on it
    moved = 0
    for i in main:
        c = me.vertices[i].co
        if not (0.36 < c.z < 0.60 and abs(c.x) < 0.15 and c.y > -0.05):
            continue
        behind = smoothstep(-0.04, 0.03, c.y)
        height = math.exp(-((c.z - 0.465) / 0.06) ** 2)
        cheek = math.exp(-((abs(c.x) - 0.055) / 0.05) ** 2)
        k = amount * behind * height * cheek
        if k > 1e-5:
            c.y += k
            c.z -= k * 0.25
            moved += 1
    me.update()
    print("seat padded:", moved, "vertices")


fuller_seat()


# =============================================================== pose solving
def rot3(m):
    return m.to_3x3().normalized()


BONES = list(arm.data.bones)                       # parents before children
REST = {b.name: b.matrix_local.copy() for b in BONES}
PARENT = {b.name: (b.parent.name if b.parent else None) for b in BONES}
REL = {n: (REST[p].inverted() @ REST[n]) if p else REST[n] for n, p in PARENT.items()}
CHILDREN = defaultdict(list)
for b in BONES:
    if b.parent:
        CHILDREN[b.parent.name].append(b.name)


def subtree(name, stop=()):
    out = [name]
    for c in CHILDREN[name]:
        if c not in stop:
            out += subtree(c, stop)
    return out


def solve(goals, hip_pos=None, legs=None):
    """goals: bone -> armature-space 3x3 rotation; unlisted bones keep their rest basis.
    legs(M) is called once the pelvis is placed and returns more goals (the IK). Returns bases."""
    M, basis = {}, {}
    for b in BONES:
        n = b.name
        p = PARENT[n]
        chain = (M[p] @ REL[n]) if p else REL[n].copy()
        if n == "L_Thigh" and legs:
            goals = dict(goals)
            goals.update(legs(M))
        if n in goals:
            pos = hip_pos if (n == "Hip" and hip_pos is not None) else chain.translation
            want = Matrix.Translation(pos) @ goals[n].to_4x4()
            bas = chain.inverted() @ want
            bas = Matrix.LocRotScale(bas.translation, bas.to_quaternion(), None)
        else:
            bas = Matrix()
        M[n] = chain @ bas
        basis[n] = bas
    return basis


def world_pos(M, n):
    return M[n].translation


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
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm.animation_data_create()
    arm.animation_data.action = act
    return act


# =============================================================== retargeting
MAP = {"Hips": "Hip", "Spine": "Waist", "Spine1": "Spine01", "Spine2": "Spine02", "Neck": "NeckTwist01", "Head": "Head"}
for s, t in (("Left", "L_"), ("Right", "R_")):
    MAP.update({s + "Shoulder": t + "Clavicle", s + "Arm": t + "Upperarm", s + "ForeArm": t + "Forearm",
                s + "Hand": t + "Hand", s + "UpLeg": t + "Thigh", s + "Leg": t + "Calf",
                s + "Foot": t + "Foot", s + "ToeBase": t + "ToeBase"})
    for f, g in (("Index", "Index"), ("Middle", "Mid"), ("Ring", "Ring"), ("Pinky", "Pinky"), ("Thumb", "Thumb")):
        for i in (1, 2, 3):
            MAP[f"{s}Hand{f}{i}"] = f"{t}{g}{i}"

SRC_REST = {b.name: rot3(src_arm.matrix_world @ b.matrix_local) for b in src_arm.data.bones}


def src_sample(action, frame):
    src_arm.animation_data.action = action
    scene.frame_set(int(math.floor(frame)), subframe=frame - math.floor(frame))
    mw = src_arm.matrix_world
    return {pb.name: (rot3(mw @ pb.matrix), (mw @ pb.matrix).translation.copy()) for pb in src_arm.pose.bones}


def retarget(sample):
    goals = {}
    for s, t in MAP.items():
        goals[t] = (sample[s][0] @ SRC_REST[s].inverted() @ rot3(REST[t])).normalized()
    return goals


_ref = src_sample(old_by_name["idle"], 1.0)
SRC_HIP = _ref["Hips"][1]
SRC_FLOOR = min(_ref["LeftToeBase"][1].z, _ref["RightToeBase"][1].z)
TGT_HIP = REST["Hip"].translation.copy()
K = (TGT_HIP.z - 0.03) / (SRC_HIP.z - SRC_FLOOR)       # old metres -> new units, by standing hip height


def src_hip(sample):
    return TGT_HIP + (sample["Hips"][1] - SRC_HIP) * K


def src_frames(action):
    f0, f1 = action.frame_range
    return f0, f1


# =============================================================== leg IK
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

    def solve(self, H, A, pole):
        d = A - H
        dl = min(d.length, (self.l1 + self.l2) * 0.999)
        u = d.normalized()
        a = (self.l1 ** 2 - self.l2 ** 2 + dl ** 2) / (2 * dl)
        h = math.sqrt(max(self.l1 ** 2 - a * a, 0.0))
        v = (pole - u * pole.dot(u)).normalized()
        K = H + u * a + v * h
        A = H + u * dl
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
        H = M["Pelvis"] @ (REST["Pelvis"].inverted() @ REST[leg.side + "Thigh"]).translation
        t, c = leg.solve(H, A, pole)
        out[leg.side + "Thigh"] = t
        out[leg.side + "Calf"] = c
        out[leg.side + "Foot"] = rfoot
        out[leg.side + "ToeBase"] = rtoe
    return out


# =============================================================== periodic smoothing
def fourier(vals, harmonics):
    n = len(vals)
    cs = []
    for k in range(harmonics + 1):
        a = sum(vals[j] * math.cos(2 * math.pi * k * j / n) for j in range(n)) * (2 / n if k else 1 / n)
        b = sum(vals[j] * math.sin(2 * math.pi * k * j / n) for j in range(n)) * (2 / n if k else 0)
        cs.append((a, b))
    return lambda ph: sum(a * math.cos(2 * math.pi * k * ph) + b * math.sin(2 * math.pi * k * ph) for k, (a, b) in enumerate(cs))


def loop_rotations(samples, harmonics):
    """samples: list (one cycle, last frame excluded) of bone -> 3x3. Returns phase -> bone -> 3x3,
    each bone's quaternion low-passed so the loop is smooth and closes on itself."""
    out = {}
    for n in samples[0]:
        qs = []
        for s in samples:
            q = s[n].to_quaternion()
            if qs and qs[-1].dot(q) < 0:
                q.negate()
            qs.append(q)
        fs = [fourier([q[i] for q in qs], harmonics) for i in range(4)]
        out[n] = fs
    return lambda ph: {n: Quaternion([f(ph) for f in fs]).normalized().to_matrix() for n, fs in out.items()}


def loop_vectors(vals, harmonics):
    fs = [fourier([v[i] for v in vals], harmonics) for i in range(3)]
    return lambda ph: Vector([f(ph) for f in fs])


# =============================================================== 2a. run + look-around
def fcurves(act):
    try:
        return list(act.fcurves)
    except AttributeError:
        return [fc for layer in act.layers for st in layer.strips for cb in st.channelbags for fc in cb.fcurves]


run = next(a for a in new_acts if a.name.lower().startswith("run"))
walk = next(a for a in new_acts if a.name.lower().startswith("walk"))
run.name, walk.name = "run", "walk"


def foot_track(act):
    arm.animation_data.action = act
    f0, f1 = map(int, act.frame_range)
    out = []
    for f in range(f0, f1 + 1):
        scene.frame_set(f)
        pb = arm.pose.bones
        out.append((pb["L_ToeBase"].head.copy(), pb["R_ToeBase"].head.copy()))
    return out


def planted_speed(track):
    """Native ground speed (units/s): how fast a toe on the floor slides back under the body."""
    vs = []
    for side in (0, 1):
        floor = min(p[side].z for p in track)
        for i in range(len(track) - 1):
            if track[i][side].z < floor + 0.012 and track[i + 1][side].z < floor + 0.012:
                vs.append((track[i + 1][side].y - track[i][side].y) * FPS)
    vs.sort()
    return vs[len(vs) // 2] if vs else 0.0


def close_loop(act):
    """Spread the gap between the last and first key over the clip, so it loops without a pop."""
    for fc in fcurves(act):
        kps = fc.keyframe_points
        if len(kps) < 3:
            continue
        gap = kps[-1].co[1] - kps[0].co[1]
        t0, t1 = kps[0].co[0], kps[-1].co[0]
        for kp in kps:
            d = gap * (kp.co[0] - t0) / (t1 - t0)
            kp.co[1] -= d
            kp.handle_left[1] -= d
            kp.handle_right[1] -= d
        fc.update()


def recentre(act):
    """Put the feet (on average) back under the origin: run came ~0.5 m in front of it."""
    track = foot_track(act)
    centre = sum(((l + r) * 0.5 for l, r in track), Vector()) / len(track)
    rest = (REST["L_ToeBase"].translation + REST["R_ToeBase"].translation) * 0.5
    local = rot3(REST["Hip"]).inverted() @ Vector((rest.x - centre.x, rest.y - centre.y, 0.0))
    for fc in fcurves(act):
        if fc.data_path == 'pose.bones["Hip"].location':
            for kp in fc.keyframe_points:
                kp.co[1] += local[fc.array_index]
                kp.handle_left[1] += local[fc.array_index]
                kp.handle_right[1] += local[fc.array_index]
            fc.update()


for act in (run, walk):
    close_loop(act)
    recentre(act)
    v = planted_speed(foot_track(act))
    print("%s: %d frames, native speed %.3f u/s = %.2f m/s in game" % (act.name, act.frame_range[1] - act.frame_range[0] + 1, v, v * GAME_HEIGHT))


# =============================================================== 2b. standing look-around + crouch idle
def planted_idle(src_name, out_name, repeats=1, harmonics=4, lookaround=False, soften=0.0, own_stance=0.0):
    """Retarget an old in-place clip with its feet planted by IK (the rigs' proportions differ, so a straight
    retarget lets them slide). `lookaround` adds the head / neck / chest turning to scan the room;
    `soften` lowers the hips a touch so straight standing legs keep a little give in the knees; `own_stance`
    pulls the feet (0..1) from the old clip's placement towards this rig's own, narrower one."""
    act = old_by_name[src_name]
    f0, f1 = src_frames(act)
    n = int(round(f1 - f0))
    samples, hips, ankles = [], [], {"L_": [], "R_": []}
    for i in range(n):
        s = src_sample(act, f0 + i)
        samples.append(retarget(s))
        hips.append(src_hip(s))
        for side, sname in (("L_", "Left"), ("R_", "Right")):
            ankles[side].append((s[sname + "Foot"][1] - SRC_HIP) * K + TGT_HIP)
    rots = loop_rotations(samples, harmonics)
    hip = loop_vectors(hips, harmonics)
    ref = rots(0.0)
    feet = {}
    for leg in LEGS:                        # where they sit on average, flat on the floor
        A = sum(ankles[leg.side], Vector()) / n
        A = A.lerp(Vector((leg.A0.x * 1.1, leg.A0.y, 0)), own_stance)
        A.z = leg.A0.z
        fwd = ref[leg.side + "Foot"] @ (rot3(REST[leg.side + "Foot"]).inverted() @ (leg.T0 - leg.A0))
        R = Matrix.Rotation(math.atan2(fwd.x, -fwd.y), 3, "Z")
        knee = (R @ Vector((0.25 * leg.sx, -1, 0.0))).normalized()
        feet[leg.side] = (A, R @ rot3(REST[leg.side + "Foot"]), R @ rot3(REST[leg.side + "ToeBase"]), knee)

    def scan(t):
        """Yaw (radians) over the whole clip, t in 0..1: look left, hold, sweep right, hold, back."""
        keys = [(0.0, 0.0), (0.08, 0.0), (0.22, 50.0), (0.40, 50.0), (0.60, -45.0), (0.78, -45.0), (0.92, 0.0), (1.0, 0.0)]
        for (ta, ya), (tb, yb) in zip(keys, keys[1:]):
            if t <= tb:
                return math.radians(ya + (yb - ya) * smoothstep(ta, tb, t))
        return 0.0

    # lower the hips as far as the legs need to reach their planted feet with the knees a touch bent
    drop = 0.0
    for i in range(n):
        ph = i / n
        M = {}
        solve(rots(ph), hip(ph), lambda m: M.update(m) or {})
        for leg in LEGS:
            H = M["Pelvis"] @ (REST["Pelvis"].inverted() @ REST[leg.side + "Thigh"]).translation
            d = feet[leg.side][0] - H
            r = (leg.l1 + leg.l2) * 0.985
            flat = Vector((d.x, d.y)).length
            if flat < r:
                drop = max(drop, -d.z - math.sqrt(r * r - flat * flat))
    soften += max(drop, 0.0)

    new_action(out_name)
    prev = {}
    total = n * repeats
    for i in range(total + 1):
        ph = (i % n) / n
        g = rots(ph)
        if lookaround:
            y = scan(i / total)
            tilt = -math.radians(6) * abs(math.sin(y))          # glances down a touch at the sides
            for root, share in (("Spine02", 0.2), ("NeckTwist01", 0.3), ("Head", 0.5)):
                R = Matrix.Rotation(y * share, 3, "Z")
                if root == "Head":
                    R = R @ Matrix.Rotation(tilt, 3, "X")
                for b in subtree(root):
                    if b in g:
                        g[b] = R @ g[b]
        basis = solve(g, hip(ph) - Vector((0, 0, soften)), lambda M: leg_goals(M, feet))
        key_pose(basis, 1 + i, prev)
    print("%s: %d frames, hip z %.3f (lowered %.3f)" % (out_name, total + 1, hip(0).z - soften, soften))
    return hip(0).z - soften


# =============================================================== 2c. crouch walk (old upper body, new legs)
def crouch_walk(idle_hip_z):
    act = old_by_name["crouch_walk"]
    f0, f1 = src_frames(act)
    n_src = int(round(f1 - f0))
    samples, hips, lfwd = [], [], []
    for i in range(n_src):
        s = src_sample(act, f0 + i)
        samples.append(retarget(s))
        hips.append(src_hip(s))
        lfwd.append(-(s["LeftFoot"][1].y - s["RightFoot"][1].y))
    src_rots = loop_rotations(samples, 2)
    hip_src = loop_vectors(hips, 2)
    hip_src_mean = sum(hips, Vector()) / len(hips)
    # phase where the old clip's left foot is furthest ahead: the left heel strikes there
    phi = max(range(n_src), key=lambda i: lfwd[i]) / n_src

    # the old clip holds its right arm up and out and turns its chest aside: keep its left arm, mirrored
    # half a stride later for the right one, and square the body up to face forward
    arm_bones = [b for b in subtree("L_Clavicle") if b in samples[0]]
    flip = Matrix.Scale(-1, 3, Vector((1, 0, 0)))
    def yaw_of(bone):          # from the bone's side axis: its forward axis dives with the lean
        side = sum((src_rots(i / 16)[bone] @ rot3(REST[bone]).inverted() @ Vector((1, 0, 0)) for i in range(16)), Vector())
        return math.atan2(side.y, side.x)
    square_chest = Matrix.Rotation(-yaw_of("Spine02"), 3, "Z")
    square_head = Matrix.Rotation(-yaw_of("Head"), 3, "Z") @ Matrix.Rotation(math.radians(-12), 3, "X")  # eyes up the corridor
    upper = set(subtree("Waist", stop=("NeckTwist01",)))
    head = set(subtree("NeckTwist01"))
    head_only = set(subtree("Head"))

    def squared(g):
        lift = Matrix.Rotation(math.radians(-13), 3, "X")
        return {b: (square_chest @ r if b in upper else (lift if b in head_only else Matrix.Identity(3)) @ square_head @ r if b in head else r)
                for b, r in g.items()}

    def rots(ph):
        g = squared(src_rots(ph))
        later = squared(src_rots((ph + 0.5) % 1.0))
        for b in arm_bones:
            rb = "R_" + b[2:]
            d = later[b] @ rot3(REST[b]).inverted()
            g[rb] = (flip @ d @ flip) @ rot3(REST[rb])
        return g

    N = CROUCH_FRAMES
    T = N / FPS
    speed = CROUCH_SPEED / GAME_HEIGHT                   # units / s
    stride = speed * T                                   # one cycle = two steps
    duty = 0.62                                          # share of the cycle a foot is planted
    reach = stride * duty                                # how far a planted foot slides back under the body
    lift = 0.055
    heel_off = math.radians(32)
    toe_up = math.radians(12)
    toe_out = math.radians(7)
    hip_z = min(idle_hip_z + 0.07, 0.345)
    print("crouch_walk: %d frames (%.2fs), stride %.3f u/cycle, hip z %.3f" % (N + 1, T, stride, hip_z))

    def foot(leg, ph):
        q = (ph - phi - (0.0 if leg.side == "L_" else 0.5)) % 1.0
        yaw = Matrix.Rotation(toe_out * leg.sx, 3, "Z")
        x = leg.A0.x + 0.012 * leg.sx
        toe_vec = yaw @ (leg.T0 - leg.A0)
        base_y = leg.A0.y + 0.012
        if q < duty:                                    # planted: slides back at walking speed
            u = q / duty
            y = base_y - reach / 2 + reach * u           # forward is -Y
            A = Vector((x, y, leg.A0.z))
            pitch = -toe_up * (1 - smoothstep(0.0, 0.16, u))          # toes come down after the heel strike
            heel = heel_off * smoothstep(0.62, 1.0, u)                # heel peels up, rolling over the toes
            if heel > 0:
                toe = A + toe_vec
                A = toe + Matrix.Rotation(heel, 3, yaw @ Vector((1, 0, 0))) @ (A - toe)
            ang = heel + pitch
            carry = Vector()
        else:                                           # swing: Hermite so it leaves / lands at stance speed
            w = (q - duty) / (1 - duty)
            m = reach * (1 - duty) / duty
            p0, p1 = reach / 2, -reach / 2
            h00, h10, h01, h11 = 2 * w ** 3 - 3 * w ** 2 + 1, w ** 3 - 2 * w ** 2 + w, -2 * w ** 3 + 3 * w ** 2, w ** 3 - w ** 2
            y = base_y + h00 * p0 + h10 * m + h01 * p1 + h11 * m
            z = leg.A0.z + lift * math.sin(math.pi * min(1.0, w ** 0.85))
            A = Vector((x, y, z))
            # at lift-off the ankle is still up on the toes: ease that offset out
            toe0 = Vector((x, base_y + reach / 2, leg.A0.z)) + toe_vec
            lifted = toe0 + Matrix.Rotation(heel_off, 3, yaw @ Vector((1, 0, 0))) @ (Vector((x, base_y + reach / 2, leg.A0.z)) - toe0)
            carry = (lifted - Vector((x, base_y + reach / 2, leg.A0.z))) * (1 - smoothstep(0.0, 0.4, w))
            A = A + carry
            ang = heel_off * (1 - smoothstep(0.0, 0.55, w)) - toe_up * smoothstep(0.45, 1.0, w)
        R = yaw @ Matrix.Rotation(ang, 3, "X")
        toe_bend = heel_off * smoothstep(0.62, 1.0, q / duty) if q < duty else heel_off * (1 - smoothstep(0.0, 0.3, (q - duty) / (1 - duty))) * 0.6
        rfoot = R @ rot3(REST[leg.side + "Foot"])
        rtoe = yaw @ Matrix.Rotation(ang - toe_bend, 3, "X") @ rot3(REST[leg.side + "ToeBase"])
        knee = (yaw @ Vector((0.22 * leg.sx, -1.0, 0.0))).normalized()
        return A, rfoot, rtoe, knee

    new_action("crouch_walk")
    prev = {}
    for i in range(N + 1):
        ph = i / N
        c = math.cos(2 * math.pi * (ph - phi))                 # +1: left foot ahead
        g = rots(ph)
        src_h = hip_src(ph)
        # pelvis: lowest just after each heel strike, over the planted foot, twisting with the stride
        bob = -0.007 * math.cos(4 * math.pi * (ph - phi - 0.06))
        sway = 0.011 * math.cos(2 * math.pi * (ph - phi - 0.31))
        hp = Vector((TGT_HIP.x + sway, TGT_HIP.y + (src_h.y - hip_src_mean.y) * 0.3, hip_z + bob))
        yaw = math.radians(6) * -c
        roll = math.radians(3) * -math.cos(2 * math.pi * (ph - phi - 0.31))
        extra = Matrix.Rotation(yaw, 3, "Z") @ Matrix.Rotation(roll, 3, "Y")
        g["Hip"] = extra @ g["Hip"]
        # chest turns against the pelvis; the head stays on the old clip's (steady) aim
        counter = Matrix.Rotation(-yaw * 0.8, 3, "Z")
        for b in subtree("Spine02", stop=("NeckTwist01",)):
            if b in g:
                g[b] = counter @ g[b]
        # arms swing against the legs, drawn in (the old suit held them out wide)
        for side, sgn in (("L_", 1), ("R_", -1)):
            sw = Matrix.Rotation(math.radians(11) * sgn * c, 3, "X") @ Matrix.Rotation(math.radians(18) * sgn, 3, "Y")
            for b in subtree(side + "Upperarm"):
                if b in g:
                    g[b] = sw @ g[b]
        feet = {leg.side: foot(leg, ph) for leg in LEGS}
        basis = solve(g, hp, lambda M: leg_goals(M, feet))
        key_pose(basis, 1 + i, prev)


# =============================================================== 2d. death (straight retarget)
def death():
    act = old_by_name["death"]
    f0, f1 = src_frames(act)
    n = int(round(f1 - f0))
    new_action("death")
    prev = {}
    for i in range(n + 1):
        s = src_sample(act, f0 + i)
        key_pose(solve(retarget(s), src_hip(s)), 1 + i, prev)
    print("death: %d frames" % (n + 1))


planted_idle("idle", "idle_lookaround", repeats=3, lookaround=True, soften=0.006, own_stance=0.75)
idle_z = planted_idle("crouch_idle", "crouch_idle")
crouch_walk(idle_z)
death()

# linear keys: the clips are sampled every frame already
for act in bpy.data.actions:
    for fc in fcurves(act):
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"


# =============================================================== 3. export
for o in old_objs:
    bpy.data.objects.remove(o, do_unlink=True)
for a in old_acts:
    bpy.data.actions.remove(a)
arm.animation_data.action = None
for pb in arm.pose.bones:
    pb.matrix_basis = Matrix()
# every clip in one file: one NLA track per clip, exported by track name
keep = ["idle_lookaround", "walk", "run", "crouch_idle", "crouch_walk", "death"]
for a in list(bpy.data.actions):
    if a.name not in keep:
        bpy.data.actions.remove(a)
ad = arm.animation_data
for t in list(ad.nla_tracks):
    ad.nla_tracks.remove(t)
for name in keep:
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
body.name, body.data.name, arm.name = "Suit", "Suit", "SuitRig"
for slot in body.material_slots:            # readable names for the texture Godot extracts
    slot.material.name = "Suit"
for img in bpy.data.images:
    if img.users and img.source == "FILE" or img.packed_file:
        img.name = "suit_basecolor"
for o in bpy.data.objects:
    o.select_set(o in (arm, body))
bpy.context.view_layer.objects.active = arm
bpy.ops.export_scene.gltf(
    filepath=OUT_GLB, export_format="GLB", use_selection=True,
    export_animations=True, export_animation_mode="NLA_TRACKS", export_force_sampling=True,
    export_frame_step=1, export_anim_slide_to_zero=True, export_skins=True, export_all_influences=False,
    export_yup=True, export_apply=False)
print("wrote", OUT_GLB, "clips", keep)
