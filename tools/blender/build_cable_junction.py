"""Builds the ceiling cable run's junction box (the box at every turn of a "Cable run", object_types.json
"cable_run") with a painted-metal texture, and exports it to godot-backrooms/models/props/cables/cable_junction.glb.

Run inside Blender (MCP execute_blender_code, or Text editor > Run Script). It only touches objects named CJ_*.
Size: 0.34 m square, 0.18 m high, bottom on z = 0 (the cable tray is 0.30 m wide, 0.15 m high at the game's scale).
"""
import bpy, bmesh, math, os, random
import numpy as np
from mathutils import Vector

REPO = r"C:\Users\alhyu\Documents\GitHub\godot-backrooms"
OUT = os.path.join(REPO, "godot-backrooms", "models", "props", "cables", "cable_junction.glb")
TEX = os.path.join(REPO, "godot-backrooms", "models", "props", "cables", "cable_junction_paint.png")

W, H = 0.34, 0.18           # box: square side, height
FLANGE = 0.012              # how far the frames round each cable opening stand out

# ---- texture: dull painted steel, scratched, dirty at the edges, a little rust
def make_texture(path, n=512, seed=7):
    rng = np.random.default_rng(seed)
    def blur_noise(scale):
        small = rng.random((n // scale + 2, n // scale + 2))
        ys = np.linspace(0, n // scale, n)
        i0 = np.floor(ys).astype(int); f = ys - i0
        rows = small[i0] * (1 - f)[:, None] + small[i0 + 1] * f[:, None]
        return rows[:, i0] * (1 - f)[None, :] + rows[:, i0 + 1] * f[None, :]
    base = np.array([0.30, 0.33, 0.30])
    lo = blur_noise(64) * 0.5 + blur_noise(16) * 0.3 + blur_noise(4) * 0.2
    grain = rng.random((n, n))
    lum = 0.75 + 0.35 * lo + 0.08 * (grain - 0.5)
    img = base[None, None, :] * lum[..., None]
    # scratches
    for _ in range(90):
        x, y = rng.integers(0, n, 2)
        ang = rng.random() * math.pi
        ln = int(rng.integers(10, 70))
        for t in range(ln):
            px, py = int(x + math.cos(ang) * t) % n, int(y + math.sin(ang) * t) % n
            img[py, px] = np.minimum(img[py, px] + 0.22, 1.0)
    # rust blooms
    rust = (blur_noise(32) > 0.86) * (blur_noise(8) * 0.8 + 0.2)
    img = img * (1.0 - rust[..., None] * 0.9) + rust[..., None] * np.array([0.42, 0.2, 0.09]) * 0.9
    # grime: darker towards each texture edge (island edges on a smart-project atlas)
    img *= (0.88 + 0.12 * blur_noise(2))[..., None]
    img = np.clip(img, 0.0, 1.0)
    bpy.data.images.new("tmp_cj", n, n)
    out = bpy.data.images["tmp_cj"]
    rgba = np.dstack([img, np.ones((n, n))]).astype(np.float32)
    out.pixels.foreach_set(rgba.ravel())
    out.filepath_raw = path
    out.file_format = "PNG"
    out.save()
    bpy.data.images.remove(out)

make_texture(TEX)

# ---- clear an earlier run of this script
for ob in [o for o in bpy.data.objects if o.name.startswith("CJ_")]:
    bpy.data.objects.remove(ob, do_unlink=True)


def box(name, size, loc):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= size[0]; v.co.y *= size[1]; v.co.z *= size[2]
        v.co += Vector(loc)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def cyl(name, r, depth, loc, axis="Z", segs=14):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segs, radius1=r, radius2=r, depth=depth)
    if axis == "X": bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=__import__("mathutils").Matrix.Rotation(math.pi / 2, 3, "Y"))
    for v in bm.verts: v.co += Vector(loc)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


parts = []
body = box("CJ_body", (W, W, H), (0, 0, H / 2))
parts.append(body)
# a lip round the open (ceiling) end and a lid plate on the underside with four bolts
parts.append(box("CJ_lip", (W + 0.02, W + 0.02, 0.014), (0, 0, H - 0.007)))
parts.append(box("CJ_lid", (W - 0.07, W - 0.07, 0.010), (0, 0, 0.0)))
for sx in (-1, 1):
    for sy in (-1, 1):
        parts.append(cyl("CJ_bolt", 0.0125, 0.012, (sx * (W / 2 - 0.05), sy * (W / 2 - 0.05), -0.004)))
# frames round the four cable openings, with a bolt each end
open_w, open_h = 0.27, 0.13
for rot in range(4):
    a = rot * math.pi / 2
    fx, fy = math.cos(a), math.sin(a)
    fr = box("CJ_frame", (FLANGE, open_w + 0.04, open_h + 0.035), (0, 0, 0))
    fr.location = Vector((fx * (W / 2 + FLANGE / 2), fy * (W / 2 + FLANGE / 2), H * 0.5))
    fr.rotation_euler.z = a
    parts.append(fr)
    for s in (-1, 1):
        b = cyl("CJ_bolt", 0.009, FLANGE + 0.006, (0, 0, 0), axis="X", segs=10)
        off = Vector((fx, fy, 0)) * (W / 2 + FLANGE) + Vector((-fy, fx, 0)) * (s * (open_w / 2 + 0.012))
        b.location = off + Vector((0, 0, H * 0.5))
        b.rotation_euler.z = a
        parts.append(b)

bpy.ops.object.select_all(action="DESELECT")
for p in parts: p.select_set(True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.join()
ob = bpy.context.active_object
ob.name = "CJ_junction"
# round the hard edges a little so the paint catches the light
bev = ob.modifiers.new("bevel", "BEVEL")
bev.width = 0.004; bev.segments = 2; bev.limit_method = "ANGLE"
bpy.ops.object.modifier_apply(modifier="bevel")
bpy.ops.object.shade_smooth()
ob.data.polygons.foreach_set("use_smooth", [True] * len(ob.data.polygons))
# shade by angle so flat faces stay flat
try:
    bpy.ops.object.shade_auto_smooth(angle=math.radians(40))
except Exception:
    pass

# UVs
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.01)
bpy.ops.object.mode_set(mode="OBJECT")

# material
mat = bpy.data.materials.get("CJ_paint") or bpy.data.materials.new("CJ_paint")
mat.use_nodes = True
nt = mat.node_tree
nt.nodes.clear()
out = nt.nodes.new("ShaderNodeOutputMaterial")
bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
tex = nt.nodes.new("ShaderNodeTexImage")
tex.image = bpy.data.images.load(TEX, check_existing=False)
nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
bsdf.inputs["Metallic"].default_value = 0.45
bsdf.inputs["Roughness"].default_value = 0.62
ob.data.materials.clear()
ob.data.materials.append(mat)

# origin: bottom of the box (the lid bolts) on z = 0, centred
bb = [ob.matrix_world @ Vector(c) for c in ob.bound_box]
low = min(v.z for v in bb)
ob.location.z -= low
bpy.ops.object.select_all(action="DESELECT")
ob.select_set(True)
bpy.context.view_layer.objects.active = ob
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True, export_yup=True,
                          export_image_format="AUTO", export_apply=True)
print("exported", OUT, [round(d, 3) for d in ob.dimensions])
