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
##
## Proximity: the nearest live threat (the entity, an awake mannequin, a spawned mimic) pushes the bed
## louder, lower and more open the closer it gets, with fewer walls in between counting for more.
## On top of that every bed drifts on its own: slow random wanders in level and pitch, sudden swells
## and moments where the tape sags out of tune, so it never settles into something you stop hearing.

const BASE := 0.1                      # AmbientSystem.BASE_VOLUME
const FADE_IN := 4.0
const FADE_OUT := 5.0
const KILL_FADE := 3.0                 # crossfade when the mood changes mid-track
const SWITCH_GAP := 45.0               # min seconds between mood switches
const NEAR_RANGE := {"Entity": 38.0, "Mannequin": 22.0, "Mimic": 26.0}
const NEAR_BOOST := 1.8                # extra level at point-blank (x2.8 overall)
const NEAR_PITCH := 0.08               # how far the bed drops in pitch as it closes in
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
var near := 0.0                        # 0..1 smoothed closeness of the nearest threat
var near_target := 0.0
var near_timer := 0.0
var swell := 0.0                       # a sudden surge in level, decays on its own
var swell_timer := 12.0
var sag := 0.0                         # a moment where the bed drags out of tune
var sag_target := 0.0
var sag_timer := 20.0

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
	t = maxf(t, near * 0.95)
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
	voices.append({"p": p, "idx": i, "t": 0.0, "left": len - from, "gain": TRACKS[i].gain, "dying": false, "dying_t": 0.0,
		"dv": 1.0, "dv_to": 1.0, "dp": 1.0, "dp_to": 1.0, "drift_t": 0.0})
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
		gap_timer -= dt * (1.0 + 6.0 * near)
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
	var duck_target := 0.8 if Game.hunted else 1.0         # a little room for the entity's feet and voice
	if player.dead:
		duck_target = 0.0                                    # dead: the beds (their wind and air) drain away
	duck += (duck_target - duck) * (1.0 - exp(-dt / (0.6 if duck_target < duck else 3.0)))
	var mood := (0.55 + 0.9 * tension) * (1.0 + NEAR_BOOST * near * near) * (1.0 + swell)
	var pitch: float = 1.0 - 0.05 * (1.0 - player.sanity / 100.0)   # the bed sags out of tune as you lose it
	pitch *= (1.0 - NEAR_PITCH * near) * (1.0 - sag)
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
				gap_timer = (8.0 + rng.randf() * 18.0) * (1.0 - 0.6 * tension)
		else:
			_drift(v, dt)
			p.volume_linear = fade * v.gain * v.dv * BASE * mood * duck * audio.vol.ambient * audio.vol.master
			p.pitch_scale = maxf(0.5, pitch * v.dp)
			strongest = maxf(strongest, fade)
		i -= 1
	audio.hum_user_target = 1.0 - 0.7 * strongest         # the synthesized hum sinks under a recorded bed

# Each bed wanders on its own: a new level / pitch goal every few seconds, eased into slowly
func _drift(v: Dictionary, dt: float) -> void:
	v.drift_t -= dt
	if v.drift_t <= 0.0:
		v.drift_t = 3.0 + rng.randf() * 6.0
		v.dv_to = rng.randf_range(0.55, 1.3)
		v.dp_to = rng.randf_range(0.94, 1.03) if rng.randf() < 0.8 else rng.randf_range(0.86, 0.94)
	var k := 1.0 - exp(-dt / 2.5)
	v.dv += (v.dv_to - v.dv) * k
	v.dp += (v.dp_to - v.dp) * k

# Sudden swells and pitch sags; both come more often the closer something is
func _update_moods(dt: float) -> void:
	swell_timer -= dt * (1.0 + 3.0 * near)
	if swell_timer <= 0.0:
		swell_timer = 10.0 + rng.randf() * 25.0
		swell = maxf(swell, rng.randf_range(0.4, 1.0) * (1.0 + near))
	swell *= exp(-dt / 1.8)
	sag_timer -= dt * (1.0 + 2.0 * near + 1.5 * tension)
	if sag_timer <= 0.0:
		sag_timer = 15.0 + rng.randf() * 30.0
		sag_target = rng.randf_range(0.04, 0.12)
	sag += (sag_target - sag) * (1.0 - exp(-dt / (1.2 if sag_target > sag else 3.0)))
	if sag_target > 0.0 and absf(sag - sag_target) < 0.005:
		sag_target = 0.0                     # hit the bottom: drift back into tune

# Nearest live threat, 0..1, cheaper walls-between check a few times a second
func _update_near(dt: float) -> void:
	near_timer -= dt
	if near_timer <= 0.0:
		near_timer = 0.2
		near_target = 0.0
		var root := get_tree().current_scene
		if root != null and not player.dead and Game.playing:
			var pp: Vector3 = player.global_position
			for key in NEAR_RANGE:
				var at = _threat_pos(root.get_node_or_null(key))
				if at == null:
					continue
				var d := pp.distance_to(at)
				var n := clampf(1.0 - d / NEAR_RANGE[key], 0.0, 1.0)
				if n > 0.0:
					n *= pow(0.75, mini(audio.walls_between(pp, at), 3))
				near_target = maxf(near_target, n)
	near += (near_target - near) * (1.0 - exp(-dt / (0.8 if near_target > near else 3.0)))

func _threat_pos(n: Node):
	if n == null:
		return null
	if n.name == "Mannequin":
		return n.real_node.global_position if n.awake and n.real_node != null else null
	if n.name == "Mimic":
		return n.body.global_position if n.spawned and n.body != null else null
	return n.global_position

# Darker in tight corridors, at low sanity and in a blackout; a slow swell keeps it from sitting still
func _update_filter(dt: float) -> void:
	lfo += dt
	var open := clampf((audio.room_size - 0.15) / 0.6, 0.0, 1.0)
	var target := lerpf(3500.0, 15000.0, open)
	var calm: float = 1.0 - clampf(Game.presence * 1.5, 0.0, 1.0)    # a chase drains sanity fast: don't muffle it
	target *= lerpf(1.0, 0.45, (1.0 - player.sanity / 100.0) * calm)
	target *= 1.0 + 0.12 * sin(lfo * 0.35)
	target = lerpf(target, maxf(target, 9000.0), near)     # it opens up as the thing closes in
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
	_update_near(dt)
	_update_moods(dt)
	tension += (_target_tension() - tension) * (1.0 - exp(-dt / 2.5))
	_update_filter(dt)
	_schedule(dt)
	_update_voices(dt)
	_update_events(dt)
