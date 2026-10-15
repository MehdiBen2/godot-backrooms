@tool
class_name UBGizmoMath
extends RefCounted
## Screen and ray math shared by the move and scale gizmos.


## Parameter t of the point on the line (pivot + axis * t) closest to the camera ray
## under the cursor. Returns NAN when the axis points almost straight at the camera
## and the closest point is unbounded; callers should hold still rather than use a
## stale value.
static func ray_line_t(camera: Camera3D, pos: Vector2, pivot: Vector3, axis: Vector3) -> float:
	var o := camera.project_ray_origin(pos)
	var d := camera.project_ray_normal(pos)
	var w := pivot - o
	var b := axis.dot(d)
	var denom := 1.0 - b * b
	if absf(denom) < 1e-6:
		return NAN
	return (b * d.dot(w) - axis.dot(w)) / denom


## Screen direction of a world axis at the pivot, unit length, or zero when the axis
## points into the camera and has no stable screen direction.
static func screen_dir(camera: Camera3D, pivot: Vector3, axis: Vector3) -> Vector2:
	var k := maxf(0.001, camera.global_position.distance_to(pivot) * 0.01)
	var probe := pivot + axis * k
	if camera.is_position_behind(probe):
		return Vector2.ZERO
	var v := camera.unproject_position(probe) - camera.unproject_position(pivot)
	return v.normalized() if v.length() > 1e-3 else Vector2.ZERO
