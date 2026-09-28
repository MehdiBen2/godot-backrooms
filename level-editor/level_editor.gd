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

const BG := Color("0d0c08")
const PANEL := Color("16140d")
const LINE := Color("3a3522")
const ZONE_HELP := {"tall": "Huge atrium ceiling", "low": "Crouch-height ceiling", "tiles": "Tile floor instead of carpet",
	"bright": "Always lit, safe room", "dark": "All tubes dead", "dim": "Most tubes dead", "flicker": "Failing tubes", "grime": "Stained carpet", "classic": "Super bright classic backrooms: steady glowing tubes, clear air"}
const ATMO_HELP := "dim = failing tubes, light dies in the fog (default)\nclassic = the whole level is a Classic zone: bright, steady, clear air\nA ceiling material with glowing panels (e.g. BRC_A) swaps the tubes for its panels."
var search: LineEdit
var tool_buttons := {}
var brush_label: Label
var snap_check: CheckBox
var rot_check: CheckBox
var align_check: CheckBox

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
	tb.add_theme_constant_override("separation", 14)
	top.add_child(tb)
	tb.add_child(_label("BACKROOMS // LEVEL EDITOR", 20, GOLD))
	title_label = _label("", 18, CREAM)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb.add_child(title_label)
	var test_b := _button("TEST  F5", _test_level)
	test_b.tooltip_text = "Save, then open this level in the game with noclip (fly through walls)"
	test_b.add_theme_color_override("font_color", Color("2fd968"))
	tb.add_child(test_b)
	tb.add_child(_button("UNDO", _undo))
	tb.add_child(_button("FIT", _fit))
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
	size_spin.min_value = 16
	size_spin.max_value = 96
	size_spin.value = grid_size
	size_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_row.add_child(size_spin)
	size_row.add_child(_button("RESIZE", func(): _resize(int(size_spin.value))))

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
	canvas = Control.new()
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.clip_contents = true
	canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
	canvas.focus_mode = Control.FOCUS_CLICK      # clicking the map commits whatever inspector field was being typed in
	canvas.draw.connect(_draw_canvas)
	canvas.gui_input.connect(_canvas_input)
	canvas.resized.connect(canvas.queue_redraw)
	mid.add_child(canvas)

	# right: tools
	var right := _panel(290)
	body.add_child(right)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(side)
	_build_inspector(side)
	side.add_child(_label("TERRAIN", 16, GOLD))
	var terrain := [[WALL, "Wall  (1)", "A solid full-depth wall block"], [FLOOR, "Floor  (2)", "Open floor"], [PIT, "Pit  (3)", "A shaft falling into the dark"]]
	for b in terrain:
		side.add_child(_tool_button("base:" + b[0], b[1], BASE_COLORS[b[0]], b[2]))
	var brow := HBoxContainer.new()
	side.add_child(brow)
	brow.add_child(_label("BRUSH ", 16, DIM))
	brow.add_child(_button("-", func(): _set_brush(brush - 1)))
	brush_label = _label(" 1 ", 16, CREAM)
	brow.add_child(brush_label)
	brow.add_child(_button("+", func(): _set_brush(brush + 1)))
	side.add_child(_label("OBJECTS", 16, GOLD))
	side.add_child(_tool_button("select", "Select / move  (V)", CREAM,
		"Click an object to edit it, drag to move, drag its round handle to rotate.\nR / Shift+R rotate, Del deletes, Esc deselects"))
	for t in OBJ_TYPES:
		var inf: Dictionary = OBJ_INFO[t]
		side.add_child(_tool_button("obj:" + t, "%s  (%s)" % [inf.label, inf.key], inf.col,
			inf.help + ".\nClick places one; keep the button down and drag to aim it. Right click deletes"))
	snap_check = CheckBox.new()
	snap_check.text = "Snap to grid  (G)"
	snap_check.button_pressed = snap
	snap_check.tooltip_text = "Positions snap to cell centres and edges. Hold Alt to place freely"
	snap_check.toggled.connect(func(on): snap = on)
	side.add_child(snap_check)
	rot_check = CheckBox.new()
	rot_check.text = "Snap rotation 90°"
	rot_check.button_pressed = rot_snap
	rot_check.tooltip_text = "Rotation snaps to 90° so doors line up with walls. Off: free (Shift steps 15°)"
	rot_check.toggled.connect(func(on): rot_snap = on)
	side.add_child(rot_check)
	align_check = CheckBox.new()
	align_check.text = "Align to walls  (A)"
	align_check.button_pressed = align
	align_check.tooltip_text = "On a cell edge a piece lines up with the edge; on a cell it spans the corridor or wall it lands in.\nHold Alt to skip"
	align_check.toggled.connect(func(on): align = on)
	side.add_child(align_check)
	side.add_child(_label("ZONES", 16, GOLD))
	for z in ZONES:
		side.add_child(_tool_button("zone:" + z, z.capitalize(), ZONES[z], ZONE_HELP[z]))
	side.add_child(_label("MARKERS", 16, GOLD))
	for m in MARKERS:
		side.add_child(_tool_button("mark:" + m, m.capitalize(), MARKERS[m], "Click places, right click removes"))
	side.add_child(_label("MATERIALS", 16, GOLD))
	for slot in SLOTS:
		side.add_child(_label(slot.capitalize(), 14, DIM))
		var ob := OptionButton.new()
		ob.add_item("(default)")
		for n in pbr_names: ob.add_item(n)
		ob.item_selected.connect(func(i): _set_material(slot, "" if i == 0 else pbr_names[i - 1]))
		side.add_child(ob)
		slot_picks[slot] = ob
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(0, 84)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.clip_contents = true
		side.add_child(tr)
		slot_previews[slot] = tr

	# bottom status bar
	var bot := PanelContainer.new()
	bot.add_theme_stylebox_override("panel", _box(Color("100e08"), LINE, 0, 6))
	root.add_child(bot)
	var bb := HBoxContainer.new()
	bb.add_theme_constant_override("separation", 20)
	bot.add_child(bb)
	status = _label("", 14, DIM)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	var r := HBoxContainer.new()
	insp.add_child(r)
	for b in [["-90°", func(): _rotate_selected(-90.0)], ["+90°", func(): _rotate_selected(90.0)], ["COPY", _duplicate_selected], ["DELETE", _delete_selected]]:
		var bt := _button(b[0], b[1])
		bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(bt)
	box.visible = false

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
	if not k.pressed or (get_viewport().gui_get_focus_owner() is LineEdit) or name_dialog.visible: return
	if k.ctrl_pressed:
		match k.keycode:
			KEY_S: save()
			KEY_Z: _undo()
			KEY_N: _ask_new()
			KEY_D: _ask_dup()
		return
	if k.keycode == KEY_F5:
		_test_level()
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
