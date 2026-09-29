"""Synthesizes the camera flash's sounds (flash_tool.gd) into godot-backrooms/audio/:
  flash_fire.wav    the tube going off: a hard electric crack over a dull thump from the reflector
  flash_charge.wav  the capacitor charging back up after it: the thin rising whine of an old flash
                    unit, ending on the click of the ready lamp
Pure standard library. Run from anywhere: python tools/gen_flash_audio.py
"""
import math, os, random, struct, wave

SR = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'audio')
random.seed(41)


def one_pole_lp(xs, hz):
    a = math.exp(-2 * math.pi * hz / SR)
    y = 0.0
    out = []
    for x in xs:
        y = (1 - a) * x + a * y
        out.append(y)
    return out


def one_pole_hp(xs, hz):
    lp = one_pole_lp(xs, hz)
    return [x - l for x, l in zip(xs, lp)]


def normalize(xs, peak):
    m = max(abs(x) for x in xs) or 1.0
    return [x / m * peak for x in xs]


def write(name, xs):
    path = os.path.join(OUT, name)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<h', int(max(-1.0, min(1.0, x)) * 32767)) for x in xs))
    print('wrote', path, '%.2f s' % (len(xs) / SR))


def fire():
    n = int(0.42 * SR)
    # the crack: white noise, all edge, gone in a few ms, with a second smaller arc just after
    crack = [0.0] * n
    for i in range(n):
        t = i / SR
        env = math.exp(-t / 0.006) + 0.35 * math.exp(-max(0.0, t - 0.011) / 0.01) * (t > 0.011)
        crack[i] = random.uniform(-1, 1) * env
    crack = one_pole_hp(crack, 1800)
    # the reflector and the body of the unit: a short low thump
    thump = [math.sin(2 * math.pi * (95 - 40 * min(1.0, i / SR / 0.08)) * i / SR) * math.exp(-i / SR / 0.05) for i in range(n)]
    # a faint ringing tail from the tube
    ring = [math.sin(2 * math.pi * 3150 * i / SR) * 0.12 * math.exp(-i / SR / 0.09) for i in range(n)]
    tail = one_pole_lp([random.uniform(-1, 1) * 0.18 * math.exp(-i / SR / 0.12) for i in range(n)], 2500)
    xs = [c + 0.8 * th + r + tl for c, th, r, tl in zip(crack, thump, ring, tail)]
    fade = int(0.02 * SR)
    for i in range(fade):
        xs[n - 1 - i] *= i / fade
    return normalize(xs, 0.92)


def charge():
    dur = 1.7
    n = int(dur * SR)
    xs = [0.0] * n
    ph = 0.0
    for i in range(n):
        t = i / SR
        k = t / dur
        f = 900 + 6400 * (k ** 0.7)                       # the whine climbs, fast then slower
        ph += 2 * math.pi * f / SR
        env = min(1.0, t / 0.08) * (0.55 + 0.45 * k) * (1.0 if t < dur - 0.2 else max(0.0, (dur - t) / 0.2))
        wob = 1.0 + 0.08 * math.sin(2 * math.pi * 31 * t)  # the transformer's buzz under it
        xs[i] = (math.sin(ph) + 0.25 * math.sin(2 * ph)) * env * wob * 0.35
    # the ready lamp: a small relay tick at the end
    at = int((dur - 0.12) * SR)
    for i in range(int(0.03 * SR)):
        if at + i < n:
            xs[at + i] += random.uniform(-1, 1) * math.exp(-i / SR / 0.003) * 0.6
    xs = one_pole_hp(xs, 400)
    return normalize(xs, 0.5)


if __name__ == '__main__':
    write('flash_fire.wav', fire())
    write('flash_charge.wav', charge())
