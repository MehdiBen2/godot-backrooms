extends "res://scripts/world/level/level_lighting.gd"
## Builds a backrooms level from levels/levels.json (the same data the web game uses) and runs it:
## a port of the web game's level.js. The work is split into layers, each extending the one before:
## level_data.gd (the grid), level_geometry.gd (walls, floors, ceilings, pits, grime) and
## level_lighting.gd (the troffers, the light pool that follows you, flicker and fog). This last layer
## puts them together and adds the exit and the battery packs.
##
## Dev keys: PageUp / PageDown switch level, Home reloads it from disk.

const LevelExit := preload("res://scripts/world/props/level_exit.gd")
const BatteryPickup := preload("res://scripts/world/props/battery_pickup.gd")
const BATTERY_PER_CELLS := 60        # roughly one pack per this many open cells
const BATTERY_MIN_SPAWN_DIST := 3    # cells: none right at the spawn point

var exit_door: Node3D

func _ready() -> void:
	rng.seed = 1971                    # the same layout of burnt / flickering tubes every run
	load_current()
	build_geometry()
	build_lighting()
	_build_exit()
	_spawn_batteries()

func _process(delta: float) -> void:
	update_lighting(delta)

## What is underfoot at `p`: "tile" in the polished rooms, "carpet" everywhere else
func surface_at(p: Vector3) -> String:
	return "tile" if tiles.has(cell_of(p)) else "carpet"

# ---------------------------------------------------------------- exit
func _build_exit() -> void:
	var e = level_data.get("exit")
	if not (e is Array) or e.size() < 2:
		return
	exit_door = LevelExit.new()
	exit_door.position = Vector3(e[0] * CELL, 0.0, e[1] * CELL)
	add_child(exit_door)

# ---------------------------------------------------------------- battery packs
# Scattered at random open floor cells each load (own RNG: the level's rng is fixed-seeded).
func _spawn_batteries() -> void:
	var r := RandomNumberGenerator.new()
	r.randomize()
	var s: Array = level_data.get("spawn", [4, 4])
	var spawn_c := Vector2i(s[0], s[1])
	var open: Array[Vector2i] = []
	for z in size:
		for x in size:
			var c := Vector2i(x, z)
			if walls.has(c) or pits.has(c): continue
			if absi(c.x - spawn_c.x) + absi(c.y - spawn_c.y) < BATTERY_MIN_SPAWN_DIST: continue
			open.append(c)
	if open.is_empty(): return
	var count := clampi(open.size() / BATTERY_PER_CELLS, 2, 12)
	for i in count:
		if open.is_empty(): break
		var c: Vector2i = open.pop_at(r.randi_range(0, open.size() - 1))
		var b := BatteryPickup.new()
		b.position = Vector3(c.x * CELL + r.randf_range(-1.4, 1.4), 0.0, c.y * CELL + r.randf_range(-1.4, 1.4))
		b.rotation.y = r.randf() * TAU
		add_child(b)

func _unhandled_input(e: InputEvent) -> void:
	if not Game.dev_keys or not (e is InputEventKey and e.pressed and not e.echo):
		return
	match e.physical_keycode:
		KEY_PAGEDOWN: Game.change_level(Game.level_index + 1)
		KEY_PAGEUP: Game.change_level(Game.level_index - 1)
		KEY_HOME: Game.change_level(Game.level_index)
