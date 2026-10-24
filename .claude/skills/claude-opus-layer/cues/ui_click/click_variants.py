# /// script
# dependencies = ["numpy", "scipy", "soundfile"]
# ///
"""Variants of the original ui_click.wav: tape pitch, tail length, tone tilt, plus a quiet switch transient."""
import sys, numpy as np, soundfile as sf
from scipy import signal
from fractions import Fraction
orig, kit, out = sys.argv[1:4]
x, sr = sf.read(orig); x = x.mean(axis=1) if x.ndim > 1 else x
def rs(y, a, b):
    r = Fraction(b, a).limit_denominator(2000); return signal.resample_poly(y, r.numerator, r.denominator)
def mono(p):
    y, s = sf.read(p); y = y.mean(axis=1) if y.ndim > 1 else y
    return rs(y, s, sr) if s != sr else y
# take: semitones, tail end s, tone (+bright / -dark), switch id, switch gain dB under the click's peak
V = [(1, 0.40, 0.0, "16", -14), (-1, 0.45, -0.5, "17", -14), (2, 0.30, 0.3, "18", -15),
     (-2, 0.40, -0.3, "19", -13), (0.5, 0.35, 0.5, "26", -14)]
for i, (st, tail, tone, sw, gdb) in enumerate(V, start=2):
    r = 2 ** (st / 12)
    y = rs(x, int(round(sr * r)), sr)                 # tape-style: faster = higher and shorter
    n = min(len(y), int(tail * sr)); y = y[:n].copy()
    f = int(0.08 * sr); y[-f:] *= np.linspace(1, 0, f) ** 2
    if tone > 0:
        y = y + tone * signal.sosfilt(signal.butter(2, 2500, "hp", fs=sr, output="sos"), y)
    elif tone < 0:
        y = (1 + tone) * y + (-tone) * signal.sosfilt(signal.butter(2, 2500, "lp", fs=sr, output="sos"), y)
    s = mono(f"{kit}/click/kenney-ui-audio-switch{sw}.wav")
    s = s / np.max(np.abs(s)) * np.max(np.abs(y)) * 10 ** (gdb / 20)
    off = int(np.argmax(np.abs(y))) - int(np.argmax(np.abs(s)))
    z = np.zeros(max(len(y), off + len(s)) if off >= 0 else len(y))
    z[:len(y)] += y
    a = max(0, off); z[a:a + len(s) - max(0, -off)] += s[max(0, -off):][:len(z) - a]
    z = z[:len(y)]
    sf.write(f"{out}/ui_click_{i}.wav", z.astype(np.float32), sr, subtype="FLOAT")
    print(i, st, tail, tone, sw, len(z) / sr)
