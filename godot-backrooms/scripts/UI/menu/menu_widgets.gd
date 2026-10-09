extends Control
## The menu, part 1: its look and its saved settings. Colours, fonts and the small widget builders
## (labels, underlined link buttons, sliders, text fields, key caps) every panel is made of, plus loading
## and saving user://settings.cfg (sensitivity, FOV, head bob, volumes, callsign, last address).

const CREAM := Color("e6e1cd")
const TITLE := Color("d8d3bd")
const RED := Color("c4271f")
const LINK_DIM := Color(0.9, 0.882, 0.804, 0.7)
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
var cam_shake := true
var cam_variation := true
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
	# Plain underlined text, no box. A red underline wipes in from the left on hover and stays
	# drawn while the link is active (open panel, chosen preset); the text eases to white with it.
	var b := Button.new()
	b.text = text.to_upper()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", _font(3))
	b.add_theme_font_size_override("font_size", 12)
	var faint := _underline(Color(0.9, 0.882, 0.804, 0.25))
	for s in ["normal", "hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(s, faint)
	_tint(LINK_DIM, b)
	var bar := ColorRect.new()
	bar.color = RED
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -1
	bar.offset_bottom = 0
	bar.scale.x = 0.001           # never exactly 0: a zero-scale transform has no inverse
	b.add_child(bar)
	b.set_meta("bar", bar)
	b.mouse_entered.connect(func():
		b.set_meta("hover", true)
		_link_state(b))
	b.mouse_exited.connect(func():
		b.set_meta("hover", false)
		_link_state(b))
	b.pressed.connect(_click)
	return b

func _set_link_active(b: Button, on: bool) -> void:
	if b.get_meta("active", false) == on and b.has_meta("tw"):
		return
	b.set_meta("active", on)
	_link_state(b)

func _link_state(b: Button) -> void:
	var lit: bool = b.get_meta("hover", false) or b.get_meta("active", false)
	var old: Tween = b.get_meta("tw") if b.has_meta("tw") else null   # a null default still errors when missing
	if old and old.is_valid():
		old.kill()
	var tw := b.create_tween().set_parallel(true)
	tw.tween_property(b.get_meta("bar"), "scale:x", 1.0 if lit else 0.001, 0.22 if lit else 0.3) \
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(_tint.bind(b), b.get_theme_color("font_color"), Color.WHITE if lit else LINK_DIM, 0.18)
	b.set_meta("tw", tw)

## Same colour in every state, so the hover fade is ours and not the theme's instant swap
func _tint(c: Color, b: Button) -> void:
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(n, c)

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
func _split_title(text: String, size: int, spacing := 4.0) -> Label:
	var main := _label(text, size, TITLE, spacing)
	for fringe in [[Vector2(2, 0), Color(0.627, 0.078, 0.059, 0.4)], [Vector2(-2, 0), Color(0.157, 0.353, 0.431, 0.28)]]:
		var s := _label(text, size, fringe[1], spacing)
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
	var dim := Color(0.9, 0.882, 0.804, 0.75)
	_tint(dim, b)
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	b.mouse_entered.connect(func(): _fade_tint(b, Color.WHITE, 0.15))
	b.mouse_exited.connect(func(): _fade_tint(b, dim, 0.25))
	return b

func _fade_tint(b: Button, to: Color, dur: float) -> void:
	var old: Tween = b.get_meta("tint_tw") if b.has_meta("tint_tw") else null   # a null default still errors when missing
	if old and old.is_valid():
		old.kill()
	var tw := b.create_tween()
	tw.tween_method(_tint.bind(b), b.get_theme_color("font_color"), to, dur)
	b.set_meta("tint_tw", tw)

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
static func _flicker(x: float) -> float:
	if x < 0.2: return 0.85 * x / 0.2
	if x < 0.35: return 0.15
	if x < 0.5: return 1.0
	if x < 0.62: return 0.45
	return 1.0

# ---- motion helpers (static: the title screen, main_menu.gd, shares them) ----------------------
## Jump a running tween to its end state, so nothing is left half-faded when it gets replaced
static func _finish(tw: Tween) -> void:
	if tw and tw.is_valid():
		tw.custom_step(100.0)
		tw.kill()

## Fade a list of items in one after another (container-safe: only touches modulate)
static func _stagger(tw: Tween, items: Array, delay: float, step: float, dur := 0.3) -> void:
	for i in items.size():
		var c: CanvasItem = items[i]
		c.modulate.a = 0.0
		tw.tween_property(c, "modulate:a", 1.0, dur).set_delay(delay + i * step) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## OSD-style typing: characters appear left to right. Shaped on the full text first, so the label
## keeps its final size while it types and nothing around it shifts.
static func _type_in(tw: Tween, l: Label, delay: float, dur: float) -> void:
	l.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	l.visible_ratio = 0.0
	tw.tween_property(l, "visible_ratio", 1.0, dur).set_delay(delay)

## The title's red / teal fringes start torn apart and settle onto the letters, like tape tracking
## locking in, while the title itself flickers on.
static func _lock_in(tw: Tween, title: Label, fringes: Array, delay: float, dur: float, spread: float) -> void:
	fringes[0].position = Vector2(spread, 0)
	fringes[1].position = Vector2(-spread * 0.8, 0)
	title.modulate.a = 0.0
	tw.tween_property(fringes[0], "position", Vector2(2, 0), dur).set_delay(delay).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(fringes[1], "position", Vector2(-2, 0), dur).set_delay(delay).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(x: float): title.modulate.a = _flicker(x), 0.0, 1.0, dur * 0.6).set_delay(delay)

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
	cam_shake = bool(cf.get_value("controls", "cam_shake", true))
	cam_variation = bool(cf.get_value("controls", "cam_variation", true))
	callsign = str(cf.get_value("player", "callsign", ""))
	last_address = str(cf.get_value("net", "address", ""))

func _save() -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)
	for k in volumes:
		cf.set_value("volume", k, volumes[k])
	cf.set_value("controls", "sensitivity", sensitivity)
	cf.set_value("controls", "fov", fov)
	cf.set_value("controls", "head_bob", head_bob)
	cf.set_value("controls", "cam_shake", cam_shake)
	cf.set_value("controls", "cam_variation", cam_variation)
	cf.set_value("player", "callsign", callsign)
	cf.set_value("net", "address", last_address)
	cf.save(SETTINGS_PATH)
