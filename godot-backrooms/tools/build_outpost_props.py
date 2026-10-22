"""Builds the T.S.R.A. outpost prop kit (models/props/tsra_outpost/*.glb): steel tanker desks, task chairs, cabinets,
a notice board. (The bulletproof glass is not a prop: it is the "glazing" opening of the smart walls, props/outpost_glazing.gd.) Run inside Blender (the pieces get registered in levels/object_types.json):

    blender --background --python tools/build_outpost_props.py

Axes (Blender, before the glTF export): +X is the piece's front (the editor's arrow), Y runs along it, Z up, the
origin on the floor in the middle of the footprint. The materials stay in the files (the types have no "textures").
"""
import math
import os

import bmesh
import numpy as np
import bpy
from mathutils import Euler

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "models", "props", "tsra_outpost")
os.makedirs(OUT, exist_ok=True)
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)


def mat(name, col, rough=0.6, metal=0.0, emit=None, alpha=1.0, tex=None, normal=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    nt = m.node_tree
    if tex:
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = bpy.data.images.load(os.path.abspath(tex))
        nt.links.new(t.outputs["Color"], b.inputs["Base Color"])
    if normal:
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = bpy.data.images.load(os.path.abspath(normal))
        t.image.colorspace_settings.name = "Non-Color"
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nm.inputs["Strength"].default_value = 0.6
        nt.links.new(t.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
    if not tex:
        b.inputs["Base Color"].default_value = (*col, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if emit:
        b.inputs["Emission Color"].default_value = (*emit, 1)
        b.inputs["Emission Strength"].default_value = 1.5
    if alpha < 1:
        b.inputs["Alpha"].default_value = alpha
        try:
            m.surface_render_method = 'BLENDED'
        except Exception:
            pass
    return m


PBR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "textures", "pbr", "Outpost_Wall")


def tinted(name, rgb, gain=1.0):
    """The outpost wall's paint texture in another colour, saved next to the models (embedded in each glb)"""
    import numpy as np
    img = bpy.data.images.load(os.path.join(PBR, "Outpost_Wall_Color.jpg"))
    w, h = img.size
    a = np.array(img.pixels[:], np.float32).reshape(h, w, 4)
    a[..., :3] = np.clip(a[..., :3] * np.array(rgb, np.float32) * gain / 0.5, 0, 1)
    out = bpy.data.images.new(name, w, h)
    out.pixels = a.ravel().tolist()
    out.filepath_raw = os.path.join(bpy.app.tempdir, name + ".png")
    out.file_format = "PNG"
    out.save()
    return out.filepath_raw


_TAN = tinted("op_tan", (0.46, 0.38, 0.30))
_CREAM = tinted("op_cream", (0.62, 0.62, 0.60))
_NRM = os.path.join(PBR, "Outpost_Wall_NormalGL.jpg")
RNG = np.random.default_rng(1991)
N = 512


def _blur(a, r):
    for ax in (0, 1):
        a = sum(np.roll(a, k, ax) for k in range(-r, r + 1)) / (2 * r + 1)
    return a


def _noise(r):
    a = _blur(RNG.random((N, N)), r)
    return (a - a.mean()) / (a.std() + 1e-6)


def _normal(h, s):
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * s
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * s
    n = np.dstack((-dx, -dy, np.ones_like(h)))
    return n / np.linalg.norm(n, axis=2, keepdims=True) * 0.5 + 0.5


def _save(name, rgb):
    img = bpy.data.images.new(name, N, N, alpha=False)
    img.pixels.foreach_set(np.dstack((np.clip(rgb, 0, 1), np.ones((N, N)))).astype(np.float32).ravel())
    img.filepath_raw = os.path.join(bpy.app.tempdir, name + ".png")
    img.file_format = "PNG"
    img.save()
    return img.filepath_raw


def laminate():
    """warm grey high-pressure laminate: a faint cloud and a fine speckle (repeat 1 m)"""
    lum = 1 + 0.012 * _noise(24) + 0.008 * _noise(1)
    sp = RNG.random((N, N))
    lum -= 0.07 * (sp > 0.985) - 0.04 * (sp < 0.015)
    return _save("op_laminate", np.array([0.70, 0.68, 0.62]) * lum[..., None])


def paint():
    """baked-enamel steel, putty grey, with the orange-peel of the spray (repeat 0.5 m)"""
    peel = _noise(3)
    col = np.array([0.47, 0.49, 0.45]) * (1 + 0.025 * _noise(20) + 0.01 * peel)[..., None]
    return _save("op_paint", col), _save("op_paint_n", _normal(peel, 0.35))


def fabric():
    """charcoal-blue office tweed: a basket weave of flecked threads (repeat 0.15 m)"""
    y, x = np.mgrid[0:N, 0:N]
    p = 8
    wx, wy = 0.5 + 0.5 * np.sin(2 * np.pi * x / p), 0.5 + 0.5 * np.sin(2 * np.pi * y / p)
    h = np.where(((x // p) + (y // p)) % 2 == 0, wy, wx) + 0.15 * _noise(1)
    thread = RNG.random((N // p + 1, N // p + 1))[(y // p), (x // p)]
    base = np.where((thread > 0.8)[..., None], np.array([0.34, 0.35, 0.38]), np.array([0.17, 0.19, 0.24]))
    col = base * (0.72 + 0.35 * h)[..., None]
    return _save("op_fabric", col), _save("op_fabric_n", _normal(h, 1.6))


_LAM = laminate()
_PAINT, _PAINT_N = paint()
_FAB, _FAB_N = fabric()
REP = {"lam": 1.0, "paint": 0.5, "fabric": 0.15}             # metres per texture repeat (else 2.22)
M = {
    "steel": mat("OP_Steel", (0.07, 0.08, 0.085), .45, .7),
    "grey": mat("OP_GreyMetal", (0.42, 0.46, 0.46), .5, .5),
    "tan": mat("OP_TanPanel", (0, 0, 0), .8, tex=_TAN, normal=_NRM),
    "base": mat("OP_Cove", (0.10, 0.07, 0.05), .6),
    "gasket": mat("OP_Gasket", (0.015, 0.015, 0.015), .7),
    "cream": mat("OP_Cream", (0, 0, 0), .65, tex=_CREAM, normal=_NRM),
    "glass": mat("OP_BulletGlass", (0.60, 0.72, 0.68), .02, 0, alpha=0.16),
    "lam": mat("OP_Laminate", (0, 0, 0), .38, tex=_LAM),
    "paint": mat("OP_PaintedSteel", (0, 0, 0), .42, .25, tex=_PAINT, normal=_PAINT_N),
    "fabric": mat("OP_Tweed", (0, 0, 0), .95, tex=_FAB, normal=_FAB_N),
    "chrome": mat("OP_Chrome", (0.82, 0.82, 0.8), .14, 1.0),
    "rubber": mat("OP_Rubber", (0.025, 0.025, 0.025), .85),
    "black": mat("OP_Black", (0.02, 0.02, 0.02), .5),
    "cork": mat("OP_Cork", (0.5, 0.3, 0.18), .95),
    "bolt": mat("OP_Bolt", (0.6, 0.6, 0.58), .35, 1.0),
}
parts = []


def _add(me, m, name):
    for poly in me.polygons:                                  # bevels read round, flat faces stay crisp
        poly.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(35))
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    o.data.materials.append(M[m])
    parts.append(o)
    return o


def box(c, s, m, name="b", bev=None, seg=2):
    """c: centre, s: size (x front, y along, z up). The edges are chamfered (`bev`, default a fifth of the thinnest
    side up to 8 mm) so nothing reads as a sharp CG block; UVs are in metres (a 2.22 m repeat)."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=s, verts=bm.verts)
    bev = min(min(s) * 0.2, 0.008) if bev is None else bev
    if bev > 0.0005:
        bmesh.ops.bevel(bm, geom=list(bm.edges), offset=bev, segments=seg, profile=0.5, affect='EDGES')
    bmesh.ops.translate(bm, vec=c, verts=bm.verts)
    uv = bm.loops.layers.uv.new("UVMap")
    rp = REP.get(m, 2.22)
    for f in bm.faces:
        n = f.normal
        ax = max(range(3), key=lambda i: abs(n[i]))
        a, b = [i for i in range(3) if i != ax]
        for l in f.loops:
            l[uv].uv = (l.vert.co[a] / rp, l.vert.co[b] / rp)
    bm.to_mesh(me)
    bm.free()
    return _add(me, m, name)


def cyl(c, r, h, m, name="c", seg=16, rot=None, r2=None):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=seg, radius1=r, radius2=r if r2 is None else r2, depth=h)
    if rot:
        bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=Euler(rot).to_matrix(), verts=bm.verts)
    bmesh.ops.translate(bm, vec=c, verts=bm.verts)
    bm.to_mesh(me)
    bm.free()
    return _add(me, m, name)


def export(name):
    global parts
    bpy.ops.object.select_all(action='DESELECT')
    for o in parts:
        o.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, name + ".glb"), export_format='GLB', use_selection=True,
                              export_apply=True, export_yup=True)
    for o in parts:
        bpy.data.objects.remove(o, do_unlink=True)
    parts = []


def desk(name, L, double):
    """A steel tanker desk (Steelcase 60 x 30 in, 29.5 in high): laminate top in an aluminium edge band, painted steel
    pedestals on a recessed toe kick, each a box drawer over a file drawer, a pencil drawer over the kneehole, a
    modesty panel. Its front (+X, the arrow) is the sitter's side."""
    D, H, tt, PW, kick = 0.76, 0.75, 0.032, 0.40, 0.07
    under = H - tt
    box((0, 0, H - tt / 2), (D, L, tt), "lam", "top", bev=0.002)
    for sx in (-1, 1):                                        # the edge band
        box((sx * (D / 2 + 0.003), 0, H - tt / 2), (0.006, L + 0.012, tt + 0.004), "chrome", "band", bev=0.002)
    for sy in (-1, 1):
        box((0, sy * (L / 2 + 0.003), H - tt / 2), (D, 0.006, tt + 0.004), "chrome", "band", bev=0.002)
    fx = D / 2 - 0.035                                        # the pedestals' front face
    peds = [L / 2 - PW / 2 - 0.01] + ([-(L / 2 - PW / 2 - 0.01)] if double else [])
    for py in peds:
        box((-0.01, py, (kick + under) / 2), (D - 0.05, PW, under - kick), "paint", "pedestal", bev=0.012, seg=3)
        box((-0.03, py, kick / 2), (D - 0.12, PW - 0.05, kick), "rubber", "toekick")
        z = under - 0.012
        for dh, label in ((0.17, False), (under - kick - 0.17 - 0.035, True)):
            zc = z - dh / 2
            box((fx + 0.008, py, zc), (0.02, PW - 0.02, dh - 0.008), "paint", "drawer", bev=0.006, seg=3)
            box((fx + 0.022, py, z - 0.045), (0.016, PW * 0.6, 0.022), "chrome", "pull", bev=0.004, seg=2)
            if label:                                         # the card holder of a file drawer
                box((fx + 0.02, py, z - 0.1), (0.006, 0.09, 0.045), "chrome", "cardframe", bev=0.001)
                box((fx + 0.022, py, z - 0.1), (0.004, 0.075, 0.032), "cream", "card", bev=0)
            z -= dh + 0.004
        cyl((fx + 0.02, py + PW / 2 - 0.04, under - 0.04), 0.011, 0.012, "chrome", "lock", 16, rot=(0, math.pi / 2, 0))
    if double:
        y0, y1 = -(L / 2 - PW - 0.01), L / 2 - PW - 0.01
    else:                                                     # a closed end panel on the other side
        y0, y1 = -L / 2 + 0.04, L / 2 - PW - 0.01
        box((-0.01, -L / 2 + 0.02, under / 2), (D - 0.05, 0.035, under), "paint", "endpanel", bev=0.008, seg=3)
    kw, kc = y1 - y0, (y0 + y1) / 2
    box((fx - 0.01, kc, under - 0.05), (0.04, kw - 0.01, 0.085), "paint", "pencildrawer", bev=0.006, seg=3)
    box((fx + 0.012, kc, under - 0.075), (0.014, 0.22, 0.016), "chrome", "pull", bev=0.004)
    box((-D / 2 + 0.04, kc, (0.22 + under) / 2), (0.02, kw, under - 0.22), "paint", "modesty", bev=0.004)
    export(name)


def chair():
    """An 80s office task chair: tweed seat and back cushions with rolled edges, the back on a black steel spine,
    loop arms, a gas lift in a telescoping shroud, a five-star base on twin-wheel casters. Front +X."""
    for i in range(5):
        a = i * 2 * math.pi / 5
        leg = box((0.17, 0, 0), (0.30, 0.045, 0.035), "black", "leg", bev=0.012, seg=3)
        leg.rotation_euler = (0, math.radians(4), a)
        leg.location.z = 0.085
        cx, cy = math.cos(a) * 0.32, math.sin(a) * 0.32
        box((cx, cy, 0.06), (0.05, 0.05, 0.03), "black", "casterhood", bev=0.01, seg=3)
        for k in (-1, 1):                                     # the twin wheels, axle along the leg
            wx, wy = cx + math.cos(a + math.pi / 2) * k * 0.014, cy + math.sin(a + math.pi / 2) * k * 0.014
            w = cyl((0, 0, 0), 0.026, 0.016, "rubber", "wheel", 16, rot=(math.pi / 2, 0, 0))
            w.rotation_euler.z = a + math.pi / 2
            w.location = (wx, wy, 0.027)
    cyl((0, 0, 0.09), 0.055, 0.07, "black", "hub", 20)
    cyl((0, 0, 0.17), 0.04, 0.12, "black", "shroud", 20, r2=0.034)
    cyl((0, 0, 0.27), 0.024, 0.14, "chrome", "gaslift", 16)
    box((0, 0, 0.345), (0.24, 0.2, 0.04), "black", "mechanism", bev=0.008, seg=3)
    box((0, 0, 0.375), (0.46, 0.47, 0.022), "black", "seatshell", bev=0.01, seg=3)
    box((0.005, 0, 0.428), (0.47, 0.48, 0.085), "fabric", "seat", bev=0.035, seg=5)
    box((-0.17, 0, 0.35), (0.16, 0.06, 0.025), "steel", "spine_foot", bev=0.006)
    sp = box((-0.25, 0, 0.55), (0.03, 0.06, 0.42), "steel", "spine", bev=0.008, seg=3)
    sp.rotation_euler.y = math.radians(-8)
    for part, off, size, m in (("back", 0.0, (0.075, 0.43, 0.44), "fabric"),
                               ("backshell", -0.045, (0.02, 0.42, 0.42), "black")):
        o = box((off, 0, 0), size, m, part, bev=0.03 if m == "fabric" else 0.008, seg=5 if m == "fabric" else 3)
        o.rotation_euler.y = math.radians(-10)
        o.location = (-0.27, 0, 0.86)
    for sy in (-1, 1):
        box((-0.02, sy * 0.19, 0.372), (0.08, 0.12, 0.012), "steel", "armbracket", bev=0.003)
        box((-0.05, sy * 0.265, 0.5), (0.03, 0.022, 0.25), "steel", "armpost", bev=0.006, seg=3)
        box((0.02, sy * 0.265, 0.635), (0.26, 0.065, 0.03), "black", "armpad", bev=0.012, seg=4)
    export("outpost_chair")


def tall_cab():
    W, D, H = 0.9, 0.45, 1.9
    box((0, 0, H / 2), (D, W, H), "grey", "body")
    for sy in (-1, 1):
        box((D / 2 + 0.012, sy * W / 4, 1.15), (0.02, W / 2 - 0.06, 1.2), "glass", "glassdoor")
        box((D / 2 + 0.012, sy * W / 4, 0.4), (0.025, W / 2 - 0.06, 0.7), "grey", "lowdoor")
        box((D / 2 + 0.03, sy * 0.04, 1.0), (0.02, 0.02, 0.2), "bolt", "handle")
    for z in (0.75, 1.1, 1.45, 1.8):
        box((0, 0, z), (D - 0.04, W - 0.06, 0.012), "cream", "shelf")
    box((0, 0, 0.03), (D + 0.02, W + 0.02, 0.06), "steel", "plinth")
    export("outpost_cabinet_tall")


def low_cab():
    W, D = 0.9, 0.5
    box((0, 0, 0.3), (D, W, 0.6), "cream", "base")
    for sy in (-1, 1):
        box((D / 2 + 0.01, sy * W / 4, 0.3), (0.012, W / 2 - 0.04, 0.54), "cream", "door")
        box((D / 2 + 0.02, sy * 0.04, 0.3), (0.02, 0.02, 0.12), "bolt", "pull")
    box((0, 0, 0.62), (D + 0.04, W + 0.04, 0.04), "lam", "worktop")
    box((-0.1, 0, 0.9), (D - 0.2, W, 0.5), "cream", "upper")
    for sy in (-1, 1):
        box((-0.1 + (D - 0.2) / 2 + 0.012, sy * W / 4, 0.9), (0.012, W / 2 - 0.04, 0.44), "glass", "upperglass")
    export("outpost_cabinet_low")


def corkboard():
    box((0.012, 0, 0.4), (0.024, 1.2, 0.8), "cork", "cork")
    box((0.02, 0, 0.8), (0.04, 1.24, 0.04), "tan", "frame_t")
    box((0.02, 0, 0.0), (0.04, 1.24, 0.04), "tan", "frame_b")
    for sy in (-1, 1):
        box((0.02, sy * 0.6, 0.4), (0.04, 0.04, 0.84), "tan", "frame_s")
    for y, z, c in ((-0.3, 0.55, "cream"), (0.1, 0.3, "cream"), (0.38, 0.6, "lam")):
        box((0.03, y, z), (0.006, 0.22, 0.3), c, "paper")
    export("outpost_corkboard")


desk("outpost_desk", 1.52, True)
desk("outpost_desk_single", 1.2, False)
chair()
tall_cab()
low_cab()
corkboard()
print("outpost props:", sorted(os.listdir(OUT)))
