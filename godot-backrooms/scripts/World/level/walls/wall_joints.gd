extends RefCounted
## WALLS, layer 2: where walls meet. Pure 2D, no scene tree. From a wall graph (wall_graph.gd) it works out the
## plan of every wall, in metres (x = world x, y = world z), so that the walls of a floor tile the plan exactly:
## no gap, no overlap, at any junction.
##
## Each wall's two faces are its centre line offset left and right by its thickness on that side (an arc's are
## arcs round the same centre). At every node the walls on it are sorted round it by the way they leave, and the
## face of each that looks at the next one round is cut where it meets that one's face: a mitred corner (line /
## line, line / arc, arc / arc). An outside corner that would run out into a long spike (walls folding back on
## each other) is cut off square across instead: a bevel. Two walls carrying straight on are met square across.
##
## Where three or more walls meet (or a bevel was cut), the corners round the node make a little polygon of its
## own, the hub: it stands as tall as the tallest wall there, so a low wall butting onto a tall one leaves the
## tall one's face whole above it. Each wall's plan then runs from its corners at one end to its corners at the
## other: [its right face a->b, across its b end, its left face b->a, across its a end], anticlockwise in the
## plan's maths frame. A wall end with no other wall on it is cut square across (a cap).

const Geom := preload("wall_geom.gd")

const MITER_LIMIT := 3.0             # an outside corner further than this many thicknesses from the node is bevelled
const STRAIGHT_ON := 0.0035          # radians off straight under which two walls carry on in line (met square across)
const TOL := 0.01                    # metres: an arc's faces are never further than this off the true curve
const LOOK := 0.1                    # metres along a wall its direction from a node is read (tells tangent walls apart)

## The plan of every wall and hub of graph `g`. `cell`: metres a cell (node positions are cells). Returns
## {edges: {e: {poly, tags, right, left, rn, ln, cv, arc}}, hubs: {n: {poly, tags, edges, flat}}}:
##   poly   the outline (PackedVector2Array, anticlockwise), tags[i] what its side poly[i] -> poly[i + 1] is:
##          {k: "side" (a face), "cap" (a free end), "chord" (across a wall's end at a node), "wedge" (the outside
##          of a bevel, or the step where a thicker wall carries on from a thinner), n: the node, e: whose face
##          ("side": the wall, "chord" on a hub: the wall across it), s: "l" / "r" (a side's face), i: the point's
##          index on that face}
##   right / left   each face a -> b as points, rn / ln their outward normals (curved faces shade smooth)
##   flat   true when the hub has no area (two walls mitred end to end, or carrying straight on): no hub then,
##          the walls' own ends meet
static func solve(g, cell: float) -> Dictionary:
	var curves := {}
	for e in g.edges: curves[e] = g.curve_of(e, cell)
	# per node: the walls on it in order round it, and their corners
	var corner := {}                 # Vector2i(e, node) -> {"l": point on e's outgoing left face, "r": on its outgoing right}
	var hubs := {}
	for n in g.nodes:
		var v: Vector2 = g.pos(n) * cell
		var ends: Array = []
		for e in g.edges_at(n):
			var ed: Dictionary = g.edges[e]
			var from_a: bool = ed.a == n
			var cv: Dictionary = curves[e] if from_a else Geom.reversed(curves[e])
			var dir := Geom.tangent(cv, 0.0)
			var nrm := Vector2(-dir.y, dir.x)
			var wl: float = ed.tl if from_a else ed.tr
			var wr: float = ed.tr if from_a else ed.tl
			var len := maxf(Geom.length(cv), 1e-6)
			var look := (Geom.point(cv, minf(LOOK / len, 0.25)) - v).angle()
			ends.append({"e": e, "dir": dir, "wl": wl, "wr": wr, "pl": v + nrm * wl, "pr": v - nrm * wr, "ang": look,
				"left": Geom.offset(cv, wl), "right": Geom.offset(cv, -wr)})
		if ends.is_empty(): continue
		ends.sort_custom(func(x, y): return x.ang < y.ang)
		var k := ends.size()
		if k == 1:
			corner[Vector2i(ends[0].e, n)] = {"l": ends[0].pl, "r": ends[0].pr, "cap": true}
			continue
		var wedges: Array = []
		for i in k:
			var I: Dictionary = ends[i]
			var J: Dictionary = ends[(i + 1) % k]
			var delta := fposmod(J.ang - I.ang, TAU)
			if k == 2 and delta < 1e-9: delta = TAU
			var pi: Vector2 = I.pl
			var pj: Vector2 = J.pr
			var pts := [pi, pj]
			var e_hit = null
			if absf(delta - PI) > STRAIGHT_ON:
				e_hit = Geom.carrier_hits({"kind": Geom.LINE, "a": pi, "b": pi + I.dir}, {"kind": Geom.LINE, "a": pj, "b": pj + J.dir})
				e_hit = e_hit[0] if not e_hit.is_empty() else null
			if e_hit != null:
				var est: Vector2 = e_hit
				var c := est
				if I.left.kind == Geom.ARC or J.right.kind == Geom.ARC:
					var best := INF
					for h: Vector2 in Geom.carrier_hits(I.left, J.right):
						if h.distance_to(est) < best:
							best = h.distance_to(est)
							c = h
					if best > maxf(maxf(I.wl, J.wr) * 4.0, 0.05): c = est
				if delta > PI and c.distance_to(v) > MITER_LIMIT * maxf(maxf(I.wl, J.wr), 1e-3):
					pts = [pi, pj]                       # bevel: square across from each wall's own end
				else:
					pts = [c, c]
			I["lp"] = pts[0]
			J["rp"] = pts[1]
			wedges.append([i, (i + 1) % k])
		for en: Dictionary in ends:
			corner[Vector2i(en.e, n)] = {"l": en.lp, "r": en.rp, "cap": false}
		# the hub: round the node through every wall's corners
		var poly := PackedVector2Array()
		var tags: Array = []
		for i in k:
			var I: Dictionary = ends[i]
			var J: Dictionary = ends[(i + 1) % k]
			_push(poly, tags, I.lp, {"k": "wedge", "n": n, "e": -1})
			if (J.rp as Vector2).distance_to(I.lp) > 1e-6: _push(poly, tags, J.rp, {"k": "chord", "n": n, "e": J.e})
			else: tags[-1] = {"k": "chord", "n": n, "e": J.e}
		if poly.size() >= 2 and poly[0].distance_to(poly[-1]) < 1e-6:
			poly.remove_at(poly.size() - 1)
			tags.remove_at(tags.size() - 1)
		var ids: Array = ends.map(func(x): return x.e)
		hubs[n] = {"poly": poly, "tags": tags, "edges": ids, "flat": poly.size() < 3 or absf(Geom.area(poly)) < 1e-6}
	# per wall: its two faces between its corners, and its outline
	var out := {}
	for e in g.edges:
		var ed: Dictionary = g.edges[e]
		var cv: Dictionary = curves[e]
		var ca: Dictionary = corner[Vector2i(e, ed.a)]
		var cb: Dictionary = corner[Vector2i(e, ed.b)]
		# at a the wall's left is its outgoing left; at b it leaves the other way, so its left is the outgoing right
		var la: Vector2 = ca.l
		var ra: Vector2 = ca.r
		var lb: Vector2 = cb.r
		var rb: Vector2 = cb.l
		var arc: bool = cv.kind == Geom.ARC
		var n := Geom.pieces(cv.r, cv.sw, TOL, int(ed.get("segs", 0))) if arc else 1
		var left := _face(Geom.offset(cv, ed.tl), la, lb, n)
		var right := _face(Geom.offset(cv, -ed.tr), ra, rb, n)
		var ln := _normals(cv, left, 1.0)
		var rn := _normals(cv, right, -1.0)
		var poly := PackedVector2Array()
		var tags: Array = []
		for i in right.size() - 1: _push(poly, tags, right[i], {"k": "side", "e": e, "s": "r", "i": i})
		_push(poly, tags, right[-1], {"k": "cap" if cb.cap else "chord", "e": e, "n": ed.b})
		for i in range(left.size() - 1, 0, -1): _push(poly, tags, left[i], {"k": "side", "e": e, "s": "l", "i": i})
		_push(poly, tags, left[0], {"k": "cap" if ca.cap else "chord", "e": e, "n": ed.a})
		out[e] = {"poly": poly, "tags": tags, "left": left, "right": right, "ln": ln, "rn": rn, "cv": cv, "arc": arc}
	return {"edges": out, "hubs": hubs}

## Push point p (and the tag of the side that starts at it) unless it repeats the last one
static func _push(poly: PackedVector2Array, tags: Array, p: Vector2, tag: Dictionary) -> void:
	if not poly.is_empty() and poly[-1].distance_to(p) < 1e-6:
		tags[-1] = tag
		return
	poly.append(p)
	tags.append(tag)

## One face of a wall: the offset curve `off` from corner `p0` to corner `p1` (a->b), `n` pieces round an arc
static func _face(off: Dictionary, p0: Vector2, p1: Vector2, n: int) -> PackedVector2Array:
	var out := PackedVector2Array([p0])
	if off.kind == Geom.ARC and n > 1:
		var c: Vector2 = off.c
		var t0 := (p0 - c).angle()
		var t1 := (p1 - c).angle()
		var total: float = off.sw + Geom.wrap((t1 - t0) - off.sw)
		for i in range(1, n): out.append(c + Vector2.from_angle(t0 + total * i / n) * off.r)
	out.append(p1)
	return out

## Each point's outward normal on a face: `side` +1 the left face, -1 the right
static func _normals(cv: Dictionary, pts: PackedVector2Array, side: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		if cv.kind == Geom.LINE:
			out.append(Geom.normal(cv, 0.0) * side)
		else:
			out.append((p - (cv.c as Vector2)).normalized() * (-signf(cv.sw)) * side)
	return out
