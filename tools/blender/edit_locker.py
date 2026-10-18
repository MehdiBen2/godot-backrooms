"""The metal locker hiding spot (godot-backrooms/scripts/World/props/hide_spot.gd), remade from the source model.

The source (asetsuimprot/neww/lowpoly-locker.zip, source/lockermodel.glb) is one mesh: two lockers side by side,
each door part of the whole, and a vent of three louvres closed behind by solid strips. This splits off the right-hand
locker's door (you hide behind it) and opens its vent:
  Body       everything else, the left-hand locker's door with it
  Door       the right-hand door with its handle and lock; its origin on its hinge
The flat strips between the louvres are cut away and the louvres made narrower, so from inside you see out
between them.

blender --background --python tools/blender/edit_locker.py
"""
import bpy, bmesh, os, tempfile, zipfile
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "asetsuimprot", "neww", "lowpoly-locker.zip")
OUT = os.path.join(ROOT, "godot-backrooms", "models", "props", "storage", "locker.glb")

# Blender axes (Z up, the front faces +X), metres as the scene has them
DOOR_Y = (0.011, 0.579)                     # the right-hand locker (seen from the front), across
FRONT_X = 0.17                              # anything wholly in front of this is door or frame
HINGE = Vector((0.198, 0.548, 0.0))         # its outer edge: the handle is on the inner one
VENT_Y = (0.115, 0.488)
VENT_Z = (1.598, 1.79)
LOUVRE_KEEP = 0.55                          # how much of each louvre's height is left

tmp = os.path.join(tempfile.gettempdir(), "lockermodel.glb")
with open(tmp, "wb") as fh:
    fh.write(zipfile.ZipFile(SRC).read("source/lockermodel.glb"))
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=tmp)
body = bpy.data.objects["locker"]
body.data.transform(body.matrix_world)
body.matrix_world = Matrix.Identity(4)
body.name = body.data.name = "Body"


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


def is_door(lo, hi):
    if lo.x <= FRONT_X or lo.z < 0.06: return False                 # the carcass, the feet
    if not (DOOR_Y[0] < (lo.y + hi.y) * 0.5 < DOOR_Y[1]): return False
    return not (lo.x > 0.214 and hi.y - lo.y > 0.55)                 # the frame round the opening stays


# split the door off
bm = bmesh.new()
bm.from_mesh(body.data)
take = set()
for comp in islands(bm):
    lo = Vector([min(v.co[i] for v in comp) for i in range(3)])
    hi = Vector([max(v.co[i] for v in comp) for i in range(3)])
    if is_door(lo, hi): take.update(v.index for v in comp)
door_me = body.data.copy()
dm = bmesh.new()
dm.from_mesh(door_me)
dm.verts.ensure_lookup_table()
bmesh.ops.delete(dm, geom=[v for v in dm.verts if v.index not in take], context="VERTS")
bm.verts.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[bm.verts[i] for i in take], context="VERTS")
bm.to_mesh(body.data)
print("door: %d verts split off" % len(dm.verts))

# the vent: the flat strips between the louvres out, the louvres themselves narrower
def in_vent(c):
    return VENT_Y[0] < c.y < VENT_Y[1] and VENT_Z[0] < c.z < VENT_Z[1]

strips = [f for f in dm.faces if abs(f.normal.x) > 0.995 and in_vent(f.calc_center_median())]
louvres = [f for f in dm.faces if 0.9 < abs(f.normal.x) <= 0.995 and in_vent(f.calc_center_median())]
print("vent: %d strip faces cut, %d louvre faces narrowed" % (len(strips), len(louvres)))
bmesh.ops.delete(dm, geom=strips, context="FACES")
bmesh.ops.split(dm, geom=louvres)                   # each louvre on its own, so narrowing it leaves the door be
near = lambda c: VENT_Y[0] - 0.01 < c.y < VENT_Y[1] + 0.01 and VENT_Z[0] - 0.01 < c.z < VENT_Z[1] + 0.01
for comp in islands(dm):
    if len(comp) > 8 or not all(near(v.co) for v in comp): continue
    zc = sum(v.co.z for v in comp) / len(comp)
    for v in comp:
        v.co.z = zc + (v.co.z - zc) * LOUVRE_KEEP
bmesh.ops.delete(dm, geom=[v for v in dm.verts if not v.link_faces], context="VERTS")
dm.to_mesh(door_me)
door_me.transform(Matrix.Translation(-HINGE))
door = bpy.data.objects.new("Door", door_me)
door_me.name = "Door"
bpy.context.collection.objects.link(door)
door.location = HINGE

bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", export_yup=True, export_apply=True)
print("wrote", OUT)
