"""Draws the mannequin hint pictograms (plain PSA stick figures) into godot-backrooms/textures/hints/.
Pillow only; supersampled for smooth edges. Run from the project: python tools/gen_mannequin_hints.py
"""
import math, os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'textures', 'hints')
S = 4            # supersampling
N = 640          # final size (px)
U = 4            # px per local unit; the local grid is 160 x 160 units, y up
PAPER = (232, 229, 218)
INK = (14, 13, 11)
RED = (196, 39, 31)
FEET = 22        # height of the floor line in local units


def mix(c, t):
    """ink c at strength t over the paper colour (for ghost frames)"""
    return tuple(int(PAPER[i] * (1 - t) + c[i] * t) for i in range(3))


class Pic:
    def __init__(self):
        self.im = Image.new("RGB", (N * S, N * S), PAPER)
        self.d = ImageDraw.Draw(self.im)

    def P(self, p):
        return (p[0] * U * S, (160 - p[1]) * U * S)

    def r(self, v):
        return v * U * S

    def dot(self, p, rad, c):
        x, y = self.P(p)
        k = self.r(rad)
        self.d.ellipse([x - k, y - k, x + k, y + k], fill=c)

    def cap(self, a, b, rad, c):
        """a thick stroke with round ends, the same width all along it"""
        self.d.line([self.P(a), self.P(b)], fill=c, width=max(1, int(2 * self.r(rad))))
        self.dot(a, rad, c)
        self.dot(b, rad, c)

    def line(self, a, b, w, c):
        self.d.line([self.P(a), self.P(b)], fill=c, width=max(1, int(self.r(w))))

    def dash(self, a, b, w, c, on=2.6, off=2.2):
        L = math.dist(a, b)
        ux, uy = (b[0] - a[0]) / L, (b[1] - a[1]) / L
        t = 0.0
        while t < L:
            e = min(L, t + on)
            self.line((a[0] + ux * t, a[1] + uy * t), (a[0] + ux * e, a[1] + uy * e), w, c)
            t += on + off

    def poly(self, pts, c):
        self.d.polygon([self.P(p) for p in pts], fill=c)

    def arrow(self, a, b, w, c):
        self.line(a, b, w, c)
        L = math.dist(a, b)
        ux, uy = (b[0] - a[0]) / L, (b[1] - a[1]) / L
        bx, by = b[0] - ux * 4.5, b[1] - uy * 4.5
        px, py = -uy * 3.0, ux * 3.0
        self.poly([b, (bx + px, by + py), (bx - px, by - py)], c)

    def zigzag(self, pts, w, c):
        self.d.line([self.P(p) for p in pts], fill=c, width=max(1, int(self.r(w))), joint="curve")

    def save(self, name):
        os.makedirs(OUT, exist_ok=True)
        self.im.resize((N, N), Image.LANCZOS).save(os.path.join(OUT, name))
        print("wrote", name)


# ---------------------------------------------------------------- figures
# joints in local units, feet on y = 0, lifted onto the floor line by FEET
LIMBS = [("shL", "elL"), ("elL", "haL"), ("shR", "elR"), ("elR", "haR"),
         ("hipL", "knL"), ("knL", "ftL"), ("hipR", "knR"), ("knR", "ftR")]

HUMAN = dict(head=(0, 93), neck=(0, 86), hip=(0, 50), shL=(-8, 82), shR=(8, 82), elL=(-12, 68), elR=(12, 68),
             haL=(-13, 55), haR=(13, 55), hipL=(-4, 50), hipR=(4, 50), knL=(-5, 27), knR=(5, 27),
             ftL=(-6, 2), ftR=(6, 2))

# stiff and straight, narrower: the mannequin
MANN = dict(head=(0, 94), neck=(0, 86), hip=(0, 50), shL=(-6, 82), shR=(6, 82), elL=(-7, 66), elR=(7, 66),
            haL=(-8, 52), haR=(8, 52), hipL=(-4, 50), hipR=(4, 50), knL=(-4, 27), knR=(4, 27),
            ftL=(-4, 2), ftR=(4, 2))

# a figure running to the right: leaning forward, arms pumping, one leg up
RUN = dict(HUMAN, head=(8, 92), neck=(5, 82), hip=(-2, 50), shL=(4, 79), shR=(-3, 79),
           elL=(16, 70), elR=(-12, 70), haL=(24, 76), haR=(-18, 62), hipL=(-2, 50), hipR=(-1, 49),
           knL=(8, 36), knR=(-9, 34), ftL=(18, 12), ftR=(-14, 14))


def with_(base, **over):
    J = dict(base)
    J.update(over)
    return J


def figure(pic, ox, J, c=INK, r_body=3.6, r_limb=2.4, r_head=6.0):
    """head, torso and limbs: one stroke width per part, round ends, no joints drawn"""
    def T(p):
        return (ox + p[0], FEET + p[1])
    head = T(J["head"])
    pic.dot(head, r_head, c)
    pic.cap(T(J["neck"]), T(J["hip"]), r_body, c)
    for a, b in LIMBS:
        pic.cap(T(J[a]), T(J[b]), r_limb, c)
    return head


def human(pic, ox, J=HUMAN, c=INK, shut=False):
    head = figure(pic, ox, J, c)
    if shut:
        pic.line((head[0] - 4.0, head[1] + 1.2), (head[0] + 4.0, head[1] + 1.2), 1.0, RED)
    return head


def mannequin(pic, ox, J=MANN, c=INK):
    return figure(pic, ox, J, c, r_body=3.0, r_limb=2.0, r_head=5.5)


def ghost(pic, ox, t, J=MANN):
    mannequin(pic, ox, J=J, c=mix(INK, t))


# ---------------------------------------------------------------- panels
def p01_watched():
    """you watch it: it holds still, the eye-line is red"""
    pic = Pic()
    head = human(pic, 36)
    mannequin(pic, 118)
    pic.dash((head[0] + 7, head[1]), (112, FEET + 94), 0.8, RED)
    pic.save("mannequin_01_watched.png")


def p02_unseen_step():
    """you look away: it steps closer, one stop-motion frame at a time"""
    pic = Pic()
    human(pic, 26, shut=True)
    ghost(pic, 124, 0.15)
    ghost(pic, 112, 0.35)
    ghost(pic, 100, 0.6)
    mannequin(pic, 90)
    pic.arrow((124, 9), (96, 9), 1.0, RED)
    pic.save("mannequin_02_moves_unseen.png")


def p03_blink():
    """a blink is looking away: the eyes shut and it moves"""
    pic = Pic()
    human(pic, 36, shut=True)
    ghost(pic, 126, 0.25)
    mannequin(pic, 110)
    pic.arrow((126, 9), (112, 9), 1.0, RED)
    pic.save("mannequin_03_blink.png")


def p04_crowd_odd_one():
    """a crowd of still figures: one of them is not like the others"""
    pic = Pic()
    for x in (22, 48, 74, 136):
        mannequin(pic, x)
    odd = with_(MANN, head=(4, 94), elR=(20, 88), haR=(26, 100))
    mannequin(pic, 104, J=odd)
    pic.arrow((104, 150), (104, 126), 1.4, RED)
    pic.save("mannequin_04_crowd_odd_one.png")


def p05_reach():
    """keep your distance: its arm reaches further than you think"""
    pic = Pic()
    human(pic, 36)
    reach = with_(MANN, elL=(-22, 80), haL=(-36, 80))
    mannequin(pic, 118, J=reach)
    pic.arrow((50, 40), (80, 40), 1.0, RED)
    pic.arrow((80, 40), (50, 40), 1.0, RED)
    pic.save("mannequin_05_reach.png")


def p06_turned_round():
    """you turn round: it moved, and its joints creak"""
    pic = Pic()
    human(pic, 36)
    ghost(pic, 124, 0.2)
    mannequin(pic, 84)
    pic.arrow((120, 9), (92, 9), 1.0, RED)
    for jx in (80, 88):
        jy = FEET + 27
        pic.zigzag([(jx - 2.5, jy), (jx - 1, jy + 1.6), (jx + 0.5, jy - 1.4), (jx + 2.5, jy + 1.0)], 0.7, RED)
    pic.save("mannequin_06_turned_round.png")


def p07_run():
    """it is hunting you: run, and do not stop to look"""
    pic = Pic()
    ghost(pic, 16, 0.15)
    for y in (FEET + 40, FEET + 52, FEET + 64):
        pic.line((40, y), (58, y), 1.0, INK)
    figure(pic, 72, RUN)
    cx, cy = 80, FEET + 92
    for ang in (55, 80, 105):
        a = math.radians(ang)
        pic.line((cx + 9 * math.cos(a), cy + 9 * math.sin(a)), (cx + 13 * math.cos(a), cy + 13 * math.sin(a)), 1.0, RED)
    pic.save("mannequin_07_run.png")


if __name__ == "__main__":
    p01_watched()
    p02_unseen_step()
    p03_blink()
    p04_crowd_odd_one()
    p05_reach()
    p06_turned_round()
    p07_run()
