"""
Generates the two seamless PBR sets for the T.S.R.A. hub (tsra_hub.lvl), in textures/pbr/<Name>/:

- Concrete_Panels: light-grey cast-in-place concrete, 2 panels per repeat (one repeat = 2.22 m in game, so a
  panel is 2.22 m x 1.11 m), with V-groove seams, form-tie holes, bugholes, faint shuttering grain and a tonal
  shift from one pour to the next.
- Tile_Raised_Floor: grey access-floor tiles, 4 x 4 per repeat (~0.555 m), laminate speckle, darker joints,
  soft scuffs. The level geometry glazes any "Tile" material to a satin finish.

Each set: <Name>_Color.jpg, <Name>_NormalGL.jpg, <Name>_Roughness.jpg, <Name>_preview.png and <Name>.tres.
Usage: python tools/generate_tsra_hub_textures.py   (run from godot-backrooms/)
"""

import os
import numpy as np
from PIL import Image

SIZE = 1024
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "textures", "pbr")
rng = np.random.default_rng(4242)


def blur(a, r):
    # periodic box-ish blur: everything below tiles seamlessly
    for _ in range(r):
        a = (np.roll(a, 1, 0) + np.roll(a, -1, 0) + np.roll(a, 1, 1) + np.roll(a, -1, 1) + 4.0 * a) / 8.0
    return a


def noise(r):
    n = blur(rng.normal(0.0, 1.0, (SIZE, SIZE)).astype(np.float32), r)
    return n / (n.std() + 1e-6)


def coarse(cells):
    # smooth periodic value noise from a cells x cells lattice (bilinear, wrapped)
    g = rng.normal(0.0, 1.0, (cells, cells)).astype(np.float32)
    t = np.arange(SIZE, dtype=np.float32) * cells / SIZE
    i0 = np.floor(t).astype(int) % cells
    i1 = (i0 + 1) % cells
    f = t - np.floor(t)
    f = f * f * (3 - 2 * f)
    rows = g[i0][:, None, :] * (1 - f)[:, None, None] + g[i1][:, None, :] * f[:, None, None]
    rows = rows[:, 0, :]
    out = rows[:, i0] * (1 - f)[None, :] + rows[:, i1] * f[None, :]
    return out / (out.std() + 1e-6)


def normal_gl(h, strength):
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    n = np.stack([-dx * strength, dy * strength, np.ones_like(h)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n * 0.5 + 0.5


def save(name, color, height, rough, strength):
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    c8 = (np.clip(color, 0, 1) * 255).astype(np.uint8)
    Image.fromarray(c8).save(os.path.join(d, name + "_Color.jpg"), quality=92)
    Image.fromarray((normal_gl(height, strength) * 255).astype(np.uint8)).save(
        os.path.join(d, name + "_NormalGL.jpg"), quality=95)
    Image.fromarray((np.clip(rough, 0, 1) * 255).astype(np.uint8)).save(os.path.join(d, name + "_Roughness.jpg"), quality=92)
    Image.fromarray(c8).resize((256, 256), Image.LANCZOS).save(os.path.join(d, name + "_preview.png"))
    p = "res://textures/pbr/%s/%s" % (name, name)
    with open(os.path.join(d, name + ".tres"), "w", newline="\n") as f:
        f.write('[gd_resource type="StandardMaterial3D" load_steps=4 format=3]\n\n'
                '[ext_resource type="Texture2D" path="%s_Color.jpg" id="1"]\n'
                '[ext_resource type="Texture2D" path="%s_NormalGL.jpg" id="2"]\n'
                '[ext_resource type="Texture2D" path="%s_Roughness.jpg" id="3"]\n\n'
                '[resource]\nresource_name = "%s"\nuv1_triplanar = false\nalbedo_texture = ExtResource("1")\n'
                'roughness_texture = ExtResource("3")\nroughness_texture_channel = 4\nnormal_enabled = true\n'
                'normal_texture = ExtResource("2")\n' % (p, p, p, name))
    print("wrote", d)


def groove(dist, half_w):
    # 1 at the groove centre, 0 outside, a soft V between
    return np.clip(1.0 - dist / half_w, 0.0, 1.0)


def concrete_panels():
    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    ph = SIZE / 2.0                                  # two panels stacked per repeat: 2.22 m wide, 1.11 m tall
    row = (ys // ph).astype(int)
    py = ys - row * ph                               # 0..ph inside a panel
    # seams: horizontal at every panel edge, vertical at the repeat edge (wraps to x = 0)
    dy = np.minimum(py, ph - py)
    dxs = np.minimum(xs, SIZE - xs)
    seam = np.maximum(groove(dy, 5.0), groove(dxs, 5.0))
    # form-tie holes: 4 across x 2 down in every panel
    ties = np.zeros((SIZE, SIZE), np.float32)
    ring = np.zeros((SIZE, SIZE), np.float32)
    for r in range(2):
        for cx in (0.125, 0.375, 0.625, 0.875):
            for cy in (0.22, 0.78):
                X, Y = cx * SIZE, r * ph + cy * ph
                d = np.hypot(xs - X, ys - Y)
                ties = np.maximum(ties, np.clip((8.0 - d) / 2.0, 0, 1))
                ring = np.maximum(ring, np.clip(1.0 - np.abs(d - 13.0) / 4.0, 0, 1))
    # bugholes: small air pockets in the cast face
    bug = np.zeros((SIZE, SIZE), np.float32)
    for _ in range(420):
        X, Y, rad = rng.uniform(0, SIZE), rng.uniform(0, SIZE), rng.uniform(1.2, 3.2)
        x0, x1 = int(X - 5), int(X + 6)
        y0, y1 = int(Y - 5), int(Y + 6)
        yy, xx = np.mgrid[y0:y1, x0:x1]
        v = np.clip((rad - np.hypot(xx - X, yy - Y)) / rad, 0, 1)
        np.maximum.at(bug, (yy % SIZE, xx % SIZE), v)
    grain = noise(1) * 0.5 + noise(3) * 0.35
    mottle = coarse(6) * 0.6 + coarse(14) * 0.4
    streak = coarse(4)                               # long, faint vertical rain/curing streaks
    streak = np.repeat(streak[:1, :], SIZE, 0) * 0.5 + blur(streak, 4) * 0.5
    pour = np.where(row == 0, 1.0, 0.955).astype(np.float32)   # each pour is a touch different
    # albedo
    base = np.array([0.66, 0.655, 0.635], np.float32)
    lum = pour * (1.0 + 0.035 * mottle + 0.018 * grain - 0.025 * np.clip(streak, 0, None))
    lum *= 1.0 - 0.32 * seam - 0.55 * ties - 0.10 * ring - 0.35 * bug
    # a darker band at the panel bottoms (paste bleed at the form joint)
    bleed = np.clip(1.0 - (ph - py) / 26.0, 0, 1) * 0.06
    lum *= 1.0 - bleed
    color = base[None, None, :] * lum[..., None]
    # height
    h = 0.5 + 0.6 * grain * 0.04 + 0.03 * mottle - 2.4 * seam - 3.0 * ties + 0.35 * ring - 1.2 * bug
    rough = 0.82 + 0.05 * grain - 0.08 * ring + 0.1 * seam
    save("Concrete_Panels", color, h, rough, 2.2)


def tile_raised_floor():
    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    t = SIZE / 4.0                                   # 4 x 4 tiles per repeat (~0.555 m each)
    tx, ty = xs % t, ys % t
    ix, iy = (xs // t).astype(int), (ys // t).astype(int)
    d = np.minimum(np.minimum(tx, t - tx), np.minimum(ty, t - ty))
    joint = np.clip(1.0 - (d - 1.0) / 1.5, 0, 1)    # ~2-3 px dark gap between tiles
    bevel = np.clip(1.0 - (d - 2.0) / 6.0, 0, 1)    # the edge trim rounds over into it
    tone = rng.normal(0.0, 1.0, (4, 4)).astype(np.float32)[iy, ix]
    speck = noise(0)
    fleck = (rng.random((SIZE, SIZE)) > 0.985).astype(np.float32)   # laminate speckle
    fleck = blur(fleck, 1) * 3.0
    scuff = np.clip(coarse(10) * 0.6 + noise(6) * 0.4 - 0.9, 0, None)
    wear = coarse(5)
    base = np.array([0.575, 0.585, 0.575], np.float32)
    lum = 1.0 + 0.025 * tone + 0.012 * speck - 0.08 * fleck + 0.06 * fleck[::-1, ::-1] - 0.05 * scuff + 0.015 * wear
    lum *= 1.0 - 0.55 * joint - 0.08 * bevel
    color = base[None, None, :] * lum[..., None]
    h = 0.5 + 0.004 * speck - 2.0 * joint - 0.6 * bevel ** 2
    rough = 0.42 + 0.03 * speck + 0.12 * scuff + 0.4 * joint + 0.04 * wear
    save("Tile_Raised_Floor", color, h, rough, 2.0)


if __name__ == "__main__":
    concrete_panels()
    tile_raised_floor()
