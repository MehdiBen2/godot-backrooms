"""Measure the level of every recorded one-shot clip and write audio/clip_levels.json.

The game cannot decode an MP3 into samples at run time, so it cannot measure how loud a recording is.
This writes each clip's peak and "active" RMS (the RMS of the audible part, silence ignored) in dBFS;
scripts/audio/clip_levels.gd turns that into a playback gain so clips recorded at wildly different
levels (the gasps range from -30 dB to -4 dB peak) all land at the same loudness.

    pip install miniaudio numpy
    python tools/measure_audio.py
"""
import json
import pathlib

import miniaudio
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
# the folders holding one-shots (the synthesized loops and breaths have audio/scales.json instead)
FOLDERS = ["audio/player", "audio/entity", "audio/events", "audio/ambients"]
SILENCE = 10 ** (-50 / 20)          # samples quieter than -50 dBFS do not count toward the RMS


def db(v: float) -> float:
    return round(20.0 * np.log10(max(v, 1e-9)), 2)


def measure(path: pathlib.Path) -> dict:
    d = miniaudio.decode_file(str(path), output_format=miniaudio.SampleFormat.FLOAT32, nchannels=1)
    a = np.frombuffer(d.samples, dtype=np.float32)
    active = a[np.abs(a) > SILENCE]
    rms = float(np.sqrt(np.mean(active * active))) if active.size else 0.0
    return {"peak": db(float(np.abs(a).max()) if a.size else 0.0), "rms": db(rms),
            "length": round(a.size / d.sample_rate, 3)}


def main() -> None:
    out = {}
    for folder in FOLDERS:
        for f in sorted((ROOT / folder).rglob("*")):
            if f.suffix.lower() not in (".mp3", ".wav", ".ogg"):
                continue
            key = "res://" + f.relative_to(ROOT).as_posix()
            out[key] = measure(f)
            print(f"{key:80s} peak {out[key]['peak']:6.1f}  rms {out[key]['rms']:6.1f}")
    (ROOT / "audio" / "clip_levels.json").write_text(json.dumps(out, indent=1) + "\n")
    print(f"wrote {len(out)} clips")


if __name__ == "__main__":
    main()
