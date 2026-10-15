@tool
class_name UBOpFillHole
extends RefCounted
## Close the boundary loop(s) touched by the selected edges with a single
## n-gon each. Boundary directed edges (one face, directed as stored in that
## face) are chained into a loop and the fill face winds the loop reversed,
## which is the winding of the face that was deleted.


static func apply(data, edge_set: Dictionary) -> void:
	var topo := UBTopology.build(data)

	edge_set = UBOpUtils.valid_edges(topo, edge_set)
	var directed := {}
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
	var filled := {}
	for e: Vector2i in edge_set:
		if topo.edge_faces.get(e, []).size() != 1:
			continue
		var start := -1
		if directed.get(e.x, -1) == e.y:
			start = e.x
		elif directed.get(e.y, -1) == e.x:
			start = e.y
		if start < 0 or filled.has(start):
			continue
		var loop := PackedInt32Array([start])
		var cur: int = directed[start]
		var guard: int = data.positions.size() + 1
		var ok := true
		while cur != start:
			if ambiguous.has(cur) or not directed.has(cur) or guard <= 0:
				ok = false
				break
			loop.append(cur)
			cur = directed[cur]
			guard -= 1
		if not ok or loop.size() < 3:
			continue

		var owners: Array = topo.edge_faces.get(
			UBSelectQueries.edge_key(loop[0], loop[1]), [])
		var material: int = data.faces[owners[0]].material_index if not owners.is_empty() else 0
		loop.reverse()
		data.add_face(loop, material)
		for v in loop:
			filled[v] = true
