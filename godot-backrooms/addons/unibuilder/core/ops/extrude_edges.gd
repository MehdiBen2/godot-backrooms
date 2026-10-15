@tool
class_name UBOpExtrudeEdges
extends RefCounted
## Extrude selected boundary edges outward in their face plane (away from the
## face center), stitching a quad per edge. Shared endpoints of chained edges
## are duplicated once and move along the averaged direction. Interior edges
## (2 faces) are skipped, since extruding them would create non-manifold
## geometry.
## Returns the new outer edge keys so the caller can reselect them.


static func apply(data, edge_set: Dictionary, distance: float) -> Array:
	var topo := UBTopology.build(data)
	edge_set = UBOpUtils.valid_edges(topo, edge_set)
	var dirs := {}
	var quads := []
	for key: Vector2i in edge_set:
		var faces: Array = topo.edge_faces.get(key, [])
		if faces.size() != 1:
			continue
		var fi: int = faces[0]
		var verts: PackedInt32Array = data.faces[fi].vertices
		var a := -1
		var b := -1
		for i in verts.size():
			if UBSelectQueries.edge_key(verts[i], verts[(i + 1) % verts.size()]) == key:
				a = verts[i]
				b = verts[(i + 1) % verts.size()]
				break
		if a < 0:
			continue
		var pa: Vector3 = data.positions[a]
		var pb: Vector3 = data.positions[b]
		var along := (pb - pa).normalized()
		var away: Vector3 = (pa + pb) * 0.5 - data.face_center(data.faces[fi])
		away -= along * away.dot(along)
		if away.length_squared() > 1e-12:
			away = away.normalized()
		dirs[a] = dirs.get(a, Vector3.ZERO) + away
		dirs[b] = dirs.get(b, Vector3.ZERO) + away
		quads.append([a, b, data.faces[fi].material_index])
	var dup := {}
	for v in dirs:
		var d: Vector3 = dirs[v]
		if d.length_squared() > 1e-12:
			d = d.normalized()
		dup[v] = data.add_vertex(data.positions[v] + d * distance)
	var new_edges := []
	for q in quads:

		data.add_face(PackedInt32Array([dup[q[0]], dup[q[1]], q[1], q[0]]), q[2])
		new_edges.append(UBSelectQueries.edge_key(dup[q[0]], dup[q[1]]))
	return new_edges
