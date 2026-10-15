@tool
class_name UBOpCutFace
extends RefCounted
## The Cut tool's op: the drawn polygon becomes its own sub-face and the
## surrounding ring is stitched into one polygon per cut edge. Each polygon
## absorbs the outer vertices that fall inside its angular span around the
## cut's centroid, so aligned cuts give quads and the general case gives
## trapezoid n-gons rather than a sliver-triangle fan. Reliable when the ring
## is star-shaped from the cut centroid, which is always true for convex faces.
## Points on the face's boundary are supported: points within EPS of an outer
## vertex reuse it, points on an outer edge are spliced into the boundary
## without T-junctions (neighbors included), and the ring becomes one region
## per boundary arc between touch points. A cut edge lying on a boundary edge
## yields no region there, which is how a cut splits a face in two. Invalid
## boundary cuts (misordered touches, revisited vertices, no bridge for a
## single-touch pinch) return with the mesh untouched.

const EPS := 1e-4
## Region-planning token bases: tokens below TOK_EDGE are outer-loop
## positions; TOK_EDGE+k and TOK_INT+k are cut point k (edge-split / interior).
const TOK_EDGE := 1000000
const TOK_INT := 2000000


static func apply(data, face_index: int, points: PackedVector3Array) -> void:
	if face_index < 0 or face_index >= data.faces.size():
		return

	var pts := PackedVector3Array()
	for i in points.size():
		if points[i].distance_to(points[(i + 1) % points.size()]) >= EPS:
			pts.append(points[i])
	if pts.size() < 3:
		return
	var face: UBFace = data.faces[face_index]
	var normal: Vector3 = data.face_normal(face)
	var axis := Vector3.RIGHT if absf(normal.x) < 0.9 else Vector3.UP
	var u := (axis - normal * axis.dot(normal)).normalized()
	var w := normal.cross(u)

	var outer_ids := face.vertices.duplicate()

	var origin := Vector3.ZERO
	for vi in outer_ids:
		origin += data.positions[vi]
	origin /= outer_ids.size()
	var outer2 := PackedVector2Array()
	for vi in outer_ids:
		var rel: Vector3 = data.positions[vi] - origin
		outer2.append(Vector2(rel.dot(u), rel.dot(w)))
	var outer_ccw := _area(outer2) >= 0.0
	if not outer_ccw:
		outer_ids.reverse()
		outer2.reverse()

	var cut2 := PackedVector2Array()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in pts:
		var rel := p - origin
		var q := Vector2(rel.dot(u), rel.dot(w))
		cut2.append(q)
		lo = lo.min(q)
		hi = hi.max(q)
	var extent := (hi - lo).length()
	if absf(_area(cut2)) <= 1e-6 * extent * extent:
		return

	var cls := _classify(pts, outer2, u, w, origin)
	for c in cls:
		if c.kind != "i":
			_apply_boundary(data, face_index, pts, cls, outer_ids, outer2, outer_ccw)
			return

	var inner_ids := PackedInt32Array()
	var inner2 := PackedVector2Array()
	for p in pts:
		inner_ids.append(data.add_vertex(p))
		var rel := p - origin
		inner2.append(Vector2(rel.dot(u), rel.dot(w)))
	if _area(inner2) < 0.0:
		inner_ids.reverse()
		inner2.reverse()

	var inner_face: UBFace = face.duplicate_face()
	var inner_loop := inner_ids.duplicate()
	if not outer_ccw:
		inner_loop.reverse()
	UBOpUtils.set_face_loop(inner_face, inner_loop)

	var polys: Array
	if _is_convex(outer2):
		polys = _stitch(outer_ids, outer2, inner_ids, inner2)
	else:
		polys = _stitch_bridged(outer_ids, outer2, inner_ids, inner2)
		if polys.is_empty():
			polys = _stitch(outer_ids, outer2, inner_ids, inner2)
	if not outer_ccw:

		for k in polys.size():
			var p: PackedInt32Array = polys[k]
			p.reverse()
			polys[k] = p

	var field := UBOpUtils.capture_colors(data, face)
	if field != null:
		inner_face.color_corners = field.colors_for_loop(data, inner_loop)
	UBOpUtils.set_face_loop(face, polys[0])
	if field != null:
		face.color_corners = field.colors_for_loop(data, polys[0])
	for k in range(1, polys.size()):
		var ring_face: UBFace = face.duplicate_face()
		UBOpUtils.set_face_loop(ring_face, polys[k])
		if field != null:
			ring_face.color_corners = field.colors_for_loop(data, polys[k])
		data.faces.append(ring_face)
	data.faces.append(inner_face)


static func _classify(pts: PackedVector3Array, outer2: PackedVector2Array, u: Vector3, w: Vector3, origin: Vector3) -> Array:
	var out := []
	var n := outer2.size()
	for p3 in pts:
		var rel := p3 - origin
		var p := Vector2(rel.dot(u), rel.dot(w))
		var c := {"kind": "i", "p2": p}
		for i in n:
			if p.distance_to(outer2[i]) < EPS:
				c = {"kind": "v", "pos": i, "p2": outer2[i]}
				break
		if c.kind == "i":
			for i in n:
				var a := outer2[i]
				var seg := outer2[(i + 1) % n] - a
				var len2 := seg.length_squared()
				if len2 < EPS * EPS:
					continue
				var t := (p - a).dot(seg) / len2
				if t <= 0.0 or t >= 1.0:
					continue
				var on_seg := a + seg * t
				if p.distance_to(on_seg) < EPS:
					c = {"kind": "e", "edge": i, "t": t, "p2": on_seg}
					break
		out.append(c)
	return out


static func _apply_boundary(data, face_index: int, pts: PackedVector3Array, cls: Array, outer_ids: PackedInt32Array, outer2: PackedVector2Array, outer_ccw: bool) -> void:
	var n := outer_ids.size()

	var edge_groups := {}
	for pi in cls.size():
		if cls[pi].kind == "e":
			if not edge_groups.has(cls[pi].edge):
				edge_groups[cls[pi].edge] = []
			edge_groups[cls[pi].edge].append(pi)
	for e in edge_groups:
		var group: Array = edge_groups[e]
		group.sort_custom(func(a: int, b: int) -> bool: return cls[a].t < cls[b].t)
	var p_tok := PackedInt32Array()
	var p2 := PackedVector2Array()
	for i in n:
		p_tok.append(i)
		p2.append(outer2[i])
		if edge_groups.has(i):
			for pi in edge_groups[i]:
				p_tok.append(TOK_EDGE + pi)
				p2.append(cls[pi].p2)
	var planned_pos := {}
	for k in p_tok.size():
		planned_pos[p_tok[k]] = k

	var q_tok := PackedInt32Array()
	var q2 := PackedVector2Array()
	for pi in cls.size():
		match cls[pi].kind:
			"v":
				q_tok.append(cls[pi].pos)
			"e":
				q_tok.append(TOK_EDGE + pi)
			"i":
				q_tok.append(TOK_INT + pi)
		q2.append(cls[pi].p2)
	if _area(q2) < 0.0:
		q_tok.reverse()
		q2.reverse()
	var kept_tok := PackedInt32Array()
	var kept2 := PackedVector2Array()
	for j in q_tok.size():
		if q_tok[j] != q_tok[(j + 1) % q_tok.size()]:
			kept_tok.append(q_tok[j])
			kept2.append(q2[j])
	q_tok = kept_tok
	q2 = kept2
	if q_tok.size() < 3:
		return
	var seen := {}
	for tok in q_tok:
		if seen.has(tok):
			return
		seen[tok] = true

	var touch_j := PackedInt32Array()
	for j in q_tok.size():
		if planned_pos.has(q_tok[j]):
			touch_j.append(j)
	var m := touch_j.size()
	var np := p_tok.size()
	var nq := q_tok.size()

	var regions: Array = []
	if m == 1:

		var j0 := touch_j[0]
		var p0: int = planned_pos[q_tok[j0]]
		var bridge := _find_bridge(p2, q2, p0, j0, p2[p0], q2[j0])
		if bridge == Vector2i(-1, -1):
			return
		var half_a := PackedInt32Array()
		var i := p0
		while true:
			half_a.append(p_tok[i])
			if i == bridge.x:
				break
			i = (i + 1) % np
		i = bridge.y
		while true:
			half_a.append(q_tok[i])
			if i == j0:
				break
			i = (i - 1 + nq) % nq
		var half_b := PackedInt32Array()
		i = bridge.x
		while true:
			half_b.append(p_tok[i])
			if i == p0:
				break
			i = (i + 1) % np
		i = j0
		while true:
			half_b.append(q_tok[i])
			if i == bridge.y:
				break
			i = (i - 1 + nq) % nq

		for half in [half_a, half_b]:
			var clean := _dedup_loop(half)
			if clean.size() < 3:
				return
			regions.append(clean)
	else:

		var arc_sum := 0
		for k in m:
			var pa: int = planned_pos[q_tok[touch_j[k]]]
			var pb: int = planned_pos[q_tok[touch_j[(k + 1) % m]]]
			var region := PackedInt32Array()
			var i := pa
			while true:
				region.append(p_tok[i])
				if i == pb:
					break
				i = (i + 1) % np
			arc_sum += region.size() - 1
			i = (touch_j[(k + 1) % m] - 1 + nq) % nq
			while i != touch_j[k]:
				region.append(q_tok[i])
				i = (i - 1 + nq) % nq
			if region.size() >= 3:
				regions.append(region)
		if arc_sum != np or regions.is_empty():
			return
	for r in regions:
		var distinct := {}
		for tok in r:
			if distinct.has(tok):
				return
			distinct[tok] = true

	var new_ids := {}
	var edge_points := {}
	for e in edge_groups:
		var a_id := outer_ids[e]
		var b_id := outer_ids[(e + 1) % n]
		var along := PackedInt32Array()
		for pi in edge_groups[e]:
			var vid: int = data.add_vertex(
				data.positions[a_id].lerp(data.positions[b_id], cls[pi].t))
			new_ids[TOK_EDGE + pi] = vid
			along.append(vid)
		var key: Vector2i = UBSelectQueries.edge_key(a_id, b_id)
		if a_id != key.x:
			along.reverse()
		edge_points[key] = along
	var used := {}
	for tok in q_tok:
		used[tok] = true
	for pi in cls.size():
		if cls[pi].kind == "i" and used.has(TOK_INT + pi):
			new_ids[TOK_INT + pi] = data.add_vertex(pts[pi])
	if not edge_points.is_empty():
		UBOpUtils.insert_edge_points(data, edge_points, {face_index: true})

	var face: UBFace = data.faces[face_index]
	var polys: Array = []
	for r in regions:
		polys.append(_tokens_to_ids(r, outer_ids, new_ids))
	var inner_loop := _tokens_to_ids(q_tok, outer_ids, new_ids)
	if not outer_ccw:
		for k in polys.size():
			var pl: PackedInt32Array = polys[k]
			pl.reverse()
			polys[k] = pl
		inner_loop.reverse()
	var inner_face: UBFace = face.duplicate_face()
	UBOpUtils.set_face_loop(inner_face, inner_loop)

	var field := UBOpUtils.capture_colors(data, face)
	if field != null:
		inner_face.color_corners = field.colors_for_loop(data, inner_loop)
	UBOpUtils.set_face_loop(face, polys[0])
	if field != null:
		face.color_corners = field.colors_for_loop(data, polys[0])
	for k in range(1, polys.size()):
		var ring_face: UBFace = face.duplicate_face()
		UBOpUtils.set_face_loop(ring_face, polys[k])
		if field != null:
			ring_face.color_corners = field.colors_for_loop(data, polys[k])
		data.faces.append(ring_face)
	data.faces.append(inner_face)


static func _dedup_loop(loop: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in loop.size():
		if loop[i] != loop[(i + 1) % loop.size()]:
			out.append(loop[i])
	return out


static func _tokens_to_ids(tokens: PackedInt32Array, outer_ids: PackedInt32Array, new_ids: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for tok in tokens:
		out.append(outer_ids[tok] if tok < TOK_EDGE else new_ids[tok])
	return out


static func _is_convex(pts: PackedVector2Array) -> bool:
	var n := pts.size()
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var c := pts[(i + 2) % n]
		if (b - a).cross(c - b) < -1e-9:
			return false
	return true


static func _stitch_bridged(outer_ids: PackedInt32Array, outer2: PackedVector2Array, inner_ids: PackedInt32Array, inner2: PackedVector2Array) -> Array:
	var p := outer2.size()
	var q := inner2.size()
	var b1 := _find_bridge(outer2, inner2, -1, -1, Vector2.ZERO, Vector2.ZERO)
	if b1 == Vector2i(-1, -1):
		return []
	var b2 := _find_bridge(outer2, inner2, b1.x, b1.y, outer2[b1.x], inner2[b1.y])
	if b2 == Vector2i(-1, -1):
		return []

	var half_a := PackedInt32Array()
	var i := b1.x
	while true:
		half_a.append(outer_ids[i])
		if i == b2.x:
			break
		i = (i + 1) % p
	i = b2.y
	while true:
		half_a.append(inner_ids[i])
		if i == b1.y:
			break
		i = (i - 1 + q) % q

	var half_b := PackedInt32Array()
	i = b2.x
	while true:
		half_b.append(outer_ids[i])
		if i == b1.x:
			break
		i = (i + 1) % p
	i = b1.y
	while true:
		half_b.append(inner_ids[i])
		if i == b2.y:
			break
		i = (i - 1 + q) % q
	return [half_a, half_b]


static func _find_bridge(outer2: PackedVector2Array, inner2: PackedVector2Array, skip_o: int, skip_i: int, other_from: Vector2, other_to: Vector2) -> Vector2i:
	for oi in outer2.size():
		if oi == skip_o:
			continue
		for ij in inner2.size():
			if ij == skip_i:
				continue
			if not _diagonal_ok(outer2, inner2, outer2[oi], inner2[ij], oi, ij):
				continue
			if skip_o >= 0 and _segments_cross(outer2[oi], inner2[ij], other_from, other_to):
				continue
			return Vector2i(oi, ij)
	return Vector2i(-1, -1)


static func _diagonal_ok(outer2: PackedVector2Array, inner2: PackedVector2Array, from: Vector2, to: Vector2, o_idx: int, i_idx: int) -> bool:
	var po := outer2.size()
	for i in po:
		if i == o_idx or (i + 1) % po == o_idx:
			continue
		if _segments_cross(from, to, outer2[i], outer2[(i + 1) % po]):
			return false
	var pi := inner2.size()
	for i in pi:
		if i == i_idx or (i + 1) % pi == i_idx:
			continue
		if _segments_cross(from, to, inner2[i], inner2[(i + 1) % pi]):
			return false
	var mid := (from + to) * 0.5
	if not Geometry2D.is_point_in_polygon(mid, outer2):
		return false
	if Geometry2D.is_point_in_polygon(mid, inner2):
		return false
	return true


static func _segments_cross(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	var d1 := (b - a).cross(c - a)
	var d2 := (b - a).cross(d - a)
	var d3 := (d - c).cross(a - c)
	var d4 := (d - c).cross(b - c)
	return ((d1 > 1e-9 and d2 < -1e-9) or (d1 < -1e-9 and d2 > 1e-9)) \
		and ((d3 > 1e-9 and d4 < -1e-9) or (d3 < -1e-9 and d4 > 1e-9))


static func _stitch(outer_ids: PackedInt32Array, outer2: PackedVector2Array, inner_ids: PackedInt32Array, inner2: PackedVector2Array) -> Array:
	var c := Vector2.ZERO
	for p in inner2:
		c += p
	c /= inner2.size()
	var o := _rotated_unwrapped(outer_ids, outer2, c)
	var h := _rotated_unwrapped(inner_ids, inner2, c)

	var oa: PackedFloat64Array = o.angles
	var ha: PackedFloat64Array = h.angles
	while ha[0] < oa[0]:
		for k in ha.size():
			ha[k] += TAU
	while ha[0] >= oa[0] + TAU:
		for k in ha.size():
			ha[k] -= TAU
	var oi: PackedInt32Array = o.ids
	var hi: PackedInt32Array = h.ids
	var p_count := oi.size()
	var q_count := hi.size()

	var a := 0
	for i in range(1, p_count):
		if oa[i] <= ha[0]:
			a = i
	var a_end := a + p_count
	var polys := []
	for b in q_count:
		var poly := PackedInt32Array([oi[a % p_count]])

		while a < a_end and _ang(oa, a + 1) <= _ang(ha, b + 1):
			a += 1
			poly.append(oi[a % p_count])
		poly.append(hi[(b + 1) % q_count])
		poly.append(hi[b])
		polys.append(poly)
	return polys


static func _rotated_unwrapped(ids: PackedInt32Array, pts: PackedVector2Array, c: Vector2) -> Dictionary:
	var n := ids.size()
	var raw := PackedFloat64Array()
	var min_i := 0
	for i in n:
		raw.append((pts[i] - c).angle())
		if raw[i] < raw[min_i]:
			min_i = i
	var out_ids := PackedInt32Array()
	var angles := PackedFloat64Array()
	for k in n:
		var i := (min_i + k) % n
		var ang := raw[i]
		while not angles.is_empty() and ang < angles[angles.size() - 1]:
			ang += TAU
		out_ids.append(ids[i])
		angles.append(ang)
	return {"ids": out_ids, "angles": angles}


static func _ang(angles: PackedFloat64Array, k: int) -> float:
	var n := angles.size()
	return angles[k % n] + TAU * float(k / n)


static func _area(pts: PackedVector2Array) -> float:
	var area := 0.0
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		area += a.x * b.y - b.x * a.y
	return area * 0.5
