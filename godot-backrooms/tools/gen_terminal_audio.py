"""Synthesizes the A.S.R.A. field terminal's UI sounds (scripts/UI/inventory/inventory.gd) into
audio/terminal/. Standard library only; re-run from anywhere after tweaking:

    python tools/gen_terminal_audio.py

  terminal_on.wav      CRT power-on: relay click, low thump, degauss buzz, static, flyback whine
  terminal_off.wav     power-off: the picture collapsing, a falling zap into static
  terminal_tab.wav     page switch: relay tick, rising two-tone BIOS chirp, a burst of data chatter
  terminal_select.wav  item cursor: a single short blip
  terminal_scan.wav    field scanner ping, repeated faster (and pitched up) as a reading completes
  terminal_logged.wav  new entry logged: three rising blips over a soft chord (the HUD toast)
Every file is peak-normalized to 0.8 (the level of audio/ui_click.wav); loudness is set per sound
by volume_db in inventory.gd.
"""
import math, os, random, struct, wave

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'audio', 'terminal')
random.seed(884)


class Biquad:
    """RBJ biquad, as in tools/gen_audio.py (only the kinds used here)."""
    def __init__(self, kind, f, q=0.707):
        w0 = 2 * math.pi * min(f, SR * 0.49) / SR
        cw, sw = math.cos(w0), math.sin(w0)
        al = sw / (2 * q)
        if kind == 'lowpass':
            b = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
        elif kind == 'highpass':
            b = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
        elif kind == 'bandpass':
            b = (al, 0.0, -al)
        else:
            raise ValueError(kind)
        a0 = 1 + al
        self.b = [x / a0 for x in b]
        self.a1, self.a2 = -2 * cw / a0, (1 - al) / a0

    def run(self, xs):
        b0, b1, b2 = self.b
        a1, a2 = self.a1, self.a2
        x1 = x2 = y1 = y2 = 0.0
        out = []
        for x in xs:
            y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1, y2, y1 = x1, x, y1, y
            out.append(y)
        return out


def silence(dur):
    return [0.0] * int(dur * SR)


def mix(dst, src, at=0.0, gain=1.0):
    i0 = int(at * SR)
    if len(dst) < i0 + len(src):
        dst.extend([0.0] * (i0 + len(src) - len(dst)))
    for i, x in enumerate(src):
        dst[i0 + i] += x * gain
    return dst


def env(n, attack, decay):
    """attack in seconds, then an exponential decay with time constant `decay` seconds"""
    a = max(1, int(attack * SR))
    return [(i / a) if i < a else math.exp(-(i - a) / (decay * SR)) for i in range(n)]


def tone(dur, f0, f1=None, shape='sine', attack=0.002, decay=0.05):
    """A pitch glide f0 -> f1 (exponential) with a fast attack and exponential decay."""
    n = int(dur * SR)
    f1 = f0 if f1 is None else f1
    e = env(n, attack, decay)
    out, ph = [], 0.0
    for i in range(n):
        f = f0 * (f1 / f0) ** (i / max(1, n - 1))
        ph += 2 * math.pi * f / SR
        if shape == 'sine':
            s = math.sin(ph)
        elif shape == 'square':    # band-limited-ish: first three odd harmonics
            s = math.sin(ph) + math.sin(3 * ph) / 3 + math.sin(5 * ph) / 5
        else:                      # triangle
            s = (2 / math.pi) * math.asin(math.sin(ph))
        out.append(s * e[i])
    return out


def noise(dur):
    return [random.random() * 2 - 1 for _ in range(int(dur * SR))]


def tick(dur=0.004, f=3500, q=1.2):
    """Relay / switch contact: a band-passed noise transient"""
    xs = noise(dur + 0.01)
    e = env(len(xs), 0.0003, dur / 3)
    return Biquad('bandpass', f, q).run([x * g for x, g in zip(xs, e)])


def crackle(dur, rate0, rate1, f=3000):
    """Static: sparse impulses whose density glides rate0 -> rate1 per second, band-passed"""
    n = int(dur * SR)
    xs = [0.0] * n
    for i in range(n):
        rate = rate0 + (rate1 - rate0) * i / n
        if random.random() < rate / SR:
            xs[i] = random.choice((-1, 1)) * random.uniform(0.4, 1.0)
    return Biquad('bandpass', f, 0.8).run(xs)


def buzz(dur, f, attack, decay):
    """Mains-hum degauss 'bwoom': a fundamental with a few harmonics, slightly saturated"""
    n = int(dur * SR)
    e = env(n, attack, decay)
    out = []
    for i in range(n):
        ph = 2 * math.pi * f * i / SR
        s = math.sin(ph) + 0.6 * math.sin(2 * ph) + 0.35 * math.sin(3 * ph) + 0.2 * math.sin(5 * ph)
        out.append(math.tanh(1.6 * s) * e[i])
    return out


def write(name, xs, peak=0.8, fade_out=0.01):
    f = int(fade_out * SR)
    for i in range(f):
        xs[len(xs) - f + i] *= 1 - i / f
    m = max(abs(x) for x in xs) or 1.0
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, name), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<h', int(x / m * peak * 32767)) for x in xs))
    print(name, '%.2fs' % (len(xs) / SR))


def terminal_on():
    out = silence(0.75)
    mix(out, tick(0.004, 2800), 0.0, 0.9)                                    # power switch
    mix(out, tone(0.25, 90, 42, 'sine', 0.004, 0.07), 0.01, 0.9)             # tube thump
    mix(out, Biquad('lowpass', 900).run(buzz(0.6, 60, 0.03, 0.16)), 0.02, 0.32)  # degauss
    mix(out, crackle(0.45, 900, 60, 3200), 0.015, 0.5)                       # static settling
    whine = tone(0.62, 11800, 11750, 'sine', 0.06, 0.1)                      # flyback, very faint
    mix(out, whine, 0.05, 0.03)
    return out


def terminal_off():
    out = silence(0.4)
    mix(out, tick(0.003, 2400), 0.0, 0.8)
    mix(out, tone(0.2, 1400, 70, 'sine', 0.002, 0.07), 0.004, 0.55)          # picture collapsing
    mix(out, tone(0.12, 70, 40, 'sine', 0.002, 0.04), 0.02, 0.5)
    mix(out, crackle(0.3, 500, 20, 2600), 0.03, 0.35)
    return out


def terminal_tab():
    out = silence(0.2)
    mix(out, tick(0.003, 4200, 1.5), 0.0, 0.7)
    lp = Biquad('lowpass', 5200)
    mix(out, lp.run(tone(0.038, 1560, None, 'square', 0.002, 0.03)), 0.006, 0.34)
    mix(out, Biquad('lowpass', 5200).run(tone(0.05, 2090, None, 'square', 0.002, 0.03)), 0.044, 0.34)
    # data chatter: band-passed noise gated in random 4-9 ms bursts
    chat = noise(0.12)
    gate, g, left = [], 0.0, 0
    for _ in chat:
        if left <= 0:
            g = random.choice((0.0, 0.0, 1.0, 0.7))
            left = int(random.uniform(0.004, 0.009) * SR)
        left -= 1
        gate.append(g)
    e = env(len(chat), 0.005, 0.05)
    chat = Biquad('bandpass', 2600, 2.5).run([x * a * b for x, a, b in zip(chat, gate, e)])
    mix(out, chat, 0.02, 0.5)
    return out


def terminal_select():
    out = silence(0.06)
    mix(out, tick(0.002, 5000, 1.5), 0.0, 0.4)
    mix(out, tone(0.03, 1900, 2000, 'sine', 0.001, 0.012), 0.002, 0.6)
    return out


def terminal_scan():
    out = silence(0.16)
    mix(out, tick(0.002, 6000, 1.5), 0.0, 0.25)
    mix(out, tone(0.15, 2350, 2250, 'sine', 0.002, 0.035), 0.001, 0.8)     # sonar ping
    mix(out, tone(0.15, 4700, 4500, 'sine', 0.002, 0.02), 0.001, 0.15)
    return out


def terminal_logged():
    out = silence(0.55)
    for i, f in enumerate((1320, 1760, 2640)):
        mix(out, Biquad('lowpass', 5000).run(tone(0.07, f, None, 'square', 0.002, 0.03)), i * 0.075, 0.3)
    for f in (1320, 1760, 2640):                                             # the chord it settles on
        mix(out, tone(0.33, f, None, 'sine', 0.01, 0.12), 0.225, 0.18)
    return out


if __name__ == '__main__':
    write('terminal_on.wav', terminal_on(), fade_out=0.05)
    write('terminal_off.wav', terminal_off(), fade_out=0.04)
    write('terminal_tab.wav', terminal_tab())
    write('terminal_select.wav', terminal_select(), fade_out=0.005)
    write('terminal_scan.wav', terminal_scan(), fade_out=0.02)
    write('terminal_logged.wav', terminal_logged(), fade_out=0.06)
