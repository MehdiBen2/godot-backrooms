@tool
class_name UBMaterialTool
extends RefCounted
## Material mode: a viewport gizmo that moves, rotates and scales the UVs of
## the selected faces in place, so a texture can be lined up on the mesh
## without leaving the 3D view. It is a top-level mode like paint: its toolbar
## button shares the mode ButtonGroup, key 6 enters, and 6, Esc or 1-4 leave.
## Entering converts the selection to faces; a click picks a face (Shift
## toggles, empty space clears), and the selected-face tint is hidden for the
## mode's lifetime so the texture stays visible.
##
## The gizmo sits at the selection pivot projected onto the reference face
## (the largest selected face) and is built from that face's own UV map
## (UBUVFrame), so the U and V handles point along the directions U and V run
## in space. Drags are measured in UV space (cursor ray onto the face plane,
## then the frame's uv_at) and applied to every selected corner about the
## selection's UV centre, in one undo entry per drag.
##
## The texture follows the cursor, so the UV transform is the inverse of the
## gesture: sliding the texture by +d moves the UVs by -d, turning it by +θ
## rotates them by -θ, growing it by s scales them by 1/s. The three
## *_transform statics own that inversion. Auto-UV faces bake to manual as
## part of the drag, and a tap that never moves reverts the bake.

enum Handle { NONE, MOVE, SCALE_U, SCALE_V, SCALE_UNIFORM, ROTATE }

const AXIS_LEN_PX := 70.0
const TIP_PX := 9.0
const CENTER_PX := 10.0
## The uniform-scale square sits on the diagonal between the U and V tips.
const CORNER_FRAC := 0.5
const RING_PX := 95.0
const RING_SEGMENTS := 48
const HIT_PX := 9.0
## UV grid the drags snap to when no UV editor is open to provide one.
const DEFAULT_UV_STEP := 0.125
const ROTATE_SNAP := PI / 12.0
const TEAL := Color(0.369, 0.918, 0.831)
const AMBER := Color(0.984, 0.749, 0.141)
const UNDO_NAMES := {
	Handle.MOVE: "Move Face UVs",
	Handle.SCALE_U: "Scale Face UVs",
	Handle.SCALE_V: "Scale Face UVs",
	Handle.SCALE_UNIFORM: "Scale Face UVs",
	Handle.ROTATE: "Rotate Face UVs",
}

var plugin: EditorPlugin
var _active := false
## Handle under the cursor while idle; highlighted so a click's target reads.
var hovered := Handle.NONE
var _drag := Handle.NONE
var _hover_face := -1
var _cursor := Vector2.ZERO


var _data: UBMeshData
var _before: UBMeshData
var _orig := {}
var _frame: UBUVFrame
var _plane := Plane()
var _gizmo_world := Vector3.ZERO
var _pivot_uv := Vector2.ZERO
var _press_uv := Vector2.ZERO
var _moved := false
var _rot_prev := 0.0
var _rot_total := 0.0
var _readout := ""


func active() -> bool:
	return _active


func begin() -> void:
	if plugin.edited == null or plugin.edited.mesh_data == null:
		return
	_active = true

	plugin.selection.change_mode(UBSelection.Mode.FACE, plugin.edited.mesh_data)
	_suppress_tint(true)


func _exit() -> void:
	cancel_drag()
	_active = false
	_clear_hover()
	_suppress_tint(false)
	plugin.material_ended()


func cancel() -> void:
	cancel_drag()
	_active = false
	_clear_hover()
	_suppress_tint(false)


## Revert a live drag only, keeping the mode. Returns whether one was live.
## The plugin's global undo chord uses this to end the gesture rather than
## let editor history move under the drag's before-snapshot.
func cancel_drag() -> bool:
	if _drag == Handle.NONE:
		return false
	if _before != null and _data != null and is_instance_valid(_data):
		_data.copy_from(_before)
		_data.notify_changed()
	_reset_drag()
	return true


func _reset_drag() -> void:
	_drag = Handle.NONE
	_data = null
	_before = null
	_orig = {}
	_frame = null
	_moved = false
	_readout = ""


func _clear_hover() -> void:
	hovered = Handle.NONE
	_hover_face = -1


func _suppress_tint(on: bool) -> void:
	if plugin.gizmo_plugin != null:
		plugin.gizmo_plugin.suppress_face_tint("material", on)


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventKey:

		var verdict: int = plugin.handle_tool_mode_key(event, 6, cancel_drag, _exit)
		return verdict if verdict >= 0 else EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var node = plugin.edited
		if node == null or not is_instance_valid(node) or node.mesh_data == null:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		if event.pressed:
			_cursor = event.position
			var h := hit_test(camera, event.position)
			if h != Handle.NONE:
				_begin_drag(camera, h, event.position)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			var f := UBPicking.pick_face(node, camera, event.position)
			if f >= 0:
				plugin.selection.click_key(f, event.shift_pressed)
			elif not event.shift_pressed:
				plugin.selection.clear_elements()
			plugin.update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if _drag != Handle.NONE:
			_end_drag()
			plugin.update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion:
		_cursor = event.position
		if _drag != Handle.NONE:
			_update_drag(camera, event.position, event.ctrl_pressed)
			plugin.update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		hovered = hit_test(camera, event.position)
		var node = plugin.edited
		_hover_face = -1
		if hovered == Handle.NONE and node != null and is_instance_valid(node) \
				and node.mesh_data != null:
			_hover_face = UBPicking.pick_face(node, camera, event.position)
		plugin.update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	return EditorPlugin.AFTER_GUI_INPUT_PASS


## The pointer left every 3D viewport: drop the hover so the face outline and
## handle highlight do not linger at their last position.
func pointer_left() -> void:
	if hovered == Handle.NONE and _hover_face < 0:
		return
	_clear_hover()
	plugin.update_overlays()


## The displayed UVs of one face: its manual coords, else the auto projection
## evaluated as the compiler would (world anchor included).
static func display_uvs(data: UBMeshData, fi: int, xf: Transform3D) -> PackedVector2Array:
	var face: UBFace = data.faces[fi]
	if face.uv_manual and face.uv_coords.size() == face.vertices.size():
		return face.uv_coords.duplicate()
	var corners := PackedVector3Array()
	for vi in face.vertices:
		corners.append(data.positions[vi])
	return UBUVUnwrap.face_uvs(corners, data.face_normal(face), face, xf)


func _reference(node) -> Dictionary:
	var data: UBMeshData = node.mesh_data
	var xf: Transform3D = node.global_transform
	var best := -1
	var best_area := -1.0
	var best_corners := PackedVector3Array()
	var best_normal := Vector3.ZERO
	for fi in plugin.selection.faces:
		if not (fi is int) or fi < 0 or fi >= data.faces.size():
			continue
		var corners := PackedVector3Array()
		for vi in data.faces[fi].vertices:
			corners.append(xf * data.positions[vi])
		var n := UBTriangulate.newell_normal(corners)
		var area := n.length()
		if area > best_area:
			best_area = area
			best = fi
			best_corners = corners
			best_normal = n
	if best < 0 or best_area <= 1e-12:
		return {}
	var normal := best_normal.normalized()
	var frame := UBUVFrame.fit(best_corners, display_uvs(data, best, xf), normal)
	if frame == null:
		return {}

	var plane := Plane(normal, frame.origin)
	return {"frame": frame, "plane": plane, "at": plane.project(plugin.selection_pivot_world())}


func _layout(camera: Camera3D) -> Dictionary:
	var frame: UBUVFrame
	var at: Vector3
	if _drag != Handle.NONE:
		frame = _frame
		at = _gizmo_world
	else:
		var node = plugin.edited
		if node == null or not is_instance_valid(node) or node.mesh_data == null:
			return {}
		var ref := _reference(node)
		if ref.is_empty():
			return {}
		frame = ref.frame
		at = ref.at
	if frame == null or camera == null or camera.is_position_behind(at):
		return {}
	var origin := camera.unproject_position(at)
	var su := UBGizmoMath.screen_dir(camera, at, frame.dir_u())
	var sv := UBGizmoMath.screen_dir(camera, at, frame.dir_v())

	var ring := PackedVector2Array()
	var ppu := _px_per_unit(camera, at, frame.t)
	if ppu > 1e-6:
		var r := RING_PX / ppu
		for i in RING_SEGMENTS:
			var a := TAU * float(i) / RING_SEGMENTS
			var wp: Vector3 = at + (frame.t * cos(a) + frame.b * sin(a)) * r
			if camera.is_position_behind(wp):
				ring = PackedVector2Array()
				break
			ring.append(camera.unproject_position(wp))
	return {"origin": origin, "su": su, "sv": sv, "ring": ring}


static func _px_per_unit(camera: Camera3D, at: Vector3, dir: Vector3) -> float:
	var k := maxf(0.001, camera.global_position.distance_to(at) * 0.01)
	var probe := at + dir * k
	if camera.is_position_behind(probe):
		return 0.0
	return (camera.unproject_position(probe) - camera.unproject_position(at)).length() / k


static func _tip_u(lay: Dictionary) -> Vector2:
	return lay.origin + lay.su * AXIS_LEN_PX


static func _tip_v(lay: Dictionary) -> Vector2:
	return lay.origin + lay.sv * AXIS_LEN_PX


static func _corner(lay: Dictionary) -> Vector2:
	return lay.origin + (lay.su + lay.sv) * (AXIS_LEN_PX * CORNER_FRAC)


func hit_test(camera: Camera3D, pos: Vector2) -> Handle:
	var lay := _layout(camera)
	if lay.is_empty():
		return Handle.NONE
	if pos.distance_to(lay.origin) <= CENTER_PX:
		return Handle.MOVE
	var has_u: bool = lay.su != Vector2.ZERO
	var has_v: bool = lay.sv != Vector2.ZERO
	if has_u and has_v and pos.distance_to(_corner(lay)) <= TIP_PX:
		return Handle.SCALE_UNIFORM
	if has_u and pos.distance_to(_tip_u(lay)) <= TIP_PX:
		return Handle.SCALE_U
	if has_v and pos.distance_to(_tip_v(lay)) <= TIP_PX:
		return Handle.SCALE_V
	var ring: PackedVector2Array = lay.ring
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		if Geometry2D.get_closest_point_to_segment(pos, a, b).distance_to(pos) <= HIT_PX:
			return Handle.ROTATE
	return Handle.NONE


func _plane_hit(camera: Camera3D, pos: Vector2) -> Variant:
	return _plane.intersects_ray(camera.project_ray_origin(pos), camera.project_ray_normal(pos))


func _begin_drag(camera: Camera3D, handle: Handle, pos: Vector2) -> void:
	var node = plugin.edited
	var data: UBMeshData = node.mesh_data
	var ref := _reference(node)
	if ref.is_empty():
		return
	_frame = ref.frame
	_plane = ref.plane
	_gizmo_world = ref.at
	var hit: Variant = _plane_hit(camera, pos)
	if hit == null:
		_frame = null
		return
	_before = data.duplicate_data()
	_data = data
	var faces: Dictionary = plugin.selection.faces.duplicate()
	UBOpUV.bake_manual(data, faces, node.global_transform)
	var corners := UBOpUV.corners_of(data, faces)
	_orig = {}
	for key: Vector2i in corners:
		_orig[key] = data.faces[key.x].uv_coords[key.y]

	_pivot_uv = _frame.uv_at(_gizmo_world)
	_press_uv = _frame.uv_at(hit)
	_drag = handle
	_moved = false
	_rot_prev = (_press_uv - _pivot_uv).angle()
	_rot_total = 0.0
	_readout = ""


func _update_drag(camera: Camera3D, pos: Vector2, ctrl: bool) -> void:
	if _data == null or not is_instance_valid(_data):
		return
	var hit: Variant = _plane_hit(camera, pos)
	if hit == null:
		return
	var now_uv: Vector2 = _frame.uv_at(hit)
	var snap_on: bool = plugin.toolbar != null and plugin.toolbar.snap_enabled != ctrl
	var step := _uv_step() if snap_on else 0.0
	var xf := Transform2D.IDENTITY
	match _drag:
		Handle.MOVE:
			xf = move_transform(_press_uv, now_uv, step)

			_readout = "%.3f, %.3f" % [-xf.origin.x, -xf.origin.y]
		Handle.ROTATE:

			var raw := (now_uv - _pivot_uv).angle()
			_rot_total += wrapf(raw - _rot_prev, -PI, PI)
			_rot_prev = raw
			var angle := snappedf(_rot_total, ROTATE_SNAP) if snap_on else _rot_total
			xf = rotate_transform(_pivot_uv, angle)
			_readout = "%.1f°" % rad_to_deg(angle)
		Handle.SCALE_U, Handle.SCALE_V, Handle.SCALE_UNIFORM:
			var axis := Vector2.ONE
			if _drag == Handle.SCALE_U:
				axis = Vector2.RIGHT
			elif _drag == Handle.SCALE_V:
				axis = Vector2.DOWN
			xf = scale_transform(_pivot_uv, _press_uv, now_uv, axis, step)
			var s := 1.0 / (xf.get_scale().x if axis.x > 0.0 else xf.get_scale().y)
			_readout = "x%.3f" % s
	if not xf.is_equal_approx(Transform2D.IDENTITY):
		_moved = true
	var moved := {}
	for key: Vector2i in _orig:
		moved[key] = xf * _orig[key]
	UBOpUV.set_uvs(_data, moved)
	_data.notify_changed()


func _end_drag() -> void:
	var name: String = UNDO_NAMES.get(_drag, "Transform Face UVs")
	var data := _data
	var before := _before
	var moved := _moved
	_reset_drag()
	if data == null or not is_instance_valid(data) or before == null:
		return

	if moved and is_instance_valid(plugin.edited) and plugin.edited.mesh_data == data:
		plugin._commit_snapshot_op(name, before)
	else:

		data.copy_from(before)
		data.notify_changed()


func _uv_step() -> float:
	if plugin.uv_editor != null and is_instance_valid(plugin.uv_editor):
		return plugin.uv_editor.snap_step_uv()
	return DEFAULT_UV_STEP


## Slide the texture by the cursor's UV travel: UVs move the opposite way.
## step > 0 quantizes the travel to that UV grid.
static func move_transform(press_uv: Vector2, now_uv: Vector2, step: float) -> Transform2D:
	var d := now_uv - press_uv
	if step > 0.0:
		d = (d / step).round() * step
	return Transform2D(0.0, -d)


## Turn the texture by `angle` about the pivot: UVs rotate by -angle.
static func rotate_transform(pivot: Vector2, angle: float) -> Transform2D:
	return Transform2D(0.0, pivot) * Transform2D(-angle, Vector2.ZERO) * Transform2D(0.0, -pivot)


## Grow the texture by the cursor's distance ratio from the pivot along
## `axis` (RIGHT = U only, DOWN = V only, ONE = uniform): UVs scale by the
## reciprocal about the pivot. Factors floor at UBScaleGizmo.MIN_FACTOR, so
## the gizmo never mirrors (use Flip U/V in the UV editor) and a snapped
## factor can never reach 0 and collapse the selection.
static func scale_transform(pivot: Vector2, press_uv: Vector2, now_uv: Vector2,
		axis: Vector2, step: float) -> Transform2D:
	var p := press_uv - pivot
	var q := now_uv - pivot
	var s := 1.0
	if axis == Vector2.ONE:
		if p.length() > 1e-9:
			s = q.length() / p.length()
	elif axis.x > 0.0:
		if absf(p.x) > 1e-9:
			s = q.x / p.x
	else:
		if absf(p.y) > 1e-9:
			s = q.y / p.y
	if step > 0.0:
		s = snappedf(s, step)
	s = maxf(s, UBScaleGizmo.MIN_FACTOR)
	var inv := 1.0 / s
	var sx := inv if axis.x > 0.0 else 1.0
	var sy := inv if axis.y > 0.0 else 1.0
	var scale := Transform2D(Vector2(sx, 0.0), Vector2(0.0, sy), Vector2.ZERO)
	return Transform2D(0.0, pivot) * scale * Transform2D(0.0, -pivot)


func draw_overlay(overlay: Control, camera: Camera3D) -> void:
	if not _active or camera == null:
		return
	if _drag == Handle.NONE:
		_draw_hover_face(overlay, camera)
	var lay := _layout(camera)
	if lay.is_empty():
		return
	var origin: Vector2 = lay.origin

	var ring: PackedVector2Array = lay.ring
	if not ring.is_empty():
		var ring_hot := _hot(Handle.ROTATE)
		var ring_color := TEAL.lightened(0.35) if ring_hot else Color(1, 1, 1, 0.5)
		for i in ring.size():
			overlay.draw_line(ring[i], ring[(i + 1) % ring.size()], ring_color,
				3.0 if ring_hot else 1.5, true)

	_draw_axis(overlay, origin, _tip_u(lay), TEAL, Handle.SCALE_U)
	_draw_axis(overlay, origin, _tip_v(lay), AMBER, Handle.SCALE_V)
	if lay.su != Vector2.ZERO and lay.sv != Vector2.ZERO:
		_draw_square(overlay, _corner(lay), TIP_PX * 0.8, Color(1, 1, 1, 0.9), _hot(Handle.SCALE_UNIFORM))
	_draw_square(overlay, origin, CENTER_PX, Color(1, 1, 1, 0.9), _hot(Handle.MOVE))
	if _drag != Handle.NONE and not _readout.is_empty():
		var font := overlay.get_theme_font("font", "Label")
		var size := overlay.get_theme_font_size("font_size", "Label")
		var pos := _cursor + Vector2(16, -12)
		overlay.draw_string(font, pos + Vector2(1, 1), _readout, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.8))
		overlay.draw_string(font, pos, _readout, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color.WHITE)


func _hot(h: Handle) -> bool:
	return hovered == h or _drag == h


func _draw_axis(overlay: Control, origin: Vector2, tip: Vector2, color: Color, h: Handle) -> void:
	if tip == origin:
		return
	var hot := _hot(h)
	var c := color.lightened(0.35) if hot else color
	overlay.draw_line(origin, tip, c, 3.0 if hot else 2.0, true)
	_draw_square(overlay, tip, TIP_PX, c, hot)


static func _draw_square(overlay: Control, at: Vector2, size: float, color: Color, hot: bool) -> void:
	var rect := Rect2(at - Vector2(size, size) * 0.5, Vector2(size, size))
	if hot:
		overlay.draw_rect(rect, Color(color, 0.35), true)
	overlay.draw_rect(rect, color, false, 3.0 if hot else 2.0)


func _draw_hover_face(overlay: Control, camera: Camera3D) -> void:
	var node = plugin.edited
	if node == null or not is_instance_valid(node) or node.mesh_data == null:
		return
	var data: UBMeshData = node.mesh_data
	if _hover_face < 0 or _hover_face >= data.faces.size():
		return
	var xf: Transform3D = node.global_transform
	var pts := PackedVector2Array()
	for vi in data.faces[_hover_face].vertices:
		var wp: Vector3 = xf * data.positions[vi]
		if camera.is_position_behind(wp):
			return
		pts.append(camera.unproject_position(wp))
	if pts.size() < 3:
		return
	var tint := Color(0.75, 1.0, 0.95, 0.9)
	for i in pts.size():
		overlay.draw_line(pts[i], pts[(i + 1) % pts.size()], Color(tint, 0.7), 2.0, true)
