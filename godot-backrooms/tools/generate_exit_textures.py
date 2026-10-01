"""
Generates the textures of the level exit (scripts/World/props/level_exit.gd) into textures/props/exit/:
- exit_leaf.png, _normal, _rough, _metal: the painted steel fire door: roller-streaked dark green enamel, a
                   pressed rim, chips down to primer and rust at the edges, scratches, grime toward the floor
                   and a brushed steel kick plate
- exit_frame.png, _normal, _rough: the same enamel on the pressed steel frame, knocked about; it tiles (1 m
                   square) and is laid on triplanar
- exit_sign.png:   the lit < EXIT > lightbox over the door (albedo and emission both)
- exit_man.png:    the running-man plate on the leaf: the ISO 7010 E001 pictogram (tools/iso7010_e001.png)
                   over an arrow down, scuffed

u runs left -> right as you face the door, v top -> bottom.
Needs numpy + Pillow. Run from anywhere: python tools/generate_exit_textures.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "textures", "props", "exit")


def noise(h, w, ny, nx, seed):
    """Smooth value noise: an ny x nx lattice stretched over h x w."""
    r = np.random.default_rng(seed).random((ny + 1, nx + 1)).astype(np.float32)
    return np.asarray(Image.fromarray(r).resize((w, h), Image.BICUBIC)).clip(0, 1)


def fbm(h, w, ny, nx, seed, octaves=4):
    out = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += amp * noise(h, w, ny * 2 ** o, nx * 2 ** o, seed + o * 17)
        tot += amp
        amp *= 0.5
    return out / tot


def tnoise(h, w, ny, nx, seed):
    """noise() that tiles: the lattice wraps round."""
    r = np.random.default_rng(seed).random((ny, nx)).astype(np.float32)
    r = np.pad(r, 2, mode="wrap")
    big = np.asarray(Image.fromarray(r).resize((w * (nx + 4) // nx, h * (ny + 4) // ny), Image.BICUBIC))
    y0, x0 = 2 * h // ny, 2 * w // nx
    return big[y0:y0 + h, x0:x0 + w].clip(0, 1)


def tfbm(h, w, ny, nx, seed, octaves=4):
    out = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += amp * tnoise(h, w, ny * 2 ** o, nx * 2 ** o, seed + o * 17)
        tot += amp
        amp *= 0.5
    return out / tot


def smooth(a, lo, hi):
    t = np.clip((a - lo) / (hi - lo), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def lerp(a, b, t):
    return a * (1 - t[..., None]) + b * t[..., None]


def srgb(col):
    return (np.clip(col, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)


def gray(a):
    return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8), "L")


def scratches(h, w, n, seed, y_lo=0.0, y_hi=1.0, long=0.12):
    """Thin random scratches, 0..1, drawn large and shrunk so they come out soft."""
    rng = np.random.default_rng(seed)
    s = 2
    im = Image.new("L", (w * s, h * s), 0)
    d = ImageDraw.Draw(im)
    for _ in range(n):
        x = rng.uniform(0, w * s)
        y = rng.uniform(y_lo, y_hi) * h * s
        a = rng.uniform(0, np.pi)
        ln = rng.uniform(0.02, long) * h * s
        d.line([(x, y), (x + np.cos(a) * ln, y + np.sin(a) * ln)], fill=int(rng.uniform(90, 255)), width=int(rng.integers(1, 3)))
    return np.asarray(im.resize((w, h), Image.LANCZOS), np.float32) / 255.0


def font(px):
    for name in ("arialbd.ttf", "Arial Bold.ttf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf"):
        try:
            return ImageFont.truetype(name, px)
        except OSError:
            pass
    return ImageFont.load_default(px)


# ================================================================ the leaf
def leaf():
    W, H = 512, 1024
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    u, v = xx / W, yy / H
    edge = np.minimum.reduce([xx, W - 1 - xx, yy, H - 1 - yy])

    blot = fbm(H, W, 6, 3, 11)
    streak = noise(H, W, 5, 200, 23)                      # roller marks, running down the door
    fine = noise(H, W, 400, 200, 31)                      # orange peel
    col = np.array([0.026, 0.046, 0.033], np.float32) * ((0.78 + 0.44 * blot) * (0.90 + 0.20 * streak))[..., None]
    height = 0.03 * (fine - 0.5) + 0.04 * (streak - 0.5)
    rough = 0.40 + 0.16 * (blot - 0.5) + 0.10 * (fine - 0.5)
    metal = np.zeros((H, W), np.float32)

    # the pressed rim a little way in from the edge
    rim = np.exp(-((edge - 24.0) / 3.0) ** 2)
    height -= 0.5 * rim
    col *= (1 - 0.30 * rim)[..., None]

    # sun-faded, chalky patches high up; greasy dark ones where it is pushed
    chalk = smooth(fbm(H, W, 5, 3, 47), 0.55, 0.8) * (1 - smooth(v, 0.3, 0.7))
    col = lerp(col, col * 1.3 + 0.006, chalk * 0.6)
    rough += 0.15 * chalk
    hand = np.exp(-(((u - 0.5) / 0.42) ** 2 + ((v - 0.47) / 0.07) ** 2)) * (0.6 + 0.4 * fbm(H, W, 10, 6, 53))
    col *= (1 - 0.30 * hand)[..., None]
    rough -= 0.20 * hand

    # paint chipped off: mostly along the edges, round the bar, and low down where it is kicked
    bias = 0.20 * np.exp(-edge / 16.0) + 0.10 * smooth(v, 0.72, 1.0) + 0.06 * np.exp(-((v - 0.535) / 0.03) ** 2)
    chip = smooth(fbm(H, W, 48, 24, 71, 4) + bias, 0.80, 0.83)
    rust = smooth(fbm(H, W, 20, 10, 83), 0.45, 0.65)
    under = lerp(np.broadcast_to(np.array([0.11, 0.11, 0.10], np.float32), (H, W, 3)),
                 np.broadcast_to(np.array([0.13, 0.055, 0.02], np.float32), (H, W, 3)), rust)
    under = under * (0.8 + 0.4 * fine)[..., None]
    col = lerp(col, under, chip)
    height -= 0.25 * chip
    rough = rough * (1 - chip) + (0.75 + 0.15 * rust) * chip
    # rust weeping down from the chips
    weep = np.zeros((H, W), np.float32)
    acc = np.zeros(W, np.float32)
    for y in range(H):
        acc = np.maximum(acc * 0.975, chip[y] * rust[y])
        weep[y] = acc
    weep *= (1 - chip) * noise(H, W, 6, 160, 97)
    col = lerp(col, col * 0.6 + np.array([0.05, 0.02, 0.005], np.float32), weep * 0.7)

    sc = scratches(H, W, 70, 5, 0.25, 1.0)
    col += (sc * 0.035)[..., None]
    height -= 0.15 * sc
    rough += 0.2 * sc

    # the kick plate: brushed steel screwed on low down
    x0, x1, y0, y1 = 0.07 * W, 0.93 * W, 0.845 * H, 0.965 * H
    inside = np.minimum.reduce([xx - x0, x1 - xx, yy - y0, y1 - yy])
    plate = smooth(inside, 0.0, 2.5)
    brush = noise(H, W, 700, 4, 101)
    steel = np.float32(0.22) * (0.75 + 0.5 * brush) * (0.75 + 0.5 * fbm(H, W, 12, 6, 113))
    scuff = smooth(fbm(H, W, 30, 40, 127), 0.55, 0.75) * smooth(v, 0.86, 0.95)        # boot marks
    steel = steel * (1 - 0.6 * scuff)
    steel_rgb = steel[..., None] * np.array([1.0, 1.0, 0.96], np.float32)
    col = lerp(col, steel_rgb, plate)
    height = height * (1 - plate) + plate * (0.35 + 0.05 * (brush - 0.5))
    rough = rough * (1 - plate) + plate * (0.30 + 0.22 * brush + 0.3 * scuff)
    metal = plate * (1 - 0.7 * scuff)
    col *= (1 - 0.45 * np.exp(-np.abs(inside) / 2.5) * (inside < 4))[..., None]     # the shadow line round it
    for sx in (x0 + 14, x1 - 14):
        for sy in (y0 + 14, y1 - 14):
            d = np.sqrt((xx - sx) ** 2 + (yy - sy) ** 2)
            head = smooth(6.0 - d, 0.0, 1.5)
            col = lerp(col, np.broadcast_to(np.array([0.22, 0.22, 0.21], np.float32), (H, W, 3)), head)
            height += 0.2 * head * (1 - (d / 6.0) ** 2).clip(0, 1)
            slot = head * (np.abs(yy - sy + (xx - sx) * 0.4) < 1.2)
            col *= (1 - 0.7 * slot)[..., None]
            height -= 0.25 * slot

    # grime: thick toward the floor, a little everywhere, dust lying in the rim
    grime = smooth(v, 0.62, 1.0) * (0.5 + 0.5 * fbm(H, W, 8, 5, 139)) + 0.25 * smooth(fbm(H, W, 7, 4, 149), 0.5, 0.9)
    col = lerp(col, col * 0.45 + np.array([0.012, 0.011, 0.008], np.float32), np.clip(grime, 0, 1) * 0.8)
    rough += 0.2 * np.clip(grime, 0, 1)

    k = 4.0
    gx = np.gradient(height, axis=1) * k
    gy = np.gradient(height, axis=0) * k
    n = np.stack([-gx, gy, np.ones_like(gx)], axis=-1)       # OpenGL: +Y up, image rows run down
    n /= np.linalg.norm(n, axis=-1, keepdims=True)

    Image.fromarray(srgb(col)).save(os.path.join(OUT, "exit_leaf.png"))
    Image.fromarray(((n * 0.5 + 0.5) * 255).astype(np.uint8)).save(os.path.join(OUT, "exit_leaf_normal.png"))
    gray(np.clip(rough, 0.12, 1.0)).save(os.path.join(OUT, "exit_leaf_rough.png"))
    gray(metal).save(os.path.join(OUT, "exit_leaf_metal.png"))


# ================================================================ the frame
def frame():
    W = H = 512
    blot = tfbm(H, W, 4, 4, 211)
    streak = tnoise(H, W, 4, 128, 223)                    # brush marks along the jambs
    fine = tnoise(H, W, 256, 256, 227)
    col = np.array([0.026, 0.046, 0.033], np.float32) * ((0.75 + 0.5 * blot) * (0.88 + 0.24 * streak))[..., None]
    height = 0.04 * (fine - 0.5) + 0.06 * (streak - 0.5)
    rough = 0.40 + 0.18 * (blot - 0.5) + 0.10 * (fine - 0.5)

    # knocks and chips, down to primer and rust
    chip = smooth(tfbm(H, W, 32, 32, 233, 4), 0.72, 0.75)
    rust = smooth(tfbm(H, W, 16, 16, 239), 0.42, 0.62)
    under = lerp(np.broadcast_to(np.array([0.11, 0.11, 0.10], np.float32), (H, W, 3)),
                 np.broadcast_to(np.array([0.13, 0.055, 0.02], np.float32), (H, W, 3)), rust)
    under = under * (0.8 + 0.4 * fine)[..., None]
    col = lerp(col, under, chip)
    height -= 0.3 * chip
    rough = rough * (1 - chip) + (0.75 + 0.15 * rust) * chip
    # a rust bloom round the chips, and greasy dark patches
    bloom = smooth(tfbm(H, W, 32, 32, 233, 4), 0.62, 0.74) * (1 - chip) * rust
    col = lerp(col, col * 0.7 + np.array([0.035, 0.014, 0.004], np.float32), bloom * 0.7)
    grime = smooth(tfbm(H, W, 6, 6, 251), 0.45, 0.85)
    col = lerp(col, col * 0.5 + np.array([0.010, 0.009, 0.007], np.float32), grime * 0.7)
    rough += 0.2 * grime + 0.1 * bloom

    k = 4.0
    gx = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * 0.5 * k
    gy = (np.roll(height, -1, 0) - np.roll(height, 1, 0)) * 0.5 * k
    n = np.stack([-gx, gy, np.ones_like(gx)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    Image.fromarray(srgb(col)).save(os.path.join(OUT, "exit_frame.png"))
    Image.fromarray(((n * 0.5 + 0.5) * 255).astype(np.uint8)).save(os.path.join(OUT, "exit_frame_normal.png"))
    gray(np.clip(rough, 0.12, 1.0)).save(os.path.join(OUT, "exit_frame_rough.png"))


# ================================================================ the lightbox
def sign():
    W, H, S = 512, 144, 4
    im = Image.new("L", (W * S, H * S), 0)
    d = ImageDraw.Draw(im)
    f = font(112 * S)
    box = d.textbbox((0, 0), "EXIT", font=f)
    d.text(((W * S - (box[2] - box[0])) / 2 - box[0], (H * S - (box[3] - box[1])) / 2 - box[1]), "EXIT", font=f, fill=255)
    for sx in (1, -1):
        cx = W * S / 2
        pts = [(cx - sx * 234 * S, 72 * S), (cx - sx * 200 * S, 40 * S), (cx - sx * 200 * S, 104 * S)]
        d.polygon(pts, fill=255)
    mask = np.asarray(im.resize((W, H), Image.LANCZOS), np.float32) / 255.0
    halo = np.asarray(im.resize((W // 8, H // 8), Image.BILINEAR).resize((W, H), Image.BICUBIC), np.float32) / 255.0

    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    u, v = xx / W, yy / H
    # the tube behind the lens: brightest along the middle, falling off to the ends and the edges
    glow = (0.50 + 0.50 * np.exp(-((v - 0.5) / 0.30) ** 2)) * (0.72 + 0.28 * np.exp(-((u - 0.5) / 0.42) ** 4))
    glow *= 0.92 + 0.16 * fbm(H, W, 6, 20, 7, 3)                                       # uneven diffuser
    green = np.array([0.02, 0.60, 0.22], np.float32) * glow[..., None]
    green += (halo * 0.10)[..., None] * np.array([0.5, 1.0, 0.6], np.float32)          # the letters bleed a little
    white = np.array([0.93, 1.0, 0.92], np.float32) * (0.80 + 0.20 * glow)[..., None]
    col = lerp(green, white, mask)

    # dust, and what has died in the bottom of the box
    dust = smooth(v, 0.70, 0.97) * (0.4 + 0.6 * fbm(H, W, 3, 40, 19, 3))
    col *= (1 - 0.55 * dust)[..., None]
    rng = np.random.default_rng(29)
    for _ in range(26):
        bx, by = rng.uniform(20, W - 20), H - 12 - abs(rng.normal(0, 5))
        r = rng.uniform(1.2, 3.2)
        col *= (1 - 0.8 * smooth(r - np.sqrt(((xx - bx) / 1.6) ** 2 + (yy - by) ** 2), -0.6, 0.6))[..., None]
    col *= (1 - 0.25 * scratches(H, W, 14, 37, long=0.5))[..., None]

    # the housing's bezel, and its shadow on the lens
    edge = np.minimum.reduce([xx, W - 1 - xx, yy, H - 1 - yy])
    col *= (0.45 + 0.55 * smooth(edge, 7.0, 20.0))[..., None]
    bezel = 1 - smooth(edge, 6.0, 8.0)
    col = lerp(col, np.broadcast_to(np.array([0.012, 0.016, 0.014], np.float32), (H, W, 3)), bezel)
    Image.fromarray(srgb(col)).save(os.path.join(OUT, "exit_sign.png"))


# ================================================================ the running man
def man():
    W, H, S = 256, 448, 4
    im = Image.new("L", (W * S, H * S), 0)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([7 * S, 7 * S, (W - 7) * S, (H - 7) * S], radius=10 * S, outline=255, width=3 * S)
    d.rectangle([112 * S, 268 * S, 144 * S, 362 * S], fill=255)                  # the arrow down
    d.polygon([(70 * S, 352 * S), (186 * S, 352 * S), (128 * S, 424 * S)], fill=255)
    mask = np.asarray(im.resize((W, H), Image.LANCZOS), np.float32) / 255.0
    # the pictogram itself is the real one: ISO 7010 E001 (public domain, from Wikimedia Commons), its
    # white margin cut off, white read off the red channel (the sign's green has next to none)
    src = Image.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "iso7010_e001.png")).convert("RGB")
    m = src.width * 32 // 1280
    pic = src.crop((m, m, src.width - m, src.height - m)).resize((224, 224), Image.LANCZOS)
    mask[20:244, 16:240] = np.clip((np.asarray(pic, np.float32)[..., 0] - 36.0) / 219.0, 0, 1)

    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    tone = 0.80 + 0.40 * fbm(H, W, 6, 4, 61)
    green = np.array([0.02, 0.30, 0.12], np.float32) * tone[..., None]
    white = np.array([0.82, 0.90, 0.80], np.float32) * (0.85 + 0.15 * tone)[..., None]
    col = lerp(green, white, mask)
    # print worn through to the bare plate, scratches, dirt in from the edges, a peeling corner's shadow
    worn = smooth(fbm(H, W, 40, 24, 67, 3) + 0.06 * smooth(yy / H, 0.6, 1.0), 0.86, 0.89)
    col = lerp(col, np.broadcast_to(np.array([0.30, 0.31, 0.28], np.float32), (H, W, 3)), worn * 0.85)
    col = lerp(col, np.broadcast_to(np.array([0.36, 0.38, 0.34], np.float32), (H, W, 3)), scratches(H, W, 12, 73, long=0.25) * 0.4)
    edge = np.minimum.reduce([xx, W - 1 - xx, yy, H - 1 - yy])
    dirt = (1 - smooth(edge, 0.0, 34.0)) * (0.4 + 0.6 * fbm(H, W, 10, 6, 79)) + 0.3 * smooth(fbm(H, W, 5, 3, 89), 0.55, 0.9)
    col *= (1 - 0.65 * np.clip(dirt, 0, 1))[..., None]
    Image.fromarray(srgb(col)).save(os.path.join(OUT, "exit_man.png"))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    leaf()
    frame()
    sign()
    man()
    print("done ->", os.path.normpath(OUT))
