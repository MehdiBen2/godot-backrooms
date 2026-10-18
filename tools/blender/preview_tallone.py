"""Contact sheets of THE TALL ONE's poses, rendered headless (Workbench), to look at while animating.

    blender -b tools/blender/tall_one.blend --python tools/blender/preview_tallone.py -- OUT.png clip=kill t=0.4,1.0,2.0 view=side [size=1.0]

    clip   idle | walk | run | spot | scream | kill        (a function in animate_tallone.py, called with t seconds for
                                                           the one-shot clips, or a 0..1 phase for the loops)
    t      comma-separated times (kill, spot, scream: seconds) or phases (idle, walk, run: 0..1)
    view   side | front | face | eye      (face: close on the head from the front, eye: through the kill's KillEye)
    size   orthographic width scale (default fits the whole body; kill uses a tighter frame)
"""
import sys
import os
import bpy
import numpy as np
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(bpy.data.filepath)) if bpy.data.filepath else os.getcwd()
args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out = args[0]
opt = dict(a.split("=", 1) for a in args[1:])
clip = opt.get("clip", "idle")
times = [float(x) for x in opt.get("t", "0").split(",")]
view = opt.get("view", "side")
scale = float(opt.get("size", "1.0"))

ns = {"__name__": "tallone"}
exec(open(os.path.join(HERE, "animate_tallone.py")).read(), ns)
ns["prepare"]()
arm = ns["arm"]
scn = bpy.context.scene
scn.render.engine = 'BLENDER_WORKBENCH'
scn.render.resolution_x = 420
scn.render.resolution_y = 560
scn.render.film_transparent = False
sh = scn.display.shading
sh.light = 'STUDIO'
sh.color_type = 'TEXTURE' if view == 'face' else 'SINGLE'
sh.single_color = (0.72, 0.72, 0.72)
sh.show_cavity = True
w = scn.world or bpy.data.worlds.new("W")
scn.world = w
w.use_nodes = False
w.color = (0.16, 0.17, 0.19)
for o in list(bpy.data.objects):
    if o.type in ('LIGHT', 'CAMERA'):
        bpy.data.objects.remove(o, do_unlink=True)
cam = bpy.data.cameras.new("PCam")
co = bpy.data.objects.new("PCam", cam)
scn.collection.objects.link(co)
scn.camera = co


def aim(loc, target, ortho=None, lens=None):
    co.location = loc
    d = Vector(target) - Vector(loc)
    co.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    if ortho:
        cam.type = 'ORTHO'
        cam.ortho_scale = ortho
    else:
        cam.type = 'PERSP'
        cam.lens = lens or 35


frames = []
for t in times:
    if clip in ("idle", "walk", "run"):
        pose = ns[clip](t)
    else:
        pose = ns[clip](t)
    P = ns["show"](pose)
    hips = P["Hips"].translation
    if view == "side":
        if clip == "kill":
            aim((9, hips.y - 0.3, 1.5), (0, hips.y - 0.3, 1.5), ortho=6.0 * scale)
        else:
            aim((9, hips.y, 2.3), (0, hips.y, 2.3), ortho=5.4 * scale)
    elif view == "front":
        aim((hips.x, -9, 2.3), (hips.x, 0, 2.3), ortho=5.4 * scale)
    elif view == "face":
        h = P["Head"].translation
        aim((h.x, h.y - 2.2, h.z + 0.2), (h.x, h.y, h.z + 0.2), ortho=1.1 * scale)
    elif view == "eye":
        e = bpy.data.objects.get("KillEye")
        ex = e.matrix_world.translation if e else Vector((0, -0.62, 0.18))
        aim(ex, ex + Vector((0, 0, 1)), lens=18)
        co.rotation_euler = Matrix(((1, 0, 0), (0, 0, 1), (0, -1, 0))).to_euler() if False else co.rotation_euler
        # look up with the top of the frame toward the front of it (-Y)
        q = Vector((0, 0, 1)).to_track_quat('-Z', 'Y')
        co.rotation_euler = Matrix(((1, 0, 0), (0, 1, 0), (0, 0, 1))).to_euler()
        fwd = Vector((0, 0, 1))
        up = Vector((0, -1, 0))
        right = fwd.cross(up)
        m = Matrix(((right.x, up.x, -fwd.x), (right.y, up.y, -fwd.y), (right.z, up.z, -fwd.z)))
        co.rotation_euler = m.to_euler()
    bpy.context.view_layer.update()
    scn.render.filepath = os.path.join(os.path.dirname(out), "_p%d.png" % len(frames))
    bpy.ops.render.render(write_still=True)
    frames.append(scn.render.filepath)

imgs = [bpy.data.images.load(f) for f in frames]
w_, h_ = imgs[0].size
sheet = np.zeros((h_, w_ * len(imgs), 4), dtype=np.float32)
for i, im in enumerate(imgs):
    a = np.array(im.pixels[:], dtype=np.float32).reshape(h_, w_, 4)
    sheet[:, i * w_:(i + 1) * w_] = a
res = bpy.data.images.new("sheet", w_ * len(imgs), h_)
res.pixels[:] = sheet.ravel()
res.filepath_raw = out
res.file_format = 'PNG'
res.save()
for f in frames:
    try:
        os.remove(f)
    except OSError:
        pass
print("SHEET", out)
