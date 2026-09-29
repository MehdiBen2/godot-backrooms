"""Draws the HUD's extra vitals icons into godot-backrooms/textures/ui/, in the same style as the
terminal's (terminal_battery / stamina / sanity / time.png): white on transparent, used as alpha
masks and tinted in game, drawn on a coarse 64 px grid without anti-aliasing and doubled to 128 so
the pixels stay chunky, like the VCR font.
  terminal_noise.png   a head in profile, talking, three sound waves off the mouth (NOISE: how far
                       your sound carries, vitals_panel.gd), traced off the reference art
  terminal_health.png  a heart with a pulse line cut through it (HEALTH)
Needs Pillow. Run from anywhere: python tools/generate_hud_icons.py
"""
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'textures', 'ui')
G = 64              # drawing grid
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)


def canvas():
    im = Image.new('RGBA', (G, G), CLEAR)
    return im, ImageDraw.Draw(im)


def save(im, name):
    bbox = im.getbbox()
    im = im.crop((max(0, bbox[0] - 1), max(0, bbox[1] - 1), min(G, bbox[2] + 1), min(G, bbox[3] + 1)))
    im = im.resize((im.width * 2, im.height * 2), Image.NEAREST)
    path = os.path.join(OUT, name)
    im.save(path)
    print('wrote', path, im.size)


def noise():
    # Traced off the reference art at its own scale (about 650 x 540), smooth, then cut down to the
    # pixel grid with a hard threshold so the edges step like the other icons'.
    k = 4                                   # supersample the tracing
    im = Image.new('L', (650 * k, 540 * k), 0)
    d = ImageDraw.Draw(im)
    head = [
        (270, 497), (268, 442), (300, 427), (333, 402), (349, 374),      # neck front, jaw, chin
        (346, 348), (352, 333), (331, 319), (351, 306), (359, 293),      # lower lip, the open mouth, upper lip
        (393, 273), (362, 226), (353, 190),                               # nose tip, bridge, brow
        (342, 128), (304, 70), (244, 40), (172, 36), (104, 60),           # forehead, crown
        (56, 110), (33, 178), (35, 248), (56, 308), (90, 368),            # back of the skull, nape
        (98, 420), (82, 470), (70, 497),                                  # the neck flaring out at the base
    ]
    d.polygon([(x * k, y * k) for x, y in head], fill=255)
    cx, cy = 330 * k, 312 * k                # the waves spread from the mouth
    for r in (135, 200, 262):
        r *= k
        d.arc((cx - r, cy - r, cx + r, cy + r), start=-44, end=44, fill=255, width=32 * k)
    im = im.crop(im.getbbox())
    w = 60                                  # the pixel grid, like the other icons' ~64
    im = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS).point(lambda v: 255 if v > 120 else 0)
    out = Image.new('RGBA', (im.width + 2, im.height + 2), CLEAR)
    out.paste(Image.new('RGBA', im.size, WHITE), (1, 1), im)
    out = out.resize((out.width * 2, out.height * 2), Image.NEAREST)
    path = os.path.join(OUT, 'terminal_noise.png')
    out.save(path)
    print('wrote', path, out.size)


def health():
    im, d = canvas()
    # a heart: two lobes and the point
    d.ellipse((6, 10, 32, 36), fill=WHITE)
    d.ellipse((30, 10, 56, 36), fill=WHITE)
    d.polygon([(7, 27), (55, 27), (31, 56)], fill=WHITE)
    # a pulse line cut through it, running out past both sides
    trace = [(2, 32), (18, 32), (23, 24), (29, 41), (35, 18), (40, 32), (60, 32)]
    d.line(trace, fill=CLEAR, width=5, joint='curve')
    d.line(trace, fill=WHITE, width=2)
    d.line([(2, 32), (6, 32)], fill=WHITE, width=2)
    d.line([(56, 32), (60, 32)], fill=WHITE, width=2)
    save(im, 'terminal_health.png')


if __name__ == '__main__':
    noise()
    health()
