@tool
class_name UBOpExtrudeFaces
extends RefCounted
## Extrude a set of faces as a group along their averaged normal. The selected
## faces are rewritten onto duplicated vertices; side quads are stitched along
## the region boundary (edges bordering exactly one selected face). Interior
## edges get no walls. Face indices survive the op, so a face selection stays
## valid; distance 0 is the shift-drag entry point (extrude in place, then move).


static func apply(data, face_set: Dictionary, distance: float) -> void:
	face_set = UBOpUtils.valid_faces(data, face_set)
	if face_set.is_empty():
		return
	var normal := Vector3.ZERO
	for fi in face_set:
		normal += data.face_normal(data.faces[fi])
	normal = normal.normalized() if normal.length_squared() > 1e-12 else Vector3.UP

	var edge_count := {}
	for fi in face_set:
		for e in UBSelectQueries.face_edges(data.faces[fi]):
			edge_count[e] = edge_count.get(e, 0) + 1

	var comp := _components(data, face_set)

	var dup := {}
	for fi in face_set:
		for vi in data.faces[fi].vertices:
			var key := Vector2i(comp[fi], vi)
			if not dup.has(key):
				dup[key] = data.add_vertex(data.positions[vi] + normal * distance)

	var side_quads := []
	for fi in face_set:
		var verts: PackedInt32Array = data.faces[fi].vertices
		var mat: int = data.faces[fi].material_index
		var c: int = comp[fi]
		for i in verts.size():
			var a := verts[i]
			var b := verts[(i + 1) % verts.size()]
			if edge_count[UBSelectQueries.edge_key(a, b)] == 1:
				side_quads.append([a, b, dup[Vector2i(c, b)], dup[Vector2i(c, a)], mat])

	for fi in face_set:
		var verts: PackedInt32Array = data.faces[fi].vertices
		var c: int = comp[fi]
		for i in verts.size():
			verts[i] = dup[Vector2i(c, verts[i])]
		data.faces[fi].vertices = verts

	for q in side_quads:
		data.add_face(PackedInt32Array([q[0], q[1], q[2], q[3]]), q[4])

	UBOpUtils.remove_unused_vertices(data)


static func _components(data, face_set: Dictionary) -> Dictionary:
	var by_edge := {}
	for fi in face_set:
		for e in UBSelectQueries.face_edges(data.faces[fi]):
			if not by_edge.has(e):
				by_edge[e] = []
			by_edge[e].append(fi)
	var comp := {}
	var next_id := 0
	for seed_face in face_set:
		if comp.has(seed_face):
			continue
		comp[seed_face] = next_id
		var stack := [seed_face]
		while not stack.is_empty():
			var fi: int = stack.pop_back()
			for e in UBSelectQueries.face_edges(data.faces[fi]):
				for other: int in by_edge[e]:
					if not comp.has(other):
						comp[other] = next_id
						stack.append(other)
		next_id += 1
	return comp
