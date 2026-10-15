@tool
class_name UBConvertMesh
extends RefCounted
## Rebuilds an editable UBMeshData from any triangle Mesh: welds coincident
## positions, emits one face per triangle keyed to its surface's material slot,
## then merges coplanar same-material neighbors back into n-gons where it can.
## Reconstruction is lossy: smoothing groups, per-face UV settings, and colors
## reset to defaults.

const COPLANAR_DOT := 0.999
## Plane-distance tolerance for the coplanar merge: absolute, plus a term
## relative to the coordinate magnitude because float32 spacing grows with it
## (the rule Select Coplanar uses).
const PLANE_EPS := 1e-4
const PLANE_REL := 1e-6


static func _on_plane(data: UBMeshData, face: UBFace, n: Vector3, d: float) -> bool:
	for vi in face.vertices:
		var p: Vector3 = data.positions[vi]
		if absf(n.dot(p) - d) > PLANE_EPS + PLANE_REL * maxf(absf(d), p.length()):
			return false
	return true


static func from_mesh(mesh: Mesh, merge_coplanar := true, weld_epsilon := 0.001, smooth_angle_deg := 0.0) -> UBMeshData:
	var data := UBMeshData.new()
	if mesh == null:
		return data
	var index_of := {}
	for s in mesh.get_surface_count():
		data.material_slots.append(mesh.surface_get_material(s))

		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]

		var idx := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			idx = arrays[Mesh.ARRAY_INDEX]
		if idx.is_empty():
			idx = PackedInt32Array(range(verts.size()))
		var shared := PackedInt32Array()
		shared.resize(verts.size())
		for i in verts.size():
			shared[i] = _weld_index(data, index_of, verts[i], weld_epsilon)
		for t in range(0, idx.size() - 2, 3):
			var a := shared[idx[t]]
			var b := shared[idx[t + 1]]
			var c := shared[idx[t + 2]]
			if a == b or b == c or a == c:
				continue
			data.add_face(PackedInt32Array([a, b, c]), s)
	if merge_coplanar:
		_merge_all_regions(data)

	UBOpUtils.remove_unused_vertices(data)
	if smooth_angle_deg > 0.0:
		reconstruct_smoothing(data, smooth_angle_deg)
	return data


static func _weld_index(data: UBMeshData, index_of: Dictionary, p: Vector3, eps: float) -> int:
	var cell := (p / eps).round()
	if absf(cell.x) >= 2147483000.0 or absf(cell.y) >= 2147483000.0 \
			or absf(cell.z) >= 2147483000.0:
		return data.add_vertex(p)
	var key := Vector3i(cell)

	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var probe := key + Vector3i(dx, dy, dz)
				if not index_of.has(probe):
					continue
				for vi: int in index_of[probe]:
					if data.positions[vi].distance_to(p) <= eps:
						return vi
	var idx := data.add_vertex(p)

	if not index_of.has(key):
		index_of[key] = []
	index_of[key].append(idx)
	return idx


## Smoothing-group reconstruction: floods faces across shared edges whose
## dihedral angle is at most `max_angle_deg`. Every multi-face smooth component
## gets a fresh group; isolated faces stay hard.
static func reconstruct_smoothing(data: UBMeshData, max_angle_deg: float) -> void:
	var cos_limit := cos(deg_to_rad(clampf(max_angle_deg, 0.0, 180.0)))
	var topo := UBTopology.build(data)
	var normals := PackedVector3Array()
	normals.resize(data.faces.size())
	for fi in data.faces.size():
		normals[fi] = data.face_normal(data.faces[fi])
	var visited := {}
	var next_group := 1
	for seed in data.faces.size():
		if visited.has(seed):
			continue
		visited[seed] = true
		var component: Array[int] = [seed]
		var queue: Array[int] = [seed]
		while not queue.is_empty():
			var fi: int = queue.pop_back()
			var verts: PackedInt32Array = data.faces[fi].vertices
			for i in verts.size():
				var key := UBSelectQueries.edge_key(verts[i], verts[(i + 1) % verts.size()])
				for nf in topo.edge_faces.get(key, []):
					if nf == fi or visited.has(nf):
						continue
					if normals[fi].dot(normals[nf]) < cos_limit - 1e-6:
						continue
					visited[nf] = true
					component.append(nf)
					queue.append(nf)
		if component.size() > 1:
			for fi in component:
				data.faces[fi].smoothing_group = next_group
			next_group += 1
		else:
			data.faces[seed].smoothing_group = 0


static func _merge_all_regions(data: UBMeshData) -> void:
	var topo := UBTopology.build(data)
	var normals := PackedVector3Array()
	normals.resize(data.faces.size())
	for fi in data.faces.size():
		normals[fi] = data.face_normal(data.faces[fi])
	var visited := {}
	var dead := {}
	for seed in data.faces.size():
		if visited.has(seed):
			continue
		visited[seed] = true
		var region := {seed: true}
		var queue := [seed]
		var seed_d := normals[seed].dot(data.face_center(data.faces[seed]))
		while not queue.is_empty():
			var fi: int = queue.pop_back()
			for e in UBSelectQueries.face_edges(data.faces[fi]):
				for nf: int in topo.edge_faces[e]:

					if region.has(nf) or visited.has(nf):
						continue
					if data.faces[nf].material_index != data.faces[seed].material_index:
						continue
					if normals[nf].dot(normals[seed]) < COPLANAR_DOT:
						continue

					if not _on_plane(data, data.faces[nf], normals[seed], seed_d):
						continue
					region[nf] = true
					visited[nf] = true
					queue.append(nf)
		if region.size() < 2:
			continue

		var edge_count := {}
		for fi in region:
			for e in UBSelectQueries.face_edges(data.faces[fi]):
				edge_count[e] = edge_count.get(e, 0) + 1
		var directed := {}
		var bow_tie := false
		for fi in region:
			var verts: PackedInt32Array = data.faces[fi].vertices
			for i in verts.size():
				var a := verts[i]
				var b := verts[(i + 1) % verts.size()]
				if edge_count[UBSelectQueries.edge_key(a, b)] == 1:
					if directed.has(a):
						bow_tie = true
						break
					directed[a] = b
			if bow_tie:
				break
		if bow_tie or directed.is_empty():
			continue
		var start: int = directed.keys()[0]
		var loop := PackedInt32Array([start])
		var cur: int = directed[start]
		var guard: int = directed.size() + 1
		var broken := false
		while cur != start:
			if not directed.has(cur) or guard <= 0:
				broken = true
				break
			loop.append(cur)
			cur = directed[cur]
			guard -= 1
		if broken or loop.size() != directed.size():
			continue
		var indices: Array = region.keys()
		indices.sort()

		UBOpUtils.set_face_loop(data.faces[indices[0]], loop)
		for fi in region:
			if fi != indices[0]:
				dead[fi] = true
	if dead.is_empty():
		return
	var kept: Array[UBFace] = []
	for fi in data.faces.size():
		if not dead.has(fi):
			kept.append(data.faces[fi])
	data.faces = kept
	UBOpUtils.remove_unused_vertices(data)
