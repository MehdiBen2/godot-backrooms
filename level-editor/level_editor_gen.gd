extends "res://level_editor_canvas.gd"
## Level editor, part 2: the generator. Fills a rectangle of the map with backrooms: rooms split off each
## other by walls with doorways (a binary split, so every room is reachable), a maze of corridors, a pillared
## hall, a mix of all three room by room, or the classic Level 0 look (one open expanse broken by short
## walls and columns). Its outer ring stays wall, opened wherever open floor waits
## just outside, so a generated block joins what is already drawn. The seed makes a run repeatable;
## REGENERATE takes the last run back and rolls it again with a new seed. level_editor_files.gd builds on this.

var gen_style := "classic"            # "classic" | "rooms" | "maze" | "pillars" | "mixed"
var gen_seed := 1
var gen_room_min := 4                 # cells: no room thinner than this
var gen_room_max := 11                # cells: rooms wider than this are always split
var gen_density := 0.35               # 0..1: more doorways, loops and pillars as it rises
var gen_corridor := 1                 # maze corridor width in cells
var gen_doors := true                 # a door in some of the 1-cell doorways between rooms
var gen_zones := true                 # give some rooms a zone (tiles, dim, dark, tall, ...)
var last_gen := {}                    # {area, undo}: the last run, for REGENERATE

var _rng := RandomNumberGenerator.new()
var _gopen := {}                       # Vector2i -> true: the cells the run leaves open
var _rooms: Array = []                # Rect2i of each room, for zones
var _gaps: Array = []                 # 1-cell doorways between rooms, for doors

const ZONE_PICKS := ["tiles", "tiles", "dim", "dim", "dark", "flicker", "flicker", "grime", "tall", "bright", "low"]

func _generate(area: Rect2i) -> void:
	area = area.intersection(Rect2i(0, 0, grid_size, grid_size))
	if area.size.x < 5 or area.size.y < 5:
		_status("The generator needs an area of at least 5 x 5 cells")
		return
	_rng.seed = gen_seed
	_gopen.clear()
	_rooms.clear()
	_gaps.clear()
	var inner := area.grow(-1)
	match gen_style:
		"classic": _classic_field(inner)
		"rooms": _bsp(inner, "room")
		"maze": _maze(inner)
		"pillars":
			_pillars(inner)
			_rooms.append(inner)
		_: _bsp(inner, "mixed")
	var joined := _connect_outside(area)
	# stairs in the area stay, with their cell and the cell you step off onto
	var stairs: Array = []
	for o: Dictionary in objects:
		var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
		if str(o.type).begins_with("stairs_") and area.has_point(c):
			stairs.append(o)
			_gopen[c] = true
			_gopen[c - Vector2i(Vector2.from_angle(deg_to_rad(o.rotation)).round())] = true
	for z in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var c := Vector2i(x, z)
			var open := _gopen.has(c) and x >= 1 and z >= 1 and x < grid_size - 1 and z < grid_size - 1
			grid[z][x] = FLOOR if open else WALL
			if gen_zones or not open:
				for zn in zones: zones[zn].erase(c)
			if open: paint["wall"].erase(c)
			else:
				paint["floor"].erase(c)
				paint["ceiling"].erase(c)
	for o: Dictionary in stairs:
		if o.type == "stairs_down": grid[roundi(o.pos_y)][roundi(o.pos_x)] = PIT
	objects = objects.filter(func(o): return str(o.type).begins_with("stairs_") or not area.has_point(Vector2i(roundi(o.pos_x), roundi(o.pos_y))))
	for m in markers:
		var mc = markers[m]
		if mc != null and area.has_point(mc) and grid[mc.y][mc.x] == WALL: markers[m] = _nearest_open_in(mc)
	if gen_doors and gen_style != "maze": _place_doors()
	if gen_zones: _room_zones()
	selected = -1
	_sync_inspector()
	_mark_dirty()
	last_gen = {"area": area, "undo": undo_stack.size()}
	var note := "" if joined else "   (nothing open next to it: carve a doorway to join it up)"
	_status("Generated %s %d x %d, seed %d. REGENERATE rolls it again%s" % [gen_style, area.size.x, area.size.y, gen_seed, note])

## Roll the last generated area again with a new seed, replacing the last run if nothing was done since
func _regenerate() -> void:
	if last_gen.is_empty():
		_status("Generate an area first (the Generate tool: drag a rectangle), or use WHOLE LEVEL")
		return
	if undo_stack.size() == last_gen.undo and not undo_stack.is_empty():
		_restore(undo_stack.pop_back())
	gen_seed = randi() % 100000
	_gen_ui_sync()
	_push_undo()
	_generate(last_gen.area)

func _generate_whole() -> void:
	_push_undo()
	_generate(Rect2i(0, 0, grid_size, grid_size))

## level_editor.gd: show the seed after it changed
func _gen_ui_sync() -> void:
	pass

func _nearest_open_in(c: Vector2i) -> Variant:
	var best = null
	var bd := 1 << 30
	for o: Vector2i in _gopen:
		var d := absi(o.x - c.x) + absi(o.y - c.y)
		if d < bd and grid[o.y][o.x] != WALL:
			bd = d
			best = o
	return best

# ---------------------------------------------------------------- rooms (binary split)
func _bsp(r: Rect2i, style: String) -> void:
	var w := r.size.x
	var h := r.size.y
	var can_x := w >= gen_room_min * 2 + 1
	var can_y := h >= gen_room_min * 2 + 1
	var must := w > gen_room_max or h > gen_room_max
	if (can_x or can_y) and (must or _rng.randf() < 0.2):
		var split_x := can_x and (not can_y or w > h or (w == h and _rng.randf() < 0.5))
		if split_x:
			var s := _rng.randi_range(r.position.x + gen_room_min, r.end.x - gen_room_min - 1)
			_bsp(Rect2i(r.position.x, r.position.y, s - r.position.x, h), style)
			_bsp(Rect2i(s + 1, r.position.y, r.end.x - s - 1, h), style)
			_join_line(Vector2i(s, r.position.y), Vector2i(0, 1), h, Vector2i(1, 0))
		else:
			var s := _rng.randi_range(r.position.y + gen_room_min, r.end.y - gen_room_min - 1)
			_bsp(Rect2i(r.position.x, r.position.y, w, s - r.position.y), style)
			_bsp(Rect2i(r.position.x, s + 1, w, r.end.y - s - 1), style)
			_join_line(Vector2i(r.position.x, s), Vector2i(1, 0), w, Vector2i(0, 1))
		return
	_leaf(r, style)

## One room of the split. Mixed: most are plain rooms, some pillared halls, some little mazes.
func _leaf(r: Rect2i, style: String) -> void:
	var kind := "room"
	if style == "mixed":
		var roll := _rng.randf()
		if roll < 0.2 and r.size.x >= 6 and r.size.y >= 6: kind = "pillars"
		elif roll < 0.42 and r.size.x >= 7 and r.size.y >= 7: kind = "maze"
	match kind:
		"maze": _maze(r)
		"pillars":
			_pillars(r)
			_rooms.append(r)
		_:
			_carve(r)
			_rooms.append(r)

## Classic Level 0: one open carpeted expanse, not rooms. Short free-standing walls, L bends, three-sided
## half rooms, lone columns and colonnades, and stubs jutting off the outer wall are dropped at random.
## Each piece keeps a clear cell all round from every other piece and touches the outer wall at most
## once (a stub's root), so walls never join up into a loop and every open cell stays reachable.
func _classic_field(r: Rect2i) -> void:
	_carve(r)
	var wall := {}
	var tries := int(r.get_area() * (0.025 + gen_density * 0.05))
	for t in tries:
		var stub := _rng.randf() < 0.15
		var cells: Array = _classic_stub(r) if stub else _classic_piece(r)
		if cells.is_empty() or not _piece_fits(cells, r, wall, stub): continue
		for c: Vector2i in cells:
			wall[c] = true
			_gopen.erase(c)
	for k in maxi(1, r.get_area() / 260):             # a few patches for zones, the rest plain
		var w := _rng.randi_range(4, mini(10, r.size.x))
		var h := _rng.randi_range(4, mini(10, r.size.y))
		_rooms.append(Rect2i(_rng.randi_range(r.position.x, r.end.x - w), _rng.randi_range(r.position.y, r.end.y - h), w, h))

func _classic_piece(r: Rect2i) -> Array:
	var o := Vector2i(_rng.randi_range(r.position.x, r.end.x - 1), _rng.randi_range(r.position.y, r.end.y - 1))
	var hdir := Vector2i(1, 0) if _rng.randf() < 0.5 else Vector2i(0, 1)
	var cells: Array = []
	var roll := _rng.randf()
	if roll < 0.3:                                                   # a short free-standing wall
		for i in _rng.randi_range(2, 6): cells.append(o + hdir * i)
	elif roll < 0.5:                                                 # an L bend
		var b := Vector2i(hdir.y, hdir.x) * (1 if _rng.randf() < 0.5 else -1)
		var a := _rng.randi_range(2, 5)
		for i in a: cells.append(o + hdir * i)
		for i in range(1, _rng.randi_range(2, 5)): cells.append(o + hdir * (a - 1) + b * i)
	elif roll < 0.62:                                                # a half room: three sides, one open
		var w := _rng.randi_range(4, 7)
		var h := _rng.randi_range(4, 7)
		var open_side := _rng.randi_range(0, 3)
		for x in w:
			if open_side != 0: cells.append(o + Vector2i(x, 0))
			if open_side != 1: cells.append(o + Vector2i(x, h - 1))
		for z in range(1, h - 1):
			if open_side != 2: cells.append(o + Vector2i(0, z))
			if open_side != 3: cells.append(o + Vector2i(w - 1, z))
		if cells.size() > 6 and _rng.randf() < 0.5: cells.remove_at(_rng.randi_range(0, cells.size() - 1))   # a gap
	elif roll < 0.82:                                                # a lone column, now and then a fat one
		cells.append(o)
		if _rng.randf() < 0.25: cells.append_array([o + Vector2i(1, 0), o + Vector2i(0, 1), o + Vector2i(1, 1)])
	else:                                                            # a colonnade
		for i in _rng.randi_range(3, 6): cells.append(o + hdir * (i * 3))
	return cells

## A wall jutting in off the area's edge; its first cell is the one against the edge
func _classic_stub(r: Rect2i) -> Array:
	var side := _rng.randi_range(0, 3)
	var start: Vector2i
	var dir: Vector2i
	match side:
		0:
			start = Vector2i(_rng.randi_range(r.position.x + 2, r.end.x - 3), r.position.y)
			dir = Vector2i(0, 1)
		1:
			start = Vector2i(_rng.randi_range(r.position.x + 2, r.end.x - 3), r.end.y - 1)
			dir = Vector2i(0, -1)
		2:
			start = Vector2i(r.position.x, _rng.randi_range(r.position.y + 2, r.end.y - 3))
			dir = Vector2i(1, 0)
		_:
			start = Vector2i(r.end.x - 1, _rng.randi_range(r.position.y + 2, r.end.y - 3))
			dir = Vector2i(-1, 0)
	var cells: Array = []
	for i in _rng.randi_range(2, 5): cells.append(start + dir * i)
	return cells

## Inside the area, a clear cell all round from other pieces, and off the edge (bar a stub's root)
func _piece_fits(cells: Array, r: Rect2i, wall: Dictionary, stub: bool) -> bool:
	var own := {}
	for c: Vector2i in cells:
		if not r.has_point(c): return false
		own[c] = true
	for i in cells.size():
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var n: Vector2i = cells[i] + Vector2i(dx, dz)
				if own.has(n): continue
				if wall.has(n): return false
				if not r.has_point(n) and not (stub and i == 0): return false
	return true

func _carve(r: Rect2i) -> void:
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_gopen[Vector2i(x, z)] = true

## Doorways through the wall line between two halves of a split: at least one, more as density rises, now
## and then the whole line knocked out into one big hall. A spot needs open floor on both sides; if the
## halves never meet the line (a maze with walls there), a short tunnel is dug through.
func _join_line(start: Vector2i, along: Vector2i, length: int, across: Vector2i) -> void:
	var cand: Array = []
	for i in length:
		var c := start + along * i
		if _gopen.has(c - across) and _gopen.has(c + across): cand.append(c)
	if not cand.is_empty() and gen_density > 0.6 and _rng.randf() < (gen_density - 0.6) * 1.2:
		for c: Vector2i in cand: _gopen[c] = true
		return
	if cand.is_empty():
		var c := start + along * _rng.randi_range(0, length - 1)
		for k in range(-2, 3): _gopen[c + across * k] = true
		return
	var count := 1 + (1 if _rng.randf() < gen_density else 0) + (1 if _rng.randf() < gen_density * gen_density else 0)
	for k in count:
		var c: Vector2i = cand[_rng.randi_range(0, cand.size() - 1)]
		_gopen[c] = true
		var wide := c + along
		if _rng.randf() < 0.35 and cand.has(wide): _gopen[wide] = true
		elif k == 0: _gaps.append(c)

# ---------------------------------------------------------------- maze
## A corridor maze on a lattice of gen_corridor-wide passages (recursive backtracker), braided by density
## so it has loops rather than only dead ends
func _maze(r: Rect2i) -> void:
	var cw := clampi(gen_corridor, 1, 3)
	var step := cw + 1
	var nx := (r.size.x + 1) / step
	var nz := (r.size.y + 1) / step
	if nx < 2 or nz < 2:
		_carve(r)
		return
	var node := func(i: int, j: int) -> Vector2i: return r.position + Vector2i(i * step, j * step)
	var carve_block := func(p: Vector2i, sx: int, sz: int) -> void:
		for dz in sz:
			for dx in sx: _gopen[p + Vector2i(dx, dz)] = true
	var seen := {}
	var stack: Array = [Vector2i(_rng.randi_range(0, nx - 1), _rng.randi_range(0, nz - 1))]
	seen[stack[0]] = true
	carve_block.call(node.call(stack[0].x, stack[0].y), cw, cw)
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var link := func(a: Vector2i, b: Vector2i) -> void:
		var pa: Vector2i = node.call(a.x, a.y)
		var pb: Vector2i = node.call(b.x, b.y)
		var lo := pa.min(pb)
		carve_block.call(lo, cw + (step if a.x != b.x else 0), cw + (step if a.y != b.y else 0))
	while not stack.is_empty():
		var cur: Vector2i = stack[-1]
		var next: Array = []
		for d: Vector2i in dirs:
			var n: Vector2i = cur + d
			if n.x >= 0 and n.y >= 0 and n.x < nx and n.y < nz and not seen.has(n): next.append(n)
		if next.is_empty():
			# a dead end: with density, knock through to a neighbour anyway (a loop)
			if _rng.randf() < gen_density * 0.6:
				var d: Vector2i = dirs[_rng.randi_range(0, 3)]
				var n: Vector2i = cur + d
				if n.x >= 0 and n.y >= 0 and n.x < nx and n.y < nz: link.call(cur, n)
			stack.pop_back()
			continue
		var n: Vector2i = next[_rng.randi_range(0, next.size() - 1)]
		seen[n] = true
		link.call(cur, n)
		stack.append(n)

# ---------------------------------------------------------------- pillared hall
func _pillars(r: Rect2i) -> void:
	_carve(r)
	var step := clampi(gen_room_min / 2 + 1, 2, 5)
	var chance := 0.3 + gen_density * 0.6
	for z in range(r.position.y + 1, r.end.y - 1, step):
		for x in range(r.position.x + 1, r.end.x - 1, step):
			if _rng.randf() > chance: continue
			_gopen.erase(Vector2i(x, z))
			if step >= 4 and _rng.randf() < 0.3 and x + 1 < r.end.x - 1 and z + 1 < r.end.y - 1:
				for c in [Vector2i(x + 1, z), Vector2i(x, z + 1), Vector2i(x + 1, z + 1)]: _gopen.erase(c)

# ---------------------------------------------------------------- joining up, doors, zones
## Open the area's outer ring wherever open floor waits right outside it: one or two doorways a side.
## Returns whether it joined anything.
func _connect_outside(area: Rect2i) -> bool:
	var joined := false
	var sides := [[Vector2i(area.position.x, area.position.y), Vector2i(1, 0), area.size.x, Vector2i(0, -1)],
		[Vector2i(area.position.x, area.end.y - 1), Vector2i(1, 0), area.size.x, Vector2i(0, 1)],
		[Vector2i(area.position.x, area.position.y), Vector2i(0, 1), area.size.y, Vector2i(-1, 0)],
		[Vector2i(area.end.x - 1, area.position.y), Vector2i(0, 1), area.size.y, Vector2i(1, 0)]]
	for sd in sides:
		var cand: Array = []
		for i in range(1, sd[2] - 1):
			var c: Vector2i = sd[0] + sd[1] * i
			var out: Vector2i = c + sd[3]
			if _in_grid(out) and grid[out.y][out.x] != WALL and _gopen.has(c - sd[3]): cand.append(c)
		if cand.is_empty(): continue
		joined = true
		for k in (2 if cand.size() > 6 and _rng.randf() < 0.5 else 1):
			var c: Vector2i = cand[_rng.randi_range(0, cand.size() - 1)]
			_gopen[c] = true
			if cand.has(c + sd[1]) and _rng.randf() < 0.5: _gopen[c + sd[1]] = true
	return joined

## Doors in some of the 1-cell doorways between rooms, turned to face through them
func _place_doors() -> void:
	for c: Vector2i in _gaps:
		if _rng.randf() > 0.55 or grid[c.y][c.x] != FLOOR: continue
		var ew := _open_at(c + Vector2i(1, 0)) and _open_at(c + Vector2i(-1, 0))
		var ns := _open_at(c + Vector2i(0, 1)) and _open_at(c + Vector2i(0, -1))
		if ew == ns: continue
		objects.append({"type": "door", "pos_x": float(c.x), "pos_y": float(c.y), "rotation": 0.0 if ew else 90.0, "scale": 1.0})
		grid[c.y][c.x] = WALL          # a door stands in a wall cell (its on_cell), like one placed by hand

func _open_at(c: Vector2i) -> bool:
	return _in_grid(c) and grid[c.y][c.x] != WALL

## Some rooms get a zone, so a generated block isn't one look throughout
func _room_zones() -> void:
	for r: Rect2i in _rooms:
		if _rng.randf() > 0.4: continue
		var zn: String = ZONE_PICKS[_rng.randi_range(0, ZONE_PICKS.size() - 1)]
		if zn == "low" and r.get_area() > 30: zn = "dim"
		if not zones.has(zn): continue
		for z in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				if grid[z][x] == FLOOR: zones[zn][Vector2i(x, z)] = true
