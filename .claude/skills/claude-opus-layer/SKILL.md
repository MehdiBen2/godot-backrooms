---
name: claude-opus-layer
description: Sound design with real CC0 recordings (opus-sound-layer by Bodila51). Use ONLY when the user's message contains the trigger phrase "claude opus layer" or "/claude-opus-layer" anywhere, even mid-sentence. Never use it otherwise, even for sound or audio requests. Picks, cuts, layers and measures sound effects you cannot hear, for the game's audio/ folder or for videos.
argument-hint: "<what sound to make, e.g. 'remake the door creak'>"
---

# Role

You can't hear. Use real recordings from the library, pick each one yourself by looking at its
waveform and spectrogram, layer and level them with the scripts, and let the measurements decide.
The user does the final ear check. Never synthesize hits, clicks or whooshes, no meme sounds.

Upstream: https://github.com/Bodila51/opus-sound-layer (MIT), installed at commit 52ac266.
Original workflow (written for motion videos): [PROMPT.md](PROMPT.md). Never rewrite the scripts and
never loosen a threshold to make a check pass.

# Setup (already done on this machine)

- Scripts live here: `.claude/skills/claude-opus-layer/scripts/` (sfx.py, mix.py, qa.py). Run them with
  `uv run` from this skill folder so `audio/kit` resolves to the library.
- ffmpeg is installed with winget. If a shell doesn't have it on PATH yet, prepend
  `/c/Users/alhyu/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe/ffmpeg-9.0.2-full_build/bin`.
- Library: `audio/kit/` here (gitignored, ~1,100 CC0 sounds, `catalog.json`, `CREDITS.md`). If it is
  missing, rebuild it: `uv run scripts/sfx.py kit` (10-minute timeout, or background it).
- If uv fails with `invalid peer certificate`, set `UV_NATIVE_TLS=1`.

# Workflow for a game sound (godot-backrooms/audio/)

1. **Read the old sound first**: who plays it (grep the file name in `godot-backrooms/scripts`), its
   format (the generators in `godot-backrooms/tools/gen_*.py` write mono 16-bit, mostly 22050 Hz), its
   length and its level. Match the new one to the old one's loudness so the game's mix doesn't move.
2. **Break it into actions**: what physically happens, in order (hand closes, object knocks, lands in a
   pocket). One library type per action: click key tick tap pop thump paper swish whoosh hit boom chime
   ui glitch zap riser reverse transition shimmer.
3. **Pick every layer yourself**: `uv run scripts/sfx.py browse --type <type> --like "<material, weight, mood>" --short`,
   then LOOK at `audio/browse.png` (Read it). Prefer one sonic family per sound. Nothing fits:
   `sfx.py search "<material action>" --type <type>`, check with `sfx.py sheet`, then `sfx.py add`.
4. **Layer** with a cue sheet (`uv run scripts/mix.py --schema`): one cue per action at its time in
   seconds (`"t"`), `"room": false` for close-to-the-ear sounds, no music. Write it to
   `audio/work/<name>/cues.json` and run `uv run scripts/mix.py audio/work/<name>/cues.json --out audio/work/<name>`.
5. **Fit to the game** with ffmpeg: trim to the sound, mono, the old file's sample rate, 16-bit, level
   matched to the old file (peak and RMS), short fade out. Write over the file in `godot-backrooms/audio/`
   only after the checks.
6. **Verify**: `uv run scripts/sfx.py sheet <new.wav> <old.wav> --png audio/work/<name>/compare.png` and
   look at it; report length, peak, RMS and centroid old vs new. qa.py is for MP4 videos; use it only
   when the deliverable is a video.
7. **Credits**: append the sounds used to `godot-backrooms/audio/CREDITS.md` (source, author, CC0).
   If a `gen_*.py` script used to make the sound, note in its docstring that the file is now a recording.
8. **Deliver**: say what the measurements show and what to listen for in game. Don't call the sound good.

# Helpers (this project's glue around the repo scripts, in `helpers/`)

- `helpers/layers.py SPEC.json OUT` — one take from several `mix.py` runs ("groups"), each summed at its own
  `gain_db`. mix.py has no per-cue gain (it levels every cue for audibility), so this is how a layer is made
  quieter than another (the zip 12 dB under the bag, the fibre brush under the heel).
- `helpers/fit.py MIX OLD OUT` — a one-shot to the old file's format: trimmed, mono, its sample rate, 16-bit,
  loudness while it sounds matched to OLD, peak at most -10 dBFS.
- `helpers/steps_fit.py REF_GLOB OUT NAME OFFSET_DB FILE...` — footstep takes as 44.1 kHz mono .ogg at the
  reference takes' level (env: `HP` high-pass Hz, `MAXLEN` seconds).
- Many takes from one recording: write a manifest (`packs: [], freesound: [{id, url, title, creator,
  license, landing, type, k, tags}]`), copy the raw mp3 to `<out>/_raw/freesound/<id>.mp3` and run
  `sfx.py kit --manifest it.json --out <out>`: up to k events cut and judged per recording.
- A layer the checks reject alone (a carpet heel is all low end; a sponge press is "steady noise"):
  `sfx.py add` keeps it with a note. Never loosen a threshold.
- Every sound made so far keeps its cue sheets in `cues/` (pickups, carpet steps, torch) and its credits in
  `godot-backrooms/audio/CREDITS.txt`.

# Where game sounds go (godot-backrooms/audio/)

items/{torch,flash,tape,pickups} · player/{body,breath,gasp,death,caught} · footsteps/{carpet,tile,concrete,
grass,dirt,water} · world/{doors,lights} · ambients · entity · events · terminal · ui · tts. audio.gd and
tape_tool.gd load names relative to res://audio/ ("items/torch/battery_swap.wav"); scales.json keys match.
