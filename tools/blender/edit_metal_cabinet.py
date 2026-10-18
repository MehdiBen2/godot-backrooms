"""The metal cabinet hiding spot (godot-backrooms/scripts/World/props/hide_spot.gd), remade from the source model.

The source (asetsuimprot/neww/metal_cabinet_low_poly.glb) has both doors in one mesh, the right one standing about
7.6 degrees ajar, and solid vents. This splits it into:
  Body       the carcass and the hinges (they stay put)
  Door_L     the left leaf, its louvres and handle; its origin on its hinge
  Door_R     the right leaf, closed flush, its louvres and handle; its origin on its hinge (the one you hide behind)
and opens the vents: the sheet behind the louvres is cut away and the louvres made narrower, so from inside you
see out between them. The right-hand side's hat shelf is taken out (it sat at eye height). Metalness is capped at 0.3 (the file's own reads near black without reflections).

blender --background --python tools/blender/edit_metal_cabinet.py
"""
import bpy, bmesh, json, math, os, struct
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "asetsuimprot", "neww", "metal_cabinet_low_poly.glb")
OUT = os.path.join(ROOT, "godot-backrooms", "models", "props", "storage", "metal_cabinet.glb")

# Blender axes (Z up, the front faces -Y), metres as the file has them
HINGE_R = Vector((0.513, -0.198, 0.0))      # the right leaf's hinge pins (outer right edge)
HINGE_L = Vector((-0.0325, -0.2025, 0.0))   # the left leaf's (it hangs from the middle)
LEAF_PLANE_Y = -0.207                       # where a closed leaf sits (the left one does already)
VENT_X = (0.149, 0.402)                     # the louvred panel on each leaf, |x|
VENT_Z = (0.568, 0.815)
LOUVRE_KEEP = 0.6                           # how much of each louvre's height is left

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)

# flatten: every mesh in world space, no empties
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
for o in meshes:
    mw = o.matrix_world.copy()
    o.parent = None
    o.matrix_world = mw
    o.data.transform(o.matrix_world)
    o.matrix_world = Matrix.Identity(4)
for o in [o for o in bpy.data.objects if o.type != "MESH"]:
    bpy.data.objects.remove(o)
by_mat = {o.data.materials[0].name: o for o in meshes}
body, door, hw = by_mat["Dolap"], by_mat["Kapak"], by_mat["Kulp_Mentese"]


def islands(bm):
    seen, out = set(), []
    for v in bm.verts:
        if v in seen: continue
        stack, comp = [v], []
        seen.add(v)
        while stack:
            x = stack.pop()
            comp.append(x)
            for e in x.link_edges:
                y = e.other_vert(x)
                if y not in seen:
                    seen.add(y)
                    stack.append(y)
        out.append(comp)
    return out


def split(obj, pick):
    """Moves the islands `pick(centre, size, n)` says yes to out of `obj` into a new object; returns it."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    keep = bmesh.new()
    keep.from_mesh(obj.data)
    take_idx = set()
    for comp in islands(bm):
        lo = Vector((min(v.co.x for v in comp), min(v.co.y for v in comp), min(v.co.z for v in comp)))
        hi = Vector((max(v.co.x for v in comp), max(v.co.y for v in comp), max(v.co.z for v in comp)))
        if pick((lo + hi) * 0.5, hi - lo, len(comp)):
            take_idx.update(v.index for v in comp)
    keep.verts.ensure_lookup_table()
    bmesh.ops.delete(keep, geom=[keep.verts[i] for i in take_idx], context="VERTS")
    bm.verts.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.index not in take_idx], context="VERTS")
    me = obj.data.copy()
    bm.to_mesh(me)
    keep.to_mesh(obj.data)
    new = bpy.data.objects.new(obj.name + "_part", me)
    bpy.context.collection.objects.link(new)
    return new


def join(parts, name):
    bpy.ops.object.select_all(action="DESELECT")
    for p in parts: p.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    o.name = name
    o.data.name = name
    return o


# the doors: each leaf with its louvres (left: x < 0)
door_r = split(door, lambda c, s, n: c.x > 0.0)
door_l = door
# the handles go with their leaves; the hinge pins stay with the body
handle_r = split(hw, lambda c, s, n: 0.06 < c.x < 0.11)
handle_l = split(hw, lambda c, s, n: -0.49 < c.x < -0.44)


def open_vents(obj, side):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    comps = islands(bm)
    leaf = set(max(comps, key=len))
    lo_x, hi_x = (VENT_X if side > 0 else (-VENT_X[1], -VENT_X[0]))
    # the sheet behind the louvres
    gone = [f for f in bm.faces if all(v in leaf for v in f.verts)
            and lo_x < f.calc_center_median().x < hi_x and VENT_Z[0] < f.calc_center_median().z < VENT_Z[1]]
    bmesh.ops.delete(bm, geom=gone, context="FACES_ONLY")
    # the louvres: thinner, so there is more gap between them
    for comp in comps:
        if len(comp) > 8: continue
        zc = sum(v.co.z for v in comp) / len(comp)
        for v in comp:
            v.co.z = zc + (v.co.z - zc) * LOUVRE_KEEP
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.to_mesh(obj.data)


# the hat shelf in the right-hand side sits at eye height, right across the vent: out, so there is room to stand
shelf = split(body, lambda c, s, n: c.x > 0.0 and 0.6 < c.z < 0.68 and s.z < 0.05)
print("hat shelf: %d faces removed" % len(shelf.data.polygons))
bpy.data.objects.remove(shelf)

open_vents(door_r, 1)
open_vents(door_l, -1)
door_r = join([door_r, handle_r], "Door_R")
door_l = join([door_l, handle_l], "Door_L")
body = join([body, hw], "Body")

# close the right leaf: turn it about its hinge until it lies in the left leaf's plane
free = min((v.co for v in door_r.data.vertices), key=lambda c: c.x)
ajar = math.atan2(HINGE_R.y - free.y, HINGE_R.x - free.x)     # > 0: the free edge stands out in front
close = Matrix.Translation(HINGE_R) @ Matrix.Rotation(-ajar, 4, "Z") @ Matrix.Translation(-HINGE_R)
door_r.data.transform(close)
print("right leaf was ajar %.2f deg" % math.degrees(ajar))
leaf_y = sorted(v.co.y for v in door_r.data.vertices)[len(door_r.data.vertices) // 2]
door_r.data.transform(Matrix.Translation((0.0, LEAF_PLANE_Y - leaf_y, 0.0)))

# each door's origin on its hinge, so turning the node about its up axis swings it
for o, h in ((door_r, HINGE_R), (door_l, HINGE_L)):
    o.data.transform(Matrix.Translation(-h))
    o.location = h

bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", export_yup=True, export_apply=True)

# metalness: the factor the importer kept in a math node does not survive the export, so set it in the file
b = open(OUT, "rb").read()
n = struct.unpack("<I", b[12:16])[0]
j = json.loads(b[20:20 + n])
rest = b[20 + n:]
for m in j["materials"]:
    m.setdefault("pbrMetallicRoughness", {})["metallicFactor"] = 0.3
    m["doubleSided"] = True
js = json.dumps(j, separators=(",", ":")).encode()
js += b" " * ((4 - len(js) % 4) % 4)
open(OUT, "wb").write(b"glTF" + struct.pack("<II", 2, 12 + 8 + len(js) + len(rest)) + struct.pack("<I", len(js)) + b"JSON" + js + rest)
print("wrote", OUT, [nd.get("name") for nd in j["nodes"]])
