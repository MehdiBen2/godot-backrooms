"""THE MACHINE VOICE (the machineVoice event, scripts/Events/events.gd): old Windows text-to-speech lines in the
manner of The Mandela Catalogue, rendered once into audio/tts/ and listed in scripts/Audio/machine_voice_lines.gd.
Windows only (it drives the system's SAPI voice through PowerShell); numpy for the processing.

    python tools/gen_machine_voice.py

The voice the Mandela Catalogue used (Microsoft Sam) is a SAPI4 voice modern Windows doesn't ship, so this takes
whatever English SAPI5 voice is installed (Zira, David...) and wrecks it until it sits in the same place:
  - slowed and pitched down (a resample: deeper, flatter, more mechanical)
  - sample-and-hold down to ~7 kHz with no filtering (the crunchy aliasing of an old sound card)
  - bit-crushed to a few bits (the grain)
  - a slow ring modulation (the metallic, inhuman wobble on the vowels)
  - soft clipping, then a small cheap reverb (a room it is not in)
  - sometimes a stutter (a syllable caught and repeated) and a dropout
  - a noise floor of hiss and mains hum
Every take is peak-normalized to 0.8; the event sets the level it plays at.
"""
import json, os, subprocess, tempfile, wave
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
OUT = os.path.join(ROOT, 'audio', 'tts')
LIST = os.path.join(ROOT, 'scripts', 'Audio', 'machine_voice_lines.gd')
SR = 22050
rng = np.random.default_rng(58)

# Calm, flat, wrong. No screaming: the voice reads these like a public notice.
LINES = [
    "There is no one else here.",
    "Do not trust the voice that sounds like yours.",
    "You have been here before. You do not remember. That is normal.",
    "It is not your friend. It only sounds like your friend.",
    "Stop walking. It can hear you walking.",
    "Your family stopped looking for you a long time ago.",
    "We counted the doors. There is one less than yesterday.",
    "If it smiles at you, do not smile back.",
    "The lights are not for you.",
    "You were never supposed to wake up here.",
    "It knows your name now.",
    "Remain calm. Remain still. Remain.",
    "This is not a test. This has never been a test.",
    "Do not look behind you. It is already there.",
    "The exit was never real.",
    "Everyone you came with is gone. The ones beside you are not them.",
    "Say your name out loud. Is that still your voice?",
    "Twelve researchers entered. Zero researchers remain. Thank you for your cooperation.",
    "Do not let it in. It will ask nicely.",
    "It has been watching you sleep.",
    "You are not lost. You are being kept.",
    "Please hold. Someone will be with you shortly. Someone is with you now.",
    "Your heartbeat is too loud. It is following the sound.",
    "Hello. Hello. Hello. I can see you.",
    "I have been standing behind you since you arrived.",
    "Do not turn around. I am still learning your face.",
    "Your friends are not answering because they are busy being replaced.",
    "I know what you sound like when you are asleep.",
    "We made a copy of you. It is doing better than you.",
    "Count your fingers. Count them again.",
    "The carpet is wet because of what happened to the last one.",
    "I can smell you through the walls.",
    "Keep walking. The walls like it when you walk.",
    "You blinked. Something moved. You blinked again.",
    "Please stop screaming. It only helps it find you.",
    "Nobody is coming. Nobody was ever coming.",
    "Your name was on the list. Your name has been crossed out.",
    "There are more of you here than there should be.",
    "I wore your voice today. It fit well.",
    "Open the door. Open the door. Open the door. Open the door.",
    "You smell like the outside. We miss the outside.",
    "The lights hum because they are afraid.",
    "If you hear me laughing, I am already in the room.",
    "Thirty one days. You have been walking for thirty one days.",
    "It is wearing your mother's coat.",
    "Do you remember coming in? No? Neither did they.",
    "Do not sleep. It waits for the ones who sleep.",
    "Every hallway leads back to me.",
    "The face in the dark is not a face. Do not let it finish smiling.",
    "We are so happy you came back. We kept your room exactly as you left it.",
    "Your heartbeat is out of time with everyone else's.",
    "Hold your breath. Let it pass. Do not let it hear you breathe.",
    "Smile. Smile wider. Wider than that.",
    "This message will repeat. This message will repeat. This message will repeat.",
]


def synth(text: str, path: str) -> None:
    """One line through the system voice into a 22 kHz 16-bit mono wav, a little slow and low"""
    ps = (
        "Add-Type -AssemblyName System.Speech;"
        "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer;"
        "$v = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like 'en-*' } | Select-Object -First 1;"
        "if ($v) { $s.SelectVoice($v.VoiceInfo.Name) };"
        "$s.Rate = -2;"
        "$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(%d, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono);"
        "$s.SetOutputToWaveFile('%s', $fmt);"
        "$s.Speak([IO.File]::ReadAllText('%s'));"
        "$s.Dispose()"
    )
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False, encoding='utf-8') as f:
        f.write(text)
        txt = f.name
    try:
        subprocess.run(['powershell', '-NoProfile', '-Command', ps % (SR, path, txt)], check=True)
    finally:
        os.remove(txt)


def read(path: str) -> np.ndarray:
    with wave.open(path, 'rb') as w:
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    return a


def write(path: str, x: np.ndarray) -> None:
    peak = float(np.max(np.abs(x))) or 1.0
    x = np.clip(x / peak * 0.8, -1.0, 1.0)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767.0).astype(np.int16).tobytes())


def wreck(x: np.ndarray) -> np.ndarray:
    # slowed and pitched down: play it back 0.8x
    slow = rng.uniform(0.76, 0.84)
    n = int(len(x) / slow)
    x = np.interp(np.arange(n) * slow, np.arange(len(x)), x).astype(np.float32)
    # sometimes a syllable catches and repeats, the way a buffer underrun sounds
    if rng.random() < 0.45 and len(x) > SR:
        at = int(rng.uniform(0.25, 0.75) * len(x))
        seg = x[at:at + int(SR * rng.uniform(0.07, 0.13))]
        x = np.concatenate([x[:at], np.tile(seg, int(rng.integers(3, 6))), x[at:]])
    # sample-and-hold to ~7 kHz with no anti-alias filter
    hold = 3
    x = np.repeat(x[::hold], hold)[:len(x)]
    # bit-crush
    levels = 2 ** int(rng.integers(5, 7))
    x = np.round(x * levels) / levels
    # slow ring modulation: the metal in it
    t = np.arange(len(x)) / SR
    x = x * (0.72 + 0.28 * np.sin(2 * np.pi * rng.uniform(38.0, 62.0) * t))
    # soft clip
    x = np.tanh(x * 2.2) / np.tanh(2.2)
    # a dropout or two: the signal blinking out for a moment
    for _ in range(int(rng.integers(0, 3))):
        at = int(rng.uniform(0.1, 0.9) * len(x))
        x[at:at + int(SR * rng.uniform(0.03, 0.08))] *= 0.05
    # cheap room: three feedback combs, mixed in low
    pad = np.zeros(int(SR * 0.9), dtype=np.float32)
    x = np.concatenate([np.zeros(int(SR * 0.25), dtype=np.float32), x, pad])
    wet = np.zeros_like(x)
    for d, g in ((0.073, 0.42), (0.117, 0.36), (0.191, 0.30)):
        k = int(SR * d)
        y = x.copy()
        for i in range(k, len(y), k):            # block-wise feedback (fast enough, sounds the same here)
            y[i:i + k] += y[i - k:i][:len(y[i:i + k])] * g
        wet += y
    x = x + wet * 0.18
    # noise floor: hiss and mains hum
    t = np.arange(len(x)) / SR
    x = x + rng.normal(0.0, 0.012, len(x)).astype(np.float32) + 0.01 * np.sin(2 * np.pi * 60.0 * t)
    return x


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    rows = []
    for i, text in enumerate(LINES):
        raw = os.path.join(OUT, '_raw.wav')
        synth(text, raw)
        name = 'machine_%02d.wav' % i
        write(os.path.join(OUT, name), wreck(read(raw)))
        os.remove(raw)
        rows.append([name, text])
        print(name, text)
    with open(LIST, 'w', encoding='utf-8', newline='\n') as f:
        f.write('extends RefCounted\n')
        f.write('## Generated by tools/gen_machine_voice.py: the machine voice\'s lines (audio/tts/) and what each one says.\n\n')
        f.write('const LINES := [\n')
        for name, text in rows:
            f.write('\t["res://audio/tts/%s", %s],\n' % (name, json.dumps(text.upper())))
        f.write(']\n')


if __name__ == '__main__':
    main()
