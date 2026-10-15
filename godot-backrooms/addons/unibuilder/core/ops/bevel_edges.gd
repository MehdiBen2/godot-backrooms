@tool
class_name UBOpBevelEdges
extends RefCounted
## Chamfer bevel of selected interior edges (those with 2 faces; boundary edges
## are skipped). With `segments` > 1 the flat chamfer becomes N strips along a
## circular arc between the two slide positions at each endpoint, and corner
## cuts in vertex-only faces splice the whole arc polyline.
## Per face, each corner touching a selected edge is replaced: with one
## selected loop edge the corner slides along the other loop edge; with both
## selected it is cut into two vertices sliding along each. Slides are keyed
## (vertex, slide-target), so coincident slides from different faces weld into
## one vertex. A chamfer quad is added per edge. Vertex-only faces (touching a
## beveled endpoint but no selected edge) get the corner cut between the two
## slides on their incident edges, or, when only one incident edge carries a
## slide, keep the vertex with the slide inserted inline, so no T-junctions
## appear. Newly created corner holes are filled; pre-existing open rims are
## not. Slides clamp to 45% of the edge slid along.


## `world_transform` is only needed to reproduce world-anchored auto-UVs when
## wrapping the chamfer; identity is right for a local-space caller.
static func apply(data, edge_set: Dictionary, distance: float, segments := 1,
		smooth := false, world_transform := Transform3D.IDENTITY) -> void:
	segments = maxi(1, segments)
	if distance <= 0.0:
		return
	var topo := UBTopology.build(data)

	edge_set = UBOpUtils.valid_edges(topo, edge_set)
	var selected := {}
	for e: Vector2i in edge_set:
		if topo.edge_faces.get(e, []).size() == 2:
			selected[e] = true
	var back_keys := _plan_reflex(data, topo, selected)
	if selected.is_empty():
		_bevel_boundary(data, edge_set, distance)
		return
	var old_vertex_count: int = data.positions.size()
	var pre_boundary := {}
	for key: Vector2i in topo.edge_faces:
		if topo.edge_faces[key].size() == 1:
			pre_boundary[key] = true

	var traverses_xy := {}
	for e: Vector2i in selected:
		var m := {}
		for fi in topo.edge_faces[e]:
			var verts: PackedInt32Array = data.faces[fi].vertices
			for i in verts.size():
				var a := verts[i]
				var b := verts[(i + 1) % verts.size()]
				if a == e.x and b == e.y:
					m[fi] = true
				elif a == e.y and b == e.x:
					m[fi] = false
		traverses_xy[e] = m

	var fields := {}
	for e: Vector2i in selected:
		for fi in topo.edge_faces[e]:
			if not fields.has(fi):
				fields[fi] = UBOpUtils.capture_colors(data, data.faces[fi])

	var slide_vert := {}
	var corner_for_edge := {}
	for fi in data.faces.size():
		var verts: PackedInt32Array = data.faces[fi].vertices
		var n := verts.size()
		var out := PackedInt32Array()
		var changed := false
		for i in n:
			var v := verts[i]
			var prev := verts[(i - 1 + n) % n]
			var next := verts[(i + 1) % n]
			var sel_prev := selected.has(UBSelectQueries.edge_key(prev, v))
			var sel_next := selected.has(UBSelectQueries.edge_key(v, next))
			if not sel_prev and not sel_next:
				out.append(v)
				continue
			changed = true
			if sel_prev and sel_next:
				var v1 := _slide(data, slide_vert, v, prev, distance, back_keys)
				var v2 := _slide(data, slide_vert, v, next, distance, back_keys)
				out.append(v1)
				out.append(v2)

				corner_for_edge[Vector3i(fi, v, prev)] = v1
				corner_for_edge[Vector3i(fi, v, next)] = v2
			elif sel_next:
				var s := _slide(data, slide_vert, v, prev, distance, back_keys)
				out.append(s)
				corner_for_edge[Vector3i(fi, v, next)] = s
			else:
				var s := _slide(data, slide_vert, v, next, distance, back_keys)
				out.append(s)
				corner_for_edge[Vector3i(fi, v, prev)] = s
		if changed:

			var uv_map := _manual_uv_map(data, data.faces[fi])
			data.faces[fi].vertices = out
			if not uv_map.is_empty():
				data.faces[fi].uv_coords = _map_loop_uvs(data, uv_map, out)

			var field = fields.get(fi)
			if field != null:
				data.faces[fi].color_corners = field.colors_for_loop(data, out)

	var arcs := {}
	var edge_arcs := {}
	for e: Vector2i in selected:
		var m: Dictionary = traverses_xy[e]
		var fis: Array = m.keys()
		if fis.size() != 2:
			continue
		var f1: int = fis[0] if m[fis[0]] else fis[1]
		var f2: int = fis[1] if m[fis[0]] else fis[0]
		var a1: int = corner_for_edge.get(Vector3i(f1, e.x, e.y), -1)
		var b1: int = corner_for_edge.get(Vector3i(f1, e.y, e.x), -1)
		var a2: int = corner_for_edge.get(Vector3i(f2, e.x, e.y), -1)
		var b2: int = corner_for_edge.get(Vector3i(f2, e.y, e.x), -1)
		if a1 < 0 or b1 < 0 or a2 < 0 or b2 < 0:
			continue

		var on_x := Vector2i(e.x, e.y)
		var on_y := Vector2i(e.y, e.x)
		var x1_on: bool = slide_vert.get(on_x, -2) == a1
		var x2_on: bool = slide_vert.get(on_x, -2) == a2
		var y1_on: bool = slide_vert.get(on_y, -2) == b1
		var y2_on: bool = slide_vert.get(on_y, -2) == b2
		var twisted := (x1_on and y2_on and not x2_on and not y1_on) \
				or (x2_on and y1_on and not x1_on and not y2_on)
		var segs := 1 if twisted else segments
		var arc_x := _shared_arc(data, arcs, e.x, a1, a2, segs)
		var arc_y := _shared_arc(data, arcs, e.y, b1, b2, segs)
		edge_arcs[e] = [arc_x, arc_y, f1, f2]

	var origin := {}
	var cut_pairs := {}
	for key: Vector2i in slide_vert:
		origin[slide_vert[key]] = key.x
	for fi in data.faces.size():
		var verts: PackedInt32Array = data.faces[fi].vertices
		var n := verts.size()
		var out := PackedInt32Array()
		var changed := false
		for i in n:
			var v := verts[i]
			var prev := verts[(i - 1 + n) % n]
			var next := verts[(i + 1) % n]
			var ov: int = origin.get(v, v)
			var oprev: int = origin.get(prev, prev)
			var onext: int = origin.get(next, next)
			var s_prev := -1
			var s_next := -1

			if ov == v:
				s_prev = _edge_slide(slide_vert, selected, v, oprev)
				s_next = _edge_slide(slide_vert, selected, v, onext)
			if s_prev >= 0 and s_next >= 0:
				cut_pairs[_pair(s_prev, s_next)] = true
				var arc: PackedInt32Array = arcs.get(
					_pair(s_prev, s_next), PackedInt32Array([s_prev, s_next]))
				if arc[0] != s_prev:
					arc = arc.duplicate()
					arc.reverse()
				out.append_array(arc)
				changed = true
			else:
				out.append(v)
				if s_next >= 0 and s_next != next:
					out.append(s_next)
					changed = true

			if onext == ov:
				continue
			var s_from_next := _edge_slide(slide_vert, selected, onext, ov)
			if s_from_next >= 0 and s_from_next != v and s_from_next != next:
				var next2 := verts[(i + 2) % n]
				var onext2: int = origin.get(next2, next2)
				if onext != next or _edge_slide(slide_vert, selected, next, onext2) < 0:
					out.append(s_from_next)
					changed = true
		if changed:

			var uv_map := _manual_uv_map(data, data.faces[fi])
			var field := UBOpUtils.capture_colors(data, data.faces[fi])
			data.faces[fi].vertices = out
			if not uv_map.is_empty():
				data.faces[fi].uv_coords = _map_loop_uvs(data, uv_map, out)
			if field != null:
				data.faces[fi].color_corners = field.colors_for_loop(data, out)

	var first_new_face: int = data.faces.size()

	var kept := {}
	for f: UBFace in data.faces:
		for vi in f.vertices:
			kept[vi] = true

	for e: Vector2i in edge_arcs:
		var arc_x: PackedInt32Array = edge_arcs[e][0]
		var arc_y: PackedInt32Array = edge_arcs[e][1]
		var f1: int = edge_arcs[e][2]
		var f2: int = edge_arcs[e][3]
		var uv_for := _wrap_uvs(data, f1, arc_x, arc_y, world_transform)
		var col_for := _band_colors(data, fields, f1, f2, arc_x, arc_y)

		var mid_x := _straight_mid(data, arc_x, e.x, kept, cut_pairs)
		var mid_y := _straight_mid(data, arc_y, e.y, kept, cut_pairs)
		_lerp_mid(data, uv_for, col_for, arc_x, mid_x)
		_lerp_mid(data, uv_for, col_for, arc_y, mid_y)
		for i in segments:

			var raw := PackedInt32Array([_arc_at(arc_y, i), _arc_at(arc_x, i)])
			if mid_x >= 0 and _arc_at(arc_x, i) != _arc_at(arc_x, i + 1):
				raw.append(mid_x)
			raw.append(_arc_at(arc_x, i + 1))
			raw.append(_arc_at(arc_y, i + 1))
			if mid_y >= 0 and _arc_at(arc_y, i) != _arc_at(arc_y, i + 1):
				raw.append(mid_y)
			var loop := _dedup_loop(raw)
			if loop.size() < 3:
				continue
			var strip: UBFace = data.faces[f1].duplicate_face()
			UBOpUtils.set_face_loop(strip, loop)

			if not uv_for.is_empty():
				var coords := PackedVector2Array()
				for v in loop:
					coords.append(uv_for.get(v, Vector2.ZERO))
				strip.uv_coords = coords
				strip.uv_manual = true
			if not col_for.is_empty():
				var band_cols := PackedColorArray()
				for v in loop:
					band_cols.append(col_for.get(v, Color.WHITE))
				strip.color_corners = band_cols
			data.faces.append(strip)

	_fill_new_holes(data, pre_boundary)
	_bevel_boundary(data, edge_set, distance)
	if smooth:

		var group := 1
		for fi in first_new_face:
			group = maxi(group, data.faces[fi].smoothing_group + 1)
		for fi in range(first_new_face, data.faces.size()):
			data.faces[fi].smoothing_group = group
	UBOpUtils.remove_unused_vertices(data)


static func _bevel_boundary(data, edge_set: Dictionary, distance: float) -> void:

	var topo: UBTopology = null
	for e: Vector2i in edge_set:
		if topo == null:
			topo = UBTopology.build(data)
		var sharers: Array = topo.edge_faces.get(e, [])
		if sharers.size() != 1:
			continue
		var fi: int = sharers[0]
		var verts: PackedInt32Array = data.faces[fi].vertices
		var n := verts.size()
		var ai := -1
		var a := -1
		var b := -1
		for i in n:
			if UBSelectQueries.edge_key(verts[i], verts[(i + 1) % n]) == e:
				ai = i
				a = verts[i]
				b = verts[(i + 1) % n]
				break
		if ai < 0:
			continue
		var prev: int = verts[(ai - 1 + n) % n]
		var next: int = verts[(ai + 2) % n]
		if prev == b or next == a:
			continue
		var pa: Vector3 = data.positions[a]
		var pb: Vector3 = data.positions[b]
		var da: Vector3 = data.positions[prev] - pa
		var db: Vector3 = data.positions[next] - pb
		if da.length() < 1e-6 or db.length() < 1e-6:
			continue
		var a2: int = data.add_vertex(pa + da.normalized() * minf(distance, da.length() * 0.45))
		var b2: int = data.add_vertex(pb + db.normalized() * minf(distance, db.length() * 0.45))
		var out := PackedInt32Array()
		for i in n:
			if verts[i] == a:
				out.append(a2)
			elif verts[i] == b:
				out.append(b2)
			else:
				out.append(verts[i])

		var uv_map := _manual_uv_map(data, data.faces[fi])
		var field := UBOpUtils.capture_colors(data, data.faces[fi])
		data.faces[fi].vertices = out
		if not uv_map.is_empty():
			data.faces[fi].uv_coords = _map_loop_uvs(data, uv_map, out)
		if field != null:
			data.faces[fi].color_corners = field.colors_for_loop(data, out)
		var strip: UBFace = data.faces[fi].duplicate_face()
		var strip_loop := PackedInt32Array([a, b, b2, a2])
		UBOpUtils.set_face_loop(strip, strip_loop)
		if not uv_map.is_empty():
			strip.uv_coords = _map_loop_uvs(data, uv_map, strip_loop)
			strip.uv_manual = true
		if field != null:
			strip.color_corners = field.colors_for_loop(data, strip_loop)
		data.faces.append(strip)
		topo = null


static func _wrap_uvs(data, f1: int, arc_x: PackedInt32Array, arc_y: PackedInt32Array,
		world_transform: Transform3D) -> Dictionary:
	var face: UBFace = data.faces[f1]
	var verts: PackedInt32Array = face.vertices
	var a1: int = arc_x[0]
	var b1: int = arc_y[0]
	var ai := verts.find(a1)
	var bi := verts.find(b1)
	if ai < 0 or bi < 0:
		return {}
	var corners := PackedVector3Array()
	for v in verts:
		corners.append(data.positions[v])
	var normal: Vector3 = data.face_normal(face)
	var uvs := (
		face.uv_coords
		if face.uv_manual and face.uv_coords.size() == verts.size()
		else UBUVUnwrap.face_uvs(corners, normal, face, world_transform)
	)
	var pa: Vector3 = data.positions[a1]
	var pb: Vector3 = data.positions[b1]
	var along := pb - pa
	var length := along.length()
	if length < 1e-9:
		return {}
	along /= length

	var outward := normal.cross(along).normalized()
	if outward.length_squared() < 0.5:
		return {}
	if outward.dot(data.face_center(face) - (pa + pb) * 0.5) > 0.0:
		outward = -outward

	var uv_map := _fit_uv_map(corners, uvs, along, outward)
	if uv_map.is_empty():
		return {}
	var grad: Vector2 = uv_map[5]
	var wrapped := {}
	_wrap_rail(data, arc_x, uvs[ai], grad, wrapped)
	_wrap_rail(data, arc_y, uvs[bi], grad, wrapped)
	return wrapped


static func _wrap_rail(data, arc: PackedInt32Array, uv0: Vector2, grad: Vector2,
		out: Dictionary) -> void:
	var travelled := 0.0
	out[arc[0]] = uv0
	for i in range(1, arc.size()):
		travelled += data.positions[arc[i - 1]].distance_to(data.positions[arc[i]])
		out[arc[i]] = uv0 + grad * travelled


static func _fit_uv_map(corners: PackedVector3Array, uvs: PackedVector2Array,
		u_dir: Vector3, v_dir: Vector3) -> Array:
	var n := corners.size()
	if n < 3 or uvs.size() != n:
		return []
	var mean := Vector2.ZERO
	var mean_uv := Vector2.ZERO
	for i in n:
		mean += Vector2(corners[i].dot(u_dir), corners[i].dot(v_dir))
		mean_uv += uvs[i]
	mean /= n
	mean_uv /= n
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	var sxu := Vector2.ZERO
	var syu := Vector2.ZERO
	for i in n:
		var l := Vector2(corners[i].dot(u_dir), corners[i].dot(v_dir)) - mean
		var duv := uvs[i] - mean_uv
		sxx += l.x * l.x
		sxy += l.x * l.y
		syy += l.y * l.y
		sxu += duv * l.x
		syu += duv * l.y
	var det := sxx * syy - sxy * sxy
	var span := sxx + syy

	if span < 1e-18 or det < 1e-9 * span * span:
		return []
	return [u_dir, v_dir, mean, mean_uv,
		(sxu * syy - syu * sxy) / det, (syu * sxx - sxu * sxy) / det]


static func _eval_uv_map(uv_map: Array, p: Vector3) -> Vector2:
	var l := Vector2(p.dot(uv_map[0]), p.dot(uv_map[1])) - (uv_map[2] as Vector2)
	return (uv_map[3] as Vector2) + (uv_map[4] as Vector2) * l.x + (uv_map[5] as Vector2) * l.y


static func _manual_uv_map(data, face: UBFace) -> Array:
	if not face.uv_manual or face.uv_coords.size() != face.vertices.size():
		return []
	var corners := PackedVector3Array()
	for v in face.vertices:
		corners.append(data.positions[v])
	var frame: Array = UBUVUnwrap.projection_frame(data.face_normal(face))
	return _fit_uv_map(corners, face.uv_coords, frame[0], frame[1])


static func _map_loop_uvs(data, uv_map: Array, loop: PackedInt32Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in loop:
		out.append(_eval_uv_map(uv_map, data.positions[v]))
	return out


static func _band_colors(data, fields: Dictionary, f1: int, f2: int,
		arc_x: PackedInt32Array, arc_y: PackedInt32Array) -> Dictionary:
	var fld1 = fields.get(f1)
	var fld2 = fields.get(f2)
	if fld1 == null and fld2 == null:
		return {}
	var out := {}
	for arc: PackedInt32Array in [arc_x, arc_y]:
		var near: Color = (
			fld1.color_at(data.positions[arc[0]]) if fld1 != null
			else data.faces[f1].color)
		var far: Color = (
			fld2.color_at(data.positions[arc[arc.size() - 1]]) if fld2 != null
			else data.faces[f2].color)
		var m := arc.size() - 1
		for i in arc.size():
			out[arc[i]] = near.lerp(far, float(i) / float(m) if m > 0 else 0.0)
	return out


static func _straight_mid(data, arc: PackedInt32Array, corner: int, kept: Dictionary,
		cut_pairs: Dictionary) -> int:
	if arc.size() != 2 or not kept.has(corner) or arc.has(corner) \
			or cut_pairs.has(_pair(arc[0], arc[1])):
		return -1
	if not _is_straight(data.positions[arc[0]] - data.positions[corner],
			data.positions[arc[1]] - data.positions[corner]):
		return -1
	return corner


static func _lerp_mid(data, uv_for: Dictionary, col_for: Dictionary,
		arc: PackedInt32Array, mid: int) -> void:
	if mid < 0:
		return
	var p0: Vector3 = data.positions[arc[0]]
	var span: float = p0.distance_to(data.positions[arc[1]])
	var t: float = p0.distance_to(data.positions[mid]) / span if span > 0.0 else 0.5
	if uv_for.has(arc[0]) and uv_for.has(arc[1]):
		uv_for[mid] = (uv_for[arc[0]] as Vector2).lerp(uv_for[arc[1]], t)
	if col_for.has(arc[0]) and col_for.has(arc[1]):
		col_for[mid] = (col_for[arc[0]] as Color).lerp(col_for[arc[1]], t)


static func _is_straight(d1: Vector3, d2: Vector3) -> bool:
	return d1.cross(d2).length_squared() <= 1e-12 * d1.length_squared() * d2.length_squared() \
			and d1.dot(d2) < 0.0


static func _arc_at(arc: PackedInt32Array, i: int) -> int:
	return arc[clampi(i, 0, arc.size() - 1)]


static func _dedup_loop(loop: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for v in loop:
		if out.is_empty() or out[out.size() - 1] != v:
			out.append(v)
	while out.size() > 1 and out[0] == out[out.size() - 1]:
		out.remove_at(out.size() - 1)
	return out


static func _pair(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


static func _shared_arc(data, arcs: Dictionary, corner: int, i1: int, i2: int,
		segments: int) -> PackedInt32Array:
	var key := _pair(i1, i2)
	var arc: PackedInt32Array
	if arcs.has(key):
		arc = arcs[key]
	else:
		arc = _arc_points(data, data.positions[corner], i1, i2, segments)
		arcs[key] = arc
	if arc[0] != i1:
		arc = arc.duplicate()
		arc.reverse()
	return arc


static func _arc_points(data, c: Vector3, i1: int, i2: int, segments: int) -> PackedInt32Array:
	if i1 == i2:

		return PackedInt32Array([i1])
	var pts := PackedInt32Array([i1])

	var straight := _is_straight(data.positions[i1] - c, data.positions[i2] - c)
	if segments > 1 and not straight:
		var m: Vector3 = data.positions[i1] + data.positions[i2] - c
		var a: Vector3 = data.positions[i1] - m
		var b: Vector3 = data.positions[i2] - m
		for s in range(1, segments):
			var t := float(s) / float(segments) * PI * 0.5
			pts.append(data.add_vertex(m + a * cos(t) + b * sin(t)))
	pts.append(i2)
	return pts


static func _plan_reflex(data, topo: UBTopology, selected: Dictionary) -> Dictionary:
	var normals := []
	for f: UBFace in data.faces:
		var pts := PackedVector3Array()
		for vi in f.vertices:
			pts.append(data.positions[vi])
		normals.append(UBTriangulate.newell_normal(pts) if pts.size() >= 3 else Vector3.ZERO)
	while true:
		var uses := {}
		var back := {}
		for fi in data.faces.size():
			var verts: PackedInt32Array = data.faces[fi].vertices
			var n := verts.size()
			for i in n:
				var v := verts[i]
				var prev := verts[(i - 1 + n) % n]
				var next := verts[(i + 1) % n]
				var sel_prev := selected.has(UBSelectQueries.edge_key(prev, v))
				var sel_next := selected.has(UBSelectQueries.edge_key(v, next))
				if not sel_prev and not sel_next:
					continue
				if sel_prev and sel_next:

					uses[Vector2i(v, prev)] = uses.get(Vector2i(v, prev), 0) + 1
					uses[Vector2i(v, next)] = uses.get(Vector2i(v, next), 0) + 1
					continue
				var toward := prev if sel_next else next
				var sel_end := next if sel_next else prev
				var key := Vector2i(v, toward)
				uses[key] = uses.get(key, 0) + 1
				var normal: Vector3 = normals[fi]
				if normal.length_squared() < 1e-20:
					continue
				var pv: Vector3 = data.positions[v]

				var along: Vector3 = (
					data.positions[next] - pv if sel_next else pv - data.positions[prev])
				var slide: Vector3 = data.positions[toward] - pv
				var inward := normal.cross(along)
				if slide.dot(inward) < -1e-6 * slide.length() * inward.length():
					back[key] = [UBSelectQueries.edge_key(v, sel_end), sel_end, fi]
		var dropped := false
		for key: Vector2i in back:
			if not _mitre_ok(data, topo, uses, key, back[key][2]):
				selected.erase(back[key][0])
				dropped = true
		if not dropped:
			var out := {}
			for key: Vector2i in back:
				out[key] = back[key][1]
			return out
		if selected.is_empty():
			return {}
	return {}


static func _mitre_ok(data, topo: UBTopology, uses: Dictionary, key: Vector2i, fi: int) -> bool:
	if uses.get(key, 0) != 1:
		return false
	var sharers: Array = topo.edge_faces.get(UBSelectQueries.edge_key(key.x, key.y), [])
	if sharers.size() != 2:
		return false
	var gi: int = sharers[0] if sharers[1] == fi else sharers[1]
	if gi == fi:
		return false
	var gv: PackedInt32Array = data.faces[gi].vertices
	var n := gv.size()
	var i := gv.find(key.x)
	if i < 0:
		return false
	var prev := gv[(i - 1 + n) % n]
	var next := gv[(i + 1) % n]
	var other := next if prev == key.y else prev
	return uses.has(Vector2i(key.x, other))


static func _edge_slide(slide_vert: Dictionary, selected: Dictionary, v: int, toward: int) -> int:
	if v == toward or selected.has(UBSelectQueries.edge_key(v, toward)):
		return -1
	return slide_vert.get(Vector2i(v, toward), -1)


static func _slide(data, slide_vert: Dictionary, v: int, toward: int, distance: float,
		back_keys := {}) -> int:
	var key := Vector2i(v, toward)
	if slide_vert.has(key):
		return slide_vert[key]
	var pv: Vector3 = data.positions[v]
	var pt: Vector3 = data.positions[toward]
	var d := minf(distance, pv.distance_to(pt) * 0.45)
	var dir := (pt - pv).normalized()
	if back_keys.has(key):

		var sel_end: int = back_keys[key]
		d = minf(d, pv.distance_to(data.positions[sel_end]) * 0.45)
		dir = -dir
	var idx: int = data.add_vertex(pv + dir * d)
	slide_vert[key] = idx
	return idx


static func _patch_colors(data, loop: PackedInt32Array) -> PackedColorArray:
	var cols := PackedColorArray()
	var any_painted := false
	for vi in loop:
		var sum := Color(0, 0, 0, 0)
		var count := 0
		for f: UBFace in data.faces:
			var idx: int = f.vertices.find(vi)
			if idx < 0:
				continue
			if f.color_corners.size() == f.vertices.size():
				sum += f.color_corners[idx]
				any_painted = true
			else:
				sum += f.color
			count += 1
		cols.append(sum / count if count > 0 else Color.WHITE)
	return cols if any_painted else PackedColorArray()


static func _fill_new_holes(data, pre_boundary: Dictionary) -> void:
	var topo := UBTopology.build(data)
	var directed := {}
	var owner_material := {}
	var ambiguous := {}
	for f in data.faces:
		var verts: PackedInt32Array = f.vertices
		for i in verts.size():
			var a := verts[i]
			var b := verts[(i + 1) % verts.size()]
			if topo.edge_faces.get(UBSelectQueries.edge_key(a, b), []).size() == 1:
				if directed.has(a):
					ambiguous[a] = true
				directed[a] = b
				owner_material[a] = f.material_index
	var visited := {}
	for start in directed.keys():
		if visited.has(start):
			continue
		var loop := PackedInt32Array([start])
		var qualifies: bool = not ambiguous.has(start)
		var cur: int = directed[start]
		var closed := false
		var guard: int = directed.size() + 1
		while guard > 0:
			guard -= 1
			if pre_boundary.has(UBSelectQueries.edge_key(loop[loop.size() - 1], cur)):
				qualifies = false
			if cur == start:
				closed = true
				break
			if ambiguous.has(cur) or not directed.has(cur):
				qualifies = false
				break
			loop.append(cur)
			cur = directed[cur]
		for v in loop:
			visited[v] = true
		if not closed or not qualifies or loop.size() < 3:
			continue
		var material: int = owner_material.get(start, 0)
		loop.reverse()
		var patch := UBFace.new()
		patch.vertices = loop
		patch.material_index = material

		var patch_cols := _patch_colors(data, loop)
		if not patch_cols.is_empty():
			patch.color_corners = patch_cols
		data.faces.append(patch)
