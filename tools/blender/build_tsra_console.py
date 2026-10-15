"""The T.S.R.A. launch console: the control desk in the hub's launch bay.

    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --factory-startup \
        --python tools/blender/build_tsra_console.py -- [preview dir]

Writes godot-backrooms/models/props/tsra/tsra_console.glb (source: assetsimported/tsra/tsra_console.blend).

2.4 m wide, three bays left to right as the operator faces it:
  terminal bay   an open bay for the field terminal (terminal_machine.gd brings its own cabinet and CRT)
  control desk   a steel base with a sloped switch panel (toggles, push buttons, gauges, lamps, a readout)
  lever bay      a short pedestal; the emergency lever panel (tsra_emergency_panel.gd) hangs on a chevron
                 hazard plate on the backboard above it
A tall backboard runs behind all three: gauges, lamp rows, "THRESHOLD LAUNCH CONTROL", the agency emblem.

In Godot: Y up, the operator side is +Z, the backboard's back on the plane z = -0.42, the floor y = 0.
Node3D markers for the props that go with it (each one faces +Z like the console):
  MOUNT_terminal   where a terminal_machine.gd node goes (its origin: the cabinet's middle, on the floor)
  MOUNT_lever      where a tsra_emergency_panel.gd node goes (its origin: back middle bottom of the panel)
Collision: "-convcolonly" boxes, which Godot's importer turns into static bodies.
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tsra_common as T  # noqa: E402

HAZARD_PNG = T.GAME / "textures" / "items" / "hazard_tapes" / "hazardous_tapes.jpg"

W = 2.4
X0, X1 = -W / 2, W / 2
BAY_T = (-1.2, -0.55)                 # terminal bay, x
DESK = (-0.55, 0.65)                  # control desk, x
LEVER = (0.65, 1.2)                   # lever bay, x
BACK_Y = (0.30, 0.42)                 # backboard, front / back face (front faces -Y)
BACK_H = 1.62
DESK_FRONT = -0.22
BASE_H = 0.78
SLOPE_LO = (DESK_FRONT, 0.86)         # (y, z) of the sloped panel's front edge
SLOPE_HI = (BACK_Y[0], 1.06)          # and its back edge, against the backboard
PED_H = 0.86


def prism_x(name, poly_yz, x0, x1, mat=None, parent=None, bevel=0.0):
    """Extrude a side-view outline (y, z) along X from x0 to x1"""
    bm = bmesh.new()
    a = [bm.verts.new((x0, y, z)) for y, z in poly_yz]
    b = [bm.verts.new((x1, y, z)) for y, z in poly_yz]
    n = len(poly_yz)
    bm.faces.new(a)
    bm.faces.new(b[::-1])
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = T.mesh_object(name, bm, mat, parent)
    if bevel:
        T.add_bevel(ob, bevel)
    return ob


def quad(name, x0, x1, z0, z1, y, mat, parent, uv_repeat=(1.0, 1.0)):
    """A front-facing (-Y) rectangle with 0..1 UVs (times uv_repeat)"""
    bm = bmesh.new()
    vs = [bm.verts.new(p) for p in ((x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1))]
    f = bm.faces.new(vs)
    uv = bm.loops.layers.uv.new("UVMap")
    for loop, (u, v) in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
        loop[uv].uv = (u * uv_repeat[0], v * uv_repeat[1])
    f.normal_update()
    if f.normal.y > 0:
        bmesh.ops.reverse_faces(bm, faces=[f])
    return T.mesh_object(name, bm, mat, parent)


def on_slope(ob, u, x):
    """Stand an object built at the origin (its up = +Z) on the sloped panel, u 0 front edge .. 1 back edge"""
    (y0, z0), (y1, z1) = SLOPE_LO, SLOPE_HI
    ang = math.atan2(z1 - z0, y1 - y0)
    ob.rotation_euler = (ang, 0.0, 0.0)
    ob.location = (x, y0 + (y1 - y0) * u, z0 + (z1 - z0) * u)
    return ob


def toggle(name, mats, parent, u, x):
    base = T.cylinder(name, 0, 0, 0.006, 0.014, 0.012, "Z", mats["steel"], None, segs=12)
    stick = T.cylinder(name + "_Stick", 0, -0.008, 0.03, 0.0035, 0.045, "Z", mats["steel"], None, segs=8)
    stick.rotation_euler = (math.radians(-25), 0, 0)
    stick.parent = base
    on_slope(base, u, x)
    base.parent = parent
    return base


def button(name, mat, mats, parent, u, x, r=0.022):
    ring = T.cylinder(name, 0, 0, 0.006, r + 0.008, 0.012, "Z", mats["steel"], None, segs=20)
    cap = T.cylinder(name + "_Cap", 0, 0, 0.018, r, 0.016, "Z", mat, None, segs=20, bevel=0.004)
    cap.parent = ring
    on_slope(ring, u, x)
    ring.parent = parent
    return ring


def gauge(name, mats, parent, x, z, y, r=0.06):
    """A round dial on a vertical face at y (facing -Y)"""
    bez = T.cylinder(name, x, y - 0.012, z, r, 0.024, "Y", mats["steel"], parent, segs=32, bevel=0.004)
    T.cylinder(name + "_Face", x, y - 0.025, z, r * 0.84, 0.004, "Y", mats["dial"], parent, segs=32)
    a = math.radians(-35)
    needle = T.box(name + "_Needle", -0.002, -0.002, 0.0, 0.002, 0.002, r * 0.72, mats["red"], None)
    needle.rotation_euler = (0.0, a, 0.0)
    needle.location = (x, y - 0.029, z)
    needle.parent = parent
    return bez


def lamp(name, mat, mats, parent, x, z, y, r=0.016):
    T.cylinder(name + "_Rim", x, y - 0.005, z, r + 0.006, 0.01, "Y", mats["steel"], parent, segs=16)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=14, v_segments=8, radius=r)
    for v in bm.verts:
        v.co.y = min(v.co.y, 0.0) * 0.8 + y - 0.01
        v.co.x += x
        v.co.z += z
    return T.mesh_object(name, bm, mat, parent)


def build():
    T.reset_scene()
    root = T.empty("TSRA_Console", (0, 0, 0), size=0.4)
    m = {
        "paint": T.material("ConsolePaint", (0.1, 0.115, 0.11), metallic=0.35, roughness=0.55),
        "dark": T.material("PanelDark", (0.035, 0.04, 0.045), metallic=0.3, roughness=0.6),
        "steel": T.material("Steel", (0.56, 0.57, 0.6), metallic=1.0, roughness=0.32),
        "rubber": T.material("Rubber", (0.02, 0.02, 0.02), roughness=0.85),
        "dial": T.material("DialFace", (0.85, 0.8, 0.66), roughness=0.5, emission=(1.0, 0.86, 0.6), strength=0.35),
        "red": T.material("LampRed", (0.7, 0.04, 0.03), roughness=0.3, emission=(1.0, 0.08, 0.05), strength=2.0),
        "amber": T.material("LampAmber", (0.8, 0.45, 0.06), roughness=0.3, emission=T.AMBER, strength=2.0),
        "green": T.material("LampGreen", (0.08, 0.6, 0.15), roughness=0.3, emission=(0.2, 1.0, 0.35), strength=2.0),
        "screen": T.material("Readout", (0.02, 0.06, 0.03), roughness=0.15, emission=(0.12, 0.65, 0.25), strength=0.8),
        "label": T.material("LabelAmber", T.AMBER, roughness=0.5, emission=T.AMBER, strength=1.2),
        "hazard": T.image_material("HazardPlate", HAZARD_PNG, closest=False, alpha=False),
        "emblem": T.image_material("EmblemDecal", T.EMBLEM_PNG, emission_strength=1.5, closest=True),
    }

    # ---- backboard across the whole width, a cap along its top
    T.box("Backboard", X0, BACK_Y[0], 0.0, X1, BACK_Y[1], BACK_H, m["paint"], root, bevel=0.01)
    T.box("BackboardCap", X0 - 0.015, BACK_Y[0] - 0.03, BACK_H, X1 + 0.015, BACK_Y[1] + 0.015, BACK_H + 0.04, m["steel"], root, bevel=0.006)
    T.box("Kick", X0, BACK_Y[0] - 0.02, 0.0, X1, BACK_Y[0], 0.08, m["rubber"], root)

    # ---- control desk: base cabinet with a kick recess, sloped panel, a lip along the front
    T.box("DeskBase", DESK[0], DESK_FRONT + 0.06, 0.0, DESK[1], BACK_Y[0], 0.1, m["rubber"], root)
    T.box("DeskBody", DESK[0], DESK_FRONT, 0.1, DESK[1], BACK_Y[0], BASE_H, m["paint"], root, bevel=0.008)
    prism_x("DeskSlope", [(DESK_FRONT - 0.02, BASE_H), (DESK_FRONT - 0.02, SLOPE_LO[1]), (SLOPE_HI[0], SLOPE_HI[1]),
                          (SLOPE_HI[0], BASE_H)], DESK[0], DESK[1], m["paint"], root, bevel=0.008)
    T.box("DeskLip", DESK[0], DESK_FRONT - 0.05, SLOPE_LO[1] - 0.03, DESK[1], DESK_FRONT + 0.0, SLOPE_LO[1] + 0.012, m["steel"], root, bevel=0.006)
    # the slope's inset face, then what is on it
    face = prism_x("SlopeFace", [(DESK_FRONT + 0.04, SLOPE_LO[1] + 0.016 + 0.002), (SLOPE_HI[0] - 0.03, SLOPE_HI[1] - 0.012 + 0.002),
                                 (SLOPE_HI[0] - 0.03, SLOPE_HI[1] - 0.02), (DESK_FRONT + 0.04, SLOPE_LO[1] + 0.008)],
                   DESK[0] + 0.04, DESK[1] - 0.04, m["dark"], root)
    face.location.z += 0.003
    for i in range(10):                                    # a row of toggles
        toggle(f"Toggle_{i}", m, root, 0.25, -0.45 + i * 0.05)
    for i, col in enumerate(("amber", "amber", "green", "green")):
        lamp_ob = T.cylinder(f"SlopeLamp_{i}", 0, 0, 0.006, 0.01, 0.012, "Z", m[col], None, segs=12)
        on_slope(lamp_ob, 0.25, 0.1 + i * 0.05)
        lamp_ob.parent = root
    for i, col in enumerate(("red", "amber", "green")):    # push buttons
        button(f"Button_{i}", m[col], m, root, 0.62, 0.12 + i * 0.075)
    big = button("ArmButton", m["red"], m, root, 0.6, 0.5, r=0.034)
    # the readout: a small glass screen in a bezel on the slope
    bez = T.box("ReadoutBezel", -0.13, -0.075, 0.0, 0.13, 0.075, 0.014, m["steel"], None, bevel=0.003)
    on_slope(bez, 0.62, -0.25)
    bez.parent = root
    scr = T.box("ReadoutGlass", -0.115, -0.06, 0.0, 0.115, 0.06, 0.017, m["screen"], None)
    on_slope(scr, 0.62, -0.25)
    scr.parent = root
    # front of the cabinet: two doors (seams), louvres, the emblem
    for x0, x1 in ((DESK[0] + 0.04, -0.0), (0.04, DESK[1] - 0.04)):
        T.box(f"DoorSeam_{x0:.2f}", x0, DESK_FRONT - 0.004, 0.14, x1, DESK_FRONT, 0.145, m["dark"], root)
        T.box(f"DoorSeamTop_{x0:.2f}", x0, DESK_FRONT - 0.004, 0.735, x1, DESK_FRONT, 0.74, m["dark"], root)
        for k in range(6):
            z = 0.2 + k * 0.03
            T.box(f"Louvre_{x0:.2f}_{k}", x0 + 0.06, DESK_FRONT - 0.006, z, x1 - 0.06, DESK_FRONT, z + 0.012, m["dark"], root)
    T.box("DoorGap", -0.004, DESK_FRONT - 0.004, 0.14, 0.004, DESK_FRONT, 0.74, m["dark"], root)
    quad("EmblemDecal", -0.11, 0.11, 0.44, 0.66, DESK_FRONT - 0.003, m["emblem"], root)

    # ---- lever bay: pedestal, the chevron plate behind the lever
    T.box("LeverPedestal", LEVER[0] + 0.06, -0.06, 0.0, LEVER[1] - 0.06, BACK_Y[0], PED_H, m["paint"], root, bevel=0.008)
    T.box("LeverPedestalTop", LEVER[0] + 0.05, -0.07, PED_H, LEVER[1] - 0.05, BACK_Y[0], PED_H + 0.02, m["steel"], root, bevel=0.004)
    lx = (LEVER[0] + LEVER[1]) / 2
    T.box("HazardFrame", lx - 0.2, BACK_Y[0] - 0.012, PED_H + 0.04, lx + 0.2, BACK_Y[0], PED_H + 0.66, m["steel"], root, bevel=0.004)
    quad("HazardPlate", lx - 0.185, lx + 0.185, PED_H + 0.055, PED_H + 0.645, BACK_Y[0] - 0.0125, m["hazard"], root, (1.0, 1.0))
    T.empty("MOUNT_lever", (lx, BACK_Y[0] - 0.013, PED_H + 0.12), root)

    # ---- terminal bay: just floor space and the backboard; a floor plate marks it
    tx = (BAY_T[0] + BAY_T[1]) / 2
    T.box("TerminalPlate", BAY_T[0] + 0.02, -0.25, 0.0, BAY_T[1] - 0.02, BACK_Y[0], 0.008, m["steel"], root)
    T.empty("MOUNT_terminal", (tx, BACK_Y[0] - 0.27, 0.008), root)

    # ---- the backboard's instrument face
    for i, x in enumerate((-0.4, -0.2, 0.0, 0.2, 0.4)):
        gauge(f"Gauge_{i}", m, root, x + 0.05, 1.25, BACK_Y[0], r=0.07 if i == 2 else 0.055)
    for i in range(12):
        col = ("green", "green", "amber", "red")[i % 4]
        lamp(f"BoardLamp_{i}", m[col], m, root, -0.47 + i * 0.09, 1.1, BACK_Y[0])
    T.text("BoardLabel", "THRESHOLD LAUNCH CONTROL", 0.05, 0.004, 0.05, BACK_Y[0], 1.44, m["label"], root)
    T.text("BayLabel", "FIELD TERMINAL FT-07", 0.03, 0.003, tx, BACK_Y[0], 1.3, m["label"], root)
    T.text("LeverLabel", "THRESHOLD ENGAGE", 0.03, 0.003, lx, BACK_Y[0], PED_H + 0.71, m["label"], root)
    # vent slots high on the bay sides
    for x in (tx, lx):
        for k in range(5):
            z = 1.42 + k * 0.03
            T.box(f"Vent_{x:.2f}_{k}", x - 0.18, BACK_Y[0] - 0.004, z, x + 0.18, BACK_Y[0], z + 0.012, m["dark"], root)

    # ---- collision
    for name, b in (("Backboard", (X0, BACK_Y[0], 0.0, X1, BACK_Y[1], BACK_H + 0.04)),
                    ("Desk", (DESK[0], DESK_FRONT - 0.05, 0.0, DESK[1], BACK_Y[0], SLOPE_HI[1])),
                    ("Pedestal", (LEVER[0] + 0.05, -0.07, 0.0, LEVER[1] - 0.05, BACK_Y[0], PED_H + 0.02))):
        col = T.box(f"COL_{name}-convcolonly", *b, None, root)
        col.display_type = "WIRE"
    return big


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    T.save_and_export("tsra_console")
    if argv:
        T.preview(argv[0], "tsra_console", (0, 0.1, 0.8), 1.5,
                  views=(("front", (0, -1, 0.25)), ("three_quarter", (0.8, -1, 0.6)), ("left", (-0.9, -0.8, 0.4))))
