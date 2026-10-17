"""Add idle variants to the survivor suit (models/player/survivor.glb) for the lobby, so the people standing in
the lobby corridor (lobby_corridor.gd) don't all breathe the same breath in step.

    blender --background --python tools/blender/add_survivor_lobby_idles.py -- <in.glb> <out.glb>
    e.g. ... -- godot-backrooms/models/player/survivor.glb godot-backrooms/models/player/survivor.glb

Run it after build_player_hazmat.py and add_survivor_directions.py (it starts from idle_still). Every clip
already in the file is kept. Each new clip is idle_still with the upper body posed over it (the legs, and the
feet on the floor, are left exactly as they are), the same length, looping cleanly:

    lobby_idle_slump    tired: head hangs, shoulders sag, one long slow sigh
    lobby_idle_sway     shifting weight from side to side, the chest and head riding it
    lobby_idle_adjust   a hand comes up to settle the hood, holds there a moment, drops
    lobby_idle_hips     hands on the hips, a slow roll of the head
    lobby_idle_glance   jumpy: shoulders up, the head flicking to either side

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

# =============================================================== load (clearing the scene, keeping prefs)
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
for coll in (bpy.data.actions, bpy.data.meshes, bpy.data.armatures, bpy.data.materials, bpy.data.images):
    for d in list(coll):
        coll.remove(d)
scene = bpy.context.scene
scene.render.fps = 24
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

X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))


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


def sample(act, frame):
    """bone -> (local basis, armature-space matrix) at `frame`"""
    bind(act)
    scene.frame_set(int(math.floor(frame)), subframe=frame - math.floor(frame))
    return {pb.name: (pb.matrix_basis.copy(), pb.matrix.copy()) for pb in arm.pose.bones}


def solve(goals, local):
    """goals: bone -> armature-space 3x3 rotation; every other bone keeps its `local` basis. Returns bases."""
    M, basis = {}, {}
    for b in BONES:
        n = b.name
        p = PARENT[n]
        chain = (M[p] @ REL[n]) if p else REL[n].copy()
        if n in goals:
            want = Matrix.Translation(chain.translation) @ goals[n].to_4x4()
            bas = chain.inverted() @ want
            bas = Matrix.LocRotScale(bas.translation, bas.to_quaternion(), None)
        else:
            bas = local.get(n, Matrix())
        M[n] = chain @ bas
        basis[n] = bas
    return basis


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


def R(axis, deg):
    return Matrix.Rotation(math.radians(deg), 3, axis)


def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def bump(u, a, b, c, d):
    """0 -> 1 over a..b, held to c, back to 0 by d (u in 0..1)"""
    return smoothstep(a, b, u) * (1.0 - smoothstep(c, d, u))


def keyed(u, keys):
    """smooth path through (u, value) keys, first value = last so it loops"""
    for (ta, va), (tb, vb) in zip(keys, keys[1:]):
        if u <= tb:
            return va + (vb - va) * smoothstep(ta, tb, u)
    return keys[-1][1]


# =============================================================== the variants
# Each returns [(bone, rotation)] for clip phase u in 0..1: the rotation turns the bone and everything under it
# (armature space, in order).
def slump(u):
    w = 2 * math.pi * u
    sigh = bump(u, 0.35, 0.55, 0.6, 0.85)                  # one long breath out, shoulders let go
    return [
        ("Spine01", R(X, 7 + 2 * sigh)),
        ("Spine02", R(X, 6 + 2.5 * math.sin(w - 0.8) + 2 * sigh)),
        ("NeckTwist01", R(X, 8)),
        ("Head", R(X, 10 + 5 * sigh) @ R(Z, 3 * math.sin(w))),
        ("L_Clavicle", R(Z, 4 + 2 * sigh)),
        ("R_Clavicle", R(Z, -4 - 2 * sigh)),
        ("L_Upperarm", R(X, -7) @ R(Y, 2)),
        ("R_Upperarm", R(X, -8) @ R(Y, -2)),
        ("L_Forearm", R(X, -6)),
        ("R_Forearm", R(X, -4)),
    ]


def sway(u):
    w = 2 * math.pi * u                                    # one shift each way per loop
    s = math.sin(w)
    return [
        ("Waist", R(Y, 3.0 * s)),
        ("Spine01", R(Y, -1.5 * s) @ R(Z, 2.5 * math.sin(w + 0.5))),
        ("Spine02", R(Y, -2.5 * s) @ R(Z, 2.0 * math.sin(w + 0.5))),
        ("Head", R(Y, 3.0 * s) @ R(Z, -3.5 * math.sin(w + 0.5)) @ R(X, 2 * math.sin(2 * w))),
        ("L_Upperarm", R(Y, 2.5 * math.sin(w + 1.2)) @ R(X, -2)),
        ("R_Upperarm", R(Y, 2.5 * math.sin(w + 1.2)) @ R(X, -2)),
    ]


def adjust(u):
    up = bump(u, 0.10, 0.28, 0.62, 0.80)                   # hand up to the hood, held, back down
    pat = 0.5 + 0.5 * math.sin(2 * math.pi * 3.0 * u) if 0.30 < u < 0.60 else 0.0
    return [
        ("Spine02", R(Z, -4 * up)),
        ("Head", R(Z, 7 * up) @ R(Y, -6 * up) @ R(X, -3 * up)),
        ("R_Clavicle", R(Z, -5 * up)),
        ("R_Upperarm", R(X, -78 * up) @ R(Y, 14 * up)),
        ("R_Forearm", R(X, -105 * up + 6 * pat * up)),
        ("R_Hand", R(X, -10 * up) @ R(Z, 12 * up)),
    ]


def hips(u):
    w = 2 * math.pi * u
    return [
        ("Spine02", R(X, -1.5 + 1.0 * math.sin(w))),
        ("Head", R(Z, 10 * math.sin(w)) @ R(Y, -5 * math.sin(w + 1.5)) @ R(X, -2)),
        ("L_Clavicle", R(Z, -3)),
        ("R_Clavicle", R(Z, 3)),
        ("L_Upperarm", R(Y, -38) @ R(X, 6)),                # elbows out
        ("R_Upperarm", R(Y, 38) @ R(X, 6)),
        ("L_Forearm", R(Y, 72) @ R(X, 14)),                 # forearms back in, down onto the hips
        ("R_Forearm", R(Y, -72) @ R(X, 14)),
        ("L_Hand", R(X, -10)),
        ("R_Hand", R(X, -10)),
    ]


def glance(u):
    yaw = keyed(u, [(0.0, 0.0), (0.10, 0.0), (0.16, 42.0), (0.30, 42.0), (0.36, -8.0), (0.44, -8.0), (0.50, -50.0),
                    (0.66, -50.0), (0.72, 0.0), (0.84, 0.0), (0.88, 25.0), (0.93, 25.0), (1.0, 0.0)])
    hunch = 0.5 + 0.5 * math.sin(2 * math.pi * 2 * u - 1.0)       # shoulders riding up and settling
    start = bump(u, 0.12, 0.17, 0.30, 0.34) + bump(u, 0.46, 0.50, 0.66, 0.70)   # a start at each glance
    y = math.radians(yaw)
    return [
        ("Spine02", R(Z, yaw * 0.25) @ R(X, 2.0 * start)),
        ("NeckTwist01", R(Z, yaw * 0.3)),
        ("Head", R(Z, yaw * 0.45) @ R(X, -3.0 - 4.0 * start) @ R(Y, -6 * math.sin(y))),
        ("L_Clavicle", R(Z, -5 - 3 * hunch)),
        ("R_Clavicle", R(Z, 5 + 3 * hunch)),
        ("L_Upperarm", R(X, -4) @ R(Y, 3)),
        ("R_Upperarm", R(X, -4) @ R(Y, -3)),
        ("L_Forearm", R(X, -12 - 6 * start)),
        ("R_Forearm", R(X, -12 - 6 * start)),
    ]


VARIANTS = {
    "lobby_idle_slump": slump, "lobby_idle_sway": sway, "lobby_idle_adjust": adjust,
    "lobby_idle_hips": hips, "lobby_idle_glance": glance,
}


def build(name, fn, src="idle_still"):
    act = SOURCE[src]
    f0, f1 = frames(act)
    total = f1 - f0
    S = [sample(act, f0 + i) for i in range(total + 1)]       # sampling binds the source: all first
    G = []
    for i in range(total + 1):
        g = {b: rot3(m[1]) for b, m in S[i].items()}
        for bone, r in fn((i % total) / total):               # the last frame is the first again: it loops
            for b in subtree(bone):
                g[b] = r @ g[b]
        G.append(g)
    new_action(name)
    prev = {}
    for i in range(total + 1):
        local = {k: v[0] for k, v in S[i].items()}
        goals = {b: G[i][b] for b in subtree("Waist")}        # the legs stay as the source has them
        key_pose(solve(goals, local), f0 + i, prev)
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
