extends RefCounted
## Footfalls of the things that hunt you, layered from synthesized parts (scare_synth.gd) and the
## recorded carpet steps. Owned by scares.gd, which keeps the howler_step / mannequin_step entry points.

var scares: Node
var rng := RandomNumberGenerator.new()
var _carpet: Array[AudioStream] = []
var _last_carpet := -1
var _howler_variant := 0
var _mq_variant := 0
var _mq_creak_variant := 0
var _mq_lp: AudioEffectLowPassFilter

func _init(owner: Node) -> void:
	scares = owner
	rng.randomize()
	_mq_lp = AudioServer.get_bus_effect(AudioServer.get_bus_index("MannequinSteps"), 0) as AudioEffectLowPassFilter
	for i in range(1, 5):
		var path := "res://audio/carpet_walk_%d.wav" % i
		if ResourceLoader.exists(path):
			_carpet.append(load(path))

# THE BACTERIA's footfall (js howlerStep). weight 0..~2: heavier the faster it moves and the closer it
# is; run 0..1: walking it rolls its weight down slow and soft, running it slams down. On the Entity bus,
# so walls between you muffle it like its voice. It limps: every other foot is the short leg, which lands
# lighter and is dragged through the pile.
func howler_step(pos: Vector3, weight: float, dragging := false, run := 0.0) -> void:
	var w := clampf(weight, 0.05, 2.0)
	var pace := 10.0 if run > 0.5 else 0.0          # the walking or the running takes
	# big and heavy: pitched down, and lower still the harder it comes down
	var pitch := rng.randf_range(0.95, 1.03) - 0.06 * minf(w, 1.5)
	if dragging:
		scares.spawn3d(scares.synth("howler_drag", pace), pos, 0.45 + w * 0.6, "Entity", 3.5, pitch)
	else:
		# never the same take twice in a row
		_howler_variant = (_howler_variant + 1 + rng.randi() % 3) % 4
		scares.spawn3d(scares.synth("howler_step", _howler_variant + pace), pos, 0.6 + w * 0.9, "Entity", 3.5, pitch)

# A mannequin footfall: a hollow composite foot on carpet over a concrete slab. Filtered for the head
# shadow (steps behind you lose their top end, so you can tell where they are) and for walls between.
func mannequin_step(pos: Vector3, weight := 1.0) -> void:
	var player: Node3D = scares.player
	var cam: Camera3D = player.get_node_or_null("Camera3D") if player else null
	if cam == null:
		return
	var cam_pos := cam.global_position
	var to_step := pos - cam_pos
	var dist := to_step.length()
	var dir := to_step / maxf(dist, 0.001)
	var fwd_dot := (-cam.global_transform.basis.z).normalized().dot(dir)
	# the pinna and skull shade sound from behind: 20 kHz in front -> 3.2 kHz straight behind
	var rear := clampf((-fwd_dot + 0.15) / 1.15, 0.0, 1.0)
	var walls: int = scares.audio.walls_between(cam_pos, pos) if scares.audio != null else 0
	var occl := clampf(walls / 3.0, 0.0, 1.0)
	var cut := minf(lerpf(20000.0, 700.0, sqrt(occl)), lerpf(20000.0, 3200.0, rear))
	if _mq_lp:
		_mq_lp.cutoff_hz = cut
	var gain := (1.0 - 0.22 * rear) * (1.0 - 0.5 * occl)
	var pan := lerpf(1.0, 1.35, rear)                   # sharper left / right behind you

	# 1. the recorded carpet scuff, pitched down: a heavy flat sole, not a rolling shoe
	if not _carpet.is_empty():
		var idx := rng.randi() % _carpet.size()
		if _carpet.size() > 1 and idx == _last_carpet:
			idx = (idx + 1) % _carpet.size()
		_last_carpet = idx
		_layer(_carpet[idx], pos, 0.65 * weight * gain, 2.4, 60.0, rng.randf_range(0.80, 0.88), pan)
	# 2. the slab thud and the hollow shell ringing
	_mq_variant = (_mq_variant + 1 + rng.randi() % 3) % 4
	_layer(scares.synth("mannequin_step", _mq_variant), pos, 0.95 * weight * gain, 3.0, 60.0, rng.randf_range(0.94, 1.06), pan)
	# 3. close by, the weight comes up through the floor
	if dist < 4.2:
		_layer(scares.synth("heel"), pos, 0.75 * (1.0 - dist / 4.2) * weight * gain, 3.5, 30.0, rng.randf_range(0.82, 0.95), pan)
	# 4. on about a third of the steps the dry joint groans as the leg locks
	if rng.randf() < 0.35:
		_mq_creak_variant = (_mq_creak_variant + 1) % 3
		var cr := _layer(scares.synth("mannequin_creak", _mq_creak_variant), pos + Vector3(0.0, 0.75, 0.0),
			0.35 * weight * gain, 2.0, 45.0, rng.randf_range(0.92, 1.12), pan)
		cr.stop()
		scares.get_tree().create_timer(0.025 + rng.randf() * 0.03, false).timeout.connect(cr.play)

## One of its joints, as you turn and find it has moved: a single dry creak where it stands
func mannequin_settle(pos: Vector3, weight := 1.0) -> void:
	_mq_creak_variant = (_mq_creak_variant + 1) % 3
	if _mq_lp:
		_mq_lp.cutoff_hz = 20000.0
	_layer(scares.synth("mannequin_creak", _mq_creak_variant), pos, 0.5 * weight, 2.0, 40.0, rng.randf_range(0.7, 0.85), 1.0)

func _layer(stream: AudioStream, pos: Vector3, linear: float, unit: float, max_d: float, pitch: float, pan: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = "MannequinSteps"
	p.unit_size = unit
	p.max_distance = max_d
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.pitch_scale = pitch
	p.panning_strength = pan
	p.volume_db = linear_to_db(maxf(linear, 0.0001))
	scares.add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()
	return p
