extends "res://scripts/UI/menu/menu_panels.gd"
## Start / pause menu, replicating the web game's #start-screen (backrooms.html + css/style.css,
## js/game/settings.js): dark left-to-right veil over the live view, REC tag, big VCR title with a
## red/blue split, sub line, lore, callsign field, blinking action line, Settings / Controls links
## and a side panel. Built for a 1920x1080 canvas so pixel sizes match the browser.

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
var t := 0.0
var blur_mat: ShaderMaterial
var shown := false
var fade: Tween
var panel_tween: Tween
var title_static: Control               # VHS tracking bars, only visible during a glitch
var sub_base := ""
var glitch_left := 0.0
var glitch_tick := 0.0
var next_glitch := 2.5

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
	var level_tag := load("res://scripts/World/level/level_data.gd")
	tag.add_child(_label("ARCHIVAL FOOTAGE // " + level_tag.current_level_tag(), 12, Color(0.9, 0.882, 0.804, 0.55), 4))
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
	psb.content_margin_top = 6        # keep the header's close band off the panel's own edge
	panel.add_theme_stylebox_override("panel", psb)
	layout.add_child(panel)

	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 0)
	panel.add_child(pv)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 0)
	# The whole header band closes the panel: a 48x19 "CLOSE" word is easy to miss by a pixel or two
	head.custom_minimum_size = Vector2(0, 28)
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	head.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	head.mouse_entered.connect(func(): Input.mouse_mode = Input.MOUSE_MODE_VISIBLE)
	head.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_show_panel(""))
	panel_title = _label("MULTIPLAYER", 13, Color(0.9, 0.882, 0.804, 0.55), 4)
	panel_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(panel_title)
	var close := _link_button("close")
	close.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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
