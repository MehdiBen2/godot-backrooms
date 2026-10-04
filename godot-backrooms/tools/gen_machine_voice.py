"""THE MACHINE VOICE (the machineVoice event, scripts/Events/events.gd): text-to-speech lines in the manner of
analog horror (The Mandela Catalogue, Local 58, Gemini Home Entertainment), rendered in several voices into
audio/tts/<voice>/<line>.wav and listed in scripts/Audio/machine_voice_lines.gd. Windows only (the system's SAPI
voice, through PowerShell); numpy for the processing.

    python tools/gen_machine_voice.py

Modern Windows ships no Microsoft Sam (a SAPI4 voice), so every voice starts from whatever English SAPI5 voice is
installed (Zira, David...) and is wrecked into one of these:
  sam        the Mandela Catalogue: slowed, pitched down, sample-and-hold aliasing, bit-crushed, a slow ring
             modulation on the vowels, stutters and dropouts, a small cheap room, hiss and hum
  broadcast  an emergency broadcast (Local 58): squeezed into a telephone band, hard-compressed, a little
             overdriven, a slap of echo off a studio wall, mains hum
  alternate  something wearing a voice: the line doubled, once far too low and once a little high and late,
             a swell of reversed reverb arriving before each word, metallic
  whisper    the words with the voice taken out: only breath, shaped like speech, right by your ear
  deep       very slow and very low, overdriven, in a large dark space
  tape       an old cassette: the speed wobbling, saturation, dropouts, one place where the tape drags
All at 11025 Hz (the voices are all lo-fi; it keeps the files small). Peak-normalized to 0.8.

Lines are plain, calm and procedural: the dread is in the tone of an official notice, not in shouting. A line with
a context tag is the one the event prefers when that is true of you (events.gd _voice_context): dark, lowbattery,
still, running, alone, group, teammate_dead, lowsanity, lowhealth, longtime, newarrival, nearentity, powercut.
"""
import os, subprocess, tempfile, wave
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
OUT = os.path.join(ROOT, 'audio', 'tts')
LIST = os.path.join(ROOT, 'scripts', 'Audio', 'machine_voice_lines.gd')
SRC = 22050            # rendered and processed at this rate...
SR = 11025             # ...written at this one

VOICES = [
    ("sam", "SAM // MANDELA"),
    ("broadcast", "EMERGENCY BROADCAST"),
    ("alternate", "ALTERNATE"),
    ("whisper", "WHISPER"),
    ("deep", "DEEP"),
    ("tape", "TAPE"),
]

# (text, context tag or "")
LINES = [
    # --- the notices
    ("There is no one else here.", ""),
    ("Do not trust the voice that sounds like yours.", ""),
    ("You have been here before. You do not remember. That is expected.", ""),
    ("It is not your friend. It only sounds like your friend.", ""),
    ("Stop walking. It can hear you walking.", ""),
    ("Your family stopped looking for you a long time ago.", ""),
    ("We counted the doors. There is one less than yesterday.", ""),
    ("You were never supposed to wake up here.", ""),
    ("It knows your name now.", ""),
    ("Remain calm. Remain still. Remain.", ""),
    ("This is not a test.", ""),
    ("Do not look behind you.", ""),
    ("The exit was never real.", ""),
    ("Everyone you came with is gone. The ones beside you are not them.", ""),
    ("Say your name out loud. Is that still your voice?", ""),
    ("Do not let it in. It will ask nicely.", ""),
    ("You are not lost. You are being kept.", ""),
    ("Please hold. Someone will be with you shortly. Someone is with you now.", ""),
    ("It has been standing behind you since you arrived.", ""),
    ("Do not turn around. It is still learning your face.", ""),
    ("It knows what you sound like when you are asleep.", ""),
    ("Nobody is coming. Nobody was ever coming.", ""),
    ("Your name has been removed from the list.", ""),
    ("There are more of you here than there should be.", ""),
    ("It wore your voice today. Nobody noticed.", ""),
    ("Do you remember coming in? Neither did they.", ""),
    ("Do not sleep here.", ""),
    ("We kept your room exactly as you left it.", ""),
    ("Hold your breath. Let it pass.", ""),
    ("This message will repeat.", ""),
    ("Attention. A survivor in your area is no longer a survivor. Do not approach them.", ""),
    ("If someone you came with asks you to follow them, ask them something only they would know.", ""),
    ("The recording you are making will be found. You will not.", ""),
    ("If the lights go out, count to ten. If you hear something else counting, stop.", ""),
    ("Do not make eye contact with the figure at the end of the hall.", ""),
    ("It is learning to walk the way you walk.", ""),
    ("You have been reported missing for three years.", ""),
    ("This is a recorded message. The person who recorded it is behind you.", ""),
    ("If you hear knocking, it is already inside.", ""),
    ("Do not answer to your name. Your name was the first thing it took.", ""),
    ("The voice calling for help was not a person. It has learned what help sounds like.", ""),
    ("Your body was recovered. Please continue walking.", ""),
    ("All personnel are accounted for. You are not personnel.", ""),
    ("You are leaving the recorded area. Beyond this point, there is no record of you.", ""),
    ("Please remain in the light for as long as the light remains.", ""),
    # --- what it can see of you
    ("It is very dark where you are standing. It prefers it that way.", "dark"),
    ("Leave your light off. It already knows where you are.", "dark"),
    ("Your light is dying. Ration what is left of it.", "lowbattery"),
    ("When your light goes out, do not call for help.", "lowbattery"),
    ("You have not moved in a while. Neither has it.", "still"),
    ("Running only tells it where you are going.", "running"),
    ("You are alone now. You were always going to be alone.", "alone"),
    ("No one can hear you from here. Not even the others.", "alone"),
    ("Count the people standing with you. Count them again.", "group"),
    ("One of the people beside you stopped breathing a minute ago. It is still smiling at you.", "group"),
    ("One of you is already gone. The others have not noticed yet.", "teammate_dead"),
    ("The one you lost is still walking. Do not wait for them.", "teammate_dead"),
    ("You are beginning to hear us clearly. That is not a good sign.", "lowsanity"),
    ("You are bleeding. It can smell it.", "lowhealth"),
    ("You have been here a long time. Longer than the clock says.", "longtime"),
    ("Welcome. Do not get comfortable.", "newarrival"),
    ("It is very close to you now. Do not run.", "nearentity"),
    ("The power is out. Everything that was hiding from the light is not hiding anymore.", "powercut"),
]

rng = np.random.default_rng(58)


# ---------------------------------------------------------------- tools
def synth(text, path, rate=-2):
    ps = (
        "Add-Type -AssemblyName System.Speech;"
        "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer;"
        "$v = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like 'en-*' } | Select-Object -First 1;"
        "if ($v) { $s.SelectVoice($v.VoiceInfo.Name) };"
        "$s.Rate = %d;"
        "$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(%d, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono);"
        "$s.SetOutputToWaveFile('%s', $fmt);"
        "$s.Speak([IO.File]::ReadAllText('%s'));"
        "$s.Dispose()"
    )
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False, encoding='utf-8') as f:
        f.write(text)
        txt = f.name
    try:
        subprocess.run(['powershell', '-NoProfile', '-Command', ps % (rate, SRC, path, txt)], check=True)
    finally:
        os.remove(txt)
    with wave.open(path, 'rb') as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


def write(path, x):
    # down to SR: band-limit, then every other sample
    x = band(x, 0.0, SR * 0.45)
    x = x[::SRC // SR]
    peak = float(np.max(np.abs(x))) or 1.0
    x = np.clip(x / peak * 0.8, -1.0, 1.0)
    # the tail: only as long as there is something left to hear in it, then a short fade
    loud = np.where(np.abs(x) > 0.012)[0]
    if len(loud):
        x = x[:min(len(x), loud[-1] + int(0.25 * SR))]
        fade = min(int(0.2 * SR), len(x) // 4)
        x[-fade:] *= np.linspace(1.0, 0.0, fade)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767.0).astype(np.int16).tobytes())


def band(x, lo, hi):
    """Band-pass in the frequency domain, with soft edges"""
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SRC)
    g = np.ones_like(f)
    if lo > 0:
        g *= np.clip((f - lo * 0.7) / (lo * 0.3), 0, 1)
    if hi < SRC / 2:
        g *= np.clip((hi * 1.25 - f) / (hi * 0.25), 0, 1)
    return np.fft.irfft(X * g, n).astype(np.float32)


def resample(x, speed):
    """Play back at `speed` (below 1: slower and lower)"""
    n = int(len(x) / speed)
    return np.interp(np.arange(n) * speed, np.arange(len(x)), x).astype(np.float32)


def convolve(x, ir):
    n = len(x) + len(ir)
    return np.fft.irfft(np.fft.rfft(x, n) * np.fft.rfft(ir, n), n)[:n].astype(np.float32)


def room(secs, dark_hz, density=1.0):
    """A reverb tail: decaying noise, darkened"""
    t = np.arange(int(SRC * secs)) / SRC
    ir = rng.normal(0, 1, len(t)).astype(np.float32) * np.exp(-t / (secs * 0.28)) * density
    return band(ir, 80.0, dark_hz) * 0.06


def pad(x, before, after):
    return np.concatenate([np.zeros(int(SRC * before), np.float32), x, np.zeros(int(SRC * after), np.float32)])


def floor_noise(x, hiss, hum):
    t = np.arange(len(x)) / SRC
    return (x + rng.normal(0, hiss, len(x)) + hum * np.sin(2 * np.pi * 60.0 * t)).astype(np.float32)


def stutter(x, chance):
    if rng.random() < chance and len(x) > SRC:
        at = int(rng.uniform(0.25, 0.75) * len(x))
        seg = x[at:at + int(SRC * rng.uniform(0.07, 0.13))]
        x = np.concatenate([x[:at], np.tile(seg, int(rng.integers(3, 6))), x[at:]])
    return x


# ---------------------------------------------------------------- the voices
def v_sam(x):
    x = resample(x, rng.uniform(0.76, 0.84))
    x = stutter(x, 0.45)
    hold = 3
    x = np.repeat(x[::hold], hold)[:len(x)]
    levels = 2 ** int(rng.integers(5, 7))
    x = np.round(x * levels) / levels
    t = np.arange(len(x)) / SRC
    x = x * (0.72 + 0.28 * np.sin(2 * np.pi * rng.uniform(38.0, 62.0) * t))
    x = (np.tanh(x * 2.2) / np.tanh(2.2)).astype(np.float32)
    for _ in range(int(rng.integers(0, 3))):
        at = int(rng.uniform(0.1, 0.9) * len(x))
        x[at:at + int(SRC * rng.uniform(0.03, 0.08))] *= 0.05
    x = pad(x, 0.25, 0.9)
    x = x + convolve(x, room(0.6, 2500.0))[:len(x)] * 0.5
    return floor_noise(x, 0.012, 0.01)


def v_broadcast(x):
    x = resample(x, 0.93)
    x = band(x, 320.0, 3100.0)
    x = x / (np.max(np.abs(x)) or 1.0)
    x = np.sign(x) * np.abs(x) ** 0.55                         # squashed flat
    x = np.tanh(x * 2.6).astype(np.float32)
    x = pad(x, 0.3, 0.6)
    k = int(SRC * 0.085)
    slap = np.concatenate([np.zeros(k, np.float32), x[:-k]])
    x = x + 0.28 * slap
    return floor_noise(x, 0.008, 0.03)


def v_alternate(x):
    x = resample(x, 0.86)
    low = resample(x, 0.7)                                     # far too low
    high = resample(x, 1.1)                                    # a little high, and late
    high = np.concatenate([np.zeros(int(SRC * 0.03), np.float32), high])
    n = max(len(low), len(high))
    mix = np.zeros(n, np.float32)
    mix[:len(low)] += low
    mix[:len(high)] += 0.55 * high
    t = np.arange(n) / SRC
    mix = (mix * (0.8 + 0.2 * np.sin(2 * np.pi * 31.0 * t))).astype(np.float32)     # metallic
    mix = pad(mix, 1.0, 0.8)
    # the reversed reverb: each word swelling up out of nothing before it is said
    swell = convolve(mix[::-1].copy(), room(1.1, 3000.0, 1.4))[:len(mix)][::-1]
    mix = mix + swell * 0.9
    return floor_noise(mix, 0.006, 0.0)


def v_whisper(x):
    x = resample(x, 0.95)
    # keep the shape of the speech (its spectrum, frame by frame) and throw the voice (the phase) away
    frame, hop = 512, 128
    win = np.hanning(frame).astype(np.float32)
    x = pad(x, 0.05, 0.3)
    out = np.zeros(len(x) + frame, np.float32)
    for i in range(0, len(x) - frame, hop):
        spec = np.fft.rfft(x[i:i + frame] * win)
        mag = np.abs(spec)
        phase = rng.uniform(-np.pi, np.pi, len(mag))
        out[i:i + frame] += np.fft.irfft(mag * np.exp(1j * phase), frame).astype(np.float32) * win
    out = band(out[:len(x)], 450.0, 7000.0)
    return floor_noise(out, 0.002, 0.0)


def v_deep(x):
    x = resample(x, 0.6)
    x = np.tanh(x * 3.0).astype(np.float32)
    x = band(x, 40.0, 2600.0)
    x = pad(x, 0.2, 2.2)
    x = x + convolve(x, room(2.4, 1400.0, 1.2))[:len(x)] * 0.9
    return floor_noise(x, 0.003, 0.0)


def v_tape(x):
    x = resample(x, 0.97)
    n = len(x)
    t = np.arange(n) / SRC
    wobble = 0.004 * np.sin(2 * np.pi * 0.7 * t) + 0.0012 * np.sin(2 * np.pi * 6.5 * t)
    drag = np.ones(n)                                          # one place where the tape drags
    at = int(rng.uniform(0.3, 0.7) * n)
    span = len(drag[at:at + int(SRC * 0.35)])
    drag[at:at + span] = np.linspace(0.65, 1.0, span)
    pos = np.cumsum((1.0 + wobble) * drag)
    pos = pos[pos < n - 1]
    x = np.interp(pos, np.arange(n), x).astype(np.float32)
    x = np.tanh(x * 1.8).astype(np.float32)
    x = band(x, 90.0, 4800.0)
    for _ in range(int(rng.integers(1, 4))):                   # dropouts
        a = int(rng.uniform(0.1, 0.9) * len(x))
        x[a:a + int(SRC * rng.uniform(0.02, 0.06))] *= 0.15
    x = pad(x, 0.25, 0.5)
    return floor_noise(x, 0.02, 0.012)


FX = {"sam": v_sam, "broadcast": v_broadcast, "alternate": v_alternate, "whisper": v_whisper, "deep": v_deep,
      "tape": v_tape}


def main():
    # the old single-voice files (audio/tts/machine_NN.wav) go
    if os.path.isdir(OUT):
        for f in os.listdir(OUT):
            if f.startswith('machine_') and (f.endswith('.wav') or f.endswith('.wav.import')):
                os.remove(os.path.join(OUT, f))
    for vid, _ in VOICES:
        os.makedirs(os.path.join(OUT, vid), exist_ok=True)
    raw = os.path.join(OUT, '_raw.wav')
    rows = []
    for i, (text, tag) in enumerate(LINES):
        lid = 'l%02d' % i
        base = synth(text, raw)
        for vid, _ in VOICES:
            write(os.path.join(OUT, vid, lid + '.wav'), FX[vid](base.copy()))
        rows.append((lid, text, tag))
        print(lid, tag or '-', text)
    os.remove(raw)
    with open(LIST, 'w', encoding='utf-8', newline='\n') as f:
        f.write('extends RefCounted\n')
        f.write('## Generated by tools/gen_machine_voice.py: the machine voice\'s voices and lines.\n')
        f.write('## Each line is in every voice: path(voice, id). `tag`: when the line is the one to say\n')
        f.write('## (events.gd _voice_context), "" for any time.\n\n')
        f.write('const VOICES := [\n')
        for vid, label in VOICES:
            f.write('\t["%s", "%s"],\n' % (vid, label))
        f.write(']\n\n')
        f.write('const LINES := [\n')
        for lid, text, tag in rows:
            f.write('\t{"id": "%s", "text": "%s", "tag": "%s"},\n' % (lid, text.upper().replace('"', '\\"'), tag))
        f.write(']\n\n')
        f.write('static func path(voice: String, id: String) -> String:\n')
        f.write('\treturn "res://audio/tts/%s/%s.wav" % [voice, id]\n')


if __name__ == '__main__':
    main()
