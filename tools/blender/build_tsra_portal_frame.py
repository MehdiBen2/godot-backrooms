"""The threshold gate's frame: the Sketchfab "Futuristic Cyberpunk Portal Frame" made game-ready.

    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --factory-startup \
        --python tools/blender/build_tsra_portal_frame.py -- [preview dir]

Reads asetsuimprot/tsraroom/futuristic_cyberpunk_portal_frame.glb (fdehell, CC-BY-4.0: see models/CREDITS.txt);
writes godot-backrooms/models/props/tsra/tsra_portal_frame.glb (source: assetsimported/tsra/tsra_portal_frame.blend).

The file is 1.8 m wide, 2 m tall and 587k triangles, its parts stacked copies of the same box. Here they are
joined, decimated to about a tenth (it is hard-surface with baked normal maps, so the silhouette holds) and scaled
up SCALE times to stand in the launch bay (the game's walls are 5.4 m). Its feet go on z = 0 (Godot y = 0), its
middle on the origin, the side with the control panel to the front (-Y here, Godot +Z). The clear opening is
measured with rays and printed: tsra_portal_gate.gd OPEN_W / OPEN_H / SILL take those numbers. The doorway is
closed at the back by a panel (y ~0.42 here, Godot z ~ -0.42): the threshold is drawn just in front of it.
"""
import sys
from pathlib import Path

import bpy
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tsra_common as T  # noqa: E402

SRC = T.ROOT / "asetsuimprot" / "tsraroom" / "futuristic_cyberpunk_portal_frame.glb"
SCALE = 2.25
RATIO = 0.1
BACK_FROM = 0.0          # m, y: a ray stopping behind this reached the back panel (it sits at y ~0.42)


def bounds(objs):
    lo = Vector((1e9,) * 3)
    hi = Vector((-1e9,) * 3)
    for ob in objs:
        for c in ob.bound_box:
            w = ob.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    return lo, hi


def opening(ob):
    """The recess seen along Y through the frame's middle, (x0, x1, z0, z1): where a ray from the front gets all
    the way in to the closed back panel (the frame is a doorway with a back, not a hole)"""
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    lo, hi = bounds([ob])
    y0 = lo.y - 1.0
    def clear(x, z):
        hit, at, *_ = bpy.context.scene.ray_cast(dg, Vector((x, y0, z)), Vector((0, 1, 0)))
        return (not hit) or at.y > BACK_FROM
    def reach(fixed_x, start, step, along_x):
        """From `start` (in the recess) step outward until the ray no longer gets to the back panel"""
        v = start
        while abs(v) < 10.0 and (clear(v, fixed_x) if along_x else clear(fixed_x, v)):
            v += step
        return v - step
    mid_z = (lo.z + hi.z) / 2
    x0, x1 = reach(mid_z, 0.0, -0.005, True), reach(mid_z, 0.0, 0.005, True)
    z0, z1 = reach(0.0, mid_z, -0.005, False), reach(0.0, mid_z, 0.005, False)
    return x0, x1, z0, z1


def build():
    T.reset_scene()
    bpy.ops.import_scene.gltf(filepath=str(SRC))
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()
    frame = bpy.context.view_layer.objects.active
    frame.parent = None
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for o in [o for o in bpy.context.scene.objects if o.type != "MESH"]:
        bpy.data.objects.remove(o)
    frame.name = frame.data.name = "PortalFrame"
    before = len(frame.data.polygons)

    dec = frame.modifiers.new("Decimate", "DECIMATE")
    dec.ratio = RATIO
    dec.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=dec.name)

    lo, hi = bounds([frame])
    frame.location = Vector((-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z)) * 1.0
    bpy.ops.object.transform_apply(location=True)
    frame.scale = (SCALE, SCALE, SCALE)
    bpy.ops.object.transform_apply(scale=True)
    for p in frame.data.polygons:
        p.use_smooth = True
    root = T.empty("TSRA_PortalFrame", (0, 0, 0), size=0.5)
    frame.parent = root

    lo, hi = bounds([frame])
    ox0, ox1, oz0, oz1 = opening(frame)
    print(f"faces {before} -> {len(frame.data.polygons)}")
    print(f"SIZE w {hi.x - lo.x:.3f} d {hi.y - lo.y:.3f} h {hi.z - lo.z:.3f}")
    print(f"OPENING x {ox0:.3f}..{ox1:.3f} (w {ox1 - ox0:.3f})  z {oz0:.3f}..{oz1:.3f} (h {oz1 - oz0:.3f})")

    dg = bpy.context.evaluated_depsgraph_get()
    hit, at, *_ = bpy.context.scene.ray_cast(dg, Vector((0.0, lo.y - 1.0, (oz0 + oz1) / 2)), Vector((0, 1, 0)))
    print(f"BACK y {at.y:.3f}")
    # collision: the two sides, the head over the opening and the back panel (the sill is left to walk over)
    T.box("COL_Left-convcolonly", lo.x, lo.y, 0.0, ox0, hi.y, hi.z, None, root).display_type = "WIRE"
    T.box("COL_Right-convcolonly", ox1, lo.y, 0.0, hi.x, hi.y, hi.z, None, root).display_type = "WIRE"
    T.box("COL_Head-convcolonly", ox0, lo.y, oz1, ox1, hi.y, hi.z, None, root).display_type = "WIRE"
    T.box("COL_Back-convcolonly", ox0, at.y, 0.0, ox1, hi.y, oz1, None, root).display_type = "WIRE"
    return hi.z


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    h = build()
    T.save_and_export("tsra_portal_frame")
    if argv:
        T.preview(argv[0], "tsra_portal_frame", (0, 0, h / 2), h * 0.62,
                  views=(("front", (0, -1, 0.1)), ("three_quarter", (0.8, -1, 0.4))))
