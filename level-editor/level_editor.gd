extends Control
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
##   Alt ignores snapping, Shift while rotating steps 15 degrees

const CREAM := Color("e6e1cd")
const DIM := Color(0.9, 0.882, 0.804, 0.55)
const GOLD := Color("e6c65a")
const RED := Color("c4271f")
const BG := Color("0d0c08")
const PANEL := Color("16140d")
const LINE := Color("3a3522")
const SEL := Color("35e0ff")             # selection gizmo: nothing else on the map is cyan, so it reads on any floor

const WALL := "#"
const FLOOR := "."
const PIT := "O"
const THIN := "T"                    # v1 tiles, converted into objects when a level opens (_migrate_legacy)
const ARCH := "A"
const DOOR := "D"
const ZONES := {"tall": Color("5a9bff"), "low": Color("ff8a3d"), "tiles": Color("f2f2f2"), "bright": Color("fff04a"),
	"dark": Color("7a2cff"), "dim": Color("8a6a3a"), "flicker": Color("ff3f9a"), "grime": Color("8a6a30"), "classic": Color("ffe86a")}
const ZONE_HELP := {"tall": "Huge atrium ceiling", "low": "Crouch-height ceiling", "tiles": "Tile floor instead of carpet",
	"bright": "Always lit, safe room", "dark": "All tubes dead", "dim": "Most tubes dead", "flicker": "Failing tubes", "grime": "Stained carpet", "classic": "Super bright classic backrooms: steady glowing tubes, clear air"}
const MARKERS := {"spawn": Color("2fd968"), "exit": Color("2fd9ee"), "entity": Color("ff3030"), "tv": Color("5c8dff")}
const BASE_COLORS := {WALL: Color("3f3a30"), FLOOR: Color("cdb86a"), PIT: Color("050505"),
	THIN: Color("7a7364"), ARCH: Color("8a7a52"), DOOR: Color("6b4a2e")}
const SLOTS := ["wall", "floor", "ceiling", "tiles"]
# Free-placed objects, mirrored from the game's level_data.gd. Positions are in cells with a cell's centre
# on a whole number (the same frame as "spawn"), rotation is degrees clockwise on this map, scale is the
# width in cells. Locally an object faces +x (you walk through it along x) and spans y.
const OBJ_TYPES := ["thin_wall", "arch", "door"]
const OBJ_INFO := {
	"thin_wall": {"label": "Thin wall", "key": "4", "col": Color("4f493e"), "help": "A slim partition"},
	"arch": {"label": "Arch", "key": "5", "col": Color("7a5f36"), "help": "A round-topped opening through a full wall. Put it square on a wall cell to punch through it"},
	"door": {"label": "Door", "key": "6", "col": Color("c0602a"), "help": "A framed wood door set in its own thin wall; opens as you approach"}}
const CELL_M := 4.5                  # metres per cell in the game; the sizes below match level_geometry.gd / door.gd
const THIN_C := 0.3 / CELL_M         # thin wall / door partition thickness
const DOOR_C := 1.12 / CELL_M        # door opening (leaf + frame lining)
const PILLAR_C := 0.75 / CELL_M      # arch pillar at each end of its span
const SNAP_STEP := 0.5               # snap to cell centres and cell edges
const ATMOS := ["dim", "classic"]      # the level-wide look ("atmosphere" in the .lvl, level_data.gd atmosphere())
const ATMO_HELP := "dim = failing tubes, light dies in the fog (default)\nclassic = the whole level is a Classic zone: bright, steady, clear air\nA ceiling material with glowing panels (e.g. BRC_A) swaps the tubes for its panels."
const NAME_WORDS := ["The Lobby", "Habitable Zone", "Sector", "Annex", "Storage", "Maintenance", "Threshold", "Pool Rooms", "Stairwell", "Office"]

var GAME := OS.get_environment("BACKROOMS_GAME_DIR") if OS.has_environment("BACKROOMS_GAME_DIR") \
	else ProjectSettings.globalize_path("res://").path_join("../godot-backrooms").simplify_path()

var index: Array = []
var current := -1
var data: Dictionary = {}
var grid_size := 46
var grid: Array = []                 # grid[z] is an Array of one-char strings
var zones := {}                      # zone -> {Vector2i: true}
var markers := {}                    # marker -> Vector2i or null
var materials := {}                  # slot -> pbr name
var tool := "base:" + WALL
var brush := 1
var undo_stack: Array = []
var painting := false
var erasing := false
var panning := false
var space_down := false
var zoom := 14.0
var pan := Vector2(10, 10)
var hover := Vector2i(-1, -1)
var dirty := false
var filter := ""
var objects: Array = []              # {type, pos_x, pos_y, rotation, scale}
var selected := -1                   # index into objects
var hover_obj := -1
var drag := ""                       # "" | "move" | "rotate" | "place"
var drag_off := Vector2.ZERO         # grab point -> object origin, in cells
var mouse_px := Vector2(-1, -1)
var place_rot := 0.0                 # new objects start at the last rotation / width used
var place_scale := 1.0
var snap := true
var rot_snap := true
var insp_undo := -1                  # the object the inspector already pushed an undo step for

var font: FontFile = load("res://fonts/vcr.ttf")
var canvas: Control
var level_list: ItemList
var search: LineEdit
var size_spin: SpinBox
var gi_pick: OptionButton
var atmo_pick: OptionButton
var title_label: Label
var status: Label
var info: Label
var tool_buttons := {}
var brush_label: Label
var slot_picks := {}
var slot_previews := {}
var pbr_names: Array = []
var name_dialog: ConfirmationDialog
var name_edit: LineEdit
var name_hint: Label
var name_mode := ""                  # "new" | "rename" | "dup"
var delete_dialog: ConfirmationDialog
var godot_dialog: FileDialog
var shown: Array = []                # index positions currently shown in the list
var insp: VBoxContainer
var insp_type: OptionButton
var insp_x: SpinBox
var insp_y: SpinBox
var insp_rot: SpinBox
var insp_scale: SpinBox
var snap_check: CheckBox
var rot_check: CheckBox

func _ready() -> void:
	theme = _make_theme()
	_scan_pbr()
	_build_ui()
	_load_index()
	_open(0)

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

# ---------------------------------------------------------------- level list
func _load_index() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(GAME.path_join("levels/levels.json")))
	index = parsed if parsed is Array else []
	_refresh_list()

func _refresh_list() -> void:
	level_list.clear()
	shown.clear()
	for i in index.size():
		var e: Dictionary = index[i]
		var label := "%d  %s" % [i, str(e.get("name", e.get("id")))]
		if filter != "" and filter not in label.to_lower(): continue
		shown.append(i)
		level_list.add_item(label)
		level_list.set_item_tooltip(level_list.item_count - 1, str(e.get("file", "")))
		if i == current:
			level_list.select(level_list.item_count - 1)

func _on_list_pick(row: int) -> void:
	var i: int = shown[row]
	if i == current: return
	if dirty: save()
	_open(i)

func _open(i: int) -> void:
	if index.is_empty(): return
	current = clampi(i, 0, index.size() - 1)
	data = JSON.parse_string(FileAccess.get_file_as_string(GAME.path_join("levels/" + str(index[current].file))))
	grid_size = int(data.get("size", data.grid.size()))
	grid = []
	for z in grid_size:
		var row: String = data.grid[z] if z < data.grid.size() else ""
		var arr := []
		for x in grid_size:
			arr.append(row[x] if x < row.length() else WALL)
		grid.append(arr)
	zones = {}
	for z in ZONES:
		zones[z] = {}
		for c in data.get("zones", {}).get(z, []):
			zones[z][Vector2i(c[0], c[1])] = true
	markers = {}
	for m in MARKERS:
		var c = data.get(m)
		markers[m] = Vector2i(c[0], c[1]) if c is Array and c.size() >= 2 else null
	objects = []
	for o in data.get("objects", []):
		if o is Dictionary and str(o.get("type", "")) in OBJ_TYPES:
			objects.append({"type": str(o.type), "pos_x": float(o.get("pos_x", 0.0)), "pos_y": float(o.get("pos_y", 0.0)),
				"rotation": float(o.get("rotation", 0.0)), "scale": clampf(float(o.get("scale", 1.0)), 0.5, 4.0)})
	var migrated := _migrate_legacy()
	selected = -1
	hover_obj = -1
	drag = ""
	materials = data.get("materials", {}).duplicate()
	for slot in SLOTS:
		var idx := pbr_names.find(str(materials.get(slot, "")))
		(slot_picks[slot] as OptionButton).select(idx + 1 if idx >= 0 else 0)
		_preview(slot)
	size_spin.value = grid_size
	gi_pick.select(0 if not data.has("sdfgi") else (1 if data["sdfgi"] else 2))
	atmo_pick.select(maxi(0, ATMOS.find(str(data.get("atmosphere", "dim")))))
	undo_stack.clear()
	dirty = false
	_refresh_list()
	_fit()
	_update_title()
	_sync_inspector()
	_status("Opened " + str(index[current].file) + ("   (%d old door / arch / thin wall tiles are objects now; save to keep)" % migrated if migrated > 0 else ""))

## v1 levels painted thin walls, arches and doors as tiles. Turn each into an object facing the way its
## corridor runs (the same rule the game's level_data.gd open_axis() uses), leaving a wall under a door /
## thin wall and floor under an arch, so the level plays exactly as before.
func _migrate_legacy() -> int:
	var solid := func(c: Vector2i) -> bool:
		return c.x <= 0 or c.y <= 0 or c.x >= grid_size - 1 or c.y >= grid_size - 1 or grid[c.y][c.x] in [WALL, THIN, DOOR]
	var found := {}
	for z in grid_size:
		for x in grid_size:
			var ch: String = grid[z][x]
			if ch not in [THIN, ARCH, DOOR]: continue
			var c := Vector2i(x, z)
			var ew: bool = not solid.call(c + Vector2i(1, 0)) and not solid.call(c + Vector2i(-1, 0))
			var ns: bool = not solid.call(c + Vector2i(0, 1)) and not solid.call(c + Vector2i(0, -1))
			var t := "thin_wall" if ch == THIN else ("arch" if ch == ARCH else "door")
			objects.append({"type": t, "pos_x": float(x), "pos_y": float(z), "rotation": 90.0 if (ns and not ew) else 0.0, "scale": 1.0})
			found[c] = ch
	for c: Vector2i in found:
		grid[c.y][c.x] = FLOOR if found[c] == ARCH else WALL
	return found.size()

func _update_title() -> void:
	if current < 0: return
	title_label.text = "%s%s" % [str(index[current].get("name", "")), "  *" if dirty else ""]
	title_label.add_theme_color_override("font_color", RED if dirty else CREAM)
	_update_info()

func _update_info() -> void:
	var open_cells := 0
	for row in grid:
		for ch in row:
			if ch == FLOOR or ch == ARCH: open_cells += 1
	var warn := []
	for m in ["spawn", "exit"]:
		if markers.get(m) == null: warn.append("no " + m)
	info.text = "%dx%d   %d open   %d objects   %s" % [grid_size, grid_size, open_cells, objects.size(), ("WARN: " + ", ".join(warn)) if not warn.is_empty() else "OK"]
	info.add_theme_color_override("font_color", RED if not warn.is_empty() else DIM)

# ---------------------------------------------------------------- smart naming
func _next_level_number() -> int:
	var n := 0
	var re := RegEx.create_from_string("(?i)level\\s*(\\d+)")
	for e in index:
		var m := re.search(str(e.get("name", "")))
		if m: n = maxi(n, int(m.get_string(1)) + 1)
	return maxi(n, index.size())

func _suggest_name() -> String:
	var n := _next_level_number()
	var used := ", ".join(index.map(func(e): return str(e.get("name", ""))))
	for w in NAME_WORDS:
		var cand: String = w if w != "Sector" else "Sector %d" % n
		if cand not in used:
			return "Level %d: %s" % [n, cand]
	return "Level %d: Sector %d" % [n, n]

func _slug(nm: String) -> String:
	var s := ""
	for ch in nm.to_lower():
		s += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	while "__" in s: s = s.replace("__", "_")
	s = s.trim_prefix("_").trim_suffix("_")
	return s if s != "" else "level"

func _unique_id(base: String) -> String:
	var ids := index.map(func(e): return str(e.get("id", "")))
	var id := base
	var k := 2
	while id in ids or FileAccess.file_exists(GAME.path_join("levels/%s.lvl" % id)):
		id = "%s_%d" % [base, k]
		k += 1
	return id

func _ask_new() -> void:
	name_mode = "new"
	name_dialog.title = "NEW LEVEL"
	name_edit.text = _suggest_name()
	_show_name()

func _ask_dup() -> void:
	if current < 0: return
	name_mode = "dup"
	name_dialog.title = "DUPLICATE LEVEL"
	name_edit.text = str(index[current].name) + " copy"
	_show_name()

func _ask_rename() -> void:
	if current < 0: return
	name_mode = "rename"
	name_dialog.title = "RENAME LEVEL"
	name_edit.text = str(index[current].name)
	_show_name()

func _show_name() -> void:
	_update_name_hint()
	name_dialog.popup_centered()
	name_edit.grab_focus()
	name_edit.select_all()

func _update_name_hint() -> void:
	var t := name_edit.text.strip_edges()
	name_hint.text = ("file: %s.lvl" % _unique_id(_slug(t))) if name_mode != "rename" else "file name stays the same"
	name_dialog.get_ok_button().disabled = t == ""

func _on_name_confirmed() -> void:
	var nm := name_edit.text.strip_edges()
	if nm == "": return
	if name_mode == "rename":
		index[current]["name"] = nm
		data["name"] = nm
		_write(GAME.path_join("levels/levels.json"), index)
		_write(GAME.path_join("levels/" + str(index[current].file)), _current_payload())
		_refresh_list()
		_update_title()
		return
	if dirty: save()
	var id := _unique_id(_slug(nm))
	var lvl: Dictionary
	if name_mode == "dup":
		lvl = _current_payload()
		lvl["name"] = nm
	else:
		lvl = _blank_level(nm)
	_write(GAME.path_join("levels/%s.lvl" % id), lvl)
	index.append({"id": id, "name": nm, "file": id + ".lvl"})
	_write(GAME.path_join("levels/levels.json"), index)
	current = index.size() - 1
	_open(current)

func _blank_level(nm: String) -> Dictionary:
	var s := 46
	var g: Array = []
	for z in s:
		var row := ""
		for x in s:
			row += WALL if (x == 0 or z == 0 or x == s - 1 or z == s - 1) else FLOOR
		g.append(row)
	return {"format": "backrooms_level", "version": 2, "name": nm, "size": s, "spawn": [4, 4], "exit": [s - 5, s - 5],
		"entity": [s / 2, s / 2], "tv": null, "grid": g, "zones": {}, "objects": []}

func _ask_delete() -> void:
	if current < 0 or index.size() <= 1:
		_status("Cannot delete the only level")
		return
	delete_dialog.title = "DELETE LEVEL"
	delete_dialog.dialog_text = "Delete '%s' and its file?\nThis cannot be undone." % str(index[current].name)
	delete_dialog.popup_centered()

func _delete_current() -> void:
	DirAccess.remove_absolute(GAME.path_join("levels/" + str(index[current].file)))
	index.remove_at(current)
	_write(GAME.path_join("levels/levels.json"), index)
	dirty = false
	_open(clampi(current, 0, index.size() - 1))

func _move(d: int) -> void:
	var j := current + d
	if current < 0 or j < 0 or j >= index.size(): return
	var e = index[current]
	index[current] = index[j]
	index[j] = e
	current = j
	_write(GAME.path_join("levels/levels.json"), index)
	_refresh_list()
	_status("Moved to position %d" % j)

# ---------------------------------------------------------------- test play
const CFG := "user://editor.cfg"

func _godot_path() -> String:
	var env := OS.get_environment("GODOT_EXE")
	if env != "": return env
	var cfg := ConfigFile.new()
	if cfg.load(CFG) == OK and FileAccess.file_exists(str(cfg.get_value("godot", "path", ""))):
		return str(cfg.get_value("godot", "path"))
	if OS.has_feature("editor"):
		return OS.get_executable_path()        # running from the Godot editor: it is Godot itself
	return ""

func _save_godot_path(p: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("godot", "path", p)
	cfg.save(CFG)

## Save, then launch the game straight into this level with noclip on
func _test_level() -> void:
	if current < 0: return
	var exe := _godot_path()
	if exe == "":
		godot_dialog.popup_centered_ratio(0.6)
		return
	save()
	var args := ["--path", GAME, "--", "--test-level=" + str(index[current].id), "--noclip"]
	var pid := OS.create_process(exe, args)
	_status("Testing %s in noclip (WASD, Space up, C down, Shift fast)" % str(index[current].name) if pid > 0 else "Could not start " + exe)

# ---------------------------------------------------------------- save
func _current_payload() -> Dictionary:
	var g: Array = []
	for row in grid:
		g.append("".join(PackedStringArray(row)))
	var out := data.duplicate()
	out["version"] = 2                   # v2: doors / arches / thin walls live in "objects", not the grid
	out["size"] = grid_size
	out["grid"] = g
	var objs := []
	for o: Dictionary in objects:
		objs.append({"type": o.type, "pos_x": snappedf(o.pos_x, 0.001), "pos_y": snappedf(o.pos_y, 0.001),
			"rotation": snappedf(fposmod(o.rotation, 360.0), 0.01), "scale": snappedf(o.scale, 0.001)})
	out["objects"] = objs
	var zd := {}
	for z in ZONES:
		var list := []
		for c: Vector2i in zones[z]:
			if grid[c.y][c.x] not in [WALL, THIN, DOOR]: list.append([c.x, c.y])
		list.sort_custom(func(a, b): return a[1] < b[1] or (a[1] == b[1] and a[0] < b[0]))
		zd[z] = list
	out["zones"] = zd
	match gi_pick.selected:
		1: out["sdfgi"] = true
		2: out["sdfgi"] = false
		_: out.erase("sdfgi")
	if atmo_pick.selected <= 0: out.erase("atmosphere")
	else: out["atmosphere"] = ATMOS[atmo_pick.selected]
	for m in MARKERS:
		out[m] = [markers[m].x, markers[m].y] if markers[m] != null else null
	var mats := {}
	for slot in SLOTS:
		if str(materials.get(slot, "")) != "": mats[slot] = materials[slot]
	if mats.is_empty(): out.erase("materials")
	else: out["materials"] = mats
	return out

func save() -> void:
	if current < 0: return
	data = _current_payload()
	_write(GAME.path_join("levels/" + str(index[current].file)), data)
	dirty = false
	_update_title()
	_status("Saved " + str(index[current].file))

func _write(path: String, payload) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status("Cannot write " + path)
		return
	f.store_string(JSON.stringify(payload, "  ") + "\n")

func _resize(n: int) -> void:
	_push_undo()
	var ng: Array = []
	for z in n:
		var row := []
		for x in n:
			var edge := x == 0 or z == 0 or x == n - 1 or z == n - 1
			row.append(WALL if edge or z >= grid_size or x >= grid_size else grid[z][x])
		ng.append(row)
	grid = ng
	grid_size = n
	for zn in zones:
		for c: Vector2i in zones[zn].keys():
			if c.x >= n - 1 or c.y >= n - 1: zones[zn].erase(c)
	for m in markers:
		var c = markers[m]
		if c != null and (c.x >= n - 1 or c.y >= n - 1): markers[m] = null
	objects = objects.filter(func(o): return o.pos_x <= n - 1 and o.pos_y <= n - 1)
	selected = -1
	_sync_inspector()
	_mark_dirty()
	_fit()

func _mark_dirty() -> void:
	dirty = true
	_update_title()
	canvas.queue_redraw()

# ---------------------------------------------------------------- materials
func _set_material(slot: String, id: String) -> void:
	materials[slot] = id
	_preview(slot)
	_mark_dirty()

func _preview(slot: String) -> void:
	var id := str(materials.get(slot, ""))
	var path := GAME.path_join("textures/pbr/%s/%s_Color.jpg" % [id, id])
	if not FileAccess.file_exists(path):
		path = path.get_basename() + ".png"
	var tex: Texture2D = null
	if id != "" and FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null:
			img.resize(192, 192)
			tex = ImageTexture.create_from_image(img)
	(slot_previews[slot] as TextureRect).texture = tex

# ---------------------------------------------------------------- canvas
func _fit() -> void:
	if canvas == null: return
	zoom = clampf(minf(canvas.size.x, canvas.size.y) / maxf(grid_size, 1) * 0.96, 6.0, 40.0)
	pan = (canvas.size - Vector2(grid_size, grid_size) * zoom) / 2.0
	canvas.queue_redraw()

func _cell_at(p: Vector2) -> Vector2i:
	var q := (p - pan) / zoom
	return Vector2i(floori(q.x), floori(q.y))

func _draw_canvas() -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), Color("080704"))
	for z in grid_size:
		for x in grid_size:
			canvas.draw_rect(Rect2(pan + Vector2(x, z) * zoom, Vector2(zoom, zoom)), BASE_COLORS.get(grid[z][x], Color.BLACK))
	for zn in ZONES:
		var col: Color = ZONES[zn]
		col.a = 0.5
		for c: Vector2i in zones[zn]:
			canvas.draw_rect(Rect2(pan + Vector2(c) * zoom + Vector2.ONE, Vector2(zoom, zoom) - Vector2(2, 2)), col)
	if zoom >= 10.0:
		for i in grid_size + 1:
			canvas.draw_line(pan + Vector2(i, 0) * zoom, pan + Vector2(i, grid_size) * zoom, Color(0, 0, 0, 0.3))
			canvas.draw_line(pan + Vector2(0, i) * zoom, pan + Vector2(grid_size, i) * zoom, Color(0, 0, 0, 0.3))
	for o: Dictionary in objects:
		_draw_object(o, 1.0)
	for m in MARKERS:
		var c = markers[m]
		if c != null:
			var p: Vector2 = pan + (Vector2(c) + Vector2(0.5, 0.5)) * zoom
			canvas.draw_circle(p, zoom * 0.42, MARKERS[m])
			canvas.draw_arc(p, zoom * 0.42, 0, TAU, 20, Color.BLACK, 1.5)
			canvas.draw_string(font, p + Vector2(-zoom * 0.2, zoom * 0.2), m.substr(0, 1).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, int(zoom * 0.6), Color.BLACK)
	if _object_tool():
		if hover_obj >= 0 and hover_obj != selected and drag == "":
			_draw_outline(objects[hover_obj], Color(SEL, 0.6), 1.5)
		elif hover.x >= 0 and hover_obj < 0 and drag == "" and tool.begins_with("obj:"):
			var p := _snap_pos(_pos_at(mouse_px))           # ghost of what a click would place
			var ghost := {"type": tool.get_slice(":", 1), "pos_x": p.x, "pos_y": p.y, "rotation": place_rot, "scale": place_scale}
			_draw_object(ghost, 0.45)
			_draw_arrow(ghost, Color(SEL, 0.5))
	elif hover.x >= 0 and not tool.begins_with("mark:"):
		var half := brush / 2
		for dz in brush:
			for dx in brush:
				var c := hover + Vector2i(dx - half, dz - half)
				canvas.draw_rect(Rect2(pan + Vector2(c) * zoom, Vector2(zoom, zoom)), Color(1, 1, 1, 0.22))
	elif hover.x >= 0:
		canvas.draw_rect(Rect2(pan + Vector2(hover) * zoom, Vector2(zoom, zoom)), Color(1, 1, 1, 0.3))
	if selected >= 0:
		_draw_gizmo(objects[selected])
	canvas.draw_rect(Rect2(pan, Vector2(grid_size, grid_size) * zoom), GOLD, false, 1.5)

func _canvas_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var before := (mb.position - pan) / zoom
			zoom = clampf(zoom * (1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12), 4.0, 60.0)
			pan = mb.position - before * zoom
			canvas.queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT and space_down:
			panning = mb.pressed
		elif (mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT) and _object_tool():
			_object_press(mb)
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			painting = mb.pressed
			erasing = mb.button_index == MOUSE_BUTTON_RIGHT
			if mb.pressed:
				_push_undo()
				_apply(_cell_at(mb.position))
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		mouse_px = mm.position
		if panning:
			pan += mm.relative
		elif drag != "":
			_object_drag(mm.position)
		elif painting:
			_apply(_cell_at(mm.position))
		var c := _cell_at(mm.position)
		hover = c if c.x >= 0 and c.y >= 0 and c.x < grid_size and c.y < grid_size else Vector2i(-1, -1)
		hover_obj = _obj_at(mm.position) if _object_tool() and drag == "" else -1
		canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
		if _object_tool() and (_on_handle(mm.position) or drag == "rotate"):
			canvas.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		elif _object_tool() and (hover_obj >= 0 or drag == "move"):
			canvas.mouse_default_cursor_shape = Control.CURSOR_MOVE
		if drag != "" and selected >= 0:
			_status(_describe(objects[selected]))
		elif hover_obj >= 0:
			_status(_describe(objects[hover_obj]) + "   click to select, drag to move, right click deletes")
		elif hover.x >= 0:
			var tags := []
			for z in ZONES:
				if zones[z].has(hover): tags.append(z)
			var p := _pos_at(mm.position)
			_status("cell %d, %d   (%.2f, %.2f)   %s" % [hover.x, hover.y, p.x, p.y, ",".join(tags)])
		canvas.queue_redraw()

func _apply(c: Vector2i) -> void:
	var kind := tool.get_slice(":", 0)
	var what := tool.get_slice(":", 1)
	if kind == "mark":
		if c.x >= 1 and c.y >= 1 and c.x < grid_size - 1 and c.y < grid_size - 1:
			markers[what] = null if erasing else c
		_mark_dirty()
		return
	var half := brush / 2
	for dz in brush:
		for dx in brush:
			var p := c + Vector2i(dx - half, dz - half)
			if p.x < 1 or p.y < 1 or p.x >= grid_size - 1 or p.y >= grid_size - 1: continue
			if kind == "base":
				grid[p.y][p.x] = (FLOOR if what == WALL else WALL) if erasing else what
				if grid[p.y][p.x] == WALL:      # solid cells: the game drops any zone tag on load
					for z in zones: zones[z].erase(p)
			elif kind == "zone" and grid[p.y][p.x] != WALL:
				if erasing: zones[what].erase(p)
				else: zones[what][p] = true
	_mark_dirty()

func _push_undo() -> void:
	var z := {}
	for k in zones: z[k] = zones[k].duplicate()
	undo_stack.append({"grid": grid.duplicate(true), "zones": z, "markers": markers.duplicate(), "size": grid_size,
		"objects": objects.duplicate(true), "selected": selected})
	if undo_stack.size() > 80: undo_stack.pop_front()
	insp_undo = -1

func _undo() -> void:
	if undo_stack.is_empty(): return
	var s: Dictionary = undo_stack.pop_back()
	grid = s.grid
	zones = s.zones
	markers = s.markers
	grid_size = s.size
	objects = s.objects
	selected = s.selected if s.selected < objects.size() else -1
	drag = ""
	_sync_inspector()
	_mark_dirty()

# ---------------------------------------------------------------- objects
func _object_tool() -> bool:
	return tool == "select" or tool.begins_with("obj:")

## Canvas pixels -> object space (cells, a cell's centre on a whole number)
func _pos_at(p: Vector2) -> Vector2:
	return (p - pan) / zoom - Vector2(0.5, 0.5)

func _snap_pos(v: Vector2) -> Vector2:
	if snap and not Input.is_key_pressed(KEY_ALT):
		v = (v / SNAP_STEP).round() * SNAP_STEP
	return v.clamp(Vector2.ZERO, Vector2(grid_size - 1, grid_size - 1))

## 90° steps with rotation snap on, otherwise free; Shift steps 15°, Alt ignores snapping
func _snap_rot(deg: float) -> float:
	var step := 1.0
	if Input.is_key_pressed(KEY_SHIFT): step = 15.0
	elif rot_snap and not Input.is_key_pressed(KEY_ALT): step = 90.0
	return fposmod(snappedf(deg, step), 360.0)

## Object space -> canvas pixels. Local x = the way it faces, local y = its span, both in cells * zoom.
func _obj_xf(o: Dictionary) -> Transform2D:
	return Transform2D(deg_to_rad(o.rotation), pan + (Vector2(o.pos_x, o.pos_y) + Vector2(0.5, 0.5)) * zoom)

## Footprint depth along local x, in cells (at least a few pixels, so thin pieces stay clickable)
func _obj_depth(o: Dictionary) -> float:
	return maxf(1.0 if o.type == "arch" else THIN_C, 4.0 / zoom)

func _obj_at(p: Vector2) -> int:
	for i in range(objects.size() - 1, -1, -1):
		var o: Dictionary = objects[i]
		var l := (_obj_xf(o).affine_inverse() * p) / zoom
		if absf(l.x) <= maxf(_obj_depth(o) * 0.5, 6.0 / zoom) and absf(l.y) <= o.scale * 0.5 + 2.0 / zoom:
			return i
	return -1

## The rotate handle: a knob just past the facing arrow's tip
func _handle_px(o: Dictionary) -> Vector2:
	var xf := _obj_xf(o)
	return xf.origin + xf.x.normalized() * (_obj_depth(o) * 0.5 * zoom + maxf(zoom * 0.8, 26.0) + 9.0)

func _on_handle(p: Vector2) -> bool:
	return selected >= 0 and p.distance_to(_handle_px(objects[selected])) <= 9.0

func _object_press(mb: InputEventMouseButton) -> void:
	if not mb.pressed:
		if drag != "":
			drag = ""
			_sync_inspector()
		return
	var i := _obj_at(mb.position)
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if i >= 0:
			_push_undo()
			_delete_object(i)
		return
	if _on_handle(mb.position):
		_push_undo()
		drag = "rotate"
	elif i >= 0:
		_select(i)
		_push_undo()
		var o: Dictionary = objects[i]
		drag_off = Vector2(o.pos_x, o.pos_y) - _pos_at(mb.position)
		drag = "move"
	elif tool == "select":
		_select(-1)
	else:
		_push_undo()
		var p := _snap_pos(_pos_at(mb.position))
		objects.append({"type": tool.get_slice(":", 1), "pos_x": p.x, "pos_y": p.y, "rotation": place_rot, "scale": place_scale})
		_select(objects.size() - 1)
		drag = "place"                   # keep the button down and drag away to aim it
		_mark_dirty()

func _object_drag(p: Vector2) -> void:
	if selected < 0:
		drag = ""
		return
	var o: Dictionary = objects[selected]
	if drag == "move":
		var q := _snap_pos(_pos_at(p) + drag_off)
		o.pos_x = q.x
		o.pos_y = q.y
	else:
		var v := p - _obj_xf(o).origin
		if drag == "place" and v.length() < maxf(zoom * 0.5, 12.0): return    # a plain click keeps place_rot
		o.rotation = _snap_rot(rad_to_deg(v.angle()))
		place_rot = o.rotation
	_sync_inspector()
	_mark_dirty()

func _select(i: int) -> void:
	selected = i
	insp_undo = -1
	_sync_inspector()
	canvas.queue_redraw()

func _delete_object(i: int) -> void:
	objects.remove_at(i)
	if selected == i: selected = -1
	elif selected > i: selected -= 1
	hover_obj = -1
	_sync_inspector()
	_mark_dirty()

func _delete_selected() -> void:
	if selected < 0: return
	_push_undo()
	_delete_object(selected)

func _duplicate_selected() -> void:
	if selected < 0: return
	_push_undo()
	var o: Dictionary = objects[selected].duplicate()
	var off := SNAP_STEP if snap else 0.25
	o.pos_x = minf(o.pos_x + off, grid_size - 1)
	o.pos_y = minf(o.pos_y + off, grid_size - 1)
	objects.append(o)
	_select(objects.size() - 1)
	_mark_dirty()

## R / Shift+R and the inspector's buttons: turn the selection, or the next placement when nothing is selected
func _rotate_selected(deg: float) -> void:
	if selected < 0:
		place_rot = fposmod(place_rot + deg, 360.0)
		_status("placing at %s°" % _deg(place_rot))
		canvas.queue_redraw()
		return
	_push_undo()
	var o: Dictionary = objects[selected]
	o.rotation = fposmod(o.rotation + deg, 360.0)
	place_rot = o.rotation
	_sync_inspector()
	_mark_dirty()

## An inspector field changed. One undo step per object per round of edits, not one per keystroke.
func _set_prop(key: String, v) -> void:
	if selected < 0: return
	if insp_undo != selected:
		_push_undo()
		insp_undo = selected
	var o: Dictionary = objects[selected]
	o[key] = v
	match key:
		"rotation":
			o.rotation = fposmod(v, 360.0)
			place_rot = o.rotation
			insp_rot.set_value_no_signal(o.rotation)
		"scale":
			place_scale = v
	_mark_dirty()

func _sync_inspector() -> void:
	if insp == null: return
	insp.get_parent().visible = selected >= 0
	if selected < 0: return
	var o: Dictionary = objects[selected]
	insp_type.select(OBJ_TYPES.find(o.type))
	for sb: SpinBox in [insp_x, insp_y]: sb.max_value = grid_size - 1
	insp_x.set_value_no_signal(o.pos_x)
	insp_y.set_value_no_signal(o.pos_y)
	insp_rot.set_value_no_signal(o.rotation)
	insp_scale.set_value_no_signal(o.scale)

func _deg(d: float) -> String:
	return str(snappedf(d, 0.1)).trim_suffix(".0")

func _describe(o: Dictionary) -> String:
	return "%s   x %.2f   y %.2f   rotation %s°   width %.2f" % [OBJ_INFO[o.type].label, o.pos_x, o.pos_y, _deg(o.rotation), o.scale]

## A rectangle in the object's local space (cells), as canvas points
func _local_rect(xf: Transform2D, x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([xf * (Vector2(x0, y0) * zoom), xf * (Vector2(x1, y0) * zoom), xf * (Vector2(x1, y1) * zoom), xf * (Vector2(x0, y1) * zoom)])

func _fill(pts: PackedVector2Array, col: Color) -> void:
	canvas.draw_colored_polygon(pts, col)
	canvas.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0, 0, 0, col.a * 0.8), 1.0)

## Plan view of an object, the way an architect's floor plan draws it
func _draw_object(o: Dictionary, alpha: float) -> void:
	var xf := _obj_xf(o)
	var col: Color = OBJ_INFO[o.type].col
	col.a = alpha
	var half: float = o.scale * 0.5
	var t := maxf(THIN_C, 5.0 / zoom)
	match o.type:
		"thin_wall":
			_fill(_local_rect(xf, -t * 0.5, -half, t * 0.5, half), col)
		"door":
			# the partition either side of the doorway, the leaf (closed) and its swing either way
			var dw := DOOR_C * 0.5
			var wall_col := Color(OBJ_INFO.thin_wall.col, alpha)
			_fill(_local_rect(xf, -t * 0.5, -half, t * 0.5, -dw), wall_col)
			_fill(_local_rect(xf, -t * 0.5, dw, t * 0.5, half), wall_col)
			var hinge := xf * (Vector2(0, -dw) * zoom)
			canvas.draw_line(hinge, xf * (Vector2(0, dw) * zoom), col, maxf(2.0, zoom * 0.04))
			var a := deg_to_rad(o.rotation)
			canvas.draw_arc(hinge, DOOR_C * zoom, a, a + PI, 24, Color(col, alpha * 0.8), 1.5)
		"arch":
			# two pillars and the passage between them, dashed where the crown spans it
			_fill(_local_rect(xf, -0.5, -half, 0.5, -half + PILLAR_C), col)
			_fill(_local_rect(xf, -0.5, half - PILLAR_C, 0.5, half), col)
			for s: float in [-0.5, 0.5]:
				canvas.draw_dashed_line(xf * (Vector2(s, -half + PILLAR_C) * zoom), xf * (Vector2(s, half - PILLAR_C) * zoom),
					Color(col, alpha * 0.8), 1.5, maxf(zoom * 0.12, 3.0))

func _draw_outline(o: Dictionary, col: Color, width: float) -> void:
	var pad := 3.0 / zoom
	var hx := _obj_depth(o) * 0.5 + pad
	var hy: float = o.scale * 0.5 + pad
	var pts := _local_rect(_obj_xf(o), -hx, -hy, hx, hy)
	canvas.draw_polyline(pts + PackedVector2Array([pts[0]]), col, width)

## The facing arrow, out of the front along local +x (the way you walk through it)
func _draw_arrow(o: Dictionary, col: Color) -> void:
	var xf := _obj_xf(o)
	var dir := xf.x.normalized()
	var tip := xf.origin + dir * (_obj_depth(o) * 0.5 * zoom + maxf(zoom * 0.8, 26.0))
	var side := dir.orthogonal() * 5.0
	var head := PackedVector2Array([tip, tip - dir * 10.0 + side, tip - dir * 10.0 - side])
	canvas.draw_line(xf.origin, tip - dir * 6.0, Color(0, 0, 0, col.a * 0.7), 4.0)     # dark underlay for contrast
	canvas.draw_polyline(head + PackedVector2Array([head[0]]), Color(0, 0, 0, col.a * 0.7), 3.0)
	canvas.draw_line(xf.origin, tip - dir * 6.0, col, 2.0)
	canvas.draw_colored_polygon(head, col)

## Selection gizmo: bounding box, facing arrow, rotate handle with its angle, pivot, and a door's hinge
func _draw_gizmo(o: Dictionary) -> void:
	_draw_outline(o, Color(0, 0, 0, 0.7), 4.0)
	_draw_outline(o, SEL, 2.0)
	_draw_arrow(o, SEL)
	var h := _handle_px(o)
	var hot := drag == "rotate" or _on_handle(mouse_px)
	canvas.draw_circle(h, 6.0, Color.WHITE if hot else SEL)
	canvas.draw_arc(h, 6.0, 0, TAU, 16, Color.BLACK, 1.5)
	var label := "%s°" % _deg(o.rotation)
	var lp := h + Vector2(10, -8)
	canvas.draw_rect(Rect2(lp + Vector2(-3, -13), font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13) + Vector2(6, 4)), Color(0, 0, 0, 0.75))
	canvas.draw_string(font, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, SEL)
	var xf := _obj_xf(o)
	if o.type == "door":
		canvas.draw_circle(xf * (Vector2(0, -DOOR_C * 0.5) * zoom), 3.0, Color.WHITE)
	canvas.draw_circle(xf.origin, 2.5, SEL)

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
	match k.keycode:
		KEY_1: _select_tool("base:" + WALL)
		KEY_2: _select_tool("base:" + FLOOR)
		KEY_3: _select_tool("base:" + PIT)
		KEY_4: _select_tool("obj:thin_wall")
		KEY_5: _select_tool("obj:arch")
		KEY_6: _select_tool("obj:door")
		KEY_V: _select_tool("select")
		KEY_R: _rotate_selected(-90.0 if k.shift_pressed else 90.0)
		KEY_G: snap_check.button_pressed = not snap_check.button_pressed
		KEY_DELETE, KEY_BACKSPACE: _delete_selected()
		KEY_ESCAPE: _select(-1)
		KEY_BRACKETLEFT: _set_brush(brush - 1)
		KEY_BRACKETRIGHT: _set_brush(brush + 1)
		KEY_F: _fit()

func _status(t: String) -> void:
	if status: status.text = t
