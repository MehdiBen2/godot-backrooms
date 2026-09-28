"""Rebuild the mannequin variant's rig in Blender and export it for the game.

    blender --background --python tools/blender/rig_mannequin_variant.py -- <in.glb> <out.glb> <out.blend>
    (or with the `bpy` module: python rig_mannequin_variant.py <in.glb> <out.glb> <out.blend>)

The sculpt is a real mannequin: rigid pieces (head, chest, pelvis, two upper arms, two forearms+hands, two
legs) with disc joints between them. So every piece is bound 100% to one bone (no blending, a piece moves as
one), and the rig gets elbows:

    Hips > LegL, LegR, Spine > Head, ArmL > ForearmL, ArmR > ForearmR

Each bone's head sits on its joint and its tail runs down the piece (the elbow for an upper arm, the far end
of the hand for a forearm, the foot for a leg), so in the game a bone's +Y is the direction of its limb.
Pieces are found by mesh connectivity (merged across UV seams); which piece is which comes from where it
sits, so this also repairs the original export's weighting mistakes (left upper arm on the spine, stray
pelvis / leg vertices on the arms).
"""
import sys
import bpy  # noqa: E402 (bmesh only exists once bpy is loaded)
import bmesh
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
IN_GLB, OUT_GLB, OUT_BLEND = args[:3]

bpy.ops.wm.read_factory_settings(use_empty=True)
for o in list(bpy.data.objects):            # the bpy module's startup scene can still hold a default mesh
    bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.import_scene.gltf(filepath=IN_GLB)
arm_obj = next(o for o in bpy.data.objects if o.type == "ARMATURE")
mesh_obj = next(o for o in bpy.data.objects if o.type == "MESH" and o.parent == arm_obj)
me = mesh_obj.data
mw = mesh_obj.matrix_world

# ---- pieces: connected faces, merged across seams (same position)
bm = bmesh.new()
bm.from_mesh(me)
bm.verts.ensure_lookup_table()
parent = list(range(len(bm.verts)))
def find(i):
    while parent[i] != i:
        parent[i] = parent[parent[i]]
        i = parent[i]
    return i
def union(a, b):
    parent[find(a)] = find(b)
for e in bm.edges:
    union(e.verts[0].index, e.verts[1].index)
seen = {}
for v in bm.verts:
    k = tuple(round(c, 5) for c in v.co)
    if k in seen:
        union(v.index, seen[k])
    else:
        seen[k] = v.index
pieces = {}
for v in bm.verts:
    pieces.setdefault(find(v.index), []).append(v.index)
world = [mw @ v.co for v in bm.verts]
bm.free()

def centre(ids):
    return sum((world[i] for i in ids), Vector()) / len(ids)

# Blender is Z-up: height is z. Left (L) is +X, as in the game.
info = []
for ids in pieces.values():
    c = centre(ids)
    info.append({"ids": ids, "c": c, "zmin": min(world[i].z for i in ids), "zmax": max(world[i].z for i in ids)})
info.sort(key=lambda p: -p["c"].z)
role = {}
for p in info:
    c = p["c"]
    if c.z > 1.5:
        r = "Head"
    elif c.z < 0.7:
        r = None                      # a leg: sorted out below by which hip it hangs from
    elif abs(c.x) < 0.1 and c.z > 1.05:
        r = "Spine"
    elif abs(c.x) < 0.1:
        r = "Hips"
    else:
        r = "Arm" + ("L" if c.x > 0 else "R")
    p["role"] = r
# of the two pieces on each side, the higher one is the upper arm, the lower one the forearm + hand
for side in "LR":
    arms = sorted([p for p in info if p["role"] == "Arm" + side], key=lambda p: -p["c"].z)
    assert len(arms) == 2, f"expected 2 arm pieces on {side}, found {len(arms)}"
    arms[1]["role"] = "Forearm" + side
legs = [p for p in info if p["role"] is None]
assert len(legs) == 2, f"expected 2 legs, found {len(legs)}"
# keep the original naming: LegL is the one its old LegL group owns most of
old = {g.index: g.name for g in mesh_obj.vertex_groups}
def dominant(ids):
    count = {}
    for i in ids:
        gs = sorted(me.vertices[i].groups, key=lambda g: -g.weight)
        if gs:
            count[old[gs[0].group]] = count.get(old[gs[0].group], 0) + 1
    return max(count, key=count.get) if count else ""
for p in legs:
    p["role"] = dominant(p["ids"]) if dominant(p["ids"]) in ("LegL", "LegR") else None
if legs[0]["role"] == legs[1]["role"] or None in (legs[0]["role"], legs[1]["role"]):
    legs.sort(key=lambda p: p["c"].y)
    legs[0]["role"], legs[1]["role"] = "LegL", "LegR"
by_role = {p["role"]: p for p in info}
print("pieces:", {p["role"]: (round(p["c"].x, 2), round(p["c"].z, 2), len(p["ids"])) for p in info})

# ---- joints
def closest_pair(a, b):
    best = (1e9, None)
    for i in a:
        for j in b:
            d = (world[i] - world[j]).length_squared
            if d < best[0]:
                best = (d, (world[i] + world[j]) / 2)
    return best[1]
def farthest(ids, frm):
    return max((world[i] for i in ids), key=lambda w: (w - frm).length)
def top_centre(ids, band=0.03):
    """Middle of the top slice of a piece: the ball of a hip or shoulder joint"""
    zmax = max(world[i].z for i in ids)
    sl = [world[i] for i in ids if world[i].z > zmax - band]
    return sum(sl, Vector()) / len(sl)
elbow = {s: closest_pair(by_role["Arm" + s]["ids"], by_role["Forearm" + s]["ids"]) for s in "LR"}
shoulder = {s: top_centre(by_role["Arm" + s]["ids"]) for s in "LR"}
hand = {s: farthest(by_role["Forearm" + s]["ids"], elbow[s]) for s in "LR"}
neck = closest_pair(by_role["Head"]["ids"], by_role["Spine"]["ids"])
top = max(world[i] for i in by_role["Head"]["ids"]).z
print("elbows", {s: tuple(round(x, 3) for x in elbow[s]) for s in "LR"})

# ---- bones
bpy.context.view_layer.objects.active = arm_obj
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_obj.data.edit_bones
aw = arm_obj.matrix_world.inverted()
def put(name, head, tail, parent_name=None):
    b = eb.get(name) or eb.new(name)
    b.head = aw @ head
    b.tail = aw @ tail
    b.roll = 0.0
    if parent_name:
        b.parent = eb[parent_name]
    b.use_connect = False
    return b
hips = eb["Hips"]
hip_head = arm_obj.matrix_world @ hips.head
put("Hips", hip_head, hip_head + Vector((0, 0, 0.12)))
put("Spine", hip_head, neck, "Hips")
put("Head", neck, Vector((neck.x, neck.y, top)), "Spine")
for s in "LR":
    put("Arm" + s, shoulder[s], elbow[s], "Spine")
    put("Forearm" + s, elbow[s], hand[s], "Arm" + s)
    leg = by_role["Leg" + s]
    hip_j = top_centre(leg["ids"])
    foot = min((world[i] for i in leg["ids"]), key=lambda w: w.z)
    put("Leg" + s, hip_j, foot, "Hips")
bpy.ops.object.mode_set(mode="OBJECT")

# ---- weights: every piece rigid on its bone
for g in list(mesh_obj.vertex_groups):
    mesh_obj.vertex_groups.remove(g)
for p in info:
    g = mesh_obj.vertex_groups.get(p["role"]) or mesh_obj.vertex_groups.new(name=p["role"])
    g.add(p["ids"], 1.0, "REPLACE")
for name in [b.name for b in arm_obj.data.bones]:
    if mesh_obj.vertex_groups.get(name) is None:
        mesh_obj.vertex_groups.new(name=name)

# ---- which piece each vertex belongs to, baked as a vertex colour (R = piece id / 10) so shaders can tell
# the chest from an arm without bone data: 1 Head, 2 Spine (chest), 3 Hips (pelvis), 4 ArmL, 5 ArmR,
# 6 ForearmL, 7 ForearmR, 8 LegL, 9 LegR. mannequin_wear.gdshader reads it.
PIECE_ID = {"Head": 1, "Spine": 2, "Hips": 3, "ArmL": 4, "ArmR": 5, "ForearmL": 6, "ForearmR": 7, "LegL": 8, "LegR": 9}
col = me.color_attributes.get("piece") or me.color_attributes.new(name="piece", type="FLOAT_COLOR", domain="POINT")
for p in info:
    v = PIECE_ID[p["role"]] / 10.0
    for i in p["ids"]:
        col.data[i].color = (v, 0.0, 0.0, 1.0)
me.color_attributes.active_color = col

bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND)
bpy.ops.export_scene.gltf(filepath=OUT_GLB, export_format="GLB", export_animations=False,
    export_skins=True, export_yup=True, export_apply=False, export_vertex_color="ACTIVE")
print("saved", OUT_BLEND, "and", OUT_GLB)
