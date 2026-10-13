extends RefCounted
## WALLS, layer 4: snapping for the level editor's wall tools, while drawing a wall and while dragging a node.
## Pure: a graph and the cursor (cells) in, the point to use and what it caught on out. In order, the first that
## is within reach wins:
##   1 node      an existing node: the wall joins it
##   2 cross     where two walls cross (the wall would split both there)
##   3 edge      a point along a wall, straight or curved (the wall is split there: a T)
##   4 tangent   straight on out of the end being drawn from (out of an arc: along its tangent, so the curve
##               carries on smoothly; out of a straight wall: in line with it)
##   5 perp / parallel   square to, or in line with, a wall nearby
##   6 extend    on the line a nearby wall would run on along past its end
##   7 angle     a whole number of angle steps from where it is drawn from
##   8 grid      the grid
## Two guide lines within reach of the cursor at once (an angle and an extension, say) give the point where they
## cross. "Within reach" is `radius` cells: the editor passes its snap radius in screen pixels over the zoom, so
## it feels the same at any zoom.

const Geom := preload("wall_geom.gd")

const RANK := {"node": 1, "cross": 2, "edge": 3, "tangent": 4, "perp": 5, "parallel": 5, "extend": 6, "angle": 7, "grid": 8, "free": 9}
const NEAR_WALLS := 4                # how many walls near the cursor offer square / in-line guides

## opts: radius (cells), grid (cells, 0 = off), angle_step (degrees, 0 = off), from (Array of Vector2: where the
## wall is drawn from / the far ends of a dragged node's walls), from_node (the node drawn from, -1 none),
## skip_node (the node being dragged, -1 none: it and its walls are never snapped to), off (true: no snapping).
## Returns {p, kind, node (-1), edge (-1), guides: [[a, b], ...], label}
static func snap(g, cur: Vector2, opts: Dictionary) -> Dictionary:
	var out := {"p": cur, "kind": "free", "node": -1, "edge": -1, "guides": [], "label": ""}
	if bool(opts.get("off", false)): return out
	var r: float = opts.get("radius", 0.3)
	var skip_node: int = opts.get("skip_node", -1)
	var skip_edges: Array = g.edges_at(skip_node) if skip_node >= 0 and g.nodes.has(skip_node) else []
	# 1: a node
	var n: int = g.node_near(cur, r, skip_node)
	if n >= 0:
		out.p = g.pos(n)
		out.kind = "node"
		out.node = n
		return out
	# 2 and 3: a crossing of two walls, else a point along one
	var near: Array = []
	for e in g.edges:
		if e in skip_edges or not g.box_of(e, r).has_point(cur): continue
		var c := Geom.closest(g.curve_of(e), cur)
		if c.d <= r: near.append([e, c])
	var best_cross = null
	for i in near.size():
		for j in range(i + 1, near.size()):
			for h: Dictionary in Geom.hits(g.curve_of(near[i][0]), g.curve_of(near[j][0])):
				if (h.p as Vector2).distance_to(cur) <= r and (best_cross == null or (h.p as Vector2).distance_to(cur) < (best_cross.p as Vector2).distance_to(cur)):
					best_cross = {"p": h.p, "e": near[i][0]}
	if best_cross != null:
		out.p = best_cross.p
		out.kind = "cross"
		out.edge = best_cross.e
		return out
	if not near.is_empty():
		near.sort_custom(func(x, y): return x[1].d < y[1].d)
		out.p = near[0][1].p
		out.kind = "edge"
		out.edge = near[0][0]
		return out
	# 4 to 7: guide lines; the nearest of the best kind, or where two of them cross
	var lines := _guides(g, cur, opts, skip_node, skip_edges)
	var hits: Array = []
	for ln: Dictionary in lines:
		var q := _project(ln, cur)
		var d := q.distance_to(cur)
		if d <= r: hits.append({"ln": ln, "q": q, "d": d})
	if not hits.is_empty():
		hits.sort_custom(func(x, y): return RANK[x.ln.kind] < RANK[y.ln.kind] or (RANK[x.ln.kind] == RANK[y.ln.kind] and x.d < y.d))
		var first: Dictionary = hits[0]
		var p: Vector2 = first.q
		var guides: Array = [_guide_of(first.ln, p)]
		var label: String = first.ln.kind
		for h: Dictionary in hits.slice(1):
			var x = _cross(first.ln, h.ln)
			if x != null and (x as Vector2).distance_to(cur) <= r:
				p = x
				guides.append(_guide_of(h.ln, p))
				label += " + " + str(h.ln.kind)
				break
		# a grid point on the guide, if one is near
		var step: float = opts.get("grid", 0.0)
		if step > 0.0 and guides.size() == 1:
			var gp := (p / step).round() * step
			if gp.distance_to(p) <= r * 0.5 and _project(first.ln, gp).distance_to(gp) < 1e-3: p = gp
		out.p = p
		out.kind = str(first.ln.kind)
		out.guides = guides
		out.label = label
		return out
	# 8: the grid
	var step: float = opts.get("grid", 0.0)
	if step > 0.0:
		out.p = (cur / step).round() * step
		out.kind = "grid"
	return out

## Guide lines: {kind, o (a point on it), d (its direction, unit), from_o (true: it starts at o, a ray)}
static func _guides(g, cur: Vector2, opts: Dictionary, skip_node: int, skip_edges: Array) -> Array:
	var out: Array = []
	var from: Array = opts.get("from", [])
	var from_node: int = opts.get("from_node", -1)
	var reach: float = maxf(float(opts.get("radius", 0.3)) * 12.0, 3.0)      # how near a wall must be to offer a guide
	# 4: straight on out of the node drawn from
	if from_node >= 0 and g.nodes.has(from_node):
		var at: Vector2 = g.pos(from_node)
		for e in g.edges_at(from_node):
			if e in skip_edges: continue
			var cv: Dictionary = g.curve_of(e) if g.edges[e].a == from_node else Geom.reversed(g.curve_of(e))
			out.append({"kind": "tangent", "o": at, "d": -Geom.tangent(cv, 0.0), "ray": true})
	# 5: square to / in line with the walls nearest the cursor, from each anchor
	if not from.is_empty():
		var walls: Array = []
		for e in g.edges:
			if e in skip_edges or not g.box_of(e, reach).has_point(cur): continue
			var c := Geom.closest(g.curve_of(e), cur)
			if c.d <= reach: walls.append([e, c])
		walls.sort_custom(func(x, y): return x[1].d < y[1].d)
		for w: Array in walls.slice(0, NEAR_WALLS):
			var cv: Dictionary = g.curve_of(w[0])
			var d := Geom.tangent(cv, w[1].t)
			for a: Vector2 in from:
				out.append({"kind": "parallel", "o": a, "d": d, "ray": false, "ref": w[1].p})
				out.append({"kind": "perp", "o": a, "d": Vector2(-d.y, d.x), "ray": false, "ref": w[1].p})
	# 6: on along past the ends of walls near the cursor
	for n in g.nodes:
		if n == skip_node: continue
		var at: Vector2 = g.pos(n)
		if at.distance_to(cur) > reach: continue
		for e in g.edges_at(n):
			if e in skip_edges: continue
			var cv: Dictionary = g.curve_of(e) if g.edges[e].a == n else Geom.reversed(g.curve_of(e))
			out.append({"kind": "extend", "o": at, "d": -Geom.tangent(cv, 0.0), "ray": true})
	# 7: whole angle steps from each anchor
	var step := deg_to_rad(float(opts.get("angle_step", 15.0)))
	if step > 0.0:
		for a: Vector2 in from:
			var v := cur - a
			if v.length() < 1e-4: continue
			var ang := roundf(v.angle() / step) * step
			out.append({"kind": "angle", "o": a, "d": Vector2.from_angle(ang), "ray": true})
	return out

static func _project(ln: Dictionary, p: Vector2) -> Vector2:
	var o: Vector2 = ln.o
	var d: Vector2 = ln.d
	var t := (p - o).dot(d)
	if ln.ray: t = maxf(t, 0.0)
	return o + d * t

static func _cross(l1: Dictionary, l2: Dictionary):
	if absf((l1.d as Vector2).cross(l2.d)) < 1e-3: return null
	return Geometry2D.line_intersects_line(l1.o, l1.d, l2.o, l2.d)

static func _guide_of(ln: Dictionary, p: Vector2) -> Array:
	var o: Vector2 = ln.o
	if ln.has("ref"): return [ln.ref, p, o]          # square / in line: the wall it is taken from, and the line
	return [o, p]
