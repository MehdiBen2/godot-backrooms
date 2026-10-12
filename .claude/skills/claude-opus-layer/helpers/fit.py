# /// script
# dependencies = ["numpy", "scipy", "soundfile"]
# ///
"""fit.py MIX OLD OUT: trim MIX to its sound, mono, OLD's sample rate, 16-bit, peak matched to OLD."""
import sys
import numpy as np, soundfile as sf
from scipy import signal
from fractions import Fraction

mix, old, out = sys.argv[1:4]
x, sr = sf.read(mix); x = x.mean(axis=1) if x.ndim > 1 else x
o, osr = sf.read(old)
env = np.sqrt(np.convolve(x * x, np.ones(96) / 96, mode="same"))
on = np.where(env > env.max() * 10 ** (-50 / 20))[0]
a, b = max(0, on[0] - int(0.003 * sr)), min(len(x), on[-1] + int(0.01 * sr))
x = x[a:b]
r = Fraction(osr, sr).limit_denominator(1000)
x = signal.resample_poly(x, r.numerator, r.denominator)
f = int(0.01 * osr); x[-f:] *= np.linspace(1, 0, f); x[:16] *= np.linspace(0, 1, 16)
act = lambda y: np.sqrt(np.mean(y[np.abs(y) > np.max(np.abs(y)) * 10 ** (-40 / 20)] ** 2))
x *= act(o) / act(x)                                 # same loudness while it sounds
x *= min(1.0, 10 ** (-10 / 20) / np.max(np.abs(x)))  # but the peak no higher than -10 dBFS
sf.write(out, x, osr, subtype="PCM_16")
db = lambda v: 20 * np.log10(v + 1e-12)
for name, y, s in (("old", o, osr), ("new", x, osr)):
    spec = np.abs(np.fft.rfft(y)) ** 2; fr = np.fft.rfftfreq(len(y), 1 / s)
    act = y[np.abs(y) > 10 ** (-50 / 20)]
    print(f"{name}: {len(y)/s:.3f} s  peak {db(np.max(np.abs(y))):.1f} dBFS  rms {db(np.sqrt(np.mean(y*y))):.1f}  "
          f"active rms {db(np.sqrt(np.mean(act*act))):.1f}  centroid {int((fr*spec).sum()/spec.sum())} Hz")
