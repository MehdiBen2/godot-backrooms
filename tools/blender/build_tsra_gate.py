"""The T.S.R.A. threshold gate's base: the platform, the charge coils and the orbit ring round the portal frame.

    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --factory-startup         --python tools/blender/build_tsra_gate.py -- [preview dir]

Writes godot-backrooms/models/props/tsra/tsra_gate.glb (source: assetsimported/tsra/tsra_gate.blend).

The frame itself is tsra_portal_frame.glb (build_tsra_portal_frame.py); scripts/World/props/tsra_portal_gate.gd stands
it on this platform and draws the threshold in its doorway. Here: a round platform edged in hazard chevrons, a
charge coil either side, and an orbit ring floating over the frame (the agency emblem's orbit).

In Godot: Y up, the front (the side you walk in from) is +Z, the platform's middle under the origin, its top
at y = PLATFORM_H. Nodes the gate script uses:
  Orbit       the ring; its origin is its own middle, so it can be spun
  GateGlow    the material on the coils' bands: its emission is driven by the charge
Collision: "-convcolonly" boxes round the coils.
"""
import math
import sys
from pathlib import Path

import bmesh
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tsra_common as T  # noqa: E402

HAZARD_PNG = T.GAME / "textures" / "items" / "hazard_tapes" / "hazardous_tapes.jpg"

PLATFORM_R, PLATFORM_H = 2.9, 0.1
COIL_X, COIL_Y = 3.75, 0.5
ORBIT_R, ORBIT_Z, ORBIT_TILT = 2.75, 5.35, 9.0


def torus(name, major, minor, mat, parent=None, segs=72, rsegs=12):
    """A torus round the Z axis at the origin"""
    bm = bmesh.new()
    rings = []
    for i in range(segs):
        a = 2 * math.pi * i / segs
        c, s = math.cos(a), math.sin(a)
        ring = []
        for j in range(rsegs):
            b = 2 * math.pi * j / rsegs
            r = major + minor * math.cos(b)
            ring.append(bm.verts.new((r * c, r * s, minor * math.sin(b))))
        rings.append(ring)
    for i in range(segs):
        for j in range(rsegs):
            a, b = rings[i], rings[(i + 1) % segs]
            bm.faces.new((a[j], b[j], b[(j + 1) % rsegs], a[(j + 1) % rsegs]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = T.mesh_object(name, bm, mat, parent)
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob


def annulus(name, r0, r1, z, mat, parent, segs=96, repeats=24):
    """A flat ring facing up, its UVs running round it (u, `repeats` times) and across it (v)"""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    inner = [bm.verts.new((r0 * math.cos(2 * math.pi * i / segs), r0 * math.sin(2 * math.pi * i / segs), z)) for i in range(segs)]
    outer = [bm.verts.new((r1 * math.cos(2 * math.pi * i / segs), r1 * math.sin(2 * math.pi * i / segs), z)) for i in range(segs)]
    for i in range(segs):
        j = (i + 1) % segs
        f = bm.faces.new((inner[i], outer[i], outer[j], inner[j]))
        u0, u1 = i / segs * repeats, (i + 1) / segs * repeats
        for loop, (u, v) in zip(f.loops, ((u0, 0), (u0, 1), (u1, 1), (u1, 0))):
            loop[uv].uv = (v, u)                       # the chevrons run along the tape's length: round the ring
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for f in bm.faces:
        if f.normal.z < 0:
            f.normal_flip()
    return T.mesh_object(name, bm, mat, parent)


def build():
    T.reset_scene()
    root = T.empty("TSRA_Gate", (0, 0, 0), size=0.5)
    steel = T.material("GateSteel", (0.22, 0.235, 0.25), metallic=0.85, roughness=0.38)
    dark = T.material("GateDark", (0.05, 0.055, 0.06), metallic=0.5, roughness=0.55)
    brass = T.material("Brass", (0.83, 0.6, 0.26), metallic=1.0, roughness=0.3)
    copper = T.material("Copper", (0.85, 0.42, 0.22), metallic=1.0, roughness=0.32)
    glow = T.material("GateGlow", T.AMBER, emission=T.AMBER, strength=1.0)
    hazard = T.image_material("HazardRing", HAZARD_PNG, closest=False, alpha=False)

    # ---- platform: a dark drum, a hazard ring round its top, a steel lip
    T.cylinder("Platform", 0, 0, PLATFORM_H / 2, PLATFORM_R, PLATFORM_H, "Z", dark, root, segs=64, bevel=0.01)
    annulus("PlatformHazard", PLATFORM_R - 0.42, PLATFORM_R - 0.06, PLATFORM_H + 0.002, hazard, root)
    lip = torus("PlatformLip", PLATFORM_R - 0.03, 0.03, steel, root, segs=96, rsegs=8)
    lip.location.z = PLATFORM_H

    # ---- the orbit ring, floating over the frame
    orbit = torus("Orbit", ORBIT_R, 0.055, brass, root, segs=96, rsegs=12)
    orbit.location = (0, 0, ORBIT_Z)
    orbit.rotation_euler = (math.radians(ORBIT_TILT), 0, 0)

    # ---- charge coils either side
    for side, tag in ((-1, "L"), (1, "R")):
        cx = side * COIL_X
        T.cylinder(f"CoilBase_{tag}", cx, COIL_Y, 0.15, 0.5, 0.3, "Z", dark, root, segs=32, bevel=0.01)
        T.cylinder(f"CoilCore_{tag}", cx, COIL_Y, 1.35, 0.26, 2.1, "Z", steel, root, segs=24)
        for k in range(9):
            ring = torus(f"CoilWind_{tag}_{k}", 0.31, 0.045, copper, root, segs=32, rsegs=8)
            ring.location = (cx, COIL_Y, 0.55 + k * 0.2)
        band = T.cylinder(f"CoilGlow_{tag}", cx, COIL_Y, 2.42, 0.29, 0.08, "Z", glow, root, segs=24)
        T.cylinder(f"CoilCap_{tag}", cx, COIL_Y, 2.55, 0.36, 0.18, "Z", steel, root, segs=24, bevel=0.02)
        T.box(f"COL_Coil_{tag}-convcolonly", cx - 0.5, COIL_Y - 0.5, 0.0, cx + 0.5, COIL_Y + 0.5, 2.64, None, root).display_type = "WIRE"


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    T.save_and_export("tsra_gate")
    if argv:
        T.preview(argv[0], "tsra_gate", (0, 0, 2.5), 4.2,
                  views=(("front", (0, -1, 0.15)), ("three_quarter", (0.8, -1, 0.5))))
