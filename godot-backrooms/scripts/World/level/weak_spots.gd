extends RefCounted
## Weak spots: a patch of a wall block gone soft behind the paper, that you can break through and hide in
## (props/weak_spot.gd). Painted in the level editor (the "weak_spot" zone, on wall cells: level_data.gd
## weak_cells); which of the painted faces actually get one is picked here, the same every time you come back to
## the floor. level_geometry_surfaces.gd cuts the hole into the block (_build_walls) and hides it behind a skin of
## the same wall; level_trim.gd keeps the skirting and the wear off it.
##
## A spot: {id: its index on this floor, key: "<level id>:<floor>:<id>" (unique across the game, for saves),
## cell: the wall block, n: out of the wall (block to the open cell it faces), u: m along the face from its middle
## (along xf's +Z), xf: the hole's frame (level space: the floor stands at y 0), its origin the bottom middle of the
## hole on the face, X out of the wall, Y up, Z along the face; the hole is HOLE_W wide (z -HOLE_W/2 .. HOLE_W/2)
## and HOLE_H tall}.

const CELL := 4.5                 # (level_data.gd CELL: no preload of it here, it preloads this)
const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const HOLE_W := 0.9               # m
const HOLE_H := 2.1               # m, from the floor
const CAV_X0 := -2.4              # m: the cavity behind the hole, in the spot's frame (X out of the wall): its back
const CAV_X1 := -0.03             # m: its front plane (the hole's face is x 0)
const CAV_HZ := 1.2               # m: half its width along the face (inside the 4.5 m block even with SLIDE: 0.45 m to the edge)
const CAV_H := 2.9                # m: its height
const HIDE_X := -0.9              # m: further in than this you are hidden (not in the doorway)
const SLIDE := 0.6                # m: the most a hole sits off its face's middle
const AVOID := 1.6                # m: clear of every placed object and wall of the graph
const MIN_SPACING := 6.0          # m between two spots
const MIN_CEIL := 2.6             # m: the room the hole opens into is at least this high
const CHANCE := 0.35              # of a candidate face getting one (the .lvl's "weak_spot_chance" overrides it)
const ORIGIN_R := 0.6             # m: an object that isn't a wall line counts this far round its origin
## Types / shapes that reach out from their origin by their scale (half of it, in cells, each way)
const SCALED_TYPES := ["door", "arch", "squeeze_gap"]
const SCALED_SHAPES := ["window", "opening", "platform", "flight", "spiral"]
const PATH_SHAPES := ["slab", "corner", "arc", "spline"]

## This floor's weak spots (none on a look-only shell). `lvl`: the level (level_geometry_surfaces.gd).
static func pick(lvl) -> Array:
	var out: Array = []
	if lvl.shell or lvl.weak_cells.is_empty(): return out
	var chance := float(lvl.level_data.get("weak_spot_chance", CHANCE))
	if chance <= 0.0: return out
	# every face of a painted block that opens onto a room high enough to stand up in, in a fixed order
	var cells: Array = lvl.weak_cells.keys()
	cells.sort()
	var cands: Array = []             # [wall cell, out of the wall]
	for c: Vector2i in cells:
		if not lvl._block_at(c) or lvl.wrap_ring.has(c): continue
		for n: Vector2i in DIRS:
			if _open_ok(lvl, c + n): cands.append([c, n])
	if cands.is_empty(): return out
	# its own RNG (the level's rng is shared and fixed-seeded: drawing from it here would move everything after)
	var r := RandomNumberGenerator.new()
	r.seed = hash(str(lvl.level_meta.get("id", "")) + ":weak:" + str(lvl.floor_no))
	for i in range(cands.size() - 1, 0, -1):
		var j := r.randi_range(0, i)
		var tmp: Array = cands[i]
		cands[i] = cands[j]
		cands[j] = tmp
	var avoid := _obstacles(lvl)
	var taken: Array[Vector2] = []
	for cand: Array in cands:
		# (both drawn for every candidate, so one turned down for its spacing doesn't reshuffle the rest)
		var roll := r.randf()
		var u := r.randf_range(-SLIDE, SLIDE)
		if roll >= chance: continue
		var c: Vector2i = cand[0]
		var n: Vector2i = cand[1]
		var x := Vector3(n.x, 0.0, n.y)
		var z := x.cross(Vector3.UP)                  # (-n.y, 0, n.x): out x up, so the frame is right-handed
		var at := Vector3(c.x * CELL + n.x * CELL * 0.5, 0.0, c.y * CELL + n.y * CELL * 0.5) + z * u
		var p := Vector2(at.x, at.z)
		if taken.any(func(q: Vector2) -> bool: return q.distance_to(p) < MIN_SPACING): continue
		if not _clear(p, avoid): continue
		var id := out.size()
		taken.append(p)
		out.append({"id": id, "key": "%s:%d:%d" % [str(lvl.level_meta.get("id", "")), int(lvl.floor_no), id],
			"cell": c, "n": n, "u": u, "xf": Transform3D(Basis(x, Vector3.UP, z), at)})
	return out

## Can a hole open onto cell `o`: plain floor, not a pit, an arch, a pool, the border, nor a low room
static func _open_ok(lvl, o: Vector2i) -> bool:
	if lvl.walls.has(o) or lvl.pits.has(o) or lvl.arch_cells.has(o) or lvl.pool_cells.has(o): return false
	if lvl.hotel.has(o) or lvl.crawl.has(o) or lvl.low.has(o) or lvl.wrap_ring.has(o): return false
	return lvl.ceiling_height(o) >= MIN_CEIL

## What a hole keeps clear of (floor plan, metres): [segments [a, b], points [p, radius], rects]
static func _obstacles(lvl) -> Array:
	var segs: Array = []
	var pts: Array = []
	var rects: Array[Rect2] = []
	for o: Dictionary in lvl.objects:
		var type := str(o.type)
		var shape := str(lvl.object_info(type).get("shape", ""))
		if shape == "zone" or type == "entity": continue
		var at := Vector2(o.pos_x, o.pos_y)
		if lvl.is_stairs(type):
			for sc: Vector2i in lvl.stair_footprint(o):
				rects.append(Rect2((Vector2(sc) - Vector2(0.5, 0.5)) * CELL, Vector2(CELL, CELL)))
		elif shape in PATH_SHAPES:
			# (shape_path takes any type without a shape for a slab: only the wall lines ask it)
			var path: PackedVector2Array = lvl.shape_path(o)
			var rot := deg_to_rad(float(o.rotation))
			for i in path.size() - 1:
				segs.append([(at + path[i].rotated(rot)) * CELL, (at + path[i + 1].rotated(rot)) * CELL])
			if path.size() == 1: pts.append([(at + path[0].rotated(rot)) * CELL, ORIGIN_R])
		elif type in SCALED_TYPES or shape in SCALED_SHAPES:
			pts.append([at * CELL, maxf(ORIGIN_R, 0.5 * float(o.get("scale", 1.0)) * CELL)])
		else:
			pts.append([at * CELL, ORIGIN_R])
	# the wall graph (cells): its walls' solid runs, and its nodes, where the runs end at a doorway or a hub
	for sp: Array in lvl.wall_graph.nav_spans(true):
		segs.append([(sp[0] as Vector2) * CELL, (sp[1] as Vector2) * CELL])
	for k in lvl.wall_graph.nodes:
		pts.append([lvl.wall_graph.pos(k) * CELL, 0.0])
	return [segs, pts, rects]

static func _clear(p: Vector2, avoid: Array) -> bool:
	for s: Array in avoid[0]:
		if p.distance_to(Geometry2D.get_closest_point_to_segment(p, s[0], s[1])) < AVOID: return false
	for q: Array in avoid[1]:
		if p.distance_to(q[0]) < AVOID + float(q[1]): return false
	for b: Rect2 in avoid[2]:
		var near := p.clamp(b.position, b.end)
		if p.distance_to(near) < AVOID: return false
	return true
