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
const VOLUME_CHANNELS := [["master", "Master"], ["ambient", "Ambience"], ["footsteps", "Footsteps"], ["hum", "Hum"], ["breathing", "Breathing"]]
const FOV_MIN := 60
const FOV_MAX := 100
const FOV_DEFAULT := 75
const CONTROLS := [
	[["W", "A", "S", "D"], "Move", "ZQSD and arrows work too"],
	[["Mouse"], "Look", ""],
	[["Shift"], "Sprint", "30 s of stamina"],
	[["Space"], "Jump", ""],
	[["C"], "Crouch", "Ctrl works too. Quieter, and harder to see"],
	[["F"], "Flashlight", "Battery packs on the floor recharge it"],
	[["V"], "Push to talk", "Co-op voice chat"],
	[["F11"], "Fullscreen", "Alt+Enter works too"],
	[["Esc"], "Pause", ""],
]

var font: FontFile = load("res://fonts/vcr.ttf")
var title_label: Label
var sub_label: Label
var lore_label: Label
var action_label: Label
var action_cursor: ColorRect
var tag_dot: ColorRect
var name_input: LineEdit
var mp_addr: LineEdit
var mp_link: LineEdit
var mp_status: Label
var last_address := ""
var panel: PanelContainer
var panel_title: Label
var sections := {}                      # name -> Control
var nav_buttons := {}                   # name -> Button
var open_section := ""
var t := 0.0
var blur_mat: ShaderMaterial
var shown := false
var fade: Tween
var click_player: AudioStreamPlayer
var panel_tween: Tween
var title_static: Control               # VHS tracking bars, only visible during a glitch
var sub_base := ""
var glitch_left := 0.0
var glitch_tick := 0.0
var next_glitch := 2.5

var volumes := {"master": 1.0, "ambient": 1.0, "footsteps": 1.0, "hum": 1.0, "breathing": 1.0}
var sensitivity := SENS_DEFAULT
var fov := FOV_DEFAULT
var head_bob := true
var callsign := ""
var embedded := false                   # title-screen mode: only the Settings / Graphics side panel

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE      # clicks on the empty veil fall through to "resume"
	_load()
	_build()
	_show_panel("")
	if embedded:
		_embed_setup()

## Title-screen mode: keep only the side panel. _build() adds blur, veil, then a margin whose HBox holds
## the main column and the panel, so hide the first three and push the panel to the right edge.
func _embed_setup() -> void:
	get_child(0).visible = false
	get_child(1).visible = false
	var layout: HBoxContainer = get_child(2).get_child(0)
	layout.get_child(0).visible = false
	layout.alignment = BoxContainer.ALIGNMENT_END

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
	blur_mat.shader = load("res://shaders/menu_blur.gdshader")
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
	title_static = Control.new()
	title_static.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_static.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_static.clip_contents = true
	title_static.visible = false
	for i in 7:
		var bar := ColorRect.new()
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title_static.add_child(bar)
	title_label.add_child(title_static)

	main.add_child(_spacer(22))
	sub_label = _label("THRESHOLD SECTOR • NON-EUCLIDEAN ZONE", 12, Color(0.9, 0.882, 0.804, 0.5), 4)
	main.add_child(sub_label)
	sub_base = sub_label.text

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
	for n in ["multiplayer", "voice", "graphics", "settings", "controls"]:
		var b := _link_button(n)
		b.pressed.connect(_on_nav.bind(n))
		nav.add_child(b)
		nav_buttons[n] = b
	var leave := _link_button("main menu")
	leave.pressed.connect(_leave_to_main_menu)
	nav.add_child(leave)
	main.add_child(nav)

	# --- side panel ---
	panel = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.custom_minimum_size = Vector2(360, 0)
	panel.resized.connect(func(): panel.pivot_offset = Vector2(0, panel.size.y))     # grows up from the bottom-left
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
	panel_title = _label("MULTIPLAYER", 13, Color(0.9, 0.882, 0.804, 0.55), 4)
	panel_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(panel_title)
	var close := _link_button("close")
	close.pressed.connect(func(): _show_panel(""))
	head.add_child(close)
	pv.add_child(head)
	pv.add_child(_spacer(20))
	sections["multiplayer"] = _build_multiplayer()
	sections["voice"] = _build_voice()
	sections["graphics"] = _build_graphics()
	sections["settings"] = _build_settings()
	sections["controls"] = _build_controls()
	pv.add_child(sections["multiplayer"])
	pv.add_child(sections["voice"])
	pv.add_child(sections["graphics"])
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
	v.add_child(_section_title("CAMERA"))
	v.add_child(_slider_row("Field of view", FOV_MIN, FOV_MAX, fov, func(x: int):
		fov = x
		_save()
		settings_changed.emit()))
	var bob := _link_button("")
	bob.custom_minimum_size = Vector2(96, 0)
	bob.text = "ON" if head_bob else "OFF"
	bob.pressed.connect(func():
		head_bob = not head_bob
		bob.text = "ON" if head_bob else "OFF"
		_save()
		settings_changed.emit())
	v.add_child(_gfx_row("Head bob", bob))
	v.add_child(_hint("Turn head bob off if the camera sway makes you feel sick."))
	return v

# ---- multiplayer section (scripts/net/net.gd) ------------------------------------------
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

func _build_multiplayer() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.add_child(_section_title("HOST A GAME", true))
	v.add_child(_hint("Start a game and send the link to your friends."))
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override("separation", 22)
	var host_btn := _link_button("host game")
	host_btn.pressed.connect(func(): Net.host())
	var stop_btn := _link_button("disconnect")
	stop_btn.pressed.connect(func(): Net.leave())
	host_row.add_child(host_btn)
	host_row.add_child(stop_btn)
	v.add_child(host_row)

	var link_row := HBoxContainer.new()
	link_row.add_theme_constant_override("separation", 12)
	mp_link = _text_field("LINK APPEARS HERE", Net.tunnel_url)
	mp_link.editable = false
	link_row.add_child(mp_link)
	var copy_btn := _link_button("copy")
	copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(mp_link.text))
	link_row.add_child(copy_btn)
	v.add_child(link_row)

	v.add_child(_section_title("JOIN A GAME"))
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 12)
	mp_addr = _text_field("PASTE THE HOST'S LINK", last_address)
	mp_addr.text_changed.connect(func(s: String):
		last_address = s.strip_edges()
		_save())
	mp_addr.text_submitted.connect(func(_s): _do_join())
	join_row.add_child(mp_addr)
	var join_btn := _link_button("join")
	join_btn.pressed.connect(_do_join)
	join_row.add_child(join_btn)
	v.add_child(join_row)

	v.add_child(_spacer(6))
	mp_status = _label(Net.status, 12, Color(0.9, 0.882, 0.804, 0.7), 2)
	mp_status.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	mp_status.custom_minimum_size = Vector2(300, 0)
	v.add_child(mp_status)
	Net.status_changed.connect(func(s: String): mp_status.text = s)
	Net.tunnel_url_changed.connect(func(u: String): mp_link.text = u)
	return v

func _do_join() -> void:
	mp_addr.release_focus()
	Net.join(mp_addr.text)

# ---- graphics section (scripts/core/graphics.gd) ------------------------------------------
var gfx_refresh: Array[Callable] = []
var gfx_preset_buttons := {}
var gfx_note: Label
var gfx_scale_slider: HSlider

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

# One setting: the value is a link that steps to the next option on each click
func _cycle_row(title: String, key: String, opts: Array) -> Control:
	var b := _link_button("")
	b.custom_minimum_size = Vector2(96, 0)
	b.pressed.connect(func(): Gfx.set_value(key, opts[(_opt_index(opts, key) + 1) % opts.size()][0]))
	gfx_refresh.append(func(): b.text = str(opts[_opt_index(opts, key)][1]).to_upper())
	return _gfx_row(title, b)

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

func _build_graphics() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.add_child(_section_title("QUALITY PRESET", true))
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 20)
	for n in Gfx.ORDER:
		var b := _link_button(n)
		b.pressed.connect(func(): Gfx.set_preset(n))
		presets.add_child(b)
		gfx_preset_buttons[n] = b
	v.add_child(_padded(presets, 8))
	gfx_note = _label("", 11, Color(0.9, 0.882, 0.804, 0.45))
	gfx_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gfx_note.custom_minimum_size = Vector2(300, 0)
	v.add_child(gfx_note)

	v.add_child(_section_title("DISPLAY"))
	var sl := _slider_row("Render scale", 50, 100, int(Gfx.s.scale), func(x: int): Gfx.set_value("scale", x))
	gfx_scale_slider = sl.find_children("*", "HSlider", true, false)[0]
	v.add_child(sl)
	var fs := _link_button("")
	fs.custom_minimum_size = Vector2(96, 0)
	fs.pressed.connect(func(): Gfx.set_fullscreen(DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN))
	gfx_refresh.append(func(): fs.text = "ON" if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else "OFF")
	v.add_child(_gfx_row("Fullscreen", fs))
	var off_on := [[false, "Off"], [true, "On"]]
	v.add_child(_cycle_row("VSync", "vsync", off_on))
	v.add_child(_cycle_row("FPS limit", "fps", [[0, "Unlimited"], [30, "30"], [60, "60"], [120, "120"], [144, "144"]]))
	v.add_child(_cycle_row("Smooth motion", "smooth", off_on))

	v.add_child(_section_title("IMAGE"))
	v.add_child(_cycle_row("Anti-aliasing (MSAA)", "msaa", [[0, "Off"], [2, "2x"], [4, "4x"]]))
	v.add_child(_cycle_row("Edge smoothing (FXAA)", "fxaa", off_on))
	v.add_child(_cycle_row("Texture filtering", "aniso", [[0, "Off"], [2, "2x"], [4, "4x"], [8, "8x"], [16, "16x"]]))
	v.add_child(_cycle_row("Camera effects", "post", [[0, "Low"], [1, "Medium"], [2, "Full"]]))
	v.add_child(_cycle_row("Bloom", "glow", off_on))

	v.add_child(_section_title("LIGHTING"))
	var quality := [[0, "Off"], [1, "Low"], [2, "Medium"], [3, "High"]]
	v.add_child(_cycle_row("Shadows", "shadows", quality))
	v.add_child(_cycle_row("Tube lights", "lights", [[6, "6"], [8, "8"], [10, "10"], [12, "12"]]))
	v.add_child(_cycle_row("Tube light shadows", "light_shadows", [[0, "Off"], [2, "2"], [4, "4"], [8, "8"]]))
	v.add_child(_cycle_row("Ambient occlusion", "ssao", quality))
	v.add_child(_cycle_row("Global illumination", "ssil", off_on))
	v.add_child(_cycle_row("Reflections", "ssr", off_on))
	v.add_child(_cycle_row("Volumetric fog", "vfog", quality))
	Gfx.changed.connect(_gfx_sync)
	_gfx_sync()
	return v

func _gfx_sync() -> void:
	for c in gfx_refresh:
		c.call()
	for n in gfx_preset_buttons:
		var b: Button = gfx_preset_buttons[n]
		var active: bool = Gfx.preset == n
		b.add_theme_stylebox_override("normal", _underline(RED if active else Color(0.9, 0.882, 0.804, 0.25)))
		b.add_theme_color_override("font_color", Color.WHITE if active else Color(0.9, 0.882, 0.804, 0.7))
	if gfx_scale_slider and int(gfx_scale_slider.value) != int(Gfx.s.scale):
		gfx_scale_slider.value = Gfx.s.scale
	var note := "CUSTOM SETTINGS. Pick a preset to reset them." if Gfx.preset == "custom" else "Low is for weak PCs. Tube lights and their shadows cost the most. Smooth motion runs the camera at your screen's refresh rate."
	if Gfx.compat:
		note = "Compatibility renderer: ambient occlusion, reflections, global illumination and volumetric fog are unavailable on this PC."
	gfx_note.text = note

# ---- voice section (scripts/voice/voice.gd) ----------------------------------------------------------
var voice_refresh: Array[Callable] = []
var voice_meter_bg: ColorRect
var voice_meter_fill: ColorRect
var voice_meter_gate: ColorRect

func _voice_row(title: String, get_text: Callable, on_press: Callable) -> Control:
	var b := _link_button("")
	b.custom_minimum_size = Vector2(150, 0)
	b.pressed.connect(on_press)
	voice_refresh.append(func(): b.text = str(get_text.call()).to_upper())
	return _gfx_row(title, b)

func _build_voice() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.add_child(_section_title("PROXIMITY VOICE", true))
	v.add_child(_hint("Players hear you by distance, from where you stand, and walls muffle you. Hold V to talk in push-to-talk."))
	v.add_child(_padded(Control.new(), 4))
	v.add_child(_voice_row("Mode", func(): return Voice.MODE_NAMES[Voice.mode], func(): Voice.cycle_mode()))
	v.add_child(_voice_row("Microphone", func(): return Voice.device_label().left(22), func(): Voice.cycle_device()))
	v.add_child(_voice_row("Mute microphone", func(): return "ON" if Voice.muted else "OFF", func(): Voice.toggle_mute()))
	v.add_child(_voice_row("Deafen", func(): return "ON" if Voice.deafened else "OFF", func(): Voice.toggle_deafen()))

	v.add_child(_section_title("MICROPHONE LEVEL"))
	voice_meter_bg = ColorRect.new()
	voice_meter_bg.color = Color(0.9, 0.882, 0.804, 0.12)
	voice_meter_bg.custom_minimum_size = Vector2(300, 10)
	voice_meter_fill = ColorRect.new()
	voice_meter_fill.color = Color("7fae72")
	voice_meter_bg.add_child(voice_meter_fill)
	voice_meter_gate = ColorRect.new()
	voice_meter_gate.color = RED
	voice_meter_gate.size = Vector2(2, 10)
	voice_meter_bg.add_child(voice_meter_gate)
	v.add_child(_padded(voice_meter_bg, 8))
	v.add_child(_hint("The bar turns green while you are transmitting. Voice activity opens when it passes the red line."))

	v.add_child(_section_title("LEVELS"))
	v.add_child(_slider_row("Sensitivity", 0, 100, Voice.sensitivity, func(x: int): Voice.set_sensitivity(x)))
	v.add_child(_slider_row("Mic volume", 0, 300, int(Voice.mic_gain * 100.0), func(x: int): Voice.set_gain(x)))
	v.add_child(_slider_row("Voice volume", 0, 150, int(Voice.voice_volume * 100.0), func(x: int): Voice.set_volume(x)))
	v.add_child(_voice_row("Hear yourself", func(): return "ON" if Voice.loopback else "OFF", func(): Voice.toggle_loopback()))
	Voice.changed.connect(_voice_sync)
	_voice_sync()
	return v

func _voice_sync() -> void:
	for c in voice_refresh:
		c.call()

func _voice_meter_tick() -> void:
	if voice_meter_bg == null or open_section != "voice":
		return
	var w := maxf(voice_meter_bg.size.x, 300.0)
	voice_meter_fill.size = Vector2(w * Voice.level, 10.0)
	voice_meter_fill.color = Color("7fae72") if Voice.transmitting else Color(0.9, 0.882, 0.804, 0.45)
	voice_meter_gate.position = Vector2(w * clampf((Voice.gate_db() + 70.0) / 70.0, 0.0, 1.0), 0.0)

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
## Back to the title screen (drops any multiplayer session first)
func _leave_to_main_menu() -> void:
	Net.leave()
	Game.playing = false
	Game.dead = false
	Game.respawned = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _on_nav(name: String) -> void:
	_show_panel("" if open_section == name else name)

func _show_panel(name: String) -> void:
	var was_open := panel.visible
	open_section = name
	panel.visible = name != ""
	if panel_tween: panel_tween.kill()
	panel.modulate.a = 1.0
	panel.scale = Vector2.ONE
	if name != "":
		_animate_panel_in(was_open)
	for n in sections:
		sections[n].visible = n == name
	for n in nav_buttons:
		var b: Button = nav_buttons[n]
		var active: bool = n == name
		b.add_theme_stylebox_override("normal", _underline(RED if active else Color(0.9, 0.882, 0.804, 0.25)))
		b.add_theme_color_override("font_color", Color.WHITE if active else Color(0.9, 0.882, 0.804, 0.7))
	if name != "":
		panel_title.text = name.to_upper()

## Panel powers on like a CRT / VHS overlay: scale settles in while the alpha stutters
func _animate_panel_in(switching: bool) -> void:
	panel.scale = Vector2(0.97, 0.94) if switching else Vector2(0.94, 0.86)
	panel.modulate.a = 0.0
	panel_tween = create_tween()
	panel_tween.set_parallel(true)
	panel_tween.tween_property(panel, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	panel_tween.tween_method(func(x: float): panel.modulate.a = _flicker(x), 0.0, 1.0, 0.3)

## Alpha curve for the power-on: dim, blink out, flash, settle
func _flicker(x: float) -> float:
	if x < 0.2: return 0.85 * x / 0.2
	if x < 0.35: return 0.15
	if x < 0.5: return 1.0
	if x < 0.62: return 0.45
	return 1.0

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
	sub_base = sub
	sub_label.text = sub
	lore_label.text = lore
	action_label.text = action

func release_focus_all() -> void:
	name_input.release_focus()
	mp_addr.release_focus()

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
	_voice_meter_tick()
	var on := fmod(t, 1.1) < 0.55        # animation: blink 1.1s steps(1)
	tag_dot.color.a = 1.0 if on else 0.0
	action_cursor.color.a = 1.0 if on else 0.0
	_update_glitch(dt)

# ---- random VHS glitch on the title / subtitle -------------------------------------------------
func _update_glitch(dt: float) -> void:
	if glitch_left > 0.0:
		glitch_left -= dt
		glitch_tick -= dt
		if glitch_left <= 0.0:
			_glitch_end()
		elif glitch_tick <= 0.0:
			glitch_tick = 0.045
			_glitch_frame()
		return
	next_glitch -= dt
	if next_glitch <= 0.0:
		glitch_left = randf_range(0.12, 0.4)
		next_glitch = randf_range(2.5, 7.0)
		if randf() < 0.3:
			next_glitch = randf_range(0.2, 0.5)       # sometimes it stutters twice in a row
		glitch_tick = 0.0

func _glitch_frame() -> void:
	var fr: Array = title_label.get_meta("fringes")
	var kick := randf_range(4.0, 14.0)
	fr[0].position = Vector2(kick, randf_range(-2, 2))          # red fringe tears right
	fr[1].position = Vector2(-kick * 0.8, randf_range(-2, 2))   # teal fringe tears left
	title_label.modulate.a = randf_range(0.55, 1.0)
	title_static.visible = true
	var h := title_label.size.y
	var w := title_label.size.x
	for bar: ColorRect in title_static.get_children():
		if randf() < 0.35:
			bar.visible = false
			continue
		bar.visible = true
		bar.position = Vector2(randf_range(-20, w * 0.8), randf() * h)
		bar.size = Vector2(randf_range(40, w * 0.6), randf_range(1.0, 5.0))
		var c: Color = [CREAM, RED, Color(0.157, 0.45, 0.55)][randi() % 3]
		bar.color = Color(c.r, c.g, c.b, randf_range(0.12, 0.45))
	# subtitle: a few characters dissolve into noise
	var noise := "#%&@?/\\|0123456789"
	var s := ""
	for ch in sub_base:
		s += noise[randi() % noise.length()] if (ch != " " and randf() < 0.14) else ch
	sub_label.text = s
	sub_label.modulate.a = randf_range(0.5, 1.0)

func _glitch_end() -> void:
	var fr: Array = title_label.get_meta("fringes")
	fr[0].position = Vector2(2, 0)
	fr[1].position = Vector2(-2, 0)
	title_label.modulate.a = 1.0
	title_static.visible = false
	sub_label.text = sub_base
	sub_label.modulate.a = 1.0

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
