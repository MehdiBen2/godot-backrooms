# /// script
# dependencies = ["numpy", "soundfile"]
# ///
"""layers.py SPEC.json OUTDIR: one take built from several mix.py runs ("groups"), each group's mix summed
at its own gain in dB. mix.py levels every cue for audibility on its own; this sets the balance between
groups (e.g. a zip 12 dB under the hand and the bag). Run from the skill folder.
SPEC: {"duration_s": 1.0, "groups": [{"gain_db": 0, "cues": [...]}, ...]}"""
import json, os, subprocess, sys
import numpy as np, soundfile as sf

spec, out = json.load(open(sys.argv[1])), sys.argv[2]
os.makedirs(out, exist_ok=True)
total = None
for i, g in enumerate(spec["groups"]):
    d = os.path.join(out, f"g{i}")
    os.makedirs(d, exist_ok=True)
    cues = dict(fps=30, duration_s=spec["duration_s"], energy="calm", lufs=-30, kit=spec.get("kit", "audio/kit"), room=False, cues=g["cues"])
    sheet = os.path.join(d, "cues.json")
    same = os.path.exists(os.path.join(d, "stems", "sfx.wav")) and os.path.exists(sheet) and json.load(open(sheet)) == cues
    if not same:                      # only re-mix a group whose cues changed (gain_db is applied here, after)
        json.dump(cues, open(sheet, "w"), indent=1)
        subprocess.run(["uv", "run", "-q", "scripts/mix.py", sheet, "--out", d], check=True)
    x, sr = sf.read(os.path.join(d, "stems", "sfx.wav"))
    x = x * 10 ** (g.get("gain_db", 0) / 20)
    total = x if total is None else total + x
sf.write(os.path.join(out, "mix.wav"), total.astype(np.float32), sr, subtype="FLOAT")
