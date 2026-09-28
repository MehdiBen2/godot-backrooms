extends "res://scripts/World/level/level_lighting.gd"
## Builds a backrooms level from levels/levels.json (the same data the web game uses) and runs it:
## a port of the web game's level.js. The work is split into layers, each extending the one before:
## level_data.gd (the grid), level_geometry.gd (walls, floors, ceilings, pits, grime), level_fixtures.gd
## (the troffers, flicker, power cuts), level_light_pool.gd (the real lights that follow you) and
## level_lighting.gd (GI, fog, eye adaptation, glare). This last layer
## puts them together and adds the exit and the battery packs.
##
## Dev keys: PageUp / PageDown switch level, Home reloads it from disk.

const LevelExit := preload("res://scripts/World/props/level_exit.gd")
const BatteryPickup := preload("res://scripts/World/props/battery_pickup.gd")
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
## F3: stand the player beside the exit door (on the nearest open cell to it)
func _goto_exit() -> void:
	var ex = level_data.get("exit")
	var p: Node3D = Game.player as Node3D
	if not (ex is Array) or ex.size() < 2 or p == null:
		return
	var c := Vector2i(ex[0], ex[1])
	var best := c
	var best_d := 1e9
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			var n := c + Vector2i(dx, dz)
			if n == c or walls.has(n) or pits.has(n): continue
			var d := dx * dx + dz * dz
			if d < best_d:
				best_d = d
				best = n
	p.global_position = Vector3(best.x * CELL, 0.1, best.y * CELL)
	if p is CharacterBody3D: (p as CharacterBody3D).velocity = Vector3.ZERO
	p.look_at(Vector3(c.x * CELL, p.global_position.y, c.y * CELL), Vector3.UP)

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

## Level keys: F1 previous level, PageDown next level (F2 is the hills portal, hills_portal.gd), F3 teleport to this level's exit.
## Also on for editor test launches (--noclip), so they work in a released build.
func _unhandled_input(e: InputEvent) -> void:
	if not (Game.dev_keys or Game.noclip) or not (e is InputEventKey and e.pressed and not e.echo):
		return
	if not e.shift_pressed:
		match e.physical_keycode:
			KEY_F1: Game.change_level(Game.level_index - 1)
			KEY_F3: _goto_exit()
	if not Game.dev_keys:
		return
	match e.physical_keycode:
		KEY_PAGEDOWN: Game.change_level(Game.level_index + 1)
		KEY_PAGEUP: Game.change_level(Game.level_index - 1)
		KEY_HOME: Game.change_level(Game.level_index)
