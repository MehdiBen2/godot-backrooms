extends Control
## Title screen + level loading. Slow-drifting stills of the level (textures/menu/bg_N.png, rendered by
## tools/capture_menu_bg.gd) that crossfade into each other behind the same VCR / found-footage styling as the in-game start screen.
## PLAY fades to a loading screen, streams scenes/main.tscn on a thread, then drops straight into the run.
## The column builds itself on launch (skippable), entries slide and caption themselves on hover or with
## the arrow keys, and QUIT switches the set off like an old CRT.

const CREAM := Color("e6e1cd")
const TITLE := Color("d8d3bd")
const RED := Color("c4271f")
const BG_PATH := "res://textures/menu/bg_%d.png"
const BG_SET := [0, 1, 3, 4, 5, 6, 8, 9, 10]     # the good frames from tools/capture_menu_bg.gd
const ZOOM := 1.14                      # slow push-in over each frame's lifetime
const BG_HOLD := 7.0                    # seconds each still stays up
const BG_FADE := 1.8                    # crossfade
const MUSIC_DB := -24.0                 # quiet bed, not a soundtrack
const MAIN_SCENE := "res://scenes/main.tscn"
const TIPS := [
	"The hum is not always the lights.",
	"Batteries stack. Tab to use them.",
	"Crouching muffles your steps.",
	"If it stops moving, do not look away.",
	"Not every corridor leads somewhere.",
	"Archive papers explain what the map will not.",
	"Sprinting costs stamina. Fear costs more.",
	"Moist old carpet is the only weather here.",
	"Six hundred million square miles of the same room.",
	"Level 0 is not empty. It is only quiet.",
	"The mannequins move on your blink, not your back.",
	"Something in here has learned what doors look like.",
	"Fear carries. So does the light of your torch.",
	"No-clip through reality and this is where you land.",
	"The tubes were humming long before you fell in.",
	"There is no way out. There are only more levels.",
	"Maintain low noise levels.",
	"Disregard auditory anomalies.",
	"Proceed along the designated route.",
	"Remain awake at all times.",
	"Verify equipment status regularly.",
	"Conserve physical energy.",
	"Monitor fluorescent light output.",
	"Regulate breathing patterns.",
	"Avoid prolonged contact with surfaces.",
	"Ensure all doors close completely.",
	"Watch for uneven carpeting.",
	"Document architectural shifts.",
	"Keep track of elapsed time.",
	"Acknowledge spatial repetition.",
	"Trust primary navigation protocols.",
	"Expect minor visual artifacts.",
	"Limit exposure to unlit sectors.",
	"Report localized reality failures.",
	"Hydrate at designated safe zones.",
	"Follow established safety guidelines.",
	"Walk at a consistent velocity.",
	"Maintain visual contact with structural pillars.",
	"Prioritize illuminated pathways.",
	"Observe ceiling tiles for irregularities.",
	"Disregard shadows detached from objects.",
	"Monitor ambient humidity levels.",
	"Expect sudden temperature drops.",
	"Breathe at a measured rate.",
	"Acknowledge localized gravity anomalies.",
	"Conserve mental focus.",
	"Maintain baseline emotional state.",
	"Verify current spatial coordinates.",
	"Rely on visual evidence over auditory input.",
	"Secure all loose equipment.",
	"Avert your gaze from structural glitches.",
	"Proceed strictly forward.",
	"Record all environmental shifts.",
	"Calculate distance walked frequently.",
	"Minimize sudden movements.",
	"Await further instructions.",
]
const MIN_LOAD_TIME := 3.0       # floor on the loading screen so the bar and phrases are actually seen,
								  # even when scenes/main.tscn itself streams in well under that
const DIM := Color(0.9, 0.882, 0.804, 0.6)
const SLIDE := 30.0               # how far a menu entry steps right when it is selected
const ROW_H := 50.0
const W := preload("res://scripts/UI/menu/menu_widgets.gd")   # shared motion helpers

var font: FontFile = load("res://fonts/vcr.ttf")
var bg_root: Control
var bg_a: TextureRect
var bg_b: TextureRect
var bg_tex: Array[Texture2D] = []
var bg_i := 0
var bg_timer := 0.0
var bg_fading := false
var title_label: Label
var fringes: Array
var glitch_left := 0.0
var next_glitch := 3.5
var glitch_tick := 0.0
var items: Array[Dictionary] = []       # {button, inner, label, mark, hint, panel, action, tw}
var sel := -1                           # entry under the mouse / picked with the arrow keys
var active_panel := ""                  # the embedded panel that is open, its entry stays lit
var menu_box: Control
var tag_row: Control
var tag_label: Label
var rec_dot: ColorRect
var sub_label: Label
var footer: Label
var credits: Label
var counter: Label
var intro: Tween
var corner_tw: Tween
var loading_root: Control
var load_title: Label
var load_bar: ColorRect
var load_pct: Label
var load_tip: Label
var load_dot: ColorRect
var loading := false
var busy := false                       # PLAY / QUIT transition running: ignore further input
var shown_progress := 0.0
var creep_progress := 0.0
var load_elapsed := 0.0
var t := 0.0
var click: AudioStreamPlayer
var tick: AudioStreamPlayer
var music: AudioStreamPlayer
var settings_menu                       # scripts/UI/menu.gd instance in embedded mode
var crt: Control
var crt_top: ColorRect
var crt_bottom: ColorRect
var crt_line: ColorRect

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build()
	_start_music()
	if Game.test_level != "":            # launched from the level editor: skip the title, open that level
		var levels: Array = load("res://scripts/World/level/level_data.gd").read_index()
		for i in levels.size():
			if str(levels[i].get("id", "")) == Game.test_level or str(levels[i].get("file", "")) == Game.test_level:
				Game.level_index = i
		Game.test_level = ""
		modulate.a = 1.0
		_on_play(true)
		return
	_intro()

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

func _spacer(h: float) -> Control:
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, h)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return sp

# ---- layout ---------------------------------------------------------------------
func _build() -> void:
	var back := ColorRect.new()
	back.color = Color(0.02, 0.018, 0.01)
	add_child(back)
	_full(back)

	# The stills, slightly oversized so the slow drift never shows an edge; two layers crossfade
	for i in BG_SET:
		if ResourceLoader.exists(BG_PATH % i):
			bg_tex.append(load(BG_PATH % i))
	if bg_tex.is_empty():
		bg_tex.append(_gradient(PackedColorArray([Color(0.16, 0.13, 0.06), Color(0.05, 0.04, 0.02)]), PackedFloat32Array([0.0, 1.0]), true))
	bg_root = Control.new()
	add_child(bg_root)
	_full(bg_root)
	bg_root.pivot_offset = Vector2(960, 540)
	bg_root.scale = Vector2(1.08, 1.08)
	bg_a = _bg_layer(bg_tex[0])
	bg_b = _bg_layer(bg_tex[0])
	bg_b.modulate.a = 0.0
	bg_i = randi() % bg_tex.size()          # start on a different frame each launch
	bg_a.texture = bg_tex[bg_i]
	_zoom(bg_a)
	var drift := create_tween().set_loops()
	drift.tween_property(bg_root, "position", Vector2(-26, -12), 14.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	drift.tween_property(bg_root, "position", Vector2(26, 12), 14.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

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

	# REC dot + tag, same as the in-game menu's
	var tag := HBoxContainer.new()
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_constant_override("separation", 10)
	rec_dot = ColorRect.new()
	rec_dot.color = RED
	rec_dot.custom_minimum_size = Vector2(8, 8)
	rec_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot_c := CenterContainer.new()
	dot_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot_c.add_child(rec_dot)
	tag.add_child(dot_c)
	tag_label = _label("ARCHIVAL FOOTAGE", 12, Color(0.9, 0.882, 0.804, 0.55), 4)
	tag.add_child(tag_label)
	col.add_child(tag)
	tag_row = tag
	col.add_child(_spacer(18))
	title_label = _label("THE BACKROOMS", 120, TITLE, 4)
	fringes = []
	for f in [[Vector2(2, 0), Color(0.627, 0.078, 0.059, 0.55)], [Vector2(-2, 0), Color(0.157, 0.353, 0.431, 0.35)]]:
		var s := _label("THE BACKROOMS", 120, f[1], 4)
		s.position = f[0]
		s.show_behind_parent = true
		title_label.add_child(s)
		fringes.append(s)
	col.add_child(title_label)
	sub_label = _label("THRESHOLD SECTOR • NON-EUCLIDEAN ZONE", 13, Color(0.9, 0.882, 0.804, 0.5), 5)
	col.add_child(sub_label)
	col.add_child(_spacer(46))

	_menu_item(col, "PLAY", _level_name().to_upper(), "", _on_play)
	_menu_item(col, "SETTINGS", "AUDIO / MOUSE / CAMERA", "settings", _open_panel.bind("settings"))
	_menu_item(col, "GRAPHICS", "PRESETS / DISPLAY / LIGHTING", "graphics", _open_panel.bind("graphics"))
	_menu_item(col, "QUIT", "EJECT TAPE", "", _on_quit)
	col.add_child(_spacer(32))
	footer = _label("BUILD 0.1 // TAPE 04        UP / DOWN  SELECT    ENTER  CONFIRM", 11, Color(0.9, 0.882, 0.804, 0.3), 3)
	col.add_child(footer)

	# Credits, bottom right
	credits = _label("CREATED BY MehdiBen;)", 13, Color(0.9, 0.882, 0.804, 0.45), 4)
	credits.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(credits)
	credits.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	credits.offset_left = -420
	credits.offset_right = -110
	credits.offset_top = -100
	credits.offset_bottom = -72

	# Camcorder tape counter, top right: runs while the title is up
	counter = _label("► PLAY  0:00:00", 13, Color(0.9, 0.882, 0.804, 0.55), 4)
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(counter)
	counter.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	counter.offset_left = -420
	counter.offset_right = -110
	counter.offset_top = 72
	counter.offset_bottom = 100

	# Settings / Graphics reuse the in-game menu's panels (same code, same saved settings)
	settings_menu = load("res://scripts/UI/menu/menu.gd").new()
	settings_menu.embedded = true
	add_child(settings_menu)
	settings_menu.panel_changed.connect(_on_panel_changed)

	# Camcorder lens over everything (text included): fisheye, chroma fringe, tape tear, grain
	var fx := ColorRect.new()
	var mat := ShaderMaterial.new()
	mat.shader = _fx_shader()
	fx.material = mat
	add_child(fx)
	_full(fx)

	click = AudioStreamPlayer.new()
	click.stream = load("res://audio/ui_click.wav")
	click.volume_db = -6.0
	add_child(click)
	tick = AudioStreamPlayer.new()          # much quieter, higher tick when the selection moves
	tick.stream = click.stream
	tick.volume_db = -22.0
	add_child(tick)
	_build_loading()
	_build_crt()

func _bg_layer(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_root.add_child(r)
	_full(r)
	r.pivot_offset = Vector2(960, 470)       # push in toward the far end of the hall, not the centre
	return r

## Slow push-in, like the camera creeping forward. Lasts as long as the frame is on screen.
func _zoom(r: TextureRect) -> void:
	r.scale = Vector2.ONE
	var tw := create_tween()
	tw.tween_property(r, "scale", Vector2(ZOOM, ZOOM), BG_HOLD + BG_FADE * 2.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	r.set_meta("zoom", tw)

func _next_bg() -> void:
	bg_fading = true
	var nxt := (bg_i + 1) % bg_tex.size()
	bg_b.texture = bg_tex[nxt]
	bg_root.move_child(bg_b, -1)             # the incoming frame fades in on top
	_zoom(bg_b)
	var tw := create_tween()
	tw.tween_property(bg_b, "modulate:a", 1.0, BG_FADE).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(func():
		if bg_a.has_meta("zoom"): bg_a.get_meta("zoom").kill()
		var done := bg_a                     # swap roles; the old frame becomes the hidden spare
		bg_a = bg_b
		bg_b = done
		bg_b.modulate.a = 0.0
		bg_i = nxt
		bg_timer = 0.0
		bg_fading = false)

# ---- menu entries ---------------------------------------------------------------------
## One entry: a red ► cursor and the word, which steps right when selected, plus a short caption
## that types itself out beside it. The hit box is only as wide as the word, not the whole column.
## Everything sits in `inner` so the intro can slide the entry in without fighting the hover motion.
func _menu_item(col: Control, text: String, hint: String, panel: String, action: Callable) -> void:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	for n in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(n, StyleBoxEmpty.new())
	var f := _font(8)
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 34).x
	b.custom_minimum_size = Vector2(w + SLIDE + 12, ROW_H)
	col.add_child(b)

	var inner := Control.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(inner)
	var mark := _label("►", 34, RED)
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mark.size = Vector2(SLIDE, ROW_H)
	mark.position.x = -10.0
	mark.modulate.a = 0.0
	inner.add_child(mark)
	var l := _label(text, 34, Color.WHITE, 8)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(w + 12, ROW_H)
	l.self_modulate = DIM
	inner.add_child(l)
	# caption sits on the word's baseline, not centred on it
	var h := _label(hint, 12, Color(0.9, 0.882, 0.804, 0.4), 4)
	h.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.size = Vector2(0, ROW_H)
	h.position = Vector2(w + SLIDE + 34, (font.get_ascent(34) - font.get_ascent(12)) * 0.5)
	h.modulate.a = 0.0
	h.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	inner.add_child(h)

	var i := items.size()
	items.append({"button": b, "inner": inner, "label": l, "mark": mark, "hint": h, "panel": panel, "action": action, "tw": null})
	b.mouse_entered.connect(func(): _select(i))
	b.mouse_exited.connect(func():
		if sel == i: _select(-1))
	b.pressed.connect(_activate.bind(i))

func _select(i: int) -> void:
	if i == sel or busy:
		return
	var prev := sel
	sel = i
	if prev >= 0:
		_item_state(prev)
	if i >= 0:
		_item_state(i)
		tick.pitch_scale = randf_range(1.45, 1.55)
		tick.play()

## Lit = selected, or its panel is open. Only the selected one shows its caption.
func _item_state(i: int) -> void:
	var it: Dictionary = items[i]
	var hovered := i == sel
	var lit: bool = hovered or (it["panel"] != "" and it["panel"] == active_panel)
	var old: Tween = it["tw"]
	if old and old.is_valid():
		old.kill()
	var tw := create_tween().set_parallel(true)
	tw.tween_property(it["label"], "position:x", SLIDE if lit else 0.0, 0.32).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(it["label"], "self_modulate", Color.WHITE if lit else DIM, 0.2)
	tw.tween_property(it["mark"], "position:x", 0.0 if lit else -10.0, 0.32).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(it["mark"], "modulate:a", 1.0 if lit else 0.0, 0.18)
	var h: Label = it["hint"]
	if hovered and h.modulate.a < 0.05:
		h.visible_ratio = 0.0
	tw.tween_property(h, "modulate:a", 1.0 if hovered else 0.0, 0.2 if hovered else 0.15)
	if hovered:
		tw.tween_property(h, "visible_ratio", 1.0, 0.3).set_delay(0.08)
	it["tw"] = tw

func _step(d: int) -> void:
	if sel < 0:
		_select(0 if d > 0 else items.size() - 1)
	else:
		_select(posmod(sel + d, items.size()))

## Click / Enter: the word blinks like a VCR menu confirming, then the entry does its thing
func _activate(i: int) -> void:
	if busy:
		return
	W._finish(intro)
	_click()
	var l: Label = items[i]["label"]
	var tw := create_tween()
	tw.tween_method(func(x: float): l.modulate.a = 1.0 if fmod(x * 3.0, 1.0) > 0.45 else 0.3, 0.0, 1.0, 0.3)
	tw.tween_callback(func(): l.modulate.a = 1.0)
	items[i]["action"].call()

func _on_panel_changed(name: String) -> void:
	active_panel = name
	for i in items.size():
		_item_state(i)
	# the counter and credits sit where the side panel opens: step them out of its way
	if corner_tw: corner_tw.kill()
	corner_tw = create_tween().set_parallel(true)
	for c in [counter, credits]:
		corner_tw.tween_property(c, "modulate:a", 0.0 if name != "" else 1.0, 0.2)

# ---- intro ----------------------------------------------------------------------------
## Out of black, then the column builds itself: tag types, the title's tracking locks in, the sub line
## types, the entries slide in one by one, and the corner OSD comes up last. Any key or click skips it.
func _intro() -> void:
	modulate.a = 0.0
	next_glitch = 3.5
	intro = create_tween().set_parallel(true)
	intro.tween_property(self, "modulate:a", 1.0, 1.0).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	W._stagger(intro, [tag_row], 0.2, 0.0, 0.3)
	W._type_in(intro, tag_label, 0.2, 0.45)
	W._lock_in(intro, title_label, fringes, 0.35, 1.1, 40.0)
	W._type_in(intro, sub_label, 0.8, 0.6)
	for i in items.size():
		var inner: Control = items[i]["inner"]
		inner.position.x = -24.0
		inner.modulate.a = 0.0
		var d := 1.0 + i * 0.08
		intro.tween_property(inner, "position:x", 0.0, 0.55).set_delay(d).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		intro.tween_property(inner, "modulate:a", 1.0, 0.4).set_delay(d)
	W._stagger(intro, [footer, credits, counter], 1.45, 0.1, 0.6)

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
	load_title = _label("LOADING", 26, TITLE, 6)
	box.add_child(load_title)
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

## Quit overlay: two black shutters and the bright line a CRT collapses to when it is switched off
func _build_crt() -> void:
	crt = Control.new()
	crt.visible = false
	add_child(crt)
	_full(crt)
	crt.mouse_filter = Control.MOUSE_FILTER_STOP
	crt_top = ColorRect.new()
	crt_bottom = ColorRect.new()
	crt_line = ColorRect.new()
	for r in [crt_top, crt_bottom]:
		r.color = Color.BLACK
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		crt.add_child(r)
	crt_line.color = Color(1.0, 0.97, 0.9)
	crt_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crt.add_child(crt_line)

func _fx_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float fisheye = 0.03;       // edge bend; the mapping below stays inside the frame (no black rim)
uniform float fringe = 0.012;       // red/blue split, only really visible right at the corners

float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	vec2 c = UV - 0.5;
	float r2 = dot(c, c);
	float tt = floor(TIME * 12.0);

	// slow tape wobble + an occasional horizontal tear that rolls down the frame
	float wobble = sin(TIME * 0.9 + UV.y * 5.0) * 0.0006;
	float band = fract(TIME * 0.11);
	float tear_on = step(0.86, h(vec2(floor(TIME * 0.7), 3.0)));
	float tear = smoothstep(0.045, 0.0, abs(UV.y - band)) * tear_on;
	float jitter = (h(vec2(tt, floor(UV.y * 90.0))) - 0.5) * 0.02 * tear + wobble;

	// barrel / fish-eye: centre magnified slightly, edges squeezed. Scale is 0.985 in the middle and
	// exactly 1.0 at the corners, so it never samples outside the screen. Kept subtle (as opposed to the
	// original 0.94/0.12) so the visual warp stays close enough to true layout for buttons near the edges
	// (e.g. the panel's CLOSE link) to still be clickable where they look clickable.
	vec2 uv = 0.5 + c * (0.985 + fisheye * r2);
	uv.x += jitter;

	// chromatic aberration: a hair of split growing with r^2, so text near the edge stays readable
	vec2 dir = c * r2 * fringe;
	vec2 lo = vec2(0.001);
	vec2 hi = vec2(0.999);
	float rr = texture(screen_tex, clamp(uv + dir, lo, hi)).r;
	float gg = texture(screen_tex, clamp(uv, lo, hi)).g;
	float bb = texture(screen_tex, clamp(uv - dir, lo, hi)).b;
	vec3 col = vec3(rr, gg, bb);

	// tape: luma noise, fine scanlines, slow brightness roll, warm lift
	float grain = h(FRAGCOORD.xy + tt * 17.3) - 0.5;
	float lines = 0.5 + 0.5 * sin(FRAGCOORD.y * 3.14159);
	float roll = 1.0 - 0.05 * smoothstep(0.0, 0.5, abs(fract(UV.y * 0.6 - TIME * 0.06) - 0.5));
	col += grain * 0.07;
	col *= (0.94 + 0.06 * lines) * roll;
	col += vec3(0.9, 0.85, 0.7) * 0.10 * tear;

	// soft lens vignette: darkens the rim a little without turning it into a black frame
	col *= 1.0 - smoothstep(0.2, 0.55, r2) * 0.35;
	COLOR = vec4(col, 1.0);
}
"""
	return s

func _start_music() -> void:
	if not ResourceLoader.exists("res://audio/ambients/ambient1.mp3"):
		return
	# Coming back from a run leaves the game's Master bus effects (compressor, low-pass, death muffle)
	# behind. The menu music is played clean, so strip them.
	while AudioServer.get_bus_effect_count(0) > 0:
		AudioServer.remove_bus_effect(0, 0)
	AudioServer.set_bus_volume_linear(0, 1.0)
	var stream: AudioStream = load("res://audio/ambients/ambient1.mp3")
	if stream is AudioStreamMP3:
		stream.loop = true
	music = AudioStreamPlayer.new()
	music.stream = stream
	music.bus = "Master"
	music.volume_db = -60.0
	add_child(music)
	music.play()
	create_tween().tween_property(music, "volume_db", MUSIC_DB, 4.0)

func _click() -> void:
	click.pitch_scale = randf_range(0.96, 1.04)
	click.play()

# ---- play / loading ----------------------------------------------------------------
func _open_panel(name: String) -> void:
	settings_menu._on_nav(name)

## Switch the set off: the picture collapses to a bright line, the line to nothing, then exit
func _on_quit() -> void:
	if busy:
		return
	busy = true
	settings_menu.close_panel()
	var s := size
	var mid := s.y * 0.5
	crt.visible = true
	crt_top.position = Vector2.ZERO
	crt_top.size = Vector2(s.x, 0)
	crt_bottom.position = Vector2(0, s.y)
	crt_bottom.size = Vector2(s.x, s.y)
	crt_line.position = Vector2(0, mid - 1.0)
	crt_line.size = Vector2(s.x, 2)
	crt_line.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_interval(0.15)                  # let the QUIT blink register first
	tw.chain().tween_property(crt_top, "size:y", mid, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tw.tween_property(crt_bottom, "position:y", mid, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tw.tween_property(crt_line, "modulate:a", 1.0, 0.08).set_delay(0.22)
	tw.chain().tween_property(crt_line, "position:x", s.x * 0.5 - 2.0, 0.24).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tw.tween_property(crt_line, "size:x", 4.0, 0.24).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tw.chain().tween_property(crt_line, "modulate:a", 0.0, 0.12)
	tw.chain().tween_interval(0.15)
	tw.chain().tween_callback(get_tree().quit)
	if music:
		create_tween().tween_property(music, "volume_db", -60.0, 0.7)

## PLAY: the entry blinks, the column fades away, then the loading screen comes up over it.
## `now` skips the hand-off (launched straight into a level from the level editor).
func _on_play(now := false) -> void:
	if busy:
		return
	busy = true
	if music:
		create_tween().tween_property(music, "volume_db", -60.0, 1.5)
	if now:
		_start_loading()
		return
	settings_menu.close_panel()
	if corner_tw: corner_tw.kill()           # closing the panel would bring the corners back
	var tw := create_tween().set_parallel(true)
	tw.tween_property(menu_box, "modulate:a", 0.0, 0.35).set_delay(0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	for c in [counter, credits]:
		tw.tween_property(c, "modulate:a", 0.0, 0.3).set_delay(0.2)
	tw.chain().tween_callback(_start_loading)

func _start_loading() -> void:
	loading = true
	loading_root.visible = true
	loading_root.modulate.a = 0.0
	load_title.text = "LOADING // %s" % _level_name().to_upper()
	load_tip.text = TIPS[randi() % TIPS.size()]
	load_bar.size.x = 0.0
	load_pct.text = "0%"
	var tw := create_tween().set_parallel(true)
	tw.tween_property(loading_root, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	W._type_in(tw, load_title, 0.15, 0.5)
	W._type_in(tw, load_tip, 0.6, 1.2)
	shown_progress = 0.0
	creep_progress = 0.0
	load_elapsed = 0.0
	ResourceLoader.load_threaded_request(MAIN_SCENE)

## The playlist entry the run starts on, so the loading screen names the level actually being built
func _level_name() -> String:
	var levels: Array = load("res://scripts/World/level/level_data.gd").read_index()
	if levels.is_empty():
		return "LEVEL 0"
	var meta = levels[clampi(Game.level_index, 0, levels.size() - 1)]
	return str(meta.get("name", "LEVEL 0"))

func _finish_loading() -> void:
	var packed := ResourceLoader.load_threaded_get(MAIN_SCENE) as PackedScene
	Game.respawned = true              # straight into the run: the title screen is this scene
	get_tree().change_scene_to_packed(packed)

## Any key or click during the intro jumps it to the end (the press still does what it normally does)
func _input(e: InputEvent) -> void:
	if intro and intro.is_valid() and e.is_pressed() and not e.is_echo() \
			and (e is InputEventKey or e is InputEventMouseButton):
		W._finish(intro)

func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed):
		return
	var k: Key = e.physical_keycode
	if k == KEY_ESCAPE and not e.echo:
		settings_menu.close_panel()
		return
	if busy:
		return
	match k:
		KEY_UP, KEY_W:
			_step(-1)
		KEY_DOWN, KEY_S:
			_step(1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if not e.echo:
				_activate(sel if sel >= 0 else 0)     # nothing picked yet: Enter still means PLAY

# ---- per-frame -----------------------------------------------------------------------
func _process(dt: float) -> void:
	t += dt
	if loading:
		_process_loading(dt)
	else:
		_update_glitch(dt)
		bg_timer += dt
		if bg_timer >= BG_HOLD and not bg_fading and bg_tex.size() > 1:
			_next_bg()
		rec_dot.color.a = 1.0 if fmod(t, 1.1) < 0.55 else 0.0
		counter.text = "► PLAY  %d:%02d:%02d" % [int(t / 3600.0), int(t / 60.0) % 60, int(t) % 60]

func _process_loading(dt: float) -> void:
	load_elapsed += dt
	var prog := []
	var status := ResourceLoader.load_threaded_get_status(MAIN_SCENE, prog)
	var real: float = prog[0] if prog.size() > 0 else 0.0
	var done := status == ResourceLoader.THREAD_LOAD_LOADED
	if done:
		real = 1.0
	# scenes/main.tscn usually streams in well under MIN_LOAD_TIME, so the bar is driven by
	# elapsed time (a steady fill you can actually watch) rather than the loader's own figure,
	# which is real but arrives in a handful of lumpy jumps. It never claims 100% until the
	# scene is truly loaded AND the floor has passed; if the real load runs long, a slow creep
	# keeps it inching forward past the floor instead of sitting dead at the cap.
	var time_frac: float = clamp(load_elapsed / MIN_LOAD_TIME, 0.0, 1.0)
	var target: float
	if done and load_elapsed >= MIN_LOAD_TIME:
		target = 1.0
	elif time_frac >= 1.0:
		creep_progress = min(creep_progress + dt * 0.06, 0.995)
		target = creep_progress
	else:
		target = max(time_frac, real * 0.6)
	shown_progress += (target - shown_progress) * (1.0 - exp(-dt * 6.0))
	load_bar.size.x = 700.0 * shown_progress
	load_pct.text = "%d%%" % int(shown_progress * 100.0)
	load_dot.color.a = 1.0 if fmod(t, 1.1) < 0.55 else 0.0
	if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		load_pct.text = "LOAD FAILED"
		loading = false
		busy = false                  # Enter tries again
		return
	if done and load_elapsed >= MIN_LOAD_TIME:
		set_process(false)
		load_bar.size.x = 700.0
		load_pct.text = "100%"
		_finish_loading()

# ---- random VHS glitch on the title -------------------------------------------------
func _update_glitch(dt: float) -> void:
	if intro and intro.is_valid():
		return                              # the intro's lock-in owns the fringes until it settles
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
