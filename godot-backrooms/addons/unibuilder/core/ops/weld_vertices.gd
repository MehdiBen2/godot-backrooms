@tool
class_name UBOpWeldVertices
extends RefCounted
## Merge selected vertices that lie within `threshold` of each other, each
## cluster collapsing to its average position.


static func apply(data, vert_set: Dictionary, threshold := 0.001) -> void:
	var indices: Array = UBOpUtils.valid_vertices(data, vert_set).keys()
	indices.sort()
	if indices.size() < 2:
		return

	var parent := {}
	for v in indices:
		parent[v] = v
	for i in indices.size():
		for j in range(i + 1, indices.size()):
			var a: int = indices[i]
			var b: int = indices[j]
			if data.positions[a].distance_to(data.positions[b]) <= threshold:
				parent[_find(parent, b)] = _find(parent, a)
	var clusters := {}
	for v in indices:
		var root: int = _find(parent, v)
		if not clusters.has(root):
			clusters[root] = []
		clusters[root].append(v)
	var remap := PackedInt32Array()
	remap.resize(data.positions.size())
	for i in data.positions.size():
		remap[i] = i
	var any_merged := false
	for root in clusters:
		var members: Array = clusters[root]
		if members.size() < 2:
			continue
		any_merged = true
		members.sort()
		var rep: int = members[0]
		var center := Vector3.ZERO
		for v in members:
			center += data.positions[v]
			remap[v] = rep
		data.positions[rep] = center / members.size()
	if any_merged:
		UBOpUtils.remap_faces(data, remap)


static func _find(parent: Dictionary, v: int) -> int:
	while parent[v] != v:
		parent[v] = parent[parent[v]]
		v = parent[v]
	return v
