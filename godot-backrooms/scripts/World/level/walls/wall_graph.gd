extends RefCounted
## WALLS, layer 1: the walls of one floor as a graph ("walls" in the .lvl, per floor). Pure data and edits, no
## scene tree: the game (level_data.gd) and the level editor (which loads this file from the game's folder) share it.
##
## A node is a point walls meet at: {p: Vector2 in cells (a cell's centre on a whole number, the frame "spawn"
## and the objects use), h: a height override in metres, 0 = none (kept for sloped tops, not built yet)}.
## An edge is one wall between two nodes, straight or an arc through both (wall_geom.gd): {a, b (node ids),
## bulge (the arc's sagitta in cells, + bends left of a->b), tl / tr (metres of wall left / right of the centre
## line), h (metres tall, 0 = up to the ceiling of the room it stands in), base (metres off the floor), mat_l /
## mat_r (a textures/pbr material per face, "" = the level's), segs (arc pieces, 0 = as many as it needs),
## cells (the grid cells it takes over the way a thin wall square on a cell does: level_data.gd), lock_len /
## lock_ang (its length / its direction stay as they are while other things move: drag_targets, translate)}.
## Every edge ends on shared nodes, so moving a node moves every wall on it, straight or curved, and nothing
## can come away from a corner.
##
## An edge's "ops" are the openings in it (doors, windows, doorways, arches: wall_openings.gd builds the hole,
## props/door.gd and props/window.gd what stands in it): [{kind, u (where its middle is along the centre line,
## 0 at a .. 1 at b), w (metres wide), h (metres tall), sill (metres off the floor), side ("l" / "r": the side a
## door swings to, the room side of a window onto the sky), hinge ("a" / "b": the jamb a door hangs on), and the
## kind's own settings (style, leaves, glass, sky, sun...)}]. They go with the wall wherever it goes: split, an
## opening keeps to the piece its middle is on; joined, both pieces' openings carry on in the one wall.

const Geom := preload("wall_geom.gd")

const CELL_M := 4.5                  # metres a cell (level_data.gd CELL): the openings are sized in metres
## Each kind of opening: its defaults, and whether you can walk through it (nav) / see and light through it
const OPENINGS := {
	"door": {"w": 1.12, "h": 2.19, "sill": 0.0, "style": "level", "leaves": 1, "walk": false, "see": true},
	"doorway": {"w": 1.2, "h": 2.4, "sill": 0.0, "walk": true, "see": true},
	"arch": {"w": 1.8, "h": 3.0, "sill": 0.0, "walk": true, "see": true},
	"window": {"w": 1.6, "h": 1.5, "sill": 0.9, "style": "pane", "glass": "sky", "panes": 3, "sky": "noon", "sun": 8.0,
		"sun_angle": 35.0, "walk": false, "see": false},
}
const OP_MIN_W := 0.3                # metres: the narrowest opening
const OP_GAP := 0.1                  # metres of wall kept between two openings, and between one and a corner

const DEFAULT_THICK := 0.3           # metres: the thin wall's thickness (object_types.json)
const SEE_OVER_H := 1.8              # level_data.gd SEE_OVER_H: a wall lower than this does not take a cell over
const EDGE_KEYS := ["tl", "tr", "h", "base", "mat_l", "mat_r", "segs", "lock_len", "lock_ang"]
const DEFAULTS := {"tl": DEFAULT_THICK * 0.5, "tr": DEFAULT_THICK * 0.5, "h": 0.0, "base": 0.0, "mat_l": "", "mat_r": "", "segs": 0,
	"lock_len": false, "lock_ang": false}
const STRAIGHT_ON := 0.9999          # cos of the angle under which two straight walls through a node are one line

var nodes := {}                      # int -> {"p": Vector2, "h": float}
var edges := {}                      # int -> {"a", "b", "bulge", EDGE_KEYS..., "cells": Array of [x, y]}
var next_id := 1

# ---------------------------------------------------------------- reading
func pos(n: int) -> Vector2:
	return nodes[n].p

func edges_at(n: int) -> Array:
	var out: Array = []
	for e in edges:
		if edges[e].a == n or edges[e].b == n: out.append(e)
	return out

func degree(n: int) -> int:
	return edges_at(n).size()

func other(e: int, n: int) -> int:
	return edges[e].b if edges[e].a == n else edges[e].a

## Edge `e`'s centre line (cells, times `scale`)
func curve_of(e: int, scale := 1.0) -> Dictionary:
	var ed: Dictionary = edges[e]
	return Geom.curve(pos(ed.a) * scale, pos(ed.b) * scale, float(ed.bulge) * scale)

func is_arc(e: int) -> bool:
	return curve_of(e).kind == Geom.ARC

func length_of(e: int) -> float:
	return Geom.length(curve_of(e))

## Edge `e`'s settings as seen walking it from node `from`: left / right (thickness, material) and the bulge
## swap round when that is its b end
func oriented(e: int, from: int) -> Dictionary:
	var ed: Dictionary = edges[e]
	var o := {}
	for k in EDGE_KEYS: o[k] = ed.get(k, DEFAULTS[k])
	o["bulge"] = ed.bulge
	o["ops"] = (ed.get("ops", []) as Array).duplicate(true)
	if from != ed.a:
		o["tl"] = ed.get("tr", DEFAULTS.tr)
		o["tr"] = ed.get("tl", DEFAULTS.tl)
		o["mat_l"] = ed.get("mat_r", "")
		o["mat_r"] = ed.get("mat_l", "")
		o["bulge"] = -float(ed.bulge)
		o["ops"] = flip_ops(o.ops)
	return o

# ---------------------------------------------------------------- openings
func ops_of(e: int) -> Array:
	return edges[e].get("ops", []) if edges.has(e) else []

## Openings as seen walking their wall the other way: their u from the other end, their sides swapped
static func flip_ops(ops: Array) -> Array:
	var out: Array = []
	for op: Dictionary in ops:
		var o := op.duplicate(true)
		o.u = 1.0 - float(op.get("u", 0.5))
		if o.has("side"): o.side = "r" if str(op.side) == "l" else "l"
		if o.has("hinge"): o.hinge = "b" if str(op.hinge) == "a" else "a"
		out.append(o)
	return out

## A new opening of `kind` (OPENINGS), its settings over the kind's defaults
static func new_opening(kind: String, u: float, settings := {}) -> Dictionary:
	var o := {"kind": kind, "u": u, "side": "l", "hinge": "a"}
	for k in OPENINGS.get(kind, {}):
		if k != "walk" and k != "see": o[k] = OPENINGS[kind][k]
	for k in settings: o[k] = settings[k]
	return o

## Can you walk / see through opening `op`?
static func op_walk(op: Dictionary) -> bool:
	return bool(OPENINGS.get(str(op.get("kind", "")), {}).get("walk", false))

static func op_see(op: Dictionary) -> bool:
	var k := str(op.get("kind", ""))
	if k == "window": return str(op.get("glass", "sky")) == "clear" or str(op.get("glass", "sky")) == "none"
	return bool(OPENINGS.get(k, {}).get("see", false))

## Where opening `op` of wall `e` runs along its centre line: [t0, t1] (parameters, 0 at a .. 1 at b)
func op_span(e: int, op: Dictionary) -> Vector2:
	var l := maxf(length_of(e) * CELL_M, 1e-6)
	var half := float(op.get("w", 1.0)) * 0.5 / l
	var u := float(op.get("u", 0.5))
	return Vector2(u - half, u + half)

## The u nearest `u` that opening `op` (w metres wide) can sit at on wall `e` clear of its ends (`margin` metres
## at each: the corners there) and of its other openings (all but number `skip`); NAN when it fits nowhere
func fit_opening(e: int, u: float, w: float, margin := OP_GAP, skip := -1) -> float:
	var l := length_of(e) * CELL_M
	if l < 1e-6: return NAN
	var half := (w * 0.5 + OP_GAP * 0.5) / l
	var lo := margin / l + w * 0.5 / l
	var hi := 1.0 - lo
	if lo > hi: return NAN
	var blocked: Array = []
	var ops := ops_of(e)
	for i in ops.size():
		if i == skip: continue
		var s := op_span(e, ops[i])
		blocked.append(Vector2(s.x - half - OP_GAP * 0.5 / l, s.y + half + OP_GAP * 0.5 / l))
	var cands: Array[float] = [clampf(u, lo, hi)]
	for b: Vector2 in blocked:
		cands.append(clampf(b.x, lo, hi))
		cands.append(clampf(b.y, lo, hi))
	var best := NAN
	for c: float in cands:
		var ok := true
		for b: Vector2 in blocked:
			if c > b.x + 1e-6 and c < b.y - 1e-6: ok = false
		if ok and (is_nan(best) or absf(c - u) < absf(best - u)): best = c
	return best

## The cells of wall `e`'s "cells" that an opening you walk through leaves open (the one its middle is nearest)
func open_cells(e: int) -> Array:
	var out: Array = []
	var cells: Array = edges[e].get("cells", [])
	if cells.is_empty(): return out
	var cv := curve_of(e)
	for op: Dictionary in ops_of(e):
		if not op_walk(op): continue
		var at := Geom.point(cv, float(op.get("u", 0.5)))
		var best = null
		var bd := INF
		for c in cells:
			var d := at.distance_to(Vector2(c[0], c[1]))
			if d < bd:
				bd = d
				best = c
		if best != null and bd < 0.75 and not out.has(best): out.append(best)
	return out

## Openings `ops` of a wall from 0 .. 1 made the openings of the stretch t0 .. t1 of it (those whose middle is
## on it), their u measured along that stretch
static func _ops_within(ops: Array, t0: float, t1: float, last: bool) -> Array:
	var out: Array = []
	for op: Dictionary in ops:
		var u := float(op.get("u", 0.5))
		if u < t0 or (u >= t1 and not last) or u > t1: continue
		var o := op.duplicate(true)
		o.u = (u - t0) / maxf(t1 - t0, 1e-9)
		out.append(o)
	return out

## Settings for a new edge: DEFAULTS, overridden by `props`
static func props_of(props: Dictionary) -> Dictionary:
	var o := {}
	for k in EDGE_KEYS: o[k] = props.get(k, DEFAULTS[k])
	return o

func box_of(e: int, grow := 0.0) -> Rect2:
	var cv := curve_of(e)
	var r: Rect2
	if cv.kind == Geom.LINE:
		r = Rect2(cv.a, Vector2.ZERO).expand(cv.b)
	else:
		r = Rect2(Geom.point(cv, 0.0), Vector2.ZERO)
		for i in 9: r = r.expand(Geom.point(cv, i / 8.0))
		r = r.grow(cv.r * (1.0 - cos(absf(cv.sw) / 16.0)))       # (the chords cut inside the arc a little)
	return r.grow(grow)

## The node within `tol` of `p` (the nearest), or -1
func node_near(p: Vector2, tol: float, skip := -1) -> int:
	var best := -1
	var bd := tol
	for n in nodes:
		if n == skip: continue
		var d: float = (nodes[n].p as Vector2).distance_to(p)
		if d <= bd:
			bd = d
			best = n
	return best

## The nearest wall to `p` within `tol`: {e, t, p, d}, or {} (edges in `skip` left out)
func edge_near(p: Vector2, tol: float, skip: Array = []) -> Dictionary:
	var best := {}
	for e in edges:
		if e in skip: continue
		if not box_of(e, tol).has_point(p): continue
		var c := Geom.closest(curve_of(e), p)
		if c.d <= tol and (best.is_empty() or c.d < best.d):
			best = c
			best["e"] = e
	return best

# ---------------------------------------------------------------- building
func add_node(p: Vector2) -> int:
	var id := next_id
	next_id += 1
	nodes[id] = {"p": p, "h": 0.0}
	return id

func add_edge(a: int, b: int, bulge := 0.0, props := {}) -> int:
	var id := next_id
	next_id += 1
	var ed := props_of(props)
	ed["a"] = a
	ed["b"] = b
	ed["bulge"] = bulge
	ed["cells"] = (props.get("cells", []) as Array).duplicate(true)
	ed["ops"] = (props.get("ops", []) as Array).duplicate(true)
	edges[id] = ed
	return id

## A wall from p to q (cells) that joins whatever it meets: an end on a node or within `tol` of one shares it,
## an end on another wall splits that wall there (a T), a crossing splits both (an X), and a stretch laid over an
## existing wall becomes that wall. Returns the edges the new wall ended up as.
func add_wall(p: Vector2, q: Vector2, bulge := 0.0, props := {}, tol := 0.02) -> Array:
	var na := node_near(p, tol)
	if na < 0: na = add_node(p)
	var nb := node_near(q, tol, na)
	if nb < 0:
		if pos(na).distance_to(q) <= tol: return []
		nb = add_node(q)
	# (an end that snapped onto a node keeps the curve's own sagitta: the arc is rebuilt between the real ends)
	var e := add_edge(na, nb, bulge, props)
	for f in edges_at(na):
		if f != e and _same_wall(f, e):          # laid right over a wall that is there: that wall, made the most of both
			_absorb_edge(f, e)
			return [f]
	return planarize([e], tol)

## Split edge `e` at the point of it nearest `p`; e keeps its a end, a new edge takes the rest. An arc's two
## halves stay on its circle. Returns the new node.
func split(e: int, p: Vector2) -> int:
	var ed: Dictionary = edges[e]
	var cv := curve_of(e)
	var t := clampf(Geom.param_of(cv, p), 0.0, 1.0)
	var at := Geom.point(cv, t)
	var n := add_node(at)
	var b: int = ed.b
	var pa := pos(ed.a)
	var pb := pos(b)
	var bulge2 := 0.0
	if cv.kind == Geom.ARC:
		ed.bulge = Geom.sagitta_of(pa, at, cv.sw * t)
		bulge2 = Geom.sagitta_of(at, pb, cv.sw * (1.0 - t))
	ed.b = n
	var props := {}
	for k in EDGE_KEYS: props[k] = ed.get(k, DEFAULTS[k])
	props["cells"] = ed.get("cells", [])
	var ops: Array = ed.get("ops", [])
	props["ops"] = _ops_within(ops, t, 1.0, true)
	ed["ops"] = _ops_within(ops, 0.0, t, false)
	add_edge(n, b, bulge2, props)
	return n

## Node `drop` becomes node `keep`: its walls are moved onto keep (one that would run from keep to keep is
## dropped), and two walls that now lie on top of each other become one
func merge_nodes(keep: int, drop: int) -> void:
	if keep == drop or not nodes.has(drop): return
	for e in edges.keys():
		var ed: Dictionary = edges[e]
		if ed.a == drop: ed.a = keep
		if ed.b == drop: ed.b = keep
		if ed.a == ed.b: edges.erase(e)
	nodes.erase(drop)
	dedupe_at(keep)

## Walls between the same two nodes along the same curve are one wall: the thicker, taller of them
func dedupe_at(n: int) -> void:
	var at := edges_at(n)
	for i in at.size():
		var e: int = at[i]
		if not edges.has(e): continue
		for j in range(i + 1, at.size()):
			var f: int = at[j]
			if not edges.has(f): continue
			if _same_wall(e, f): _absorb_edge(e, f)

func _same_wall(e: int, f: int) -> bool:
	var a: Dictionary = edges[e]
	var b: Dictionary = edges[f]
	if not ((a.a == b.a and a.b == b.b) or (a.a == b.b and a.b == b.a)): return false
	var fb: float = b.bulge if a.a == b.a else -float(b.bulge)
	var chord := pos(a.a).distance_to(pos(a.b))
	return absf(float(a.bulge) - fb) <= maxf(chord * 0.01, 1e-4)

## Edge f goes, e takes on the most of the two of them
func _absorb_edge(e: int, f: int) -> void:
	var a: Dictionary = edges[e]
	var o := oriented(f, a.a)
	a.tl = maxf(a.tl, o.tl)
	a.tr = maxf(a.tr, o.tr)
	a.h = 0.0 if (is_zero_approx(a.h) or is_zero_approx(o.h)) else maxf(a.h, o.h)
	a.base = minf(a.base, o.base)
	if a.mat_l == "": a.mat_l = o.mat_l
	if a.mat_r == "": a.mat_r = o.mat_r
	a.cells = _union_cells(a.get("cells", []), edges[f].get("cells", []))
	a.lock_len = bool(a.get("lock_len", false)) or bool(o.lock_len)
	a.lock_ang = bool(a.get("lock_ang", false)) or bool(o.lock_ang)
	var ops: Array = (a.get("ops", []) as Array).duplicate(true)
	for op: Dictionary in o.ops:
		var clash := false
		for k: Dictionary in ops:
			if absf(float(k.u) - float(op.u)) * length_of(e) * CELL_M < (float(k.w) + float(op.w)) * 0.5: clash = true
		if not clash: ops.append(op)
	a["ops"] = ops
	edges.erase(f)

static func _union_cells(x: Array, y: Array) -> Array:
	var out: Array = x.duplicate(true)
	for c in y:
		if not out.has(c): out.append(c)
	return out

## Make the walls in `work` join everything they touch: an end of another wall lying on one splits it (a T),
## an end of one lying on another wall splits that, two walls crossing split both (an X), and two walls laid
## along the same stretch become one. Returns the pieces the walls in `work` became.
func planarize(work: Array, tol := 0.02) -> Array:
	var mine := {}
	for e in work: mine[e] = true
	var queue: Array = work.duplicate()
	var guard := 0
	while not queue.is_empty() and guard < 20000:
		guard += 1
		var e: int = queue.pop_back()
		if not edges.has(e): continue
		var hit := _first_conflict(e, tol)
		if hit.is_empty(): continue
		match str(hit.kind):
			"node_on_e":                      # another wall's end lies along e: split e onto that node
				var n := split(e, hit.p)
				var piece := next_id - 1
				mine[piece] = true
				queue.append(piece)
				merge_nodes(hit.node, n)
			"end_on_f":                       # an end of e lies along f: split f there, e's end moved onto f
				var n := split(hit.f, hit.p)
				nodes[hit.node].p = pos(n)
				merge_nodes(hit.node, n)
			"cross":                          # e crosses f: both split, onto one node
				var n1 := split(hit.f, hit.p)
				var n2 := split(e, hit.p)
				var piece := next_id - 1
				mine[piece] = true
				queue.append(piece)
				merge_nodes(n1, n2)
		queue.append(e)
	var res: Array = []
	for k in mine:
		if edges.has(k): res.append(k)
	return res

func _first_conflict(e: int, tol: float) -> Dictionary:
	var ed: Dictionary = edges[e]
	var ce := curve_of(e)
	var box := box_of(e, tol)
	var ea := pos(ed.a)
	var eb := pos(ed.b)
	for f in edges:
		if f == e: continue
		var fd: Dictionary = edges[f]
		if not box.intersects(box_of(f, tol)): continue
		var cf := curve_of(f)
		var fa := pos(fd.a)
		var fb := pos(fd.b)
		for n: int in [fd.a, fd.b]:
			if n == ed.a or n == ed.b: continue
			var c := Geom.closest(ce, pos(n))
			if c.d <= tol and c.p.distance_to(ea) > tol and c.p.distance_to(eb) > tol:
				return {"kind": "node_on_e", "node": n, "p": c.p}
		for n: int in [ed.a, ed.b]:
			if n == fd.a or n == fd.b: continue
			var c := Geom.closest(cf, pos(n))
			if c.d <= tol and c.p.distance_to(fa) > tol and c.p.distance_to(fb) > tol:
				return {"kind": "end_on_f", "f": f, "node": n, "p": c.p}
		for h: Dictionary in Geom.hits(ce, cf):
			var p: Vector2 = h.p
			if p.distance_to(ea) <= tol or p.distance_to(eb) <= tol or p.distance_to(fa) <= tol or p.distance_to(fb) <= tol: continue
			return {"kind": "cross", "f": f, "p": p}
	return {}

# ---------------------------------------------------------------- editing
## Move a node: every wall on it follows (an arc keeps its sagitta, so it keeps its shape as it stretches)
func move_node(n: int, p: Vector2) -> void:
	nodes[n].p = p

## Where a dragged node comes to rest: onto a node within `tol` (they become one), else onto a wall within
## `tol` (it is split there, a T), and every wall on it is joined to whatever it now crosses. Returns the node.
func settle_node(n: int, tol := 0.02) -> int:
	var m := node_near(pos(n), tol, n)
	if m >= 0:
		merge_nodes(m, n)
		n = m
	else:
		var hit := edge_near(pos(n), tol, edges_at(n))
		if not hit.is_empty():
			var s := split(hit.e, hit.p)
			nodes[n].p = pos(s)
			merge_nodes(n, s)
	if nodes.has(n): planarize(edges_at(n), tol)
	return n

## Take wall `e` away, then tidy the nodes it ran between (tidy_node)
func delete_edge(e: int) -> void:
	if not edges.has(e): return
	var a: int = edges[e].a
	var b: int = edges[e].b
	edges.erase(e)
	tidy_node(a)
	if b != a: tidy_node(b)

## Take node `n` away with every wall on it, then tidy the nodes they ran to
func delete_node(n: int) -> void:
	if not nodes.has(n): return
	var ends: Array = []
	for e in edges_at(n):
		ends.append(other(e, n))
		edges.erase(e)
	nodes.erase(n)
	for m in ends:
		if nodes.has(m): tidy_node(m)

## A node nothing ends on goes. A node with two walls through it that are really one (straight on in line, or
## the same arc carrying on round its circle, built the same) goes too, the two walls joined into one.
func tidy_node(n: int) -> void:
	if not nodes.has(n): return
	var at := edges_at(n)
	if at.is_empty():
		nodes.erase(n)
		return
	if at.size() != 2: return
	var e1: int = at[0]
	var e2: int = at[1]
	var x := other(e1, n)
	var y := other(e2, n)
	if x == y or x == n or y == n: return
	var o1 := oriented(e1, x)                    # e1 walked x -> n
	var o2 := oriented(e2, n)                    # e2 walked n -> y
	for k in EDGE_KEYS:
		if typeof(o1[k]) == TYPE_FLOAT or typeof(o1[k]) == TYPE_INT:
			if absf(float(o1[k]) - float(o2[k])) > 1e-4: return
		elif str(o1[k]) != str(o2[k]): return
	var px := pos(x)
	var pn := pos(n)
	var py := pos(y)
	var c1 := Geom.curve(px, pn, o1.bulge)
	var c2 := Geom.curve(pn, py, o2.bulge)
	var bulge := 0.0
	if c1.kind == Geom.LINE and c2.kind == Geom.LINE:
		if (pn - px).normalized().dot((py - pn).normalized()) < STRAIGHT_ON: return
	elif c1.kind == Geom.ARC and c2.kind == Geom.ARC:
		if (c1.c as Vector2).distance_to(c2.c) > 1e-3 * maxf(c1.r, 1.0) or absf(c1.r - c2.r) > 1e-3 * maxf(c1.r, 1.0): return
		if signf(c1.sw) != signf(c2.sw) or absf(c1.sw + c2.sw) > TAU - 0.05: return
		bulge = Geom.sagitta_of(px, py, c1.sw + c2.sw)
	else:
		return
	var props := o1.duplicate()
	props["cells"] = _union_cells(edges[e1].get("cells", []), edges[e2].get("cells", []))
	var l1 := Geom.length(c1)
	var l2 := Geom.length(c2)
	var f1 := l1 / maxf(l1 + l2, 1e-9)
	var ops: Array = []
	for op: Dictionary in o1.ops:
		var k := op.duplicate(true)
		k.u = float(op.u) * f1
		ops.append(k)
	for op: Dictionary in o2.ops:
		var k := op.duplicate(true)
		k.u = f1 + float(op.u) * (1.0 - f1)
		ops.append(k)
	props["ops"] = ops
	edges.erase(e1)
	edges.erase(e2)
	nodes.erase(n)
	add_edge(x, y, bulge, props)

## The centre line of every wall as straight spans for the monsters' paths and sight (level_data.gd
## wall_segments / blocked_edges): [[a, b, half thickness, see over], ...] in cells. Each end is pulled in a
## hair (as the old wall objects' were), so a wall ending on a cell's centre line doesn't catch the cell links
## beside it. A wall lying wholly inside the cells it takes over adds nothing: those cells are walls already
## (`all`: it does, for whoever wants every wall, the editor's acoustics). The openings you walk through leave a
## gap (`sight`: the ones you see and light through too: a door, open or not, glass you see through).
func nav_spans(all := false, sight := false) -> Array:
	var out: Array = []
	for e in edges:
		var ed: Dictionary = edges[e]
		var cv := curve_of(e)
		var whole := Geom.polyline(cv, maxi(2, ceili(absf(cv.get("sw", 0.0)) / (PI / 12.0))))
		var cells: Array = ed.get("cells", [])
		if not cells.is_empty() and not all:
			var inside := true
			for p in whole:
				var hit := false
				for c in cells:
					if absf(p.x - c[0]) <= 0.52 and absf(p.y - c[1]) <= 0.52: hit = true
				if not hit: inside = false
			if inside: continue
		var low := float(ed.h) > 0.0 and float(ed.h) < SEE_OVER_H
		for r: Vector2 in _solid_runs(e, sight):
			var pts := _run_points(cv, r.x, r.y)
			if pts[0].distance_to(pts[-1]) < 0.03: continue
			pts[0] = pts[0].move_toward(pts[1], 0.01)
			pts[-1] = pts[-1].move_toward(pts[-2], 0.01)
			for i in pts.size() - 1: out.append([pts[i], pts[i + 1], maxf(float(ed.tl), float(ed.tr)), low])
	return out

## The stretches of wall `e` (t0 .. t1) between the openings you walk through (`sight`: see through)
func _solid_runs(e: int, sight: bool) -> Array:
	var gaps: Array = []
	for op: Dictionary in ops_of(e):
		if op_walk(op) or (sight and op_see(op)): gaps.append(op_span(e, op))
	gaps.sort_custom(func(x: Vector2, y: Vector2) -> bool: return x.x < y.x)
	var out: Array = []
	var t := 0.0
	for g: Vector2 in gaps:
		if g.x > t: out.append(Vector2(t, g.x))
		t = maxf(t, g.y)
	if t < 1.0: out.append(Vector2(t, 1.0))
	return out

static func _run_points(cv: Dictionary, t0: float, t1: float) -> PackedVector2Array:
	var n := 1 if cv.kind == Geom.LINE else maxi(1, ceili(absf(cv.sw) * (t1 - t0) / (PI / 12.0)))
	var out := PackedVector2Array()
	for i in n + 1: out.append(Geom.point(cv, lerpf(t0, t1, float(i) / n)))
	return out

## Lines `a` .. `b` - 1 (columns, or rows) cut out of the map: the nodes on them go with their walls, the
## nodes past them close up by b - a (a wall from one side to the other stays, shorter)
func cut_lines(columns: bool, a: int, b: int) -> void:
	var count := b - a
	for n in nodes.keys():
		if not nodes.has(n): continue
		var p: Vector2 = nodes[n].p
		var i := roundi(p.x if columns else p.y)
		if i >= a and i < b: delete_node(n)
	for n in nodes:
		var p: Vector2 = nodes[n].p
		if roundi(p.x if columns else p.y) >= b: nodes[n].p = p - (Vector2(count, 0) if columns else Vector2(0, count))
	for e in edges:
		var kept: Array = []
		for c in edges[e].get("cells", []):
			var i := int(c[0]) if columns else int(c[1])
			if i >= a and i < b: continue
			if i >= b: kept.append([int(c[0]) - count, int(c[1])] if columns else [int(c[0]), int(c[1]) - count])
			else: kept.append(c)
		edges[e].cells = kept

## The walls with both ends in `box` (cells, rounded to the cell they are on), as [a, b, bulge, settings] with
## the ends made relative to `origin`: what the editor copies with an area
func walls_in(box: Rect2i, origin: Vector2) -> Array:
	var out: Array = []
	for e in edges:
		var ed: Dictionary = edges[e]
		var pa := pos(ed.a)
		var pb := pos(ed.b)
		if not (box.has_point(Vector2i(roundi(pa.x), roundi(pa.y))) and box.has_point(Vector2i(roundi(pb.x), roundi(pb.y)))): continue
		var props := oriented(e, ed.a)
		props["cells"] = (ed.get("cells", []) as Array).map(func(c): return [int(c[0]) - roundi(origin.x), int(c[1]) - roundi(origin.y)])
		out.append([pa - origin, pb - origin, float(ed.bulge), props])
	return out

# ---------------------------------------------------------------- moving with locks, exact sizes
## Where dragging node `n` to `p` puts the nodes: {node: position}. A wall on it with its length locked keeps
## the node on the circle round its other end, one with its direction locked on its line, one with both locked
## is rigid: its other end comes along (and on through any rigid walls from there). Several at once: the point
## that keeps them all, or where the node is when none does.
func drag_targets(n: int, p: Vector2) -> Dictionary:
	var cur := pos(n)
	var lines: Array = []                # [a point, a direction]
	var circles: Array = []              # [centre, radius]
	for e in edges_at(n):
		var ed: Dictionary = edges[e]
		var ll := bool(ed.get("lock_len", false))
		var la := bool(ed.get("lock_ang", false))
		if ll and la: continue
		var c := pos(other(e, n))
		if la and cur.distance_to(c) > 1e-6: lines.append([c, (cur - c).normalized()])
		elif ll: circles.append([c, cur.distance_to(c)])
	var t := p
	var cands: Array = []
	if lines.size() + circles.size() == 1:
		if lines.size() == 1: t = _on_line(lines[0], p)
		else: t = _on_circle(circles[0], p)
	elif lines.size() + circles.size() > 1:
		# where the first two meet (nearest the mouse), if the rest hold there too
		var shapes: Array = lines.map(func(l): return {"kind": Geom.LINE, "a": l[0], "b": (l[0] as Vector2) + (l[1] as Vector2)})
		shapes.append_array(circles.map(func(c): return {"kind": Geom.ARC, "c": c[0], "r": c[1], "a0": 0.0, "sw": TAU}))
		cands = Geom.carrier_hits(shapes[0], shapes[1])
		t = cur
		var best := INF
		for h: Vector2 in cands:
			var ok := true
			for l: Array in lines:
				if _on_line(l, h).distance_to(h) > 1e-4: ok = false
			for c: Array in circles:
				if absf(h.distance_to(c[0]) - float(c[1])) > 1e-4: ok = false
			if ok and h.distance_to(p) < best:
				best = h.distance_to(p)
				t = h
	var out := {n: t}
	var d := t - cur
	for m in _rigid_from([n], true):
		if m != n: out[m] = pos(m) + d
	return out

static func _on_line(l: Array, p: Vector2) -> Vector2:
	var o: Vector2 = l[0]
	var d: Vector2 = l[1]
	return o + d * (p - o).dot(d)

static func _on_circle(c: Array, p: Vector2) -> Vector2:
	var o: Vector2 = c[0]
	var v := p - o
	return o + (v.normalized() if v.length() > 1e-6 else Vector2.RIGHT) * float(c[1])

## The nodes moved along with `from`: through walls with both locks (`full_only`), or through any locked wall
func _rigid_from(from: Array, full_only: bool) -> Array:
	var seen := {}
	var queue: Array = from.duplicate()
	while not queue.is_empty():
		var n: int = queue.pop_back()
		if seen.has(n): continue
		seen[n] = true
		for e in edges_at(n):
			var ed: Dictionary = edges[e]
			var ll := bool(ed.get("lock_len", false))
			var la := bool(ed.get("lock_ang", false))
			if (ll and la) if full_only else (ll or la): queue.append(other(e, n))
	return seen.keys()

func move_nodes(moves: Dictionary) -> void:
	for n in moves:
		if nodes.has(n): nodes[n].p = moves[n]

## Move nodes `ns` by `d`; a locked wall on any of them comes along whole (and on from its other end), so no
## locked wall stretches or turns. Returns the nodes moved.
func translate(ns: Array, d: Vector2) -> Array:
	var moved := _rigid_from(ns, false)
	for n in moved: nodes[n].p += d
	return moved

## Slide wall `e` sideways by `dist` cells (+ to its left): both its ends move, the walls on them stretch to follow
func slide(e: int, dist: float) -> void:
	var a := pos(edges[e].a)
	var b := pos(edges[e].b)
	var d := (b - a).normalized()
	translate([edges[e].a, edges[e].b], Vector2(-d.y, d.x) * dist)

## Wall `e` made `len` cells long along its curve: its `keep` end stays, the other moves along the chord (an arc
## keeps its sweep, so its shape)
func set_length(e: int, len: float, keep: int) -> void:
	var ed: Dictionary = edges[e]
	var cv := curve_of(e)
	var far := other(e, keep)
	var a := pos(keep)
	var b := pos(far)
	if a.distance_to(b) < 1e-6 or len <= 0.0: return
	var sw: float = cv.get("sw", 0.0)
	var chord := len if absf(sw) < 1e-6 else len * 2.0 * sin(absf(sw) * 0.5) / absf(sw)
	nodes[far].p = a + (b - a).normalized() * chord
	ed.bulge = Geom.sagitta_of(pos(ed.a), pos(ed.b), sw)

## Wall `e` turned about its `keep` end so it runs at `ang` radians (maths frame), keep -> the other end
func set_angle(e: int, ang: float, keep: int) -> void:
	var far := other(e, keep)
	var a := pos(keep)
	var to := a + Vector2.from_angle(ang) * a.distance_to(pos(far))
	nodes[far].p = to

## Wall `e` bent round a circle of radius `r` cells, to the side it bends now (left when straight), keeping to the
## bigger part of the circle if it is on it now. 0 straightens it; under half its chord is a half circle.
func set_radius(e: int, r: float) -> void:
	var ed: Dictionary = edges[e]
	var c := pos(ed.a).distance_to(pos(ed.b))
	if r <= 0.0:
		ed.bulge = 0.0
		return
	r = maxf(r, c * 0.5)
	var side := signf(ed.bulge) if absf(float(ed.bulge)) > 1e-6 else 1.0
	var major := absf(float(ed.bulge)) > c * 0.5
	var h := sqrt(maxf(r * r - c * c * 0.25, 0.0))
	ed.bulge = side * (r + h if major else r - h)

func _locked(e: int) -> bool:
	return bool(edges[e].get("lock_len", false)) or bool(edges[e].get("lock_ang", false))

## The walls `es` as [a, b, bulge, settings], ends relative to `origin` (what the editor copies)
func walls_of(es: Array, origin: Vector2) -> Array:
	var out: Array = []
	for e in es:
		if not edges.has(e): continue
		var ed: Dictionary = edges[e]
		var props := oriented(e, ed.a)
		props["cells"] = (ed.get("cells", []) as Array).map(func(c): return [int(c[0]) - roundi(origin.x), int(c[1]) - roundi(origin.y)])
		out.append([pos(ed.a) - origin, pos(ed.b) - origin, float(ed.bulge), props])
	return out

## Every node moved by `off` (the map grew / was trimmed); then every node outside 0..`size`-1 goes with its walls
func shift(off: Vector2, size: int) -> void:
	for n in nodes: nodes[n].p += off
	for n in nodes.keys():
		var p: Vector2 = nodes[n].p
		if p.x < -0.5 or p.y < -0.5 or p.x > size - 0.5 or p.y > size - 0.5: delete_node(n)
	for e in edges:
		var kept: Array = []
		for c in edges[e].get("cells", []):
			var v := Vector2i(int(c[0]) + roundi(off.x), int(c[1]) + roundi(off.y))
			if v.x > 0 and v.y > 0 and v.x < size - 1 and v.y < size - 1: kept.append([v.x, v.y])
		edges[e].cells = kept

# ---------------------------------------------------------------- saving
func to_dict() -> Dictionary:
	var ns: Array = []
	var ids := nodes.keys()
	ids.sort()
	for n in ids:
		var p: Vector2 = nodes[n].p
		var o := {"id": n, "x": snappedf(p.x, 0.0001), "y": snappedf(p.y, 0.0001)}
		if float(nodes[n].h) > 0.0: o["h"] = snappedf(nodes[n].h, 0.001)
		ns.append(o)
	var es: Array = []
	ids = edges.keys()
	ids.sort()
	for e in ids:
		var ed: Dictionary = edges[e]
		var o := {"id": e, "a": ed.a, "b": ed.b, "bulge": snappedf(ed.bulge, 0.0001), "tl": snappedf(ed.tl, 0.0001),
			"tr": snappedf(ed.tr, 0.0001), "h": snappedf(ed.h, 0.001)}
		if float(ed.base) > 0.0: o["base"] = snappedf(ed.base, 0.001)
		if str(ed.mat_l) != "": o["mat_l"] = ed.mat_l
		if str(ed.mat_r) != "": o["mat_r"] = ed.mat_r
		if int(ed.segs) > 0: o["segs"] = int(ed.segs)
		if not (ed.get("cells", []) as Array).is_empty(): o["cells"] = ed.cells
		if bool(ed.get("lock_len", false)): o["lock_len"] = true
		if bool(ed.get("lock_ang", false)): o["lock_ang"] = true
		if not (ed.get("ops", []) as Array).is_empty():
			o["ops"] = (ed.ops as Array).map(func(op: Dictionary) -> Dictionary:
				var k := {}
				for key in op: k[key] = float(op[key]) if op[key] is int else op[key]     # (as they come back from JSON)
				k.u = snappedf(float(op.u), 0.00001)
				return k)
		es.append(o)
	return {"nodes": ns, "edges": es}

## Fill this (empty) graph from a saved "walls" entry (to_dict())
func load_dict(d) -> void:
	if not (d is Dictionary): return
	for o in d.get("nodes", []):
		if not (o is Dictionary): continue
		var id := int(o.get("id", 0))
		nodes[id] = {"p": Vector2(float(o.get("x", 0.0)), float(o.get("y", 0.0))), "h": float(o.get("h", 0.0))}
		next_id = maxi(next_id, id + 1)
	for o in d.get("edges", []):
		if not (o is Dictionary): continue
		var id := int(o.get("id", 0))
		var a := int(o.get("a", -1))
		var b := int(o.get("b", -1))
		if not (nodes.has(a) and nodes.has(b)) or a == b: continue
		var ed := {"a": a, "b": b, "bulge": float(o.get("bulge", 0.0))}
		for k in EDGE_KEYS:
			var v = o.get(k, DEFAULTS[k])
			if DEFAULTS[k] is bool: ed[k] = bool(v)
			elif k == "segs": ed[k] = int(v)
			else: ed[k] = str(v) if DEFAULTS[k] is String else float(v)
		var cells: Array = []
		for c in o.get("cells", []):
			if c is Array and c.size() >= 2: cells.append([int(c[0]), int(c[1])])
		ed["cells"] = cells
		var ops: Array = []
		for op in o.get("ops", []):
			if op is Dictionary and OPENINGS.has(str(op.get("kind", ""))):
				ops.append(new_opening(str(op.kind), float(op.get("u", 0.5)), op))
		ed["ops"] = ops
		edges[id] = ed
		next_id = maxi(next_id, id + 1)
	# a node no wall ends on is nothing
	for n in nodes.keys():
		if edges_at(n).is_empty(): nodes.erase(n)

func duplicate_graph() -> RefCounted:
	var g = get_script().new()
	for n in nodes: g.nodes[n] = (nodes[n] as Dictionary).duplicate(true)
	for e in edges: g.edges[e] = (edges[e] as Dictionary).duplicate(true)
	g.next_id = next_id
	return g

func is_empty() -> bool:
	return edges.is_empty() and nodes.is_empty()

# ---------------------------------------------------------------- old wall objects
## Turn the wall objects of a floor (object_types.json "shape" slab, corner, arc, and straight spline walls) into
## edges of this graph, ends within `tol` cells of each other joined into one node, an end on another wall a T, a
## crossing an X. A thin wall square on a cell keeps the cell it took over (its edges' "cells"). Smooth spline
## walls stay objects (they are no arcs). `types`: object_types.json. Returns the objects that are left.
func absorb(objects: Array, types: Dictionary, size: int, tol := 0.1 / 4.5) -> Array:
	var kept: Array = []
	for o in objects:
		if not (o is Dictionary):
			kept.append(o)
			continue
		var info: Dictionary = types.get(str(o.get("type", "")), {})
		var shape := str(info.get("shape", ""))
		if str(o.get("type", "")) == "door":
			_absorb_door(o, info, size, tol)
			continue
		if shape not in ["slab", "corner", "arc", "spline"] or info.has("model"):
			kept.append(o)
			continue
		var params: Dictionary = info.get("params", {})
		var thick := float(o.get("thick", params.get("thick", info.get("thickness", DEFAULT_THICK))))
		var h := float(o.get("height", params.get("height", 0.0)))
		var props := {"tl": thick * 0.5, "tr": thick * 0.5, "h": h}
		var at := Vector2(float(o.get("pos_x", 0.0)), float(o.get("pos_y", 0.0)))
		var rot := deg_to_rad(float(o.get("rotation", 0.0)))
		var s := float(o.get("scale", 1.0))
		var cap := float(info.get("max_scale", 4.0))
		s = clampf(s, 0.5, cap)
		var xf := func(v: Vector2) -> Vector2: return at + v.rotated(rot)
		var c := Vector2i(roundi(at.x), roundi(at.y))
		var centred := absf(at.x - c.x) <= 0.26 and absf(at.y - c.y) <= 0.26
		var inside := c.x > 0 and c.y > 0 and c.x < size - 1 and c.y < size - 1
		var low := h > 0.0 and h < SEE_OVER_H
		if centred and inside and not low and str(info.get("on_cell", "")) == "wall":
			props["cells"] = [[c.x, c.y]]
		match shape:
			"slab":
				add_wall(xf.call(Vector2(0, -s * 0.5)), xf.call(Vector2(0, s * 0.5)), 0.0, props, tol)
			"corner":
				add_wall(xf.call(Vector2(s, 0)), xf.call(Vector2.ZERO), 0.0, props, tol)
				add_wall(xf.call(Vector2.ZERO), xf.call(Vector2(0, s)), 0.0, props, tol)
			"arc":
				var arc := deg_to_rad(clampf(float(o.get("arc", params.get("arc", 90.0))), 5.0, 360.0))
				var r := s * 0.5
				var spans := [[-arc * 0.5, arc * 0.5]] if arc < TAU - 0.001 else [[0.0, PI], [PI, TAU]]
				for sp: Array in spans:
					var p0: Vector2 = xf.call(Vector2.from_angle(sp[0]) * r)
					var p1: Vector2 = xf.call(Vector2.from_angle(sp[1]) * r)
					add_wall(p0, p1, Geom.sagitta_of(p0, p1, sp[1] - sp[0]), props, tol)
			"spline":
				var pts: Array[Vector2] = []
				var raw = o.get("points", [])
				if raw is Array:
					for q in raw:
						if q is Array and q.size() >= 2:
							var v := Vector2(float(q[0]), float(q[1]))
							if pts.is_empty() or pts[-1].distance_to(v) > 0.01: pts.append(v)
				var closed := bool(o.get("closed", false)) and pts.size() >= 3
				if closed and pts[0].distance_to(pts[-1]) < 0.01: pts.remove_at(pts.size() - 1)
				# a smooth spline through three or more points is a curve this graph can't hold: it stays an object
				if pts.size() < 2 or (bool(o.get("smooth", true)) and pts.size() >= 3):
					kept.append(o)
					continue
				for i in pts.size() - 1:
					add_wall(xf.call(pts[i]), xf.call(pts[i + 1]), 0.0, props, tol)
				if closed: add_wall(xf.call(pts[-1]), xf.call(pts[0]), 0.0, props, tol)
	# windows hung on a wall of the graph go into it (on the grid's block walls they stay as they were)
	var left: Array = []
	for o in kept:
		if not (o is Dictionary and str(types.get(str(o.get("type", "")), {}).get("shape", "")) == "window" and _absorb_window(o)):
			left.append(o)
	return left

## An old door object (a thin wall across its cells with a door in its middle): the same wall, the door in it
func _absorb_door(o: Dictionary, info: Dictionary, size: int, tol: float) -> void:
	var at := Vector2(float(o.get("pos_x", 0.0)), float(o.get("pos_y", 0.0)))
	var rot := deg_to_rad(float(o.get("rotation", 0.0)))
	var s := clampf(float(o.get("scale", 1.0)), 0.5, 4.0)
	var thick := float(info.get("thickness", DEFAULT_THICK))
	var props := {"tl": thick * 0.5, "tr": thick * 0.5, "h": 0.0}
	var c := Vector2i(roundi(at.x), roundi(at.y))
	if absf(at.x - c.x) <= 0.26 and absf(at.y - c.y) <= 0.26 and c.x > 0 and c.y > 0 and c.x < size - 1 and c.y < size - 1:
		props["cells"] = [[c.x, c.y]]
	var p := at + Vector2(0, -s * 0.5).rotated(rot)
	var q := at + Vector2(0, s * 0.5).rotated(rot)
	add_wall(p, q, 0.0, props, tol)
	# (the old door's leaf hung on its -z jamb, the p end, and swung away from whoever opened it)
	var hit := edge_near(at, 0.05)
	if hit.is_empty(): return
	var e: int = hit.e
	var near_a := pos(edges[e].a).distance_to(p) < pos(edges[e].a).distance_to(q)
	var w := float(info.get("opening", OPENINGS.door.w))
	var fit := fit_opening(e, float(hit.t), w)
	if is_nan(fit): return
	var settings := {"w": w, "hinge": "a" if near_a else "b", "style": str(o.get("leaf", "wood"))}
	edges[e].ops.append(new_opening("door", fit, settings))

## An old window object on a wall of the graph: its back on a face of the wall, its arrow (+x) into the room.
## False if there is no wall of the graph under it.
func _absorb_window(o: Dictionary) -> bool:
	var at := Vector2(float(o.get("pos_x", 0.0)), float(o.get("pos_y", 0.0)))
	var rot := deg_to_rad(float(o.get("rotation", 0.0)))
	var into := Vector2(1, 0).rotated(rot)
	var hit := edge_near(at - into * 0.04, 0.12)
	if hit.is_empty(): return false
	var e: int = hit.e
	var cv := curve_of(e)
	var t := float(hit.t)
	var facing := Geom.normal(cv, t).dot(into)
	if absf(facing) < 0.7: return false
	var w := clampf(float(o.get("scale", 0.5)) * CELL_M, OP_MIN_W, 30.0)
	var fit := fit_opening(e, t, w)
	if is_nan(fit): return false
	var settings := {"w": w, "side": "l" if facing > 0.0 else "r", "glass": "sky"}
	for k in ["panes", "sky", "sun", "sun_angle", "shadows"]:
		if o.has(k): settings[k] = o[k]
	if o.has("frame"): settings["style"] = o.frame
	settings["sill"] = maxf(0.0, float(o.get("elev", OPENINGS.window.sill)))
	settings["h"] = float(o.height) if float(o.get("height", 0.0)) > 0.0 else 2.2
	edges[e].ops.append(new_opening("window", fit, settings))
	return true
