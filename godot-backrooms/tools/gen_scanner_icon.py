"""Draws the T.S.R.A. field scanner's inventory icon (textures/items/scanner/scanner_icon.png):
a rugged handheld with a radar screen, antenna, keypad and ribbed grip, tilted a little, on a
transparent background. Shapes are signed distance fields with analytic anti-aliasing, composited
back to front. Pure standard library. Run from anywhere: python tools/gen_scanner_icon.py
"""
import math, os, struct, zlib

SIZE = 256                     # same as the icons rendered from 3D models (item_icon.gd SIZE)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'textures', 'items', 'scanner', 'scanner_icon.png')
TILT = math.radians(-11)       # the device leans a little to the right
S = SIZE / 256.0               # everything below is laid out on a 256 px grid


# ---------------------------------------------------------------- distance fields (256 grid units)
def rrect(x, y, cx, cy, hw, hh, r):
    qx = abs(x - cx) - hw + r
    qy = abs(y - cy) - hh + r
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def circle(x, y, cx, cy, r):
    return math.hypot(x - cx, y - cy) - r


def ring(x, y, cx, cy, r, w):
    return abs(math.hypot(x - cx, y - cy) - r) - w


def seg(x, y, ax, ay, bx, by, w):
    px, py = x - ax, y - ay
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, (px * dx + py * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - dx * t, py - dy * t) - w


# ---------------------------------------------------------------- the device
BODY = (128, 138, 62, 96, 16)          # cx, cy, half w, half h, corner radius
SCREEN = (128, 100, 46, 40, 7)
RADAR = (128, 100)
GREEN = (0.35, 1.0, 0.55)


def layers(x, y):
    """(sdf, (r, g, b)[, opacity]) back to front for the point (x, y) on the 256 grid."""
    out = []
    # antenna: a stubby whip off the top left, red tip
    out.append((seg(x, y, 92, 50, 80, 8, 4.2), (0.16, 0.16, 0.17)))
    out.append((seg(x, y, 91, 46, 83, 18, 1.6), (0.36, 0.37, 0.39)))
    out.append((circle(x, y, 79, 7, 6.5), (0.95, 0.22, 0.14)))
    out.append((circle(x, y, 77.5, 5.5, 2.2), (1.0, 0.75, 0.65)))
    # body: dark bevel, then the gunmetal face
    cx, cy, hw, hh, r = BODY
    out.append((rrect(x, y, cx, cy, hw, hh, r), (0.09, 0.09, 0.1)))
    out.append((rrect(x, y, cx, cy - 1.5, hw - 5, hh - 5, r - 4), (0.27, 0.28, 0.3)))
    # a soft highlight down the left edge of the face
    out.append((max(rrect(x, y, cx, cy - 1.5, hw - 5, hh - 5, r - 4), x - 78), (0.36, 0.37, 0.4)))
    # amber rubber bumpers on the four corners
    for sx in (-1, 1):
        for sy in (-1, 1):
            bx, by = cx + sx * (hw - 9), cy + sy * (hh - 9)
            d = max(rrect(x, y, cx, cy, hw + 1.5, hh + 1.5, r + 1.5), -rrect(x, y, cx, cy, hw - 5, hh - 5, r - 4))
            d = max(d, circle(x, y, bx, by, 22))
            out.append((d, (0.93, 0.55, 0.12)))
    # screen bezel and glass
    sx_, sy_, shw, shh, sr = SCREEN
    out.append((rrect(x, y, sx_, sy_, shw + 4, shh + 4, sr + 3), (0.06, 0.06, 0.07)))
    glass = rrect(x, y, sx_, sy_, shw, shh, sr)
    out.append((glass, (0.02, 0.1, 0.06)))
    # radar: rings, cross, sweep, blips (clipped to the glass)
    rx, ry = RADAR
    dim = tuple(c * 0.45 for c in GREEN)
    for rad in (12, 24, 36):
        out.append((max(ring(x, y, rx, ry, rad, 0.7), glass), dim))
    out.append((max(min(seg(x, y, rx - 44, ry, rx + 44, ry, 0.5), seg(x, y, rx, ry - 38, rx, ry + 38, 0.5)), glass), dim))
    # sweep: a wedge fading behind the beam
    ang = math.atan2(y - ry, x - rx)
    beam = math.radians(-40)
    behind = (beam - ang) % math.tau
    dist = math.hypot(x - rx, y - ry)
    if behind < 1.1 and dist < 38:
        k = (1.0 - behind / 1.1) ** 2
        out.append((glass, GREEN, 0.4 * k))
    out.append((max(seg(x, y, rx, ry, rx + math.cos(beam) * 38, ry + math.sin(beam) * 38, 1.1), glass), GREEN))
    out.append((max(circle(x, y, rx + 20, ry - 13, 3.2), glass), (0.75, 1.0, 0.8)))
    out.append((max(circle(x, y, rx - 17, ry + 19, 2.4), glass), (1.0, 0.45, 0.2)))
    out.append((circle(x, y, rx, ry, 1.8), GREEN))
    # glare across the top of the glass
    out.append((max(glass, seg(x, y, sx_ - 40, sy_ - 31, sx_ - 16, sy_ - 37, 3)), (0.8, 1.0, 0.9), 0.14))
    # hazard label strip under the screen
    lab = rrect(x, y, 128, 152, 44, 5, 2)
    out.append((lab, (0.93, 0.62, 0.1)))
    stripe = ((x + y) % 10) < 5
    if stripe:
        out.append((lab, (0.1, 0.09, 0.08)))
    # keypad: big trigger button, two small, a status LED
    out.append((circle(x, y, 103, 177, 11), (0.08, 0.08, 0.09)))
    out.append((circle(x, y, 103, 176, 8.5), (0.85, 0.2, 0.12)))
    out.append((circle(x, y, 100.5, 173.5, 3.0), (1.0, 0.55, 0.45)))
    for bx in (133, 155):
        out.append((rrect(x, y, bx, 176, 8, 5.5, 2.5), (0.08, 0.08, 0.09)))
        out.append((rrect(x, y, bx, 175, 6.5, 4.0, 2), (0.45, 0.46, 0.48)))
    out.append((circle(x, y, 160, 158, 2.2), GREEN))
    # grip: ribs across the lower body
    for i in range(4):
        gy = 199 + i * 8
        out.append((rrect(x, y, 128, gy, 40, 1.6, 1.6), (0.12, 0.12, 0.13)))
    return out


# ---------------------------------------------------------------- raster + png
def over(dst, src, a):
    r, g, b, da = dst
    na = a + da * (1 - a)
    if na <= 0:
        return (0.0, 0.0, 0.0, 0.0)
    return tuple((s * a + d * da * (1 - a)) / na for s, d in zip(src, (r, g, b))) + (na,)


def render():
    px = 1.0 / S                                   # one output pixel on the 256 grid
    c, s = math.cos(-TILT), math.sin(-TILT)
    rows = []
    for j in range(SIZE):
        row = bytearray()
        for i in range(SIZE):
            u = (i + 0.5) / S - 128
            v = (j + 0.5) / S - 128
            x = c * u - s * v + 128                # undo the tilt: the layout is drawn upright
            y = s * u + c * v + 128
            col = (0.0, 0.0, 0.0, 0.0)
            if rrect(x, y, 128, 130, 70, 128, 20) < 2 or y < 20:
                for layer in layers(x, y):
                    d, rgb = layer[0], layer[1]
                    a = max(0.0, min(1.0, 0.5 - d / px)) * (layer[2] if len(layer) > 2 else 1.0)
                    if a > 0:
                        col = over(col, rgb, a)
            row += bytes(int(max(0, min(1, ch)) * 255 + 0.5) for ch in col)
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    raw = b''.join(b'\x00' + r for r in rows)
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))
    print('wrote', os.path.normpath(path))


if __name__ == '__main__':
    write_png(OUT, render())
