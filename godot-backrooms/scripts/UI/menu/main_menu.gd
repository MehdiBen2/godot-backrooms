extends Control
## Title screen + level loading. Live 3D sets of the level with flickering troffers and a mannequin standing in each
## (title_set.gd), cut between one after another behind the same VCR / found-footage styling as the in-game start screen.
## PLAY fades to a loading screen, streams scenes/main.tscn on a thread, then drops straight into the run.
## The column builds itself on launch (skippable), entries slide and caption themselves on hover or with
## the arrow keys, and QUIT switches the set off like an old CRT.
## PLAY (and a joined game) first opens the lobby screen (lobby_screen.gd): the picture pushes in and hands
## over to a live corridor whose camera carries the move on; the save tape and the crew are picked there.

const CREAM := Color("e6e1cd")
const TITLE := Color("d8d3bd")
const RED := Color("c4271f")
const TitleSet := preload("res://scripts/UI/menu/title_set.gd")     # the backdrop: live 3D sets, one after another
const LOAD_MUSIC_DB := -32.0           # the loading-screen bed, well under the menu's
const MUSIC_DB := -20.0                # quiet bed, not a soundtrack
const INTRO_PATH := "res://audio/ambients/menu_intro.mp3"      # the loading-screen track
const BED_PATH := "res://audio/ambients/menu_skin_of_your_teeth.mp3"   # the menu loop (title and tape select)
const PUSH_TIME := 2.2                  # BEGIN: the lobby's push on into the dark before the briefing (black at 0.9 of it)
const MAIN_SCENE := "res://scenes/main.tscn"
const MENU_SMEAR := 0.3                 # title screen VHS layer: a quarter-ish of the loading screen's bleed
const MENU_WIGGLE := 0.012
const MENU_FISHEYE := 0.03              # subtle on purpose: it only bends the picture, the buttons keep their flat hit boxes
										# (at 0.03 a control at the screen edge is ~6 px from where it is drawn; 0.1 was 20+)
const LoadManifest := preload("res://scripts/GameLogicEngine/load_manifest.gd")
const Briefing := preload("res://scripts/UI/menu/mission_briefing.gd")
const WakeGate := preload("res://scripts/UI/wake_gate.gd")
const LobbyScreen := preload("res://scripts/UI/menu/lobby_screen.gd")
const LOBBY_PUSH := 1.3                 # PLAY: seconds the camera pushes on down the title's hall before the corridor has taken over
const Kit := preload("res://scripts/UI/inventory/terminal_kit.gd")      # Kit.logo(): the T.S.R.A. emblem
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
const MIN_LOAD_TIME := 1.6       # s: the screen stays up at least this long, so a fast load does not flash
const CREEP_RATE := 0.04         # emblem fill creep per second while the loaders report nothing new
const CREEP_AHEAD := 0.15        # ...never further than this past what is really loaded
const TIP_EVERY := 7.0           # s between field notes
const AMBER := Color("f5a623")   # the emblem's own colour
const EMBLEM_PX := 176.0
const LOAD_FADE := 2.5           # s: the loading music fades out over the end of its own track
const LOAD_SHARE := 0.8          # of the emblem's fill: the files; the rest is the level built and settled (wake_gate.gd)
const DIM := Color(0.9, 0.882, 0.804, 0.6)
const SLIDE := 30.0               # how far a menu entry steps right when it is selected
const ROW_H := 50.0
const W := preload("res://scripts/UI/menu/menu_widgets.gd")   # shared motion helpers

var font: FontFile = load("res://fonts/vcr.ttf")
var title_view: SubViewportContainer      # the title's 3D sets (title_set.gd), on a world of their own
var title_sub: SubViewport
var title: Node3D
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
var idle_time := 0.0
var idle := false                       # AFK screen up: logo centred, "click to resume tape"
var idle_tw: Tween
var idle_root: Control
var idle_prompt: Label
var corner_tw: Tween
var last_tick_time := 0.0               # cooldown: the hover tick must not fire faster than this
var group := "main"                     # which entry list is up: "main" or "sub" (Settings categories)
var group_tw: Tween
var group_filler: Control
var briefing: Control                   # PLAY: the T.S.R.A. mission briefing, between the push-in and the loading screen
var lobby: Control                      # PLAY: the lobby screen (save tapes, crew, the live corridor), before the briefing
var loading_root: Control
var load_emblem: TextureRect            # the T.S.R.A. emblem: it fills with amber from the bottom as the level loads
var load_glow: TextureRect              # soft amber halo behind it, breathing
var load_status: Label                  # under the emblem: LOADING, then PRESS ANY KEY
var load_name: Label
var load_sub: Label
var load_tip: Label                     # bottom right: a field note, changed every TIP_EVERY seconds
var load_gate := true                   # false when launched straight from the level editor: no key press needed
var tip_clock := 0.0
var loading := false
var busy := false                       # PLAY / QUIT transition running: ignore further input
var shown_progress := 0.0
var creep_progress := 0.0
var load_elapsed := 0.0
var t := 0.0
var click: AudioStreamPlayer
var tick: AudioStreamPlayer
var music: AudioStreamPlayer             # the looping menu track
var music_fade: Tween                   # the live volume tween on whichever track(s) are audible
static var _load_music_player: AudioStreamPlayer
static var _load_music_tween: Tween
static var _load_music_fading := false
var push_black: ColorRect               # PLAY: fades in over the whole title screen before the loading screen
var settings_menu                       # scripts/UI/menu.gd instance in embedded mode
var crt: Control
var crt_top: ColorRect
var crt_bottom: ColorRect
var crt_line: ColorRect

func _ready() -> void:
	LoadManifest.install(get_tree())         # before the first threaded load (_preload_game), see load_manifest.gd
	_menu_fps()
	Gfx.changed.connect(_menu_fps)           # Gfx.apply() writes the in-game FPS cap on every settings change
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	multiplayer.connected_to_server.connect(_on_multiplayer_connected)
	_build()
	if Game.test_level == "":
		_preload_game()                  # (a level editor launch picks its level first: _on_play does it then)
	if Game.test_level == "" and not Game.boot_played:   # first time up this launch: warnings, logo, CRT on
		Game.boot_played = true
		modulate.a = 0.0
		var boot: CanvasLayer = load("res://scripts/UI/menu/boot_sequence.gd").new()
		boot.reveal.connect(func() -> void:
			_start_music()
			_intro()
			modulate.a = 1.0)                    # the picture is there at once: the tube does the fade-up
		add_child(boot)
		return
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

## The title screen runs uncapped: vsync (on in every preset) paces it to the monitor's refresh rate, so the
## slow drift and the CRT effect stay smooth. The in-game cap (a preset's `fps`) is only for the run itself.
func _menu_fps() -> void:
	Engine.max_fps = 0

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

	# The backdrop: the title's 3D sets on a world of their own (title_set.gd), under the veil and vignette below
	title_view = SubViewportContainer.new()
	title_view.stretch = true
	add_child(title_view)
	_full(title_view)
	title_sub = SubViewport.new()
	title_sub.own_world_3d = true
	title_sub.msaa_3d = Viewport.MSAA_2X
	title_sub.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	title_sub.use_debanding = true
	title_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	title_view.add_child(title_sub)
	title = TitleSet.new()
	title_sub.add_child(title)

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
	title_label = _label(TITLE_TEXT, 84, TITLE, 20)     # smaller and widely tracked: reads as a caption, not a logo
	title_label.add_theme_constant_override("outline_size", 4)   # VCR has no bold: a same-colour outline thickens the strokes
	title_label.add_theme_color_override("font_outline_color", TITLE)
	fringes = []
	for f in [[Vector2(2, 0), Color(0.627, 0.078, 0.059, 0.4)], [Vector2(-2, 0), Color(0.157, 0.353, 0.431, 0.28)]]:
		var s := _label(TITLE_TEXT, 84, f[1], 20)
		s.add_theme_constant_override("outline_size", 4)
		s.add_theme_color_override("font_outline_color", f[1])
		s.position = f[0]
		s.show_behind_parent = true
		title_label.add_child(s)
		fringes.append(s)
	col.add_child(title_label)
	# the second line of the lockup: NULLSPACE in the red of the tag dot, under the title, with the same glitch
	nullspace_label = _label(NAME_TEXT, 60, RED, 20)
	nullspace_label.add_theme_constant_override("outline_size", 4)
	nullspace_label.add_theme_color_override("font_outline_color", RED)
	name_fringes = []
	for f in [[Vector2(2, 0), Color(0.627, 0.078, 0.059, 0.4)], [Vector2(-2, 0), Color(0.157, 0.353, 0.431, 0.28)]]:
		var s := _label(NAME_TEXT, 60, f[1], 20)
		s.add_theme_constant_override("outline_size", 4)
		s.add_theme_color_override("font_outline_color", f[1])
		s.position = f[0]
		s.show_behind_parent = true
		nullspace_label.add_child(s)
		name_fringes.append(s)
	col.add_child(nullspace_label)
	col.add_child(_spacer(8))
	sub_label = _label("T.S.R.A // THRESHOLD SPATIAL RESEARCH AGENCY", 13, Color(0.9, 0.882, 0.804, 0.5), 5)
	col.add_child(sub_label)
	col.add_child(_spacer(46))

	_menu_item(col, "PLAY", _level_name().to_upper(), "", _on_play)
	_menu_item(col, "JOIN A GAME", "INPUT ROOM CODE", "multiplayer", _open_join_panel)
	_menu_item(col, "SETTINGS", "GRAPHICS / CONTROLS / AUDIO", "", _set_group.bind("sub"))
	_menu_item(col, "QUIT", "EJECT TAPE", "", _on_quit)
	group_filler = _spacer(ROW_H)       # the Settings list is one row longer: keeps the title from jumping
	col.add_child(group_filler)
	_menu_item(col, "GENERAL", "AUDIO / MOUSE / CAMERA", "settings", _open_panel.bind("settings"), "sub")
	_menu_item(col, "GRAPHICS", "PRESETS / DISPLAY / LIGHTING", "graphics", _open_panel.bind("graphics"), "sub")
	_menu_item(col, "CONTROLS", "KEYBINDS / LAYOUT", "controls", _open_panel.bind("controls"), "sub")
	_menu_item(col, "VOICE", "MICROPHONE / PROXIMITY", "voice", _open_panel.bind("voice"), "sub")
	_menu_item(col, "GO BACK", "MAIN MENU", "", _set_group.bind("main"), "sub")
	col.add_child(_spacer(32))
	footer = _label("BUILD 0.1.30 // TAPE 04        UP / DOWN  SELECT    ENTER  CONFIRM", 11, Color(0.9, 0.882, 0.804, 0.3), 3)
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

	# the lobby screen: over the title, under the lens and the VHS smear, so it is the same tape
	lobby = LobbyScreen.new()
	add_child(lobby)
	lobby.begin_requested.connect(_begin_from_lobby)
	lobby.back_requested.connect(_back_from_lobby)

	# Settings / Graphics reuse the in-game menu's panels (same code, same saved settings)
	settings_menu = load("res://scripts/UI/menu/menu.gd").new()
	settings_menu.embedded = true
	add_child(settings_menu)
	settings_menu.panel_changed.connect(_on_panel_changed)

	# Camcorder lens over everything (text included): chroma fringe, tape tear, grain
	var fx := ColorRect.new()
	var mat := ShaderMaterial.new()
	mat.shader = _fx_shader()
	fx.material = mat
	add_child(fx)
	_full(fx)

	# VHS smear (wiggle, tracking band, chroma bleed) over the whole title screen: it reads the screen under it, so it
	# comes after the lens. A fresh screen copy, as the lens already took this frame's.
	var vhs_copy := BackBufferCopy.new()
	vhs_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(vhs_copy)
	var vhs := ColorRect.new()
	var vhs_mat := ShaderMaterial.new()
	vhs_mat.shader = load("res://shaders/vhs_smear.gdshader")
	vhs_mat.set_shader_parameter("smear", MENU_SMEAR)
	vhs_mat.set_shader_parameter("wiggle", MENU_WIGGLE)
	vhs_mat.set_shader_parameter("blur_samples", 9)
	vhs_mat.set_shader_parameter("fisheye", MENU_FISHEYE)
	vhs.material = vhs_mat
	add_child(vhs)
	_full(vhs)

	click = AudioStreamPlayer.new()
	click.stream = load("res://audio/ui/ui_click.tres")
	click.volume_db = -6.0
	add_child(click)
	tick = AudioStreamPlayer.new()          # much quieter, higher tick when the selection moves
	tick.stream = click.stream
	tick.volume_db = -22.0
	add_child(tick)
	push_black = ColorRect.new()            # over the picture and every bit of menu chrome, under the loading screen
	push_black.color = Color(0.008, 0.008, 0.005)
	push_black.modulate.a = 0.0
	push_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(push_black)
	_full(push_black)
	_build_briefing()
	_build_loading()
	_build_crt()

# ---- menu entries ---------------------------------------------------------------------
## One entry: a red ► cursor and the word, which steps right when selected, plus a short caption
## that types itself out beside it. The hit box is only as wide as the word, not the whole column.
## Everything sits in `inner` so the intro can slide the entry in without fighting the hover motion.
func _menu_item(col: Control, text: String, hint: String, panel: String, action: Callable, group := "main") -> void:
	var b := Button.new()
	b.visible = group == "main"
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	for n in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(n, StyleBoxEmpty.new())
	var f := _font(8)
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 34).x
	b.custom_minimum_size = Vector2(620, ROW_H)
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
	items.append({"button": b, "inner": inner, "label": l, "mark": mark, "hint": h, "panel": panel, "action": action, "group": group, "tw": null})
	b.mouse_entered.connect(func(): _select(i))
	b.mouse_exited.connect(func():
		if sel == i:
			call_deferred("_check_mouse_leave", i))
	b.pressed.connect(_activate.bind(i))

func _check_mouse_leave(i: int) -> void:
	if sel == i:
		for it in items:
			var btn: Button = it["button"]
			if btn.visible and btn.get_global_rect().has_point(btn.get_global_mouse_position()):
				return
		if active_panel == "":
			_select(-1)

func _select(i: int) -> void:
	if i == sel or busy:
		return
	var prev := sel
	sel = i
	if prev >= 0:
		_item_state(prev)
	if i >= 0:
		_item_state(i)
		var now := Time.get_ticks_msec() / 1000.0
		if now - last_tick_time >= 0.08:          # debounce: don't spam when the mouse wobbles on an edge
			last_tick_time = now
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

func _group_items() -> Array[int]:
	var ids: Array[int] = []
	for i in items.size():
		if items[i]["group"] == group:
			ids.append(i)
	return ids

func _step(d: int) -> void:
	var ids := _group_items()
	var at := ids.find(sel)
	if at < 0:
		_select(ids[0] if d > 0 else ids[-1])
	else:
		_select(ids[posmod(at + d, ids.size())])

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

## SETTINGS / GO BACK: the list swaps for the other one. The old entries slide out and fade, the new ones
## slide in one after another; picking a category then opens its panel on the right.
func _set_group(g: String) -> void:
	if g == group:
		return
	W._finish(intro)
	if group_tw: W._finish(group_tw)
	settings_menu.close_panel()
	var old := group
	group = g
	_select(-1)
	group_tw = create_tween().set_parallel(true)
	for it in items:
		if it["group"] == old:
			group_tw.tween_property(it["inner"], "modulate:a", 0.0, 0.14)
	group_tw.chain().tween_callback(func():
		group_filler.visible = g == "main"
		var n := 0
		for it in items:
			it["button"].visible = it["group"] == g
			if it["group"] == g:
				var inner: Control = it["inner"]
				inner.position.x = -24.0
				inner.modulate.a = 0.0
				var tw := create_tween().set_parallel(true)
				tw.tween_property(inner, "position:x", 0.0, 0.45).set_delay(n * 0.05).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
				tw.tween_property(inner, "modulate:a", 1.0, 0.3).set_delay(n * 0.05)
				n += 1)

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

func _build_briefing() -> void:
	briefing = Briefing.new()
	add_child(briefing)
	briefing.accepted.connect(_start_loading.bind(true))

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

	# centre: the emblem over its halo, the agency's name, one status word
	var center := CenterContainer.new()
	loading_root.add_child(center)
	_full(center)
	var mid := VBoxContainer.new()
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	mid.add_theme_constant_override("separation", 0)
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(mid)
	load_emblem = Kit.logo(EMBLEM_PX)
	load_emblem.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var mat := ShaderMaterial.new()
	mat.shader = _emblem_shader()
	load_emblem.material = mat
	mid.add_child(load_emblem)
	load_glow = TextureRect.new()
	load_glow.texture = _gradient(PackedColorArray([Color(AMBER, 0.13), Color(AMBER, 0.04), Color(AMBER, 0.0)]), PackedFloat32Array([0.0, 0.45, 1.0]), true)
	load_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	load_glow.stretch_mode = TextureRect.STRETCH_SCALE
	load_glow.size = Vector2(EMBLEM_PX, EMBLEM_PX) * 3.4
	load_glow.position = (Vector2(EMBLEM_PX, EMBLEM_PX) - load_glow.size) * 0.5
	load_glow.pivot_offset = load_glow.size * 0.5
	load_glow.show_behind_parent = true
	load_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	load_emblem.add_child(load_glow)
	mid.add_child(_spacer(34))
	var agency := _label("T.S.R.A.", 15, Color(CREAM, 0.75), 12)
	agency.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.add_child(agency)
	mid.add_child(_spacer(6))
	var full := _label("THRESHOLD SPATIAL RESEARCH AGENCY", 11, Color(CREAM, 0.42), 5)
	full.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.add_child(full)
	mid.add_child(_spacer(40))
	load_status = _label("LOADING", 13, Color(CREAM, 0.62), 8)
	load_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	load_status.custom_minimum_size = Vector2(420, 0)
	mid.add_child(load_status)

	# corners: the level card bottom left, the field note bottom right
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 110 if side in ["left", "right"] else 84)
	loading_root.add_child(margin)
	_full(margin)

	var place := VBoxContainer.new()
	place.size_flags_vertical = Control.SIZE_SHRINK_END
	place.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	place.add_theme_constant_override("separation", 0)
	place.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(place)
	place.add_child(_label("NOW ENTERING", 11, Color(CREAM, 0.4), 6))
	place.add_child(_spacer(12))
	load_name = _label("LEVEL 0", 46, TITLE, 10)
	load_name.add_theme_constant_override("outline_size", 2)    # VCR has no bold
	load_name.add_theme_color_override("font_outline_color", TITLE)
	place.add_child(load_name)
	place.add_child(_spacer(10))
	load_sub = _label("", 15, Color(AMBER, 0.85), 7)
	place.add_child(load_sub)
	place.add_child(_spacer(18))
	var accent := ColorRect.new()
	accent.color = AMBER
	accent.custom_minimum_size = Vector2(56, 2)
	accent.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place.add_child(accent)

	var note := VBoxContainer.new()
	note.size_flags_vertical = Control.SIZE_SHRINK_END
	note.size_flags_horizontal = Control.SIZE_SHRINK_END
	note.add_theme_constant_override("separation", 10)
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(note)
	var head := _label("FIELD NOTE", 12, Color(AMBER, 0.8), 6)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	note.add_child(head)
	load_tip = _label(TIPS[randi() % TIPS.size()], 16, Color(CREAM, 0.72), 2)
	load_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	load_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	load_tip.custom_minimum_size = Vector2(440, 0)
	note.add_child(load_tip)

	# VHS smear over all of it (wiggle, tracking band, chroma bleed): reads the screen under it, so it goes last.
	# The title's lens already took this frame's screen copy (the menu): a fresh copy, so it smears the loading screen
	var fresh := BackBufferCopy.new()
	fresh.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	loading_root.add_child(fresh)
	var vhs := ColorRect.new()
	var vhs_mat := ShaderMaterial.new()
	vhs_mat.shader = load("res://shaders/vhs_smear.gdshader")
	vhs_mat.set_shader_parameter("smear", MENU_SMEAR * 0.8)     # the small centred lines must stay readable
	vhs_mat.set_shader_parameter("wiggle", MENU_WIGGLE)
	vhs_mat.set_shader_parameter("blur_samples", 9)
	vhs_mat.set_shader_parameter("fisheye", MENU_FISHEYE)
	vhs.material = vhs_mat
	loading_root.add_child(vhs)
	_full(vhs)

## The emblem as a progress meter: the part below `progress` (from the bottom) is lit in its own amber, the rest
## is a dim grey ghost of it, and a thin bright line rides the boundary. `flash` whitens it for the READY beat.
func _emblem_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
uniform float progress = 0.0;
uniform float flash = 0.0;

void fragment() {
	vec4 c = COLOR;
	float line = 1.0 - progress;
	float lit = step(line, UV.y);
	float live = step(0.002, progress) * (1.0 - step(0.998, progress));
	float edge = smoothstep(0.03, 0.0, abs(UV.y - line)) * live;
	vec3 ghost = vec3(dot(c.rgb, vec3(0.3, 0.59, 0.11))) * 0.32;
	vec3 col = mix(ghost, c.rgb, lit) + vec3(1.0, 0.9, 0.7) * edge * 0.8;
	col = mix(col, vec3(1.0, 0.95, 0.85), flash * 0.7);
	COLOR = vec4(col, c.a * mix(0.4, 1.0, max(lit, edge)));
}
"""
	return sh

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

	// Keep 1:1 screen mapping so buttons and sliders match their exact physical hitboxes
	vec2 uv = UV;

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
	if not ResourceLoader.exists(BED_PATH):
		return
	_stop_loading_music()
	# Coming back from a run leaves the game's Master bus effects (compressor, low-pass, death muffle)
	# behind. The menu music is played clean, so strip them.
	while AudioServer.get_bus_effect_count(0) > 0:
		AudioServer.remove_bus_effect(0, 0)
	AudioServer.set_bus_volume_linear(0, 1.0)
	var stream: AudioStream = load(BED_PATH)
	if stream is AudioStreamMP3:
		stream.loop = true
	music = _music_player(stream, -60.0)
	music.finished.connect(music.play)   # belt and braces: restart if the stream's own loop flag did not take
	music.play()
	music_fade = create_tween()
	music_fade.tween_property(music, "volume_db", MUSIC_DB, 4.0)

func _music_player(stream: AudioStream, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = "Master"
	p.volume_db = db
	add_child(p)
	return p

## Move every audible menu track to `db` over `secs`. Replaces any fade still running.
func _fade_music(db: float, secs: float) -> void:
	if music_fade:
		music_fade.kill()
	music_fade = create_tween().set_parallel(true)
	for p in [music]:
		if p and is_instance_valid(p) and p.playing:
			music_fade.tween_property(p, "volume_db", db, secs)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_fade_music(-80.0, 0.2)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if not busy:
			_fade_music(MUSIC_DB, 0.25)

func _click() -> void:
	click.play()

# ---- play / loading ----------------------------------------------------------------
func _open_panel(name: String) -> void:
	settings_menu._on_nav(name)

func _open_join_panel() -> void:
	_open_panel("multiplayer")
	if settings_menu and settings_menu.mp_addr:
		settings_menu.mp_addr.grab_focus()

func _on_multiplayer_connected() -> void:
	if not busy:
		_open_lobby(true)              # into the host's lobby (or straight on, if the host is in a run already)

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
	_fade_music(-60.0, 0.7)

## PLAY: the entry blinks and the lobby screen opens (_open_lobby); its BEGIN brings up the mission briefing,
## and accepting that the loading screen (the level keeps streaming in behind the briefing).
## `now` skips all of it (launched straight into a level from the level editor).
func _on_play(now := false) -> void:
	if not now:
		_open_lobby(false)
		return
	if busy:
		return
	busy = true
	load_gate = false
	_fade_music(-60.0, 1.5)
	_start_loading()

## PLAY / a joined game: the column fades, the still starts pushing in toward the far end of its hall, and the
## lobby's live corridor comes up through it with its camera still travelling forward, slowing to rest on the
## survivors. `guest`: in someone else's room (no tapes; their BEGIN takes us along).
func _open_lobby(guest: bool) -> void:
	if busy:
		return
	busy = true
	settings_menu.close_panel()
	if corner_tw: corner_tw.kill()           # closing the panel would bring the corners back
	title.push_in(LOBBY_PUSH)                # the camera pushes on down the title's hall for the corridor to come up through
	_fade_music(MUSIC_DB - 7.0, 1.5)         # under the tubes' hum
	var tw := create_tween().set_parallel(true)
	tw.tween_property(menu_box, "modulate:a", 0.0, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	for c in [counter, credits]:
		tw.tween_property(c, "modulate:a", 0.0, 0.45)
	var hide_title := tw.tween_callback(func() -> void:
		if lobby.shown:                      # the corridor covers the title from here: stop drawing it
			_title_on(false))
	hide_title.set_delay(LOBBY_PUSH)
	lobby.open(guest)

## BACK: the corridor backs away and fades, the camera pulls back up the title's hall and the column returns
func _back_from_lobby() -> void:
	lobby.close()
	_select(-1)
	_fade_music(MUSIC_DB, 1.2)
	_title_on(true)
	title.pull_back(1.4)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(menu_box, "modulate:a", 1.0, 0.5).set_delay(0.7)
	for c in [counter, credits]:
		tw.tween_property(c, "modulate:a", 1.0, 0.5).set_delay(0.8)
	tw.chain().tween_callback(func() -> void:
		busy = false)

## The title's 3D sets are only drawn while they are on screen (the lobby's corridor takes over the picture)
func _title_on(on: bool) -> void:
	title_view.visible = on
	title_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED

## BEGIN (ours, or the host's on a guest): the camera pushes on past the group into the dark down the hall,
## everything sinks into the black, and the mission briefing comes up out of it
func _begin_from_lobby() -> void:
	load_gate = true
	_fade_music(-60.0, 1.5)
	lobby.play_out()
	var tw := create_tween()
	tw.tween_property(push_black, "modulate:a", 1.0, PUSH_TIME * 0.7).set_delay(PUSH_TIME * 0.2).set_trans(Tween.TRANS_SINE)
	# the run's loader threads start mid-fade, the main-thread part of the request (level JSON, file checks) under
	# the dark: the briefing then opens on a run already loading, with no hitch of its own
	tw.parallel().tween_callback(_preload_game).set_delay(PUSH_TIME * 0.55)
	tw.tween_callback(func() -> void:
		lobby.hide_now()
		_start_briefing())

## The run keeps loading on its threads while the briefing is read; `accepted` then shows the loading screen
func _start_briefing() -> void:
	_preload_game()
	briefing.open(Archive.current_level_id(), _level_name())

## `fade`: coming out of the push (fully black by now), the loading text comes up out of the dark instead of cutting in
func _start_loading(fade := false) -> void:
	loading = true
	set_process(true)
	loading_root.visible = true
	loading_root.modulate.a = 1.0
	for c in loading_root.get_children().slice(1):          # child 0 is the opaque black backdrop
		c.modulate.a = 0.0 if fade else 1.0
		if fade:
			create_tween().tween_property(c, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	# "LEVEL 0: FLOOR ZERO" -> the name big, what follows the colon under it
	var full := _level_name().to_upper()
	var colon := full.find(":")
	load_name.text = full if colon < 0 else full.substr(0, colon).strip_edges()
	load_sub.text = "" if colon < 0 else full.substr(colon + 1).strip_edges()
	load_sub.visible = load_sub.text != ""
	load_tip.text = TIPS[randi() % TIPS.size()]
	load_tip.modulate.a = 1.0
	load_status.text = "LOADING"
	load_status.modulate = Color.WHITE
	load_emblem.material.set_shader_parameter("progress", 0.0)
	load_emblem.material.set_shader_parameter("flash", 0.0)
	shown_progress = 0.0
	creep_progress = 0.0
	load_elapsed = 0.0
	tip_clock = 0.0
	_preload_game()
	_play_loading_music()

## The menu's start track again, under the loading screen: it fades in while loading, and fades out over LOAD_FADE
## seconds once the level finishes loading (or on entering the level).
func _play_loading_music() -> void:
	if not ResourceLoader.exists(INTRO_PATH):
		return
	_stop_loading_music()
	var p := AudioStreamPlayer.new()
	p.name = "LoadingMusicPlayer"
	p.stream = load(INTRO_PATH)
	p.bus = "Master"
	p.volume_db = -60.0
	get_tree().root.add_child.call_deferred(p)     # (the root is still setting up children when an editor launch gets here from _ready)
	p.play.call_deferred()
	_load_music_player = p
	_load_music_fading = false
	var secs := p.stream.get_length()
	var tw := get_tree().create_tween()
	_load_music_tween = tw
	tw.tween_property(p, "volume_db", LOAD_MUSIC_DB, minf(1.0, secs * 0.25))
	# Fallback fade-out if the screen is kept open for the track's entire duration
	tw.tween_interval(maxf(secs - LOAD_FADE - 1.0, 0.0))
	tw.tween_property(p, "volume_db", -80.0, LOAD_FADE)
	tw.tween_callback(func() -> void:
		if is_instance_valid(p):
			p.queue_free()
		if _load_music_player == p:
			_load_music_player = null)

static func _fade_loading_music(fade_time: float = LOAD_FADE) -> void:
	if _load_music_fading:
		return
	_load_music_fading = true
	if _load_music_tween and _load_music_tween.is_valid():
		_load_music_tween.kill()
		_load_music_tween = null
	var p := _load_music_player
	if not is_instance_valid(p):
		_load_music_player = null
		return
	p.set_meta("fading", true)
	if p.is_inside_tree():
		var tw := p.create_tween()
		_load_music_tween = tw
		tw.tween_property(p, "volume_db", -80.0, fade_time)
		tw.tween_callback(func() -> void:
			if is_instance_valid(p):
				p.queue_free()
			if _load_music_player == p:
				_load_music_player = null)
	else:
		p.queue_free()
		_load_music_player = null

static func _stop_loading_music() -> void:
	_load_music_fading = false
	if _load_music_tween and _load_music_tween.is_valid():
		_load_music_tween.kill()
		_load_music_tween = null
	if is_instance_valid(_load_music_player):
		_load_music_player.queue_free()
	_load_music_player = null

## The run, loading on loader threads from the moment the title screen is up (and again here, for a level other
## than the one asked for then). Loading main.tscn compiles every script the run uses, ~57,000 lines of GDScript:
## nearly all of the 3.5 s it takes, which used to start only when PLAY was pressed.
static var _main_asked := false
var _warm_for := -1                     # the level whose files _warm_level_resources asked for

func _preload_game() -> void:
	if not _main_asked:
		_main_asked = ResourceLoader.load_threaded_request(MAIN_SCENE) == OK
	if _warm_for != Game.level_index:
		_warm_for = Game.level_index
		_warm_level_resources()

## Things the level builder load()s one after another (a stall with no loading screen once the scene has
## switched): requested here on loader threads, so those load() calls find them already in the cache. These are
## the ones known by hand; everything else the level read the last time it was built comes from load_manifest.gd.
const WARM_SETS := [
	["l0_carpet_", ["color", "normal", "rough", "ao"], ".webp"], ["l0_ceiling_", ["color", "normal", "rough", "ao"], ".webp"],
	["l0_wallpaper_", ["color", "normal", "rough", "ao"], ".webp"], ["tiles_", ["color", "normal", "rough", "ao"], ".png"],
	["grime_dry_", ["0", "1", "2", "3", "4"], ".png"], ["grime_wet_", ["0", "1", "2", "3", "4"], ".png"],
]
const WARM_FILES := [
	"res://textures/l0_carpet_height.png", "res://textures/concrete_color.jpg", "res://textures/concrete_normal.jpg",
	"res://shaders/drop_ceiling.gdshader", "res://shaders/panel_ceiling.gdshader",
	"res://models/lights/office_lighting_troffer_light_1x4.glb", "res://models/ceiling/backrooms_blender_kit.glb",
]
var _warm: Array[String] = []

func _warm_level_resources() -> void:
	_warm.clear()
	var paths: Array[String] = []
	for set in WARM_SETS:
		for part in set[1]:
			paths.append("res://textures/%s%s%s" % [set[0], part, set[2]])
	paths.append_array(WARM_FILES)
	for id in ["Wood_Dark_Knot", "Metal_Grey_Plate"]:      # the door's fallback materials (level_geometry.gd _make_materials)
		paths.append("res://textures/pbr/%s/%s.tres" % [id, id])
	paths.append("res://textures/props/door/door_leaf.tres")
	var levels: Array = load("res://scripts/World/level/level_data.gd").read_index()
	if not levels.is_empty():
		var meta: Dictionary = levels[clampi(Game.level_index, 0, levels.size() - 1)]
		# the level's own material picks: its "materials" slots and every pbr name used by the "paint" brush
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://levels/" + str(meta.get("file", ""))))
		if d is Dictionary:
			var ids := {}
			for slot in d.get("materials", {}):
				ids[str(d["materials"][slot])] = true
			for slot in d.get("paint", {}):
				for id in d["paint"][slot]:
					ids[str(id)] = true
			for id in ids:
				if not str(id).is_empty():
					paths.append("res://textures/pbr/%s/%s.tres" % [id, id])
	_warm = LoadManifest.warm(PackedStringArray(paths) + LoadManifest.paths(Game.level_index))

func _warm_pending() -> bool:
	for p in _warm:
		if ResourceLoader.load_threaded_get_status(p) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return true
	return false

## The playlist entry the run starts on, so the loading screen names the level actually being built
func _level_name() -> String:
	var levels: Array = load("res://scripts/World/level/level_data.gd").read_index()
	if levels.is_empty():
		return "LEVEL 0"
	var meta = levels[clampi(Game.level_index, 0, levels.size() - 1)]
	return str(meta.get("name", "LEVEL 0"))

func _finish_loading() -> void:
	loading = false                    # once only: _process_loading must not hand over again next frame
	set_process(false)
	var packed := ResourceLoader.load_threaded_get(MAIN_SCENE) as PackedScene
	_main_asked = false
	Stability.trace("play: main scene loaded (%s), switching to it" % ("OK" if packed != null else "FAILED: null"))
	Game.respawned = true              # straight into the run: the title screen is this scene
	Engine.max_fps = int(Gfx.s.get("fps", 0))
	var tree := get_tree()
	LoadManifest.record(Game.level_index)      # (main.gd stops it once the run is up)
	if packed != null:
		# the loading screen goes on over the level until it is built and has settled, then asks for a key
		var gate := WakeGate.new()
		gate.setup(loading_root, load_status, load_emblem, load_glow, shown_progress, load_gate)
		tree.root.add_child(gate)
		loading_root.reparent(gate)
	tree.change_scene_to_packed(packed)
	Stability.trace("play: change_scene_to_packed returned")

## Any key or click during the intro jumps it to the end (the press still does what it normally does)
func _input(e: InputEvent) -> void:
	if not is_inside_tree():
		return
	if e is InputEventKey or e is InputEventMouseButton or (e is InputEventMouseMotion and e.relative.length() > 1.0):
		idle_time = 0.0
	if idle and e.is_pressed() and not e.is_echo() and (e is InputEventKey or e is InputEventMouseButton):
		get_viewport().set_input_as_handled()     # the wake-up press is not a menu click
		_leave_idle()
		return
	if intro and intro.is_valid() and e.is_pressed() and not e.is_echo() \
			and (e is InputEventKey or e is InputEventMouseButton):
		W._finish(intro)

func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed) or lobby.shown:
		return
	var k: Key = e.physical_keycode
	if k == KEY_ESCAPE and not e.echo:
		if not settings_menu.close_panel() and group == "sub":     # panel first, then the list
			_set_group("main")
		return
	if busy:
		return
	match k:
		KEY_UP, KEY_W, KEY_Z:
			_step(-1)
		KEY_DOWN, KEY_S:
			_step(1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if not e.echo:
				_activate(sel if sel >= 0 else _group_items()[0])     # nothing picked yet: Enter takes the first entry (PLAY)

# ---- per-frame -----------------------------------------------------------------------
func _process(dt: float) -> void:
	t += dt
	if loading:
		_process_loading(dt)
	else:
		if idle:
			idle_prompt.modulate.a = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 2.4))
		elif not busy and active_panel == "" and not (intro and intro.is_valid()):
			idle_time += dt
			if idle_time >= IDLE_AFTER:
				_enter_idle()
		_update_glitch(dt)
		rec_dot.color.a = 1.0 if fmod(t, 1.1) < 0.55 else 0.0
		counter.text = "► PLAY  %d:%02d:%02d" % [int(t / 3600.0), int(t / 60.0) % 60, int(t) % 60]

func _process_loading(dt: float) -> void:
	load_elapsed += dt
	_loading_motion(dt)
	var prog := []
	var status := ResourceLoader.load_threaded_get_status(MAIN_SCENE, prog)
	if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		load_status.text = "SIGNAL LOST  //  ENTER TO RETRY"
		load_status.modulate = Color(1.0, 0.32, 0.26)
		loading = false
		busy = false                  # Enter tries again
		return

	var scene_progress: float = 0.0
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		scene_progress = 1.0
	elif status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		scene_progress = prog[0] if not prog.is_empty() else 0.05

	# the pre-warmed level files (textures, meshes, shaders, sounds)
	var warm_total: float = 0.0
	var warm_pending := false
	for p in _warm:
		var wp := []
		var ws := ResourceLoader.load_threaded_get_status(p, wp)
		if ws == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			warm_pending = true
			warm_total += wp[0] if not wp.is_empty() else 0.0
		else:
			warm_total += 1.0
	var warm_progress: float = (warm_total / float(_warm.size())) if not _warm.is_empty() else 1.0
	var loaded := status == ResourceLoader.THREAD_LOAD_LOADED and not warm_pending
	var done := loaded and load_elapsed >= MIN_LOAD_TIME
	var real_progress: float = 1.0 if loaded else (scene_progress * 0.4 + warm_progress * 0.6)

	# creep: the fill keeps moving a little while a loader reports nothing, but never far past the real figure
	creep_progress = minf(creep_progress + dt * CREEP_RATE, real_progress + CREEP_AHEAD)
	var target := LOAD_SHARE * (1.0 if done else minf(maxf(real_progress, creep_progress), 0.95))
	shown_progress = maxf(shown_progress, move_toward(shown_progress, target, dt * (1.6 if done else 0.9)))
	load_emblem.material.set_shader_parameter("progress", shown_progress)

	if done and shown_progress >= LOAD_SHARE - 0.001:
		_finish_loading()                # (the key is asked for once the level stands: wake_gate.gd)

## Slow life on an otherwise still screen: the halo breathes, LOADING's dots tick, the field note changes
func _loading_motion(dt: float) -> void:
	var breath := 0.5 + 0.5 * sin(t * 1.3)
	load_glow.modulate.a = 0.65 + 0.35 * breath
	if load_status.text.contains("LOADING"):
		var n := int(t * 2.0) % 4                # the dots tick; padded both sides so the word never shifts
		load_status.text = "   LOADING" + ".".repeat(n) + " ".repeat(3 - n)
	tip_clock += dt
	if tip_clock >= TIP_EVERY:
		tip_clock = 0.0
		var tw := create_tween()
		tw.tween_property(load_tip, "modulate:a", 0.0, 0.5).set_trans(Tween.TRANS_SINE)
		tw.tween_callback(func() -> void:
			var nxt: String = TIPS[randi() % TIPS.size()]
			while nxt == load_tip.text:
				nxt = TIPS[randi() % TIPS.size()]
			load_tip.text = nxt)
		tw.tween_property(load_tip, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)

# ---- AFK screen: the column fades away, the logo sits in the middle, a click brings the menu back ----
const IDLE_AFTER := 15.0

func _build_idle() -> void:
	idle_root = Control.new()
	idle_root.mouse_filter = Control.MOUSE_FILTER_STOP
	idle_root.modulate.a = 0.0
	add_child(idle_root)
	_full(idle_root)
	idle_root.mouse_filter = Control.MOUSE_FILTER_STOP
	if crt and crt.get_parent() == self:
		move_child(idle_root, crt.get_index())       # keep the CRT effect on top of it
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	idle_root.add_child(center)
	_full(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 30)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(col)
	var logo := _label(TITLE_TEXT, 84, TITLE, 20)
	logo.add_theme_constant_override("outline_size", 4)
	logo.add_theme_color_override("font_outline_color", TITLE)
	logo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for f in [[Vector2(2, 0), Color(0.627, 0.078, 0.059, 0.4)], [Vector2(-2, 0), Color(0.157, 0.353, 0.431, 0.28)]]:
		var fr := _label(TITLE_TEXT, 84, f[1], 20)
		fr.add_theme_constant_override("outline_size", 4)
		fr.add_theme_color_override("font_outline_color", f[1])
		fr.position = f[0]
		fr.show_behind_parent = true
		logo.add_child(fr)
	col.add_child(logo)
	idle_prompt = _label("❚❚  CLICK TO RESUME TAPE", 16, Color(0.9, 0.882, 0.804, 0.8), 6)
	idle_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(idle_prompt)

func _fade_menu(to: float, dur: float) -> void:
	if idle_tw and idle_tw.is_valid():
		idle_tw.kill()
	idle_tw = create_tween().set_parallel(true)
	for c in [menu_box, counter, credits]:
		idle_tw.tween_property(c, "modulate:a", to, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	idle_tw.tween_property(idle_root, "modulate:a", 1.0 - to, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)

func _enter_idle() -> void:
	if idle_root == null:
		_build_idle()
	idle = true
	idle_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_fade_menu(0.0, 1.2)

func _leave_idle() -> void:
	idle = false
	idle_time = 0.0
	idle_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_menu(1.0, 0.9)

# ---- random VHS glitch on the title -------------------------------------------------
const TITLE_TEXT := "THE BACKROOMS"
const WRONG_GLYPHS := {"T": "7", "H": "N", "E": "3", "B": "8", "A": "4", "C": "(", "K": "X",
		"R": "P", "O": "0", "M": "W", "S": "5"}   # lookalikes; W is the M turned upside down
var next_wrong := 1.5
const NAME_TEXT := "NULLSPACE"
const NAME_GLYPHS := {"N": "H", "U": "V", "L": "1", "P": "R", "A": "4", "C": "(", "E": "3", "S": "5"}
var nullspace_label: Label
var name_fringes: Array = []

# The same swap for NULLSPACE: one of its letters turns into a lookalike, then snaps back
func _wrong_name() -> void:
	var idx := randi() % NAME_TEXT.length()
	while not NAME_GLYPHS.has(NAME_TEXT[idx]):
		idx = randi() % NAME_TEXT.length()
	var bad: String = NAME_TEXT.substr(0, idx) + NAME_GLYPHS[NAME_TEXT[idx]] + NAME_TEXT.substr(idx + 1)
	nullspace_label.text = bad
	for f in name_fringes:
		f.text = bad
	await get_tree().create_timer(randf_range(0.2, 0.45)).timeout
	nullspace_label.text = NAME_TEXT
	for f in name_fringes:
		f.text = NAME_TEXT

# One letter of the title briefly turns into a lookalike, then snaps back
func _wrong_letter() -> void:
	var idx := randi() % TITLE_TEXT.length()
	while not WRONG_GLYPHS.has(TITLE_TEXT[idx]):
		idx = randi() % TITLE_TEXT.length()
	var bad: String = TITLE_TEXT.substr(0, idx) + WRONG_GLYPHS[TITLE_TEXT[idx]] + TITLE_TEXT.substr(idx + 1)
	_set_title_text(bad)
	await get_tree().create_timer(randf_range(0.2, 0.45)).timeout
	_set_title_text(TITLE_TEXT)

func _set_title_text(txt: String) -> void:
	title_label.text = txt
	for f in fringes:
		f.text = txt

func _update_glitch(dt: float) -> void:
	if intro and intro.is_valid():
		return                              # the intro's lock-in owns the fringes until it settles
	next_wrong -= dt
	if next_wrong <= 0.0:
		next_wrong = randf_range(1.2, 3.5)
		_wrong_letter()
		_wrong_name()
	if glitch_left > 0.0:
		glitch_left -= dt
		glitch_tick -= dt
		if glitch_left <= 0.0:
			fringes[0].position = Vector2(2, 0)
			fringes[1].position = Vector2(-2, 0)
			title_label.modulate.a = 1.0
			name_fringes[0].position = Vector2(2, 0)
			name_fringes[1].position = Vector2(-2, 0)
			nullspace_label.modulate.a = 1.0
		elif glitch_tick <= 0.0:
			glitch_tick = 0.045
			var kick := randf_range(4.0, 16.0)
			fringes[0].position = Vector2(kick, randf_range(-2, 2))
			fringes[1].position = Vector2(-kick * 0.8, randf_range(-2, 2))
			title_label.modulate.a = randf_range(0.55, 1.0)
			var nk := randf_range(4.0, 16.0)
			name_fringes[0].position = Vector2(nk, randf_range(-2, 2))
			name_fringes[1].position = Vector2(-nk * 0.8, randf_range(-2, 2))
			nullspace_label.modulate.a = randf_range(0.55, 1.0)
		return
	next_glitch -= dt
	if next_glitch <= 0.0:
		glitch_left = randf_range(0.12, 0.4)
		next_glitch = randf_range(2.5, 7.0)
		glitch_tick = 0.0
