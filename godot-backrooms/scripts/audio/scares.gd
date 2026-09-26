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
var mannequin_lp: AudioEffectLowPassFilter
var mannequin_cut := 20000.0
var mannequin_cut_target := 20000.0
var _carpet_samples: Array[AudioStream] = []
var _last_carpet_idx := -1
var _mq_variant := 0
var _mq_creak_variant := 0
var clip_gain := {}
var glitchers: Array = []                    # [player, next_toggle, base_db]
var live: Array = []                         # everything scheduled, so stop_all() can silence it
var player: Node3D
var _blood_scream_stream: AudioStream = null  # tithuh-blood-the-screaming, loaded once
var _body_fall_stream: AudioStream = preload("res://audio/player/body_fall.mp3")
var _gridoff_stream: AudioStream = null
var _gasp_streams: Array[AudioStream] = []
var _last_gasp_time := -10.0
var _last_scream_time := -100.0

func _ready() -> void:
	rng.randomize()
	player = get_parent().get_node("Player")
	_make_bus("Entity", "World")
	entity_lp = AudioEffectLowPassFilter.new()
	entity_lp.cutoff_hz = 20000.0
	var entity_bus := AudioServer.get_bus_index("Entity")
	while AudioServer.get_bus_effect_count(entity_bus) > 0:
		AudioServer.remove_bus_effect(entity_bus, 0)
	AudioServer.add_bus_effect(entity_bus, entity_lp)
	_make_bus("Scares", "World")
	_make_bus("MannequinSteps", "World")
	mannequin_lp = AudioEffectLowPassFilter.new()
	mannequin_lp.cutoff_hz = 20000.0
	var mq_bus := AudioServer.get_bus_index("MannequinSteps")
	while AudioServer.get_bus_effect_count(mq_bus) > 0:
		AudioServer.remove_bus_effect(mq_bus, 0)
	AudioServer.add_bus_effect(mq_bus, mannequin_lp)
	for i in range(1, 5):
		var cp_path := "res://audio/carpet_walk_%d.wav" % i
		if ResourceLoader.exists(cp_path):
			_carpet_samples.append(load(cp_path))
	_make_bus("Preacher", "World")
	voice = AudioStreamPlayer3D.new()
	voice.bus = "Entity"
	voice.max_distance = 90.0
	voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(voice)
	# Preload blood-scream sample so splat() never calls load() on the hot path
	if ResourceLoader.exists("res://audio/entity/blood_scream.mp3"):
		_blood_scream_stream = load("res://audio/entity/blood_scream.mp3")
	# Preload grid-off sample so grid_off() never hits load() on the hot path
	if ResourceLoader.exists("res://sounds/events/gridoff/gridoff.mp3"):
		_gridoff_stream = load("res://sounds/events/gridoff/gridoff.mp3")
	elif ResourceLoader.exists("res://audio/events/gridoff.mp3"):
		_gridoff_stream = load("res://audio/events/gridoff.mp3")
	# Preload male gasp audio samples for when the player gets caught by entities
	for p in [
		"res://audio/events/freesound_community-male-gasp-2-103066.mp3",
		"res://audio/events/freesound_community-male-gasp-3-82554.mp3",
		"res://sounds/player/gasp/freesound_community-male-gasp-2-103066.mp3",
		"res://sounds/player/gasp/freesound_community-male-gasp-3-82554.mp3"
	]:
		if ResourceLoader.exists(p):
			var st: AudioStream = load(p)
			if st != null and not _gasp_streams.has(st):
				_gasp_streams.append(st)

func _make_bus(name: String, send: String) -> void:
	if AudioServer.get_bus_index(name) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, name)
	AudioServer.set_bus_send(idx, send)

var _clock := 0.0

func _process(dt: float) -> void:
	_clock += dt
	entity_cut += (entity_cut_target - entity_cut) * (1.0 - exp(-dt / 0.08))
	if absf(entity_lp.cutoff_hz - entity_cut) > 20.0:
		entity_lp.cutoff_hz = entity_cut
	mannequin_cut += (mannequin_cut_target - mannequin_cut) * (1.0 - exp(-dt / 0.06))
	if absf(mannequin_lp.cutoff_hz - mannequin_cut) > 15.0:
		mannequin_lp.cutoff_hz = mannequin_cut
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
func _spawn3d(stream: AudioStream, pos: Vector3, linear: float, bus := "Scares", ref := 5.0, pitch := 1.0, occlude := true) -> AudioStreamPlayer3D:
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
	if occlude:
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
		"gridOff", "gridoff":
			var pos: Vector3 = a if a is Vector3 else Vector3.INF
			grid_off(pos)

func grid_off(pos := Vector3.INF) -> void:
	if not pos.is_finite():
		pos = player.global_position + Vector3(18.0, 2.4, 0.0) if player else Vector3(18.0, 2.4, 0.0)
	if _gridoff_stream == null:
		if ResourceLoader.exists("res://sounds/events/gridoff/gridoff.mp3"):
			_gridoff_stream = load("res://sounds/events/gridoff/gridoff.mp3")
		elif ResourceLoader.exists("res://audio/events/gridoff.mp3"):
			_gridoff_stream = load("res://audio/events/gridoff.mp3")
	if _gridoff_stream != null:
		# Mirror web scares.js: ref=12, volume=2.0, non-occluded (reverberant distant sound carries through walls)
		_spawn3d(_gridoff_stream, pos, 2.0, "Scares", 12.0, 1.0, false)

var _last_beat := -1.0

# One heart: two callers asking for a beat in the same instant (the grab and the entity's proximity
# beat, say) get ONE beat, never a flam that sounds like it stuttered
func heartbeat(strength := 1.0) -> void:
	if _clock - _last_beat < 0.3:          # game time, not the wall clock
		return
	_last_beat = _clock
	_spawn_flat(synth("heartbeat"), clampf(0.45 * strength, 0.05, 1.2), "Body")
	Game.beat()

# The moment something seizes you: one designed hit instead of a stinger + static burst stacked
func seize() -> void:
	_spawn_flat(synth("seize"), 1.0, "Body")

func entity_static() -> void:
	_spawn_flat(synth("static"), 0.5, "Scares", rng.randf_range(0.9, 1.15))

func startle(amount := 0.5) -> void:
	_spawn_flat(synth("stinger"), clampf(amount * 1.2, 0.1, 1.2))

func splat() -> void:
	# Recorded blood + screaming sample (tithuh-blood-the-screaming-545569 from the web game)
	# The bite calls this three times (bite + two rips): the scream sample plays ONCE per death, the
	# later rips get the synthesized wet hit only, so the scream never stacks or repeats.
	var now := Time.get_ticks_msec() / 1000.0
	if _blood_scream_stream != null and now - _last_scream_time > _blood_scream_stream.get_length() + 1.0:
		_last_scream_time = now
		_spawn_flat(_blood_scream_stream, 0.9, "Body")
	else:
		_spawn_flat(synth("splat"), 0.9, "Body")

var _flat_player: AudioStreamPlayer = null

# The monitor's flat tone of a heart that has stopped. ONE player per life: it is started once and after
# that only its level moves (the grab / snap bring it up, death settles it down to a quiet hold). Never
# a second copy: two of the same 1 kHz tone beat against each other and it sounds like it restarts.
const FLATLINE_GAIN := 1.0        # as the heart stops (grab, snap)
const FLATLINE_HOLD_GAIN := 0.5   # dead: a thin line under the muffle until the respawn, not an alarm
var _flat_tween: Tween

func flatline(gain := FLATLINE_GAIN, fade := 0.9) -> void:
	if not flatlining():
		_flat_player = _spawn_flat(synth("flatline_loop"), 1.0, "Body")
		_flat_player.volume_db = -60.0
	if _flat_tween != null and _flat_tween.is_valid():
		_flat_tween.kill()
	# a tween in dB is an exponential ramp in level: the tone swells in the way the old one did
	_flat_tween = create_tween()
	_flat_tween.tween_property(_flat_player, "volume_db", linear_to_db(gain), fade)

func flatline_hold(fade := 1.5) -> void:
	flatline(FLATLINE_HOLD_GAIN, fade)

func stop_flatline() -> void:
	if _flat_player == null or not is_instance_valid(_flat_player):
		_flat_player = null
		return
	if _flat_tween != null and _flat_tween.is_valid():
		_flat_tween.kill()
	var p := _flat_player
	_flat_player = null
	var tw := create_tween()
	tw.tween_property(p, "volume_db", -80.0, 0.25)
	tw.tween_callback(p.queue_free)

func flatlining() -> bool:
	return _flat_player != null and is_instance_valid(_flat_player) and _flat_player.playing

# Dead silence: high ear ringing
func tinnitus(seconds: float) -> void:
	_spawn_flat(synth("tinnitus", seconds), 1.0, "Body")

# ------------------------------------------------------------------ death

# Your body hitting the floor under the death camera (thekids15 body-fall recording). `from` skips
# into the file, so the death camera can line its thud up with the frame the body lands on.
func body_fall(from := 0.0) -> void:
	if _body_fall_stream == null:
		return
	var p := _spawn_flat(_body_fall_stream, 1.0, "Body")
	if from > 0.0:
		p.play(from)

# At death: a grab or snap already stopped the heart, so its flatline (the same player) just settles
# down to the quiet hold. A death nothing built up to gets a few weak, uneven beats first, then the line.
func heart_stop() -> void:
	if flatlining():
		flatline_hold(2.0)
		return
	for b in [[0.3, 1.2], [1.15, 0.8], [2.35, 0.45]]:
		get_tree().create_timer(b[0], false).timeout.connect(heartbeat.bind(b[1]))
	get_tree().create_timer(3.1, false).timeout.connect(flatline_hold.bind(0.9))

# Render the death sounds on a worker thread now, so the moment you die never hitches on the synthesis.
# The synth cache is static: this only does real work once per session.
var _prewarm_task := -1

func prewarm_death() -> void:
	if _prewarm_task >= 0:
		return
	var s := ScareSynth.new()          # its own rng: not shared with the main thread
	var jobs := [["flatline_loop", 0.0],
		["static_hit", 0.0], ["stinger", 0.0], ["seize", 0.0], ["heartbeat", 0.0], ["splat", 0.0],
		["howler_step", 0.0], ["howler_step", 1.0], ["howler_step", 2.0], ["howler_step", 3.0],
		["howler_drag", 0.0], ["bone_crack", 0.0], ["heel", 0.0],
		["mannequin_step", 0.0], ["mannequin_step", 1.0], ["mannequin_step", 2.0], ["mannequin_step", 3.0],
		["mannequin_creak", 0.0], ["mannequin_creak", 1.0], ["mannequin_creak", 2.0]]
	_prewarm_task = WorkerThreadPool.add_task(func():
		for j in jobs:
			s.render(j[0], j[1]))

func _exit_tree() -> void:
	if _prewarm_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_prewarm_task)
		_prewarm_task = -1

func gasp(volume_mult := 1.0) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_gasp_time < 0.35:
		return
	_last_gasp_time = now

	if _gasp_streams.is_empty():
		for p in [
			"res://audio/events/freesound_community-male-gasp-2-103066.mp3",
			"res://audio/events/freesound_community-male-gasp-3-82554.mp3",
			"res://sounds/player/gasp/freesound_community-male-gasp-2-103066.mp3",
			"res://sounds/player/gasp/freesound_community-male-gasp-3-82554.mp3"
		]:
			if ResourceLoader.exists(p):
				var st: AudioStream = load(p)
				if st != null and not _gasp_streams.has(st):
					_gasp_streams.append(st)

	if not _gasp_streams.is_empty():
		var stream: AudioStream = _gasp_streams[rng.randi() % _gasp_streams.size()]
		var pitch := rng.randf_range(0.96, 1.04)
		_spawn_flat(stream, 6.0 * volume_mult, "Body", pitch)

	# Involuntary gasp reflects in the respiratory simulation
	var au: Node = get_parent().get_node_or_null("Audio")
	if au != null and au.get("breathing") != null:
		au.breathing.gasp(1.0)

func stop_all() -> void:
	for c in get_children():
		if c is AudioStreamPlayer or c is AudioStreamPlayer3D:
			if c != voice:
				c.queue_free()
	glitchers.clear()

# THE BACTERIA's footfall (js howlerStep). weight 0..~2: heavier the faster it moves and the closer it
# is. On the Entity bus, so walls between you muffle it like its voice. It limps: every other foot is
# the short leg, which lands lighter and is dragged, claws raking the carpet. Now and then a joint cracks.
var _howler_variant := 0

func howler_step(pos: Vector3, weight: float, dragging := false) -> void:
	var w := clampf(weight, 0.05, 2.0)
	var pitch := rng.randf_range(0.94, 1.06) - 0.07 * minf(w, 1.5)
	if dragging:
		_spawn3d(synth("howler_drag"), pos, 0.5 + w * 0.7, "Entity", 2.5, pitch)
	else:
		# never the same take twice in a row
		_howler_variant = (_howler_variant + 1 + rng.randi() % 3) % 4
		_spawn3d(synth("howler_step", _howler_variant), pos, 0.6 + w * 0.9, "Entity", 2.5, pitch)
	if not dragging and rng.randf() < 0.25 + w * 0.15:
		var crack := _spawn3d(synth("bone_crack"), pos + Vector3(0.0, 2.0, 0.0), 0.35 * w, "Entity", 2.5, rng.randf_range(0.8, 1.4))
		crack.stop()
		get_tree().create_timer(0.03 + rng.randf() * 0.05, false).timeout.connect(crack.play)

# A mannequin footfall: physically modeled contact on carpet over concrete slab.
# Calculates physical rear pinna head-shadow (HRTF) filtering so player can accurately tell
# when footsteps are behind them, plus alternating left/right bipedal foot placement.
func mannequin_step(pos: Vector3, weight := 1.0, _is_left := false, _mannequin_node: Node3D = null) -> void:
	if player == null:
		return
	var cam: Camera3D = player.get_node_or_null("Camera3D")
	if cam == null:
		return
		
	var cam_pos := cam.global_position
	var to_step := pos - cam_pos
	var dist := to_step.length()
	var dir := to_step / maxf(dist, 0.001)
	
	# Head-relative orientation:
	# In Godot, -cam.global_transform.basis.z is camera forward, basis.x is camera right
	var cam_forward := -cam.global_transform.basis.z.normalized()
	var fwd_dot := cam_forward.dot(dir)
	
	# Physics: Pinna (outer ear) head shadow effect.
	# Direct sound from behind is shielded by the ear pinnae and skull:
	# Front (fwd_dot >= 0.2): full high frequency line of sight.
	# Rear (fwd_dot < 0.2 down to -1.0): high frequencies above 3.2-3.8 kHz are blocked.
	var rear_factor := clampf((-fwd_dot + 0.15) / 1.15, 0.0, 1.0)
	
	# Wall occlusion (obstacles between ears and foot):
	var audio_node = get_parent().get_node_or_null("Audio")
	var walls: int = audio_node.walls_between(cam_pos, pos) if audio_node != null else 0
	var occl_factor := clampf(walls / 3.0, 0.0, 1.0)
	var wall_cutoff := lerpf(20000.0, 700.0, sqrt(occl_factor))
	
	# Pinna shadow cutoff: 20000 Hz in front -> 3200 Hz directly behind
	var pinna_cutoff := lerpf(20000.0, 3200.0, rear_factor)
	mannequin_cut_target = minf(wall_cutoff, pinna_cutoff)
	mannequin_cut = mannequin_cut_target
	mannequin_lp.cutoff_hz = mannequin_cut
	
	# Direct sound volume reduction when behind (pinna shadowing attenuation)
	var rear_gain := 1.0 - 0.22 * rear_factor
	if occl_factor > 0.0:
		rear_gain *= (1.0 - 0.5 * occl_factor)
		
	# Binaural panning strength: increase when behind for razor-sharp spatial localization
	var pan_str := lerpf(1.0, 1.35, rear_factor)
	
	# ---------------- LAYER 1: Real Carpet Scuff & Fiber Compression
	if not _carpet_samples.is_empty():
		var idx := rng.randi() % _carpet_samples.size()
		if _carpet_samples.size() > 1 and idx == _last_carpet_idx:
			idx = (idx + 1) % _carpet_samples.size()
		_last_carpet_idx = idx
		
		var cp := AudioStreamPlayer3D.new()
		cp.stream = _carpet_samples[idx]
		cp.bus = "MannequinSteps"
		cp.unit_size = 2.4
		cp.max_distance = 60.0
		cp.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		# Pitched down (0.80-0.88): heavy flat sole instead of rolling shoe
		cp.pitch_scale = rng.randf_range(0.80, 0.88)
		cp.panning_strength = pan_str
		cp.volume_db = linear_to_db(maxf(0.65 * weight * rear_gain, 0.0001))
		add_child(cp)
		cp.global_position = pos
		cp.finished.connect(cp.queue_free)
		cp.play()
		
	# ---------------- LAYER 2: Heavy Floor Slab Thud + Hollow Shell Resonance
	_mq_variant = (_mq_variant + 1 + rng.randi() % 3) % 4
	var sp := AudioStreamPlayer3D.new()
	sp.stream = synth("mannequin_step", _mq_variant)
	sp.bus = "MannequinSteps"
	sp.unit_size = 3.0
	sp.max_distance = 60.0
	sp.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	sp.pitch_scale = rng.randf_range(0.94, 1.06)
	sp.panning_strength = pan_str
	sp.volume_db = linear_to_db(maxf(0.95 * weight * rear_gain, 0.0001))
	add_child(sp)
	sp.global_position = pos
	sp.finished.connect(sp.queue_free)
	sp.play()
	
	# ---------------- LAYER 3: Low-Frequency Slab Vibration (Close Proximity)
	# When stalking within 4.2m, the physical weight radiates through the floor slab
	if dist < 4.2:
		var close_k := 1.0 - (dist / 4.2)
		var vp := AudioStreamPlayer3D.new()
		vp.stream = synth("heel")
		vp.bus = "MannequinSteps"
		vp.unit_size = 3.5
		vp.max_distance = 30.0
		vp.pitch_scale = rng.randf_range(0.82, 0.95)
		vp.panning_strength = pan_str
		vp.volume_db = linear_to_db(maxf(0.75 * close_k * weight * rear_gain, 0.0001))
		add_child(vp)
		vp.global_position = pos
		vp.finished.connect(vp.queue_free)
		vp.play()
		
	# ---------------- LAYER 4: Mechanical Joint Stick-Slip Friction
	# On ~35% of steps, the dry unlubricated joint groans slightly as the leg locks into place
	if rng.randf() < 0.35:
		_mq_creak_variant = (_mq_creak_variant + 1) % 3
		var cr := AudioStreamPlayer3D.new()
		cr.stream = synth("mannequin_creak", _mq_creak_variant)
		cr.bus = "MannequinSteps"
		cr.unit_size = 2.0
		cr.max_distance = 45.0
		cr.pitch_scale = rng.randf_range(0.92, 1.12)
		cr.panning_strength = pan_str
		cr.volume_db = linear_to_db(maxf(0.35 * weight * rear_gain, 0.0001))
		add_child(cr)
		cr.global_position = pos + Vector3(0.0, 0.75, 0.0)
		cr.finished.connect(cr.queue_free)
		cr.stop()
		get_tree().create_timer(0.025 + rng.randf() * 0.03, false).timeout.connect(cr.play)

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
