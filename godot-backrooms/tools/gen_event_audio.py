"""Sounds for the director events in scripts/Events/events.gd that need a recording of their own, rendered into
audio/events/. Windows (the party crowd is the system's SAPI voice, through PowerShell) and numpy.

    python tools/gen_event_audio.py

  hum_loop.wav      humRises: a fluorescent ballast buzz (120 Hz and its harmonics, an arc sizzle on top),
                    seamless, 4 s; the event swells it until it hurts
  party_muffled.wav partyWall: a party on the other side of the drywall, 24 s, looped: a four-on-the-floor
                    song with a walking bass and chords, and a crowd talking and laughing over it, all of it
                    through a wall (everything over ~350 Hz gone, the bass thumping through)
  phone_ring.wav    phoneRing: one ring of an old desk phone's bell (two gongs struck by a 20 Hz clapper),
                    2 s, then the silence the event spaces them with
  doorbell.wav      doorbell: a cheap two-tone door chime (ding... dong), struck metal bars ringing out
Every file is peak-normalized to 0.8; the event sets the level it plays at.
"""
import os, subprocess, tempfile, wave
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
OUT = os.path.join(ROOT, 'audio', 'events')
SR = 22050
rng = np.random.default_rng(1993)


def write(name, x, loop=False):
    peak = float(np.max(np.abs(x))) or 1.0
    x = np.clip(x / peak * 0.8, -1.0, 1.0)
    if loop:                                      # crossfade the tail into the head: no click at the seam
        n = int(SR * 0.25)
        x[:n] = x[:n] * np.linspace(0, 1, n) + x[-n:] * np.linspace(1, 0, n)
        x = x[:-n]
    with wave.open(os.path.join(OUT, name), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767.0).astype(np.int16).tobytes())


def lowpass(x, hz):
    """One-pole low-pass, run twice (12 dB/oct)"""
    a = np.exp(-2.0 * np.pi * hz / SR)
    for _ in range(2):
        y = np.empty_like(x)
        acc = 0.0
        for i in range(len(x)):
            acc = (1.0 - a) * x[i] + a * acc
            y[i] = acc
        x = y
    return x


def t_axis(secs):
    return np.arange(int(SR * secs)) / SR


# ---------------------------------------------------------------- hum
def hum():
    t = t_axis(4.25)
    x = np.zeros_like(t)
    for h, g in ((1, 1.0), (2, 0.55), (3, 0.42), (4, 0.2), (5, 0.16), (7, 0.08), (9, 0.05)):
        x += g * np.sin(2 * np.pi * 120.0 * h * t + rng.uniform(0, 6.28))
    x = np.sign(x) * np.abs(x) ** 0.7                        # a harder, buzzier edge
    sizzle = rng.normal(0, 1, len(t)) * (0.5 + 0.5 * np.sin(2 * np.pi * 120.0 * t) ** 8)
    sizzle = sizzle - lowpass(sizzle, 2500.0)
    x = x + 0.25 * sizzle
    write('hum_loop.wav', x.astype(np.float32), loop=True)


# ---------------------------------------------------------------- party
PARTY_LINES = ["Oh my god, no way.", "Ha ha ha ha.", "Did you see that?", "Happy birthday!", "Come here, come here.",
               "Who invited him?", "Yes! Yes!", "Where did everyone go?", "Turn it up!", "Ha ha.",
               "You have to try this.", "Wait, listen.", "Is that him?", "Ha ha ha.", "Over here!"]


def say(text, path):
    ps = ("Add-Type -AssemblyName System.Speech;"
          "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer;"
          "$v = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like 'en-*' } | Select-Object -First 1;"
          "if ($v) { $s.SelectVoice($v.VoiceInfo.Name) };"
          "$s.Rate = 2;"
          "$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(%d, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono);"
          "$s.SetOutputToWaveFile('%s', $fmt);"
          "$s.Speak([IO.File]::ReadAllText('%s'));$s.Dispose()")
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False, encoding='utf-8') as f:
        f.write(text)
        txt = f.name
    try:
        subprocess.run(['powershell', '-NoProfile', '-Command', ps % (SR, path, txt)], check=True)
    finally:
        os.remove(txt)
    with wave.open(path, 'rb') as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


def party():
    secs = 24.0
    t = t_axis(secs + 0.25)
    n = len(t)
    bpm = 118.0
    beat = 60.0 / bpm
    song = np.zeros(n, dtype=np.float32)
    # kick on every beat
    for k in range(int(len(t) / SR / beat) + 1):
        at = int(k * beat * SR)
        kt = t_axis(0.35)
        kick = np.sin(2 * np.pi * (45.0 + 70.0 * np.exp(-kt * 25.0)) * kt) * np.exp(-kt * 9.0)
        song[at:at + len(kick)] += kick[:max(0, min(len(kick), n - at))]
    # walking bass and a pad over four chords (a bar each)
    roots = [55.0, 43.65, 49.0, 41.2]                        # A, F, G, E (low)
    bar = beat * 4
    for i in range(int(secs / bar) + 1):
        r = roots[i % 4]
        s, e = int(i * bar * SR), min(n, int((i + 1) * bar * SR))
        if s >= e:
            continue
        tt = t[s:e] - t[s]
        for q in range(4):                                    # the bass steps each beat
            qs, qe = s + int(q * beat * SR), min(e, s + int((q + 1) * beat * SR))
            if qs >= qe:
                continue
            seg = t[qs:qe] - t[qs]
            f = r * (1.0, 1.5, 2.0, 1.5)[q]
            song[qs:qe] += 0.6 * np.sign(np.sin(2 * np.pi * f * seg)) * np.exp(-seg * 3.0)
        for m in (2.0, 2.52, 3.0):                            # the pad: root, third, fifth an octave up
            song[s:e] += 0.12 * np.sin(2 * np.pi * r * m * tt)
    # the crowd: lines said over each other at different pitches, all through the evening
    crowd = np.zeros(n, dtype=np.float32)
    raw = os.path.join(OUT, '_raw.wav')
    takes = [say(line, raw) for line in PARTY_LINES]
    os.remove(raw)
    for _ in range(46):
        x = takes[int(rng.integers(len(takes)))]
        pitch = rng.uniform(0.8, 1.35)                        # men, women, someone shrieking a laugh
        m = int(len(x) / pitch)
        x = np.interp(np.arange(m) * pitch, np.arange(len(x)), x).astype(np.float32)
        at = int(rng.uniform(0, secs - 1.5) * SR)
        crowd[at:at + len(x)] += x[:max(0, min(len(x), n - at))] * rng.uniform(0.3, 0.9)
    crowd += 0.08 * lowpass(rng.normal(0, 1, n).astype(np.float32), 600.0)     # the murmur under it
    # through the wall
    mix = lowpass(song * 0.9 + crowd * 0.8, 340.0)
    write('party_muffled.wav', mix.astype(np.float32), loop=True)


# ---------------------------------------------------------------- phone
def phone():
    t = t_axis(2.0)
    bell = np.zeros_like(t)
    for f0 in (1150.0, 1450.0):                               # two gongs
        for ratio, g in ((1.0, 1.0), (2.76, 0.45), (5.4, 0.2)):
            bell += g * np.sin(2 * np.pi * f0 * ratio * t)
    clapper = (np.sin(2 * np.pi * 20.0 * t) > 0).astype(np.float32)   # struck 20 times a second
    strike = np.convolve(np.diff(clapper, prepend=0).clip(0), np.exp(-np.arange(int(SR * 0.05)) / (SR * 0.012)))[:len(t)]
    x = bell * (0.3 + strike) * np.clip(t / 0.01, 0, 1) * np.clip((2.0 - t) / 0.05, 0, 1)
    x = x + 0.25 * lowpass(x, 900.0)                          # the plastic body under the bells
    write('phone_ring.wav', np.concatenate([x, np.zeros(int(SR * 0.2))]).astype(np.float32))


# ---------------------------------------------------------------- doorbell
def doorbell():
    out = np.zeros(int(SR * 3.2), dtype=np.float32)
    for at, f0, g in ((0.0, 659.3, 1.0), (0.62, 523.3, 0.9)):        # E5 ding, C5 dong
        t = t_axis(2.6)
        bar = np.zeros_like(t)
        for ratio, pg, decay in ((1.0, 1.0, 1.4), (2.76, 0.35, 0.5), (5.4, 0.12, 0.25), (8.93, 0.05, 0.15)):
            bar += pg * np.sin(2 * np.pi * f0 * ratio * t) * np.exp(-t / decay)
        bar *= g * np.clip(t / 0.003, 0, 1)
        s = int(at * SR)
        out[s:s + len(bar)] += bar[:max(0, min(len(bar), len(out) - s))]
    out = out + 0.2 * lowpass(out, 700.0)                          # the plastic housing
    write('doorbell.wav', out)


if __name__ == '__main__':
    import sys
    os.makedirs(OUT, exist_ok=True)
    only = sys.argv[1:]                       # e.g. "doorbell": just that one
    for name, fn in (('hum', hum), ('phone', phone), ('party', party), ('doorbell', doorbell)):
        if not only or name in only:
            fn()
    print('written to', os.path.abspath(OUT))
