@tool
class_name UBOpConnectEdges
extends RefCounted
## Connect selected edges through their midpoints: every face containing
## exactly two selected edges is split in two through the midpoints (a partial
## loop insert); other faces sharing a selected edge get the midpoint inserted
## inline, keeping topology consistent.


static func apply(data, edge_set: Dictionary) -> void:

	edge_set = UBOpUtils.valid_edges(UBTopology.build(data), edge_set)
	var mids := {}
	for e: Vector2i in edge_set:
		if e.x >= 0 and e.x < data.positions.size() and e.y >= 0 and e.y < data.positions.size():
			mids[e] = data.add_vertex((data.positions[e.x] + data.positions[e.y]) * 0.5)
	if mids.is_empty():
		return
	var split_faces := {}
	var chords := {}
	var original_count: int = data.faces.size()
	for fi in original_count:
		var verts: PackedInt32Array = data.faces[fi].vertices
		var n := verts.size()

		var expanded := PackedInt32Array()
		var mid_positions: Array[int] = []
		for i in n:
			expanded.append(verts[i])
			var key := UBSelectQueries.edge_key(verts[i], verts[(i + 1) % n])
			if mids.has(key):
				mid_positions.append(expanded.size())
				expanded.append(mids[key])
		if mid_positions.size() != 2:
			continue
		var a: int = mid_positions[0]
		var b: int = mid_positions[1]

		var lp := UBOpUtils.loop_plane(data, expanded)
		if lp == null or not UBOpUtils.chord_inside(lp, a, b):
			continue

		var chord := UBSelectQueries.edge_key(expanded[a], expanded[b])
		if chords.has(chord):
			continue
		chords[chord] = true
		split_faces[fi] = true
		var m := expanded.size()
		var first := PackedInt32Array()
		for k in range(a, b + 1):
			first.append(expanded[k])
		var second := PackedInt32Array()
		var k := b
		while true:
			second.append(expanded[k % m])
			if k % m == a:
				break
			k += 1

		var field := UBOpUtils.capture_colors(data, data.faces[fi])
		var extra: UBFace = data.faces[fi].duplicate_face()
		UBOpUtils.set_face_loop(extra, second)
		UBOpUtils.set_face_loop(data.faces[fi], first)
		if field != null:
			extra.color_corners = field.colors_for_loop(data, second)
			data.faces[fi].color_corners = field.colors_for_loop(data, first)
		data.faces.append(extra)
	UBOpUtils.insert_edge_points(data, mids, split_faces)
