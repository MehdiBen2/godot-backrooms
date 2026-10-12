"""Draws the T.S.R.A. emblem (two crystal shards split down the middle, ringed by an orbit) as amber
pixel art into textures/ui/tsra_logo.png, for the field terminal (scripts/UI/terminal_os.gd).
Standard library only; re-run from anywhere after tweaking:

    python tools/gen_tsra_logo.py

One texel per logo pixel, transparent background: the terminal draws it with nearest filtering, so the
blocks stay square at any size. The geometry is in the coordinates of the 1254 px reference drawing.
"""
import math, os, struct, zlib

N = 96                                   # logo pixels across
REF = 1254.0                             # the reference drawing's size
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'textures', 'ui', 'tsra_logo.png')

LINE = (0xff, 0xb8, 0x48)                # bright phosphor amber (Kit.AMBER, a touch hotter)
FILL_HI = (0x8a, 0x55, 0x12)             # the dithered glass of the shards
FILL_LO = (0x3a, 0x22, 0x06)

MID = 626.0                              # the split between the two shards
TOP, BOT = 88.0, 1145.0
SHOULDER_T, SHOULDER_B = 285.0, 950.0
OUTER = 405.0                            # outer wall of the left shard (the right mirrors it)
BAR = (576.0, 606.0)                     # the inner bar of the left shard
RING_C = (628.0, 612.0)
RING_A, RING_B = 492.0, 128.0
LINE_W = 9.0                             # half the stroke width


def seg_dist(p, a, b):
    ax, ay = a; bx, by = b; px, py = p
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def shard_outline(x, y):
    """The left shard's outer walls (pointed top, straight side, pointed bottom); x already folded left"""
    pts = [(BAR[1] - 8, TOP), (OUTER, SHOULDER_T), (OUTER, SHOULDER_B), (BAR[1] - 8, BOT)]
    return min(seg_dist((x, y), pts[i], pts[i + 1]) for i in range(3))


def in_shard(x, y, grow=0.0):
    if y < TOP - grow or y > BOT + grow or x < OUTER - grow or x > BAR[1] + grow:
        return False
    if y < SHOULDER_T:                    # the pointed top: the wall runs from the shoulder up to the tip
        k = (SHOULDER_T - y) / (SHOULDER_T - TOP)
        return x >= OUTER + k * (BAR[1] - 8 - OUTER) - grow
    if y > SHOULDER_B:
        k = (y - SHOULDER_B) / (BOT - SHOULDER_B)
        return x >= OUTER + k * (BAR[1] - 8 - OUTER) - grow
    return True


def ring_dist(x, y):
    dx, dy = x - RING_C[0], y - RING_C[1]
    f = (dx / RING_A) ** 2 + (dy / RING_B) ** 2 - 1.0
    g = math.hypot(2 * dx / RING_A ** 2, 2 * dy / RING_B ** 2)
    return abs(f) / max(g, 1e-6)


def pixel(i, j):
    cell = REF / N
    x, y = (i + 0.5) * cell, (j + 0.5) * cell
    fx = x if x <= MID else 2 * MID - x       # fold the right shard onto the left
    rd = ring_dist(x, y)
    front = y >= RING_C[1]                    # the near half of the orbit passes in front of the shards
    if front and rd < LINE_W + 2:
        return LINE
    if not front and rd < LINE_W + 2 and fx < OUTER - 10.0:
        return LINE                           # the far half is hidden behind them
    knock = (front and rd < 30.0) or (not front and rd < 26.0 and fx < OUTER + 20)
    if knock:
        return None                           # a dark gap round the orbit where it crosses
    if BAR[0] <= fx <= BAR[1] and TOP <= y <= BOT:
        return LINE
    if shard_outline(fx, y) < LINE_W + 1:
        return LINE
    if in_shard(fx, y) and fx > OUTER + 16 and fx < BAR[0] - 10 and (i + j) % 2 == 0:
        # dithered glass, brighter towards the inner bar and the shoulders' middle
        k = (fx - OUTER) / (BAR[0] - OUTER)
        return tuple(int(lo + (hi - lo) * (0.35 + 0.65 * k)) for lo, hi in zip(FILL_LO, FILL_HI))
    return None


def write_png(path, rows):
    raw = b''.join(b'\x00' + bytes(sum(([*c, 255] if c else [0, 0, 0, 0] for c in row), [])) for row in rows)
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', N, N, 8, 6, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(png)


write_png(OUT, [[pixel(i, j) for i in range(N)] for j in range(N)])
print(os.path.normpath(OUT), '%dx%d' % (N, N))
