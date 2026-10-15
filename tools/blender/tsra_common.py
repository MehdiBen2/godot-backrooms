"""Shared bits for the T.S.R.A. hub prop builders (build_tsra_sign.py, build_tsra_console.py).

Run those headless, apart from any Blender session that is open:
    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --factory-startup --python tools/blender/<script>.py -- <preview dir>

Blender space: Z up, the prop's front faces -Y (the glTF export turns that into Godot's +Z, Y up).
"""
import math
import os
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "godot-backrooms"
OUT_DIR = GAME / "models" / "props" / "tsra"
BLEND_DIR = ROOT / "assetsimported" / "tsra"          # gitignored source files
VCR_FONT = GAME / "fonts" / "vcr.ttf"
EMBLEM_PNG = GAME / "textures" / "ui" / "tsra_logo.png"

AMBER = (0.941, 0.659, 0.22)


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = "METRIC"
    return sc


def material(name, color, metallic=0.0, roughness=0.5, emission=None, strength=0.0, alpha=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    p.inputs["Base Color"].default_value = (*color, 1.0)
    p.inputs["Metallic"].default_value = metallic
    p.inputs["Roughness"].default_value = roughness
    if emission:
        p.inputs["Emission Color"].default_value = (*emission, 1.0)
        p.inputs["Emission Strength"].default_value = strength
    if alpha < 1.0:
        p.inputs["Alpha"].default_value = alpha
        try:
            m.surface_render_method = "BLENDED"
        except (AttributeError, TypeError):
            m.blend_method = "BLEND"
    return m


def image_material(name, path, emission_strength=0.0, closest=True, alpha=True):
    """An unlit-looking decal: the image as base colour (and emission), alpha from the image"""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    p = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(str(path))
    tex.interpolation = "Closest" if closest else "Linear"
    nt.links.new(tex.outputs["Color"], p.inputs["Base Color"])
    if alpha:
        nt.links.new(tex.outputs["Alpha"], p.inputs["Alpha"])
    if emission_strength > 0:
        nt.links.new(tex.outputs["Color"], p.inputs["Emission Color"])
        p.inputs["Emission Strength"].default_value = emission_strength
    p.inputs["Roughness"].default_value = 0.4
    if not alpha:
        return m
    try:
        m.surface_render_method = "BLENDED"
    except (AttributeError, TypeError):
        m.blend_method = "BLEND"
    return m


def mesh_object(name, bm, mat=None, parent=None):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    if mat:
        me.materials.append(mat)
    if parent:
        ob.parent = parent
    return ob


def box(name, x0, y0, z0, x1, y1, z1, mat=None, parent=None, bevel=0.0):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector(((x0 + x1) / 2 + v.co.x * (x1 - x0), (y0 + y1) / 2 + v.co.y * (y1 - y0), (z0 + z1) / 2 + v.co.z * (z1 - z0)))
    ob = mesh_object(name, bm, mat, parent)
    if bevel > 0:
        add_bevel(ob, bevel)
    return ob


def cylinder(name, x, y, z, r, depth, axis="Y", mat=None, parent=None, segs=24, bevel=0.0):
    """Cylinder centred at (x, y, z) along `axis`"""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segs, radius1=r, radius2=r, depth=depth)
    rot = {"X": (0, math.pi / 2, 0), "Y": (math.pi / 2, 0, 0), "Z": (0, 0, 0)}[axis]
    from mathutils import Euler
    m = Euler(rot).to_matrix().to_4x4()
    bmesh.ops.transform(bm, matrix=m, verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector((x, y, z)), verts=bm.verts)
    ob = mesh_object(name, bm, mat, parent)
    if bevel > 0:
        add_bevel(ob, bevel)
    return ob


def add_bevel(ob, width, segments=2):
    mod = ob.modifiers.new("Bevel", "BEVEL")
    mod.width = width
    mod.segments = segments
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(40)
    ob.modifiers.new("WeightedNormal", "WEIGHTED_NORMAL").keep_sharp = True
    return mod


def prism(name, poly_xz, y0, y1, mat=None, parent=None, bevel=0.0):
    """Extrude a front-view outline (list of (x, z), counter-clockwise seen from the front) from y0 to y1"""
    bm = bmesh.new()
    front = [bm.verts.new((x, y0, z)) for x, z in poly_xz]
    back = [bm.verts.new((x, y1, z)) for x, z in poly_xz]
    n = len(poly_xz)
    bm.faces.new(front)
    bm.faces.new(back[::-1])
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[j], front[i], back[i], back[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = mesh_object(name, bm, mat, parent)
    if bevel > 0:
        add_bevel(ob, bevel)
    return ob


def ring_prism(name, outer_xz, inner_xz, y0, y1, mat=None, parent=None, bevel=0.0):
    """A frame: the band between two outlines with the same vertex count, extruded from y0 to y1"""
    bm = bmesh.new()
    n = len(outer_xz)
    of = [bm.verts.new((x, y0, z)) for x, z in outer_xz]
    inf = [bm.verts.new((x, y0, z)) for x, z in inner_xz]
    ob_ = [bm.verts.new((x, y1, z)) for x, z in outer_xz]
    ib = [bm.verts.new((x, y1, z)) for x, z in inner_xz]
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((of[i], of[j], inf[j], inf[i]))
        bm.faces.new((ob_[j], ob_[i], ib[i], ib[j]))
        bm.faces.new((of[j], of[i], ob_[i], ob_[j]))
        bm.faces.new((inf[i], inf[j], ib[j], ib[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = mesh_object(name, bm, mat, parent)
    if bevel > 0:
        add_bevel(ob, bevel)
    return ob


def offset_poly(poly, d):
    """Inset a convex counter-clockwise polygon by d (each edge moved inward, neighbours intersected)"""
    n = len(poly)
    lines = []
    for i in range(n):
        a, b = Vector(poly[i]), Vector(poly[(i + 1) % n])
        e = (b - a).normalized()
        nrm = Vector((-e.y, e.x))                       # left of the edge: inside for CCW
        lines.append((a + nrm * d, e))
    out = []
    for i in range(n):
        p1, d1 = lines[i - 1]
        p2, d2 = lines[i]
        den = d1.x * d2.y - d1.y * d2.x
        t = ((p2.x - p1.x) * d2.y - (p2.y - p1.y) * d2.x) / den
        out.append(tuple(p1 + d1 * t))
    return out


def clip_poly(poly, keep):
    """Sutherland-Hodgman against one line: keep(p) -> signed value, kept where >= 0"""
    out = []
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        fa, fb = keep(a), keep(b)
        if fa >= 0:
            out.append(a)
        if (fa >= 0) != (fb >= 0):
            t = fa / (fa - fb)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def tube_path(name, pts, radius, mat=None, parent=None, cyclic=True, bevel_res=6):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    sp = cu.splines.new("POLY")
    sp.points.add(len(pts) - 1)
    for p, co in zip(sp.points, pts):
        p.co = (*co, 1.0)
    sp.use_cyclic_u = cyclic
    cu.bevel_depth = radius
    cu.bevel_resolution = bevel_res
    cu.fill_mode = "FULL"
    ob = bpy.data.objects.new(name, cu)
    bpy.context.scene.collection.objects.link(ob)
    if mat:
        cu.materials.append(mat)
    if parent:
        ob.parent = parent
    return to_mesh(ob)


def text(name, body, size, depth, x, y, z, mat=None, parent=None, font=VCR_FONT, spacing=1.0):
    """Extruded text, centred on x, its baseline at z, front face at y, facing -Y"""
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    cu.size = size
    cu.extrude = depth / 2
    cu.align_x = "CENTER"
    cu.space_character = spacing
    if font and Path(font).exists():
        cu.font = bpy.data.fonts.load(str(font))
    ob = bpy.data.objects.new(name, cu)
    bpy.context.scene.collection.objects.link(ob)
    ob.rotation_euler = (math.pi / 2, 0, 0)            # text lies in XY; stand it up facing -Y
    ob.location = (x, y - depth / 2, z)
    if mat:
        cu.materials.append(mat)
    if parent:
        ob.parent = parent
    return to_mesh(ob)


def to_mesh(ob):
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    new = bpy.data.objects.new(ob.name, me)
    bpy.context.scene.collection.objects.link(new)
    new.matrix_world = ob.matrix_world.copy()
    new.parent = ob.parent
    if new.parent:
        new.matrix_parent_inverse = ob.matrix_parent_inverse.copy()
    name = ob.name
    bpy.data.objects.remove(ob)
    new.name = name
    return new


def empty(name, loc, parent=None, size=0.1):
    e = bpy.data.objects.new(name, None)
    e.empty_display_size = size
    e.location = loc
    bpy.context.scene.collection.objects.link(e)
    if parent:
        e.parent = parent
    return e


def stats():
    tris = 0
    dg = bpy.context.evaluated_depsgraph_get()
    for ob in bpy.context.scene.objects:
        if ob.type == "MESH":
            me = ob.evaluated_get(dg).to_mesh()
            me.calc_loop_triangles()
            tris += len(me.loop_triangles)
            ob.evaluated_get(dg).to_mesh_clear()
    return tris


def save_and_export(stem):
    BLEND_DIR.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_DIR / f"{stem}.blend"))
    out = OUT_DIR / f"{stem}.glb"
    bpy.ops.export_scene.gltf(filepath=str(out), export_format="GLB", export_apply=True, export_yup=True,
                              export_cameras=False, export_lights=False, use_visible=True)
    print(f"exported {out}  ({stats()} triangles)")
    return out


def preview(out_dir, stem, target_center, size, views=(("front", (0, -1, 0.05)), ("three_quarter", (0.7, -1, 0.35)))):
    """EEVEE stills of the prop on a dark set, written to out_dir/<stem>_<view>.png"""
    sc = bpy.context.scene
    hidden = []
    for ob in sc.objects:                              # collision helpers stay out of the pictures
        if ob.name.endswith("-convcolonly") or ob.name.endswith("-colonly"):
            ob.hide_render = True
            hidden.append(ob)
    try:
        sc.render.engine = "BLENDER_EEVEE"
    except TypeError:
        sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = 900, 900
    sc.render.film_transparent = False
    try:
        sc.view_settings.view_transform = "Standard"   # closer to the game than AgX
    except TypeError:
        pass
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = (0.02, 0.022, 0.025, 1)
    bg.inputs["Strength"].default_value = 1.0
    sc.world = world
    c = Vector(target_center)
    for name, energy, loc in (("Key", 900, (2.5, -3.0, 3.0)), ("Fill", 250, (-3.0, -2.0, 1.5)), ("Rim", 400, (0.0, 3.0, 3.0))):
        ld = bpy.data.lights.new(name, "AREA")
        ld.energy = energy * size * size
        ld.size = 2.0 * size
        lo = bpy.data.objects.new(name, ld)
        lo.location = c + Vector(loc) * size
        lo.rotation_euler = (c - lo.location).to_track_quat("-Z", "Y").to_euler()
        sc.collection.objects.link(lo)
    cam_d = bpy.data.cameras.new("Cam")
    cam_d.lens = 50
    cam = bpy.data.objects.new("Cam", cam_d)
    sc.collection.objects.link(cam)
    sc.camera = cam
    os.makedirs(out_dir, exist_ok=True)
    for name, d in views:
        d = Vector(d).normalized()
        cam.location = c + d * size * 2.6
        cam.rotation_euler = (c - cam.location).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = os.path.join(out_dir, f"{stem}_{name}.png")
        bpy.ops.render.render(write_still=True)
    for ob in hidden:
        ob.hide_render = False
