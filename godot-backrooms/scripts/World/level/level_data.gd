extends Node3D
## THE LEVEL, layer 1 of 4: the grid it is built from. Reads levels/levels.json (the playlist the web
## game and tools/level_editor.py share) and the .lvl it points at. Grid rows are z, characters are x:
## '#' wall, '.' floor, 'O' pit. Zones paint extra properties onto cells (tall / low ceilings, tile
## floors, bright / dim / dark lighting, flickering tubes, grime).
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

var size := 0
var walls := {}       # Vector2i -> true
var pits := {}
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
	for z in size:
		var row: String = grid[z] if z < grid.size() else ""
		for x in size:
			var ch := row[x] if x < row.length() else "#"
			var edge := x == 0 or z == 0 or x == size - 1 or z == size - 1
			if edge or ch == "#":
				walls[Vector2i(x, z)] = true
			elif ch == "O":
				pits[Vector2i(x, z)] = true
	var zones: Dictionary = d.get("zones", {})
	for zone in ["tall", "low", "tiles", "bright", "dark", "dim", "flicker", "classic"]:
		var target: Dictionary = get(zone)
		for c in zones.get(zone, []):
			var v := Vector2i(c[0], c[1])
			if not walls.has(v): target[v] = true
	var s: Array = d.get("spawn", [4, 4])
	spawn_pos = Vector3(s[0] * CELL, 0.1, s[1] * CELL)
	level_name = str(level_meta.get("name", "LEVEL 0"))

static func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(roundi(p.x / CELL), roundi(p.z / CELL))

func ceiling_height(c: Vector2i) -> float:
	if tall.has(c): return TALL_H
	if low.has(c): return LOW_H
	return WALL_H
