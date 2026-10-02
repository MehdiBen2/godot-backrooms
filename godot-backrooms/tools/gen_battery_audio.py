"""Synthesizes the torch's battery sounds into godot-backrooms/audio/:
  battery_swap.wav    changing the cells, start to finish, cut to the hands' TorchReload clip
                      (tools/build_player_arms.py; torch_model.gd plays the two together). In order:
                      the hand closes on the tail cap, two turns of thread unscrewing, the cap coming away,
                      the old cells rattling down the tube and landing on the carpet, cloth for the new
                      pair, each one knocking home, the cap set back on, two turns screwing down and the
                      last one seating.
  battery_pickup.wav  a pack off the floor: a hand closing on it, the two cells knocking
Small sounds made close to the ear by hands, at the level of the torch's own click (flash_click_on.wav)
and as dull: everything is shaped noise, short and damped. Nothing rings or glides, a note in here reads
as a cartoon.
Pure standard library. Run from anywhere: python tools/gen_battery_audio.py
"""
import math, os, random, struct, wave

SR = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'audio')
random.seed(77)

# when things happen in TorchReload (s); the clip's curves in build_player_arms.py are keyed on the same
ARM = ((0.10, 0.85), (5.62, 6.40))    # the right arm turning the torch level, and taking it back: its sleeve
LAND = 1.14
UNSCREW = ((1.20, 1.50), (1.84, 2.12))
CAP_OFF = 2.28
SLIDE_OUT = (2.78, 3.02)
DROPS = (3.08, 3.21)
RUSTLE = (2.90, 3.50)
PUSH = (3.87, 4.18)
CAP_ON = 4.52
SCREW = ((4.62, 4.90), (5.22, 5.50))
HANDLING = (1.00, 5.75)           # the hands are on the torch from, to
LENGTH = 6.8
PEAK = 0.15                       # flash_click_on.wav peaks at 0.17
PICKUP_PEAK = 0.11


def bandpass(xs, f, q):
    w = 2 * math.pi * min(f, SR * 0.45) / SR
    al = math.sin(w) / (2 * q)
    b0, b2, a0, a1, a2 = al, -al, 1 + al, -2 * math.cos(w), 1 - al
    x1 = x2 = y1 = y2 = 0.0
    out = []
    for x in xs:
        y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, x, y1, y
        out.append(y)
    return out


def lowpass(xs, hz):
    a = math.exp(-2 * math.pi * hz / SR)
    y = 0.0
    out = []
    for x in xs:
        y = (1 - a) * x + a * y
        out.append(y)
    return out


def highpass(xs, hz):
    return [x - l for x, l in zip(xs, lowpass(xs, hz))]


def noise(dur):
    return [random.uniform(-1, 1) for _ in range(int(dur * SR))]


def burst(decay, attack=0.0004):
    """Noise that is there at once and gone in a few `decay`s"""
    n = int(decay * 9 * SR)
    return [random.uniform(-1, 1) * math.exp(-i / SR / decay) * min(1.0, i / (attack * SR)) for i in range(n)]


def swell(n, hz):
    """An uneven 0..1 rise and fall, `hz` the rate it wanders at"""
    xs = lowpass(lowpass([random.uniform(0, 1) for _ in range(n)], hz), hz)
    low, top = min(xs), max(xs)
    return [(x - low) / ((top - low) or 1.0) for x in xs]


def tap(level, body, edge=0.0, decay=0.006):
    """Two small hard things meeting in a hand: a few ms of noise through the dull resonance of what met
    (`body` Hz), with a shorter, brighter `edge` (0..1) for the instant of contact. Held in a fist, so it's
    over at once; each one lands a little differently"""
    src = burst(decay * random.uniform(0.8, 1.25))
    out = bandpass(src, body * random.uniform(0.88, 1.14), 1.4)
    low = lowpass(src, body * 0.5)
    hi = bandpass(src, body * random.uniform(2.6, 3.4), 1.8)
    return [level * (o + 0.6 * l + edge * h * math.exp(-i / SR / (decay * 0.35)))
            for i, (o, l, h) in enumerate(zip(out, low, hi))]


def knock(level, body, edge=0.0):
    """A cell going home: it meets the contact, and chatters on it once"""
    a = tap(level, body, edge, 0.007)
    b = tap(level * random.uniform(0.25, 0.4), body * 1.15, edge * 0.5, 0.004)
    gap = int(random.uniform(0.014, 0.022) * SR)
    return [x + (b[i - gap] if 0 <= i - gap < len(b) else 0.0) for i, x in enumerate(a + [0.0] * gap)]


def thud(level):
    """Something small landing on carpet, or in a palm: no edge to it at all"""
    low = lowpass(burst(0.028, 0.002), 230)
    skin = lowpass(burst(0.007), 1100)
    return [level * (l * 2.2 + 0.25 * (skin[i] if i < len(skin) else 0.0)) for i, l in enumerate(low)]


def scrape(dur, level, hz):
    """One turn of the cap: fine dry thread dragging, in the uneven little grabs of fingers turning
    something (grains a few ms long, no two alike, never a steady buzz), over the rub of the hand on it"""
    n = int(dur * SR)
    src = noise(dur)
    grit = bandpass(src, hz, 1.1)
    rub = lowpass(highpass(src, 220), 800)
    grab = [0.0] * n
    i = 0
    while i < n:
        g = int(random.uniform(0.004, 0.012) * SR)
        a = random.uniform(0.2, 1.0) ** 1.5
        for k in range(min(g, n - i)):
            grab[i + k] = a * math.exp(-k / (g * 0.45))
        i += g + int(random.uniform(0.0, 0.005) * SR)
    grab = lowpass(grab, 350)
    return [level * (grit[i] * grab[i] + 1.4 * rub[i] * (0.35 + 0.65 * grab[i])) * math.sin(math.pi * i / n) ** 0.5
            for i in range(n)]


def rattle(dur, level, body, count):
    """Cells loose in the tube: a handful of small knocks at no particular times, over them dragging on it"""
    n = int(dur * SR)
    drag = bandpass(noise(dur), body, 0.9)
    out = [level * 0.5 * d * (i / n) * math.sin(math.pi * i / n) for i, d in enumerate(drag)]
    for _ in range(count):
        put(out, random.uniform(0.0, dur * 0.85), tap(level * random.uniform(0.35, 0.8), body * random.uniform(0.8, 1.3), 0.15, 0.004))
    return out


def cloth(dur, level, top=1500.0):
    """A hand in a pocket, or closing on something: dull cloth noise that comes and goes unevenly"""
    src = highpass(lowpass(noise(dur), top), 240)
    n = len(src)
    wave_ = swell(n, 9)
    return [level * src[i] * wave_[i] ** 2 * math.sin(math.pi * i / n) for i in range(n)]


def put(track, at, xs, gain=1.0):
    start = int(at * SR)
    for i, x in enumerate(xs):
        if 0 <= start + i < len(track):
            track[start + i] += x * gain


def finish(xs, peak):
    """Off the top (it's heard through the same ears as the torch's dull click), the rumble out, to `peak`"""
    xs = highpass(lowpass(lowpass(xs, 3400), 3400), 90)
    top = max(abs(x) for x in xs) or 1.0
    xs = [x / top * peak for x in xs]
    fade = int(0.01 * SR)
    for i in range(fade):
        xs[i] *= i / fade
        xs[-1 - i] *= i / fade
    return xs


def write(name, xs):
    with wave.open(os.path.join(OUT, name), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<h', int(max(-1.0, min(1.0, x)) * 32767)) for x in xs))
    print(name, '%.2f s' % (len(xs) / SR))


def swap():
    track = [0.0] * int(LENGTH * SR)
    # the hands on the torch the whole time: skin and sleeve, barely there, so the rest isn't cut out of silence
    put(track, HANDLING[0], cloth(HANDLING[1] - HANDLING[0], 0.07, 900.0))
    for start, end in ARM:
        put(track, start, cloth(end - start, 0.09, 1100.0))
    # the hand closing on the cap
    put(track, LAND - 0.04, cloth(0.10, 0.35))
    put(track, LAND, tap(0.22, 520))
    # unscrewing: each turn runs a little freer than the one before
    for k, (start, end) in enumerate(UNSCREW):
        put(track, start, scrape(end - start, 0.46 - 0.06 * k, 1250 + 120 * k))
        put(track, end - 0.01, tap(0.10, 700, 0.2, 0.003))          # the fingers letting go to take a new hold
    # off: the cap leaves the last thread and knocks the tube's rim
    put(track, CAP_OFF, tap(0.42, 760, 0.35))
    put(track, CAP_OFF + 0.035, tap(0.16, 980, 0.2, 0.004))
    # the old cells run out, knocking each other, and land one after the other
    put(track, SLIDE_OUT[0], rattle(SLIDE_OUT[1] - SLIDE_OUT[0], 0.34, 900, 4))
    put(track, DROPS[0], thud(0.22))
    put(track, DROPS[1], thud(0.15))
    put(track, DROPS[1] + 0.12, thud(0.05))                 # the second one rolls over
    # the new pair out of the pocket
    put(track, RUSTLE[0], cloth(RUSTLE[1] - RUSTLE[0], 0.16))
    put(track, RUSTLE[1] - 0.06, tap(0.12, 640, 0.1))       # the two knock in the fist
    # in they go: a short run down the tube, then home
    for k, at in enumerate(PUSH):
        put(track, at - 0.06, rattle(0.06, 0.16, 950, 1))
        put(track, at, knock(1.0 if k else 0.8, 560 + 60 * k, 0.4))
    # the cap back on, then down the threads: stiffer each turn
    put(track, CAP_ON, tap(0.40, 720, 0.3))
    for k, (start, end) in enumerate(SCREW):
        put(track, start, scrape(end - start, 0.42 + 0.06 * k, 1350 - 150 * k))
    put(track, SCREW[0][1] - 0.01, tap(0.10, 700, 0.2, 0.003))
    put(track, SCREW[1][1] - 0.005, tap(0.5, 600, 0.3))     # seated
    return finish(track, PEAK)


def pickup():
    track = [0.0] * int(0.34 * SR)
    put(track, 0.0, cloth(0.26, 0.7, 1400.0))
    put(track, 0.04, tap(0.6, 620, 0.2))
    put(track, 0.12, tap(0.4, 700, 0.15))
    return finish(track, PICKUP_PEAK)


if __name__ == '__main__':
    write('battery_swap.wav', swap())
    write('battery_pickup.wav', pickup())
