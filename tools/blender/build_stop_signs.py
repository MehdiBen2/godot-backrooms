"""Blender (headless) -> res://models/props/stop_sign/*.glb. Run:
blender -b -P tools/blender/build_stop_signs.py
Each raw pack is imported, stood upright (+Z up in Blender), scaled to a real-world 2.4 m sign on a pole, its
pole base put on z = 0 and centred, then exported Y-up with the textures embedded."""
import bpy, os, glob
from mathutils import Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "asetsuimprot")
OUT = os.path.join(ROOT, "godot-backrooms", "models", "props", "stop_sign")
HEIGHT = 2.4

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def bounds():
    lo = Vector((1e9,) * 3); hi = Vector((-1e9,) * 3)
    for o in bpy.context.scene.objects:
        if o.type != "MESH":
            continue
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
    return lo, hi

def normalise():
    # objects to a single empty so one transform moves the lot
    root = bpy.data.objects.new("root", None); bpy.context.scene.collection.objects.link(root)
    for o in list(bpy.context.scene.objects):
        if o is not root and o.parent is None:
            o.parent = root
    bpy.context.view_layer.update()
    lo, hi = bounds()
    s = HEIGHT / (hi.z - lo.z)
    root.scale = (s, s, s)
    bpy.context.view_layer.update()
    lo, hi = bounds()
    root.location -= Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
    bpy.context.view_layer.update()
    print("FINAL", bounds())

def export(name):
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, name + ".glb"), export_format="GLB", export_yup=True, export_apply=True)

# 1. the Sketchfab glb: measure + rescale
reset()
bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, "stop_sign.glb"))
print("RAW stop_sign.glb", bounds())
normalise(); export("stop_sign")

# 2. L3 obj (its Z is up, 152 units tall)
reset()
bpy.ops.wm.obj_import(filepath=glob.glob(os.path.join(SRC, "StopSign_L3*", "*", "*.obj"))[0], forward_axis="NEGATIVE_Y", up_axis="Z")
print("RAW L3", bounds())
normalise(); export("stop_sign_l3")

# 3. TyroSmith obj
reset()
bpy.ops.wm.obj_import(filepath=os.path.join(SRC, "zgzccjcx2b-StopSign_By_TyroSmith", "StopSign", "StopSign.obj"), forward_axis="NEGATIVE_Y", up_axis="Y")
print("RAW Tyro", bounds())
normalise(); export("stop_sign_tyro")
