extends RefCounted
## WALLS, layer 3: the plan from wall_joints.gd stood up into meshes. Pure (SurfaceTool and ArrayMesh are no
## nodes): the game builds its walls with it, the level editor its 3D preview, tools/test_walls.gd checks it.
##
## Every wall stands from its base to its top over its own plan, a hub as tall as the tallest wall on it. A side
## two plans share is only built where one of them stands and the other doesn't (a tall wall's face over a low
## one, the strip under a wall lifted off the floor), so no two faces ever lie on top of each other. Tops are
## capped, and the underside of a lifted wall too.
##
## Wallpaper: every face at the foot of the walls is chained to the next one round the outline of the walls (a
## room's inside, the outside of a run), and u is the distance along that chain, so the paper runs on unbroken
## round corners, along curves and from one wall into the next. A closed chain is fitted to a whole number of
## repeats, so it has no seam where it meets itself. v is the height off the floor. Both in metres (the wall
## materials are scaled per metre: level_geometry.gd _wall_uv_mat).
##
## Openings (wall_openings.gd holes): the faces are cut round each hole after the wallpaper is laid out, so the
## paper runs on across an opening as if it had never been cut; the hole is lined (its jambs square across the
## wall, its head following a round top, its sill), a recess cut into one face only is backed, and the wall's
## solid is cut there too (not under glass). The skirting stops at a door: its chain of faces is broken there.

const Geom := preload("wall_geom.gd")
const Openings := preload("wall_openings.gd")

const GROUND := 1e-4
const EDGE_GAP := 0.05               # metres of wall an opening keeps from the corner at either end at least
const ROUND_STEPS := 16              # pieces a round head is built in

## `sol`: wall_joints.gd solve(). `spans`: wall id -> Vector2(base, top), metres. `keys`: wall id ->
## {"l", "r", "cap"}: which mesh (material) its left face, right face and the rest go in. `rep`: metres one
## repeat of the wallpaper runs. `meshes`: false to work out only the faces, chains and solids. `holes`:
## wall_openings.gd holes_of().
## Returns {meshes: {key: ArrayMesh}, pieces: [{p, q, y0, y1, own (wall id, -1 a hub), key}], loops: [{pts,
## closed, inward}] (the foot of the walls, for skirting), solids: [{poly, base, top}] (for collision), holes:
## {wall id: [hole as cut (fitted between the corners), with ts (parameters across it), l / r (the left / right
## face's points there)]}, reveals: [the faces lining the holes]}
static func build(sol: Dictionary, spans: Dictionary, keys: Dictionary, rep := 2.25, meshes := true, holes := {}) -> Dictionary:
	var pieces: Array = []
	var hub_span := {}               # node -> [the height spans the hub stands over (its walls', joined), its tallest wall]
	for n in sol.hubs:
		var hub: Dictionary = sol.hubs[n]
		var hi := -INF
		var tallest := -1
		var list: Array = []
		for e in hub.edges:
			var s: Vector2 = spans[e]
			list.append(s)
			if s.y > hi:
				hi = s.y
				tallest = e
		hub_span[n] = [_union(list), tallest]
	# the walls' own faces and free ends
	for e in sol.edges:
		var w: Dictionary = sol.edges[e]
		var sp: Vector2 = spans[e]
		var poly: PackedVector2Array = w.poly
		for i in poly.size():
			var t: Dictionary = w.tags[i]
			var p := poly[i]
			var q := poly[(i + 1) % poly.size()]
			if p.distance_to(q) < 1e-6: continue
			match str(t.k):
				"side":
					var nr: PackedVector2Array = w.ln if t.s == "l" else w.rn
					var j: int = t.i - 1 if t.s == "l" else t.i + 1
					var smooth: bool = w.arc
					var pc := _piece(p, q, sp, nr[t.i] if smooth else null, nr[j] if smooth else null, keys[e][t.s], e)
					pc.side = t.s
					pieces.append(pc)
				"cap":
					pieces.append(_piece(p, q, sp, null, null, keys[e].cap, e))
	# where walls meet with no hub between them, their ends face each other
	for n in sol.hubs:
		var hub: Dictionary = sol.hubs[n]
		if not hub.flat: continue
		var chords: Array = []
		for e in hub.edges:
			var w: Dictionary = sol.edges[e]
			for i in w.poly.size():
				var t: Dictionary = w.tags[i]
				if t.k == "chord" and t.n == n:
					chords.append([e, w.poly[i], w.poly[(i + 1) % w.poly.size()]])
		for c: Array in chords: _chord_pieces(c, chords, spans, keys, pieces)
	# hubs: the outside of a bevel or a step, and their faces over / under a lower wall on them
	for n in sol.hubs:
		var hub: Dictionary = sol.hubs[n]
		if hub.flat: continue
		var key: String = keys[hub_span[n][1]].cap
		var poly: PackedVector2Array = hub.poly
		for i in poly.size():
			var t: Dictionary = hub.tags[i]
			var p := poly[i]
			var q := poly[(i + 1) % poly.size()]
			if p.distance_to(q) < 1e-6: continue
			for hs: Vector2 in hub_span[n][0]:
				if t.k == "wedge":
					pieces.append(_piece(p, q, hs, null, null, key, -1))
				else:
					for y: Vector2 in _minus(hs, [spans[t.e]]):
						pieces.append(_piece(p, q, y, null, null, key, -1))
	var loops := _chain(pieces, rep)
	var cut := {}
	var reveals: Array = []
	if not holes.is_empty():
		cut = _fit_holes(sol, holes)
		pieces = _cut(sol, cut, pieces)
		reveals = _reveals(sol, spans, keys, cut)
		loops = _chain(pieces, rep, false)
	var out := {"pieces": pieces, "loops": loops, "solids": _solids(sol, spans, hub_span, cut), "meshes": {}, "holes": cut,
		"reveals": reveals}
	if meshes: out.meshes = _meshes(sol, spans, keys, hub_span, pieces, reveals)
	return out

## (y0q / y1q: the bottom / top at q, where a face under a round head slopes; side: the wall face it is, "" none)
static func _piece(p: Vector2, q: Vector2, y: Vector2, np, nq, key: String, own: int) -> Dictionary:
	return {"p": p, "q": q, "y0": y.x, "y1": y.y, "y0q": y.x, "y1q": y.y, "np": np, "nq": nq, "key": key, "own": own,
		"u0": 0.0, "u1": 0.0, "loop": false, "side": ""}

## Height spans joined where they touch or overlap, lowest first
static func _union(list: Array) -> Array:
	var s := list.duplicate()
	s.sort_custom(func(x: Vector2, y: Vector2) -> bool: return x.x < y.x)
	var out: Array = []
	for v: Vector2 in s:
		if not out.is_empty() and v.x <= (out[-1] as Vector2).y + 1e-5:
			out[-1] = Vector2((out[-1] as Vector2).x, maxf((out[-1] as Vector2).y, v.y))
		else:
			out.append(v)
	return out

## Height span `a` less every span in `cut`
static func _minus(a: Vector2, cut: Array) -> Array:
	var cur: Array = [a]
	for b: Vector2 in cut:
		var nxt: Array = []
		for x: Vector2 in cur:
			if b.y <= x.x or b.x >= x.y:
				nxt.append(x)
				continue
			if b.x > x.x: nxt.append(Vector2(x.x, b.x))
			if b.y < x.y: nxt.append(Vector2(b.y, x.y))
		cur = nxt
	return cur.filter(func(x: Vector2) -> bool: return x.y - x.x > 1e-5)

## Wall c's end [e, p, q] where it meets the other ends at a node with no hub: each stretch of it is built where
## the walls lying against that stretch don't stand (none: all of it, a step where a thicker wall carries on)
static func _chord_pieces(c: Array, all: Array, spans: Dictionary, keys: Dictionary, pieces: Array) -> void:
	var e: int = c[0]
	var p: Vector2 = c[1]
	var q: Vector2 = c[2]
	var l := p.distance_to(q)
	if l < 1e-6: return
	var d := (q - p) / l
	var nrm := Vector2(d.y, -d.x)
	var covers: Array = []
	var cuts: Array[float] = [0.0, l]
	for o: Array in all:
		if o[0] == e: continue
		if absf(((o[1] as Vector2) - p).dot(nrm)) > 1e-4 or absf(((o[2] as Vector2) - p).dot(nrm)) > 1e-4: continue
		var u0 := ((o[1] as Vector2) - p).dot(d)
		var u1 := ((o[2] as Vector2) - p).dot(d)
		var lo := clampf(minf(u0, u1), 0.0, l)
		var hi := clampf(maxf(u0, u1), 0.0, l)
		if hi - lo < 1e-6: continue
		covers.append([lo, hi, spans[o[0]]])
		cuts.append(lo)
		cuts.append(hi)
	cuts.sort()
	for i in cuts.size() - 1:
		var a := cuts[i]
		var b := cuts[i + 1]
		if b - a < 1e-6: continue
		var mid := (a + b) * 0.5
		var over: Array = []
		for cv: Array in covers:
			if mid > cv[0] and mid < cv[1]: over.append(cv[2])
		for y: Vector2 in _minus(spans[e], over):
			pieces.append(_piece(p + d * a, p + d * b, y, null, null, keys[e].cap, e))

## Chain the faces at the foot of the walls round the outlines and give every face its u (`assign`: false, only
## the chains). Returns the chains.
static func _chain(pieces: Array, rep: float, assign := true) -> Array:
	var by_start := {}
	var ground: Array = []
	for i in pieces.size():
		if pieces[i].y0 < GROUND:
			ground.append(i)
			by_start[_key(pieces[i].p)] = i
	# a chain that isn't closed is walked from its first face (none comes before it)
	var has_pred := {}
	for i: int in ground:
		var j = _find(by_start, pieces[i].q)
		if j != null and j != i: has_pred[j] = true
	var order: Array = ground.filter(func(i): return not has_pred.has(i))
	order.append_array(ground.filter(func(i): return has_pred.has(i)))
	var seen := {}
	var loops: Array = []
	var u_at := {}
	for i: int in order:
		if seen.has(i): continue
		var chain: Array = []
		var j = i
		while j != null and not seen.has(j):
			seen[j] = true
			chain.append(j)
			j = _find(by_start, pieces[j].q)
		var closed: bool = j == i
		if not assign:
			var pts0 := PackedVector2Array()
			for k: int in chain: pts0.append(pieces[k].p)
			if not closed: pts0.append(pieces[chain[-1]].q)
			loops.append({"pts": pts0, "closed": closed, "inward": closed and Geom.area(pts0) < 0.0})
			continue
		var total := 0.0
		for k: int in chain: total += (pieces[k].p as Vector2).distance_to(pieces[k].q)
		var fit := 1.0
		if closed and total > rep * 0.5: fit = maxf(1.0, roundf(total / rep)) * rep / total
		var s := 0.0
		var pts := PackedVector2Array()
		for k: int in chain:
			var pc: Dictionary = pieces[k]
			pc.u0 = -s * fit
			s += (pc.p as Vector2).distance_to(pc.q)
			pc.u1 = -s * fit
			pc.loop = true
			u_at[_key(pc.p)] = pc.u0
			pts.append(pc.p)
		if not closed: pts.append(pieces[chain[-1]].q)
		loops.append({"pts": pts, "closed": closed, "inward": closed and Geom.area(pts) < 0.0})
	if not assign: return loops
	# the faces up off the floor take the u of the foot of the wall under where they start
	for pc: Dictionary in pieces:
		if pc.loop: continue
		pc.u0 = u_at.get(_key(pc.p), 0.0)
		pc.u1 = pc.u0 - (pc.p as Vector2).distance_to(pc.q)
	return loops

static func _key(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x * 2000.0), roundi(p.y * 2000.0))

static func _find(by_start: Dictionary, p: Vector2):
	var k := _key(p)
	if by_start.has(k): return by_start[k]
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			var kk := k + Vector2i(dx, dy)
			if by_start.has(kk): return by_start[kk]
	return null

static func _solids(sol: Dictionary, spans: Dictionary, hub_span: Dictionary, cut := {}) -> Array:
	var out: Array = []
	for e in sol.edges:
		var sp: Vector2 = spans[e]
		var open: Array = (cut.get(e, []) as Array).filter(func(h): return not h.solid)
		if open.is_empty():
			out.append({"poly": sol.edges[e].poly, "base": sp.x, "top": sp.y, "own": e})
			continue
		# round an opening you walk through: the wall either side, and over (and under) it
		open.sort_custom(func(x, y): return x.t0 < y.t0)
		var w: Dictionary = sol.edges[e]
		var t := -INF
		for h: Dictionary in open:
			out.append({"poly": _slice(w, t, h.t0), "base": sp.x, "top": sp.y, "own": e})
			var mid := _slice(w, h.t0, h.t1)
			if h.y0 > sp.x + 1e-3: out.append({"poly": mid, "base": sp.x, "top": h.y0, "own": e})
			if h.y1 < sp.y - 1e-3: out.append({"poly": mid, "base": h.y1, "top": sp.y, "own": e})
			t = h.t1
		out.append({"poly": _slice(w, t, INF), "base": sp.x, "top": sp.y, "own": e})
	for n in sol.hubs:
		if not sol.hubs[n].flat:
			for hs: Vector2 in hub_span[n][0]:
				out.append({"poly": sol.hubs[n].poly, "base": hs.x, "top": hs.y, "own": -1})
	return out

# ---------------------------------------------------------------- meshes
static func _meshes(sol: Dictionary, spans: Dictionary, keys: Dictionary, hub_span: Dictionary, pieces: Array, reveals: Array = []) -> Dictionary:
	var sts := {}
	var st_for := func(key: String) -> SurfaceTool:
		if not sts.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			sts[key] = st
		return sts[key]
	for pc: Dictionary in pieces:
		var p: Vector2 = pc.p
		var q: Vector2 = pc.q
		var d := (q - p).normalized()
		var flat := Vector3(d.y, 0.0, -d.x)
		var np: Vector3 = Vector3(pc.np.x, 0.0, pc.np.y) if pc.np != null else flat
		var nq: Vector3 = Vector3(pc.nq.x, 0.0, pc.nq.y) if pc.nq != null else flat
		var y0: float = pc.y0
		var y1: float = pc.y1
		var y0q: float = pc.y0q
		var y1q: float = pc.y1q
		var v := [Vector3(p.x, y0, p.y), Vector3(q.x, y0q, q.y), Vector3(q.x, y1q, q.y), Vector3(p.x, y1, p.y)]
		var uv := [Vector2(pc.u0, y0), Vector2(pc.u1, y0q), Vector2(pc.u1, y1q), Vector2(pc.u0, y1)]
		_quad(st_for.call(pc.key), v, [np, nq, nq, np], uv, flat)
	for rv: Dictionary in reveals:
		_quad(st_for.call(rv.key), rv.v, rv.n, rv.uv, rv.facing)
	for e in sol.edges:
		var sp: Vector2 = spans[e]
		_cap(st_for.call(keys[e].cap), sol.edges[e].poly, sp.y, true)
		if sp.x > GROUND: _cap(st_for.call(keys[e].cap), sol.edges[e].poly, sp.x, false)
	for n in sol.hubs:
		if sol.hubs[n].flat: continue
		var key: String = keys[hub_span[n][1]].cap
		for hs: Vector2 in hub_span[n][0]:
			_cap(st_for.call(key), sol.hubs[n].poly, hs.y, true)
			if hs.x > GROUND: _cap(st_for.call(key), sol.hubs[n].poly, hs.x, false)
	var out := {}
	for key in sts:
		var st: SurfaceTool = sts[key]
		st.generate_tangents()
		out[key] = st.commit()
	return out

## A flat cap over plan `poly` at height y, facing up (or down)
static func _cap(st: SurfaceTool, poly: PackedVector2Array, y: float, up: bool) -> void:
	if poly.size() < 3: return
	var idx := Geometry2D.triangulate_polygon(poly)
	var facing := Vector3.UP if up else Vector3.DOWN
	for i in range(0, idx.size(), 3):
		var tri: Array = []
		for k in 3:
			var p := poly[idx[i + k]]
			tri.append(Vector3(p.x, y, p.y))
		var order := [0, 1, 2]
		if ((tri[1] as Vector3) - tri[0]).cross((tri[2] as Vector3) - tri[0]).dot(facing) > 0.0: order = [0, 2, 1]
		for k in order:
			st.set_normal(facing)
			st.set_uv(Vector2((tri[k] as Vector3).x, (tri[k] as Vector3).z))
			st.add_vertex(tri[k])

## Two triangles a-b-c, a-c-d wound to face `facing` (Godot's front faces are clockwise)
static func _quad(st: SurfaceTool, v: Array, nrm: Array, uv: Array, facing: Vector3) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	if ((v[1] as Vector3) - v[0]).cross((v[2] as Vector3) - v[0]).dot(facing) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for k in order:
		st.set_normal(nrm[k])
		st.set_uv(uv[k])
		st.add_vertex(v[k])

# ---------------------------------------------------------------- openings
## A parameter of curve `cv` for a point by it: param_of, with a point a hair before the start of an arc counted
## before it (not most of the way round)
static func _par(cv: Dictionary, p: Vector2) -> float:
	var t := Geom.param_of(cv, p)
	if cv.kind == Geom.ARC:
		var full := TAU / maxf(absf(cv.sw), 1e-9)
		if t > 1.0 + (full - 1.0) * 0.5: t -= full
	return t

## Where the line square across the wall at parameter t (along the radius, on an arc) meets polyline `face`
static func _face_at(face: PackedVector2Array, cv: Dictionary, t: float) -> Vector2:
	var o := Geom.point(cv, t)
	var n := Geom.normal(cv, t)
	var best := o
	var bd := INF
	for i in face.size() - 1:
		var d := face[i + 1] - face[i]
		if d.length_squared() < 1e-12: continue
		var hit = Geometry2D.line_intersects_line(o, n, face[i], d)
		if hit == null: continue
		var f := ((hit as Vector2) - face[i]).dot(d) / d.length_squared()
		if f < -1e-4 or f > 1.0 + 1e-4: continue
		if (hit as Vector2).distance_to(o) < bd:
			bd = (hit as Vector2).distance_to(o)
			best = hit
	return best

## How far along piece p -> q (0..1) the line square across the wall at t crosses it
static func _frac(p: Vector2, q: Vector2, cv: Dictionary, t: float) -> float:
	var d := q - p
	if d.length_squared() < 1e-12: return 0.0
	var hit = Geometry2D.line_intersects_line(Geom.point(cv, t), Geom.normal(cv, t), p, d)
	if hit == null: return 0.0
	return clampf(((hit as Vector2) - p).dot(d) / d.length_squared(), 0.0, 1.0)

## The holes fitted between the corners of their walls, each with the points across it on both faces
static func _fit_holes(sol: Dictionary, holes: Dictionary) -> Dictionary:
	var out := {}
	for e in holes:
		if not sol.edges.has(e): continue
		var w: Dictionary = sol.edges[e]
		var cv: Dictionary = w.cv
		var l := maxf(Geom.length(cv), 1e-6)
		var left: PackedVector2Array = w.left
		var right: PackedVector2Array = w.right
		var lo := maxf(_par(cv, left[0]), _par(cv, right[0])) + EDGE_GAP / l
		var hi := minf(_par(cv, left[-1]), _par(cv, right[-1])) - EDGE_GAP / l
		var list: Array = []
		for h: Dictionary in holes[e]:
			var k := h.duplicate()
			k.t0 = maxf(float(h.t0), lo)
			k.t1 = minf(float(h.t1), hi)
			if (k.t1 - k.t0) * l < 0.2: continue
			k.w_m = (k.t1 - k.t0) * l
			var ts: Array[float] = [k.t0, k.t1]
			for face: PackedVector2Array in [left, right]:
				for p in face:
					var t := _par(cv, p)
					if t > k.t0 + 1e-6 and t < k.t1 - 1e-6: ts.append(t)
			if k["round"]:
				for i in range(1, ROUND_STEPS): ts.append(lerpf(k.t0, k.t1, float(i) / ROUND_STEPS))
			ts.sort()
			var uniq: Array[float] = []
			for t in ts:
				if uniq.is_empty() or t - uniq[-1] > 1e-6: uniq.append(t)
			k.ts = uniq
			k.l = PackedVector2Array(uniq.map(func(t): return _face_at(left, cv, t)))
			k.r = PackedVector2Array(uniq.map(func(t): return _face_at(right, cv, t)))
			list.append(k)
		# (two that now overlap: the later one goes)
		list.sort_custom(func(x, y): return x.t0 < y.t0)
		var kept: Array = []
		for h: Dictionary in list:
			if kept.is_empty() or h.t0 >= kept[-1].t1: kept.append(h)
		if not kept.is_empty(): out[e] = kept
	return out

## The faces of the walls with the holes cut out of them: a face across a hole keeps what is under its sill and
## over its head (sloping under a round head), each part with the u and the normals it had there
static func _cut(sol: Dictionary, cut: Dictionary, pieces: Array) -> Array:
	var out: Array = []
	for pc: Dictionary in pieces:
		var e: int = pc.own
		if e < 0 or pc.side == "" or not cut.has(e):
			out.append(pc)
			continue
		var cv: Dictionary = sol.edges[e].cv
		var tp := _par(cv, pc.p)
		var tq := _par(cv, pc.q)
		var lo := minf(tp, tq)
		var hi := maxf(tp, tq)
		var hs: Array = (cut[e] as Array).filter(func(h): return h["cut_" + str(pc.side)] and h.t1 > lo + 1e-7 and h.t0 < hi - 1e-7)
		if hs.is_empty():
			out.append(pc)
			continue
		var ts: Array[float] = [lo, hi]
		for h: Dictionary in hs:
			for t: float in h.ts:
				if t > lo + 1e-7 and t < hi - 1e-7: ts.append(t)
		ts.sort()
		if tp > tq: ts.reverse()
		for i in ts.size() - 1:
			var ta := ts[i]
			var tb := ts[i + 1]
			if absf(tb - ta) < 1e-7: continue
			var fa := _frac(pc.p, pc.q, cv, ta) if i > 0 else 0.0
			var fb := _frac(pc.p, pc.q, cv, tb) if i < ts.size() - 2 else 1.0
			var tm := (ta + tb) * 0.5
			var h = null
			for x: Dictionary in hs:
				if tm > x.t0 and tm < x.t1: h = x
			if h == null:
				out.append(_sub(pc, fa, fb, pc.y0, pc.y0, pc.y1))
				continue
			var bot_a := Openings.bottom_at(h, ta)
			var bot_b := Openings.bottom_at(h, tb)
			if maxf(bot_a, bot_b) > pc.y0 + 1e-4: out.append(_sub(pc, fa, fb, pc.y0, pc.y0, minf(bot_a, pc.y1), minf(bot_b, pc.y1)))
			var top_a := Openings.top_at(h, ta)
			var top_b := Openings.top_at(h, tb)
			if minf(top_a, top_b) < pc.y1 - 1e-4: out.append(_sub(pc, fa, fb, minf(top_a, pc.y1), minf(top_b, pc.y1), pc.y1))
	return out

static func _sub(pc: Dictionary, fa: float, fb: float, y0p: float, y0q: float, y1: float, y1q := NAN) -> Dictionary:
	var k := pc.duplicate()
	k.p = (pc.p as Vector2).lerp(pc.q, fa)
	k.q = (pc.p as Vector2).lerp(pc.q, fb)
	k.u0 = lerpf(pc.u0, pc.u1, fa)
	k.u1 = lerpf(pc.u0, pc.u1, fb)
	if pc.np != null:
		k.np = (pc.np as Vector2).lerp(pc.nq, fa).normalized()
		k.nq = (pc.np as Vector2).lerp(pc.nq, fb).normalized()
	k.y0 = y0p
	k.y0q = y0q
	k.y1 = y1
	k.y1q = y1 if is_nan(y1q) else y1q
	return k

## The faces lining each hole: its two jambs (square across the wall), its head (flat, or round over its
## width), its sill (when it is up off the floor), and the back of a recess cut into one face only
static func _reveals(sol: Dictionary, spans: Dictionary, keys: Dictionary, cut: Dictionary) -> Array:
	var out: Array = []
	for e in cut:
		var cv: Dictionary = sol.edges[e].cv
		var key: String = keys[e].cap
		for h: Dictionary in cut[e]:
			var ts: Array = h.ts
			var l: PackedVector2Array = h.l
			var r: PackedVector2Array = h.r
			var n := ts.size()
			var v3 := func(p: Vector2, y: float) -> Vector3: return Vector3(p.x, y, p.y)
			var tops: Array[float] = []
			var bots: Array[float] = []
			for t: float in ts:
				tops.append(Openings.top_at(h, t))
				bots.append(Openings.bottom_at(h, t))
			var mid_t := (float(h.t0) + float(h.t1)) * 0.5
			var spring := Openings.spring_of(h)
			# the jambs, facing into the hole
			for k: int in [0, n - 1]:
				var tan := Geom.tangent(cv, ts[k]) * (1.0 if k == 0 else -1.0)
				var f := Vector3(tan.x, 0.0, tan.y)
				var top: float = tops[k]
				var bot: float = bots[k]
				if top - bot < 1e-4: continue
				var depth := l[k].distance_to(r[k])
				out.append({"key": key, "facing": f, "n": [f, f, f, f],
					"v": [v3.call(l[k], bot), v3.call(r[k], bot), v3.call(r[k], top), v3.call(l[k], top)],
					"uv": [Vector2(0.0, bot), Vector2(depth, bot), Vector2(depth, top), Vector2(0.0, top)]})
			# the head, and the sill
			var run := 0.0
			for i in n - 1:
				var step := l[i].distance_to(l[i + 1])
				var na := Vector3.DOWN
				var nb := Vector3.DOWN
				if h["round"]:
					na = _toward_mid(cv, mid_t, ts[i], l[i], spring - tops[i])
					nb = _toward_mid(cv, mid_t, ts[i + 1], l[i + 1], spring - tops[i + 1])
				var depth := l[i].distance_to(r[i])
				out.append({"key": key, "facing": (na + nb).normalized(), "n": [na, nb, nb, na],
					"v": [v3.call(l[i], tops[i]), v3.call(l[i + 1], tops[i + 1]), v3.call(r[i + 1], tops[i + 1]), v3.call(r[i], tops[i])],
					"uv": [Vector2(run, 0.0), Vector2(run + step, 0.0), Vector2(run + step, depth), Vector2(run, depth)]})
				if h.y0 > (spans[e] as Vector2).x + 1e-3:
					var ua := Vector3.UP
					var ub := Vector3.UP
					if h.get("disc", false):              # round under a porthole: facing in to its middle
						ua = _toward_mid(cv, mid_t, ts[i], l[i], spring - bots[i])
						ub = _toward_mid(cv, mid_t, ts[i + 1], l[i + 1], spring - bots[i + 1])
					out.append({"key": key, "facing": (ua + ub).normalized(), "n": [ua, ub, ub, ua],
						"v": [v3.call(l[i], bots[i]), v3.call(l[i + 1], bots[i + 1]), v3.call(r[i + 1], bots[i + 1]), v3.call(r[i], bots[i])],
						"uv": [Vector2(run, 0.0), Vector2(run + step, 0.0), Vector2(run + step, depth), Vector2(run, depth)]})
				# a recess's back: the uncut face seen from inside the hole
				for side: String in ["l", "r"]:
					if h["cut_" + side]: continue
					var face: PackedVector2Array = l if side == "l" else r
					var nn := Geom.normal(cv, (ts[i] + ts[i + 1]) * 0.5) * (-1.0 if side == "l" else 1.0)
					var f := Vector3(nn.x, 0.0, nn.y)
					out.append({"key": key, "facing": f, "n": [f, f, f, f],
						"v": [v3.call(face[i], bots[i]), v3.call(face[i + 1], bots[i + 1]), v3.call(face[i + 1], tops[i + 1]), v3.call(face[i], tops[i])],
						"uv": [Vector2(run, bots[i]), Vector2(run + step, bots[i + 1]), Vector2(run + step, tops[i + 1]), Vector2(run, tops[i])]})
				run += step
	return out

## The normal of a round head (or a porthole's bottom) at parameter t, point p on a face: in towards the
## middle of the opening, `dy` up from p to the middle's height
static func _toward_mid(cv: Dictionary, mid_t: float, t: float, p: Vector2, dy: float) -> Vector3:
	var c := Geom.point(cv, mid_t)
	var dir := Geom.tangent(cv, t)
	var d3 := Vector3(dir.x, 0.0, dir.y)
	var v := d3 * d3.dot(Vector3(c.x - p.x, 0.0, c.y - p.y)) + Vector3(0.0, dy, 0.0)
	return v.normalized() if v.length() > 1e-6 else (Vector3.DOWN if dy <= 0.0 else Vector3.UP)

## Wall plan `w` between parameters ta and tb (-INF / INF: from / to its own end): its right face that far, back
## along its left
static func _slice(w: Dictionary, ta: float, tb: float) -> PackedVector2Array:
	var r := _sub_face(w.right, w.cv, ta, tb)
	var l := _sub_face(w.left, w.cv, ta, tb)
	l.reverse()
	return r + l

static func _sub_face(face: PackedVector2Array, cv: Dictionary, ta: float, tb: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if ta > -INF: out.append(_face_at(face, cv, ta))
	for p in face:
		var t := _par(cv, p)
		if t > ta + 1e-7 and t < tb - 1e-7: out.append(p)
	if tb < INF: out.append(_face_at(face, cv, tb))
	return out
