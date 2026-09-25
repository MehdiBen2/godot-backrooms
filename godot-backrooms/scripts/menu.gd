extends Control
## Start / pause menu, replicating the web game's #start-screen (backrooms.html + css/style.css,
## js/game/settings.js): dark left-to-right veil over the live view, REC tag, big VCR title with a
## red/blue split, sub line, lore, callsign field, blinking action line, Settings / Controls links
## and a side panel. Built for a 1920x1080 canvas so pixel sizes match the browser.

signal settings_changed

const CREAM := Color("e6e1cd")
const TITLE := Color("d8d3bd")
const RED := Color("c4271f")
const SETTINGS_PATH := "user://settings.cfg"
const SENS_BASE := 0.0022
const SENS_MIN := 1
const SENS_MAX := 20
const SENS_DEFAULT := 10
const VOLUME_CHANNELS := [["master", "Master"], ["footsteps", "Footsteps"], ["hum", "Hum"], ["breathing", "Breathing"]]
const CONTROLS := [
	[["W", "A", "S", "D"], "Move", "ZQSD and arrows work too"],
	[["Mouse"], "Look", ""],
	[["Shift"], "Sprint", "30 s of stamina"],
	[["Tab"], "Inventory", "Stack & use batteries (+25%)"],
	[["Space"], "Jump", ""],
	[["C"], "Crouch", ""],
	[["F"], "Flashlight", ""],
	[["N"], "Archive notes", "20 new pages per area found"],
	[["P"], "Papers", "View collected archive papers"],
	[["Esc"], "Release cursor", ""],
]

var font: FontFile = load("res://fonts/vcr.ttf")
var title_label: Label
var sub_label: Label
var lore_label: Label
var action_label: Label
var action_cursor: ColorRect
var tag_dot: ColorRect
var name_input: LineEdit
var panel: PanelContainer
var panel_title: Label
var sections := {}                      # name -> Control
var nav_buttons := {}                   # name -> Button
var open_section := ""
var t := 0.0
var blur_mat: ShaderMaterial
var shown := false
var fade: Tween

var volumes := {"master": 1.0, "footsteps": 1.0, "hum": 1.0, "breathing": 1.0}
var sensitivity := SENS_DEFAULT
var callsign := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE      # clicks on the empty veil fall through to "resume"
	_load()
	_build()
	_show_panel("")

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
	return b

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

# ---- layout ---------------------------------------------------------------------
func _build() -> void:
	# Veil: rgba(3,3,2) 0.94 -> 0.7 -> 0.6, left to right
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([Color(0.012, 0.012, 0.008, 0.94), Color(0.012, 0.012, 0.008, 0.7), Color(0.012, 0.012, 0.008, 0.6)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 512
	gt.height = 1
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	var blur := ColorRect.new()
	blur_mat = ShaderMaterial.new()
	blur_mat.shader = load("res://scripts/menu_blur.gdshader")
	blur.material = blur_mat
	blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(blur)
	blur.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var veil := TextureRect.new()
	veil.texture = gt
	veil.stretch_mode = TextureRect.STRETCH_SCALE
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(veil)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 110)
	margin.add_theme_constant_override("margin_right", 110)
	margin.add_theme_constant_override("margin_top", 72)
	margin.add_theme_constant_override("margin_bottom", 72)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var layout := HBoxContainer.new()
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_theme_constant_override("separation", 48)
	margin.add_child(layout)

	# --- left column ---
	var main := VBoxContainer.new()
	main.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.size_flags_vertical = Control.SIZE_SHRINK_END
	main.custom_minimum_size = Vector2(544, 0)
	layout.add_child(main)

	var tag := HBoxContainer.new()
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_constant_override("separation", 10)
	tag_dot = ColorRect.new()
	tag_dot.color = RED
	tag_dot.custom_minimum_size = Vector2(8, 8)
	tag_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot_c := CenterContainer.new()
	dot_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot_c.add_child(tag_dot)
	tag.add_child(dot_c)
	tag.add_child(_label("ARCHIVAL FOOTAGE // LEVEL 0", 12, Color(0.9, 0.882, 0.804, 0.55), 4))
	main.add_child(tag)
	main.add_child(_spacer(18))

	title_label = _split_title("THE BACKROOMS", 104)
	main.add_child(title_label)

	main.add_child(_spacer(22))
	sub_label = _label("THRESHOLD SECTOR • NON-EUCLIDEAN ZONE", 12, Color(0.9, 0.882, 0.804, 0.5), 4)
	main.add_child(sub_label)

	main.add_child(_spacer(22))
	lore_label = _label("Unknown area, unknown location.", 14, Color(0.9, 0.882, 0.804, 0.4))
	lore_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lore_label.custom_minimum_size = Vector2(300, 0)
	main.add_child(lore_label)

	# Callsign
	main.add_child(_spacer(22))
	var name_row := HBoxContainer.new()
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_theme_constant_override("separation", 14)
	name_row.add_child(_label("CALLSIGN", 12, Color(0.9, 0.882, 0.804, 0.5), 3))
	name_input = LineEdit.new()
	name_input.custom_minimum_size = Vector2(240, 0)
	name_input.placeholder_text = "ENTER YOUR NAME"
	name_input.text = callsign
	name_input.max_length = 16
	name_input.context_menu_enabled = false
	name_input.add_theme_font_override("font", _font(2))
	name_input.add_theme_font_size_override("font_size", 14)
	name_input.add_theme_color_override("font_color", CREAM)
	name_input.add_theme_color_override("font_placeholder_color", Color(0.9, 0.882, 0.804, 0.25))
	name_input.add_theme_color_override("caret_color", CREAM)
	name_input.add_theme_stylebox_override("normal", _underline(Color(0.9, 0.882, 0.804, 0.3)))
	name_input.add_theme_stylebox_override("focus", _underline(RED))
	name_input.text_changed.connect(_on_name_changed)
	name_input.text_submitted.connect(func(_s): name_input.release_focus())
	name_row.add_child(name_input)
	main.add_child(name_row)

	# Action line with the blinking block cursor
	main.add_child(_spacer(36))
	var action := HBoxContainer.new()
	action.mouse_filter = Control.MOUSE_FILTER_IGNORE
	action.add_theme_constant_override("separation", 8)
	action_label = _label("CLICK TO ENTER THE LOBBY", 15, CREAM, 4)
	action.add_child(action_label)
	action_cursor = ColorRect.new()
	action_cursor.color = CREAM
	action_cursor.custom_minimum_size = Vector2(8, 15)
	action_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cur_c := CenterContainer.new()
	cur_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cur_c.add_child(action_cursor)
	action.add_child(cur_c)
	main.add_child(action)

	# Section links
	main.add_child(_spacer(26))
	var nav := HBoxContainer.new()
	nav.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nav.add_theme_constant_override("separation", 28)
	for n in ["settings", "controls"]:
		var b := _link_button(n)
		b.pressed.connect(_on_nav.bind(n))
		nav.add_child(b)
		nav_buttons[n] = b
	main.add_child(nav)

	# --- side panel ---
	panel = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.custom_minimum_size = Vector2(360, 0)
	panel.size_flags_vertical = Control.SIZE_SHRINK_END
	var psb := _box(Color(0, 0, 0, 0), Color(0.9, 0.882, 0.804, 0.15), Vector4(1, 0, 0, 0))
	psb.content_margin_left = 26
	panel.add_theme_stylebox_override("panel", psb)
	layout.add_child(panel)

	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 0)
	panel.add_child(pv)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 0)
	panel_title = _label("SETTINGS", 13, Color(0.9, 0.882, 0.804, 0.55), 4)
	panel_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(panel_title)
	var close := _link_button("close")
	close.pressed.connect(func(): _show_panel(""))
	head.add_child(close)
	pv.add_child(head)
	pv.add_child(_spacer(20))
	sections["settings"] = _build_settings()
	sections["controls"] = _build_controls()
	pv.add_child(sections["settings"])
	pv.add_child(sections["controls"])

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
	row.add_child(n)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	_slider_theme(s)
	row.add_child(s)
	var v := _label(str(value), 12, Color(0.9, 0.882, 0.804, 0.6), 2)
	v.custom_minimum_size = Vector2(30, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	s.value_changed.connect(func(x: float):
		v.text = str(int(x))
		on_change.call(int(x)))
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_top", 6)
	pad.add_theme_constant_override("margin_bottom", 6)
	pad.add_child(row)
	return pad

func _build_settings() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.add_child(_section_title("AUDIO", true))
	for ch in VOLUME_CHANNELS:
		var key: String = ch[0]
		v.add_child(_slider_row(ch[1], 0, 100, int(round(volumes[key] * 100.0)), func(x: int):
			volumes[key] = x / 100.0
			_save()
			settings_changed.emit()))
	v.add_child(_section_title("CONTROLS"))
	v.add_child(_slider_row("Mouse Sens", SENS_MIN, SENS_MAX, sensitivity, func(x: int):
		sensitivity = x
		_save()
		settings_changed.emit()))
	return v

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

func _build_controls() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	for c in CONTROLS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		var keys := HBoxContainer.new()
		keys.add_theme_constant_override("separation", 4)
		keys.alignment = BoxContainer.ALIGNMENT_END
		keys.custom_minimum_size = Vector2(116, 0)
		for k in c[0]:
			keys.add_child(_kbd(k))
		row.add_child(keys)
		var names := VBoxContainer.new()
		names.add_theme_constant_override("separation", 0)
		names.add_child(_label(c[1], 13, Color(0.9, 0.882, 0.804, 0.75)))
		if c[2] != "":
			names.add_child(_label(c[2], 11, Color(0.9, 0.882, 0.804, 0.4)))
		row.add_child(names)
		v.add_child(row)
	return v

# ---- panel navigation ------------------------------------------------------------------
func _on_nav(name: String) -> void:
	_show_panel("" if open_section == name else name)

func _show_panel(name: String) -> void:
	open_section = name
	panel.visible = name != ""
	for n in sections:
		sections[n].visible = n == name
	for n in nav_buttons:
		var b: Button = nav_buttons[n]
		var active: bool = n == name
		b.add_theme_stylebox_override("normal", _underline(RED if active else Color(0.9, 0.882, 0.804, 0.25)))
		b.add_theme_color_override("font_color", Color.WHITE if active else Color(0.9, 0.882, 0.804, 0.7))
	if name != "":
		panel_title.text = name.to_upper()

## Fade in (0.45 s) / fade out (0.35 s), matching the web #start-screen opacity transition
func show_menu(on: bool) -> void:
	if on == shown and visible == on:
		return
	shown = on
	if fade: fade.kill()
	fade = create_tween()
	if on:
		visible = true
		modulate.a = 0.0
		fade.tween_property(self, "modulate:a", 1.0, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	else:
		fade.tween_property(self, "modulate:a", 0.0, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		fade.tween_callback(func(): visible = false)

## ESC closes an open panel first (like input.js); returns true if it consumed the key
func close_panel() -> bool:
	if open_section == "":
		return false
	_show_panel("")
	return true

# ---- text --------------------------------------------------------------------------------
func set_text(title: String, sub: String, lore: String, action: String) -> void:
	title_label.text = title
	for f in title_label.get_meta("fringes"):
		f.text = title
	sub_label.text = sub
	lore_label.text = lore
	action_label.text = action

func release_focus_all() -> void:
	name_input.release_focus()

func _on_name_changed(s: String) -> void:
	var caret := name_input.caret_column
	callsign = s.to_upper()
	if callsign != s:
		name_input.text = callsign
		name_input.caret_column = caret
	_save()

func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	t += dt
	var on := fmod(t, 1.1) < 0.55        # animation: blink 1.1s steps(1)
	tag_dot.color.a = 1.0 if on else 0.0
	action_cursor.color.a = 1.0 if on else 0.0

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
	callsign = str(cf.get_value("player", "callsign", ""))

func _save() -> void:
	var cf := ConfigFile.new()
	for k in volumes:
		cf.set_value("volume", k, volumes[k])
	cf.set_value("controls", "sensitivity", sensitivity)
	cf.set_value("player", "callsign", callsign)
	cf.save(SETTINGS_PATH)
