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
##   A align to walls, Alt ignores snapping and aligning, Shift while rotating steps 15 degrees
## The object types (and their keys, colours and sizes) come from the game's levels/object_types.json.
## Types with a "model" key are decorative clutter (imported meshes, not procedural geometry); those also
## flagged "scatter": true can be dropped in bulk with the SCATTER PROPS button in the OBJECTS panel.

const BG := Color("0d0c08")
const PANEL := Color("16140d")
const LINE := Color("3a3522")
const ZONE_HELP := {"tall": "Huge atrium ceiling", "low": "Crouch-height ceiling", "tiles": "Tile floor instead of carpet",
	"bright": "Always lit, safe room", "dark": "All tubes dead", "dim": "Most tubes dead", "flicker": "Failing tubes", "grime": "Stained carpet", "classic": "Super bright classic backrooms: steady glowing tubes, clear air",
	"liminal": "Liminal: every tube on and steady, flat pale light, halls fading into haze far away",
	"mannequin": "Where the mannequins stand: paint as many areas as you like"}
const ATMO_HELP := "dim = failing tubes, light dies in the fog (default)\nclassic = the whole level is a Classic zone: bright, steady, clear air\nliminal = the whole level is a Liminal zone: all lights on, pale, a haze you can see a long way into\nA ceiling material with glowing panels (e.g. BRC_A) swaps the tubes for its panels."
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

func _ready() -> void:
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
	t.default_font_size = 16
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
	view_b.tooltip_text = "Switch the map to an orbitable 3D view of the level (right drag orbit, wheel zoom, C ceiling)"
	tb.add_child(view_b)
	tb.add_child(_button("UNDO", _undo))
	tb.add_child(_button("REDO", _redo))
	tb.add_child(_button("FIT", _fit))
	for b in tb.get_children():
		if b is Button: b.add_theme_font_size_override("font_size", 14)
	var save_b := _button("SAVE  Ctrl+S", save)
	save_b.add_theme_color_override("font_color", GOLD)
	tb.add_child(save_b)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)

	# left: level list
	var left := _panel(270)
	body.add_child(left)
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

	# center: canvas
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 0)
	body.add_child(mid)
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
	floor_pick.tooltip_text = "Which floor of the level you are editing (PageUp / PageDown).\nStairs up / down (keys 7 / 8) join floors; the game loads one floor at a time"
	floor_pick.item_selected.connect(func(i): _switch_floor(floor_pick.get_item_id(i) - 1000))
	hb.add_child(floor_pick)
	for fb in [["+ UP", func(): _add_floor(1), "Add a floor above the top one"], ["+ DOWN", func(): _add_floor(-1), "Add a basement below the bottom one"],
			["DEL", _delete_floor, "Delete this floor (not the ground floor). Ctrl+Z brings it back"]]:
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
	for l in [["show_tex", "Textures"], ["show_zones", "Zones"], ["show_paint", "Paint"], ["show_objects", "Objects"], ["show_grid", "Grid"]]:
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
	var right := _panel(330)
	body.add_child(right)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(side)
	_build_inspector(side)
	var ter := _section(side, "TERRAIN")
	var terrain := [[WALL, "Wall  (1)", "A solid full-depth wall block"], [FLOOR, "Floor  (2)", "Open floor"], [PIT, "Pit  (3)", "A shaft falling into the dark"]]
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

	var obj := _section(side, "OBJECTS")
	obj.add_child(_tool_button("select", "Select / move  (V)", CREAM,
		"Click an object to edit it, drag to move, drag its round handle to rotate.\nR / Shift+R rotate, Del deletes, Esc deselects"))
	for t in OBJ_TYPES:
		var inf: Dictionary = OBJ_INFO[t]
		var hotkey := str(inf.get("key", ""))
		var title := "%s  (%s)" % [inf.label, hotkey] if hotkey != "" else str(inf.label)
		obj.add_child(_tool_button("obj:" + t, title, inf.col,
			str(inf.get("help", "")) + ".\nClick places one; keep the button down and drag to aim it. Right click deletes"))
	var has_scatter := OBJ_TYPES.any(func(t): return bool(OBJ_INFO[t].get("scatter", false)))
	if has_scatter:
		var scatter_b := _button("SCATTER PROPS", _scatter_props)
		scatter_b.tooltip_text = "Drop a random spread of clutter props onto open floor, clear of spawn / exit / entity / tv and anything already placed.\nOne undo step; Ctrl+Z to take it all back"
		scatter_b.add_theme_color_override("font_color", GOLD)
		obj.add_child(scatter_b)
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

	var zn := _section(side, "ZONES")
	var zgrid := GridContainer.new()
	zgrid.columns = 2
	zn.add_child(zgrid)
	for z in ZONES:
		var zb := _tool_button("zone:" + z, z.capitalize(), ZONES[z], ZONE_HELP[z])
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

## The selected object's properties, at the top of the tool panel (hidden when nothing is selected)
func _build_inspector(side: VBoxContainer) -> void:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _box(Color("221e10"), GOLD, 0, 8))
	side.add_child(box)
	insp = VBoxContainer.new()
	box.add_child(insp)
	insp.add_child(_label("SELECTED OBJECT", 16, GOLD))
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
	var relabel := func(): head.text = ("-  " if body.visible else "+  ") + title
	relabel.call()
	head.pressed.connect(func():
		body.visible = not body.visible
		relabel.call())
	return body

func _note(text: String) -> Label:
	var l := _label(text, 12, DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(200, 0)
	return l

func _small_toggle(text: String, tip: String, group: ButtonGroup) -> Button:
	var b := Button.new()
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

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b

func _tool_button(id: String, text: String, col: Color, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = true
	b.button_pressed = id == tool
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(col)
	b.icon = ImageTexture.create_from_image(img)
	b.pressed.connect(func(): _select_tool(id))
	tool_buttons[id] = b
	return b

func _select_tool(id: String) -> void:
	tool = id
	if id == "paint:ceiling": _set_view(true)
	elif id.begins_with("paint:") or id.begins_with("base:"): _set_view(false)
	rect_from = Vector2i(-1, -1)
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
	if k.keycode == KEY_SPACE:
		space_down = k.pressed
		return
	if k.keycode in [KEY_CTRL, KEY_SHIFT]:     # they change what a click does: show it
		canvas.queue_redraw()
	if not k.pressed or (get_viewport().gui_get_focus_owner() is LineEdit) or name_dialog.visible: return
	if k.ctrl_pressed:
		match k.keycode:
			KEY_S: save()
			KEY_Z: _redo() if k.shift_pressed else _undo()
			KEY_Y: _redo()
			KEY_N: _ask_new()
			KEY_D: _ask_dup()
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
		KEY_R: _rotate_selected(-90.0 if k.shift_pressed else 90.0)
		KEY_G: snap_check.button_pressed = not snap_check.button_pressed
		KEY_A: align_check.button_pressed = not align_check.button_pressed
		KEY_DELETE, KEY_BACKSPACE: _delete_selected()
		KEY_ESCAPE: _select(-1)
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
