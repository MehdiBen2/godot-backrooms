extends Control
## Standalone level editor: its own Godot project, not part of the game. Open level-editor/ in Godot
## (or export it) and run. It edits the game's levels/*.lvl and levels.json in place, including the
## per-level PBR "materials" ({wall, floor, ceiling, tiles} -> folders in the game's textures/pbr/).
## Set BACKROOMS_GAME_DIR to point at a different game folder.
##   left drag paint   right drag erase   middle drag / Space+drag pan   wheel zoom   F fit
##   1 2 3 wall/floor/pit   [ ] brush size   Ctrl+S save   Ctrl+Z undo   Ctrl+N new   Ctrl+D duplicate
##
## 3D mode (the "3D" button): freeform thin-wall panels from the imported kit (Assets/LoafbrrAssets/
## BackroomsLikeAsset2/Scenes/Wall), placed anywhere rather than snapped to the grid.
##   pick a piece on the right   left click empty ground places it   left click a piece selects it
##   left drag a selected piece moves it along the ground   Q / E rotate (Shift = 90 deg snap)
##   Page Up / Page Down raise / lower   Delete removes   right drag looks   WASD flies (Shift = fast)
##   wheel = fly speed

const CREAM := Color("e6e1cd")
const DIM := Color(0.9, 0.882, 0.804, 0.55)
const GOLD := Color("e6c65a")
const RED := Color("c4271f")
const BG := Color("0d0c08")
const PANEL := Color("16140d")
const LINE := Color("3a3522")

const WALL := "#"
const FLOOR := "."
const PIT := "O"
const ZONES := {"tall": Color("5a9bff"), "low": Color("ff8a3d"), "tiles": Color("f2f2f2"), "bright": Color("fff04a"),
	"dark": Color("7a2cff"), "dim": Color("8a6a3a"), "flicker": Color("ff3f9a"), "grime": Color("8a6a30"), "classic": Color("ffe86a")}
const ZONE_HELP := {"tall": "Huge atrium ceiling", "low": "Crouch-height ceiling", "tiles": "Tile floor instead of carpet",
	"bright": "Always lit, safe room", "dark": "All tubes dead", "dim": "Most tubes dead", "flicker": "Failing tubes", "grime": "Stained carpet", "classic": "Super bright classic backrooms: steady glowing tubes, clear air"}
const MARKERS := {"spawn": Color("2fd968"), "exit": Color("2fd9ee"), "entity": Color("ff3030"), "tv": Color("5c8dff")}
const BASE_COLORS := {WALL: Color("3f3a30"), FLOOR: Color("cdb86a"), PIT: Color("050505")}
const SLOTS := ["wall", "floor", "ceiling", "tiles"]
const NAME_WORDS := ["The Lobby", "Habitable Zone", "Sector", "Annex", "Storage", "Maintenance", "Threshold", "Pool Rooms", "Stairwell", "Office"]

# ---- 3D thin-wall placement mode ----
const CELL_3D := 4.5          # must match level_data.gd's CELL
const WALL_H_3D := 5.4        # must match level_data.gd's WALL_H
const WALL_KIT_DIR := "res://Assets/LoafbrrAssets/BackroomsLikeAsset2/Scenes/Wall/"
const FLY_SPEED := 26.0
const LOOK_SENSITIVITY := 0.008
const PICK_RADIUS_PX := 26.0
const SELECT_TINT := Color(0.4, 0.9, 1.0)

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

# ---- 3D thin-wall placement mode ----
var thin_walls: Array = []           # [{piece, pos: Vector3, rot: float(deg)}]
var wall_pieces: Array = []          # piece names scanned from WALL_KIT_DIR
var selected_wall := -1
var active_piece := ""
var mode_3d := false
var view3d: SubViewportContainer
var sub_viewport: SubViewport
var cam3d: Camera3D
var cam_yaw := 0.0
var cam_pitch := -0.35
var fly_speed := FLY_SPEED
var looking := false
var dragging_wall := false
var context_root: Node3D              # grey-box preview of the grid, rebuilt per level
var walls_root: Node3D                # placed thin-wall instances
var ghost: Node3D                     # preview of the piece about to be placed
var wall_piece_scenes: Dictionary = {}  # piece name -> PackedScene (cached)
var mode_button: Button
var piece_buttons := {}

var font: FontFile = load("res://fonts/vcr.ttf")
var canvas: Control
var level_list: ItemList
var search: LineEdit
var size_spin: SpinBox
var gi_pick: OptionButton
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

func _ready() -> void:
	theme = _make_theme()
	_scan_pbr()
	_scan_wall_pieces()
	_build_ui()
	_load_index()
	_open(0)

func _scan_pbr() -> void:
	var d := DirAccess.open(GAME.path_join("textures/pbr"))
	if d == null: return
	for n in d.get_directories():
		pbr_names.append(n)
	pbr_names.sort()

func _scan_wall_pieces() -> void:
	var d := DirAccess.open(WALL_KIT_DIR)
	if d == null: return
	for f in d.get_files():
		if f.ends_with(".tscn"):
			wall_pieces.append(f.get_basename())
	wall_pieces.sort()
	# Plain "br_wall_a_3x_3" sorts after all the "br_wall_3x_..." trim/door-frame pieces (digits sort
	# before letters), so picking wall_pieces[0] as the default landed on a thin decorative trim strip
	# instead of an actual wall panel. Prefer a real full wall panel as the starting default.
	if wall_pieces.has("br_wall_a_3x_3"):
		active_piece = "br_wall_a_3x_3"
	elif not wall_pieces.is_empty():
		active_piece = wall_pieces[0]

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
	mode_button = _button("3D", _toggle_3d)
	mode_button.toggle_mode = true
	tb.add_child(mode_button)
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

	# center: canvas
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 0)
	body.add_child(mid)
	canvas = Control.new()
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.clip_contents = true
	canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
	canvas.draw.connect(_draw_canvas)
	canvas.gui_input.connect(_canvas_input)
	canvas.resized.connect(canvas.queue_redraw)
	mid.add_child(canvas)
	_build_3d_view(mid)

	# right: tools
	var right := _panel(290)
	body.add_child(right)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(side)
	side.add_child(_label("TERRAIN", 16, GOLD))
	var terrain := [[WALL, "Wall  (1)"], [FLOOR, "Floor  (2)"], [PIT, "Pit  (3)"]]
	for b in terrain:
		side.add_child(_tool_button("base:" + b[0], b[1], BASE_COLORS[b[0]], "Left paints, right erases"))
	var brow := HBoxContainer.new()
	side.add_child(brow)
	brow.add_child(_label("BRUSH ", 16, DIM))
	brow.add_child(_button("-", func(): _set_brush(brush - 1)))
	brush_label = _label(" 1 ", 16, CREAM)
	brow.add_child(brush_label)
	brow.add_child(_button("+", func(): _set_brush(brush + 1)))
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

	side.add_child(_label("THIN WALLS  (3D mode)", 16, GOLD))
	var wall_scroll := ScrollContainer.new()
	wall_scroll.custom_minimum_size = Vector2(0, 180)
	wall_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(wall_scroll)
	var wall_list := VBoxContainer.new()
	wall_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wall_scroll.add_child(wall_list)
	for p in wall_pieces:
		wall_list.add_child(_piece_button(p))
	side.add_child(_button("DELETE SELECTED  (Del)", _delete_selected_wall))

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

## Its own function (not inlined in the palette's `for` loop) because GDScript lambdas capture a
## `for` loop's variable by reference - every button's callback would otherwise fire with whatever
## `p` happened to be after the loop finished (the last piece), not the one that was clicked.
func _piece_button(p: String) -> Button:
	var b := Button.new()
	b.text = p.trim_prefix("br_wall_").replace("_", " ")
	b.tooltip_text = p + "  -  click empty ground in the 3D view to place"
	b.toggle_mode = true
	b.button_pressed = p == active_piece
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(func(): _select_piece(p))
	piece_buttons[p] = b
	return b

func _select_piece(p: String) -> void:
	active_piece = p
	for k in piece_buttons:
		piece_buttons[k].button_pressed = (k == p)
	if mode_3d: _update_ghost()

func _set_brush(n: int) -> void:
	brush = clampi(n, 1, 8)
	brush_label.text = " %d " % brush

# ---------------------------------------------------------------- 3D thin-wall mode
func _build_3d_view(mid: VBoxContainer) -> void:
	view3d = SubViewportContainer.new()
	view3d.stretch = true
	view3d.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view3d.visible = false
	view3d.gui_input.connect(_view3d_input)
	view3d.mouse_default_cursor_shape = Control.CURSOR_CROSS
	mid.add_child(view3d)

	sub_viewport = SubViewport.new()
	sub_viewport.world_3d = World3D.new()   # assign directly - own_world_3d alone can leave it null until the next frame
	sub_viewport.own_world_3d = true
	sub_viewport.handle_input_locally = false
	sub_viewport.size = Vector2i(1, 1)
	view3d.add_child(sub_viewport)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("0d0c08")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("d8d0b8")
	e.ambient_light_energy = 1.1
	env.environment = e
	sub_viewport.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-1.0, 0.6, 0.0)
	sun.light_energy = 1.8
	sub_viewport.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(-0.6, -2.4, 0.0)
	fill.light_energy = 0.7
	sub_viewport.add_child(fill)

	cam3d = Camera3D.new()
	cam3d.far = 400.0
	sub_viewport.add_child(cam3d)

	context_root = Node3D.new()
	sub_viewport.add_child(context_root)
	walls_root = Node3D.new()
	sub_viewport.add_child(walls_root)
	ghost = Node3D.new()
	sub_viewport.add_child(ghost)

func _toggle_3d() -> void:
	mode_3d = mode_button.button_pressed
	canvas.visible = not mode_3d
	view3d.visible = mode_3d
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	looking = false
	if mode_3d:
		sub_viewport.size = Vector2i(maxi(1, int(view3d.size.x)), maxi(1, int(view3d.size.y)))
		_rebuild_3d_context()
		_rebuild_3d_walls()
		_update_ghost()
		var center := float(grid_size) * 0.5 * CELL_3D
		cam3d.position = Vector3(center, WALL_H_3D * 1.5, center + 10.0)
		cam_yaw = 0.0
		cam_pitch = -0.5
		_apply_cam_rotation()
	else:
		canvas.queue_redraw()

func _apply_cam_rotation() -> void:
	cam3d.rotation = Vector3(cam_pitch, cam_yaw, 0.0)

# Cheap grey-box preview of the grid's walls/floor, just for spatial context while placing pieces.
func _rebuild_3d_context() -> void:
	for c in context_root.get_children(): c.free()
	var wall_cells: Array = []
	for z in grid_size:
		for x in grid_size:
			if grid[z][x] == WALL: wall_cells.append(Vector2i(x, z))
	if not wall_cells.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var box := BoxMesh.new()
		box.size = Vector3(CELL_3D, WALL_H_3D, CELL_3D)
		mm.mesh = box
		mm.instance_count = wall_cells.size()
		for i in wall_cells.size():
			var c: Vector2i = wall_cells[i]
			mm.set_instance_transform(i, Transform3D(Basis(), Vector3(c.x * CELL_3D, WALL_H_3D / 2.0, c.y * CELL_3D)))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color("55503c")
		mmi.material_override = m
		context_root.add_child(mmi)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	var extent := float(grid_size) * CELL_3D
	pm.size = Vector2(extent, extent)
	floor_mi.mesh = pm
	floor_mi.position = Vector3(extent / 2.0 - CELL_3D / 2.0, 0.0, extent / 2.0 - CELL_3D / 2.0)
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("2a2818")
	floor_mi.material_override = fm
	context_root.add_child(floor_mi)

func _load_wall_scene(piece: String) -> PackedScene:
	if not wall_piece_scenes.has(piece):
		var path := WALL_KIT_DIR + piece + ".tscn"
		wall_piece_scenes[piece] = load(path) if ResourceLoader.exists(path) else null
	return wall_piece_scenes[piece]

func _rebuild_3d_walls() -> void:
	for c in walls_root.get_children(): c.free()
	for i in thin_walls.size():
		_add_wall_instance(i)

func _add_wall_instance(i: int) -> void:
	var w: Dictionary = thin_walls[i]
	var scene := _load_wall_scene(str(w.get("piece", "")))
	if scene == null: return
	var inst := scene.instantiate() as Node3D
	inst.set_meta("wall_index", i)
	walls_root.add_child(inst)
	_refresh_wall_transform(i)

func _refresh_wall_transform(i: int) -> void:
	var inst := _wall_instance(i)
	if inst == null: return
	var w: Dictionary = thin_walls[i]
	var p: Vector3 = w.get("pos", Vector3.ZERO)
	inst.position = p
	inst.rotation.y = deg_to_rad(float(w.get("rot", 0.0)))

func _wall_instance(i: int) -> Node3D:
	for c in walls_root.get_children():
		if c.has_meta("wall_index") and int(c.get_meta("wall_index")) == i:
			return c as Node3D
	return null

func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D: return n
	for c in n.get_children():
		var m := _find_mesh(c)
		if m != null: return m
	return null

func _set_wall_highlight(i: int, on: bool) -> void:
	var inst := _wall_instance(i)
	if inst == null: return
	var mi := _find_mesh(inst)
	if mi == null: return
	if on:
		var m := StandardMaterial3D.new()
		m.albedo_color = SELECT_TINT
		m.emission_enabled = true
		m.emission = SELECT_TINT
		m.emission_energy_multiplier = 0.6
		mi.material_override = m
	else:
		mi.material_override = null

func _select_wall(i: int) -> void:
	if selected_wall == i: return
	if selected_wall >= 0: _set_wall_highlight(selected_wall, false)
	selected_wall = i
	if selected_wall >= 0: _set_wall_highlight(selected_wall, true)

func _delete_selected_wall() -> void:
	if selected_wall < 0 or selected_wall >= thin_walls.size(): return
	_push_undo()
	thin_walls.remove_at(selected_wall)
	selected_wall = -1
	_rebuild_3d_walls()          # indices shifted, cheapest to rebuild fully (also frees the old instance)
	_mark_dirty()

func _update_ghost() -> void:
	for c in ghost.get_children(): c.free()
	ghost.visible = false
	if active_piece == "": return
	var scene := _load_wall_scene(active_piece)
	if scene == null: return
	var inst := scene.instantiate() as Node3D
	var mi := _find_mesh(inst)
	if mi != null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1, 1, 1, 0.4)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mi.material_override = m
	for c in inst.get_children():
		if c is StaticBody3D: c.queue_free()   # no collision on the ghost
	ghost.add_child(inst)

# Pure math, no physics: a ray from the camera through `pos` intersected with the horizontal plane
# at `plane_y`. Avoids any dependency on the physics server having caught up with freshly added
# collision shapes, which made placement/selection flaky.
func _ray_plane(pos: Vector2, plane_y: float) -> Vector3:
	var from := cam3d.project_ray_origin(pos)
	var dir := cam3d.project_ray_normal(pos)
	if absf(dir.y) < 0.0001:
		return from + dir * 50.0
	var t := (plane_y - from.y) / dir.y
	return from + dir * (t if t > 0.0 else 50.0)

# Nearest placed piece to the click, in screen space, within PICK_RADIUS_PX - or -1 for empty ground.
func _pick_wall_at_screen(pos: Vector2) -> int:
	var best := -1
	var best_d := PICK_RADIUS_PX * PICK_RADIUS_PX
	for i in thin_walls.size():
		var w: Dictionary = thin_walls[i]
		var wp: Vector3 = w.pos + Vector3(0, 1.0, 0)
		if cam3d.is_position_behind(wp): continue
		var d := cam3d.unproject_position(wp).distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = i
	return best

func _view3d_input(ev: InputEvent) -> void:
	if not mode_3d: return
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			looking = mb.pressed
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if looking else Input.MOUSE_MODE_VISIBLE)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			fly_speed = clampf(fly_speed * 1.25, 2.0, 150.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			fly_speed = clampf(fly_speed / 1.25, 2.0, 150.0)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var idx := _pick_wall_at_screen(mb.position)
				if idx >= 0:
					_select_wall(idx)
					dragging_wall = true
				elif active_piece != "":
					_push_undo()
					thin_walls.append({"piece": active_piece, "pos": _ray_plane(mb.position, 0.0), "rot": 0.0})
					_add_wall_instance(thin_walls.size() - 1)
					_select_wall(thin_walls.size() - 1)
					_mark_dirty()
			else:
				dragging_wall = false
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if looking:
			cam_yaw -= mm.relative.x * LOOK_SENSITIVITY
			cam_pitch = clampf(cam_pitch - mm.relative.y * LOOK_SENSITIVITY, -1.5, 1.5)
			_apply_cam_rotation()
		elif dragging_wall and selected_wall >= 0:
			var w: Dictionary = thin_walls[selected_wall]
			var p: Vector3 = w.pos
			w["pos"] = _ray_plane(mm.position, p.y)
			_refresh_wall_transform(selected_wall)
			_mark_dirty()
		else:
			ghost.visible = active_piece != "" and _pick_wall_at_screen(mm.position) < 0
			if ghost.visible: ghost.position = _ray_plane(mm.position, 0.0)

func _process(delta: float) -> void:
	if not mode_3d or cam3d == null: return
	var v := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): v.z -= 1.0
	if Input.is_key_pressed(KEY_S): v.z += 1.0
	if Input.is_key_pressed(KEY_A): v.x -= 1.0
	if Input.is_key_pressed(KEY_D): v.x += 1.0
	if Input.is_key_pressed(KEY_E) and not selected_wall_key_active(): v.y += 1.0
	if Input.is_key_pressed(KEY_Q) and not selected_wall_key_active(): v.y -= 1.0
	if v != Vector3.ZERO:
		var boost := 3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		cam3d.position += cam3d.global_transform.basis * v.normalized() * fly_speed * boost * delta

func selected_wall_key_active() -> bool:
	return selected_wall >= 0        # Q/E rotate the selection instead of flying vertically when one is picked

func _rotate_selected(delta_deg: float) -> void:
	if selected_wall < 0: return
	_push_undo()
	var w: Dictionary = thin_walls[selected_wall]
	w["rot"] = fmod(float(w.get("rot", 0.0)) + delta_deg + 360.0, 360.0)
	_refresh_wall_transform(selected_wall)
	_mark_dirty()

func _raise_selected(delta_y: float) -> void:
	if selected_wall < 0: return
	_push_undo()
	var w: Dictionary = thin_walls[selected_wall]
	var p: Vector3 = w.get("pos", Vector3.ZERO)
	w["pos"] = p + Vector3(0, delta_y, 0)
	_refresh_wall_transform(selected_wall)
	_mark_dirty()

func _fit_3d() -> void:
	if cam3d == null: return
	var center := float(grid_size) * 0.5 * CELL_3D
	cam3d.position = Vector3(center, WALL_H_3D * 1.5, center + 10.0)
	cam_yaw = 0.0
	cam_pitch = -0.5
	_apply_cam_rotation()

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
	materials = data.get("materials", {}).duplicate()
	thin_walls = []
	for w in data.get("thin_walls", []):
		var p: Array = w.get("pos", [0.0, 0.0, 0.0])
		thin_walls.append({"piece": str(w.get("piece", "")), "pos": Vector3(p[0], p[1], p[2]), "rot": float(w.get("rot", 0.0))})
	selected_wall = -1
	if mode_3d:
		_rebuild_3d_context()
		_rebuild_3d_walls()
	for slot in SLOTS:
		var idx := pbr_names.find(str(materials.get(slot, "")))
		(slot_picks[slot] as OptionButton).select(idx + 1 if idx >= 0 else 0)
		_preview(slot)
	size_spin.value = grid_size
	gi_pick.select(0 if not data.has("sdfgi") else (1 if data["sdfgi"] else 2))
	undo_stack.clear()
	dirty = false
	_refresh_list()
	_fit()
	_update_title()
	_status("Opened " + str(index[current].file))

func _update_title() -> void:
	if current < 0: return
	title_label.text = "%s%s" % [str(index[current].get("name", "")), "  *" if dirty else ""]
	title_label.add_theme_color_override("font_color", RED if dirty else CREAM)
	_update_info()

func _update_info() -> void:
	var open_cells := 0
	for row in grid:
		for ch in row:
			if ch == FLOOR: open_cells += 1
	var warn := []
	for m in ["spawn", "exit"]:
		if markers.get(m) == null: warn.append("no " + m)
	info.text = "%dx%d   %d open   %s" % [grid_size, grid_size, open_cells, ("WARN: " + ", ".join(warn)) if not warn.is_empty() else "OK"]
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
	return {"format": "backrooms_level", "version": 1, "name": nm, "size": s, "spawn": [4, 4], "exit": [s - 5, s - 5],
		"entity": [s / 2, s / 2], "tv": null, "grid": g, "zones": {}}

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
	out["size"] = grid_size
	out["grid"] = g
	var zd := {}
	for z in ZONES:
		var list := []
		for c: Vector2i in zones[z]:
			if grid[c.y][c.x] != WALL: list.append([c.x, c.y])
		list.sort_custom(func(a, b): return a[1] < b[1] or (a[1] == b[1] and a[0] < b[0]))
		zd[z] = list
	out["zones"] = zd
	match gi_pick.selected:
		1: out["sdfgi"] = true
		2: out["sdfgi"] = false
		_: out.erase("sdfgi")
	for m in MARKERS:
		out[m] = [markers[m].x, markers[m].y] if markers[m] != null else null
	var mats := {}
	for slot in SLOTS:
		if str(materials.get(slot, "")) != "": mats[slot] = materials[slot]
	if mats.is_empty(): out.erase("materials")
	else: out["materials"] = mats
	if thin_walls.is_empty():
		out.erase("thin_walls")
	else:
		var tw := []
		for w in thin_walls:
			var p: Vector3 = w.pos
			tw.append({"piece": w.piece, "pos": [p.x, p.y, p.z], "rot": w.rot})
		out["thin_walls"] = tw
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
	if mode_3d: _rebuild_3d_context()
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
	for m in MARKERS:
		var c = markers[m]
		if c != null:
			var p: Vector2 = pan + (Vector2(c) + Vector2(0.5, 0.5)) * zoom
			canvas.draw_circle(p, zoom * 0.42, MARKERS[m])
			canvas.draw_arc(p, zoom * 0.42, 0, TAU, 20, Color.BLACK, 1.5)
			canvas.draw_string(font, p + Vector2(-zoom * 0.2, zoom * 0.2), m.substr(0, 1).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, int(zoom * 0.6), Color.BLACK)
	for w in thin_walls:
		var p: Vector3 = w.pos
		var center := pan + Vector2(p.x, p.z) / CELL_3D * zoom
		var dir := Vector2.RIGHT.rotated(deg_to_rad(float(w.rot))) * zoom * 0.5
		canvas.draw_line(center - dir, center + dir, Color("8fd8ff"), 2.0)
	if hover.x >= 0 and not tool.begins_with("mark:"):
		var half := brush / 2
		for dz in brush:
			for dx in brush:
				var c := hover + Vector2i(dx - half, dz - half)
				canvas.draw_rect(Rect2(pan + Vector2(c) * zoom, Vector2(zoom, zoom)), Color(1, 1, 1, 0.22))
	elif hover.x >= 0:
		canvas.draw_rect(Rect2(pan + Vector2(hover) * zoom, Vector2(zoom, zoom)), Color(1, 1, 1, 0.3))
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
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			painting = mb.pressed
			erasing = mb.button_index == MOUSE_BUTTON_RIGHT
			if mb.pressed:
				_push_undo()
				_apply(_cell_at(mb.position))
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if panning:
			pan += mm.relative
		elif painting:
			_apply(_cell_at(mm.position))
		var c := _cell_at(mm.position)
		hover = c if c.x >= 0 and c.y >= 0 and c.x < grid_size and c.y < grid_size else Vector2i(-1, -1)
		if hover.x >= 0:
			var tags := []
			for z in ZONES:
				if zones[z].has(hover): tags.append(z)
			_status("cell %d, %d   %s" % [hover.x, hover.y, ",".join(tags)])
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
				if grid[p.y][p.x] == WALL:
					for z in zones: zones[z].erase(p)
			elif kind == "zone" and grid[p.y][p.x] != WALL:
				if erasing: zones[what].erase(p)
				else: zones[what][p] = true
	_mark_dirty()

func _push_undo() -> void:
	var z := {}
	for k in zones: z[k] = zones[k].duplicate()
	var tw := []
	for w in thin_walls: tw.append(w.duplicate())
	undo_stack.append({"grid": grid.duplicate(true), "zones": z, "markers": markers.duplicate(), "size": grid_size, "thin_walls": tw})
	if undo_stack.size() > 80: undo_stack.pop_front()

func _undo() -> void:
	if undo_stack.is_empty(): return
	var s: Dictionary = undo_stack.pop_back()
	grid = s.grid
	zones = s.zones
	markers = s.markers
	grid_size = s.size
	thin_walls = s.get("thin_walls", [])
	selected_wall = -1
	if mode_3d:
		_rebuild_3d_context()
		_rebuild_3d_walls()
	_mark_dirty()

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
	if mode_3d:
		match k.keycode:
			KEY_DELETE, KEY_BACKSPACE: _delete_selected_wall()
			KEY_Q: _rotate_selected(-90.0 if k.shift_pressed else -15.0)
			KEY_E: _rotate_selected(90.0 if k.shift_pressed else 15.0)
			KEY_PAGEUP: _raise_selected(0.3)
			KEY_PAGEDOWN: _raise_selected(-0.3)
			KEY_F: _fit_3d()
		return
	match k.keycode:
		KEY_1: _select_tool("base:" + WALL)
		KEY_2: _select_tool("base:" + FLOOR)
		KEY_3: _select_tool("base:" + PIT)
		KEY_BRACKETLEFT: _set_brush(brush - 1)
		KEY_BRACKETRIGHT: _set_brush(brush + 1)
		KEY_F: _fit()

func _status(t: String) -> void:
	if status: status.text = t
