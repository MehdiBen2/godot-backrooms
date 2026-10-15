@tool
class_name UBScaleGizmo
extends RefCounted
## Element-scale gizmo: three orientation-axis handles with square tips plus a
## center square for uniform scaling. Axis drags take the factor from the ratio of
## ray-line parameters (t / t0), the uniform drag from the cursor's travel along the
## drag's own direction. Snap quantizes factors to the step, as the UV editor does.

enum Handle { NONE, AXIS_X, AXIS_Y, AXIS_Z, UNIFORM }

const AXIS_LEN_PX := 64.0
const HIT_PX := 10.0
const TIP_PX := 7.0
const CENTER_PX := 10.0
## Screen travel a uniform (center-square) drag maps onto one whole factor: this far
## out doubles the selection, the same distance back past the press point collapses
## it. Matches the axis handles' length so both gestures feel the same.
const UNIFORM_REF_PX := AXIS_LEN_PX
## Travel a uniform drag needs before it commits to a direction.
const UNIFORM_DIR_PX := 3.0
const AXIS_COLORS: Array[Color] = [
	Color(0.96, 0.3, 0.33), Color(0.53, 0.84, 0.28), Color(0.3, 0.55, 0.96),
]

var basis := Basis.IDENTITY
var active := Handle.NONE
var hovered := Handle.NONE
## Live factors of the current drag (orientation space), for the readout.
var last_factors := Vector3.ONE
## When non-empty, drawn as the readout instead of the factor (the Shift+drag inset
## gesture shows the inset width). Cleared when the drag ends.
var readout_override := ""
var _pivot := Vector3.ZERO
var _axis := Vector3.ZERO
var _t0 := 0.0


var _press := Vector2.ZERO
var _dir := Vector2.ZERO
var _cursor := Vector2.ZERO


func _axis_dir(i: int) -> Vector3:
	return [basis.x, basis.y, basis.z][i]


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
		var tip := origin + sdir * AXIS_LEN_PX
		overlay.draw_line(origin, tip, color, 3.5 if hot else 2.0, true)
		var half := (TIP_PX + (2.0 if hot else 0.0)) * 0.5
		overlay.draw_rect(Rect2(tip - Vector2(half, half), Vector2(half, half) * 2.0), color, true)
	var center_hot := hovered == Handle.UNIFORM or active == Handle.UNIFORM
	var rect := Rect2(origin - Vector2(CENTER_PX, CENTER_PX) * 0.5, Vector2(CENTER_PX, CENTER_PX))
	if center_hot:
		overlay.draw_rect(rect, Color(1, 1, 1, 0.35), true)
	overlay.draw_rect(rect, Color(1, 1, 1, 0.9), false, 3.0 if center_hot else 2.0)
	if active != Handle.NONE:
		_draw_readout(overlay)


func _draw_readout(overlay: Control) -> void:
	var text: String
	if not readout_override.is_empty():
		text = readout_override
	elif active == Handle.UNIFORM:
		text = "× %.3f" % last_factors.x
	else:
		text = "× %.3f" % last_factors[active - Handle.AXIS_X]
	var font := overlay.get_theme_font("font", "Label")
	var size := overlay.get_theme_font_size("font_size", "Label")
	var pos := _cursor + Vector2(16, -12)
	overlay.draw_string(font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.8))
	overlay.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color.WHITE)


func hit_test(camera: Camera3D, pivot: Vector3, pos: Vector2) -> Handle:
	if camera == null or camera.is_position_behind(pivot):
		return Handle.NONE
	var origin := camera.unproject_position(pivot)
	if pos.distance_to(origin) <= CENTER_PX:
		return Handle.UNIFORM
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
	last_factors = Vector3.ONE
	_cursor = pos
	if handle == Handle.UNIFORM:

		_press = pos
		_dir = Vector2.ZERO
	else:
		_axis = _axis_dir(handle - Handle.AXIS_X).normalized()

		var t := _ray_line_t(camera, pos)
		_t0 = 1e-4 if is_nan(t) or absf(t) < 1e-4 else t


## Smallest factor a drag may produce. Snapping quantizes to the grid step (1.0 by
## default), so without a floor the first snap bucket toward the pivot is 0 and the
## selection collapses flat. Type 0 in the inspector if you really mean it.
const MIN_FACTOR := 0.001


## Per-axis factors (orientation space) for the cursor position. snap_step 0 =
## no snap; otherwise factors quantize to the step (x0.125-style).
func update_drag(camera: Camera3D, pos: Vector2, snap_step: float) -> Vector3:
	_cursor = pos
	var factors := Vector3.ONE
	if active == Handle.UNIFORM:

		var delta := pos - _press
		if _dir == Vector2.ZERO:
			if delta.length() < UNIFORM_DIR_PX:
				return last_factors
			_dir = delta.normalized()
		var f := 1.0 + delta.dot(_dir) / UNIFORM_REF_PX
		if snap_step > 0.0:
			f = snappedf(f, snap_step)
		f = maxf(f, MIN_FACTOR)
		factors = Vector3(f, f, f)
	elif active >= Handle.AXIS_X:
		var t := _ray_line_t(camera, pos)
		if is_nan(t):
			return last_factors
		var f := t / _t0
		if snap_step > 0.0:
			f = snappedf(f, snap_step)
		factors[active - Handle.AXIS_X] = _floor_factor(f)
	last_factors = factors
	return factors


static func _floor_factor(f: float) -> float:
	if absf(f) >= MIN_FACTOR:
		return f
	return MIN_FACTOR if f >= 0.0 else -MIN_FACTOR


func end_drag() -> void:
	active = Handle.NONE
	last_factors = Vector3.ONE
	readout_override = ""


func _screen_dir(camera: Camera3D, pivot: Vector3, axis: Vector3) -> Vector2:
	return UBGizmoMath.screen_dir(camera, pivot, axis)


func _ray_line_t(camera: Camera3D, pos: Vector2) -> float:
	return UBGizmoMath.ray_line_t(camera, pos, _pivot, _axis)
