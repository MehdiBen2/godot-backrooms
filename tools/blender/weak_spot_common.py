"""Shared bits for the weak-spot wall hole builders (build_weak_spot.py, build_weak_spot_decals.py).

Run those headless, apart from any Blender session that is open:
    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --factory-startup --python tools/blender/build_weak_spot.py -- <preview dir> [parts]

Blender space here: Z up; the wall face is the plane x = 0, +X points out of the wall into the room, Y runs along the
wall. The glTF export (Y up) turns that into Godot's x = x, y = z, z = -y, so a Godot "along the wall" z is -Blender y.
Every procedural material is baked by Cycles into image textures (albedo with baked AO, roughness, OpenGL normal),
which the .glb then embeds.
"""
import json
import math
import os
import random
import struct
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Euler, Matrix, Vector

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "godot-backrooms"
OUT_DIR = GAME / "models" / "props" / "weak_spot"
TEX_DIR = GAME / "textures" / "weak_spot"
SRC_DIR = ROOT / "assetsimported" / "weak_spot"        # gitignored: baked maps, .blend sources
WALL_COLOR = GAME / "textures" / "wall_color.png"
WALL_NORMAL = GAME / "textures" / "wall_normal.png"
WALL_ROUGH = GAME / "textures" / "wall_rough.png"
CARPET = GAME / "textures" / "l0_carpet_color.webp"

WALL_H = 5.4            # wall_wallpaper.gdshader: wall_h
PAPER_W = 2.25          # one texture width along the wall (per_m_u = 1 / 2.25)
SKIRT_HIDE = 0.14       # the texture's baked skirting band is never shown
PAPER_TINT = (1.0, 0.98, 0.88)

HOLE_W = 0.9            # the cut in the wall: Godot z in [-0.45, 0.45], y in [0, 2.1]
HOLE_H = 2.1


def srgb(r, g, b, a=1.0):
    f = lambda c: c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (f(r / 255.0), f(g / 255.0), f(b / 255.0), a)


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = "METRIC"
    return sc


# ---------------------------------------------------------------------------------------------------------------
# node building

class NB:
    """Tiny shader-graph builder: every call returns an output socket (or a node for textures)"""

    def __init__(self, mat):
        mat.use_nodes = True
        self.mat = mat
        self.nt = mat.node_tree
        self.nt.nodes.clear()
        self.out = self.nt.nodes.new("ShaderNodeOutputMaterial")
        self.bsdf = self.nt.nodes.new("ShaderNodeBsdfPrincipled")
        self.nt.links.new(self.bsdf.outputs[0], self.out.inputs[0])

    def node(self, t, **kw):
        n = self.nt.nodes.new(t)
        for k, v in kw.items():
            setattr(n, k, v)
        return n

    def set(self, sock, v):
        if isinstance(v, bpy.types.NodeSocket):
            self.nt.links.new(v, sock)
        elif v is not None:
            if isinstance(v, (int, float)) and hasattr(sock.default_value, "__len__"):
                n = len(sock.default_value)
                sock.default_value = (v,) * n if n != 4 else (v, v, v, 1.0)
            else:
                sock.default_value = v

    def math(self, op, a, b=0.0, c=None, clamp=False):
        n = self.node("ShaderNodeMath", operation=op, use_clamp=clamp)
        self.set(n.inputs[0], a)
        self.set(n.inputs[1], b)
        if c is not None:
            self.set(n.inputs[2], c)
        return n.outputs[0]

    def add(self, a, b): return self.math("ADD", a, b)
    def sub(self, a, b): return self.math("SUBTRACT", a, b)
    def mul(self, a, b): return self.math("MULTIPLY", a, b)

    def vmath(self, op, a, b=None, scale=None):
        n = self.node("ShaderNodeVectorMath", operation=op)
        self.set(n.inputs[0], a)
        if b is not None:
            self.set(n.inputs[1], b)
        if scale is not None:
            self.set(n.inputs["Scale"], scale)
        return n.outputs["Value"] if op in ("LENGTH", "DOT_PRODUCT", "DISTANCE") else n.outputs["Vector"]

    def vscale(self, v, s):
        """component-wise scale by a 3-tuple"""
        return self.vmath("MULTIPLY", v, s)

    def mix(self, fac, a, b, blend="MIX", clamp=True):
        n = self.node("ShaderNodeMix", data_type="RGBA", blend_type=blend, clamp_factor=clamp)
        self.set(n.inputs[0], fac)
        self.set(n.inputs[6], a)
        self.set(n.inputs[7], b)
        return n.outputs[2]

    def lerp(self, fac, a, b):
        n = self.node("ShaderNodeMix", data_type="FLOAT", clamp_factor=True)
        self.set(n.inputs[0], fac)
        self.set(n.inputs[2], a)
        self.set(n.inputs[3], b)
        return n.outputs[0]

    def noise(self, vec, scale, detail=2.0, rough=0.5, dist=0.0, lac=2.0, dims="3D", w=None):
        n = self.node("ShaderNodeTexNoise", noise_dimensions=dims)
        self.set(n.inputs["Vector"], vec)
        self.set(n.inputs["Scale"], scale)
        self.set(n.inputs["Detail"], detail)
        self.set(n.inputs["Roughness"], rough)
        self.set(n.inputs["Lacunarity"], lac)
        self.set(n.inputs["Distortion"], dist)
        if w is not None:
            self.set(n.inputs["W"], w)
        return n

    def voronoi(self, vec, scale, feature="F1", metric="EUCLIDEAN", rand=1.0, dims="3D"):
        n = self.node("ShaderNodeTexVoronoi", feature=feature, distance=metric, voronoi_dimensions=dims)
        self.set(n.inputs["Vector"], vec)
        self.set(n.inputs["Scale"], scale)
        self.set(n.inputs["Randomness"], rand)
        return n

    def ramp(self, fac, stops, interp="LINEAR"):
        n = self.node("ShaderNodeValToRGB")
        n.color_ramp.interpolation = interp
        els = n.color_ramp.elements
        while len(els) > len(stops):
            els.remove(els[-1])
        while len(els) < len(stops):
            els.new(0.5)
        for e, (pos, col) in zip(els, stops):
            e.position = pos
            e.color = col if isinstance(col, tuple) and len(col) == 4 else ((col,) * 3 + (1.0,) if not isinstance(col, tuple) else (*col, 1.0))
        self.set(n.inputs[0], fac)
        return n.outputs[0]

    def mapr(self, v, a, b, c=0.0, d=1.0, clamp=True, smooth=False):
        n = self.node("ShaderNodeMapRange", clamp=clamp, interpolation_type="SMOOTHSTEP" if smooth else "LINEAR")
        self.set(n.inputs[0], v)
        n.inputs[1].default_value, n.inputs[2].default_value = a, b
        n.inputs[3].default_value, n.inputs[4].default_value = c, d
        return n.outputs[0]

    def sep(self, v):
        n = self.node("ShaderNodeSeparateXYZ")
        self.set(n.inputs[0], v)
        return n.outputs[0], n.outputs[1], n.outputs[2]

    def comb(self, x, y, z):
        n = self.node("ShaderNodeCombineXYZ")
        self.set(n.inputs[0], x)
        self.set(n.inputs[1], y)
        self.set(n.inputs[2], z)
        return n.outputs[0]

    def coord(self, kind="Object"):
        return self.node("ShaderNodeTexCoord").outputs[kind]

    def geo(self, kind):
        return self.node("ShaderNodeNewGeometry").outputs[kind]

    def rand(self):
        return self.node("ShaderNodeObjectInfo").outputs["Random"]

    def bump(self, height, strength=1.0, distance=0.002, normal=None):
        n = self.node("ShaderNodeBump")
        self.set(n.inputs["Height"], height)
        n.inputs["Strength"].default_value = strength
        n.inputs["Distance"].default_value = distance
        if normal is not None:
            self.set(n.inputs["Normal"], normal)
        return n.outputs[0]

    def image(self, path, colorspace="sRGB", vec=None, interp="Linear", ext="REPEAT"):
        n = self.node("ShaderNodeTexImage", interpolation=interp, extension=ext)
        n.image = load_image(path, colorspace)
        if vec is not None:
            self.set(n.inputs[0], vec)
        return n

    def finish(self, color, rough, normal=None, alpha=None, metallic=0.0):
        p = self.bsdf
        self.set(p.inputs["Base Color"], color)
        self.set(p.inputs["Roughness"], rough)
        self.set(p.inputs["Metallic"], metallic)
        if normal is not None:
            self.set(p.inputs["Normal"], normal)
        if alpha is not None:
            self.set(p.inputs["Alpha"], alpha)
        return self.mat


def load_image(path, colorspace="sRGB"):
    path = str(path)
    for im in bpy.data.images:
        if im.filepath and os.path.normcase(bpy.path.abspath(im.filepath)) == os.path.normcase(path) and im.colorspace_settings.name == colorspace:
            return im
    im = bpy.data.images.load(path, check_existing=False)
    im.colorspace_settings.name = colorspace
    return im


def new_mat(name):
    m = bpy.data.materials.new(name)
    return m, NB(m)


# ---------------------------------------------------------------------------------------------------------------
# meshes

def link(ob):
    bpy.context.scene.collection.objects.link(ob)
    return ob


def mesh_from_bm(name, bm, mats=()):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    ob = link(bpy.data.objects.new(name, me))
    return ob


def board(name, length, width, thick, mat, segs=6, jitter=0.0015, bow=0.0, twist=0.0, bevel=0.004, end_rough=0.0,
          rng=None, bevel_segs=1):
    """A wooden board along local +X (from 0 to length), width along local Y (centred), thickness along local Z
    (centred). Subdivided along its length, warped a little (bow along Z, twist about X), edges chamfered."""
    rng = rng or random.Random(1)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x + 0.5, v.co.y * width, v.co.z * thick))
    # cut along the length
    edges = [e for e in bm.edges if abs(e.verts[0].co.x - e.verts[1].co.x) > 0.5]
    bmesh.ops.subdivide_edges(bm, edges=edges, cuts=segs - 1, use_grid_fill=True)
    for v in bm.verts:
        t = v.co.x
        x = t * length
        y, z = v.co.y, v.co.z
        # twist and bow
        a = twist * (t - 0.5)
        y, z = y * math.cos(a) - z * math.sin(a), y * math.sin(a) + z * math.cos(a)
        z += bow * (1.0 - (2.0 * t - 1.0) ** 2)
        y += rng.uniform(-jitter, jitter)
        z += rng.uniform(-jitter, jitter) * 0.6
        if end_rough and (t < 1e-4 or t > 1 - 1e-4):
            x += rng.uniform(-end_rough, end_rough)
        v.co = Vector((x, y, z))
    ob = mesh_from_bm(name, bm, [mat])
    ob["bw"], ob["bt"] = width, thick
    if bevel > 0:
        mod = ob.modifiers.new("Bevel", "BEVEL")
        mod.width = bevel
        mod.segments = bevel_segs
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(50)
        mod.harden_normals = False
    return ob


def uv_board(ob, width, thick):
    """Wrap a board's UVs around its length (local X): one long strip island (u = x, v = distance round the
    section), the two end faces planar. Call on the modifier-applied mesh, before uv_unwrap()."""
    me = ob.data
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uvl = me.uv_layers.active.data
    hw, ht = width / 2, thick / 2
    per = 2 * (width + thick)

    def around(y, z):
        # nearest point on the rectangle's outline, as arc length from (-hw, -ht) going +y first
        y = max(-hw, min(hw, y))
        z = max(-ht, min(ht, z))
        d = {"b": abs(z + ht), "r": abs(y - hw), "t": abs(z - ht), "l": abs(y + hw)}
        s = min(d, key=d.get)
        if s == "b":
            return y + hw
        if s == "r":
            return width + z + ht
        if s == "t":
            return width + thick + (hw - y)
        return 2 * width + thick + (ht - z)

    xs = [v.co.x for v in me.vertices]
    x0, x1 = min(xs), max(xs)
    for p in me.polygons:
        if abs(p.normal.x) > 0.85:          # end grain: planar, its own island
            for li in p.loop_indices:
                co = me.vertices[me.loops[li].vertex_index].co
                uvl[li].uv = (co.y + 10.0, co.z + 10.0)
            continue
        vs = []
        for li in p.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            vs.append((li, co.x, around(co.y, co.z)))
        vals = [v for _, _, v in vs]
        if max(vals) - min(vals) > per / 2:
            vs = [(li, x, v + per if v < per / 2 else v) for li, x, v in vs]
        for li, x, v in vs:
            uvl[li].uv = (x, v)
    ob["uv_done"] = True


def place(ob, loc=(0, 0, 0), rot=(0, 0, 0)):
    from mathutils import Euler
    ob.location = loc
    ob.rotation_euler = Euler(rot)
    return ob


AX = {"X": (1, 0, 0), "-X": (-1, 0, 0), "Y": (0, 1, 0), "-Y": (0, -1, 0), "Z": (0, 0, 1), "-Z": (0, 0, -1)}


def orient(ob, lx, ly, loc, extra=None):
    """Point the object's local X along world axis lx and local Y along ly (e.g. "Z", "X"), then move it to loc.
    extra: a small Euler (radians) applied in local space first, for slight lean / skew."""
    a, b = Vector(AX[lx]), Vector(AX[ly])
    c = a.cross(b)
    m = Matrix((a, b, c)).transposed().to_4x4()
    if extra:
        m = m @ Euler(extra).to_matrix().to_4x4()
    m.translation = Vector(loc)
    ob.matrix_world = m
    return ob


def apply_all(obs, transforms=False):
    """Apply modifiers (and, with transforms=True, the transforms: mesh data in world space). The wood keeps its
    transforms until after baking: its grain is computed in object space."""
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    out = []
    for ob in obs:
        if ob.type != "MESH" or ob.modifiers:
            me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
            new = link(bpy.data.objects.new(ob.name + "_m", me))
            new.matrix_world = ob.matrix_world.copy()
            for k in ob.keys():
                new[k] = ob[k]
            name = ob.name
            bpy.data.objects.remove(ob)
            new.name = name
            ob = new
        if "bw" in ob.keys() and not ob.get("uv_done"):
            uv_board(ob, ob["bw"], ob["bt"])
        if transforms:
            ob.data.transform(ob.matrix_world)
            ob.matrix_world = Matrix.Identity(4)
        out.append(ob)
    return out


def delete_faces(ob, pred):
    """Remove faces whose (centre, normal) in world space satisfy pred"""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    mw = ob.matrix_world
    m3 = mw.to_3x3()
    dead = [f for f in bm.faces if pred(mw @ f.calc_center_median(), (m3 @ f.normal).normalized())]
    bmesh.ops.delete(bm, geom=dead, context="FACES")
    bm.to_mesh(ob.data)
    bm.free()
    return len(dead)


def select_only(obs, active=None):
    bpy.ops.object.select_all(action="DESELECT")
    for o in obs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or obs[0]


def join(obs, name):
    select_only(obs)
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob


def tri_count(obs):
    t = 0
    for o in obs:
        o.data.calc_loop_triangles()
        t += len(o.data.loop_triangles)
    return t


# ---------------------------------------------------------------------------------------------------------------
# baking

def setup_cycles(samples=8):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = False
    sc.render.threads_mode = "FIXED"         # leave the machine usable while it bakes
    sc.render.threads = max(1, (os.cpu_count() or 4) // 2)
    return sc


def uv_unwrap(obs, weights=None, margin=0.006, angle=66.0):
    """Smart-project every object, scale each object's islands by weights[name] (texel priority), then pack all of
    them together into one 0..1 square."""
    todo = [o for o in obs if not o.get("uv_done")]
    if todo:
        select_only(todo)
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.smart_project(angle_limit=math.radians(angle), island_margin=0.0, area_weight=0.0,
                                 scale_to_bounds=False)
        bpy.ops.object.mode_set(mode="OBJECT")
    # smart_project gives each object its own 0..1 scale; put them all on one world-space texel density first
    for o in obs:
        uvl = o.data.uv_layers.active.data
        me = o.data
        area3 = sum(p.area for p in me.polygons)
        area2 = 0.0
        for p in me.polygons:
            pts = [uvl[i].uv for i in p.loop_indices]
            a = 0.0
            for i in range(len(pts)):
                a += pts[i].x * pts[(i + 1) % len(pts)].y - pts[(i + 1) % len(pts)].x * pts[i].y
            area2 += abs(a) * 0.5
        s = math.sqrt(area3 / max(area2, 1e-9))
        if weights:
            s *= weights.get(o.name, weights.get("*", 1.0))
        for l in uvl:
            l.uv = l.uv * s
    select_only(obs)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(margin=margin, rotate=True, scale=True)
    bpy.ops.object.mode_set(mode="OBJECT")


def texel_density(ob, size):
    """pixels per metre of the object's UVs on a size x size map"""
    uvl = ob.data.uv_layers.active.data
    a3 = sum(p.area for p in ob.data.polygons)
    a2 = 0.0
    for p in ob.data.polygons:
        pts = [uvl[i].uv for i in p.loop_indices]
        a = 0.0
        for i in range(len(pts)):
            a += pts[i].x * pts[(i + 1) % len(pts)].y - pts[(i + 1) % len(pts)].x * pts[i].y
        a2 += abs(a) * 0.5
    return size * math.sqrt(a2 / max(a3, 1e-9))


def _new_img(name, size, noncolor, alpha=False):
    im = bpy.data.images.new(name, size, size, alpha=alpha, float_buffer=False)
    if noncolor:
        im.colorspace_settings.name = "Non-Color"
    return im


def _target(obs, im):
    for o in obs:
        for m in o.data.materials:
            nt = m.node_tree
            t = nt.nodes.get("__bake__") or nt.nodes.new("ShaderNodeTexImage")
            t.name = "__bake__"
            t.image = im
            for n in nt.nodes:
                n.select = False
            t.select = True
            nt.nodes.active = t


def _save(im, path):
    im.filepath_raw = str(path)
    im.file_format = "PNG"
    im.save()


def bake_atlas(obs, stem, size, ao_amount=0.75, ao_dist=0.25, samples=2, ao_samples=12, margin=16, alpha_from=None,
               keep_roughness=None):
    """Bake every material on `obs` (already UV-packed into one square) into stem_{albedo,rough,normal}.png
    under SRC_DIR, albedo multiplied by baked AO. Returns the baked material (assigned to every object)."""
    SRC_DIR.mkdir(parents=True, exist_ok=True)
    sc = setup_cycles(samples)
    sc.render.bake.margin = margin
    sc.render.bake.use_clear = True
    select_only(obs)
    paths = {}
    # albedo
    im = _new_img(stem + "_albedo", size, False)
    _target(obs, im)
    bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, margin=margin, use_clear=True)
    alb = np.array(im.pixels[:], dtype=np.float32).reshape(size, size, 4)
    # roughness
    imr = _new_img(stem + "_rough", size, True)
    _target(obs, imr)
    bpy.ops.object.bake(type="ROUGHNESS", margin=margin, use_clear=True)
    # normal (tangent space, OpenGL +Y)
    imn = _new_img(stem + "_normal", size, True)
    _target(obs, imn)
    bpy.ops.object.bake(type="NORMAL", normal_space="TANGENT", margin=margin, use_clear=True)
    # ambient occlusion
    if ao_amount > 0:
        sc.cycles.samples = ao_samples
        bpy.context.scene.world = bpy.context.scene.world or bpy.data.worlds.new("W")
        bpy.context.scene.world.light_settings.distance = ao_dist
        ima = _new_img(stem + "_ao", size, True)
        _target(obs, ima)
        bpy.ops.object.bake(type="AO", margin=margin, use_clear=True)
        ao = np.array(ima.pixels[:], dtype=np.float32).reshape(size, size, 4)[..., :1]
        # albedo is linear in pixels[] for a byte sRGB image? pixels are the stored (sRGB-encoded) values: work there
        alb[..., :3] *= (1.0 - ao_amount) + ao_amount * ao
        _save(ima, SRC_DIR / f"{stem}_ao.png")
    if alpha_from is not None:
        alb[..., 3] = alpha_from
    im.pixels[:] = alb.ravel()
    paths["albedo"] = SRC_DIR / f"{stem}_albedo.png"
    paths["rough"] = SRC_DIR / f"{stem}_rough.png"
    paths["normal"] = SRC_DIR / f"{stem}_normal.png"
    _save(im, paths["albedo"])
    _save(imr, paths["rough"])
    _save(imn, paths["normal"])
    sc.cycles.samples = samples
    mat = baked_material(stem, paths)
    for o in obs:
        o.data.materials.clear()
        o.data.materials.append(mat)
    return mat


def baked_material(name, paths, alpha=False, double=False):
    m, nb = new_mat(name)
    a = nb.image(paths["albedo"], "sRGB")
    r = nb.image(paths["rough"], "Non-Color")
    n = nb.image(paths["normal"], "Non-Color")
    nm = nb.node("ShaderNodeNormalMap")
    nb.set(nm.inputs["Color"], n.outputs[0])
    nb.finish(a.outputs[0], r.outputs[0], nm.outputs[0], alpha=a.outputs[1] if alpha else None)
    m.use_backface_culling = not double
    if alpha:
        try:
            m.surface_render_method = "BLENDED"
        except (AttributeError, TypeError):
            m.blend_method = "BLEND"
    return m


def wallpaper_material(name="Wallpaper"):
    """The game's wallpaper on the rim / lip / shard / debris faces. Its UV0 is written to match
    wall_wallpaper.gdshader's world projection, so it can also simply be swapped for that ShaderMaterial."""
    m, nb = new_mat(name)
    uv = nb.coord("UV")
    a = nb.image(WALL_COLOR, "sRGB", uv)
    r = nb.image(WALL_ROUGH, "Non-Color", uv)
    n = nb.image(WALL_NORMAL, "Non-Color", uv)
    nm = nb.node("ShaderNodeNormalMap")
    nb.set(nm.inputs["Color"], n.outputs[0])
    nm.inputs["Strength"].default_value = 0.95
    col = nb.mix(1.0, a.outputs[0], (*PAPER_TINT, 1.0), blend="MULTIPLY")
    nb.finish(col, nb.mul(r.outputs[0], 0.95), nm.outputs[0])
    m.use_backface_culling = True
    return m


def wallpaper_uv(ob, mat_index, offset_along=0.0):
    """UV0 on the faces using material slot mat_index = the shader's world projection from each vertex's
    position: u = along / 2.25 (along = Godot z = -Blender y), v (glTF, down) = min(1 - up / 5.4, 1 - 0.14 / 5.4),
    i.e. Blender v = max(up / 5.4, 0.14 / 5.4)."""
    me = ob.data
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uvl = me.uv_layers.active.data
    for p in me.polygons:
        if p.material_index != mat_index:
            continue
        for li in p.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uvl[li].uv = ((-co.y + offset_along) / PAPER_W, max(co.z / WALL_H, SKIRT_HIDE / WALL_H))


# ---------------------------------------------------------------------------------------------------------------
# export and checks

def export_glb(obs, path):
    select_only(obs)
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", export_yup=True, export_apply=True,
                              use_selection=True, export_cameras=False, export_lights=False,
                              export_image_format="AUTO")
    print("exported", path, "%.1f MB" % (os.path.getsize(path) / 1e6))
    return path


def glb_report(path):
    """Read the glb back: per node (Godot axes) bounding box, triangle count, materials; images embedded"""
    b = open(path, "rb").read()
    n = struct.unpack("<I", b[12:16])[0]
    j = json.loads(b[20:20 + n])
    lines = [f"{Path(path).name}: {os.path.getsize(path) / 1e6:.1f} MB, {len(j.get('images', []))} images embedded"]
    tot = 0
    for nd in j["nodes"]:
        if "mesh" not in nd:
            lines.append(f"  node {nd['name']} (no mesh)")
            continue
        t = Vector(nd.get("translation", (0, 0, 0)))
        mesh = j["meshes"][nd["mesh"]]
        lo = Vector((1e9,) * 3)
        hi = Vector((-1e9,) * 3)
        tris = 0
        mats = []
        for pr in mesh["primitives"]:
            acc = j["accessors"][pr["attributes"]["POSITION"]]
            lo = Vector(map(min, lo, acc["min"]))
            hi = Vector(map(max, hi, acc["max"]))
            tris += j["accessors"][pr["indices"]]["count"] // 3
            mt = j["materials"][pr["material"]]
            mats.append("%s[%s%s%s%s]" % (mt["name"], "N" if "normalTexture" in mt else "-",
                                         "R" if "metallicRoughnessTexture" in mt.get("pbrMetallicRoughness", {}) else "-",
                                         " " + mt.get("alphaMode", "OPAQUE"), " 2side" if mt.get("doubleSided") else ""))
        tot += tris
        if "rotation" in nd or "scale" in nd:
            lines.append(f"  !! node {nd['name']} has rotation/scale {nd.get('rotation')} {nd.get('scale')}")
        lo, hi = lo + t, hi + t
        lines.append(f"  node {nd['name']}: origin ({t.x:.3f}, {t.y:.3f}, {t.z:.3f})  bbox x[{lo.x:.3f},{hi.x:.3f}] "
                     f"y[{lo.y:.3f},{hi.y:.3f}] z[{lo.z:.3f},{hi.z:.3f}]  {tris} tris  {', '.join(mats)}")
    lines.append(f"  total {tot} tris")
    s = "\n".join(lines)
    print(s)
    return s


# ---------------------------------------------------------------------------------------------------------------
# preview renders

def preview_setup(engine="CYCLES", res=(1280, 720), samples=64):
    sc = bpy.context.scene
    if engine == "CYCLES":
        setup_cycles(samples)
        sc.cycles.use_denoising = True
        try:
            sc.cycles.denoiser = "OPENIMAGEDENOISE"
        except TypeError:
            pass
        sc.cycles.max_bounces = 6
    else:
        try:
            sc.render.engine = "BLENDER_EEVEE"
        except TypeError:
            sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.film_transparent = False
    try:
        sc.view_settings.view_transform = "AgX"
        sc.view_settings.look = "AgX - Medium High Contrast"
    except TypeError:
        pass
    w = bpy.data.worlds.new("Pw")
    w.use_nodes = True
    bg = next(n for n in w.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = (0.02, 0.02, 0.018, 1)
    bg.inputs["Strength"].default_value = 1.0
    sc.world = w
    cam_d = bpy.data.cameras.new("PCam")
    cam_d.lens = 28
    cam_d.clip_start = 0.02
    cam = link(bpy.data.objects.new("PCam", cam_d))
    sc.camera = cam
    return sc, cam


def area_light(name, loc, target, energy, size, color=(1.0, 0.95, 0.82)):
    ld = bpy.data.lights.new(name, "AREA")
    ld.energy = energy
    ld.size = size
    ld.color = color
    lo = link(bpy.data.objects.new(name, ld))
    lo.location = loc
    lo.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    return lo


def point_light(name, loc, energy, radius=0.05, color=(1.0, 0.95, 0.85)):
    ld = bpy.data.lights.new(name, "POINT")
    ld.energy = energy
    ld.shadow_soft_size = radius
    ld.color = color
    lo = link(bpy.data.objects.new(name, ld))
    lo.location = loc
    return lo


def shoot(cam, loc, target, path, lens=None):
    cam.location = loc
    cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    if lens:
        cam.data.lens = lens
    sc = bpy.context.scene
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sc.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    print("rendered", path)


# ---------------------------------------------------------------------------------------------------------------
# numpy drawing (cobweb, decals)

def gauss_blur(a, sigma):
    if sigma <= 0.05:
        return a
    r = max(1, int(math.ceil(sigma * 3)))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    out = np.zeros_like(a)
    for i, w in enumerate(k):
        out += w * np.roll(a, i - r, axis=0)
    out2 = np.zeros_like(a)
    for i, w in enumerate(k):
        out2 += w * np.roll(out, i - r, axis=1)
    return out2


def splat_lines(shape, lines, sigma, peak=1.0):
    """lines: list of (N, 2) float arrays in pixel (x, y) coords. Returns a float image with each line drawn as a
    soft stroke of the given gaussian sigma and roughly `peak` intensity at its centre"""
    acc = np.zeros(shape, np.float32)
    hgt, wid = shape
    for pts in lines:
        pts = np.asarray(pts, np.float32)
        seg = np.diff(pts, axis=0)
        ln = np.hypot(seg[:, 0], seg[:, 1])
        for p0, d, l in zip(pts[:-1], seg, ln):
            n = max(2, int(l / 0.4))
            t = (np.arange(n) + 0.5) / n
            q = p0[None, :] + d[None, :] * t[:, None]
            x0 = np.floor(q[:, 0]).astype(int)
            y0 = np.floor(q[:, 1]).astype(int)
            fx = q[:, 0] - x0
            fy = q[:, 1] - y0
            wgt = l / n
            for dx, dy, ww in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
                xi = np.clip(x0 + dx, 0, wid - 1)
                yi = np.clip(y0 + dy, 0, hgt - 1)
                np.add.at(acc, (yi, xi), ww * wgt)
    acc = gauss_blur(acc, sigma)
    return acc * (math.sqrt(2 * math.pi) * max(sigma, 0.5)) * peak


def save_rgba(path, rgba):
    """rgba: (H, W, 4) float, row 0 = TOP of the image"""
    h, w = rgba.shape[:2]
    im = bpy.data.images.new(os.path.splitext(os.path.basename(str(path)))[0], w, h, alpha=True)
    im.pixels[:] = np.flipud(np.clip(rgba, 0, 1)).astype(np.float32).ravel()
    im.filepath_raw = str(path)
    im.file_format = "PNG"
    im.save()
    return im
