@tool
class_name UBOpMirrorObject
extends RefCounted
## Duplicate the whole mesh reflected across the local axis plane through the
## origin, with windings reversed so the copy faces outward (parallel
## per-corner arrays reverse too). With `weld`, only vertices sitting on the
## plane within `threshold` are welded, so a modelled half closes its seam and
## nothing else is touched. Mirroring a closed mesh leaves an internal wall;
## delete the plane-facing faces first.


static func apply(data, axis: int, weld := true, threshold := 0.001) -> void:
	axis = clampi(axis, 0, 2)
	var n0: int = data.positions.size()
	var f0: int = data.faces.size()
	var mirror := Vector3.ONE
	mirror[axis] = -1.0
	var pos: PackedVector3Array = data.positions.duplicate()
	for i in n0:
		pos.append(data.positions[i] * mirror)
	data.positions = pos
	for fi in f0:
		var copy: UBFace = data.faces[fi].duplicate_face()
		var verts: PackedInt32Array = copy.vertices
		for i in verts.size():
			verts[i] += n0
		copy.vertices = verts

		if copy.uv_axis != Vector3.ZERO:
			copy.uv_axis = copy.uv_axis * mirror
		UBOpUtils.reverse_face_loop(copy)
		data.faces.append(copy)
	if weld:
		var near := {}
		for i in data.positions.size():
			if absf(data.positions[i][axis]) <= threshold:
				near[i] = true
		if near.size() >= 2:
			UBOpWeldVertices.apply(data, near, threshold * 2.0)
