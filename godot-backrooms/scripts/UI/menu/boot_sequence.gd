extends CanvasLayer
## The boot sequence, played once per launch in front of the title screen: a photosensitivity and
## sensory warning, a note on the assets' licensing, a word from the developer, the logo coming up under
## a failing tube, then the CRT switching on onto the menu. Any key, click or pad button skips the card
## on screen; Esc skips straight to the menu.

signal reveal     # the CRT is switching on: the menu should start its own intro behind it
signal done

const CREAM := Color("e6e1cd")
const RED := Color("c4271f")
const DIM := Color(0.9, 0.882, 0.804, 0.62)
const FAINT := Color(0.9, 0.882, 0.804, 0.4)
const MIN_SHOW := 0.35     # presses this soon after a card appears are ignored, so one press = one skip
const HUM_DB := -30.0
const TV_TIME := 2.4       # power-on to a settled picture
const TV_RATE := 44100.0

const CARDS := [
	{
		"head": "WARNING", "color": RED, "icon": true,
		"sub": "PHOTOSENSITIVITY & SENSORY WARNING",
		"body": "This game contains flashing and flickering lights, strobe-like effects, visual distortion, sudden loud noises and long stretches of darkness. A small percentage of people may experience epileptic seizures or blackouts when exposed to certain light patterns, even with no prior history of epilepsy.\n\nIf you or anyone in your family has an epileptic condition, consult a doctor before playing. Stop playing immediately if you experience dizziness, altered vision, eye or muscle twitching, disorientation, nausea, anxiety or any involuntary movement.",
		"foot": "PLAY IN A WELL-LIT ROOM  /  TAKE REGULAR BREAKS  /  HEADPHONES RECOMMENDED",
		"hold": 8.0,
	},
	{
		"head": "NOTICE", "color": CREAM,
		"sub": "ASSETS & LICENSING",
		"body": "All third-party assets used in this game (3D models, textures, sound effects, music and fonts) are open-source or royalty-free resources, released under licenses that permit redistribution and commercial use.\n\nEvery asset remains the work of its original author, and attribution is given in the credits. The Backrooms is a collaborative internet mythos: this game is an independent work, not affiliated with or endorsed by its original creators.",
		"foot": "THANK YOU TO EVERY ARTIST WHO SHARES THEIR WORK FREELY",
		"hold": 6.5,
	},
	{
		"head": "A NOTE", "color": CREAM,
		"sub": "INDEPENDENT DEVELOPMENT",
		"body": "This game is developed by a single person.\n\nIt is an independent project focused on atmosphere, tension and psychological horror in the Backrooms, built for players who want a slower, more oppressive experience.\n\nThank you for playing.",
		"hold": 6.5,
	},
]

var font: FontFile = load("res://fonts/vcr.ttf")
var root: Control
var bg: ColorRect
var hint: Label
var grain: ColorRect
var logo: Control
var logo_live := false     # the logo's tube is lit: it stutters now and then
var hum: AudioStreamPlayer
var tv: ColorRect
var tv_audio: AudioStreamPlayer
var tv_sample := 0
var clock := 0.0
var shown_at := 0.0
var skip := false
var skip_all := false

func _ready() -> void:
	layer = 100
	root = Control.new()
	add_child(root)
	_full(root)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	bg = ColorRect.new()
	bg.color = Color.BLACK
	root.add_child(bg)
	_full(bg)
	hint = _label("PRESS ANY KEY TO SKIP  /  ESC TO SKIP ALL", 15, CREAM, 3)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hint.position -= Vector2(56, 46)
	hint.modulate.a = 0.0
	root.add_child(hint)
	grain = ColorRect.new()
	grain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grain.material = ShaderMaterial.new()
	grain.material.shader = _grain_shader()
	root.add_child(grain)
	_full(grain)
	hum = _player("res://audio/hum_diffuse.wav", -60.0)
	if hum:
		hum.finished.connect(hum.play)
		hum.play()
		create_tween().tween_property(hum, "volume_db", HUM_DB, 3.0)
	_run()

# ---- sequence -------------------------------------------------------------------------
func _run() -> void:
	await _wait(0.8)                       # a beat of black before anything shows
	for c in CARDS:
		if skip_all:
			break
		await _show(_card(c), c["hold"])
	if not skip_all:
		await _logo()
	await _tv_on()
	done.emit()
	queue_free()

## Fade a card up, hold it, fade it out. A skip cuts the hold and uses a quick fade.
func _show(card: Control, hold: float) -> void:
	skip = false
	shown_at = clock
	var tw := create_tween()
	tw.tween_property(card, "modulate:a", 1.0, 1.0).set_trans(Tween.TRANS_SINE)
	await _wait(1.0 + hold)
	tw.kill()
	var out := 0.2 if skip or skip_all else 0.8
	var tw_out := create_tween()
	tw_out.tween_property(card, "modulate:a", 0.0, out).set_trans(Tween.TRANS_SINE)
	await tw_out.finished
	card.queue_free()
	skip = false
	await _wait(0.4)

## The title strikes like a tube coming on, hums a while under a stutter, and dies back to black.
func _logo() -> void:
	skip = false
	shown_at = clock
	logo = _build_logo()
	_sfx("res://audio/tube_restrike.wav", -6.0)
	if hum:
		create_tween().tween_property(hum, "volume_db", -16.0, 0.6)
	for step in [[1.0, 0.05], [0.0, 0.09], [0.7, 0.04], [0.0, 0.2], [1.0, 0.06], [0.15, 0.1], [1.0, 0.0]]:
		logo.modulate.a = step[0]
		await _wait(step[1])
		if skip or skip_all:
			break
	logo.modulate.a = 1.0
	logo_live = true
	await _wait(3.0)
	logo_live = false
	if hum:
		create_tween().tween_property(hum, "volume_db", -60.0, 0.5)
	for a in [0.2, 1.0, 0.0, 0.5, 0.0]:
		logo.modulate.a = a
		await get_tree().create_timer(0.05).timeout
	logo.queue_free()
	skip = false
	await _wait(0.5)

## A CRT switching on, done on the real rendered menu: the power click and the degauss coil's thump, the
## tube firing as a white-hot line, the vertical sweep opening it out (overshooting a touch before it
## settles), the picture overexposed, soft and full of snow while vertical hold rolls it a few times and
## locks, then the glare calming down to the normal picture.
func _tv_on() -> void:
	skip = false
	shown_at = clock
	create_tween().tween_property(hint, "modulate:a", 0.0, 0.2)
	if hum:
		hum.stop()
	var copy := BackBufferCopy.new()      # fresh grab of the menu: its own CRT pass already took the screen copy
	copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	root.add_child(copy)
	tv = ColorRect.new()
	tv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tv.material = ShaderMaterial.new()
	tv.material.shader = _tv_shader()
	root.add_child(tv)
	_full(tv)
	root.move_child(grain, -1)
	_tv_frame(0.0)
	bg.visible = false                     # the tube's own black takes over from here
	reveal.emit()
	_sfx("res://audio/flash_click_on.wav", -4.0)
	_start_tv_audio()
	var tw := create_tween()
	tw.tween_method(_tv_frame, 0.0, TV_TIME, TV_TIME)
	tw.parallel().tween_property(grain, "modulate:a", 0.0, TV_TIME * 0.8)
	while tw.is_running() and not skip:
		await get_tree().process_frame
	if tw.is_running():
		tw.custom_step(TV_TIME)

## Drive the tube shader at `t` seconds after power-on
func _tv_frame(t: float) -> void:
	var m: ShaderMaterial = tv.material
	var sweep := 1.0 - pow(1.0 - clampf((t - 0.22) / 0.5, 0.0, 1.0), 3.0)
	var v := lerpf(0.0025, 1.0, sweep)
	if t > 0.72:                           # deflection overshoots and rings down
		v = 1.0 + 0.045 * exp(-(t - 0.72) * 5.0) * sin((t - 0.72) * 22.0)
	var since := maxf(t - 0.2, 0.0)
	m.set_shader_parameter("lit", 0.0 if t < 0.1 else 1.0)
	m.set_shader_parameter("v_scale", v)
	m.set_shader_parameter("h_scale", lerpf(0.55, 1.0, smoothstep(0.1, 0.24, t)) + 0.008 * sin(t * 40.0) * exp(-t * 3.0))
	m.set_shader_parameter("hot", 1.0 - smoothstep(0.16, 0.6, t))
	m.set_shader_parameter("bright", 1.0 + 3.5 * exp(-since * 3.2) + 0.06 * sin(t * 47.0) * exp(-t * 1.5))
	m.set_shader_parameter("blur", 0.006 * exp(-since * 2.5))
	m.set_shader_parameter("noise", 0.55 * exp(-maxf(t - 0.15, 0.0) * 3.5))
	# vertical hold: the picture rolls, slowing, then snaps into lock
	m.set_shader_parameter("roll", 0.45 * exp(-maxf(t - 0.3, 0.0) * 3.0) if t < 1.35 else 0.0)
	m.set_shader_parameter("fade", 1.0 - smoothstep(1.8, TV_TIME, t))

## The set's power-on noise, synthesised: degauss "bwong" (a clipped 50 Hz buzz), a burst of static with
## the odd crackle, and the flyback transformer's faint whine.
func _start_tv_audio() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = TV_RATE
	gen.buffer_length = 0.1
	tv_audio = AudioStreamPlayer.new()
	tv_audio.stream = gen
	tv_audio.volume_db = -6.0
	add_child(tv_audio)
	tv_audio.play()
	tv_sample = 0
	_feed_tv_audio()

func _feed_tv_audio() -> void:
	var pb := tv_audio.get_stream_playback() as AudioStreamGeneratorPlayback
	for i in pb.get_frames_available():
		var t := tv_sample / TV_RATE
		tv_sample += 1
		var x := 0.0
		var d := t - 0.06
		if d > 0.0:
			x += clampf(sin(TAU * 50.0 * d) * 3.0, -1.0, 1.0) * 0.22 * exp(-d * 4.5)
			x += sin(TAU * 100.0 * d) * 0.12 * exp(-d * 3.0)
		if t > 0.1:
			x += (randf() * 2.0 - 1.0) * 0.16 * exp(-(t - 0.1) * 3.0)
			if randf() < 0.0004:
				x += randf_range(-0.5, 0.5)
		x += sin(TAU * 15734.0 * t) * 0.012 * clampf((t - 0.15) * 3.0, 0.0, 1.0)
		x *= 1.0 - smoothstep(1.8, TV_TIME, t)
		pb.push_frame(Vector2(x, x))

## Wait `sec` seconds of our own clock, cut short by a skip
func _wait(sec: float) -> void:
	var end := clock + sec
	while clock < end and not skip and not skip_all:
		await get_tree().process_frame

func _input(e: InputEvent) -> void:
	if not (e is InputEventKey or e is InputEventMouseButton or e is InputEventJoypadButton):
		return
	get_viewport().set_input_as_handled()  # nothing reaches the menu underneath while this runs
	if not e.is_pressed() or e.is_echo() or clock - shown_at < MIN_SHOW:
		return
	if e is InputEventKey and e.physical_keycode == KEY_ESCAPE:
		skip_all = true
	skip = true

func _process(dt: float) -> void:
	clock += dt
	if bg.visible:                         # the hint blinks until the CRT starts switching on
		hint.modulate.a = clampf(clock - 1.5, 0.0, 1.0) * (0.3 + 0.12 * sin(clock * 2.4))
	if logo_live and logo:
		logo.modulate.a = 1.0 if randf() > 0.035 else randf_range(0.3, 0.8)
	if tv_audio:
		_feed_tv_audio()

# ---- building -------------------------------------------------------------------------
func _card(c: Dictionary) -> Control:
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.modulate.a = 0.0
	root.add_child(center)
	root.move_child(center, grain.get_index())
	_full(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 18)
	center.add_child(col)
	if c.get("icon", false):
		col.add_child(_warn_icon())
	col.add_child(_label(c["head"], 46, c["color"], 20))
	col.add_child(_rule(420))
	col.add_child(_label(c["sub"], 22, CREAM, 6))
	col.add_child(_spacer(16))
	var body := _label(c["body"], 23, DIM, 1)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size.x = 1180
	body.add_theme_constant_override("line_spacing", 10)
	col.add_child(body)
	if c.has("foot"):
		col.add_child(_spacer(20))
		col.add_child(_label(c["foot"], 16, FAINT, 4))
	return center

func _build_logo() -> Control:
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.modulate.a = 0.0
	root.add_child(center)
	root.move_child(center, grain.get_index())
	_full(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 26)
	center.add_child(col)
	var title := _label("THE BACKROOMS", 124, Color("ece3bf"), 28)
	title.add_theme_constant_override("outline_size", 5)   # VCR has no bold: a same-colour outline thickens the strokes
	title.add_theme_color_override("font_outline_color", Color("ece3bf"))
	for f in [[Vector2(-4, 0), Color(1, 0.1, 0.1, 0.35)], [Vector2(4, 1), Color(0.1, 0.4, 1, 0.35)]]:
		var fringe := _label("THE BACKROOMS", 124, f[1], 28)
		fringe.add_theme_constant_override("outline_size", 5)
		fringe.add_theme_color_override("font_outline_color", f[1])
		fringe.position = f[0]
		fringe.show_behind_parent = true
		title.add_child(fringe)
	col.add_child(title)
	col.add_child(_rule(760))
	return center

func _warn_icon() -> Control:
	var box := Control.new()
	box.custom_minimum_size = Vector2(72, 64)
	box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var tri := Line2D.new()
	tri.points = PackedVector2Array([Vector2(36, 3), Vector2(69, 61), Vector2(3, 61)])
	tri.closed = true
	tri.width = 3.0
	tri.default_color = RED
	tri.joint_mode = Line2D.LINE_JOINT_ROUND
	box.add_child(tri)
	var bang := _label("!", 34, RED)
	bang.position = Vector2(0, 18)
	bang.size = Vector2(72, 40)
	bang.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.add_child(bang)
	return box

func _rule(w: float) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(CREAM, 0.25)
	r.custom_minimum_size = Vector2(w, 1)
	r.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return r

func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = h
	return c

func _label(text: String, size: int, color: Color, spacing := 0.0) -> Label:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", fv)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _full(c: Control) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _player(path: String, db: float) -> AudioStreamPlayer:
	if not ResourceLoader.exists(path):
		return null
	var p := AudioStreamPlayer.new()
	p.stream = load(path)
	p.volume_db = db
	add_child(p)
	return p

## One-shot sound. `outlive` parents it to the menu so it keeps playing after this overlay is freed.
func _sfx(path: String, db: float, outlive := false) -> void:
	var p := _player(path, db)
	if not p:
		return
	if outlive:
		p.reparent(get_parent())
	p.finished.connect(p.queue_free)
	p.play()

## The tube: the screen as rendered underneath, squeezed by the vertical sweep, rolled by vertical hold,
## overexposed, blurred and snowy; outside the sweep it is black with the beam's glow bleeding into it.
func _tv_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float lit = 0.0;        // 0 until the tube fires
uniform float v_scale = 1.0;    // height of the picture, 1 = full frame
uniform float h_scale = 1.0;
uniform float hot = 0.0;        // 1 = still a white-hot beam line
uniform float bright = 1.0;     // overexposure
uniform float blur = 0.0;
uniform float noise = 0.0;
uniform float roll = 0.0;       // vertical hold offset, 0 = locked
uniform float fade = 1.0;       // 0 = hand the untouched picture back

float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

vec3 pic(vec2 uv) {
	vec3 c = texture(screen_tex, uv).rgb * 0.4;
	c += texture(screen_tex, clamp(uv + vec2(blur, 0.0), 0.001, 0.999)).rgb * 0.15;
	c += texture(screen_tex, clamp(uv - vec2(blur, 0.0), 0.001, 0.999)).rgb * 0.15;
	c += texture(screen_tex, clamp(uv + vec2(0.0, blur), 0.001, 0.999)).rgb * 0.15;
	c += texture(screen_tex, clamp(uv - vec2(0.0, blur), 0.001, 0.999)).rgb * 0.15;
	return c;
}

void fragment() {
	vec3 orig = texture(screen_tex, UV).rgb;
	float tt = floor(TIME * 30.0);
	float half_h = v_scale * 0.5;
	float dy = UV.y - 0.5;
	float inside = step(abs(dy), half_h);
	vec2 uv = vec2((UV.x - 0.5) / h_scale + 0.5, fract(dy / max(v_scale, 0.001) + 0.5 - roll));
	uv.x += (h(vec2(tt, floor(uv.y * 240.0))) - 0.5) * 0.02 * noise;     // unlocked lines tear sideways
	float in_x = step(0.0, uv.x) * step(uv.x, 1.0);
	vec2 cuv = clamp(uv, 0.001, 0.999);
	vec2 ca = vec2(0.0015 + blur * 0.5, 0.0);
	vec3 col = vec3(pic(cuv + ca).r, pic(cuv).g, pic(cuv - ca).b);

	// overexposed phosphor glare, then the white-hot beam while it is still a line
	float l = dot(col, vec3(0.3, 0.59, 0.11));
	col = col * bright + vec3(0.85, 0.9, 1.0) * l * (bright - 1.0) * 0.35;
	col = mix(col, vec3(1.0, 0.98, 0.93) * 2.0, hot);
	col *= mix(1.0, smoothstep(0.0, 0.25, uv.x) * smoothstep(1.0, 0.75, uv.x), hot);

	float n = h(floor(FRAGCOORD.xy / 2.0) + tt * 7.1);
	col = mix(col, vec3(n) * (0.6 + bright * 0.2), noise);
	// the vertical blanking bar rolls through with the picture until it locks
	float seam = min(uv.y, 1.0 - uv.y);
	col *= mix(1.0, smoothstep(0.0, 0.04, seam), step(0.002, abs(roll)) * (1.0 - hot));
	col *= inside * in_x;

	float out_d = max(abs(dy) - half_h, 0.0);
	col += vec3(1.0, 0.97, 0.9) * exp(-out_d / 0.012) * (1.0 - inside) * (hot * 1.2 + (bright - 1.0) * 0.08);
	col *= 0.92 + 0.08 * sin(FRAGCOORD.y * 3.14159);
	col *= lit;
	COLOR = vec4(mix(orig, col, fade), 1.0);
}
"""
	return s

## Film grain, faint scanlines and a vignette over everything the boot shows
func _grain_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type canvas_item;
float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	float g = h(FRAGCOORD.xy + floor(TIME * 24.0) * 13.7);
	float lines = 0.5 + 0.5 * sin(FRAGCOORD.y * 3.14159);
	float vig = smoothstep(0.3, 0.8, length(UV - 0.5));
	COLOR = vec4(vec3(g) * (1.0 - vig), (0.045 + 0.035 * lines + vig * 0.55) * COLOR.a);   // COLOR.a carries the fade
}
"""
	return s
