extends Node
## Proximity voice chat engine (autoload: Voice).
##
##  microphone -> capture bus -> resample to 16 kHz mono -> high-pass -> gain -> soft clip
##             -> 20 ms frames -> gate (voice activity, or push-to-talk) -> IMA ADPCM -> network
##  network    -> voice_speaker.gd, one per player: jitter buffer -> 3D player at THEIR position,
##                muffled by the walls between you (see voice_speaker.gd)
##
## Packets ride the same WebSocket as everything else (the host relays them), 8 KB/s per talker, only while
## someone is actually talking. Settings live in user://voice.cfg and the menu's VOICE panel.

signal changed
## You stopped talking (your own mic, local only: nothing here goes over the network). `syllables` roughly how
## many words, `loud` the peak level 0..1. events.gd listens: itHeardYou, answerBack.
signal you_spoke(pcm: PackedFloat32Array, syllables: int, loud: float)

const Adpcm := preload("res://scripts/Voice/adpcm.gd")
const Speaker := preload("res://scripts/Voice/voice_speaker.gd")
const GridNav := preload("res://scripts/World/grid_nav.gd")

const PATH := "user://voice.cfg"
const CAPTURE_BUS := "VoiceCapture"
const RATE := 16000
const FRAME := 320                          # 20 ms
const BLOCK := Adpcm.HEADER + FRAME / 2     # one encoded frame
## Frames per network message: 40 ms of voice each, so half as many messages through the tunnel (every
## one carries WebSocket and RPC overhead and sits in the same queue as the snapshots) for 20 ms more delay
const FRAMES_PER_PKT := 2
const MAX_BLOCKS := 4
const MAX_PKT := 2 + BLOCK * MAX_BLOCKS     # seq + blocks
const PTT_KEY := KEY_V
const HANG_TIME := 0.35                     # keeps sending this long after the voice drops (no clipped word endings)
const PTT_HANG := 0.15
const PREROLL := 3                          # frames kept from before the gate opened (no clipped starts)
const HIGHPASS := 0.985                     # one-pole DC / rumble filter, about 60 Hz
const WALL_STEP := 0.75
const MODE_NAMES := ["Voice activity", "Push to talk (V)", "Off"]
enum Mode { ACTIVITY, PUSH, OFF }

var mode: int = Mode.ACTIVITY
var device := "Default"
var mic_gain := 1.0                         # 0 .. 3
var sensitivity := 50                       # 0 .. 100: higher opens the gate on quieter sounds
var voice_volume := 1.0                     # how loud everyone else is, 0 .. 1.5
var muted := false
var deafened := false
var loopback := false                       # hear yourself (mic test)

var level := 0.0                            # mic meter 0..1 (about -70 .. 0 dB)
var transmitting := false
var speakers := {}                          # peer id -> voice_speaker.gd
var clips := {}                             # peer id -> [{pcm, score}]: their last few utterances worth repeating
const CLIPS_KEPT := 6
const CLIP_MIN_SCORE := 4.0                 # a clean call (3) said apart or out of sight (+1 each): anything less, never used

var _capture: AudioEffectCapture
var _mic: AudioStreamPlayer
var _enc := Adpcm.new()
var _pcm := PackedFloat32Array()            # 16 kHz mono, waiting to be cut into frames
var _preroll: Array = []
var _phase := 0.0
var _hp_x := 0.0
var _hp_y := 0.0
var _hang := 0.0
var _seq := 0
var _out_blocks := PackedByteArray()        # encoded frames waiting to fill a message
var _out_n := 0
var _test = null
var _nav
var _nav_level: Node
var _overlay: Label
var _in_rate := 48000.0
var my_clips: Array = []                    # your own last few sentences, clean enough to play back (yourOwnVoice)
const MY_CLIPS_KEPT := 4
## Hearing you, for the events (local only, voice chat or not, muted or not: nothing of it is sent). Its own
## detector, not the voice-chat gate: a level over the room's own noise floor (which it follows slowly, so a hum or a
## fan doesn't count), held through the gaps between words.
const SPEECH_OVER_FLOOR := 12.0             # dB over the noise floor that counts as you talking
const SPEECH_HANG := 0.45                   # s of quiet that ends a sentence
var heard_at := -100.0                      # when you last finished saying something (Time.get_ticks_msec / 1000)
var speaking_now := false
var _noise_db := -60.0
var _spk_hang := 0.0
var _my_take := PackedFloat32Array()
var _my_peak := 0.0

func _ready() -> void:
	_load()
	# Level-editor test launches skip the mic: the macOS permission prompt for the editor's process blocks
	# startup before the first frame (a black window), and a test play has no voice chat to use it for.
	var editor_test := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--test-level="): editor_test = true
	if not editor_test:
		_setup_capture()
	_build_overlay()
	changed.connect(_save)

# ---- settings -----------------------------------------------------------------------------------
func gate_db() -> float:
	return lerpf(-28.0, -66.0, sensitivity / 100.0)

func cycle_mode() -> void:
	mode = (mode + 1) % 3
	_apply_mic_active()
	changed.emit()

func device_list() -> PackedStringArray:
	return AudioServer.get_input_device_list()

func device_label() -> String:
	return device

func cycle_device() -> void:
	var list := device_list()
	if list.is_empty():
		return
	var i := list.find(device)
	device = list[(i + 1) % list.size()]
	AudioServer.input_device = device
	changed.emit()

func toggle_mute() -> void:
	muted = not muted
	changed.emit()

func toggle_deafen() -> void:
	deafened = not deafened
	if deafened:
		muted = true                                  # deaf means muted too, like every voice app
	changed.emit()

func toggle_loopback() -> void:
	loopback = not loopback
	if not loopback and _test != null:
		_test.queue_free()
		_test = null
	changed.emit()

func set_gain(pct: int) -> void:
	mic_gain = pct / 100.0
	changed.emit()

func set_sensitivity(v: int) -> void:
	sensitivity = v
	changed.emit()

func set_volume(pct: int) -> void:
	voice_volume = pct / 100.0
	changed.emit()

## One utterance a survivor just finished (voice_speaker.gd), kept on this machine only if it is the kind
## of thing someone calls out to a teammate. Nothing here understands words; it goes by what a call
## sounds like and when it is made:
##   - said while they were apart from everyone else, out of sight (where "where are you?", "over
##     here", "come here" get said), and not with a monster close to them
##   - short and clear: 0.7-3 s, a handful of syllables, steadily voiced, not screamed or clipped
## Anything scoring under CLIP_MIN_SCORE is dropped: the Mimic would rather say nothing than something
## that gives it away. The newest CLIPS_KEPT that pass are kept, trimmed of silence, with soft ends.
func remember_clip(peer_id: int, samples: PackedFloat32Array) -> void:
	var pcm := _trim(samples)
	var score := _clip_score(pcm) + _call_context(peer_id)
	if score < CLIP_MIN_SCORE:
		return
	var list: Array = clips.get(peer_id, [])
	list.append({"pcm": pcm, "score": score})
	if list.size() > CLIPS_KEPT:
		list.pop_front()
	clips[peer_id] = list

## Something they called out lately, for THE MIMIC to say back in their voice (mimic.gd): the better a
## call it sounds, the likelier. Empty if they haven't said anything worth repeating.
func clip_of(peer_id: int) -> PackedFloat32Array:
	var list: Array = clips.get(peer_id, [])
	if list.is_empty():
		return PackedFloat32Array()
	var total := 0.0
	for c in list:
		total += float(c.score)
	var r := randf() * total
	for c in list:
		r -= float(c.score)
		if r <= 0.0:
			return c.pcm
	return list[-1].pcm

const CLIP_RATE := 16000
const FRAME_S := 0.02

## How much an utterance sounds like a clear call, from its shape alone (0 .. about 4)
func _clip_score(pcm: PackedFloat32Array) -> float:
	var dur := pcm.size() / float(CLIP_RATE)
	if dur < 0.6 or dur > 4.0:
		return -10.0
	# 20 ms energy frames, the loud ones, and the syllables (energy peaks at least 100 ms apart)
	var fl := int(FRAME_S * CLIP_RATE)
	var env := PackedFloat32Array()
	var clipped := 0
	for f in range(0, pcm.size() - fl, fl):
		var e := 0.0
		for i in fl:
			var v := pcm[f + i]
			e += v * v
			if absf(v) > 0.97: clipped += 1
		env.append(sqrt(e / fl))
	if env.size() < 10:
		return -10.0
	var peak := 0.0
	for e in env: peak = maxf(peak, e)
	if peak < 0.02:
		return -10.0                                 # a mumble, or breath on the mic
	var voiced := 0
	var syllables := 0
	var last_peak := -100
	for i in range(1, env.size() - 1):
		if env[i] > peak * 0.18: voiced += 1
		if env[i] > peak * 0.35 and env[i] >= env[i - 1] and env[i] >= env[i + 1] and i - last_peak >= 5:
			syllables += 1
			last_peak = i
	var voiced_ratio := voiced / float(env.size())
	var score := 0.0
	score += 1.0 if dur >= 0.7 and dur <= 3.0 else 0.3
	score += 1.0 if syllables >= 2 and syllables <= 7 else (0.3 if syllables <= 10 else -1.5)   # a long rant isn't a call
	score += 1.0 if voiced_ratio >= 0.35 and voiced_ratio <= 0.92 else -0.5    # a word or two with gaps, not static
	if clipped > pcm.size() * 0.01:
		score -= 2.0                                 # screaming into the mic: nobody calls a teammate like that
	return score

## When it was said: apart from everyone, out of sight, nothing hunting them (a teammate calling out)
func _call_context(peer_id: int) -> float:
	var r = Net.remotes.get(peer_id)
	if r == null or not is_instance_valid(r):
		return 0.0
	var at: Vector3 = r.target_pos
	var nearest := INF
	var in_sight := false
	for s in Net.survivors():
		if s.id == peer_id:
			continue
		var d: float = at.distance_to(s.pos)
		nearest = minf(nearest, d)
		if d < 30.0 and wall_thickness(at, s.pos) < 0.5:
			in_sight = true
	var score := 0.0
	if nearest > 10.0: score += 1.0
	if not in_sight: score += 1.0
	var ent: Node = Game.main.get_node_or_null("Entity") if Game.main != null and is_instance_valid(Game.main) else null
	if ent != null and ent.is_visible_in_tree() and at.distance_to(ent.global_position) < 20.0:
		score -= 1.5                                 # shouting at a monster, not calling a friend
	return score

## Cut the silence off both ends (the voice gate lets a little through) and fade the edges in and out
func _trim(pcm: PackedFloat32Array) -> PackedFloat32Array:
	var n := pcm.size()
	var a := 0
	var b := n - 1
	while a < n and absf(pcm[a]) < 0.02: a += 1
	while b > a and absf(pcm[b]) < 0.02: b -= 1
	a = maxi(0, a - int(0.04 * CLIP_RATE))
	b = mini(n - 1, b + int(0.08 * CLIP_RATE))
	var out := pcm.slice(a, b + 1)
	var fade := mini(int(0.015 * CLIP_RATE), out.size() / 4)
	for i in fade:
		var k := i / float(fade)
		out[i] *= k
		out[out.size() - 1 - i] *= k
	return out

## Is the mic open at all (voice mode not Off, the device capturing)?
func mic_live() -> bool:
	return _capture != null and _mic != null and _mic.playing

## The events' own ear (see SPEECH_OVER_FLOOR): a sentence starts when the level climbs well over the room's floor
## and ends after SPEECH_HANG of quiet
func _detect_speech(frame: PackedFloat32Array, db: float) -> void:
	# the floor falls quickly to quiet and climbs only slowly: it follows the room, not your voice
	_noise_db = lerpf(_noise_db, db, 0.25 if db < _noise_db else 0.0015)
	var loud := db > maxf(_noise_db + SPEECH_OVER_FLOOR, -58.0)
	if loud:
		_spk_hang = SPEECH_HANG
		if not speaking_now:
			speaking_now = true
			_my_take = PackedFloat32Array()
			for f in _preroll:
				_my_take.append_array(f)
			_my_peak = 0.0
	else:
		_spk_hang -= FRAME / float(RATE)
	if not speaking_now:
		return
	if _my_take.size() < RATE * 6:
		_my_take.append_array(frame)
	_my_peak = maxf(_my_peak, clampf((db + 70.0) / 70.0, 0.0, 1.0))
	if _spk_hang <= 0.0:
		speaking_now = false
		_end_take()

## Something you just said: told to whoever listens (you_spoke), and kept if it would play back clean. Not kept
## if the game itself was loud just then (a scare's sound coming back in through the mic is not your voice).
func _end_take() -> void:
	var take := _my_take
	var peak := _my_peak
	_my_take = PackedFloat32Array()
	_my_peak = 0.0
	if take.size() < int(0.25 * RATE):
		return
	var pcm := _trim(take)
	var syl := count_syllables(pcm)
	heard_at = Time.get_ticks_msec() / 1000.0
	you_spoke.emit(pcm, syl, peak)
	var bus := AudioServer.get_bus_index("Scares")
	var bleed := bus >= 0 and AudioServer.get_bus_peak_volume_left_db(bus, 0) > -26.0
	if not bleed and syl >= 2 and _clip_score(pcm) >= 1.5:
		my_clips.append(pcm)
		if my_clips.size() > MY_CLIPS_KEPT:
			my_clips.pop_front()

## One of your own recent sentences (empty if you haven't said anything usable)
func my_clip() -> PackedFloat32Array:
	if my_clips.is_empty():
		return PackedFloat32Array()
	return my_clips[randi() % my_clips.size()]

## Roughly how many syllables: peaks in the 20 ms energy envelope at least 100 ms apart
func count_syllables(pcm: PackedFloat32Array) -> int:
	var fl := int(FRAME_S * CLIP_RATE)
	var env := PackedFloat32Array()
	for f in range(0, pcm.size() - fl, fl):
		var e := 0.0
		for i in fl:
			e += pcm[f + i] * pcm[f + i]
		env.append(sqrt(e / fl))
	var peak := 0.0
	for e in env: peak = maxf(peak, e)
	var n := 0
	var last := -100
	for i in range(1, env.size() - 1):
		if env[i] > peak * 0.35 and env[i] >= env[i - 1] and env[i] >= env[i + 1] and i - last >= 5:
			n += 1
			last = i
	return n

## 16 kHz samples as something an AudioStreamPlayer can play
static func pcm_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var pcm := PackedByteArray()
	pcm.resize(samples.size() * 2)
	for i in samples.size():
		pcm.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = CLIP_RATE
	wav.stereo = false
	wav.data = pcm
	return wav

func is_speaking(peer_id: int) -> bool:
	var s = speakers.get(peer_id)
	return s != null and is_instance_valid(s) and s.speaking()

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return
	mode = clampi(int(cf.get_value("voice", "mode", mode)), 0, 2)
	device = str(cf.get_value("voice", "device", device))
	mic_gain = clampf(float(cf.get_value("voice", "gain", mic_gain)), 0.0, 3.0)
	sensitivity = clampi(int(cf.get_value("voice", "sensitivity", sensitivity)), 0, 100)
	voice_volume = clampf(float(cf.get_value("voice", "volume", voice_volume)), 0.0, 1.5)
	muted = bool(cf.get_value("voice", "muted", false))

func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("voice", "mode", mode)
	cf.set_value("voice", "device", device)
	cf.set_value("voice", "gain", mic_gain)
	cf.set_value("voice", "sensitivity", sensitivity)
	cf.set_value("voice", "volume", voice_volume)
	cf.set_value("voice", "muted", muted)
	cf.save(PATH)

# ---- capture ---------------------------------------------------------------------------------------
func _setup_capture() -> void:
	var idx := AudioServer.get_bus_index(CAPTURE_BUS)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, CAPTURE_BUS)
		_capture = AudioEffectCapture.new()
		_capture.buffer_length = 0.5
		AudioServer.add_bus_effect(idx, _capture)
		AudioServer.set_bus_mute(idx, true)              # the capture effect still hears it; you never do
	else:
		_capture = AudioServer.get_bus_effect(idx, 0)
	if device != "Default" and device_list().has(device):
		AudioServer.input_device = device
	_mic = AudioStreamPlayer.new()
	_mic.stream = AudioStreamMicrophone.new()
	_mic.bus = CAPTURE_BUS
	add_child(_mic)
	_apply_mic_active()
	# The mic is resampled into the audio graph before it reaches this bus, so what
	# AudioEffectCapture hands us runs at the engine's mix rate, not the raw input device rate
	# (get_input_mix_rate()) -- using the wrong one here mis-tunes the resample to 16 kHz below
	# and comes out pitch-shifted / aliased on the other end.
	_in_rate = AudioServer.get_mix_rate()
	if _in_rate <= 0.0:
		_in_rate = 44100.0

## The mic device only needs to be open while voice chat can actually use it: leaving it capturing
## for the whole session (menus, singleplayer, mode Off) keeps a CoreAudio input unit running for no
## reason, and on macOS that shares hardware with the output unit closely enough that a hiccup on the
## input side (AudioUnitRender failures on device/session changes) can show up as clicks on output too.
func _apply_mic_active() -> void:
	if _mic == null:
		return
	if mode != Mode.OFF:
		if not _mic.playing:
			_mic.play()
	elif _mic.playing:
		_mic.stop()

func _process(dt: float) -> void:
	if _capture != null:
		var avail := _capture.get_frames_available()
		if avail > 0:
			_ingest(_capture.get_buffer(avail))
		while _pcm.size() >= FRAME:
			var frame := _pcm.slice(0, FRAME)
			_pcm = _pcm.slice(FRAME)
			_process_frame(frame)
	if _pcm.size() > RATE * 2:           # a stalled consumer must not let the backlog grow without bound
		_pcm = _pcm.slice(_pcm.size() - FRAME)
	_tidy_speakers()
	_update_overlay()

# Stereo input frames at the device rate -> mono 16 kHz, high-passed, with gain and a soft limiter
func _ingest(buf: PackedVector2Array) -> void:
	var count := buf.size()
	var step := _in_rate / RATE
	var i := _phase
	while i < count:
		var k := int(i)
		var f := i - k
		var a := (buf[k].x + buf[k].y) * 0.5
		var b := a
		if k + 1 < count:
			b = (buf[k + 1].x + buf[k + 1].y) * 0.5
		var x := lerpf(a, b, f)
		var y := HIGHPASS * (_hp_y + x - _hp_x)
		_hp_x = x
		_hp_y = y
		_pcm.append(tanh(y * mic_gain * 1.6) * 0.62)        # soft clip: a shout distorts gently instead of harshly
		i += step
	_phase = i - count

func _process_frame(frame: PackedFloat32Array) -> void:
	var sum := 0.0
	for s in frame:
		sum += s * s
	var rms := sqrt(sum / frame.size())
	var db := linear_to_db(maxf(rms, 0.000001))
	level = lerpf(level, clampf((db + 70.0) / 70.0, 0.0, 1.0), 0.5)
	var open := false
	var hang_for := HANG_TIME
	if not muted and not deafened and mode != Mode.OFF:
		if mode == Mode.PUSH:
			open = Input.is_action_pressed("voice") and not (get_viewport().gui_get_focus_owner() is LineEdit)
			hang_for = PTT_HANG
		else:
			open = db > gate_db()
	if open:
		_hang = hang_for
	else:
		_hang -= FRAME / float(RATE)
	_preroll.append(frame)
	if _preroll.size() > PREROLL:
		_preroll.pop_front()
	_detect_speech(frame, db)
	if _hang > 0.0:
		if not transmitting:
			transmitting = true
			for j in range(_preroll.size() - 1):
				_send_frame(_preroll[j])
		_send_frame(frame)
	elif transmitting:
		transmitting = false
		_flush_voice()                      # the last word's tail, not left waiting for a partner frame
		_enc.reset()

func _send_frame(frame: PackedFloat32Array) -> void:
	var block := _enc.encode_block(frame)
	if loopback:
		_hear_myself(block)
	if not Net.is_online():
		_out_blocks.clear()
		_out_n = 0
		return
	_out_blocks.append_array(block)
	_out_n += 1
	if _out_n >= FRAMES_PER_PKT:
		_flush_voice()

func _flush_voice() -> void:
	if _out_n == 0:
		return
	var pkt := PackedByteArray()
	if Net.is_online():
		_seq = (_seq + 1) & 0xFFFF
		pkt = PackedByteArray([_seq & 0xFF, (_seq >> 8) & 0xFF])
		pkt.append_array(_out_blocks)
	_out_blocks = PackedByteArray()
	_out_n = 0
	if not pkt.is_empty():
		_pkt.rpc(pkt)

func _hear_myself(block: PackedByteArray) -> void:
	if _test == null:
		_test = Speaker.new()
		add_child(_test)
		_test.setup(0, false)
	_test.feed(block)

# ---- network ----------------------------------------------------------------------------------------
@rpc("any_peer", "call_remote", "unreliable")
func _pkt(pkt: PackedByteArray) -> void:
	if deafened or pkt.size() < 2 + BLOCK or pkt.size() > MAX_PKT or (pkt.size() - 2) % BLOCK != 0:
		return
	var id := multiplayer.get_remote_sender_id()
	if not Net.remotes.has(id):           # only survivors we know about get a speaker (no node spam from strangers)
		return
	var s = speakers.get(id)
	if s == null or not is_instance_valid(s):
		s = Speaker.new()
		add_child(s)
		s.setup(id)
		speakers[id] = s
	for at in range(2, pkt.size(), BLOCK):
		s.feed(pkt.slice(at, at + BLOCK))

func _tidy_speakers() -> void:
	for id in speakers.keys():
		if not Net.remotes.has(id) or not is_instance_valid(speakers[id]):
			if is_instance_valid(speakers[id]):
				speakers[id].queue_free()
			speakers.erase(id)
	for id in clips.keys():
		if not Net.remotes.has(id):
			clips.erase(id)                     # they left: nothing of theirs stays behind

# ---- walls ---------------------------------------------------------------------------------------------
## Metres of wall between two points, from the level grid (sampled every WALL_STEP)
func wall_thickness(a: Vector3, b: Vector3) -> float:
	var lvl: Node = Game.level
	if lvl == null or not is_instance_valid(lvl) or lvl.get("walls") == null:
		return 0.0
	if lvl != _nav_level:
		_nav_level = lvl
		_nav = GridNav.new(lvl)
	var d := Vector2(b.x - a.x, b.z - a.z).length()
	if d < 0.6:
		return 0.0
	var steps := int(d / WALL_STEP)
	var walls := 0
	for i in range(1, steps):
		var t := float(i) / steps
		if _nav.is_wall(GridNav.cell(lerpf(a.x, b.x, t)), GridNav.cell(lerpf(a.z, b.z, t))):
			walls += 1
	return walls * WALL_STEP

# ---- who is talking ------------------------------------------------------------------------------------
func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 8
	add_child(layer)
	_overlay = Label.new()
	_overlay.position = Vector2(40, 330)
	_overlay.add_theme_font_size_override("font_size", 15)
	_overlay.add_theme_color_override("font_color", Color(0.5, 0.95, 0.55))
	_overlay.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_overlay.add_theme_constant_override("shadow_offset_y", 1)
	if ResourceLoader.exists("res://fonts/vcr.ttf"):
		_overlay.add_theme_font_override("font", load("res://fonts/vcr.ttf"))
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_overlay)

func _update_overlay() -> void:
	var lines: Array[String] = []
	if transmitting and not muted:
		lines.append("> YOU")
	for id in speakers:
		if is_speaking(id):
			lines.append("> " + Net.label_for(id))
	_overlay.text = "\n".join(lines)
	_overlay.visible = Net.is_online() and not lines.is_empty()
