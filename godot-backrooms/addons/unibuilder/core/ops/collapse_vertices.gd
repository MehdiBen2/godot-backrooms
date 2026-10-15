@tool
class_name UBOpCollapseVertices
extends RefCounted
## Collapse the selected vertices into one at their center; faces that
## degenerate are removed, and a face pinched by the merge (two non-adjacent
## corners of one n-gon) splits into its sub-loops (see
## UBOpUtils.remap_faces). A collapse that would leave an edge shared by more
## than two faces (the link condition: on a triangulated cone, collapsing some
## edges fuses two fans along an edge) is refused and the mesh is left
## untouched.


static func apply(data, vert_set: Dictionary) -> void:
	vert_set = UBOpUtils.valid_vertices(data, vert_set)
	if vert_set.size() < 2:
		return
	var indices: Array = vert_set.keys()
	indices.sort()
	var rep: int = indices[0]
	var target := Vector3.ZERO
	for vi in indices:
		target += data.positions[vi]
	target /= indices.size()
	var remap := PackedInt32Array()
	remap.resize(data.positions.size())
	for i in data.positions.size():
		remap[i] = i
	for vi in indices:
		remap[vi] = rep
	if UBOpUtils.remap_overshares(data, remap):
		return
	data.positions[rep] = target
	UBOpUtils.remap_faces(data, remap)
