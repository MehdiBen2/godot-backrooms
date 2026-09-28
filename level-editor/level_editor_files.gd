extends "res://level_editor_canvas.gd"
## Level editor, part 2: the level files. Reads and writes levels.json and the .lvl files (including legacy
## migration), creates / duplicates / renames / moves / deletes levels, resizes the grid, sets materials,
## bakes GI and launches the game on the current level. level_editor.gd builds the window around it.

const SLOTS := ["wall", "floor", "ceiling", "tiles"]
const ATMOS := ["dim", "classic"]      # the level-wide look ("atmosphere" in the .lvl, level_data.gd atmosphere())
const NAME_WORDS := ["The Lobby", "Habitable Zone", "Sector", "Annex", "Storage", "Maintenance", "Threshold", "Pool Rooms", "Stairwell", "Office"]

var GAME := OS.get_environment("BACKROOMS_GAME_DIR") if OS.has_environment("BACKROOMS_GAME_DIR") \
	else ProjectSettings.globalize_path("res://").path_join("../godot-backrooms").simplify_path()

var data: Dictionary = {}
var materials := {}                  # slot -> pbr name
var filter := ""
var level_list: ItemList
var size_spin: SpinBox
var gi_pick: OptionButton
var atmo_pick: OptionButton
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
		if o is Dictionary and str(o.get("type", "")) != "":     # unknown types are kept as they are, drawn as slabs
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
	_bake(str(index[current].id))

## Bake the saved level's bounce light (the game's tools/bake_level.gd: a VoxelGI of its walls, floors and
## ceilings) in the background. Takes 30 s to 2 min depending on size; until it lands the game falls back to SDFGI.
var _bake_pid := -1

func _bake(id: String) -> void:
	var exe := _godot_path()
	if exe == "": return
	if _bake_pid > 0 and OS.is_process_running(_bake_pid):
		OS.kill(_bake_pid)                      # a newer save supersedes the running bake
	var args := ["--path", GAME, "--resolution", "320x180", "--position", "-4000,-4000",
		"--script", "res://tools/bake_level.gd", "--", "--bake-level=" + id]
	_bake_pid = OS.create_process(exe, args)
	if _bake_pid > 0:
		_status("Saved %s  -  baking lighting in the background..." % str(index[current].file))

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
