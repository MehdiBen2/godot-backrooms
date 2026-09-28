"""Synthesizes the T.S.R.A. field terminal's UI sounds (scripts/UI/inventory/inventory.gd) into
audio/terminal/. Standard library only; re-run from anywhere after tweaking:

    python tools/gen_terminal_audio.py

Hardware, not a game show: relays, key switches, static and a Geiger counter; nothing bleeps.
  terminal_on.wav      power-on: a heavy relay knocking shut, static swelling as the tube warms
  terminal_off.wav     power-off: the relay again, the static draining away
  terminal_tab.wav     page switch: a dry key switch, press and release
  terminal_select.wav  item / entry cursor: a lighter key tick
  terminal_scan.wav    field scanner: one Geiger-counter tick (scanner.gd fires them at random,
                       sparse at the edge of a signal, a rattle as a reading fills)
  terminal_logged.wav  new entry logged: a run of print-head strikes, then one low muted tone
Every file is peak-normalized to 0.8 (the level of audio/ui_click.wav); loudness is set per sound
by volume_db where it is played (inventory.gd SFX, scanner.gd, terminal_toast.gd).
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


def thud(dur, f0, f1, decay, lp=900):
    """A muffled knock through a housing: a short low pitch drop, low-passed"""
    return Biquad('lowpass', lp).run(tone(dur, f0, f1, 'sine', 0.001, decay))


def hiss(dur, attack, decay, lo=900, hi=5000):
    """Soft CRT static: band-limited noise with a swell"""
    xs = noise(dur)
    e = env(len(xs), attack, decay)
    return Biquad('lowpass', hi).run(Biquad('highpass', lo).run([x * g for x, g in zip(xs, e)]))


def terminal_on():
    out = silence(0.7)
    mix(out, tick(0.003, 1800, 0.9), 0.0, 0.8)                               # heavy relay closing
    mix(out, thud(0.12, 110, 70, 0.03, 700), 0.002, 0.9)                     # its knock through the case
    mix(out, tick(0.002, 2400, 1.2), 0.045, 0.35)                            # contact bounce
    mix(out, hiss(0.6, 0.12, 0.18), 0.05, 0.28)                              # static rising as it warms
    mix(out, Biquad('lowpass', 400).run(buzz(0.6, 50, 0.15, 0.2)), 0.06, 0.08)   # faint mains hum
    return out


def terminal_off():
    out = silence(0.4)
    mix(out, tick(0.003, 1600, 0.9), 0.0, 0.8)
    mix(out, thud(0.1, 95, 60, 0.025, 600), 0.002, 0.8)
    mix(out, hiss(0.3, 0.004, 0.07), 0.01, 0.25)                             # the picture draining away
    return out


def terminal_tab():
    out = silence(0.09)                                                      # a dry key switch
    mix(out, tick(0.0025, 2600, 1.1), 0.0, 0.8)                              # press
    mix(out, thud(0.03, 180, 140, 0.008, 1200), 0.0, 0.35)
    mix(out, tick(0.002, 3400, 1.3), 0.032, 0.35)                            # release
    return out


def terminal_select():
    out = silence(0.04)
    mix(out, tick(0.0015, 3800, 1.4), 0.0, 0.8)
    mix(out, thud(0.02, 240, 200, 0.005, 1500), 0.0, 0.25)
    return out


def terminal_scan():
    out = silence(0.03)                                                      # one Geiger tick
    imp = [0.0] * int(0.01 * SR)
    imp[2], imp[3] = 1.0, -0.6
    mix(out, Biquad('highpass', 1200).run(Biquad('lowpass', 7000).run(imp)), 0.0, 1.0)
    mix(out, tick(0.0012, 4500, 1.0), 0.0, 0.5)
    return out


def terminal_logged():
    out = silence(0.75)
    at = 0.0
    for i in range(9):                                                       # the entry being printed
        mix(out, tick(0.0015, random.uniform(2200, 3200), 1.3), at, 0.5 * (1 - i / 12))
        at += random.uniform(0.018, 0.03)
    for f, g in ((392.0, 1.0), (784.0, 0.18)):                               # one low tone, like a muted bell
        mix(out, Biquad('lowpass', 2000).run(tone(0.5, f, None, 'sine', 0.012, 0.16)), at + 0.02, 0.45 * g)
    return out


if __name__ == '__main__':
    write('terminal_on.wav', terminal_on(), fade_out=0.05)
    write('terminal_off.wav', terminal_off(), fade_out=0.04)
    write('terminal_tab.wav', terminal_tab())
    write('terminal_select.wav', terminal_select(), fade_out=0.005)
    write('terminal_scan.wav', terminal_scan(), fade_out=0.02)
    write('terminal_logged.wav', terminal_logged(), fade_out=0.06)
