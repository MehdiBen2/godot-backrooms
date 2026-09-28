extends Node3D
## THE LEVEL, layer 1 of 4: the grid it is built from. Reads levels/levels.json (the playlist the web
## game and tools/level_editor.py share) and the .lvl it points at. Grid rows are z, characters are x:
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

@export var level_index := 0

## Free-standing architectural pieces, placed off-grid in the level editor ("objects" in the .lvl).
## Positions are in cells where a cell's centre is a whole number (the same frame as "spawn"), so world =
## pos * CELL. `rotation` is degrees clockwise on the editor's top-down map (+X east, +Z south); in local
## space every piece faces +X (the direction you walk through it) and spans `scale` cells along Z. What each
## type is (size, what it does to the grid, how the editor shows it) lives in levels/object_types.json,
## shared with the level editor.
const OBJECT_TYPES_PATH := "res://levels/object_types.json"
static var _object_types := {}

var size := 0
var walls := {}       # Vector2i -> true
var pits := {}
var objects: Array = []   # {type, pos_x, pos_y, rotation, scale}, see object_types()
var carved := {}      # Vector2i -> true: a wall cell an object stands in, so no solid block is built there
var arch_cells := {}  # Vector2i -> true: a cell with an arch square in it (walkable, but full of arch mass)
## Off-centre blocking objects (a thin wall or door on a cell edge, or at an angle) don't fill a cell, so
## instead they cut the links between cells for the monster's grid nav: blocked_edges holds each pair of
## neighbouring cells whose centre-to-centre step crosses one, wall_segments the spans themselves
## ([from, to] in cells, half thickness in metres) for line of sight and push-out collision.
var blocked_edges := {}   # Vector4i(a.x, a.y, b.x, b.y), a < b -> true
var wall_segments: Array = []
var tall := {}
var low := {}
var tiles := {}
var bright := {}
var dark := {}
var dim := {}
var flicker := {}
var classic := {}     # the super-bright classic backrooms look: steady dense tubes, clear air, glowing yellow
var spawn_pos := Vector3.ZERO
var level_data := {}
var level_meta := {}
var level_name := "LEVEL 0"
var player: Node3D
var rng := RandomNumberGenerator.new()

# The same files the web game and tools/level_editor.py use: levels/levels.json is the playlist
# ([{id, name, file}]) and each file is a .lvl (JSON: size, spawn, exit, entity, tv, grid, zones).
# The Python editor mirrors saves straight into this folder.
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
	var levels := read_index()
	Game.level_count = levels.size()
	level_index = clampi(Game.level_index, 0, levels.size() - 1)
	level_meta = levels[level_index]
	level_data = read_level(level_meta)
	_parse(level_data)

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
	# old tiles become objects facing whichever way the corridor runs (needs the full wall set first)
	for v: Vector2i in legacy:
		objects.append({"type": legacy[v], "pos_x": float(v.x), "pos_y": float(v.y), "rotation": 90.0 * open_axis(v), "scale": 1.0})
	for o in d.get("objects", []):
		if o is Dictionary and object_types().has(str(o.get("type", ""))):
			objects.append({"type": str(o.type), "pos_x": float(o.get("pos_x", 0.0)), "pos_y": float(o.get("pos_y", 0.0)),
				"rotation": float(o.get("rotation", 0.0)), "scale": clampf(float(o.get("scale", 1.0)), 0.5, 4.0)})
	# An object sitting square in an interior cell takes it over (its type's on_cell): a door / thin wall
	# stands in for the wall block there (still a wall to nav), an arch punches an opening through it.
	# Off-centre, a blocks_nav piece cuts the cell links it crosses; the grid underneath is left alone.
	for o: Dictionary in objects:
		var info := object_info(o.type)
		var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
		var centred := absf(o.pos_x - c.x) <= 0.26 and absf(o.pos_y - c.y) <= 0.26
		if centred and c.x > 0 and c.y > 0 and c.x < size - 1 and c.y < size - 1:
			if info.get("on_cell") == "wall":
				walls[c] = true
				carved[c] = true
				if o.scale > 1.01 and info.get("blocks_nav", false):   # reaches past its own cell
					_block_span(o, float(info.get("thickness", 0.3)) * 0.5)
			elif info.get("on_cell") == "open":
				walls.erase(c)
				arch_cells[c] = true
		elif info.get("blocks_nav", false):
			_block_span(o, float(info.get("thickness", 0.3)) * 0.5)
	var zones: Dictionary = d.get("zones", {})
	for zone in ["tall", "low", "tiles", "bright", "dark", "dim", "flicker", "classic"]:
		var target: Dictionary = get(zone)
		for c in zones.get(zone, []):
			var v := Vector2i(c[0], c[1])
			if not walls.has(v): target[v] = true
	# A level-wide atmosphere ("atmosphere" in the .lvl, picked in the level editor). "classic" is the
	# Classic zone painted over every open cell, except where a Dark / Dim zone says the tubes are dead.
	if atmosphere() == "classic":
		for x in size:
			for z in size:
				var v := Vector2i(x, z)
				if not (walls.has(v) or dark.has(v) or dim.has(v)): classic[v] = true
	var s: Array = d.get("spawn", [4, 4])
	spawn_pos = Vector3(s[0] * CELL, 0.1, s[1] * CELL)
	level_name = str(level_meta.get("name", "LEVEL 0"))

## "dim" (the default: failing tubes, light that dies in the fog) or "classic" (the whole level lit bright
## and steady, clear air). New level-wide looks go here and in level_lighting.gd's ATMOSPHERES.
func atmosphere() -> String:
	return str(level_data.get("atmosphere", "dim"))

static func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(roundi(p.x / CELL), roundi(p.z / CELL))

func ceiling_height(c: Vector2i) -> float:
	if tall.has(c): return TALL_H
	if low.has(c): return LOW_H
	return WALL_H

## Record an off-centre blocking object: its span (along local Z, shortened a hair so a piece that ends
## exactly on a cell centre line doesn't catch the links beside it) and every cell link that crosses it
func _block_span(o: Dictionary, half_thick: float) -> void:
	var r := deg_to_rad(o.rotation)
	var half: Vector2 = Vector2(-sin(r), cos(r)) * (o.scale * 0.5 - 0.01)
	var p := Vector2(o.pos_x, o.pos_y)
	var a := p - half
	var b := p + half
	wall_segments.append([a, b, half_thick])
	for x in range(floori(minf(a.x, b.x)) - 1, ceili(maxf(a.x, b.x)) + 1):
		for z in range(floori(minf(a.y, b.y)) - 1, ceili(maxf(a.y, b.y)) + 1):
			var c := Vector2i(x, z)
			for step: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				if Geometry2D.segment_intersects_segment(Vector2(c), Vector2(c + step), a, b) != null:
					blocked_edges[_edge_key(c, c + step)] = true

static func _edge_key(a: Vector2i, b: Vector2i) -> Vector4i:
	return Vector4i(a.x, a.y, b.x, b.y) if a < b else Vector4i(b.x, b.y, a.x, a.y)

## Can't step straight between these neighbouring cells: an off-centre thin wall / door is in the way
func edge_blocked(a: Vector2i, b: Vector2i) -> bool:
	return not blocked_edges.is_empty() and blocked_edges.has(_edge_key(a, b))

## Does the straight line a -> b (in cells) cross an off-centre thin wall / door?
func crosses_wall_segment(a: Vector2, b: Vector2) -> bool:
	for s: Array in wall_segments:
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
