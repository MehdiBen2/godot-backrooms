@tool
class_name UBOpMergeFaces
extends RefCounted
## Merge the selected faces into one n-gon by chaining their boundary directed
## edges. A no-op when the region is not a single loop: disconnected
## selections, holes, or bow-tie vertices. Interior vertices are compacted.
##
## When any merged face carries per-corner colors, each boundary corner of the
## result averages what the source faces held at that vertex: a painted face
## contributes its corner color, an unpainted one its uniform color. Brush
## strokes paint every corner sharing a vertex the same, so their values are
## kept exactly; per-face fill seams blend at the boundary. Interior vertices
## vanish with their colors. Manual UVs degrade to auto.


static func apply(data, face_set: Dictionary) -> void:
	if face_set.size() < 2:
		return
	var edge_count := {}
	for fi in face_set:

		if not (fi is int) or fi < 0 or fi >= data.faces.size():
			return
		for e in UBSelectQueries.face_edges(data.faces[fi]):
			edge_count[e] = edge_count.get(e, 0) + 1
	var directed := {}
	for fi in face_set:
		var verts: PackedInt32Array = data.faces[fi].vertices
		for i in verts.size():
			var a := verts[i]
			var b := verts[(i + 1) % verts.size()]
			if edge_count[UBSelectQueries.edge_key(a, b)] == 1:
				if directed.has(a):
					return
				directed[a] = b
	if directed.is_empty():
		return
	var start: int = directed.keys()[0]
	var loop := PackedInt32Array([start])
	var cur: int = directed[start]
	var guard: int = directed.size() + 1
	while cur != start:
		if not directed.has(cur) or guard <= 0:
			return
		loop.append(cur)
		cur = directed[cur]
		guard -= 1
	if loop.size() != directed.size():
		return
	var indices: Array = face_set.keys()
	indices.sort()
	var target: int = indices[0]

	var has_colors := false
	for fi in face_set:
		var f: UBFace = data.faces[fi]
		if f.color_corners.size() == f.vertices.size():
			has_colors = true
			break
	var cols := PackedColorArray()
	if has_colors:
		for vi in loop:
			cols.append(_vertex_color(data, face_set, vi))
	UBOpUtils.set_face_loop(data.faces[target], loop)
	if has_colors:
		data.faces[target].color_corners = cols
	var kept: Array[UBFace] = []
	for fi in data.faces.size():
		if fi == target or not face_set.has(fi):
			kept.append(data.faces[fi])
	data.faces = kept
	UBOpUtils.remove_unused_vertices(data)


static func _vertex_color(data, face_set: Dictionary, vi: int) -> Color:
	var sum := Color(0, 0, 0, 0)
	var count := 0
	for fi in face_set:
		var face: UBFace = data.faces[fi]
		var idx := face.vertices.find(vi)
		if idx < 0:
			continue
		sum += (face.color_corners[idx]
			if face.color_corners.size() == face.vertices.size() else face.color)
		count += 1
	return sum / count if count > 0 else Color.WHITE
