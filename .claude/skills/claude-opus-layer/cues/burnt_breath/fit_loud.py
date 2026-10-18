# fit_loud.py MIX OUT: mono, 44.1 kHz, 16-bit; trailing silence trimmed (-50 dB), 30 ms fade out; scaled so its
# loudest ~50 ms (RMS) is 0.2, the loudness burnt.gd _sfx matches every sound to (SFX_LOUD). Prints the figures.
import sys, subprocess, numpy as np, soundfile as sf

src, out = sys.argv[1], sys.argv[2]
tmp = out + ".tmp.wav"
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1", "-ar", "44100", tmp], check=True)
x, sr = sf.read(tmp)
win = int(sr * 0.05)
env = np.array([np.sqrt(np.mean(x[i:i + win] ** 2)) for i in range(0, max(1, len(x) - win), win // 2)])
last = np.nonzero(20 * np.log10(env / env.max() + 1e-12) > -50)[0][-1]
x = x[: min(len(x), (last + 2) * win // 2 + win)]
f = int(sr * 0.03)
x[-f:] *= np.linspace(1, 0, f)
loud = max(np.sqrt(np.mean(x[i:i + win] ** 2)) for i in range(0, len(x) - win, win // 2))
x *= 0.2 / loud
peak = np.abs(x).max()
if peak > 0.89: x *= 0.89 / peak                       # never over -1 dBFS
sf.write(out, x, sr, subtype="PCM_16")
import os; os.remove(tmp)
spec = np.abs(np.fft.rfft(x)); fr = np.fft.rfftfreq(len(x), 1 / sr)
print("%s  %.2fs  peak %.1f dBFS  rms %.1f dBFS  loud %.3f  centroid %d Hz" % (os.path.basename(out), len(x) / sr,
      20 * np.log10(np.abs(x).max()), 20 * np.log10(np.sqrt(np.mean(x ** 2))),
      max(np.sqrt(np.mean(x[i:i + win] ** 2)) for i in range(0, len(x) - win, win // 2)), (spec * fr).sum() / spec.sum()))
