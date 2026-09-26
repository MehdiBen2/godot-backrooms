"""Synthesizes a seamless stereo wind loop (audio/ambients/outdoor/wind_loop.wav): band-limited noise
with slow gust swells, built with circular FFT filtering so the loop point is inaudible."""
import numpy as np, wave, sys
sr, secs = 44100, 24
n = sr * secs
rng = np.random.default_rng(7)
def wind(seed):
    r = np.random.default_rng(seed)
    spec = np.fft.rfft(r.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / sr)
    shape = np.zeros_like(f)
    shape[1:] = 1.0 / np.sqrt(np.maximum(f[1:], 1.0))                   # pink-ish
    shape *= 1.0 / (1.0 + (f / 900.0) ** 3)                              # roll off the hiss
    shape *= 1.0 / (1.0 + (60.0 / np.maximum(f, 1.0)) ** 2)              # no rumble below ~60 Hz
    x = np.fft.irfft(spec * shape, n)
    t = np.arange(n) / n
    g = np.zeros(n)
    for k, a in ((3, 1.0), (5, 0.6), (8, 0.35), (13, 0.15)):             # integer cycles per loop = seamless
        g += a * np.sin(2 * np.pi * (k * t + r.random()))
    g = 0.55 + 0.45 * (g - g.min()) / (g.max() - g.min())
    return x * g
L, R = wind(1), wind(2)
out = np.stack([L, R], 1)
out /= np.abs(out).max() * 1.05
pcm = (out * 32767).astype(np.int16)
with wave.open(sys.argv[1] if len(sys.argv) > 1 else "audio/ambients/outdoor/wind_loop.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(pcm.tobytes())
