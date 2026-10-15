@tool
class_name UBViewportInput
extends RefCounted
## State machine for 3D-viewport input while a UBMeshInstance3D is edited:
## mode-switch keys, click picking, marquee drag, loop and ring double-clicks,
## and gizmo drags (with Shift+drag extrude in move mode and Shift+drag inset
## in scale mode, both face-mode gestures). Only left-button events and our
## keys are consumed; right, middle and wheel pass through so camera
## navigation keeps working.

const DRAG_THRESHOLD := 6.0

## Set by plugin.gd; exposes .selection, .edited, .toolbar, update_overlays().
var plugin: EditorPlugin

var move_gizmo := UBMoveGizmo.new()
var rotate_gizmo := UBRotateGizmo.new()
var scale_gizmo := UBScaleGizmo.new()
## Last camera seen. The overlay draw pass uses it because the per-viewport
## camera is not available there; it is correct for the viewport under the mouse.
var last_camera: Camera3D

const ROTATE_SNAP_DEG := 15.0

var marquee := false
var marquee_rect := Rect2()
## Hover preselect: the element a plain click would pick, tinted by the
## overlay. -1 / NO_EDGE means nothing is hovered.
var hover_vertex := -1
var hover_edge := UBPicking.NO_EDGE
var hover_face := -1
var _pressed := false
var _press_pos := Vector2.ZERO

## Insert-vertex modal: while active, clicking an edge inserts a vertex at the
## closest point on it (snapped along the edge when Snap is on).
var insert_vert_active := false
var insert_point := Vector3.ZERO
var insert_edge := UBPicking.NO_EDGE


var _modal_adjust := false
var _modal_anchor := Vector2.ZERO
var _modal_has_anchor := false

var _dragging := false
var _obj_dragging := false


var _drag_moved := false
var _obj_start_local := Transform3D.IDENTITY
var _obj_start_global := Transform3D.IDENTITY
var _drag_mode := 0
var _drag_gizmo: RefCounted
var _drag_extrude := false


var _drag_inset := false
var _drag_inset_equal := false
var _drag_inset_ref := 1.0
var _drag_before: UBMeshData
var _start_positions := PackedVector3Array()
var _moved := {}
var _local_pivot := Vector3.ZERO


var _world_axis := Vector3.ZERO
var _node_basis := Basis.IDENTITY
var _local_basis := Basis.IDENTITY


var _snap_targets := PackedVector3Array()
var _snap_anchor := Vector3.ZERO
var snap_hit: Variant = null


var _abs_ref := Vector3.ZERO


var _soft_weights := {}


var _drag_uv_frames := {}
var _last_drag_camera: Camera3D
var _last_drag_pos := Vector2.ZERO
var _last_drag_ctrl := false
var _last_drag_alt := false


## The gizmo the toolbar's W/E/R mode selects, with its orientation applied.
func active_gizmo() -> RefCounted:
	var mode: int = plugin.toolbar.gizmo_mode if plugin.toolbar != null else 0
	var g: RefCounted = [move_gizmo, rotate_gizmo, scale_gizmo][clampi(mode, 0, 2)]
	g.basis = plugin.gizmo_basis_world()
	return g


## Overlay entry point (plugin._forward_3d_draw_over_viewport).
func draw_gizmo(overlay: Control, pivot: Vector3) -> void:
	active_gizmo().draw(overlay, last_camera, pivot)
	_draw_prop_radius(overlay)


func _draw_prop_radius(overlay: Control) -> void:
	if not prop_drag_active() or last_camera == null:
		return
	if not is_instance_valid(plugin.edited) or plugin.toolbar == null:
		return
	var center: Vector3 = plugin.edited.global_transform * _local_pivot
	if last_camera.is_position_behind(center):
		return
	var cp := last_camera.unproject_position(center)
	var right := last_camera.global_transform.basis.x
	var radius: float = plugin.toolbar.prop_radius
	var px := last_camera.unproject_position(center + right * radius).distance_to(cp)
	overlay.draw_arc(cp, px, 0.0, TAU, 64, Color(0.369, 0.918, 0.831, 0.55), 1.5, true)


func forward_input(camera: Camera3D, event: InputEvent) -> int:
	last_camera = camera

	var sel: UBSelection = plugin.selection

	if event is InputEventKey and event.pressed and not event.echo:
		return _handle_key(event, sel)

	if _modal_adjust:
		var handled := _handle_modal_adjust(camera, event)
		if handled != -1:
			return handled

	if insert_vert_active and sel.mode == UBSelection.Mode.EDGE:
		var handled := _handle_insert_vert(camera, event)
		if handled != -1:
			return handled

	if sel.mode == UBSelection.Mode.OBJECT:

		clear_preselect()

		if not _object_mode_active():
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		return _forward_object_input(camera, event)

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.double_click:
				_pressed = false
				_handle_double_click(camera, event)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			if sel.count() > 0:
				var pivot: Vector3 = plugin.selection_pivot_world()
				var g := active_gizmo()
				var handle: int = g.hit_test(camera, pivot, event.position)
				if handle != 0:
					_begin_drag(camera, pivot, handle, event)
					return EditorPlugin.AFTER_GUI_INPUT_STOP
			_pressed = true
			marquee = false
			_press_pos = event.position
			clear_preselect()
			return EditorPlugin.AFTER_GUI_INPUT_STOP

		if _dragging:
			_end_drag()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if not _pressed:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		_pressed = false
		if marquee:
			marquee = false
			_apply_marquee(camera, event)
			plugin.update_overlays()
		else:
			_handle_click(camera, event)
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	if event is InputEventMouseMotion:
		if _dragging:
			_update_drag(camera, event)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if _pressed:
			if not marquee and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
				marquee = true
			if marquee:
				marquee_rect = Rect2(_press_pos, Vector2.ZERO).expand(event.position).abs()
				plugin.update_overlays()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		else:
			_update_gizmo_hover(camera, event.position, sel)
			_update_preselect(camera, event.position, sel)

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _update_gizmo_hover(camera: Camera3D, pos: Vector2, sel: UBSelection) -> void:
	var g := active_gizmo()
	var hovered := 0
	if sel.count() > 0 or (sel.mode == UBSelection.Mode.OBJECT and _object_mode_active()):
		hovered = g.hit_test(camera, plugin.selection_pivot_world(), pos)
	if hovered != g.hovered:
		g.hovered = hovered
		plugin.update_overlays()


func _mesh_data() -> UBMeshData:
	if is_instance_valid(plugin.edited):
		return plugin.edited.mesh_data
	return null


func _update_preselect(camera: Camera3D, pos: Vector2, sel: UBSelection) -> void:
	var v := -1
	var e := UBPicking.NO_EDGE
	var f := -1
	var node = plugin.edited
	if is_instance_valid(node) and node.mesh_data != null and active_gizmo().hovered == 0:
		match sel.mode:
			UBSelection.Mode.VERTEX:
				v = UBPicking.pick_vertex(node, camera, pos)
			UBSelection.Mode.EDGE:
				e = UBPicking.pick_edge(node, camera, pos)
			UBSelection.Mode.FACE:
				f = UBPicking.pick_face(node, camera, pos)
	if v != hover_vertex or e != hover_edge or f != hover_face:
		hover_vertex = v
		hover_edge = e
		hover_face = f
		plugin.update_overlays()


## Drops the hover preselect tint (and redraws when one was showing). Public
## for the plugin: call it when the cursor leaves the 3D viewports or the
## selection mode changes from outside the viewport (toolbar).
func clear_preselect() -> void:
	var had := (
		hover_vertex != -1 or hover_edge != UBPicking.NO_EDGE or hover_face != -1)
	hover_vertex = -1
	hover_edge = UBPicking.NO_EDGE
	hover_face = -1
	if had and plugin != null:
		plugin.update_overlays()


## Abandons a click or marquee whose button is still held, without selecting
## anything. Public for the plugin's _cancel_interactions.
func cancel_press() -> void:
	var had := _pressed or marquee
	_pressed = false
	marquee = false
	marquee_rect = Rect2()
	if had and plugin != null:
		plugin.update_overlays()


static func _press_cancel_key(event: InputEventKey) -> bool:
	if event.keycode == KEY_ESCAPE:
		return not (event.ctrl_pressed or event.alt_pressed or event.meta_pressed)
	return mode_digit(event) != 0


## The mode keys are Shift+1..Shift+6 (1-4 selection modes, 5 paint, 6
## material); returns that digit, or 0 for any other key. Plain digits belong
## to the viewport: "Emulate Numpad" (an editor setting, ON by default) turns
## the top-row digits into the numpad view keys (1 front, 3 right, 7 top, 5
## orthographic, Alt for the opposite views) and Ctrl+1..4 switch the viewport
## layout, so a plain-digit mode key overrode the editor's view navigation.
## Shift+digit is bound nowhere in the editor. Matched on the PHYSICAL key,
## because the emulation rewrites keycode (1 -> KP_1) before plugins see it;
## synthetic events with no physical key fall back to keycode.
static func mode_digit(event: InputEventKey) -> int:
	if not event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return 0
	var key := event.physical_keycode
	if key == KEY_NONE:
		key = event.keycode
		if key >= KEY_KP_1 and key <= KEY_KP_6:
			key = key - KEY_KP_1 + KEY_1
	if key >= KEY_1 and key <= KEY_6:
		return key - KEY_1 + 1
	return 0


func _wer_applies(sel: UBSelection) -> bool:
	if _dragging or _obj_dragging or freelook_held():
		return false
	return sel.mode != UBSelection.Mode.OBJECT or _object_mode_active()


## True while the right mouse button is held, which is how Godot's freelook
## flies the 3D camera: W/S/A/D/Q/E move it and Shift speeds it up, so
## Shift+W and Shift+E are "fly forward/up fast" for that moment. The editor's
## own W/E/R tool keys stand down during freelook and ours must too, or flying
## switched the gizmo. Freelook polls key state, so passing the event through
## costs it nothing.
static func freelook_held() -> bool:
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)


func _begin_modal_adjust(sel: UBSelection) -> bool:
	if _modal_adjust or _dragging or _obj_dragging:
		return false

	end_insert_vert()
	var id := ""
	if sel.mode == UBSelection.Mode.EDGE and not sel.edges.is_empty():
		id = "bevel"
	elif sel.mode == UBSelection.Mode.FACE and not sel.faces.is_empty():
		id = "inset"
	if id.is_empty():
		return false
	plugin._begin_adjust(id)
	_modal_adjust = true
	_modal_has_anchor = false
	return true


func end_modal_adjust() -> void:
	_modal_adjust = false
	_modal_has_anchor = false


## True while the Ctrl+B modal session owns the mouse. The plugin's global
## _input checks this before deciding whether the wheel belongs to us or to
## the viewport's zoom.
func modal_adjust_active() -> bool:
	return _modal_adjust and not plugin.adjust.is_empty()


## Wheel step on the modal session's segment count (bevel rounding or inset
## rings). Shared by the _input claim and the forward path so both routes
## agree on what a notch does.
func step_modal_segments(delta: int) -> void:
	if plugin.adjust.is_empty():
		return
	var values: Dictionary = plugin.adjust.values
	if not values.has("segments"):
		return
	plugin._on_adjust_param_changed("segments", clampi(int(values.segments) + delta, 1, 8))


## Ends whatever gesture currently owns the mesh, a gizmo drag (element or
## object) or a Ctrl+B modal session, the way Esc does: the gesture is
## reverted. Returns false when there was nothing to end.
##
## Call this before an undo or redo: a live gesture holds its own
## before-snapshot and has recorded nothing yet, so history moving underneath
## it would leave that snapshot describing a mesh that is gone.
func cancel_gesture() -> bool:
	if _dragging:
		_cancel_drag()
		return true
	if _obj_dragging:
		_cancel_object_drag()
		return true
	if _modal_adjust:
		end_modal_adjust()
		plugin._cancel_adjust()
		return true
	if _pressed or marquee:
		cancel_press()
		return true
	return false


func _handle_modal_adjust(camera: Camera3D, event: InputEvent) -> int:
	if plugin.adjust.is_empty():
		end_modal_adjust()
		return -1
	if event is InputEventMouseMotion:
		if not _modal_has_anchor:
			_modal_anchor = event.position
			_modal_has_anchor = true
			return EditorPlugin.AFTER_GUI_INPUT_STOP

		var pivot: Vector3 = plugin.selection_pivot_world()
		var right := camera.global_transform.basis.x
		var px_per_unit := camera.unproject_position(pivot + right).distance_to(
			camera.unproject_position(pivot))
		var amount: float = event.position.distance_to(_modal_anchor) / maxf(px_per_unit, 1e-3)
		plugin._on_adjust_param_changed("amount", maxf(0.001, amount))
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				end_modal_adjust()
				plugin._commit_adjust()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:

				step_modal_segments(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
	return -1


func begin_insert_vert() -> void:
	insert_vert_active = true
	insert_edge = UBPicking.NO_EDGE


func end_insert_vert() -> void:
	insert_vert_active = false
	insert_edge = UBPicking.NO_EDGE


func _handle_insert_vert(camera: Camera3D, event: InputEvent) -> int:
	var node = plugin.edited
	if not is_instance_valid(node) or node.mesh_data == null:
		return -1
	if event is InputEventMouseMotion:
		_update_insert_point(camera, event.position)
		plugin.update_overlays()
		return -1
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_update_insert_point(camera, event.position)
		if insert_edge != UBPicking.NO_EDGE:
			plugin.commit_insert_vertex(insert_edge, insert_point)
			plugin.update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return -1


func _update_insert_point(camera: Camera3D, pos: Vector2) -> void:
	var node = plugin.edited
	insert_edge = UBPicking.pick_edge(node, camera, pos)
	if insert_edge == UBPicking.NO_EDGE:
		return
	var data: UBMeshData = node.mesh_data
	if insert_edge.x >= data.positions.size() or insert_edge.y >= data.positions.size():
		insert_edge = UBPicking.NO_EDGE
		return
	var xf: Transform3D = node.global_transform
	var a: Vector3 = xf * data.positions[insert_edge.x]
	var b: Vector3 = xf * data.positions[insert_edge.y]
	var o := camera.project_ray_origin(pos)
	var pts := Geometry3D.get_closest_points_between_segments(
		o, o + camera.project_ray_normal(pos) * 4096.0, a, b)
	var world: Vector3 = pts[1]
	var edge_len := a.distance_to(b)
	var step := 0.0
	if plugin.toolbar != null and plugin.toolbar.snap_enabled:
		step = maxf(plugin.toolbar.snap_step, 0.001)
	var t := insert_distance(a.distance_to(world), edge_len, step)
	if t < 0.0:
		insert_edge = UBPicking.NO_EDGE
		return
	world = a + (b - a).normalized() * t
	insert_point = xf.affine_inverse() * world


## Insert Vertex's interior margin with Snap off, as a fraction of the edge.
const INSERT_MARGIN := 0.01


## Insert Vertex's split distance from the edge's first endpoint: `t` snapped
## to `step` (0 = Snap off), then kept strictly INSIDE the edge, or -1 for an
## edge too short to split. On an edge shorter than the grid step (a unit cube
## at the default step of 1) snapping can only land on 0 or edge_len, and with
## Snap off the closest point to the cursor ray clamps onto an endpoint
## whenever the cursor is past one; either way a vertex spliced onto an
## existing endpoint is a zero-length edge and a duplicate position that break
## bevel and loop work downstream. The margin is a quarter step (capped at a
## quarter edge) with Snap on, so the snap stays honest where it fits, and
## INSERT_MARGIN of the edge with Snap off.
static func insert_distance(t: float, edge_len: float, step: float) -> float:
	if not (edge_len > 1e-6):
		return -1.0
	var margin := edge_len * INSERT_MARGIN
	if step > 0.0:
		t = snappedf(t, step)
		margin = minf(step, edge_len) * 0.25
	return clampf(t, margin, edge_len - margin)


func _object_mode_active() -> bool:
	if not is_instance_valid(plugin.edited):
		return false
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	return nodes.size() == 1 and nodes[0] == plugin.edited


func _forward_object_input(camera: Camera3D, event: InputEvent) -> int:
	var node = plugin.edited
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var g := active_gizmo()
			var handle: int = g.hit_test(camera, node.global_position, event.position)
			if handle != 0:
				_obj_dragging = true
				_drag_mode = plugin.toolbar.gizmo_mode if plugin.toolbar != null else 0
				_drag_gizmo = g
				_drag_moved = false
				_obj_start_local = node.transform
				_obj_start_global = node.global_transform
				g.begin_drag(camera, node.global_position, handle, event.position)
				if _drag_mode == 0 and node.mesh_data != null:

					_snap_setup(camera, event.position, node.global_position,
						node.mesh_data, {}, false)

				_abs_ref = node.global_position
				if node.mesh_data != null:
					_abs_ref = UBTransformMath.bounds_min(
						node.mesh_data.positions, {}, node.global_transform, _abs_ref)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		if _obj_dragging:
			_end_object_drag()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if event is InputEventMouseMotion:
		if _obj_dragging:
			_update_object_drag(camera, event)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		_update_gizmo_hover(camera, event.position, plugin.selection)
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _update_object_drag(camera: Camera3D, event: InputEventMouseMotion) -> void:
	_drag_moved = true
	var node = plugin.edited
	var snap_on: bool = plugin.toolbar != null and plugin.toolbar.snap_enabled
	if event.ctrl_pressed:
		snap_on = not snap_on
	var step: float = plugin.toolbar.snap_step if snap_on and plugin.toolbar != null else 0.0
	var g := _obj_start_global
	match _drag_mode:
		1:
			var snap_rad := deg_to_rad(ROTATE_SNAP_DEG) if snap_on else 0.0
			var angle: float = rotate_gizmo.update_drag(camera, event.position, snap_rad)
			node.global_transform = Transform3D(
				Basis(rotate_gizmo._axis, angle) * g.basis, g.origin)
		2:
			var factors: Vector3 = scale_gizmo.update_drag(camera, event.position, step)
			var o: Basis = scale_gizmo.basis
			node.global_transform = Transform3D(
				o * Basis.from_scale(factors) * o.inverse() * g.basis, g.origin)
		_:
			var world_offset: Vector3
			var vsnap_offset: Variant = _snap_world_offset(camera, event.position)
			if vsnap_offset != null:
				world_offset = vsnap_offset
			else:
				world_offset = _move_offset(camera, event.position, step)
			node.global_transform = Transform3D(g.basis, g.origin + world_offset)
	plugin.update_overlays()


func _end_object_drag() -> void:
	if not _drag_moved:
		_cancel_object_drag()
		return
	var node = plugin.edited
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	ur.create_action(["Move Object", "Rotate Object", "Scale Object"][_drag_mode])
	ur.add_do_property(node, "transform", node.transform)
	ur.add_undo_property(node, "transform", _obj_start_local)
	ur.commit_action(false)
	_finish_object_drag()


func _cancel_object_drag() -> void:
	if is_instance_valid(plugin.edited):
		plugin.edited.transform = _obj_start_local
	_finish_object_drag()
	plugin.update_overlays()


func _finish_object_drag() -> void:
	_obj_dragging = false
	_snap_targets = PackedVector3Array()
	snap_hit = null
	if _drag_gizmo != null:
		_drag_gizmo.end_drag()
	_drag_gizmo = null


func _snap_setup(
	camera: Camera3D, cursor: Vector2, pivot: Vector3,
	data, moved: Dictionary, include_self := true, exclude: Variant = null
) -> void:
	snap_hit = null
	var xf: Transform3D = plugin.edited.global_transform
	_snap_anchor = pivot
	var best_d := 1e18
	var anchor_set: Variant = moved.keys() if not moved.is_empty() else range(data.positions.size())
	for vi in anchor_set:
		var wp: Vector3 = xf * data.positions[vi]
		if camera.is_position_behind(wp):
			continue
		var d := camera.unproject_position(wp).distance_to(cursor)
		if d < best_d:
			best_d = d
			_snap_anchor = wp
	_collect_snap_targets(data.positions, moved if exclude == null else exclude, include_self)


func _collect_snap_targets(positions: PackedVector3Array, exclude: Dictionary,
		include_self: bool) -> void:
	var xf: Transform3D = plugin.edited.global_transform
	_snap_targets = (
		UBVertexSnap.collect_positions(positions, xf, exclude) if include_self
		else PackedVector3Array()
	)
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		UBVertexSnap.collect_scene_targets(root, plugin.edited, _snap_targets)


func _snap_world_offset(camera: Camera3D, cursor: Vector2) -> Variant:
	if not Input.is_key_pressed(KEY_V) or _snap_targets.is_empty():
		snap_hit = null
		return null
	var idx := UBVertexSnap.nearest_target(
		_snap_targets,
		func(wp: Vector3) -> Variant:
			return null if camera.is_position_behind(wp) else camera.unproject_position(wp),
		cursor, UBVertexSnap.SNAP_PX)
	if idx < 0:
		snap_hit = null
		return null
	snap_hit = _snap_targets[idx]
	return _snap_targets[idx] - _snap_anchor


func _move_offset(camera: Camera3D, pos: Vector2, step: float) -> Vector3:
	var absolute: bool = (
		step > 0.0 and plugin.toolbar != null and plugin.toolbar.snap_absolute)
	if not absolute:
		return move_gizmo.update_drag(camera, pos, step)
	return UBTransformMath.snap_offset_absolute(
		_abs_ref, move_gizmo.update_drag(camera, pos, 0.0), step, _grid_origin(),
		move_gizmo.drag_axis())


func _grid_origin() -> Vector3:
	var origin := Vector3.ZERO
	if plugin.toolbar != null:
		origin[plugin.toolbar.grid_axis] = plugin.grid_offset
	return origin


func _handle_key(event: InputEventKey, sel: UBSelection) -> int:
	if event.keycode == KEY_ESCAPE and _dragging:
		_cancel_drag()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event.keycode == KEY_ESCAPE and _obj_dragging:
		_cancel_object_drag()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event.keycode == KEY_ESCAPE and _modal_adjust:
		end_modal_adjust()
		plugin._cancel_adjust()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event.keycode == KEY_ESCAPE and insert_vert_active:
		end_insert_vert()
		plugin.update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	if _pressed and _press_cancel_key(event):
		cancel_press()
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	if _dragging or _obj_dragging:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if (
		event.keycode == KEY_B and event.ctrl_pressed
		and not event.shift_pressed and not event.alt_pressed and not event.meta_pressed
	):
		if _begin_modal_adjust(sel):
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	if (
		event.keycode == KEY_I and event.ctrl_pressed
		and not event.shift_pressed and not event.alt_pressed and not event.meta_pressed
		and sel.mode != UBSelection.Mode.OBJECT
	):
		plugin._on_invert()
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	if plugin.select_all_hotkey_matches(event) and sel.mode != UBSelection.Mode.OBJECT:
		plugin._on_select_all()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	match mode_digit(event):
		1, 2, 3, 4:

			sel.change_mode(mode_digit(event) - 1, _mesh_data())
			clear_preselect()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		5:

			if plugin.toolbar != null:
				clear_preselect()
				plugin.toolbar.press_paint()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		6:

			if plugin.toolbar != null:
				clear_preselect()
				plugin.toolbar.press_material()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	match event.keycode:
		KEY_ESCAPE:
			if sel.mode != UBSelection.Mode.OBJECT:
				sel.change_mode(UBSelection.Mode.OBJECT, _mesh_data())
				clear_preselect()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_DELETE:
			if sel.mode == UBSelection.Mode.FACE and not sel.faces.is_empty():
				plugin.run_action("delete")
				return EditorPlugin.AFTER_GUI_INPUT_STOP

		KEY_W:
			if event.shift_pressed and _wer_applies(sel):
				plugin.set_gizmo_mode(0)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_E:
			if event.shift_pressed and _wer_applies(sel):
				plugin.set_gizmo_mode(1)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_R:
			if event.shift_pressed and _wer_applies(sel):
				plugin.set_gizmo_mode(2)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_BRACKETLEFT:
			plugin.adjust_grid_step(0.5)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_BRACKETRIGHT:
			plugin.adjust_grid_step(2.0)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_COMMA:
			plugin.nudge_grid_offset(-1.0)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_PERIOD:
			plugin.nudge_grid_offset(1.0)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_0:
			plugin.reset_grid_offset()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _begin_drag(camera: Camera3D, pivot: Vector3, handle: int, event: InputEventMouseButton) -> void:
	var sel: UBSelection = plugin.selection
	var data: UBMeshData = plugin.edited.mesh_data
	clear_preselect()
	_dragging = true
	_drag_mode = plugin.toolbar.gizmo_mode if plugin.toolbar != null else 0
	_drag_gizmo = active_gizmo()

	_drag_extrude = (
		_drag_mode == 0 and event.shift_pressed
		and sel.mode == UBSelection.Mode.FACE and not sel.faces.is_empty())

	_drag_inset = (
		_drag_mode == 2 and event.shift_pressed
		and sel.mode == UBSelection.Mode.FACE and not sel.faces.is_empty())
	if not _drag_inset:

		plugin._commit_adjust()
	if _drag_extrude:
		_drag_before = data.duplicate_data()
		UBOpExtrudeFaces.apply(data, sel.faces, 0.0)
	if _drag_inset:
		_drag_inset_equal = event.alt_pressed
		_drag_inset_ref = _inset_ref_distance(data, sel.faces)

		if not plugin.action_options.has("inset"):
			plugin.action_options["inset"] = {}
		plugin.action_options["inset"]["equal"] = 1.0 if _drag_inset_equal else 0.0
		plugin.action_options["inset"]["amount"] = 0.001
		plugin._begin_adjust("inset")
	_moved = sel.gather_vertices(data)
	_drag_moved = false
	_start_positions = data.positions.duplicate()
	_drag_gizmo.begin_drag(camera, pivot, handle, event.position)

	var xf: Transform3D = plugin.edited.global_transform
	_local_pivot = xf.affine_inverse() * pivot

	_soft_weights = {}
	if (
		not _drag_extrude and not _drag_inset
		and plugin.toolbar != null and plugin.toolbar.prop_enabled
	):
		_soft_weights = UBSoftSelect.weights(
			_start_positions, _moved, plugin.toolbar.prop_radius, xf,
			plugin.toolbar.prop_falloff)
	if _drag_mode == 1:
		_world_axis = rotate_gizmo._axis
		_node_basis = xf.basis
	elif _drag_mode == 2:
		_local_basis = xf.basis.inverse() * scale_gizmo.basis
	elif _drag_mode == 0:
		_snap_setup(camera, event.position, pivot, data, _moved, true, _drag_touched())
		_abs_ref = UBTransformMath.bounds_min(_start_positions, _moved, xf, pivot)

	_drag_uv_frames = {}
	if not _drag_inset:
		_drag_uv_frames = UBOpUV.drag_uv_frames(data, _drag_touched(), _start_positions)


func _drag_touched() -> Dictionary:
	var out := _moved.duplicate()
	for vi in _soft_weights:
		out[vi] = true
	return out


func _update_drag(camera: Camera3D, event: InputEventMouseMotion) -> void:
	_drag_moved = true
	_last_drag_camera = camera
	_last_drag_pos = event.position
	_last_drag_ctrl = event.ctrl_pressed
	_last_drag_alt = event.alt_pressed
	_apply_drag(camera, event.position, event.ctrl_pressed, event.alt_pressed)


func _apply_drag(camera: Camera3D, pos: Vector2, ctrl: bool, alt: bool) -> void:
	var data: UBMeshData = plugin.edited.mesh_data
	var snap_on: bool = plugin.toolbar != null and plugin.toolbar.snap_enabled
	if ctrl:
		snap_on = not snap_on
	var step: float = plugin.toolbar.snap_step if snap_on and plugin.toolbar != null else 0.0
	match _drag_mode:
		1:
			var snap_rad := deg_to_rad(ROTATE_SNAP_DEG) if snap_on else 0.0
			var angle: float = rotate_gizmo.update_drag(camera, pos, snap_rad)
			data.positions = (
				UBTransformMath.rotate_weighted_basis(
					_start_positions, _soft_weights, _local_pivot, _world_axis, angle, _node_basis)
				if not _soft_weights.is_empty() else
				UBTransformMath.rotate_positions_basis(
					_start_positions, _moved, _local_pivot, _world_axis, angle, _node_basis))
		2:

			var factors: Vector3 = scale_gizmo.update_drag(
				camera, pos, 0.0 if _drag_inset else step)
			if _drag_inset:
				_update_inset_drag(factors, step, alt)
				plugin.update_overlays()
				return
			data.positions = (
				UBTransformMath.scale_weighted(
					_start_positions, _soft_weights, _local_pivot, _local_basis, factors)
				if not _soft_weights.is_empty() else
				UBTransformMath.scale_positions(
					_start_positions, _moved, _local_pivot, _local_basis, factors))
		_:

			var per_each: bool = (
				plugin.toolbar != null and plugin.toolbar.snap_each and step > 0.0)

			var world_offset: Vector3
			var vertex_snapped := false
			var vsnap_offset: Variant = _snap_world_offset(camera, pos)
			if vsnap_offset != null:
				world_offset = vsnap_offset
				vertex_snapped = true
			else:
				world_offset = _move_offset(camera, pos, 0.0 if per_each else step)
			var local_offset: Vector3 = plugin.edited.global_transform.basis.inverse() * world_offset
			var positions: PackedVector3Array
			if _soft_weights.is_empty():
				positions = _start_positions.duplicate()
				for vi in _moved:
					positions[vi] += local_offset
			else:
				positions = UBTransformMath.translate_weighted(
					_start_positions, _soft_weights, local_offset)
			if per_each and not vertex_snapped:

				var xf: Transform3D = plugin.edited.global_transform
				var inv := xf.affine_inverse()
				var origin := _grid_origin()
				for vi in _moved:
					positions[vi] = inv * UBTransformMath.snap_point(xf * positions[vi], step, origin)
			data.positions = positions
	if not _drag_uv_frames.is_empty():
		UBOpUV.refit_drag_uvs(data, _drag_uv_frames)
	data.notify_changed()
	plugin.update_overlays()


## True while a transform drag with proportional weights is live. Gates the
## plugin's global wheel claim, so the radius adjust does not also zoom.
func prop_drag_active() -> bool:
	return _dragging and not _soft_weights.is_empty()


## Mouse-wheel radius adjust mid-drag: scales the toolbar radius, recomputes
## the weights against the drag's start positions and replays the latest
## motion, so the mesh follows the new radius before the cursor moves again.
func adjust_prop_radius(factor: float) -> void:
	if plugin.toolbar == null:
		return
	plugin.toolbar.set_prop_radius(plugin.toolbar.prop_radius * factor)
	if not prop_drag_active() or not is_instance_valid(plugin.edited):
		return
	_soft_weights = UBSoftSelect.weights(
		_start_positions, _moved, plugin.toolbar.prop_radius,
		plugin.edited.global_transform, plugin.toolbar.prop_falloff)

	var fresh := UBOpUV.drag_uv_frames(plugin.edited.mesh_data, _drag_touched(), _start_positions)
	for fi in fresh:
		if not _drag_uv_frames.has(fi):
			_drag_uv_frames[fi] = fresh[fi]

	UBOpUV.link_drag_patches(plugin.edited.mesh_data, _drag_uv_frames)

	if _drag_mode == 0 and not _drag_extrude:
		_collect_snap_targets(_start_positions, _drag_touched(), true)
	if _last_drag_camera != null:
		_apply_drag(_last_drag_camera, _last_drag_pos, _last_drag_ctrl, _last_drag_alt)


func _update_inset_drag(factors: Vector3, step: float, alt: bool) -> void:
	if alt != _drag_inset_equal:

		_drag_inset_equal = alt
		plugin._on_adjust_param_changed("equal", 1.0 if alt else 0.0)
	var f: float = factors.x
	if absf(factors.y - 1.0) > absf(f - 1.0):
		f = factors.y
	if absf(factors.z - 1.0) > absf(f - 1.0):
		f = factors.z

	var deviation: float = (
		absf(1.0 - f) if scale_gizmo.active == UBScaleGizmo.Handle.UNIFORM
		else 1.0 - f)
	var amount := deviation * _drag_inset_ref
	if step > 0.0:
		amount = snappedf(amount, step)
	amount = maxf(0.001, amount)
	scale_gizmo.readout_override = (
		"Inset %.3f (equal)" if _drag_inset_equal else "Inset %.3f") % amount
	plugin._on_adjust_param_changed("amount", amount)


func _inset_ref_distance(data: UBMeshData, faces: Dictionary) -> float:
	var total := 0.0
	var count := 0
	for fi in faces:
		if fi < 0 or fi >= data.faces.size():
			continue
		var face: UBFace = data.faces[fi]
		var center: Vector3 = data.face_center(face)
		for vi in face.vertices:
			total += data.positions[vi].distance_to(center)
			count += 1
	return total / count if count > 0 else 1.0


func _end_drag() -> void:
	if _drag_inset:

		_finish_drag()
		return

	if not _drag_moved:
		_cancel_drag()
		return
	var data: UBMeshData = plugin.edited.mesh_data
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	if _drag_extrude:
		ur.create_action("Extrude Faces")
		ur.add_do_method(data, "copy_from", data.duplicate_data())
		ur.add_undo_method(data, "copy_from", _drag_before)
	else:
		ur.create_action(["Move Elements", "Rotate Elements", "Scale Elements"][_drag_mode])
		ur.add_do_property(data, "positions", data.positions.duplicate())
		ur.add_undo_property(data, "positions", _start_positions)
		if not _drag_uv_frames.is_empty():

			ur.add_do_method(data, "apply_uv_coords", UBOpUV.drag_uv_coords(data, _drag_uv_frames, false))
			ur.add_undo_method(data, "apply_uv_coords", UBOpUV.drag_uv_coords(data, _drag_uv_frames, true))
			var axes_after := UBOpUV.drag_uv_axes(data, _drag_uv_frames, false)
			if not axes_after.is_empty():
				ur.add_do_method(data, "apply_uv_axes", axes_after)
				ur.add_undo_method(data, "apply_uv_axes", UBOpUV.drag_uv_axes(data, _drag_uv_frames, true))
		ur.add_do_method(data, "notify_changed")
		ur.add_undo_method(data, "notify_changed")
	ur.commit_action(false)
	_finish_drag()
	plugin._refresh_vertex_panel()


func _cancel_drag() -> void:
	if _drag_inset:
		plugin._cancel_adjust()
		_finish_drag()
		plugin.update_overlays()
		return
	if not is_instance_valid(plugin.edited) or plugin.edited.mesh_data == null:
		_finish_drag()
		plugin.update_overlays()
		return
	var data: UBMeshData = plugin.edited.mesh_data
	if _drag_extrude:
		data.copy_from(_drag_before)
	else:
		data.positions = _start_positions
		if not _drag_uv_frames.is_empty():
			data.apply_uv_coords(UBOpUV.drag_uv_coords(data, _drag_uv_frames, true))
			data.apply_uv_axes(UBOpUV.drag_uv_axes(data, _drag_uv_frames, true))
		data.notify_changed()
	_finish_drag()
	plugin.update_overlays()


func _finish_drag() -> void:
	_dragging = false
	_drag_extrude = false
	_drag_inset = false
	_drag_before = null
	_moved = {}
	_soft_weights = {}
	_drag_uv_frames = {}
	_last_drag_camera = null
	_snap_targets = PackedVector3Array()
	snap_hit = null
	if _drag_gizmo != null:
		_drag_gizmo.end_drag()
	_drag_gizmo = null


func _handle_click(camera: Camera3D, event: InputEventMouseButton) -> void:
	var sel: UBSelection = plugin.selection
	var node = plugin.edited
	var additive: bool = event.shift_pressed
	match sel.mode:
		UBSelection.Mode.VERTEX:
			var v := UBPicking.pick_vertex(node, camera, event.position)
			if v >= 0:
				sel.click_key(v, additive)
			elif not additive:
				sel.clear_elements()
		UBSelection.Mode.EDGE:
			var e := UBPicking.pick_edge(node, camera, event.position)
			if e != UBPicking.NO_EDGE:
				sel.click_key(e, additive)
			elif not additive:
				sel.clear_elements()
		UBSelection.Mode.FACE:
			var f := UBPicking.pick_face(node, camera, event.position)
			if f >= 0:
				sel.click_key(f, additive)
			elif not additive:
				sel.clear_elements()


func _handle_double_click(camera: Camera3D, event: InputEventMouseButton) -> void:
	var sel: UBSelection = plugin.selection
	var node = plugin.edited
	var data: UBMeshData = node.mesh_data
	var additive: bool = event.shift_pressed
	match sel.mode:
		UBSelection.Mode.EDGE:
			var e := UBPicking.pick_edge(node, camera, event.position)
			if e == UBPicking.NO_EDGE:
				return
			var topo := UBTopology.build(data)
			var keys: Array[Vector2i]
			if event.alt_pressed:
				keys = UBSelectQueries.edge_ring(data, topo, e)
			else:
				keys = UBSelectQueries.edge_loop(topo, e)
			sel.select_keys(keys, additive)
		UBSelection.Mode.FACE:
			var f := UBPicking.pick_face(node, camera, event.position)
			if f < 0:
				return
			var direction := UBPicking.nearest_face_edge(node, camera, f, event.position)
			if direction == UBPicking.NO_EDGE:
				return
			var topo := UBTopology.build(data)
			var loop := UBSelectQueries.face_loop(data, topo, f, direction)
			sel.select_keys(loop.keys(), additive)


func _apply_marquee(camera: Camera3D, event: InputEventMouseButton) -> void:
	var sel: UBSelection = plugin.selection
	var node = plugin.edited
	var additive: bool = event.shift_pressed
	var through: bool = plugin.toolbar != null and plugin.toolbar.xray
	match sel.mode:
		UBSelection.Mode.VERTEX:
			sel.select_keys(UBPicking.marquee_vertices(node, camera, marquee_rect, through), additive)
		UBSelection.Mode.EDGE:
			sel.select_keys(UBPicking.marquee_edges(node, camera, marquee_rect, through), additive)
		UBSelection.Mode.FACE:
			sel.select_keys(UBPicking.marquee_faces(node, camera, marquee_rect, through), additive)
