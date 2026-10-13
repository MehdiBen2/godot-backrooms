extends SceneTree
## Wall graph checks, headless:  godot --headless --path godot-backrooms --script res://tools/test_walls.gd
## Every scene in tools/wall_cases.gd is solved (wall_joints.gd) and built (wall_mesh.gd), then checked:
##   - topology: the nodes and walls it should have (T and X junctions found, a deleted wall's leftovers joined)
##   - plan: every wall and hub outline a proper polygon, no two of them overlapping by any area
##   - outline: the feet of the walls chain into closed outlines, as many as the scene should make (a gap or an
##     overlap anywhere breaks a chain or makes an extra one)
##   - mesh: watertight (every edge of every triangle met by the same length of edge the other way, the open foot
##     of the walls aside), no two triangles lying on top of each other (z-fighting), every face facing out
## Then the save format round trip, and level0 converted from its old wall objects (the same cells taken over,
## the same cell links cut, every wall converted). Exits 1 when anything fails.

const Cases := preload("res://tools/wall_cases.gd")
const WallGraph := preload("res://scripts/World/level/walls/wall_graph.gd")
const Joints := preload("res://scripts/World/level/walls/wall_joints.gd")
const WallMesh := preload("res://scripts/World/level/walls/wall_mesh.gd")
const Geom := preload("res://scripts/World/level/walls/wall_geom.gd")
const Snap := preload("res://scripts/World/level/walls/wall_snap.gd")
const CELL := 4.5
const FULL := 5.4

var fails := 0

func _initialize() -> void:
	for c: Dictionary in Cases.cases():
		if _check(c.name, c.g, c).is_empty(): _fail(c.name, "the check crashed (see the script error above)")
	_round_trip()
	_snapping()
	_editing()
	if not _level0(): _fail("level0", "the check crashed (see the script error above)")
	print("")
	print("ALL PASSED" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)

func _fail(name: String, why: String) -> void:
	fails += 1
	print("  FAIL ", name, ": ", why)

static func spans_of(g) -> Dictionary:
	var out := {}
	for e in g.edges:
		var ed: Dictionary = g.edges[e]
		out[e] = Vector2(ed.base, ed.h if ed.h > 0.0 else FULL)
	return out

static func keys_of(g) -> Dictionary:
	var out := {}
	for e in g.edges: out[e] = {"l": "w", "r": "w", "cap": "w"}
	return out

func _check(name: String, g, want: Dictionary) -> Dictionary:
	var f0 := fails
	if want.has("nodes") and g.nodes.size() != want.nodes: _fail(name, "%d nodes, wanted %d" % [g.nodes.size(), want.nodes])
	if want.has("edges") and g.edges.size() != want.edges: _fail(name, "%d walls, wanted %d" % [g.edges.size(), want.edges])
	for n in want.get("moved", []):
		for e in g.edges_at(n):
			var cv: Dictionary = g.curve_of(e)
			var at: Vector2 = Geom.start_of(cv) if g.edges[e].a == n else Geom.end_of(cv)
			if at.distance_to(g.pos(n)) > 1e-4: _fail(name, "wall %d came away from moved node %d" % [e, n])
	var sol := Joints.solve(g, CELL)
	var res := WallMesh.build(sol, spans_of(g), keys_of(g), 2.25)
	var polys: Array = []
	for e in sol.edges: polys.append([sol.edges[e].poly, "wall %d" % e])
	for n in sol.hubs:
		if not sol.hubs[n].flat: polys.append([sol.hubs[n].poly, "hub %d" % n])
	# plan
	for p: Array in polys:
		var poly: PackedVector2Array = p[0]
		if Geom.area(poly) <= 1e-6: _fail(name, "%s outline has no area / runs clockwise (%.6f)" % [p[1], Geom.area(poly)])
		elif Geometry2D.triangulate_polygon(poly).is_empty(): _fail(name, "%s outline crosses itself" % p[1])
	var overlap := 0.0
	for i in polys.size():
		var bi := _box(polys[i][0])
		for j in range(i + 1, polys.size()):
			if not bi.intersects(_box(polys[j][0])): continue
			for o: PackedVector2Array in Geometry2D.intersect_polygons(polys[i][0], polys[j][0]):
				var a := absf(Geom.area(o))
				if a > 1e-6:
					overlap += a
					_fail(name, "%s overlaps %s by %.5f m2" % [polys[i][1], polys[j][1], a])
	# outline
	var open: int = (res.loops as Array).filter(func(l): return not l.closed).size()
	if open > 0: _fail(name, "%d outlines don't close (a gap or an overlap)" % open)
	if want.has("loops") and res.loops.size() != want.loops: _fail(name, "%d outlines, wanted %d" % [res.loops.size(), want.loops])
	# mesh
	var tris := _triangles(res.meshes)
	var leak := _watertight(tris)
	if leak != "": _fail(name, "not watertight: " + leak)
	var fight := _zfight(tris)
	if fight != "": _fail(name, "faces on top of each other: " + fight)
	var facing := _outward(res)
	if facing != "": _fail(name, "face pointing in: " + facing)
	print("%s %s   (%d nodes, %d walls, %d hubs, %d outlines, %d triangles)" % ["PASS" if fails == f0 else "FAIL", name,
		g.nodes.size(), g.edges.size(), polys.size() - sol.edges.size(), res.loops.size(), tris.size() / 3])
	res["done"] = true
	return res

static func _box(poly: PackedVector2Array) -> Rect2:
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly: r = r.expand(p)
	return r.grow(1e-4)

static func _triangles(meshes: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	for key in meshes:
		var m: ArrayMesh = meshes[key]
		for s in m.get_surface_count():
			out.append_array(m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX])
	return out

## Every triangle edge (the floor's aside) must be met along its whole length by edges running the other way
static func _watertight(tris: PackedVector3Array) -> String:
	var lines := {}
	for i in range(0, tris.size(), 3):
		for k in 3:
			var a := tris[i + k]
			var b := tris[i + (k + 1) % 3]
			if absf(a.y) < 1e-4 and absf(b.y) < 1e-4: continue
			var d := b - a
			if d.length() < 1e-6: continue
			var dir := d.normalized()
			if dir.x < -1e-5 or (absf(dir.x) <= 1e-5 and (dir.y < -1e-5 or (absf(dir.y) <= 1e-5 and dir.z < 0.0))): dir = -dir
			var o := a - dir * a.dot(dir)
			var key := "%d,%d,%d|%d,%d,%d" % [roundi(dir.x * 2000), roundi(dir.y * 2000), roundi(dir.z * 2000), roundi(o.x * 500), roundi(o.y * 500), roundi(o.z * 500)]
			var t0 := a.dot(dir)
			var t1 := b.dot(dir)
			if not lines.has(key): lines[key] = []
			lines[key].append([minf(t0, t1), maxf(t0, t1), 1 if t1 > t0 else -1, a, b])
	for key in lines:
		var ivs: Array = lines[key]
		var cuts: Array[float] = []
		for iv: Array in ivs:
			cuts.append(iv[0])
			cuts.append(iv[1])
		cuts.sort()
		for i in cuts.size() - 1:
			if cuts[i + 1] - cuts[i] < 2e-4: continue
			var mid := (cuts[i] + cuts[i + 1]) * 0.5
			var sum := 0
			var any: Array = []
			for iv: Array in ivs:
				if mid > iv[0] and mid < iv[1]:
					sum += iv[2]
					any = iv
			if sum != 0:
				return "an edge near %s-%s is open (%d)" % [_v(any[3]), _v(any[4]), sum]
	return ""

## No two triangles in the same plane overlapping
static func _zfight(tris: PackedVector3Array) -> String:
	var planes := {}
	for i in range(0, tris.size(), 3):
		var n := (tris[i + 1] - tris[i]).cross(tris[i + 2] - tris[i])
		if n.length() < 1e-9: continue
		n = n.normalized()
		if n.x < -1e-5 or (absf(n.x) <= 1e-5 and (n.y < -1e-5 or (absf(n.y) <= 1e-5 and n.z < 0.0))): n = -n
		var key := "%d,%d,%d|%d" % [roundi(n.x * 1000), roundi(n.y * 1000), roundi(n.z * 1000), roundi(n.dot(tris[i]) * 1000)]
		if not planes.has(key): planes[key] = [n, []]
		planes[key][1].append(i)
	for key in planes:
		var n: Vector3 = planes[key][0]
		var list: Array = planes[key][1]
		if list.size() < 2: continue
		var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
		var w := n.cross(u)
		var flat: Array = []
		var boxes: Array = []
		for i: int in list:
			var t := PackedVector2Array([Vector2(tris[i].dot(u), tris[i].dot(w)), Vector2(tris[i + 1].dot(u), tris[i + 1].dot(w)), Vector2(tris[i + 2].dot(u), tris[i + 2].dot(w))])
			if Geom.area(t) < 0.0: t.reverse()
			flat.append(t)
			boxes.append(_box(t))
		for a in flat.size():
			for b in range(a + 1, flat.size()):
				if not (boxes[a] as Rect2).intersects(boxes[b]): continue
				for o: PackedVector2Array in Geometry2D.intersect_polygons(flat[a], flat[b]):
					if absf(Geom.area(o)) > 1e-6:
						return "two triangles at %s overlap by %.6f m2" % [_v(tris[list[a]]), absf(Geom.area(o))]
	return ""

## Just off every face, out the way it faces, is out of every wall; just behind it is in one
static func _outward(res: Dictionary) -> String:
	for pc: Dictionary in res.pieces:
		var p: Vector2 = pc.p
		var q: Vector2 = pc.q
		var d := (q - p).normalized()
		var nrm := Vector2(d.y, -d.x)
		var m := (p + q) * 0.5
		var y := (float(pc.y0) + float(pc.y1)) * 0.5
		var front = _solid_at(res.solids, m + nrm * 0.004, y)
		if front != null: return "%s-%s (wall %d, y %.2f-%.2f) has wall %d in front of it" % [_v2(p), _v2(q), pc.own, pc.y0, pc.y1, front]
		if _solid_at(res.solids, m - nrm * 0.004, y) == null: return "%s-%s has no wall behind it" % [_v2(p), _v2(q)]
	return ""

static func _solid_at(solids: Array, p: Vector2, y: float):
	for s: Dictionary in solids:
		if y > s.base and y < s.top and _inside(p, s.poly): return s.own
	return null

## Crossing-number point in polygon (Geometry2D.is_point_in_polygon gets points a few mm outside a thin
## polygon wrong this far from the origin)
static func _inside(p: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		if (a.y > p.y) != (b.y > p.y):
			var x := a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
			if p.x < x: inside = not inside
	return inside

static func _v(p: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z]

static func _v2(p: Vector2) -> String:
	return "(%.2f, %.2f)" % [p.x, p.y]

# ---------------------------------------------------------------- saving
func _round_trip() -> void:
	var f0 := fails
	for c: Dictionary in Cases.cases():
		var d: Dictionary = c.g.to_dict()
		var g2 = WallGraph.new()
		g2.load_dict(JSON.parse_string(JSON.stringify(d)))
		if JSON.stringify(g2.to_dict()) != JSON.stringify(d): _fail("save round trip", c.name + " changed on the way back in")
	print("%s save round trip" % ("PASS" if fails == f0 else "FAIL"))

# ---------------------------------------------------------------- snapping
func _snapping() -> void:
	var f0 := fails
	var g = WallGraph.new()
	Cases.line(g, Vector2(0, 0), Vector2(4, 0))
	Cases.line(g, Vector2(2, -2), Vector2(2, 2))
	var arc_end: Vector2 = Vector2(6, 0)
	Cases.arc(g, Vector2(6, 4), arc_end, 90.0)
	var base := {"radius": 0.25, "grid": 0.5, "angle_step": 15.0}
	var want := func(what: String, cur: Vector2, kind: String, at, extra := {}) -> void:
		var o := base.duplicate()
		o.merge(extra, true)
		var r: Dictionary = Snap.snap(g, cur, o)
		var ok: bool = str(r.kind).begins_with(kind) and (at == null or (r.p as Vector2).distance_to(at) < 1e-3)
		if not ok: _fail("snapping", "%s: got %s at %s" % [what, r.kind, r.p])
	want.call("onto a node", Vector2(4.1, 0.1), "node", Vector2(4, 0))
	want.call("onto a crossing", Vector2(2.15, 0.12), "node", Vector2(2, 0))      # (the crossing is a node already)
	want.call("along a wall", Vector2(3.1, 0.2), "edge", Vector2(3.1, 0))
	var mid_arc: Vector2 = Geom.point(g.curve_of(g.edges.keys()[-1]), 0.5)
	want.call("along an arc", mid_arc + Vector2(0.1, 0.1), "edge", null)
	var n_end: int = g.node_near(arc_end, 0.01)
	var cv: Dictionary = g.curve_of(g.edges_at(n_end)[0])
	var tan: Vector2 = Geom.tangent(cv, 1.0) if Geom.end_of(cv).distance_to(arc_end) < 0.01 else -Geom.tangent(cv, 0.0)
	want.call("on out of an arc's end", arc_end + tan * 2.0 + Vector2(-tan.y, tan.x) * 0.15, "tangent", arc_end + tan * 2.0,
		{"from": [arc_end], "from_node": n_end, "grid": 0.0})
	want.call("a 45 degree step", Vector2(10, 10) + Vector2(1.5, 1.42), "angle", Vector2(10, 10) + Vector2(1.46, 1.46),
		{"from": [Vector2(10, 10)], "grid": 0.0})
	want.call("in line past a wall's end", Vector2(5.3, 0.12), "extend", Vector2(5.3, 0), {"grid": 0.0})
	want.call("the grid", Vector2(20.2, 20.3), "grid", Vector2(20, 20.5))
	want.call("off", Vector2(4.1, 0.1), "free", Vector2(4.1, 0.1), {"off": true})
	print("%s snapping" % ("PASS" if fails == f0 else "FAIL"))

# ---------------------------------------------------------------- editing: exact sizes, sliding, locks
func _editing() -> void:
	var f0 := fails
	var near := func(what: String, got, want, tol := 1e-3) -> void:
		var bad: bool = (got as Vector2).distance_to(want) > tol if got is Vector2 else absf(float(got) - float(want)) > tol
		if bad: _fail("editing", "%s: got %s, wanted %s" % [what, got, want])
	# a room: slide its right wall out, the top and bottom walls stretch to follow
	var g = WallGraph.new()
	for w: Array in [[Vector2(0, 0), Vector2(4, 0)], [Vector2(4, 0), Vector2(4, 3)], [Vector2(4, 3), Vector2(0, 3)], [Vector2(0, 3), Vector2(0, 0)]]:
		Cases.line(g, w[0], w[1])
	var right: int = g.edge_near(Vector2(4, 1.5), 0.01).e
	var left_n: Vector2 = Vector2(-1, 0) if g.pos(g.edges[right].a).y < g.pos(g.edges[right].b).y else Vector2(1, 0)
	g.slide(right, -1.0 if left_n.x < 0 else 1.0)
	near.call("slid wall's end", g.pos(g.node_near(Vector2(5, 0), 0.01)) if g.node_near(Vector2(5, 0), 0.01) >= 0 else Vector2(-99, -99), Vector2(5, 0))
	near.call("top wall stretched", g.length_of(g.edge_near(Vector2(2, 0), 0.01).e), 5.0)
	# exact length, straight and curved (an arc keeps its sweep)
	var top: int = g.edge_near(Vector2(2, 0), 0.01).e
	var keep: int = g.node_near(Vector2(0, 0), 0.01)
	g.set_length(top, 3.0, keep)
	near.call("set length", g.length_of(top), 3.0)
	g.set_radius(top, 2.0)
	var sw: float = g.curve_of(top).sw
	near.call("set radius", g.curve_of(top).r, 2.0)
	g.set_length(top, 2.5, keep)
	near.call("set length of an arc", g.length_of(top), 2.5)
	near.call("arc keeps its sweep", g.curve_of(top).sw, sw)
	g.set_radius(top, 0.0)
	near.call("straightened", g.edges[top].bulge, 0.0)
	g.set_angle(top, deg_to_rad(30.0), keep)
	near.call("set angle", Geom.wrap((g.pos(g.other(top, keep)) - g.pos(keep)).angle()), deg_to_rad(30.0))
	# locks while dragging a node
	g = WallGraph.new()
	Cases.line(g, Vector2(0, 0), Vector2(4, 0))
	Cases.line(g, Vector2(4, 0), Vector2(4, 3))
	var corner: int = g.node_near(Vector2(4, 0), 0.01)
	var bottom: int = g.edge_near(Vector2(2, 0), 0.01).e
	var side: int = g.edge_near(Vector2(4, 1.5), 0.01).e
	g.edges[bottom].lock_len = true
	var t: Dictionary = g.drag_targets(corner, Vector2(5, 2))
	near.call("length lock keeps the node on its circle", (t[corner] as Vector2).length(), 4.0)
	g.edges[bottom].lock_len = false
	g.edges[bottom].lock_ang = true
	t = g.drag_targets(corner, Vector2(5, 2))
	near.call("direction lock keeps it on its line", t[corner], Vector2(5, 0))
	g.edges[side].lock_len = true
	t = g.drag_targets(corner, Vector2(5, 2))
	near.call("a direction and a length lock: where they meet", (t[corner] as Vector2).distance_to(Vector2(4, 3)), 3.0)
	near.call("... on the line", (t[corner] as Vector2).y, 0.0)
	g.edges[side].lock_len = false
	g.edges[bottom].lock_len = true
	t = g.drag_targets(corner, Vector2(5, 2))
	near.call("a rigid wall comes along whole", t.get(g.node_near(Vector2(0, 0), 0.01), Vector2(-99, -99)), Vector2(1, 2))
	# moving walls: a locked wall on them comes along rather than stretch
	var moved: Array = g.translate([g.node_near(Vector2(4, 3), 0.01)], Vector2(0, 1))
	near.call("free wall stretches, locked one stays", g.length_of(bottom), 4.0)
	var d: Dictionary = g.to_dict()
	var g2 = WallGraph.new()
	g2.load_dict(JSON.parse_string(JSON.stringify(d)))
	if not (bool(g2.edges[bottom].lock_len) and bool(g2.edges[bottom].lock_ang)): _fail("editing", "locks lost on saving")
	print("%s editing (exact sizes, sliding, locks)" % ("PASS" if fails == f0 else "FAIL"))

# ---------------------------------------------------------------- level0's old walls
func _level0() -> bool:
	var f0 := fails
	var types := {}
	var raw = JSON.parse_string(FileAccess.get_file_as_string("res://levels/object_types.json"))
	for k in raw:
		if not str(k).begins_with("_"): types[k] = raw[k]
	var lvl: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://levels/level0.lvl"))
	var size := int(lvl.size)
	var objects: Array = lvl.objects
	var walls := objects.filter(func(o): return str(types.get(o.type, {}).get("shape", "")) in ["slab", "corner", "arc", "spline"])
	# the old way: which cells the wall objects took over, and which cell links they cut
	var old_cells := {}
	var old_cut := {}
	for o: Dictionary in walls:
		var info: Dictionary = types[o.type]
		var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
		var centred := absf(o.pos_x - c.x) <= 0.26 and absf(o.pos_y - c.y) <= 0.26
		var inside := c.x > 0 and c.y > 0 and c.x < size - 1 and c.y < size - 1
		var h := float(o.get("height", 0.0))
		var low := h > 0.0 and h < 1.8
		var path := _old_path(o, info)
		if centred and inside and not low and info.get("on_cell") == "wall":
			old_cells[c] = true
			if float(o.scale) <= 1.01: continue
		if path.size() < 2: continue
		var r := deg_to_rad(o.rotation)
		var at := Vector2(o.pos_x, o.pos_y)
		path[0] = path[0].move_toward(path[1], 0.01)
		path[-1] = path[-1].move_toward(path[-2], 0.01)
		for i in path.size() - 1: _cut(old_cut, at + path[i].rotated(r), at + path[i + 1].rotated(r))
	# the new way
	var g = WallGraph.new()
	var kept: Array = g.absorb(objects, types, size)
	var new_cells := {}
	var new_cut := {}
	for e in g.edges:
		for c in g.edges[e].cells: new_cells[Vector2i(c[0], c[1])] = true
	for sp: Array in g.nav_spans(): _cut(new_cut, sp[0], sp[1])
	# a link into a cell a wall takes over leads into a wall either way: only the others count
	for cut: Dictionary in [old_cut, new_cut]:
		for k: Vector4i in cut.keys():
			if old_cells.has(Vector2i(k.x, k.y)) or old_cells.has(Vector2i(k.z, k.w)): cut.erase(k)
	var converted := objects.size() - kept.size()
	print("  level0: %d wall objects -> %d walls on %d nodes (%d objects converted, %d kept as they were)" % [walls.size(), g.edges.size(), g.nodes.size(), converted, kept.size()])
	if converted < walls.size() - 1: _fail("level0", "only %d of %d wall objects converted" % [converted, walls.size()])
	if old_cells.keys().size() != new_cells.keys().size() or old_cells.keys().any(func(c): return not new_cells.has(c)):
		_fail("level0", "cells taken over differ: %d before, %d after" % [old_cells.size(), new_cells.size()])
	var lost := old_cut.keys().filter(func(k): return not new_cut.has(k))
	var gained := new_cut.keys().filter(func(k): return not old_cut.has(k))
	print("  level0: cell links cut %d before, %d after (%d no longer cut, %d newly cut)" % [old_cut.size(), new_cut.size(), lost.size(), gained.size()])
	for k in lost: print("    no longer cut: ", k)
	for k in gained: print("    newly cut: ", k)
	if not lost.is_empty(): _fail("level0", "%d cell links a wall used to cut are open now" % lost.size())
	print("%s level0 conversion" % ("PASS" if fails == f0 else "FAIL"))
	return not _check("level0 walls built", g, {}).is_empty()

static func _old_path(o: Dictionary, info: Dictionary) -> PackedVector2Array:
	var s := float(o.scale)
	match str(info.get("shape", "")):
		"slab": return PackedVector2Array([Vector2(0, -s * 0.5), Vector2(0, s * 0.5)])
		"corner": return PackedVector2Array([Vector2(s, 0), Vector2.ZERO, Vector2(0, s)])
	return PackedVector2Array()

static func _cut(out: Dictionary, a: Vector2, b: Vector2) -> void:
	for x in range(floori(minf(a.x, b.x)) - 1, ceili(maxf(a.x, b.x)) + 1):
		for z in range(floori(minf(a.y, b.y)) - 1, ceili(maxf(a.y, b.y)) + 1):
			var c := Vector2i(x, z)
			for step: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				if Geometry2D.segment_intersects_segment(Vector2(c), Vector2(c + step), a, b) != null:
					out[Vector4i(c.x, c.y, c.x + step.x, c.y + step.y)] = true
