extends Control
## Level editor, part 1: the map canvas. Draws the grid, zones, markers and free-placed objects with their
## gizmos, turns mouse input into painting, erasing, placing, moving and rotating, snaps and aligns objects,
## and keeps the undo stack. level_editor_files.gd adds opening and saving levels, level_editor.gd the UI.

const CREAM := Color("e6e1cd")
const DIM := Color(0.9, 0.882, 0.804, 0.55)
const GOLD := Color("e6c65a")
const RED := Color("c4271f")
const SEL := Color("35e0ff")             # selection gizmo: nothing else on the map is cyan, so it reads on any floor

const WALL := "#"
const FLOOR := "."
const PIT := "O"
const THIN := "T"                    # v1 tiles, converted into objects when a level opens (_migrate_legacy)
const ARCH := "A"
const DOOR := "D"
const ZONES := {"tall": Color("5a9bff"), "low": Color("ff8a3d"), "tiles": Color("f2f2f2"), "bright": Color("fff04a"),
	"dark": Color("7a2cff"), "dim": Color("8a6a3a"), "flicker": Color("ff3f9a"), "grime": Color("8a6a30"), "classic": Color("ffe86a"),
	"liminal": Color("9fe0c8"), "mannequin": Color("e8e0d0"),
	"safe": Color("39d98a"), "drain": Color("d1345b"), "loot": Color("ff9f1c"), "open_ceiling": Color("a8dcff"),
	"echo": Color("2ec4b6"), "loop": Color("b388ff"), "abyss": Color("6b5d2e"), "endless_ceiling": Color("c9b8ff")}
const PAINT_SLOTS := ["wall", "floor", "ceiling"]
const MARKERS := {"spawn": Color("2fd968"), "exit": Color("2fd9ee"), "entity": Color("ff3030"), "tv": Color("5c8dff"), "drop_hole": Color("ff7722")}
const BASE_COLORS := {WALL: Color("3f3a30"), FLOOR: Color("cdb86a"), PIT: Color("050505"),
	THIN: Color("7a7364"), ARCH: Color("8a7a52"), DOOR: Color("6b4a2e")}
# Free-placed objects, mirrored from the game's level_data.gd. Positions are in cells with a cell's centre
# on a whole number (the same frame as "spawn"), rotation is degrees clockwise on this map, scale is the
# width in cells. Locally an object faces +x (you walk through it along x) and spans y.
const CELL_M := 4.5                  # metres per cell in the game (level_data.gd CELL)
const SNAP_STEP := 0.5               # snap to cell centres and cell edges
var index: Array = []
var current := -1
var grid_size := 46
var grid: Array = []                 # grid[z] is an Array of one-char strings
var zones := {}                      # zone -> {Vector2i: true}
var paint := {"wall": {}, "floor": {}, "ceiling": {}}   # slot -> {Vector2i: pbr name}: per-cell material overrides
var paint_mat := ""                  # the material the paint tools lay down
var markers := {}                    # marker -> Vector2i or null
var spawn_rot := 270.0               # the way the player looks at spawn: degrees clockwise on the map, 0 = right, 270 = up
var tool := "base:" + WALL
var brush := 1
var undo_stack: Array = []
var painting := false
var erasing := false
var panning := false
var pan_button := MOUSE_BUTTON_MIDDLE    # the button the pan was started with: it ends when that one comes up
var zoom := 14.0
var pan := Vector2(10, 10)
var hover := Vector2i(-1, -1)
var dirty := false
var objects: Array = []              # {type, pos_x, pos_y, rotation, scale, <its type's params>}
var selected := -1                   # index into objects
var hover_obj := -1
var drag := ""                       # "" | "move" | "rotate" | "place" | "line" | "chain" | "box"
var multi: Array = []                # indices of a multi-selection (box drag or Shift+click); [] = just `selected`
var group_start: Array = []          # [index, pos_x, pos_y] of each piece a group move started with
var group_anchor := Vector2.ZERO     # where the group move was grabbed, in cells
var box_from := Vector2.ZERO         # canvas px where a box selection started
var line_from := Vector2.ZERO        # where the wall being drawn starts, in cells
var drag_off := Vector2.ZERO         # grab point -> object origin, in cells
var mouse_px := Vector2(-1, -1)
var place_rot := 0.0                 # new objects start at the last rotation used, and their type's last width
var place_scales := {}               # type -> the width its last one was given
var snap := true
var rot_snap := true
var align := true                    # turn doors / arches / thin walls to fit the wall or corridor they land on
var OBJ_TYPES: Array = []            # the object types, in levels/object_types.json order
var OBJ_INFO := {}                   # type -> its object_types.json entry, plus "col" as a Color
var insp_undo := -1                  # the object the inspector already pushed an undo step for
var redo_stack: Array = []

var GAME := OS.get_environment("BACKROOMS_GAME_DIR") if OS.has_environment("BACKROOMS_GAME_DIR") \
	else ProjectSettings.globalize_path("res://").path_join("../godot-backrooms").simplify_path()
var materials := {}                  # slot -> pbr name: the level-wide material of each surface
var pbr_names: Array = []            # the folders in the game's textures/pbr/

# How the map is shown (the bar above it)
var view_ceiling := false            # show the ceiling's materials instead of the floor's
var show_tex := true                 # draw the real textures on cells
var show_zones := true
var show_paint := true               # outline painted materials and list them
var show_objects := true
var show_grid := true
# How a click paints: "brush" (drag the brush), "rect" (drag a rectangle), "fill" (the connected area)
var mode := "brush"
var rect_from := Vector2i(-1, -1)    # where a rectangle drag started
var hover_raw := Vector2i(-1, -1)    # the cell under the mouse even outside the map (drawing there grows it)
var auto_walls := true               # floor rectangles are drawn as rooms: a wall round a floor
var scatter := 100                   # % of the cells a paint stroke actually paints (random variation)
var paint_mix: Array = []            # more materials painted at random alongside paint_mat
var stroke_seed := 0                 # new each click, so scatter / mix are stable while you drag over a cell
const MAX_SIZE := 256                # cells a side: 1.15 km at 4.5 m a cell

# Floors: the level's other floors, kept aside while you edit one. The live grid / zones / paint / markers /
# objects are floor `floor_idx`; floor_store holds every other floor (int -> the same set of fields).
var floor_idx := 0
var floor_store := {}
var show_onion := true               # the floor below (or above) drawn faintly under this one

var font: FontFile = load("res://fonts/vcr.ttf")
var canvas: Control
var title_label: Label
var status: Label
var info: Label
var insp: VBoxContainer
var tool_scroll: ScrollContainer
var insp_trigger_btn: Button
var insp_type: OptionButton
var insp_x: SpinBox
var insp_y: SpinBox
var insp_rot: SpinBox
var insp_scale: SpinBox
var insp_scale_label: Label
var insp_params := {}                # param -> {"row": [label, control], "ctrl": control}: level_editor.gd builds them
func _info(t: String) -> Dictionary:
	return OBJ_INFO.get(t, {"label": t, "key": "", "col": Color("a39c8a"), "help": ""})

## A size from object_types.json, in cells
func _cells(t: String, key: String, metres: float) -> float:
	return float(_info(t).get(key, metres)) / CELL_M

## What a type is built as (object_types.json "shape": slab, corner, arc, pillar, column, zone; "" for the rest)
func _shape(t: String) -> String:
	return str(_info(t).get("shape", ""))

## An object's own value of one of its type's params, else the type's default
func _param(o: Dictionary, key: String, fallback = null):
	return o.get(key, _info(o.type).get("params", {}).get(key, fallback))

## A wall object's thickness in cells (its own, else its type's)
func _thick_cells(o: Dictionary) -> float:
	return float(_param(o, "thick", _info(o.type).get("thickness", 0.3))) / CELL_M

## The widest a type may be made (object_types.json "max_scale", else 4 cells)
func _max_scale(t: String) -> float:
	return float(_info(t).get("max_scale", 4.0))

## The width the next object of type `t` is placed at: its type's last one, else 1 cell (a trigger: 3)
func _place_scale(t: String) -> float:
	return float(place_scales.get(t, 3.0 if _shape(t) == "zone" else 1.0))

## The centre line of a wall-shaped object in object space (cells): the game's level_data.gd shape_path()
func _shape_path(o: Dictionary) -> PackedVector2Array:
	var sc: float = o.scale
	match _shape(o.type):
		"slab", "":
			return PackedVector2Array([Vector2(0, -sc * 0.5), Vector2(0, sc * 0.5)])
		"corner":
			return PackedVector2Array([Vector2(sc, 0), Vector2.ZERO, Vector2(0, sc)])
		"arc":
			var arc := deg_to_rad(clampf(float(_param(o, "arc", 90.0)), 5.0, 360.0))
			var n := maxi(2, ceili(arc / deg_to_rad(10.0)))
			var pts := PackedVector2Array()
			for i in n + 1:
				pts.append(Vector2.from_angle(-arc * 0.5 + arc * i / n) * sc * 0.5)
			return pts
	return PackedVector2Array()

## A new object of type `t` with every param at its default
func _new_object(t: String, at: Vector2, rot: float) -> Dictionary:
	var o := {"type": t, "pos_x": at.x, "pos_y": at.y, "rotation": rot, "scale": _place_scale(t)}
	var params: Dictionary = _info(t).get("params", {})
	for k in params:
		var val = params[k]
		if val is Array or val is Dictionary:
			o[k] = val.duplicate(true)
		else:
			o[k] = val
	return o

# ---------------------------------------------------------------- stairwells
# A stairwell (object_types.json "stairs": true; the game's props/stairs.gd) stands square on the grid:
# STAIR_CELLS cells from its own along its arrow by STAIR_WIDE across (its own row, where its doorway is, and
# the one to the left of the arrow). One well is one object on each floor it reaches, on the same cells of
# every one, all sharing a "well" number so they move, turn and are dressed together. The game joins two
# floors wherever both have a stairwell on the very same cells.
const STAIR_CELLS := 3               # level_data.gd STAIR_CELLS / STAIR_WIDE
const STAIR_WIDE := 2

func _is_stairs(t: String) -> bool:
	return bool(_info(t).get("stairs", false))

func _stair_dir(o: Dictionary) -> Vector2i:
	return Vector2i(Vector2.from_angle(deg_to_rad(float(o.rotation))).round())

func _stair_cells(o: Dictionary) -> Array[Vector2i]:
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	var dir := _stair_dir(o)
	var left := Vector2i(dir.y, -dir.x)
	var out: Array[Vector2i] = []
	for i in STAIR_CELLS:
		for j in STAIR_WIDE: out.append(c + dir * i + left * j)
	return out

## The cell in front of the well's doorway
func _stair_door(o: Dictionary) -> Vector2i:
	return Vector2i(roundi(o.pos_x), roundi(o.pos_y)) - _stair_dir(o)

## Square on the grid: whole cells, quarter turns, one size
func _stair_square(o: Dictionary) -> void:
	o.pos_x = roundf(o.pos_x)
	o.pos_y = roundf(o.pos_y)
	o.rotation = fposmod(snappedf(o.rotation, 90.0), 360.0)
	o.scale = 1.0

## The stairwell among `objs` standing on the very cells of `o`, the same way round (-1: none)
func _stair_twin(objs: Array, o: Dictionary) -> int:
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	for i in objs.size():
		var p: Dictionary = objs[i]
		if is_same(p, o) or not _is_stairs(str(p.type)): continue
		if Vector2i(roundi(p.pos_x), roundi(p.pos_y)) == c and _stair_dir(p) == _stair_dir(o): return i
	return -1

## Does another stairwell among `objs` share a cell with `o` (without standing exactly on it)?
func _stair_clash(objs: Array, o: Dictionary) -> bool:
	var mine := _stair_cells(o)
	var twin := _stair_twin(objs, o)
	for i in objs.size():
		var p: Dictionary = objs[i]
		if i == twin or is_same(p, o) or not _is_stairs(str(p.type)): continue
		for c in _stair_cells(p):
			if mine.has(c): return true
	return false

## Inside the map's border wall?
func _inner(c: Vector2i) -> bool:
	return c.x >= 1 and c.y >= 1 and c.x < grid_size - 1 and c.y < grid_size - 1

## Do all the well's cells, and the one in front of its door, lie inside the map?
func _stair_fits(o: Dictionary) -> bool:
	if not _inner(_stair_door(o)): return false
	for c in _stair_cells(o):
		if not _inner(c): return false
	return true

## The way a new well at `o` should face: as `o` does if it fits there with an open cell at its door, else the
## first quarter turn that does, else the first that fits at all
func _stair_facing(o: Dictionary) -> float:
	var probe := o.duplicate()
	for want_open in [true, false]:
		for k in 4:
			probe.rotation = fposmod(float(o.rotation) + 90.0 * k, 360.0)
			if not _stair_fits(probe) or _stair_clash(objects, probe): continue
			var d := _stair_door(probe)
			if not want_open or grid[d.y][d.x] != WALL: return probe.rotation
	return o.rotation

func _floor_objects(f: int) -> Array:
	if f == floor_idx: return objects
	return floor_store[f].objects if floor_store.has(f) else []

## Is the stairwell `o` of floor `f` joined to the floor `d` up from it (-1: down)?
func _stair_linked(o: Dictionary, f: int, d: int) -> bool:
	return _stair_twin(_floor_objects(f + d), o) >= 0

## The grid under a stairwell: floor in its cells (the game builds the well itself there) and an open cell in
## front of its door. `landing`: where that cell was solid, a little room round it to arrive in too.
func _stair_carve(g: Array, o: Dictionary, landing := false) -> void:
	var cells := _stair_cells(o)
	for c in cells:
		if _inner(c): g[c.y][c.x] = FLOOR
	var door := _stair_door(o)
	if not _inner(door) or g[door.y][door.x] != WALL: return
	g[door.y][door.x] = FLOOR
	if not landing: return
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var n := door + Vector2i(dx, dz)
			if _inner(n) and not cells.has(n) and g[n.y][n.x] == WALL: g[n.y][n.x] = FLOOR

## A number no stairwell of the level has yet
func _well_new() -> int:
	var top := 0
	var all := _all_floors()
	for f in all:
		for p: Dictionary in all[f].objects: top = maxi(top, int(p.get("well", 0)))
	return top + 1

## Carry stairwell `o` of this floor on to the floor `d` up from it (-1: down): that floor gets the same well
## on the same cells, or is joined to the one already standing there. A floor the level doesn't have is made.
func _stair_extend(o: Dictionary, d: int) -> void:
	var f := floor_idx + d
	var made := not floor_store.has(f)
	if made:
		floor_store[f] = _new_floor()
		_floors_changed()
	var fd: Dictionary = floor_store[f]
	var k := _stair_twin(fd.objects, o)
	if k >= 0:
		var was := int(fd.objects[k].get("well", 0))
		if was != 0 and was != int(o.well):          # two wells meet: they are one from here on
			var all := _all_floors()
			for g in all:
				for p: Dictionary in all[g].objects:
					if int(p.get("well", 0)) == was: p["well"] = o.well
		fd.objects[k]["well"] = o.well
		_status("This floor and %s are joined by the stairwell" % _floor_name(f))
		return
	var p := o.duplicate(true)
	p.type = "stairs_down" if d > 0 else "stairs_up"
	if _stair_clash(fd.objects, p):
		_status("Another stairwell is in the way on %s: not joined to it" % _floor_name(f))
		return
	fd.objects.append(p)
	_status("%s%s has the other end of the stairwell (PageUp / PageDown to go there)" % ["Made " if made else "", _floor_name(f)])

## The other floors' ends of the stairwell `o` follow it: the same cells, the same way round, the same look
func _well_follow(o: Dictionary) -> void:
	var id := int(o.get("well", 0))
	if id == 0: return
	for f in floor_store:
		for p: Dictionary in floor_store[f].objects:
			if int(p.get("well", 0)) != id or not _is_stairs(str(p.type)): continue
			p.pos_x = o.pos_x
			p.pos_y = o.pos_y
			p.rotation = o.rotation
			for k in ["style", "rail"]:
				if o.has(k): p[k] = o[k]

## A stairwell was placed, moved, turned or edited: square it up, take its other ends with it and make the
## grid right under each. False (and the edit undone) when it no longer fits where it was put.
func _stair_settle(o: Dictionary) -> bool:
	_stair_square(o)
	if not _stair_fits(o) or _stair_clash(objects, o):
		_undo()
		_status("A stairwell needs %d x %d clear cells, and the cell in front of its door, inside the map" % [STAIR_CELLS, STAIR_WIDE])
		return false
	_well_follow(o)
	_stair_carve(grid, o)
	var id := int(o.get("well", 0))
	for f in floor_store:
		for p: Dictionary in floor_store[f].objects:
			if id != 0 and int(p.get("well", 0)) == id and _is_stairs(str(p.type)): _stair_carve(floor_store[f].grid, p, true)
	return true

## An end of stairwell `id` was deleted: any other end left with no floor to lead to goes with it
func _well_prune(id: int) -> void:
	if id == 0: return
	var all := _all_floors()
	var lost: Array = []
	var again := true
	while again:
		again = false
		for f in all:
			var objs: Array = all[f].objects
			for i in range(objs.size() - 1, -1, -1):
				var p: Dictionary = objs[i]
				if int(p.get("well", 0)) != id or not _is_stairs(str(p.type)): continue
				if _stair_linked(p, f, 1) or _stair_linked(p, f, -1): continue
				objs.remove_at(i)
				lost.append(_floor_name(f))
				again = true
	if not lost.is_empty():
		selected = -1
		multi = []
		_status("Its other end on %s went with it" % ", ".join(lost))

## Stairwells loaded from a file: squared up, floor under them, and numbered (ends of one well, on the same
## cells of neighbouring floors, get the same number)
func _wells_adopt() -> void:
	var all := _all_floors()
	var floors: Array = all.keys()
	floors.sort()
	for f in floors:
		for o: Dictionary in all[f].objects:
			if not _is_stairs(str(o.type)): continue
			_stair_square(o)
			for c in _stair_cells(o):
				if _inner(c) and all[f].grid[c.y][c.x] == PIT: all[f].grid[c.y][c.x] = FLOOR
			var params: Dictionary = _info(str(o.type)).get("params", {})
			for k in params:
				if not o.has(k): o[k] = params[k]
			o["well"] = int(o.get("well", 0))             # a whole number, however the file had it
			if int(o.well) != 0: continue
			var below := _stair_twin(all[f - 1].objects, o) if all.has(f - 1) else -1
			o["well"] = int(all[f - 1].objects[below].get("well", 0)) if below >= 0 else 0
			if int(o.well) == 0: o["well"] = _well_new()

## Floors the player can't get to from the ground floor: there is no stairwell both floors share on the way,
## nor a drop hole down to them
func _unreachable_floors() -> Array:
	var all := _all_floors()
	var seen := {0: true}
	var todo: Array = [0]
	while not todo.is_empty():
		var f: int = todo.pop_back()
		for d: int in [-1, 1]:
			var g := f + d
			if seen.has(g) or not all.has(g): continue
			var joined: bool = d == -1 and all[f].markers.get("drop_hole") != null
			for o: Dictionary in all[f].objects:
				if joined: break
				joined = _is_stairs(str(o.type)) and _stair_twin(all[g].objects, o) >= 0
			if joined:
				seen[g] = true
				todo.append(g)
	var out: Array = []
	for f in all:
		if not seen.has(f): out.append(f)
	out.sort()
	return out

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
	var ground: Dictionary = markers if floor_idx == 0 else floor_store.get(0, {}).get("markers", {})
	for m in ["spawn", "exit"]:
		var found = ground.get(m)
		if m == "exit":                        # an exit can be on any floor
			for f in floor_store:
				if floor_store[f].markers.get("exit") != null: found = true
			if markers.get("exit") != null: found = true
		if found == null: warn.append("no " + m)
	var lost := _unreachable_floors()
	if lost.size() == 1: warn.append("no stairs to " + _floor_name(lost[0]))
	elif lost.size() > 1: warn.append("%d floors with no stairs to them (%s ... %s)" % [lost.size(), _floor_name(lost[0]), _floor_name(lost[-1])])
	info.text = "%s   %dx%d   %d open   %d objects   %s" % [_floor_name(floor_idx), grid_size, grid_size, open_cells, objects.size(), ("WARN: " + ", ".join(warn)) if not warn.is_empty() else "OK"]
	info.add_theme_color_override("font_color", RED if not warn.is_empty() else DIM)

var preview3d: Control               # level_editor_3d.gd: rebuilt when the map changes while it is open

func _mark_dirty() -> void:
	dirty = true
	for k in _group():
		if k < objects.size() and _is_stairs(str(objects[k].type)): _well_follow(objects[k])
	if preview3d != null and preview3d.visible: preview3d.mark_stale()
	_update_title()
	canvas.queue_redraw()

# ---------------------------------------------------------------- canvas
func _fit() -> void:
	if canvas == null: return
	if canvas.size.x < 32.0:             # not laid out yet (the level opens before the first frame)
		if not canvas.resized.is_connected(_fit): canvas.resized.connect(_fit, CONNECT_ONE_SHOT)
		return
	zoom = clampf(minf(canvas.size.x, canvas.size.y) / maxf(grid_size, 1) * 0.96, 6.0, 40.0)
	zoom_goal = zoom
	pan = (canvas.size - Vector2(grid_size, grid_size) * zoom) / 2.0
	canvas.queue_redraw()

## Every material keeps one bright colour (from its name), used for its outlines and marks on the map
func _paint_colour(id: String) -> Color:
	return Color.from_hsv(fmod(float(hash(id) & 0xffff) / 65535.0, 1.0), 0.7, 1.0)

# ---------------------------------------------------------------- material thumbnails
# How a surface looks when the level sets no material: the game's own Level 0 textures
const DEFAULT_TEX := {"wall": "textures/wall_color.png", "floor": "textures/l0_carpet_color.webp",
	"ceiling": "textures/l0_ceiling_color.webp", "tiles": "textures/tiles_color.png"}
# ...and the tint the game puts over each (level_geometry.gd _mat / _wall_material)
const DEFAULT_TINT := {"wall": Color(1.0, 0.98, 0.88), "floor": Color(1.0, 0.94, 0.75), "ceiling": Color(0.89, 0.85, 0.74)}
const THUMB := 128
const DIRS4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const WALL_SHADE := Color(0.42, 0.4, 0.36)      # wall tops drawn darker than the floor round them
const DEEP_WALL := Color("1d1a14")               # wall mass with no open side
var _thumbs := {}                    # key -> {tex, avg}

## The colour map of a folder in the game's textures/pbr/: its <name>_Color file, else what its .tres uses as albedo
func _pbr_colour_path(id: String) -> String:
	var dir := GAME.path_join("textures/pbr/" + id)
	for ext in ["jpg", "png", "webp"]:
		var p := dir.path_join("%s_Color.%s" % [id, ext])
		if FileAccess.file_exists(p): return p
	var tres := FileAccess.get_file_as_string(dir.path_join(id + ".tres"))
	var m := RegEx.create_from_string('albedo_texture = ExtResource\\("([^"]+)"\\)').search(tres)
	if m != null:
		var r := RegEx.create_from_string('path="res://([^"]+)" id="%s"' % m.get_string(1)).search(tres)
		if r != null: return GAME.path_join(r.get_string(1))
	return ""

## A small texture of a material and its average colour. `key` is a pbr name, or "default:<slot>" for the
## game's built-in look. Thumbnails are cached in user://thumbs so the editor opens fast next time.
func _thumb(key: String) -> Dictionary:
	if _thumbs.has(key): return _thumbs[key]
	var e := {"tex": null, "avg": _paint_colour(key)}
	var path := ""
	if key.begins_with("default:"): path = GAME.path_join(str(DEFAULT_TEX.get(key.get_slice(":", 1), "")))
	elif key != "": path = _pbr_colour_path(key)
	if path != "" and FileAccess.file_exists(path):
		var cache := "user://thumbs/%s_v2.png" % key.replace(":", "_")
		var img: Image = null
		if FileAccess.file_exists(cache) and FileAccess.get_modified_time(cache) >= FileAccess.get_modified_time(path):
			img = Image.load_from_file(cache)
		if img == null:
			img = Image.load_from_file(path)
			if img != null:
				if img.is_compressed(): img.decompress()
				img.convert(Image.FORMAT_RGBA8)
				img.resize(THUMB, THUMB, Image.INTERPOLATE_LANCZOS)
				var tint: Color = DEFAULT_TINT.get(key.get_slice(":", 1), Color.WHITE) if key.begins_with("default:") else Color.WHITE
				if tint != Color.WHITE:
					for y in THUMB:
						for x in THUMB:
							img.set_pixel(x, y, img.get_pixel(x, y) * tint)
				DirAccess.make_dir_recursive_absolute("user://thumbs")
				img.save_png(cache)
		if img != null:
			var sum := Color(0, 0, 0, 0)
			var n := 0.0
			for y in range(0, img.get_height(), 8):
				for x in range(0, img.get_width(), 8):
					sum += img.get_pixel(x, y)
					n += 1.0
			e.avg = Color(sum.r / n, sum.g / n, sum.b / n)
			img.generate_mipmaps()
			e.tex = ImageTexture.create_from_image(img)
	_thumbs[key] = e
	return e

## What a cell's surface is made of: its painted material, else the level's, else "default:<slot>".
## A Tiles zone floor uses the level's tiles material, as in the game.
func _surface_key(slot: String, c: Vector2i) -> String:
	if paint.has(slot) and paint[slot].has(c): return paint[slot][c]
	var s := slot
	if slot == "floor" and zones.has("tiles") and zones["tiles"].has(c): s = "tiles"
	var id := str(materials.get(s, ""))
	return id if id != "" else "default:" + s

func _nice_key(k: String) -> String:
	return "default" if k.begins_with("default:") else k

# ---------------------------------------------------------------- drawing
func _cell_at(p: Vector2) -> Vector2i:
	var q := (p - pan) / zoom
	return Vector2i(floori(q.x), floori(q.y))

func _in_grid(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < grid_size and c.y < grid_size

func _cell_rect(c: Vector2i) -> Rect2:
	return Rect2(pan + Vector2(c) * zoom, Vector2(zoom, zoom))

## The strip `w` wide along side `d` of `r`, inside it
func _edge(r: Rect2, d: Vector2i, w: float) -> Rect2:
	if d.x > 0: return Rect2(r.end.x - w, r.position.y, w, r.size.y)
	if d.x < 0: return Rect2(r.position.x, r.position.y, w, r.size.y)
	if d.y > 0: return Rect2(r.position.x, r.end.y - w, r.size.x, w)
	return Rect2(r.position.x, r.position.y, r.size.x, w)

## A little label on a dark pill, its top-left corner at `p`
func _tag(p: Vector2, text: String, col: Color, size := 11) -> void:
	var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	canvas.draw_rect(Rect2(p, ts + Vector2(6, 2)), Color(0, 0, 0, 0.78))
	canvas.draw_string(font, p + Vector2(3, 1 + font.get_ascent(size)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _draw_canvas() -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), Color("080704"))
	if _can_grow() and zoom >= 7.0:             # the space round the map you can draw into
		var off := Vector2(fposmod(pan.x, zoom), fposmod(pan.y, zoom))
		for i in int(canvas.size.x / zoom) + 2:
			canvas.draw_line(Vector2(off.x + i * zoom, 0), Vector2(off.x + i * zoom, canvas.size.y), Color(1, 1, 1, 0.035))
		for i in int(canvas.size.y / zoom) + 2:
			canvas.draw_line(Vector2(0, off.y + i * zoom), Vector2(canvas.size.x, off.y + i * zoom), Color(1, 1, 1, 0.035))
	# only the cells on screen
	var lo := Vector2i(maxi(0, floori(-pan.x / zoom)), maxi(0, floori(-pan.y / zoom)))
	var hi := Vector2i(mini(grid_size - 1, floori((canvas.size.x - pan.x) / zoom)), mini(grid_size - 1, floori((canvas.size.y - pan.y) / zoom)))
	var tex_on := show_tex and zoom >= 5.0
	var surf := "ceiling" if view_ceiling else "floor"
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			_draw_cell(Vector2i(x, z), tex_on, surf)
	_draw_shading(lo, hi)
	if show_onion: _draw_onion()
	if show_zones: _draw_zones()
	if show_paint: _draw_paint_marks()
	if show_grid: _draw_grid(lo, hi)
	if show_objects:
		for o: Dictionary in objects:
			_draw_object(o, 1.0)
	_draw_markers()
	if _object_tool():
		if not show_objects: pass
		elif hover_obj >= 0 and hover_obj != selected and drag == "":
			_draw_outline(objects[hover_obj], Color(SEL, 0.6), 1.5)
		elif hover.x >= 0 and hover_obj < 0 and drag == "" and tool.begins_with("obj:"):
			var p := _snap_pos(_pos_at(mouse_px))           # ghost of what a click would place
			var t := tool.get_slice(":", 1)
			var ghost := _new_object(t, p, _wall_align(p, place_rot, t))
			if _is_stairs(t):
				_stair_square(ghost)
				ghost.rotation = _stair_facing(ghost)
			_draw_object(ghost, 0.45, false)
			_draw_arrow(ghost, Color(SEL, 0.5))
	elif tool != "area":
		_draw_hover()
	_draw_area()
	if show_objects:
		for k in multi:
			if k != selected and k < objects.size():
				_draw_outline(objects[k], Color(0, 0, 0, 0.7), 4.0)
				_draw_outline(objects[k], SEL, 2.0)
	if selected >= 0 and show_objects:
		_draw_gizmo(objects[selected])
	if drag == "box":
		var r := Rect2(box_from, Vector2.ZERO).expand(mouse_px)
		canvas.draw_rect(r, Color(SEL, 0.08))
		canvas.draw_rect(r, SEL, false, 1.5)
	canvas.draw_rect(Rect2(pan, Vector2(grid_size, grid_size) * zoom), GOLD, false, 1.5)
	_draw_rulers()
	_draw_hints()
	if show_paint: _draw_legend()
	if view_ceiling:
		_tag(Vector2(canvas.size.x * 0.5 - 90, 8), "CEILING VIEW  (C: floor)", GOLD, 14)

func _draw_cell(c: Vector2i, tex_on: bool, surf: String) -> void:
	var r := _cell_rect(c)
	var ch: String = grid[c.y][c.x]
	if ch == WALL:
		var exposed := false
		for d: Vector2i in DIRS4:
			var n := c + d
			if _in_grid(n) and grid[n.y][n.x] != WALL: exposed = true
		if not exposed:
			canvas.draw_rect(r, DEEP_WALL)
			if zoom >= 10.0:       # hatched like the solid mass on a floor plan; the lines join up cell to cell
				var hc := Color(1, 1, 1, 0.045)
				canvas.draw_line(r.position + Vector2(0, zoom), r.position + Vector2(zoom, 0), hc)
				canvas.draw_line(r.position + Vector2(0, zoom * 0.5), r.position + Vector2(zoom * 0.5, 0), hc)
				canvas.draw_line(r.position + Vector2(zoom * 0.5, zoom), r.position + Vector2(zoom, zoom * 0.5), hc)
			return
		if not tex_on:
			canvas.draw_rect(r, BASE_COLORS[WALL])
			return
		var tw := _thumb(_surface_key("wall", c))
		if tw.tex != null: canvas.draw_texture_rect(tw.tex, r, false, WALL_SHADE)
		else: canvas.draw_rect(r, (tw.avg as Color) * WALL_SHADE)
		return
	if ch == PIT:
		canvas.draw_rect(r, Color("030303"))
		canvas.draw_rect(r.grow(-zoom * 0.14), Color("100e0a"), false, maxf(1.0, zoom * 0.06))
		return
	if not tex_on:
		canvas.draw_rect(r, BASE_COLORS.get(ch, BASE_COLORS[FLOOR]))
		return
	var t := _thumb(_surface_key(surf, c))
	if t.tex != null: canvas.draw_texture_rect(t.tex, r, false, Color(0.9, 0.9, 0.95) if view_ceiling else Color.WHITE)
	else: canvas.draw_rect(r, t.avg)

## Contact shadows where floor meets wall (as if looking down into the rooms), and a lit rim on the wall tops
func _draw_shading(lo: Vector2i, hi: Vector2i) -> void:
	if zoom < 6.0: return
	var s1 := zoom * 0.1
	var s2 := zoom * 0.26
	var rim := maxf(1.0, zoom * 0.06)
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if grid[z][x] == WALL: continue
			var c := Vector2i(x, z)
			var r := _cell_rect(c)
			for d: Vector2i in DIRS4:
				var n := c + d
				if not _in_grid(n) or grid[n.y][n.x] != WALL: continue
				canvas.draw_rect(_edge(r, d, s2), Color(0, 0, 0, 0.16))
				canvas.draw_rect(_edge(r, d, s1), Color(0, 0, 0, 0.3))
				canvas.draw_rect(_edge(_cell_rect(n), -d, rim), Color(1, 0.95, 0.8, 0.3))

## The floor below this one (the one above, on the lowest floor) as a faint cyan outline of its open space,
## and its stairs, so floors line up
func _draw_onion() -> void:
	var other := floor_idx - 1 if floor_store.has(floor_idx - 1) else floor_idx + 1
	if not floor_store.has(other): return
	var fd: Dictionary = floor_store[other]
	var open := {}
	for z in grid_size:
		for x in grid_size:
			if fd.grid[z][x] != WALL: open[Vector2i(x, z)] = true
	var col := Color(0.35, 0.85, 1.0, 0.55)
	_outline_cells(open, col, maxf(1.0, zoom * 0.05), 0.0)
	for o: Dictionary in fd.objects:
		if _is_stairs(str(o.type)): _draw_object(o, 0.35, false)
	if zoom >= 9.0:
		_tag(Vector2(canvas.size.x - 200, 8), "cyan: " + _floor_name(other), col, 11)

func _draw_grid(lo: Vector2i, hi: Vector2i) -> void:
	if zoom < 7.0: return
	for i in range(lo.x, hi.x + 2):
		canvas.draw_line(pan + Vector2(i, lo.y) * zoom, pan + Vector2(i, hi.y + 1) * zoom, Color(0, 0, 0, 0.34 if i % 5 == 0 else 0.13))
	for i in range(lo.y, hi.y + 2):
		canvas.draw_line(pan + Vector2(lo.x, i) * zoom, pan + Vector2(hi.x + 1, i) * zoom, Color(0, 0, 0, 0.34 if i % 5 == 0 else 0.13))

## Cell numbers along the map's top and left edges, kept on screen when the map is scrolled past them
func _draw_rulers() -> void:
	if zoom < 4.0: return
	var step := 5 if zoom >= 9.0 else 10
	var ty := clampf(pan.y - 17.0, 2.0, canvas.size.y - 17.0)
	var lx := clampf(pan.x - 4.0, 26.0, canvas.size.x)
	for i in range(0, grid_size, step):
		var x := pan.x + (i + 0.5) * zoom
		if x > 0 and x < canvas.size.x:
			var w := font.get_string_size(str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			_tag(Vector2(x - w * 0.5 - 3, ty), str(i), DIM, 10)
		var y := pan.y + (i + 0.5) * zoom
		if y > 0 and y < canvas.size.y:
			var w := font.get_string_size(str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			_tag(Vector2(lx - w - 6, y - 7), str(i), DIM, 10)

## The top-left cell of every separate patch in `cells` (side-by-side neighbours make one patch) of at least
## `min_cells` cells
func _patch_tops(cells: Dictionary, min_cells := 1) -> Array:
	var seen := {}
	var tops: Array = []
	for start: Vector2i in cells:
		if seen.has(start): continue
		var best := start
		var todo: Array = [start]
		seen[start] = true
		var count := 0
		while not todo.is_empty():
			var c: Vector2i = todo.pop_back()
			count += 1
			if c.y < best.y or (c.y == best.y and c.x < best.x): best = c
			for d: Vector2i in DIRS4:
				var n: Vector2i = c + d
				if cells.has(n) and not seen.has(n):
					seen[n] = true
					todo.append(n)
		if count >= min_cells: tops.append(best)
	return tops

## An outline `w` wide round each patch of `cells`, `inset` pixels in from the cell edges
func _outline_cells(cells: Dictionary, col: Color, w: float, inset: float) -> void:
	for c: Vector2i in cells:
		var r := _cell_rect(c).grow(-inset)
		for d: Vector2i in DIRS4:
			if not cells.has(c + d): canvas.draw_rect(_edge(r, d, w), col)

## Each zone as a light wash with a solid outline round every patch, and its name on the patch
func _draw_zones() -> void:
	var w := maxf(1.5, zoom * 0.07)
	var i := 0
	for zn in ZONES:
		var cells: Dictionary = zones[zn]
		if cells.is_empty(): continue
		var col: Color = ZONES[zn]
		for c: Vector2i in cells:
			canvas.draw_rect(_cell_rect(c), Color(col, 0.16))
		_outline_cells(cells, col, w, 1.0 + (i % 3) * w)       # overlapping zones step their outlines inwards
		if zoom >= 9.0:
			for top: Vector2i in _patch_tops(cells):
				_tag(pan + Vector2(top) * zoom + Vector2(3, 3 + (i % 3) * 14), str(zn).to_upper().replace("_", " "), col, 10)
		i += 1

## Painted materials: an outline in the material's own colour round each painted patch, and its name, for
## the surfaces this view shows. The floor view also flags painted ceilings with a corner mark.
func _draw_paint_marks() -> void:
	var w := maxf(1.5, zoom * 0.08)
	for slot in (["ceiling"] if view_ceiling else ["floor", "wall"]):
		var by_mat := {}
		for c: Vector2i in paint[slot]:
			if not by_mat.has(paint[slot][c]): by_mat[paint[slot][c]] = {}
			by_mat[paint[slot][c]][c] = true
		for id in by_mat:
			var col := _paint_colour(id)
			_outline_cells(by_mat[id], Color(0, 0, 0, 0.6), w + 2.0, w * 0.5)
			_outline_cells(by_mat[id], col, w, w * 0.5 + 1.0)
			if zoom >= 9.0:
				for top: Vector2i in _patch_tops(by_mat[id], 4):      # scattered specks go unlabelled (the legend has them)
					_tag(pan + (Vector2(top) + Vector2(0, 1)) * zoom + Vector2(3, -17), id, col, 10)
	if not view_ceiling:
		var k := maxf(4.0, zoom * 0.32)
		for c: Vector2i in paint["ceiling"]:
			var e := _cell_rect(c).end
			var col := _paint_colour(paint["ceiling"][c])
			canvas.draw_colored_polygon(PackedVector2Array([e, e - Vector2(k, 0), e - Vector2(0, k)]), col)

## Bottom-left of the map: every material painted on this level and how many cells of each surface
func _draw_legend() -> void:
	var rows := {}
	for slot in PAINT_SLOTS:
		for c in paint[slot]:
			var id: String = paint[slot][c]
			if not rows.has(id): rows[id] = {"floor": 0, "wall": 0, "ceiling": 0}
			rows[id][slot] += 1
	if rows.is_empty(): return
	var lines := {}
	var width := 90.0
	for id in rows:
		var parts := []
		for slot in PAINT_SLOTS:
			if rows[id][slot] > 0: parts.append("%s %d" % [slot, rows[id][slot]])
		lines[id] = "%s   %s" % [id, "  ".join(parts)]
		width = maxf(width, font.get_string_size(lines[id], HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 44)
	var lh := 22.0
	var box := Rect2(8, canvas.size.y - 14 - lh * (rows.size() + 1), width, lh * (rows.size() + 1) + 6)
	canvas.draw_rect(box, Color(0, 0, 0, 0.8))
	canvas.draw_rect(box, Color("3a3522"), false, 1.0)
	canvas.draw_string(font, box.position + Vector2(8, 16), "PAINTED MATERIALS", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, GOLD)
	var y := box.position.y + lh
	for id in rows:
		var sw := Rect2(box.position.x + 8, y + 2, 18, 18)
		var t := _thumb(id)
		if t.tex != null: canvas.draw_texture_rect(t.tex, sw, false)
		else: canvas.draw_rect(sw, t.avg)
		canvas.draw_rect(sw, _paint_colour(id), false, 2.0)
		canvas.draw_string(font, Vector2(sw.end.x + 8, y + 16), lines[id], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, CREAM)
		y += lh

func _draw_markers() -> void:
	for m in MARKERS:
		var c = markers[m]
		if c == null: continue
		var p: Vector2 = pan + (Vector2(c) + Vector2(0.5, 0.5)) * zoom
		var rad := maxf(zoom * 0.42, 7.0)
		canvas.draw_circle(p + Vector2(1.5, 2.0), rad, Color(0, 0, 0, 0.5))
		canvas.draw_circle(p, rad, MARKERS[m])
		canvas.draw_arc(p, rad, 0, TAU, 24, Color.BLACK, 1.5)
		var fs := maxi(8, int(rad * 1.2))
		var letter: String = str(m).substr(0, 1).to_upper()
		var ls := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		canvas.draw_string(font, p + Vector2(-ls.x * 0.5, fs * 0.36), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.BLACK)
		if m == "spawn": _draw_look_arrow(p, rad)
		elif m == "drop_hole": _draw_drop_hole_indicator(p, rad)
		if zoom >= 12.0:
			var tag_text: String = m.to_upper()
			if m == "drop_hole":
				tag_text = "DROP HOLE [TO F%d]" % (floor_idx - 1)
			_tag(p + Vector2(rad + 4, -8), tag_text, MARKERS[m], 10)

## Visual transition indicator for a drop hole / pit descent
func _draw_drop_hole_indicator(p: Vector2, rad: float) -> void:
	canvas.draw_circle(p, rad * 0.72, Color(0.04, 0.04, 0.04, 0.95))
	canvas.draw_circle(p, rad * 0.42, Color(0.85, 0.4, 0.1, 0.8))
	canvas.draw_circle(p, rad * 0.18, Color.BLACK)
	var sz := rad * 0.55
	var pts := PackedVector2Array([p + Vector2(-sz * 0.45, -sz * 0.25), p + Vector2(0, sz * 0.4), p + Vector2(sz * 0.45, -sz * 0.25)])
	canvas.draw_polyline(pts, Color.WHITE, 1.8)

## An arrow out of the spawn marker showing where the player starts out looking
func _draw_look_arrow(p: Vector2, rad: float) -> void:
	var d := Vector2.from_angle(deg_to_rad(spawn_rot))
	var n := d.orthogonal()
	var tip := p + d * (rad + maxf(zoom * 1.1, 16.0))
	var base := p + d * (rad + 1.0)
	var head := maxf(zoom * 0.4, 7.0)
	var col: Color = MARKERS["spawn"]
	canvas.draw_line(base, tip - d * head * 0.5, Color.BLACK, 5.0)
	canvas.draw_line(base, tip - d * head * 0.5, col, 3.0)
	var tri := PackedVector2Array([tip, tip - d * head + n * head * 0.6, tip - d * head - n * head * 0.6])
	canvas.draw_colored_polygon(tri, col)
	canvas.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color.BLACK, 1.5)

## What the current tool is about to do under the mouse: the brush footprint, the rectangle being dragged,
## or the cell a fill starts from, filled with the colour or material it lays down
func _draw_hover() -> void:
	var grow := _can_grow()
	var at := hover_raw if grow else hover
	if at.x < -1000 or (not grow and hover.x < 0): return
	if tool.begins_with("mark:"):
		var r := _cell_rect(hover)
		canvas.draw_rect(r, Color(MARKERS.get(tool.get_slice(":", 1), Color.WHITE), 0.4))
		canvas.draw_rect(r, Color.WHITE, false, 1.5)
		return
	var m := "rect" if tool == "gen" else _mode_now()
	var cells: Array
	if rect_from.x >= 0: cells = _rect_cells(rect_from, at)
	elif m == "fill" or tool == "gen": cells = [at]
	else: cells = _brush_cells(at)
	var area := {}
	for c: Vector2i in cells:
		if grow or _in_grid(c): area[c] = true
	var tex: Texture2D = null
	if tool.begins_with("paint:") and paint_mat != "": tex = _thumb(paint_mat).tex
	var col := _tool_colour()
	var room := rect_from.x >= 0 and auto_walls and tool == "base:" + FLOOR and absi(at.x - rect_from.x) >= 2 and absi(at.y - rect_from.y) >= 2
	var lo := rect_from.min(at)
	var hi := rect_from.max(at)
	for c: Vector2i in area:
		var ring := room and (c.x == lo.x or c.y == lo.y or c.x == hi.x or c.y == hi.y)
		if ring: canvas.draw_rect(_cell_rect(c), Color(0.15, 0.13, 0.1, 0.85))
		elif tex != null: canvas.draw_texture_rect(tex, _cell_rect(c), false, Color(1, 1, 1, 0.8))
		else: canvas.draw_rect(_cell_rect(c), Color(col, 0.5))
	_outline_cells(area, Color.WHITE, 1.5, 0.0)
	if rect_from.x >= 0:
		var sz := (at - rect_from).abs() + Vector2i.ONE
		var what := "GENERATE " if tool == "gen" else ("ROOM " if room else "")
		_tag(mouse_px + Vector2(14, 10), "%s%d x %d" % [what, sz.x, sz.y], CREAM, 12)
	elif tool == "gen":
		_tag(mouse_px + Vector2(14, 10), "drag the area to generate", CREAM, 12)
	elif grow and not _in_grid(at):
		_tag(mouse_px + Vector2(14, 10), "draws outside: the map grows", CREAM, 12)
	elif m == "fill":
		_tag(mouse_px + Vector2(14, 10), "FILL", CREAM, 12)

func _tool_colour() -> Color:
	var what := tool.get_slice(":", 1)
	match tool.get_slice(":", 0):
		"base": return Color("8a7f68") if what == WALL else BASE_COLORS.get(what, Color.WHITE)
		"zone": return ZONES.get(what, Color.WHITE)
		"paint": return _paint_colour(paint_mat)
		"gen": return Color("3fd1a0")
	return Color.WHITE

## Ctrl held = fill, Shift held = rectangle, otherwise the mode picked in the bar over the map
func _mode_now() -> String:
	if Input.is_key_pressed(KEY_CTRL): return "fill"
	if Input.is_key_pressed(KEY_SHIFT): return "rect"
	return mode

# ---------------------------------------------------------------- input
## Zoom by `factor`, keeping the map point under `at` fixed. `smooth`: glide there over a few frames (the
## mouse wheel); a trackpad pinch already comes in small steps and is taken at once.
func _zoom_at(at: Vector2, factor: float, smooth := false) -> void:
	if smooth:
		zoom_goal = clampf(zoom_goal * factor, 4.0, 80.0)
		zoom_pivot = at
		set_process(true)
		return
	var before := (at - pan) / zoom
	zoom = clampf(zoom * factor, 4.0, 80.0)
	zoom_goal = zoom
	pan = at - before * zoom
	canvas.queue_redraw()

var zoom_goal := 14.0                # where a wheel zoom is gliding to
var zoom_pivot := Vector2.ZERO       # the canvas point that stays put while it does

func _process(dt: float) -> void:
	if canvas == null or is_equal_approx(zoom, zoom_goal):
		set_process(false)
		return
	var before := (zoom_pivot - pan) / zoom
	zoom = lerpf(zoom, zoom_goal, minf(1.0, dt * 16.0))
	if absf(zoom - zoom_goal) < 0.02: zoom = zoom_goal
	pan = zoom_pivot - before * zoom
	canvas.queue_redraw()

func _canvas_input(ev: InputEvent) -> void:
	if ev is InputEventMagnifyGesture:              # trackpad pinch
		_zoom_at((ev as InputEventMagnifyGesture).position, (ev as InputEventMagnifyGesture).factor)
	elif ev is InputEventPanGesture:                # trackpad two-finger scroll: move the map, Ctrl = zoom
		var pg := ev as InputEventPanGesture
		if pg.ctrl_pressed or pg.meta_pressed:
			_zoom_at(pg.position, 1.0 - pg.delta.y * 0.05)
		else:
			pan -= pg.delta * 18.0
			canvas.queue_redraw()
	elif ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			var up := mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_LEFT
			if (mb.shift_pressed or mb.alt_pressed) and _object_tool() and selected >= 0 and selected < objects.size() and multi.size() <= 1:
				if mb.pressed: _wheel_edit(up, mb.alt_pressed)      # (Shift can turn the wheel sideways: both count)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_at(mb.position, 1.12 if up else 1.0 / 1.12, true)
		elif panning and not mb.pressed and mb.button_index == pan_button:
			panning = false                             # whatever Space is doing by now
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_MIDDLE or (mb.button_index == MOUSE_BUTTON_LEFT and _space_held())):
			_let_go()
			panning = true
			pan_button = mb.button_index
		elif panning:
			pass                                        # another button while panning: nothing
		elif (mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT) and tool == "area":
			_area_press(mb)
		elif (mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT) and _object_tool():
			_object_press(mb)
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			var c := _cell_at(mb.position)
			if not mb.pressed:
				if rect_from.x >= 0:
					_apply_rect(rect_from, c if _can_grow() else c.clamp(Vector2i.ZERO, Vector2i(grid_size - 1, grid_size - 1)))
					rect_from = Vector2i(-1, -1)
				painting = false
				canvas.queue_redraw()
				return
			erasing = mb.button_index == MOUSE_BUTTON_RIGHT
			if mb.alt_pressed and not erasing and tool.begins_with("paint:"):
				_eyedrop(c)
				return
			if not _in_grid(c) and not _can_grow(): return
			_push_undo()
			stroke_seed = randi()
			var m := "brush" if tool.begins_with("mark:") else ("rect" if tool == "gen" else _mode_now())
			if m == "fill" and not _in_grid(c): m = "brush"
			if m == "fill": _apply_cells(_flood_cells(c))
			elif m == "rect": rect_from = c
			else:
				painting = true
				_apply(c)
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		mouse_px = mm.position
		# a button that came up without the map hearing of it (the window lost focus, a dialog opened over it):
		# whatever it was doing stops here, instead of following the mouse about with no button down
		if panning and not (mm.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_MIDDLE)): panning = false
		if not (mm.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT)): _let_go()
		if panning:
			pan += mm.relative
		elif area_from.x >= 0:
			pass                                        # the box is drawn from area_from to the mouse
		elif drag != "":
			_object_drag(mm.position)
		elif painting and tool == "mark:spawn" and not erasing:
			_face_spawn(mm.position)                # drag from the spawn marker to turn where the player looks
		elif painting:
			_apply(_cell_at(mm.position))
		var c := _cell_at(mm.position)
		hover = c if _in_grid(c) else Vector2i(-1, -1)
		hover_raw = c
		hover_obj = _obj_at(mm.position) if _object_tool() and show_objects and drag == "" else -1
		canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
		if panning:
			canvas.mouse_default_cursor_shape = Control.CURSOR_DRAG
		elif _object_tool() and (drag == "size" or (drag == "" and _grip_at(mm.position) >= 0)):
			# a resize arrow the way the grip pulls on screen
			var pull := Vector2.RIGHT
			if drag == "size": pull = grip.get("dir_w", Vector2.RIGHT)
			else:
				var og: Dictionary = objects[selected]
				pull = _obj_xf(og).basis_xform(_grips(og)[_grip_at(mm.position)].dir as Vector2)
			canvas.mouse_default_cursor_shape = Control.CURSOR_HSIZE if absf(pull.x) >= absf(pull.y) else Control.CURSOR_VSIZE
			hover_obj = -1
		elif _object_tool() and (_on_handle(mm.position) or drag == "rotate"):
			canvas.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		elif _object_tool() and (hover_obj >= 0 or drag == "move"):
			canvas.mouse_default_cursor_shape = Control.CURSOR_MOVE
		if tool == "area":
			pass                                        # its own hints stay up (_area_status)
		elif drag != "" and selected >= 0:
			_status(_describe(objects[selected]))
		elif hover_obj >= 0:
			_status(_describe(objects[hover_obj]) + "   click to select, drag to move, right click deletes")
		elif hover.x >= 0:
			_status(_describe_cell(hover))
		canvas.queue_redraw()

# ---------------------------------------------------------------- area selection
## The Select area tool (S): drag a box of cells on the map, then act on everything in it at once: Del empties
## it (objects, zones, paint, markers; the rooms stay), Shift+Del also fills it with wall, Ctrl+C / Ctrl+X /
## Ctrl+V copy, cut and paste it, rooms and all (onto another floor or another level too). A click outside
## the box, a right click or Esc drops it.
var area := Rect2i()                 # the selected cells (no size: nothing selected)
var area_from := Vector2i(-1, -1)    # the cell the box being dragged out started on
var clip := {}                       # what was copied: {size, grid (rows of cells, or null for objects only), zones, paint, objects}

func _area_press(mb: InputEventMouseButton) -> void:
	var c := _cell_at(mb.position).clamp(Vector2i.ZERO, Vector2i(grid_size - 1, grid_size - 1))
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if mb.pressed:
			area = Rect2i()
			area_from = Vector2i(-1, -1)
			_area_status()
		canvas.queue_redraw()
		return
	if mb.pressed:
		area_from = c
	elif area_from.x >= 0:
		area = Rect2i(area_from.min(c), (area_from - c).abs() + Vector2i.ONE) if c != area_from else Rect2i()
		area_from = Vector2i(-1, -1)
		_area_status()
	canvas.queue_redraw()

func _area_status() -> void:
	if not area.has_area():
		_status("Select area: drag a box on the map. Ctrl+A takes the whole floor, Ctrl+V pastes at the mouse")
		return
	var n := 0
	for o: Dictionary in objects:
		if area.has_point(Vector2i(roundi(o.pos_x), roundi(o.pos_y))): n += 1
	_status("%d x %d cells, %d objects selected.   Del: empty it   Shift+Del: wall it in   Ctrl+C copy   Ctrl+X cut   Ctrl+V paste   Esc: drop" % [area.size.x, area.size.y, n])

## The whole floor (Ctrl+A with the area tool)
func _area_all() -> void:
	area = Rect2i(0, 0, grid_size, grid_size)
	_area_status()
	canvas.queue_redraw()

## The selected cells that can be edited: the map's border stays wall
func _area_inner() -> Array:
	var out: Array = []
	for z in range(maxi(area.position.y, 1), mini(area.end.y, grid_size - 1)):
		for x in range(maxi(area.position.x, 1), mini(area.end.x, grid_size - 1)):
			out.append(Vector2i(x, z))
	return out

## Empty the selection: its objects, zones, painted materials and markers go (the spawn stays unless the cells
## are walled in). `terrain`: also turn every cell into this (WALL, FLOOR or PIT); "" leaves the rooms as they are.
func _area_clear(terrain := "", undo := true) -> void:
	if not area.has_area(): return
	if undo: _push_undo()
	var gone := 0
	for i in range(objects.size() - 1, -1, -1):
		if i < objects.size() and area.has_point(Vector2i(roundi(objects[i].pos_x), roundi(objects[i].pos_y))):
			_delete_object(i)
			gone += 1
	multi = []
	selected = -1
	for z in zones:
		for c: Vector2i in zones[z].keys():
			if area.has_point(c): zones[z].erase(c)
	for slot in paint:
		for c: Vector2i in paint[slot].keys():
			if area.has_point(c): paint[slot].erase(c)
	for m in markers:
		if markers[m] != null and area.has_point(markers[m]) and (m != "spawn" or terrain == WALL): markers[m] = null
	if terrain != "":
		for c: Vector2i in _area_inner(): grid[c.y][c.x] = terrain
	_sync_inspector()
	_mark_dirty()
	_status("%s %d x %d cells (%d objects removed). Ctrl+Z brings it back" % [
		{"": "Emptied", WALL: "Walled in", FLOOR: "Cleared to open floor", PIT: "Made a pit of"}.get(terrain, "Changed"), area.size.x, area.size.y, gone])

## Cut the selected columns (or rows) right out of the map, on every floor: what lay beyond them closes up
## against what lay before, so stairs and shafts still line up floor to floor. Whole columns go, however tall
## the box is. The map is square, so it only gets smaller when the other direction has as many spare lines of
## solid wall at its far edge; otherwise the space freed ends up as solid wall at the far edge of this
## direction (which costs nothing in the game: buried wall is neither built nor drawn).
func _area_cut_strip(columns: bool) -> void:
	var what := "columns" if columns else "rows"
	if not area.has_area():
		_status("Drag a box over the %s to cut out first (Select area, S)" % what)
		return
	var n := grid_size
	var all := _all_floors()
	# is line `i` (a column, or a row) solid wall from end to end on every floor?
	var solid := func(i: int, cols: bool) -> bool:
		if i < 0 or i >= n: return true
		for f in all:
			var g: Array = all[f].grid
			for j in n:
				if (g[j][i] if cols else g[i][j]) != WALL: return false
		return true
	var a := clampi(area.position.x if columns else area.position.y, 0, n)
	var b := clampi(area.end.x if columns else area.end.y, 0, n)          # one past the last line to go
	# the line that lands on the map's border has to be solid already: if it isn't, the border line stays
	if a <= 0: a = 0 if solid.call(b, columns) else 1
	if b >= n: b = n if solid.call(a - 1, columns) else n - 1
	var count := b - a
	if count <= 0 or n - count < 8:
		_status("Those %s can't be cut out: nothing would be left of the map" % what)
		return
	for f in all:
		for o: Dictionary in all[f].objects:
			if not _is_stairs(str(o.type)): continue
			var inside := 0
			var cells := _stair_cells(o)
			for c: Vector2i in cells:
				var i := c.x if columns else c.y
				if i >= a and i < b: inside += 1
			if inside > 0 and inside < cells.size():
				_status("A stairwell on %s stands across the edge of the box: take all of it in, or none" % _floor_name(f))
				return
	_push_undo()
	for f in all:
		var fd: Dictionary = all[f]
		var ng: Array = []
		if columns:
			for z in n:
				var row: Array = (fd.grid[z] as Array).slice(0, a) + (fd.grid[z] as Array).slice(b)
				for i in count: row.append(WALL)
				ng.append(row)
		else:
			for z in n:
				if z >= a and z < b: continue
				ng.append((fd.grid[z] as Array).duplicate())
			for i in count:
				var row: Array = []
				row.resize(n)
				row.fill(WALL)
				ng.append(row)
		fd.grid = ng
		for k in fd.zones:
			var moved := {}
			for c: Vector2i in fd.zones[k]:
				var i := c.x if columns else c.y
				if i < a: moved[c] = true
				elif i >= b: moved[c - (Vector2i(count, 0) if columns else Vector2i(0, count))] = true
			fd.zones[k] = moved
		for k in fd.paint:
			var moved := {}
			for c: Vector2i in fd.paint[k]:
				var i := c.x if columns else c.y
				if i < a: moved[c] = fd.paint[k][c]
				elif i >= b: moved[c - (Vector2i(count, 0) if columns else Vector2i(0, count))] = fd.paint[k][c]
			fd.paint[k] = moved
		for m in fd.markers:
			var c = fd.markers[m]
			if c == null: continue
			var i: int = c.x if columns else c.y
			if i >= a and i < b: fd.markers[m] = null
			elif i >= b: fd.markers[m] = c - (Vector2i(count, 0) if columns else Vector2i(0, count))
		var kept: Array = []
		for o: Dictionary in fd.objects:
			var i := roundi(o.pos_x if columns else o.pos_y)
			if i >= a and i < b: continue
			if i >= b:
				if columns: o.pos_x -= count
				else: o.pos_y -= count
			kept.append(o)
		fd.objects = kept
	for f in all:
		if f == floor_idx: _load_floor(all[f])
		else: floor_store[f] = all[f]
	selected = -1
	multi = []
	area = Rect2i()
	# the square can shrink too if the other direction ends in as many lines of nothing
	var spare := true
	all = _all_floors()
	for i in range(n - count - 1, n):
		for f in all:
			var g: Array = all[f].grid
			for j in n:
				if (g[i][j] if columns else g[j][i]) != WALL: spare = false
	for f in all:
		for o: Dictionary in all[f].objects:
			if (o.pos_y if columns else o.pos_x) > n - count - 2: spare = false
		for m in all[f].markers:
			var c = all[f].markers[m]
			if c != null and (c.y if columns else c.x) > n - count - 2: spare = false
	if spare:
		_reframe(n - count, Vector2i.ZERO)
		_status("Cut out %d %s on every floor: the map is %d x %d now. Ctrl+Z brings them back" % [count, what, grid_size, grid_size])
	else:
		_status("Cut out %d %s on every floor and closed the gap. The map is square and its %s are still in use, so it stays %d x %d: the room freed is solid wall at the far edge" % [
			count, what, "last rows" if columns else "last columns", n, n])
	_sync_inspector()
	_mark_dirty()
	_fit()

## Keep only the selected box: every floor is cut down to it (with a wall border round it)
func _area_crop() -> void:
	if not area.has_area():
		_status("Drag a box round what to keep first (Select area, S)")
		return
	_push_undo()
	var n := clampi(maxi(area.size.x, area.size.y) + 2, 8, MAX_SIZE)
	_reframe(n, Vector2i(1, 1) - area.position)
	area = Rect2i()
	multi = []
	_mark_dirty()
	_fit()
	_status("Cropped every floor to the box: the map is %d x %d now. Ctrl+Z undoes it" % [n, n])

## Ctrl+C. With the area tool: the selected cells and everything on them. Otherwise: the selected objects.
func _copy() -> bool:
	if tool == "area":
		if not area.has_area():
			_status("Nothing selected to copy: drag a box with the Select area tool first")
			return false
		var rows: Array = []
		for dz in area.size.y:
			var row: Array = []
			for dx in area.size.x:
				var c := area.position + Vector2i(dx, dz)
				row.append(grid[c.y][c.x] if _in_grid(c) else WALL)
			rows.append(row)
		clip = {"size": area.size, "at": area.position, "grid": rows, "zones": {}, "paint": {}, "objects": []}
		for z in zones:
			clip.zones[z] = []
			for c: Vector2i in zones[z]:
				if area.has_point(c): clip.zones[z].append(c - area.position)
		for slot in paint:
			clip.paint[slot] = {}
			for c: Vector2i in paint[slot]:
				if area.has_point(c): clip.paint[slot][c - area.position] = paint[slot][c]
		for o: Dictionary in objects:
			if area.has_point(Vector2i(roundi(o.pos_x), roundi(o.pos_y))) and not _is_stairs(str(o.type)):
				var d: Dictionary = o.duplicate(true)
				d.pos_x -= area.position.x
				d.pos_y -= area.position.y
				clip.objects.append(d)
		_status("Copied %d x %d cells and %d objects. Ctrl+V pastes at the mouse, Ctrl+Shift+V on the same cells (of another floor, say). Stairwells are not copied" % [area.size.x, area.size.y, clip.objects.size()])
		return true
	var g := _group()
	if g.is_empty():
		_status("Nothing selected to copy")
		return false
	var lo := Vector2(INF, INF)
	for k in g: lo = lo.min(Vector2(objects[k].pos_x, objects[k].pos_y))
	lo = lo.floor()
	clip = {"size": Vector2i.ONE, "at": Vector2i(lo), "grid": null, "zones": {}, "paint": {}, "objects": []}
	for k in g:
		if _is_stairs(str(objects[k].type)): continue
		var d: Dictionary = objects[k].duplicate(true)
		d.pos_x -= lo.x
		d.pos_y -= lo.y
		clip.objects.append(d)
	_status("Copied %d objects. Ctrl+V pastes them at the mouse" % clip.objects.size())
	return true

## Ctrl+X: copy, then the area is walled in (it has moved away), or the copied objects deleted
func _cut() -> void:
	if not _copy(): return
	if tool == "area": _area_clear(WALL)
	else: _delete_selected()

## Ctrl+V: what was copied goes down with its top left corner on the cell under the mouse. `in_place`
## (Ctrl+Shift+V): on the very cells it was copied from, which on another floor puts it straight above or below.
func _paste(in_place := false) -> void:
	if clip.is_empty():
		_status("Nothing copied yet: select something and press Ctrl+C")
		return
	var at: Vector2i = clip.at if in_place else (hover if hover.x >= 0 else (area.position if area.has_area() else Vector2i(1, 1)))
	_push_undo()
	var size: Vector2i = clip.size
	if clip.grid != null:
		var was := area
		area = Rect2i(at, size)
		_area_clear("", false)                           # what was there makes way
		area = was
		for dz in size.y:
			for dx in size.x:
				var c := at + Vector2i(dx, dz)
				if c.x < 1 or c.y < 1 or c.x >= grid_size - 1 or c.y >= grid_size - 1: continue
				grid[c.y][c.x] = clip.grid[dz][dx]
		for z in clip.zones:
			if not zones.has(z): continue
			for d: Vector2i in clip.zones[z]:
				var c := at + d
				if c.x >= 1 and c.y >= 1 and c.x < grid_size - 1 and c.y < grid_size - 1 and grid[c.y][c.x] != WALL: zones[z][c] = true
		for slot in clip.paint:
			if not paint.has(slot): continue
			for d: Vector2i in clip.paint[slot]:
				var c := at + d
				if _in_grid(c): paint[slot][c] = clip.paint[slot][d]
	var made: Array = []
	for src: Dictionary in clip.objects:
		var o: Dictionary = src.duplicate(true)
		o.pos_x += at.x
		o.pos_y += at.y
		if o.pos_x < 0.0 or o.pos_y < 0.0 or o.pos_x > grid_size - 1 or o.pos_y > grid_size - 1: continue
		objects.append(o)
		made.append(objects.size() - 1)
	if clip.grid != null:
		area = Rect2i(at, size).intersection(Rect2i(0, 0, grid_size, grid_size))
		_status("Pasted %d x %d cells and %d objects at %d, %d (parts off the map are left out). Ctrl+Z undoes it" % [size.x, size.y, made.size(), at.x, at.y])
	else:
		selected = made[-1] if not made.is_empty() else -1
		multi = made if made.size() > 1 else []
		_status("Pasted %d objects: drag one to move them all" % made.size())
	_sync_inspector()
	_mark_dirty()

## Every object on this floor becomes the selection (Ctrl+A with the Select tool)
func _select_all_objects() -> void:
	multi = range(objects.size()) if objects.size() > 1 else []
	selected = objects.size() - 1
	_sync_inspector()
	_status("%d objects selected: drag one to move them all, R rotates, Ctrl+C copies, Del deletes" % objects.size())
	canvas.queue_redraw()

## The arrow keys: the selected objects a snap step that way (a whole cell with Shift)
func _nudge(d: Vector2, undo: bool) -> void:
	var g := _group()
	if g.is_empty(): return
	if undo: _push_undo()
	var step := 1.0 if Input.is_key_pressed(KEY_SHIFT) or not snap else SNAP_STEP
	for k in g:
		var o: Dictionary = objects[k]
		if _is_stairs(str(o.type)): continue          # a stairwell is moved by dragging: its other ends follow
		o.pos_x = clampf(o.pos_x + d.x * step, 0.0, grid_size - 1)
		o.pos_y = clampf(o.pos_y + d.y * step, 0.0, grid_size - 1)
	_sync_inspector()
	_mark_dirty()

func _draw_area() -> void:
	var r := area
	if area_from.x >= 0:
		var c := _cell_at(mouse_px).clamp(Vector2i.ZERO, Vector2i(grid_size - 1, grid_size - 1))
		r = Rect2i(area_from.min(c), (area_from - c).abs() + Vector2i.ONE)
	if not r.has_area(): return
	var px := Rect2(pan + Vector2(r.position) * zoom, Vector2(r.size) * zoom)
	canvas.draw_rect(px, Color(SEL, 0.12))
	canvas.draw_rect(px.grow(1.0), Color(0, 0, 0, 0.8), false, 4.0)
	canvas.draw_rect(px, SEL, false, 2.0)
	_tag(px.position + Vector2(4, 4), "%d x %d" % [r.size.x, r.size.y], SEL, 12)      # inside the box: clear of the rulers

## The status line for a cell: where it is, what its surfaces are made of (painted or the level's) and its zones
func _describe_cell(c: Vector2i) -> String:
	var bits := ["cell %d, %d" % [c.x, c.y]]
	var slots := ["wall"] if grid[c.y][c.x] == WALL else (["pit"] if grid[c.y][c.x] == PIT else ["floor", "ceiling"])
	for slot in slots:
		if slot == "pit":
			bits.append("pit")
			continue
		bits.append("%s: %s%s" % [slot, _nice_key(_surface_key(slot, c)), " (painted)" if paint[slot].has(c) else ""])
	var tags := []
	for z in ZONES:
		if zones[z].has(c): tags.append(z)
	if not tags.is_empty(): bits.append("zones: " + ", ".join(tags))
	return "    ".join(bits)

func _brush_cells(c: Vector2i) -> Array:
	var out: Array = []
	var half := brush / 2
	for dz in brush:
		for dx in brush:
			out.append(c + Vector2i(dx - half, dz - half))
	return out

func _rect_cells(a: Vector2i, b: Vector2i) -> Array:
	var out: Array = []
	for z in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
		for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			out.append(Vector2i(x, z))
	return out

## The area a fill click covers: cells joined side by side to `start` that look the same to the current tool
## (same terrain, same zone state, or the same material on that surface). Wall paint clicked on a floor
## cell does the walls round the whole open area instead: "paint this room's walls".
func _flood_cells(start: Vector2i) -> Array:
	var kind := tool.get_slice(":", 0)
	var what := tool.get_slice(":", 1)
	var room_walls: bool = kind == "paint" and what == "wall" and grid[start.y][start.x] != WALL
	var key := func(c: Vector2i) -> String:
		var wall: bool = grid[c.y][c.x] == WALL
		if room_walls: return "open" if not wall else "stop"
		match kind:
			"base": return grid[c.y][c.x]
			"zone": return "stop" if wall else str(zones[what].has(c))
			"paint":
				if (what == "wall") != wall: return "stop"
				return _surface_key(what, c)
		return "stop"
	var want: String = key.call(start)
	if want == "stop": return []
	var seen := {start: true}
	var todo: Array = [start]
	while not todo.is_empty():
		var c: Vector2i = todo.pop_back()
		for d: Vector2i in DIRS4:
			var n: Vector2i = c + d
			if n.x < 1 or n.y < 1 or n.x >= grid_size - 1 or n.y >= grid_size - 1 or seen.has(n): continue
			if key.call(n) == want:
				seen[n] = true
				todo.append(n)
	if not room_walls: return seen.keys()
	var walls := {}
	for c: Vector2i in seen:
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var n := c + Vector2i(dx, dz)
				if _in_grid(n) and grid[n.y][n.x] == WALL: walls[n] = true
	return walls.keys()

func _face_spawn(px: Vector2) -> void:
	var c = markers.get("spawn")
	if c == null: return
	var v := px - (pan + (Vector2(c) + Vector2(0.5, 0.5)) * zoom)
	if v.length() < maxf(zoom * 0.6, 10.0): return
	var a := snappedf(fposmod(rad_to_deg(v.angle()), 360.0), 15.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	if not is_equal_approx(a, spawn_rot):
		spawn_rot = fposmod(a, 360.0)
		_mark_dirty()
		_status("Player looks %d°   (hold Shift to snap to 15°)" % roundi(spawn_rot))
		canvas.queue_redraw()

func _apply(c: Vector2i) -> void:
	if tool.begins_with("mark:"):
		if c.x >= 1 and c.y >= 1 and c.x < grid_size - 1 and c.y < grid_size - 1:
			markers[tool.get_slice(":", 1)] = null if erasing else c
		_mark_dirty()
		return
	_apply_cells(_brush_cells(c))

func _apply_cells(cells: Array) -> void:
	var kind := tool.get_slice(":", 0)
	var what := tool.get_slice(":", 1)
	if _can_grow() and not erasing:
		var off := _grow_to(cells)
		if off != Vector2i.ZERO: cells = cells.map(func(c): return c + off)
	for p: Vector2i in cells:
		if kind == "paint" and what == "wall":
			if not _in_grid(p) or grid[p.y][p.x] != WALL: continue      # the border walls can be painted too
		elif p.x < 1 or p.y < 1 or p.x >= grid_size - 1 or p.y >= grid_size - 1: continue
		if kind == "base":
			grid[p.y][p.x] = (FLOOR if what == WALL else WALL) if erasing else what
			if grid[p.y][p.x] == WALL:      # solid cells: the game drops any zone tag on load
				for z in zones: zones[z].erase(p)
		elif kind == "paint":
			if what != "wall" and grid[p.y][p.x] == WALL: continue
			if erasing: paint[what].erase(p)
			elif paint_mat != "":
				var hv := absi(hash([p, stroke_seed]))
				if scatter < 100 and hv % 100 >= scatter: continue
				var mix: Array = [paint_mat] + paint_mix
				paint[what][p] = mix[(hv / 100) % mix.size()]
		elif kind == "zone" and grid[p.y][p.x] != WALL:
			if erasing: zones[what].erase(p)
			else: zones[what][p] = true
	_mark_dirty()

## A dragged rectangle: the generator's area, a room when auto walls is on (floor inside a wall ring), or
## just every cell in it
func _apply_rect(a: Vector2i, b: Vector2i) -> void:
	var cells := _rect_cells(a, b)
	if tool == "gen":
		var off := _grow_to(cells)
		_generate(Rect2i(a.min(b) + off, (a - b).abs() + Vector2i.ONE))
		return
	var room := auto_walls and tool == "base:" + FLOOR and not erasing and absi(a.x - b.x) >= 2 and absi(a.y - b.y) >= 2
	if not room:
		_apply_cells(cells)
		return
	var off := _grow_to(cells)
	var lo := a.min(b) + off
	var hi := a.max(b) + off
	for p: Vector2i in _rect_cells(lo, hi):
		if p.x < 1 or p.y < 1 or p.x >= grid_size - 1 or p.y >= grid_size - 1: continue
		var ring := p.x == lo.x or p.y == lo.y or p.x == hi.x or p.y == hi.y
		grid[p.y][p.x] = WALL if ring else FLOOR
		if ring:
			for z in zones: zones[z].erase(p)
	_mark_dirty()
	_status("Room %d x %d with walls round it (auto walls). Carve doorways with the Floor brush" % [hi.x - lo.x - 1, hi.y - lo.y - 1])

## level_editor_gen.gd
func _generate(_area: Rect2i) -> void:
	pass

## Take the material under the mouse into the brush (I, or Alt+click with a paint tool)
func _eyedrop(c: Vector2i) -> void:
	if not _in_grid(c): return
	var slot := "wall"
	if grid[c.y][c.x] != WALL:
		slot = "ceiling" if view_ceiling or tool == "paint:ceiling" else "floor"
	var k := _surface_key(slot, c)
	if k.begins_with("default:") or k == "":
		_status("The %s here is the game's default look: nothing to pick" % slot)
		return
	_set_paint_mat(k)
	_select_tool("paint:" + slot)
	_status("Picked %s from the %s" % [k, slot])

## Overridden by level_editor.gd, which also updates the buttons
func _select_tool(id: String) -> void:
	tool = id

func _set_paint_mat(id: String) -> void:
	paint_mat = id

# ---------------------------------------------------------------- undo
# ---------------------------------------------------------------- floors
func _live_floor() -> Dictionary:
	return {"grid": grid, "zones": zones, "paint": paint, "markers": markers, "objects": objects}

func _load_floor(fd: Dictionary) -> void:
	grid = fd.grid
	zones = fd.zones
	paint = fd.paint
	markers = fd.markers
	objects = fd.objects

func _copy_floor(fd: Dictionary) -> Dictionary:
	var z := {}
	for k in fd.zones: z[k] = fd.zones[k].duplicate()
	var pt := {}
	for k in fd.paint: pt[k] = fd.paint[k].duplicate()
	return {"grid": fd.grid.duplicate(true), "zones": z, "paint": pt, "markers": fd.markers.duplicate(), "objects": fd.objects.duplicate(true)}

## A new floor: solid everywhere (draw its rooms in), no zones, paint, markers or objects
func _new_floor() -> Dictionary:
	var g: Array = []
	for z in grid_size:
		var row := []
		row.resize(grid_size)
		row.fill(WALL)
		g.append(row)
	var zd := {}
	for z in ZONES: zd[z] = {}
	var mk := {}
	for m in MARKERS: mk[m] = null
	return {"grid": g, "zones": zd, "paint": {"wall": {}, "floor": {}, "ceiling": {}}, "markers": mk, "objects": []}

## Every floor, the live one included: int -> its fields
func _all_floors() -> Dictionary:
	var all := floor_store.duplicate()
	all[floor_idx] = _live_floor()
	return all

func _floor_numbers() -> Array:
	var ks: Array = _all_floors().keys()
	ks.sort()
	return ks

func _floor_name(f: int) -> String:
	if f == 0: return "Ground floor"
	return ("Floor %d" % f) if f > 0 else ("Basement %d" % -f)

func _switch_floor(f: int) -> void:
	if f == floor_idx or not floor_store.has(f): return
	floor_store[floor_idx] = _live_floor()
	_load_floor(floor_store[f])
	floor_store.erase(f)
	floor_idx = f
	selected = -1
	hover_obj = -1
	drag = ""
	rect_from = Vector2i(-1, -1)
	_floors_changed()
	_sync_inspector()
	if preview3d != null and preview3d.visible: preview3d.mark_stale()
	_update_info()
	canvas.queue_redraw()
	_status("Editing " + _floor_name(f))

## Overridden by level_editor.gd to refresh the floor picker
func _floors_changed() -> void:
	pass

# ---------------------------------------------------------------- growing the map
## Re-lay every floor on an n x n grid with its old cell (x, z) at (x, z) + off. Cells, zones, paint,
## markers and objects that end up outside are dropped; the new border is wall.
func _reframe(n: int, off: Vector2i) -> void:
	var all := _all_floors()
	var inner := func(c: Vector2i) -> bool: return c.x >= 1 and c.y >= 1 and c.x < n - 1 and c.y < n - 1
	for f in all:
		var fd: Dictionary = all[f]
		var ng: Array = []
		for z in n:
			var row := []
			for x in n:
				var o := Vector2i(x, z) - off
				var inside := o.x >= 0 and o.y >= 0 and o.x < grid_size and o.y < grid_size
				var edge := x == 0 or z == 0 or x == n - 1 or z == n - 1
				row.append(WALL if edge or not inside else fd.grid[o.y][o.x])
			ng.append(row)
		fd.grid = ng
		for k in fd.zones:
			var moved := {}
			for c: Vector2i in fd.zones[k]:
				if inner.call(c + off): moved[c + off] = true
			fd.zones[k] = moved
		for k in fd.paint:
			var moved := {}
			for c: Vector2i in fd.paint[k]:
				var d: Vector2i = c + off
				if d.x >= 0 and d.y >= 0 and d.x < n and d.y < n: moved[d] = fd.paint[k][c]
			fd.paint[k] = moved
		for m in fd.markers:
			var c = fd.markers[m]
			if c != null: fd.markers[m] = (c + off) if inner.call(c + off) else null
		var kept: Array = []
		for o: Dictionary in fd.objects:
			o.pos_x += off.x
			o.pos_y += off.y
			if o.pos_x >= 0 and o.pos_y >= 0 and o.pos_x <= n - 1 and o.pos_y <= n - 1: kept.append(o)
		fd.objects = kept
	grid_size = n
	for f in all:
		if f == floor_idx: _load_floor(all[f])
		else: floor_store[f] = all[f]
	selected = -1
	_sync_inspector()

## Drawing outside the map grows it (every floor) so `cells` land inside with a wall border round them.
## Returns how far existing cells moved (drawing above / left of the map shifts everything down / right).
func _grow_to(cells: Array) -> Vector2i:
	if cells.is_empty(): return Vector2i.ZERO
	var mn := Vector2i(1, 1)
	var mx := Vector2i(grid_size - 2, grid_size - 2)
	for c: Vector2i in cells:
		mn = mn.min(c)
		mx = mx.max(c)
	if mn.x >= 1 and mn.y >= 1 and mx.x <= grid_size - 2 and mx.y <= grid_size - 2:
		return Vector2i.ZERO
	var off := Vector2i(maxi(0, 1 - mn.x), maxi(0, 1 - mn.y))
	var n := maxi(grid_size + maxi(off.x, off.y), maxi(mx.x, mx.y) + maxi(off.x, off.y) + 2)
	if n > MAX_SIZE:
		_status("The map can't grow past %d x %d" % [MAX_SIZE, MAX_SIZE])
		n = MAX_SIZE
	_reframe(n, off)
	pan -= Vector2(off) * zoom                  # the map moves under the mouse, not the view
	if rect_from.x >= 0: rect_from += off
	_status("Map grown to %d x %d" % [grid_size, grid_size])
	return off

## Tools that may draw outside the map (and so grow it)
func _can_grow() -> bool:
	return tool == "base:" + FLOOR or tool == "base:" + PIT or tool == "gen"

## Shrink every floor to what is used (open cells and markers) plus a wall border
func _trim() -> void:
	var mn := Vector2i(grid_size, grid_size)
	var mx := Vector2i(-1, -1)
	var all := _all_floors()
	for f in all:
		var fd: Dictionary = all[f]
		for z in grid_size:
			for x in grid_size:
				if fd.grid[z][x] != WALL:
					mn = mn.min(Vector2i(x, z))
					mx = mx.max(Vector2i(x, z))
		for m in fd.markers:
			if fd.markers[m] != null:
				mn = mn.min(fd.markers[m])
				mx = mx.max(fd.markers[m])
	if mx.x < 0:
		_status("Nothing to trim to: the level has no open floor")
		return
	_push_undo()
	var n := maxi(maxi(mx.x - mn.x, mx.y - mn.y) + 3, 8)
	_reframe(n, Vector2i(1, 1) - mn)
	_mark_dirty()
	_fit()
	_status("Trimmed to %d x %d" % [n, n])

# ---------------------------------------------------------------- undo
## Undo steps hold the whole level (every floor): growing the map or adding a floor touches them all
func _snapshot() -> Dictionary:
	var fl := {}
	var all := _all_floors()
	for f in all: fl[f] = _copy_floor(all[f])
	return {"floors": fl, "floor": floor_idx, "size": grid_size, "selected": selected}

func _restore(s: Dictionary) -> void:
	floor_store = s.floors
	floor_idx = s.floor
	_load_floor(floor_store[floor_idx])
	floor_store.erase(floor_idx)
	grid_size = s.size
	selected = s.selected if s.selected < objects.size() else -1
	drag = ""
	_floors_changed()
	_sync_inspector()
	_mark_dirty()

func _push_undo() -> void:
	undo_stack.append(_snapshot())
	if undo_stack.size() > 80: undo_stack.pop_front()
	redo_stack.clear()
	insp_undo = -1

func _undo() -> void:
	if undo_stack.is_empty():
		_status("Nothing to undo")
		return
	redo_stack.append(_snapshot())
	_restore(undo_stack.pop_back())

func _redo() -> void:
	if redo_stack.is_empty():
		_status("Nothing to redo")
		return
	undo_stack.append(_snapshot())
	_restore(redo_stack.pop_back())

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
	return maxf(_thick_cells(o), 4.0 / zoom)

## The object's footprint in object space (cells): the box its gizmo outlines
func _obj_bounds(o: Dictionary) -> Rect2:
	if _is_stairs(str(o.type)):
		return Rect2(-0.5, 0.5 - STAIR_WIDE, STAIR_CELLS, STAIR_WIDE)
	match _shape(o.type):
		"corner", "arc":
			var pts := _shape_path(o)
			var r := Rect2(pts[0], Vector2.ZERO)
			for q in pts: r = r.expand(q)
			return r.grow(_obj_depth(o) * 0.5)
		"pillar", "column":
			var h := maxf(_thick_cells(o) * 0.5, 4.0 / zoom)
			return Rect2(-h, -h, h * 2.0, h * 2.0)
		"zone":
			var d := float(_param(o, "depth", 2.0))
			return Rect2(-d * 0.5, -o.scale * 0.5, d, o.scale)
	var d := _obj_depth(o)
	return Rect2(-d * 0.5, -o.scale * 0.5, d, o.scale)

## Is the canvas point `p` on object `o`? Bent walls count along their line only, so a click inside a round
## room reaches what's in it; everything else by its footprint.
func _obj_hit(o: Dictionary, p: Vector2) -> bool:
	var l := (_obj_xf(o).affine_inverse() * p) / zoom
	var slack := 6.0 / zoom
	if _shape(o.type) in ["corner", "arc"]:
		var pts := _shape_path(o)
		var reach := maxf(_obj_depth(o) * 0.5, slack)
		for i in pts.size() - 1:
			if l.distance_to(Geometry2D.get_closest_point_to_segment(l, pts[i], pts[i + 1])) <= reach: return true
		return false
	var b := _obj_bounds(o)
	if b.size.x < slack * 2.0: b = b.grow_individual(slack - b.size.x * 0.5, 0, slack - b.size.x * 0.5, 0)
	return b.grow(2.0 / zoom).has_point(l)

func _obj_at(p: Vector2) -> int:
	for i in range(objects.size() - 1, -1, -1):
		if _obj_hit(objects[i], p): return i
	return -1

## The rotate handle: a knob just past the facing arrow's tip
func _handle_px(o: Dictionary) -> Vector2:
	var xf := _obj_xf(o)
	return xf.origin + xf.x.normalized() * (maxf(_obj_bounds(o).end.x, 0.0) * zoom + maxf(zoom * 0.8, 26.0) + 9.0)

func _on_handle(p: Vector2) -> bool:
	return selected >= 0 and p.distance_to(_handle_px(objects[selected])) <= 9.0

# ---------------------------------------------------------------- resize grips
## The little squares round a selected object: drag one to size it on the map instead of typing in the
## inspector. What a grip sets is its `kind`: "width" (an end of a wall, door, arch or trigger: the other end
## stays where it is), "size" (a prop, about its middle), "thick" (a wall's thickness, a pillar's or column's
## width), "depth" (a trigger, along its arrow), "leg" (a corner wall's legs), "diameter" and "arc" (a curved
## wall). `at` is where it sits in the object's own space (cells; +x the way the object faces, +y along its
## span) and `dir` the way it is pulled to make the object bigger. They stand GRIP_OUT pixels off the object,
## so the smallest pillar can still be picked up by its middle. Snap applies (Alt: free). Stairwells have none.
const GRIP_OUT := 9.0
const GRIP_HIT := 8.0
var grip := {}                       # the grip being dragged (drag == "size"), with where it and the object started
var show_hints := true               # the line of the current tool's controls along the bottom of the map

func _grips(o: Dictionary) -> Array:
	var t := str(o.type)
	var out: Array = []
	if _is_stairs(t): return out
	var half: float = float(o.scale) * 0.5
	match _shape(t):
		"pillar", "column":
			var r := _thick_cells(o) * 0.5
			for d: Vector2 in [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0)]:
				out.append({"kind": "thick", "at": d * r, "dir": d})
		"corner":
			out.append({"kind": "leg", "at": Vector2(half * 2.0, 0), "dir": Vector2(1, 0)})
			out.append({"kind": "leg", "at": Vector2(0, half * 2.0), "dir": Vector2(0, 1)})
		"arc":
			var arc := deg_to_rad(clampf(float(_param(o, "arc", 90.0)), 5.0, 360.0))
			out.append({"kind": "diameter", "at": Vector2(half, 0), "dir": Vector2(1, 0)})
			for s: float in [-1.0, 1.0]:
				var v := Vector2.from_angle(s * arc * 0.5)
				out.append({"kind": "arc", "at": v * half, "dir": v})
		"zone":
			for s: float in [-1.0, 1.0]:
				out.append({"kind": "width", "at": Vector2(0, s * half), "dir": Vector2(0, s)})
			out.append({"kind": "depth", "at": Vector2(-float(_param(o, "depth", 2.0)) * 0.5, 0), "dir": Vector2(-1, 0)})
		_:
			var kind := "size" if _info(t).has("model") else "width"
			for s: float in [-1.0, 1.0]:
				out.append({"kind": kind, "at": Vector2(0, s * half), "dir": Vector2(0, s)})
			if (_info(t).get("params", {}) as Dictionary).has("thick"):
				out.append({"kind": "thick", "at": Vector2(-_thick_cells(o) * 0.5, 0), "dir": Vector2(-1, 0)})
	return out

## Where a grip is drawn and grabbed, in canvas pixels
func _grip_px(o: Dictionary, g: Dictionary) -> Vector2:
	var xf := _obj_xf(o)
	return xf * ((g.at as Vector2) * zoom) + xf.basis_xform(g.dir as Vector2).normalized() * GRIP_OUT

## The grip of the selected object under canvas point `p` (its place in _grips()), or -1
func _grip_at(p: Vector2) -> int:
	if selected < 0 or selected >= objects.size() or multi.size() > 1 or not show_objects: return -1
	var o: Dictionary = objects[selected]
	var gs := _grips(o)
	for i in gs.size():
		if p.distance_to(_grip_px(o, gs[i])) <= GRIP_HIT: return i
	return -1

func _grab_grip(g: Dictionary, p: Vector2) -> void:
	var o: Dictionary = objects[selected]
	grip = g.duplicate()
	grip["dir_w"] = (g.dir as Vector2).rotated(deg_to_rad(float(o.rotation)))      # the pull, on the map
	grip["m0"] = _pos_at(p)
	grip["pos0"] = Vector2(o.pos_x, o.pos_y)
	grip["scale0"] = float(o.scale)
	grip["thick0"] = _thick_cells(o) * CELL_M
	grip["depth0"] = float(_param(o, "depth", 2.0))
	drag = "size"

func _stepped(v: float, step: float) -> float:
	return v if (Input.is_key_pressed(KEY_ALT) or not snap) else snappedf(v, step)

## The grip follows the mouse: how far it has been pulled along its own direction since it was grabbed
func _resize_drag(p: Vector2) -> void:
	var o: Dictionary = objects[selected]
	var dir: Vector2 = grip.dir_w
	var d: float = (_pos_at(p) - (grip.m0 as Vector2)).dot(dir)
	var pos0: Vector2 = grip.pos0
	var top := _max_scale(str(o.type))
	match str(grip.kind):
		"width":
			var w := clampf(_stepped(float(grip.scale0) + d, SNAP_STEP), 0.5, top)
			var mid := pos0 + dir * (w - float(grip.scale0)) * 0.5      # the other end stays where it is
			o.scale = w
			o.pos_x = clampf(mid.x, 0.0, grid_size - 1)
			o.pos_y = clampf(mid.y, 0.0, grid_size - 1)
			place_scales[o.type] = w
		"size", "diameter":
			o.scale = clampf(_stepped(float(grip.scale0) + d * 2.0, SNAP_STEP), 0.5, top)
		"leg":
			o.scale = clampf(_stepped(float(grip.scale0) + d, SNAP_STEP), 0.5, top)
		"thick":
			o["thick"] = clampf(_stepped(float(grip.thick0) + d * 2.0 * CELL_M, 0.05), 0.05, 4.5)
		"depth":
			var dep := clampf(_stepped(float(grip.depth0) + d, 0.25), 0.25, 40.0)
			var mid := pos0 + dir * (dep - float(grip.depth0)) * 0.5
			o["depth"] = dep
			o.pos_x = clampf(mid.x, 0.0, grid_size - 1)
			o.pos_y = clampf(mid.y, 0.0, grid_size - 1)
		"arc":
			var l := (_obj_xf(o).affine_inverse() * p) / zoom
			o["arc"] = clampf(_stepped(absf(rad_to_deg(l.angle())) * 2.0, 5.0), 5.0, 360.0)
	_sync_inspector()
	_mark_dirty()

## What a grip is setting, for the label beside the mouse
func _grip_text(o: Dictionary, kind: String) -> String:
	match kind:
		"thick": return "%.2f m %s" % [_thick_cells(o) * CELL_M, "across" if _shape(str(o.type)) in ["pillar", "column"] else "thick"]
		"depth": return "%.2f cells deep  (%.1f m)" % [float(_param(o, "depth", 2.0)), float(_param(o, "depth", 2.0)) * CELL_M]
		"arc": return "arc %s°" % _deg(float(_param(o, "arc", 90.0)))
		"size": return "size x %.2f" % float(o.scale)
		"diameter": return "%.2f cells across  (%.1f m)" % [float(o.scale), float(o.scale) * CELL_M]
	return "%.2f cells  (%.1f m)" % [float(o.scale), float(o.scale) * CELL_M]

## Shift + wheel over the map sizes the selected object, Alt + wheel turns it 15 degrees a notch
func _wheel_edit(up: bool, turn: bool) -> void:
	var o: Dictionary = objects[selected]
	var t := str(o.type)
	if _is_stairs(t): return
	var s := 1.0 if up else -1.0
	if turn: _set_prop("rotation", float(o.rotation) + s * 15.0)
	elif _shape(t) in ["pillar", "column"]: _set_prop("thick", clampf(snappedf(_thick_cells(o) * CELL_M + s * 0.1, 0.05), 0.05, 4.5))
	else: _set_prop("scale", clampf(float(o.scale) + s * SNAP_STEP, 0.5, _max_scale(t)))
	_sync_inspector()
	_status(_describe(o))
	canvas.queue_redraw()

## The current tool's controls, for the line along the bottom of the map
func _hint_text() -> String:
	var always := "     Space / middle drag: move the map     wheel: zoom     Esc: cancel"
	if drag == "chain": return "Click: end this wall     Shift+click: end it and start the next     right click / Esc: stop"
	if tool == "area":
		if area.has_area(): return "Del: empty the box     Shift+Del: wall it in     Ctrl+C copy     Ctrl+X cut     Ctrl+V paste at the mouse     Ctrl+Shift+V paste in place     Esc: drop the box"
		return "Drag: select a box of the map     Ctrl+A: the whole floor     Ctrl+V: paste what was copied" + always
	if tool == "select" or (tool.begins_with("obj:") and selected >= 0):
		if multi.size() > 1: return "%d selected     drag one: move them all     arrows: nudge     R: turn     Ctrl+C / Ctrl+V     Del: delete" % multi.size()
		if selected >= 0: return "Drag: move     squares: resize     round knob: turn     Shift+wheel: size     Alt+wheel: turn     arrows: nudge     Del: delete"
		return "Click: select     drag on empty map: box select     Shift+click: add to the selection     Ctrl+A: all" + always
	if tool.begins_with("obj:"):
		if bool(_info(tool.get_slice(":", 1)).get("draw_line", false)): return "Drag: draw the wall     let go with Shift: chain the next one     right click: delete" + always
		return "Click: place     keep the button down and drag: aim it     R: turn the next one     right click: delete" + always
	if tool == "gen": return "Drag: the area to generate" + always
	if tool.begins_with("mark:"): return "Click: put the marker     right click: remove it" + always
	var pick := "     Alt+click: pick the material here" if tool.begins_with("paint:") else ""
	return "Drag: paint     right drag: erase     Shift: rectangle     Ctrl: fill     [ ]: brush size" + pick + always

func _draw_hints() -> void:
	if not show_hints: return
	var text := _hint_text()
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 6.0
	_tag(Vector2(maxf(canvas.size.x - w - 8.0, 8.0), canvas.size.y - 24.0), text, CREAM, 12)

## Wall-aware placement. On a cell edge a piece lines up with that edge; square on a cell it spans the
## corridor or wall run it lands in (you walk through it the way the open neighbours lie, like the game's
## old tiles did). Of the two ways to face along that axis it keeps the one nearer `cur`, so a door keeps
## its swing side. Off, with Alt held, on a cell corner or off the half-cell grid, `cur` stays.
func _wall_align(p: Vector2, cur: float, t := "") -> float:
	if not align or Input.is_key_pressed(KEY_ALT): return cur
	if t != "" and not bool(_info(t).get("align", true)): return cur      # corners, curves, pillars, triggers
	var whole := func(v: float) -> bool: return absf(v - roundf(v)) < 0.1
	var half := func(v: float) -> bool: return absf(absf(v - floorf(v)) - 0.5) < 0.1
	var facing := -1.0
	if half.call(p.x) and whole.call(p.y): facing = 0.0            # on a north-south edge: face across it
	elif whole.call(p.x) and half.call(p.y): facing = 90.0
	elif whole.call(p.x) and whole.call(p.y):
		var c := Vector2i(roundi(p.x), roundi(p.y))
		var ew := _open_cell(c + Vector2i(1, 0)) and _open_cell(c + Vector2i(-1, 0))
		var ns := _open_cell(c + Vector2i(0, 1)) and _open_cell(c + Vector2i(0, -1))
		if ew and not ns: facing = 0.0
		elif ns and not ew: facing = 90.0
	if facing < 0.0: return cur
	return facing if absf(angle_difference(deg_to_rad(cur), deg_to_rad(facing))) <= PI / 2.0 else facing + 180.0

func _open_cell(c: Vector2i) -> bool:
	return c.x > 0 and c.y > 0 and c.x < grid_size - 1 and c.y < grid_size - 1 and grid[c.y][c.x] != WALL

func _object_press(mb: InputEventMouseButton) -> void:
	# a chained wall is waiting for its end: left click sets it (Shift: and starts the next), right click drops it
	if drag == "chain" and mb.pressed:
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_delete_object(selected)
			drag = ""
		else:
			_end_line(mb.shift_pressed)
		return
	if not mb.pressed:
		_object_release(mb.position, mb.shift_pressed)
		return
	var i := _obj_at(mb.position)
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if i >= 0:
			_push_undo()
			_delete_object(i)
		return
	var gi := _grip_at(mb.position)
	if gi >= 0:
		_push_undo()
		_grab_grip(_grips(objects[selected])[gi], mb.position)
	elif _on_handle(mb.position):
		_push_undo()
		drag = "rotate"
	elif i >= 0 and mb.shift_pressed:
		# Shift+click adds to / takes from the multi-selection
		var g := _group()
		if g.has(i): g.erase(i)
		else: g.append(i)
		multi = g if g.size() > 1 else []
		selected = g[-1] if not g.is_empty() else -1
		_sync_inspector()
		canvas.queue_redraw()
	elif i >= 0 and multi.size() > 1 and multi.has(i):
		# grab the whole group
		_push_undo()
		group_start = multi.map(func(k): return [k, objects[k].pos_x, objects[k].pos_y])
		group_anchor = _pos_at(mb.position)
		drag = "group"
	elif i >= 0 and _is_stairs(tool.get_slice(":", 1)) and _is_stairs(str(objects[i].type)):
		# a stairs tool on a stairwell that is already here: carry that one on, up or down another floor
		_push_undo()
		_select(i)
		_stair_extend(objects[i], 1 if tool == "obj:stairs_up" else -1)
		_stair_settle(objects[i])
		_mark_dirty()
	elif i >= 0:
		_select(i)
		if mb.double_click and objects[i].type == "trigger":
			_open_trigger_dialog(i)
			return
		_push_undo()
		var o: Dictionary = objects[i]
		drag_off = Vector2(o.pos_x, o.pos_y) - _pos_at(mb.position)
		drag = "move"
	elif tool == "select":
		_select(-1)
		box_from = mb.position                       # drag out a box to select everything in it
		drag = "box"
	else:
		_push_undo()
		var p := _snap_pos(_pos_at(mb.position))
		var t := tool.get_slice(":", 1)
		if bool(_info(t).get("draw_line", false)):
			# a wall drawn as a line: it runs from here to wherever the button comes up
			objects.append(_new_object(t, p, 0.0))
			line_from = p
			_select(objects.size() - 1)
			drag = "line"
			_mark_dirty()
			return
		var made := _new_object(t, p, _wall_align(p, place_rot, t))
		if _is_stairs(t):
			# a new stairwell: here, and its other end on the floor above (Stairs up) or below (Stairs down)
			_stair_square(made)
			made.rotation = _stair_facing(made)
			if not _stair_fits(made) or _stair_clash(objects, made):
				_status("No room for a stairwell here: it needs %d x %d cells clear of other stairs, and the cell in front of its door" % [STAIR_CELLS, STAIR_WIDE])
				return
			made["well"] = _well_new()
			objects.append(made)
			_stair_extend(made, 1 if t == "stairs_up" else -1)
		else:
			objects.append(made)
		_select(objects.size() - 1)
		drag = "place"                   # keep the button down and drag away to aim it
		_mark_dirty()

## The button came up on whatever an object tool was dragging (a chained wall is not a drag: it waits for a click)
func _object_release(at: Vector2, shift := false) -> void:
	if drag == "chain" or drag == "": return
	if drag == "line":
		_end_line(shift)
		return
	if drag == "box":
		_end_box(at)
		return
	drag = ""
	for k in _group():                    # a stairwell that was placed, moved or turned settles onto the grid
		if k < objects.size() and _is_stairs(str(objects[k].type)) and not _stair_settle(objects[k]): break
	_sync_inspector()
	_mark_dirty()

## Is Space held to pan? Asked of the keyboard at the click, not remembered from key events: a release that
## never arrives (the window lost focus with it down) can't leave every click panning. Not while typing.
func _space_held() -> bool:
	return Input.is_key_pressed(KEY_SPACE) and not (get_viewport().gui_get_focus_owner() is LineEdit)

## Stop everything a held mouse button was doing on the map: a paint stroke, a rectangle or selection box
## being dragged out (dropped, not applied), an object being moved or turned (left where it is)
func _let_go() -> void:
	if painting or rect_from.x >= 0 or area_from.x >= 0:
		painting = false
		rect_from = Vector2i(-1, -1)
		area_from = Vector2i(-1, -1)
		canvas.queue_redraw()
	if drag != "" and drag != "chain": _object_release(mouse_px)

## Esc, or the window losing focus: nothing is left following the mouse
func _cancel_all() -> void:
	panning = false
	_let_go()
	if drag == "chain": _delete_selected()

func _object_drag(p: Vector2) -> void:
	if drag == "box":
		canvas.queue_redraw()
		return
	if drag == "group":
		var d := _pos_at(p) - group_anchor
		if snap and not Input.is_key_pressed(KEY_ALT): d = (d / SNAP_STEP).round() * SNAP_STEP
		for g: Array in group_start:
			objects[g[0]].pos_x = clampf(g[1] + d.x, 0.0, grid_size - 1)
			objects[g[0]].pos_y = clampf(g[2] + d.y, 0.0, grid_size - 1)
		_mark_dirty()
		return
	if selected < 0 or selected >= objects.size():
		drag = ""
		return
	if drag == "size":
		_resize_drag(p)
		return
	var o: Dictionary = objects[selected]
	if drag == "line" or drag == "chain":
		var q := _snap_pos(_pos_at(p))
		if Input.is_key_pressed(KEY_SHIFT) and rot_snap:            # keep chained runs square
			var d := q - line_from
			q = line_from + (Vector2(d.x, 0) if absf(d.x) >= absf(d.y) else Vector2(0, d.y))
		_set_line(o, line_from, q)
		_sync_inspector()
		_mark_dirty()
		return
	if drag == "move":
		var q := _snap_pos(_pos_at(p) + drag_off)
		if _is_stairs(str(o.type)): q = q.round()
		o.pos_x = q.x
		o.pos_y = q.y
		if is_zero_approx(fposmod(o.rotation, 90.0)):      # a piece hand-turned off the grid axes keeps its angle
			o.rotation = _wall_align(q, o.rotation, o.type)
	else:
		var v := p - _obj_xf(o).origin
		if drag == "place" and v.length() < maxf(zoom * 0.5, 12.0): return    # a plain click keeps place_rot
		o.rotation = _snap_rot(rad_to_deg(v.angle()))
		if _is_stairs(str(o.type)): o.rotation = fposmod(snappedf(o.rotation, 90.0), 360.0)
		place_rot = o.rotation
	_sync_inspector()
	_mark_dirty()

## A line wall laid from `a` to `b` (cells): centred between them, turned to run along them, as long as them
func _set_line(o: Dictionary, a: Vector2, b: Vector2) -> void:
	var run := b - a
	var len := clampf(run.length(), 0.5, _max_scale(o.type))
	var dir := run.normalized() if run.length() > 0.01 else Vector2.DOWN
	var mid := a + dir * len * 0.5
	o.pos_x = mid.x
	o.pos_y = mid.y
	o.rotation = fposmod(rad_to_deg(dir.angle()) - 90.0, 360.0)     # a slab spans its local +y
	o.scale = len

## The button came up on a line wall: a plain click leaves a one-cell piece fitted to the wall it's on;
## with Shift the next wall starts at this one's end and follows the mouse until the next click
func _end_line(chain: bool) -> void:
	var o: Dictionary = objects[selected]
	var end: Vector2 = Vector2(o.pos_x, o.pos_y) + Vector2.from_angle(deg_to_rad(o.rotation + 90.0)) * o.scale * 0.5
	if drag == "line" and Vector2(o.pos_x, o.pos_y).distance_to(line_from) < 0.2:
		o.pos_x = line_from.x
		o.pos_y = line_from.y
		o.scale = _place_scale(o.type)
		o.rotation = _wall_align(line_from, place_rot, o.type)
		chain = false
	else:
		place_scales[o.type] = o.scale
	drag = ""
	if chain:
		_push_undo()
		objects.append(_new_object(o.type, end, 0.0))
		line_from = end
		_select(objects.size() - 1)
		_set_line(objects[selected], end, end + Vector2(0, 0.5))
		drag = "chain"
		_status("Chaining walls: click to end this one (Shift+click to keep going), right click or Esc to stop")
	_sync_inspector()
	_mark_dirty()

## Everything whose origin is inside the dragged box becomes the selection
func _end_box(to: Vector2) -> void:
	drag = ""
	var r := Rect2(box_from, Vector2.ZERO).expand(to)
	if r.size.length() < 4.0:
		canvas.queue_redraw()
		return
	var hit: Array = []
	for i in objects.size():
		if r.has_point(_obj_xf(objects[i]).origin): hit.append(i)
	multi = hit if hit.size() > 1 else []
	selected = hit[-1] if not hit.is_empty() else -1
	_sync_inspector()
	_status("%d objects selected: drag one to move them all, R rotates, COPY copies, Del deletes" % hit.size())
	canvas.queue_redraw()

## The selection as indices: the multi-selection, else the one selected object, else none
func _group() -> Array:
	if multi.size() > 1: return multi.duplicate()
	return [selected] if selected >= 0 else []

func _open_trigger_dialog(_idx: int) -> void:
	pass

func _select(i: int) -> void:
	multi = []
	selected = i
	insp_undo = -1
	_sync_inspector()
	canvas.queue_redraw()

func _delete_object(i: int) -> void:
	var gone: Dictionary = objects[i]
	objects.remove_at(i)
	if selected == i: selected = -1
	elif selected > i: selected -= 1
	hover_obj = -1
	if _is_stairs(str(gone.type)): _well_prune(int(gone.get("well", 0)))
	_sync_inspector()
	_mark_dirty()

func _delete_selected() -> void:
	if drag == "chain":
		_delete_object(selected)
		drag = ""
		return
	var g := _group()
	if g.is_empty(): return
	_push_undo()
	g.sort()
	for k in range(g.size() - 1, -1, -1): _delete_object(g[k])
	multi = []

func _duplicate_selected() -> void:
	var g := _group()
	if g.is_empty(): return
	_push_undo()
	var off := SNAP_STEP if snap else 0.25
	var made: Array = []
	for k in g:
		if _is_stairs(str(objects[k].type)):
			_status("A stairwell isn't copied: place another with Stairs up / down")
			continue
		var o: Dictionary = objects[k].duplicate()
		o.pos_x = minf(o.pos_x + off, grid_size - 1)
		o.pos_y = minf(o.pos_y + off, grid_size - 1)
		objects.append(o)
		made.append(objects.size() - 1)
	if made.is_empty(): return
	selected = made[-1]
	multi = made if made.size() > 1 else []
	_sync_inspector()
	_mark_dirty()

## R / Shift+R and the inspector's buttons: turn the selection, or the next placement when nothing is selected
func _rotate_selected(deg: float) -> void:
	if selected < 0:
		place_rot = fposmod(place_rot + deg, 360.0)
		_status("placing at %s°" % _deg(place_rot))
		canvas.queue_redraw()
		return
	_push_undo()
	if multi.size() > 1:
		# the group turns round its middle, each piece with it
		var mid := Vector2.ZERO
		for k in multi: mid += Vector2(objects[k].pos_x, objects[k].pos_y)
		mid /= multi.size()
		for k in multi:
			var ob: Dictionary = objects[k]
			var q := mid + (Vector2(ob.pos_x, ob.pos_y) - mid).rotated(deg_to_rad(deg))
			ob.pos_x = q.x
			ob.pos_y = q.y
			ob.rotation = fposmod(ob.rotation + deg, 360.0)
		for k in multi:
			if k < objects.size() and _is_stairs(str(objects[k].type)) and not _stair_settle(objects[k]): break
		_mark_dirty()
		return
	var o: Dictionary = objects[selected]
	o.rotation = fposmod(o.rotation + deg, 360.0)
	if _is_stairs(str(o.type)) and not _stair_settle(o): return
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
			place_scales[o.type] = v
		"type":                                           # the new type's params, at their defaults
			var params: Dictionary = _info(v).get("params", {})
			for k in params:
				if not o.has(k): o[k] = params[k]
			o.scale = minf(o.scale, _max_scale(v))
			_sync_inspector()
		"event":
			var raw_list = o.get("events_list", [])
			if raw_list is Array and not raw_list.is_empty() and raw_list[0] is Dictionary:
				raw_list[0]["event"] = v
			_sync_inspector()
		"custom_event":
			var raw_list = o.get("events_list", [])
			if raw_list is Array and not raw_list.is_empty() and raw_list[0] is Dictionary:
				raw_list[0]["custom_event"] = v
			_sync_inspector()
	if _is_stairs(str(o.type)):
		if not _stair_settle(o): return
		insp_x.set_value_no_signal(o.pos_x)
		insp_y.set_value_no_signal(o.pos_y)
		insp_rot.set_value_no_signal(o.rotation)
	_mark_dirty()

func _sync_inspector() -> void:
	if insp == null: return
	insp.get_parent().visible = selected >= 0
	if selected < 0: return
	if tool_scroll != null:
		tool_scroll.scroll_vertical = 0
	var o: Dictionary = objects[selected]
	insp_type.select(OBJ_TYPES.find(o.type))
	for sb: SpinBox in [insp_x, insp_y]: sb.max_value = grid_size - 1
	insp_x.set_value_no_signal(o.pos_x)
	insp_y.set_value_no_signal(o.pos_y)
	insp_rot.set_value_no_signal(o.rotation)
	insp_scale.max_value = _max_scale(o.type)
	insp_scale.set_value_no_signal(o.scale)
	# the size field means what the shape makes of it; pillars and columns are sized by their thickness
	var sh := _shape(o.type)
	insp_scale_label.text = {"arc": "Diameter", "corner": "Leg length", "zone": "Width"}.get(sh, "Width")
	insp_scale_label.visible = sh not in ["pillar", "column"] and not _is_stairs(str(o.type))
	insp_scale.visible = insp_scale_label.visible
	if insp_trigger_btn != null:
		insp_trigger_btn.visible = (o.type == "trigger")
		if o.type == "trigger":
			var raw_list = o.get("events_list", [])
			var ev_count: int = raw_list.size() if raw_list is Array else 0
			if ev_count > 1:
				insp_trigger_btn.text = "CONFIGURE EVENTS (%d ACTIONS)..." % ev_count
			else:
				insp_trigger_btn.text = "CONFIGURE EVENT OPTIONS..."
	var params: Dictionary = _info(o.type).get("params", {})
	var is_custom_event: bool = (o.type == "trigger" and str(_param(o, "event")) == "custom")
	for k in insp_params:
		var on := params.has(k)
		if k == "custom_event":
			on = on and is_custom_event
		for n: Control in insp_params[k].row: n.visible = on
		if not on: continue
		var ctrl: Control = insp_params[k].ctrl
		var v = _param(o, k)
		if ctrl is SpinBox: (ctrl as SpinBox).set_value_no_signal(float(v))
		elif ctrl is CheckBox: (ctrl as CheckBox).set_pressed_no_signal(bool(v))
		elif ctrl is LineEdit:
			if (ctrl as LineEdit).text != str(v): (ctrl as LineEdit).text = str(v)
		elif ctrl is OptionButton and insp_params[k].has("choices"):          # one of object_types.json "choices"
			(ctrl as OptionButton).select(maxi(0, (insp_params[k].choices as Array).find(str(v))))
		elif ctrl is OptionButton:
			var evs: Array = _info(o.type).get("events", {}).keys()
			var ev_idx := evs.find(str(v))
			if ev_idx < 0:
				ev_idx = evs.find("custom")
			(ctrl as OptionButton).select(maxi(0, ev_idx))

func _deg(d: float) -> String:
	return str(snappedf(d, 0.1)).trim_suffix(".0")

func _describe(o: Dictionary) -> String:
	var t := "%s   x %.2f   y %.2f   rotation %s°   width %.2f" % [_info(o.type).label, o.pos_x, o.pos_y, _deg(o.rotation), o.scale]
	var params: Dictionary = _info(o.type).get("params", {})
	if params.has("thick"): t += "   %.2f m thick" % float(_param(o, "thick"))
	if params.has("height"): t += "   " + ("to the ceiling" if float(_param(o, "height")) <= 0.0 else "%.2f m high" % float(_param(o, "height")))
	if params.has("arc"): t += "   arc %s°" % _deg(float(_param(o, "arc")))
	if params.has("elev") and float(_param(o, "elev")) > 0.0: t += "   %.2f m off the floor" % float(_param(o, "elev"))
	if _is_stairs(str(o.type)) and objects.has(o):
		var up := _stair_linked(o, floor_idx, 1)
		var down := _stair_linked(o, floor_idx, -1)
		t = "Stairwell   x %d   y %d   " % [roundi(o.pos_x), roundi(o.pos_y)]
		t += "up to %s" % _floor_name(floor_idx + 1) if up else "no way up"
		t += ",  down to %s" % _floor_name(floor_idx - 1) if down else ",  no way down"
		t += "   (%s, lamps %s)" % [str(_param(o, "style", "carpet")), str(_param(o, "light", "on"))]
	if params.has("event"):
		var ev_names: Array = []
		var raw_list = o.get("events_list", [])
		if raw_list is Array and not raw_list.is_empty():
			for entry in raw_list:
				var name_str := ""
				if entry is Dictionary:
					name_str = str(entry.get("event", ""))
					if name_str == "custom":
						var c_ev := str(entry.get("custom_event", "")).strip_edges()
						if c_ev != "": name_str = "custom (%s)" % c_ev
				elif entry is String:
					name_str = str(entry).strip_edges()
				if name_str != "":
					ev_names.append(name_str)
		if ev_names.is_empty():
			var ev_name := str(_param(o, "event"))
			if ev_name == "custom":
				var c_ev := str(_param(o, "custom_event", "")).strip_edges()
				if c_ev != "": ev_name = "custom (%s)" % c_ev
			ev_names.append(ev_name)
		t += "   events: %s%s" % [", ".join(ev_names), "  (once)" if bool(_param(o, "once", true)) else ""]
		var tx := str(_param(o, "text", "")).strip_edges()
		if tx != "": t += '   text: "%s"' % tx
	return t

## A rectangle in the object's local space (cells), as canvas points
func _local_rect(xf: Transform2D, x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([xf * (Vector2(x0, y0) * zoom), xf * (Vector2(x1, y0) * zoom), xf * (Vector2(x1, y1) * zoom), xf * (Vector2(x0, y1) * zoom)])

func _fill(pts: PackedVector2Array, col: Color) -> void:
	canvas.draw_colored_polygon(pts, col)
	canvas.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0, 0, 0, col.a * 0.8), 1.0)

## Plan view of an object, the way an architect's floor plan draws it
## `own`: one of this floor's (a stairwell then shows which floors it is joined to)
func _draw_object(o: Dictionary, alpha: float, own := true) -> void:
	var xf := _obj_xf(o)
	var col: Color = _info(o.type).col
	col.a = alpha
	var half: float = o.scale * 0.5
	var t := maxf(_cells(o.type, "thickness", 0.3), 5.0 / zoom)
	match o.type:
		"door":
			# the partition either side of the doorway, the leaf (closed) and its swing either way
			var door_c := _cells("door", "opening", 1.12)
			var dw := door_c * 0.5
			var wall_col := Color(_info("thin_wall").col, alpha)
			_fill(_local_rect(xf, -t * 0.5, -half, t * 0.5, -dw), wall_col)
			_fill(_local_rect(xf, -t * 0.5, dw, t * 0.5, half), wall_col)
			var hinge := xf * (Vector2(0, -dw) * zoom)
			canvas.draw_line(hinge, xf * (Vector2(0, dw) * zoom), col, maxf(2.0, zoom * 0.04))
			var a := deg_to_rad(o.rotation)
			canvas.draw_arc(hinge, door_c * zoom, a, a + PI, 24, Color(col, alpha * 0.8), 1.5)
		"arch":
			# two pillars and the passage between them, dashed where the crown spans it
			var p := _cells("arch", "pillar", 0.75)
			var d := t * 0.5
			_fill(_local_rect(xf, -d, -half, d, -half + p), col)
			_fill(_local_rect(xf, -d, half - p, d, half), col)
			for s: float in [-d, d]:
				canvas.draw_dashed_line(xf * (Vector2(s, -half + p) * zoom), xf * (Vector2(s, half - p) * zoom),
					Color(col, alpha * 0.8), 1.5, maxf(zoom * 0.12, 3.0))
		"stairs_up", "stairs_down":
			_draw_stairs(o, xf, col, alpha, own)
		_:
			_draw_shaped(o, xf, col, alpha)

## Walls by shape (thin / half walls, corners, curves), pillars, columns and triggers, and any type the
## editor has no plan drawing for: a slab its thickness by its width. A wall you can see over (a half
## wall) is drawn hatched with a dashed centre line.
func _draw_shaped(o: Dictionary, xf: Transform2D, col: Color, alpha: float) -> void:
	var t := maxf(_thick_cells(o), 5.0 / zoom)
	var h := float(_param(o, "height", 0.0))
	var low := h > 0.0 and h < 1.8
	match _shape(o.type):
		"pillar":
			_fill(_local_rect(xf, -t * 0.5, -t * 0.5, t * 0.5, t * 0.5), col)
		"column":
			canvas.draw_circle(xf.origin, t * 0.5 * zoom, col)
			canvas.draw_arc(xf.origin, t * 0.5 * zoom, 0, TAU, 24, Color(0, 0, 0, alpha * 0.8), 1.0)
		"zone":
			# a trigger: a see-through box with a dashed rim and its event, never mistaken for a wall
			var d := float(_param(o, "depth", 2.0)) * 0.5
			var hw: float = o.scale * 0.5
			var pts := _local_rect(xf, -d, -hw, d, hw)
			canvas.draw_colored_polygon(pts, Color(col, alpha * 0.14))
			for i in 4:
				canvas.draw_dashed_line(pts[i], pts[(i + 1) % 4], Color(col, alpha * 0.9), 1.5, maxf(zoom * 0.2, 4.0))
			if zoom >= 8.0:
				var ev_names: Array = []
				var raw_list = o.get("events_list", [])
				if raw_list is Array and not raw_list.is_empty():
					for entry in raw_list:
						var name_str := ""
						if entry is Dictionary:
							name_str = str(entry.get("event", ""))
							if name_str == "custom":
								var c_ev := str(entry.get("custom_event", "")).strip_edges()
								if c_ev != "": name_str = c_ev
						elif entry is String:
							name_str = str(entry).strip_edges()
						if name_str != "":
							ev_names.append(name_str)
				if ev_names.is_empty():
					var ev := str(_param(o, "event", ""))
					if ev == "custom":
						var c_ev := str(_param(o, "custom_event", "")).strip_edges()
						if c_ev != "": ev = c_ev
					if ev != "": ev_names.append(ev)
				var summary := ""
				if ev_names.size() == 1:
					summary = ev_names[0]
				elif ev_names.size() == 2:
					summary = ev_names[0] + " + " + ev_names[1]
				elif ev_names.size() > 2:
					summary = ev_names[0] + " (+" + str(ev_names.size() - 1) + " events)"
				else:
					summary = "trigger"
				var tx := str(_param(o, "text", "")).strip_edges()
				if tx != "":
					var preview := tx if tx.length() <= 22 else tx.substr(0, 20) + ".."
					summary += ' "%s"' % preview
				var lbl := summary + ("" if bool(_param(o, "once", true)) else " [repeat]")
				_tag(xf.origin + Vector2(-20, -8), lbl, Color(col, alpha), 10)
		_:
			var pts := _shape_path(o)
			var line := PackedVector2Array()
			for q in pts: line.append(xf * (q * zoom))
			var w := t * zoom
			canvas.draw_polyline(line, Color(0, 0, 0, alpha * 0.8), w + 2.0)
			canvas.draw_polyline(line, Color(col, alpha * (0.55 if low else 1.0)), w)
			if low:
				for i in line.size() - 1:
					canvas.draw_dashed_line(line[i], line[i + 1], Color(1, 1, 1, alpha * 0.6), 1.0, maxf(zoom * 0.15, 3.0))

## A stairwell in plan: its box with the doorway in the front, the wall between the lanes, and each lane's
## steps. The right-hand lane (of the arrow) goes up, the left-hand one down; a lane with no floor to lead to
## is drawn walled off, as the game builds it.
func _draw_stairs(o: Dictionary, xf: Transform2D, col: Color, alpha: float, own: bool) -> void:
	var m := 1.0 / CELL_M                             # metres -> cells (the sizes are props/stairs.gd's)
	var x0 := -0.5
	var x1 := STAIR_CELLS - 0.5
	var y0 := 0.5 - STAIR_WIDE
	var y1 := 0.5
	var mid := (y0 + y1) * 0.5
	var wall := maxf(0.2 * m, 2.0 / zoom)
	var spine := 1.0 * m
	var xa := x0 + 0.2 * m + 3.0 * m
	var xb := x1 - 0.2 * m - 3.0 * m
	var up := not own or _stair_linked(o, floor_idx, 1)
	var down := not own or _stair_linked(o, floor_idx, -1)
	var solid := Color(BASE_COLORS[WALL], alpha)
	var ink := Color(0, 0, 0, alpha * 0.55)
	canvas.draw_colored_polygon(_local_rect(xf, x0, y0, x1, y1), Color(col.darkened(0.6), alpha * 0.92))      # the landings
	var fs := int(clampf(zoom * 0.3, 8, 15))
	for lane: Array in [[mid + spine * 0.5, y1, up, "UP"], [y0, mid - spine * 0.5, down, "DOWN"]]:
		var a: float = lane[0]
		var b: float = lane[1]
		if not lane[2]:
			canvas.draw_colored_polygon(_local_rect(xf, xa, a, xb, b), solid)
			continue
		canvas.draw_colored_polygon(_local_rect(xf, xa, a, xb, b), Color(col, alpha * 0.9))
		for i in 13:
			var x := lerpf(xa, xb, i / 12.0)
			canvas.draw_line(xf * (Vector2(x, a) * zoom), xf * (Vector2(x, b) * zoom), ink, 1.0)
		if own and zoom >= 14.0:
			var at := xf * (Vector2((xa + xb) * 0.5, (a + b) * 0.5) * zoom)
			var ts := font.get_string_size(lane[3], HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			canvas.draw_string(font, at - Vector2(ts.x * 0.5, -fs * 0.35), lane[3], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, alpha))
	canvas.draw_colored_polygon(_local_rect(xf, xa, mid - spine * 0.5, xb, mid + spine * 0.5), solid)             # the wall between the lanes
	# the box, with the doorway in the front of the up lane
	var door_mid := mid + (spine * 0.5 + 3.8 * m * 0.5)
	var door := 1.1 * m
	for r: Array in [[x0, y0, x1, y0 + wall], [x0, y1 - wall, x1, y1], [x1 - wall, y0, x1, y1],
			[x0, y0, x0 + wall, door_mid - door], [x0, door_mid + door, x0 + wall, y1]]:
		canvas.draw_colored_polygon(_local_rect(xf, r[0], r[1], r[2], r[3]), solid)
	var rim := _local_rect(xf, x0, y0, x1, y1)
	canvas.draw_polyline(rim + PackedVector2Array([rim[0]]), Color(0, 0, 0, alpha * 0.8), 1.0)
	_draw_arrow(o, Color(1, 1, 1, alpha * 0.8))
	if not own or zoom < 9.0: return
	var bits: Array = []
	if up: bits.append("▲ " + _floor_name(floor_idx + 1).to_upper())
	if down: bits.append("▼ " + _floor_name(floor_idx - 1).to_upper())
	var tag_col := Color("2fd968") if (up or down) else Color("ff9922")
	var corner := rim[0]
	for q in rim:
		if q.y < corner.y or (q.y == corner.y and q.x < corner.x): corner = q
	_tag(corner + Vector2(0, -15), "   ".join(bits) if not bits.is_empty() else "NOT JOINED TO A FLOOR", Color(tag_col, alpha), 10)

func _draw_outline(o: Dictionary, col: Color, width: float) -> void:
	var b := _obj_bounds(o).grow(3.0 / zoom)
	var pts := _local_rect(_obj_xf(o), b.position.x, b.position.y, b.end.x, b.end.y)
	canvas.draw_polyline(pts + PackedVector2Array([pts[0]]), col, width)

## The facing arrow, out of the front along local +x (the way you walk through it)
func _draw_arrow(o: Dictionary, col: Color) -> void:
	var xf := _obj_xf(o)
	var dir := xf.x.normalized()
	var tip := xf.origin + dir * (maxf(_obj_bounds(o).end.x, 0.0) * zoom + maxf(zoom * 0.8, 26.0))
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
		canvas.draw_circle(xf * (Vector2(0, -_cells("door", "opening", 1.12) * 0.5) * zoom), 3.0, Color.WHITE)
	canvas.draw_circle(xf.origin, 2.5, SEL)
	# the resize grips, the one under the mouse (or in hand) lit, with what it is setting beside the mouse
	if multi.size() > 1: return
	var over := _grip_at(mouse_px) if drag == "" else -1
	var gs := _grips(o)
	var said := ""
	for i in gs.size():
		var g: Dictionary = gs[i]
		var held: bool = drag == "size" and str(grip.get("kind", "")) == str(g.kind) and (g.dir as Vector2).is_equal_approx(grip.get("dir", Vector2.ZERO))
		var gp := _grip_px(o, g)
		var box := Rect2(gp - Vector2(4.5, 4.5), Vector2(9, 9))
		canvas.draw_rect(box.grow(1.5), Color.BLACK)
		canvas.draw_rect(box, Color.WHITE if (held or i == over) else SEL)
		if held or i == over: said = _grip_text(o, str(g.kind))
	if said != "": _tag(mouse_px + Vector2(16, 14), said, SEL, 12)

func _status(t: String) -> void:
	if status: status.text = t
