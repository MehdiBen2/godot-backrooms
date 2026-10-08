extends "res://level_editor_files.gd"
## Standalone level editor: its own Godot project, not part of the game. Open level-editor/ in Godot
## (or export it) and run. It edits the game's levels/*.lvl and levels.json in place, including the
## per-level PBR "materials" ({wall, floor, ceiling, tiles} -> folders in the game's textures/pbr/).
## Set BACKROOMS_GAME_DIR to point at a different game folder.
## Two layers: terrain (walls, floor, pits, zones, markers) is painted onto the grid; doors, arches and
## thin walls are free-placed objects with their own position, rotation and width ("objects" in the .lvl).
##   left drag paint   right drag erase   middle drag / Space+drag pan   wheel zoom   F fit
##   1-3 wall/floor/pit   [ ] brush size   Ctrl+S save   Ctrl+Z undo   Ctrl+N new   Ctrl+D duplicate
##   objects: 4-6 thin wall/arch/door (click places, drag while placing aims it), V select / move,
##   drag the round handle to rotate, R / Shift+R rotate, Del delete, Esc deselect, G snap to grid,
##   A align to walls, Alt ignores snapping and aligning, Shift while rotating steps 15 degrees,
##   the squares round a selected object resize it, Shift+wheel sizes and Alt+wheel turns it, arrows nudge,
##   Ctrl+A all objects, Ctrl+C / Ctrl+X / Ctrl+V copy, cut and paste
##   S select area: drag a box of the map, Del empties it, Shift+Del walls it in, Ctrl+C / X / V work on it too
##   Esc always lets go of whatever is following the mouse
## The object types (and their keys, colours and sizes) come from the game's levels/object_types.json.
## Types with a "model" key are decorative clutter (imported meshes, not procedural geometry); those also
## flagged "scatter": true can be dropped in bulk with the SCATTER PROPS button in the OBJECTS panel.
## The 3D view (F4, level_editor_3d.gd) shows them as their real models and places objects where you point:
## on the floor, or for a "mount": "wall" prop on the wall face and at the height under the mouse.

const Icons := preload("res://editor_icons.gd")
## The interface's colours: dark neutral greys and one blue accent (the map keeps its own palette)
const UI_BG := Color("17181b")
const UI_PANEL := Color("1f2023")
const UI_PANEL2 := Color("27292d")
const UI_FIELD := Color("141517")
const UI_LINE := Color("323439")
const UI_TEXT := Color("d6d8dd")
const UI_DIM := Color("8b8f98")
const ACCENT := Color("4c9eff")
const BG := UI_BG
const PANEL := UI_PANEL
const LINE := UI_LINE
## Zone names for their buttons (the rest: their key, capitalised)
const ZONE_NAMES := {"open_ceiling": "Open ceiling", "endless_ceiling": "Endless ceiling", "noclip_floor": "Noclip floor",
	"hall_reverb": "Hall reverb", "grand": "Grand hall"}
const ZONE_HELP := {"tall": "Tall: a 10.8 m atrium ceiling", "grand": "Grand hall: a 16.2 m ceiling, three storeys of open air over you.\nThe tubes hang down on long chains; the walls round it rise to meet it",
	"hall_reverb": "Hall reverb: every sound rings on in a long, bright, wet tail (a tiled rotunda, a pool hall), whatever the room's shape.\nAUTO ACOUSTICS paints it where the architecture calls for it",
	"muffled": "Muffled: a dead, tight space. Short, dark and dull, the highs gone (a crawlway, a padded corridor).\nAUTO ACOUSTICS paints it in tight, low places", "low": "Crouch-height ceiling", "crawl": "Crawl space: a very low ceiling (about 1.2 m). You have to get right down and crawl through it, hands on the floor, the torch a dim glow", "tiles": "Tile floor instead of carpet",
	"bright": "Always lit, safe room", "dark": "All tubes dead", "dim": "Dim: most tubes dead, the halls darker and foggier (your Dim look, pushed further)", "flicker": "Failing tubes", "grime": "Stained carpet",
	"classic": "Classic: the Kane Pixels found-footage look. Every tube steady and glowing, flat overexposed mono-yellow,\nclear air, milky blacks. Filmed on the camcorder (VHS tape) while you stand in it, with the Camera setting on Auto",
	"liminal": "Liminal: every tube on and steady, flat pale light, halls fading into haze far away. Filmed on the bodycam",
	"mannequin": "Where the mannequins stand: paint as many areas as you like",
	"safe": "Safe: no entity sets foot here. They path round it and are pushed out of it, though they still see in\n(and can reach in from its edge: keep away from the rim)",
	"drain": "Drain: sanity runs out while you stand here, lit or not, torch or not",
	"loot": "Loot: battery packs, tape and camera flashes turn up here far more often",
	"open_ceiling": "Open ceiling: no ceiling. You look up into the floor above, which gets a hole in its floor over these cells\n(whoever is up there can fall through). On the top floor there is only the dark above",
	"echo": "Echo: a long, wet echo on footsteps and everything you hear, whatever the size of the room",
	"loop": "Loop: a corridor that never ends. Paint it along a straight, plain corridor at least 6 cells long (12 or more hides it best):\nwalk on down it and you are back near its start, with nothing to show it. Turning back takes you out.\nIts tubes are all lit and steady, and nothing is scattered in it",
	"abyss": "Abyss: paint it on pits. A pit with no bottom: storey after storey of this level's wall and buzzing tubes,\nfading into haze. Whoever falls in falls for 5 seconds (\"abyss_secs\" in the .lvl, 0: for ever), then the screen goes black and the recording ends: they die falling into the void.\nOver a room on the floor below it still has no bottom (that floor keeps its ceiling). Pits on the lowest floor are abysses anyway",
	"noclip": "Noclip: paint it anywhere: the floor opens there (on pits too). Whoever falls in drops through the floor of reality: the same bottomless fall as an Abyss,\nthe sound of hitting the ground in the black, then they slowly come to, lying on the floor, in another level.\nChoosing this tool asks which level (one per floor of this level)",
	"noclip_floor": "Noclip floor: looks like any floor. Stand on it a moment and it gives: you sink through the carpet and the slab,
the picture tearing, fall through the nothing under the level, and wake up on the floor of another level.
The Kane Pixels opening. Uses the same destination as this floor's Noclip zone (choosing this tool asks)",
	"endless_ceiling": "Endless ceiling: the pit's twin, turned upside down. No ceiling over these cells, and the walls and buzzing tubes go on up for ever,
fading into the dark (it is only ever looked at, you cannot climb it). Paint it on open floor, ideally where the floor above is solid wall
or there is none: it does not make a hole in the floor above, so up there it is just floor"}
const ATMO_HELP := "The level's look (the game's scripts/Render/atmospheres.gd), shown in the 3D view (F4):\ndim = your look (default): failing tubes, warm dark halls, light dies in the fog. Filmed on the bodycam\nclassic = the whole level is a Classic zone: the Kane Pixels found footage, bright, flat, overexposed yellow, clear air. Filmed on the camcorder\nliminal = the whole level is a Liminal zone: all lights on, pale, a haze you can see a long way into. Filmed on the bodycam\n(Which camera: the game's Camera setting on Auto.) A ceiling material with glowing panels (YBR_CeilingSquare, YBR_CeilingLong, BRC_A) swaps the tubes for its panels."
var search: LineEdit
var tool_buttons := {}
var brush_label: Label
var snap_check: Button
var rot_check: Button
var align_check: Button
var paint_name: Label
var floor_pick: OptionButton
var seed_spin: SpinBox
var swatch_buttons := {}             # pbr name -> its swatch in PAINT MATERIALS
var mode_buttons := {}
var view_buttons: Array = []         # [floor, ceiling]
var trigger_dialog: ConfirmationDialog
var noclip_dialog: ConfirmationDialog
var noclip_pick: OptionButton
var trigger_dialog_target_idx := -1
var td_events_container: VBoxContainer
var td_event_rows: Array = []
var td_text: LineEdit
var td_once: CheckBox
var td_width: SpinBox
var td_depth: SpinBox
var td_delay: SpinBox
var td_duration: SpinBox

func _ready() -> void:
	_apply_ui_scale(_load_ui_scale())
	theme = _make_theme()
	_scan_pbr()
	_load_object_types()
	_build_ui()
	_load_index()
	_open(0)

## The game's levels/object_types.json (shared with level_data.gd): one entry per object type
func _load_object_types() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(GAME.path_join("levels/object_types.json")))
	if not (parsed is Dictionary):
		push_error("cannot read levels/object_types.json in " + GAME)
		return
	for t in parsed:
		if str(t).begins_with("_"): continue
		var inf: Dictionary = parsed[t].duplicate()
		inf["col"] = Color(str(inf.get("color", "a39c8a")))
		OBJ_INFO[t] = inf
		OBJ_TYPES.append(t)

func _scan_pbr() -> void:
	var d := DirAccess.open(GAME.path_join("textures/pbr"))
	if d == null: return
	for n in d.get_directories():
		pbr_names.append(n)
	pbr_names.sort()

# ---------------------------------------------------------------- theme
## A box style: `bg` filled, `border` round it (`widths`: left, top, right, bottom; default all 1)
func _box(bg: Color, border := LINE, radius := 0, margin := 8, widths: Array = []) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	if widths.size() == 4:
		sb.border_width_left = widths[0]
		sb.border_width_top = widths[1]
		sb.border_width_right = widths[2]
		sb.border_width_bottom = widths[3]
	else:
		sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	sb.anti_aliasing = radius > 0
	return sb

## A dark, neutral, flat theme in the manner of the big editors: grey panels, one blue accent for what is
## active or selected, a clean sans face (the map keeps its own colours and its VCR labels)
func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 14
	var btn_n := _box(UI_PANEL2, UI_LINE, 4, 6)
	var btn_h := _box(Color("33353b"), Color("464950"), 4, 6)
	var btn_p := _box(Color("23395a"), ACCENT, 4, 6)
	for c in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", c, btn_n)
		t.set_stylebox("hover", c, btn_h)
		t.set_stylebox("pressed", c, btn_p)
		t.set_stylebox("hover_pressed", c, btn_p)
		t.set_stylebox("focus", c, StyleBoxEmpty.new())
		t.set_stylebox("disabled", c, _box(UI_PANEL, UI_LINE, 4, 6))
		t.set_color("font_color", c, UI_TEXT)
		t.set_color("font_hover_color", c, Color.WHITE)
		t.set_color("font_pressed_color", c, Color.WHITE)
		t.set_color("font_hover_pressed_color", c, Color.WHITE)
		t.set_color("font_disabled_color", c, UI_DIM)
		t.set_color("icon_normal_color", c, UI_TEXT)
		t.set_constant("h_separation", c, 6)
		t.set_constant("icon_max_width", c, 20)
	for c in ["CheckBox", "CheckButton"]:
		t.set_stylebox("normal", c, _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 4))
		t.set_stylebox("hover", c, _box(Color(1, 1, 1, 0.04), Color(0, 0, 0, 0), 4, 4))
		t.set_stylebox("pressed", c, _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 4))
		t.set_stylebox("hover_pressed", c, _box(Color(1, 1, 1, 0.04), Color(0, 0, 0, 0), 4, 4))
		t.set_stylebox("focus", c, StyleBoxEmpty.new())
		t.set_color("font_color", c, UI_TEXT)
		t.set_color("font_hover_color", c, Color.WHITE)
		t.set_color("font_pressed_color", c, UI_TEXT)
		t.set_color("font_hover_pressed_color", c, Color.WHITE)
	for c in ["LineEdit", "SpinBox"]:
		t.set_stylebox("normal", c, _box(UI_FIELD, UI_LINE, 4, 6))
		t.set_stylebox("focus", c, _box(UI_FIELD, ACCENT, 4, 6))
		t.set_stylebox("read_only", c, _box(UI_PANEL, UI_LINE, 4, 6))
		t.set_color("font_color", c, UI_TEXT)
		t.set_color("font_placeholder_color", c, Color(UI_DIM, 0.7))
		t.set_color("caret_color", c, ACCENT)
		t.set_color("selection_color", c, Color(ACCENT, 0.35))
	t.set_color("font_color", "Label", UI_TEXT)
	t.set_stylebox("panel", "PanelContainer", _box(UI_PANEL, UI_PANEL, 0, 8))
	t.set_stylebox("panel", "PopupPanel", _box(UI_PANEL2, UI_LINE, 6, 8))
	t.set_stylebox("panel", "PopupMenu", _box(UI_PANEL2, UI_LINE, 6, 6))
	t.set_stylebox("hover", "PopupMenu", _box(Color("23395a"), Color("23395a"), 4, 4))
	t.set_stylebox("separator", "PopupMenu", _box(UI_LINE, UI_LINE, 0, 0))
	t.set_color("font_color", "PopupMenu", UI_TEXT)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	t.set_color("font_accelerator_color", "PopupMenu", UI_DIM)
	t.set_color("font_disabled_color", "PopupMenu", Color(UI_DIM, 0.6))
	t.set_constant("v_separation", "PopupMenu", 7)
	t.set_constant("item_start_padding", "PopupMenu", 10)
	t.set_constant("item_end_padding", "PopupMenu", 14)
	for st in ["normal", "pressed", "hover_pressed", "disabled"]:
		t.set_stylebox(st, "MenuBar", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 6))
	t.set_stylebox("hover", "MenuBar", _box(UI_PANEL2, UI_PANEL2, 4, 6))
	t.set_color("font_color", "MenuBar", UI_TEXT)
	t.set_color("font_hover_color", "MenuBar", Color.WHITE)
	t.set_color("font_pressed_color", "MenuBar", Color.WHITE)
	t.set_stylebox("panel", "AcceptDialog", _box(UI_PANEL, UI_LINE, 0, 12))
	t.set_stylebox("embedded_border", "Window", _box(UI_PANEL, UI_LINE, 6, 12))
	t.set_stylebox("embedded_unfocused_border", "Window", _box(UI_PANEL, UI_LINE, 6, 12))
	t.set_color("title_color", "Window", UI_TEXT)
	t.set_stylebox("panel", "ItemList", _box(UI_FIELD, UI_LINE, 4, 4))
	t.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("selected", "ItemList", _box(Color("23395a"), Color("23395a"), 3, 4))
	t.set_stylebox("selected_focus", "ItemList", _box(Color("23395a"), ACCENT, 3, 4))
	t.set_stylebox("hovered", "ItemList", _box(Color(1, 1, 1, 0.05), Color(0, 0, 0, 0), 3, 4))
	t.set_stylebox("cursor", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("cursor_unfocused", "ItemList", StyleBoxEmpty.new())
	t.set_color("font_color", "ItemList", UI_TEXT)
	t.set_color("font_selected_color", "ItemList", Color.WHITE)
	t.set_color("font_hovered_color", "ItemList", Color.WHITE)
	t.set_constant("v_separation", "ItemList", 5)
	t.set_constant("icon_margin", "ItemList", 6)
	t.set_stylebox("panel", "TabContainer", _box(UI_PANEL, UI_PANEL, 0, 6))
	t.set_stylebox("tab_selected", "TabContainer", _box(UI_PANEL, ACCENT, 0, 8, [0, 2, 0, 0]))
	t.set_stylebox("tab_unselected", "TabContainer", _box(UI_BG, UI_BG, 0, 8, [0, 0, 0, 0]))
	t.set_stylebox("tab_hovered", "TabContainer", _box(UI_PANEL2, UI_PANEL2, 0, 8, [0, 0, 0, 0]))
	t.set_stylebox("tabbar_background", "TabContainer", _box(UI_BG, UI_BG, 0, 0))
	t.set_color("font_selected_color", "TabContainer", Color.WHITE)
	t.set_color("font_unselected_color", "TabContainer", UI_DIM)
	t.set_color("font_hovered_color", "TabContainer", UI_TEXT)
	t.set_constant("icon_max_width", "TabContainer", 16)
	t.set_stylebox("scroll", "VScrollBar", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 3))
	t.set_stylebox("grabber", "VScrollBar", _box(Color("3b3e45"), Color("3b3e45"), 4, 3))
	t.set_stylebox("grabber_highlight", "VScrollBar", _box(Color("50545c"), Color("50545c"), 4, 3))
	t.set_stylebox("grabber_pressed", "VScrollBar", _box(ACCENT, ACCENT, 4, 3))
	t.set_stylebox("panel", "TooltipPanel", _box(Color("2e3036"), UI_LINE, 4, 8))
	t.set_color("font_color", "TooltipLabel", UI_TEXT)
	t.set_stylebox("separator", "HSeparator", _box(UI_LINE, UI_LINE, 0, 0))
	t.set_stylebox("separator", "VSeparator", _box(UI_LINE, UI_LINE, 0, 0))
	t.set_constant("separation", "HSeparator", 10)
	t.set_constant("separation", "VSeparator", 10)
	t.set_constant("separation", "VBoxContainer", 6)
	t.set_constant("separation", "HSplitContainer", 4)
	return t

func _label(text: String, size := 14, color := UI_TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _panel(min_w: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(min_w, 0)
	return p

## A small caps heading over a group of controls
func _heading(text: String) -> Label:
	var l := _label(text.to_upper(), 11, UI_DIM)
	l.add_theme_constant_override("line_spacing", 0)
	return l

# ---------------------------------------------------------------- UI
## menu bar | tool bar | levels, level, layers, outliner | the map | inspector and tool palette | status bar
func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	root.add_child(_build_menubar())
	root.add_child(_build_toolbar())
	var body := HSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	var inner := HSplitContainer.new()
	split_left = body
	split_right = inner
	body.add_child(_build_left_dock())
	body.add_child(inner)
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 0)
	inner.add_child(mid)
	mid.add_child(_build_viewbar())
	canvas = Control.new()
	canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.clip_contents = true
	canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
	canvas.focus_mode = Control.FOCUS_CLICK      # clicking the map commits whatever inspector field was being typed in
	canvas.draw.connect(_draw_canvas)
	canvas.gui_input.connect(_canvas_input)
	canvas.resized.connect(canvas.queue_redraw)
	mid.add_child(canvas)
	preview3d = preload("res://level_editor_3d.gd").new(self)
	canvas.add_child(preview3d)
	inner.add_child(_build_right_dock())
	_restore_splits()
	root.add_child(_build_statusbar())
	_build_dialogs()
	var tick := Timer.new()
	tick.wait_time = 0.25
	tick.autostart = true
	tick.timeout.connect(_dock_tick)
	add_child(tick)

# ---- menu bar
func _build_menubar() -> Control:
	var top := PanelContainer.new()
	top.add_theme_stylebox_override("panel", _box(UI_BG, UI_LINE, 0, 4, [0, 0, 0, 1]))
	var tb := HBoxContainer.new()
	tb.add_theme_constant_override("separation", 4)
	top.add_child(tb)
	var logo := TextureRect.new()
	logo.texture = Icons.icon("cube", ACCENT, 20)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(28, 26)
	tb.add_child(logo)
	var mb := MenuBar.new()
	mb.flat = true
	mb.prefer_global_menu = false
	tb.add_child(mb)
	var ctrl := KEY_MASK_CTRL
	_menu(mb, "File", [
		["New level", _ask_new, ctrl | KEY_N], ["Duplicate level", _ask_dup, ctrl | KEY_D], ["Rename level...", _ask_rename, 0], [],
		["Save", save, ctrl | KEY_S], ["Save and bake lighting", func():
			save()
			if current >= 0: _bake(str(index[current].id)), 0], [],
		["Test", _test_level, KEY_F5], ["Test here (noclip, cell under the mouse)", func(): _test_level(true), KEY_F6], [],
		["Delete level...", _ask_delete, 0]])
	_menu(mb, "Edit", [
		["Undo", _undo, ctrl | KEY_Z], ["Redo", _redo, ctrl | KEY_Y], [],
		["Cut", _cut, ctrl | KEY_X], ["Copy", func(): _copy(), ctrl | KEY_C], ["Paste at the mouse", func(): _paste(false), ctrl | KEY_V],
		["Paste in place", func(): _paste(true), ctrl | KEY_MASK_SHIFT | KEY_V], [],
		["Select all objects", func():
			_select_tool("select")
			_select_all_objects(), ctrl | KEY_A],
		["Duplicate selection", _duplicate_selected, 0], ["Rotate 90° clockwise   R", func(): _rotate_selected(90.0), 0],
		["Rotate 90° anticlockwise   Shift+R", func(): _rotate_selected(-90.0), 0], ["Delete selection   Del", _delete_selected, 0]])
	_menu(mb, "View", [
		["3D view", _toggle_3d, KEY_F4], ["Fit the map   F", _fit, 0],
		["Zoom in   +", func(): _zoom_at(canvas.size * 0.5, 1.25, true), 0], ["Zoom out   -", func(): _zoom_at(canvas.size * 0.5, 1.0 / 1.25, true), 0], [],
		["Floor / ceiling view   C", func(): _set_view(not view_ceiling), 0], [],
		["Textures", null, 0, "show_tex"], ["Zones", null, 0, "show_zones"], ["Painted materials", null, 0, "show_paint"],
		["Objects", null, 0, "show_objects"], ["Grid", null, 0, "show_grid"], ["The floor below / above", null, 0, "show_onion"],
		["Control hints", null, 0, "show_hints"], [],
		["Larger interface", func(): _step_ui_scale(0.1), ctrl | KEY_EQUAL], ["Smaller interface", func(): _step_ui_scale(-0.1), ctrl | KEY_MINUS],
		["Interface to fit the screen", func(): _step_ui_scale(0.0), ctrl | KEY_0]])
	_menu(mb, "Level", [
		["Add a floor above", func(): _add_floor(1), 0], ["Add a floor below", func(): _add_floor(-1), 0],
		["Delete this floor", _delete_floor, 0], ["Repeat this floor down", _repeat_down, 0], [],
		["Go up a floor   PgUp", func(): _step_floor(1), 0], ["Go down a floor   PgDn", func(): _step_floor(-1), 0], [],
		["Auto acoustics (paint reverb zones)", _auto_acoustics, 0], ["Scatter props", _scatter_props, 0],
		["Generate the whole floor", _generate_whole, 0], ["Trim the map to what is used", _trim, 0], [],
		["Move up the playlist", func(): _move(-1), 0], ["Move down the playlist", func(): _move(1), 0]])
	_menu(mb, "Help", [["Keyboard and mouse...", _show_help, 0]])
	title_label = _label("", 14, UI_DIM)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.clip_text = true
	title_label.custom_minimum_size = Vector2(80, 0)
	tb.add_child(title_label)
	tb.add_child(_action_button("Test", "play", Color("3ecf6e"), func(): _test_level(), "Save, then play this level from its spawn marker  (F5)"))
	tb.add_child(_action_button("Test here", "play_here", Color("3ecf6e"), func(): _test_level(true), "Start on the cell under the mouse, in noclip (fly through walls)  (F6)"))
	var sv := _action_button("Save", "save", Color.WHITE, save, "Save the level  (Ctrl+S)")
	sv.add_theme_stylebox_override("normal", _box(Color("2f6fcf"), Color("2f6fcf"), 4, 6))
	sv.add_theme_stylebox_override("hover", _box(Color("3d80e0"), Color("3d80e0"), 4, 6))
	tb.add_child(sv)
	return top

## A menu of the menu bar: items [label, callable, accelerator] (an empty item: a separator; with a fourth, the
## name of a bool property: a tick item that flips it)
func _menu(mb: MenuBar, title: String, items: Array) -> PopupMenu:
	var pm := PopupMenu.new()
	pm.name = title
	mb.add_child(pm)
	var acts: Array = []
	for it: Array in items:
		var id := acts.size()
		acts.append(it)
		if it.is_empty(): pm.add_separator("", id)
		elif it.size() > 3: pm.add_check_item(it[0], id, it[2])
		else: pm.add_item(it[0], id, it[2])
	pm.about_to_popup.connect(func():
		for id in acts.size():
			if (acts[id] as Array).size() > 3: pm.set_item_checked(pm.get_item_index(id), bool(get(acts[id][3]))))
	pm.id_pressed.connect(func(id: int):
		var it: Array = acts[id]
		if it.size() > 3:
			set(it[3], not bool(get(it[3])))
			_sync_view_toggles()
			canvas.queue_redraw()
		elif it.size() > 1 and it[1] is Callable:
			(it[1] as Callable).call())
	return pm

## A labelled button with an icon, for the bar's actions
func _action_button(text: String, icon_name: String, col: Color, cb: Callable, tip: String) -> Button:
	var b := _button(text, cb)
	b.icon = Icons.icon(icon_name, col, 18)
	b.tooltip_text = tip
	b.add_theme_font_size_override("font_size", 13)
	return b

# ---- tool bar
func _build_toolbar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _box(UI_PANEL, UI_LINE, 0, 4, [0, 0, 0, 1]))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 2)
	bar.add_child(h)
	h.add_child(_tool_icon("select", "select", "Select / move  (V)\nClick an object to edit it, drag to move it, its round knob turns it, its squares size it.\nDrag on empty map to box-select; Shift+click adds; Ctrl+A takes every object"))
	h.add_child(_tool_icon("area", "area", "Select area  (S)\nDrag a box of the map: Del empties it, Shift+Del walls it in, Ctrl+C / X / V copy, cut, paste it"))
	h.add_child(_vsep())
	h.add_child(_tool_icon("base:" + WALL, "wall", "Wall  (1): solid full-height wall blocks"))
	h.add_child(_tool_icon("base:" + FLOOR, "floor", "Floor  (2): open floor. Drawn past the map's edge it grows the map"))
	h.add_child(_tool_icon("base:" + PIT, "pit", "Pit  (3): a shaft into the dark; over open floor below, a hole through to it"))
	h.add_child(_vsep())
	var mode_group := ButtonGroup.new()
	for m: Array in [["brush", "brush", "Brush  (B): drag to paint, [ ] sizes it"], ["rect", "rect", "Rectangle  (M): drag a box. Shift does this in any mode"],
			["fill", "fill", "Fill  (K): click fills the connected area. Ctrl does this in any mode"]]:
		var b := _icon_toggle(m[1], m[2])
		b.button_group = mode_group
		b.button_pressed = m[0] == mode
		b.pressed.connect(func(): _set_mode(m[0]))
		mode_buttons[m[0]] = b
		h.add_child(b)
	var sz_dn := _icon_button("minus", "Smaller brush  ([)", func(): _set_brush(brush - 1))
	h.add_child(sz_dn)
	brush_label = _label("1", 13, UI_TEXT)
	brush_label.custom_minimum_size = Vector2(18, 0)
	brush_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	brush_label.tooltip_text = "Brush size"
	brush_label.mouse_filter = Control.MOUSE_FILTER_PASS
	h.add_child(brush_label)
	h.add_child(_icon_button("plus", "Bigger brush  (])", func(): _set_brush(brush + 1)))
	h.add_child(_vsep())
	snap_check = _icon_toggle("magnet", "Snap to grid  (G): cell centres and edges. Alt places freely")
	snap_check.button_pressed = snap
	snap_check.toggled.connect(func(on): snap = on)
	h.add_child(snap_check)
	rot_check = _icon_toggle("rotate", "Snap rotation to 90°. Off: free (Shift steps 15°)")
	rot_check.button_pressed = rot_snap
	rot_check.toggled.connect(func(on): rot_snap = on)
	h.add_child(rot_check)
	align_check = _icon_toggle("align", "Align to walls  (A): a piece on a cell edge lines up with it; square on a cell it spans the corridor it is in")
	align_check.button_pressed = align
	align_check.toggled.connect(func(on): align = on)
	h.add_child(align_check)
	h.add_child(_vsep())
	var view_group := ButtonGroup.new()
	for v: Array in [[false, "floorview", "Floor view: floor materials, walls drawn as their tops"], [true, "ceiling", "Ceiling view  (C): the ceiling's materials, to see and paint them"]]:
		var b := _icon_toggle(v[1], v[2])
		b.button_group = view_group
		b.button_pressed = v[0] == view_ceiling
		b.pressed.connect(func(): _set_view(v[0]))
		view_buttons.append(b)
		h.add_child(b)
	h.add_child(_vsep())
	h.add_child(_icon_button("undo", "Undo  (Ctrl+Z)", _undo))
	h.add_child(_icon_button("redo", "Redo  (Ctrl+Y)", _redo))
	h.add_child(_vsep())
	h.add_child(_icon_button("zoom_out", "Zoom out  (-)", func(): _zoom_at(canvas.size * 0.5, 1.0 / 1.25, true)))
	h.add_child(_icon_button("zoom_in", "Zoom in  (+)", func(): _zoom_at(canvas.size * 0.5, 1.25, true)))
	h.add_child(_icon_button("fit", "Fit the map  (F)", _fit))
	h.add_child(_icon_button("cube", "3D view  (F4)\nRight drag orbits, wheel zooms, E walks it. Pick an object and click where it goes", _toggle_3d))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(gap)
	var fl := TextureRect.new()
	fl.texture = Icons.icon("layers", UI_DIM, 18)
	fl.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fl.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	fl.custom_minimum_size = Vector2(22, 22)
	h.add_child(fl)
	floor_pick = OptionButton.new()
	floor_pick.add_theme_font_size_override("font_size", 13)
	floor_pick.custom_minimum_size = Vector2(150, 0)
	floor_pick.tooltip_text = "The floor (storey) you are editing  (PageUp / PageDown).\nStairs join floors; a pit over open floor below is a hole through to it"
	floor_pick.item_selected.connect(func(i): _switch_floor(floor_pick.get_item_id(i) - 1000))
	h.add_child(floor_pick)
	h.add_child(_icon_button("floor_up", "Add a floor above the top one", func(): _add_floor(1)))
	h.add_child(_icon_button("floor_down", "Add a basement below the bottom one", func(): _add_floor(-1)))
	return bar

func _vsep() -> VSeparator:
	var s := VSeparator.new()
	s.add_theme_constant_override("separation", 8)
	return s

## A square icon button
func _icon_button(icon_name: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.icon = Icons.icon(icon_name, UI_TEXT, 18)
	b.tooltip_text = tip
	b.flat = true
	b.custom_minimum_size = Vector2(30, 30)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_stylebox_override("hover", _box(UI_PANEL2, UI_PANEL2, 4, 4))
	b.add_theme_stylebox_override("pressed", _box(Color("23395a"), Color("23395a"), 4, 4))
	b.pressed.connect(cb)
	return b

## A square icon button that stays down while its setting is on
func _icon_toggle(icon_name: String, tip: String) -> Button:
	var b := _icon_button(icon_name, tip, func(): pass)
	b.toggle_mode = true
	b.add_theme_stylebox_override("hover_pressed", _box(Color("2b4a75"), ACCENT, 4, 4))
	b.add_theme_stylebox_override("pressed", _box(Color("23395a"), ACCENT, 4, 4))
	return b

## A tool in the tool bar: an icon toggle that picks the tool (one of tool_buttons)
func _tool_icon(id: String, icon_name: String, tip: String) -> Button:
	var b := _icon_toggle(icon_name, tip)
	b.button_pressed = id == tool
	b.pressed.connect(func(): _select_tool(id))
	_register_tool(id, b)
	return b

# ---- the bar over the map: which layers of the map are drawn
var view_toggles := {}               # property -> its toggle

func _build_viewbar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _box(UI_BG, UI_LINE, 0, 3, [0, 0, 0, 1]))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 1)
	bar.add_child(h)
	h.add_child(_heading(" Show"))
	for l: Array in [["show_tex", "texture", "Textures on the cells"], ["show_zones", "zones", "Zones"], ["show_paint", "paint", "Painted materials (outlined and listed)"],
			["show_objects", "objects", "Objects"], ["show_grid", "grid", "Grid lines"], ["show_onion", "onion", "The floor below (or above), faintly, to line floors and stairs up"],
			["show_hints", "hint", "The current tool's controls, along the bottom of the map"]]:
		var b := _icon_toggle(l[1], l[2])
		b.custom_minimum_size = Vector2(26, 24)
		b.button_pressed = bool(get(l[0]))
		b.toggled.connect(func(on):
			set(l[0], on)
			canvas.queue_redraw())
		view_toggles[l[0]] = b
		h.add_child(b)
	return bar

## The view toggles follow their properties (after the View menu changed one)
func _sync_view_toggles() -> void:
	for k in view_toggles: (view_toggles[k] as Button).set_pressed_no_signal(bool(get(k)))

# ---- left dock: levels, the level's settings, its layers, its objects
var layers_box: VBoxContainer
var outliner: ItemList
var outliner_filter: LineEdit
var _outliner_rows: Array = []       # outliner row -> object index
var _dock_dirty := true
var insp_head: Label
var insp_icon: TextureRect

func _build_left_dock() -> Control:
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(250, 0)
	tabs.clip_tabs = false
	tabs.add_theme_font_size_override("font_size", 12)
	tabs.add_theme_stylebox_override("tab_selected", _box(UI_PANEL, ACCENT, 0, 6, [0, 2, 0, 0]))
	tabs.add_theme_stylebox_override("tab_unselected", _box(UI_BG, UI_BG, 0, 6, [0, 0, 0, 0]))
	tabs.add_theme_stylebox_override("tab_hovered", _box(UI_PANEL2, UI_PANEL2, 0, 6, [0, 0, 0, 0]))
	tabs.drag_to_rearrange_enabled = false
	# Levels
	var lv := VBoxContainer.new()
	lv.name = "Levels"
	tabs.add_child(lv)
	search = LineEdit.new()
	search.placeholder_text = "Filter levels"
	search.clear_button_enabled = true
	search.right_icon = Icons.icon("search", UI_DIM, 16)
	search.text_changed.connect(func(t): filter = t.to_lower(); _refresh_list())
	lv.add_child(search)
	level_list = ItemList.new()
	level_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	level_list.item_selected.connect(_on_list_pick)
	lv.add_child(level_list)
	var r1 := GridContainer.new()
	r1.columns = 3
	lv.add_child(r1)
	for b: Array in [["New", "plus", _ask_new, "A new level (Ctrl+N)"], ["Copy", "copy", _ask_dup, "Duplicate this level (Ctrl+D)"], ["Rename", "rename", _ask_rename, "Rename this level"],
			["Up", "up", func(): _move(-1), "Earlier in the playlist"], ["Down", "down", func(): _move(1), "Later in the playlist"], ["Delete", "trash", _ask_delete, "Delete this level"]]:
		var bt := _action_button(b[0], b[1], UI_TEXT, b[2], b[3])
		bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r1.add_child(bt)
	# Level
	var ls := ScrollContainer.new()
	ls.name = "Level"
	ls.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(ls)
	var lvl := VBoxContainer.new()
	lvl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ls.add_child(lvl)
	_build_level_settings(lvl)
	# Layers
	var ly := ScrollContainer.new()
	ly.name = "Layers"
	ly.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(ly)
	layers_box = VBoxContainer.new()
	layers_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ly.add_child(layers_box)
	# Outliner
	var ol := VBoxContainer.new()
	ol.name = "Outliner"
	tabs.add_child(ol)
	outliner_filter = LineEdit.new()
	outliner_filter.placeholder_text = "Filter objects"
	outliner_filter.clear_button_enabled = true
	outliner_filter.right_icon = Icons.icon("search", UI_DIM, 16)
	outliner_filter.text_changed.connect(func(_t): _refresh_outliner())
	ol.add_child(outliner_filter)
	outliner = ItemList.new()
	outliner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outliner.select_mode = ItemList.SELECT_SINGLE
	outliner.fixed_icon_size = Vector2i(20, 20)
	outliner.item_selected.connect(func(row: int):
		if row < _outliner_rows.size(): _focus_object(int(_outliner_rows[row])))
	ol.add_child(outliner)
	ol.add_child(_note("Every object on this floor. Click one to select it and bring it into view."))
	for i: int in [0, 1, 2, 3]:
		tabs.set_tab_icon(i, Icons.icon(["folder", "sliders", "layers", "list"][i], UI_DIM, 16))
	return tabs

## The Level tab: the map's size, the level's look and lights, and its materials
func _build_level_settings(lvl: VBoxContainer) -> void:
	lvl.add_child(_heading("Map"))
	var size_row := HBoxContainer.new()
	lvl.add_child(size_row)
	size_row.add_child(_label("Size", 13, UI_DIM))
	size_spin = SpinBox.new()
	size_spin.min_value = 8
	size_spin.max_value = MAX_SIZE
	size_spin.value = grid_size
	size_spin.tooltip_text = "Cells a side (the map is square). It also grows by itself when you draw past its edge"
	size_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_row.add_child(size_spin)
	size_row.add_child(_button("Resize", func(): _resize(int(size_spin.value))))
	var trim_b := _button("Trim", _trim)
	trim_b.tooltip_text = "Shrink the map (every floor) to the space in use, plus a wall border"
	size_row.add_child(trim_b)
	lvl.add_child(HSeparator.new())
	lvl.add_child(_heading("Look and light"))
	var g := GridContainer.new()
	g.columns = 2
	lvl.add_child(g)
	g.add_child(_label("Atmosphere", 13, UI_DIM))
	atmo_pick = OptionButton.new()
	for a in ATMOS: atmo_pick.add_item(a.capitalize())
	atmo_pick.tooltip_text = ATMO_HELP
	atmo_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	atmo_pick.item_selected.connect(func(_i): _mark_dirty())
	g.add_child(atmo_pick)
	g.add_child(_label("Lights", 13, UI_DIM))
	lights_pick = OptionButton.new()
	for l: Array in LIGHTS: lights_pick.add_item(l[1])
	lights_pick.tooltip_text = "The ceiling's lights.\nCeiling panels: the ceiling's own light panels; a plain tiled ceiling (Tiles107, the default) gets squares of its tiles lit from behind.\nTroffers: hanging 1 x 4 fluorescent fixtures with their humming ballasts (the Level 0 look).\nNone: only what windows and the torch give"
	lights_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lights_pick.item_selected.connect(func(_i): _mark_dirty())
	g.add_child(lights_pick)
	g.add_child(_label("Bounce light", 13, UI_DIM))
	gi_pick = OptionButton.new()
	for s in ["Auto", "On", "Off"]: gi_pick.add_item(s)
	gi_pick.tooltip_text = "Real-time GI (SDFGI). Auto = only levels with a Classic zone. Heavy on weak GPUs"
	gi_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gi_pick.item_selected.connect(func(_i): _mark_dirty())
	g.add_child(gi_pick)
	endless_check = CheckBox.new()
	endless_check.text = "Endless floors"
	endless_check.tooltip_text = "The lowest floor repeats for ever below and the highest for ever above.\nA pit through the lowest floor has no bottom. Stairs still end where the level's own floors do"
	endless_check.toggled.connect(func(_on): _mark_dirty())
	lvl.add_child(endless_check)
	wrap_check = CheckBox.new()
	wrap_check.text = "Endless halls (wrap the edges)"
	wrap_check.tooltip_text = "Walk off one edge and you are on the opposite side, seamlessly; the halls are drawn repeating out to the horizon.\nLeave openings on the edges. Monsters stay inside the map"
	wrap_check.toggled.connect(func(_on): _mark_dirty())
	lvl.add_child(wrap_check)
	lvl.add_child(HSeparator.new())
	lvl.add_child(_heading("Materials"))
	lvl.add_child(_note("What every cell you have not painted is made of. The ceiling's default is Tiles107."))
	for slot in SLOTS:
		var row := HBoxContainer.new()
		lvl.add_child(row)
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(38, 38)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		row.add_child(tr)
		slot_previews[slot] = tr
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 2)
		row.add_child(col)
		col.add_child(_label(slot.capitalize() + ("  (Tiles zones)" if slot == "tiles" else ""), 12, UI_DIM))
		var ob := OptionButton.new()
		ob.add_item("Tiles107 (default)" if slot == "ceiling" else "Game default")
		for n in pbr_names: ob.add_item(n)
		ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ob.fit_to_longest_item = false
		ob.item_selected.connect(func(i): _set_material(slot, "" if i == 0 else pbr_names[i - 1]))
		col.add_child(ob)
		slot_picks[slot] = ob

# ---- right dock: the inspector, then the tool palette
func _build_right_dock() -> Control:
	var right := _panel(270)
	right.add_theme_stylebox_override("panel", _box(UI_PANEL, UI_LINE, 0, 6, [1, 0, 0, 0]))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tool_scroll = scroll
	right.add_child(scroll)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(side)
	_build_inspector(side)
	_build_tabs(side)
	# BUILD
	var ter := _section(side, "TERRAIN")
	var tg := _tile_grid(ter)
	for b: Array in [[WALL, "Wall", "wall", "A solid full-depth wall block  (1)"], [FLOOR, "Floor", "floor", "Open floor  (2)"],
			[PIT, "Pit", "pit", "A shaft falling into the dark. Over an open cell of the floor below it is a hole through to that floor  (3)"]]:
		tg.add_child(_tile("base:" + b[0], b[1], Icons.icon(b[2], BASE_COLORS[b[0]].lightened(0.3), 24), b[3]))
	var aw := CheckBox.new()
	aw.text = "Auto walls round rectangles"
	aw.button_pressed = auto_walls
	aw.tooltip_text = "Floor drawn as a rectangle (Rectangle mode, or Shift+drag) becomes a room: floor with a wall all round it"
	aw.toggled.connect(func(on): auto_walls = on)
	ter.add_child(aw)
	var sel := _section(side, "SELECT AREA")
	sel.add_child(_tool_button("area", "Select area  (S)", SEL, "Drag a box on the map to select everything in it: rooms, zones, paint, objects.\nDel empties it, Shift+Del walls it in, Ctrl+C / Ctrl+X / Ctrl+V copy, cut and paste it"))
	var edge_btn := _button("Delete edge area", func():
		_select_tool("area")
		area = Rect2i()
		edge_cut = true
		_status("Delete edge area: drag a box from the map's edge over what to cut off (right click / Esc cancels). It goes on every floor"))
	edge_btn.tooltip_text = "Drag a box that touches the map's edge: those columns or rows are cut off the whole level"
	sel.add_child(edge_btn)
	var selgrid := GridContainer.new()
	selgrid.columns = 2
	sel.add_child(selgrid)
	for a: Array in [["Empty  Del", func(): _area_clear(), "Delete every object, zone, painted material and marker in the box. The rooms stay"],
			["Wall in", func(): _area_clear(WALL), "Empty the box and fill it with solid wall (Shift+Del)"],
			["Floor", func(): _area_clear(FLOOR), "Empty the box and make it all open floor"],
			["Pit", func(): _area_clear(PIT), "Empty the box and make it all pit"],
			["Copy", _copy, "Ctrl+C"], ["Cut", _cut, "Ctrl+X: copy the box, then wall it in"],
			["Paste", func(): _paste(true), "Paste on the cells it was copied from (Ctrl+Shift+V). Ctrl+V pastes at the mouse"],
			["Whole floor", _area_all, "Select the whole floor (Ctrl+A)"],
			["Cut columns", func(): _area_cut_strip(true), "Cut the box's columns right out of the map, on every floor"],
			["Cut rows", func(): _area_cut_strip(false), "Cut the box's rows right out of the map, on every floor"],
			["Crop to box", _area_crop, "Keep only what is in the box, on every floor"]]:
		var ab := _button(a[0], func():
			if tool != "area" and a[0] != "Paste": _select_tool("area")
			a[1].call())
		ab.tooltip_text = a[2]
		ab.add_theme_font_size_override("font_size", 13)
		ab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		selgrid.add_child(ab)
	# objects, one panel per object_types.json "category", each a grid of tiles
	var titles := {"walls": "WALLS", "openings": "DOORS & STAIRS", "vertical": "LEVELS & STAIRS", "light": "WINDOWS & LIGHT",
		"water": "WATER & POOLS", "events": "EVENTS", "props": "PROPS"}
	var panels := {}
	var grids := {}
	for cat in ["walls", "openings", "vertical", "light", "water", "events", "props"]:
		var used := OBJ_TYPES.any(func(t): return str(OBJ_INFO[t].get("category", "props")) == cat)
		if not used: continue
		panels[cat] = _section(side, titles[cat], cat != "props")
		grids[cat] = _tile_grid(panels[cat])
	for t in OBJ_TYPES:
		var inf: Dictionary = OBJ_INFO[t]
		var cat := str(inf.get("category", "props"))
		if not grids.has(cat):
			panels[cat] = _section(side, cat.to_upper(), true)
			grids[cat] = _tile_grid(panels[cat])
		var hotkey := str(inf.get("key", ""))
		var b := _tile("obj:" + t, str(inf.label), _obj_icon(t, inf.col), str(inf.get("help", "")) + ("\nKey: %s" % hotkey if hotkey != "" else "") + "\nRight click on the map deletes")
		grids[cat].add_child(b)
	if panels.has("props") and OBJ_TYPES.any(func(t): return bool(OBJ_INFO[t].get("scatter", false))):
		var scatter_b := _action_button("Scatter props", "scatter", GOLD, _scatter_props, "Drop a random spread of clutter props onto open floor, clear of the markers and what is already placed. One undo step")
		panels["props"].add_child(scatter_b)
	var mk := _section(side, "MARKERS")
	var mgrid := _tile_grid(mk)
	for m in MARKERS:
		mgrid.add_child(_tile("mark:" + m, m.capitalize().replace("Tv", "TV"), Icons.icon(m, MARKERS[m], 24),
			"Click places, right click removes" + ("\nDrag from the marker to turn where the player looks (Shift snaps to 15°)" if m == "spawn" else "")))
	# PAINT
	var pnt := _section(side, "PAINT MATERIALS")
	pnt.add_child(_note("Pick a material and a surface, drag over cells. Right click puts the level's material back. Alt+click picks up the material under the mouse; Ctrl+click fills an area."))
	var srow := HBoxContainer.new()
	pnt.add_child(srow)
	for slot in PAINT_SLOTS:
		var sb := _tool_button("paint:" + slot, slot.capitalize(), GOLD, "Paint the brush material on the %s of the cells you drag over. Right click clears it" % slot)
		sb.icon = Icons.icon({"wall": "wall", "floor": "floor", "ceiling": "ceiling"}[slot], UI_TEXT, 16)
		sb.alignment = HORIZONTAL_ALIGNMENT_CENTER
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		srow.add_child(sb)
	paint_name = _label("", 12, UI_TEXT)
	paint_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	paint_name.custom_minimum_size = Vector2(200, 0)
	pnt.add_child(paint_name)
	var scrow := HBoxContainer.new()
	pnt.add_child(scrow)
	scrow.add_child(_label("Scatter", 12, UI_DIM))
	var sc := HSlider.new()
	sc.min_value = 5
	sc.max_value = 100
	sc.step = 5
	sc.value = scatter
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.tooltip_text = "Paint only this share of the cells, at random"
	var sc_lbl := _label("100%", 12, UI_TEXT)
	sc.value_changed.connect(func(v):
		scatter = int(v)
		sc_lbl.text = "%d%%" % scatter
		_set_paint_mat(paint_mat))
	scrow.add_child(sc)
	scrow.add_child(sc_lbl)
	pnt.add_child(_note("Ctrl+click swatches to mix materials: each painted cell takes one of them at random."))
	var sgrid := GridContainer.new()
	sgrid.columns = 4
	sgrid.add_theme_constant_override("h_separation", 4)
	sgrid.add_theme_constant_override("v_separation", 4)
	pnt.add_child(sgrid)
	for n in pbr_names:
		var b := Button.new()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(56, 56)
		b.icon = _thumb(n).tex
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_constant_override("icon_max_width", 0)       # (the theme caps icons at 20 px: a swatch fills its button)
		b.tooltip_text = n
		b.add_theme_stylebox_override("normal", _box(UI_FIELD, UI_LINE, 4, 3))
		b.add_theme_stylebox_override("hover", _box(UI_FIELD, Color("6a6e78"), 4, 3))
		b.add_theme_stylebox_override("pressed", _box(UI_FIELD, ACCENT, 4, 3))
		b.add_theme_stylebox_override("hover_pressed", _box(UI_FIELD, ACCENT, 4, 3))
		(b.get_theme_stylebox("pressed") as StyleBoxFlat).set_border_width_all(2)
		b.pressed.connect(func():
			if Input.is_key_pressed(KEY_CTRL) and n != paint_mat:
				if paint_mix.has(n): paint_mix.erase(n)
				else: paint_mix.append(n)
				_set_paint_mat(paint_mat)
			else:
				paint_mix.clear()
				_set_paint_mat(n)
			if not tool.begins_with("paint:"): _select_tool("paint:" + ("ceiling" if view_ceiling else "floor")))
		swatch_buttons[n] = b
		sgrid.add_child(b)
	var clear_b := _button("Clear all paint", func():
		_push_undo()
		for slot in PAINT_SLOTS: paint[slot].clear()
		_mark_dirty()
		_status("All painted materials removed (Ctrl+Z brings them back)"))
	clear_b.tooltip_text = "Take every painted material off this level, back to the level materials"
	pnt.add_child(clear_b)
	if not pbr_names.is_empty(): _set_paint_mat(pbr_names[0])
	# zones by what they do to the place, each group under its own small heading; any zone not listed lands in OTHER
	var zn := _section(side, "ZONES")
	var zone_groups := [
		["Ceiling & height", ["tall", "grand", "low", "crawl", "open_ceiling", "endless_ceiling"]],
		["Light", ["bright", "dark", "dim", "flicker"]],
		["Look & surface", ["classic", "liminal", "tiles", "grime"]],
		["Pits & falls", ["abyss", "noclip", "noclip_floor"]],
		["Space & sound", ["hall_reverb", "muffled", "echo", "loop"]],
		["Gameplay", ["safe", "drain", "loot", "mannequin"]],
	]
	var placed := {}
	for gr in zone_groups:
		for z in gr[1]: placed[z] = true
	var rest: Array = ZONES.keys().filter(func(z): return not placed.has(z))
	if not rest.is_empty(): zone_groups.append(["Other", rest])
	for gr in zone_groups:
		var names: Array = (gr[1] as Array).filter(func(z): return ZONES.has(z))
		if names.is_empty(): continue
		zn.add_child(_heading(str(gr[0])))
		var zgrid := GridContainer.new()
		zgrid.columns = 2
		zn.add_child(zgrid)
		for z in names:
			var zb := _tool_button("zone:" + z, ZONE_NAMES.get(z, str(z).capitalize()), ZONES[z], ZONE_HELP.get(z, ""))
			zb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			zgrid.add_child(zb)
		if gr[0] == "Space & sound":
			var ac := _action_button("Auto acoustics", "acoustics", ZONES["hall_reverb"], _auto_acoustics,
				"Paint this floor's Hall reverb and Muffled zones from its architecture: how far sound runs before a wall\n(curved walls and columns too), how high the ceiling is, and how hard the walls, the floor and any water are.\nThe game works every place out this way anyway; painting it lets you see it and touch it up. One undo step")
			ac.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			zn.add_child(ac)
	# GENERATE
	_build_generate(side)
	_refresh_layers_panel()
	return right

## A grid of tool tiles (icon over its name), as wide as the panel lets it
func _tile_grid(parent: Control) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 4)
	g.add_theme_constant_override("v_separation", 4)
	parent.add_child(g)
	return g

## A tool tile: its icon over its name; picks tool `id`
func _tile(id: String, text: String, icon: Texture2D, tip: String) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.toggle_mode = true
	b.button_pressed = id == tool
	b.text = text
	b.icon = icon
	b.tooltip_text = text + "\n" + tip
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	b.expand_icon = false
	b.clip_text = true
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.custom_minimum_size = Vector2(78, 62)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 11)
	b.add_theme_constant_override("icon_max_width", 26)
	b.add_theme_stylebox_override("normal", _box(UI_PANEL2, UI_PANEL2, 5, 5))
	b.add_theme_stylebox_override("hover", _box(Color("33353b"), Color("4a4d55"), 5, 5))
	b.add_theme_stylebox_override("pressed", _box(Color("23395a"), ACCENT, 5, 5))
	b.add_theme_stylebox_override("hover_pressed", _box(Color("2b4a75"), ACCENT, 5, 5))
	b.pressed.connect(func(): _select_tool(id))
	_register_tool(id, b)
	return b

func _build_generate(side: VBoxContainer) -> void:
	var gen := _section(side, "GENERATE")
	gen.add_child(_note("Pick the Generate tool and drag an area (it can reach past the map, which grows). Rooms join whatever floor is next to the area. Regenerate rolls the last area again."))
	var gen_b := _tile("gen", "Generate area", Icons.icon("generate", Color("3fd1a0"), 24), "Drag a rectangle: it is filled with generated rooms / corridors")
	var gg := _tile_grid(gen)
	gg.add_child(gen_b)
	var ggrid := GridContainer.new()
	ggrid.columns = 2
	gen.add_child(ggrid)
	ggrid.add_child(_label("Style", 13, UI_DIM))
	var style_pick := OptionButton.new()
	var styles := [["classic", "Classic Level 0"], ["liminal", "Liminal halls"], ["mixed", "Mixed"], ["rooms", "Rooms"], ["maze", "Maze"], ["pillars", "Pillar hall"]]
	for st in styles: style_pick.add_item(st[1])
	style_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_pick.item_selected.connect(func(i): gen_style = styles[i][0])
	ggrid.add_child(style_pick)
	ggrid.add_child(_label("Seed", 13, UI_DIM))
	var srow2 := HBoxContainer.new()
	seed_spin = SpinBox.new()
	seed_spin.max_value = 99999
	seed_spin.value = gen_seed
	seed_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_spin.value_changed.connect(func(v): gen_seed = int(v))
	srow2.add_child(seed_spin)
	srow2.add_child(_icon_button("generate", "Random seed", func(): seed_spin.value = randi() % 100000))
	ggrid.add_child(srow2)
	for row in [["Room min", "gen_room_min", 3, 12, "Smallest room side, in cells"], ["Room max", "gen_room_max", 5, 30, "Rooms wider than this are always split"],
			["Corridor", "gen_corridor", 1, 3, "Maze corridor width, in cells"]]:
		ggrid.add_child(_label(row[0], 13, UI_DIM))
		var sp := SpinBox.new()
		sp.min_value = row[2]
		sp.max_value = row[3]
		sp.value = get(row[1])
		sp.tooltip_text = row[4]
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp.value_changed.connect(func(v): set(row[1], int(v)))
		ggrid.add_child(sp)
	ggrid.add_child(_label("Density", 13, UI_DIM))
	var dens := HSlider.new()
	dens.min_value = 0.0
	dens.max_value = 1.0
	dens.step = 0.05
	dens.value = gen_density
	dens.tooltip_text = "More doorways, loops and pillars; high values knock rooms together into halls"
	dens.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dens.value_changed.connect(func(v): gen_density = v)
	ggrid.add_child(dens)
	for cb_def in [["Doors in doorways", "gen_doors"], ["Random room zones", "gen_zones"]]:
		var cb := CheckBox.new()
		cb.text = cb_def[0]
		cb.button_pressed = get(cb_def[1])
		cb.toggled.connect(func(on): set(cb_def[1], on))
		gen.add_child(cb)
	var grow := HBoxContainer.new()
	gen.add_child(grow)
	var regen := _button("Regenerate", _regenerate)
	regen.tooltip_text = "Roll the last generated area again with a new seed"
	regen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grow.add_child(regen)
	var whole := _button("Whole floor", _generate_whole)
	whole.tooltip_text = "Generate over this entire floor (stairs are kept). Ctrl+Z takes it back"
	whole.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grow.add_child(whole)

# ---- status bar
func _build_statusbar() -> Control:
	var bot := PanelContainer.new()
	bot.add_theme_stylebox_override("panel", _box(UI_BG, UI_LINE, 0, 5, [0, 1, 0, 0]))
	var bb := HBoxContainer.new()
	bb.add_theme_constant_override("separation", 16)
	bot.add_child(bb)
	status = _label("", 13, UI_DIM)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.clip_text = true                   # a long message must never widen the window
	status.custom_minimum_size = Vector2(100, 0)
	bb.add_child(status)
	info = _label("", 13, UI_DIM)
	bb.add_child(info)
	return bot

# ---- the docks follow the map (a few times a second at most: rebuilding them on every drag step would crawl)
func _refresh_layers() -> void:
	_dock_dirty = true

func _dock_tick() -> void:
	if not _dock_dirty: return
	_dock_dirty = false
	_refresh_layers_panel()
	_refresh_outliner()

## The Layers tab: the level's storeys (the floor picker's), and the heights within this one that its raised
## floors make, each shown or hidden, one of them where new pieces go
func _refresh_layers_panel() -> void:
	if layers_box == null: return
	for c in layers_box.get_children(): c.queue_free()
	layers_box.add_child(_heading("Storeys"))
	var fs := _floor_numbers()
	fs.reverse()
	for f: int in fs:
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.button_pressed = f == floor_idx
		b.text = _floor_name(f)
		b.icon = Icons.icon("layers", ACCENT if f == floor_idx else UI_DIM, 16)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = "Edit %s (PageUp / PageDown step floors). Floors stand 9 m apart" % _floor_name(f)
		b.pressed.connect(func(): _switch_floor(f))
		layers_box.add_child(b)
	var fr := GridContainer.new()
	fr.columns = 2
	layers_box.add_child(fr)
	for a: Array in [["Floor above", "floor_up", func(): _add_floor(1)], ["Basement", "floor_down", func(): _add_floor(-1)],
			["Delete floor", "trash", _delete_floor], ["Repeat down", "repeat", _repeat_down]]:
		var ab := _action_button(a[0], a[1], UI_TEXT, a[2], a[0])
		ab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fr.add_child(ab)
	layers_box.add_child(HSeparator.new())
	layers_box.add_child(_heading("Heights on this floor"))
	for row: Array in _layers():
		var e: float = row[0]
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 4)
		layers_box.add_child(h)
		var eye := _icon_toggle("eye", "Show or hide what stands at this height (hidden: drawn faint, can't be picked)")
		eye.button_pressed = not hidden_elevs.has(e)
		eye.icon = Icons.icon("eye" if eye.button_pressed else "eye_off", UI_TEXT, 18)
		eye.toggled.connect(func(on):
			if on: hidden_elevs.erase(e)
			else: hidden_elevs[e] = true
			_dock_dirty = true
			canvas.queue_redraw())
		h.add_child(eye)
		var pick := Button.new()
		pick.focus_mode = Control.FOCUS_NONE
		pick.toggle_mode = true
		pick.button_pressed = is_equal_approx(e, snappedf(active_elev, 0.1))
		pick.alignment = HORIZONTAL_ALIGNMENT_LEFT
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pick.text = ("Ground" if e <= 0.0 else "Raised") + "  %.1f m   %d piece%s" % [e, int(row[1]), "" if int(row[1]) == 1 else "s"]
		pick.tooltip_text = "Make this the active height: new stairs and props are put on it"
		pick.pressed.connect(func():
			active_elev = e
			_dock_dirty = true
			_status("New pieces now stand at %.1f m" % e))
		h.add_child(pick)
	layers_box.add_child(_note("A raised floor makes a height of its own. New stairs and props stand on the active height; a hidden height's pieces are drawn faint and can't be picked, so you can work under a balcony."))

## The Outliner tab: every object on this floor, by type, the filter's matches only
func _refresh_outliner() -> void:
	if outliner == null: return
	outliner.clear()
	_outliner_rows.clear()
	var q := outliner_filter.text.strip_edges().to_lower() if outliner_filter != null else ""
	for i in objects.size():
		var o: Dictionary = objects[i]
		var name := str(_info(o.type).label)
		if q != "" and not name.to_lower().contains(q) and not str(o.type).contains(q): continue
		var hidden := _layer_hidden(o)
		outliner.add_item("%s    %.1f, %.1f%s" % [name, float(o.pos_x), float(o.pos_y), "   (hidden)" if hidden else ""], _obj_icon(str(o.type), _info(o.type).col))
		outliner.set_item_tooltip(outliner.item_count - 1, _describe(o))
		if hidden: outliner.set_item_custom_fg_color(outliner.item_count - 1, UI_DIM)
		_outliner_rows.append(i)
		if i == selected: outliner.select(outliner.item_count - 1)

## Select object `i` and bring it into view
func _focus_object(i: int) -> void:
	if i < 0 or i >= objects.size(): return
	if not _object_tool(): _select_tool("select")
	_select(i)
	var o: Dictionary = objects[i]
	pan = canvas.size * 0.5 - (Vector2(o.pos_x, o.pos_y) + Vector2(0.5, 0.5)) * zoom
	_invalidate_map_cache()
	_status(_describe(o))
	canvas.queue_redraw()

## The inspector's heading follows the selection, and the outliner its row
func _sync_inspector() -> void:
	super()
	if insp_head == null or selected < 0 or selected >= objects.size(): return
	var o: Dictionary = objects[selected]
	insp_head.text = str(_info(o.type).label)
	insp_icon.texture = _obj_icon(str(o.type), _info(o.type).col)
	if outliner != null:
		var row := _outliner_rows.find(selected)
		if row >= 0 and (outliner.get_selected_items().is_empty() or outliner.get_selected_items()[0] != row): outliner.select(row)

func _show_help() -> void:
	var d := AcceptDialog.new()
	d.title = "Keyboard and mouse"
	var l := _label(HELP_TEXT, 13, UI_TEXT)
	d.add_child(l)
	add_child(d)
	d.popup_centered()
	d.confirmed.connect(d.queue_free)
	d.canceled.connect(d.queue_free)

const HELP_TEXT := """MAP
  Left drag paint          Right drag erase          Middle drag / Space+drag pan          Wheel zoom          F fit
  B brush   M rectangle   K fill   (Shift: rectangle, Ctrl: fill, in any mode)          [ ] brush size
  1 wall   2 floor   3 pit          C floor / ceiling view          PageUp / PageDown floors          F4 3D view

OBJECTS
  V select / move     S select area     Click places, keep the button down and drag to aim it, right click deletes
  Drag the round knob to turn it, the squares to size it          R / Shift+R turn 90°          arrows nudge
  Shift+wheel sizes, Alt+wheel turns          G snap to grid   A align to walls   (Alt ignores both)
  Ctrl+A every object   Ctrl+C / X / V copy, cut, paste   Del delete   Esc lets go of anything

SPLINE WALLS AND POOLS
  Click each point, Enter / double click / right click to finish (a pool closes itself)   Backspace takes a point back
  Selected: drag a square to move that point, Shift+click an edge to add a point, Ctrl+click a point to remove it

FILES
  Ctrl+S save   Ctrl+N new   Ctrl+D duplicate   F5 test   F6 test here (noclip)   Ctrl+Z / Ctrl+Y undo / redo
  Ctrl + / Ctrl - / Ctrl 0  interface size"""
func _build_dialogs() -> void:
	_build_trigger_dialog()
	_build_noclip_dialog()
	name_dialog = ConfirmationDialog.new()
	name_dialog.confirmed.connect(_on_name_confirmed)
	var v := VBoxContainer.new()
	name_edit = LineEdit.new()
	name_edit.custom_minimum_size = Vector2(380, 0)
	name_edit.text_changed.connect(func(_t): _update_name_hint())
	name_edit.text_submitted.connect(func(_t): name_dialog.hide(); _on_name_confirmed())
	v.add_child(_label("NAME", 14, DIM))
	v.add_child(name_edit)
	name_hint = _label("", 13, DIM)
	v.add_child(name_hint)
	name_dialog.add_child(v)
	add_child(name_dialog)
	delete_dialog = ConfirmationDialog.new()
	delete_dialog.confirmed.connect(_delete_current)
	add_child(delete_dialog)
	godot_dialog = FileDialog.new()
	godot_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	godot_dialog.access = FileDialog.ACCESS_FILESYSTEM
	godot_dialog.use_native_dialog = true
	godot_dialog.title = "Locate the Godot executable"
	godot_dialog.file_selected.connect(func(p): _save_godot_path(p); _test_level())
	add_child(godot_dialog)

## The Noclip zone's "where do they wake up?" question: a level from levels.json, kept on this floor
func _build_noclip_dialog() -> void:
	noclip_dialog = ConfirmationDialog.new()
	noclip_dialog.title = "Noclip: where do they wake up?"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.add_child(_label("A player who falls into this floor's Noclip pits comes to, lying on the floor, at the spawn point of:", 13, DIM))
	noclip_pick = OptionButton.new()
	noclip_pick.custom_minimum_size = Vector2(380, 0)
	v.add_child(noclip_pick)
	v.add_child(_label("Paint the Noclip zone where the floor should open. One destination per floor; pick this tool again to change it.", 12, DIM))
	noclip_dialog.add_child(v)
	noclip_dialog.confirmed.connect(func():
		var i := noclip_pick.selected
		if i < 0 or i >= index.size(): return
		noclip_to = str(index[i].get("id", ""))
		_mark_dirty()
		_status("Noclip on this floor leads to: %s" % str(index[i].get("name", noclip_to))))
	add_child(noclip_dialog)

func _open_noclip_dialog() -> void:
	noclip_pick.clear()
	var sel := 0
	for i in index.size():
		var e: Dictionary = index[i]
		noclip_pick.add_item("%s   (%s)" % [str(e.get("name", e.get("id", "?"))), str(e.get("file", ""))])
		if str(e.get("id", "")) == noclip_to:
			sel = i
		elif noclip_to == "" and i == (current + 1) % maxi(index.size(), 1):
			sel = i                                 # (by default: the next level along)
	if index.size() > 0:
		noclip_pick.select(sel)
	noclip_dialog.popup_centered(Vector2(520, 180))

func _build_trigger_dialog() -> void:
	trigger_dialog = ConfirmationDialog.new()
	trigger_dialog.title = "Configure Event Trigger"
	trigger_dialog.confirmed.connect(_on_trigger_dialog_confirmed)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(460, 420)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 10)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var ev_section := VBoxContainer.new()
	ev_section.add_theme_constant_override("separation", 6)
	ev_section.add_child(_label("EVENT TYPE(S)", 14, GOLD))

	td_events_container = VBoxContainer.new()
	td_events_container.add_theme_constant_override("separation", 8)
	ev_section.add_child(td_events_container)

	var add_ev_btn := _button("+ ADD ANOTHER EVENT", func():
		_add_td_event_row("message", "")
	)
	add_ev_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	ev_section.add_child(add_ev_btn)

	tv.add_child(ev_section)
	tv.add_child(HSeparator.new())

	var opt_grid := GridContainer.new()
	opt_grid.columns = 2
	opt_grid.add_theme_constant_override("h_separation", 12)
	opt_grid.add_theme_constant_override("v_separation", 6)

	opt_grid.add_child(_label("Screen Text:", 13, DIM))
	td_text = LineEdit.new()
	td_text.placeholder_text = "Caption displayed on screen (optional)"
	td_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_grid.add_child(td_text)

	opt_grid.add_child(_label("Width (cells):", 13, DIM))
	td_width = SpinBox.new()
	td_width.min_value = 0.5
	td_width.max_value = 40.0
	td_width.step = 0.5
	td_width.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_grid.add_child(td_width)

	opt_grid.add_child(_label("Depth (cells):", 13, DIM))
	td_depth = SpinBox.new()
	td_depth.min_value = 0.5
	td_depth.max_value = 40.0
	td_depth.step = 0.5
	td_depth.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_grid.add_child(td_depth)

	opt_grid.add_child(_label("Delay (seconds):", 13, DIM))
	td_delay = SpinBox.new()
	td_delay.min_value = 0.0
	td_delay.max_value = 60.0
	td_delay.step = 0.1
	td_delay.suffix = " s"
	td_delay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_grid.add_child(td_delay)

	opt_grid.add_child(_label("Duration (seconds):", 13, DIM))
	td_duration = SpinBox.new()
	td_duration.min_value = 1.0
	td_duration.max_value = 120.0
	td_duration.step = 1.0
	td_duration.suffix = " s"
	td_duration.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_grid.add_child(td_duration)

	tv.add_child(opt_grid)

	td_once = CheckBox.new()
	td_once.text = "Trigger only once (first time entered)"
	tv.add_child(td_once)

	scroll.add_child(tv)
	trigger_dialog.add_child(scroll)
	trigger_dialog.register_text_enter(td_text)       # Enter in the caption box = OK
	add_child(trigger_dialog)

func _add_td_event_row(ev_name: String = "flicker", custom_name: String = "") -> void:
	var row_box := VBoxContainer.new()
	row_box.add_theme_constant_override("separation", 3)

	var top_h := HBoxContainer.new()
	top_h.add_theme_constant_override("separation", 6)

	var num_lbl := _label("Event 1:", 13, GOLD)
	num_lbl.custom_minimum_size = Vector2(64, 0)
	top_h.add_child(num_lbl)

	var pick := OptionButton.new()
	var evs: Dictionary = OBJ_INFO.get("trigger", {}).get("events", {})
	for e in evs:
		pick.add_item(e)
		pick.set_item_tooltip(pick.item_count - 1, str(evs[e]))
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var ev_keys: Array = evs.keys()
	var sel_idx: int = ev_keys.find(ev_name)
	if sel_idx < 0:
		sel_idx = ev_keys.find("custom")
		if sel_idx < 0: sel_idx = 0
	pick.select(sel_idx)
	top_h.add_child(pick)

	var del_btn := Button.new()
	del_btn.text = "X"
	if font: del_btn.add_theme_font_override("font", font)
	del_btn.custom_minimum_size = Vector2(28, 0)
	del_btn.add_theme_color_override("font_color", RED)
	top_h.add_child(del_btn)
	row_box.add_child(top_h)

	var active_key: String = ev_keys[sel_idx] if sel_idx >= 0 and sel_idx < ev_keys.size() else ""
	var hint := _label(str(evs.get(active_key, "")), 12, DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row_box.add_child(hint)

	var c_row := HBoxContainer.new()
	c_row.add_child(_label("Custom Event: ", 13, CREAM))
	var c_edit := LineEdit.new()
	c_edit.placeholder_text = "e.g. secret_door_open"
	c_edit.text = custom_name
	c_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c_row.add_child(c_edit)
	c_row.visible = (active_key == "custom")
	row_box.add_child(c_row)

	pick.item_selected.connect(func(i):
		var ek: Array = evs.keys()
		if i >= 0 and i < ek.size():
			hint.text = str(evs[ek[i]])
			c_row.visible = (ek[i] == "custom")
	)

	var row_data := {
		"root": row_box,
		"header_lbl": num_lbl,
		"pick": pick,
		"hint": hint,
		"custom_row": c_row,
		"custom_edit": c_edit,
		"remove_btn": del_btn
	}

	del_btn.pressed.connect(func():
		_remove_td_event_row(row_data)
	)

	td_event_rows.append(row_data)
	td_events_container.add_child(row_box)
	_update_td_event_rows()

func _remove_td_event_row(row_data: Dictionary) -> void:
	if td_event_rows.size() <= 1: return
	var idx := td_event_rows.find(row_data)
	if idx >= 0:
		td_event_rows.remove_at(idx)
		row_data.root.queue_free()
		_update_td_event_rows()

func _update_td_event_rows() -> void:
	for i in td_event_rows.size():
		var r: Dictionary = td_event_rows[i]
		r.header_lbl.text = "Event %d:" % (i + 1)
		r.remove_btn.visible = td_event_rows.size() > 1

func _open_trigger_dialog(idx: int) -> void:
	if idx < 0 or idx >= objects.size(): return
	var o: Dictionary = objects[idx]
	if o.type != "trigger": return
	_select(idx)
	trigger_dialog_target_idx = idx

	for r in td_event_rows:
		r.root.queue_free()
	td_event_rows.clear()

	var raw_list = o.get("events_list", [])
	if raw_list is Array and not raw_list.is_empty():
		for item in raw_list:
			if item is Dictionary:
				_add_td_event_row(str(item.get("event", "lights_out")), str(item.get("custom_event", "")))
			elif item is String:
				_add_td_event_row(str(item), "")
	else:
		var current_ev: String = str(_param(o, "event", "lights_out"))
		var c_ev: String = str(_param(o, "custom_event", ""))
		_add_td_event_row(current_ev, c_ev)

	td_text.text = str(_param(o, "text", ""))
	td_once.button_pressed = bool(_param(o, "once", true))
	td_width.value = float(o.get("scale", 2.0))
	td_depth.value = float(_param(o, "depth", 2.0))
	td_delay.value = float(_param(o, "delay", 0.0))
	td_duration.value = float(_param(o, "duration", 10.0))

	trigger_dialog.popup_centered(Vector2(500, 520))

func _on_trigger_dialog_confirmed() -> void:
	if trigger_dialog_target_idx < 0 or trigger_dialog_target_idx >= objects.size(): return
	var o: Dictionary = objects[trigger_dialog_target_idx]
	if o.type != "trigger": return
	_push_undo()

	var evs: Dictionary = OBJ_INFO.get("trigger", {}).get("events", {})
	var ev_keys: Array = evs.keys()

	var new_list: Array = []
	for r in td_event_rows:
		var sel_idx: int = r.pick.selected
		var ev_key: String = ev_keys[sel_idx] if sel_idx >= 0 and sel_idx < ev_keys.size() else "message"
		var c_name: String = r.custom_edit.text.strip_edges()
		new_list.append({"event": ev_key, "custom_event": c_name})

	if new_list.is_empty():
		new_list.append({"event": "message", "custom_event": ""})

	o["events_list"] = new_list
	o["event"] = new_list[0]["event"]
	o["custom_event"] = new_list[0]["custom_event"]
	o["text"] = td_text.text
	o["once"] = td_once.button_pressed
	o["scale"] = td_width.value
	o["depth"] = td_depth.value
	o["delay"] = td_delay.value
	o["duration"] = td_duration.value
	place_scales["trigger"] = o["scale"]
	_sync_inspector()
	_mark_dirty()
	canvas.queue_redraw()

## The selected object's properties, at the top of the tool panel (hidden when nothing is selected)
func _build_inspector(side: VBoxContainer) -> void:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _box(UI_PANEL2, UI_LINE, 6, 10))
	side.add_child(box)
	insp = VBoxContainer.new()
	box.add_child(insp)
	var head := HBoxContainer.new()
	insp.add_child(head)
	insp_icon = TextureRect.new()
	insp_icon.custom_minimum_size = Vector2(26, 26)
	insp_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	insp_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(insp_icon)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 0)
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(hv)
	hv.add_child(_heading("Selected object"))
	insp_head = _label("", 15, Color.WHITE)
	hv.add_child(insp_head)
	insp_trigger_btn = _button("Configure event options...", func():
		if selected >= 0 and selected < objects.size() and objects[selected].type == "trigger":
			_open_trigger_dialog(selected)
	)
	insp_trigger_btn.visible = false
	insp.add_child(insp_trigger_btn)
	var grid_box := GridContainer.new()
	grid_box.columns = 2
	grid_box.add_theme_constant_override("h_separation", 10)
	insp.add_child(grid_box)
	grid_box.add_child(_label("Type", 13, UI_DIM))
	insp_type = OptionButton.new()
	for t in OBJ_TYPES: insp_type.add_item(OBJ_INFO[t].label)
	insp_type.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	insp_type.item_selected.connect(func(i): _set_prop("type", OBJ_TYPES[i]))
	grid_box.add_child(insp_type)
	insp_x = _insp_spin(grid_box, "X", 0.0, 256.0, 0.05, "pos_x", "cells, a cell's centre is a whole number")
	insp_y = _insp_spin(grid_box, "Y", 0.0, 256.0, 0.05, "pos_y", "cells, a cell's centre is a whole number")
	insp_rot = _insp_spin(grid_box, "Rotation", -360.0, 720.0, 0.5, "rotation", "degrees clockwise; the arrow shows which way it faces")
	insp_rot.suffix = "°"
	insp_scale = _insp_spin(grid_box, "Width", 0.5, 4.0, 0.05, "scale", "span in cells")
	insp_scale_label = grid_box.get_child(grid_box.get_child_count() - 2)
	# per-type fields (object_types.json "params"): only the selected type's are shown
	_insp_param_spin(grid_box, "thick", "Thickness", 0.05, 4.5, 0.05, " m", "wall thickness (a pillar or column: its width)")
	_insp_param_spin(grid_box, "height", "Height", 0.0, 16.2, 0.05, " m", "0 = up to the ceiling. Under 1.8 m you see over it (a half wall, a counter). A window: its glass's height")
	_insp_param_spin(grid_box, "arc", "Arc", 5.0, 360.0, 5.0, "°", "how much of the circle is built: 90 rounds a corner, 360 closes a round room")
	_insp_param_spin(grid_box, "depth", "Depth", 0.25, 60.0, 0.25, "", "cells along the arrow")
	_insp_param_spin(grid_box, "elev", "Off floor", 0.0, 16.2, 0.05, " m", "how high it stands: a prop's lowest point, a stair's foot, a raised floor's top, a window's sill.\nIn the 3D view (F4): Ctrl+wheel, or drag a wall prop up and down its wall")
	var ev_lbl := _label("Event", 13, UI_DIM)
	grid_box.add_child(ev_lbl)
	var ev_pick := OptionButton.new()
	var evs: Dictionary = OBJ_INFO.get("trigger", {}).get("events", {})
	for e in evs:
		ev_pick.add_item(e)
		ev_pick.set_item_tooltip(ev_pick.item_count - 1, str(evs[e]))
	ev_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ev_pick.item_selected.connect(func(i): _set_prop("event", evs.keys()[i]))
	grid_box.add_child(ev_pick)
	insp_params["event"] = {"row": [ev_lbl, ev_pick], "ctrl": ev_pick}
	var c_ev_lbl := _label("Custom event", 13, UI_DIM)
	grid_box.add_child(c_ev_lbl)
	var c_ev := LineEdit.new()
	c_ev.placeholder_text = "event_name"
	c_ev.tooltip_text = "Event identifier dispatched when player enters the trigger area"
	c_ev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c_ev.text_changed.connect(func(t): _set_prop("custom_event", t))
	c_ev.text_submitted.connect(func(_t): c_ev.release_focus())
	grid_box.add_child(c_ev)
	insp_params["custom_event"] = {"row": [c_ev_lbl, c_ev], "ctrl": c_ev}
	var tx_lbl := _label("Text", 13, UI_DIM)
	grid_box.add_child(tx_lbl)
	var tx := LineEdit.new()
	tx.placeholder_text = "a caption (optional)"
	tx.tooltip_text = "Shown low on the screen when it fires, whatever the event"
	tx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tx.text_changed.connect(func(t): _set_prop("text", t))
	tx.text_submitted.connect(func(_t): tx.release_focus())
	grid_box.add_child(tx)
	insp_params["text"] = {"row": [tx_lbl, tx], "ctrl": tx}
	var once_lbl := _label("Once", 13, UI_DIM)
	grid_box.add_child(once_lbl)
	var once := CheckBox.new()
	once.text = "only the first time"
	once.tooltip_text = "Off: fires every time the player walks back in (at most every 5 s)"
	once.toggled.connect(func(on): _set_prop("once", on))
	grid_box.add_child(once)
	insp_params["once"] = {"row": [once_lbl, once], "ctrl": once}
	_insp_param_spin(grid_box, "delay", "Delay", 0.0, 60.0, 0.1, " s", "seconds from walking in to the event")
	_insp_param_spin(grid_box, "duration", "Duration", 1.0, 120.0, 1.0, " s", "how long lights_out / silence / drone last")
	# any other type's params: a drop-down for one with "choices", a tick box for a yes / no, a number box from
	# its type's "ranges" (object_types.json)
	for t in OBJ_TYPES:
		var params: Dictionary = OBJ_INFO[t].get("params", {})
		var choices: Dictionary = OBJ_INFO[t].get("choices", {})
		var ranges: Dictionary = OBJ_INFO[t].get("ranges", {})
		for k in params:
			if insp_params.has(k): continue
			var title := str(k).capitalize()
			if choices.has(k):
				var lbl := _label(title, 13, UI_DIM)
				grid_box.add_child(lbl)
				var pick := OptionButton.new()
				var names: Array = (choices[k] as Dictionary).keys()
				for n in names:
					pick.add_item(str(n).capitalize())
					pick.set_item_tooltip(pick.item_count - 1, str(choices[k][n]))
				pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				pick.item_selected.connect(func(i): _set_prop(k, names[i]))
				grid_box.add_child(pick)
				insp_params[k] = {"row": [lbl, pick], "ctrl": pick, "choices": names}
			elif params[k] is bool:
				var lbl := _label(title, 13, UI_DIM)
				grid_box.add_child(lbl)
				var tick := CheckBox.new()
				tick.toggled.connect(func(on): _set_prop(k, on))
				grid_box.add_child(tick)
				insp_params[k] = {"row": [lbl, tick], "ctrl": tick}
			elif params[k] is float or params[k] is int:
				var r: Array = ranges.get(k, [0.0, 100.0, 0.05, "", ""])
				_insp_param_spin(grid_box, k, title, float(r[0]), float(r[1]), float(r[2]), str(r[3]), str(r[4]))
	var r := HBoxContainer.new()
	insp.add_child(r)
	for b: Array in [["rotate", "Turn 90° anticlockwise  (Shift+R)", func(): _rotate_selected(-90.0)], ["rotate", "Turn 90° clockwise  (R)", func(): _rotate_selected(90.0)],
			["copy", "Duplicate", _duplicate_selected], ["trash", "Delete  (Del)", _delete_selected]]:
		var bt := _icon_button(b[0], b[1], b[2])
		bt.flat = false
		bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(bt)
	box.visible = false

## One per-type param row of the inspector (see _build_inspector), kept in insp_params to show / hide
func _insp_param_spin(parent: Control, key: String, text: String, lo: float, hi: float, step: float, suffix: String, tip: String) -> void:
	var sb := _insp_spin(parent, text, lo, hi, step, key, tip)
	sb.suffix = suffix
	insp_params[key] = {"row": [parent.get_child(parent.get_child_count() - 2), sb], "ctrl": sb}

func _insp_spin(parent: Control, text: String, lo: float, hi: float, step: float, key: String, tip: String) -> SpinBox:
	parent.add_child(_label(text, 13, UI_DIM))
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = step
	sb.tooltip_text = tip
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.value_changed.connect(func(v): _set_prop(key, v))
	parent.add_child(sb)
	return sb

## A foldable block of the tool panel: click its heading to open or close it
func _section(side: VBoxContainer, title: String, open := true) -> VBoxContainer:
	var head := Button.new()
	head.flat = true
	head.focus_mode = Control.FOCUS_NONE
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_font_size_override("font_size", 12)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		head.add_theme_color_override(c, UI_TEXT)
	head.add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 4))
	head.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.04), Color(0, 0, 0, 0), 4, 4))
	head.add_theme_stylebox_override("pressed", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 4))
	var body := VBoxContainer.new()
	body.visible = open
	body.add_theme_constant_override("separation", 5)
	var sep := HSeparator.new()
	side.add_child(sep)
	side.add_child(head)
	side.add_child(body)
	tab_parts.get_or_add(TAB_OF.get(title, "build"), []).append_array([sep, head, body])
	var relabel := func(): head.text = ("▾  " if body.visible else "▸  ") + title
	relabel.call()
	head.pressed.connect(func():
		body.visible = not body.visible
		body.set_meta("open", body.visible)
		relabel.call())
	body.set_meta("open", open)
	return body

func _note(text: String) -> Label:
	var l := _label(text, 12, UI_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(180, 0)
	return l

func _small_toggle(text: String, tip: String, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = true
	b.button_group = group
	b.add_theme_font_size_override("font_size", 13)
	return b

func _set_mode(m: String) -> void:
	mode = m
	if mode_buttons.has(m): mode_buttons[m].button_pressed = true
	_status({"brush": "Brush: drag to paint", "rect": "Rectangle: drag a box", "fill": "Fill: click fills the connected area"}[m])
	canvas.queue_redraw()

func _floors_changed() -> void:
	if floor_pick == null: return
	floor_pick.clear()
	var fs := _floor_numbers()
	fs.reverse()                               # top floor first, like a building's directory
	for f in fs:
		floor_pick.add_item(_floor_name(f), f + 1000)
		if f == floor_idx: floor_pick.select(floor_pick.item_count - 1)
	_dock_dirty = true

func _gen_ui_sync() -> void:
	if seed_spin: seed_spin.set_value_no_signal(gen_seed)

func _set_view(ceiling: bool) -> void:
	view_ceiling = ceiling
	if view_buttons.size() == 2: view_buttons[1 if ceiling else 0].button_pressed = true
	_invalidate_map_cache()
	canvas.queue_redraw()

func _set_paint_mat(id: String) -> void:
	paint_mat = id
	paint_mix.erase(id)
	for n in swatch_buttons: swatch_buttons[n].button_pressed = n == id or paint_mix.has(n)
	if paint_name:
		paint_name.text = "Brush: " + " + ".join([id] + paint_mix) + ("   (%d%% of cells)" % scatter if scatter < 100 else "")
	canvas.queue_redraw()

func _toggle_3d() -> void:
	if preview3d.visible: preview3d.visible = false
	else: preview3d.open()

## The window lost focus (another program, the test game, a dialog) with a button or Space down: its release
## will not arrive here, so whatever it was doing on the map ends now
func _notification(what: int) -> void:
	if (what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT) and canvas != null:
		panning = false
		_let_go()

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE     # worked with the mouse: a button that kept the focus would take Space and Enter
	b.text = text
	b.pressed.connect(cb)
	return b

## A row button for a tool (zones, paint surfaces): a rounded swatch of its colour, its name
func _tool_button(id: String, text: String, col: Color, tip: String) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 30)
	b.add_theme_constant_override("h_separation", 8)
	b.add_theme_font_size_override("font_size", 13)
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = true
	b.button_pressed = id == tool
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	var img := Image.create(28, 28, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 28:
		for x in 28:
			var d := Vector2(maxf(absf(x - 13.5) - 8.0, 0.0), maxf(absf(y - 13.5) - 8.0, 0.0)).length()
			if d < 4.5: img.set_pixel(x, y, col if d < 3.2 else Color(0, 0, 0, 0.7))
	b.icon = ImageTexture.create_from_image(img)
	b.add_theme_constant_override("icon_max_width", 14)
	b.pressed.connect(func(): _select_tool(id))
	_register_tool(id, b)
	return b

## Every button that picks a tool, by tool: the tool bar's, the palette's, the search's (one tool can have several)
var tool_extra := {}                 # tool -> its buttons beyond tool_buttons[tool]

func _register_tool(id: String, b: Button) -> void:
	if tool_buttons.has(id) and is_instance_valid(tool_buttons[id]): tool_extra.get_or_add(id, []).append(b)
	else: tool_buttons[id] = b

func _select_tool(id: String) -> void:
	_let_go()
	tool = id
	if id == "paint:ceiling": _set_view(true)
	elif id.begins_with("paint:") or id.begins_with("base:"): _set_view(false)
	rect_from = Vector2i(-1, -1)
	edge_cut = false
	if id == "area": _area_status()
	else: area = Rect2i()
	if id == "zone:noclip" or id == "zone:noclip_floor": _open_noclip_dialog()
	canvas.queue_redraw()
	for k in tool_buttons:
		if is_instance_valid(tool_buttons[k]): tool_buttons[k].set_pressed_no_signal(k == id)
	for k in tool_extra:
		for b: Button in tool_extra[k]:
			if is_instance_valid(b): b.set_pressed_no_signal(k == id)

func _set_brush(n: int) -> void:
	brush = clampi(n, 1, 8)
	brush_label.text = "%d" % brush

func _on_list_pick(row: int) -> void:
	var i: int = shown[row]
	if i == current: return
	if dirty: save()
	_open(i)

func _save_godot_path(p: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("godot", "path", p)
	cfg.save(CFG)

func _input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null: return
	var focus := get_viewport().gui_get_focus_owner()
	var typing := focus is LineEdit or focus is TextEdit or name_dialog.visible or trigger_dialog.visible or noclip_dialog.visible or delete_dialog.visible or godot_dialog.visible
	if k.keycode == KEY_SPACE:
		# Space is the pan key (Space + drag, level_editor_canvas.gd _space_held). It must not also press
		# whichever button was clicked last, which is what Space does to a button with the keyboard focus.
		if not typing: get_viewport().set_input_as_handled()
		return
	if k.keycode in [KEY_CTRL, KEY_SHIFT]:     # they change what a click does: show it
		canvas.queue_redraw()
	# typing in a dialog (a level name, a trigger's caption) must not fire the canvas shortcuts (R, Backspace...)
	if not k.pressed or typing: return
	if k.keycode == KEY_SLASH and not k.ctrl_pressed and search_box != null:
		search_box.grab_focus()
		get_viewport().set_input_as_handled()
		return
	if k.ctrl_pressed:
		match k.keycode:
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD: _step_ui_scale(0.1)
			KEY_MINUS, KEY_KP_SUBTRACT: _step_ui_scale(-0.1)
			KEY_0: _step_ui_scale(0.0)
			KEY_S: save()
			KEY_Z: _redo() if k.shift_pressed else _undo()
			KEY_Y: _redo()
			KEY_N: _ask_new()
			KEY_D: _ask_dup()
			KEY_C: _copy()
			KEY_X: _cut()
			KEY_V: _paste(k.shift_pressed)
			KEY_A:
				if tool == "area": _area_all()
				else:
					_select_tool("select")
					_select_all_objects()
		get_viewport().set_input_as_handled()     # (the menus show these too: they must not fire them again)
		return
	if k.keycode == KEY_F5:
		_test_level()
		get_viewport().set_input_as_handled()
		return
	if k.keycode == KEY_F6:
		_test_level(true)
		get_viewport().set_input_as_handled()
		return
	if k.keycode == KEY_F4:
		_toggle_3d()
		get_viewport().set_input_as_handled()
		return
	if preview3d.visible:                # the 3D view owns the letter keys (WASD, C)
		return
	if drag == "spline":                 # drawing a spline wall or a pool: Enter ends it, Backspace takes a point back
		if k.keycode in [KEY_ENTER, KEY_KP_ENTER]:
			_end_spline()
			get_viewport().set_input_as_handled()
			return
		if k.keycode == KEY_BACKSPACE:
			_spline_back()
			get_viewport().set_input_as_handled()
			return
	for t in OBJ_TYPES:                  # each object type's key, from object_types.json
		if str(OBJ_INFO[t].get("key", "")) == OS.get_keycode_string(k.keycode):
			_select_tool("obj:" + t)
			return
	match k.keycode:
		KEY_1: _select_tool("base:" + WALL)
		KEY_2: _select_tool("base:" + FLOOR)
		KEY_3: _select_tool("base:" + PIT)
		KEY_V: _select_tool("select")
		KEY_S: _select_tool("area")
		KEY_R: _rotate_selected(-90.0 if k.shift_pressed else 90.0)
		KEY_G: snap_check.button_pressed = not snap_check.button_pressed
		KEY_A: align_check.button_pressed = not align_check.button_pressed
		KEY_DELETE, KEY_BACKSPACE:
			if tool == "area": _area_clear(WALL if k.shift_pressed else "")
			else: _delete_selected()
		KEY_ESCAPE:
			# the way out of anything: whatever is following the mouse stops, then the selection goes
			var busy := panning or painting or drag != "" or rect_from.x >= 0 or area_from.x >= 0
			_cancel_all()
			edge_cut = false
			if not busy:
				_select(-1)
				area = Rect2i()
				canvas.queue_redraw()
		KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN:
			if _object_tool() and not _group().is_empty():
				_nudge({KEY_LEFT: Vector2.LEFT, KEY_RIGHT: Vector2.RIGHT, KEY_UP: Vector2.UP, KEY_DOWN: Vector2.DOWN}[k.keycode], not k.echo)
				get_viewport().set_input_as_handled()      # not also a step of the keyboard focus
		KEY_BRACKETLEFT: _set_brush(brush - 1)
		KEY_BRACKETRIGHT: _set_brush(brush + 1)
		KEY_F: _fit()
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			_zoom_at(canvas.size * 0.5, 1.25, true)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom_at(canvas.size * 0.5, 1.0 / 1.25, true)
		KEY_PAGEUP: _step_floor(1)
		KEY_PAGEDOWN: _step_floor(-1)
		KEY_B: _set_mode("brush")
		KEY_M: _set_mode("rect")
		KEY_K: _set_mode("fill")
		KEY_C: _set_view(not view_ceiling)
		KEY_I: _eyedrop(hover)

# ---------------------------------------------------------------- UI scale
## The whole editor is drawn at this scale: by default it follows the screen (high-DPI and big monitors get a
## larger UI), Ctrl + / Ctrl - / Ctrl 0 change it and it is remembered in user://editor.cfg
const UI_CFG := "user://editor.cfg"
var ui_scale := 1.0
var split_left: HSplitContainer                  # levels | the rest
var split_right: HSplitContainer                 # map | tools

## The panel widths from last time (drag a divider to change them; double-click it for the default)
func _restore_splits() -> void:
	var cf := ConfigFile.new()
	cf.load(UI_CFG)
	split_left.split_offset = int(cf.get_value("ui", "left_w", 290))
	split_right.split_offset = int(cf.get_value("ui", "right_w", -40))
	for sp: HSplitContainer in [split_left, split_right]:
		sp.add_theme_constant_override("separation", 8)
		sp.add_theme_icon_override("grabber", _grip_icon())
		sp.drag_ended.connect(_save_splits)
		sp.gui_input.connect(func(e):
			if e is InputEventMouseButton and e.double_click:
				split_left.split_offset = 270 if sp == split_left else split_left.split_offset
				if sp == split_right: split_right.split_offset = -40
				_save_splits())

func _save_splits() -> void:
	var cf := ConfigFile.new()
	cf.load(UI_CFG)
	cf.set_value("ui", "left_w", split_left.split_offset)
	cf.set_value("ui", "right_w", split_right.split_offset)
	cf.save(UI_CFG)

## Three dots on the divider, so it reads as something to drag
func _grip_icon() -> ImageTexture:
	var img := Image.create(6, 26, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in [4, 11, 18]: img.fill_rect(Rect2i(1, y, 4, 4), GOLD)
	return ImageTexture.create_from_image(img)

func _load_ui_scale() -> float:
	var cf := ConfigFile.new()
	if cf.load(UI_CFG) == OK and cf.has_section_key("ui", "scale2"):
		return float(cf.get_value("ui", "scale2"))
	return _auto_ui_scale()

func _auto_ui_scale() -> float:
	# Retina / hi-DPI screens report a scale (2 on a Mac); a tall screen gets a little more on top
	var scr := DisplayServer.window_get_current_screen()
	var dpi := DisplayServer.screen_get_scale(scr)
	# macOS already sizes windows in points (a Retina 2x is handled by the OS), so don't scale up again
	if OS.get_name() == "macOS":
		return 1.0
	var tall := DisplayServer.screen_get_size(scr).y / dpi / 1000.0
	return clampf(snappedf(dpi * 0.75 * maxf(1.0, tall), 0.05), 1.0, 2.5)

func _apply_ui_scale(v: float) -> void:
	ui_scale = clampf(v, 0.75, 2.5)
	get_window().content_scale_factor = ui_scale

func _step_ui_scale(d: float) -> void:
	_apply_ui_scale(_auto_ui_scale() if d == 0.0 else ui_scale + d)
	var cf := ConfigFile.new()
	cf.load(UI_CFG)
	cf.set_value("ui", "scale2", ui_scale)
	cf.save(UI_CFG)
	_status("UI scale %d%%  (Ctrl + / Ctrl - / Ctrl 0 = fit the screen)" % roundi(ui_scale * 100.0))

# ---------------------------------------------------------------- object icons
## An object type's icon, in its colour (editor_icons.gd, by its shape)
func _obj_icon(t: String, col: Color) -> ImageTexture:
	if t == "_select": return Icons.icon("select", UI_TEXT, 22)
	return Icons.icon(Icons.for_type(t, OBJ_INFO.get(t, {})), col.lightened(0.2), 24)

# ---------------------------------------------------------------- tabs and tool search
## The tool panel is split into tabs (each section belongs to one) with a search box over them
const TABS := [["build", "Build", "wall"], ["paint", "Paint", "paint"], ["generate", "Generate", "generate"], ["props", "Props", "prop"]]
const TAB_OF := {"TERRAIN": "build", "SELECT AREA": "build", "WALLS": "build", "DOORS & STAIRS": "build", "LEVELS & STAIRS": "build",
	"WINDOWS & LIGHT": "build", "WATER & POOLS": "build", "EVENTS": "build", "MARKERS": "build",
	"PAINT MATERIALS": "paint", "ZONES": "paint", "GENERATE": "generate", "PROPS": "props"}
var tab_parts := {}                  # tab -> the section controls it shows
var tab_now := "build"
var tab_buttons := {}
var search_box: LineEdit
var search_results: VBoxContainer

func _build_tabs(side: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	side.add_child(row)
	var grp := ButtonGroup.new()
	for t: Array in TABS:
		var b := Button.new()
		b.text = t[1]
		b.icon = Icons.icon(t[2], UI_TEXT, 16)
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.button_group = grp
		b.button_pressed = t[0] == tab_now
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_constant_override("icon_max_width", 14)
		b.add_theme_stylebox_override("normal", _box(UI_BG, UI_BG, 0, 6, [0, 0, 0, 2]))
		b.add_theme_stylebox_override("hover", _box(UI_PANEL2, UI_PANEL2, 0, 6, [0, 0, 0, 2]))
		b.add_theme_stylebox_override("pressed", _box(UI_PANEL2, ACCENT, 0, 6, [0, 0, 0, 2]))
		b.add_theme_stylebox_override("hover_pressed", _box(UI_PANEL2, ACCENT, 0, 6, [0, 0, 0, 2]))
		b.pressed.connect(func(): _show_tab(t[0]))
		row.add_child(b)
		tab_buttons[t[0]] = b
	search_box = LineEdit.new()
	search_box.placeholder_text = "Search tools   ( / )"
	search_box.clear_button_enabled = true
	search_box.right_icon = Icons.icon("search", UI_DIM, 16)
	search_box.text_changed.connect(_search_tools)
	search_box.text_submitted.connect(func(_t):
		if search_results.get_child_count() > 0: (search_results.get_child(0) as Button).pressed.emit())
	side.add_child(search_box)
	search_results = VBoxContainer.new()
	side.add_child(search_results)
	_show_tab.call_deferred(tab_now)

func _show_tab(t: String) -> void:
	tab_now = t
	for k in tab_buttons: tab_buttons[k].set_pressed_no_signal(k == t)
	var searching := search_box != null and search_box.text.strip_edges() != ""
	for k in tab_parts:
		for n: Control in tab_parts[k]:
			if n is VBoxContainer: n.visible = (k == t and not searching) and n.get_meta("open", true)
			else: n.visible = k == t and not searching

## Every tool whose name matches, as buttons (Enter picks the first); an empty box brings the tabs back
func _search_tools(q: String) -> void:
	for c in search_results.get_children(): c.queue_free()
	q = q.strip_edges().to_lower()
	if q != "":
		for id in tool_buttons:
			var tb: Button = tool_buttons[id]
			if not is_instance_valid(tb): continue
			var name := tb.text if tb.text != "" else str(tb.tooltip_text).get_slice("\n", 0)
			if not name.to_lower().contains(q) and not str(id).to_lower().contains(q): continue
			var b := Button.new()
			b.text = name
			b.icon = tb.icon
			b.focus_mode = Control.FOCUS_NONE
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.custom_minimum_size = Vector2(0, 32)
			b.add_theme_constant_override("icon_max_width", 18)
			b.tooltip_text = tb.tooltip_text
			b.pressed.connect(func():
				_select_tool(id)
				for k in tab_parts:                  # bring up the tab the tool lives on
					for n in tab_parts[k]:
						if n is VBoxContainer and tb.get_parent() != null and n.is_ancestor_of(tb): tab_now = k
				search_box.text = ""
				_search_tools(""))
			search_results.add_child(b)
	_show_tab(tab_now)

