# /// script
# dependencies = ["numpy", "scipy", "soundfile"]
# ///
"""steps_fit.py REF_GLOB OUT_DIR NAME OFFSET_DB FILE...: one game footstep take per FILE, written as
OUT_DIR/NAME_<START+i>.ogg (44.1 kHz mono): cut where it has died 40 dB under its peak (0.3 s at most),
15 ms fade, the step's first 120 ms at the reference takes' level + OFFSET_DB, peak no higher than -1 dBFS."""
import glob, os, subprocess, sys
import numpy as np, soundfile as sf
from scipy import signal

SR = 44100
ref_glob, out, name, offset = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
HP = float(os.environ.get("HP", "0"))     # optional high-pass (Hz): carpet takes are the scuff, the heel is synth
db = lambda v: 20 * np.log10(v + 1e-12)

def load(p):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).astype(np.float64)

def body(x):
    pk = int(np.argmax(np.abs(x)))
    return np.sqrt(np.mean(x[max(0, pk - int(0.01 * SR)): pk + int(0.11 * SR)] ** 2))

ref = float(np.mean([db(body(load(p))) for p in sorted(glob.glob(ref_glob))]))
target = ref + offset
os.makedirs(out, exist_ok=True)
for i, f in enumerate(sys.argv[5:]):
    x = load(f)
    if HP: x = signal.sosfilt(signal.butter(2, HP, "highpass", fs=SR, output="sos"), x)
    env = np.sqrt(np.convolve(x * x, np.ones(220) / 220, mode="same"))
    pk = int(np.argmax(env))
    live = np.where(env[pk:] > env[pk] * 10 ** (-40 / 20))[0]
    end = min(len(x), pk + (live[-1] if len(live) else 0) + int(0.01 * SR), int(float(os.environ.get("MAXLEN", "0.3")) * SR))
    x = x[:end].copy()
    n = int(0.015 * SR); x[-n:] *= np.linspace(1, 0, n) ** 2
    g = 10 ** ((target - db(body(x))) / 20)
    g = min(g, 10 ** (-1 / 20) / np.max(np.abs(x)))
    x *= g
    dst = os.path.join(out, f"{name}_{i + int(os.environ.get('START', '0'))}.ogg")
    tmp = dst[:-4] + ".tmp.wav"
    sf.write(tmp, x.astype(np.float32), SR, subtype="FLOAT")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", tmp, "-c:a", "libvorbis", "-q:a", "6", dst], check=True)
    os.remove(tmp)
    spec = np.abs(np.fft.rfft(x)) ** 2; fr = np.fft.rfftfreq(len(x), 1 / SR)
    print(f"{os.path.basename(dst):14s} {len(x)/SR:.3f} s  body {db(body(x)):6.1f} dB (target {target:.1f})  "
          f"peak {db(np.max(np.abs(x))):5.1f}  centroid {int((fr*spec).sum()/spec.sum()):5d} Hz  <- {os.path.basename(f)}")
