"""Idle gestures for the free (left) hand of the first-person arms (models/player/playerarms.glb).

    blender --background --python tools/blender/build_idle_hands.py -- <arms.glb> <out.glb>
    e.g. ... -- godot-backrooms/models/player/playerarms.glb godot-backrooms/models/player/playerarms_idle.glb

Standing about, now and then the left hand comes up into view and does something small, then goes back
down (torch_model.gd picks one at random, wall_hand.gd eases the hand in and out of it):

    IdleLookHand   brought up in front of the face, palm to you; turned over to look at the back of it,
                   turned back, the fingers flexing as it goes, and let down
    IdleFlex       up low on the left, back to you: closed slowly into a tight fist (a little tremble),
                   opened wide with the fingers spread, shaken loose and let down
    IdleRub        up palm-up, the fingers half closed: the thumb rubs over the fingertips a few times,
                   feeling at something on them (dust, damp from the carpet), and let down

    IdleRest       a loop: the hand held low at the bottom of the view, only the back of it showing (IdleFlex's
                   pose REST_AT in), breathing. Kept up the whole time the torch is; the gestures above
                   blend out of it and back into it then

    IdleSprint     a loop, one stride: the arm pumps, the fist swinging up into the lower left of the view
                   and back down out of it past the hip. torch_model.gd scrubs it by the head bob's phase,
                   so it keeps time with your feet at any pace (forward at one footfall, back at the next)

The out file is only the skeleton and these clips; torch_model.gd lays their Left* tracks over the arms it
already has. Each gesture starts and ends with the hand below the view.

Authored in the camera's space (metres, -Z ahead, +Y up), the way torch_model.gd hangs the arms there:
VIEW_POS / VIEW_ROT / ARMS_SCALE have to be its POS / ROT / ARMS_SCALE. A pose is where the wrist is, the
way the fingers point and the way the palm faces, plus how far each finger curls; the elbow is found
from the shoulder (two-bone, hanging down and out), and every channel then goes through a damped spring
(sprung()) so the hand eases in, runs a touch past and settles instead of stopping dead on each key.
Inside a live Blender (the MCP), exec the file with BUILD_ONLY = True set to build without exporting.
"""
import sys
import math
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector

REPO = Path(__file__).resolve().parents[2] if "__file__" in globals() else Path.cwd()
ARMS = REPO / "godot-backrooms/models/player/playerarms.glb"
OUT = REPO / "godot-backrooms/models/player/playerarms_idle.glb"

VIEW_POS = Vector((0.2, -0.2, -0.38))  # torch_model.gd POS, ROT, ARMS_SCALE
VIEW_ROT = (0.16, 0.14)
ARMS_SCALE = 0.6
FPS = 30
SHOULDER = Vector((-0.22, -0.30, 0.06))   # m, camera space: the left shoulder, below and behind the eye
UPPER = 0.43                      # armature units, elbow to the sleeve's shoulder end (wall_hand.gd UPPER)
SAG = Vector((-0.45, -1.0, 0.0))  # the way the elbow hangs: down and out to the left
FINGERS = ["Index", "Middle", "Ring", "Little"]
JOINTS = ["Proximal", "Intermediate", "Distal"]
THUMB = ["ThumbMetacarpal", "ThumbProximal", "ThumbDistal"]
DOWN = dict(at=(-0.20, -0.55, -0.16), f=(0.15, 0.35, -1.0), n=(1.0, 0.0, 0.1))   # let down, out of view
CLIP_NAMES = ("IdleLookHand", "IdleFlex", "IdleRub")
REST = "IdleRest"                 # the hand held low while the torch is up (a loop)
REST_AT = 0.5                     # s into IdleFlex: the pose it holds (the hand on its way up, only its back in view)
REST_LENGTH = 4.0                 # s: one breath
SPRINT = "IdleSprint"             # the arm pumping while you sprint (a loop: one stride, scrubbed by the stride)
SPRINT_LENGTH = 0.8               # s: about one stride at a sprint (torch_model.gd only reads its phase)
PUMP_FORE = dict(at=(-0.09, -0.135, -0.30), f=(0.20, 0.85, -0.50), n=(1.0, 0.0, 0.3))   # forward: the fist up in view
PUMP_BACK = dict(at=(-0.23, -0.47, -0.04), f=(0.10, -0.25, -1.0), n=(1.0, 0.0, 0.0))    # back: down by the hip


def to_rig():
    """camera space (m) -> the arms' armature space (units): the turn, and the map for points"""
    spin = (Matrix.Rotation(VIEW_ROT[1], 3, "Y") @ Matrix.Rotation(VIEW_ROT[0], 3, "X")).transposed()
    return spin, lambda c: ANCHOR + spin @ (Vector(c) - VIEW_POS) / ARMS_SCALE


def hand_turn(f, n):
    """The hand's turn in camera space: fingers (+Y) along `f`, palm (+Z) facing `n`"""
    y = Vector(f).normalized()
    z = Vector(n) - y * y.dot(Vector(n))
    z.normalize()
    x = y.cross(z)
    return Matrix((x, y, z)).transposed().to_quaternion()


def ease(a, b, u):
    u = max(0.0, min(1.0, u))
    return a + (b - a) * u * u * (3.0 - 2.0 * u)


def track(keys, t):
    """value of `keys` [(time, value)] at t, eased key to key (values: float, Vector or Quaternion)"""
    if t <= keys[0][0]:
        return keys[0][1]
    for (t0, a), (t1, b) in zip(keys, keys[1:]):
        if t <= t1:
            u = (t - t0) / (t1 - t0)
            if isinstance(a, Quaternion):
                return a.slerp(b, u * u * (3.0 - 2.0 * u))
            return ease(a, b, u) if not isinstance(a, Vector) else a.lerp(b, u * u * (3.0 - 2.0 * u))
    return keys[-1][1]


def sprung(values, w, z):
    """`values` (a list per frame of floats / Vectors) followed by a damped spring: w rad/s, damping z"""
    x = values[0].copy() if hasattr(values[0], "copy") else values[0]
    v = x * 0.0
    out = []
    dt = 1.0 / FPS
    for goal in values:
        for _ in range(4):
            v = v + (w * w * (goal - x) - 2.0 * z * w * v) * (dt / 4)
            x = x + v * (dt / 4)
        out.append(x.copy() if hasattr(x, "copy") else x)
    return out


def sprung_q(qs, w, z):
    """the same for quaternions, as 4-vectors kept on one hemisphere"""
    vs = []
    for q in qs:
        v = Vector((q.w, q.x, q.y, q.z))
        if vs and v.dot(vs[-1]) < 0.0:
            v = -v
        vs.append(v)
    return [Quaternion(v).normalized() for v in sprung(vs, w, z)]


def limb(wrist, hand_q, fore_len, upper_len, rest_upper):
    """elbow (camera space, m), forearm turn, wrist turn (local to the forearm), upper arm turn (local)"""
    shoulder = SHOULDER.copy()
    reach = (fore_len + upper_len) * 0.97
    span = wrist - shoulder
    if span.length > reach:
        shoulder = wrist - span.normalized() * reach
    far = max((wrist - shoulder).length, abs(upper_len - fore_len) + 0.01)
    to_wrist = (wrist - shoulder).normalized()
    bend = max(-1.0, min(1.0, (upper_len ** 2 + far ** 2 - fore_len ** 2) / (2.0 * upper_len * far)))
    sag = SAG.normalized()
    sag = (sag - to_wrist * sag.dot(to_wrist)).normalized()
    elbow = shoulder + (to_wrist * bend + sag * math.sqrt(1.0 - bend * bend)) * upper_len
    along = (wrist - elbow).normalized()
    fore = (hand_q @ Vector((0, 1, 0))).rotation_difference(along) @ hand_q
    rests = fore @ rest_upper
    upper = fore.inverted() @ ((rests @ Vector((0, 1, 0))).rotation_difference((shoulder - elbow).normalized()) @ rests)
    return elbow, fore, fore.inverted() @ hand_q, upper


# ---------------------------------------------------------------- the gestures
# A key: time, wrist (m), fingers' way, palm's way, curl per finger (deg added to knuckle, middle, tip),
# spread (deg), thumb (deg about its base: across the palm, out of it)
def K(t, at, f, n, curl=(0.0, 0.0, 0.0), spread=0.0, thumb=(0.0, 0.0), each=None):
    return dict(t=t, at=Vector(at), q=hand_turn(f, n), curl=curl, spread=spread, thumb=thumb, each=each)


def down(t):
    return K(t, DOWN["at"], DOWN["f"], DOWN["n"], curl=(10.0, 10.0, 5.0))


def look_hand():
    up_at = (-0.075, -0.135, -0.34)
    face = dict(f=(0.12, 1.0, 0.12), n=(0.08, -0.05, 1.0))        # palm to you, fingers up
    side = dict(f=(0.05, 1.0, 0.05), n=(1.0, 0.0, 0.15))          # half turned: the edge of the hand
    back = dict(f=(0.10, 1.0, -0.05), n=(-0.10, 0.05, -1.0))      # back of the hand to you
    return 4.6, [
        down(0.0),
        K(0.85, up_at, **face, curl=(5.0, 5.0, 0.0)),
        K(1.40, (-0.07, -0.125, -0.335), **face, curl=(-12.0, -35.0, -10.0), spread=10.0, thumb=(-10.0, 8.0)),
        K(1.90, (-0.065, -0.13, -0.34), **side, curl=(-5.0, -20.0, -5.0), spread=4.0),
        K(2.35, (-0.07, -0.13, -0.34), **back, curl=(-8.0, -28.0, -8.0), spread=8.0),
        K(2.75, (-0.072, -0.132, -0.34), **back, curl=(35.0, 40.0, 30.0), thumb=(15.0, 0.0),
          each=[0.12, 0.08, 0.04, 0.0]),                          # the fingers fold, little finger first
        K(3.15, (-0.07, -0.13, -0.34), **back, curl=(-6.0, -25.0, -8.0), spread=6.0),
        K(3.55, (-0.075, -0.135, -0.34), **side, curl=(0.0, -5.0, 0.0)),
        K(3.85, (-0.09, -0.17, -0.33), **face, curl=(8.0, 8.0, 4.0)),
        down(4.6),
    ]


def flex():
    at = (-0.11, -0.165, -0.34)
    hold = dict(f=(0.30, 0.80, -0.50), n=(0.25, -0.45, -0.85))    # back of the hand to you, fingers ahead and up
    return 3.8, [
        down(0.0),
        K(0.70, at, **hold, curl=(5.0, 0.0, 0.0)),
        K(1.45, (-0.108, -0.16, -0.338), **hold, curl=(80.0, 45.0, 45.0), thumb=(35.0, -10.0), each=[0.0, 0.04, 0.08, 0.12]),
        K(1.85, (-0.107, -0.158, -0.338), **hold, curl=(88.0, 50.0, 50.0), thumb=(40.0, -12.0)),
        K(2.20, (-0.11, -0.155, -0.342), **hold, curl=(-18.0, -45.0, -12.0), spread=14.0, thumb=(-15.0, 15.0)),
        K(2.60, (-0.112, -0.16, -0.34), **hold, curl=(-10.0, -30.0, -8.0), spread=10.0, thumb=(-10.0, 10.0)),
        K(2.95, (-0.12, -0.18, -0.335), **hold, curl=(10.0, 10.0, 5.0)),
        down(3.8),
    ]


def rub():
    at = (-0.09, -0.115, -0.33)
    palm_up = dict(f=(0.55, 0.45, -0.70), n=(-0.10, 0.65, 0.75))    # palm up and turned to you
    keys = [down(0.0), K(0.75, at, **palm_up, curl=(22.0, 12.0, 6.0), thumb=(10.0, 0.0))]
    for k in range(4):                                            # the thumb across the tips and back
        t = 1.05 + k * 0.42
        keys.append(K(t, (-0.09, -0.112 + 0.002 * (k % 2), -0.33), **palm_up, curl=(38.0, 30.0, 14.0), thumb=(42.0, -10.0)))
        keys.append(K(t + 0.21, (-0.091, -0.113, -0.33), **palm_up, curl=(34.0, 26.0, 12.0), thumb=(20.0, 6.0)))
    keys += [K(2.95, (-0.095, -0.12, -0.33), **palm_up, curl=(12.0, 4.0, 2.0), spread=5.0, thumb=(5.0, 5.0)),
             down(3.8)]
    return 3.8, keys


# ---------------------------------------------------------------- build
def sample(length, keys, t):
    def tr(f):
        return track([(k["t"], f(k)) for k in keys], t)
    at = tr(lambda k: k["at"])
    q = tr(lambda k: k["q"])
    curls = []
    for i in range(4):
        c = []                                                    # `each`: a finger's own lag behind the key
        for j in range(3):
            pts = [(k["t"] + (k["each"][i] if k["each"] else 0.0), k["curl"][j]) for k in keys]
            pts.sort(key=lambda p: p[0])
            c.append(track(pts, t))
        curls.append(c)
    spread = tr(lambda k: k["spread"])
    thumb = (tr(lambda k: k["thumb"][0]), tr(lambda k: k["thumb"][1]))
    # a little life: the hand never holds quite still
    drift = Vector((math.sin(t * 2.3) * 0.0015, math.sin(t * 3.1 + 1.0) * 0.0012, 0.0))
    return at + drift, q, curls, spread, thumb


def solve(length, keys):
    """every frame of a gesture: (wrist, hand turn, curls [finger][joint], spread, thumb), sprung"""
    frames = int(round(length * FPS)) + 1
    raw = [sample(length, keys, f / FPS) for f in range(frames)]
    ats = sprung([r[0] for r in raw], 16.0, 0.75)
    qs = sprung_q([r[1] for r in raw], 15.0, 0.8)
    curls = [[sprung([r[2][i][j] for r in raw], 24.0, 0.7) for j in range(3)] for i in range(4)]
    spreads = sprung([r[3] for r in raw], 20.0, 0.8)
    thumbs = [sprung([r[4][j] for r in raw], 22.0, 0.75) for j in range(2)]
    out = [(ats[f], qs[f], [[curls[i][j][f] for j in range(3)] for i in range(4)], spreads[f], (thumbs[0][f], thumbs[1][f]))
           for f in range(frames)]
    # start and end exactly on the let-down pose
    out[-1] = (Vector(DOWN["at"]), hand_turn(DOWN["f"], DOWN["n"])) + out[-1][2:]
    return out


def resting(pose):
    """IdleRest: `pose` held, breathing. One breath a loop, so it runs on without a seam"""
    at, q, curls, spread, thumb = pose
    out = []
    frames = int(round(REST_LENGTH * FPS)) + 1
    for f in range(frames):
        ph = 2.0 * math.pi * f / (frames - 1)
        breath = math.sin(ph)
        sway = Vector((math.sin(ph * 2.0 + 0.7) * 0.0012, breath * 0.004, -breath * 0.0015))
        turn = Quaternion((1, 0, 0), math.radians(breath * 1.5)) @ Quaternion((0, 0, 1), math.radians(math.sin(ph + 1.3) * 1.0))
        c = [[curls[i][j] + 2.5 * math.sin(ph * 2.0 - i * 0.6) * (1.0 if j else 0.6) for j in range(3)] for i in range(4)]
        out.append((at + sway, q @ turn, c, spread, (thumb[0] + 2.0 * math.sin(ph + 2.0), thumb[1])))
    return out


def pumping():
    """IdleSprint: a clenched fist swung forward (phase 0) and back (0.5) and forward again. It races through
    the middle and hangs at each end, a little longer up front, and the way forward runs higher than the way
    back (an ellipse, not a line), so it reads as an arm thrown, not a pendulum"""
    fore, back = PUMP_FORE, PUMP_BACK
    q_fore, q_back = hand_turn(fore["f"], fore["n"]), hand_turn(back["f"], back["n"])
    out = []
    frames = int(round(SPRINT_LENGTH * FPS)) + 1
    for f in range(frames):
        ph = 2.0 * math.pi * f / (frames - 1)
        c, sn = math.cos(ph), math.sin(ph)
        u = (1.0 + c) / 2.0
        u = u ** 0.8                                              # a touch longer at the front
        at = Vector(back["at"]).lerp(Vector(fore["at"]), u) + Vector((0.01, 0.025, -0.02)) * -sn
        q = q_back.slerp(q_fore, u)
        squeeze = 6.0 * u
        curls = [[85.0 + squeeze, 55.0 + squeeze * 0.5, 50.0] for _ in range(4)]
        out.append((at, q, curls, 0.0, (40.0, -12.0)))
    return out


def build(arm_obj):
    arm = arm_obj.data
    rest = {}
    for b in arm.bones:
        m = (b.parent.matrix_local.inverted() @ b.matrix_local) if b.parent else b.matrix_local
        rest[b.name] = m.decompose()
    global ANCHOR
    anchor = bpy.data.objects.get("TorchAnchor")
    ANCHOR = Vector((anchor.location.x, anchor.location.z, -anchor.location.y))   # Blender -> glTF (y up)
    spin, rig_at = to_rig()
    spin_q = spin.to_quaternion()
    fore_len = rest["LeftHand"][0].length * ARMS_SCALE
    upper_len = UPPER * ARMS_SCALE
    rest_upper = rest["LeftUpperArm"][1]
    clips = dict(zip(CLIP_NAMES, (solve(*look_hand()), solve(*flex()), solve(*rub()))))
    clips[REST] = resting(clips["IdleFlex"][int(round(REST_AT * FPS))])
    clips[SPRINT] = pumping()
    pbs = arm_obj.pose.bones
    for name, frames in clips.items():
        old = bpy.data.actions.get(name)
        if old:
            bpy.data.actions.remove(old)
        act = bpy.data.actions.new(name)
        act.use_fake_user = True
        arm_obj.animation_data_create()
        arm_obj.animation_data.action = act
        for f, (at, q, curls, spread, thumb) in enumerate(frames):
            elbow, fore, wrist, upper = limb(at, q, fore_len, upper_len, rest_upper)
            pose = {"LeftLowerArm": (rig_at(elbow), spin_q @ fore),
                    "LeftHand": (None, wrist), "LeftUpperArm": (None, upper)}
            for i, fn in enumerate(FINGERS):
                for j, jn in enumerate(JOINTS):
                    bone = "Left" + fn + jn
                    turn = Quaternion((1, 0, 0), math.radians(curls[i][j]))
                    if j == 0:
                        sp = spread * (1.0, 0.3, -0.4, -1.0)[i]
                        turn = Quaternion((0, 0, 1), math.radians(sp)) @ turn
                    pose[bone] = (None, rest[bone][1] @ turn)
            across, out = thumb
            pose["LeftThumbMetacarpal"] = (None, rest["LeftThumbMetacarpal"][1] @ Quaternion((0, 0, 1), math.radians(-across * 0.5))
                                           @ Quaternion((1, 0, 0), math.radians(out)))
            pose["LeftThumbProximal"] = (None, rest["LeftThumbProximal"][1] @ Quaternion((1, 0, 0), math.radians(across * 0.6)))
            pose["LeftThumbDistal"] = (None, rest["LeftThumbDistal"][1] @ Quaternion((1, 0, 0), math.radians(across * 0.4)))
            for bone, (loc, rot) in pose.items():
                pb = pbs[bone]
                pb.rotation_mode = "QUATERNION"
                rq = rest[bone][1]
                pb.rotation_quaternion = rq.inverted() @ rot
                pb.location = (rq.inverted() @ (loc - rest[bone][0])) if loc is not None else Vector()
                pb.keyframe_insert("rotation_quaternion", frame=f + 1, group=bone)
                pb.keyframe_insert("location", frame=f + 1, group=bone)
        print(name, "%.2f s, %d frames" % ((len(frames) - 1) / FPS, len(frames)))
    return list(clips)


def export(arm_obj, out):
    keep = set(CLIP_NAMES) | {REST, SPRINT}
    for a in list(bpy.data.actions):
        if a.name not in keep:
            bpy.data.actions.remove(a)
    for o in list(bpy.data.objects):
        if o.type == "MESH":
            bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.object.select_all(action="DESELECT")
    arm_obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(out), export_format="GLB", use_selection=True,
                              export_animations=True, export_animation_mode="ACTIONS",
                              export_force_sampling=True, export_frame_step=1, export_yup=True)
    print("wrote", out)


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    src = Path(args[0]) if args else ARMS
    out = Path(args[1]) if len(args) > 1 else OUT
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = FPS
    bpy.ops.import_scene.gltf(filepath=str(src))
    arm_obj = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    build(arm_obj)
    export(arm_obj, out)


ANCHOR = Vector()
if globals().get("BUILD_ONLY"):
    build(next(o for o in bpy.data.objects if o.type == "ARMATURE"))
elif __name__ == "__main__":
    main()
