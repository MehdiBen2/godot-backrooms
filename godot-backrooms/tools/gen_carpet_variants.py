"""Makes more carpet footstep takes from the recorded ones, so a long corridor walk repeats less:
  audio/footsteps/carpet/carpet_walk_5..12.wav    from carpet_walk_1..4.wav
  audio/footsteps/carpet/carpet_sprint_5..12.wav  from carpet_sprint_1..4.wav
Each new take is the heel of one recorded take crossfaded into the scuff of another from the same set, with a
gentle shelf (darker or brighter by a couple of dB) and its tail let go a little sooner or later. The game adds
its own pitch / level wobble and lays a second take under each step (scripts/Player/footsteps.gd), so nothing
here re-pitches. Peaks at the originals' level (-0.9 dBFS). Same format: 44.1 kHz mono 16-bit.
Pure standard library. Run from anywhere: python tools/gen_carpet_variants.py
"""
import math, os, random, struct, wave

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'audio', 'footsteps', 'carpet')
SR = 44100
PEAK = 10 ** (-0.915 / 20)
NEW = range(5, 13)
random.seed(4401)


def read(name):
    with wave.open(os.path.join(DIR, name), 'rb') as w:
        n = w.getnframes()
        data = struct.unpack('<%dh' % n, w.readframes(n))
    return [x / 32768.0 for x in data]


def write(name, xs):
    with wave.open(os.path.join(DIR, name), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<h', int(max(-1.0, min(1.0, x)) * 32767)) for x in xs))
    print(name, '%.3f s' % (len(xs) / SR))


def shelf(xs, f, gain_db, high):
    """RBJ low / high shelf, slope 1"""
    a = 10 ** (gain_db / 40)
    w0 = 2 * math.pi * f / SR
    cw, sw = math.cos(w0), math.sin(w0)
    al = sw / 2 * math.sqrt(2)
    k = 2 * math.sqrt(a) * al
    if high:
        b = (a * ((a + 1) + (a - 1) * cw + k), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - k))
        d = ((a + 1) - (a - 1) * cw + k, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - k)
    else:
        b = (a * ((a + 1) - (a - 1) * cw + k), 2 * a * ((a - 1) - (a + 1) * cw), a * ((a + 1) - (a - 1) * cw - k))
        d = ((a + 1) + (a - 1) * cw + k, -2 * ((a - 1) + (a + 1) * cw), (a + 1) + (a - 1) * cw - k)
    b0, b1, b2 = (x / d[0] for x in b)
    a1, a2 = d[1] / d[0], d[2] / d[0]
    out, x1, x2, y1, y2 = [], 0.0, 0.0, 0.0, 0.0
    for x in xs:
        y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, x, y1, y
        out.append(y)
    return out


def peak_at(xs):
    return max(range(len(xs)), key=lambda i: abs(xs[i]))


def splice(heel, scuff):
    """heel's first 30 ms after its peak, crossfaded over 15 ms into scuff from the same point after its peak"""
    ph, ps = peak_at(heel), peak_at(scuff)
    cut, fade = int(0.030 * SR), int(0.015 * SR)
    out = heel[:ph + cut]
    tail = scuff[ps + cut - fade:]
    if len(tail) < fade:
        return heel[:]
    lh = abs(heel[ph]) or 1.0
    ls = abs(scuff[ps]) or 1.0
    tail = [x * lh / ls for x in tail]          # scuff at the heel's level, so the join doesn't jump
    for i in range(fade):
        t = i / fade
        if len(out) - fade + i < len(out):
            out[len(out) - fade + i] = out[len(out) - fade + i] * math.cos(t * math.pi / 2) + tail[i] * math.sin(t * math.pi / 2)
    return out + tail[fade:]


def brightness(xs):
    """share of the energy above ~1 kHz: a cheap stand-in for the spectral centroid"""
    hi = shelf(xs, 1000, -40.0, False)          # a low shelf 40 dB down: what is left is the top
    return sum(x * x for x in hi) / (sum(x * x for x in xs) or 1.0)


def weight(xs):
    """share of the energy below ~200 Hz: the heel's boom"""
    lo = shelf(xs, 200, -40.0, True)
    return sum(x * x for x in lo) / (sum(x * x for x in xs) or 1.0)


SHELVES = [(260, -3.0, False), (260, -2.0, False), (260, 2.0, False),      # less / more heel weight
           (3200, -3.0, True), (3200, -2.0, True), (3200, 1.5, True)]      # duller / crisper fibre


def variant(takes, a, b, span, heavy):
    """span: (darkest, brightest) of the recorded takes; the shelf is the first, in random order, that keeps
    the new take inside it, so no variant is duller or brighter than any recording"""
    xs = splice(takes[a], takes[b])
    options = SHELVES[:]
    random.shuffle(options)
    for f, g, high in options:
        ys = shelf(xs, f, g, high)
        if span[0] <= brightness(ys) <= span[1] and heavy[0] <= weight(ys) <= heavy[1]:
            break
    else:
        return None                     # this pair can't be brought into the recordings' range
    keep = random.uniform(0.85, 1.0)                                    # let the tail go a little sooner
    n = int(len(ys) * keep)
    ys = ys[:n]
    fade = int(0.02 * SR)
    for i in range(fade):
        ys[n - fade + i] *= (1 - i / fade) ** 2
    top = max(abs(x) for x in ys) or 1.0
    return [x / top * PEAK for x in ys]


if __name__ == '__main__':
    for kind in ('walk', 'sprint'):
        takes = [read('carpet_%s_%d.wav' % (kind, i)) for i in range(1, 5)]
        lit = [brightness(t) for t in takes]
        span = (min(lit), max(lit))
        lows = [weight(t) for t in takes]
        heavy = (min(lows), max(lows))
        pairs = [(a, b) for a in range(4) for b in range(4) if a != b]   # 12 heel / scuff pairs: the first 8 that fit, none twice
        random.shuffle(pairs)
        made = []
        for a, b in pairs:
            xs = variant(takes, a, b, span, heavy)
            if xs is not None:
                made.append(xs)
            if len(made) == len(NEW):
                break
        for k, xs in zip(NEW, made):
            write('carpet_%s_%d.wav' % (kind, k), xs)
