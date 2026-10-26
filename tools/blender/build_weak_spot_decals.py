"""Decal textures for the weak spot in the Level 0 wallpaper (a Godot Decal projects them onto the wall).

Writes to godot-backrooms/textures/weak_spot/, each 1024 x 2048, covering 1.2 m wide x 2.4 m tall of wall; the hole
(0.9 m x 2.1 m) sits centred horizontally with its bottom on the texture's bottom edge (px x 128..896, rows 256..2048):
  tell_albedo.png   RGBA  the intact tell: faint water-stain tide lines, a yellowed / darkened patch, a few hairline
                          cracks, a seam lifting a little. Alpha stays low (0.05-0.5); it never reads as obvious. The
                          whole bulge area has a little alpha so a Decal that masks its normal by albedo alpha still
                          shows the bulge.
  tell_normal.png   RGB   OpenGL normal map (green = up): the bulge, buckled paper, the cracks, the seam ridge
  crack_1/2/3.png   RGBA  the hold-E cracking, growing from the centre (stage 3: a spiderweb, the paper split and
                          flaking off). Each stage contains the previous ones, wider.
Pure numpy, no rendering. Previews of each on a flat piece of the wallpaper (lit by a grazing light through the
normal map) go to the preview dir.

    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --factory-startup --python tools/blender/build_weak_spot_decals.py -- <preview dir>
"""
import math
import os
import random
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import weak_spot_common as C  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
PREVIEW = ARGS[0] if ARGS else str(C.ROOT / "assetsimported" / "weak_spot" / "previews")

W, H = 1024, 2048
PX = W / 1.2                     # pixels per metre
CX, CH = 0.6, 1.15               # crack centre: metres from the left, metres up from the floor


def to_px(u, h):
    """metres (from the left edge, up from the floor) to pixel (x, row from the top)"""
    return np.stack([np.asarray(u) * PX, (2.4 - np.asarray(h)) * PX], axis=-1)


def value_noise(shape, cells, seed):
    """smooth value noise, `cells` lattice cells across the width"""
    rng = np.random.default_rng(seed)
    h, w = shape
    gw = cells + 2
    gh = int(cells * h / w) + 2
    g = rng.random((gh + 1, gw + 1)).astype(np.float32)
    ys = np.linspace(0, gh - 2, h, dtype=np.float32)
    xs = np.linspace(0, gw - 2, w, dtype=np.float32)
    y0 = np.floor(ys).astype(int)
    x0 = np.floor(xs).astype(int)
    fy = ys - y0
    fx = xs - x0
    fy = fy * fy * (3 - 2 * fy)
    fx = fx * fx * (3 - 2 * fx)
    a = g[y0][:, x0]
    b = g[y0][:, x0 + 1]
    c = g[y0 + 1][:, x0]
    d = g[y0 + 1][:, x0 + 1]
    top = a + (b - a) * fx[None, :]
    bot = c + (d - c) * fx[None, :]
    return top + (bot - top) * fy[:, None]


def fbm(shape, cells, octaves, seed, gain=0.5):
    out = np.zeros(shape, np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += amp * value_noise(shape, cells * 2 ** o, seed + 17 * o)
        tot += amp
        amp *= gain
    return out / tot


def sstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


YY, XX = np.mgrid[0:H, 0:W].astype(np.float32)
U = XX / PX                       # metres from the left
HM = 2.4 - YY / PX                # metres up from the floor


# ---------------------------------------------------------------------------------------------------------------
# crack networks

def walk(rng, start, ang, length, step=0.006, wiggle=0.32, bias=None, bias_k=0.25):
    """a jagged crack path (metres); bias: a direction it keeps returning to"""
    pts = [np.array(start, float)]
    a = ang
    n = int(length / step)
    for _ in range(n):
        a += rng.gauss(0, wiggle)
        if bias is not None:
            d = (bias - a + math.pi) % (2 * math.pi) - math.pi
            a += d * bias_k
        s = step * rng.uniform(0.6, 1.5)
        pts.append(pts[-1] + np.array((math.cos(a), math.sin(a))) * s)
    return np.array(pts)


def crack_network(seed=5):
    """list of (points (N,2) metres, stage born 1..3, base width px) for the cracking, centred on (CX, CH)"""
    rng = random.Random(seed)
    cracks = []
    c = np.array((CX, CH))
    nrad = 9
    angs = [2 * math.pi * (i + rng.uniform(-0.3, 0.3)) / nrad for i in range(nrad)]
    radials = []
    for a in angs:
        # how far this direction can go before the hole edge (stage 3 reaches it)
        dx, dy = math.cos(a), math.sin(a)
        lim = min((0.45 / abs(dx)) if abs(dx) > 1e-3 else 9, ((2.1 - CH) / dy) if dy > 0 else ((CH - 0.05) / -dy) if dy < 0 else 9)
        L = min(lim * rng.uniform(0.85, 1.05), 1.15)
        p = walk(rng, c + np.array((dx, dy)) * 0.015, a, L, bias=a, bias_k=0.18)
        r = np.linalg.norm(p - c, axis=1)
        # split the path into stages by distance from the centre
        lim1, lim2 = rng.uniform(0.12, 0.22), rng.uniform(0.32, 0.5)
        for lo, hi, st in ((0, lim1, 1), (lim1, lim2, 2), (lim2, 9, 3)):
            sel = np.where((r >= lo - 1e-6) & (r <= hi))[0]
            if len(sel) > 1:
                seg = p[max(sel[0] - 1, 0):sel[-1] + 1]
                cracks.append((seg, st, 2.2 if st == 1 else 1.8))
        radials.append((a, p, r))
        # branches
        for k in range(3):
            i = rng.randrange(len(p) // 5, len(p) - 2)
            ri = r[i]
            st = 1 if ri < 0.14 else 2 if ri < 0.4 else 3
            ba = a + rng.choice((-1, 1)) * rng.uniform(0.35, 0.9)
            bp = walk(rng, p[i], ba, rng.uniform(0.05, 0.22), bias=ba, bias_k=0.12)
            cracks.append((bp, max(st, 2 if k else st), 1.2))
    # concentric rings between neighbouring radials (the spiderweb)
    for ring_r, st in ((0.07, 1), (0.13, 2), (0.24, 2), (0.36, 3), (0.5, 3), (0.68, 3)):
        for i in range(nrad):
            if rng.random() < (0.15 if st < 3 else 0.3):
                continue
            a0, p0, r0 = radials[i]
            a1, p1, r1 = radials[(i + 1) % nrad]
            rr0 = ring_r * rng.uniform(0.85, 1.15)
            rr1 = ring_r * rng.uniform(0.85, 1.15)
            if r0[-1] < rr0 or r1[-1] < rr1:
                continue
            q0 = p0[np.argmin(abs(r0 - rr0))]
            q1 = p1[np.argmin(abs(r1 - rr1))]
            n = max(3, int(np.linalg.norm(q1 - q0) / 0.012))
            t = np.linspace(0, 1, n)[:, None]
            mid = q0 * (1 - t) + q1 * t
            # bow slightly toward the centre, jagged
            toward = (c - (q0 + q1) / 2)
            toward /= max(np.linalg.norm(toward), 1e-6)
            mid = mid + toward * (np.sin(np.pi * t) * np.linalg.norm(q1 - q0) * rng.uniform(0.02, 0.12))
            mid[1:-1] += np.array([[rng.gauss(0, 0.003), rng.gauss(0, 0.003)] for _ in range(n - 2)])
            cracks.append((mid, st, 1.4 if st < 3 else 1.6))
    return cracks


def render_cracks(cracks, stage, seed):
    """RGBA for one stage: dark crack gaps, torn light paper edges, slight dirt halo, paper flakes off near the
    centre at stage 3"""
    rng = np.random.default_rng(seed)
    core = np.zeros((H, W), np.float32)
    edge = np.zeros((H, W), np.float32)
    halo = np.zeros((H, W), np.float32)
    c = np.array((CX, CH))
    buckets = {}
    for pts, st, wbase in cracks:
        if st > stage:
            continue
        grow = stage - st
        r = np.linalg.norm(pts.mean(axis=0) - c)
        crush = 1.0 + 2.4 * max(0.0, 0.3 - r) / 0.3 * (stage - 1) / 2
        w = wbase * (0.55 + 0.45 * grow) * crush
        key = round(min(max(w, 0.5), 4.0) * 2) / 2
        buckets.setdefault(key, []).append(to_px(pts[:, 0], pts[:, 1]))
    for w, lines in buckets.items():
        core += C.splat_lines((H, W), lines, w * 0.45, 1.0)
        # the torn paper edge shows up beside the gap (offset down-right a pixel or two)
        shifted = [l + np.array((0.8 + w * 0.35, 0.8 + w * 0.35)) for l in lines]
        edge += C.splat_lines((H, W), shifted, w * 0.4, 0.8)
        halo += C.splat_lines((H, W), lines, w * 2.5 + 2.0, 0.6)
    core = np.clip(core, 0, 1)
    edge = np.clip(edge - core, 0, 1)
    halo = np.clip(halo, 0, 1)
    rgba = np.zeros((H, W, 4), np.float32)
    dark = np.array((0.09, 0.07, 0.05))
    paper = np.array((0.80, 0.77, 0.66))
    dirt = np.array((0.25, 0.21, 0.13))
    a_halo = halo * (0.12 + 0.08 * (stage - 1))
    a_edge = edge * (0.25 + 0.2 * (stage - 1))
    a_core = core * (0.75 + 0.1 * (stage - 1))
    col = dirt[None, None, :] * a_halo[..., None]
    a = a_halo
    for cc, aa in ((paper, a_edge), (dark, a_core)):
        col = col * (1 - aa[..., None]) + cc[None, None, :] * aa[..., None]
        a = a + aa * (1 - a)
    # stage 2+: the paper buckles and darkens round the centre
    d = np.hypot(U - CX, (HM - CH) * 0.85)
    if stage >= 2:
        buck = (1 - sstep(0.05, 0.35 + 0.1 * stage, d)) * (0.10 + 0.06 * (stage - 2))
        col = col * (1 - buck[..., None]) + dirt[None, None, :] * buck[..., None]
        a = a + buck * (1 - a)
    # stage 3: flakes of wallpaper gone near the centre (grey plasterboard paper shows), split paper
    if stage >= 3:
        flake = np.zeros((H, W), np.float32)
        prng = random.Random(seed)
        near = [p for pts, st, _ in cracks for p in pts if np.linalg.norm(p - c) < 0.3]
        for _ in range(34):
            q = np.array(prng.choice(near)) + np.array((prng.gauss(0, 0.01), prng.gauss(0, 0.01)))
            rad = prng.uniform(0.006, 0.022) * (1.4 - np.linalg.norm(q - c) / 0.3)
            n = prng.randint(4, 7)
            poly = [q + rad * prng.uniform(0.5, 1.2) * np.array((math.cos(2 * math.pi * (k + prng.uniform(-0.3, 0.3)) / n),
                                                                  math.sin(2 * math.pi * (k + prng.uniform(-0.3, 0.3)) / n))) for k in range(n)]
            pp = to_px(np.array([p[0] for p in poly]), np.array([p[1] for p in poly]))
            x0, y0 = np.floor(pp.min(0)).astype(int)
            x1, y1 = np.ceil(pp.max(0)).astype(int) + 1
            xs, ys = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
            inside = np.zeros(xs.shape, bool)
            for k in range(n):
                (ax, ay), (bx, by) = pp[k], pp[(k + 1) % n]
                cond = ((ay > ys) != (by > ys)) & (xs < (bx - ax) * (ys - ay) / (by - ay + 1e-9) + ax)
                inside ^= cond
            flake[y0:y1, x0:x1] = np.maximum(flake[y0:y1, x0:x1], inside)
        flake = C.gauss_blur(flake, 0.6)
        board = np.array((0.62, 0.60, 0.55))
        col = col * (1 - flake[..., None]) + board[None, None, :] * flake[..., None]
        a = a + flake * (1 - a)
        rim = np.clip(C.gauss_blur(flake, 1.5) - flake, 0, 1) * 2.0
        col = col * (1 - rim[..., None] * 0.6) + paper[None, None, :] * rim[..., None] * 0.6
    rgba[..., :3] = np.where(a[..., None] > 1e-4, col / np.maximum(a[..., None], 1e-4), 0)
    rgba[..., 3] = a
    return rgba


# ---------------------------------------------------------------------------------------------------------------
# the tell

def tell(seed=9):
    rng = random.Random(seed)
    # the patch: yellowed, darker, irregular, over the hole area
    n1 = fbm((H, W), 6, 5, seed)
    n2 = fbm((H, W), 18, 4, seed + 1)
    d = np.hypot((U - CX) / 0.5, (HM - 1.1) / 0.95)
    patch = 1 - sstep(0.55, 1.05, d + (n1 - 0.5) * 0.7)
    # water came down from above: tide lines are contours of a distorted distance from a point up high
    f = np.hypot((U - 0.62) / 0.40, (HM - 1.5) / 0.72) + (n1 - 0.5) * 0.5 + (n2 - 0.5) * 0.12
    tides = np.zeros((H, W), np.float32)
    for lvl, wd, k in ((1.0, 0.007, 1.0), (0.965, 0.005, 0.55), (0.84, 0.006, 0.35)):
        tides += k * np.exp(-((f - lvl) / wd) ** 2)
    inside = (1 - sstep(0.9, 1.0, f)) * 0.22 + (1 - sstep(0.75, 0.86, f)) * 0.08
    tides = np.clip(tides, 0, 1)
    # hairline cracks out of the centre
    lines = []
    c = np.array((CX, CH))
    for i in range(5):
        a = rng.uniform(0, 2 * math.pi)
        p = walk(rng, c + np.array((math.cos(a), math.sin(a))) * rng.uniform(0.0, 0.08), a, rng.uniform(0.08, 0.22),
                 step=0.005, wiggle=0.35, bias=a, bias_k=0.15)
        lines.append(to_px(p[:, 0], p[:, 1]))
    hair = np.clip(C.splat_lines((H, W), lines, 0.55, 1.0), 0, 1)
    # a wallpaper seam (rolls 0.53 m wide) at 0.85 m from the left, lifting a little in the middle
    seam_u = 0.853
    sd = (U - seam_u) * PX
    lift = sstep(0.55, 0.95, HM) * (1 - sstep(1.55, 1.95, HM))
    seam_dark = np.exp(-(sd / 0.7) ** 2) * (0.25 + 0.35 * lift)
    seam_light = np.exp(-((sd - 2.2) / 1.4) ** 2) * 0.35 * lift
    # colours (linear-ish 0..1 values written as sRGB-ish)
    rgb = np.zeros((H, W, 3), np.float32)
    a = np.zeros((H, W), np.float32)

    def over(col, alpha):
        nonlocal rgb, a
        col = np.asarray(col, np.float32)
        if col.ndim == 1:
            col = col[None, None, :]
        rgb = rgb * (1 - alpha[..., None]) + col * alpha[..., None]
        a = a + alpha * (1 - a)

    paper_tone = np.array((0.55, 0.52, 0.30))            # close to the wallpaper: alpha here barely shows
    over(paper_tone, patch * 0.10)
    over(np.array((0.52, 0.44, 0.22)), patch * (0.10 + 0.08 * n2))          # yellowed
    over(np.array((0.36, 0.30, 0.16)), inside * patch)                      # stained inside the tide lines
    over(np.array((0.30, 0.22, 0.10)), tides * 0.42)                        # tide lines
    over(np.array((0.18, 0.15, 0.10)), hair * 0.55)
    over(np.array((0.20, 0.17, 0.10)), seam_dark)
    over(np.array((0.78, 0.74, 0.55)), seam_light)
    # faint mould freckles low down inside the patch
    speck = (np.random.default_rng(seed).random((H, W)) > 0.9993).astype(np.float32)
    speck = np.clip(C.gauss_blur(speck, 1.3) * 8, 0, 1) * patch * (1 - sstep(0.3, 0.9, HM))
    over(np.array((0.10, 0.10, 0.07)), speck * 0.45)
    border = sstep(0.0, 0.1, U) * sstep(0.0, 0.1, 1.2 - U) * sstep(0.0, 0.1, 2.4 - HM)
    rgba = np.zeros((H, W, 4), np.float32)
    rgba[..., :3] = np.where(a[..., None] > 1e-4, rgb / np.maximum(a[..., None], 1e-4), paper_tone)
    rgba[..., 3] = a * border
    # height for the normal map: bulge, buckled paper on it, cracks as grooves, the seam ridge
    bulge = np.exp(-(((U - CX) / 0.36) ** 2 + ((HM - 1.15) / 0.62) ** 2) * 1.0)
    buckle = (fbm((H, W), 14, 3, seed + 5) - 0.5) * bulge
    groove = C.gauss_blur(hair, 0.8)
    height = bulge * 35.0 + buckle * 5.0 - groove * 0.7 + seam_light * 0.9 + tides * 0.1
    return rgba, height * border


def height_to_normal(height, strength):
    """OpenGL convention: +X right, +Y up (row 0 is the top, so up is -row)"""
    gx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
    gy = (np.roll(height, 1, axis=0) - np.roll(height, -1, axis=0)) * 0.5     # d/d(up)
    nx, ny, nz = -gx * strength, -gy * strength, np.ones_like(height)
    l = np.sqrt(nx * nx + ny * ny + nz * nz)
    n = np.stack([nx / l, ny / l, nz / l], axis=-1)
    out = np.ones((height.shape[0], height.shape[1], 4), np.float32)
    out[..., :3] = n * 0.5 + 0.5
    return out


# ---------------------------------------------------------------------------------------------------------------
# previews: the decal laid over the wallpaper, lit through the normal map

def load_px(path):
    im = bpy.data.images.load(str(path))
    w, h = im.size
    a = np.array(im.pixels[:], np.float32).reshape(h, w, 4)
    return np.flipud(a)           # row 0 = top


def wall_patch():
    """the wallpaper as it shows on 1.2 m x 2.4 m of wall from the floor up (resampled to the decal's pixels)"""
    wc = load_px(C.WALL_COLOR)
    wn = load_px(C.WALL_NORMAL)
    hh, ww = wc.shape[:2]
    ppm = ww / C.PAPER_W
    rows = (C.WALL_H - np.clip(HM, C.SKIRT_HIDE, None)) * ppm
    cols = (U + 0.3) * ppm
    ri = np.clip(rows.astype(int), 0, hh - 1)
    ci = np.clip(cols.astype(int), 0, ww - 1) % ww
    return wc[ri, ci, :3] * np.array(C.PAPER_TINT), wn[ri, ci, :3] * 2 - 1


def preview_on_wall(name, rgba, normal=None, light=(-0.75, 0.35, 0.55)):
    base, wnrm = wall_patch()
    a = rgba[..., 3:4]
    col = base * (1 - a) + rgba[..., :3] * a
    n = np.zeros_like(base)
    n[..., 2] = 1
    n[..., :2] = wnrm[..., :2] * 0.25
    if normal is not None:
        dn = normal[..., :3] * 2 - 1
        n[..., :2] += dn[..., :2]
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    L = np.array(light, np.float32)
    L /= np.linalg.norm(L)
    lam = np.clip((n * L).sum(-1), 0, 1) / max(L[2], 1e-3)
    shade = 0.35 + 0.65 * lam
    out = np.ones((H, W, 4), np.float32)
    out[..., :3] = np.clip(col * shade[..., None], 0, 1)
    # half size, with the hole outline dotted in for reference
    small = out[::2, ::2].copy()
    hx0, hx1, hy0 = 128 // 2, 896 // 2, 256 // 2
    small[hy0, hx0:hx1:6, :3] = (1, 0, 0)
    small[hy0:, hx0, :3][::6] = (1, 0, 0)
    small[hy0:, hx1, :3][::6] = (1, 0, 0)
    os.makedirs(PREVIEW, exist_ok=True)
    C.save_rgba(os.path.join(PREVIEW, f"decal_{name}.png"), small)


def main():
    C.TEX_DIR.mkdir(parents=True, exist_ok=True)
    rgba, height = tell()
    C.save_rgba(C.TEX_DIR / "tell_albedo.png", rgba)
    nrm = height_to_normal(height, 1.0)
    im = C.save_rgba(C.TEX_DIR / "tell_normal.png", nrm)
    print("tell alpha: mean %.3f max %.3f; normal tilt max %.1f deg" % (
        rgba[..., 3].mean(), rgba[..., 3].max(), math.degrees(math.acos(float((nrm[..., 2] * 2 - 1).min())))))
    preview_on_wall("tell", rgba, nrm)
    cracks = crack_network()
    for st in (1, 2, 3):
        cr = render_cracks(cracks, st, 30 + st)
        C.save_rgba(C.TEX_DIR / f"crack_{st}.png", cr)
        print(f"crack_{st}: alpha mean %.3f, %d cracks" % (cr[..., 3].mean(), sum(1 for _, s, _ in cracks if s <= st)))
        # preview: the tell underneath, then the crack stage
        comb = rgba.copy()
        a2 = cr[..., 3:4]
        comb[..., :3] = rgba[..., :3] * rgba[..., 3:4] * (1 - a2) + cr[..., :3] * a2
        comb[..., 3:4] = rgba[..., 3:4] + a2 * (1 - rgba[..., 3:4])
        comb[..., :3] /= np.maximum(comb[..., 3:4], 1e-4)
        preview_on_wall(f"crack_{st}", comb, nrm)
    # an orientation check: the hole occupies the middle 0.9 m and the lower 2.1 m
    print("wrote", C.TEX_DIR)


main()
