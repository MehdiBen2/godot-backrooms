@tool
class_name UBUVEditor
extends VBoxContainer
## Manual UV editor, shown as an editor bottom panel. Displays the UV layout of the
## edited node's faces (the 3D face selection when there is one, else the whole
## mesh), with UV face/vertex selection, snapped drags and the UBOpUV actions. Every
## mutation is one undo entry. Auto faces draw dimmed; editing one bakes it to
## manual in place first.

const TEAL := Color(0.369, 0.918, 0.831)
const AMBER := Color(0.984, 0.749, 0.141)
const BG := Color(0.11, 0.12, 0.14)
const PICK_PX := 8.0
## Zoom rails, shared by the wheel and the Frame buttons.
const ZOOM_MIN := 8.0
const ZOOM_MAX := 20000.0
## Margin left around a framed selection, as a fraction of the view on each side,
## so the neighbouring UVs stay on screen.
const FRAME_MARGIN := 0.12
## The panel's layout; create() instantiates it.
const SCENE := "res://addons/unibuilder/editor/uv_editor.tscn"

enum Drag { NONE, PAN, MOVE, SCALE, ROTATE, MARQUEE }

var plugin: EditorPlugin

var _canvas: Control
var _info: Label
var _vert_mode_btn: Button
var _face_mode_btn: Button
var _snap_btn: Button
var _step_spin: SpinBox
var _tile_btn: Button

## UV-space selection, owned here (the 3D selection is separate).
var sel_faces := {}
var sel_corners := {}

var _zoom := 220.0
var _pan := Vector2(60.0, 40.0)
var _framed := false

var _uvs := {}
var _scope := {}

var _drag := Drag.NONE
var _drag_start := Vector2.ZERO
var _drag_orig := {}
var _drag_before: UBMeshData


var _drag_data: UBMeshData
var _drag_moved := false
var _scale_pivot := Vector2.ZERO
var _scale_factors := Vector2.ONE
var _rotate_angle := 0.0
var _scale_cursor := Vector2.ZERO
var _scale_u: SpinBox
var _scale_v: SpinBox
var _split_btn: Button


var _lock_btn: Button
var _drag_bounds := Rect2()
var _copied_coords := PackedVector2Array()
var _marquee := Rect2()


var _pointer_over := false


## The one way to make this control (plugin and tests both use it). The layout
## lives in uv_editor.tscn; the icons are rasterized here because they follow
## the editor's scale and theme, which a saved scene cannot.
static func create() -> UBUVEditor:
	var editor := (load(SCENE) as PackedScene).instantiate() as UBUVEditor
	editor._dress()
	return editor


func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_canvas = %Canvas
		_info = %Info
		_vert_mode_btn = %VertMode
		_face_mode_btn = %FaceMode
		_snap_btn = %Snap
		_step_spin = %Step
		_tile_btn = %Tile
		_scale_u = %ScaleU
		_scale_v = %ScaleV
		_split_btn = %Split
		_lock_btn = %Lock


func _dress() -> void:
	for b: Button in %Bar.get_children().filter(func(n: Node) -> bool: return n is Button):
		if b.has_meta("icon"):
			UBOverlayToolbar._iconify(b, b.get_meta("icon"), b.text)
		if b.toggle_mode:
			UBOverlayToolbar.dim_toggle(b)

	UBAdjustPanel.free_float_field(_scale_u, 0.01)
	UBAdjustPanel.free_float_field(_scale_v, 0.01)
	UBAdjustPanel.free_float_field(_step_spin, 0.001)


func _on_view_option_changed(_value: Variant) -> void:
	_canvas.queue_redraw()


func _on_canvas_resized() -> void:
	if not _framed:
		_frame_unit()


func _process(_delta: float) -> void:
	var over := (
		is_visible_in_tree()
		and get_global_rect().has_point(get_global_mouse_position())
	)
	if over == _pointer_over:
		return
	_pointer_over = over
	if plugin == null or not is_instance_valid(plugin) or plugin.gizmo_plugin == null:
		return
	plugin.gizmo_plugin.suppress_face_tint("uv_editor", over)
	if plugin.edited != null:
		plugin.edited.update_gizmos()


func _data() -> UBMeshData:

	if plugin == null or not is_instance_valid(plugin):
		return null
	var node = plugin.edited
	if node == null or not is_instance_valid(node):
		return null
	return node.mesh_data


func _display_faces() -> Dictionary:
	var data := _data()
	if data == null:
		return {}
	var sel = plugin.selection
	if sel != null and sel.mode == UBSelection.Mode.FACE and not sel.faces.is_empty():
		return sel.faces.duplicate()
	var all := {}
	for fi in data.faces.size():
		all[fi] = true
	return all


func _target_faces() -> Dictionary:
	if not sel_faces.is_empty():
		return sel_faces.duplicate()
	if not sel_corners.is_empty():
		var out := {}
		for key: Vector2i in sel_corners:
			out[key.x] = true
		return out
	return _display_faces()


func _target_corners() -> Dictionary:
	var data := _data()
	if data == null:
		return {}
	if not sel_corners.is_empty():
		return sel_corners.duplicate()
	return UBOpUV.corners_of(data, _target_faces())


## Rebuilds the display cache and prunes the UV selection against the mesh.
func refresh() -> void:
	var data := _data()
	_uvs.clear()
	_scope = _display_faces()
	if data != null:
		for fi in _scope:
			var face: UBFace = data.faces[fi]
			if face.uv_manual and face.uv_coords.size() == face.vertices.size():
				_uvs[fi] = face.uv_coords.duplicate()
			else:
				var corners := PackedVector3Array()
				for vi in face.vertices:
					corners.append(data.positions[vi])
				_uvs[fi] = UBUVUnwrap.face_uvs(
					corners, data.face_normal(face), face, _world_transform())
		for fi in sel_faces.keys():
			if not _scope.has(fi):
				sel_faces.erase(fi)
		for key: Vector2i in sel_corners.keys():
			if not _scope.has(key.x) or key.y >= data.faces[key.x].vertices.size():
				sel_corners.erase(key)
	else:
		sel_faces.clear()
		sel_corners.clear()
	_update_info()
	_canvas.queue_redraw()


func _world_transform() -> Transform3D:

	var node = plugin.edited if plugin != null and is_instance_valid(plugin) else null
	if node != null and is_instance_valid(node) and node.is_inside_tree():
		return node.global_transform
	return Transform3D.IDENTITY


func _update_info() -> void:
	var data := _data()
	if data == null:
		_info.text = "Select a Unibuilder mesh"
		return
	var manual := 0
	for fi in _scope:
		if data.faces[fi].uv_manual:
			manual += 1
	var picked := sel_faces.size() if not sel_faces.is_empty() else sel_corners.size()
	var what := "faces" if not sel_faces.is_empty() else "corners"
	_info.text = "%d faces (%d manual), %d %s selected" % [_scope.size(), manual, picked, what]


func uv_to_px(uv: Vector2) -> Vector2:
	return uv * _zoom + _pan


func px_to_uv(px: Vector2) -> Vector2:
	return (px - _pan) / _zoom


## The UV grid step the material-mode gizmo snaps to. Independent of this panel's
## own Snap toggle; the viewport gizmo answers to the toolbar's Snap.
func snap_step_uv() -> float:
	return maxf(_step_spin.value, 0.001)


func _frame_unit() -> void:
	var size := _canvas.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_zoom = minf(size.x, size.y) * 0.8
	_pan = (size - Vector2(_zoom, _zoom)) * 0.5
	_framed = true
	_canvas.queue_redraw()


func _frame_uv_rect(rect: Rect2) -> void:
	var size := _canvas.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var avail := size * (1.0 - 2.0 * FRAME_MARGIN)
	var fit := INF
	if rect.size.x > 1e-6:
		fit = minf(fit, avail.x / rect.size.x)
	if rect.size.y > 1e-6:
		fit = minf(fit, avail.y / rect.size.y)
	if is_finite(fit):
		_zoom = clampf(fit, ZOOM_MIN, ZOOM_MAX)
	_pan = size * 0.5 - rect.get_center() * _zoom
	_framed = true
	_canvas.queue_redraw()


func _selection_uv_bounds() -> Rect2:
	var lo := Vector2.INF
	var hi := -Vector2.INF
	if not sel_corners.is_empty():
		for key: Vector2i in sel_corners:
			var uvs: PackedVector2Array = _uvs.get(key.x, PackedVector2Array())
			if key.y < uvs.size():
				lo = lo.min(uvs[key.y])
				hi = hi.max(uvs[key.y])
	else:
		var faces: Dictionary = sel_faces if not sel_faces.is_empty() else _scope
		for fi in faces:
			for uv: Vector2 in _uvs.get(fi, PackedVector2Array()):
				lo = lo.min(uv)
				hi = hi.max(uv)
	if lo.x > hi.x:
		return Rect2(0.0, 0.0, -1.0, -1.0)
	return Rect2(lo, hi - lo)


func _draw_canvas() -> void:
	var size := _canvas.size
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	var data := _data()
	if data == null:
		var font := get_theme_font("font", "Label")
		_canvas.draw_string(font, size * 0.5 + Vector2(-90.0, 0.0),
			"Select a Unibuilder mesh", HORIZONTAL_ALIGNMENT_LEFT, -1,
			get_theme_font_size("font_size", "Label"), Color(1, 1, 1, 0.35))
		return

	_draw_texture_underlay()
	_draw_grid(size)

	for fi in _uvs:
		var face: UBFace = data.faces[fi]
		var uvs: PackedVector2Array = _uvs[fi]
		var pts := PackedVector2Array()
		for uv in uvs:
			pts.append(uv_to_px(uv))
		var selected: bool = sel_faces.has(fi)
		if selected:

			var fill := pts.duplicate()
			if not Geometry2D.triangulate_polygon(fill).is_empty():
				_canvas.draw_colored_polygon(fill, Color(AMBER, 0.18))
		var wire := Color(TEAL, 0.8) if face.uv_manual else Color(TEAL, 0.3)
		if selected:
			wire = AMBER
		for i in pts.size():
			_canvas.draw_line(pts[i], pts[(i + 1) % pts.size()], wire, 1.5, true)
		if _vert_mode_btn.button_pressed:
			for ci in pts.size():
				var col := AMBER if sel_corners.has(Vector2i(fi, ci)) else TEAL
				_canvas.draw_rect(Rect2(pts[ci] - Vector2(2.5, 2.5), Vector2(5.0, 5.0)), col, true)

	if _drag == Drag.MARQUEE:
		_canvas.draw_rect(_marquee.abs(), Color(TEAL, 0.1), true)
		_canvas.draw_rect(_marquee.abs(), Color(TEAL, 0.7), false, 1.0)
	elif _drag == Drag.SCALE or _drag == Drag.ROTATE:

		var pp := uv_to_px(_scale_pivot)
		_canvas.draw_line(pp - Vector2(6, 0), pp + Vector2(6, 0), AMBER, 1.5)
		_canvas.draw_line(pp - Vector2(0, 6), pp + Vector2(0, 6), AMBER, 1.5)
		var text: String
		if _drag == Drag.ROTATE:
			text = "%.1f°" % rad_to_deg(_rotate_angle)
		elif is_equal_approx(_scale_factors.x, _scale_factors.y):
			text = "× %.3f" % _scale_factors.x
		else:
			text = "× %.3f, %.3f" % [_scale_factors.x, _scale_factors.y]
		var font := get_theme_font("font", "Label")
		var fsize := get_theme_font_size("font_size", "Label")
		var pos := _scale_cursor + Vector2(16, -12)
		_canvas.draw_string(font, pos + Vector2(1, 1), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0, 0, 0, 0.8))
		_canvas.draw_string(font, pos, text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color.WHITE)


func _draw_texture_underlay() -> void:
	var data := _data()
	var tex: Texture2D = null
	for fi in _scope:
		var slot: int = data.faces[fi].material_index
		if slot >= 0 and slot < data.material_slots.size():
			var mat := data.material_slots[slot] as BaseMaterial3D
			if mat != null and mat.albedo_texture != null:
				tex = mat.albedo_texture
				break
	if tex == null:
		return

	if _tile_btn.button_pressed:

		var lo := px_to_uv(Vector2.ZERO).floor()
		var hi := px_to_uv(_canvas.size).ceil()
		var cells := hi - lo
		var size := tex.get_size()
		_canvas.draw_texture_rect_region(tex, Rect2(uv_to_px(lo), cells * _zoom),
			Rect2(lo * size, cells * size), Color.WHITE)
		return
	_canvas.draw_texture_rect(tex, Rect2(uv_to_px(Vector2.ZERO), Vector2(_zoom, _zoom)),
		false, Color(1, 1, 1, 0.4))


func _draw_grid(size: Vector2) -> void:
	var step: float = maxf(_step_spin.value, 0.001)
	var uv_min := px_to_uv(Vector2.ZERO)
	var uv_max := px_to_uv(size)
	if (uv_max.x - uv_min.x) / step < 200.0:
		var minor := Color(1, 1, 1, 0.05)
		var x := floorf(uv_min.x / step) * step
		while x <= uv_max.x:
			_canvas.draw_line(uv_to_px(Vector2(x, uv_min.y)), uv_to_px(Vector2(x, uv_max.y)), minor)
			x += step
		var y := floorf(uv_min.y / step) * step
		while y <= uv_max.y:
			_canvas.draw_line(uv_to_px(Vector2(uv_min.x, y)), uv_to_px(Vector2(uv_max.x, y)), minor)
			y += step

	var unit := Rect2(uv_to_px(Vector2.ZERO), Vector2(_zoom, _zoom))
	if _lock_btn.button_pressed:
		_canvas.draw_rect(unit, Color(AMBER, 0.8), false, 2.0)
	else:
		_canvas.draw_rect(unit, Color(TEAL, 0.45), false, 1.0)


func _on_canvas_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1.15)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, 1.0 / 1.15)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:

			if mb.pressed:
				if _drag == Drag.NONE:
					_drag = Drag.PAN
			elif _drag == Drag.PAN:
				_drag = Drag.NONE
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_on_left_press(mb)
			else:
				_on_left_release()
		_canvas.accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		match _drag:
			Drag.PAN:
				_pan += mm.relative
				_canvas.queue_redraw()
			Drag.MOVE:
				_update_move(mm.position)
			Drag.SCALE:
				_update_scale(mm.position, mm.shift_pressed)
			Drag.ROTATE:
				_update_rotate(mm.position)
			Drag.MARQUEE:
				_marquee.size = mm.position - _marquee.position
				_canvas.queue_redraw()
		_canvas.accept_event()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _drag == Drag.MOVE or _drag == Drag.SCALE or _drag == Drag.ROTATE:
			_cancel_move()
		elif _drag == Drag.MARQUEE:

			_drag = Drag.NONE
			_canvas.queue_redraw()
		else:
			sel_faces.clear()
			sel_corners.clear()
			_update_info()
			_canvas.queue_redraw()
		_canvas.accept_event()


func _zoom_at(px: Vector2, factor: float) -> void:

	var old := _zoom
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_pan = px - (px - _pan) * (_zoom / old)
	_canvas.queue_redraw()


func _on_left_press(mb: InputEventMouseButton) -> void:
	_canvas.grab_focus()
	if _data() == null:
		return
	if mb.double_click:
		_select_island(mb.position, mb.shift_pressed)
		return
	if mb.alt_pressed:

		var rot_corners := (
			sel_corners.duplicate() if _vert_mode_btn.button_pressed
			else UBOpUV.corners_of(_data(), sel_faces)
		)
		if not rot_corners.is_empty():
			_begin_scale(mb.position, rot_corners)
			_drag = Drag.ROTATE
			_rotate_angle = 0.0
			return
	if mb.ctrl_pressed:

		var corners := (
			sel_corners.duplicate() if _vert_mode_btn.button_pressed
			else UBOpUV.corners_of(_data(), sel_faces)
		)
		if not corners.is_empty():
			_begin_scale(mb.position, corners)
			return
	if _vert_mode_btn.button_pressed:
		var hits := _pick_corners(mb.position)
		if hits.is_empty():
			_begin_marquee(mb)
			return
		var any_selected := false
		for key in hits:
			if sel_corners.has(key):
				any_selected = true
		if not any_selected:
			if not mb.shift_pressed:
				sel_corners.clear()
			for key in hits:
				sel_corners[key] = true
		elif mb.shift_pressed:
			for key in hits:
				sel_corners.erase(key)
			_update_info()
			_canvas.queue_redraw()
			return
		_begin_move(mb.position, sel_corners.duplicate())
	else:
		var fi := _pick_face(mb.position)
		if fi < 0:
			_begin_marquee(mb)
			return
		if not sel_faces.has(fi):
			if not mb.shift_pressed:
				sel_faces.clear()
			sel_faces[fi] = true
		elif mb.shift_pressed:
			sel_faces.erase(fi)
			_update_info()
			_canvas.queue_redraw()
			return
		_begin_move(mb.position, UBOpUV.corners_of(_data(), sel_faces))
	_update_info()
	_canvas.queue_redraw()


func _on_left_release() -> void:
	match _drag:
		Drag.MOVE, Drag.SCALE, Drag.ROTATE:
			var op_name := "Move UVs"
			if _drag == Drag.SCALE:
				op_name = "Scale UVs"
			elif _drag == Drag.ROTATE:
				op_name = "Rotate UVs"
			_drag = Drag.NONE

			if _drag_before != null and _drag_data != null:

				if _drag_moved and _data() == _drag_data:
					plugin._commit_snapshot_op(op_name, _drag_before)
				else:
					_drag_data.copy_from(_drag_before)
					_drag_data.notify_changed()
			_drag_before = null
			_drag_data = null
		Drag.MARQUEE:
			_drag = Drag.NONE
			_apply_marquee()
	_canvas.queue_redraw()


func _pick_corners(px: Vector2) -> Array:
	var hits := []
	var best := Vector2i(-1, -1)
	var best_d := float(PICK_PX)
	for fi in _uvs:
		var uvs: PackedVector2Array = _uvs[fi]
		for ci in uvs.size():
			var d := uv_to_px(uvs[ci]).distance_to(px)
			if d <= PICK_PX:
				hits.append(Vector2i(fi, ci))
				if d < best_d:
					best_d = d
					best = Vector2i(fi, ci)
	if _split_btn.button_pressed:
		return [best] if best.x >= 0 else []
	return hits


func _select_island(px: Vector2, additive: bool) -> void:
	var fi := _pick_face(px)
	var data := _data()
	if fi < 0 or data == null:
		return
	var island := UBOpUV.island_faces(data, fi)
	if _vert_mode_btn.button_pressed:
		if not additive:
			sel_corners.clear()
		for key: Vector2i in UBOpUV.corners_of(data, island):
			sel_corners[key] = true
	else:
		if not additive:
			sel_faces.clear()
		for isle_fi in island:
			sel_faces[isle_fi] = true
	_update_info()
	_canvas.queue_redraw()


func _pick_face(px: Vector2) -> int:
	var uv := px_to_uv(px)
	for fi in _uvs:
		var poly: PackedVector2Array = _uvs[fi]
		if Geometry2D.is_point_in_polygon(uv, poly):
			return fi
	return -1


func _begin_marquee(mb: InputEventMouseButton) -> void:
	_drag = Drag.MARQUEE
	_marquee = Rect2(mb.position, Vector2.ZERO)
	if not mb.shift_pressed:
		sel_faces.clear()
		sel_corners.clear()
	_update_info()
	_canvas.queue_redraw()


func _apply_marquee() -> void:
	var rect := _marquee.abs()
	if _vert_mode_btn.button_pressed:
		for fi in _uvs:
			var uvs: PackedVector2Array = _uvs[fi]
			for ci in uvs.size():
				if rect.has_point(uv_to_px(uvs[ci])):
					sel_corners[Vector2i(fi, ci)] = true
	else:
		for fi in _uvs:
			var uvs: PackedVector2Array = _uvs[fi]
			for uv in uvs:
				if rect.has_point(uv_to_px(uv)):
					sel_faces[fi] = true
					break
	_update_info()


func _begin_move(px: Vector2, corners: Dictionary) -> void:
	var data := _data()
	if data == null or corners.is_empty():
		return
	_end_adjust_session()
	_drag_before = data.duplicate_data()
	_drag_data = data
	var faces := {}
	for key: Vector2i in corners:
		faces[key.x] = true
	UBOpUV.bake_manual(data, faces, _world_transform())
	_drag = Drag.MOVE
	_drag_moved = false
	_drag_start = px
	_drag_orig.clear()
	for key: Vector2i in corners:
		_drag_orig[key] = data.faces[key.x].uv_coords[key.y]
	_drag_bounds = _points_bounds(_drag_orig.values())


func _update_move(px: Vector2) -> void:
	var data := _drag_data
	if data == null:
		return
	var delta := (px - _drag_start) / _zoom
	if _snap_btn.button_pressed:
		var step: float = maxf(_step_spin.value, 0.001)
		delta = (delta / step).round() * step
	if _lock_btn.button_pressed:

		delta += UBOpUV.unit_lock_offset(
			Rect2(_drag_bounds.position + delta, _drag_bounds.size))
	if delta != Vector2.ZERO:
		_drag_moved = true
	var moved := {}
	for key: Vector2i in _drag_orig:
		moved[key] = _drag_orig[key] + delta
	UBOpUV.set_uvs(data, moved)
	data.notify_changed()


func _begin_scale(px: Vector2, corners: Dictionary) -> void:
	var data := _data()
	if data == null or corners.is_empty():
		return
	_end_adjust_session()
	_drag_before = data.duplicate_data()
	_drag_data = data
	var faces := {}
	for key: Vector2i in corners:
		faces[key.x] = true
	UBOpUV.bake_manual(data, faces, _world_transform())
	_drag = Drag.SCALE
	_drag_moved = false
	_drag_start = px
	_drag_orig.clear()
	for key: Vector2i in corners:
		_drag_orig[key] = data.faces[key.x].uv_coords[key.y]
	_drag_bounds = _points_bounds(_drag_orig.values())
	_scale_pivot = UBOpUV.uv_bounds(data, corners).get_center()


func _update_scale(px: Vector2, per_axis: bool) -> void:
	var data := _drag_data
	if data == null:
		return
	var pivot_px := uv_to_px(_scale_pivot)
	var factors: Vector2
	if per_axis:

		factors = Vector2(
			(px.x - pivot_px.x) / _safe_denom(_drag_start.x - pivot_px.x),
			(px.y - pivot_px.y) / _safe_denom(_drag_start.y - pivot_px.y))
	else:
		var f := pivot_px.distance_to(px) / maxf(pivot_px.distance_to(_drag_start), 4.0)
		factors = Vector2(f, f)
	if _snap_btn.button_pressed:

		var step: float = maxf(_step_spin.value, 0.001)
		factors = Vector2(snappedf(factors.x, step), snappedf(factors.y, step))

	factors.x = _floor_factor(factors.x)
	factors.y = _floor_factor(factors.y)
	if _lock_btn.button_pressed:
		factors = UBOpUV.unit_lock_factors(_drag_bounds.size, factors, not per_axis)
	if not factors.is_equal_approx(Vector2.ONE):
		_drag_moved = true
	_scale_factors = factors
	_scale_cursor = px
	var moved := {}
	for key: Vector2i in _drag_orig:
		moved[key] = _scale_pivot + (_drag_orig[key] - _scale_pivot) * factors
	_lock_moved(moved)
	UBOpUV.set_uvs(data, moved)
	data.notify_changed()
	_canvas.queue_redraw()


static func _safe_denom(v: float) -> float:
	if absf(v) < 1e-6:
		return 4.0
	return signf(v) * maxf(absf(v), 4.0)


static func _floor_factor(f: float) -> float:
	if absf(f) >= UBScaleGizmo.MIN_FACTOR:
		return f
	return UBScaleGizmo.MIN_FACTOR if f >= 0.0 else -UBScaleGizmo.MIN_FACTOR


func _update_rotate(px: Vector2) -> void:
	var data := _drag_data
	if data == null:
		return
	var pivot_px := uv_to_px(_scale_pivot)
	var ang := (px - pivot_px).angle() - (_drag_start - pivot_px).angle()
	if _snap_btn.button_pressed:
		ang = snappedf(ang, deg_to_rad(15.0))
	if not is_zero_approx(ang):
		_drag_moved = true
	_rotate_angle = ang
	_scale_cursor = px
	var xf := (
		Transform2D(0.0, _scale_pivot)
		* Transform2D(ang, Vector2.ZERO)
		* Transform2D(0.0, -_scale_pivot)
	)
	var moved := {}
	for key: Vector2i in _drag_orig:
		moved[key] = xf * _drag_orig[key]
	_lock_moved(moved)
	UBOpUV.set_uvs(data, moved)
	data.notify_changed()
	_canvas.queue_redraw()


func _lock_moved(moved: Dictionary) -> void:
	if not _lock_btn.button_pressed or moved.is_empty():
		return
	var shift := UBOpUV.unit_lock_offset(_points_bounds(moved.values()))
	if shift == Vector2.ZERO:
		return
	for key in moved:
		moved[key] += shift


static func _points_bounds(points: Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var rect := Rect2(points[0], Vector2.ZERO)
	for p: Vector2 in points:
		rect = rect.expand(p)
	return rect


func _end_adjust_session() -> void:
	if plugin != null and is_instance_valid(plugin) and plugin.has_method("_commit_adjust"):
		plugin._commit_adjust()


## End a live canvas gesture the way Esc does: a move/scale/rotate drag reverts
## onto the mesh it started on, a marquee is abandoned. Returns false when
## nothing was live. The plugin calls this before an undo or redo, because the
## drag holds a before-snapshot that history moving underneath would turn stale.
func cancel_drag() -> bool:
	match _drag:
		Drag.MOVE, Drag.SCALE, Drag.ROTATE:
			_cancel_move()
		Drag.MARQUEE:
			_drag = Drag.NONE
		_:
			return false
	_canvas.queue_redraw()
	return true


func _cancel_move() -> void:
	_drag = Drag.NONE

	if _drag_data != null and _drag_before != null:
		_drag_data.copy_from(_drag_before)
		_drag_data.notify_changed()
	_drag_before = null
	_drag_data = null


func _on_mode_switched() -> void:
	sel_faces.clear()
	sel_corners.clear()
	_update_info()
	_canvas.queue_redraw()


func _commit(name: String, mutator: Callable) -> void:
	if _data() == null:
		return
	plugin._commit_topology_op(name, mutator)


func _act_manual() -> void:
	var data := _data()
	var faces := _target_faces()
	var xf := _world_transform()
	if data == null or faces.is_empty():
		return
	_commit("UVs to Manual", func() -> void: UBOpUV.bake_manual(data, faces, xf))


func _act_auto() -> void:
	var data := _data()
	var faces := _target_faces()
	if data == null or faces.is_empty():
		return
	_commit("UVs to Auto", func() -> void: UBOpUV.clear_manual(data, faces))


func _act_planar() -> void:
	var data := _data()
	var faces := _target_faces()
	if data == null or faces.is_empty():
		return
	_commit("Planar Project UVs", func() -> void: UBOpUV.planar_project(data, faces))


func _act_box() -> void:
	var data := _data()
	var faces := _target_faces()
	if data == null or faces.is_empty():
		return
	_commit("Box Project UVs", func() -> void: UBOpUV.box_project(data, faces))


func _act_flip_u() -> void:
	_transform_about_center(Vector2(-1.0, 1.0), 0.0, "Flip UVs U")


func _act_flip_v() -> void:
	_transform_about_center(Vector2(1.0, -1.0), 0.0, "Flip UVs V")


func _act_rot90() -> void:
	_transform_about_center(Vector2.ONE, PI * 0.5, "Rotate UVs 90")


func _transform_about_center(scale: Vector2, rot: float, name: String) -> bool:
	var data := _data()
	if data == null:
		return false
	var faces := _target_faces()
	var corners := _target_corners()
	var xf_world := _world_transform()
	if corners.is_empty():
		return false
	var lock := _lock_btn.button_pressed
	_commit(name, func() -> void:
		UBOpUV.bake_manual(data, faces, xf_world)
		var bounds := UBOpUV.uv_bounds(data, corners)
		var pivot := bounds.get_center()
		var s := scale
		if lock:
			s = UBOpUV.unit_lock_factors(bounds.size, s, is_equal_approx(s.x, s.y))
		var xf := (
			Transform2D(0.0, pivot)
			* Transform2D(rot, Vector2.ZERO)
			* Transform2D(0.0, s, 0.0, Vector2.ZERO)
			* Transform2D(0.0, -pivot)
		)
		UBOpUV.transform_uvs(data, corners, xf)
		if lock:
			var shift := UBOpUV.unit_lock_offset(UBOpUV.uv_bounds(data, corners))
			if shift != Vector2.ZERO:
				UBOpUV.transform_uvs(data, corners, Transform2D(0.0, shift)))
	return true


func _act_fit(axis: UBOpUV.FitAxis) -> void:
	var data := _data()
	var faces := _target_faces()
	var xf := _world_transform()
	if data == null or faces.is_empty():
		return
	var names := {
		UBOpUV.FitAxis.BOTH: "Fit UVs",
		UBOpUV.FitAxis.U: "Fit UVs U",
		UBOpUV.FitAxis.V: "Fit UVs V",
	}
	_commit(names[axis], func() -> void:
		UBOpUV.bake_manual(data, faces, xf)
		UBOpUV.fit_to_unit(data, faces, axis))


func _act_scale() -> void:
	var factors := Vector2(_scale_u.value, _scale_v.value)
	if factors.is_equal_approx(Vector2.ONE):
		return
	if not _transform_about_center(factors, 0.0, "Scale UVs"):
		return

	_scale_u.value = 1.0
	_scale_v.value = 1.0


func _act_sew() -> void:
	var data := _data()
	var corners := _target_corners()
	if data == null or corners.is_empty():
		return
	_commit("Sew UVs", func() -> void: UBOpUV.weld_uvs(data, corners))


func _act_copy() -> void:
	var faces := _target_faces()
	if faces.is_empty():
		return
	var fi: int = faces.keys()[0]
	if _uvs.has(fi):
		_copied_coords = (_uvs[fi] as PackedVector2Array).duplicate()
		_update_info()


func _act_paste() -> void:
	var data := _data()
	var faces := _target_faces()
	if data == null or faces.is_empty() or _copied_coords.is_empty():
		return
	var coords := _copied_coords
	_commit("Paste UVs", func() -> void: UBOpUV.copy_uvs(data, coords, faces))


func _act_texel() -> void:
	var data := _data()
	var faces := _target_faces()
	var xf := _world_transform()
	if data == null or faces.size() < 2:
		return
	var ref: int = faces.keys()[0]
	_commit("Normalize Texel Density", func() -> void:
		UBOpUV.bake_manual(data, faces, xf)

		UBOpUV.texel_normalize(data, faces, ref, xf))


func _act_frame() -> void:
	_frame_unit()


func _act_frame_selection() -> void:
	var rect := _selection_uv_bounds()
	if rect.size.x < 0.0:
		return
	_frame_uv_rect(rect)
