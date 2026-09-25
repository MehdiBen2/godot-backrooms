extends Node
## Ambience director: decides WHICH recorded bed plays, WHEN, how loud and how dark.
##
## Tension (0..1) is read from the game every frame: the entity's fear/presence, darkness, lost
## sanity and power cuts. Each track has a tension it suits, so a calm walk gets the quiet beds and
## a hunt-in-the-dark gets the heavy ones. Beds crossfade, never repeat back to back, start part-way
## in so the long ones stay fresh, and step out of the way while the entity is actually hunting you
## (you need to hear it). Everything goes through an "Ambience" bus (high-pass + low-pass) that gets
## darker in tight corridors, at low sanity and during a blackout.
##
## Also owns a sparse layer of far-off events (muffled thumps behind walls) so the silence between
## beds is never truly empty.

const BASE := 0.1                      # AmbientSystem.BASE_VOLUME
const FADE_IN := 4.0
const FADE_OUT := 5.0
const KILL_FADE := 3.0                 # crossfade when the mood changes mid-track
const SWITCH_GAP := 45.0               # min seconds between mood switches
# tension = the mood each bed suits; gain = level trim between the recordings (tune by ear)
const TRACKS := [
	{"file": "ambient1.mp3", "tension": 0.15, "gain": 1.0},
	{"file": "mleckert82-spooky-ambience-212885.mp3", "tension": 0.3, "gain": 1.0},
	{"file": "dragon-studio-dark-horror-ambient-05-425468.mp3", "tension": 0.5, "gain": 1.0},
	{"file": "universfield-creepy-tension-background-30-352872.mp3", "tension": 0.7, "gain": 1.0},
	{"file": "universfield-horror-background-atmosphere-09-219111.mp3", "tension": 0.9, "gain": 1.0},
]

var audio: Node
var player: Node
var lp: AudioEffectLowPassFilter
var voices: Array = []                 # {p, idx, t, left, gain, dying, dying_t}
var streams := {}
var recent: Array[int] = []
var rng := RandomNumberGenerator.new()

var tension := 0.0
var duck := 1.0
var cutoff := 12000.0
var lfo := 0.0
var gap_timer := 10.0
var switch_cd := 0.0
var event_timer := 30.0

func _ready() -> void:
	rng.randomize()
	audio = get_parent()
	player = audio.player
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, "Ambience")
	AudioServer.set_bus_send(idx, "World")
	var hp := AudioEffectHighPassFilter.new()
	hp.cutoff_hz = 70.0                # keep MP3 rumble out of the drone's sub-bass
	AudioServer.add_bus_effect(idx, hp)
	lp = AudioEffectLowPassFilter.new()
	lp.cutoff_hz = cutoff
	AudioServer.add_bus_effect(idx, lp)
	gap_timer = 8.0 + rng.randf() * 8.0

# ---------------------------------------------------------------- mood
func _target_tension() -> float:
	var dark := 1.0 - clampf(player.light_level / 0.5, 0.0, 1.0)
	var t := maxf(Game.fear, Game.presence * 0.8)
	t = maxf(t, dark * 0.5)
	t = maxf(t, (1.0 - player.sanity / 100.0) * 0.8)
	if player.grid_down:
		t = maxf(t, 0.7)
	return clampf(t, 0.0, 1.0)

func _stream(i: int) -> AudioStreamMP3:
	if not streams.has(i):
		var path: String = "res://audio/ambients/" + TRACKS[i].file
		streams[i] = load(path) if ResourceLoader.exists(path) else null    # null until Godot has imported it
	return streams[i]

# Weighted pick: tracks whose mood matches now, never the one just played, never one already up
func _pick() -> int:
	var live: Array[int] = []
	for v in voices:
		live.append(v.idx)
	var best := -1
	var total := 0.0
	var weights := {}
	for i in TRACKS.size():
		if live.has(i) or _stream(i) == null:
			continue
		var d: float = (tension - TRACKS[i].tension) / 0.28
		var w := exp(-d * d) + 0.03
		if recent.has(i):
			w *= 0.05
		weights[i] = w
		total += w
	if total <= 0.0:
		return best
	var r := rng.randf() * total
	for i in weights:
		r -= weights[i]
		best = i
		if r <= 0.0:
			break
	return best

func _start(i: int) -> void:
	var s := _stream(i)
	if s == null:
		return
	for v in voices:
		if not v.dying:
			v.dying = true
			v.dying_t = 0.0
	var len := s.get_length()
	# the long beds join part-way through, so the same track never sounds like the same track
	var from := rng.randf() * len * 0.5 if (len > 60.0 and rng.randf() < 0.6) else 0.0
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.bus = "Ambience"
	p.volume_linear = 0.0
	add_child(p)
	p.play(from)
	voices.append({"p": p, "idx": i, "t": 0.0, "left": len - from, "gain": TRACKS[i].gain, "dying": false, "dying_t": 0.0})
	recent.append(i)
	if recent.size() > 2:
		recent.pop_front()
	switch_cd = SWITCH_GAP

func _schedule(dt: float) -> void:
	switch_cd = maxf(0.0, switch_cd - dt)
	var current = null
	for v in voices:
		if not v.dying:
			current = v
	if current == null:
		gap_timer -= dt
		if gap_timer <= 0.0:
			var i := _pick()
			if i >= 0:
				_start(i)
			gap_timer = 20.0                       # nothing importable yet: try again shortly
		return
	# the mood has moved on from what is playing: crossfade to a better fit
	if current.t > 20.0 and switch_cd <= 0.0 and absf(tension - TRACKS[current.idx].tension) > 0.45:
		var i := _pick()
		if i >= 0:
			_start(i)

# ---------------------------------------------------------------- playback
func _update_voices(dt: float) -> void:
	var duck_target := 0.35 if Game.hunted else 1.0        # make room for the entity's feet and voice
	duck += (duck_target - duck) * (1.0 - exp(-dt / (0.6 if duck_target < duck else 3.0)))
	var mood := 0.55 + 0.9 * tension
	var pitch: float = 1.0 - 0.05 * (1.0 - player.sanity / 100.0)   # the bed sags out of tune as you lose it
	var strongest := 0.0
	var i := voices.size() - 1
	while i >= 0:
		var v: Dictionary = voices[i]
		var p: AudioStreamPlayer = v.p
		v.t += dt
		var fade := minf(1.0, v.t / FADE_IN)
		fade = minf(fade, maxf(0.0, (v.left - v.t) / FADE_OUT))
		if v.dying:
			v.dying_t += dt
			fade = minf(fade, maxf(0.0, 1.0 - v.dying_t / KILL_FADE))
		if fade <= 0.0 and v.t > 0.5 or not p.playing:
			p.queue_free()
			voices.remove_at(i)
			if voices.is_empty():
				gap_timer = (60.0 + rng.randf() * 60.0) * (1.0 - 0.6 * tension)
		else:
			p.volume_linear = fade * v.gain * BASE * mood * duck * audio.vol.ambient * audio.vol.master
			p.pitch_scale = pitch
			strongest = maxf(strongest, fade)
		i -= 1
	audio.hum_user_target = 1.0 - 0.7 * strongest         # the synthesized hum sinks under a recorded bed

# Darker in tight corridors, at low sanity and in a blackout; a slow swell keeps it from sitting still
func _update_filter(dt: float) -> void:
	lfo += dt
	var open := clampf((audio.room_size - 0.15) / 0.6, 0.0, 1.0)
	var target := lerpf(3500.0, 15000.0, open)
	var calm: float = 1.0 - clampf(Game.presence * 1.5, 0.0, 1.0)    # a chase drains sanity fast: don't muffle it
	target *= lerpf(1.0, 0.45, (1.0 - player.sanity / 100.0) * calm)
	target *= 1.0 + 0.12 * sin(lfo * 0.35)
	if player.grid_down:
		target = minf(target, 1400.0)
	if Game.hunted:
		target = maxf(target, 7000.0)
	cutoff += (target - cutoff) * (1.0 - exp(-dt / 1.0))
	if absf(lp.cutoff_hz - cutoff) > 20.0:                # only when it moves: re-setting resets the filter
		lp.cutoff_hz = cutoff

# ---------------------------------------------------------------- far-off events
func _update_events(dt: float) -> void:
	event_timer -= dt
	if event_timer > 0.0:
		return
	event_timer = (30.0 + rng.randf() * 50.0) * (1.0 - 0.5 * tension)
	if Game.hunted or audio.paused or not Game.playing or player.dead:
		return
	var nav = audio._grid()
	if nav == null:
		return
	var pp: Vector3 = player.global_position
	for tries in 12:
		var a := rng.randf() * TAU
		var d := 22.0 + rng.randf() * 23.0
		var x := pp.x + sin(a) * d
		var z := pp.z + cos(a) * d
		if not nav.open_at(x, z):
			continue
		var scares := audio.get_parent().get_node("Scares")
		var n := 1 + rng.randi() % 3
		for k in n:
			var at := Vector3(x, pp.y + 0.2, z)
			get_tree().create_timer(k * (0.4 + rng.randf() * 0.15)).timeout.connect(func():
				scares.play_scare("footThump", at, 0.5))
		return

func _process(dt: float) -> void:
	tension += (_target_tension() - tension) * (1.0 - exp(-dt / 2.5))
	_update_filter(dt)
	_schedule(dt)
	_update_voices(dt)
	_update_events(dt)
