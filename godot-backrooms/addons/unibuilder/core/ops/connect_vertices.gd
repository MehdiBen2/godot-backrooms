@tool
class_name UBOpConnectVertices
extends RefCounted
## Insert chords between selected vertices on each face. Two selected verts
## split the face in two; more split repeatedly: each pass connects the first
## consecutive-in-loop-order pair of selected verts that is not already an
## edge, and the resulting sub-faces are re-examined, so k selected corners
## fan a face into k parts (alternating corners of a hexagon yield three rim
## faces and a center triangle). Every chord ends up shared by exactly two
## faces.


static func apply(data, vert_set: Dictionary) -> void:
	var changed := true
	var guard: int = data.faces.size() + vert_set.size() * 8 + 8
	while changed and guard > 0:
		guard -= 1
		changed = false

		var topo := UBTopology.build(data)
		for fi in data.faces.size():
			if _split_face(data, fi, vert_set, topo):
				changed = true
				break


static func _split_face(data, fi: int, vert_set: Dictionary, topo) -> bool:
	var verts: PackedInt32Array = data.faces[fi].vertices
	var n := verts.size()
	var picked: Array[int] = []
	for i in n:
		if vert_set.has(verts[i]):
			picked.append(i)
	if picked.size() < 2:
		return false

	var lp := UBOpUtils.loop_plane(data, verts)
	if lp == null:
		return false
	for j in picked.size():
		var i0: int = picked[j]
		var i1: int = picked[(j + 1) % picked.size()]
		var span := (i1 - i0 + n) % n
		if span <= 1 or span >= n - 1:
			continue

		if UBOpUtils.is_real_edge(topo, UBSelectQueries.edge_key(verts[i0], verts[i1])):
			continue
		if not UBOpUtils.chord_inside(lp, i0, i1):
			continue
		var first := PackedInt32Array()
		for k in range(i0, i0 + span + 1):
			first.append(verts[k % n])
		var second := PackedInt32Array()
		var k := i1
		while true:
			second.append(verts[k % n])
			if k % n == i0:
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
		return true
	return false
