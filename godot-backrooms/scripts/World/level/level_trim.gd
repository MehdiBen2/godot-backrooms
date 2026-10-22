extends "res://scripts/World/level/level_geometry.gd"
## THE LEVEL, layer 2b: what an office's walls wear once it has been lived in. All built once from the grid
## and the placed walls when the floor loads (_build_trim, after the walls and objects):
##   - skirting: a vinyl cove base along the foot of every wall, pillar and thin wall (the dark rubber strip
##     every commercial building has), mitred round the corners;
##   - a drop ceiling's wall angle: the steel strip its cut edge tiles rest on, along the top of every wall;
##   - outlets and light switches: a socket low on the odd wall, a switch beside the odd way through;
##   - wear: rubber scuffs and kick marks low on the walls, grey hand marks round the switches and on the
##     corners people round;
##   - grime and damp: a film over the paper, grime along the foot, water down from the ceiling, by how dirty and
##     how damp each area is (wall_grime_at: the floor's own noise and the editor's Clean / Dirty / Moist zones).

# ---------------------------------------------------------------- the wall faces
## One per side of an open cell that a solid wall block stands against: {c: the open cell, n: towards the wall,
## t: along the face, ends: [at -t, at +t]}, an end being how the wall carries on there: END_ON (straight on),
## END_IN (into a corner, the next wall coming at you), END_OUT (round an outside corner: the wall ends, a way
## through or a room beyond).
const END_ON := 0
const END_IN := 1
const END_OUT := 2
var _faces: Array = []

## Wall to the trim: a wall block, or the box of a stairwell (skirted and finished like the walls it stands in)
func _trim_wall(c: Vector2i) -> bool:
	return _block_at(c) or stair_cells.has(c)

func _wall_faces() -> Array:
	var out: Array = []
	var doorways := {}                    # [open cell, way to the wall] -> the stairwell whose doorway is in that face
	for o: Dictionary in objects:
		if is_stairs(str(o.type)):
			var dir := stair_dir(o)
			doorways[[Vector2i(roundi(o.pos_x), roundi(o.pos_y)) - dir, dir]] = o
	for x in range(1, size - 1):
		await _slice()
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			if _trim_wall(c) or pits.has(c) or arch_cells.has(c): continue
			if not crop.is_empty() and not crop.has(c): continue
			if edge_wrap and wrap_ring.has(c): continue
			for n: Vector2i in DIRS:
				if not _trim_wall(c + n): continue
				if edge_wrap and wrap_ring.has(c + n): continue          # (the copy beyond the seam draws that one)
				var t := Vector2i(-n.y, n.x)
				var ends := []
				for s: Vector2i in [-t, t]:
					if _trim_wall(c + s): ends.append(END_IN)
					elif _trim_wall(c + s + n): ends.append(END_ON)
					else: ends.append(END_OUT)
				var face := {"c": c, "n": n, "t": t, "ends": ends}
				if doorways.has([c, n]):
					# the doorway's edges along this face (m from its middle): the skirting stops short of them
					var xf := _stair_xf(doorways[[c, n]])
					var mid := Vector3((c.x + n.x * 0.5) * CELL, 0.0, (c.y + n.y * 0.5) * CELL)
					var along := Vector3(t.x, 0.0, t.y)
					var d0 := (xf * Vector3(-CELL * 0.5, 0.0, 1.3) - mid).dot(along)
					var d1 := (xf * Vector3(-CELL * 0.5, 0.0, 3.5) - mid).dot(along)
					face["door"] = [minf(d0, d1), maxf(d0, d1)]
				out.append(face)
	return out

## Where face `f` is: the middle of it on the floor (world), its normal out into the room, and along it
func _face_frame(f: Dictionary) -> Array:
	var c: Vector2i = f.c
	var n: Vector2i = f.n
	var t: Vector2i = f.t
	var at := Vector3((c.x + n.x * 0.5) * CELL, 0.0, (c.y + n.y * 0.5) * CELL)
	return [at, Vector3(-n.x, 0.0, -n.y), Vector3(t.x, 0.0, t.y)]

## The placed walls, pillars and columns (level_data.gd `objects`) as floor-plan outlines (world): the faces
## above only know the grid, so a thin wall butting onto a grid wall is invisible to them, and a switch or a
## stain put there would sit half inside it. [outline, solid] (solid: the outline's inside is wall too; a round
## room's two rings are not, the room is inside them).
var _obstacles: Array = []
## The same outlines filed by grid cell (each under every cell its box, grown by OBSTACLE_REACH, overlaps), so a
## query looks at the few near it, not at every object on the floor: the trim asks thousands of them a floor
const OBSTACLE_REACH := 0.5          # m: the widest margin _clear_of_objects is ever asked for
var _obstacle_grid := {}             # Vector2i -> Array of _obstacles entries

func _gather_obstacles() -> void:
	_obstacles.clear()
	_obstacle_grid.clear()
	var plans: Array = []                 # [world outline, solid]
	for o: Dictionary in objects:
		var outlines := _object_outlines(o)
		var xf := object_transform(o)
		for outline: Array in outlines:
			var poly := PackedVector2Array()
			for p: Vector2 in outline[0]:
				var w := xf * Vector3(p.x, 0.0, p.y)
				poly.append(Vector2(w.x, w.z))
			plans.append([poly, outlines.size() == 1])
	# the wall graph's walls and hubs (level_geometry.gd wall_plan), each a solid plan of its own
	for s: Dictionary in wall_plan.get("solids", []):
		if float(s.base) < 0.05: plans.append([s.poly, true])
	for ob: Array in plans:
		var poly: PackedVector2Array = ob[0]
		if poly.is_empty(): continue
		_obstacles.append(ob)
		var box := Rect2(poly[0], Vector2.ZERO)
		for v in poly: box = box.expand(v)
		box = box.grow(OBSTACLE_REACH)
		for gx in range(floori(box.position.x / CELL), floori(box.end.x / CELL) + 1):
			for gz in range(floori(box.position.y / CELL), floori(box.end.y / CELL) + 1):
				var k := Vector2i(gx, gz)
				if not _obstacle_grid.has(k): _obstacle_grid[k] = []
				(_obstacle_grid[k] as Array).append(ob)

## True when floor-plan point `p` (world) is at least `margin` metres (at most OBSTACLE_REACH) clear of every
## placed wall, pillar and column
func _clear_of_objects(p: Vector3, margin: float) -> bool:
	var q := Vector2(p.x, p.z)
	var here = _obstacle_grid.get(Vector2i(floori(q.x / CELL), floori(q.y / CELL)))     # (a .get(k, []) makes an Array every miss)
	if here == null: return true
	for ob: Array in here:
		var poly: PackedVector2Array = ob[0]
		if ob[1] and Geometry2D.is_point_in_polygon(q, poly): return false
		for i in poly.size():
			if Geometry2D.get_closest_point_to_segment(q, poly[i], poly[(i + 1) % poly.size()]).distance_to(q) < margin:
				return false
	return true

## A basis standing on the wall: +Z out of it into the room, +Y up, +X along it
static func _on_wall(out: Vector3) -> Basis:
	return Basis(Vector3.UP.cross(out), Vector3.UP, out)

func _build_trim() -> void:
	_faces = await _wall_faces()
	_gather_obstacles()
	_wall_grime_field()
	await _build_skirting()
	await _slice()
	_build_wall_angle()
	await _slice()
	var switches := _build_fittings()
	await _slice()
	_build_wall_wear(switches)
	await _slice()
	_build_damp()
	await _slice()
	_build_wall_grime()

# ---------------------------------------------------------------- skirting
# A vinyl cove base, in cross-section from its top edge against the wall down to its toe on the carpet
# (x: out from the wall, y: up; metres): 10 cm tall, a few millimetres thick, a rounded top edge, and the cove
# that curls out at the foot so a mop can't catch it.
const SKIRT := [Vector2(0.0, 0.102), Vector2(0.0015, 0.1019), Vector2(0.0033, 0.1011), Vector2(0.0047, 0.0997),
	Vector2(0.0054, 0.0978), Vector2(0.0056, 0.0955), Vector2(0.0052, 0.0935), Vector2(0.0046, 0.0918),
	Vector2(0.0050, 0.0902), Vector2(0.0062, 0.0890), Vector2(0.0080, 0.0882), Vector2(0.0098, 0.0872),
	Vector2(0.0108, 0.0850), Vector2(0.0112, 0.0820), Vector2(0.0112, 0.022), Vector2(0.0116, 0.0135),
	Vector2(0.0124, 0.0075), Vector2(0.0134, 0.0030), Vector2(0.0146, 0.0)]
var _skirt_normals: Array[Vector2] = []
const MITRE := [0.0, -1.0, 1.0]     # by end (END_ON, END_IN, END_OUT): how far along the wall a vertex at depth d moves, times d

## A cross-section's vertex normals: square to the profile, on the left of the way it runs (SKIRT runs top to
## toe: out of the wall and up)
static func _profile_normals(prof: Array) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in prof.size():
		var a: Vector2 = prof[maxi(i - 1, 0)]
		var b: Vector2 = prof[mini(i + 1, prof.size() - 1)]
		var d := (b - a).normalized()
		out.append(Vector2(-d.y, d.x))
	return out

func _build_skirting() -> void:
	# tiled walls run down to the floor: a rubber cove base on glazed tile is wrong
	if _has_pbr("wall") and _mat_id("wall").to_lower().contains("tile"): return
	_skirt_normals = _profile_normals(SKIRT)
	# one mesh per chunk (_chunk_st): every wall face of the level in one mesh was drawn whole whenever any of it showed
	var sts := {}
	# the maze's walls, a face at a time: its ends cut square where the wall runs straight on, mitred into an
	# inside corner, and mitred round an outside one (the vertex at depth d moves d along the wall)
	var n_done := 0
	for f: Dictionary in _faces:
		n_done += 1
		if n_done % 32 == 0: await _slice()
		var fr := _face_frame(f)
		var mid: Vector3 = fr[0]
		var out: Vector3 = fr[1]
		var along: Vector3 = fr[2]
		var a := mid - along * (CELL * 0.5)
		var b := mid + along * (CELL * 0.5)
		var sa: float = MITRE[f.ends[0]]
		var sb: float = MITRE[f.ends[1]]
		if f.has("door"):                 # a stairwell's doorway: a run each side of it, butting up to its casing
			var lo: float = f.door[0] - SKIRT_STOP
			var hi: float = f.door[1] + SKIRT_STOP
			if lo > -CELL * 0.5 + 0.05: _skirt_run(_chunk_st(sts, mid), [a, mid + along * lo], [out - along * sa, out], [out, out], [out, out], false)
			if hi < CELL * 0.5 - 0.05: _skirt_run(_chunk_st(sts, mid), [mid + along * hi, b], [out, out + along * sb], [out, out], [out, out], false)
			continue
		_skirt_run(_chunk_st(sts, mid), [a, b], [out - along * sa, out + along * sb], [out, out], [out, out], false)
	# placed walls, pillars and columns: round the outline of each
	for o: Dictionary in objects:
		var xf := object_transform(o)
		for outline: Array in _object_outlines(o):
			_skirt_loop(_chunk_st(sts, xf.origin), outline[0], xf, outline[1])
	# the wall graph: right round the outline of its walls' feet, unbroken round every corner, curve and junction
	# (level_geometry.gd wall_plan; a hole in the outline, a room the walls close in, is skirted from inside)
	for loop: Dictionary in wall_plan.get("loops", []):
		var pts: Array = Array(loop.pts)
		if pts.size() < 2: continue
		var at: Vector2 = pts[0]
		var runs := _skirted_runs(pts, loop.closed)
		if runs.is_empty(): continue
		if runs[0].is_empty():                   # (no bare wall on it: the whole loop, as it was)
			if loop.closed:
				if pts.size() >= 3: _skirt_loop(_chunk_st(sts, Vector3(at.x, 0.0, at.y)), pts, Transform3D.IDENTITY, loop.inward)
			else:
				_skirt_open(_chunk_st(sts, Vector3(at.x, 0.0, at.y)), pts)
			continue
		for run: Array in runs:
			at = run[0]
			_skirt_open(_chunk_st(sts, Vector3(at.x, 0.0, at.y)), run)
	if sts.is_empty(): return
	var mat := _skirt_material()
	_commit_chunks(sts, func(mi: MeshInstance3D) -> void:
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)      # (a centimetre proud of the wall)

## One strip of skirting along `pts` (world, on the floor at the wall's face). `miter[i]`: where a vertex at
## depth d sits, as pts[i] + miter[i] * d. `face_in[i]` / `face_out[i]`: the wall's outward normal at pts[i] for
## the run arriving there / leaving it (the same on a curve, the two faces' own at a corner: no smeared shading).
## `prof` / `nrms`: the cross-section swept (the skirting's, or the ceiling's wall angle: ANGLE / _angle_normals).
func _skirt_run(st: SurfaceTool, pts: Array, miter: Array, face_in: Array, face_out: Array, closed: bool,
		prof: Array = SKIRT, nrms: Array = []) -> void:
	if nrms.is_empty(): nrms = _skirt_normals
	var n := pts.size()
	var segs := n if closed else n - 1
	for i in segs:
		var j := (i + 1) % n
		var fi: Vector3 = face_out[i]
		var fj: Vector3 = face_in[j]
		var pi: Vector3 = pts[i]
		var pj: Vector3 = pts[j]
		var mi: Vector3 = miter[i]
		var mj: Vector3 = miter[j]
		for k in prof.size() - 1:
			var p0: Vector2 = prof[k]
			var p1: Vector2 = prof[k + 1]
			var n0: Vector2 = nrms[k]
			var n1: Vector2 = nrms[k + 1]
			var v := [pi + mi * p0.x + Vector3(0, p0.y, 0), pj + mj * p0.x + Vector3(0, p0.y, 0),
				pj + mj * p1.x + Vector3(0, p1.y, 0), pi + mi * p1.x + Vector3(0, p1.y, 0)]
			var nm := [fi * n0.x + Vector3.UP * n0.y, fj * n0.x + Vector3.UP * n0.y,
				fj * n1.x + Vector3.UP * n1.y, fi * n1.x + Vector3.UP * n1.y]
			_quad(st, v, nm, ((nm[0] as Vector3) + (nm[2] as Vector3)).normalized())

## Skirting right round a closed outline `pts` (object space, on the floor, wound either way): outside it, or
## inside it (`inward`: the inner face of a round room's wall). `y`, `prof`, `nrms`: up the wall, and another
## cross-section (_build_wall_angle).
func _skirt_loop(st: SurfaceTool, pts: Array, xf: Transform3D, inward: bool, y := 0.0, prof: Array = SKIRT,
		nrms: Array = []) -> void:
	var n := pts.size()
	if n < 3: return
	var area := 0.0
	for i in n:
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % n]
		area += p.x * q.y - q.x * p.y
	var sgn := (1.0 if area > 0.0 else -1.0) * (-1.0 if inward else 1.0)
	var side: Array[Vector2] = []                # each edge's normal, the side the skirting goes
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		var d := (b - a).normalized()
		side.append(Vector2(d.y, -d.x) * sgn)
	var at: Array = []
	var miter: Array = []
	var face_in: Array = []
	var face_out: Array = []
	for i in n:
		var before: Vector2 = side[(i - 1 + n) % n]
		var after: Vector2 = side[i]
		var m := (before + after).normalized()
		var off := m / maxf(m.dot(after), 0.3)
		var p: Vector2 = pts[i]
		at.append(xf * Vector3(p.x, y, p.y))
		miter.append(xf.basis * Vector3(off.x, 0.0, off.y))
		var smooth := before.dot(after) > 0.85            # under ~30 degrees: part of a curve
		face_in.append(xf.basis * Vector3(m.x, 0.0, m.y) if smooth else xf.basis * Vector3(before.x, 0.0, before.y))
		face_out.append(xf.basis * Vector3(m.x, 0.0, m.y) if smooth else xf.basis * Vector3(after.x, 0.0, after.y))
	_skirt_run(st, at, miter, face_in, face_out, true, prof, nrms)

## Walls painted with one of BARE_WALLS (the T.S.R.A. outpost's) have no skirting: their paint runs down to the
## floor. Loop `pts` (world metres) as the runs of it that are skirted: [[]] when all of it is (skirt it as it
## is), [] when none of it is, else the open runs between the bare stretches.
const BARE_WALLS := ["Outpost_Wall"]
func _skirted_runs(pts: Array, closed: bool) -> Array:
	var n := pts.size()
	var segs := n if closed else n - 1
	var bare: Array[bool] = []
	var any := false
	for i in segs:
		var mid: Vector2 = ((pts[i] as Vector2) + (pts[(i + 1) % n] as Vector2)) * 0.5 / CELL
		var hit: Dictionary = wall_graph.edge_near(mid, 0.4 / CELL)
		var b := false
		if not hit.is_empty():
			var ed: Dictionary = wall_graph.edges[hit.e]
			b = str(ed.get("mat_l", "")) in BARE_WALLS or str(ed.get("mat_r", "")) in BARE_WALLS
		bare.append(b)
		any = any or b
	if not any: return [[]]
	var start := 0
	if closed:
		while not bare[start]: start += 1        # (begin at a bare stretch, so no run wraps round the loop's start)
	var out: Array = []
	var run: Array = []
	for k in segs:
		var i := (start + k) % segs
		if bare[i]:
			if run.size() >= 2: out.append(run)
			run = []
			continue
		if run.is_empty(): run.append(pts[i])
		run.append(pts[(i + 1) % n])
	if run.size() >= 2: out.append(run)
	return out

## Skirting along a run of the wall graph's feet that stops at a doorway each end (wall_mesh.gd breaks the chain
## there): out from the faces the way they face (the right of the way the run goes), butting up to the door's
## casing (SKIRT_STOP short of the opening's edge)
## (`y`, `prof`, `nrms`, `stop`: up the wall, another cross-section, and how far short of the ends it stops)
const SKIRT_STOP := 0.09                  # m: the casing's width (level_geometry.gd CASING_W)
func _skirt_open(st: SurfaceTool, pts: Array, y := 0.0, prof: Array = SKIRT, nrms: Array = [], stop := SKIRT_STOP) -> void:
	var p: Array = pts.duplicate()
	if (p[0] as Vector2).distance_to(p[1]) > stop * 2.0: p[0] = (p[0] as Vector2).move_toward(p[1], stop)
	var n := p.size()
	if (p[n - 1] as Vector2).distance_to(p[n - 2]) > stop * 2.0: p[n - 1] = (p[n - 1] as Vector2).move_toward(p[n - 2], stop)
	var side: Array[Vector2] = []
	for i in n - 1:
		var d: Vector2 = ((p[i + 1] as Vector2) - (p[i] as Vector2)).normalized()
		side.append(Vector2(d.y, -d.x))
	var at: Array = []
	var miter: Array = []
	var face_in: Array = []
	var face_out: Array = []
	for i in n:
		var before: Vector2 = side[maxi(i - 1, 0)]
		var after: Vector2 = side[mini(i, n - 2)]
		var m := (before + after).normalized()
		var off := m / maxf(m.dot(after), 0.3)
		var q: Vector2 = p[i]
		at.append(Vector3(q.x, y, q.y))
		miter.append(Vector3(off.x, 0.0, off.y))
		var smooth := before.dot(after) > 0.85
		face_in.append(Vector3(m.x, 0.0, m.y) if smooth else Vector3(before.x, 0.0, before.y))
		face_out.append(Vector3(m.x, 0.0, m.y) if smooth else Vector3(after.x, 0.0, after.y))
	_skirt_run(st, at, miter, face_in, face_out, false, prof, nrms)

## The plan outlines (object space, metres) a placed wall, pillar or column stands on, as [points, inward]: what
## its skirting runs round. Doors, arches and everything else: none (a door's frame meets the floor itself).
func _object_outlines(o: Dictionary) -> Array:
	if o.type == "squeeze_gap":              # the two jambs either side of the slit
		var half := CELL * 0.5
		var g := clampf(float(o.get("gap", 0.55)), 0.35, 0.9) * 0.5
		return [[[Vector2(-half, -half), Vector2(half, -half), Vector2(half, -g), Vector2(-half, -g)], false],
			[[Vector2(-half, g), Vector2(half, g), Vector2(half, half), Vector2(-half, half)], false]]
	if o.type == "door":                     # the partition's two sides either side of the doorway (props/door.gd), skirted like any wall
		var t := float(object_info("door").get("thickness", 0.3)) * 0.5
		var span := CELL * float(o.scale) * 0.5
		var gap := (Door.DOOR_W + Door.LINING * 2.0) * 0.5
		return [[[Vector2(-t, -span), Vector2(t, -span), Vector2(t, -gap), Vector2(-t, -gap)], false],
			[[Vector2(-t, gap), Vector2(t, gap), Vector2(t, span), Vector2(-t, span)], false]]
	if o.type == "arch" or is_stairs(o.type): return []
	var info := object_info(o.type)
	if info.has("model"): return []
	match str(info.get("shape", "")):
		"pillar":
			var h := object_thick(o) * 0.5
			return [[[Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)], false]]
		"column":
			var r := object_thick(o) * 0.5
			var ring: Array = []
			for i in 24: ring.append(Vector2.from_angle(TAU * i / 24.0) * r)
			return [[ring, false]]
		"slab", "corner", "arc":
			var path := shape_path(o)
			if path.size() < 2: return []
			var p: Array[Vector2] = []
			for v in path: p.append(v * CELL)
			var closed := p.size() > 2 and p[0].distance_to(p[-1]) < 0.01
			if closed: p.remove_at(p.size() - 1)
			var n := p.size()
			var segs := n if closed else n - 1
			var side: Array[Vector2] = []
			for i in segs:
				var d := (p[(i + 1) % n] - p[i]).normalized()
				side.append(Vector2(-d.y, d.x))
			var half := object_thick(o) * 0.5
			var left: Array = []
			var right: Array = []
			for i in n:            # (the same mitred faces as level_geometry.gd _sweep_wall)
				var before: Vector2 = side[(i - 1 + segs) % segs] if (closed or i > 0) else side[0]
				var after: Vector2 = side[i % segs] if (closed or i < n - 1) else side[segs - 1]
				var m := (before + after).normalized()
				var off := m * (half / maxf(m.dot(after), 0.3))
				left.append(p[i] + off)
				right.append(p[i] - off)
			if closed:                     # a round room: its outside, and its inside (the smaller of the two rings)
				var la := _area(left)
				var ra := _area(right)
				return [[left, la < ra], [right, ra <= la]]
			right.reverse()
			return [[left + right, false]]
	return []

static func _area(pts: Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a)

## Dark brown vinyl, matte: a pebbled rubber strip, scuffed and uneven, that takes the light like the wall
## above it. Kept rough with little specular: a glossy one mirrored the bright ceiling at a low camera
## (crawling) and read as a white stripe whatever the light on it.


# ---------------------------------------------------------------- the drop ceiling's wall angle
# A suspended ceiling's grid doesn't keep to the walls: the tiles round a room's edge are cut to fit, and their cut
# edges rest on a wall angle, an L of painted steel screwed along the top of the wall. Without it a wall off the
# tile grid (every cell edge is the middle of a tile, drop_ceiling.gdshader, and a drawn wall can stand anywhere)
# cut the grid off bare: a sliver of tile and a T-bar running straight into the wallpaper. Its cross-section, from
# the flange's front edge in to the wall (x: out from the wall, y: from the ceiling; metres), wound so its normals
# face out and down: the lip, a rounded edge, the underside.
const ANGLE := [Vector2(0.03, 0.0), Vector2(0.03, -0.004), Vector2(0.0296, -0.0048), Vector2(0.0288, -0.0052),
	Vector2(0.0, -0.0052)]

func _build_wall_angle() -> void:
	var nrms := _profile_normals(ANGLE)
	var sts := {}
	# the maze's walls, a face at a time, mitred as the skirting is
	for f: Dictionary in _faces:
		var c: Vector2i = f.c
		if not _drop_at(c): continue
		var fr := _face_frame(f)
		var mid: Vector3 = fr[0] + Vector3(0.0, ceiling_height(c), 0.0)
		var out: Vector3 = fr[1]
		var along: Vector3 = fr[2]
		var sa: float = MITRE[f.ends[0]]
		var sb: float = MITRE[f.ends[1]]
		_skirt_run(_chunk_st(sts, mid), [mid - along * (CELL * 0.5), mid + along * (CELL * 0.5)],
			[out - along * sa, out + along * sb], [out, out], [out, out], false, ANGLE, nrms)
	# placed walls, pillars and columns that go right up to the ceiling: round the outline of each (a door's
	# partition and a squeeze gap's jambs have a lintel over the way through: round the whole of them)
	for o: Dictionary in objects:
		var outlines := _object_outlines(o)
		if outlines.is_empty(): continue
		var full := _object_wall_h(o)
		var h := float(o.get("height", 0.0))
		if h > 0.0 and h < full - 0.01: continue
		if not _drop_at(Vector2i(roundi(o.pos_x), roundi(o.pos_y))): continue
		if o.type == "door":
			var t := float(object_info("door").get("thickness", 0.3)) * 0.5
			var span := CELL * float(o.scale) * 0.5
			outlines = [[[Vector2(-t, -span), Vector2(t, -span), Vector2(t, span), Vector2(-t, span)], false]]
		elif o.type == "squeeze_gap":
			var half := CELL * 0.5
			outlines = [[[Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)], false]]
		var xf := object_transform(o)
		for outline: Array in outlines:
			_skirt_loop(_chunk_st(sts, xf.origin + Vector3(0.0, full, 0.0)), outline[0], xf, outline[1], full, ANGLE, nrms)
	# the wall graph: along the tops of its faces that reach the ceiling, chained round its corners and curves (and
	# over its doorways, the wall over them going on up to the ceiling)
	var by_start := {}
	for pc: Dictionary in wall_plan.get("pieces", []):
		var p: Vector2 = pc.p
		var q: Vector2 = pc.q
		if p.distance_to(q) < 1e-4: continue
		var d := (q - p).normalized()
		var room: Vector2 = (p + q) * 0.5 + Vector2(d.y, -d.x) * 0.1       # (a face looks out to its right)
		var c := Vector2i(roundi(room.x / CELL), roundi(room.y / CELL))
		var y := ceiling_height(c)
		if minf(float(pc.y1), float(pc.y1q)) < y - 0.02 or not _drop_at(c): continue
		by_start[_angle_key(p, y)] = [p, q, y]
	var has_pred := {}
	for k: Vector3i in by_start:
		var nk := _angle_key(by_start[k][1], by_start[k][2])
		if by_start.has(nk) and nk != k: has_pred[nk] = true
	var order: Array = by_start.keys().filter(func(k): return not has_pred.has(k))
	order.append_array(by_start.keys().filter(func(k): return has_pred.has(k)))
	var seen := {}
	for k0: Vector3i in order:
		if seen.has(k0): continue
		var pts: Array = []
		var k = k0
		var tail := k0
		while k != null and not seen.has(k):
			seen[k] = true
			tail = k
			pts.append(by_start[k][0])
			var nk := _angle_key(by_start[k][1], by_start[k][2])
			if by_start.has(nk): k = nk
			else: k = null
		var y: float = by_start[k0][2]
		var at: Vector2 = pts[0]
		var st := _chunk_st(sts, Vector3(at.x, y, at.y))
		if k == k0 and pts.size() >= 3:
			var area := 0.0
			for i in pts.size():
				var a: Vector2 = pts[i]
				var b: Vector2 = pts[(i + 1) % pts.size()]
				area += a.x * b.y - b.x * a.y
			_skirt_loop(st, pts, Transform3D.IDENTITY, area < 0.0, y, ANGLE, nrms)
		else:
			pts.append(by_start[tail][1])
			_skirt_open(st, pts, y, ANGLE, nrms, 0.0)
	if sts.is_empty(): return
	var mat := StandardMaterial3D.new()
	# painted dark, the wallpaper's black band along the top of the walls: the two read as one edge (a white
	# strip on the band was a second line round every room)
	mat.albedo_color = Color(0.05, 0.045, 0.04)
	mat.roughness = 0.85
	mat.metallic_specular = 0.1
	_commit_chunks(sts, func(mi: MeshInstance3D) -> void:
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)

static func _angle_key(p: Vector2, y: float) -> Vector3i:
	return Vector3i(roundi(p.x * 2000.0), roundi(p.y * 2000.0), roundi(y * 100.0))

## True when cell c's ceiling is a drop ceiling (a textures/pbr material whose .tres says "metadata/drop_ceiling":
## the level's, or one painted on the cell) and there is a ceiling there at all
var _drop_ids := {}
func _drop_at(c: Vector2i) -> bool:
	if open_above.has(c): return false
	var id := str(painted("ceiling").get(c, _mat_id("ceiling")))
	if not _drop_ids.has(id):
		var path := "res://textures/pbr/%s/%s.tres" % [id, id]
		_drop_ids[id] = ResourceLoader.exists(path) and bool(load(path).get_meta("drop_ceiling", false))
	return _drop_ids[id]

# ---------------------------------------------------------------- outlets and switches
## A duplex socket and a rocker switch (light_switch_and_wall_socket.glb, "Light Switch And Wall Socket" by
## Theocritus on Sketchfab), at the heights an electrician puts them: the socket 30 cm up, the switch 1.2 m
## up and a hand's width in from the edge of a way through. Rolled per wall face with a dice of its own (so the
## tubes' dice don't move); a look-only copy of the floor gets the same ones.
const FITTINGS := "res://models/props/wall_socket/light_switch_and_wall_socket.glb"
const OUTLET_H := 0.3
const SWITCH_H := 1.2
const OUTLET_CHANCE := 0.08         # a wall face (4.5 m) with a socket on it
const SWITCH_CHANCE := 0.06         # an outside corner with a switch beside it
const FITTING_SQUARE := 8           # cells a side of a group (one MultiMesh a part a group: they cull by group)
const FITTING_RANGE := 32.0         # m: a fitting's own draw distance (7 cm across: a pixel or two beyond this)

## Places them; returns where the switches went (world, [position, out of the wall]) for the hand marks
func _build_fittings() -> Array:
	var switches: Array = []
	var outlets: Array = []
	for f: Dictionary in _faces:
		if f.has("door"): continue
		var c: Vector2i = f.c
		var r := RandomNumberGenerator.new()
		r.seed = hash(Vector4i(c.x, c.y, DIRS.find(f.n), floor_src(level_raw, floor_no) + 8117))
		var fr := _face_frame(f)
		var mid: Vector3 = fr[0]
		var out: Vector3 = fr[1]
		var along: Vector3 = fr[2]
		var taken: Array[float] = []
		# (never inside a doorway or a thin wall's cell: the switch goes on the room's wall beside the opening,
		# not in its jamb; and never where a placed wall meets this one, or it would sit half inside it)
		var in_passage := carved.has(c)
		for e in 2:
			if f.ends[e] != END_OUT or r.randf() >= SWITCH_CHANCE or in_passage: continue
			var side := -1.0 if e == 0 else 1.0
			var u := (CELL * 0.5 - 0.2) * side
			# the corner itself must be a real one: no placed wall carrying the wall on from it
			if not _clear_of_objects(mid + along * (CELL * 0.5 * side) + out * 0.05, 0.4): continue
			if not _clear_of_objects(mid + along * u + out * 0.05, 0.35): continue
			taken.append(u)
			switches.append([mid + along * u + Vector3(0.0, SWITCH_H, 0.0), out, c])
		if r.randf() < OUTLET_CHANCE and not in_passage:
			var u := r.randf_range(-1.6, 1.6)
			var clear := _clear_of_objects(mid + along * u + out * 0.05, 0.35)
			for v in taken:
				if absf(v - u) < 0.5: clear = false
			if clear: outlets.append([mid + along * u + Vector3(0.0, OUTLET_H, 0.0), out, c])
	if switches.is_empty() and outlets.is_empty(): return switches
	var parts := _fitting_parts()
	if parts.is_empty(): return switches
	for kind: String in ["socket", "switch"]:
		var spots: Array = outlets if kind == "socket" else switches
		if spots.is_empty(): continue
		var groups := {}
		for s: Array in spots:
			var c: Vector2i = s[2]
			groups.get_or_add(Vector2i(floori(float(c.x) / FITTING_SQUARE), floori(float(c.y) / FITTING_SQUARE)), []).append(s)
		for part: Array in parts[kind]:
			var mesh: Mesh = part[0]
			var local: Transform3D = part[1]
			for g in groups:
				var list: Array = groups[g]
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = mesh
				mm.instance_count = list.size()
				var buf := MMBuffer.alloc(mm)
				var st := MMBuffer.stride(mm)
				for i in list.size():
					var s: Array = list[i]
					MMBuffer.put(buf, i * st, Transform3D(_on_wall(s[1]), s[0] + (s[1] as Vector3) * 0.001) * local)
				mm.buffer = buf
				var mmi := MultiMeshInstance3D.new()
				mmi.multimesh = mm
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mmi.visibility_range_end = FITTING_RANGE + FITTING_SQUARE * CELL * sqrt(2.0) / 2.0     # (the group's centre: its nearest fitting is past FITTING_RANGE)
				mmi.visibility_range_end_margin = 4.0
				mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				add_child(mmi)
	return switches

## The model's meshes, by fitting: {"socket": [[mesh, transform], ...], "switch": [...]}, each transform
## putting the part where it sits on its plate, the plate centred on the origin with its back on z = 0 and its
## face to +Z. The file has both side by side (the socket on the left), so they are told apart by where they are.
static var _fitting_cache := {}
func _fitting_parts() -> Dictionary:
	if not _fitting_cache.is_empty(): return _fitting_cache
	var root := IndustrialProp._instance(FITTINGS)
	if root == null: return {}
	var found := {"socket": [], "switch": []}
	var box := {}
	var plate := {}                     # kind -> the plate's box (its biggest part, face on): what sits on the wall
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null: continue
		var xf := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != root:
			if p is Node3D: xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var aabb := xf * mi.mesh.get_aabb()
		var kind := "socket" if aabb.get_center().x < 0.0 else "switch"
		found[kind].append([mi.mesh, xf])
		if box.has(kind):
			var was: AABB = box[kind]
			box[kind] = was.merge(aabb)
		else:
			box[kind] = aabb
		if not plate.has(kind) or aabb.size.x * aabb.size.y > (plate[kind] as AABB).size.x * (plate[kind] as AABB).size.y:
			plate[kind] = aabb
	root.free()
	for kind: String in found:
		if not box.has(kind): continue
		var b: AABB = box[kind]
		# its back flat on the wall: the plate's back, not the deepest part (the toggle's pivot reaches in behind
		# the plate, into the wall box, and measured from that the plate stood a couple of centimetres off)
		var pb: AABB = plate[kind]
		var shift := Vector3(-b.get_center().x, -b.get_center().y, -pb.position.z)
		for part: Array in found[kind]:
			var at: Transform3D = part[1]
			part[1] = Transform3D(Basis(), shift) * at
	_fitting_cache = found
	return found

# ---------------------------------------------------------------- wear
## The marks living leaves on walls, drawn over them (a multiply, so the wallpaper shows through): a band of
## kick marks and grime along the foot of every wall, grey hand marks round each switch, and hands and carts on
## the outside corners people round. Cards a few millimetres off the wall, the marks worked out in the shader
## from where they are; they fade out further off than they could be told apart.
const WEAR_FOOT := Vector2(0.105, 0.72)          # the kick band: from the top of the skirting up to here
func _build_wall_wear(switches: Array) -> void:
	var cards: Array = []                       # [transform, mode, seed, corner side, centre height]
	for f: Dictionary in _faces:
		if f.has("door"): continue
		var fr := _face_frame(f)
		var mid: Vector3 = fr[0]
		var out: Vector3 = fr[1]
		var along: Vector3 = fr[2]
		var b := _on_wall(out)
		var c: Vector2i = f.c
		var dirt := wall_grime_at(c).x
		if dirt < 0.03: continue                    # (a Clean zone: kept up, no marks)
		var sd := fposmod(float(hash(Vector3i(c.x, c.y, DIRS.find(f.n)))) * 0.000123, 1.0)
		var h := WEAR_FOOT.y - WEAR_FOOT.x
		var cy := (WEAR_FOOT.x + WEAR_FOOT.y) * 0.5
		# (the mode's fraction, 0..0.4, carries the area's dirt to the shader: more grime and scuffs where it is dirty)
		cards.append([Transform3D(b * Basis.from_scale(Vector3(CELL, h, 1.0)), mid + out * 0.004 + Vector3(0, cy, 0)), dirt * 0.4, sd, 0.0, cy])
		for e in 2:
			# (only some corners are rounded often enough to mark: one in three)
			if f.ends[e] != END_OUT or fposmod(sd * 7.31 + e * 0.53, 1.0) > 0.33: continue
			var side := -1.0 if e == 0 else 1.0
			if not _clear_of_objects(mid + along * (CELL * 0.5 * side) + out * 0.05, 0.4): continue    # (a placed wall carries on from it: no corner)
			var w := 0.7
			var at := mid + along * side * (CELL * 0.5 - w * 0.5) + out * 0.005 + Vector3(0, 0.9, 0)
			cards.append([Transform3D(b * Basis.from_scale(Vector3(w, 1.6, 1.0)), at), 2.0, sd, side * w * 0.5, 0.9])
	for s: Array in switches:
		if wall_grime_at(s[2]).x < 0.03: continue
		var b := _on_wall(s[1])
		cards.append([Transform3D(b * Basis.from_scale(Vector3(0.36, 0.44, 1.0)), (s[0] as Vector3) + (s[1] as Vector3) * 0.005), 1.0, 0.5, 0.0, SWITCH_H])
	if cards.is_empty(): return
	var mat := ShaderMaterial.new()
	mat.shader = _coded_wear()
	mat.render_priority = 1
	var quad := QuadMesh.new()
	_chunked(cards, func(cd: Array) -> Vector3: return (cd[0] as Transform3D).origin, "", func(list: Array) -> MultiMeshInstance3D:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = quad
		mm.instance_count = list.size()
		var buf := MMBuffer.alloc(mm)
		var st := MMBuffer.stride(mm)
		for i in list.size():
			var cd: Array = list[i]
			MMBuffer.put(buf, i * st, cd[0])
			buf[i * st + 12] = cd[1]
			buf[i * st + 13] = cd[2]
			buf[i * st + 14] = cd[3]
			buf[i * st + 15] = cd[4]
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		return mmi)

# ---------------------------------------------------------------- damp
## Water come down the wall from a leak in the ceiling: mould and wet staining in streaks from the top, fading
## out lower down. From photos of damp plaster (textures/damp_atlas.jpg, three of them stacked, made a multiply
## map: the clean plaster white, so the wallpaper shows through and only the stain darkens it). A card on the
## odd wall face, its top at the ceiling, showing a random stretch of a random photo (mirrored or not) at true
## size (the photos are 5.4 m of wall high), fading out raggedly at the face's ends.
const DAMP_ATLAS := "res://textures/damp_atlas.jpg"
const DAMP_CHANCE := 0.3            # times the area's damp (wall_grime_at): a face with a big photo stain down it (a wet
                                    # patch now and then; in a Moist zone one face in four)
const DAMP_PHOTO_H := 5.4           # metres of wall a photo's height covers
const DAMP_STRIP := 1365.0 / 4096.0 # one photo's share of the atlas's height
const DAMP_ASPECT := 2048.0 / 1365.0

## A texture by its res:// path. One Godot hasn't imported yet (added while the editor was shut, or a run
## started without it) is read straight from its file, so it still shows.
static var _raw_tex := {}
static func _texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path): return load(path)
	if not _raw_tex.has(path):
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img != null and not img.is_empty():
			img.generate_mipmaps()
			_raw_tex[path] = ImageTexture.create_from_image(img)
		else:
			push_warning("texture not found: " + path)
			_raw_tex[path] = null
	return _raw_tex[path]

func _build_damp() -> void:
	var atlas := _texture(DAMP_ATLAS)
	if atlas == null: return
	var span := CELL / (DAMP_PHOTO_H * DAMP_ASPECT)          # a face's width as a share of a photo's
	var cards: Array = []
	for f: Dictionary in _faces:
		if f.has("door"): continue
		var c: Vector2i = f.c
		var r := RandomNumberGenerator.new()
		r.seed = hash(Vector4i(c.x, c.y, DIRS.find(f.n), floor_src(level_raw, floor_no) + 4441))
		if r.randf() >= DAMP_CHANCE * wall_grime_at(c).y: continue
		var fr := _face_frame(f)
		# (not on a wall a placed wall butts onto: the stain would run straight through the thin wall's end)
		var clear := true
		for k in 5:
			var at: Vector3 = (fr[0] as Vector3) + (fr[2] as Vector3) * (CELL * (k / 4.0 - 0.5)) + (fr[1] as Vector3) * 0.05
			if not _clear_of_objects(at, 0.2): clear = false
		if not clear: continue
		var top := ceiling_height(c)
		var h := minf(top, DAMP_PHOTO_H)
		var xf := Transform3D(_on_wall(fr[1]) * Basis.from_scale(Vector3(CELL, h, 1.0)),
			(fr[0] as Vector3) + (fr[1] as Vector3) * 0.006 + Vector3(0.0, top - h * 0.5, 0.0))
		var custom := Color(float(r.randi() % 3), r.randf() * (1.0 - span), -1.0 if r.randf() < 0.5 else 1.0, h / DAMP_PHOTO_H)
		cards.append([xf, custom, r.randf_range(0.55, 0.95)])
	if cards.is_empty(): return
	var mat := ShaderMaterial.new()
	mat.shader = _coded_damp()
	mat.render_priority = 1
	mat.set_shader_parameter("damp", atlas)
	mat.set_shader_parameter("strip_h", DAMP_STRIP)
	mat.set_shader_parameter("span", span)
	var quad := QuadMesh.new()
	_chunked(cards, func(cd: Array) -> Vector3: return (cd[0] as Transform3D).origin, "", func(list: Array) -> MultiMeshInstance3D:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = quad
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i][0])
			mm.set_instance_custom_data(i, list[i][1])
			mm.set_instance_color(i, Color(1, 1, 1, list[i][2]))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		return mmi)

static var _damp_shader: Shader
static func _coded_damp() -> Shader:
	if _damp_shader != null: return _damp_shader
	_damp_shader = Shader.new()
	_damp_shader.code = """shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
uniform sampler2D damp : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float strip_h = 0.3333;         // one photo's share of the atlas's height
uniform float span = 0.5556;            // a face's width as a share of a photo's
varying vec2 lp;          // metres on the card: x along the wall, y up from its middle
varying vec2 sz;
varying vec4 info;        // x: which photo, y: where along it this face starts, z: mirrored (-1), w: share of its height shown
varying float strength;
void vertex() {
	sz = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	lp = VERTEX.xy * sz;
	info = INSTANCE_CUSTOM;
	strength = COLOR.a;
}
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}
void fragment() {
	float fx = lp.x / sz.x + 0.5;
	if (info.z < 0.0) fx = 1.0 - fx;
	float v = clamp((0.5 - lp.y / sz.y) * info.w, 0.002, 0.995);      // 0 at the ceiling
	vec3 t = texture(damp, vec2(info.y + fx * span, (info.x + v) * strip_h)).rgb;
	// the water ran down from above: it fades out at the face's ends, raggedly, not at a straight edge
	float e = sz.x * 0.5 - abs(lp.x);
	float ragged = (vnoise(vec2(lp.y * 1.3, info.x * 7.0 + info.y * 11.0)) - 0.5) * 0.7;
	float keep = smoothstep(0.0, 1.0, e - 0.1 + ragged);
	ALBEDO = mix(vec3(1.0), t, strength * keep);
}
"""
	return _damp_shader

# ---------------------------------------------------------------- grime
## How lived-in each stretch of wall looks: a grey film over the paper, grime and damp along its foot, water run
## down from the ceiling. Real walls are not dirty face by face at random: grime gathers where nobody cleans and
## water where the building leaks, and both spread over a whole run of wall. So every open cell in front of a wall
## gets a dirt and a damp amount (0..1) from a slow noise across the floor (whole areas worse than others), raised
## by the level editor's Dirty and Moist zones and wiped by Clean (each fading out a cell past its painted edge),
## and its wall faces are dressed from that. The cards are decals: ambientCG photos (textures/grime/, CC0), colour
## in RGB and opacity in alpha, multiplied over the wall so the paper shows through.
const GRIME_DIR := "res://textures/grime/"
const GRIME_FILMS := ["film_1", "film_2", "film_3"]
const GRIME_FOOT := ["floor_damp_1", "floor_damp_2", "floor_damp_3"]
const GRIME_LEAKS := ["ceiling_leak_1", "ceiling_leak_2", "ceiling_leak_3", "ceiling_leak_4", "ceiling_leak_5"]
const GRIME_DRIPS := ["drip_1"]
const GRIME_NOISE_CELLS := 5.0      # cells across one rise and fall of the floor's own dirt
const GRIME_FILM_M := 3.0           # metres of wall one pass of a film photo covers
const GRIME_FILM_MAX := 10.0        # m: how far up a film goes (an endless ceiling's walls are not filmed for ever)
var _wall_grime := {}               # Vector2i (open cell) -> Vector2(dirt, damp)

## The dirt (x) and damp (y) of the walls round open cell `c`, 0..1 each
func wall_grime_at(c: Vector2i) -> Vector2:
	return _wall_grime.get(c, Vector2.ZERO)

func _wall_grime_field() -> void:
	_wall_grime.clear()
	var sd := floor_src(level_raw, floor_no)
	var dust := FastNoiseLite.new()
	dust.seed = sd * 7 + 311
	dust.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	dust.frequency = 1.0 / GRIME_NOISE_CELLS
	dust.fractal_octaves = 2
	var wet := FastNoiseLite.new()
	wet.seed = sd * 13 + 977
	wet.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	wet.frequency = 1.0 / (GRIME_NOISE_CELLS * 1.6)
	# 1 in a painted zone, 0.5 a cell past its edge: a zone's edge is a fade along the wall, not a line on it
	var reach := func(zone: Dictionary, c: Vector2i) -> float:
		if zone.has(c): return 1.0
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if zone.has(c + Vector2i(dx, dz)): return 0.5
		return 0.0
	for f: Dictionary in _faces:
		var c: Vector2i = f.c
		if _wall_grime.has(c): continue
		var n := dust.get_noise_2d(c.x, c.y) * 0.5 + 0.5
		var w := wet.get_noise_2d(c.x, c.y) * 0.5 + 0.5
		var dirt := 0.06 + 0.3 * smoothstep(0.3, 0.85, n)            # every wall a little, some areas a good deal more
		var damp := 0.3 * smoothstep(0.72, 0.95, w)                  # dry, but for the odd patch where water gets in
		var dirty_k: float = reach.call(grime_zones.dirty, c)
		var moist_k: float = reach.call(grime_zones.moist, c)
		dirt += 0.7 * dirty_k + 0.15 * moist_k                                 # (a wet wall gathers dirt too)
		damp += 0.85 * moist_k
		if low.has(c) or crawl.has(c): dirt += 0.1                    # (low, tight places are never cleaned)
		var keep := 1.0 - float(reach.call(grime_zones.clean, c))
		if liminal.has(c) or bright.has(c): keep *= 0.25              # (the kept, clean places)
		_wall_grime[c] = Vector2(clampf(dirt * keep, 0.0, 1.0), clampf(damp * keep, 0.0, 1.0))

func _build_wall_grime() -> void:
	var films := {}                     # photo pic -> cards
	var decals := {}
	var sd := floor_src(level_raw, floor_no)
	for f: Dictionary in _faces:
		if f.has("door"): continue
		var c: Vector2i = f.c
		var g := wall_grime_at(c)
		if g.x < 0.02 and g.y < 0.02: continue
		var fr := _face_frame(f)
		var mid: Vector3 = fr[0]
		var out: Vector3 = fr[1]
		var along: Vector3 = fr[2]
		# (not on a wall a placed wall butts onto: the stain would run straight through the thin wall's end)
		var clear := true
		for k in 5:
			if not _clear_of_objects(mid + along * (CELL * (k / 4.0 - 0.5)) + out * 0.05, 0.2): clear = false
		if not clear: continue
		var r := RandomNumberGenerator.new()
		r.seed = hash(Vector4i(c.x, c.y, DIRS.find(f.n), sd + 7117))
		var b := _on_wall(out)
		var top := ceiling_height(c)
		var roofed := not (open_ceiling.has(c) or endless_ceiling.has(c))
		# 1. a film of grey over the whole face, the dirtier the area the heavier
		var film := g.x * 0.42 + g.y * 0.12
		if film > 0.03:
			var h := minf(top, GRIME_FILM_MAX)
			var pic: String = GRIME_FILMS[r.randi() % GRIME_FILMS.size()]
			_grime_card(films, pic, b, Vector3(CELL, h, 1.0), mid + out * 0.007 + Vector3(0.0, h * 0.5, 0.0),
				Color(r.randf(), r.randf(), -1.0 if r.randf() < 0.5 else 1.0, 1.0 if r.randf() < 0.5 else 0.0), film)
		# 2. along the foot: mop splash and dust on a dirty wall, damp creeping up a wet one. Into an inside
		# corner more often than not (where the mop never reaches and the dust settles)
		if r.randf() < 0.06 + 0.8 * g.x + 0.7 * g.y:
			var w := r.randf_range(1.6, CELL)
			var h := w * 0.25 * r.randf_range(0.9, 1.6)
			var x := _grime_along(f, w, r, 0.65)
			_grime_card(decals, GRIME_FOOT[r.randi() % GRIME_FOOT.size()], b, Vector3(w, h, 1.0),
				mid + along * x + out * 0.008 + Vector3(0.0, h * 0.5, 0.0),
				Color(0.0, 0.0, -1.0 if r.randf() < 0.5 else 1.0, 0.0), clampf(0.3 + 0.55 * maxf(g.x, g.y * 1.1), 0.0, 0.85))
		if roofed:
			# 3. water run down from the ceiling: where it leaks, a broad stain hanging from the top of the wall
			if r.randf() < 0.75 * g.y:
				var w := r.randf_range(1.4, CELL)
				var h := minf(w * 0.5 * r.randf_range(1.0, 2.2), top * 0.8)
				var x := _grime_along(f, w, r, 0.0)
				_grime_card(decals, GRIME_LEAKS[r.randi() % GRIME_LEAKS.size()], b, Vector3(w, h, 1.0),
					mid + along * x + out * 0.009 + Vector3(0.0, top - h * 0.5, 0.0),
					Color(0.0, 0.0, -1.0 if r.randf() < 0.5 else 1.0, 0.0), clampf(0.35 + 0.5 * g.y, 0.0, 0.85))
			# 4. and a drip or two, a narrow streak from a joint in the ceiling
			if g.y > 0.25 and r.randf() < g.y * 0.5:
				for i in 1 + int(r.randf() < 0.4):
					var w := r.randf_range(0.22, 0.45)
					var h := minf(w * 4.0 * r.randf_range(0.7, 1.3), top * 0.9)
					var x := _grime_along(f, w, r, 0.0)
					_grime_card(decals, GRIME_DRIPS[r.randi() % GRIME_DRIPS.size()], b, Vector3(w, h, 1.0),
						mid + along * x + out * 0.01 + Vector3(0.0, top - h * 0.5, 0.0),
						Color(0.0, 0.0, -1.0 if r.randf() < 0.5 else 1.0, 0.0), r.randf_range(0.4, 0.75))
	_grime_cards(films, _coded_grime_film(), {"photo_m": GRIME_FILM_M})
	_grime_cards(decals, _coded_grime_decal(), {})

## Where along face `f` (m from its middle) a decal `w` wide goes: anywhere on it, or with chance `corner` hard
## into one of its inside corners
func _grime_along(f: Dictionary, w: float, r: RandomNumberGenerator, corner: float) -> float:
	var room := maxf(CELL - w, 0.0) * 0.5
	var ins: Array = []
	for e in 2:
		if f.ends[e] == END_IN: ins.append(-1.0 if e == 0 else 1.0)
	if not ins.is_empty() and r.randf() < corner:
		return float(ins[r.randi() % ins.size()]) * room * r.randf_range(0.85, 1.0)
	return r.randf_range(-room, room)

func _grime_card(by: Dictionary, pic: String, b: Basis, size: Vector3, at: Vector3, custom: Color, strength: float) -> void:
	if not by.has(pic): by[pic] = []
	(by[pic] as Array).append([Transform3D(b * Basis.from_scale(size), at), custom, strength])

## The cards, one material per photo, chunked like the rest of the trim
func _grime_cards(by: Dictionary, shader: Shader, params: Dictionary) -> void:
	for pic: String in by:
		var tex := _texture(GRIME_DIR + pic + ".png")
		if tex == null: continue
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.render_priority = 1
		mat.set_shader_parameter("photo", tex)
		for k: String in params: mat.set_shader_parameter(k, params[k])
		var quad := QuadMesh.new()
		_chunked(by[pic], func(cd: Array) -> Vector3: return (cd[0] as Transform3D).origin, "", func(list: Array) -> MultiMeshInstance3D:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.use_custom_data = true
			mm.mesh = quad
			mm.instance_count = list.size()
			for j in list.size():
				mm.set_instance_transform(j, list[j][0])
				mm.set_instance_custom_data(j, list[j][1])
				mm.set_instance_color(j, Color(1, 1, 1, list[j][2]))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = mat
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			return mmi)

## A film photo tiled over the card at true size (turned and mirrored at random), fading out raggedly at its edges
static var _grime_film_shader: Shader
static func _coded_grime_film() -> Shader:
	if _grime_film_shader != null: return _grime_film_shader
	_grime_film_shader = Shader.new()
	_grime_film_shader.code = """shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
uniform sampler2D photo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float photo_m = 3.0;            // metres of wall one pass of the photo covers
varying vec2 lp;          // metres on the card: x along the wall, y up from its middle
varying vec2 sz;
varying vec4 info;        // x, y: where in the photo this card starts, z: mirrored (-1), w: turned a quarter (1)
varying float strength;
void vertex() {
	sz = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	lp = VERTEX.xy * sz;
	info = INSTANCE_CUSTOM;
	strength = COLOR.a;
}
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}
void fragment() {
	vec2 m = vec2(lp.x * info.z, lp.y);
	if (info.w > 0.5) m = m.yx;
	vec4 t = texture(photo, m / photo_m + info.xy);
	// heavier low on the wall, where the dust settles and hands and shoes go, lighter up under the ceiling
	float y = lp.y + sz.y * 0.5;
	float lowk = mix(1.0, 0.55, smoothstep(0.8, 2.6, y));
	// ragged fade at the card's own edges, so no outline shows where the next face's film starts
	vec2 edge = sz * 0.5 - abs(lp);
	float ragged = (vnoise(lp * 1.6 + info.xy * 23.0) - 0.5) * 0.9;
	float keep = smoothstep(0.0, 0.9, min(edge.x, edge.y) - 0.05 + ragged);
	ALBEDO = mix(vec3(1.0), t.rgb, clamp(t.a * strength * keep * lowk, 0.0, 1.0));
}
"""
	return _grime_film_shader

## One decal photo over the whole card (mirrored or not), fading out just inside its edges
static var _grime_decal_shader: Shader
static func _coded_grime_decal() -> Shader:
	if _grime_decal_shader != null: return _grime_decal_shader
	_grime_decal_shader = Shader.new()
	_grime_decal_shader.code = """shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
uniform sampler2D photo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
varying vec2 lp;          // metres on the card: x along the wall, y up from its middle
varying vec2 sz;
varying vec4 info;        // z: mirrored (-1)
varying float strength;
void vertex() {
	sz = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	lp = VERTEX.xy * sz;
	info = INSTANCE_CUSTOM;
	strength = COLOR.a;
}
void fragment() {
	vec2 uv = vec2(lp.x / sz.x + 0.5, 0.5 - lp.y / sz.y);
	if (info.z < 0.0) uv.x = 1.0 - uv.x;
	vec4 t = texture(photo, uv);
	vec2 edge = sz * 0.5 - abs(lp);
	float keep = smoothstep(0.0, 0.06, min(edge.x, edge.y));
	ALBEDO = mix(vec3(1.0), t.rgb, clamp(t.a * strength * keep, 0.0, 1.0));
}
"""
	return _grime_decal_shader

static var _wear_shader: Shader
static func _coded_wear() -> Shader:
	if _wear_shader != null: return _wear_shader
	_wear_shader = Shader.new()
	_wear_shader.code = """shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
uniform vec3 mark : source_color = vec3(0.3, 0.28, 0.25);   // what full-strength grime leaves of the wall's colour
uniform float strength = 1.0;
varying vec2 lp;          // metres on the card: x along the wall, y up from its middle
varying vec2 sz;          // the card's size, metres
varying vec4 info;        // x: 0 the foot of a wall, 1 round a switch, 2 an outside corner; y: its dice; z: where the corner is (x); w: the card's middle, metres up
void vertex() {
	sz = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	lp = VERTEX.xy * sz;
	info = INSTANCE_CUSTOM;
}
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}
void fragment() {
	float y = lp.y + info.w;                    // metres up the wall
	float u = lp.x + info.y * 37.0;             // metres along it (each wall its own marks)
	float aa = max(length(fwidth(lp)), 0.0005);
	float m = 0.0;
	if (info.x < 0.5) {
		// Walls differ: most are fairly clean, some grimy, a few well kicked (the same marks on every wall
		// read as a pattern). How grimy and how scuffed this wall is, each rolled on its own, and both
		// raised by the dirt of the area it is in (info.x / 0.4, level_trim.gd wall_grime_at)
		float area = clamp(info.x / 0.4, 0.0, 1.0);
		float grimy = max(smoothstep(0.6, 0.9, hash12(vec2(info.y * 91.0, 3.7))), smoothstep(0.25, 0.7, area));
		float scuffed = 0.06 + 0.32 * pow(hash12(vec2(info.y * 53.0, 8.1)), 2.0) + 0.3 * smoothstep(0.3, 0.9, area);
		// grime settled along the foot: mop splash and dust, uneven, gone by knee height
		float band = (1.0 - smoothstep(0.11, 0.5, y)) * smoothstep(0.104, 0.118, y);
		m = band * grimy * (0.1 + 0.25 * vnoise(vec2(u * 1.6, y * 3.0)) * vnoise(vec2(u * 0.35, 1.7)));
		// kick and cart marks: short dark rubber strokes, most of them low, each fading along its drag
		float cs = 0.3;
		float id0 = floor(u / cs);
		for (int k = -1; k <= 1; k++) {
			vec2 hs = vec2(id0 + float(k), info.y * 97.0);
			if (hash12(hs) > scuffed) continue;
			vec2 ctr = vec2((hs.x + hash12(hs + 1.3)) * cs, 0.13 + 0.36 * pow(hash12(hs + 2.7), 1.8));
			float len = 0.03 + 0.18 * hash12(hs + 4.1);
			float ang = (hash12(hs + 5.9) - 0.5) * 0.5;
			vec2 dir = vec2(cos(ang), sin(ang));
			vec2 a = ctr - dir * len * 0.5;
			vec2 ba = dir * len;
			vec2 pa = vec2(u, y) - a;
			float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
			float wdt = 0.0012 + 0.0035 * hash12(hs + 7.7);
			float line = 1.0 - smoothstep(wdt - aa, wdt + aa, length(pa - ba * h));
			float fade = hash12(hs + 8.1) > 0.5 ? h : 1.0 - h;
			m = max(m, line * (0.25 + 0.6 * fade) * (0.5 + 0.5 * hash12(hs + 9.3)));
		}
	} else if (info.x < 1.5) {
		// round a switch: the grey of a thousand hands, heaviest just beside and under the plate
		vec2 q = (lp - vec2(0.0, -0.02)) / vec2(0.1, 0.15);
		float r = length(q) + (vnoise(lp * 22.0 + info.y * 40.0) - 0.5) * 0.45;
		m = (1.0 - smoothstep(0.3, 1.0, r)) * 0.32;
	} else {
		// an outside corner: hands and shoulders at waist to chest height, carts and feet at the bottom
		float e = abs(lp.x - info.z);
		float hand = (1.0 - smoothstep(0.0, 0.3, e)) * smoothstep(0.75, 1.0, y) * (1.0 - smoothstep(1.3, 1.65, y));
		float foot = (1.0 - smoothstep(0.0, 0.22, e)) * smoothstep(0.104, 0.118, y) * (1.0 - smoothstep(0.15, 0.55, y));
		m = (hand * 0.2 + foot * 0.25) * (0.45 + 0.9 * vnoise(vec2(e * 10.0, y * 7.0) + info.y * 30.0));
	}
	// fade out at the card's own edge and in the distance (the marks are under a pixel there: they'd crawl)
	vec2 edge = sz * 0.5 - abs(lp);
	m *= smoothstep(0.0, 0.03, min(edge.x, edge.y)) * (1.0 - smoothstep(14.0, 26.0, length(VERTEX)));
	ALBEDO = mix(vec3(1.0), mark, clamp(m * strength, 0.0, 0.9));
}
"""
	return _wear_shader
