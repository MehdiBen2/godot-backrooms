@tool
class_name UBRotateGizmo
extends RefCounted
## Element-rotate gizmo: three orientation-axis circles around the pivot at constant
## pixel radius. A drag measures the cursor's angle about the axis on the rotation
## plane (screen-space fallback when the plane is edge-on) and accumulates
## shortest-arc increments, so drags past 180 degrees keep going. Snap quantizes
## the total angle.

enum Handle { NONE, AXIS_X, AXIS_Y, AXIS_Z }

const RADIUS_PX := 64.0
const HIT_PX := 10.0
const SEGMENTS := 48
## Below this |axis . ray| the rotation plane is edge-on and ray hits explode; fall
## back to screen-space angles around the projected pivot.
const EDGE_ON := 0.08
const AXIS_COLORS: Array[Color] = [
	Color(0.96, 0.3, 0.33), Color(0.53, 0.84, 0.28), Color(0.3, 0.55, 0.96),
]

var basis := Basis.IDENTITY
var active := Handle.NONE
var hovered := Handle.NONE
## Total applied angle of the live drag (radians, after snapping), for the readout.
var last_angle := 0.0
var _pivot := Vector3.ZERO
var _axis := Vector3.ZERO
var _tangent := Vector3.ZERO
var _bitangent := Vector3.ZERO
var _screen_mode := false
var _prev_raw := 0.0
var _unsnapped := 0.0
var _cursor := Vector2.ZERO


func _axis_dir(i: int) -> Vector3:
	return [basis.x, basis.y, basis.z][i]


func draw(overlay: Control, camera: Camera3D, pivot: Vector3) -> void:
	if camera == null or camera.is_position_behind(pivot):
		return
	var r := _world_radius(camera, pivot)
	for i in 3:
		var handle := (Handle.AXIS_X + i) as Handle
		var hot := hovered == handle or active == handle
		if active != Handle.NONE and not hot:
			continue
		var color := AXIS_COLORS[i].lightened(0.45) if hot else AXIS_COLORS[i]
		for run: PackedVector2Array in _circle_runs(camera, pivot, _axis_dir(i), r):
			for k in run.size() - 1:
				overlay.draw_line(run[k], run[k + 1], color, 3.0 if hot else 2.0, true)
	if active != Handle.NONE:
		_draw_readout(overlay)


func _draw_readout(overlay: Control) -> void:
	var text := "%.1f°" % rad_to_deg(last_angle)
	var font := overlay.get_theme_font("font", "Label")
	var size := overlay.get_theme_font_size("font_size", "Label")
	var pos := _cursor + Vector2(16, -12)
	overlay.draw_string(font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.8))
	overlay.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color.WHITE)


func hit_test(camera: Camera3D, pivot: Vector3, pos: Vector2) -> Handle:
	if camera == null or camera.is_position_behind(pivot):
		return Handle.NONE
	var r := _world_radius(camera, pivot)
	var best := Handle.NONE
	var best_d := HIT_PX
	for i in 3:
		for run: PackedVector2Array in _circle_runs(camera, pivot, _axis_dir(i), r):
			for k in run.size() - 1:
				var d := Geometry2D.get_closest_point_to_segment(pos, run[k], run[k + 1]).distance_to(pos)
				if d < best_d:
					best_d = d
					best = (Handle.AXIS_X + i) as Handle
	return best


func begin_drag(camera: Camera3D, pivot: Vector3, handle: Handle, pos: Vector2) -> void:
	active = handle
	_pivot = pivot
	_axis = _axis_dir(handle - Handle.AXIS_X).normalized()
	var ref := Vector3.RIGHT if absf(_axis.x) < 0.9 else Vector3.UP
	_tangent = (ref - _axis * ref.dot(_axis)).normalized()
	_bitangent = _axis.cross(_tangent)
	_screen_mode = absf(_axis.dot(camera.project_ray_normal(pos))) < EDGE_ON
	_prev_raw = _raw_angle(camera, pos)
	_unsnapped = 0.0
	last_angle = 0.0
	_cursor = pos


## Total rotation angle (radians) about the axis for the cursor position.
## snap_step 0 = no snap.
func update_drag(camera: Camera3D, pos: Vector2, snap_step: float) -> float:
	var raw := _raw_angle(camera, pos)
	_unsnapped += wrapf(raw - _prev_raw, -PI, PI)
	_prev_raw = raw
	_cursor = pos
	last_angle = snappedf(_unsnapped, snap_step) if snap_step > 0.0 else _unsnapped
	return last_angle


func end_drag() -> void:
	active = Handle.NONE
	last_angle = 0.0


func _raw_angle(camera: Camera3D, pos: Vector2) -> float:
	if not _screen_mode:
		var plane := Plane(_axis, _pivot)
		var hit = plane.intersects_ray(camera.project_ray_origin(pos), camera.project_ray_normal(pos))
		if hit != null:
			var dir: Vector3 = hit - _pivot
			return atan2(dir.dot(_bitangent), dir.dot(_tangent))

		return _prev_raw
	var to_cam := camera.global_position - _pivot
	var sign := 1.0 if _axis.dot(to_cam) >= 0.0 else -1.0
	var v := pos - camera.unproject_position(_pivot)
	return -sign * atan2(v.y, v.x)


func _world_radius(camera: Camera3D, pivot: Vector3) -> float:
	var right := camera.global_transform.basis.x
	var px := camera.unproject_position(pivot + right).distance_to(camera.unproject_position(pivot))
	return RADIUS_PX / maxf(px, 1e-3)


func _circle_runs(camera: Camera3D, pivot: Vector3, axis: Vector3, r: float) -> Array:
	axis = axis.normalized()
	var ref := Vector3.RIGHT if absf(axis.x) < 0.9 else Vector3.UP
	var t := (ref - axis * ref.dot(axis)).normalized()
	var b := axis.cross(t)
	var runs: Array = []
	var current := PackedVector2Array()
	for k in SEGMENTS + 1:
		var a := TAU * k / SEGMENTS
		var world := pivot + (t * cos(a) + b * sin(a)) * r
		if camera.is_position_behind(world):
			if current.size() > 1:
				runs.append(current)
			current = PackedVector2Array()
			continue
		current.append(camera.unproject_position(world))
	if current.size() > 1:
		runs.append(current)
	return runs
