@tool
class_name UBSelectQueries
extends RefCounted
## Pure topology-driven selection queries: grow/shrink, edge loops/rings, face
## loops. Selections are Dictionaries used as sets (key -> true); vertex keys
## are ints, edge keys Vector2i(lo, hi), face keys ints. Nothing here touches
## editor state; callers own the UBSelection. Live sets may name elements the
## mesh no longer has, or keys of the wrong type, so every query skips unknown
## and out-of-range keys.


static func edge_key(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


static func face_edges(face) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var verts: PackedInt32Array = face.vertices
	for i in verts.size():
		out.append(edge_key(verts[i], verts[(i + 1) % verts.size()]))
	return out


static func grow_vertices(topo, selected: Dictionary) -> Dictionary:
	var out := selected.duplicate()
	for v in selected:
		if not (v is int and v >= 0 and v < topo.vertex_edges.size()):
			continue
		for e: Vector2i in topo.vertex_edges[v]:
			out[e.x] = true
			out[e.y] = true
	return out


## Keeps a vertex only if every edge-neighbor is also selected.
static func shrink_vertices(topo, selected: Dictionary) -> Dictionary:
	var out := {}
	for v in selected:
		if not (v is int and v >= 0 and v < topo.vertex_edges.size()):
			continue
		var keep := true
		for e: Vector2i in topo.vertex_edges[v]:
			var other: int = e.x if e.y == v else e.y
			if not selected.has(other):
				keep = false
				break
		if keep:
			out[v] = true
	return out


static func grow_edges(topo, selected: Dictionary) -> Dictionary:
	var out := selected.duplicate()
	for e in selected:
		if not (e is Vector2i and topo.edge_faces.has(e)):
			continue
		for v in [e.x, e.y]:
			for e2: Vector2i in topo.vertex_edges[v]:
				out[e2] = true
	return out


## Keeps an edge only if every edge sharing one of its vertices is selected.
static func shrink_edges(topo, selected: Dictionary) -> Dictionary:
	var out := {}
	for e in selected:
		if not (e is Vector2i and topo.edge_faces.has(e)):
			continue
		var keep := true
		for v in [e.x, e.y]:
			for e2: Vector2i in topo.vertex_edges[v]:
				if e2 != e and not selected.has(e2):
					keep = false
					break
			if not keep:
				break
		if keep:
			out[e] = true
	return out


## max_angle_deg < 180 limits growth to neighbors whose normal deviates from
## the seed face's by at most that angle (crease-respecting grow).
static func grow_faces(data, topo, selected: Dictionary, max_angle_deg := 180.0) -> Dictionary:
	var limited := max_angle_deg < 179.5
	var cos_limit := cos(deg_to_rad(max_angle_deg))
	var out := selected.duplicate()
	for fi in selected:
		if not (fi is int and fi >= 0 and fi < data.faces.size()):
			continue
		var n: Vector3 = data.face_normal(data.faces[fi]) if limited else Vector3.ZERO
		for e in face_edges(data.faces[fi]):
			for nf in topo.edge_faces.get(e, []):
				if limited and not selected.has(nf):
					if data.face_normal(data.faces[nf]).dot(n) < cos_limit - 1e-6:
						continue
				out[nf] = true
	return out


## Keeps a face only if every edge-adjacent face is selected.
static func shrink_faces(data, topo, selected: Dictionary) -> Dictionary:
	var out := {}
	for fi in selected:
		if not (fi is int and fi >= 0 and fi < data.faces.size()):
			continue
		var keep := true
		for e in face_edges(data.faces[fi]):
			for nf in topo.edge_faces.get(e, []):
				if nf != fi and not selected.has(nf):
					keep = false
					break
			if not keep:
				break
		if keep:
			out[fi] = true
	return out


## Edges with both endpoints in the vertex set; upward conversion keeps only
## fully covered elements.
static func edges_from_vertices(topo, verts: Dictionary) -> Dictionary:
	var out := {}
	for e: Vector2i in topo.edge_faces:
		if verts.has(e.x) and verts.has(e.y):
			out[e] = true
	return out


## Faces with every corner in the vertex set.
static func faces_from_vertices(data, verts: Dictionary) -> Dictionary:
	var out := {}
	for fi in data.faces.size():
		var all_in := true
		for vi in data.faces[fi].vertices:
			if not verts.has(vi):
				all_in = false
				break
		if all_in:
			out[fi] = true
	return out


## Select Similar: every face sharing (material, smoothing group, color) with
## any selected face.
static func similar_faces(data, selected: Dictionary) -> Dictionary:
	var traits := {}
	for fi in selected:
		if fi is int and fi >= 0 and fi < data.faces.size():
			var f = data.faces[fi]
			traits[[f.material_index, f.smoothing_group, f.color]] = true
	var out := selected.duplicate()
	for fi in data.faces.size():
		var f = data.faces[fi]
		if traits.has([f.material_index, f.smoothing_group, f.color]):
			out[fi] = true
	return out


## Select Coplanar: floods across shared edges from each selected face, keeping
## neighbors that lie in the seed face's plane (normal aligned within
## `angle_deg`, every corner within `plane_eps` of the plane). The plane stays
## anchored to the seed, so a gently curved surface cannot drift the region
## open one tolerance at a time, and the walk follows adjacency, so a disjoint
## patch on the same infinite plane stays out. Opposite-facing neighbors fail
## the normal test.
static func coplanar_faces(data, topo, selected: Dictionary, angle_deg := 0.5, plane_eps := 1e-4) -> Dictionary:
	var out := selected.duplicate()
	var cos_limit := cos(deg_to_rad(angle_deg))
	for seed in selected:
		if not (seed is int and seed >= 0 and seed < data.faces.size()):
			continue
		var n: Vector3 = data.face_normal(data.faces[seed])
		var d: float = n.dot(data.positions[data.faces[seed].vertices[0]])
		var stack: Array[int] = [seed]
		var seen := {seed: true}
		while not stack.is_empty():
			var fi: int = stack.pop_back()
			for e in face_edges(data.faces[fi]):
				for nf in topo.edge_faces.get(e, []):
					if seen.has(nf):
						continue

					seen[nf] = true
					if _face_in_plane(data, data.faces[nf], n, d, cos_limit, plane_eps):
						out[nf] = true
						stack.append(nf)
	return out


## Relative term added to the coplanar tolerance, scaled by the larger of the
## plane offset and the point's distance from the origin, since float32
## spacing grows with magnitude.
const PLANE_REL := 1e-6


static func _face_in_plane(data, face, n: Vector3, d: float, cos_limit: float, eps: float) -> bool:
	if data.face_normal(face).dot(n) < cos_limit:
		return false
	for vi in face.vertices:
		var p: Vector3 = data.positions[vi]
		var tol: float = eps + PLANE_REL * maxf(absf(d), p.length())
		if absf(n.dot(p) - d) > tol:
			return false
	return true


## Select Holes: every boundary edge (bordering exactly one face), which is
## the rims of open meshes and deleted-face holes.
static func boundary_edges(topo) -> Dictionary:
	var out := {}
	for e: Vector2i in topo.edge_faces:
		if topo.edge_faces[e].size() == 1:
			out[e] = true
	return out


## Walks from both endpoints: at a valence-4 vertex the loop continues through
## the unique edge that shares no face with the current edge. Stops at
## boundaries, poles, and non-quad junctions.
static func edge_loop(topo, start: Vector2i) -> Array[Vector2i]:
	var loop: Array[Vector2i] = [start]
	var visited := {start: true}
	for start_vertex in [start.x, start.y]:
		var edge := start
		var pivot: int = start_vertex
		while true:
			var next := _loop_continuation(topo, edge, pivot)
			if next == Vector2i(-1, -1) or visited.has(next):
				break
			visited[next] = true
			loop.append(next)
			pivot = next.y if next.x == pivot else next.x
			edge = next
	return loop


static func _loop_continuation(topo, edge: Vector2i, pivot: int) -> Vector2i:
	if topo.vertex_edges[pivot].size() != 4:
		return Vector2i(-1, -1)
	var edge_face_set := {}
	for f in topo.edge_faces[edge]:
		edge_face_set[f] = true
	var candidate := Vector2i(-1, -1)
	for e2: Vector2i in topo.vertex_edges[pivot]:
		if e2 == edge:
			continue
		var shares := false
		for f in topo.edge_faces[e2]:
			if edge_face_set.has(f):
				shares = true
				break
		if not shares:
			if candidate != Vector2i(-1, -1):
				return Vector2i(-1, -1)
			candidate = e2
	return candidate


## Walks across quads: the ring continues through the opposite edge of each
## bordering quad. Stops at boundaries, non-quads, and when it closes.
static func edge_ring(data, topo, start: Vector2i) -> Array[Vector2i]:
	var ring: Array[Vector2i] = [start]
	var visited := {start: true}
	for f0 in topo.edge_faces.get(start, []):
		var edge := start
		var fi: int = f0
		while true:
			var opposite := _opposite_edge(data.faces[fi], edge)
			if opposite == Vector2i(-1, -1) or visited.has(opposite):
				break
			visited[opposite] = true
			ring.append(opposite)
			var nf := -1
			for f2 in topo.edge_faces.get(opposite, []):
				if f2 != fi:
					nf = f2
					break
			if nf < 0:
				break
			fi = nf
			edge = opposite
	return ring


## Chain of quads crossed perpendicular to `direction_edge`, both ways.
static func face_loop(data, topo, start_face: int, direction_edge: Vector2i) -> Dictionary:
	var out := {start_face: true}
	_face_walk(data, topo, start_face, direction_edge, out)
	for f in topo.edge_faces.get(direction_edge, []):
		if f != start_face:
			out[f] = true
			_face_walk(data, topo, f, direction_edge, out)
			break
	return out


static func _face_walk(data, topo, fi: int, entry: Vector2i, out: Dictionary) -> void:
	while true:
		var opposite := _opposite_edge(data.faces[fi], entry)
		if opposite == Vector2i(-1, -1):
			return
		var nf := -1
		for f2 in topo.edge_faces.get(opposite, []):
			if f2 != fi:
				nf = f2
				break
		if nf < 0 or out.has(nf):
			return
		out[nf] = true
		entry = opposite
		fi = nf


static func _opposite_edge(face, edge: Vector2i) -> Vector2i:
	var verts: PackedInt32Array = face.vertices
	if verts.size() != 4:
		return Vector2i(-1, -1)
	for i in 4:
		if edge_key(verts[i], verts[(i + 1) % 4]) == edge:
			return edge_key(verts[(i + 2) % 4], verts[(i + 3) % 4])
	return Vector2i(-1, -1)
