extends Node
## Port of the web game's audio engine (js/audio/*.js) to Godot.
##
## Bus layout mirrors core.js:
##   World  = worldTrim (x0.5) + lowpass 16 kHz (750 Hz while paused, 260 Hz blacked out) + small
##            absorptive-room reverb  <- hum, drone, ambience, one-shots
##   Body   = x0.7, never muffled     <- your own breathing, jump, landing
##   Steps  = lowpass per footstep    <- recorded carpet footfalls, straight to master
##   Master = limiter (-10 dB, 6:1)
##
## The synthesized sounds (ballast hum, breaths, clicks, pops, drone) are pre-rendered from the
## same filter chains by tools/gen_audio.py; audio/scales.json holds the level each file was
## stored at, so playback gain here = the web game's gain.

const HUM_VOLUME := 0.1              # AUDIO.humVolume
const HUM_HABITUATED := 0.45         # AUDIO.humHabituatedLevel
const HUM_HABIT_TIME := 14.0         # AUDIO.humHabituationTime
const BREATH_VOLUME := 0.75          # AUDIO.breathVolume
const CALM_BREATH := 0.0             # AUDIO.calmBreathVolume
const AMBIENT_BASE := 0.1            # AmbientSystem.BASE_VOLUME
const SLOT_GAIN := 0.3               # per-fixture hum voice gain
const BREATH_DURS := [0.22, 0.34, 0.5, 0.7, 0.9, 1.3, 1.6]
const BREATH_MOUTH := [0.0, 0.6, 1.0]

var level: Node
var player: Node
var ui: Node

var scales := {}
var streams := {}
var vol := {"master": 1.0, "footsteps": 1.0, "hum": 1.0, "breathing": 1.0, "ambient": 1.0}

# --- buses
var world_idx := 0
var body_idx := 0
var steps_idx := 0
var world_lp: AudioEffectLowPassFilter
var steps_lp: AudioEffectLowPassFilter
var world_cutoff := 16000.0
var world_cutoff_target := 16000.0
var paused := false
var pops_enabled := true

# --- hum
var voices: Array[AudioStreamPlayer3D] = []
var voice_gain: Array[float] = []
var diffuse: AudioStreamPlayer
var drone: AudioStreamPlayer
var hum_attention := 1.0
var hum_mix := 0.0
var hum_user := 1.0
var hum_user_target := 1.0

# --- ambience
var ambient_player: AudioStreamPlayer
var ambient_timer := 0.0
var ambient_state := "idle"      # idle | in | play | out
var ambient_t := 0.0
var ambient_len := 0.0
const AMBIENT_FADE_IN := 3.0
const AMBIENT_FADE_OUT := 4.0

# --- breathing model (breathing.js)
var breath_pool: Array[AudioStreamPlayer] = []
var queue: Array = []
var b_drive := 0.0
var b_debt := 0.0
var b_exertion := 0.0
var b_anxiety := 0.0
var b_terror := 0.0
var b_loudness := 0.0
var b_next := 0.0
var b_last := -1e9
var b_last_jitter := 1.0
var b_busy_until := 0.0
var b_holding := false
var b_hold_time := 0.0
var b_hold_cd := 0.0
var b_calm_time := 10.0
var b_sigh_timer := 20.0
var b_was_exhausted := false

var one_shots: Array[AudioStreamPlayer] = []

func now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _ready() -> void:
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	ui = get_parent().get_node("UI")
	scales = JSON.parse_string(FileAccess.get_file_as_string("res://audio/scales.json"))
	_setup_buses()
	_setup_hum()
	_setup_breathing()
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		one_shots.append(p)
	level.fixture_event.connect(_on_fixture_event)
	level.slot_assigned.connect(func(_i): hum_notice(0.12))   # walking under a new light draws the ear back
	player.jumped.connect(_on_jump)
	player.landed.connect(_on_land)
	player.battery_died.connect(func(): _play_world("battery_dead.wav"))
	player.dead_click.connect(func(): _play_world("battery_dead_click.wav"))
	player.contact_click.connect(func(off: bool): _play_world("flash_click_off.wav" if off else "flash_click_on.wav"))
	ambient_timer = 20.0 + randf() * 20.0
	ambient_player = AudioStreamPlayer.new()
	ambient_player.bus = "World"
	ambient_player.volume_linear = 0.0
	add_child(ambient_player)

# ---------------------------------------------------------------- buses
func _setup_buses() -> void:
	var master := AudioServer.get_bus_index("Master")
	var comp := AudioEffectCompressor.new()
	comp.threshold = -10.0
	comp.ratio = 6.0
	comp.attack_us = 4000.0
	comp.release_ms = 200.0
	AudioServer.add_bus_effect(master, comp)

	for n in ["World", "Body", "Steps"]:
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, n)
		AudioServer.set_bus_send(idx, "Master")
	world_idx = AudioServer.get_bus_index("World")
	body_idx = AudioServer.get_bus_index("Body")
	steps_idx = AudioServer.get_bus_index("Steps")

	# World: small absorptive room (dropped ceiling + damp carpet = short dark tail), then the muffle filter
	var rev := AudioEffectReverb.new()
	rev.room_size = 0.35
	rev.damping = 0.75
	rev.spread = 1.0
	rev.hipass = 0.0
	rev.dry = 1.0
	rev.wet = 0.14
	AudioServer.add_bus_effect(world_idx, rev)
	world_lp = AudioEffectLowPassFilter.new()
	world_lp.cutoff_hz = 16000.0
	AudioServer.add_bus_effect(world_idx, world_lp)
	AudioServer.set_bus_volume_linear(world_idx, 0.5)          # worldTrim
	AudioServer.set_bus_volume_linear(body_idx, 0.7)
	steps_lp = AudioEffectLowPassFilter.new()
	steps_lp.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(steps_idx, steps_lp)

func stream(name: String) -> AudioStreamWAV:
	if not streams.has(name):
		streams[name] = load("res://audio/" + name)
	return streams[name]

func loop_stream(name: String) -> AudioStreamWAV:
	# Looping is set in the .import files (edit/loop_mode=Forward, uncompressed). Never compute
	# loop points from data.size(): with compressed imports that cut the loop mid-file and ticked.
	return stream(name)

# ---------------------------------------------------------------- hum
func _setup_hum() -> void:
	for i in level.POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.stream = loop_stream("hum_voice.wav")
		p.bus = "World"
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.unit_size = 1.6
		p.max_distance = 40.0
		p.volume_db = -80.0
		add_child(p)
		p.play(randf() * 15.0)          # decorrelated, like the per-voice delay lines
		voices.append(p)
		voice_gain.append(0.0)
	diffuse = AudioStreamPlayer.new()
	diffuse.stream = loop_stream("hum_diffuse.wav")
	diffuse.bus = "World"
	diffuse.volume_db = -80.0
	add_child(diffuse)
	diffuse.play()
	drone = AudioStreamPlayer.new()
	drone.stream = loop_stream("drone.wav")
	drone.bus = "World"
	drone.volume_linear = 0.2 / float(scales.get("drone.wav", 1.0))     # sub-bass dread drone (fear swells it)
	add_child(drone)
	drone.play()

func hum_notice(amount := 0.3) -> void:
	hum_attention = minf(1.0, hum_attention + amount)

func _update_hum(dt: float) -> void:
	# HumDirector: habituation, masking by breathing, dread, menu dimming
	hum_attention += (HUM_HABITUATED - hum_attention) * minf(1.0, dt / HUM_HABIT_TIME)
	var masking := 1.0 - 0.55 * b_loudness - (0.2 if player.is_sprinting else 0.0)
	var dread := 1.0            # fear 0 until the entity exists
	var menu := 0.4 if paused else 1.0
	var target := maxf(0.0, hum_attention * masking * dread * menu)
	hum_mix += (target - hum_mix) * (1.0 - exp(-dt / 0.35))
	hum_user += (hum_user_target - hum_user) * (1.0 - exp(-dt / 1.5))
	var mix: float = hum_mix * HUM_VOLUME * hum_user * vol.hum
	var comp := 1.0 / float(scales["hum_voice.wav"])
	for i in voices.size():
		var lvl: float = level.slot_level(i)
		var p := voices[i]
		if lvl > 0.004: p.global_position = level.slot_position(i)
		# inverse-distance falloff: Godot's model is half the web panner's at the reference distance
		var want := lvl * SLOT_GAIN * mix * comp * 2.0
		voice_gain[i] += (want - voice_gain[i]) * (1.0 - exp(-dt / 0.03))
		p.volume_linear = voice_gain[i]
	diffuse.volume_linear = mix / float(scales["hum_diffuse.wav"])

# ---------------------------------------------------------------- tube pops
func _on_fixture_event(f: Dictionary, restrike: bool) -> void:
	if not pops_enabled or f.slot < 0 or not (restrike or randf() < 0.5): return
	var name := "tube_restrike.wav" if restrike else "tube_drop.wav"
	var p := AudioStreamPlayer3D.new()
	p.stream = stream(name)
	p.bus = "World"
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.unit_size = 1.6
	p.max_distance = 40.0
	p.volume_linear = hum_mix * HUM_VOLUME * hum_user * 2.0 * 1.0
	add_child(p)
	p.global_position = f.light_pos
	p.finished.connect(p.queue_free)
	p.play()
	hum_notice(0.15 if restrike else 0.25)

# ---------------------------------------------------------------- one-shots
func _play(name: String, bus: String, linear: float, pitch := 1.0) -> void:
	for p in one_shots:
		if not p.playing:
			p.stream = stream(name)
			p.bus = bus
			p.volume_linear = linear / float(scales.get(name, 1.0))
			p.pitch_scale = pitch
			p.play()
			return

func _play_world(name: String) -> void:
	_play(name, "World", 1.0)

func _on_jump() -> void:
	_play("jump.wav", "Body", 1.0)

func _on_land(strength: float) -> void:
	var s := minf(1.0, 0.4 + strength * 0.6)
	_play("land_thud.wav", "Body", s)

# ---------------------------------------------------------------- ambience (AmbientSystem)
func _update_ambient(dt: float) -> void:
	match ambient_state:
		"idle":
			ambient_timer -= dt
			if ambient_timer <= 0.0:
				var m: AudioStreamMP3 = load("res://audio/ambient1.mp3")
				m.loop = false
				ambient_player.stream = m
				ambient_len = m.get_length()
				ambient_player.volume_linear = 0.0
				ambient_player.play()
				ambient_state = "in"
				ambient_t = 0.0
				hum_user_target = 0.3           # the synthesized hum sinks under the recorded track
		"in", "play", "out":
			ambient_t += dt
			var fade := 1.0
			if ambient_t < AMBIENT_FADE_IN:
				fade = ambient_t / AMBIENT_FADE_IN
			var left := ambient_len - ambient_t
			if left < AMBIENT_FADE_OUT:
				fade = minf(fade, maxf(0.0, left / AMBIENT_FADE_OUT))
			ambient_player.volume_linear = fade * AMBIENT_BASE * vol.ambient * vol.master
			if left <= 0.0 or not ambient_player.playing:
				ambient_player.stop()
				ambient_state = "idle"
				ambient_timer = 90.0 + randf() * 90.0
				hum_user_target = 1.0

# ---------------------------------------------------------------- pause / muffle
func set_paused(on: bool) -> void:
	paused = on
	world_cutoff_target = 750.0 if on else 16000.0
	if not on: hum_notice(0.4)

# ---------------------------------------------------------------- breathing (BreathingSystem)
func _setup_breathing() -> void:
	for i in 8:
		var p := AudioStreamPlayer.new()
		p.bus = "Body"
		add_child(p)
		breath_pool.append(p)

func clamp01(v: float) -> float:
	return clampf(v, 0.0, 1.0)

func smooth(a: float, b: float, v: float) -> float:
	var t := clamp01((v - a) / (b - a))
	return t * t * (3.0 - 2.0 * t)

func _approach(cur: float, target: float, up: float, down: float, dt: float) -> float:
	return cur + (target - cur) * minf(1.0, dt * (up if target > cur else down))

func _update_breathing(dt: float) -> void:
	var sprinting: bool = player.is_sprinting
	var exhausted: bool = player.exhausted
	var moving: bool = player.is_moving
	var crouching: bool = player.is_crouching
	var terror := 0.0
	var anxiety: float = 1.0 - player.sanity / 100.0

	b_drive = _approach(b_drive, 1.0 if sprinting else 0.0, 2.5, 0.6, dt)
	var stamina_debt: float = 1.0 if exhausted else 1.0 - player.stamina / 100.0
	b_debt = _approach(b_debt, stamina_debt, 1.2, 0.09, dt)
	var e := clamp01(0.3 * b_drive + 0.8 * b_debt)
	if moving: e = maxf(e, 0.05)
	b_exertion = e

	var raw_terror := clamp01(terror)
	b_terror = _approach(b_terror, raw_terror, 4.0, 1.2, dt)
	b_anxiety = _approach(b_anxiety, clamp01(anxiety), 0.5, 0.25, dt)

	if b_was_exhausted and not exhausted: sigh()
	b_was_exhausted = exhausted

	# startle: entity first comes into range after a quiet spell
	if raw_terror <= 0.0: b_calm_time += dt
	else:
		if b_calm_time > 6.0: gasp(0.75)
		b_calm_time = 0.0
	# freeze response
	b_hold_cd = maxf(0.0, b_hold_cd - dt)
	var still := (not moving) or crouching
	if not b_holding:
		if b_terror > 0.45 and still and not sprinting and b_exertion < 0.6 and b_hold_cd == 0.0:
			b_holding = true
			b_hold_time = (4.0 if crouching else 2.5) + randf() * 2.5
	else:
		b_hold_time -= dt
		if sprinting:
			b_holding = false; b_hold_cd = 5.0; gasp(0.7)
		elif b_terror < 0.25:
			b_holding = false; b_hold_cd = 5.0; sigh(0.5, 0.5)
		elif b_hold_time <= 0.0:
			b_holding = false; b_hold_cd = 7.0; gasp(0.85)
	# spontaneous sighs
	b_sigh_timer -= dt
	if b_sigh_timer <= 0.0:
		var a := _arousal()
		b_sigh_timer = (40.0 - 25.0 * a) * (0.7 + randf() * 0.6)
		if a > 0.2 and b_exertion < 0.45 and not b_holding: sigh(0.3 + 0.2 * a, a)

	var arousal := _arousal()
	var active := e > 0.08 or arousal > 0.15
	var loud := clamp01(smooth(0.08, 1.0, e) * 0.9 + arousal * 0.35) if active else CALM_BREATH
	if b_holding: loud = 0.0
	b_loudness = loud
	_schedule(loud)

func _arousal() -> float:
	return maxf(b_terror, b_anxiety * 0.55)

func _schedule(loud: float) -> void:
	var t_now := now()
	if b_next < t_now: b_next = t_now + 0.05
	if b_holding:
		b_next = maxf(t_now + 0.3, b_busy_until + 0.08)
		return
	if loud <= 0.01:
		b_next = maxf(t_now + 0.1, b_busy_until + 0.08)
		return
	var e := b_exertion
	var a := _arousal()
	var t0 := b_terror
	var bpm := 13.0 + 32.0 * e + 14.0 * a * (1.0 - e)
	var period := 60.0 / bpm
	var due := b_last + period * b_last_jitter
	b_next = maxf(t_now + 0.05, maxf(b_busy_until + 0.08, minf(b_next, due)))
	while b_next < t_now + 0.12:
		var t := b_next
		var spread := 0.06 + 0.22 * a * (1.0 - e)
		var jitter := 1.0 + (randf() * 2.0 - 1.0) * spread
		var inhale := period * (0.3 + 0.15 * e + 0.05 * a) * jitter
		var exhale := period * (0.45 + 0.07 * e - 0.05 * a) * jitter
		var mouth := smooth(0.3, 0.65, maxf(e, t0 * 0.8))
		var shake := maxf(smooth(0.3, 0.8, t0) * 0.6, smooth(0.5, 1.0, b_anxiety) * 0.25)
		var depth := (1.0 - 0.25 * a * (1.0 - e)) * (0.9 + randf() * 0.2)
		var ragged := smooth(0.8, 1.0, e)
		if randf() < ragged * 0.35:
			_phase(t, inhale * 0.45, true, loud * 0.7 * depth, mouth, shake)
			_phase(t + inhale * 0.55, inhale * 0.45, true, loud * 0.8 * depth, mouth, shake)
		else:
			_phase(t, inhale, true, loud * 0.7 * depth, mouth, shake)
		_phase(t + inhale + 0.03, exhale, false, loud * depth, mouth, shake, smooth(0.75, 1.0, e))
		b_last = t
		b_last_jitter = jitter
		b_busy_until = t + inhale + 0.03 + exhale
		b_next = t + period * jitter

func gasp(strength := 1.0) -> void:
	var t := now() + 0.01
	_phase(t, 0.34, true, strength, 1.0, 0.25)
	_phase(t + 0.4, 0.7, false, strength * 0.7, 0.8, 0.4)
	b_last = t + 0.4
	b_last_jitter = 1.0
	b_busy_until = t + 1.1
	b_next = t + 1.2

func sigh(strength := 0.45, shake := 0.0) -> void:
	var t := maxf(now() + 0.01, b_busy_until + 0.1)
	_phase(t, 0.8, true, strength * 0.6, 0.3, 0.1 + shake * 0.2)
	_phase(t + 0.85, 1.6, false, strength, 0.5, 0.15 + shake * 0.3)
	b_last = t + 1.3
	b_last_jitter = 1.0
	b_busy_until = t + 2.45
	b_next = t + 2.8

func _nearest(arr: Array, v: float) -> int:
	var best := 0
	for i in arr.size():
		if absf(arr[i] - v) < absf(arr[best] - v): best = i
	return best

func _phase(t: float, dur: float, inhale: bool, amp: float, mouth: float, shake: float, voiced := 0.0) -> void:
	queue.append({"t": t, "dur": dur, "inhale": inhale, "amp": amp, "mouth": mouth, "shake": shake, "voiced": voiced})

func _play_queue() -> void:
	var t_now := now()
	var i := 0
	while i < queue.size():
		var q: Dictionary = queue[i]
		if q.t > t_now:
			i += 1
			continue
		queue.remove_at(i)
		if t_now - q.t > 0.4: continue          # stale (game was paused)
		var di := _nearest(BREATH_DURS, q.dur)
		var mi := _nearest(BREATH_MOUTH, q.mouth)
		var si := 1 if q.shake > 0.2 else 0
		var file: String
		if q.inhale: file = "breath_in_%d_%d_%d.wav" % [mi, di, si]
		elif q.voiced > 0.3: file = "breath_outv_%d.wav" % di
		else: file = "breath_out_%d_%d_%d.wav" % [mi, di, si]
		var pitch := clampf(BREATH_DURS[di] / maxf(0.05, q.dur), 0.7, 1.4)
		for p in breath_pool:
			if not p.playing:
				p.stream = stream(file)
				p.volume_linear = q.amp * BREATH_VOLUME * vol.breathing / float(scales.get(file, 1.0))
				p.pitch_scale = pitch
				p.play()
				break

# ---------------------------------------------------------------- frame
func _process(dt: float) -> void:
	# world filter: menu = soft lowpass, otherwise open
	world_cutoff += (world_cutoff_target - world_cutoff) * (1.0 - exp(-dt / 0.3))
	# Only touch the filter when the cutoff actually moves: re-setting it every frame resets
	# the filter state and clicks
	if absf(world_lp.cutoff_hz - world_cutoff) > 5.0:
		world_lp.cutoff_hz = world_cutoff
	if not paused:
		_update_breathing(dt)
	_update_hum(dt)
	_update_ambient(dt)
	_play_queue()
