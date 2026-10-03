extends Node3D
## One remote player's voice: decodes their packets, smooths network jitter with a small buffer, and plays them
## from THEIR position in the world (3D: quieter and duller with distance, panned to where they are).
##
## Walls: the level grid is sampled between you and them. Every metre of wall drags a two-stage low-pass down
## (a shout through a door is a dull mumble, through two rooms it is barely there) and lowers the volume.
## Each speaker owns a small audio bus (Voice_<id>) holding those filters, so occlusion is per person.
##
## It also keeps what they said: each utterance (TAKE_MIN..TAKE_MAX s, cut at the first silence) goes to
## Voice.remember_clip(), and THE MIMIC (mimic.gd) plays one back when it is wearing their face.

const Adpcm := preload("res://scripts/Voice/adpcm.gd")
const RATE := 16000
const FRAME := 320                    # samples per 20 ms packet
const PREBUFFER := 3                  # packets collected before playing starts (60 ms)
const MAX_QUEUE := 12                 # more than this (240 ms) and the oldest are dropped to catch up
const HOLD_FRAMES := 1920             # never keep more than 120 ms inside the generator (that would be latency)
const GEN_SECONDS := 0.4
const HEAD_HEIGHT := 1.6
const OPEN_CUTOFF := 20000.0
const MUFFLE_PER_M := 0.6             # cutoff *= exp(-this * metres of wall)
const MIN_CUTOFF := 380.0
const DB_PER_M := 2.2
const MAX_WALL_DB := 14.0
const TAKE_MIN := 0.6                 # s: shorter than this is a cough, not something worth repeating
const TAKE_MAX := 4.0                 # s kept of one utterance (the start of it)

var id := 0
var spatial := true                   # false = the "hear yourself" test: plain stereo, no walls
var volume := 1.0                     # this player's own volume
var wall_m := 0.0                     # metres of wall between us right now (for the debug line)

var queue: Array = []                 # decoded frames waiting to be played
var _buffered := false
var _last_rx := -10.0
var _pb: AudioStreamGeneratorPlayback
var _p3: AudioStreamPlayer3D
var _p2: AudioStreamPlayer
var _bus := ""
var _lp1: AudioEffectLowPassFilter
var _lp2: AudioEffectLowPassFilter
var _cut := OPEN_CUTOFF
var _wall_db := 0.0
var _occl_t := 0.0
var _take := PackedFloat32Array()     # what they are saying right now, for Voice.remember_clip

func setup(peer_id: int, is_spatial := true) -> void:
	id = peer_id
	spatial = is_spatial
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = GEN_SECONDS
	if spatial:
		_bus = "Voice_%d" % id
		if AudioServer.get_bus_index(_bus) < 0:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, _bus)
			AudioServer.set_bus_send(idx, "Master")
			_lp1 = AudioEffectLowPassFilter.new()
			_lp2 = AudioEffectLowPassFilter.new()
			_lp1.resonance = 0.6
			_lp2.resonance = 0.6
			AudioServer.add_bus_effect(idx, _lp1)
			AudioServer.add_bus_effect(idx, _lp2)
		_p3 = AudioStreamPlayer3D.new()
		_p3.stream = gen
		_p3.bus = _bus
		_p3.unit_size = 5.0                                    # a voice carries about this far before it drops
		_p3.max_distance = 45.0
		_p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		_p3.attenuation_filter_cutoff_hz = 9000.0             # far voices also lose their top end
		_p3.attenuation_filter_db = -14.0
		_p3.panning_strength = 1.2
		add_child(_p3)
		_p3.play()
		_pb = _p3.get_stream_playback()
	else:
		_p2 = AudioStreamPlayer.new()
		_p2.stream = gen
		add_child(_p2)
		_p2.play()
		_pb = _p2.get_stream_playback()

func _exit_tree() -> void:
	# stop the stream before its bus goes: a player still mixing into a bus that is being removed under it
	# is a crash risk on the audio thread
	if _p3 != null:
		_p3.stop()
		_p3.bus = &"Master"
	if _bus != "":
		var idx := AudioServer.get_bus_index(_bus)
		if idx >= 0:
			AudioServer.remove_bus(idx)

## A block from the network (Adpcm.encode_block)
func feed(block: PackedByteArray) -> void:
	var samples: PackedFloat32Array = Adpcm.decode_block(block)
	if samples.is_empty():
		return
	if spatial and _take.size() < int(TAKE_MAX * RATE):
		_take.append_array(samples)
	var frame := PackedVector2Array()
	frame.resize(samples.size())
	for i in samples.size():
		frame[i] = Vector2(samples[i], samples[i])
	queue.append(frame)
	_last_rx = Time.get_ticks_msec() / 1000.0
	if queue.size() > MAX_QUEUE:
		queue = queue.slice(queue.size() - PREBUFFER - 2)        # a late burst: skip ahead rather than lag behind

func speaking() -> bool:
	return Time.get_ticks_msec() / 1000.0 - _last_rx < 0.35

func _process(dt: float) -> void:
	_push()
	if not _take.is_empty() and not speaking():       # they stopped talking: keep it if it is a real sentence
		if _take.size() >= int(TAKE_MIN * RATE):
			Voice.remember_clip(id, _take)
		_take = PackedFloat32Array()
	var player: Node = _p3 if spatial else _p2
	if player == null:
		return
	if not spatial:
		_p2.volume_db = linear_to_db(maxf(Voice.voice_volume * volume, 0.0001))
		return
	var r: Node3D = Net.remotes.get(id)
	var cam := get_viewport().get_camera_3d()
	if r == null or not is_instance_valid(r) or cam == null:
		_p3.volume_db = -80.0
		return
	global_position = r.global_position + Vector3(0.0, HEAD_HEIGHT * (0.7 if r.get("crouching") else 1.0), 0.0)
	# players on another level are somewhere else entirely: not audible
	var audible: bool = r.visible and not Voice.deafened
	# walls: sampled a few times a second, then eased so the filter never zips
	_occl_t -= dt
	if _occl_t <= 0.0:
		_occl_t = 0.1
		wall_m = Voice.wall_thickness(cam.global_position, global_position)
	var cut_t := clampf(OPEN_CUTOFF * exp(-MUFFLE_PER_M * wall_m), MIN_CUTOFF, OPEN_CUTOFF)
	var k := minf(1.0, dt * 9.0)
	_cut = exp(lerpf(log(_cut), log(cut_t), k))
	_wall_db = lerpf(_wall_db, -minf(wall_m * DB_PER_M, MAX_WALL_DB), k)
	if _lp1 != null:
		_lp1.cutoff_hz = _cut
		_lp2.cutoff_hz = _cut
	var idx := AudioServer.get_bus_index(_bus)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, _wall_db)
	_p3.volume_db = linear_to_db(maxf(Voice.voice_volume * volume, 0.0001)) if audible else -80.0

# Jitter buffer: start once a few packets are in, keep the generator only slightly ahead, rebuffer after a gap
func _push() -> void:
	if _pb == null:
		return
	var capacity := int(GEN_SECONDS * RATE)
	if not _buffered:
		if queue.size() >= PREBUFFER:
			_buffered = true
		else:
			return
	while not queue.is_empty() and capacity - _pb.get_frames_available() < HOLD_FRAMES and _pb.get_frames_available() >= FRAME:
		_pb.push_buffer(queue.pop_front())
	if queue.is_empty() and _pb.get_frames_available() >= int(capacity * 0.95):
		_buffered = false                                       # ran dry: collect a little again before resuming
