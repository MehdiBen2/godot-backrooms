extends Control
## The menu, part 1: its look and its saved settings. Colours, fonts and the small widget builders
## (labels, underlined link buttons, sliders, text fields, key caps) every panel is made of, plus loading
## and saving user://settings.cfg (sensitivity, FOV, head bob, volumes, callsign, last address).

const CREAM := Color("e6e1cd")
const TITLE := Color("d8d3bd")
const RED := Color("c4271f")
const SETTINGS_PATH := "user://settings.cfg"
const SENS_BASE := 0.0022
const SENS_MIN := 1
const SENS_MAX := 20
const SENS_DEFAULT := 10
const FOV_MIN := 60
const FOV_MAX := 100
const FOV_DEFAULT := 75
var font: FontFile = load("res://fonts/vcr.ttf")
var last_address := ""
var click_player: AudioStreamPlayer
var volumes := {"master": 1.0, "ambient": 1.0, "footsteps": 1.0, "hum": 1.0, "breathing": 1.0}
var sensitivity := SENS_DEFAULT
var fov := FOV_DEFAULT
var head_bob := true
var callsign := ""
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

func _box(fill: Color, border := Color(0, 0, 0, 0), bw := Vector4.ZERO) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.border_width_left = int(bw.x); sb.border_width_top = int(bw.y)
	sb.border_width_right = int(bw.z); sb.border_width_bottom = int(bw.w)
	return sb

func _underline(color: Color) -> StyleBoxFlat:
	var sb := _box(Color(0, 0, 0, 0), color, Vector4(0, 0, 0, 1))
	sb.content_margin_top = 4; sb.content_margin_bottom = 4
	return sb

func _link_button(text: String) -> Button:
	# Plain underlined text, no box; red underline on hover / when active
	var b := Button.new()
	b.text = text.to_upper()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", _font(3))
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", Color(0.9, 0.882, 0.804, 0.7))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", _underline(Color(0.9, 0.882, 0.804, 0.25)))
	b.add_theme_stylebox_override("hover", _underline(RED))
	b.add_theme_stylebox_override("pressed", _underline(RED))
	b.add_theme_stylebox_override("hover_pressed", _underline(RED))
	b.pressed.connect(_click)
	return b

## Soft, dry UI tick: quiet with a touch of pitch variation so repeats don't sound mechanical
func _click() -> void:
	if click_player == null:
		click_player = AudioStreamPlayer.new()
		click_player.stream = load("res://audio/ui_click.wav")
		click_player.volume_db = -6.0
		add_child(click_player)
	click_player.pitch_scale = randf_range(0.96, 1.04)
	click_player.play()

func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s

# A label with the web's title text-shadow: red fringe right, teal fringe left
func _split_title(text: String, size: int) -> Label:
	var main := _label(text, size, TITLE, 4)
	for fringe in [[Vector2(2, 0), Color(0.627, 0.078, 0.059, 0.55)], [Vector2(-2, 0), Color(0.157, 0.353, 0.431, 0.35)]]:
		var s := _label(text, size, fringe[1], 4)
		s.position = fringe[0]
		s.show_behind_parent = true
		main.add_child(s)
	main.set_meta("fringes", main.get_children())
	return main

func _section_title(text: String, first := false) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.add_child(_spacer(0 if first else 16))
	v.add_child(_label(text, 12, Color(0.9, 0.882, 0.804, 0.45), 4))
	var line := ColorRect.new()
	line.color = Color(0.9, 0.882, 0.804, 0.12)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(line)
	return v

# ---- settings section (js/game/settings.js) -----------------------------------------
func _slider_theme(s: HSlider) -> void:
	var track := _box(Color(0.9, 0.882, 0.804, 0.25))
	track.content_margin_top = 1; track.content_margin_bottom = 1
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", StyleBoxEmpty.new())
	s.add_theme_stylebox_override("grabber_area_highlight", StyleBoxEmpty.new())
	for pair in [["grabber", TITLE], ["grabber_highlight", RED]]:
		var img := Image.create(8, 14, false, Image.FORMAT_RGBA8)
		img.fill(pair[1])
		s.add_theme_icon_override(pair[0], ImageTexture.create_from_image(img))

func _slider_row(name: String, lo: int, hi: int, value: int, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var n := _label(name.to_upper(), 12, Color(0.9, 0.882, 0.804, 0.75), 2)
	n.custom_minimum_size = Vector2(104, 0)
	n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(n)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# the row band is the target, not the 2px line drawn in the middle of it
	s.custom_minimum_size = Vector2(0, 26)
	s.focus_mode = Control.FOCUS_NONE
	_slider_theme(s)
	row.add_child(s)
	var v := _label(str(value), 12, Color(0.9, 0.882, 0.804, 0.6), 2)
	v.custom_minimum_size = Vector2(30, 0)
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	s.value_changed.connect(func(x: float):
		v.text = str(int(x))
		on_change.call(int(x)))
	return row

# ---- multiplayer section (scripts/Net/net.gd) ------------------------------------------
func _text_field(placeholder: String, value: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = value
	e.context_menu_enabled = false
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.add_theme_font_override("font", _font(1))
	e.add_theme_font_size_override("font_size", 13)
	e.add_theme_color_override("font_color", CREAM)
	e.add_theme_color_override("font_uneditable_color", CREAM)
	e.add_theme_color_override("font_placeholder_color", Color(0.9, 0.882, 0.804, 0.25))
	e.add_theme_color_override("caret_color", CREAM)
	e.add_theme_stylebox_override("normal", _underline(Color(0.9, 0.882, 0.804, 0.3)))
	e.add_theme_stylebox_override("focus", _underline(RED))
	e.add_theme_stylebox_override("read_only", _underline(Color(0.9, 0.882, 0.804, 0.3)))
	return e

func _hint(text: String) -> Label:
	var l := _label(text, 11, Color(0.9, 0.882, 0.804, 0.45))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(300, 0)
	return l

func _opt_index(opts: Array, key: String) -> int:
	for i in opts.size():
		if opts[i][0] == Gfx.s.get(key):
			return i
	return 0

func _padded(c: Control, v := 5) -> Control:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", v)
	m.add_theme_constant_override("margin_bottom", v)
	m.add_child(c)
	return m

func _gfx_row(title: String, value: Control) -> Control:
	# One band per setting with no dead gaps: the row is as tall as the old row + its margins,
	# the label fills it, and the two controls touch each other.
	var row := HBoxContainer.new()
	var n := _row_title(title)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if value is BaseButton:
		n.pressed.connect(func(): (value as BaseButton).pressed.emit())
	row.add_child(n)
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(value)
	row.custom_minimum_size = Vector2(0, 29)
	return row

## A row label that looks like a label but takes the click like the control beside it
func _row_title(text: String) -> Button:
	var b := Button.new()
	b.text = text.to_upper()
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", _font(2))
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", Color(0.9, 0.882, 0.804, 0.75))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	return b

# ---- controls section --------------------------------------------------------------
func _kbd(text: String) -> Control:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _box(Color(0.9, 0.882, 0.804, 0.06), Color(0.9, 0.882, 0.804, 0.25), Vector4(1, 1, 1, 3))
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 7; sb.content_margin_right = 7
	sb.content_margin_top = 2; sb.content_margin_bottom = 1
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(26, 0)
	var l := _label(text, 11, TITLE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p

## Alpha curve for the power-on: dim, blink out, flash, settle
func _flicker(x: float) -> float:
	if x < 0.2: return 0.85 * x / 0.2
	if x < 0.35: return 0.15
	if x < 0.5: return 1.0
	if x < 0.62: return 0.45
	return 1.0

# ---- persistence ------------------------------------------------------------------------------
func mouse_sens() -> float:
	return SENS_BASE * (float(sensitivity) / SENS_DEFAULT)

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return
	for k in volumes:
		volumes[k] = clampf(float(cf.get_value("volume", k, volumes[k])), 0.0, 1.0)
	sensitivity = clampi(int(cf.get_value("controls", "sensitivity", SENS_DEFAULT)), SENS_MIN, SENS_MAX)
	fov = clampi(int(cf.get_value("controls", "fov", FOV_DEFAULT)), FOV_MIN, FOV_MAX)
	head_bob = bool(cf.get_value("controls", "head_bob", true))
	callsign = str(cf.get_value("player", "callsign", ""))
	last_address = str(cf.get_value("net", "address", ""))

func _save() -> void:
	var cf := ConfigFile.new()
	for k in volumes:
		cf.set_value("volume", k, volumes[k])
	cf.set_value("controls", "sensitivity", sensitivity)
	cf.set_value("controls", "fov", fov)
	cf.set_value("controls", "head_bob", head_bob)
	cf.set_value("player", "callsign", callsign)
	cf.set_value("net", "address", last_address)
	cf.save(SETTINGS_PATH)
