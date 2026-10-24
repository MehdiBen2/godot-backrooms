ui_click_1..6.wav: take 1 is the original ui_click.wav (git 5ec51b8). Takes 2-6 are made from it by
  uv run cues/ui_click/click_variants.py <orig.wav> audio/kit <out>   (from the skill folder)
(tape pitch, tail length, tone tilt, and a Kenney UI Audio switch transient 13-15 dB under), then each is leveled
with ffmpeg to the original's max momentary loudness (-22.1 LUFS), peak capped at -1.9 dBFS.
