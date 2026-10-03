extends Node3D
## THE LEVEL, layer 1: the grid it is built from. Reads levels/levels.json (the playlist, edited
## with the level editor in level-editor/) and the .lvl it points at. Grid rows are z, characters are x:
## '#' wall, '.' floor, 'O' pit (v1 files also used 'T' thin wall, 'A' archway, 'D' door; those load as
## objects now). Zones paint extra properties onto cells (tall / low ceilings, tile floors, bright / dim /
## dark lighting, flickering tubes, grime). Doors, arches and thin walls are free-placed "objects".
##   level_data.gd      the grid and its zones                       (this file)
##   level_geometry.gd  floors, walls, ceilings, pits, grime
##   level_lighting.gd  the troffers, the light pool that follows you, flicker, fog
##   level_builder.gd   builds it all, plus the exit and the battery packs (the node's script)

const CELL := 4.5
const WALL_H := 5.4
const TALL_H := 10.8
const LOW_H := 2.3
const PIT_DEPTH := 14.0
const STOREY_H := 9.0     # floor to floor (props/stairs.gd STOREY): the room, and the slab up to the next floor
const SEE_OVER_H := 1.8  # a wall object lower than this (its "height") is seen over: it blocks feet, not eyes

@export var level_index := 0

## Free-standing architectural pieces, placed off-grid in the level editor ("objects" in the .lvl).
## Positions are in cells where a cell's centre is a whole number (the same frame as "spawn"), so world =
## pos * CELL. `rotation` is degrees clockwise on the editor's top-down map (+X east, +Z south); in local
## space every piece faces +X (the direction you walk through it) and spans `scale` cells along Z. What each
## type is (size, what it does to the grid, how the editor shows it) lives in levels/object_types.json,
## shared with the level editor. A type's "params" are extra per-object fields (a wall's thickness and
## height, a curve's arc, a trigger's event...); every loaded object carries all of its type's, defaults
## filled in.
const OBJECT_TYPES_PATH := "res://levels/object_types.json"
static var _object_types := {}

var size := 0
var walls := {}       # Vector2i -> true
var pits := {}
var objects: Array = []   # {type, pos_x, pos_y, rotation, scale, <its type's params>}, see object_types()
var carved := {}      # Vector2i -> true: a wall cell an object stands in, so no solid block is built there
var arch_cells := {}  # Vector2i -> true: a cell with an arch square in it (walkable, but full of arch mass)
## Vector2i -> true: a cell a stairwell stands in (props/stairs.gd builds everything in it, floor to ceiling).
## A wall to the grid: nothing paths through it, no tube hangs over it, no light is seen across it.
var stair_cells := {}
var level_raw := {}   # the whole .lvl (every floor), for what the stairs join on the floors above and below
## The floors of a level stand STOREY_H apart, and the ones round the floor you are on are built too, to be
## looked at (level_builder.gd, level_shell.gd). A pit over a cell of the floor below that is not a wall is a
## hole right through the slab: you see that floor through it, and fall into it.
var floor_no := 0
var shell := false        # a look-only copy of a floor: nothing to walk on, bump into or set off
var through := {}         # Vector2i -> true: this floor's pits that open into the floor below
var open_above := {}      # Vector2i -> true: the floor above has such a pit here, so no ceiling
var crop := {}            # Vector2i -> true: a shell builds only these cells (empty: all of them)
var hole_box := Rect2i()  # the cells round all of this floor's holes, up and down (no size: it has none)
var pillar_cells := {}  # Vector2i -> true: a pillar / column stands square in it (no tube light over it)
## Off-centre blocking objects (a thin wall or door on a cell edge, or at an angle) don't fill a cell, so
## instead they cut the links between cells for the monster's grid nav: blocked_edges holds each pair of
## neighbouring cells whose centre-to-centre step crosses one, wall_segments the spans themselves
## ([from, to] in cells, half thickness in metres, seen-over) for line of sight and push-out collision.
## A curved or L-shaped wall is several spans; a pillar is one of zero length (push-out only).
var blocked_edges := {}   # Vector4i(a.x, a.y, b.x, b.y), a < b -> true
var wall_segments: Array = []
var tall := {}
var low := {}
var tiles := {}
var bright := {}
var dark := {}
var dim := {}
var flicker := {}
var mannequin := {}   # cells where the mannequin room stands (painted in the level editor)
var classic := {}     # the super-bright classic backrooms look: steady dense tubes, clear air, glowing yellow
var liminal := {}     # the liminal look: every tube steady and humming, pale air you can see a long way down
var safe := {}        # no entity sets foot here: solid to their paths and their bodies (grid_nav.gd), not to their eyes
var drain := {}       # sanity runs out while you stand here, whatever the light (player.gd)
var loot := {}        # battery packs, tape and flashes turn up here far more often (level_builder.gd _scatter)
var echo := {}        # a long, wet echo on footsteps and everything heard (audio.gd)
var loop := {}        # a corridor that never ends: walk on down it and you are back near its start (level_builder.gd)
var endless_ceiling := {}      # no ceiling and a shaft up that never ends: the Endless zone (endless_shaft.gd)
var abyss := {}       # pits with no bottom: the Abyss zone, and every pit with no floor under it (pit_fall.gd)
## No ceiling: you look up into the storey above, whose floor has a hole over these cells (the floor above
## treats them as pits, holes_below). On the top floor there is only the dark above.
var open_ceiling := {}
var holes_below := {} # Vector2i -> true: cells the floor below has an open ceiling under, so pits here
var shaft_up := {}    # Vector2i -> true: open-ceiling cells with no room above to see into: a shaft up into the dark
var shaft_floors := 0 # how many floors above this one that shaft rises through (they are solid wall there)
var shaft_pass := {}  # Vector2i -> true: wall cells of this floor a shaft from a floor below rises through
var fired_triggers := {}   # event triggers already spent this run (props/event_trigger.gd), across floor changes
var spawn_pos := Vector3.ZERO
var spawn_yaw := 0.0          # set with has_spawn_yaw when you arrive by the stairs
var has_spawn_yaw := false
var level_data := {}
var level_meta := {}
var level_name := "LEVEL 0"
var player: Node3D
var rng := RandomNumberGenerator.new()

# levels/levels.json is the playlist ([{id, name, file}]) and each file is a .lvl (JSON: size, spawn,
# exit, entity, tv, grid, zones). The level editor (level-editor/level_editor_files.gd, a separate
# Godot app) reads and saves them in place: this folder, or the one BACKROOMS_GAME_DIR points at.
static func read_index() -> Array:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://levels/levels.json"))
	var out: Array = parsed if parsed is Array else []
	if out.is_empty():
		push_error("levels/levels.json is missing or empty")
		out = [{"id": "level0", "name": "Level 0", "file": "level0.lvl"}]
	return out

## "LEVEL 0", "LEVEL 1", ... for whichever playlist entry Game.level_index points at right now,
## used by the title screen and pause menu's "ARCHIVAL FOOTAGE // LEVEL N" tag
static func current_level_tag() -> String:
	var levels := read_index()
	if levels.is_empty():
		return "LEVEL 0"
	var meta: Dictionary = levels[clampi(Game.level_index, 0, levels.size() - 1)]
	var name := str(meta.get("name", "LEVEL 0"))
	var colon := name.find(":")
	return (name.substr(0, colon) if colon != -1 else name).to_upper()

## levels/object_types.json without its "_about" note: type -> {label, key, color, help, thickness, on_cell, blocks_nav, ...}
static func object_types() -> Dictionary:
	if _object_types.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(OBJECT_TYPES_PATH))
		if not (parsed is Dictionary):
			push_error("cannot read " + OBJECT_TYPES_PATH)
			parsed = {}
		for k in parsed:
			if not str(k).begins_with("_"): _object_types[k] = parsed[k]
	return _object_types

static func object_info(type: String) -> Dictionary:
	return object_types().get(type, {})

## A raw .lvl object as loaded: the common fields, scale capped for its type, and every one of its type's
## params (object_types.json "params") with the file's value, or the default, as the default's type
static func load_object(o: Dictionary) -> Dictionary:
	var info := object_info(str(o.get("type", "")))
	var out := {"type": str(o.get("type", "")), "pos_x": float(o.get("pos_x", 0.0)), "pos_y": float(o.get("pos_y", 0.0)),
		"rotation": float(o.get("rotation", 0.0)), "scale": clampf(float(o.get("scale", 1.0)), 0.5, float(info.get("max_scale", 4.0)))}
	var params: Dictionary = info.get("params", {})
	for k in params:
		var v = o.get(k, params[k])
		match typeof(params[k]):
			TYPE_BOOL: out[k] = bool(v)
			TYPE_FLOAT, TYPE_INT: out[k] = float(v)
			TYPE_ARRAY: out[k] = v if v is Array else params[k]
			TYPE_DICTIONARY: out[k] = v if v is Dictionary else params[k]
			_: out[k] = str(v)
	return out

## The centre line of a wall-shaped object (its type's "shape") in object space: cells, +x the way it faces,
## +y across it (world +z at rotation 0). "slab" runs `scale` cells across, "corner" is an L with both legs
## `scale` long (along +x and +y from the origin), "arc" bends round a circle `scale` cells across centred
## on the origin, `arc` degrees of it centred on +x (the last point is the first again at 360). Empty for
## anything else. The walls (level_geometry.gd), the nav spans here and the editor's plan all use it.
static func shape_path(o: Dictionary) -> PackedVector2Array:
	var s: float = o.scale
	match str(object_info(o.type).get("shape", "slab")):
		"slab":
			return PackedVector2Array([Vector2(0, -s * 0.5), Vector2(0, s * 0.5)])
		"corner":
			return PackedVector2Array([Vector2(s, 0), Vector2.ZERO, Vector2(0, s)])
		"arc":
			var arc := deg_to_rad(clampf(float(o.get("arc", 90.0)), 5.0, 360.0))
			var n := maxi(2, ceili(arc / deg_to_rad(10.0)))
			var pts := PackedVector2Array()
			for i in n + 1:
				pts.append(Vector2.from_angle(-arc * 0.5 + arc * i / n) * s * 0.5)
			return pts
	return PackedVector2Array()

## Stairs ("stairs_up" / "stairs_down", the same stairwell either way: the type only says which floor the
## level editor made its other end on). A stairwell stands square on the grid: STAIR_CELLS cells from its own
## along its arrow by STAIR_WIDE across (its own row, where its doorway is, and the one to the left of the
## arrow). It joins this floor to the next one up / down wherever that floor has a stairwell on the very same
## cells (stair_partner).
const STAIR_CELLS := 3
const STAIR_WIDE := 2

static func is_stairs(type: String) -> bool:
	return type == "stairs_up" or type == "stairs_down"

## The way a stairwell runs on the map: its arrow, squared to the grid
static func stair_dir(o: Dictionary) -> Vector2i:
	return Vector2i(Vector2.from_angle(deg_to_rad(float(o.rotation))).round())

static func stair_footprint(o: Dictionary) -> Array[Vector2i]:
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	var dir := stair_dir(o)
	var left := Vector2i(dir.y, -dir.x)
	var out: Array[Vector2i] = []
	for i in STAIR_CELLS:
		for j in STAIR_WIDE: out.append(c + dir * i + left * j)
	return out

## Does floor `f` exist in this .lvl? (floor_data() hands back the ground floor for one that doesn't)
static func has_floor(d: Dictionary, f: int) -> bool:
	return f == 0 or d.get("floors", {}).get(str(f)) is Dictionary

## The stairwell on floor `f` standing on the same cells as `o`, the same way round ({} when there is none):
## the other end of `o`, one floor up or down
static func stair_partner(d: Dictionary, f: int, o: Dictionary) -> Dictionary:
	if not has_floor(d, f): return {}
	var objs = floor_data(d, f).get("objects")
	if not (objs is Array): return {}
	for other in objs:
		if other is Dictionary and is_stairs(str(other.get("type", ""))):
			var p := load_object(other)
			if roundi(p.pos_x) == roundi(o.pos_x) and roundi(p.pos_y) == roundi(o.pos_y) and stair_dir(p) == stair_dir(o):
				return p
	return {}

## A wall object's thickness in metres: its own, else its type's
static func object_thick(o: Dictionary) -> float:
	return float(o.get("thick", object_info(o.type).get("thickness", 0.3)))

## A wall object low enough to see over (a half wall, a counter)
static func seen_over(o: Dictionary) -> bool:
	var h := float(o.get("height", 0.0))
	return h > 0.0 and h < SEE_OVER_H

## One floor of a level as a plain level: floor 0 is the file itself, any other its "floors" entry laid over
## it (grid, zones, paint, objects and markers are per floor; size, materials and the look are shared).
## A floor that doesn't exist falls back to the ground floor.
const FLOOR_KEYS := ["grid", "zones", "paint", "objects", "spawn", "exit", "entity", "tv"]
static func floor_data(d: Dictionary, f: int) -> Dictionary:
	if f == 0: return d
	var fl = d.get("floors", {}).get(str(f))
	if not (fl is Dictionary): return d
	var out := d.duplicate()
	for k in FLOOR_KEYS:
		out[k] = fl.get(k)
	if out["grid"] == null: out["grid"] = d["grid"]
	for k in ["zones", "paint"]:
		if out[k] == null: out[k] = {}
	if out["objects"] == null: out["objects"] = []
	return out

static func read_level(meta: Dictionary) -> Dictionary:
	if meta.has("data"):                              # old baked format
		return meta["data"]
	var path := "res://levels/" + str(meta.get("file", ""))
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not parsed.has("grid"):
		push_error("cannot read level file " + path)
		return {"size": 8, "spawn": [2, 2], "grid": ["########", "#......#", "#......#", "#......#", "#......#", "#......#", "#......#", "########"]}
	return parsed

## Load the playlist entry Game.level_index points at
func load_current() -> void:
	_step_mask = PackedByteArray()      # walls / pits / edges are about to change
	var levels := read_index()
	Game.level_count = levels.size()
	level_index = clampi(Game.level_index, 0, levels.size() - 1)
	level_meta = levels[level_index]
	load_floor(Game.level_floor)

## An "endless" level (the .lvl's "endless", a tick box in the level editor) goes on past its last floors: every
## floor under the lowest is the lowest over again, every floor over the highest the highest. A shaft through
## the lowest floor then has no bottom to be seen, and none to reach. Stairs still end where the file does.
static func endless(d: Dictionary) -> bool:
	return bool(d.get("endless", false))

## The floor of the file that floor `f` is: itself, or past either end of an endless level the last one that way
static func floor_src(d: Dictionary, f: int) -> int:
	if has_floor(d, f) or not endless(d): return f
	var lo := 0
	var hi := 0
	for k in d.get("floors", {}):
		if d["floors"][k] is Dictionary:
			lo = mini(lo, int(k))
			hi = maxi(hi, int(k))
	return clampi(f, lo, hi)

## Is there a floor `f`, in the file or as one of an endless level's repeats?
static func in_stack(d: Dictionary, f: int) -> bool:
	return has_floor(d, f) or endless(d)

## The cells floor `f` has zone `zone` painted on (its open cells: a zone on a wall counts for nothing)
static func zone_cells(d: Dictionary, f: int, zone: String) -> Dictionary:
	var out := {}
	if not in_stack(d, f): return out
	var fd := floor_data(d, floor_src(d, f))
	var grid: Array = fd["grid"]
	var zones = fd.get("zones")
	if not (zones is Dictionary): return out
	var n := int(d["size"])
	for c in zones.get(zone, []):
		var v := Vector2i(c[0], c[1])
		if v.x < 1 or v.y < 1 or v.x >= n - 1 or v.y >= n - 1 or v.y >= grid.size(): continue
		var row: String = grid[v.y]
		if v.x < row.length() and row[v.x] != "#": out[v] = true
	return out

## Floor `f`'s pits that open into the floor below: the cell under them is not a wall there
static func through_cells(d: Dictionary, f: int) -> Dictionary:
	var out := {}
	if not (in_stack(d, f) and in_stack(d, f - 1)): return out
	var grid: Array = floor_data(d, floor_src(d, f))["grid"]
	var under: Array = floor_data(d, floor_src(d, f - 1))["grid"]
	var n := int(d["size"])
	for z in range(1, mini(n - 1, mini(grid.size(), under.size()))):
		var row: String = grid[z]
		if row.find("O") == -1: continue
		var low: String = under[z]
		for x in range(1, mini(n - 1, mini(row.length(), low.length()))):
			if row[x] == "O" and low[x] != "#": out[Vector2i(x, z)] = true
	# an open ceiling on the floor below is a hole in this floor too, wherever this floor is not wall
	for c: Vector2i in zone_cells(d, f - 1, "open_ceiling"):
		if c.y < grid.size() and c.x < (grid[c.y] as String).length() and grid[c.y][c.x] != "#": out[c] = true
	# a pit painted Abyss has no bottom, whatever is under it (pit_fall.gd): the floor below keeps its ceiling
	for c: Vector2i in zone_cells(d, f, "abyss"): out.erase(c)
	if out.is_empty(): return out
	# a stairwell on either floor has those cells to itself (older files have a pit under their stairs down)
	for g: int in [f, f - 1]:
		var objs = floor_data(d, floor_src(d, g)).get("objects")
		if not (objs is Array): continue
		for o in objs:
			if o is Dictionary and is_stairs(str(o.get("type", ""))):
				for c in stair_footprint(load_object(o)): out.erase(c)
	return out

## Floor `f`'s open-ceiling cells with no room over them to look up into (the cell above is wall, or there
## is no floor above): a shaft rises from them instead (level_geometry.gd)
static func blind_cells(d: Dictionary, f: int) -> Dictionary:
	var out := zone_cells(d, f, "open_ceiling")
	if out.is_empty(): return out
	for c: Vector2i in through_cells(d, f + 1): out.erase(c)
	return out

## How many of the floors above floor `f` that shaft rises through, SHAFT_FLOORS at most: the floors where each
## of its cells is wall with wall on all four sides. Nothing of such a floor is built there, so nothing of it
## is cut into; it only leaves the ceiling off over those cells (shaft_pass).
const SHAFT_FLOORS := 4
static func shaft_rise(d: Dictionary, f: int) -> int:
	var cells := blind_cells(d, f)
	if cells.is_empty(): return 0
	var n := 0
	while n < SHAFT_FLOORS and in_stack(d, f + n + 1):
		var grid: Array = floor_data(d, floor_src(d, f + n + 1))["grid"]
		for c: Vector2i in cells:
			for o: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var q := c + o
				if q.y < 0 or q.y >= grid.size() or q.x < 0 or q.x >= (grid[q.y] as String).length(): continue
				if grid[q.y][q.x] != "#": return n
		n += 1
	return n

## Read floor `f` of the current level into the grid (which must be empty): off the disk, or out of `raw`,
## the whole .lvl already read
func load_floor(f: int, raw := {}) -> void:
	level_raw = raw if not raw.is_empty() else read_level(level_meta)
	level_data = floor_data(level_raw, floor_src(level_raw, f))
	floor_no = f
	holes_below = zone_cells(level_raw, f - 1, "open_ceiling")
	_parse(level_data)
	# a stairwell, or a wall object square on the cell, takes the cell over on this floor
	through = through_cells(level_raw, f)
	open_above = through_cells(level_raw, f + 1)
	shaft_up.clear()
	for c: Vector2i in endless_ceiling.keys():                           # no ceiling here, and no floor above takes it over
		open_above[c] = true
	for c: Vector2i in open_ceiling:                             # no ceiling, whether or not there is a floor above to see
		if not open_above.has(c): shaft_up[c] = true
		open_above[c] = true
	# the bottomless pits: the ones painted so, and on a floor with nothing under it every pit (it used to
	# fall through a black floor and put you back at the spawn point)
	for c: Vector2i in abyss.keys():
		if not pits.has(c): abyss.erase(c)
	if not in_stack(level_raw, f - 1):
		for c: Vector2i in pits:
			if not through.has(c): abyss[c] = true
	shaft_floors = 0 if shaft_up.is_empty() else shaft_rise(level_raw, f)
	shaft_pass.clear()
	for k in range(1, SHAFT_FLOORS + 1):                         # the shafts of the floors below that reach this one
		if shaft_rise(level_raw, f - k) >= k:
			for c: Vector2i in blind_cells(level_raw, f - k): shaft_pass[c] = true
	for c: Vector2i in endless_ceiling.keys():
		if walls.has(c): endless_ceiling.erase(c)
	hole_box = Rect2i()
	for holes: Dictionary in [through, open_above]:
		for c: Vector2i in holes.keys():
			if walls.has(c): holes.erase(c)
			else: hole_box = Rect2i(c, Vector2i.ONE) if hole_box.size == Vector2i.ZERO else hole_box.merge(Rect2i(c, Vector2i.ONE))

## Has the player, at `p`, dropped through one of this floor's holes into the slab under it?
func fell_through(p: Vector3) -> bool:
	return p.y < -FALL_SWAP and through.has(cell_of(p))

## How far under the floor your feet are when the floor below takes over: your eyes are inside the slab by
## then, with nothing of the room you left in view but what shows up the hole
const FALL_SWAP := 2.2

func _parse(d: Dictionary) -> void:
	size = int(d["size"])
	var grid: Array = d["grid"]
	var legacy := {}                                 # v1 files painted these as tiles: Vector2i -> type
	for z in size:
		var row: String = grid[z] if z < grid.size() else ""
		for x in size:
			var ch := row[x] if x < row.length() else "#"
			var edge := x == 0 or z == 0 or x == size - 1 or z == size - 1
			var v := Vector2i(x, z)
			if edge or ch == "#":
				walls[v] = true
			elif ch == "O":
				pits[v] = true
			elif ch == "T" or ch == "D":
				walls[v] = true
				legacy[v] = "thin_wall" if ch == "T" else "door"
			elif ch == "A":
				legacy[v] = "arch"
	for v: Vector2i in holes_below:                  # the floor below has no ceiling here: a hole in this floor
		if not walls.has(v): pits[v] = true
	# old tiles become objects facing whichever way the corridor runs (needs the full wall set first)
	for v: Vector2i in legacy:
		objects.append(load_object({"type": legacy[v], "pos_x": float(v.x), "pos_y": float(v.y), "rotation": 90.0 * open_axis(v)}))
	for o in d.get("objects", []):
		if o is Dictionary and object_types().has(str(o.get("type", ""))):
			objects.append(load_object(o))
	# An object sitting square in an interior cell takes it over (its type's on_cell): a door / thin wall
	# stands in for the wall block there (still a wall to nav), an arch punches an opening through it.
	# Off-centre (or low enough to see over), a blocks_nav piece cuts the cell links it crosses; the grid
	# underneath is left alone. Pillars and columns take no cell: monsters are pushed out round them.
	for o: Dictionary in objects:
		var info := object_info(o.type)
		var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
		var centred := absf(o.pos_x - c.x) <= 0.26 and absf(o.pos_y - c.y) <= 0.26
		var inside := c.x > 0 and c.y > 0 and c.x < size - 1 and c.y < size - 1
		var half_t := object_thick(o) * 0.5
		var low := seen_over(o)
		var shape := str(info.get("shape", ""))
		if is_stairs(o.type):
			# square on the grid whatever the file says; its cells are the stairwell's, not floor or pit
			o.pos_x = float(c.x)
			o.pos_y = float(c.y)
			o.rotation = fposmod(snappedf(o.rotation, 90.0), 360.0)
			o.scale = 1.0
			for sc in stair_footprint(o):
				if sc.x > 0 and sc.y > 0 and sc.x < size - 1 and sc.y < size - 1:
					walls[sc] = true
					pits.erase(sc)
					stair_cells[sc] = true
		elif shape == "pillar" or shape == "column":
			var at := Vector2(o.pos_x, o.pos_y)
			wall_segments.append([at, at, half_t * (1.2 if shape == "pillar" else 1.0), true])
			if centred and inside: pillar_cells[c] = true
		elif centred and inside and not low and info.get("on_cell") == "wall":
			walls[c] = true
			carved[c] = true
			if o.scale > 1.01 and info.get("blocks_nav", false):   # reaches past its own cell
				_block_span(o, half_t)
		elif centred and inside and info.get("on_cell") == "open":
			walls.erase(c)
			arch_cells[c] = true
		elif info.get("blocks_nav", false):
			_block_span(o, half_t, low)
	var zones: Dictionary = d.get("zones", {})
	for zone in ["tall", "low", "tiles", "bright", "dark", "dim", "flicker", "classic", "liminal", "mannequin",
			"safe", "drain", "loot", "echo", "loop", "open_ceiling", "abyss", "endless_ceiling"]:
		var target: Dictionary = get(zone)
		for c in zones.get(zone, []):
			var v := Vector2i(c[0], c[1])
			if not walls.has(v): target[v] = true
	# A level-wide atmosphere ("atmosphere" in the .lvl, picked in the level editor). "classic" is the
	# Classic zone painted over every open cell, except where a Dark / Dim zone says the tubes are dead.
	# "liminal" is the same for the Liminal zone.
	var look := atmosphere()
	if look == "classic" or look == "liminal":
		var target: Dictionary = get(look)
		for x in size:
			for z in size:
				var v := Vector2i(x, z)
				if not (walls.has(v) or dark.has(v) or dim.has(v)): target[v] = true
	var s = d.get("spawn")
	if not (s is Array and s.size() >= 2): s = _first_open()
	spawn_pos = Vector3(s[0] * CELL, 0.1, s[1] * CELL)
	if d.has("spawn_rot"):                          # the level editor's look-direction arrow (degrees clockwise on the map)
		var f := Vector2.from_angle(deg_to_rad(float(d.spawn_rot)))
		spawn_yaw = atan2(-f.x, -f.y)
		has_spawn_yaw = true
	if not shell:
		_arrive_by_stairs()
		var at := Game.test_spawn.split(",")           # level editor "test from here": start on the cell it picked
		if at.size() == 2 and not walls.has(Vector2i(int(at[0]), int(at[1]))):
			spawn_pos = Vector3(int(at[0]) * CELL, 0.1, int(at[1]) * CELL)
	level_name = str(level_meta.get("name", "LEVEL 0"))

## Arriving by the stairs (Game.floor_link): where a respawn on this floor puts you, one cell out from the
## door of the stairwell you came by (the one nearest where you left), facing away from it. No stairs here:
## the nearest open cell to that spot. (Walking the stairs themselves never moves you: level_builder.gd
## rebuild_floor_seamless keeps you where you stand.)
func _arrive_by_stairs() -> void:
	if Game.floor_link.is_empty(): return
	var from := Vector2(Game.floor_link.x, Game.floor_link.y)
	if Game.floor_link.get("kind", "") in ["drop_hole", "fall"]:
		var ch := _nearest_open(Vector2i(roundi(from.x), roundi(from.y)))
		spawn_pos = Vector3(ch.x * CELL, 0.1, ch.y * CELL)
		return
	var best: Dictionary = {}
	for o: Dictionary in objects:
		if is_stairs(o.type) and (best.is_empty() or Vector2(o.pos_x, o.pos_y).distance_to(from) < Vector2(best.pos_x, best.pos_y).distance_to(from)):
			best = o
	var target := from
	var face := Vector2.ZERO
	if not best.is_empty():
		var dir := Vector2.from_angle(deg_to_rad(best.rotation))      # the way the stairs run (their local +x on the map)
		target = Vector2(best.pos_x, best.pos_y) - dir
		face = -dir
	var c := _nearest_open(Vector2i(roundi(target.x), roundi(target.y)))
	spawn_pos = Vector3(c.x * CELL, 0.1, c.y * CELL)
	if face != Vector2.ZERO:
		spawn_yaw = atan2(-face.x, -face.y)
		has_spawn_yaw = true

func _nearest_open(c: Vector2i) -> Vector2i:
	for r in range(0, size):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r: continue
				var n := c + Vector2i(dx, dz)
				if n.x > 0 and n.y > 0 and n.x < size - 1 and n.y < size - 1 and not walls.has(n) and not pits.has(n):
					return n
	return c

func _first_open() -> Array:
	var c := _nearest_open(Vector2i(size / 2, size / 2))
	return [c.x, c.y]

## "dim" (the default: failing tubes, light that dies in the fog), "classic" (the whole level lit bright
## and steady, clear air) or "liminal" (every tube on and steady, flat pale light, halls that fade into a
## haze far away instead of the dark). New level-wide looks go here and in scripts/Render/atmospheres.gd.
func atmosphere() -> String:
	return str(level_data.get("atmosphere", "dim"))

static func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(roundi(p.x / CELL), roundi(p.z / CELL))

func ceiling_height(c: Vector2i) -> float:
	if tall.has(c): return TALL_H
	if low.has(c): return LOW_H
	return WALL_H

## Record an off-centre blocking object: each span of its shape_path() (the open ends shortened a hair so
## a piece that ends exactly on a cell centre line doesn't catch the links beside it) and every cell link
## that crosses one. `see_over`: a low wall, which blocks the way but not line of sight.
func _block_span(o: Dictionary, half_thick: float, see_over := false) -> void:
	var r := deg_to_rad(o.rotation)
	var p := Vector2(o.pos_x, o.pos_y)
	var path := shape_path(o)
	var n := path.size()
	if n < 2: return
	var closed := path[0].distance_to(path[n - 1]) < 0.001
	if not closed:
		path[0] = path[0].move_toward(path[1], 0.01)
		path[n - 1] = path[n - 1].move_toward(path[n - 2], 0.01)
	for i in n - 1:
		_block_segment(p + path[i].rotated(r), p + path[i + 1].rotated(r), half_thick, see_over)

func _block_segment(a: Vector2, b: Vector2, half_thick: float, see_over: bool) -> void:
	wall_segments.append([a, b, half_thick, see_over])
	for x in range(floori(minf(a.x, b.x)) - 1, ceili(maxf(a.x, b.x)) + 1):
		for z in range(floori(minf(a.y, b.y)) - 1, ceili(maxf(a.y, b.y)) + 1):
			var c := Vector2i(x, z)
			for step: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				if Geometry2D.segment_intersects_segment(Vector2(c), Vector2(c + step), a, b) != null:
					blocked_edges[_edge_key(c, c + step)] = true

static func _edge_key(a: Vector2i, b: Vector2i) -> Vector4i:
	return Vector4i(a.x, a.y, b.x, b.y) if a < b else Vector4i(b.x, b.y, a.x, a.y)

## Walkability for grid_nav.gd's flood fill, built on first use after each load: one byte per cell
## (index x * size + z), a bit set for each step out of it that is open - in bounds, onto a cell that is
## neither wall nor pit, not cut by an off-centre wall. Bits 1/2/4/8 = +x/-x/+z/-z (GridNav.NEIGHBOURS).
## Saves the flood fill two dictionary lookups and a call per neighbour of every cell it visits.
var _step_mask := PackedByteArray()

func step_mask() -> PackedByteArray:
	if _step_mask.size() == size * size:
		return _step_mask
	var m := PackedByteArray()
	m.resize(size * size)
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for x in size:
		for z in size:
			var c := Vector2i(x, z)
			if walls.has(c) or pits.has(c) or safe.has(c): continue          # (a Safe zone: no entity's path crosses it)
			var bits := 0
			for i in 4:
				var nb: Vector2i = c + dirs[i]
				if nb.x < 0 or nb.y < 0 or nb.x >= size or nb.y >= size: continue
				if walls.has(nb) or pits.has(nb) or safe.has(nb) or edge_blocked(c, nb): continue
				bits |= 1 << i
			m[x * size + z] = bits
	_step_mask = m
	return m

## Can't step straight between these neighbouring cells: an off-centre thin wall / door is in the way
func edge_blocked(a: Vector2i, b: Vector2i) -> bool:
	return not blocked_edges.is_empty() and blocked_edges.has(_edge_key(a, b))

## Does the straight line a -> b (in cells) cross an off-centre thin wall / door? Low walls and pillars
## don't count: you see over and past them.
func crosses_wall_segment(a: Vector2, b: Vector2) -> bool:
	for s: Array in wall_segments:
		if s[3]: continue
		if Geometry2D.segment_intersects_segment(a, b, s[0], s[1]) != null: return true
	return false

## An object's placement in the world: origin on the floor, rotated so its local +X faces `rotation`
func object_transform(o: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, -deg_to_rad(o.rotation)), Vector3(o.pos_x * CELL, 0.0, o.pos_y * CELL))

## Which way an old v1 thin wall / archway / door tile at `c` faced: the axis its opening runs along, read
## off whichever pair of opposite neighbors is clear of walls (a corridor punched through in that
## direction). Ties (e.g. an isolated cell) default to running east-west.
func open_axis(c: Vector2i) -> int:
	var ew_open := not walls.has(c + Vector2i(1, 0)) and not walls.has(c + Vector2i(-1, 0))
	var ns_open := not walls.has(c + Vector2i(0, 1)) and not walls.has(c + Vector2i(0, -1))
	return 1 if (ns_open and not ew_open) else 0
