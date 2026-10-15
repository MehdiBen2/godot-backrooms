@tool
class_name UBOpBridgeEdges
extends RefCounted
## Bridge two boundary edges with a quad. Each edge is traversed opposite to
## its own face (the fill rule for boundaries, so bridging the rims of an open
## tube faces outward), which fixes the quad's corner order and keeps its
## winding consistent with BOTH neighbours. Two sheets facing the same way
## cannot be joined consistently (the consistent quad is a bow-tie); there the
## untwisted pairing is used and the quad winds with the first edge's face.
## Refused, leaving the mesh untouched, when the edges share an endpoint (the
## quad would name a vertex twice), when a side of the quad would make an edge
## non-manifold, or when the quad would have no area.


static func apply(data, e1: Vector2i, e2: Vector2i) -> void:
	var topo := UBTopology.build(data)

	if not (UBOpUtils.is_real_edge(topo, e1) and UBOpUtils.is_real_edge(topo, e2)):
		return

	var faces1: Array = topo.edge_faces.get(e1, [])
	var faces2: Array = topo.edge_faces.get(e2, [])
	if faces1.size() != 1 or faces2.size() != 1:
		return

	if e1.x == e2.x or e1.x == e2.y or e1.y == e2.x or e1.y == e2.y:
		return

	var t1 := _traversal(data.faces[faces1[0]], e1)
	var t2 := _traversal(data.faces[faces2[0]], e2)
	if t1.is_empty() or t2.is_empty():
		return
	var a: int = t1[0]
	var b: int = t1[1]
	var c: int = t2[0]
	var d: int = t2[1]
	if _bowtie(data, PackedInt32Array([b, a, d, c])):
		var swap := c
		c = d
		d = swap

	if not _side_ok(data, topo, a, d) or not _side_ok(data, topo, c, b):
		return

	if _degenerate(data, PackedInt32Array([b, a, d, c])):
		return
	data.add_face(PackedInt32Array([b, a, d, c]), data.faces[faces1[0]].material_index)


static func _traversal(face: UBFace, e: Vector2i) -> Array:
	var verts: PackedInt32Array = face.vertices
	var n := verts.size()
	for i in n:
		var u := verts[i]
		var v := verts[(i + 1) % n]
		if UBSelectQueries.edge_key(u, v) == e:
			return [u, v]
	return []


static func _degenerate(data, loop: PackedInt32Array) -> bool:
	var pts := PackedVector3Array()
	for vi in loop:
		pts.append(data.positions[vi])
	var scale := 0.0
	for i in pts.size():
		for j in range(i + 1, pts.size()):
			scale = maxf(scale, pts[i].distance_to(pts[j]))
	for i in pts.size():
		for j in range(i + 1, pts.size()):
			if pts[i].distance_to(pts[j]) <= 1e-6 * scale:
				return true
	return UBTriangulate.newell_normal(pts).length() <= 1e-6 * scale * scale


static func _bowtie(data, loop: PackedInt32Array) -> bool:
	var n := loop.size()
	var turns := []
	var total := Vector3.ZERO
	for i in n:
		var p: Vector3 = data.positions[loop[i]]
		var prev: Vector3 = data.positions[loop[(i - 1 + n) % n]]
		var next: Vector3 = data.positions[loop[(i + 1) % n]]
		var turn := (next - p).cross(prev - p)
		turns.append(turn)
		total += turn
	if total.length_squared() <= 0.0:
		return true
	for turn: Vector3 in turns:
		if turn.dot(total) < 0.0:
			return true
	return false


static func _side_ok(data, topo: UBTopology, u: int, v: int) -> bool:
	var sharers: Array = topo.edge_faces.get(UBSelectQueries.edge_key(u, v), [])
	if sharers.is_empty():
		return true
	if sharers.size() != 1:
		return false
	var t := _traversal(data.faces[sharers[0]], UBSelectQueries.edge_key(u, v))
	return not t.is_empty() and t[0] == v and t[1] == u
