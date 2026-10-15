@tool
class_name UBOpPivot
extends RefCounted
## The data-side halves of Center Pivot, Set Pivot to Selection, and Freeze
## Transform. The editor pairs each with the matching node-transform change in
## one undo action, so world-space geometry never moves.


## Axis-aligned bounds center of all positions (mesh-local).
static func bounds_center(data) -> Vector3:
	if data.positions.is_empty():
		return Vector3.ZERO
	var lo: Vector3 = data.positions[0]
	var hi: Vector3 = lo
	for p in data.positions:
		lo = lo.min(p)
		hi = hi.max(p)
	return (lo + hi) * 0.5


## Shift every position by offset (the node origin moves by -offset in the
## same frame to compensate).
static func translate_all(data, offset: Vector3) -> void:
	var out: PackedVector3Array = data.positions.duplicate()
	for i in out.size():
		out[i] += offset
	data.positions = out


## Bake a transform into the positions (Freeze Transform: the node's local
## transform, which then resets to identity). A mirroring transform (negative
## determinant) reverses face loops to keep normals facing out, and parallel
## per-corner arrays such as manual UVs reverse with them.
static func apply_transform(data, xf: Transform3D) -> void:
	var out: PackedVector3Array = data.positions.duplicate()
	for i in out.size():
		out[i] = xf * out[i]
	data.positions = out

	if absf(xf.basis.determinant()) > 1e-12:
		var normal_basis := xf.basis.inverse().transposed()
		for face in data.faces:
			if face.uv_axis != Vector3.ZERO:
				face.uv_axis = (normal_basis * face.uv_axis).normalized()
	if xf.basis.determinant() < 0.0:
		for face in data.faces:
			UBOpUtils.reverse_face_loop(face)
