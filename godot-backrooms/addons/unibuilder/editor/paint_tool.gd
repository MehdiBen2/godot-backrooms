@tool
class_name UBPaintTool
extends RefCounted
## Vertex-paint mode: press-drag paints with the panel's Brush or Fill. Brush blends
## vertices inside a world-radius falloff circle toward the paint color, applying the
## stroke's peak weight per vertex so hovering never compounds; Fill floods whole
## faces. One stroke is one undo entry. Esc cancels a live stroke, then exits; 5
## toggles out; 1-4 leave into that selection mode; Shift+click eyedrops.

var plugin: EditorPlugin
var _active := false
var _stroke := false
var _before: UBMeshData
var _painted := {}
var _stroke_weights := {}
var _hover_world := Vector3.ZERO
var _hover_hit := false
var _hover_face := -1


var _reticle := RID()
var _reticle_scenario := RID()
var _reticle_mesh: SphereMesh


func active() -> bool:
	return _active


func begin() -> void:
	if plugin.edited == null or plugin.edited.mesh_data == null:
		return

	_active = true


func _exit() -> void:
	if _stroke and _before != null and is_instance_valid(plugin.edited) \
			and plugin.edited.mesh_data != null:
		plugin.edited.mesh_data.copy_from(_before)
	_stroke = false
	_before = null
	_painted = {}
	_stroke_weights = {}
	_active = false
	_free_reticle()
	plugin.paint_ended()


func cancel() -> void:
	cancel_stroke()
	_active = false
	_stroke = false
	_before = null
	_painted = {}
	_stroke_weights = {}
	_free_reticle()


## Reverts a live stroke and keeps the tool active. Returns whether a stroke was
## live, so the global undo chord can end the gesture instead of undoing beneath it.
func cancel_stroke() -> bool:
	if not _stroke:
		return false
	if _before != null and is_instance_valid(plugin.edited) \
			and plugin.edited.mesh_data != null:
		plugin.edited.mesh_data.copy_from(_before)
	_stroke = false
	_before = null
	_painted = {}
	_stroke_weights = {}
	return true


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventKey:

		var verdict: int = plugin.handle_tool_mode_key(event, 5, cancel_stroke, _exit)
		return verdict if verdict >= 0 else EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if plugin.edited == null or plugin.edited.mesh_data == null:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			if event.shift_pressed:
				_eyedrop(camera, event.position)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			_stroke = true
			_painted = {}
			_stroke_weights = {}
			_before = plugin.edited.mesh_data.duplicate_data()
			_update_hover(camera, event.position)
			_paint_at(camera, event.position)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if _stroke:
			_stroke = false
			if _painted.is_empty() and _stroke_weights.is_empty():

				_before = null
			else:
				plugin._commit_snapshot_op("Paint Vertex Colors", _before)
				_before = null
			_stroke_weights = {}
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion:
		_update_hover(camera, event.position)
		if _stroke:
			_paint_at(camera, event.position)
			plugin.update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		plugin.update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _update_hover(camera: Camera3D, pos: Vector2) -> void:
	_hover_hit = false
	_hover_face = -1
	var node = plugin.edited
	if node == null or not is_instance_valid(node) or node.mesh_data == null:
		_update_reticle(node)
		return
	var pick := UBPicking.pick_face_point(node, camera, pos)
	if pick[0] >= 0:
		_hover_face = pick[0]
		_hover_world = node.global_transform * pick[1]
		_hover_hit = true
	_update_reticle(node)


func _paint_at(_camera: Camera3D, _pos: Vector2) -> void:
	var node = plugin.edited
	var data: UBMeshData = node.mesh_data
	var color: Color = plugin.paint_panel.paint_color()
	var mask: int = plugin.paint_panel.paint_mask()
	if not plugin.paint_panel.fill_mode():
		if not _hover_hit:
			return
		var dab := UBOpPaint.brush_weights(
			data, node.global_transform, _hover_world,
			plugin.paint_panel.brush_radius(),
			plugin.paint_panel.brush_strength(),
			plugin.paint_panel.brush_softness())

		var changed := false
		for v in dab:
			var w: float = dab[v]
			if w > float(_stroke_weights.get(v, 0.0)) + 1e-4:
				_stroke_weights[v] = w
				changed = true
		if not changed:
			return
		UBOpPaint.paint_weighted(data, _before, _stroke_weights, color, mask)
		data.notify_colors_changed()
	else:
		var f := _hover_face

		if f >= 0 and not _painted.has(-f - 1):
			_painted[-f - 1] = true
			UBOpPaint.paint_faces(data, {f: true}, color, mask)
			data.notify_colors_changed()


## Fill-mode hover: tints the face a click would flood in the 2D overlay, in the
## same teal as the hover preselect.
func draw_overlay(overlay: Control, camera: Camera3D) -> void:
	if camera == null or not plugin.paint_panel.fill_mode():
		return
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

	var tint := Color(0.984, 0.749, 0.141)

	if not Geometry2D.triangulate_polygon(pts).is_empty():
		overlay.draw_colored_polygon(pts, Color(tint, 0.22))
	for i in pts.size():
		overlay.draw_line(pts[i], pts[(i + 1) % pts.size()], Color(tint, 0.9), 2.5, true)


## Brush/Fill switched on the panel: retires the sphere reticle at once, since no
## viewport motion event arrives while the cursor is on the panel.
func apply_mode_changed() -> void:
	_update_reticle(plugin.edited)


## The pointer left every 3D viewport: drops the hover so neither the reticle nor
## the fill highlight lingers. Safe mid-stroke; the next in-viewport motion re-picks.
func pointer_left() -> void:
	if not _hover_hit and _hover_face < 0:
		return
	_hover_hit = false
	_hover_face = -1
	_update_reticle(plugin.edited)
	plugin.update_overlays()


func _eyedrop(camera: Camera3D, pos: Vector2) -> void:
	var node = plugin.edited
	var f := UBPicking.pick_face(node, camera, pos)
	if f < 0:
		return
	var data: UBMeshData = node.mesh_data
	var projected := PackedVector2Array()
	for vi in data.faces[f].vertices:
		var world: Vector3 = node.global_transform * data.positions[vi]

		projected.append(
			Vector2(INF, INF) if camera.is_position_behind(world)
			else camera.unproject_position(world)
		)
	var ci := UBOpPaint.nearest_corner(projected, pos)
	if ci >= 0:
		plugin.paint_panel.set_paint_color(UBOpPaint.sample(data, f, ci))


func _update_reticle(node) -> void:
	var show: bool = (
		_hover_hit and not plugin.paint_panel.fill_mode()
		and is_instance_valid(node) and node.is_inside_tree()
	)
	if not show:
		if _reticle.is_valid():
			RenderingServer.instance_set_visible(_reticle, false)
		return
	var world: World3D = node.get_world_3d()
	if world == null:
		return
	if not _reticle.is_valid() or _reticle_scenario != world.scenario:
		_free_reticle()
		if _reticle_mesh == null:
			_reticle_mesh = SphereMesh.new()
			_reticle_mesh.radial_segments = 24
			_reticle_mesh.rings = 12
			_reticle_mesh.radius = 1.0
			_reticle_mesh.height = 2.0
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(0.369, 0.918, 0.831, 0.18)
			_reticle_mesh.material = mat
		_reticle_scenario = world.scenario
		_reticle = RenderingServer.instance_create2(_reticle_mesh.get_rid(), _reticle_scenario)
		RenderingServer.instance_geometry_set_cast_shadows_setting(
			_reticle, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	var r: float = maxf(plugin.paint_panel.brush_radius(), 0.001)
	RenderingServer.instance_set_transform(
		_reticle, Transform3D(Basis.from_scale(Vector3.ONE * r), _hover_world))
	RenderingServer.instance_set_visible(_reticle, true)


func _free_reticle() -> void:
	if _reticle.is_valid():
		RenderingServer.free_rid(_reticle)
	_reticle = RID()
	_reticle_scenario = RID()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _reticle.is_valid():
		RenderingServer.free_rid(_reticle)
		_reticle = RID()
