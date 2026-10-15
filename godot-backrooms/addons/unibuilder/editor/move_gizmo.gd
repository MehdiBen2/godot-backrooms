@tool
class_name UBMoveGizmo
extends RefCounted
## Element-move gizmo, drawn as a 2D overlay at the selection pivot at constant pixel
## size: three orientation-axis arrows plus a center square for view-plane moves.
## Drags map the cursor back through ray-line or ray-plane intersection; snapping
## quantizes the world-space delta. Axes come from `basis`: identity for global, or
## the node/normal orientation the toolbar selects.

enum Handle { NONE, AXIS_X, AXIS_Y, AXIS_Z, VIEW }

const AXIS_LEN_PX := 80.0
const HIT_PX := 10.0
const CENTER_PX := 8.0
const AXIS_COLORS: Array[Color] = [
	Color(0.96, 0.3, 0.33), Color(0.53, 0.84, 0.28), Color(0.3, 0.55, 0.96),
]

var basis := Basis.IDENTITY

var active := Handle.NONE
## Handle under the cursor, updated by viewport input on hover; drawn highlighted
## so it is clear what a click will grab.
var hovered := Handle.NONE


func _axis_dir(i: int) -> Vector3:
	return [basis.x, basis.y, basis.z][i]
var _pivot := Vector3.ZERO
var _axis := Vector3.ZERO
var _t0 := 0.0
var _plane := Plane()
var _plane_hit0 := Vector3.ZERO


func draw(overlay: Control, camera: Camera3D, pivot: Vector3) -> void:
	if camera == null or camera.is_position_behind(pivot):
		return
	var origin := camera.unproject_position(pivot)
	for i in 3:
		var sdir := _screen_dir(camera, pivot, _axis_dir(i))
		if sdir == Vector2.ZERO:
			continue
		var handle := (Handle.AXIS_X + i) as Handle
		var hot := hovered == handle or active == handle
		var color := AXIS_COLORS[i].lightened(0.45) if hot else AXIS_COLORS[i]
		var width := 3.5 if hot else 2.0
		var head := 5.5 if hot else 4.5
		var tip := origin + sdir * AXIS_LEN_PX
		overlay.draw_line(origin, tip, color, width, true)
		var n := sdir.orthogonal()
		overlay.draw_colored_polygon(
			PackedVector2Array([tip + sdir * (10.0 + (2.0 if hot else 0.0)), tip + n * head, tip - n * head]),
			color)
	var center_hot := hovered == Handle.VIEW or active == Handle.VIEW
	var center_rect := Rect2(
		origin - Vector2(CENTER_PX, CENTER_PX) * 0.5, Vector2(CENTER_PX, CENTER_PX))
	if center_hot:
		overlay.draw_rect(center_rect, Color(1, 1, 1, 0.35), true)
	overlay.draw_rect(center_rect, Color(1, 1, 1, 0.9), false, 3.0 if center_hot else 2.0)


func hit_test(camera: Camera3D, pivot: Vector3, pos: Vector2) -> Handle:
	if camera == null or camera.is_position_behind(pivot):
		return Handle.NONE
	var origin := camera.unproject_position(pivot)
	if pos.distance_to(origin) <= CENTER_PX:
		return Handle.VIEW
	var best := Handle.NONE
	var best_d := HIT_PX
	for i in 3:
		var sdir := _screen_dir(camera, pivot, _axis_dir(i))
		if sdir == Vector2.ZERO:
			continue
		var d := Geometry2D.get_closest_point_to_segment(
			pos, origin, origin + sdir * AXIS_LEN_PX).distance_to(pos)
		if d < best_d:
			best_d = d
			best = (Handle.AXIS_X + i) as Handle
	return best


func begin_drag(camera: Camera3D, pivot: Vector3, handle: Handle, pos: Vector2) -> void:
	active = handle
	_pivot = pivot
	if handle == Handle.VIEW:
		var forward := -camera.global_transform.basis.z
		_plane = Plane(forward, pivot)
		var hit = _plane.intersects_ray(camera.project_ray_origin(pos), camera.project_ray_normal(pos))
		_plane_hit0 = hit if hit != null else pivot
	else:
		_axis = _axis_dir(handle - Handle.AXIS_X).normalized()

		_t0 = _ray_line_t(camera, pos)


## World-space offset for the current cursor position. snap_step 0 = no snap.
func update_drag(camera: Camera3D, pos: Vector2, snap_step: float) -> Vector3:
	if active == Handle.VIEW:
		var hit = _plane.intersects_ray(camera.project_ray_origin(pos), camera.project_ray_normal(pos))
		if hit == null:
			return Vector3.ZERO
		var offset: Vector3 = hit - _plane_hit0
		if snap_step > 0.0:
			offset = offset.snapped(Vector3.ONE * snap_step)
		return offset
	if active >= Handle.AXIS_X:
		var t := _ray_line_t(camera, pos)
		if is_nan(t) or is_nan(_t0):
			return Vector3.ZERO
		var delta := t - _t0
		if snap_step > 0.0:
			delta = snappedf(delta, snap_step)
		return _axis * delta
	return Vector3.ZERO


## World direction of the live axis drag, or zero for the view-plane handle.
## Absolute snapping uses it to keep an axis move on its line.
func drag_axis() -> Vector3:
	return _axis if active >= Handle.AXIS_X else Vector3.ZERO


func end_drag() -> void:
	active = Handle.NONE


func _screen_dir(camera: Camera3D, pivot: Vector3, axis: Vector3) -> Vector2:
	return UBGizmoMath.screen_dir(camera, pivot, axis)


func _ray_line_t(camera: Camera3D, pos: Vector2) -> float:
	return UBGizmoMath.ray_line_t(camera, pos, _pivot, _axis)
