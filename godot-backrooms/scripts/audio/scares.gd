extends Node
const ScareSynth := preload("res://scripts/audio/scare_synth.gd")
## Scare sounds (js/audio/scares.js, scares2.js, bacteria.js). The web game builds these from
## oscillators and filtered noise at run time; here the same recipes are rendered into
## AudioStreamWAVs on first use, and positioned through AudioStreamPlayer3D.
## Also the entity's recorded voice, with the walls-between-you muffle (the "Entity" bus).

const BACTERIA_CALLS := {
	"idle": [3, 12, 14, 15, 20, 23, 24, 26, 27],
	"stalk": [14, 15, 23],
	"chase": [1, 2, 5, 6, 8, 11, 13, 16, 18, 19, 21, 22, 25, 28, 29, 30],
	"flee": [7, 10, 17],
	"hurt": [11, 19],
	"scream": [0],                         # 0 = scream.mp3
}
# volume, ref distance (m of full volume), reverb-ish send is left to the World bus
const BACTERIA_MIX := {
	"idle": [1.0, 6.0], "stalk": [0.7, 5.0], "chase": [1.3, 6.0],
	"flee": [1.1, 6.0], "hurt": [1.2, 5.0], "scream": [1.3, 8.0], "whisper": [1.0, 6.0],
}
const TARGET_RMS := 0.1
const MAX_PEAK := 0.5

var rng := RandomNumberGenerator.new()
var voice: AudioStreamPlayer3D
var voice_last := {}
var occluded := false
var entity_lp: AudioEffectLowPassFilter
var entity_cut := 20000.0
var entity_cut_target := 20000.0
var clip_gain := {}
var glitchers: Array = []                    # [player, next_toggle, base_db]
var live: Array = []                         # everything scheduled, so stop_all() can silence it
var player: Node3D
var _blood_scream_stream: AudioStream = null  # tithuh-blood-the-screaming, loaded once

func _ready() -> void:
	rng.randomize()
	player = get_parent().get_node("Player")
	_make_bus("Entity", "World")
	entity_lp = AudioEffectLowPassFilter.new()
	entity_lp.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(AudioServer.get_bus_index("Entity"), entity_lp)
	_make_bus("Scares", "World")
	_make_bus("Preacher", "World")
	voice = AudioStreamPlayer3D.new()
	voice.bus = "Entity"
	voice.max_distance = 90.0
	voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(voice)
	# Preload blood-scream sample so splat() never calls load() on the hot path
	if ResourceLoader.exists("res://audio/entity/blood_scream.mp3"):
		_blood_scream_stream = load("res://audio/entity/blood_scream.mp3")

func _make_bus(name: String, send: String) -> void:
	if AudioServer.get_bus_index(name) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, name)
	AudioServer.set_bus_send(idx, send)

func _process(dt: float) -> void:
	entity_cut += (entity_cut_target - entity_cut) * (1.0 - exp(-dt / 0.08))
	if absf(entity_lp.cutoff_hz - entity_cut) > 20.0:
		entity_lp.cutoff_hz = entity_cut
	# preacher glitch variant: the level stutters like a failing circuit
	for i in range(glitchers.size() - 1, -1, -1):
		var g: Array = glitchers[i]
		var p: AudioStreamPlayer3D = g[0]
		if not is_instance_valid(p) or not p.playing:
			glitchers.remove_at(i)
			continue
		g[1] -= dt
		if g[1] <= 0.0:
			g[1] = 0.05 + rng.randf() * 0.2
			p.volume_db = g[2] + (-40.0 if rng.randf() < 0.45 else 0.0)

# ------------------------------------------------------------------ synthesis
var _synth := ScareSynth.new()

func synth(name: String, arg := 0.0) -> AudioStreamWAV:
	return _synth.render(name, arg)

# ------------------------------------------------------------------ playback
func _spawn3d(stream: AudioStream, pos: Vector3, linear: float, bus := "Scares", ref := 5.0, pitch := 1.0) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = bus
	p.unit_size = ref
	p.max_distance = 90.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.volume_db = linear_to_db(maxf(linear, 0.0001))
	p.pitch_scale = pitch
	add_child(p)
	p.global_position = pos
	get_parent().get_node("Audio").occlude(p, true)       # walls between you and it muffle it
	p.finished.connect(p.queue_free)
	p.play()
	return p

func _spawn_flat(stream: AudioStream, linear: float, bus := "Scares", pitch := 1.0) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = bus
	p.volume_db = linear_to_db(maxf(linear, 0.0001))
	p.pitch_scale = pitch
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()
	return p

# audio.playScare(name, ...) from the web events
func play_scare(name: String, a = null, b = null) -> void:
	match name:
		"footThump":
			var vol := float(b) if b != null else 0.8
			_spawn3d(synth("thump"), a, vol * 1.6, "Scares", 4.0, rng.randf_range(0.85, 1.1))
		"vanish":
			_spawn_flat(synth("vanish"), 0.6)
		"restrike":
			_spawn_flat(load("res://audio/tube_restrike.wav"), 0.8)
		"drone":
			_spawn_flat(synth("drone", float(a) if a != null else 14.0), 0.9)
		"staticHit":
			_spawn_flat(synth("static_hit"), 0.7 * (float(a) if a != null else 1.0))

func grid_off(pos: Vector3) -> void:
	_spawn3d(load("res://audio/events/gridoff.mp3"), pos, 1.4, "Scares", 8.0)

func heartbeat(strength := 1.0) -> void:
	_spawn_flat(synth("heartbeat"), clampf(0.45 * strength, 0.05, 1.2), "Body")
	Game.beat()

func entity_static() -> void:
	_spawn_flat(synth("static"), 0.5, "Scares", rng.randf_range(0.9, 1.15))

func startle(amount := 0.5) -> void:
	_spawn_flat(synth("stinger"), clampf(amount * 1.2, 0.1, 1.2))

func splat() -> void:
	# Recorded blood + screaming sample (tithuh-blood-the-screaming-545569 from the web game)
	if _blood_scream_stream != null:
		_spawn_flat(_blood_scream_stream, 0.9, "Body")
	else:
		_spawn_flat(synth("splat"), 0.9, "Body")

var _flat_player: AudioStreamPlayer = null

# The long monitor tone of a heart that has stopped (on the Body bus: not muffled with the world)
func flatline(seconds: float) -> void:
	stop_flatline()
	_flat_player = _spawn_flat(synth("flatline", seconds), 1.0, "Body")

func stop_flatline() -> void:
	if _flat_player == null or not is_instance_valid(_flat_player):
		_flat_player = null
		return
	var p := _flat_player
	_flat_player = null
	var tw := create_tween()
	tw.tween_property(p, "volume_db", -80.0, 0.25)
	tw.tween_callback(p.queue_free)

# Dead silence: high ear ringing
func tinnitus(seconds: float) -> void:
	_spawn_flat(synth("tinnitus", seconds), 1.0, "Body")

func gasp() -> void:
	var f := "res://audio/events/freesound_community-male-gasp-%s.mp3" % ("2-103066" if rng.randf() < 0.5 else "3-82554")
	_spawn_flat(load(f), 1.6, "Body")

func stop_all() -> void:
	for c in get_children():
		if c is AudioStreamPlayer or c is AudioStreamPlayer3D:
			if c != voice:
				c.queue_free()
	glitchers.clear()

# A mannequin footfall: a wooden knock plus a muffled carpet scuff
func mannequin_step(pos: Vector3, weight := 1.0) -> void:
	_spawn3d(synth("knock"), pos, 0.9 * weight, "Scares", 4.0, rng.randf_range(0.8, 1.2))
	if rng.randf() < 0.3:
		_spawn3d(synth("creak"), pos, 0.35 * weight, "Scares", 4.0, rng.randf_range(0.9, 1.2))

# ------------------------------------------------------------------ preacher (scares2.js)
const PREACHER_NAMES := [
	"Distant Corridor Echo", "Deep Sub-Bass Alternate", "Corrupted Radio / EVP",
	"Cavernous Hallway Delay", "Glitch Tremolo & Flickering Apparatus", "Approaching Corridor Stalker",
]

func _preacher_bus(variant: int) -> void:
	var idx := AudioServer.get_bus_index("Preacher")
	while AudioServer.get_bus_effect_count(idx) > 0:
		AudioServer.remove_bus_effect(idx, 0)
	var lp := AudioEffectLowPassFilter.new()
	var hp := AudioEffectHighPassFilter.new()
	var rev := AudioEffectReverb.new()
	match variant:
		0:
			lp.cutoff_hz = 3500.0
			rev.room_size = 0.8; rev.wet = 0.5
			AudioServer.add_bus_effect(idx, lp); AudioServer.add_bus_effect(idx, rev)
		1:
			lp.cutoff_hz = 900.0
			rev.room_size = 0.6; rev.wet = 0.3
			AudioServer.add_bus_effect(idx, lp); AudioServer.add_bus_effect(idx, rev)
		2:
			hp.cutoff_hz = 600.0; lp.cutoff_hz = 3200.0
			var dist := AudioEffectDistortion.new()
			dist.mode = AudioEffectDistortion.MODE_CLIP
			dist.drive = 0.35
			AudioServer.add_bus_effect(idx, hp); AudioServer.add_bus_effect(idx, lp); AudioServer.add_bus_effect(idx, dist)
		3:
			var delay := AudioEffectDelay.new()
			delay.tap1_active = true; delay.tap1_delay_ms = 380.0; delay.tap1_level_db = -6.0
			delay.tap2_active = true; delay.tap2_delay_ms = 760.0; delay.tap2_level_db = -12.0
			rev.room_size = 1.0; rev.wet = 0.6
			AudioServer.add_bus_effect(idx, delay); AudioServer.add_bus_effect(idx, rev)
		4:
			hp.cutoff_hz = 300.0; lp.cutoff_hz = 4500.0
			AudioServer.add_bus_effect(idx, hp); AudioServer.add_bus_effect(idx, lp)
		_:
			lp.cutoff_hz = 6000.0
			rev.room_size = 0.3; rev.wet = 0.15
			AudioServer.add_bus_effect(idx, lp); AudioServer.add_bus_effect(idx, rev)

func preacher(pos: Vector3, variant: int, end_pos: Vector3, glide: float, volume := 1.0) -> void:
	_preacher_bus(variant)
	var gain := 1.5 * volume * (1.6 if variant == 1 else 1.0)
	var p := _spawn3d(load("res://audio/events/preacher.mp3"), pos, gain, "Preacher", 7.0)
	if end_pos != pos and glide > 0.0:
		create_tween().tween_property(p, "global_position", end_pos, glide)
	if variant == 4:
		glitchers.append([p, 0.1, p.volume_db])

# ------------------------------------------------------------------ the entity's voice
func _clip(n: int) -> AudioStream:
	if n == 0:
		return load("res://audio/entity/scream.mp3")
	return load("res://audio/entity/entity_%d.wav" % n)

# Gain that brings a WAV clip to the target RMS without letting its peak pass the cap
func _match_gain(s: AudioStream, key: String) -> float:
	if clip_gain.has(key):
		return clip_gain[key]
	var g := 0.6
	if s is AudioStreamWAV and (s as AudioStreamWAV).format == AudioStreamWAV.FORMAT_16_BITS:
		var d := (s as AudioStreamWAV).data
		var count := d.size() / 2
		var sum := 0.0
		var peak := 0.0
		var i := 0
		while i < count:
			var v := absf(d.decode_s16(i * 2) / 32768.0)
			sum += v * v
			peak = maxf(peak, v)
			i += 4
		var rms := sqrt(sum / maxf(1.0, count / 4.0))
		g = minf(TARGET_RMS / maxf(rms, 0.0001), MAX_PEAK / maxf(peak, 0.0001))
	clip_gain[key] = g
	return g

func voice_busy() -> bool:
	return voice.playing

# entity call of `kind` at pos; interrupt cuts off the current one. Returns false if busy.
func entity_call(kind: String, pos: Vector3, interrupt := false, volume := 1.0) -> bool:
	if not BACTERIA_CALLS.has(kind):
		return false
	if voice.playing and not interrupt:
		return false
	var list: Array = BACTERIA_CALLS[kind]
	var i := rng.randi() % list.size()
	if list.size() > 1 and i == voice_last.get(kind, -1):
		i = (i + 1) % list.size()
	voice_last[kind] = i
	var n: int = list[i]
	var s := _clip(n)
	var mix: Array = BACTERIA_MIX[kind]
	voice.stream = s
	voice.unit_size = mix[1]
	voice.global_position = pos
	voice.volume_db = linear_to_db(_match_gain(s, "%s%d" % [kind, n]) * mix[0] * volume)
	voice.pitch_scale = 1.0 if kind == "scream" else 0.9 + rng.randf() * 0.15
	voice.play()
	return true

func entity_move(pos: Vector3) -> void:
	voice.global_position = pos

# It whispers from its corner, and faintly beside your ear on its side
func entity_whisper(pos: Vector3, ear_pos: Vector3) -> bool:
	if voice.playing:
		return false
	if not entity_call("stalk", pos, false, 0.9):
		return false
	var ear := _spawn3d(voice.stream, ear_pos, 0.2, "Entity", 2.0, voice.pitch_scale)
	ear.volume_db = voice.volume_db - 10.0
	return true

func set_entity_occlusion(blocked: bool) -> void:
	occluded = blocked
	# hunting: it is running the corridors to reach you, so a wall between you is a muffle, not a mute
	entity_cut_target = (2500.0 if Game.hunted else 700.0) if blocked else 20000.0
