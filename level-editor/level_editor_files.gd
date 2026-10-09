extends "res://level_editor_gen.gd"
## Level editor, part 3: the level files. Reads and writes levels.json and the .lvl files (including legacy
## migration), creates / duplicates / renames / moves / deletes levels, resizes the grid, sets materials,
## bakes GI and launches the game on the current level. level_editor.gd builds the window around it.

const SLOTS := ["wall", "floor", "ceiling", "tiles"]
const ATMOS := ["dim", "classic", "liminal"]      # the level-wide look ("atmosphere" in the .lvl, level_data.gd atmosphere())
## The ceiling lights ("lights" in the .lvl, level_geometry.gd lights_mode()): the ceiling's own light panels (its
## tiles lit where it has none), hanging troffers with their ballasts, or none at all. Unset: panels.
const LIGHTS := [["panels", "Ceiling panels"], ["troffers", "Troffers (ballast tubes)"], ["none", "None"]]
const NAME_WORDS := ["The Lobby", "Habitable Zone", "Sector", "Annex", "Storage", "Maintenance", "Threshold", "Pool Rooms", "Stairwell", "Office"]
const SCATTER_PER_CELLS := 25         # roughly one prop per this many open floor cells
const SCATTER_KEEPOUT := 2            # cells kept clear round spawn / exit / entity / tv and existing objects

var data: Dictionary = {}
var filter := ""
var level_list: ItemList
var size_spin: SpinBox
var gi_pick: OptionButton
var atmo_pick: OptionButton
var endless_check: CheckBox          # the .lvl's "endless": the lowest and highest floors repeat for ever (level_data.gd endless())
var wrap_check: CheckBox             # the .lvl's "wrap": opposite map edges joined, the halls never end (level_data.gd wrap)
var lights_pick: OptionButton        # the .lvl's "lights" (LIGHTS)
var slot_picks := {}
var slot_previews := {}
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
	var ms = data.get("mark_shift", [0, 0])
	mark_shift = Vector2i(int(ms[0]), int(ms[1])) if ms is Array and ms.size() >= 2 else Vector2i.ZERO
	floor_idx = 0
	floor_store = {}
	_load_floor(_parse_floor(data))
	for k in data.get("floors", {}):
		if data.floors[k] is Dictionary and int(k) != 0: floor_store[int(k)] = _parse_floor(data.floors[k])
	_wells_adopt()
	_floors_changed()
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
	spawn_rot = float(data.get("spawn_rot", 270.0))
	gi_pick.select(0 if not data.has("sdfgi") else (1 if data["sdfgi"] else 2))
	atmo_pick.select(maxi(0, ATMOS.find(str(data.get("atmosphere", "dim")))))
	endless_check.set_pressed_no_signal(bool(data.get("endless", false)))
	wrap_check.set_pressed_no_signal(bool(data.get("wrap", false)))
	var lm := str(data.get("lights", "panels"))
	lights_pick.select(0)
	for j in LIGHTS.size():
		if LIGHTS[j][0] == lm: lights_pick.select(j)
	undo_stack.clear()
	redo_stack.clear()
	dirty = false
	if preview3d != null and preview3d.visible: preview3d.mark_stale()
	_refresh_list()
	_fit()
	_update_title()
	_sync_inspector()
	_status("Opened " + str(index[current].file) + ("   (%d old door / arch / thin wall tiles are objects now; save to keep)" % migrated if migrated > 0 else ""))

## One floor of a .lvl (the file itself for the ground floor, a "floors" entry for the others) as editor fields
func _parse_floor(d: Dictionary) -> Dictionary:
	var fd := _new_floor()
	var rows: Array = d.get("grid", []) if d.get("grid") is Array else []
	for z in mini(grid_size, rows.size()):
		var row: String = rows[z]
		for x in mini(grid_size, row.length()):
			fd.grid[z][x] = row[x]
	fd["noclip_to"] = str(d.get("noclip_to", ""))
	var zd = d.get("zones")
	if zd is Dictionary:
		for z in ZONES:
			for c in zd.get(z, []):
				fd.zones[z][Vector2i(c[0], c[1])] = true
	var pd = d.get("paint")
	if pd is Dictionary:
		for slot in PAINT_SLOTS:
			var by_mat: Dictionary = pd.get(slot, {})
			for id in by_mat:
				for c in by_mat[id]:
					fd.paint[slot][Vector2i(c[0], c[1])] = str(id)
	for m in MARKERS:
		var c = d.get(m)
		fd.markers[m] = Vector2i(c[0], c[1]) if c is Array and c.size() >= 2 else null
	var objs = d.get("objects")
	if objs is Array:
		for o in objs:
			if o is Dictionary and str(o.get("type", "")) != "":     # unknown types are kept as they are, drawn as slabs
				var t := str(o.type)
				var obj := {"type": t, "pos_x": float(o.get("pos_x", 0.0)), "pos_y": float(o.get("pos_y", 0.0)),
					"rotation": float(o.get("rotation", 0.0)), "scale": clampf(float(o.get("scale", 1.0)), 0.5, _max_scale(t))}
				for k in o:                                        # its params (thickness, height, event...), kept as saved
					if not obj.has(k): obj[k] = o[k]
				fd.objects.append(obj)
	return fd

## One floor's fields as .lvl keys (grid, objects, zones, paint, markers)
func _serialize_floor(fd: Dictionary) -> Dictionary:
	var out := {}
	var g: Array = []
	for row in fd.grid:
		g.append("".join(PackedStringArray(row)))
	out["grid"] = g
	var objs := []
	for o: Dictionary in fd.objects:
		var so := {"type": o.type, "pos_x": snappedf(o.pos_x, 0.001), "pos_y": snappedf(o.pos_y, 0.001),
			"rotation": snappedf(fposmod(o.rotation, 360.0), 0.01), "scale": snappedf(o.scale, 0.001)}
		for k in o:                                            # its params, as object_types.json "params" lists them
			if not so.has(k): so[k] = snappedf(o[k], 0.001) if o[k] is float else o[k]
		objs.append(so)
	out["objects"] = objs
	var zd := {}
	for z in ZONES:
		var list := []
		for c: Vector2i in fd.zones[z]:
			if fd.grid[c.y][c.x] not in [WALL, THIN, DOOR]: list.append([c.x, c.y])
		list.sort_custom(func(a, b): return a[1] < b[1] or (a[1] == b[1] and a[0] < b[0]))
		zd[z] = list
	out["zones"] = zd
	if str(fd.get("noclip_to", "")) != "" and not ((fd.zones.get("noclip", {}) as Dictionary).is_empty() and (fd.zones.get("noclip_floor", {}) as Dictionary).is_empty()):
		out["noclip_to"] = str(fd.noclip_to)
	var pd := {}
	for slot in PAINT_SLOTS:
		var by_mat := {}
		for c: Vector2i in fd.paint[slot]:
			if c.x < grid_size and c.y < grid_size:
				if not by_mat.has(fd.paint[slot][c]): by_mat[fd.paint[slot][c]] = []
				by_mat[fd.paint[slot][c]].append([c.x, c.y])
		for id in by_mat:
			by_mat[id].sort_custom(func(a, b): return a[1] < b[1] or (a[1] == b[1] and a[0] < b[0]))
		if not by_mat.is_empty(): pd[slot] = by_mat
	if not pd.is_empty(): out["paint"] = pd
	for m in MARKERS:
		out[m] = [fd.markers[m].x, fd.markers[m].y] if fd.markers[m] != null else null
	return out

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

## A new level: a small room in solid ground. Draw rooms out from it (the map grows as you draw past its
## edge), or drag the Generate tool over an area.
func _blank_level(nm: String) -> Dictionary:
	var s := 24
	var g: Array = []
	for z in s:
		var row := ""
		for x in s:
			row += FLOOR if (x >= 8 and x <= 15 and z >= 9 and z <= 14) else WALL
		g.append(row)
	return {"format": "backrooms_level", "version": 2, "name": nm, "size": s, "spawn": [9, 11], "exit": null,
		"entity": [14, 13], "tv": null, "grid": g, "zones": {}, "objects": []}

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

var _test_pid := -1

## Save, then launch the game straight into this level. TEST plays normally from the spawn marker; `here`
## (TEST HERE) starts on the cell under the mouse with noclip on. A test window still open from the last run is closed first.
func _test_level(here := false) -> void:
	if current < 0: return
	var exe := _godot_path()
	if exe == "":
		godot_dialog.popup_centered_ratio(0.6)
		return
	save()
	if _test_pid > 0 and OS.is_process_running(_test_pid):
		OS.kill(_test_pid)
	var args := ["--path", GAME, "--", "--test-level=" + str(index[current].id)]
	if floor_idx != 0: args.append("--test-floor=%d" % floor_idx)
	if here: args.append("--noclip")
	if here and hover.x >= 1 and hover.y >= 1 and hover.x < grid_size - 1 and hover.y < grid_size - 1 and grid[hover.y][hover.x] != WALL:
		args.append("--test-spawn=%d,%d" % [hover.x, hover.y])
	_test_pid = OS.create_process(exe, args)
	if _test_pid <= 0:
		_status("Could not start " + exe)
	elif here:
		_status("Testing %s in noclip (WASD, Space up, C down, Shift fast)" % str(index[current].name))
	else:
		_status("Testing %s" % str(index[current].name))

# ---------------------------------------------------------------- save
func _current_payload() -> Dictionary:
	var out := data.duplicate()
	out["version"] = 2                   # v2: doors / arches / thin walls live in "objects", not the grid
	out["size"] = grid_size
	if mark_shift == Vector2i.ZERO: out.erase("mark_shift")
	else: out["mark_shift"] = [mark_shift.x, mark_shift.y]
	out.erase("paint")
	var all := _all_floors()
	var ground := _serialize_floor(all[0])
	for k in ground: out[k] = ground[k]
	var floors := {}
	for f in all:
		if f != 0: floors[str(f)] = _serialize_floor(all[f])
	if floors.is_empty(): out.erase("floors")
	else: out["floors"] = floors
	if is_equal_approx(spawn_rot, 270.0): out.erase("spawn_rot")
	else: out["spawn_rot"] = snappedf(spawn_rot, 0.1)
	match gi_pick.selected:
		1: out["sdfgi"] = true
		2: out["sdfgi"] = false
		_: out.erase("sdfgi")
	if atmo_pick.selected <= 0: out.erase("atmosphere")
	else: out["atmosphere"] = ATMOS[atmo_pick.selected]
	if endless_check.button_pressed: out["endless"] = true
	else: out.erase("endless")
	if wrap_check.button_pressed: out["wrap"] = true
	else: out.erase("wrap")
	if lights_pick.selected <= 0: out.erase("lights")
	else: out["lights"] = LIGHTS[lights_pick.selected][0]
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

## Random clutter, scattered onto open floor: every object type flagged "scatter" in object_types.json
## (the industrial props), dropped at a random cell with a random rotation and size, clear of spawn / exit
## / entity / tv and anything already placed. Undoable in one step, same as a paint stroke.
func _scatter_props() -> void:
	var kinds: Array = []
	for t in OBJ_TYPES:
		if bool(OBJ_INFO[t].get("scatter", false)): kinds.append(t)
	if kinds.is_empty():
		_status("No object type has \"scatter\": true in object_types.json")
		return
	var keep_clear: Array[Vector2i] = []
	for m in markers:
		var c = markers[m]
		if c != null: keep_clear.append(c)
	for o: Dictionary in objects:
		keep_clear.append(Vector2i(roundi(o.pos_x), roundi(o.pos_y)))
	var open: Array[Vector2i] = []
	for z in range(1, grid_size - 1):
		for x in range(1, grid_size - 1):
			if grid[z][x] != FLOOR: continue
			var c := Vector2i(x, z)
			var near := false
			for k in keep_clear:
				if absi(c.x - k.x) + absi(c.y - k.y) < SCATTER_KEEPOUT:
					near = true
					break
			if not near: open.append(c)
	if open.is_empty():
		_status("No open floor clear enough to scatter onto")
		return
	_push_undo()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var count := clampi(open.size() / SCATTER_PER_CELLS, 4, 40)
	var placed := 0
	for i in count:
		if open.is_empty(): break
		var c: Vector2i = open.pop_at(rng.randi_range(0, open.size() - 1))
		var t: String = kinds[rng.randi_range(0, kinds.size() - 1)]
		objects.append({"type": t, "pos_x": c.x + rng.randf_range(-0.3, 0.3), "pos_y": c.y + rng.randf_range(-0.3, 0.3),
			"rotation": rng.randf_range(0.0, 360.0), "scale": rng.randf_range(0.8, 1.3)})
		placed += 1
	selected = -1
	_sync_inspector()
	_mark_dirty()
	_status("Scattered %d random props" % placed)

func _write(path: String, payload) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status("Cannot write " + path)
		return
	f.store_string(JSON.stringify(payload, "  ") + "\n")

func _resize(n: int) -> void:
	_push_undo()
	_reframe(clampi(n, 8, MAX_SIZE), Vector2i.ZERO)
	_mark_dirty()
	_fit()

# ---------------------------------------------------------------- floors
## A new floor above the top one (dir 1) or below the bottom one (-1), and go to it
func _add_floor(dir: int) -> void:
	var fs := _floor_numbers()
	var f: int = (fs[-1] + 1) if dir > 0 else (fs[0] - 1)
	_push_undo()
	floor_store[f] = _new_floor()
	_switch_floor(f)
	_mark_dirty()
	_status("Added %s, and you are on it now. Draw its rooms; to join it to %s put Stairs %s (%s) here, or Stairs %s on that floor" % [
		_floor_name(f), _floor_name(f - dir), "down" if dir > 0 else "up", "8" if dir > 0 else "7", "up" if dir > 0 else "down"])

## The floor being edited, copied into every floor below it (what was on them is replaced): the same rooms
## storey after storey, so a pit here is a shaft through all of them. The spawn, exit, entity and TV stay on
## the floor they are on.
func _repeat_down() -> void:
	var below: Array = _floor_numbers().filter(func(f: int) -> bool: return f < floor_idx)
	if below.is_empty():
		_status("No floor below this one. Add some with + DOWN, or tick ENDLESS and the lowest floor repeats by itself")
		return
	_push_undo()
	var src := _live_floor()
	for f: int in below:
		var fd := _copy_floor(src)
		for m in fd.markers: fd.markers[m] = null
		floor_store[f] = fd
	_mark_dirty()
	_update_info()
	canvas.queue_redraw()
	_status("Copied %s into the %d floor%s below it (Ctrl+Z undoes it)" % [_floor_name(floor_idx), below.size(), "" if below.size() == 1 else "s"])

func _delete_floor() -> void:
	if floor_idx == 0:
		_status("The ground floor can't be deleted")
		return
	_push_undo()
	var gone := floor_idx
	var to := gone - 1 if gone > 0 else gone + 1
	_load_floor(floor_store[to])
	floor_store.erase(to)
	floor_idx = to
	selected = -1
	_floors_changed()
	_sync_inspector()
	_mark_dirty()
	_status("Deleted %s (Ctrl+Z brings it back)" % _floor_name(gone))

func _step_floor(d: int) -> void:
	var fs := _floor_numbers()
	var i := fs.find(floor_idx) + d
	if i >= 0 and i < fs.size(): _switch_floor(fs[i])

# ---------------------------------------------------------------- materials
func _set_material(slot: String, id: String) -> void:
	materials[slot] = id
	_preview(slot)
	_mark_dirty()

## The swatch beside a level material picker: the material, or the game's default look when none is set
func _preview(slot: String) -> void:
	var id := str(materials.get(slot, ""))
	(slot_previews[slot] as TextureRect).texture = _thumb(id if id != "" else "default:" + slot).tex
