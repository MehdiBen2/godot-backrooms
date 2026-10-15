"""The T.S.R.A. wall sign: the agency emblem in 3D over its name, for the hub's walls.

    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --factory-startup \
        --python tools/blender/build_tsra_sign.py -- [preview dir]

Writes godot-backrooms/models/props/tsra/tsra_sign.glb (source: assetsimported/tsra/tsra_sign.blend).

The emblem is the field terminal's (godot-backrooms/tools/gen_tsra_logo.py, whose 1254 px reference drawing
gives every coordinate here): two crystal shards split down the middle, each an amber glass pane in a brass
frame with a heavy brass bar along the split, and the orbit round them as a real ring, passing in front of
the shards below their middle and behind them above it. Under it "T.S.R.A." and the agency's full name in
the terminal's VCR font, on a dark gunmetal plate with an amber light strip round its face.

In Godot: Y up, facing +Z, the plate's back on the plane z = 0 (hang it on a wall), its bottom edge at y = 0,
centred on x. 1.3 m wide, 1.8 m tall; the emblem is 1 m tall.
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tsra_common as T  # noqa: E402

# gen_tsra_logo.py reference geometry
MID, TOP, BOT = 626.0, 88.0, 1145.0
SHOULDER_T, SHOULDER_B = 285.0, 950.0
OUTER = 405.0
BAR = (576.0, 606.0)
RING_C = (628.0, 612.0)
RING_A, RING_B = 492.0, 128.0
LINE = 18.0                                    # the frame's width (2 x LINE_W)

EMBLEM_H = 1.0                                 # m, tip to tip
S = EMBLEM_H / (BOT - TOP)
PLATE_W, PLATE_H, PLATE_T = 1.3, 1.8, 0.04
EMBLEM_Z = 0.62                                # the shards' lower tips
EMBLEM_Y = -0.23                               # the shards' middle plane (the plate's face is at -0.04)
RING_DEPTH = 0.16                              # how far the orbit swings in front of / behind the shards
RING_R = 0.011


def ref(x, y):
    """Reference drawing px -> (X, Z) in metres"""
    return ((x - MID) * S, (BOT - y) * S + EMBLEM_Z)


def shard_outline(side):
    """The shard as a CCW outline seen from the front; side -1 left, +1 right"""
    tip_x = BAR[1]
    pts = [ref(tip_x, TOP), ref(OUTER, SHOULDER_T), ref(OUTER, SHOULDER_B), ref(tip_x, BOT)]
    if side > 0:
        pts = [(-x, z) for x, z in pts][::-1]
    return pts


def build():
    T.reset_scene()
    root = T.empty("TSRA_Sign", (0, 0, 0), size=0.3)

    brass = T.material("Brass", (0.83, 0.6, 0.26), metallic=1.0, roughness=0.3)
    glass = T.material("AmberGlass", (0.78, 0.36, 0.04), roughness=0.06, emission=(1.0, 0.5, 0.08), strength=0.45, alpha=0.72)
    plate = T.material("Gunmetal", (0.045, 0.05, 0.055), metallic=0.65, roughness=0.42)
    glow = T.material("AmberLight", T.AMBER, emission=T.AMBER, strength=3.0)

    # ---- the plate and its light strip
    T.box("Plate", -PLATE_W / 2, -PLATE_T, 0.0, PLATE_W / 2, 0.0, PLATE_H, plate, root, bevel=0.012)
    def rect(m):
        return [(-PLATE_W / 2 + m, m), (PLATE_W / 2 - m, m), (PLATE_W / 2 - m, PLATE_H - m), (-PLATE_W / 2 + m, PLATE_H - m)]
    T.ring_prism("LightStrip", rect(0.045), rect(0.06), -PLATE_T - 0.006, -PLATE_T, glow, root)

    # ---- the shards
    bar_x = (BAR[0] - MID) * S                 # the bar's outer edge (negative: left shard)
    lo, hi = EMBLEM_Y - 0.018, EMBLEM_Y + 0.018
    for side, tag in ((-1, "L"), (1, "R")):
        outline = shard_outline(side)
        inner = T.offset_poly(outline, LINE * S)
        T.ring_prism(f"ShardFrame_{tag}", outline, inner, EMBLEM_Y - 0.03, EMBLEM_Y + 0.03, brass, root, bevel=0.003)
        pane = T.clip_poly(inner, lambda p, s=side: (p[0] - (-bar_x)) if s > 0 else (bar_x - p[0]))
        T.prism(f"ShardGlass_{tag}", pane, lo, hi, glass, root)
        bar = T.clip_poly(outline, lambda p, s=side: ((-bar_x) - p[0]) if s > 0 else (p[0] - bar_x))
        T.prism(f"ShardBar_{tag}", bar, EMBLEM_Y - 0.036, EMBLEM_Y + 0.036, brass, root, bevel=0.003)
        # standoffs: the shards hang off the plate on two brass posts each
        sx = ref(OUTER + 90, 0)[0] * (1 if side < 0 else -1)
        for z in (EMBLEM_Z + 0.22, EMBLEM_Z + 0.78):
            y0, y1 = -PLATE_T, EMBLEM_Y + 0.03
            T.cylinder(f"Standoff_{tag}_{int(z * 100)}", sx, (y0 + y1) / 2, z, 0.012, abs(y1 - y0), "Y", brass, root, segs=12)

    # ---- the orbit: in front below the middle, behind above it
    cx, cz = ref(RING_C[0], RING_C[1])
    pts = []
    n = 160
    for i in range(n):
        th = 2 * math.pi * i / n
        pts.append((cx + RING_A * S * math.cos(th), EMBLEM_Y - RING_DEPTH * math.sin(th), cz - RING_B * S * math.sin(th)))
    T.tube_path("Orbit", pts, RING_R, brass, root)

    # ---- the name
    T.text("Wordmark", "T.S.R.A.", 0.17, 0.016, 0.0, -PLATE_T, 0.33, brass, root, spacing=1.1)
    T.text("FullName", "THRESHOLD SPATIAL RESEARCH AGENCY", 0.047, 0.008, 0.0, -PLATE_T, 0.17, brass, root)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build()
    T.save_and_export("tsra_sign")
    if argv:
        T.preview(argv[0], "tsra_sign", (0, 0, PLATE_H / 2), 1.0)
