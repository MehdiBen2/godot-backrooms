extends Control
## Title screen + level loading. A slow-drifting still of the level (textures/menu_bg.png, rendered by
## tools/capture_menu_bg.gd) behind the same VCR / found-footage styling as the in-game start screen.
## PLAY fades to a loading screen, streams scenes/main.tscn on a thread, then drops straight into the run.

const CREAM := Color("e6e1cd")
const TITLE := Color("d8d3bd")
const RED := Color("c4271f")
const BG_PATH := "res://textures/menu_bg.png"
const MAIN_SCENE := "res://scenes/main.tscn"
const MIN_LOAD := 2.6                   # never flash the loading screen; also lets the bar read
const TIPS := [
	"The hum is not always the lights.",
	"Batteries stack. Tab to use them.",
	"Crouching muffles your steps.",
	"If it stops moving, do not look away.",
	"Not every corridor leads somewhere.",
	"Archive papers explain what the map will not.",
	"Sprinting costs stamina. Fear costs more.",
]

var font: FontFile = load("res://fonts/vcr.ttf")
var bg: TextureRect
var title_label: Label
var fringes: Array
var glitch_left := 0.0
var next_glitch := 2.0
var glitch_tick := 0.0
var buttons: Array[Button] = []
var menu_box: Control
var loading_root: Control
var load_bar: ColorRect
var load_pct: Label
var load_tip: Label
var load_dot: ColorRect
var loading := false
var load_t := 0.0
var shown_progress := 0.0
var tip_t := 0.0
var t := 0.0
var click: AudioStreamPlayer
var music: AudioStreamPlayer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build()
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 1.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_start_music()

# ---- helpers ------------------------------------------------------------------
func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	return fv

func _label(text: String, size: int, color: Color, spacing := 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _full(c: Control) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _gradient(colors: PackedColorArray, offsets: PackedFloat32Array, radial := false) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = offsets
	g.colors = colors
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 512
	gt.height = 512 if radial else 1
	if radial:
		gt.fill = GradientTexture2D.FILL_RADIAL
		gt.fill_from = Vector2(0.5, 0.5)
		gt.fill_to = Vector2(1.0, 0.5)
	else:
		gt.fill_from = Vector2(0, 0)
		gt.fill_to = Vector2(1, 0)
	return gt

# ---- layout ---------------------------------------------------------------------
func _build() -> void:
	var back := ColorRect.new()
	back.color = Color(0.02, 0.018, 0.01)
	add_child(back)
	_full(back)

	# The still, slightly oversized so the slow drift never shows an edge
	bg = TextureRect.new()
	if ResourceLoader.exists(BG_PATH):
		bg.texture = load(BG_PATH)
	else:
		bg.texture = _gradient(PackedColorArray([Color(0.16, 0.13, 0.06), Color(0.05, 0.04, 0.02)]), PackedFloat32Array([0.0, 1.0]), true)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	add_child(bg)
	_full(bg)
	bg.pivot_offset = Vector2(960, 540)
	bg.scale = Vector2(1.08, 1.08)
	var drift := create_tween().set_loops()
	drift.tween_property(bg, "position", Vector2(-26, -12), 14.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	drift.tween_property(bg, "position", Vector2(26, 12), 14.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# Left-to-right veil so the text stays readable, then a vignette
	var veil := TextureRect.new()
	veil.texture = _gradient(PackedColorArray([Color(0.012, 0.012, 0.008, 0.92), Color(0.012, 0.012, 0.008, 0.35), Color(0.012, 0.012, 0.008, 0.1)]), PackedFloat32Array([0.0, 0.5, 1.0]))
	veil.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(veil)
	_full(veil)
	var vig := TextureRect.new()
	vig.texture = _gradient(PackedColorArray([Color(0, 0, 0, 0), Color(0, 0, 0, 0.15), Color(0, 0, 0, 0.85)]), PackedFloat32Array([0.35, 0.7, 1.0]), true)
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(vig)
	_full(vig)

	# Camcorder grain + scanlines
	var fx := ColorRect.new()
	var mat := ShaderMaterial.new()
	mat.shader = _fx_shader()
	fx.material = mat
	add_child(fx)
	_full(fx)

	# Text column
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 110 if side in ["left", "right"] else 72)
	add_child(margin)
	_full(margin)
	var col := VBoxContainer.new()
	col.size_flags_vertical = Control.SIZE_SHRINK_END
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(col)
	menu_box = col

	col.add_child(_label("ARCHIVAL FOOTAGE // LEVEL 0", 12, Color(0.9, 0.882, 0.804, 0.55), 4))
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 18)
	col.add_child(sp)
	title_label = _label("THE BACKROOMS", 120, TITLE, 4)
	fringes = []
	for f in [[Vector2(2, 0), Color(0.627, 0.078, 0.059, 0.55)], [Vector2(-2, 0), Color(0.157, 0.353, 0.431, 0.35)]]:
		var s := _label("THE BACKROOMS", 120, f[1], 4)
		s.position = f[0]
		s.show_behind_parent = true
		title_label.add_child(s)
		fringes.append(s)
	col.add_child(title_label)
	var sub := _label("THRESHOLD SECTOR • NON-EUCLIDEAN ZONE", 13, Color(0.9, 0.882, 0.804, 0.5), 5)
	col.add_child(sub)
	var sp2 := Control.new()
	sp2.custom_minimum_size = Vector2(0, 54)
	col.add_child(sp2)

	for item in [["PLAY", _on_play], ["QUIT", func(): get_tree().quit()]]:
		var b := _menu_button(item[0])
		b.pressed.connect(item[1])
		col.add_child(b)
		buttons.append(b)
	var sp3 := Control.new()
	sp3.custom_minimum_size = Vector2(0, 40)
	col.add_child(sp3)
	col.add_child(_label("BUILD 0.1 // TAPE 04", 11, Color(0.9, 0.882, 0.804, 0.3), 3))

	click = AudioStreamPlayer.new()
	click.stream = load("res://audio/ui_click.wav")
	click.volume_db = -6.0
	add_child(click)
	_build_loading()

func _menu_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", _font(8))
	b.add_theme_font_size_override("font_size", 34)
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(n, Color(0.9, 0.882, 0.804, 0.6) if n == "font_color" else Color.WHITE)
	var empty := StyleBoxEmpty.new()
	empty.content_margin_top = 6
	empty.content_margin_bottom = 6
	for n in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(n, empty)
	# a red marker slides in on hover
	b.mouse_entered.connect(func(): b.text = "> " + text)
	b.mouse_exited.connect(func(): b.text = text)
	b.pressed.connect(_click)
	return b

func _build_loading() -> void:
	loading_root = Control.new()
	loading_root.visible = false
	add_child(loading_root)
	_full(loading_root)
	loading_root.mouse_filter = Control.MOUSE_FILTER_STOP
	var black := ColorRect.new()
	black.color = Color(0.008, 0.008, 0.005)
	loading_root.add_child(black)
	_full(black)

	var dot_row := HBoxContainer.new()
	dot_row.add_theme_constant_override("separation", 10)
	dot_row.position = Vector2(110, 72)
	loading_root.add_child(dot_row)
	load_dot = ColorRect.new()
	load_dot.color = RED
	load_dot.custom_minimum_size = Vector2(9, 9)
	var dc := CenterContainer.new()
	dc.add_child(load_dot)
	dot_row.add_child(dc)
	dot_row.add_child(_label("REC", 13, Color(0.9, 0.882, 0.804, 0.7), 4))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.position = Vector2(110, 800)
	box.custom_minimum_size = Vector2(700, 0)
	loading_root.add_child(box)
	box.add_child(_label("LOADING // LEVEL 0", 26, TITLE, 6))
	var track := ColorRect.new()
	track.color = Color(0.9, 0.882, 0.804, 0.15)
	track.custom_minimum_size = Vector2(700, 2)
	box.add_child(track)
	load_bar = ColorRect.new()
	load_bar.color = CREAM
	load_bar.size = Vector2(0, 2)
	track.add_child(load_bar)
	load_pct = _label("0%", 12, Color(0.9, 0.882, 0.804, 0.55), 4)
	box.add_child(load_pct)
	load_tip = _label(TIPS[randi() % TIPS.size()], 14, Color(0.9, 0.882, 0.804, 0.45), 1)
	load_tip.position = Vector2(110, 960)
	loading_root.add_child(load_tip)

func _fx_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type canvas_item;
float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 uv = FRAGCOORD.xy;
	float grain = h(uv + floor(TIME * 24.0) * 17.3) - 0.5;
	float line = 0.5 + 0.5 * sin(uv.y * 1.6);
	float roll = smoothstep(0.0, 0.05, abs(fract(UV.y - TIME * 0.05) - 0.5) - 0.44);
	COLOR = vec4(vec3(0.9, 0.88, 0.8) * max(grain, 0.0), 0.07) + vec4(0.0, 0.0, 0.0, (1.0 - line) * 0.10 + (1.0 - roll) * 0.02);
}
"""
	return s

func _start_music() -> void:
	if not ResourceLoader.exists("res://audio/ambient1.mp3"):
		return
	var stream: AudioStream = load("res://audio/ambient1.mp3")
	if stream is AudioStreamMP3:
		stream.loop = true
	music = AudioStreamPlayer.new()
	music.stream = stream
	music.volume_db = -60.0
	add_child(music)
	music.play()
	create_tween().tween_property(music, "volume_db", -16.0, 3.0)

func _click() -> void:
	click.pitch_scale = randf_range(0.96, 1.04)
	click.play()

# ---- play / loading ----------------------------------------------------------------
func _on_play() -> void:
	if loading:
		return
	loading = true
	load_t = 0.0
	loading_root.visible = true
	loading_root.modulate.a = 0.0
	create_tween().tween_property(loading_root, "modulate:a", 1.0, 0.5)
	if music:
		create_tween().tween_property(music, "volume_db", -60.0, 1.5)
	ResourceLoader.load_threaded_request(MAIN_SCENE)

func _finish_loading() -> void:
	var packed := ResourceLoader.load_threaded_get(MAIN_SCENE) as PackedScene
	Game.respawned = true              # straight into the run: the title screen is this scene
	get_tree().change_scene_to_packed(packed)

func _unhandled_input(e: InputEvent) -> void:
	if not loading and e is InputEventKey and e.pressed and not e.echo and e.physical_keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		_click()
		_on_play()

# ---- per-frame -----------------------------------------------------------------------
func _process(dt: float) -> void:
	t += dt
	if loading:
		_process_loading(dt)
	else:
		_update_glitch(dt)

func _process_loading(dt: float) -> void:
	load_t += dt
	var prog := []
	var status := ResourceLoader.load_threaded_get_status(MAIN_SCENE, prog)
	var real: float = prog[0] if prog.size() > 0 else 0.0
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		real = 1.0
	# eased and time-paced so the bar always reads as work, never a jump
	var goal := minf(real, load_t / MIN_LOAD)
	shown_progress += (goal - shown_progress) * (1.0 - exp(-dt * 6.0))
	load_bar.size.x = 700.0 * shown_progress
	load_pct.text = "%d%%" % int(shown_progress * 100.0)
	load_dot.color.a = 1.0 if fmod(t, 1.1) < 0.55 else 0.0
	tip_t += dt
	if tip_t > 3.2:
		tip_t = 0.0
		load_tip.text = TIPS[randi() % TIPS.size()]
	if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		load_pct.text = "LOAD FAILED"
		loading = false
		return
	if status == ResourceLoader.THREAD_LOAD_LOADED and load_t >= MIN_LOAD and shown_progress > 0.97:
		set_process(false)
		load_pct.text = "100%"
		_finish_loading()

# ---- random VHS glitch on the title -------------------------------------------------
func _update_glitch(dt: float) -> void:
	if glitch_left > 0.0:
		glitch_left -= dt
		glitch_tick -= dt
		if glitch_left <= 0.0:
			fringes[0].position = Vector2(2, 0)
			fringes[1].position = Vector2(-2, 0)
			title_label.modulate.a = 1.0
		elif glitch_tick <= 0.0:
			glitch_tick = 0.045
			var kick := randf_range(4.0, 16.0)
			fringes[0].position = Vector2(kick, randf_range(-2, 2))
			fringes[1].position = Vector2(-kick * 0.8, randf_range(-2, 2))
			title_label.modulate.a = randf_range(0.55, 1.0)
		return
	next_glitch -= dt
	if next_glitch <= 0.0:
		glitch_left = randf_range(0.12, 0.4)
		next_glitch = randf_range(2.5, 7.0)
		glitch_tick = 0.0
