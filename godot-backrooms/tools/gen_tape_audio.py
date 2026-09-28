"""Synthesizes the hazard tape's sounds (tape_tool.gd) into godot-backrooms/audio/:
  tape_grain_0..3.wav  a short burst of adhesive crackle, played every few cm of tape pulled off
                       the roll, so the sound follows how fast you pull
  tape_stick.wav       the end pressed down onto the wall
  tape_rip.wav         the strip torn off the roll
Pure standard library. Run from anywhere: python tools/gen_tape_audio.py
"""
import math, os, random, struct, wave

SR = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'audio')
random.seed(75)


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


def crackle(n, density, decay_ms=0.6):
    """Sparse clicks: each a tiny decaying noise tick. `density(i)` = clicks per second at sample i."""
    out = [0.0] * n
    k = math.exp(-1000.0 / (decay_ms * SR))
    i = 0
    while i < n:
        rate = max(density(i), 1.0)
        i += max(1, int(random.expovariate(rate) * SR))
        if i >= n:
            break
        amp = random.uniform(0.3, 1.0) * random.choice((-1, 1))
        e = 1.0
        for j in range(i, min(n, i + int(SR * decay_ms * 0.006))):
            out[j] += amp * e * random.uniform(0.6, 1.0)
            amp = -amp * 0.8
            e *= k
    return out


def envelope(n, attack, release):
    a = max(1, int(attack * SR))
    r = max(1, int(release * SR))
    return [min(1.0, i / a) * min(1.0, (n - i) / r) for i in range(n)]


def normalize(xs, peak):
    m = max(abs(x) for x in xs) or 1.0
    return [x * peak / m for x in xs]


def write(name, xs):
    path = os.path.join(OUT, name)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<h', int(max(-1.0, min(1.0, x)) * 32767)) for x in xs))
    print('wrote', os.path.normpath(path), '%.2fs' % (len(xs) / SR))


def grain(seed):
    random.seed(seed)
    n = int(SR * random.uniform(0.07, 0.095))
    c = crackle(n, lambda i: 900 + 700 * math.sin(math.pi * i / n))
    hiss = [random.uniform(-1, 1) * 0.12 for _ in range(n)]
    x = one_pole_hp([a + b for a, b in zip(c, hiss)], 1400)
    x = one_pole_lp(x, 7000)
    env = envelope(n, 0.006, 0.03)
    return normalize([a * e for a, e in zip(x, env)], 0.55)


def stick():
    n = int(SR * 0.14)
    thump = [math.sin(2 * math.pi * 110 * i / SR) * math.exp(-i / (SR * 0.025)) for i in range(n)]
    pat = one_pole_lp([random.uniform(-1, 1) * math.exp(-i / (SR * 0.012)) for i in range(n)], 1800)
    c = one_pole_hp(crackle(n, lambda i: 400 * math.exp(-i / (SR * 0.04))), 1500)
    x = [0.6 * a + 0.9 * b + 0.25 * d for a, b, d in zip(thump, pat, c)]
    return normalize([a * e for a, e in zip(x, envelope(n, 0.002, 0.05))], 0.6)


def rip():
    n = int(SR * 0.32)
    # the tear races across the width: dense, bright crackle that swells then snaps off
    dens = lambda i: 2500 + 9000 * math.sin(math.pi * min(1.0, i / (n * 0.85))) ** 0.6
    c = crackle(n, dens, 0.4)
    tear = one_pole_hp([random.uniform(-1, 1) for _ in range(n)], 2500)
    shape = [math.sin(math.pi * min(1.0, i / (n * 0.85))) ** 1.5 for i in range(n)]
    x = [0.8 * a + 0.35 * b * s for a, b, s in zip(c, tear, shape)]
    x = one_pole_hp(x, 900)
    x = one_pole_lp(x, 8000)
    # a last snap as it parts
    snap_at = int(n * 0.84)
    for j in range(snap_at, min(n, snap_at + 220)):
        x[j] += random.uniform(-1, 1) * 1.6 * math.exp(-(j - snap_at) / 40.0)
    return normalize([a * e for a, e in zip(x, envelope(n, 0.01, 0.04))], 0.75)


if __name__ == '__main__':
    for k in range(4):
        write('tape_grain_%d.wav' % k, grain(100 + k))
    write('tape_stick.wav', stick())
    write('tape_rip.wav', rip())
