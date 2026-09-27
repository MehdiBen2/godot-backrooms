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

const Adpcm := preload("res://scripts/Voice/adpcm.gd")
const Speaker := preload("res://scripts/Voice/voice_speaker.gd")
const GridNav := preload("res://scripts/World/grid_nav.gd")

const PATH := "user://voice.cfg"
const CAPTURE_BUS := "VoiceCapture"
const RATE := 16000
const FRAME := 320                          # 20 ms
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
var _test = null
var _nav
var _nav_level: Node
var _overlay: Label
var _in_rate := 48000.0

func _ready() -> void:
	_load()
	_setup_capture()
	_build_overlay()
	changed.connect(_save)

# ---- settings -----------------------------------------------------------------------------------
func gate_db() -> float:
	return lerpf(-28.0, -66.0, sensitivity / 100.0)

func cycle_mode() -> void:
	mode = (mode + 1) % 3
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
	_mic.play()
	_in_rate = AudioServer.get_input_mix_rate()
	if _in_rate <= 0.0:
		_in_rate = AudioServer.get_mix_rate()

func _process(dt: float) -> void:
	if _capture != null:
		var avail := _capture.get_frames_available()
		if avail > 0:
			_ingest(_capture.get_buffer(avail))
		while _pcm.size() >= FRAME:
			var frame := _pcm.slice(0, FRAME)
			_pcm = _pcm.slice(FRAME)
			_process_frame(frame)
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
			open = Input.is_key_pressed(PTT_KEY) and not (get_viewport().gui_get_focus_owner() is LineEdit)
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
	if _hang > 0.0:
		if not transmitting:
			transmitting = true
			for j in range(_preroll.size() - 1):
				_send_frame(_preroll[j])
		_send_frame(frame)
	elif transmitting:
		transmitting = false
		_enc.reset()

func _send_frame(frame: PackedFloat32Array) -> void:
	var block := _enc.encode_block(frame)
	if loopback:
		_hear_myself(block)
	if not Net.is_online():
		return
	_seq = (_seq + 1) & 0xFFFF
	var pkt := PackedByteArray([_seq & 0xFF, (_seq >> 8) & 0xFF])
	pkt.append_array(block)
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
	if deafened or pkt.size() <= Adpcm.HEADER + 2:
		return
	var id := multiplayer.get_remote_sender_id()
	var s = speakers.get(id)
	if s == null or not is_instance_valid(s):
		s = Speaker.new()
		add_child(s)
		s.setup(id)
		speakers[id] = s
	s.feed(pkt.slice(2))

func _tidy_speakers() -> void:
	for id in speakers.keys():
		if not Net.remotes.has(id) or not is_instance_valid(speakers[id]):
			if is_instance_valid(speakers[id]):
				speakers[id].queue_free()
			speakers.erase(id)

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
