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

const BG := Color("0d0c08")
const PANEL := Color("16140d")
const LINE := Color("3a3522")
const ZONE_HELP := {"tall": "Huge atrium ceiling", "low": "Crouch-height ceiling", "crawl": "Crawl space: a very low ceiling (about 1.2 m). You have to get right down and crawl through it, hands on the floor, the torch a dim glow", "tiles": "Tile floor instead of carpet",
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
var snap_check: CheckBox
var rot_check: CheckBox
var align_check: CheckBox
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
func _box(bg: Color, border := LINE, radius := 0, margin := 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	return sb

func _make_theme() -> Theme:
	var t := Theme.new()
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = 1
	t.default_font = fv
	t.default_font_size = 17
	for c in ["Button", "OptionButton", "CheckBox"]:
		t.set_stylebox("normal", c, _box(Color("1d1a10"), LINE, 0, 6))
		t.set_stylebox("hover", c, _box(Color("2b2716"), GOLD, 0, 6))
		t.set_stylebox("pressed", c, _box(Color("3a3218"), GOLD, 0, 6))
		t.set_stylebox("focus", c, _box(Color(0, 0, 0, 0), GOLD, 0, 6))
		t.set_color("font_color", c, CREAM)
		t.set_color("font_hover_color", c, Color.WHITE)
		t.set_color("font_pressed_color", c, GOLD)
	t.set_stylebox("hover_pressed", "Button", _box(Color("3a3218"), GOLD, 0, 6))
	t.set_color("font_hover_pressed_color", "Button", GOLD)
	t.set_stylebox("normal", "LineEdit", _box(Color("0a0906"), LINE, 0, 6))
	t.set_stylebox("focus", "LineEdit", _box(Color("0a0906"), GOLD, 0, 6))
	t.set_color("font_color", "LineEdit", CREAM)
	t.set_color("font_placeholder_color", "LineEdit", Color(0.9, 0.88, 0.8, 0.3))
	t.set_color("font_color", "Label", CREAM)
	t.set_stylebox("panel", "PanelContainer", _box(PANEL, LINE, 0, 10))
	t.set_stylebox("panel", "PopupPanel", _box(PANEL, GOLD, 0, 12))
	t.set_stylebox("panel", "AcceptDialog", _box(PANEL, GOLD, 0, 12))
	t.set_stylebox("embedded_border", "Window", _box(PANEL, GOLD, 0, 12))
	t.set_stylebox("embedded_unfocused_border", "Window", _box(PANEL, LINE, 0, 12))
	t.set_color("title_color", "Window", GOLD)
	t.set_stylebox("panel", "ItemList", _box(Color("0a0906"), LINE, 0, 4))
	t.set_stylebox("selected", "ItemList", _box(Color("3a3218"), GOLD, 0, 4))
	t.set_stylebox("selected_focus", "ItemList", _box(Color("3a3218"), GOLD, 0, 4))
	t.set_stylebox("hovered", "ItemList", _box(Color("221f12"), LINE, 0, 4))
	t.set_color("font_color", "ItemList", DIM)
	t.set_color("font_selected_color", "ItemList", GOLD)
	t.set_color("font_hovered_color", "ItemList", CREAM)
	t.set_constant("v_separation", "ItemList", 4)
	t.set_constant("separation", "VBoxContainer", 6)
	return t

func _label(text: String, size := 16, color := CREAM) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _panel(min_w: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(min_w, 0)
	return p

# ---------------------------------------------------------------- UI
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

	# top bar
	var top := PanelContainer.new()
	top.add_theme_stylebox_override("panel", _box(Color("100e08"), LINE, 0, 10))
	root.add_child(top)
	var tb := HBoxContainer.new()
	tb.add_theme_constant_override("separation", 8)
	top.add_child(tb)
	tb.add_child(_label("LEVEL EDITOR", 18, GOLD))
	title_label = _label("", 18, CREAM)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.clip_text = true
	title_label.custom_minimum_size = Vector2(80, 0)
	tb.add_child(title_label)
	var test_b := _button("TEST  F5", _test_level)
	test_b.tooltip_text = "Save, then play this level in the game from the spawn marker (normal gameplay)"
	test_b.add_theme_color_override("font_color", Color("2fd968"))
	tb.add_child(test_b)
	var here_b := _button("TEST HERE  F6", func(): _test_level(true))
	here_b.tooltip_text = "Start on the cell under the mouse with noclip on (fly through walls)"
	here_b.add_theme_color_override("font_color", Color("2fd968"))
	tb.add_child(here_b)
	var view_b := _button("3D  F4", _toggle_3d)
	view_b.tooltip_text = "Switch the map to an orbitable 3D view of the level (right drag orbit, wheel zoom, C ceiling, E walk it).\nObjects can be placed there too: pick one in the tool panel and click where it goes (a wall prop: on the wall, at that height);\nwith Select / move, click an object and drag it. Props are shown as their real models"
	tb.add_child(view_b)
	tb.add_child(_button("UNDO", _undo))
	tb.add_child(_button("REDO", _redo))
	tb.add_child(_button("FIT", _fit))
	for b in tb.get_children():
		if b is Button: b.add_theme_font_size_override("font_size", 14)
	var save_b := _button("SAVE  Ctrl+S", save)
	save_b.add_theme_color_override("font_color", GOLD)
	tb.add_child(save_b)

	# levels | map | tools, with draggable dividers between them (widths remembered in user://editor.cfg)
	var body := HSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	var inner := HSplitContainer.new()
	split_left = body
	split_right = inner

	# left: level list
	var left := _panel(160)
	left.custom_minimum_size.x = 160
	body.add_child(left)
	body.add_child(inner)
	var lv := VBoxContainer.new()
	left.add_child(lv)
	lv.add_child(_label("LEVELS", 16, GOLD))
	search = LineEdit.new()
	search.placeholder_text = "search..."
	search.clear_button_enabled = true
	search.text_changed.connect(func(t): filter = t.to_lower(); _refresh_list())
	lv.add_child(search)
	level_list = ItemList.new()
	level_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	level_list.item_selected.connect(_on_list_pick)
	lv.add_child(level_list)
	var r1 := HBoxContainer.new()
	lv.add_child(r1)
	for b in [["NEW", _ask_new], ["COPY", _ask_dup], ["RENAME", _ask_rename]]:
		var bt := _button(b[0], b[1])
		bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r1.add_child(bt)
	var r2 := HBoxContainer.new()
	lv.add_child(r2)
	for b in [["UP", func(): _move(-1)], ["DOWN", func(): _move(1)], ["DELETE", _ask_delete]]:
		var bt := _button(b[0], b[1])
		bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r2.add_child(bt)
	var size_row := HBoxContainer.new()
	lv.add_child(size_row)
	size_row.add_child(_label("SIZE", 16, DIM))
	size_spin = SpinBox.new()
	size_spin.min_value = 8
	size_spin.max_value = MAX_SIZE
	size_spin.tooltip_text = "The map is square. It also grows by itself when you draw Floor, Pit or Generate past its edge"
	size_spin.value = grid_size
	size_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_row.add_child(size_spin)
	size_row.add_child(_button("RESIZE", func(): _resize(int(size_spin.value))))
	var trim_b := _button("TRIM", _trim)
	trim_b.tooltip_text = "Shrink the map (every floor) to the space in use, plus a wall border"
	size_row.add_child(trim_b)

	var gi_row := HBoxContainer.new()
	lv.add_child(gi_row)
	gi_row.add_child(_label("REAL-TIME GI", 16, DIM))
	gi_pick = OptionButton.new()
	gi_pick.add_item("auto")
	gi_pick.add_item("on")
	gi_pick.add_item("off")
	gi_pick.tooltip_text = "SDFGI bounce light. auto = only levels with a Classic zone. It is heavy on weak GPUs."
	gi_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gi_pick.item_selected.connect(func(_i): _mark_dirty())
	gi_row.add_child(gi_pick)

	var atmo_row := HBoxContainer.new()
	lv.add_child(atmo_row)
	atmo_row.add_child(_label("ATMOSPHERE", 16, DIM))
	atmo_pick = OptionButton.new()
	for a in ATMOS: atmo_pick.add_item(a)
	atmo_pick.tooltip_text = ATMO_HELP
	atmo_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	atmo_pick.item_selected.connect(func(_i): _mark_dirty())
	atmo_row.add_child(atmo_pick)

	endless_check = CheckBox.new()
	endless_check.text = "ENDLESS FLOORS"
	endless_check.tooltip_text = "The lowest floor repeats for ever below the level and the highest for ever above it.\nA pit shaft through the lowest floor then has no bottom: you look down into floor after floor until the haze takes them,\nand whoever falls in keeps falling, floor after floor. Stairs still end where the level's own floors do."
	endless_check.add_theme_font_size_override("font_size", 16)
	endless_check.toggled.connect(func(_on): _mark_dirty())
	lv.add_child(endless_check)

	wrap_check = CheckBox.new()
	wrap_check.text = "ENDLESS HALLS (WRAP)"
	wrap_check.tooltip_text = "The level never ends: walk off one edge and you are on the opposite side, seamlessly, and the halls are drawn\nrepeating past every edge out to the horizon. The border cells don't count: the map's opposite edges are joined,\nso leave openings on the edges (a hall running off the right edge comes back in on the left). Best with Classic halls.\nMonsters stay inside the map: crossing the edge is a way to lose one."
	wrap_check.add_theme_font_size_override("font_size", 16)
	wrap_check.toggled.connect(func(_on): _mark_dirty())
	lv.add_child(wrap_check)

	# center: canvas
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 0)
	inner.add_child(mid)
	# the bar over the map: how clicks paint, which surface is shown, which layers are drawn
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _box(Color("100e08"), LINE, 0, 5))
	mid.add_child(bar)
	var hb := HFlowContainer.new()
	hb.add_theme_constant_override("h_separation", 5)
	hb.add_theme_constant_override("v_separation", 4)
	bar.add_child(hb)
	hb.add_child(_label("FLOOR", 12, GOLD))
	floor_pick = OptionButton.new()
	floor_pick.add_theme_font_size_override("font_size", 13)
	floor_pick.tooltip_text = "Which floor of the level you are editing (PageUp / PageDown).\nStairs up / down (keys 7 / 8) join floors. A pit over an open cell of the floor below is a hole through to it:\nin the game you see the floors above and below through such holes, and fall from one into the next"
	floor_pick.item_selected.connect(func(i): _switch_floor(floor_pick.get_item_id(i) - 1000))
	hb.add_child(floor_pick)
	for fb in [["+ UP", func(): _add_floor(1), "Add a floor above the top one"], ["+ DOWN", func(): _add_floor(-1), "Add a basement below the bottom one"],
			["DEL", _delete_floor, "Delete this floor (not the ground floor). Ctrl+Z brings it back"],
			["REPEAT DOWN", _repeat_down, "Copy this floor into every floor below it, replacing what is there: the same rooms storey after storey.\nPaint a pit shaft first and it runs through them all. Ctrl+Z undoes it"]]:
		var b := _button(fb[0], fb[1])
		b.tooltip_text = fb[2]
		b.add_theme_font_size_override("font_size", 13)
		hb.add_child(b)
	var onion := CheckBox.new()
	onion.text = "Other floor"
	onion.tooltip_text = "Draw the floor below (or above) as a faint cyan outline, to line floors and stairs up"
	onion.button_pressed = show_onion
	onion.add_theme_font_size_override("font_size", 13)
	onion.toggled.connect(func(on): show_onion = on; canvas.queue_redraw())
	hb.add_child(onion)
	hb.add_child(VSeparator.new())
	hb.add_child(_label("MODE", 12, DIM))
	var mode_group := ButtonGroup.new()
	for m in [["brush", "Brush  B", "Drag to paint with the brush ([ ] changes its size)"],
			["rect", "Rectangle  M", "Drag out a rectangle. Hold Shift for this in any mode"],
			["fill", "Fill  K", "Click fills the connected area (same terrain / zone / material).\nHold Ctrl for this in any mode"]]:
		var b := _small_toggle(m[1], m[2], mode_group)
		b.button_pressed = m[0] == mode
		b.pressed.connect(func(): _set_mode(m[0]))
		mode_buttons[m[0]] = b
		hb.add_child(b)
	hb.add_child(VSeparator.new())
	hb.add_child(_label("VIEW", 12, DIM))
	var view_group := ButtonGroup.new()
	for v in [[false, "Floor", "Show floor materials (walls are drawn as their tops)"], [true, "Ceiling  C", "Show ceiling materials, to see and paint them"]]:
		var b := _small_toggle(v[1], v[2], view_group)
		b.button_pressed = v[0] == view_ceiling
		b.pressed.connect(func(): _set_view(v[0]))
		view_buttons.append(b)
		hb.add_child(b)
	hb.add_child(VSeparator.new())
	hb.add_child(_label("SHOW", 12, DIM))
	for l in [["show_tex", "Textures"], ["show_zones", "Zones"], ["show_paint", "Paint"], ["show_objects", "Objects"], ["show_grid", "Grid"], ["show_hints", "Hints"]]:
		var cb := CheckBox.new()
		cb.text = l[1]
		cb.button_pressed = get(l[0])
		cb.add_theme_font_size_override("font_size", 13)
		cb.toggled.connect(func(on): set(l[0], on); canvas.queue_redraw())
		hb.add_child(cb)
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

	# right: tools
	var right := _panel(220)
	inner.add_child(right)
	_restore_splits()
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tool_scroll = scroll
	right.add_child(scroll)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(side)
	_build_inspector(side)
	_build_tabs(side)
	var ter := _section(side, "TERRAIN")
	var terrain := [[WALL, "Wall  (1)", "A solid full-depth wall block"], [FLOOR, "Floor  (2)", "Open floor"], [PIT, "Pit  (3)", "A shaft falling into the dark. Over an open cell of the floor below it is a hole through to that floor"]]
	for b in terrain:
		ter.add_child(_tool_button("base:" + b[0], b[1], BASE_COLORS[b[0]], b[2]))
	var brow := HBoxContainer.new()
	ter.add_child(brow)
	brow.add_child(_label("BRUSH ", 14, DIM))
	brow.add_child(_button("-", func(): _set_brush(brush - 1)))
	brush_label = _label(" 1 ", 16, CREAM)
	brow.add_child(brush_label)
	brow.add_child(_button("+", func(): _set_brush(brush + 1)))
	brow.add_child(_label("  [ ]", 12, DIM))
	var aw := CheckBox.new()
	aw.text = "Auto walls"
	aw.button_pressed = auto_walls
	aw.tooltip_text = "Floor drawn as a rectangle (Rectangle mode, or Shift+drag) becomes a room: floor with a wall all round it.\nDrawing Floor past the map's edge grows the map, a wall border kept round everything"
	aw.toggled.connect(func(on): auto_walls = on)
	ter.add_child(aw)

	var sel := _section(side, "SELECT AREA")
	sel.add_child(_tool_button("area", "Select area  (S)", SEL,
		"Drag a box on the map to select everything in it: rooms, zones, paint, objects.\nDel empties it, Shift+Del walls it in, Ctrl+C / Ctrl+X / Ctrl+V copy, cut and paste it (on any floor or level),\nCtrl+Shift+V pastes on the same cells, Ctrl+A takes the whole floor, Esc or a right click drops the box"))
	var edge_btn := _button("DELETE EDGE AREA", func():
		_select_tool("area")
		area = Rect2i()
		edge_cut = true
		_status("Delete edge area: drag a box from the map's edge over what to cut off (right click / Esc cancels). It goes on every floor"))
	edge_btn.tooltip_text = "Click this, then drag a box that touches the map's edge: those columns or rows are cut off the whole level,
and everything beyond them closes up. Ctrl+Z brings them back"
	edge_btn.add_theme_font_size_override("font_size", 13)
	sel.add_child(edge_btn)
	var selgrid := GridContainer.new()
	selgrid.columns = 2
	sel.add_child(selgrid)
	for a in [["EMPTY  Del", func(): _area_clear(), "Delete every object, zone, painted material and marker in the box. The rooms stay"],
			["WALL IN", func(): _area_clear(WALL), "Empty the box and fill it with solid wall (Shift+Del)"],
			["FLOOR", func(): _area_clear(FLOOR), "Empty the box and make it all open floor"],
			["PIT", func(): _area_clear(PIT), "Empty the box and make it all pit: a shaft"],
			["COPY", _copy, "Ctrl+C"], ["CUT", _cut, "Ctrl+X: copy the box, then wall it in"],
			["PASTE", func(): _paste(true), "Paste on the cells it was copied from (Ctrl+Shift+V): on another floor that is straight above or below.\nCtrl+V pastes at the mouse instead"],
			["WHOLE FLOOR", _area_all, "Select the whole floor (Ctrl+A)"],
			["CUT COLUMNS", func(): _area_cut_strip(true), "Cut the box's columns right out of the map, on every floor: everything to their right moves left to close the gap\nand the level gets narrower. Whole columns go, top to bottom. The map is square: it only gets smaller if its last rows are unused too"],
			["CUT ROWS", func(): _area_cut_strip(false), "Cut the box's rows right out of the map, on every floor: everything below moves up to close the gap"],
			["CROP TO BOX", _area_crop, "Keep only what is in the box: every floor is cut down to it, with a wall border round it"]]:
		var ab := _button(a[0], func():
			if tool != "area" and a[0] != "PASTE": _select_tool("area")
			a[1].call())
		ab.tooltip_text = a[2]
		ab.add_theme_font_size_override("font_size", 13)
		ab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		selgrid.add_child(ab)

	var gen := _section(side, "GENERATE")
	gen.add_child(_note("Pick the Generate tool and drag an area (it can reach past the map, which grows). Rooms join whatever floor is next to the area. REGENERATE rolls the last area again."))
	var gen_b := _tool_button("gen", "Generate area  (drag)", Color("3fd1a0"), "Drag a rectangle: it is filled with generated rooms / corridors")
	gen.add_child(gen_b)
	var ggrid := GridContainer.new()
	ggrid.columns = 2
	gen.add_child(ggrid)
	ggrid.add_child(_label("Style", 13, DIM))
	var style_pick := OptionButton.new()
	var styles := [["classic", "Classic Level 0"], ["liminal", "Liminal halls"], ["mixed", "Mixed"], ["rooms", "Rooms"], ["maze", "Maze"], ["pillars", "Pillar hall"]]
	for st in styles: style_pick.add_item(st[1])
	style_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_pick.item_selected.connect(func(i): gen_style = styles[i][0])
	ggrid.add_child(style_pick)
	ggrid.add_child(_label("Seed", 13, DIM))
	var srow2 := HBoxContainer.new()
	seed_spin = SpinBox.new()
	seed_spin.max_value = 99999
	seed_spin.value = gen_seed
	seed_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_spin.value_changed.connect(func(v): gen_seed = int(v))
	srow2.add_child(seed_spin)
	var dice := _button("?", func(): seed_spin.value = randi() % 100000)
	dice.tooltip_text = "Random seed"
	srow2.add_child(dice)
	ggrid.add_child(srow2)
	for row in [["Room min", "gen_room_min", 3, 12, "Smallest room side, in cells"], ["Room max", "gen_room_max", 5, 30, "Rooms wider than this are always split"],
			["Corridor", "gen_corridor", 1, 3, "Maze corridor width, in cells"]]:
		ggrid.add_child(_label(row[0], 13, DIM))
		var sp := SpinBox.new()
		sp.min_value = row[2]
		sp.max_value = row[3]
		sp.value = get(row[1])
		sp.tooltip_text = row[4]
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp.value_changed.connect(func(v): set(row[1], int(v)))
		ggrid.add_child(sp)
	ggrid.add_child(_label("Density", 13, DIM))
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
		cb.add_theme_font_size_override("font_size", 13)
		cb.toggled.connect(func(on): set(cb_def[1], on))
		gen.add_child(cb)
	var grow := HBoxContainer.new()
	gen.add_child(grow)
	var regen := _button("REGENERATE", _regenerate)
	regen.tooltip_text = "Roll the last generated area again with a new seed"
	regen.add_theme_color_override("font_color", Color("3fd1a0"))
	regen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grow.add_child(regen)
	var whole := _button("WHOLE LEVEL", _generate_whole)
	whole.tooltip_text = "Generate over this entire floor (stairs are kept). Ctrl+Z takes it back"
	whole.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grow.add_child(whole)

	var pnt := _section(side, "PAINT MATERIALS")
	pnt.add_child(_note("Pick a material, pick a surface, drag over cells. Right click puts the level material back. Alt+click or I picks up the material under the mouse. Ctrl+click fills an area; wall paint Ctrl+clicked on a floor does that room's walls."))
	var srow := HBoxContainer.new()
	pnt.add_child(srow)
	for slot in PAINT_SLOTS:
		var sb := _tool_button("paint:" + slot, slot.capitalize(), GOLD,
			"Paint the brush material on the %s of the cells you drag over. Right click clears it%s" % [slot,
			"\nThe map switches to the ceiling view while you paint ceilings" if slot == "ceiling" else ""])
		sb.icon = null
		sb.add_theme_font_size_override("font_size", 13)
		sb.alignment = HORIZONTAL_ALIGNMENT_CENTER
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		srow.add_child(sb)
	paint_name = _label("", 13, CREAM)
	paint_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	paint_name.custom_minimum_size = Vector2(200, 0)
	pnt.add_child(paint_name)
	var scrow := HBoxContainer.new()
	pnt.add_child(scrow)
	scrow.add_child(_label("Scatter", 13, DIM))
	var sc := HSlider.new()
	sc.min_value = 5
	sc.max_value = 100
	sc.step = 5
	sc.value = scatter
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.tooltip_text = "Paint only this share of the cells, at random (e.g. 10% stained carpet over a room)"
	var sc_lbl := _label("100%", 13, CREAM)
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
	var picked := _box(Color("3a3218"), GOLD, 0, 3)
	picked.set_border_width_all(3)
	for n in pbr_names:
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(58, 58)
		b.icon = _thumb(n).tex
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.tooltip_text = n
		for st in ["normal", "hover", "pressed", "hover_pressed"]:
			b.add_theme_stylebox_override(st, picked if st.contains("pressed") else _box(Color("1d1a10"), LINE if st == "normal" else CREAM, 0, 3))
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
	var clear_b := _button("CLEAR ALL PAINT", func():
		_push_undo()
		for slot in PAINT_SLOTS: paint[slot].clear()
		_mark_dirty()
		_status("All painted materials removed (Ctrl+Z brings them back)"))
	clear_b.tooltip_text = "Take every painted material off this level, back to the level materials"
	pnt.add_child(clear_b)
	if not pbr_names.is_empty(): _set_paint_mat(pbr_names[0])

	var mats := _section(side, "LEVEL MATERIALS")
	mats.add_child(_note("The look of every cell you have not painted."))
	mats.add_child(_note("Ceiling YBR_CeilingSquare / YBR_CeilingLong: a real drop ceiling (2x2 or 2x4 tiles), every tile varied, light panels on the lights, air vents. YBR_*: Yasu's Backrooms Material Pack (CC BY 4.0)."))
	for slot in SLOTS:
		var row := HBoxContainer.new()
		mats.add_child(row)
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(44, 44)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		row.add_child(tr)
		slot_previews[slot] = tr
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 2)
		row.add_child(col)
		col.add_child(_label(slot.capitalize() + ("  (Tiles zones)" if slot == "tiles" else ""), 12, DIM))
		var ob := OptionButton.new()
		ob.add_item("(game default)")
		for n in pbr_names: ob.add_item(n)
		ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ob.item_selected.connect(func(i): _set_material(slot, "" if i == 0 else pbr_names[i - 1]))
		col.add_child(ob)
		slot_picks[slot] = ob

	# objects, one panel per object_types.json "category"
	var obj := _section(side, "WALLS")
	obj.add_child(_tool_button("select", "Select / move  (V)", CREAM,
		"Click an object to edit it, drag to move, drag its round handle to rotate, drag its squares to resize it\n(a wall's ends and thickness, a pillar's width, a trigger's depth, a curve's size and arc).\nShift+wheel sizes it, Alt+wheel turns it, the arrow keys nudge it. Drag on empty map to box-select, Shift+click adds,\nCtrl+A takes every object, Ctrl+C / Ctrl+V copy and paste. R / Shift+R rotate, Del deletes, Esc deselects"))
	tool_buttons["select"].icon = _obj_icon("_select", CREAM)
	var panels := {"walls": obj}
	for cat in [["openings", "DOORS & STAIRS"], ["events", "EVENTS"], ["props", "PROPS"]]:
		panels[cat[0]] = null
	for t in OBJ_TYPES:
		var inf: Dictionary = OBJ_INFO[t]
		var cat := str(inf.get("category", "props"))
		if panels.get(cat) == null:
			var titles := {"openings": "DOORS & STAIRS", "events": "EVENTS", "props": "PROPS"}
			panels[cat] = _section(side, titles.get(cat, cat.to_upper()), cat != "props")
		var hotkey := str(inf.get("key", ""))
		var title := "%s  (%s)" % [inf.label, hotkey] if hotkey != "" else str(inf.label)
		var b := _tool_button("obj:" + t, title, inf.col,
			str(inf.get("help", "")) + ".\nClick places one; keep the button down and drag to aim it. Right click deletes")
		b.icon = _obj_icon(t, inf.col)
		panels[cat].add_child(b)
	var props_panel: VBoxContainer = panels.get("props") if panels.get("props") != null else obj
	var has_scatter := OBJ_TYPES.any(func(t): return bool(OBJ_INFO[t].get("scatter", false)))
	if has_scatter:
		var scatter_b := _button("SCATTER PROPS", _scatter_props)
		scatter_b.tooltip_text = "Drop a random spread of clutter props onto open floor, clear of spawn / exit / entity / tv and anything already placed.\nOne undo step; Ctrl+Z to take it all back"
		scatter_b.add_theme_color_override("font_color", GOLD)
		props_panel.add_child(scatter_b)
	obj.add_child(_label("PLACING", 13, DIM))       # these apply to every object
	snap_check = CheckBox.new()
	snap_check.text = "Snap to grid  (G)"
	snap_check.button_pressed = snap
	snap_check.tooltip_text = "Positions snap to cell centres and edges. Hold Alt to place freely"
	snap_check.toggled.connect(func(on): snap = on)
	obj.add_child(snap_check)
	rot_check = CheckBox.new()
	rot_check.text = "Snap rotation 90°"
	rot_check.button_pressed = rot_snap
	rot_check.tooltip_text = "Rotation snaps to 90° so doors line up with walls. Off: free (Shift steps 15°)"
	rot_check.toggled.connect(func(on): rot_snap = on)
	obj.add_child(rot_check)
	align_check = CheckBox.new()
	align_check.text = "Align to walls  (A)"
	align_check.button_pressed = align
	align_check.tooltip_text = "On a cell edge a piece lines up with the edge; on a cell it spans the corridor or wall it lands in.\nHold Alt to skip"
	align_check.toggled.connect(func(on): align = on)
	obj.add_child(align_check)

	# zones by what they do to the place, each group under its own small heading; any zone not listed here
	# (a new one) lands in OTHER, so nothing goes missing
	var zn := _section(side, "ZONES")
	var zone_groups := [
		["CEILING & HEIGHT", ["tall", "low", "crawl", "open_ceiling", "endless_ceiling"]],
		["LIGHT", ["bright", "dark", "dim", "flicker"]],
		["LOOK & SURFACE", ["classic", "liminal", "tiles", "grime"]],
		["PITS & FALLS", ["abyss", "noclip", "noclip_floor"]],
		["SPACE & SOUND", ["loop", "echo"]],
		["GAMEPLAY", ["safe", "drain", "loot", "mannequin"]],
	]
	var placed := {}
	for g in zone_groups:
		for z in g[1]: placed[z] = true
	var rest: Array = ZONES.keys().filter(func(z): return not placed.has(z))
	if not rest.is_empty(): zone_groups.append(["OTHER", rest])
	for g in zone_groups:
		var names: Array = (g[1] as Array).filter(func(z): return ZONES.has(z))
		if names.is_empty(): continue
		var head := _label(str(g[0]), 12, DIM)
		zn.add_child(head)
		var zgrid := GridContainer.new()
		zgrid.columns = 2
		zn.add_child(zgrid)
		for z in names:
			var zb := _tool_button("zone:" + z, str(z).capitalize(), ZONES[z], ZONE_HELP.get(z, ""))
			zb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			zgrid.add_child(zb)

	var mk := _section(side, "MARKERS")
	var mgrid := GridContainer.new()
	mgrid.columns = 2
	mk.add_child(mgrid)
	for m in MARKERS:
		var mb := _tool_button("mark:" + m, m.capitalize(), MARKERS[m], "Click places, right click removes" + ("\nDrag from the marker to turn where the player looks (Shift snaps to 15°)" if m == "spawn" else ""))
		mb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mgrid.add_child(mb)

	# bottom status bar
	var bot := PanelContainer.new()
	bot.add_theme_stylebox_override("panel", _box(Color("100e08"), LINE, 0, 6))
	root.add_child(bot)
	var bb := HBoxContainer.new()
	bb.add_theme_constant_override("separation", 20)
	bot.add_child(bb)
	status = _label("", 14, DIM)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.clip_text = true                   # a long message must never widen the window
	status.custom_minimum_size = Vector2(100, 0)
	bb.add_child(status)
	info = _label("", 14, DIM)
	bb.add_child(info)

	_build_dialogs()

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
	box.add_theme_stylebox_override("panel", _box(Color("221e10"), GOLD, 0, 8))
	side.add_child(box)
	insp = VBoxContainer.new()
	box.add_child(insp)
	insp.add_child(_label("SELECTED OBJECT", 16, GOLD))
	insp_trigger_btn = _button("CONFIGURE EVENT OPTIONS...", func():
		if selected >= 0 and selected < objects.size() and objects[selected].type == "trigger":
			_open_trigger_dialog(selected)
	)
	insp_trigger_btn.add_theme_color_override("font_color", GOLD)
	insp_trigger_btn.visible = false
	insp.add_child(insp_trigger_btn)
	var grid_box := GridContainer.new()
	grid_box.columns = 2
	insp.add_child(grid_box)
	grid_box.add_child(_label("Type", 14, DIM))
	insp_type = OptionButton.new()
	for t in OBJ_TYPES: insp_type.add_item(OBJ_INFO[t].label)
	insp_type.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	insp_type.item_selected.connect(func(i): _set_prop("type", OBJ_TYPES[i]))
	grid_box.add_child(insp_type)
	insp_x = _insp_spin(grid_box, "X", 0.0, 96.0, 0.05, "pos_x", "cells, a cell's centre is a whole number")
	insp_y = _insp_spin(grid_box, "Y", 0.0, 96.0, 0.05, "pos_y", "cells, a cell's centre is a whole number")
	insp_rot = _insp_spin(grid_box, "Rotation", -360.0, 720.0, 0.5, "rotation", "degrees clockwise; the arrow shows which way it faces")
	insp_rot.suffix = "°"
	insp_scale = _insp_spin(grid_box, "Width", 0.5, 4.0, 0.05, "scale", "span in cells")
	insp_scale_label = grid_box.get_child(grid_box.get_child_count() - 2)
	# per-type fields (object_types.json "params"): only the selected type's are shown
	_insp_param_spin(grid_box, "thick", "Thickness", 0.05, 4.5, 0.05, " m", "wall thickness (a pillar or column: its width)")
	_insp_param_spin(grid_box, "height", "Height", 0.0, 10.8, 0.05, " m", "0 = up to the ceiling. Under 1.8 m you see over it (a half wall, a counter)")
	_insp_param_spin(grid_box, "arc", "Arc", 5.0, 360.0, 5.0, "°", "how much of the circle is built: 90 rounds a corner, 360 closes a round room")
	_insp_param_spin(grid_box, "depth", "Depth", 0.25, 40.0, 0.25, "", "cells along the arrow")
	_insp_param_spin(grid_box, "elev", "Off floor", 0.0, 10.8, 0.05, " m", "how far its lowest point is lifted off the floor: a sign on a wall, a box on a shelf.\nIn the 3D view (F4): Ctrl+wheel, or drag a wall prop up and down its wall")
	var ev_lbl := _label("Event", 14, DIM)
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
	var c_ev_lbl := _label("Custom Event", 14, DIM)
	grid_box.add_child(c_ev_lbl)
	var c_ev := LineEdit.new()
	c_ev.placeholder_text = "event_name"
	c_ev.tooltip_text = "Event identifier dispatched when player enters the trigger area"
	c_ev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c_ev.text_changed.connect(func(t): _set_prop("custom_event", t))
	c_ev.text_submitted.connect(func(_t): c_ev.release_focus())
	grid_box.add_child(c_ev)
	insp_params["custom_event"] = {"row": [c_ev_lbl, c_ev], "ctrl": c_ev}
	var tx_lbl := _label("Text", 14, DIM)
	grid_box.add_child(tx_lbl)
	var tx := LineEdit.new()
	tx.placeholder_text = "a caption (optional)"
	tx.tooltip_text = "Shown low on the screen when it fires, whatever the event"
	tx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tx.text_changed.connect(func(t): _set_prop("text", t))
	tx.text_submitted.connect(func(_t): tx.release_focus())
	grid_box.add_child(tx)
	insp_params["text"] = {"row": [tx_lbl, tx], "ctrl": tx}
	var once_lbl := _label("Once", 14, DIM)
	grid_box.add_child(once_lbl)
	var once := CheckBox.new()
	once.text = "only the first time"
	once.tooltip_text = "Off: fires every time the player walks back in (at most every 5 s)"
	once.toggled.connect(func(on): _set_prop("once", on))
	grid_box.add_child(once)
	insp_params["once"] = {"row": [once_lbl, once], "ctrl": once}
	_insp_param_spin(grid_box, "delay", "Delay", 0.0, 60.0, 0.1, " s", "seconds from walking in to the event")
	_insp_param_spin(grid_box, "duration", "Duration", 1.0, 120.0, 1.0, " s", "how long lights_out / silence / drone last")
	# any other type's params: a drop-down for one with "choices" (object_types.json), a tick box for a yes / no
	for t in OBJ_TYPES:
		var params: Dictionary = OBJ_INFO[t].get("params", {})
		var choices: Dictionary = OBJ_INFO[t].get("choices", {})
		for k in params:
			if insp_params.has(k): continue
			var title := str(k).capitalize()
			if choices.has(k):
				var lbl := _label(title, 14, DIM)
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
				var lbl := _label(title, 14, DIM)
				grid_box.add_child(lbl)
				var tick := CheckBox.new()
				tick.toggled.connect(func(on): _set_prop(k, on))
				grid_box.add_child(tick)
				insp_params[k] = {"row": [lbl, tick], "ctrl": tick}
	var r := HBoxContainer.new()
	insp.add_child(r)
	for b in [["-90°", func(): _rotate_selected(-90.0)], ["+90°", func(): _rotate_selected(90.0)], ["COPY", _duplicate_selected], ["DELETE", _delete_selected]]:
		var bt := _button(b[0], b[1])
		bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(bt)
	box.visible = false

## One per-type param row of the inspector (see _build_inspector), kept in insp_params to show / hide
func _insp_param_spin(parent: Control, key: String, text: String, lo: float, hi: float, step: float, suffix: String, tip: String) -> void:
	var sb := _insp_spin(parent, text, lo, hi, step, key, tip)
	sb.suffix = suffix
	insp_params[key] = {"row": [parent.get_child(parent.get_child_count() - 2), sb], "ctrl": sb}

func _insp_spin(parent: Control, text: String, lo: float, hi: float, step: float, key: String, tip: String) -> SpinBox:
	parent.add_child(_label(text, 14, DIM))
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
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_font_size_override("font_size", 16)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		head.add_theme_color_override(c, GOLD)
	var body := VBoxContainer.new()
	body.visible = open
	body.add_theme_constant_override("separation", 5)
	var sep := HSeparator.new()
	side.add_child(sep)
	side.add_child(head)
	side.add_child(body)
	tab_parts.get_or_add(TAB_OF.get(title, "build"), []).append_array([sep, head, body])
	var relabel := func(): head.text = ("-  " if body.visible else "+  ") + title
	relabel.call()
	head.pressed.connect(func():
		body.visible = not body.visible
		body.set_meta("open", body.visible)
		relabel.call())
	body.set_meta("open", open)
	return body

func _note(text: String) -> Label:
	var l := _label(text, 12, DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(200, 0)
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

func _gen_ui_sync() -> void:
	if seed_spin: seed_spin.set_value_no_signal(gen_seed)

func _set_view(ceiling: bool) -> void:
	view_ceiling = ceiling
	if view_buttons.size() == 2: view_buttons[1 if ceiling else 0].button_pressed = true
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

func _tool_button(id: String, text: String, col: Color, tip: String) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 36)
	b.add_theme_constant_override("h_separation", 10)
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = true
	b.button_pressed = id == tool
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(Rect2i(2, 2, 14, 14), Color.BLACK)
	img.fill_rect(Rect2i(3, 3, 12, 12), col)
	b.icon = ImageTexture.create_from_image(img)
	b.pressed.connect(func(): _select_tool(id))
	tool_buttons[id] = b
	return b

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
		tool_buttons[k].button_pressed = (k == id)

func _set_brush(n: int) -> void:
	brush = clampi(n, 1, 8)
	brush_label.text = " %d " % brush

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
		return
	if k.keycode == KEY_F5:
		_test_level()
		return
	if k.keycode == KEY_F6:
		_test_level(true)
		return
	if k.keycode == KEY_F4:
		_toggle_3d()
		return
	if preview3d.visible:                # the 3D view owns the letter keys (WASD, C)
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
	split_left.split_offset = int(cf.get_value("ui", "left_w", 270))
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
	if cf.load(UI_CFG) == OK and cf.has_section_key("ui", "scale"):
		return float(cf.get_value("ui", "scale"))
	return _auto_ui_scale()

func _auto_ui_scale() -> float:
	# Retina / hi-DPI screens report a scale (2 on a Mac); a tall screen gets a little more on top
	var scr := DisplayServer.window_get_current_screen()
	var dpi := DisplayServer.screen_get_scale(scr)
	var tall := DisplayServer.screen_get_size(scr).y / dpi / 1000.0
	return clampf(snappedf(dpi * 0.75 * maxf(1.0, tall), 0.05), 1.0, 2.5)

func _apply_ui_scale(v: float) -> void:
	ui_scale = clampf(v, 0.75, 2.5)
	get_window().content_scale_factor = ui_scale

func _step_ui_scale(d: float) -> void:
	_apply_ui_scale(_auto_ui_scale() if d == 0.0 else ui_scale + d)
	var cf := ConfigFile.new()
	cf.load(UI_CFG)
	cf.set_value("ui", "scale", ui_scale)
	cf.save(UI_CFG)
	_status("UI scale %d%%  (Ctrl + / Ctrl - / Ctrl 0 = fit the screen)" % roundi(ui_scale * 100.0))

# ---------------------------------------------------------------- object icons
## A 28 px plan-view pictogram of an object type, in its colour, so the tools read at a glance
func _obj_icon(t: String, col: Color) -> ImageTexture:
	const N := 28
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := col.lightened(0.15)
	var dark := Color(0, 0, 0, 0.9)
	var box := func(x0: int, y0: int, x1: int, y1: int, k: Color) -> void:
		img.fill_rect(Rect2i(x0, y0, x1 - x0, y1 - y0), k)
	var disc := func(cx: float, cy: float, r: float, k: Color, ring := 0.0) -> void:
		for y in N:
			for x in N:
				var d := Vector2(x + 0.5 - cx, y + 0.5 - cy).length()
				if d <= r and (ring <= 0.0 or d >= r - ring): img.set_pixel(x, y, k)
	var info: Dictionary = OBJ_INFO.get(t, {})
	var shape := str(info.get("shape", ""))
	if t == "_select":
		for i in 16:                                      # an arrow cursor
			for j in i / 2 + 1:
				img.set_pixel(6 + j, 4 + i, c)
		box.call(10, 16, 13, 25, c)
	elif t == "door":
		box.call(2, 12, 8, 16, c); box.call(20, 12, 26, 16, c)
		box.call(8, 4, 10, 14, c)                         # the leaf, swung open
		disc.call(9, 14, 11, c, 1.2)
		box.call(0, 0, 0, 0, c)
	elif t == "squeeze_gap":
		box.call(2, 6, 12, 22, c); box.call(16, 6, 26, 22, c)   # the wall, and the slit between
	elif t == "arch":
		box.call(3, 8, 8, 26, c); box.call(20, 8, 25, 26, c)
		disc.call(14, 14, 11, c, 4.0)
		box.call(8, 14, 20, 27, Color(0, 0, 0, 0))
	elif t.begins_with("stairs_"):
		for i in 5:
			box.call(4 + i * 4, 26 - (i + 1) * 4, 8 + i * 4, 26, c.darkened(0.12 * i))
		var up := t == "stairs_up"
		for i in 6:                                       # an arrow up or down
			box.call(20 - i, (3 + i) if up else (12 - i), 21 + i, (4 + i) if up else (13 - i), Color.WHITE)
	elif shape == "zone":
		for i in range(2, 26, 4):                         # dashed box and a bolt
			box.call(i, 2, i + 2, 4, c); box.call(i, 24, i + 2, 26, c)
			box.call(2, i, 4, i + 2, c); box.call(24, i, 26, i + 2, c)
		for i in 7:
			box.call(15 - i, 6 + i, 18 - i, 7 + i, Color.WHITE)
		box.call(10, 13, 19, 15, Color.WHITE)
		for i in 7:
			box.call(14 - i + 3, 15 + i, 17 - i + 3, 16 + i, Color.WHITE)
	elif shape == "slab" and t == "half_wall":
		box.call(2, 11, 26, 18, c)
		for x in range(3, 26, 4): box.call(x, 12, x + 2, 17, dark)   # hatched: you see over it
	elif shape == "slab":
		box.call(2, 11, 26, 17, c)
	elif shape == "corner":
		box.call(4, 4, 10, 25, c); box.call(4, 19, 25, 25, c)
	elif shape == "arc":
		disc.call(24, 24, 20, c, 5.0)
	elif shape == "pillar":
		box.call(7, 7, 21, 21, c)
	elif shape == "column":
		disc.call(14, 14, 8, c)
	else:                                                 # a clutter prop: a crate-like blob in its colour
		disc.call(14, 15, 10, c)
		disc.call(14, 15, 10, dark, 1.5)
		box.call(8, 13, 20, 15, dark)
	# a dark outline round whatever was drawn, so light icons read on the light buttons too
	var out := img.duplicate()
	for y in N:
		for x in N:
			if img.get_pixel(x, y).a > 0.5: continue
			for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var q: Vector2i = Vector2i(x, y) + o
				if q.x >= 0 and q.y >= 0 and q.x < N and q.y < N and img.get_pixelv(q).a > 0.5:
					out.set_pixel(x, y, Color(0, 0, 0, 0.85))
					break
	return ImageTexture.create_from_image(out)

# ---------------------------------------------------------------- tabs and tool search
## The tool panel is split into tabs (each section belongs to one) with a search box over them
const TABS := [["build", "BUILD"], ["paint", "PAINT"], ["generate", "GENERATE"], ["props", "PROPS"]]
const TAB_OF := {"TERRAIN": "build", "WALLS": "build", "DOORS & STAIRS": "build", "EVENTS": "build", "MARKERS": "build",
	"PAINT MATERIALS": "paint", "LEVEL MATERIALS": "paint", "ZONES": "paint", "GENERATE": "generate", "PROPS": "props"}
var tab_parts := {}                  # tab -> the section controls it shows
var tab_now := "build"
var tab_buttons := {}
var search_box: LineEdit
var search_results: VBoxContainer

func _build_tabs(side: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	side.add_child(row)
	var grp := ButtonGroup.new()
	for t in TABS:
		var b := Button.new()
		b.text = t[1]
		b.toggle_mode = true
		b.button_group = grp
		b.button_pressed = t[0] == tab_now
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 14)
		b.add_theme_color_override("font_pressed_color", Color.BLACK)
		b.add_theme_stylebox_override("pressed", _box(GOLD, GOLD, 0, 6))
		b.add_theme_stylebox_override("hover_pressed", _box(GOLD, GOLD, 0, 6))
		b.pressed.connect(func(): _show_tab(t[0]))
		row.add_child(b)
		tab_buttons[t[0]] = b
	search_box = LineEdit.new()
	search_box.placeholder_text = "search tools...   ( / )"
	search_box.clear_button_enabled = true
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
			if not tb.text.to_lower().contains(q) and not str(id).to_lower().contains(q): continue
			var b := Button.new()
			b.text = tb.text
			b.icon = tb.icon
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.custom_minimum_size = Vector2(0, 36)
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
