"""Renders the web game's synthesized sounds (js/audio/*.js) to WAV files for Godot.
Filters are RBJ biquads, matching WebAudio's BiquadFilterNode, so tone and levels carry over.
"""
import math, random, struct, wave, os, sys
OUT = 'C:/Users/alhyu/Documents/backrooms/audio/'
SR = 22050
SCALES = {}
random.seed(1971)

# ------------------------------------------------------------------ DSP helpers
class Biquad:
    def __init__(self, kind, f, q=1.0, gain_db=0.0):
        w0 = 2 * math.pi * min(f, SR * 0.49) / SR
        cw, sw = math.cos(w0), math.sin(w0)
        A = 10 ** (gain_db / 40)
        if kind == 'lowpass':
            qq = 10 ** (q / 20)
            al = sw / (2 * qq)
            b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
            a0, a1, a2 = 1 + al, -2 * cw, 1 - al
        elif kind == 'highpass':
            qq = 10 ** (q / 20)
            al = sw / (2 * qq)
            b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
            a0, a1, a2 = 1 + al, -2 * cw, 1 - al
        elif kind == 'bandpass':
            al = sw / (2 * q)
            b0, b1, b2 = al, 0.0, -al
            a0, a1, a2 = 1 + al, -2 * cw, 1 - al
        elif kind == 'peaking':
            al = sw / (2 * q)
            b0, b1, b2 = 1 + al * A, -2 * cw, 1 - al * A
            a0, a1, a2 = 1 + al / A, -2 * cw, 1 - al / A
        else:
            raise ValueError(kind)
        self.b0, self.b1, self.b2 = b0 / a0, b1 / a0, b2 / a0
        self.a1, self.a2 = a1 / a0, a2 / a0
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def run(self, xs):
        b0, b1, b2, a1, a2 = self.b0, self.b1, self.b2, self.a1, self.a2
        x1, x2, y1, y2 = self.x1, self.x2, self.y1, self.y2
        out = []
        ap = out.append
        for x in xs:
            y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1 = x1, x
            y2, y1 = y1, y
            ap(y)
        self.x1, self.x2, self.y1, self.y2 = x1, x2, y1, y2
        return out

def noise(n):
    return [random.random() * 2 - 1 for _ in range(n)]

def write(name, xs, gain=1.0, loop_fade=0):
    if loop_fade:
        n = len(xs)
        f = loop_fade
        xs = list(xs)
        # equal-power crossfade of the tail into the head so the loop seam is inaudible
        for i in range(f):
            t = i / f
            a = math.cos(t * math.pi / 2)
            b = math.sin(t * math.pi / 2)
            xs[i] = xs[i] * b + xs[n - f + i] * a
        xs = xs[:n - f]
    pk = max(abs(x) for x in xs) * gain
    if pk > 0.999:
        gain *= 0.999 / pk
        print('  (limited %s by %.4f)' % (name, 0.999 / pk))
    SCALES[name] = gain      # linear factor applied on top of the web-level signal; Godot divides it back out
    with wave.open(OUT + name, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<h', int(max(-1, min(1, x * gain)) * 32767)) for x in xs))
    print(name, len(xs) / SR, 's')

# ------------------------------------------------------------------ fluorescent hum (hum.js)
def hum():
    T = 20
    n = SR * T
    # Ballast wave: 60 Hz series, even harmonics strong, soft 2.6 kHz lump (normalised like WebAudio)
    N = 80
    table_len = 4096
    rnd = random.Random(3)
    amps = []
    for k in range(1, N):
        even = k % 2 == 0
        a = (1.0 if even else 0.16) / (k ** 0.95)
        a *= 1 + 0.5 * math.exp(-(((k * 60 - 2600) / 900) ** 2))
        ph = 0.0 if even else rnd.random() * 2 * math.pi
        amps.append((k, a, ph))
    table = [sum(a * math.sin(2 * math.pi * k * i / table_len + ph) for k, a, ph in amps) for i in range(table_len)]
    pk = max(abs(x) for x in table)
    table = [x / pk for x in table]
    tone = []
    phase = 0.0
    for i in range(n):
        t = i / SR
        f = 60 + 0.18 * math.sin(2 * math.pi * 0.05 * t)       # slow drift (0.05 Hz so 20 s loops)
        phase += f / SR
        p = (phase % 1.0) * table_len
        i0 = int(p)
        fr = p - i0
        tone.append(table[i0] * (1 - fr) + table[(i0 + 1) % table_len] * fr)
    # Arc sizzle: high-passed noise gated at 120 Hz
    sizz = Biquad('highpass', 3200, 0.7).run(noise(n))
    bus = []
    for i in range(n):
        t = i / SR
        gate = 0.5 + 0.5 * math.sin(2 * math.pi * 120 * t)
        v = tone[i] * 0.85 + sizz[i] * gate * 0.06
        v *= 1 + 0.08 * math.sin(2 * math.pi * 0.2 * t)          # slow wobble
        bus.append(v)
    # Housing resonance then a darker top end
    out = Biquad('lowpass', 3800, 0.6).run(Biquad('peaking', 2350, 1.4, 1.5).run(bus))
    write('hum_voice.wav', out, 1.0, loop_fade=SR // 4)
    # Diffuse room tone (the sea of distant fixtures): lowpass 480 x0.05 + 120 Hz mains x0.012.
    # Stored 10x hotter (level restored in Godot) so 16-bit quantisation stays clean.
    diff = Biquad('lowpass', 480, 0.5).run(out)
    mix = [d * 0.05 + 0.012 * math.sin(2 * math.pi * 120 * i / SR) for i, d in enumerate(diff)]
    write('hum_diffuse.wav', mix, 10.0, loop_fade=SR // 4)

# dread drone: 38 Hz through a lowpass at 80 Hz, always on (fear swells it)
def drone():
    n = SR * 2
    xs = [math.sin(2 * math.pi * 38 * i / SR) for i in range(n)]
    write('drone.wav', xs, 1.0)

# ------------------------------------------------------------------ breathing (breathing.js _phase)
def lerp(a, b, m):
    return a + (b - a) * m

def envelope(dur, inhale, peak, shake, n_out):
    a, b = (0.7, 0.3) if inhale else (0.2, 1.1)
    norm = (a / (a + b)) ** a * (b / (a + b)) ** b
    trem_hz = 7.4
    ph = 1.3
    out = []
    for i in range(n_out):
        x = i / max(1, n_out - 1)
        v = (x ** a) * ((1 - x) ** b) / norm
        if shake > 0:
            v *= 1 + shake * 0.6 * math.sin(2 * math.pi * trem_hz * dur * x + ph)
        out.append(max(0.0, v * peak))
    out[-1] = 0.0
    return out

def breath(name, dur, inhale, mouth, shake, voiced=0.0):
    n = int((dur + 0.05) * SR)
    src = noise(n)
    f1 = Biquad('bandpass', lerp(1100, 1500, mouth) if inhale else lerp(620, 800, mouth), 1.1)
    f2 = Biquad('bandpass', lerp(2600, 3100, mouth) if inhale else lerp(1300, 1700, mouth), 1.8)
    hs = Biquad('highpass', 3500 if inhale else 4200, 0.7)
    a = f1.run(src)
    if voiced > 0 and not inhale:
        pitch = 112.0
        ph = 0.0
        g = []
        for i in range(n):
            f = pitch * (1 - 0.18 * min(1, i / (dur * SR)))
            ph += f / SR
            g.append((2 * abs(2 * (ph % 1) - 1) - 1) * 0.035 * voiced)   # triangle
        a = Biquad('bandpass', lerp(620, 800, mouth), 1.1).run([s + gg for s, gg in zip(src, g)])
    b = f2.run(src)
    h = hs.run(src)
    hg = (0.25 if inhale else 0.12) * mouth
    mixed = [x + y * 0.55 + z * hg for x, y, z in zip(a, b, h)]
    tone = Biquad('lowpass', lerp(1500, 6000 if inhale else 4500, mouth), 0.5).run(mixed)
    env = envelope(dur, inhale, 0.2, shake, len(tone))
    xs = [t * e for t, e in zip(tone, env)]
    write(name, xs, 8.0)     # stored 8x hotter; Godot plays them at amp / 8

BREATH_DURS = [0.22, 0.34, 0.5, 0.7, 0.9, 1.3, 1.6]
BREATH_MOUTH = [0.0, 0.6, 1.0]
def breaths():
    for di, d in enumerate(BREATH_DURS):
        for mi, m in enumerate(BREATH_MOUTH):
            for si, sh in enumerate([0.0, 0.4]):
                breath('breath_in_%d_%d_%d.wav' % (mi, di, si), d, True, m, sh)
                breath('breath_out_%d_%d_%d.wav' % (mi, di, si), d, False, m, sh)
        breath('breath_outv_%d.wav' % di, d, False, 1.0, 0.0, 1.0)

# ------------------------------------------------------------------ one-shots (sfx.js)
def exp_ramp(a, b, t):
    return a * (b / a) ** t

def click(name, f0, f1, dur, gain, kind='triangle'):
    n = int(dur * SR)
    xs = []
    ph = 0.0
    for i in range(n):
        t = i / n
        f = exp_ramp(f0, f1, t)
        ph += f / SR
        x = math.sin(2 * math.pi * ph) if kind == 'sine' else (2 * abs(2 * (ph % 1) - 1) - 1)
        if kind == 'square':
            x = 1.0 if (ph % 1) < 0.5 else -1.0
        xs.append(x * exp_ramp(gain, 0.001, t))
    write(name, xs, 1.0)

def noise_burst(name, dur, kind, freq, q, vol, decay=0.3):
    n = int(dur * SR * 3)
    src = Biquad(kind, freq, q).run(noise(n))
    tc = dur * decay
    xs = [s * vol * math.exp(-(i / SR) / tc) for i, s in enumerate(src)]
    write(name, xs, 1.0)

def sfx():
    click('flash_click_on.wav', 1600, 120, 0.04, 0.18)
    click('flash_click_off.wav', 1100, 120, 0.04, 0.18)
    click('battery_dead_click.wav', 340, 70, 0.04, 0.14)
    # battery dying: saw sweep 480->50 through a falling lowpass, plus a noise burst
    n = int(0.45 * SR)
    ph = 0.0
    xs = []
    lp_f = []
    for i in range(n):
        t = i / (0.4 * SR)
        f = exp_ramp(480, 50, min(1, t))
        ph += f / SR
        xs.append((2 * (ph % 1) - 1) * exp_ramp(0.22, 0.001, min(1, i / (0.42 * SR))))
    xs = Biquad('lowpass', 500, 2.5).run(xs)
    nb = Biquad('bandpass', 800, 2).run(noise(n))
    xs = [x + b * 0.18 * math.exp(-(i / SR) / 0.05) for i, (x, b) in enumerate(zip(xs, nb))]
    write('battery_dead.wav', xs, 1.0)
    noise_burst('tube_drop.wav', 0.05, 'bandpass', 1300, 2.0, 0.2, 0.3)
    noise_burst('tube_restrike.wav', 0.03, 'bandpass', 3400, 2.5, 0.12, 0.25)
    # jump: clothing rustle (bandpass sweeping 700->1500), on the body bus
    n = int(0.18 * SR)
    src = noise(n)
    xs = []
    f = Biquad('bandpass', 700, 0.8)
    for i in range(n):
        t = i / (0.15 * SR)
        g = (0.0001 + 0.0699 * min(1, i / (0.03 * SR))) if i < 0.03 * SR else exp_ramp(0.07, 0.001, min(1, (i - 0.03 * SR) / (0.13 * SR)))
        xs.append(src[i] * g)
    xs = Biquad('bandpass', 1000, 0.8).run(xs)
    write('jump.wav', xs, 6.0)
    # landing thud: 90 -> 38 Hz over 0.14 s
    n = int(0.22 * SR)
    ph = 0.0
    xs = []
    for i in range(n):
        f = exp_ramp(90, 38, min(1, i / (0.14 * SR)))
        ph += f / SR
        xs.append(math.sin(2 * math.pi * ph) * exp_ramp(0.22, 0.001, min(1, i / (0.2 * SR))))
    write('land_thud.wav', xs, 1.0)

if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    what = sys.argv[1:] or ['hum', 'drone', 'sfx', 'breaths']
    if 'hum' in what: hum()
    if 'drone' in what: drone()
    if 'sfx' in what: sfx()
    if 'breaths' in what: breaths()
    import json
    path = OUT + 'scales.json'
    old = json.load(open(path)) if os.path.exists(path) else {}
    old.update(SCALES)
    json.dump(old, open(path, 'w'), indent=0)
