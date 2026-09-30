extends "res://scripts/World/level/level_lighting.gd"
## Builds a backrooms level from levels/levels.json (edited with the level editor in level-editor/)
## and runs it; it began as a port of the web game's level.js. The work is split into layers, each
## extending the one before:
## level_data.gd (the grid), level_geometry.gd (walls, floors, ceilings, pits, grime), level_fixtures.gd
## (the troffers, flicker, power cuts), level_light_pool.gd (the real lights that follow you) and
## level_lighting.gd (GI, fog, eye adaptation, glare). This last layer
## puts them together and adds the exit, the battery packs, the rolls of hazard tape, the spare camera
## flashes and the tape already stuck up in this level (tape_marks.gd).
##
## Dev keys: PageUp / PageDown switch level, Home reloads it from disk.

const LevelExit := preload("res://scripts/World/props/level_exit.gd")
const BatteryPickup := preload("res://scripts/World/props/battery_pickup.gd")
const BATTERY_PER_CELLS := 60        # roughly one pack per this many open cells
const BATTERY_MIN_SPAWN_DIST := 3    # cells: none right at the spawn point
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")
const SketchMarks := preload("res://scripts/World/props/sketch_marks.gd")
const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const TAPE_PER_CELLS := 300          # rare: one roll lasts a long while
const FlashPickup := preload("res://scripts/World/props/flash_pickup.gd")
const FLASH_PER_CELLS := 250         # rare: a flash is a way out of one chase
const SurveyClipboard := preload("res://scripts/World/props/survey_clipboard.gd")
const DeadFixture := preload("res://scripts/World/props/dead_fixture.gd")
const CLIPBOARD_PER_CELLS := 90
const DEAD_FIXTURE_PER_CELLS := 75

var exit_door: Node3D

func _ready() -> void:
	rng.seed = 1971                    # the same layout of burnt / flickering tubes every run
	load_current()
	build_geometry()
	build_lighting()
	_build_exit()
	_spawn_batteries()
	_spawn_tape()
	_spawn_flashes()
	_spawn_survey_props()
	var marks := TapeMarks.new()
	marks.name = "TapeMarks"
	add_child(marks)
	var sketches := SketchMarks.new()
	sketches.name = "SketchMarks"
	add_child(sketches)

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
	_scatter(func(): return BatteryPickup.new(), BATTERY_PER_CELLS, 2, 12)

# ---------------------------------------------------------------- hazard tape
func _spawn_tape() -> void:
	_scatter(func(): return TapePickup.new(), TAPE_PER_CELLS, 1, 2)

# ---------------------------------------------------------------- camera flashes
func _spawn_flashes() -> void:
	_scatter(func(): return FlashPickup.new(), FLASH_PER_CELLS, 1, 2)

# ---------------------------------------------------------------- interactive survey props
func _spawn_survey_props() -> void:
	_scatter(func(): return SurveyClipboard.new(), CLIPBOARD_PER_CELLS, 2, 6)
	_scatter(func(): return DeadFixture.new(), DEAD_FIXTURE_PER_CELLS, 2, 8)

## Seamless in-place floor transition: unloads current floor geometry and builds floor `f`
## without any loading screen or scene reload.
func rebuild_floor_seamless(f: int, link: Dictionary = {}) -> void:
	Game.level_floor = f
	Game.floor_link = link

	# 1. Clear dynamic floor children, keeping persistent marks, light pool, and voxel_gi
	var marks := get_node_or_null("TapeMarks")
	var sketches := get_node_or_null("SketchMarks")
	var pool_set := {}
	for l in pool + pool_b + far_pool + ceil_glow:
		if l != null:
			pool_set[l] = true

	var to_remove: Array[Node] = []
	for c in get_children():
		if c == marks or c == sketches or pool_set.has(c) or c == voxel_gi:
			continue
		to_remove.append(c)

	for c in to_remove:
		c.free()

	# 2. Reset data structures
	walls.clear()
	pits.clear()
	objects.clear()
	carved.clear()
	arch_cells.clear()
	blocked_edges.clear()
	wall_segments.clear()
	tall.clear()
	low.clear()
	tiles.clear()
	bright.clear()
	dark.clear()
	dim.clear()
	flicker.clear()
	mannequin.clear()
	classic.clear()
	_painted.clear()
	has_spawn_yaw = false

	# 3. Reset fixture arrays
	fx.clear()
	lit.clear()
	fill_lights.clear()
	reflect_mmi = null
	tubes_mm = null
	lens_mm = null
	panels_mm = null
	for i in slot_fixture.size():
		slot_fixture[i] = null
		slot_weight[i] = 0.0
		slot_target[i] = 0.0
		slot_on[i] = 0.0
		slot_want[i] = false
		slot_single[i] = 0.0
	for i in far_fixture.size():
		far_fixture[i] = null
		far_weight[i] = 0.0

	# 4. Load floor data
	level_data = floor_data(read_level(level_meta), f)
	_parse(level_data)
	_arrive_by_stairs()

	# 5. Build geometry & lighting
	build_geometry()
	if panel_ceiling != null:
		_place_panel_fixtures()
		_build_panel_ceiling()
	else:
		_place_fixtures()
		_build_fixture_meshes()
	_build_floor_reflections()
	_apply_gi()

	# 6. Build exit & props
	_build_exit()
	_spawn_batteries()
	_spawn_tape()
	_spawn_flashes()
	_spawn_survey_props()

	# 7. Reload marks for the new floor
	if marks != null and marks.has_method("reload_floor"):
		marks.reload_floor()
	if sketches != null and sketches.has_method("reload_floor"):
		sketches.reload_floor()

	# 8. Move player to the arrival position seamlessly
	var p: Node3D = player if player != null else Game.player
	if p != null and is_instance_valid(p):
		p.global_position = spawn_pos
		if has_spawn_yaw:
			p.rotation.y = spawn_yaw
		if p is CharacterBody3D:
			(p as CharacterBody3D).velocity = Vector3.ZERO

	# 9. Notify entity of updated grid navigation
	var root := get_parent()
	if root != null:
		var ent: Node = root.get_node_or_null("Entity")
		if ent != null and ent.has_method("_setup_nav"):
			ent._setup_nav()
			if ent.has_method("_spawn_cell"):
				var sp: Array = ent._spawn_cell()
				ent.global_position = Vector3(sp[0] * CELL, 0.0, sp[1] * CELL)

## Seamless in-place level transition: changes to playlist entry `idx` without a loading screen.
func load_level_seamless(idx: int) -> void:
	var levels := read_index()
	Game.level_count = levels.size()
	level_index = clampi(idx, 0, levels.size() - 1)
	level_meta = levels[level_index]
	rebuild_floor_seamless(0, {})

## `make` a pickup at about one per `per_cells` open floor cells (between lo and hi of them),
## none right at the spawn point
func _scatter(make: Callable, per_cells: int, lo: int, hi: int) -> void:
	var r := RandomNumberGenerator.new()
	r.randomize()
	var spawn_c := Vector2i(roundi(spawn_pos.x / CELL), roundi(spawn_pos.z / CELL))
	var open: Array[Vector2i] = []
	for z in size:
		for x in size:
			var c := Vector2i(x, z)
			if walls.has(c) or pits.has(c): continue
			if absi(c.x - spawn_c.x) + absi(c.y - spawn_c.y) < BATTERY_MIN_SPAWN_DIST: continue
			open.append(c)
	if open.is_empty(): return
	var count := clampi(open.size() / per_cells, lo, hi)
	for i in count:
		if open.is_empty(): break
		var c: Vector2i = open.pop_at(r.randi_range(0, open.size() - 1))
		var b: Node3D = make.call()
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
