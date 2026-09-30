extends Node
## THE BACTERIA's voice (js/audio/bacteria.js): its recorded calls, one at a time, positioned on it and
## muffled on the "Entity" bus when walls stand between you. And its breathing: a wet, growling rasp,
## looped on its body, that you hear round a corner before you see it. bacteria.gd drives both every
## frame. Child of Scares (scares.gd keeps the old entity_* entry points).

const CALLS := {
	"idle": [3, 12, 14, 15, 20, 23, 24, 26, 27],
	"stalk": [14, 15, 23],
	"chase": [1, 2, 5, 6, 8, 11, 13, 16, 18, 19, 21, 22, 25, 28, 29, 30],
	"flee": [7, 10, 17],
	"hurt": [11, 19],
	"scream": [0],                         # 0 = scream.mp3
}
# volume, ref distance (m of full volume); the reverb is left to the World bus
const MIX := {
	"idle": [1.0, 6.0], "stalk": [0.7, 5.0], "chase": [1.3, 6.0],
	"flee": [1.1, 6.0], "hurt": [1.2, 5.0], "scream": [1.3, 8.0], "whisper": [1.0, 6.0],
}
const ScareSynth := preload("res://scripts/Audio/scares/scare_synth.gd")
const SfxPool := preload("res://scripts/Audio/sfx_pool.gd")
const TARGET_RMS := 0.1
const MAX_PEAK := 0.5
const BREATH_GAIN := 0.9

var scares: Node
var rng := RandomNumberGenerator.new()
var voice: AudioStreamPlayer3D
var breath: AudioStreamPlayer3D
var occluded := false
var _last := {}
var _gain := {}
var _lp: AudioEffectLowPassFilter
var _cut := 20000.0
var _cut_target := 20000.0
var _breath_level := 0.0
var _breath_target := 0.0
var _breath_pitch := 1.0
var _breath_pitch_target := 1.0

func _ready() -> void:
	rng.randomize()
	scares = get_parent()
	_lp = AudioServer.get_bus_effect(AudioServer.get_bus_index("Entity"), 0) as AudioEffectLowPassFilter
	voice = AudioStreamPlayer3D.new()
	voice.bus = "Entity"
	voice.max_distance = 90.0
	voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(voice)
	breath = AudioStreamPlayer3D.new()
	breath.stream = ScareSynth.cached("rasp_loop")      # scares.prewarm_death() renders it off the main thread
	breath.bus = "Entity"
	breath.unit_size = 2.2
	breath.max_distance = 32.0
	breath.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	breath.volume_db = -80.0
	add_child(breath)

func _process(dt: float) -> void:
	_cut += (_cut_target - _cut) * (1.0 - exp(-dt / 0.08))
	if _lp and absf(_lp.cutoff_hz - _cut) > 20.0:
		_lp.cutoff_hz = _cut
	# the breath eases in and out; paused outright once silent, so it costs nothing when far away
	_breath_level += (_breath_target - _breath_level) * (1.0 - exp(-dt / 0.6))
	_breath_pitch += (_breath_pitch_target - _breath_pitch) * (1.0 - exp(-dt / 0.8))
	if _breath_level < 0.003:
		if breath.playing:
			breath.stop()
		return
	if breath.stream == null:
		breath.stream = ScareSynth.cached("rasp_loop")
		if breath.stream == null:
			return                                          # still rendering
	if not breath.playing:
		breath.play(rng.randf() * 3.0)
	breath.volume_db = linear_to_db(_breath_level * BREATH_GAIN)
	breath.pitch_scale = _breath_pitch

# ---------------------------------------------------------------- calls
func _clip(n: int) -> AudioStream:
	if n == 0:
		return SfxPool.get_stream("res://audio/entity/scream.mp3")
	return SfxPool.get_stream("res://audio/entity/entity_%d.wav" % n)

# Gain that brings a WAV clip to the target RMS without letting its peak pass the cap
func _match_gain(s: AudioStream, key: String) -> float:
	if _gain.has(key):
		return _gain[key]
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
	_gain[key] = g
	return g

func busy() -> bool:
	return voice.playing

## A call of `kind` from `pos`; `interrupt` cuts off the current one. Returns false if busy.
## `pitch` < 0 picks the usual slight random detune.
func call_out(kind: String, pos: Vector3, interrupt := false, volume := 1.0, pitch := -1.0) -> bool:
	if not CALLS.has(kind):
		return false
	if voice.playing and not interrupt:
		return false
	var list: Array = CALLS[kind]
	var i := rng.randi() % list.size()
	if list.size() > 1 and i == _last.get(kind, -1):
		i = (i + 1) % list.size()
	_last[kind] = i
	var n: int = list[i]
	var s := _clip(n)
	var mix: Array = MIX[kind]
	voice.stream = s
	voice.unit_size = mix[1]
	voice.global_position = pos
	voice.volume_db = linear_to_db(_match_gain(s, "%s%d" % [kind, n]) * mix[0] * volume)
	if pitch > 0.0:
		voice.pitch_scale = pitch
	else:
		voice.pitch_scale = 1.0 if kind == "scream" else 0.9 + rng.randf() * 0.15
	voice.play()
	return true

func move(pos: Vector3) -> void:
	voice.global_position = pos
	breath.global_position = pos - Vector3(0.0, 0.5, 0.0)

## It whispers from its corner, and faintly beside your ear on its side (not muffled: that one is in
## your head, not in the room)
func whisper(pos: Vector3, ear_pos: Vector3) -> bool:
	if voice.playing:
		return false
	if not call_out("stalk", pos, false, 0.9):
		return false
	var ear: AudioStreamPlayer3D = scares.spawn3d(voice.stream, ear_pos, 0.2, "Scares", 2.0, voice.pitch_scale, false)
	ear.volume_db = voice.volume_db - 10.0
	return true

func set_occlusion(blocked: bool) -> void:
	occluded = blocked
	# hunting: it is running the corridors to reach you, so a wall between you is a muffle, not a mute
	_cut_target = (2500.0 if Game.hunted else 700.0) if blocked else 20000.0

## How loud its breathing is (0..1) and how fast (pitch 1 = resting)
func breathe(level: float, pitch := 1.0) -> void:
	_breath_target = clampf(level, 0.0, 1.5)
	_breath_pitch_target = clampf(pitch, 0.5, 2.0)

func silence() -> void:
	voice.stop()
	_breath_target = 0.0
