@tool
class_name UBOpInsertLoop
extends RefCounted
## Insert `cuts` evenly spaced edge loops along the ring through `start_edge`:
## every ring edge gets `cuts` points, ring quads bordered by two opposite ring
## edges are cut into cuts+1 strips, and non-ring neighbors (caps, boundaries)
## get the points inserted as collinear vertices so no T-junctions appear.
## cuts=1 is the classic single midpoint loop.


static func apply(data, start_edge: Vector2i, cuts := 1) -> void:
	cuts = maxi(1, cuts)
	var topo := UBTopology.build(data)
	if not UBOpUtils.is_real_edge(topo, start_edge):
		return
	var ring: Array[Vector2i] = UBSelectQueries.edge_ring(data, topo, start_edge)
	if ring.is_empty():
		return
	var ring_set := {}
	for e in ring:
		ring_set[e] = true

	var points := {}
	for e: Vector2i in ring:
		var list := PackedInt32Array()
		for s in range(1, cuts + 1):
			list.append(data.add_vertex(
				data.positions[e.x].lerp(data.positions[e.y], float(s) / float(cuts + 1))))
		points[e] = list

	var original_count: int = data.faces.size()
	for fi in original_count:
		var verts: PackedInt32Array = data.faces[fi].vertices
		if verts.size() != 4:
			continue
		var hits: Array[int] = []
		for i in 4:
			if ring_set.has(UBSelectQueries.edge_key(verts[i], verts[(i + 1) % 4])):
				hits.append(i)
		if hits.size() != 2 or hits[1] - hits[0] != 2:
			continue
		var i0: int = hits[0]
		var v0 := verts[i0]
		var v1 := verts[(i0 + 1) % 4]
		var v2 := verts[(i0 + 2) % 4]
		var v3 := verts[(i0 + 3) % 4]

		var a_seq := _seq(points, v0, v1)
		var b_seq := _seq(points, v3, v2)

		var field := UBOpUtils.capture_colors(data, data.faces[fi])
		var template: UBFace = data.faces[fi].duplicate_face()
		var first_loop := PackedInt32Array([a_seq[0], a_seq[1], b_seq[1], b_seq[0]])
		UBOpUtils.set_face_loop(data.faces[fi], first_loop)
		if field != null:
			data.faces[fi].color_corners = field.colors_for_loop(data, first_loop)
		for j in range(1, cuts + 1):
			var strip: UBFace = template.duplicate_face()
			var strip_loop := PackedInt32Array([a_seq[j], a_seq[j + 1], b_seq[j + 1], b_seq[j]])
			UBOpUtils.set_face_loop(strip, strip_loop)
			if field != null:
				strip.color_corners = field.colors_for_loop(data, strip_loop)
			data.faces.append(strip)

	UBOpUtils.insert_edge_points(data, points)


static func _seq(points: Dictionary, from: int, to: int) -> PackedInt32Array:
	var key := UBSelectQueries.edge_key(from, to)
	var list: PackedInt32Array = points[key]
	var seq := PackedInt32Array([from])
	if from == key.x:
		seq.append_array(list)
	else:
		for i in range(list.size() - 1, -1, -1):
			seq.append(list[i])
	seq.append(to)
	return seq
