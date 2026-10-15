@tool
class_name UBUVUnwrap
extends RefCounted
## Auto-UV: per-face planar projection onto the face's own plane, so texel
## density is 1:1 everywhere. The dominant normal axis picks only the
## reference U direction, which keeps the box-mapping look and leaves
## axis-aligned faces identical to a pure axis projection. The face's
## offset, rotation and scale apply in UV space.


## Returns one UV per corner. `corners` are local-space positions in face order;
## `world_transform` is applied first for world-anchored faces.
static func face_uvs(corners: PackedVector3Array, normal: Vector3, face, world_transform: Transform3D) -> PackedVector2Array:
	var uvs := PackedVector2Array()
	uvs.resize(corners.size())
	var rot: float = deg_to_rad(face.uv_rotation)

	var frame_normal := normal
	if face.uv_axis != Vector3.ZERO:
		frame_normal = face.uv_axis
	if face.uv_world_space and absf(world_transform.basis.determinant()) > 1e-12:
		frame_normal = (world_transform.basis.inverse().transposed() * frame_normal).normalized()
	var frame := projection_frame(frame_normal)
	var t: Vector3 = frame[0]
	var b: Vector3 = frame[1]
	for i in corners.size():
		var p := corners[i]
		if face.uv_world_space:
			p = world_transform * p
		var uv := Vector2(p.dot(t), p.dot(b))
		uvs[i] = uv.rotated(rot) * face.uv_scale + face.uv_offset
	return uvs


## The [U, V] axes a face with this normal projects along: box-style and
## sign-aware so opposite faces are not mirrored, but lying in the face's own
## plane rather than the dominant axis plane. The dominant axis picks the
## reference U, which is then orthogonalised against the real normal, and V
## follows as U x N. This does not remove the seam between faces with
## different normals; ops that create a band between two faces bake
## continuous UVs instead (see UBOpBevelEdges).
static func projection_frame(n: Vector3) -> Array:
	var a := n.abs()
	var u0: Vector3
	if a.y >= a.x and a.y >= a.z:
		u0 = Vector3.RIGHT
	elif a.x >= a.z:
		u0 = Vector3(0.0, 0.0, -_sign_or_one(n.x))
	else:
		u0 = Vector3(_sign_or_one(n.z), 0.0, 0.0)
	var axis := n.normalized()
	if axis == Vector3.ZERO:
		return [Vector3.RIGHT, Vector3.DOWN]

	var t := (u0 - axis * axis.dot(u0)).normalized()
	return [t, t.cross(axis)]


static func _sign_or_one(x: float) -> float:
	return -1.0 if x < 0.0 else 1.0
