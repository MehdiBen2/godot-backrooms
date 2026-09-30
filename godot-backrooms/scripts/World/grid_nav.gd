extends RefCounted
## Grid helpers over the level's wall / pit maps: line of sight, breadth-first flow fields and
## push-out collision for entities. World x/z <-> cell = round(v / CELL), same as the web game.
## Thin walls and doors placed off-centre in the editor don't fill a cell: they cut the links between the
## cells either side (level_data.gd blocked_edges / wall_segments), which every step here respects.

const CELL := 4.5
const NEIGHBOURS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var level: Node
var n := 0
var _queue := PackedInt32Array()     # reused by bfs(): no n*n allocation per call

func _init(l: Node) -> void:
	level = l
	n = l.size

static func cell(v: float) -> int:
	return roundi(v / CELL)

func is_wall(cx: int, cz: int) -> bool:
	return level.walls.has(Vector2i(cx, cz))

func blocked(cx: int, cz: int) -> bool:
	var c := Vector2i(cx, cz)
	return level.walls.has(c) or level.pits.has(c)

func open_at(x: float, z: float) -> bool:
	return not blocked(cell(x), cell(z))

## One step from a cell to a neighbouring one: the target is open and no off-centre wall is in between
func can_step(ax: int, az: int, bx: int, bz: int) -> bool:
	return not blocked(bx, bz) and not level.edge_blocked(Vector2i(ax, az), Vector2i(bx, bz))

# Line of sight across the grid (walls block, pits don't)
func clear_line(ax: float, az: float, bx: float, bz: float, step := 0.25) -> bool:
	var dx := bx - ax
	var dz := bz - az
	var steps := ceili(sqrt(dx * dx + dz * dz) / step)
	for i in range(1, steps):
		var t := float(i) / steps
		if level.walls.has(Vector2i(cell(ax + dx * t), cell(az + dz * t))):
			return false
	return not level.crosses_wall_segment(Vector2(ax, az) / CELL, Vector2(bx, bz) / CELL)

# Path distance from (sx, sz) to every cell; -1 = unreachable. `out` is n*n, index x * n + z.
func bfs(sx: int, sz: int, out: PackedInt32Array) -> bool:
	out.fill(-1)
	if sx < 0 or sz < 0 or sx >= n or sz >= n or blocked(sx, sz):
		return false
	# the level's precomputed step mask (level_data.gd step_mask()) stands in for can_step(): bits
	# 1/2/4/8 = +x/-x/+z/-z, so each neighbour is one byte test and an index offset
	var mask: PackedByteArray = level.step_mask()
	if _queue.size() != n * n:
		_queue.resize(n * n)
	var queue := _queue
	var head := 0
	var tail := 0
	out[sx * n + sz] = 0
	queue[tail] = sx * n + sz
	tail += 1
	while head < tail:
		var idx := queue[head]
		head += 1
		var m := mask[idx]
		if m == 0:
			continue
		var d := out[idx] + 1
		if m & 1 and out[idx + n] == -1:
			out[idx + n] = d
			queue[tail] = idx + n
			tail += 1
		if m & 2 and out[idx - n] == -1:
			out[idx - n] = d
			queue[tail] = idx - n
			tail += 1
		if m & 4 and out[idx + 1] == -1:
			out[idx + 1] = d
			queue[tail] = idx + 1
			tail += 1
		if m & 8 and out[idx - 1] == -1:
			out[idx - 1] = d
			queue[tail] = idx - 1
			tail += 1
	return true

# Push a circle (x/z of `p`) out of every wall cell it overlaps
func resolve(p: Vector3, radius: float) -> Vector3:
	var cx := cell(p.x)
	var cz := cell(p.z)
	var half := CELL / 2.0
	for ox in range(-1, 2):
		for oz in range(-1, 2):
			var c := Vector2i(cx + ox, cz + oz)
			if not level.walls.has(c):
				continue
			var minx := c.x * CELL - half
			var maxx := c.x * CELL + half
			var minz := c.y * CELL - half
			var maxz := c.y * CELL + half
			var qx := clampf(p.x, minx, maxx)
			var qz := clampf(p.z, minz, maxz)
			var dx := p.x - qx
			var dz := p.z - qz
			var dsq := dx * dx + dz * dz
			if dsq >= radius * radius:
				continue
			if dsq > 0.000001:
				var d := sqrt(dsq)
				p.x = qx + dx / d * radius
				p.z = qz + dz / d * radius
			else:
				# centre inside the wall: leave through the nearest face
				var l := p.x - minx
				var r := maxx - p.x
				var u := p.z - minz
				var dn := maxz - p.z
				var m := minf(minf(l, r), minf(u, dn))
				if m == l: p.x = minx - radius
				elif m == r: p.x = maxx + radius
				elif m == u: p.z = minz - radius
				else: p.z = maxz + radius
	# off-centre thin walls / doors: keep the circle a radius clear of each span (plus its thickness);
	# a pillar is a span of zero length, so it pushes out round a circle
	for s: Array in level.wall_segments:
		var here := Vector2(p.x, p.z)
		var q := Geometry2D.get_closest_point_to_segment(here, s[0] * CELL, s[1] * CELL)
		var clear: float = radius + s[2]
		var off := here - q
		if off.length_squared() >= clear * clear:
			continue
		if off.length_squared() < 0.000001:              # dead on the line: out the side it faces
			var along: Vector2 = s[1] - s[0]
			off = along.orthogonal() if along != Vector2.ZERO else Vector2.RIGHT
		var out := q + off.normalized() * clear
		p.x = out.x
		p.z = out.y
	return p
