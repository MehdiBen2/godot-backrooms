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
## One floor of the level is the one you walk on, built here at y = 0. Changing floor rebuilds it in place
## (rebuild_floor_seamless). The floors above and below that can be seen from it, through holes in the slabs,
## stand round it as look-only copies (`shells`, level_shell.gd).
##
## Dev keys: PageUp / PageDown switch level, Home reloads it from disk.

const LevelExit := preload("res://scripts/World/props/level_exit.gd")
const TerminalMachine := preload("res://scripts/World/props/terminal_machine.gd")
const BatteryPickup := preload("res://scripts/World/props/battery_pickup.gd")
const BATTERY_PER_CELLS := 60        # roughly one pack per this many open cells
const BATTERY_MIN_SPAWN_DIST := 3    # cells: none right at the spawn point
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")
const SketchMarks := preload("res://scripts/World/props/sketch_marks.gd")
const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const CableMarks := preload("res://scripts/World/props/cable_marks.gd")
const PortalMarks := preload("res://scripts/World/props/portal_marks.gd")
const TAPE_PER_CELLS := 300          # rare: one roll lasts a long while
const FlashPickup := preload("res://scripts/World/props/flash_pickup.gd")
const FLASH_PER_CELLS := 250         # rare: a flash is a way out of one chase
const SurveyClipboard := preload("res://scripts/World/props/survey_clipboard.gd")
const LaunchBay := preload("res://scripts/World/props/tsra_launch_bay.gd")
const LOOT_WEIGHT := 6               # how many ordinary cells a Loot zone cell is worth when things are scattered
const CLIPBOARD_PER_CELLS := 90

var exit_door: Node3D

func _ready() -> void:
	Stability.trace("level: building")
	rng.seed = _floor_seed()           # the same layout of burnt / flickering tubes every run
	built_floor = Game.level_floor
	load_current()
	Stability.trace("level: level data loaded")
	step_mask()                        # the nav table, now while loading, not on a monster's first flood fill
	build_geometry()
	Stability.trace("level: geometry built")
	build_lighting()
	Stability.trace("level: lighting built")
	_build_exit()
	_spawn_batteries()
	_spawn_tape()
	_spawn_flashes()
	_spawn_survey_props()
	Stability.trace("level: props spawned")
	var marks := TapeMarks.new()
	marks.name = "TapeMarks"
	add_child(marks)
	var sketches := SketchMarks.new()
	sketches.name = "SketchMarks"
	add_child(sketches)
	var cables := CableMarks.new()
	cables.name = "CableMarks"
	add_child(cables)
	var portals := PortalMarks.new()
	portals.name = "PortalMarks"
	add_child(portals)
	_find_loops()
	_sync_shells()
	_build_wrap_copies()
	Stability.trace("level: level fully built")
	_prewarm_floors()

func _process(delta: float) -> void:
	var _pt := Time.get_ticks_usec()
	_process_timed(delta)
	Perf.add("Level", _pt)

func _process_timed(delta: float) -> void:
	if rebuilding or _stub:            # no fixtures to light with until the floor is built
		_pace_build(delta)
		return
	if Game.freefall: return           # down a bottomless pit: pit_fall.gd has the fog, and the level is out of sight
	update_lighting(delta)

## Through a hole in the floor into the one below: that floor takes over half way down the slab between them,
## with the player where they are, still falling (rebuild_floor_seamless, kind "fall")
func _physics_process(_delta: float) -> void:
	var _pt := Time.get_ticks_usec()
	_physics_process_timed(_delta)
	Perf.add("Level (physics)", _pt)

func _physics_process_timed(_delta: float) -> void:
	if rebuilding or player == null or Game.draw_mode or Game.dead or Death.respawn_busy or Game.freefall:
		return
	if edge_wrap: _wrap_player()          # (noclip too: flying off the edge of an endless level comes back round)
	if Game.noclip: return
	if not _loops.is_empty(): _walk_loops()
	var p := player.global_position
	if _stub:
		if not through.has(cell_of(p)): _realize_stub()
		elif fell_through(p): Game.change_floor(built_floor - 1, Vector2(p.x, p.z) / CELL, "fall", STOREY_H)
		return
	var standing: bool = player is CharacterBody3D and (player as CharacterBody3D).is_on_floor()
	# up a flight or spiral that runs on through the ceiling (level_data.gd climb_cells): the floor above takes over
	# as you come up level with it, and you walk on out onto it
	if standing and not climb_up.is_empty() and p.y > STOREY_H - CLIMB_SWAP and climb_up.has(cell_of(p)):
		Game.change_floor(built_floor + 1, Vector2(p.x, p.z) / CELL, "climb", -STOREY_H)
		return
	if through.is_empty(): return
	if standing: _fallen = 0
	if not fell_through(p): return
	if standing and climb_down.has(cell_of(p)):
		# walking back down those stairs: the floor below takes over at once, under your feet
		Game.change_floor(built_floor - 1, Vector2(p.x, p.z) / CELL, "descend", STOREY_H)
		return
	_fallen += 1
	if _fallen > FALL_LIMIT:
		# an endless level's shaft has no bottom: after this many storeys you find yourself standing beside it
		_fallen = 0
		player.global_position = spawn_pos
		if player is CharacterBody3D: (player as CharacterBody3D).velocity = Vector3.ZERO
		return
	Game.change_floor(built_floor - 1, Vector2(p.x, p.z) / CELL, "fall", STOREY_H)

const FALL_LIMIT := 24
const CLIMB_SWAP := 1.2            # m under the floor above at which, climbing stairs up to it, it takes over
var _fallen := 0                   # storeys fallen through since the player last stood on a floor

# ---------------------------------------------------------------- corridors that never end
## A Loop zone (level_data.gd `loop`) painted along a corridor: walk on down it and, a cell short of its far
## end, you are put back that far short of the end you came in by, an even number of cells (the tubes of a
## corridor hang every other cell, and in a Loop zone all of them are lit and steady), looking the same way,
## in step. Nothing shows it, so the corridor goes on for as long as you keep walking. Turning back takes you
## out the way you came in. Each run of joined Loop cells at least LOOP_MIN long is one loop, along its length.
const LOOP_MIN := 6
var _loops: Array = []             # each {axis: 0 along x / 1 along z, lo, hi (cells along it), shift (cells)}
var _loop_of := {}                 # Vector2i -> its place in _loops
var _loop_in := -1                 # the loop the player is in
var _loop_side := 0                # -1: they came in by its low end, 1: its high end

func _find_loops() -> void:
	_loops.clear()
	_loop_of.clear()
	_loop_in = -1
	var seen := {}
	for start: Vector2i in loop:
		if seen.has(start): continue
		var cells: Array = [start]
		seen[start] = true
		var lo := start
		var hi := start
		var k := 0
		while k < cells.size():
			var c: Vector2i = cells[k]
			k += 1
			lo = lo.min(c)
			hi = hi.max(c)
			for d: Vector2i in DIRS:
				var nb: Vector2i = c + d
				if loop.has(nb) and not seen.has(nb):
					seen[nb] = true
					cells.append(nb)
		var axis := 0 if hi.x - lo.x >= hi.y - lo.y else 1
		var a: int = lo.x if axis == 0 else lo.y
		var b: int = hi.x if axis == 0 else hi.y
		if b - a + 1 < LOOP_MIN: continue
		var shift := ((b - a - 2) / 2) * 2               # even, and it lands at least a cell inside the other end
		for c: Vector2i in cells: _loop_of[c] = _loops.size()
		_loops.append({"axis": axis, "lo": a, "hi": b, "shift": shift})

func _walk_loops() -> void:
	var p := player.global_position
	var id: int = _loop_of.get(cell_of(p), -1)
	if id < 0:
		_loop_in = -1
		return
	var run: Dictionary = _loops[id]
	var along: float = (p.x if run.axis == 0 else p.z) / CELL
	if id != _loop_in:
		_loop_in = id
		_loop_side = -1 if along < (float(run.lo) + float(run.hi)) * 0.5 else 1
		return
	var move := 0.0
	if _loop_side < 0 and along > float(run.hi) - 1.0: move = -float(run.shift) * CELL
	elif _loop_side > 0 and along < float(run.lo) + 1.0: move = float(run.shift) * CELL
	if move == 0.0: return
	if run.axis == 0: player.global_position.x += move
	else: player.global_position.z += move

# ---------------------------------------------------------------- halls that never end
## Endless halls (level_data.gd edge_wrap): the player who crosses the edge of the map is moved one period back,
## onto the other side, which looks exactly like what they were walking into (the copies, _build_wrap_copies).
## The real lights follow at once (_rank_timer: re-ranked this frame), so nothing pops. Monsters keep to the
## map (the border is closed to their paths): crossing the seam is a way to lose one.
signal wrapped(move: Vector3)

func _wrap_player() -> void:
	var p := player.global_position
	var lo := 0.5 * CELL
	var hi := (size - 1.5) * CELL
	var w := wrap_size()
	var move := Vector3.ZERO
	if p.x > hi: move.x = -w
	elif p.x < lo: move.x = w
	if p.z > hi: move.z = -w
	elif p.z < lo: move.z = w
	if move == Vector3.ZERO: return
	player.global_position += move
	_rank_timer = 0.0
	wrapped.emit(move)

## The level drawn again one period away on all eight sides, so the halls run on past every edge out to the
## horizon (and what is across the seam is there to see before you cross it). Each copy shares the level's
## meshes and MultiMeshes, so a tube flickering, a power cut or a tint shows in every copy at once, and costs
## draw calls only where it is in view: frustum and occlusion culling (the occluders are copied too) drop the
## rest. Only what the floor itself built is copied: no props, monsters, marks or stairwells.
var _wrap_root: Node3D
var _view_far := -1.0                  # the camera's own far plane, put back on a level that doesn't wrap

func _build_wrap_copies() -> void:
	if is_instance_valid(_wrap_root): _wrap_root.free()
	_wrap_root = null
	_apply_wrap_view.call_deferred()       # (deferred: the level is built before main.gd hands it the player)
	if not edge_wrap or shell: return
	var src: Array = []
	_collect_wrap(self, src)
	_wrap_root = Node3D.new()
	_wrap_root.name = "WrapCopies"
	add_child(_wrap_root)
	var w := wrap_size()
	var mats := {}
	for sx in range(-1, 2):
		for sz in range(-1, 2):
			if sx == 0 and sz == 0: continue
			var off := Vector3(sx * w, 0.0, sz * w)
			for n: Node3D in src:
				var c := _wrap_copy(n, off, mats)
				if c == null: continue
				_wrap_root.add_child(c)
				c.global_transform = Transform3D(n.global_transform.basis, n.global_transform.origin + off)

## The plain geometry the floor's build made (no scripted node or scene, nor anything under one)
func _collect_wrap(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c == _wrap_root or c == _horizon or c in shells.values() or c.has_meta("demoted"): continue
		if c.get_script() != null or c.scene_file_path != "" or c is Light3D: continue
		if (c is GeometryInstance3D and (c as Node3D).visible) or c is OccluderInstance3D: out.append(c)
		if c is Node3D: _collect_wrap(c, out)

func _wrap_copy(n: Node3D, off: Vector3, mats: Dictionary) -> Node3D:
	if n is OccluderInstance3D:
		var oi := OccluderInstance3D.new()
		oi.occluder = (n as OccluderInstance3D).occluder
		return oi
	var g: GeometryInstance3D
	if n is MultiMeshInstance3D:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = (n as MultiMeshInstance3D).multimesh
		g = mmi
	elif n is MeshInstance3D:
		var src := n as MeshInstance3D
		var mi := MeshInstance3D.new()
		mi.mesh = src.mesh
		for i in src.get_surface_override_material_count():
			mi.set_surface_override_material(i, _wrap_mat(src.get_surface_override_material(i), off, mats))
		g = mi
	else:
		return null
	var s := n as GeometryInstance3D
	g.material_override = _wrap_mat(s.material_override, off, mats)
	g.material_overlay = s.material_overlay
	g.cast_shadow = s.cast_shadow
	g.layers = s.layers
	g.extra_cull_margin = s.extra_cull_margin
	# the copy drops out with its original's range: it is as far from the camera as the original would be
	g.visibility_range_begin = s.visibility_range_begin
	g.visibility_range_begin_margin = s.visibility_range_begin_margin
	g.visibility_range_end = s.visibility_range_end
	g.visibility_range_end_margin = s.visibility_range_end_margin
	g.visibility_range_fade_mode = s.visibility_range_fade_mode
	g.gi_mode = GeometryInstance3D.GI_MODE_DISABLED     # (the baked GI covers the level itself only)
	return g

## A material as the copy `off` away needs it: one that textures by world position samples where the level it
## copies would (world-triplanar ones by their uv offset, the level's own shaders by their world_shift), so
## the pattern runs on across the seam without a jump. Anything else is shared as it is.
func _wrap_mat(m: Material, off: Vector3, cache: Dictionary) -> Material:
	if m == null: return null
	var shifted := false
	if m is BaseMaterial3D:
		shifted = (m as BaseMaterial3D).uv1_triplanar and (m as BaseMaterial3D).uv1_world_triplanar
	elif m is ShaderMaterial:
		var sh := (m as ShaderMaterial).shader
		shifted = sh != null and sh.code.contains("world_shift")
	if not shifted: return m
	var key := "%d|%s" % [m.get_instance_id(), off]
	if not cache.has(key):
		var d := m.duplicate() as Material
		if d is BaseMaterial3D:
			var b := d as BaseMaterial3D
			b.uv1_offset = b.uv1_offset - off * b.uv1_scale
		else:
			(d as ShaderMaterial).set_shader_parameter("world_shift", -off)
		if m in ceil_mats: ceil_mats.append(d)        # (level_lighting.gd drives their ceiling fill too)
		cache[key] = d
	return cache[key]

## How far the view reaches: on an endless level the horizon fog is pushed out to nearly a period (the copies
## fill that far in every direction) and the camera's far plane with it; elsewhere both are as they were
func _apply_wrap_view() -> void:
	var cam: Camera3D = player.get("cam") if player != null and is_instance_valid(player) else null
	if cam != null and _view_far < 0.0: _view_far = cam.far
	var end := _fog_end()                  # (level_geometry.gd: the same reach the floors and ceilings are ranged to)
	var begin := maxf(HORIZON_BEGIN, end * 0.45)
	if _horizon_mat != null:
		_horizon_mat.set_shader_parameter("begin", begin)
		_horizon_mat.set_shader_parameter("end", end)
	if cam != null and _view_far > 0.0:
		cam.far = maxf(_view_far, end + 30.0) if end > FOG_END else _view_far

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
	if exit_door != null:
		var at := exit_door.global_position
		p.global_position = at + exit_door.global_transform.basis.x * 2.5 + Vector3(0, 0.1, 0)
		if p is CharacterBody3D: (p as CharacterBody3D).velocity = Vector3.ZERO
		p.look_at(Vector3(at.x, p.global_position.y, at.z), Vector3.UP)
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
	_build_exit_door("exit", false)
	_build_exit_door("fake_exit", true)    # looks the same, goes nowhere

func _build_exit_door(key: String, fake: bool) -> void:
	var e = level_data.get(key)
	if not (e is Array) or e.size() < 2:
		return
	var door := LevelExit.new()
	door.fake = fake
	var c := Vector2i(e[0], e[1])
	var mount := _exit_mount(c)
	if mount.is_empty():
		# no wall in reach: the door stands at the exit cell in a slab of wall of its own
		door.position = Vector3(c.x * CELL, 0.0, c.y * CELL)
		door.backing = grand_wall_mat if grand.has(c) else (tall_wall_mat if tall.has(c) else wall_mat)
		door.backing_h = ceiling_height(c)
	else:
		# on the wall's face, between the open cell and the wall cell, turned so its +X is out into the room
		var from: Vector2i = mount[0]
		var d: Vector2i = mount[1]
		door.position = Vector3((from.x + d.x * 0.5) * CELL, 0.0, (from.y + d.y * 0.5) * CELL)
		door.rotation.y = atan2(d.y, -d.x)
	if not fake:
		exit_door = door
	add_child(door)

const EXIT_REACH := 8                # cells from the exit cell a wall is looked for

## Where the exit door goes: [the open cell it is walked up to from, the step from that cell into the wall].
## The exit cell's own wall if it has one beside it (or is one), else the nearest wall straight along a row
## or column from it. Empty: none in reach.
func _exit_mount(c: Vector2i) -> Array:
	if _block_at(c):
		for d: Vector2i in DIRS:
			if _exit_floor(c + d): return [c + d, -d]
		return []
	var best: Array = []
	var best_k := EXIT_REACH
	for d: Vector2i in DIRS:
		for k in best_k:
			var o: Vector2i = c + d * k
			if not _exit_floor(o) or (k > 0 and edge_blocked(o - d, o)): break
			if _block_at(o + d):
				best = [o, d]
				best_k = k
				break
	return best

func _exit_floor(c: Vector2i) -> bool:
	return not (walls.has(c) or pits.has(c) or arch_cells.has(c) or pillar_cells.has(c) or pool_cells.has(c))

# ---------------------------------------------------------------- battery packs
# Scattered at random open floor cells each load (own RNG: the level's rng is fixed-seeded).
func _spawn_batteries() -> void:
	if is_hub(): return
	_scatter(func(): return BatteryPickup.new(), BATTERY_PER_CELLS, 2, 12)

# ---------------------------------------------------------------- hazard tape
func _spawn_tape() -> void:
	if is_hub(): return
	_scatter(func(): return TapePickup.new(), TAPE_PER_CELLS, 1, 2)

# ---------------------------------------------------------------- camera flashes
func _spawn_flashes() -> void:
	if is_hub(): return
	_scatter(func(): return FlashPickup.new(), FLASH_PER_CELLS, 1, 2)

# ---------------------------------------------------------------- interactive survey props
func _spawn_survey_props() -> void:
	if is_hub():
		# the T.S.R.A. hub (levels/tsra_hub.lvl): the launch bay brings the terminal, the lever and the gate
		var bay := LaunchBay.new()
		bay.name = "LaunchBay"
		add_child(bay)
		bay.setup(level_data.get("hub"))
		var first_notebook := SurveyClipboard.new()
		first_notebook.position = spawn_pos + Vector3(0.6, 0.0, -1.2)
		add_child(first_notebook)
		return
	if level_index == 0 and built_floor == 0:
		var first_notebook := SurveyClipboard.new()
		first_notebook.position = spawn_pos + Vector3(0.5, 0.0, 0.8)
		add_child(first_notebook)
		
		var term := TerminalMachine.new()
		term.position = spawn_pos + Vector3(1.5, 0.0, 0.8)
		add_child(term)
	
	_scatter(func(): return SurveyClipboard.new(), CLIPBOARD_PER_CELLS, 2, 6)

## A T.S.R.A. hub rather than a level of the Backrooms: its .lvl has a "hub" block (tools/gen_tsra_hub.py)
func is_hub() -> bool:
	return level_data.get("hub") is Dictionary

## Each floor's own layout of burnt and flickering tubes and stains, the same every time you come back to it
func _floor_seed() -> int:
	return 1971 + Game.level_floor * 7919

var rebuilding := false            # a floor is being built in stages (rebuild_floor_seamless): the lighting waits
var built_floor := 0               # the floor that stands (Game.level_floor is already the next one when a rebuild is asked for)

## Seamless in-place floor transition: unloads the current floor and builds floor `f`, with no loading screen
## or scene reload. `link` is Game.floor_link, how you got there.
##
## By the stairs (props/stairs.gd) it is built a stage a frame while you walk on: the stairwell you are in
## stays as it is, moved a storey with you so it stands where floor f's end of the same well will, until
## that one is built and takes its place. From inside it nothing else can be seen, so nothing gives the swap
## away, not even a dropped frame.
##
## Through a hole in the floor (kind "fall", player.gd) it is built in stages too, out of sight: the look-only
## copy of floor f that you were already seeing down the hole (`shells`) stays up until the real floor is
## whole, and the two change places in one frame. You are a storey higher in the new floor's terms and still
## falling. Any other way (a drop hole, a level change) it is built at once. `fresh`: another level altogether.
func rebuild_floor_seamless(f: int, link: Dictionary = {}, fresh := false) -> void:
	if rebuilding: return
	_stub = false
	_stub_cover = null
	var was := built_floor
	built_floor = f
	Game.level_floor = f
	Game.floor_link = link
	var p: Node3D = player if player != null else Game.player
	var here := p != null and is_instance_valid(p)
	var kind := str(link.get("kind", ""))
	var well: Node3D = null
	if kind == "stairs" and here:
		for s in stairwells:
			if is_instance_valid(s) and s.holds(p.global_position): well = s
	var falling := kind == "fall" and here
	_shell_run += 1                     # whatever look-only floor was being built is for the old stack
	var cover: Node3D = shells.get(f)
	shells.erase(f)
	if cover != null and not falling:
		cover.free()
		cover = null
	_tear_down(was, well, cover, not fresh and f != was and was in _wanted_shells(f))
	# the same level: its file is already in memory, so the swap frame doesn't re-read and re-parse it off the disk
	load_floor(f, {} if fresh else level_raw)
	_place_shells()
	if cover != null: Shell.set_height(cover, 0.0)
	var lift := Vector3(0, float(link.get("lift", 0.0)), 0)
	if falling and cover != null and through_cells(level_raw, f).has(cell_of(p.global_position)):
		# the hole goes on through this floor too: you are only passing it. Its look-only copy stands in for it and
		# nothing of it is built; the floor you come to rest on is (_realize_stub, or the next fall's build)
		p.global_position += lift
		_stub = true
		_stub_cover = cover
		return
	_step_mask = PackedByteArray()      # the nav table: cached by grid size, and every floor has the same size
	step_mask()
	if well != null or cover != null:
		# the same well, or the same shaft, stands on this floor a storey higher or lower: the player goes there with it
		if well != null: well.global_position += lift
		p.global_position += lift
		_build_in_stages(well, cover)
		return
	for stage: Callable in _build_stages(null): stage.call()
	if falling:
		p.global_position += lift       # down a hole before its floor could be shown: built at once, and on you fall
	elif here and kind in ["climb", "descend"]:
		p.global_position += lift       # up or down the stairs between the floors: where you were, in its terms
	elif here:
		p.global_position = spawn_pos
		if has_spawn_yaw:
			p.rotation.y = spawn_yaw
		if p is CharacterBody3D:
			(p as CharacterBody3D).velocity = Vector3.ZERO
	_floor_ready()
	if falling: prime_pool()
	_sync_shells()

var _stub := false                 # the floor that stands is only its look-only copy, passed on a fall through a chain of holes
var _stub_cover: Node3D = null

## The player has left the hole's line in a floor that was only passed: build it now, whole, and show it
func _realize_stub() -> void:
	_stub = false
	if is_instance_valid(_stub_cover): _stub_cover.free()
	_stub_cover = null
	_step_mask = PackedByteArray()
	step_mask()
	for stage: Callable in _build_stages(null): stage.call()
	_floor_ready()
	prime_pool()
	_sync_shells()

## Everything of the old floor (floor `was`) goes, bar the marks, the light pool, the baked GI node and the
## look-only floors (and `keep`, the stairwell the player is standing in, and `cover`, the look-only copy of
## the floor about to be built), and the grid is emptied for the next floor's. `demote`: the old floor is in
## view from the new one, through a hole, so it is not freed: as it stands it becomes one of the look-only floors.
func _tear_down(was: int, keep: Node, cover: Node, demote: bool) -> void:
	if is_instance_valid(_wrap_root): _wrap_root.free()          # (never kept as a look-only floor: only the floor itself)
	_wrap_root = null
	var marks := get_node_or_null("TapeMarks")
	var sketches := get_node_or_null("SketchMarks")
	var pool_set := {}
	for l in pool + pool_b + far_pool + ceil_glow:
		if l != null:
			pool_set[l] = true
			l.visible = false          # they belong to tubes that are about to go
	var stay := {}
	for s in shells.values(): stay[s] = true
	if is_instance_valid(_horizon): stay[_horizon] = true      # the horizon fog is the level's, not a floor's
	var away: Node3D = null
	if demote:
		away = Node3D.new()
		away.process_mode = Node.PROCESS_MODE_DISABLED     # nothing in it runs, and its colliders leave the physics world
		away.set_meta("demoted", true)
		add_child(away)
		stay[away] = true
	var mats: Array = []
	for c in get_children():
		if c == marks or c == sketches or pool_set.has(c) or c == dust or c == keep or c == cover or stay.has(c):
			continue
		# (the fake floor reflections hang under their floor, which from here would be in the room below it)
		if away != null and not (c in stairwells) and c != reflect_mmi and c != pit_fall:
			c.reparent(away, false)
		else:
			_hold(c, mats)
			c.free()
	_held[was] = mats
	for k: int in _held.keys():        # (an endless level has no end of floors to have held)
		if absi(k - built_floor) > 4: _held.erase(k)
	if away != null:
		# its stairwells as a look-only floor has them: the stair itself is the new floor's to build
		for o: Dictionary in objects:
			if is_stairs(o.type): away.add_child(stair_skin(o))
		Shell.dress(away, Shell.layer_of(was))
		Shell.add_lights(away, lit, through.keys() + open_above.keys(), Shell.layer_of(was), PANEL_ENERGY if panels_mm else LIGHT_ENERGY, liminal.duplicate())
		shells[was] = away
		exit_door = null
	stairwells.clear()
	if keep != null: stairwells.append(keep)
	walls.clear()
	pits.clear()
	objects.clear()
	carved.clear()
	stair_cells.clear()
	arch_cells.clear()
	pillar_cells.clear()
	blocked_edges.clear()
	wall_segments.clear()
	for zone: Dictionary in [safe, drain, loot, echo, hall_reverb, muffled, loop, open_ceiling, abyss, endless_ceiling, noclip, noclip_floor, noclip_death, climb_up, climb_down, pool_cells]: zone.clear()
	waters.clear()
	underwater = 0.0
	acoustics = null
	pit_fall = null
	_loops.clear()
	_loop_of.clear()
	tall.clear()
	grand.clear()
	under_slab.clear()
	low.clear()
	crawl.clear()
	tiles.clear()
	hotel.clear()
	hotel_faces.clear()
	bright.clear()
	dark.clear()
	dim.clear()
	flicker.clear()
	mannequin.clear()
	classic.clear()
	liminal.clear()
	_painted.clear()
	ceil_mats.clear()                  # the new ceilings start unlit: update_lighting hands them the fill again
	_ceil_fill = -1.0
	has_spawn_yaw = false
	rng.seed = _floor_seed()
	fx.clear()
	lit.clear()
	_index_fixtures()                  # (empties it: nothing may stutter a torn-down floor's tubes)
	_seen_key = SEEN_NONE
	fill_lights.clear()
	reflect_mmi = null
	tubes_mm = null
	lens_mm = null
	glow_mm = null
	cone_mm = null
	wall_glow_mm = null
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

## What a floor being torn down had loaded, so the floor built in its place finds it all still in memory:
## its materials, floor by floor (they hold their textures, and while one of a kind lives the engine keeps that
## kind's compiled shader), and by file its imported meshes, models and sounds. Without this every texture was
## read off the disk again and every material's shader compiled again, which was nearly all of the second a
## rebuild took.
var _held := {}        # floor -> the materials its last build used
var _kept := {}        # res:// path -> Resource

func _keep(r: Resource, mats: Array) -> void:
	if r == null: return
	if r is Material: mats.append(r)
	elif r.resource_path != "" and not r.resource_path.contains("::"): _kept[r.resource_path] = r

func _hold(n: Node, mats: Array) -> void:
	if n.scene_file_path != "" and not _kept.has(n.scene_file_path):
		_kept[n.scene_file_path] = load(n.scene_file_path)
	if n is GeometryInstance3D:
		var g := n as GeometryInstance3D
		_keep(g.material_override, mats)
		var mesh: Mesh = null
		if g is MeshInstance3D: mesh = (g as MeshInstance3D).mesh
		elif g is MultiMeshInstance3D and (g as MultiMeshInstance3D).multimesh != null: mesh = (g as MultiMeshInstance3D).multimesh.mesh
		if mesh != null:
			_keep(mesh, mats)
			for i in mesh.get_surface_count():
				_keep(mesh.surface_get_material(i), mats)
	elif n is AudioStreamPlayer3D:
		_keep((n as AudioStreamPlayer3D).stream, mats)
	elif n is Light3D:
		_keep((n as Light3D).light_projector, mats)
	for c in n.get_children():
		_hold(c, mats)

## The floor's build, in order. Each stage starts on a frame of its own, and its long loops are cut into slices
## (level_data.gd _slice) when it is built as you walk on. `old_well`: the stairwell kept from the floor before;
## it gives way to its replacement in one frame (level_geometry.gd _swap_wells), so the two are never both drawn
## and never neither.
func _build_stages(old_well: Node) -> Array[Callable]:
	return [
		func() -> void:
			_make_materials()
			await _build_surfaces(true, false),
		func() -> void: await _build_surfaces(false, true),
		_build_walls,
		func() -> void:
			well_to_replace = old_well         # (goes when its replacement stands: _swap_wells)
			await _build_objects()
			await _build_trim(),
		func() -> void:
			_build_ceiling_steps()
			_build_pit_shafts(),
		_build_dirt,
		func() -> void:
			if panel_ceiling != null:
				await _place_panel_fixtures()
				_build_panel_ceiling()
			else:
				await _place_fixtures()
				_build_fixture_meshes()
			await _slice()
			_build_floor_reflections()
			await _build_floor_glow()
			grid_gi = null                 # (the old floor's surfaces, which it was laid over, are gone)
			await _apply_gi(),
		func() -> void:
			_build_exit()
			_spawn_batteries()
			_spawn_tape()
			_spawn_flashes()
			_spawn_survey_props(),
	]

## `cover`: the look-only copy of this floor, in view down the hole the player is falling through. What is
## built is kept out of sight until all of it stands, then the copy goes and the real floor shows, lit.
##
## The build takes a few milliseconds of each frame (BUILD_SLICE_MS, growing by BUILD_RAMP_MS a second it has
## gone on) rather than a whole stage a frame: a big floor's stages ran to a few hundred milliseconds each, every
## one a dropped frame. Whatever is left is built at once (_pace_build) when the floor is about to be seen or
## stood on: you come down to the stairwell's front landing, from which its doorway shows the floor; the floor
## you are falling to is close under you; or BUILD_DEADLINE has passed.
const BUILD_SLICE_MS := 4.0
const BUILD_RAMP_MS := 6.0
const BUILD_DEADLINE := 4.0
const FALL_LANDING_Y := 3.5            # m over the new floor: falling to it, it is all there by then
var _build_t := 0.0                    # s the build has been going
var _build_cover: Node = null

func _build_in_stages(old_well: Node, cover: Node = null) -> void:
	rebuilding = true
	_build_t = 0.0
	_build_cover = cover
	slice_usec = int(BUILD_SLICE_MS * 1000.0)
	var veiled: Array = []
	# (out of sight under the cover as each piece comes, not at the end of its stage: a stage spans frames now)
	var veil := func(c: Node) -> void:
		if c is Node3D and (c as Node3D).visible:
			(c as Node3D).visible = false
			veiled.append(c)
	if cover != null: child_entered_tree.connect(veil)
	for stage: Callable in _build_stages(old_well):
		if slice_usec > 0: await get_tree().process_frame
		_slice_from = Time.get_ticks_usec()
		await stage.call()
	slice_usec = 0
	_build_cover = null
	if cover != null:
		child_entered_tree.disconnect(veil)
		cover.free()
		for c in veiled:
			if is_instance_valid(c): (c as Node3D).visible = true
	rebuilding = false
	_floor_ready()
	if cover != null: prime_pool()
	_sync_shells()

## While a floor is built a slice a frame: the next frames' share of time, or the rest of it at once when it is
## wanted now (_build_in_stages)
func _pace_build(delta: float) -> void:
	if slice_usec <= 0: return
	_build_t += delta
	slice_usec = int((BUILD_SLICE_MS + BUILD_RAMP_MS * _build_t) * 1000.0)
	if _build_t > BUILD_DEADLINE or _floor_wanted_now(): slice_usec = 0

func _floor_wanted_now() -> bool:
	var p: Node3D = player if player != null else Game.player
	if p == null or not is_instance_valid(p): return true
	if _build_cover != null: return p.global_position.y < FALL_LANDING_Y
	for s in stairwells:
		if is_instance_valid(s) and s.holds(p.global_position):
			return s.to_local(p.global_position).x < Stairs.XA + 1.0     # coming onto the landing behind its doorway
	return true                        # out of the well: it is all in view

# ---------------------------------------------------------------- the floors above and below
## The other floors of the level that can be seen from this one, through the holes in the slabs (a pit over an
## open cell of the floor below, level_data.gd `through`): look-only copies (level_shell.gd), each a storey
## higher or lower than the last. A floor you have just left is kept as it stood instead of being copied
## (_tear_down). Levels with no such hole have none of them.
const Shell := preload("res://scripts/World/level/level_shell.gd")
const SHELLS_BELOW := 12           # 108 m: past where the horizon fog has closed (level_lighting.gd HORIZON_END), so the last one is never seen to be the last
const SHELLS_ABOVE := 12

var shells := {}                   # floor -> its look-only copy
const SHELL_SLICE_MS := 4.0        # ms a frame a look-only floor's build may take
var _shell_run := 0                # goes up whenever the stack changes: a build still under way for the old one stops

## The floors to show from floor `f`: down while each floor opens into the next, and up likewise, nearest first
func _wanted_shells(f: int) -> Array[int]:
	var out: Array[int] = []
	var g := f
	while f - g < SHELLS_BELOW and not through_cells(level_raw, g).is_empty():
		g -= 1
		out.append(g)
	g = f
	while g - f < SHELLS_ABOVE and not through_cells(level_raw, g + 1).is_empty():
		g += 1
		out.append(g)
	out.sort_custom(func(a: int, b: int) -> bool: return absi(a - f) < absi(b - f))
	return out

func _place_shells() -> void:
	for k: int in shells:
		Shell.set_height(shells[k], (k - built_floor) * STOREY_H)
		Shell.show_lights(shells[k], absi(k - built_floor))

func _drop_shell(k: int) -> void:
	var s: Node = shells[k]
	shells.erase(k)
	if s.has_meta("demoted"):          # a floor that was walked on: its materials stay loaded, as when any floor goes
		var mats: Array = []
		_hold(s, mats)
		_held[k] = mats
	s.free()

## Free the look-only floors that are out of reach now, and build the missing ones, one a frame
func _sync_shells() -> void:
	_shell_run += 1
	var run := _shell_run
	var want := _wanted_shells(built_floor)
	for k: int in shells.keys():
		if not (k in want): _drop_shell(k)
	_place_shells()
	for k in want:
		if shells.has(k): continue
		var s := Shell.new()
		s.slice_usec = int(SHELL_SLICE_MS * 1000.0)     # (out of sight till whole: no hurry, a few ms a frame)
		for stage: Callable in s.build_stages(level_meta, level_raw, k):
			await get_tree().process_frame
			if run != _shell_run:
				s.free()
				return
			s._slice_from = Time.get_ticks_usec()
			await stage.call()
			if run != _shell_run:
				s.free()
				return
		s.slice_usec = 0
		add_child(s)
		shells[k] = s
		_place_shells()

## The other floors of the level, built whole out of sight one after another as soon as this one stands, then
## freed with their materials, textures, meshes and sounds held (_hold): the first trip up the stairs or down a pit
## finds all of it in memory, as a floor you have been on before does. Stops if the level or the floor changes.
const PREWARM_FLOORS := 6
const PREWARM_SLICE_MS := 3.0

func _prewarm_floors() -> void:
	var ask := _level_ask
	var floors: Array[int] = []
	for k in level_raw.get("floors", {}):
		var f := int(k)
		if f != built_floor and has_floor(level_raw, f): floors.append(f)
	if has_floor(level_raw, 0) and built_floor != 0: floors.append(0)
	floors.sort_custom(func(a: int, b: int) -> bool: return absi(a - built_floor) < absi(b - built_floor))
	for f in floors.slice(0, PREWARM_FLOORS):
		if _held.has(f): continue
		var s := Shell.new()
		s.warm = true
		s.slice_usec = int(PREWARM_SLICE_MS * 1000.0)
		for stage: Callable in s.build_stages(level_meta, level_raw, f):
			await get_tree().process_frame
			while rebuilding: await get_tree().process_frame     # (never while a real floor is being built)
			if ask != _level_ask or not is_inside_tree() or Game.level_floor != built_floor:
				s.free()
				return
			s._slice_from = Time.get_ticks_usec()
			await stage.call()
		var mats: Array = []
		_hold(s, mats)
		_held[f] = mats
		s.free()

func _floor_ready() -> void:
	_find_loops()
	_build_wrap_copies()
	var marks := get_node_or_null("TapeMarks")
	var sketches := get_node_or_null("SketchMarks")
	if marks != null and marks.has_method("reload_floor"):
		marks.reload_floor()
	if sketches != null and sketches.has_method("reload_floor"):
		sketches.reload_floor()
	var cables := get_node_or_null("CableMarks")
	if cables != null and cables.has_method("reload_floor"):
		cables.reload_floor()
	var portals := get_node_or_null("PortalMarks")
	if portals != null and portals.has_method("reload_floor"):
		portals.reload_floor()
	var root := get_parent()
	if root != null:
		var ent: Node = root.get_node_or_null("Entity")
		if ent != null:
			if ent.has_method("_setup_nav"):
				ent._setup_nav()
			if ent.has_method("on_floor_changed"):
				ent.on_floor_changed()
			elif ent.has_method("relocate"):
				ent.relocate()                 # onto this floor's bacteria mark, with its behavior
		# the Mimic's grid (a new level can be another size) and the routes it remembers
		var mm: Node = root.get_node_or_null("Mimic")
		if mm != null and mm.has_method("on_floor_changed"):
			mm.on_floor_changed()

## Seamless in-place level transition: changes to playlist entry `idx` without a loading screen.
## A floor still being built in stages (the stairs, a fall) is let finish first: switching level_meta and dropping
## the shells under it, then being turned away by rebuild_floor_seamless, left that build carrying on with half of
## the old level and half of the new. Only the newest of several asks goes ahead (the host can send two in a row).
var _level_ask := 0

func load_level_seamless(idx: int) -> void:
	_level_ask += 1
	var ask := _level_ask
	while rebuilding:
		await get_tree().process_frame
		if ask != _level_ask or not is_inside_tree():
			return
	var levels := read_index()
	if levels.is_empty():
		return
	Stability.trace("level: switching to level %d in place" % idx)
	Game.level_count = levels.size()
	level_index = clampi(idx, 0, levels.size() - 1)
	level_meta = levels[level_index]
	fired_triggers.clear()
	for k: int in shells.keys(): _drop_shell(k)
	rebuild_floor_seamless(0, {}, true)
	Stability.trace("level: level %d is up" % level_index)

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
			if walls.has(c) or pits.has(c) or loop.has(c) or pool_cells.has(c): continue      # (nothing lying about in a corridor that repeats, or afloat over a pool)
			if absi(c.x - spawn_c.x) + absi(c.y - spawn_c.y) < BATTERY_MIN_SPAWN_DIST: continue
			open.append(c)
			if loot.has(c):                              # a Loot zone: each of its cells counts LOOT_WEIGHT times
				for i in LOOT_WEIGHT - 1: open.append(c)
	if open.is_empty(): return
	var count := clampi(open.size() / per_cells, lo, hi + mini(loot.size() / 6, hi))
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
	if not is_inside_tree():
		return
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
		KEY_HOME:
			_level_cache.clear()
			Game.change_level(Game.level_index)
