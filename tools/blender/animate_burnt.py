"""Author THE BURNT's clips (models/entities/burnt/theburnt_animated.glb) from its unanimated Tripo rig.

    blender -b --python tools/blender/animate_burnt.py            (or exec() it in a live Blender over the MCP)

The source file, theburnt.glb, has a skeleton and no animation; burnt.gd used to pose every bone itself. This
builds a small control rig on that skeleton (IK legs, IK arms, FK spine/head/fingers), keys each clip on the
controls, bakes it down to plain bone rotations and exports every clip into one GLB. The skeleton and the skin
are left as they are (bone names are what burnt.gd finds), except that the half-length limb bones Tripo makes
(each followed by its twist bones) are stretched to reach the next joint, so a two-bone IK chain lands its
hand / foot where the target is. glTF keeps no bone length, so that changes nothing in the file.

Model space: the figure stands 0.978 tall (4.5 m in game: body.scale ~4.6), faces -Y, its right side is -X.
Clips (30 fps; in-place, burnt.gd moves it and sets each clip's speed from how fast it goes):
    idle      4 s loop    stood dead still, hunched; breath you can barely see
    walk      2.6 s loop  the stalk: heavy, long strides that linger on the footfall and snap through
    run       0.87 s loop the charge: folded forward, thrown off its toes, arms trailing and flailing
    crouch    0.9 s       the set before it runs (holds its last frame)
    skid      0.67 s      thrown back on its heels, feet out in front (holds its last frame)
    heave     2 s loop    stood after the skid, the chest heaving
    windup    0.45 s      the tell before it takes you: draws back, then folds over you
    peek_r    1.6 s       behind a wall, its right hand curls round the edge and it leans out past it (holds)
    peek_l    1.6 s       the same round an edge on its left
    peek_r_hold / peek_l_hold  3 s loops: hanging there, fingers working on the edge, head cocked
    kill      12.5 s      face on: grab 0.7 / lift 6.0 / stare 3.4 / corrupt 2.4 (burnt.gd's timings). Its hands
                          hold you: burnt.gd puts the camera between them
"""
import bpy
import math
from mathutils import Matrix, Quaternion, Vector

SRC = r"C:\Users\alhyu\Documents\GitHub\godot-backrooms\godot-backrooms\models\entities\burnt\theburnt.glb"
OUT = r"C:\Users\alhyu\Documents\GitHub\godot-backrooms\godot-backrooms\models\entities\burnt\theburnt_animated.glb"
FPS = 30
U = 0.978 / 4.5                     # one game metre in model units
X = Vector((1, 0, 0))               # pitch: + folds forward (top toward -Y)
Y = Vector((0, 1, 0))               # roll about the facing axis
Z = Vector((0, 0, 1))               # yaw: + turns its face toward +X (its left)
FWD = Vector((0, -1, 0))
RIGHT = Vector((-1, 0, 0))

arm = None
rest = {}                           # bone -> armature-space rest rotation
head0 = {}                          # bone -> armature-space rest head
ctl = {}                            # control empties


def q(axis, ang):
    return Quaternion(axis, ang)


def ease(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def ease5(x):
    x = min(1.0, max(0.0, x))
    return x * x * x * (x * (x * 6 - 15) + 10)


def lerp(a, b, t):
    return a + (b - a) * t


# ---------------------------------------------------------------- setup
def load():
    global arm
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    rest.clear()
    head0.clear()
    ctl.clear()
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)
    bpy.ops.import_scene.gltf(filepath=SRC)
    for o in list(bpy.data.objects):
        if o.type == 'MESH' and o.parent is None:
            bpy.data.objects.remove(o, do_unlink=True)     # the importer's bone-shape icosphere
    arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
    scn = bpy.context.scene
    scn.render.fps = FPS
    bpy.context.view_layer.objects.active = arm
    arm.select_set(True)
    # stretch the half-length limb bones to their next joint (colinear: the rest frames don't change)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.data.edit_bones
    for s in ("L_", "R_"):
        for a, b in (("Thigh", "Calf"), ("Calf", "Foot"), ("Upperarm", "Forearm"), ("Forearm", "Hand")):
            bone, nxt = eb[s + a], eb[s + b]
            roll = bone.roll
            bone.tail = nxt.head.copy()
            bone.roll = roll
    bpy.ops.object.mode_set(mode='POSE')
    for b in arm.data.bones:
        rest[b.name] = b.matrix_local.to_quaternion()
        head0[b.name] = b.head_local.copy()
    for pb in arm.pose.bones:
        pb.rotation_mode = 'QUATERNION'
    build_rig()


def empty(name, at, rot=None):
    e = bpy.data.objects.new(name, None)
    e.empty_display_size = 0.02
    bpy.context.scene.collection.objects.link(e)
    e.location = at
    e.rotation_mode = 'QUATERNION'
    if rot is not None:
        e.rotation_quaternion = rot
    return e


def pole_angle(pb, target_bone):
    """The pole angle that leaves the chain where it rests (brute force, to the degree)"""
    c = pb.constraints["IK"]
    want = arm.matrix_world @ arm.data.bones[pb.name].head_local
    best = (1e9, 0.0)
    for deg in range(-180, 180, 2):
        c.pole_angle = math.radians(deg)
        bpy.context.view_layer.update()
        err = (arm.matrix_world @ pb.head - want).length
        if err < best[0]:
            best = (err, deg)
    for deg in [best[1] + d * 0.25 for d in range(-8, 9)]:
        c.pole_angle = math.radians(deg)
        bpy.context.view_layer.update()
        err = (arm.matrix_world @ pb.head - want).length
        if err < best[0]:
            best = (err, deg)
    c.pole_angle = math.radians(best[1])
    return best


def build_rig():
    P = arm.pose.bones
    for s, sx in (("R", -1.0), ("L", 1.0)):
        # legs: IK on the calf to the ankle, the knee aimed ahead; the foot copies its target's turn
        foot = s + "_Foot"
        ctl[foot] = empty("T_" + foot, head0[foot], rest[foot])
        knee = head0[s + "_Calf"]
        ctl[s + "_Knee"] = empty("P_" + s + "_Knee", knee + FWD * 0.3)
        c = P[s + "_Calf"].constraints.new('IK')
        c.name = "IK"
        c.target = ctl[foot]
        c.pole_target = ctl[s + "_Knee"]
        c.chain_count = 2
        c.use_stretch = False
        cr = P[foot].constraints.new('COPY_ROTATION')
        cr.name = "Rot"
        cr.target = ctl[foot]
        # arms: IK on the forearm to the wrist, the elbow aimed back and out; off (influence 0) unless keyed on
        hand = s + "_Hand"
        ctl[hand] = empty("T_" + hand, head0[hand], rest[hand])
        elbow = head0[s + "_Forearm"]
        ctl[s + "_Elbow"] = empty("P_" + s + "_Elbow", elbow + Vector((sx * 0.15, 0.3, 0)))
        c = P[s + "_Forearm"].constraints.new('IK')
        c.name = "IK"
        c.target = ctl[hand]
        c.pole_target = ctl[s + "_Elbow"]
        c.chain_count = 2
        c.use_stretch = False
        cr = P[hand].constraints.new('COPY_ROTATION')
        cr.name = "Rot"
        cr.target = ctl[hand]
    bpy.context.view_layer.update()
    for s in ("R", "L"):
        print(s, "knee pole", pole_angle(P[s + "_Calf"], s + "_Foot"), "elbow pole", pole_angle(P[s + "_Forearm"], s + "_Hand"))


# ---------------------------------------------------------------- keying
FINGERS = ("Thumb", "Index", "Mid", "Ring", "Pinky")


CURL_SIGN = {"R": 1.0, "L": -1.0}


def curl_axis(s):
    """The axis a hand's fingers fold about (across the knuckles, signed so + closes the fist) and the palm's
    normal (what they spread about), in armature space"""
    ax = (head0[s + "_Index1"] - head0[s + "_Pinky1"]).normalized() * CURL_SIGN[s]
    fing = (arm.data.bones[s + "_Mid1"].tail_local - head0[s + "_Mid1"]).normalized()
    return ax, ax.cross(fing).normalized()


class Pose:
    """One key: every control set from scratch (unset = rest), then written at `frame`"""

    def __init__(self):
        self.rot = {}                  # bone -> armature-space quaternion (FK, relative to rest)
        self.hip = Vector()            # Hip offset, armature space
        self.foot = {}                 # "R"/"L" -> (ankle pos, quaternion delta)
        self.hand = {}                 # "R"/"L" -> (wrist pos, quaternion delta) when the arm is on IK
        self.knee = {}
        self.elbow = {}
        self.curl = {"R": [0.25] * 5, "L": [0.25] * 5}   # 0 open .. 1 fist, per finger
        self.spread = {"R": 0.0, "L": 0.0}

    def turn(self, bone, *rots):
        r = self.rot.get(bone, Quaternion())
        for axis, ang in rots:
            r = q(axis, ang) @ r
        self.rot[bone] = r
        return self


def key(p: Pose, frame: int):
    P = arm.pose.bones
    for pb in P:
        if pb.name in ("Hip",):
            continue
        r = p.rot.get(pb.name)
        if r is None and any(f in pb.name for f in FINGERS):
            continue                   # (fingers keyed below)
        pb.rotation_quaternion = (rest[pb.name].inverted() @ r @ rest[pb.name]) if r else Quaternion()
        pb.location = Vector()
        pb.keyframe_insert("rotation_quaternion", frame=frame)
    hip = P["Hip"]
    hip.location = rest["Hip"].inverted() @ p.hip
    r = p.rot.get("Hip", Quaternion())
    hip.rotation_quaternion = rest["Hip"].inverted() @ r @ rest["Hip"]
    hip.keyframe_insert("location", frame=frame)
    hip.keyframe_insert("rotation_quaternion", frame=frame)
    for s in ("R", "L"):
        at, d = p.foot.get(s, (head0[s + "_Foot"], Quaternion()))
        e = ctl[s + "_Foot"]
        e.location = at
        e.rotation_quaternion = d @ rest[s + "_Foot"]
        e.keyframe_insert("location", frame=frame)
        e.keyframe_insert("rotation_quaternion", frame=frame)
        k = ctl[s + "_Knee"]
        k.location = p.knee.get(s, head0[s + "_Calf"] + p.hip + FWD * 0.3)
        k.keyframe_insert("location", frame=frame)
        on = s in p.hand
        for b in (s + "_Forearm", s + "_Hand"):
            c = P[b].constraints["IK" if b.endswith("arm") else "Rot"]
            c.influence = 1.0 if on else 0.0
            c.keyframe_insert("influence", frame=frame)
        if on:
            at, d = p.hand[s]
            e = ctl[s + "_Hand"]
            e.location = at
            e.rotation_quaternion = d @ rest[s + "_Hand"]
            e.keyframe_insert("location", frame=frame)
            e.keyframe_insert("rotation_quaternion", frame=frame)
            el = ctl[s + "_Elbow"]
            sx = -1.0 if s == "R" else 1.0
            el.location = p.elbow.get(s, head0[s + "_Forearm"] + Vector((sx * 0.15, 0.3, 0)))
            el.keyframe_insert("location", frame=frame)
        # fingers: each joint folds about the knuckle line; the thumb about its own, less
        ax, nrm = curl_axis(s)
        for i, f in enumerate(FINGERS):
            c = p.curl[s][i]
            for j in (1, 2, 3):
                b = "%s_%s%d" % (s, f, j)
                if b not in P:
                    continue
                ang = c * (0.55 if f == "Thumb" else (1.1, 1.3, 0.9)[j - 1])
                rr = q(ax, ang)
                if j == 1 and f != "Thumb":
                    rr = q(nrm, p.spread[s] * (i - 2.5) * 0.12) @ rr
                pb = P[b]
                pb.rotation_quaternion = rest[b].inverted() @ rr @ rest[b]
                pb.keyframe_insert("rotation_quaternion", frame=frame)


def begin(name, frames):
    """A fresh action on the armature and every control, for the clip's source keys"""
    scn = bpy.context.scene
    scn.frame_start = 0
    scn.frame_end = frames
    for o in [arm] + list(ctl.values()):
        o.animation_data_create()
        o.animation_data.action = bpy.data.actions.new("src_" + name + "_" + o.name)


def bake(name, frames):
    """Bake the clip down to bone keys (visual: constraints applied), then drop the source keys. Every clip is
    keyed on every frame from its own function of time, so a loop's last frame is its first again"""
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='POSE')
    bpy.ops.pose.select_all(action='SELECT')
    bpy.ops.nla.bake(frame_start=0, frame_end=frames, only_selected=True, visual_keying=True,
                     clear_constraints=False, clear_parents=False, use_current_action=False,
                     bake_types={'POSE'})
    act = arm.animation_data.action
    act.name = name
    act.use_fake_user = True
    arm.animation_data.action = None
    for o in list(ctl.values()):
        o.animation_data.action = None
    for a in list(bpy.data.actions):
        if a.name.startswith("src_"):
            bpy.data.actions.remove(a)
    return act


# ---------------------------------------------------------------- shared posture
def wave(u, at):
    """cos peaking (1) at phase `at` (cycles)"""
    return math.cos(2 * math.pi * (u - at))


def hunch(p: Pose, amt=1.0, head_comp=1.0):
    """Its resting posture: the back rounded forward, the shoulders rolled in and dropped, the head pushed out
    and tipped up to keep its eyes level, cocked a little to one side"""
    p.turn("Waist", (X, 0.10 * amt))
    p.turn("Spine01", (X, 0.17 * amt))
    p.turn("Spine02", (X, 0.22 * amt))
    p.turn("NeckTwist01", (X, 0.22 * amt))
    p.turn("Head", (X, -0.55 * amt * head_comp), (Y, 0.09))
    p.turn("R_Clavicle", (Z, 0.2 * amt), (Y, 0.08 * amt))
    p.turn("L_Clavicle", (Z, -0.2 * amt), (Y, -0.08 * amt))
    p.hip = Vector((0, 0.012 * amt, -0.035 * amt))     # (the hips sit back under the folded trunk, knees bent)


def hang_arms(p: Pose, swing_r=0.0, swing_l=0.0, out=0.06, bend=0.15):
    """Arms hanging dead from the shoulders: + swing brings the hand forward; the elbow gives as it does"""
    for s, sw, sx in (("R", swing_r, 1.0), ("L", swing_l, -1.0)):
        p.turn(s + "_Upperarm", (X, -sw), (Y, out * sx))
        p.turn(s + "_Forearm", (X, -(bend + 0.35 * max(0.0, sw))))
        p.turn(s + "_Hand", (X, -0.12))


def foot_at(s, fwd=0.0, up=0.0, side=0.0, pitch=0.0):
    """Ankle `fwd` ahead of where it rests (model units), `up` off the floor; + pitch lifts the heel"""
    a = head0[s + "_Foot"] + FWD * fwd + Z * up + RIGHT * side
    return (a, q(X, pitch))


def gait_foot(v, duty, stride, lift, snap=1.0):
    """One foot over its cycle v (0..1, 0 = heel strike): (fwd, up, pitch). Stance slides it back at a constant
    speed (the ground going by); the swing carries it forward on an arc"""
    if v < duty:
        k = v / duty
        fwd = lerp(stride / 2, -stride / 2, k)
        heel = ease((k - 0.68) / 0.32) * 0.5          # heel off, rolling onto the toes
        strike = (1.0 - ease(k / 0.14)) * -0.22        # toes up as the heel lands
        return fwd, 0.075 * math.sin(max(0.0, heel)), heel + strike
    k = (v - duty) / (1 - duty)
    pk = ease5(k) if snap >= 1.0 else lerp(k, ease5(k), snap)
    fwd = lerp(-stride / 2, stride / 2, pk)
    up = lift * math.sin(math.pi * min(1.0, k * 1.15)) ** 0.8 + 0.075 * math.sin(0.5) * (1 - ease(k / 0.3))
    pitch = lerp(0.5, -0.22, ease(k / 0.85))
    return fwd, up, pitch


# ---------------------------------------------------------------- clips
WALK_N = 78                 # 2.6 s
WALK_STRIDE = 0.5           # model units each foot slides back over its stance (burnt.gd: WALK_CLIP_SPEED)
WALK_DUTY = 0.64
WALK_PH = {"R": 0.0, "L": 0.53}     # not quite opposite: the left step comes a beat late


def walk_pose(u):
    p = Pose()
    hunch(p)
    v = {s: (u - WALK_PH[s]) % 1.0 for s in "RL"}
    for s in "RL":
        f, up, pitch = gait_foot(v[s], WALK_DUTY, WALK_STRIDE * (1.0 if s == "R" else 0.9), 0.045)
        p.foot[s] = foot_at(s, f, up, 0.006 if s == "R" else -0.006, pitch)
    # the weight comes down on each footfall (a dip just after the strike) and rides up over the planted leg
    land = sum(math.exp(-((v[s] - 0.07) / 0.06) ** 2) for s in "RL")
    p.hip += Vector((-0.012 * wave(u, 0.30), 0, 0.009 * math.cos(4 * math.pi * (u - 0.30)) - 0.014 * land))
    # the pelvis turns with the swinging leg and drops on its side; the chest turns back against it, late
    tw = wave(u, 0.82)
    p.turn("Hip", (Z, 0.07 * tw), (Y, -0.045 * tw))
    lag = wave(u, 0.82 + 0.09)
    p.turn("Spine01", (Z, -0.05 * lag), (Y, 0.04 * lag))
    p.turn("Spine02", (Z, -0.04 * lag), (Y, 0.05 * lag))
    p.turn("Head", (Y, -0.05 * lag), (X, 0.04 * land))          # the head nods down on the landing, late
    # arms: dead weight, swung by the body (opposite the legs, a quarter beat late); the left barely moves
    hang_arms(p, 0.13 * wave(u, 0.35 + 0.08), 0.07 * wave(u, 0.85 + 0.1), bend=0.18)
    p.curl["R"] = [0.25, 0.35, 0.45, 0.55, 0.6]
    p.curl["L"] = [0.2, 0.5, 0.35, 0.6, 0.45]
    return p


def make_loop(name, n, fn):
    begin(name, n)
    for f in range(n + 1):
        key(fn((f % n) / n), f)
    return bake(name, n)


def show(name):
    """Play a baked clip on the bare skeleton (the control rig switched off), to look at"""
    for pb in arm.pose.bones:
        for c in pb.constraints:
            c.mute = True
    arm.animation_data_create()
    arm.animation_data.action = bpy.data.actions[name]
    if hasattr(arm.animation_data, "action_slot") and arm.animation_data.action_suitable_slots:
        arm.animation_data.action_slot = arm.animation_data.action_suitable_slots[0]
    r = bpy.data.actions[name].frame_range
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = int(r[0]), int(r[1])


def unshow():
    for pb in arm.pose.bones:
        for c in pb.constraints:
            c.mute = False
    if arm.animation_data:
        arm.animation_data.action = None


def mirror_q(r):
    """A turn reflected across the figure's midline (x -> -x)"""
    return Quaternion((r.w, r.x, -r.y, -r.z))


def stand_feet(p: Pose, r_fwd=0.02, l_fwd=-0.03, wide=0.015, l_heel=0.0):
    p.foot["R"] = foot_at("R", r_fwd, 0.0, wide)
    p.foot["L"] = foot_at("L", l_fwd, 0.075 * math.sin(l_heel), -wide, l_heel)


IDLE_N = 120


def idle_pose(u):
    """Dead still. One slow breath in four seconds, and once, a finger curling and letting go"""
    p = Pose()
    hunch(p)
    stand_feet(p)
    b = math.sin(2 * math.pi * u)
    p.turn("Spine02", (X, -0.02 * b))
    p.turn("Head", (X, 0.012 * b))
    p.hip += Vector((0, 0, 0.002 * b))
    hang_arms(p, 0.03, -0.02, bend=0.2)
    tw = math.exp(-((u - 0.6) / 0.025) ** 2)
    p.curl["R"] = [0.25, 0.35 + 0.5 * tw, 0.45, 0.55, 0.6]
    p.curl["L"] = [0.2, 0.5, 0.35, 0.6, 0.45]
    return p


RUN_N = 26                  # 0.87 s
RUN_STRIDE = 0.7
RUN_DUTY = 0.34
RUN_PH = {"R": 0.0, "L": 0.5}


def run_pose(u):
    """The charge. Pitched far forward and falling after itself, thrown off its toes, its feet kicking up
    behind; the arms trail back from the shoulders and flail loose, each to its own beat; the head hangs over"""
    p = Pose()
    hunch(p, 1.2, head_comp=1.6)
    v = {s: (u - RUN_PH[s]) % 1.0 for s in "RL"}
    comp = 0.0
    for s in "RL":
        vs = v[s]
        if vs < RUN_DUTY:
            k = vs / RUN_DUTY
            f = lerp(RUN_STRIDE / 2 * 0.6, -RUN_STRIDE / 2, k)
            pitch = lerp(-0.1, 0.7, ease((k - 0.4) / 0.6))
            up = 0.075 * math.sin(max(0.0, pitch)) * ease((k - 0.4) / 0.6)
            comp += math.sin(math.pi * k)
        else:
            k = (vs - RUN_DUTY) / (1 - RUN_DUTY)
            f = lerp(-RUN_STRIDE / 2, RUN_STRIDE / 2 * 0.6, ease5(k))
            up = 0.11 * math.sin(math.pi * k) + 0.09 * math.sin(math.pi * min(1.0, k / 0.55)) * (1 - k)
            pitch = lerp(0.9, -0.1, ease(k / 0.9))
        p.foot[s] = foot_at(s, f, up, 0.0, pitch)
        p.knee[s] = head0[s + "_Calf"] + FWD * 0.4 + Z * 0.05
    p.hip += Vector((0.008 * wave(u, 0.17), -0.03, -0.035 - 0.03 * comp + 0.012))
    p.turn("Hip", (X, 0.32), (Z, 0.1 * wave(u, 0.67)), (Y, -0.05 * wave(u, 0.67)))
    p.turn("Spine01", (X, 0.12), (Z, -0.09 * wave(u, 0.75)))
    p.turn("Spine02", (X, 0.1), (Z, -0.07 * wave(u, 0.8)), (Y, 0.06 * wave(u, 0.8)))
    p.turn("Head", (Y, 0.38 + 0.05 * math.sin(4 * math.pi * u + 0.5)), (X, 0.06 * math.cos(4 * math.pi * u)))
    # the arms: thrown back behind it, loose, each flapping on its own (whole harmonics so the loop closes)
    r = -0.62 + 0.34 * wave(u, 0.05) + 0.1 * math.sin(4 * math.pi * u + 0.7)
    l = -0.55 + 0.38 * wave(u, 0.6) + 0.12 * math.sin(6 * math.pi * u + 1.3)
    hang_arms(p, r, l, out=0.3, bend=0.0)
    p.turn("R_Forearm", (X, -0.35 - 0.3 * wave(u, 0.2)))
    p.turn("L_Forearm", (X, -0.25 - 0.35 * wave(u, 0.78)))
    p.turn("R_Hand", (X, 0.35 * wave(u, 0.3)))
    p.turn("L_Hand", (X, 0.4 * wave(u, 0.85)))
    p.curl["R"] = [0.05, 0.05, 0.1, 0.15, 0.1]
    p.curl["L"] = [0.1, 0.0, 0.05, 0.1, 0.2]
    p.spread = {"R": 1.0, "L": 1.2}
    return p


def blend(a: Pose, b: Pose, t):
    """Pose a -> b at t (FK by slerp, positions by lerp). An arm on IK in only one of them switches at t 0.5"""
    p = Pose()
    for n in set(a.rot) | set(b.rot):
        p.rot[n] = a.rot.get(n, Quaternion()).slerp(b.rot.get(n, Quaternion()), t)
    p.hip = a.hip.lerp(b.hip, t)
    for s in "RL":
        fa = a.foot.get(s, (head0[s + "_Foot"], Quaternion()))
        fb = b.foot.get(s, (head0[s + "_Foot"], Quaternion()))
        p.foot[s] = (fa[0].lerp(fb[0], t), fa[1].slerp(fb[1], t))
        if s in a.knee or s in b.knee:
            ka = a.knee.get(s, head0[s + "_Calf"] + a.hip + FWD * 0.3)
            kb = b.knee.get(s, head0[s + "_Calf"] + b.hip + FWD * 0.3)
            p.knee[s] = ka.lerp(kb, t)
        p.curl[s] = [lerp(x, y, t) for x, y in zip(a.curl[s], b.curl[s])]
        p.spread[s] = lerp(a.spread[s], b.spread[s], t)
        if s in a.hand and s in b.hand:
            p.hand[s] = (a.hand[s][0].lerp(b.hand[s][0], t), a.hand[s][1].slerp(b.hand[s][1], t))
            ea = a.elbow.get(s, head0[s + "_Forearm"])
            eb = b.elbow.get(s, head0[s + "_Forearm"])
            p.elbow[s] = ea.lerp(eb, t)
        else:
            src = a if t < 0.5 else b
            if s in src.hand:
                p.hand[s] = src.hand[s]
                if s in src.elbow:
                    p.elbow[s] = src.elbow[s]
    return p


def crouch_end():
    """The set: dropped low and staggered, folded right over, arms drawn back, its face up at you"""
    p = Pose()
    hunch(p, 1.0, head_comp=2.2)
    p.hip += Vector((0, 0.05, -0.1))
    p.turn("Hip", (X, 0.35))
    p.turn("Spine01", (X, 0.2))
    p.turn("Spine02", (X, 0.1))
    p.foot["R"] = foot_at("R", 0.07, 0.0, 0.01)
    p.foot["L"] = foot_at("L", -0.12, 0.075 * math.sin(0.6), -0.015, 0.6)
    p.knee = {"R": head0["R_Calf"] + FWD * 0.4, "L": head0["L_Calf"] + FWD * 0.4 + Z * -0.1}
    hang_arms(p, -0.75, -0.6, out=0.2, bend=0.15)
    p.curl["R"] = [0.3, 0.6, 0.7, 0.75, 0.8]
    p.curl["L"] = [0.3, 0.7, 0.6, 0.8, 0.7]
    return p


def make_crouch():
    n = 27
    begin("crouch", n)
    a, b = idle_pose(0.0), crouch_end()
    for f in range(n + 1):
        k = f / n
        p = blend(a, b, ease5(k / 0.6))                  # drops fast...
        inhale = ease((k - 0.55) / 0.45)                 # ...then draws breath, the chest and shoulders rising
        p.turn("Spine02", (X, -0.07 * inhale))
        p.turn("R_Clavicle", (X, -0.08 * inhale))
        p.turn("L_Clavicle", (X, -0.08 * inhale))
        key(p, f)
    return bake("crouch", n)


def skid_end():
    """Thrown back on its heels, the front foot dug in, the arms flung out behind"""
    p = Pose()
    hunch(p, 0.6, head_comp=0.8)
    p.hip += Vector((0, 0.07, -0.09))
    p.turn("Hip", (X, -0.12))
    p.turn("Spine02", (X, -0.08))
    p.foot["R"] = foot_at("R", 0.2, 0.0, 0.01, -0.45)
    p.foot["L"] = foot_at("L", 0.0, 0.0, -0.02, 0.0)
    p.knee = {"R": head0["R_Calf"] + FWD * 0.4, "L": head0["L_Calf"] + FWD * 0.4}
    hang_arms(p, -0.9, -0.75, out=0.45, bend=0.25)
    p.curl["R"] = [0.0, 0.0, 0.05, 0.1, 0.1]
    p.curl["L"] = [0.0, 0.05, 0.0, 0.1, 0.15]
    p.spread = {"R": 1.3, "L": 1.1}
    return p


def make_skid():
    n = 20
    begin("skid", n)
    a, b = run_pose(0.15), skid_end()
    for f in range(n + 1):
        k = f / n
        t = ease5(k / 0.45)
        over = 0.12 * math.sin(math.pi * ease((k - 0.4) / 0.6))    # rocks past the stop and back
        p = blend(a, b, t)
        p.turn("Spine01", (X, over))
        p.turn("Spine02", (X, over))
        key(p, f)
    return bake("skid", n)


HEAVE_N = 60


def heave_pose(u):
    """Stood where the skid ended, sunk and heaving: two great breaths in two seconds, the shoulders riding up"""
    p = Pose()
    hunch(p, 1.3)
    stand_feet(p, 0.07, -0.05, 0.025)
    b = math.sin(4 * math.pi * u) * 0.5 + 0.5
    p.hip += Vector((0, 0.01, -0.03 + 0.006 * b))
    p.turn("Spine01", (X, -0.04 * b))
    p.turn("Spine02", (X, -0.08 * b))
    p.turn("NeckTwist01", (X, 0.05 * b))
    p.turn("R_Clavicle", (X, -0.12 * b))
    p.turn("L_Clavicle", (X, -0.12 * b))
    hang_arms(p, 0.05 + 0.03 * b, 0.02 + 0.04 * math.sin(4 * math.pi * u - 0.6), out=0.1, bend=0.2)
    p.curl["R"] = [0.3, 0.6, 0.65, 0.7, 0.8]
    p.curl["L"] = [0.25, 0.55, 0.6, 0.7, 0.75]
    return p


def make_windup():
    """The tell: from stood, it draws back (0.18 s), then folds forward over you, the arms dropping to hang"""
    n = 14
    begin("windup", n)
    for f in range(n + 1):
        k = f / n
        back = ease(k / 0.4)
        go = ease((k - 0.4) / 0.6) ** 2
        coil = lerp(-0.25, 1.0, go) * 0.45 if k >= 0.4 else -0.25 * 0.45 * back
        draw = lerp(0.45, 0.0, go) if k >= 0.4 else 0.45 * back
        p = idle_pose(0.0)
        p.turn("Spine01", (X, coil * 0.5))
        p.turn("Spine02", (X, coil * 0.5))
        p.turn("Head", (X, -coil * 0.4))
        p.turn("R_Upperarm", (X, draw))
        p.turn("L_Upperarm", (X, draw))
        p.hip += Vector((0, 0.02 * coil, -0.02 * max(0.0, coil)))
        key(p, f)
    return bake("windup", n)


# ---------------------------------------------------------------- the peek round a wall edge
# The wall stands across in front of it, its edge on the near side (`m` +1: its right, -1: its left). Model space:
EDGE_X = 0.16               # the edge's distance off its midline
EDGE_Y = -0.15              # the wall's face, ahead of it (clear of its toes)
GRIP_Z = 0.54               # how high its hand curls round the edge: low, under its chin (higher, the arm goes
                            # through the head as it leans out under it)
PEEK_IN_N = 48
PEEK_HOLD_N = 90


def peek_pose(m, reach, grip, lean, cock, u=0.0):
    """reach 0..1 the near hand up from hanging to the edge; grip 0..1 its fingers round it; lean 0..1 the
    trunk out past the edge; cock 0..1 the head turned over on its side. u: the hold's own little motions"""
    S, O = ("R", "L") if m > 0 else ("L", "R")
    sx = -m                                                  # the sign of x on its near side
    p = Pose()
    hunch(p, 0.75)
    b = math.sin(2 * math.pi * u)
    # it sidles toward the edge, its weight over the near foot, and the trunk leans out past it
    L = ease5(lean)
    p.hip += Vector((sx * 0.045 * L, 0, -0.012 * L))
    p.turn("Waist", (Y, -m * 0.18 * L))
    p.turn("Spine01", (Y, -m * 0.28 * L), (Z, m * 0.05 * L))
    p.turn("Spine02", (Y, -m * (0.3 + 0.012 * b) * L), (Z, m * 0.08 * L))
    p.turn("NeckTwist01", (Y, -m * 0.3 * L), (X, -0.06 * L))
    # the head: laid over on its side, nearly flat, looking round the edge (burnt.gd turns it on to you)
    C = ease5(cock)
    p.turn("Head", (Y, -m * (1.05 + 0.03 * math.sin(4 * math.pi * u)) * C), (Z, -m * 0.25 * C))
    p.foot[S] = foot_at(S, 0.02, 0.0, 0.075 * L * m)
    p.foot[O] = foot_at(O, -0.04, 0.075 * math.sin(0.5 * L), 0.03 * L * m, 0.5 * L)
    # the near hand: hanging (reach 0) -> up past its face -> knuckles on the edge, the palm on the wall's
    # face and the fingers wrapped round onto the side of it
    shoulder = head0[S + "_Upperarm"]
    hang = shoulder + Vector((0.0, -0.02, -0.36))
    edge = Vector((sx * EDGE_X, EDGE_Y, GRIP_Z))
    wrist = edge + Vector((-sx * (0.062 if m > 0 else 0.052), 0.016, 0.0))     # (the left hand is a little shorter)
    R = ease5(reach)
    arc = Vector((sx * 0.06, 0.02, 0.0)) * math.sin(math.pi * R)   # it swings out, not straight
    at = hang.lerp(wrist, R) + arc
    turn_to = q(X, math.radians(-90)) @ q(Y, math.radians(90))      # fingers out to the side, palm to the wall
    if m < 0:
        turn_to = mirror_q(turn_to)
    p.hand[S] = (at, Quaternion().slerp(turn_to, ease(reach * 1.3)))
    p.elbow[S] = shoulder + Vector((sx * 0.1, 0.3, -0.12))              # back, tucked behind the edge, low
    g = ease(grip)
    knead = [0.04 * math.sin(2 * math.pi * (u * k + 0.2 * i)) for i, k in enumerate((1, 2, 1, 3, 2))]
    p.curl[S] = [lerp(0.0, 0.15, g)] + [lerp(0.0, 0.5, g) + knead[i] * g for i in range(1, 5)]   # ~90 deg: round the corner
    p.spread[S] = lerp(1.2, 0.2, g)
    # the far hand flat on the wall's face, lower, fingers spread
    far = Vector((-sx * 0.07, EDGE_Y + 0.035, 0.55))                   # (off the face: its fingertips must not show through)
    flat = q(Z, math.radians(90 * m)) @ q(Y, math.radians(180))
    hang_o = head0[O + "_Upperarm"] + Vector((0.0, -0.02, -0.36))
    F = ease5(min(1.0, reach * 1.2))
    p.hand[O] = (hang_o.lerp(far, F), Quaternion().slerp(flat, F))
    p.elbow[O] = head0[O + "_Upperarm"] + Vector((-sx * 0.25, 0.15, -0.1))
    p.curl[O] = [0.1, 0.1 * F, 0.05, 0.1 * F, 0.15]
    p.spread[O] = 1.4 * F
    return p


def make_peek(m):
    nm = "peek_r" if m > 0 else "peek_l"
    begin(nm, PEEK_IN_N)
    for f in range(PEEK_IN_N + 1):
        s = f / 30.0
        reach = ease(s / 0.55)
        grip = ease((s - 0.45) / 0.2)
        lean = ease((s - 0.55) / 0.95)
        cock = ease((s - 1.05) / 0.5)
        key(peek_pose(m, reach, grip, lean, cock), f)
    bake(nm, PEEK_IN_N)
    make_loop(nm + "_hold", PEEK_HOLD_N, lambda u: peek_pose(m, 1.0, 1.0, 1.0, 1.0, u))


# ---------------------------------------------------------------- the kill
# burnt.gd's sequence, face on: grab / lift / stare / corrupt. The victim is held by the chest between its hands
# (palms in, fingers forward round your ribs); burnt.gd puts the camera at the wrists' midpoint, KILL_EYE above it.
KILL_T = (0.7, 6.0, 3.4, 2.4)
KILL_N = int(round(sum(KILL_T) * FPS))         # 375
KILL_EYE = 0.06                                 # model units from the grip up to your eyes
V_GRAB = Vector((0.0, -0.21, 0.41))             # where it takes you: a metre and more in front, off your feet
V_LIFT = Vector((0.0, -0.31, 0.80))             # raised to its face: your eyes level with its, ~0.9 m off
V_STARE = Vector((0.0, -0.28, 0.77))            # drawn in to ~0.4 m (its face leans in to meet you)
V_END = Vector((0.0, -0.285, 0.76))             # (the last lunge is its head, not you)


def back_out(x):
    """ease-out-back: overshoots a little and settles (the snap of its arms)"""
    x = min(1.0, max(0.0, x)) - 1.0
    return 1.0 + 2.70158 * x * x * x + 1.70158 * x * x


def kill_pose(t):
    g, lf, st, co = KILL_T
    t1, t2, t3 = g, g + lf, g + lf + st
    p = Pose()
    # where you are: snatched (0.3 s) to V_GRAB, raised the length of it to its face (smootherstep over the lift),
    # then pulled in to it, stopping dead for 0.4 s two seconds into the stare, and last, yanked right up to it
    if t < t1:
        v = V_GRAB.copy()
    elif t < t2:
        v = V_GRAB.lerp(V_LIFT, ease5((t - t1) / lf))
        v.z += 0.004 * math.sin((t - t1) * 2.2)                        # its breathing, heaving you
    elif t < t3:
        s = t - t2
        held = s if s < 2.0 else (2.0 if s < 2.4 else s - 0.4)
        v = V_LIFT.lerp(V_STARE, ease(held / (st - 0.4)))
    else:
        k = (t - t3) / co
        v = V_STARE.lerp(V_END, ease(k))
    # the body: lunges over you on the grab and settles into a stoop; straightens under your weight as it
    # lifts; leans in as it studies you
    lunge = 0.3 * math.exp(-((t - 0.2) / 0.13) ** 2)
    up = ease((t - t1) / lf)
    lean_in = 0.12 * ease((t - t2) / st) + 0.08 * ease((t - t3) / co)
    hunch(p, lerp(1.0, 0.55, up), head_comp=1.0)
    stand_feet(p, 0.04 + 0.05 * ease(t / 0.2), -0.03, 0.025)
    p.turn("Hip", (X, 0.1 + lunge + lean_in - 0.05 * up))
    breath = math.sin(t * 2.2) if t < t2 else math.sin(t * 1.3) * 0.4
    p.turn("Spine02", (X, -0.03 * breath))
    p.turn("R_Clavicle", (X, -0.05 * breath - 0.15 * up))
    p.turn("L_Clavicle", (X, -0.05 * breath - 0.15 * up))
    # the head: looking down at you, then level with you as you come up; held, it tips over, slowly (one sharp
    # tick at the pause), and at the end it shakes, draws back, and comes at you
    look_down = 0.45 * (1.0 - up)
    tilt = 0.38 * ease((t - t2 - 1.2) / (st - 1.2)) + 0.12 * ease((t - t3) / co)
    tick = 0.13 * ease((t - t2 - 2.0) / 0.08) * (1.0 - ease((t - t3) / 0.6))
    shake = 0.0
    pull = 0.0
    if t >= t3:
        k = (t - t3) / co
        shake = (0.02 + 0.05 * k) * (math.sin(t * 71.0) + 0.6 * math.sin(t * 113.0 + 1.0))
        pull = -0.3 * ease((k - 0.6) / 0.25) + 0.55 * ease((k - 0.9) / 0.06)
    p.turn("NeckTwist01", (X, 0.15 * lean_in / 0.2 + pull * 0.4))
    p.turn("Head", (X, look_down + pull * 0.6 + shake * 0.5), (Y, -(tilt + tick) + shake), (Z, shake * 0.7))
    # the hands: from hanging, snapped round you (0.3 s, overshooting), then wherever you are
    snap = back_out(t / 0.3)
    squeeze = 0.006 * ease((t - t3) / co)
    for s, sx in (("R", -1.0), ("L", 1.0)):
        grip = v + Vector((sx * (0.052 - squeeze), 0.035, 0.0))
        hang = head0[s + "_Upperarm"] + Vector((0.0, -0.09, -0.34))
        at = hang.lerp(grip, snap)
        trem = 0.0015 * math.sin(t * 31.0 + (0 if s == "R" else 2.0)) * ease((t - t1) / 1.0)
        at += Vector((trem, 0.0, trem))
        p.hand[s] = (at, Quaternion().slerp(q(X, math.radians(-90)), min(1.0, snap)))
        p.elbow[s] = Vector((sx * 0.4, at.y + 0.12, at.z - 0.12))
        c = lerp(0.1, 0.55, ease(t / 0.3)) + 0.3 * ease((t - t3) / co)
        c += 0.04 * math.sin(t * 17.0 + len(s)) * ease((t - t2) / st)
        p.curl[s] = [c * 0.6, c, c * 1.05, c * 1.1, c * 1.15]
        p.spread[s] = lerp(1.2, 0.5, ease(t / 0.3))
    return p


def make_kill():
    begin("kill", KILL_N)
    for f in range(KILL_N + 1):
        key(kill_pose(f / FPS), f)
    return bake("kill", KILL_N)


# ---------------------------------------------------------------- all of it
def build_all():
    load()
    make_loop("idle", IDLE_N, idle_pose)
    make_loop("walk", WALK_N, walk_pose)
    make_loop("run", RUN_N, run_pose)
    make_crouch()
    make_skid()
    make_loop("heave", HEAVE_N, heave_pose)
    make_windup()
    make_peek(1)
    make_peek(-1)
    make_kill()


def export():
    """The control rig out, the baked clips in, one GLB beside the original"""
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for pb in arm.pose.bones:
        for c in list(pb.constraints):
            pb.constraints.remove(c)
        pb.rotation_quaternion = Quaternion()
        pb.location = Vector()
    for o in list(bpy.data.objects):
        if o.type == 'EMPTY' or (o.type == 'MESH' and o.parent is None):
            bpy.data.objects.remove(o, do_unlink=True)
    for a in list(bpy.data.actions):
        if a.name.startswith("src_"):
            bpy.data.actions.remove(a)
    if arm.animation_data:
        arm.animation_data.action = None
    # each clip as its own NLA track, so the exporter takes them all, named as they are
    arm.animation_data_create()
    for tr in list(arm.animation_data.nla_tracks):
        arm.animation_data.nla_tracks.remove(tr)
    for a in bpy.data.actions:
        tr = arm.animation_data.nla_tracks.new()
        tr.name = a.name
        st = tr.strips.new(a.name, int(a.frame_range[0]), a)
        tr.mute = True
    bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', export_animations=True,
                              export_animation_mode='NLA_TRACKS', export_force_sampling=True,
                              export_frame_range=False, export_anim_single_armature=True,
                              export_def_bones=False, export_yup=True, export_apply=False,
                              export_image_format='AUTO')
    print("wrote", OUT)


if __name__ == "__main__":
    build_all()
    export()
