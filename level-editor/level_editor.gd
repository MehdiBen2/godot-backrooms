extends Control
## Standalone level editor: its own Godot project, not part of the game. Open level-editor/ in Godot
## (or export it) and run. It edits the game's levels/*.lvl and levels.json in place, including the
## per-level PBR "materials" ({wall, floor, ceiling, tiles} -> folders in the game's textures/pbr/).
## Set BACKROOMS_GAME_DIR to point at a different game folder.
##   left drag paint   right drag erase   middle drag / Space+drag pan   wheel zoom   F fit
##   1 2 3 wall/floor/pit   [ ] brush size   Ctrl+S save   Ctrl+Z undo   Ctrl+N new   Ctrl+D duplicate

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
	"dark": Color("7a2cff"), "dim": Color("8a6a3a"), "flicker": Color("ff3f9a"), "grime": Color("8a6a30")}
const ZONE_HELP := {"tall": "Huge atrium ceiling", "low": "Crouch-height ceiling", "tiles": "Tile floor instead of carpet",
	"bright": "Always lit, safe room", "dark": "All tubes dead", "dim": "Most tubes dead", "flicker": "Failing tubes", "grime": "Stained carpet"}
const MARKERS := {"spawn": Color("2fd968"), "exit": Color("2fd9ee"), "entity": Color("ff3030"), "tv": Color("5c8dff")}
const BASE_COLORS := {WALL: Color("3f3a30"), FLOOR: Color("cdb86a"), PIT: Color("050505")}
const SLOTS := ["wall", "floor", "ceiling", "tiles"]
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

var font: FontFile = load("res://fonts/vcr.ttf")
var canvas: Control
var level_list: ItemList
var search: LineEdit
var size_spin: SpinBox
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
var shown: Array = []                # index positions currently shown in the list

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
	materials = data.get("materials", {}).duplicate()
	for slot in SLOTS:
		var idx := pbr_names.find(str(materials.get(slot, "")))
		(slot_picks[slot] as OptionButton).select(idx + 1 if idx >= 0 else 0)
		_preview(slot)
	size_spin.value = grid_size
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
	undo_stack.append({"grid": grid.duplicate(true), "zones": z, "markers": markers.duplicate(), "size": grid_size})
	if undo_stack.size() > 80: undo_stack.pop_front()

func _undo() -> void:
	if undo_stack.is_empty(): return
	var s: Dictionary = undo_stack.pop_back()
	grid = s.grid
	zones = s.zones
	markers = s.markers
	grid_size = s.size
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
	match k.keycode:
		KEY_1: _select_tool("base:" + WALL)
		KEY_2: _select_tool("base:" + FLOOR)
		KEY_3: _select_tool("base:" + PIT)
		KEY_BRACKETLEFT: _set_brush(brush - 1)
		KEY_BRACKETRIGHT: _set_brush(brush + 1)
		KEY_F: _fit()

func _status(t: String) -> void:
	if status: status.text = t
