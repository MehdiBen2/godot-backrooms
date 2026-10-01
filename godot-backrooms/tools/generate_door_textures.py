"""
Generates the PBR textures for the six-panel wooden door leaf (textures/props/door/):
- Door1.jpg:           stained oak albedo: vertical grain on stiles/panels, horizontal on rails, knots, grime in the joints
- Door1_Normal.png:    OpenGL-style normal map from a real height field (joint grooves, moulded raised panels, grain)
- Door1_Roughness.png: satin varnish, rougher in the joints and worn patches, polished where hands touch the knob
- Door1_AO.png:        cavity occlusion from the same height field

Layout matches the leaf mesh in scripts/World/props/door.gd: u runs hinge -> latch, v top -> bottom,
and the knob sits on the right-hand stile at the lock rail.
Needs numpy + Pillow. Run from anywhere: python tools/generate_door_textures.py
"""
import os
import numpy as np
from PIL import Image

W, H = 1024, 2048
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "textures", "props", "door")
rng = np.random.default_rng(1989)

yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)


def noise(ny, nx, seed):
    """Smooth value noise with ny x nx lattice cells stretched over the whole texture."""
    r = np.random.default_rng(seed).random((ny + 3, nx + 3)).astype(np.float32)
    im = Image.fromarray(r, mode="F").resize((W + W // nx * 2, H + H // ny * 2), Image.BICUBIC)
    a = np.asarray(im)
    return a[H // ny:H // ny + H, W // nx:W // nx + W]


def fbm(ny, nx, seed, octaves=4):
    out = np.zeros((H, W), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += amp * noise(ny * 2 ** o, nx * 2 ** o, seed + o * 17)
        tot += amp
        amp *= 0.5
    return out / tot


def blur(a, radius):
    """Separable box-ish blur through a cumulative sum (3 passes ~ gaussian)."""
    for _ in range(3):
        for axis in (0, 1):
            k = int(radius)
            pad = [(0, 0), (0, 0)]
            pad[axis] = (k + 1, k)
            c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis, dtype=np.float64)
            n = a.shape[axis]
            hi = np.take(c, range(2 * k + 1, 2 * k + 1 + n), axis=axis)
            lo = np.take(c, range(0, n), axis=axis)
            a = ((hi - lo) / (2 * k + 1)).astype(np.float32)
    return a


def smooth(a, lo, hi):
    t = np.clip((a - lo) / (hi - lo), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ---------------------------------------------------------------- layout (pixels)
stile = int(W * 0.105)
col_x = [(stile, int(W * 0.475)), (int(W * 0.525), W - stile)]
row_y = [(int(H * 0.060), int(H * 0.275)),
         (int(H * 0.330), int(H * 0.550)),
         (int(H * 0.650), int(H * 0.890))]

# region ids: 0 stiles, 1 rails, 2 muntins, 3.. panels
region = np.zeros((H, W), np.int32)
region[:, stile:W - stile] = 1                                   # everything between the stiles is rail...
for (y0, y1) in row_y:
    region[y0:y1, col_x[0][1]:col_x[1][0]] = 2                   # ...except muntins...
    for ci, (x0, x1) in enumerate(col_x):
        region[y0:y1, x0:x1] = 3 + len(row_y) * ci + row_y.index((y0, y1))   # ...and panels

# ---------------------------------------------------------------- height field
height = np.ones((H, W), np.float32)

# distance inside each panel's opening, measured from its edge
for (y0, y1) in row_y:
    for (x0, x1) in col_x:
        d = np.minimum.reduce([xx - x0, x1 - 1 - xx, yy - y0, y1 - 1 - yy])
        inside = d >= 0
        prof = np.where(d < 7, 1.0 - 0.8 * smooth(d, 0, 7),            # scribe groove down to the moulding
               np.where(d < 14, 0.2,                                    # groove floor
               0.2 + 0.52 * smooth(d, 14, 70)))                         # long bevel up to the raised field
        height = np.where(inside, np.minimum(height, prof.astype(np.float32)), height)

# thin joints where rails/muntins meet stiles, and a soft bevel round the leaf's outer edge
for x in (stile, W - stile):
    height -= 0.18 * np.exp(-((xx - x) / 2.2) ** 2)
for yb in (row_y[0][0] - 1, row_y[2][1]):
    height -= 0.10 * np.exp(-((yy - yb) / 2.0) ** 2) * ((xx > stile) & (xx < W - stile))
edge = np.minimum.reduce([xx, W - 1 - xx, yy, H - 1 - yy])
height -= 0.35 * (1.0 - smooth(edge, 0, 9))

# ---------------------------------------------------------------- wood grain
def grain_set(seed, vertical):
    """(tone, fine) 0..1 fields. Vertical: stretched along y; else along x."""
    if vertical:
        fine = fbm(6, 520, seed, 3)
        warp = fbm(2, 2, seed + 101, 1)
        coord = xx / W * 7.0 + 2.6 * warp
    else:
        fine = fbm(520, 6, seed, 3)
        warp = fbm(2, 2, seed + 101, 1)
        coord = yy / H * 7.0 + 2.6 * warp
    rings = 0.5 + 0.5 * np.sin(2 * np.pi * coord)
    rings = rings ** 1.6
    tone = 0.32 * rings + 0.68 * smooth(fine, 0.2, 0.8)
    return tone.astype(np.float32), fine.astype(np.float32)


print("grain...")
gv = [grain_set(10 + 31 * i, True) for i in range(4)]
gh = [grain_set(500 + 31 * i, False) for i in range(2)]

tone = np.zeros((H, W), np.float32)
fine = np.zeros((H, W), np.float32)
board_shift = np.zeros((H, W), np.float32)
for rid in np.unique(region):
    m = region == rid
    if rid == 1:
        t, f = gh[0]
    elif rid == 0:
        t, f = gv[0]
    else:
        t, f = gv[1 + rid % 3]
    tone[m], fine[m] = t[m], f[m]
    board_shift[m] = rng.uniform(-0.06, 0.06)
# the two stiles get different boards
right = (region == 0) & (xx > W / 2)
t, f = gv[3]
tone[right], fine[right] = t[right], f[right]
# the lock rail and the other rails come from different boards
lock = (region == 1) & (yy > row_y[1][1]) & (yy < row_y[2][0])
t, f = gh[1]
tone[lock], fine[lock] = t[lock], f[lock]

# knots: dark eye with rings that bend the grain around it
def knot(cx, cy, rx, ry):
    global tone, height
    d = np.sqrt(((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2)
    fall = np.exp(-d ** 2 / 1.6)
    tone = tone * (1 - 0.65 * fall) + 0.08 * np.sin(d * 9.0) * np.exp(-d ** 2 / 6.0)
    height -= 0.025 * fall

knot(W * 0.945, H * 0.215, 12, 22)      # right stile
knot(W * 0.045, H * 0.80, 10, 18)       # left stile
knot(W * 0.30, H * 0.605, 16, 9)        # lock rail
knot(W * 0.72, H * 0.945, 18, 10)       # bottom rail

# ---------------------------------------------------------------- height -> AO / normal
height += 0.012 * (fine - 0.5)          # open pores
hs = blur(height, 1)                     # tiny blur so the 1px pore noise doesn't alias
cavity = np.clip(blur(height, 14) - height, 0, 1)
ao = 1.0 - np.clip(cavity * 2.4, 0, 0.75)

k = 5.0
gx = np.gradient(hs, axis=1) * k
gy = np.gradient(hs, axis=0) * k
n = np.stack([-gx, gy, np.ones_like(gx)], axis=-1)       # OpenGL: +Y up, image rows run down
n /= np.linalg.norm(n, axis=-1, keepdims=True)
normal = ((n * 0.5 + 0.5) * 255).astype(np.uint8)

# ---------------------------------------------------------------- albedo
dark = np.array([0.20, 0.105, 0.05], np.float32)
light = np.array([0.50, 0.29, 0.14], np.float32)
t = np.clip(tone + board_shift, 0, 1)[..., None]
col = dark * (1 - t) + light * t

# panel fields a touch lighter and redder than the frame, like re-stained inserts
panel = (region >= 3)[..., None]
col = np.where(panel, col * np.array([1.07, 1.04, 1.0], np.float32), col)

# blotchy uneven stain / old varnish
blot = fbm(4, 2, 900, 5)
col *= (0.92 + 0.16 * blot)[..., None]

# dark pores
pores = np.where(region == 1, smooth(noise(900, 170, 777), 0.80, 0.95), smooth(noise(170, 900, 778), 0.80, 0.95))
col *= (1 - 0.28 * pores)[..., None]

# grime packed into the joints and grooves, darker toward the floor
col *= (0.45 + 0.55 * ao)[..., None]
col *= (1.0 - 0.28 * smooth(yy / H, 0.8, 1.0))[..., None]

# raised edges rubbed down to lighter bare wood
rub = smooth(np.clip(hs - blur(hs, 3), 0, 1) * 8.0, 0.2, 0.9) * (0.4 + 0.6 * fbm(30, 15, 55, 3))
col += (rub * 0.08)[..., None] * np.array([1.0, 0.8, 0.5], np.float32)

# hands: darker, greasy patch round the knob and the latch stile
hand = np.exp(-(((xx - W * 0.93) / (W * 0.07)) ** 2 + ((yy - H * 0.556) / (H * 0.05)) ** 2))
col *= (1.0 - 0.22 * hand)[..., None]

albedo = (np.clip(col, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)   # values above are linear-ish; store sRGB

# ---------------------------------------------------------------- roughness
rough = 0.58 + 0.10 * (fine - 0.5) + 0.22 * (1 - ao) + 0.18 * fbm(8, 4, 321, 3)
rough += 0.18 * rub
rough -= 0.22 * hand
rough = np.clip(rough, 0.25, 1.0)

# ---------------------------------------------------------------- write
os.makedirs(OUT, exist_ok=True)
Image.fromarray(albedo).save(os.path.join(OUT, "Door1.jpg"), quality=95, subsampling=0)
Image.fromarray(normal).save(os.path.join(OUT, "Door1_Normal.png"))
Image.fromarray((rough * 255).astype(np.uint8), "L").save(os.path.join(OUT, "Door1_Roughness.png"))
Image.fromarray((np.clip(ao, 0, 1) * 255).astype(np.uint8), "L").save(os.path.join(OUT, "Door1_AO.png"))
print("done ->", os.path.normpath(OUT))
