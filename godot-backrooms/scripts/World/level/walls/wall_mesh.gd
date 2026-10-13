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

const Geom := preload("wall_geom.gd")

const GROUND := 1e-4

## `sol`: wall_joints.gd solve(). `spans`: wall id -> Vector2(base, top), metres. `keys`: wall id ->
## {"l", "r", "cap"}: which mesh (material) its left face, right face and the rest go in. `rep`: metres one
## repeat of the wallpaper runs. `meshes`: false to work out only the faces, chains and solids.
## Returns {meshes: {key: ArrayMesh}, pieces: [{p, q, y0, y1, own (wall id, -1 a hub), key}], loops: [{pts,
## closed, inward}] (the foot of the walls, for skirting), solids: [{poly, base, top}] (for collision)}
static func build(sol: Dictionary, spans: Dictionary, keys: Dictionary, rep := 2.25, meshes := true) -> Dictionary:
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
					pieces.append(_piece(p, q, sp, nr[t.i] if smooth else null, nr[j] if smooth else null, keys[e][t.s], e))
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
	var out := {"pieces": pieces, "loops": loops, "solids": _solids(sol, spans, hub_span), "meshes": {}}
	if meshes: out.meshes = _meshes(sol, spans, keys, hub_span, pieces)
	return out

static func _piece(p: Vector2, q: Vector2, y: Vector2, np, nq, key: String, own: int) -> Dictionary:
	return {"p": p, "q": q, "y0": y.x, "y1": y.y, "np": np, "nq": nq, "key": key, "own": own, "u0": 0.0, "u1": 0.0, "loop": false}

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

## Chain the faces at the foot of the walls round the outlines and give every face its u. Returns the chains.
static func _chain(pieces: Array, rep: float) -> Array:
	var by_start := {}
	var ground: Array = []
	for i in pieces.size():
		if pieces[i].y0 < GROUND:
			ground.append(i)
			by_start[_key(pieces[i].p)] = i
	var seen := {}
	var loops: Array = []
	var u_at := {}
	for i: int in ground:
		if seen.has(i): continue
		var chain: Array = []
		var j = i
		while j != null and not seen.has(j):
			seen[j] = true
			chain.append(j)
			j = _find(by_start, pieces[j].q)
		var closed: bool = j == i
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

static func _solids(sol: Dictionary, spans: Dictionary, hub_span: Dictionary) -> Array:
	var out: Array = []
	for e in sol.edges:
		out.append({"poly": sol.edges[e].poly, "base": (spans[e] as Vector2).x, "top": (spans[e] as Vector2).y, "own": e})
	for n in sol.hubs:
		if not sol.hubs[n].flat:
			for hs: Vector2 in hub_span[n][0]:
				out.append({"poly": sol.hubs[n].poly, "base": hs.x, "top": hs.y, "own": -1})
	return out

# ---------------------------------------------------------------- meshes
static func _meshes(sol: Dictionary, spans: Dictionary, keys: Dictionary, hub_span: Dictionary, pieces: Array) -> Dictionary:
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
		var v := [Vector3(p.x, y0, p.y), Vector3(q.x, y0, q.y), Vector3(q.x, y1, q.y), Vector3(p.x, y1, p.y)]
		var uv := [Vector2(pc.u0, y0), Vector2(pc.u1, y0), Vector2(pc.u1, y1), Vector2(pc.u0, y1)]
		_quad(st_for.call(pc.key), v, [np, nq, nq, np], uv, flat)
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
