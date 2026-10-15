@tool
extends EditorPlugin
## Unibuilder entry point: owns the selection state and edited node, and wires
## the gizmo plugin, overlay toolbar, and viewport input together.

var selection: UBSelection
var edited: UBMeshInstance3D
var toolbar: UBOverlayToolbar


var _toolbar_row: PanelContainer
var gizmo_plugin: UBGizmoPlugin
var input: UBViewportInput
var grid: UBGrid
var shape_tool: UBShapeTool
var cut_tool: UBCutTool
var face_panel: UBFacePanel
var material_palette: UBMaterialPalette
var vertex_panel: UBVertexPanel
var paint_tool: UBPaintTool
var paint_panel: UBPaintPanel
var material_tool: UBMaterialTool
var uv_editor: UBUVEditor


var _side_scroll: ScrollContainer
var _side_dock: VBoxContainer

var _drop_targets: Array = []


var _drag_material: Material = null
var _drag_overrides: Array = []
var _drop_consumed := false
## Per-action option overrides (action id -> {key: value}); persisted. Unset
## keys fall back to snap-derived defaults (see UBActions).
var action_options := {}
## Click-through Control over the active viewport that the shape tool draws on.
var shape_overlay: Control
var _overlay_camera: Camera3D
## Grid plane offset along its normal axis, in world units (nudged with ,/.).
var grid_offset := 0.0


var _lock_target: UBMeshInstance3D


var _float_surface: Control = null
var _float_viewport: SubViewport = null


var _lock_desired: UBMeshInstance3D


var _bound_data: UBMeshData
var _export_dialog: EditorFileDialog

var _export_target: UBMeshInstance3D
var _blend_layer_dialog: EditorFileDialog
var toast: UBToast


var _demo_dialog: AcceptDialog
var _demo_timer: Timer

var _blend_layer_target := 0
## Overlay color/size overrides (see UBGizmoPlugin.DEFAULTS); persisted with
## the grid state, unset keys fall back to defaults.
var prefs := {}
var _prefs_panel: UBPreferencesPanel

const ADJUSTABLE := {"weld": "Weld Vertices", "extrude_edges": "Extrude Edges",
	"bevel": "Bevel Edges", "subdiv_edges": "Subdivide Edges",
	"insert_loop": "Insert Edge Loops",
	"extrude": "Extrude Faces", "inset": "Inset Faces",
	"subdiv_faces": "Subdivide Faces"}

## Live adjust session for the last parameterised op (empty = none): the
## before-snapshots plus the current values. Every tweak restores and re-applies.
var adjust := {}
var adjust_panel: UBAdjustPanel


var _adjust_reapplying := false


var _shape_check_at := -1.0
## Seconds the mesh must sit unchanged before the shape check runs, so a drag
## pays for one rebuild on release instead of one per frame.
const SHAPE_CHECK_DELAY := 0.4


func _enter_tree() -> void:
	selection = UBSelection.new()
	selection.changed.connect(_on_selection_changed)

	gizmo_plugin = UBGizmoPlugin.new()
	gizmo_plugin.plugin = self
	add_node_3d_gizmo_plugin(gizmo_plugin)

	toolbar = UBOverlayToolbar.create()
	toolbar.mode_requested.connect(_on_mode_requested)
	toolbar.gizmo_mode_requested.connect(set_gizmo_mode)
	toolbar.gizmo_changed.connect(_on_gizmo_changed)
	toolbar.grow_requested.connect(_on_grow)
	toolbar.shrink_requested.connect(_on_shrink)
	toolbar.select_all_requested.connect(_on_select_all)
	toolbar.invert_requested.connect(_on_invert)
	toolbar.paint_toggled.connect(_on_paint_toggled)
	toolbar.material_toggled.connect(_on_material_toggled)
	toolbar.action_requested.connect(run_action)
	toolbar.grid_changed.connect(_on_grid_changed)
	toolbar.grid_align_requested.connect(_on_grid_align)
	toolbar.grid_reset_requested.connect(reset_grid_offset)
	toolbar.shape_requested.connect(_on_shape_requested)
	toolbar.shape_edit_requested.connect(_on_shape_edit_requested)
	toolbar.tool_requested.connect(_on_tool_requested)
	_mount_toolbar()

	input = UBViewportInput.new()
	input.plugin = self

	shape_tool = UBShapeTool.new()
	shape_tool.plugin = self

	cut_tool = UBCutTool.new()
	cut_tool.plugin = self

	_mount_side_dock()

	face_panel = UBFacePanel.create()
	face_panel.visible = false
	face_panel.props_requested.connect(_on_face_props_requested)
	face_panel.slot_material_changed.connect(_on_slot_material_changed)
	_dock_panel(face_panel)

	material_palette = UBMaterialPalette.create()
	material_palette.visible = false
	material_palette.apply_requested.connect(_on_palette_apply)
	material_palette.changed.connect(_save_grid_settings)
	_dock_panel(material_palette)

	adjust_panel = UBAdjustPanel.create()
	adjust_panel.visible = false
	adjust_panel.param_changed.connect(_on_adjust_param_changed)
	adjust_panel.apply_requested.connect(_on_adjust_apply)
	adjust_panel.cancel_requested.connect(_on_adjust_cancel)
	adjust_panel.preset_selected.connect(_on_preset_selected)
	adjust_panel.preset_save_requested.connect(_on_preset_save)
	adjust_panel.preset_delete_requested.connect(_on_preset_delete)

	vertex_panel = UBVertexPanel.create()
	vertex_panel.visible = false
	vertex_panel.position_committed.connect(_on_vertex_position_committed)

	toast = UBToast.create()

	paint_tool = UBPaintTool.new()
	paint_tool.plugin = self
	material_tool = UBMaterialTool.new()
	material_tool.plugin = self
	paint_panel = UBPaintPanel.create()
	paint_panel.visible = false

	paint_panel.palette_changed.connect(_queue_save_settings)
	paint_panel.fill_changed.connect(_on_paint_fill_changed)
	paint_panel.blend_material_requested.connect(_on_blend_material_requested)
	paint_panel.invert_alpha_requested.connect(_on_invert_alpha_requested)
	_dock_panel(paint_panel)

	uv_editor = UBUVEditor.create()
	uv_editor.plugin = self
	add_control_to_bottom_panel(uv_editor, "UV Editor")

	grid = UBGrid.new()
	_load_grid_settings()
	_apply_prefs()
	scene_changed.connect(_on_scene_changed)

	EditorInterface.get_selection().selection_changed.connect(_sync_native_gizmo_lock)
	_update_grid()

	_refresh_existing_gizmos.call_deferred()

	if UBEdition.DEMO:
		_start_demo_nags()


const SIDE_DOCK_SCENE := "res://addons/unibuilder/editor/side_dock.tscn"


func _mount_side_dock() -> void:

	_side_scroll = (load(SIDE_DOCK_SCENE) as PackedScene).instantiate() as ScrollContainer
	_side_dock = _side_scroll.get_node("Dock") as VBoxContainer
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_SIDE_RIGHT, _side_scroll)


func _dock_panel(panel: Control) -> void:
	if _side_dock == null:
		add_control_to_container(CONTAINER_SPATIAL_EDITOR_SIDE_RIGHT, panel)
		return
	_side_dock.add_child(panel)
	panel.visibility_changed.connect(_update_side_dock)
	_update_side_dock()


func _update_side_dock() -> void:
	if _side_scroll == null or not is_instance_valid(_side_scroll):
		return
	var any := false
	for child in _side_dock.get_children():
		if child is Control and (child as Control).visible:
			any = true
			break
	_side_scroll.visible = any


func _mount_toolbar() -> void:
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)
	var menu_hbox := toolbar.get_parent()
	var found := UBToolbarMount.find_row_anchor(menu_hbox)
	if found.is_empty():
		return
	var vbox: VBoxContainer = found.vbox
	var anchor: Node = found.anchor
	var row := PanelContainer.new()

	var style_src := menu_hbox.get_parent()
	if style_src is PanelContainer:
		row.add_theme_stylebox_override("panel", (style_src as Control).get_theme_stylebox("panel"))
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)
	row.add_child(toolbar)
	vbox.add_child(row)
	vbox.move_child(row, anchor.get_index() + 1)
	_toolbar_row = row


func _refresh_existing_gizmos() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is UBMeshInstance3D:
			n.clear_gizmos()
			n.update_gizmos()
		stack.append_array(n.get_children())


func _exit_tree() -> void:
	_commit_adjust()

	UBMeshInstance3D.live_uv2_texel = 0.0
	UBMeshInstance3D.uv2_hook = Callable()
	var esel := EditorInterface.get_selection()
	if esel.selection_changed.is_connected(_sync_native_gizmo_lock):
		esel.selection_changed.disconnect(_sync_native_gizmo_lock)
	if is_instance_valid(_lock_target):
		_lock_target.set_plugin_lock(false)

		esel.selection_changed.emit()
	_lock_target = null
	_lock_desired = null

	_save_grid_settings()
	if grid != null:
		grid.cleanup()
	if shape_tool != null:
		shape_tool.cancel()
	if cut_tool != null:
		cut_tool.cancel()
	_detach_shape_overlay()
	if _toolbar_row != null:
		_toolbar_row.queue_free()
		_toolbar_row = null
	elif toolbar != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)
		toolbar.queue_free()
	if gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(gizmo_plugin)

	if _side_scroll != null and is_instance_valid(_side_scroll):
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_SIDE_RIGHT, _side_scroll)
		_side_scroll.queue_free()
	_side_scroll = null
	_side_dock = null
	if adjust_panel != null:
		adjust_panel.queue_free()
	if vertex_panel != null:
		vertex_panel.queue_free()
	if toast != null and is_instance_valid(toast):
		toast.queue_free()
	if paint_tool != null:
		paint_tool.cancel()
	if material_tool != null:
		material_tool.cancel()
	if uv_editor != null:
		remove_control_from_bottom_panel(uv_editor)
		uv_editor.queue_free()
	if _export_dialog != null and is_instance_valid(_export_dialog):
		_export_dialog.queue_free()
	if _demo_dialog != null and is_instance_valid(_demo_dialog):
		_demo_dialog.queue_free()
	if _blend_layer_dialog != null and is_instance_valid(_blend_layer_dialog):
		_blend_layer_dialog.queue_free()
	if _prefs_panel != null and is_instance_valid(_prefs_panel):
		_prefs_panel.queue_free()
	_remove_material_drop_targets()

	UBTopology.clear_cache()
	UBRayAccel.clear_cache()


func _ensure_session_state() -> void:
	if selection == null:
		selection = UBSelection.new()
		selection.changed.connect(_on_selection_changed)
	if input == null:
		input = UBViewportInput.new()
		input.plugin = self
	if shape_tool == null:
		shape_tool = UBShapeTool.new()
		shape_tool.plugin = self
	if cut_tool == null:
		cut_tool = UBCutTool.new()
		cut_tool.plugin = self
	if grid == null:

		grid = UBGrid.new()
	if not (action_options is Dictionary):
		action_options = {}
	if not (adjust is Dictionary):
		adjust = {}
	if not (prefs is Dictionary):
		prefs = {}


func _handles(object: Object) -> bool:
	return object is UBMeshInstance3D


func _edit(object: Object) -> void:
	_ensure_session_state()

	var keep_session: bool = (
		not adjust.is_empty() and adjust.has("node") and adjust.get("node") == object)
	if not keep_session:
		_commit_adjust()

	if object == null and _still_multi_selected():
		return
	var prev := edited
	var next_edited := object as UBMeshInstance3D

	if prev != next_edited:
		_cancel_interactions()
	edited = next_edited
	if prev == edited:
		return
	_bind_mesh_data()
	_schedule_shape_check()
	selection.clear_elements(false)
	if is_instance_valid(prev):
		prev.update_gizmos()
	if edited != null:
		edited.update_gizmos()

	if keep_session:
		_adjust_reapplying = true
	selection.notify()
	if keep_session:
		_adjust_reapplying = false


func _bind_mesh_data() -> void:
	var want: UBMeshData = edited.mesh_data if is_instance_valid(edited) else null
	if want == _bound_data:
		return
	if _bound_data != null and _bound_data.changed.is_connected(_on_data_changed):
		_bound_data.changed.disconnect(_on_data_changed)
	_bound_data = want
	if _bound_data != null and not _bound_data.changed.is_connected(_on_data_changed):
		_bound_data.changed.connect(_on_data_changed)


func _stand_down_tools(keep := "") -> void:
	_commit_adjust()
	if keep != "cut" and cut_tool != null and cut_tool.active():
		cut_tool.cancel()
	if keep != "paint" and paint_tool != null and paint_tool.active():
		paint_tool.cancel()
		if toolbar != null:
			toolbar.sync_paint(false)
		if paint_panel != null:
			paint_panel.visible = false
	if keep != "material" and material_tool != null and material_tool.active():
		material_tool.cancel()
		if toolbar != null:
			toolbar.sync_material(false)
	if keep != "shape" and shape_tool != null and shape_tool.active():
		shape_tool.cancel()
		refresh_shape_overlay()
	if keep != "insert_vert" and input != null:
		input.end_insert_vert()
	update_overlays()


func _cancel_interactions() -> void:
	if input != null:
		if input._dragging:
			input._cancel_drag()
		if input._obj_dragging:
			input._cancel_object_drag()
		if input._modal_adjust:
			input.end_modal_adjust()
		input.end_insert_vert()
		input.clear_preselect()

		input.cancel_press()
	if cut_tool != null and cut_tool.active():
		cut_tool.cancel()
	if paint_tool != null and paint_tool.active():
		paint_tool.cancel()
		if toolbar != null:
			toolbar.sync_paint(false)
		if paint_panel != null:
			paint_panel.visible = false
	if material_tool != null and material_tool.active():
		material_tool.cancel()
		if toolbar != null:
			toolbar.sync_material(false)


func _on_data_changed() -> void:
	if selection != null and is_instance_valid(edited) and edited.mesh_data != null:
		selection.prune_invalid(edited.mesh_data)
	_refresh_face_panel()
	_refresh_vertex_panel()

	_shape_check_at = _now() + SHAPE_CHECK_DELAY
	if uv_editor != null:
		uv_editor.refresh()
	update_overlays()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _make_visible(visible: bool) -> void:
	if not visible:
		_edit(null)
	_update_grid()


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if edited == null or edited.mesh_data == null:
		return AFTER_GUI_INPUT_PASS
	_ensure_session_state()

	var tool_live: bool = (
		cut_tool.active()
		or (paint_tool != null and paint_tool.active())
		or (material_tool != null and material_tool.active()))
	if (
		not tool_live and not adjust.is_empty() and event is InputEventKey
		and event.pressed and event.keycode == KEY_ESCAPE
	):

		if input.cancel_gesture():
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		_cancel_adjust()
		return AFTER_GUI_INPUT_STOP

	if event is InputEventMouseButton and event.pressed and _over_floating_panel():
		_panel_press = true
		return AFTER_GUI_INPUT_STOP
	if event is InputEventMouseButton and not event.pressed and _panel_press:
		_panel_press = false
		return AFTER_GUI_INPUT_STOP
	if cut_tool.active():
		return cut_tool.handle_input(viewport_camera, event)
	if paint_tool != null and paint_tool.active():
		return paint_tool.handle_input(viewport_camera, event)
	if material_tool != null and material_tool.active():
		return material_tool.handle_input(viewport_camera, event)
	return input.forward_input(viewport_camera, event)


var _panel_press := false


func _over_floating_panel() -> bool:
	var gp := EditorInterface.get_base_control().get_global_mouse_position()
	for panel in [adjust_panel, vertex_panel]:
		if panel != null and is_instance_valid(panel) and panel.is_visible_in_tree() \
				and panel.get_global_rect().has_point(gp):
			return true
	return false


func _forward_3d_draw_over_viewport(viewport_control: Control) -> void:
	_ensure_drop_target(viewport_control)
	_ensure_floating_panels(viewport_control)
	if input == null:
		return
	if input.marquee:
		viewport_control.draw_rect(input.marquee_rect, Color(0.5, 0.7, 1.0, 0.12), true)
		viewport_control.draw_rect(input.marquee_rect, Color(0.5, 0.7, 1.0, 0.8), false, 1.0)
	if shape_tool != null and shape_tool.active():

		return
	if cut_tool != null and cut_tool.active():
		cut_tool.draw_overlay(viewport_control, input.last_camera)
		return
	if paint_tool != null and paint_tool.active():

		paint_tool.draw_overlay(viewport_control, input.last_camera)
		return
	if material_tool != null and material_tool.active():

		material_tool.draw_overlay(viewport_control, input.last_camera)
		return
	if (
		is_instance_valid(edited) and edited.mesh_data != null and edited.is_inside_tree()
		and (
			(selection.mode != UBSelection.Mode.OBJECT and selection.count() > 0)
			or (selection.mode == UBSelection.Mode.OBJECT and input._object_mode_active())
		)
	):
		input.draw_gizmo(viewport_control, selection_pivot_world())

	if input.snap_hit != null and input.last_camera != null:
		var hit_wp: Vector3 = input.snap_hit
		if not input.last_camera.is_position_behind(hit_wp):
			var hp := input.last_camera.unproject_position(hit_wp)
			var amber := Color(0.984, 0.749, 0.141)
			viewport_control.draw_arc(hp, 8.0, 0.0, TAU, 24, amber, 2.5, true)
			viewport_control.draw_line(hp - Vector2(13, 0), hp + Vector2(13, 0), Color(amber, 0.8), 1.5, true)
			viewport_control.draw_line(hp - Vector2(0, 13), hp + Vector2(0, 13), Color(amber, 0.8), 1.5, true)
	_draw_preselect(viewport_control)
	if toolbar != null and toolbar.dims_visible:
		_draw_dimensions(viewport_control)


func _has_preselect() -> bool:
	return input != null and (
		input.hover_vertex >= 0 or input.hover_edge != UBPicking.NO_EDGE
		or input.hover_face >= 0)


func _draw_preselect(overlay: Control) -> void:
	if (
		input == null or input.last_camera == null
		or not is_instance_valid(edited) or edited.mesh_data == null or not edited.is_inside_tree()
	):
		return
	var camera: Camera3D = input.last_camera
	var data := edited.mesh_data
	var xf := edited.global_transform
	var tint := Color(0.75, 1.0, 0.95, 0.9)

	var show_hover := selection != null and selection.mode != UBSelection.Mode.OBJECT
	if not show_hover:
		pass
	elif input.hover_vertex >= 0 and input.hover_vertex < data.positions.size():
		var wp: Vector3 = xf * data.positions[input.hover_vertex]
		if not camera.is_position_behind(wp):
			overlay.draw_arc(camera.unproject_position(wp), 7.0, 0.0, TAU, 20, tint, 2.0, true)
	elif input.hover_edge != UBPicking.NO_EDGE:
		var e: Vector2i = input.hover_edge
		if e.x < data.positions.size() and e.y < data.positions.size():
			var a: Vector3 = xf * data.positions[e.x]
			var b: Vector3 = xf * data.positions[e.y]
			if not camera.is_position_behind(a) and not camera.is_position_behind(b):
				overlay.draw_line(
					camera.unproject_position(a), camera.unproject_position(b), tint, 3.0, true)
	elif input.hover_face >= 0 and input.hover_face < data.faces.size():
		var pts := PackedVector2Array()
		for vi in data.faces[input.hover_face].vertices:
			var wp: Vector3 = xf * data.positions[vi]
			if camera.is_position_behind(wp):
				return
			pts.append(camera.unproject_position(wp))
		if pts.size() >= 3:

			if not Geometry2D.triangulate_polygon(pts).is_empty():
				overlay.draw_colored_polygon(pts, Color(tint, 0.12))
			for i in pts.size():
				overlay.draw_line(pts[i], pts[(i + 1) % pts.size()], Color(tint, 0.7), 2.0, true)

	if input.insert_vert_active and input.insert_edge != UBPicking.NO_EDGE:
		var wp: Vector3 = xf * input.insert_point
		if not camera.is_position_behind(wp):
			var p := camera.unproject_position(wp)
			overlay.draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)),
				Color(0.984, 0.749, 0.141), false, 2.0)


## Switch the element gizmo: 0 move, 1 rotate, 2 scale. The toolbar and the
## gizmo hotkeys both land here.
func set_gizmo_mode(mode: int) -> void:
	if toolbar == null:
		return
	toolbar.gizmo_mode = clampi(mode, 0, 2)
	toolbar.sync_gizmo_mode(toolbar.gizmo_mode)
	update_overlays()


## Orientation basis for the element gizmos, in world space: Global (identity),
## Local (node basis), or Normal (Z = average selection normal, tangent frame
## around it). Degenerate normals fall back to Global.
func gizmo_basis_world() -> Basis:
	var orient: int = toolbar.gizmo_orient if toolbar != null else 0
	if orient == 1 and is_instance_valid(edited):
		return edited.global_transform.basis.orthonormalized()
	if orient == 2 and is_instance_valid(edited) and edited.mesh_data != null:
		var n := _selection_normal_world()
		if n.length_squared() > 1e-8:
			n = n.normalized()
			var ref := Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.UP
			var t := (ref - n * ref.dot(n)).normalized()
			return Basis(t, n.cross(t), n)
	return Basis.IDENTITY


func _selection_normal_world() -> Vector3:
	var data := edited.mesh_data
	var faces := {}
	match selection.mode:
		UBSelection.Mode.FACE:
			faces = selection.faces
		UBSelection.Mode.EDGE:

			var topo := UBTopology.build_cached(data)
			for e: Vector2i in selection.edges:
				for fi in topo.edge_faces.get(e, []):
					faces[fi] = true
		UBSelection.Mode.VERTEX:
			var topo := UBTopology.build_cached(data)
			for vi in selection.vertices:
				if vi >= 0 and vi < topo.vertex_faces.size():
					for fi in topo.vertex_faces[vi]:
						faces[fi] = true
	var sum := Vector3.ZERO
	for fi in faces:
		if fi is int and fi >= 0 and fi < data.faces.size():
			sum += data.face_normal(data.faces[fi])
	return selection_normal_to_world(sum, edited.global_transform.basis)


## A local-space normal (sum) in world space. Normals transform by the
## basis's inverse-transpose, not the basis: on a non-uniformly scaled node
## the basis tilts a normal off its face (a (2,1,1) scale left the Normal
## gizmo's Z leaning into the face plane). Normalized; ZERO stays ZERO, and a
## singular basis falls back to the plain transform.
static func selection_normal_to_world(local_normal: Vector3, basis: Basis) -> Vector3:
	if local_normal.length_squared() < 1e-16:
		return Vector3.ZERO
	var n: Vector3
	if absf(basis.determinant()) > 1e-12:
		n = basis.inverse().transposed() * local_normal
	else:
		n = basis * local_normal
	return n.normalized() if n.length_squared() > 1e-16 else Vector3.ZERO


## World-space average of the selected elements' vertices; the gizmo pivot.
func selection_pivot_world() -> Vector3:
	var verts := selection.gather_vertices(edited.mesh_data)
	if verts.is_empty():
		return edited.global_position
	var sum := Vector3.ZERO
	for vi in verts:
		sum += edited.mesh_data.positions[vi]
	return edited.global_transform * (sum / verts.size())


## Run an undo-wrapped topology op from the toolbar or a shortcut. Every action
## needs a selection in its mode; misuse warns instead of erroring.
func run_action(id: String) -> void:
	if edited == null or edited.mesh_data == null:
		return
	if selection.count() == 0 and id != "cut" and id != "holes" and id != "insert_vert":
		return
	var data := edited.mesh_data
	var verts := selection.vertices
	var edges := selection.edges
	var faces := selection.faces
	match id:

		"weld":
			_begin_adjust("weld")
		"collapse":
			_commit_topology_op("Collapse Vertices",
				func() -> void: UBOpCollapseVertices.apply(data, verts))
			selection.clear_elements()
		"split":
			_commit_topology_op("Split Vertices",
				func() -> void: UBOpSplitVertices.apply(data, verts))
		"connect":
			_commit_topology_op("Connect Vertices",
				func() -> void: UBOpConnectVertices.apply(data, verts))
		"fill_hole_v":

			var topo := UBTopology.build(data)
			var hole_edges := {}
			for e: Vector2i in UBSelectQueries.edges_from_vertices(topo, verts):
				if topo.edge_faces.get(e, []).size() == 1:
					hole_edges[e] = true
			if hole_edges.is_empty():
				_notify_user("Fill needs selected vertices along a hole rim.")
			else:
				_commit_topology_op("Fill Hole",
					func() -> void: UBOpFillHole.apply(data, hole_edges))

		"extrude_edges":
			_begin_adjust("extrude_edges")
		"connect_edges":
			_commit_topology_op("Connect Edges",
				func() -> void: UBOpConnectEdges.apply(data, edges))
			selection.clear_elements()
		"bevel":
			_begin_adjust("bevel")
		"bridge":
			if edges.size() != 2:
				_notify_user("Bridge needs exactly 2 selected edges.")
				return
			var pair: Array = edges.keys()
			var faces_before := data.faces.size()
			_commit_topology_op("Bridge Edges",
				func() -> void: UBOpBridgeEdges.apply(data, pair[0], pair[1]))

			if data.faces.size() == faces_before:
				_notify_user("Bridge needs two separate open edges that a new face can join cleanly.")
		"insert_loop":
			_begin_adjust("insert_loop")
		"subdiv_edges":
			_begin_adjust("subdiv_edges")
		"fill_hole":
			_commit_topology_op("Fill Hole",
				func() -> void: UBOpFillHole.apply(data, edges))
		"holes":

			selection.replace_current(UBSelectQueries.boundary_edges(UBTopology.build(data)))
		"insert_vert":
			_stand_down_tools("insert_vert")
			input.begin_insert_vert()
			update_overlays()

		"extrude":
			_begin_adjust("extrude")
		"inset":
			_begin_adjust("inset")
		"cut":
			_stand_down_tools("cut")
			cut_tool.begin()
			update_overlays()
		"subdiv_faces":
			_begin_adjust("subdiv_faces")
		"similar":

			selection.replace_current(UBSelectQueries.similar_faces(data, faces))
		"coplanar":

			selection.replace_current(
				UBSelectQueries.coplanar_faces(data, UBTopology.build(data), faces))
		"merge":

			var merge_before: int = data.faces.size()
			_commit_topology_op("Merge Faces",
				func() -> void: UBOpMergeFaces.apply(data, faces))
			if data.faces.size() != merge_before:
				selection.clear_elements()
			else:
				_notify_user("Merge needs one clean region. The selection has a hole or a bow-tie vertex.")
		"duplicate":
			var dup_from := faces.duplicate()

			var new_faces := {}
			var dup_before: int = data.faces.size()
			_commit_topology_op("Duplicate Faces",
				func() -> void: new_faces.merge(UBOpDuplicateFaces.apply(data, dup_from)))

			if data.faces.size() != dup_before:
				selection.replace_current(new_faces)
		"flip_edge":
			_commit_topology_op("Flip Face Edge",
				func() -> void: UBOpFlipFaceEdge.apply(data, faces))
		"detach":
			_run_detach(faces.duplicate())
		"delete":
			var doomed := faces.duplicate()
			_commit_topology_op("Delete Faces",
				func() -> void: UBOpDeleteFaces.apply(data, doomed))
			selection.clear_elements()
		"flip":
			_commit_topology_op("Flip Normals",
				func() -> void: UBOpFlipNormals.apply(data, faces))


## Undo-wrapped entry point for the cut tool's commit.
func commit_cut(face_index: int, points: PackedVector3Array) -> void:
	var data := edited.mesh_data
	_commit_topology_op("Cut Face",
		func() -> void: UBOpCutFace.apply(data, face_index, points))


## Undo-wrapped entry point for the insert-vertex modal: one vertex at `pos`
## (mesh-local) spliced T-junction-free into every face sharing `edge`.
func commit_insert_vertex(edge: Vector2i, pos: Vector3) -> void:
	if edited == null or edited.mesh_data == null:
		return
	var data := edited.mesh_data
	_commit_topology_op("Insert Vertex",
		func() -> void:
			var vid: int = data.add_vertex(pos)
			UBOpUtils.insert_edge_points(data, {edge: vid}))


func _resolve_params(id: String) -> Dictionary:
	var out := {}
	var step: float = toolbar.snap_step if toolbar != null else 1.0
	for action in UBActions.list():
		if action.id != id:
			continue
		for spec in action.get("params", []):
			var fallback: Variant = spec.default
			match fallback:
				"step":
					fallback = step
				"quarter":
					fallback = step * 0.25
			out[spec.key] = action_options.get(id, {}).get(spec.key, fallback)
	return out


func _begin_adjust(id: String) -> void:
	_commit_adjust()
	var values := _resolve_params(id)
	_adjust_reapplying = true
	adjust = {
		"id": id,
		"before": edited.mesh_data.duplicate_data(),
		"sel_mode": selection.mode,
		"sel_verts": selection.vertices.duplicate(),
		"sel_edges": selection.edges.duplicate(),
		"sel_faces": selection.faces.duplicate(),
		"values": values,
	}
	_action_apply(id, values)

	if _demo_face_wall(adjust.before.faces.size(), edited.mesh_data.faces.size(), ADJUSTABLE[id]):
		edited.mesh_data.copy_from(adjust.before)
		_restore_adjust_selection()
		adjust = {}
		edited.mesh_data.notify_changed()
		selection.notify()
		_adjust_reapplying = false
		return
	edited.mesh_data.notify_changed()
	selection.notify()
	_adjust_reapplying = false
	for action in UBActions.list():
		if action.id == id:
			adjust_panel.show_action(ADJUSTABLE[id], action.params, values)
			_refresh_presets()
	adjust_panel.visible = true


## Start a shape parameter session in the adjust panel: every edit rebuilds
## the committed primitive from its draw dims and the current params via
## UBShapeTool.build_shape. Ends by the same rules as action sessions; an
## untouched session leaves no undo entry.
func begin_shape_adjust(node: UBMeshInstance3D, shape_kind: int, dims: Dictionary,
		params: Array, values: Dictionary, title: String, base := false) -> void:
	_commit_adjust()
	if node == null or node.mesh_data == null or adjust_panel == null:
		return
	_ensure_panels_discovered()

	var own_sel: bool = node == edited
	adjust = {
		"id": "shape",
		"node": node,
		"kind": shape_kind,
		"dims": dims,
		"params": params,
		"base": base,
		"title": title,
		"values": values,
		"dirty": false,
		"before": node.mesh_data.duplicate_data(),
		"sel_mode": selection.mode,
		"sel_verts": selection.vertices.duplicate() if own_sel else {},
		"sel_edges": selection.edges.duplicate() if own_sel else {},
		"sel_faces": selection.faces.duplicate() if own_sel else {},
	}
	adjust_panel.show_action(title, params, values)
	_refresh_presets()
	adjust_panel.visible = true

	_remember_shape_params(shape_kind, values)


func _remember_shape_params(shape_kind: int, values: Dictionary) -> void:
	action_options[UBShapeTool.memory_key(shape_kind)] = values.duplicate()
	_queue_save_settings()


func _on_shape_edit_requested() -> void:
	if not is_instance_valid(edited) or edited.mesh_data == null:
		return
	var spec := UBShapeTool.editable_spec(edited.mesh_data)
	if spec.is_empty():
		_notify_user("This mesh is no longer the shape it was drawn as"
			+ ". Its parameters can only be edited while the geometry is untouched.")
		_refresh_shape_button()
		return
	var kind := int(spec.kind)

	begin_shape_adjust(edited, kind, (spec.dims as Dictionary).duplicate(),
		UBShapeTool.SHAPE_PARAMS[kind], (spec.params as Dictionary).duplicate(),
		UBShapeTool.shape_title(kind), bool(spec.get("base", false)))


func _schedule_shape_check() -> void:
	var data: UBMeshData = edited.mesh_data if is_instance_valid(edited) else null
	if toolbar != null:
		toolbar.sync_shape_edit(data != null, false)
	_shape_check_at = _now() + SHAPE_CHECK_DELAY if data != null else -1.0
	if data != null:
		set_process(true)


func _refresh_shape_button() -> void:
	_shape_check_at = -1.0
	if toolbar == null:
		return
	var data: UBMeshData = edited.mesh_data if is_instance_valid(edited) else null
	toolbar.sync_shape_edit(data != null, not UBShapeTool.editable_spec(data).is_empty())


func _action_apply(id: String, values: Dictionary) -> void:
	var data := edited.mesh_data
	match id:
		"weld":
			UBOpWeldVertices.apply(data, selection.vertices, values.threshold)
			selection.clear_elements(false)
		"extrude_edges":
			var new_edges := UBOpExtrudeEdges.apply(data, selection.edges, values.distance)
			if new_edges.is_empty():
				_notify_user("Only boundary edges (bordering one face) can be extruded.")
			else:
				selection.edges.clear()
				for e in new_edges:
					selection.edges[e] = true
		"bevel":
			UBOpBevelEdges.apply(data, selection.edges, values.amount,
				int(values.segments), bool(values.get("smooth", false)),
				edited.global_transform)
			selection.clear_elements(false)
		"subdiv_edges":
			UBOpSubdivideEdges.apply(data, selection.edges, int(values.segments))
			selection.clear_elements(false)
		"insert_loop":
			if not selection.edges.is_empty():
				UBOpInsertLoop.apply(data, selection.edges.keys()[0], int(values.cuts))
			selection.clear_elements(false)
		"subdiv_faces":
			UBOpSubdivideFaces.apply(data, selection.faces, int(values.segments))
			selection.clear_elements(false)
		"extrude":
			UBOpExtrudeFaces.apply(data, selection.faces, values.distance)
		"inset":
			UBOpInsetFaces.apply(data, selection.faces, values.amount,
				bool(values.get("equal", false)))


## Keys the draw gesture decides and a preset must never impose; a trim preset
## would otherwise flip a strip drawn the other way round.
const PRESET_SKIP := ["upright", "flip"]


func _session_preset_key() -> String:
	if not adjust.is_empty():
		if adjust.get("id") == "shape":
			return UBShapeTool.preset_key(int(adjust.kind))
		return str(adjust.id)
	if shape_tool != null and shape_tool.stage == UBShapeTool.Stage.PLACE_WALLS:
		return UBShapeTool.preset_key(UBShapeTool.Kind.TRIM_WALLS)
	return ""


static func _migrate_presets(options: Dictionary) -> void:
	var all = options.get("presets")
	if not (all is Dictionary):
		return
	var legacy_key := UBShapeTool.memory_key(UBShapeTool.Kind.TRIM_WALLS)
	var legacy = all.get(legacy_key)
	if not (legacy is Dictionary):
		return
	var shared_key := UBShapeTool.preset_key(UBShapeTool.Kind.TRIM_WALLS)
	if not (all.get(shared_key) is Dictionary):
		all[shared_key] = {}
	for name in legacy:
		if not all[shared_key].has(name):
			all[shared_key][name] = legacy[name]
	all.erase(legacy_key)


func _presets_for(key: String) -> Dictionary:
	var all = action_options.get("presets", {})
	if not (all is Dictionary):
		return {}
	var mine = all.get(key, {})
	return mine if mine is Dictionary else {}


func _session_values() -> Dictionary:
	if not adjust.is_empty():
		return adjust.values
	if shape_tool != null and shape_tool.stage == UBShapeTool.Stage.PLACE_WALLS:
		return shape_tool._wall_params
	return {}


func _refresh_presets(current := "") -> void:
	if adjust_panel == null:
		return
	var key := _session_preset_key()
	if key.is_empty():
		return
	var names := _presets_for(key).keys()
	names.sort()
	adjust_panel.set_presets(names, current)


func _on_preset_selected(name: String) -> void:
	var key := _session_preset_key()
	var values: Dictionary = _presets_for(key).get(name, {})
	if values.is_empty():
		return

	if not adjust.is_empty():
		var changes := {}
		for k in values:
			if k in PRESET_SKIP or not adjust.values.has(k):
				continue
			changes[k] = float(values[k])
		_apply_session_changes(changes, preset_derive_key(changes))
		if adjust_panel != null:
			adjust_panel.sync_values(adjust.values)
	elif shape_tool != null and shape_tool.stage == UBShapeTool.Stage.PLACE_WALLS:
		for k in values:
			if k in PRESET_SKIP or not shape_tool._wall_params.has(k):
				continue
			shape_tool.set_wall_param(k, float(values[k]))
		if adjust_panel != null:
			adjust_panel.sync_values(shape_tool._wall_params)
	_refresh_presets(name)


## Which key of a preset's change set the stairs' steps/riser pair derives
## from: the riser (the remembered target) when the preset carries one, else
## the step count, else any key (derive then reports the riser).
static func preset_derive_key(changes: Dictionary) -> String:
	if changes.has("riser"):
		return "riser"
	if changes.has("steps"):
		return "steps"
	return str(changes.keys()[0]) if not changes.is_empty() else ""


func _on_preset_save(name: String) -> void:
	var key := _session_preset_key()
	var values := _session_values()
	if key.is_empty() or values.is_empty():
		return
	if not (action_options.get("presets") is Dictionary):
		action_options["presets"] = {}
	if not (action_options.presets.get(key) is Dictionary):
		action_options.presets[key] = {}
	action_options.presets[key][name] = values.duplicate()
	_save_grid_settings()
	_refresh_presets(name)


func _on_preset_delete(name: String) -> void:
	var key := _session_preset_key()
	var mine := _presets_for(key)
	if not mine.has(name):
		return
	mine.erase(name)
	_save_grid_settings()
	_refresh_presets()


func _on_adjust_apply() -> void:
	if adjust.is_empty() and shape_tool != null and shape_tool.stage == UBShapeTool.Stage.PLACE_WALLS:
		shape_tool._commit()
		refresh_shape_overlay()
		return
	_commit_adjust()


func _on_adjust_cancel() -> void:
	if adjust.is_empty() and shape_tool != null and shape_tool.stage == UBShapeTool.Stage.PLACE_WALLS:
		shape_tool.cancel()
		refresh_shape_overlay()
		return
	_cancel_adjust()


func _on_adjust_param_changed(key: String, value: float) -> void:
	if adjust.is_empty():

		if shape_tool != null and shape_tool.stage == UBShapeTool.Stage.PLACE_WALLS:
			shape_tool.set_wall_param(key, value)
		return
	_apply_session_changes({key: value}, key)


## Apply one or more parameter changes to the live session with ONE rebuild
## (shape) or re-apply (action). A typed edit is one key; a preset is all of
## its keys at once. `derive_key` is the key the stairs' steps/riser pair
## derives from, so a preset's riser decides its count whatever order its
## dictionary happens to list keys in.
func _apply_session_changes(changes: Dictionary, derive_key: String) -> void:
	if adjust.is_empty() or changes.is_empty():
		return

	var prior: Dictionary = (adjust.values as Dictionary).duplicate()
	for k in changes:
		adjust.values[k] = changes[k]
	adjust.dirty = true

	if adjust_panel != null:
		adjust_panel.sync_values(adjust.values)
	if adjust.id == "shape":

		var node = adjust.node
		if node == null or not is_instance_valid(node) or node.mesh_data == null:
			return
		if adjust.kind == UBShapeTool.Kind.STAIRS:

			UBShapeTool.derive_stairs_params(adjust.dims, adjust.values, derive_key)
			adjust_panel.sync_values(adjust.values)
		_adjust_reapplying = true
		var rebuilt := UBShapeTool.build_placed(adjust.kind, adjust.dims, adjust.values, bool(adjust.get("base", false)))

		if _demo_face_wall(node.mesh_data.faces.size(), rebuilt.faces.size(), adjust.title):
			_restore_session_values(prior)
			adjust_panel.sync_values(adjust.values)
			_adjust_reapplying = false
			return
		_carry_shape_materials(node.mesh_data, rebuilt)

		rebuilt.shape_spec = {
			"kind": adjust.kind,
			"dims": (adjust.dims as Dictionary).duplicate(),
			"params": (adjust.values as Dictionary).duplicate(),
			"base": bool(adjust.get("base", false)),
		}
		node.mesh_data.copy_from(rebuilt)

		_remember_shape_params(adjust.kind, adjust.values)
		_adjust_reapplying = false
		return
	if not action_options.has(adjust.id):
		action_options[adjust.id] = {}
	for k in changes:
		action_options[adjust.id][k] = adjust.values[k]

	_queue_save_settings()
	_adjust_reapplying = true
	edited.mesh_data.copy_from(adjust.before)
	_restore_adjust_selection()
	_action_apply(adjust.id, adjust.values)

	if _demo_face_wall(adjust.before.faces.size(), edited.mesh_data.faces.size(), ADJUSTABLE[adjust.id]):
		_restore_session_values(prior)
		for k in changes:
			action_options[adjust.id][k] = adjust.values.get(k)
		_queue_save_settings()
		adjust_panel.sync_values(adjust.values)
		edited.mesh_data.copy_from(adjust.before)
		_restore_adjust_selection()
		_action_apply(adjust.id, adjust.values)
	edited.mesh_data.notify_changed()
	selection.notify()
	_adjust_reapplying = false


func _restore_session_values(prior: Dictionary) -> void:
	var values: Dictionary = adjust.values
	values.clear()
	values.merge(prior)


func _restore_adjust_selection() -> void:
	selection.mode = adjust.sel_mode
	selection.vertices = adjust.sel_verts.duplicate()
	selection.edges = adjust.sel_edges.duplicate()
	selection.faces = adjust.sel_faces.duplicate()


func _commit_adjust() -> void:
	if adjust.is_empty():
		return
	var before: UBMeshData = adjust.before
	var target = adjust.get("node", edited)

	var untouched: bool = adjust.get("id") == "shape" and not adjust.get("dirty", false)
	adjust = {}
	if adjust_panel != null:
		adjust_panel.visible = false
	if untouched or target == null or not is_instance_valid(target) or target.mesh_data == null:
		return
	var data: UBMeshData = target.mesh_data

	if data.matches(before):
		return
	if not target.is_inside_tree():

		if is_in_open_background_scene(target):
			_parked_commits.append({
				"target": target, "data": data,
				"before": before, "after": data.duplicate_data()})
		return
	var ur := get_undo_redo()
	ur.create_action("Adjust Operation")
	ur.add_do_method(data, "copy_from", data.duplicate_data())
	ur.add_undo_method(data, "copy_from", before)
	ur.commit_action(false)


var _parked_commits: Array = []


## True when `node` is out of the tree because its scene's tab is in the
## background: its topmost ancestor is one of the editor's open scene roots.
## A node removed by Undo has no parent and is no scene root, so it is false.
func is_in_open_background_scene(node: Node) -> bool:
	if node == null or not is_instance_valid(node) or node.is_inside_tree():
		return false
	var top := node
	while top.get_parent() != null:
		top = top.get_parent()
	if not EditorInterface.has_method("get_open_scene_roots"):
		return false
	return top in EditorInterface.get_open_scene_roots()


func _flush_parked_commits() -> void:
	if _parked_commits.is_empty():
		return
	var keep: Array = []
	for entry in _parked_commits:
		var target = entry.target
		if not is_instance_valid(target) or target.mesh_data != entry.data:
			continue
		if not target.is_inside_tree():
			if is_in_open_background_scene(target):
				keep.append(entry)
			continue
		if not _in_edited_scene(target):
			continue
		var ur := get_undo_redo()
		ur.create_action("Adjust Operation")
		ur.add_do_method(entry.data, "copy_from", entry.after)
		ur.add_undo_method(entry.data, "copy_from", entry.before)
		ur.commit_action(false)
	_parked_commits = keep


func _cancel_adjust() -> void:
	if adjust.is_empty():
		return
	var before: UBMeshData = adjust.before
	var session := adjust
	adjust = {}
	if adjust_panel != null:
		adjust_panel.visible = false
	var target = session.get("node", edited)
	if target == null or not is_instance_valid(target) or target.mesh_data == null:
		return
	_adjust_reapplying = true
	target.mesh_data.copy_from(before)

	adjust = session
	_restore_adjust_selection()
	adjust = {}
	selection.notify()
	_adjust_reapplying = false


func _run_detach(faces: Dictionary) -> void:
	_commit_adjust()
	var data := edited.mesh_data
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	if _demo_node_wall("Detaching to a new mesh"):
		return
	var before := data.duplicate_data()
	var detached := UBOpDetachFaces.apply(data, faces)
	var node := UBMeshInstance3D.new()
	node.name = "UBDetached"
	node.mesh_data = detached
	var source_transform := edited.global_transform
	var ur := get_undo_redo()
	ur.create_action("Detach Faces")
	ur.add_do_method(data, "copy_from", data.duplicate_data())
	ur.add_do_method(root, "add_child", node, true)
	ur.add_do_method(node, "set_owner", root)
	ur.add_do_reference(node)
	ur.add_undo_method(root, "remove_child", node)
	ur.add_undo_method(data, "copy_from", before)
	ur.commit_action(false)
	root.add_child(node, true)
	node.owner = root
	node.global_transform = source_transform
	data.notify_changed()

	var esel := EditorInterface.get_selection()
	esel.clear()
	esel.add_node(node)
	_edit(node)
	selection.change_mode(UBSelection.Mode.FACE, detached)
	for fi in detached.faces.size():
		selection.faces[fi] = true
	selection.notify()


func _on_shape_requested(kind: int) -> void:
	_ensure_session_state()
	if EditorInterface.get_edited_scene_root() == null:
		_notify_user("Open a scene before drawing shapes.")
		return
	_stand_down_tools("shape")
	shape_tool.begin(kind)
	_attach_shape_overlay(EditorInterface.get_editor_viewport_3d(0))
	refresh_shape_overlay()


func _on_tool_requested(id: String) -> void:
	match id:
		"bake":
			if UBEdition.DEMO:
				_demo_wall("Baking to MeshInstance3D")
			else:
				_bake_edited()
		"export_obj":
			if UBEdition.DEMO:
				_demo_wall("OBJ export")
			else:
				_export_mesh("obj")
		"export_gltf":
			if UBEdition.DEMO:
				_demo_wall("glTF export")
			else:
				_export_mesh("glb")
		"convert":
			_convert_selection()
		"blend_layer_a":
			_import_blend_layer(UBBlendMaterial.Layer.A)
		"blend_layer_b":
			_import_blend_layer(UBBlendMaterial.Layer.B)
		"toggle_dims":
			_save_grid_settings()
			update_overlays()
		"toggle_snap_each", "toggle_snap_absolute":
			_save_grid_settings()
		"center_pivot":
			_run_pivot_op("Center Pivot", UBOpPivot.bounds_center(edited.mesh_data) if _can_pivot() else Vector3.ZERO)
		"pivot_to_selection":
			if _can_pivot() and selection.count() > 0 and selection.mode != UBSelection.Mode.OBJECT:
				var verts := selection.gather_vertices(edited.mesh_data)
				var sum := Vector3.ZERO
				for vi in verts:
					sum += edited.mesh_data.positions[vi]
				if not verts.is_empty():
					_run_pivot_op("Set Pivot to Selection", sum / verts.size())
			else:
				_notify_user("Set Pivot to Selection needs an element selection.")
		"freeze_transform":
			_run_freeze()
		"set_collider":
			_set_entity_type(UBMeshInstance3D.EntityType.COLLIDER, "Set Collider")
		"set_trigger":
			_set_entity_type(UBMeshInstance3D.EntityType.TRIGGER, "Set Trigger")
		"rebuild_uv2":
			rebuild_scene_uv2()
		"merge_objects":
			_run_merge_objects()
		"mirror_x", "mirror_y", "mirror_z":
			if _can_pivot():
				var axis := ["mirror_x", "mirror_y", "mirror_z"].find(id)
				var data := edited.mesh_data
				_commit_topology_op("Mirror Object",
					func() -> void: UBOpMirrorObject.apply(data, axis))
		"triangulate_object":
			if _can_pivot():
				var data := edited.mesh_data
				var all := {}
				for fi in data.faces.size():
					all[fi] = true
				_commit_topology_op("Triangulate Object",
					func() -> void: UBOpTriangulateFaces.apply(data, all))
				selection.clear_elements()
		"subdivide_object":
			if _can_pivot():
				var data := edited.mesh_data
				var all := {}
				for fi in data.faces.size():
					all[fi] = true
				_commit_topology_op("Subdivide Object",
					func() -> void: UBOpSubdivideFaces.apply(data, all))
				selection.clear_elements()
		"conform_normals":
			if _can_pivot():
				var data := edited.mesh_data
				_commit_topology_op("Conform Normals",
					func() -> void: UBOpConformNormals.apply(data))
		"boolean_union":
			_run_boolean(UBOpBoolean.UNION, "Boolean Union")
		"boolean_subtract":
			_run_boolean(UBOpBoolean.SUBTRACT, "Boolean Subtract")
		"boolean_intersect":
			_run_boolean(UBOpBoolean.INTERSECT, "Boolean Intersect")
		"preferences":
			_popup_preferences()


func _can_pivot() -> bool:
	return is_instance_valid(edited) and edited.mesh_data != null


func _still_multi_selected() -> bool:
	if not is_instance_valid(edited):
		return false
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	return nodes.size() > 1 and nodes.has(edited)


func _notify_user(msg: String) -> void:
	push_warning("Unibuilder: " + msg)
	if toast == null or not is_instance_valid(toast):
		toast = UBToast.create()
	if toast.get_parent() == null and (_float_surface == null or not is_instance_valid(_float_surface)):

		var found := _find_viewport_surface()
		if found != null:
			_ensure_floating_panels(found)
	if toast.get_parent() == null:
		if _float_surface != null and is_instance_valid(_float_surface):
			_float_surface.add_child(toast)
		else:

			var host := EditorInterface.get_editor_main_screen()
			if host == null:
				return
			host.add_child(toast)
	toast.show_message(msg)
	_place_toast()
	set_process(true)


func _demo_wall(feature: String) -> void:
	_show_demo_dialog(feature + " isn't available in the Unibuilder demo.\n"
		+ "Everything you've built carries over when you upgrade.")


func _demo_node_count() -> int:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return 0
	var count := 0
	if root is UBMeshInstance3D:
		count += 1
	for node in root.find_children("*", "UBMeshInstance3D", true, false):
		if node.owner != null:
			count += 1
	return count


func _demo_node_wall(what: String, adding := 1) -> bool:
	var existing := _demo_node_count()
	if not UBEdition.node_cap_blocks(existing, adding):
		return false
	_show_demo_dialog("%s would put this scene over the demo's limit of %d Unibuilder meshes.\n%s" % [
		what, UBEdition.DEMO_MAX_NODES, DEMO_CAP_FOOTER])
	return true


func _demo_face_wall(before: int, after: int, what: String) -> bool:
	if not UBEdition.face_cap_blocks(before, after):
		return false
	_show_demo_dialog("%s would take this mesh to %d faces, over the demo's limit of %d.\n%s" % [
		what, after, UBEdition.DEMO_MAX_FACES, DEMO_CAP_FOOTER])
	return true


const DEMO_DIALOG_SCENE := "res://addons/unibuilder/editor/demo_dialog.tscn"
const DEMO_CAP_FOOTER := "The full version has no limits, and everything you've built carries over."


func _show_demo_dialog(msg: String) -> void:
	if _demo_dialog == null or not is_instance_valid(_demo_dialog):
		_demo_dialog = (load(DEMO_DIALOG_SCENE) as PackedScene).instantiate() as AcceptDialog

		_demo_dialog.add_button("Get the full version", true, "buy")
		_demo_dialog.custom_action.connect(func(_action: StringName) -> void:
			OS.shell_open(UBEdition.STORE_URL)
			_demo_dialog.hide())
		EditorInterface.get_base_control().add_child(_demo_dialog)
	_demo_dialog.dialog_text = msg
	_demo_dialog.popup_centered()


func _start_demo_nags() -> void:
	_demo_timer = Timer.new()
	_demo_timer.wait_time = UBEdition.NAG_MINUTES * 60.0
	_demo_timer.timeout.connect(func() -> void:
		_notify_user("Enjoying Unibuilder? The full version is at "
			+ UBEdition.STORE_URL))
	add_child(_demo_timer)
	_demo_timer.start()


func _run_boolean(operation: int, name: String) -> void:
	if not _can_pivot():
		_notify_user("Select a Unibuilder mesh to use as the first operand, then add the second one to the selection.")
		return
	_commit_adjust()
	var sources: Array = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is UBMeshInstance3D and n != edited and n.mesh_data != null:
			sources.append(n)
	if sources.size() != 1:
		_notify_user(("Booleans need exactly TWO Unibuilder meshes selected: %s plus one other (found %d other%s).\n\n"
			+ "Add the second mesh with Ctrl+click in the Scene dock, or Shift+click in the 3D viewport.") % [
				edited.name, sources.size(), "" if sources.size() == 1 else "s"])
		return
	var src = sources[0]
	var own_errors := UBOpBoolean.manifold_errors(edited.mesh_data)
	if not own_errors.is_empty():
		selection.change_mode(UBSelection.Mode.EDGE, edited.mesh_data)
		var bad := {}
		for e in own_errors:
			bad[e] = true
		selection.replace_current(bad)
		_notify_user("%s is not watertight. Its %d offending edges are now selected in Edge mode. Fill Hole or Conform Normals usually fixes it, then run the boolean again." % [edited.name, own_errors.size()])
		return
	var src_errors := UBOpBoolean.manifold_errors(src.mesh_data)
	if not src_errors.is_empty():
		_notify_user("%s is not watertight (%d bad edges). Edit that mesh and use Select Holes / Conform Normals, then run the boolean again." % [src.name, src_errors.size()])
		return
	var target := edited
	var data := edited.mesh_data
	var before := data.duplicate_data()
	var b_rel: Transform3D = edited.global_transform.affine_inverse() * src.global_transform
	var result: UBMeshData = await UBOpBoolean.apply(edited, data, src.mesh_data, b_rel, operation)
	if result == null or result.faces.is_empty():
		_notify_user("%s produced no geometry. The meshes probably do not overlap. Nothing was changed." % name)
		return
	if not is_instance_valid(target) or not is_instance_valid(src):
		return

	if edited != target:
		_notify_user("%s was cancelled: the selection changed while the CSG kernel was running." % name)
		return

	if _demo_face_wall(before.faces.size(), result.faces.size(), name):
		return
	data.copy_from(result)
	var ur := get_undo_redo()
	ur.create_action(name)
	ur.add_do_method(data, "copy_from", data.duplicate_data())
	ur.add_undo_method(data, "copy_from", before)
	var parent: Node = src.get_parent()
	ur.add_do_method(parent, "remove_child", src)
	ur.add_undo_method(parent, "add_child", src, true)

	ur.add_undo_method(src, "set_owner", src.owner)
	ur.add_undo_reference(src)
	ur.commit_action(false)
	parent.remove_child(src)
	selection.clear_elements(false)
	data.notify_changed()


func _run_merge_objects() -> void:
	if not _can_pivot():
		_notify_user("Select the Unibuilder mesh to merge INTO first, then add the meshes to merge in.")
		return
	_commit_adjust()
	var sources: Array = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is UBMeshInstance3D and n != edited and n.mesh_data != null:
			sources.append(n)
	if sources.is_empty():
		_notify_user(("Merge Objects needs at least one OTHER Unibuilder mesh selected alongside %s.\n\n"
			+ "Add it with Ctrl+click in the Scene dock, or Shift+click in the 3D viewport.") % edited.name)
		return
	var data := edited.mesh_data
	var before := data.duplicate_data()
	var inv := edited.global_transform.affine_inverse()
	for src in sources:
		UBOpMergeObjects.apply(data, src.mesh_data, inv * src.global_transform)

	if _demo_face_wall(before.faces.size(), data.faces.size(), "Merge Objects"):
		data.copy_from(before)
		data.notify_changed()
		return
	var ur := get_undo_redo()
	ur.create_action("Merge Objects")
	ur.add_do_method(data, "copy_from", data.duplicate_data())
	ur.add_undo_method(data, "copy_from", before)
	for src in sources:
		var parent: Node = src.get_parent()
		ur.add_do_method(parent, "remove_child", src)
		ur.add_undo_method(parent, "add_child", src, true)

		ur.add_undo_method(src, "set_owner", src.owner)
		ur.add_undo_reference(src)
	ur.commit_action(false)
	for src in sources:
		src.get_parent().remove_child(src)
	data.notify_changed()


func _run_pivot_op(name: String, center: Vector3) -> void:
	if not _can_pivot() or center == Vector3.ZERO:
		return
	_commit_adjust()
	var data := edited.mesh_data
	var node := edited
	var before := data.duplicate_data()
	var old_xf := node.transform
	UBOpPivot.translate_all(data, -center)
	var new_xf := old_xf
	new_xf.origin += old_xf.basis * center
	var ur := get_undo_redo()
	ur.create_action(name)
	ur.add_do_method(data, "copy_from", data.duplicate_data())
	ur.add_do_property(node, "transform", new_xf)
	ur.add_undo_method(data, "copy_from", before)
	ur.add_undo_property(node, "transform", old_xf)
	var kids := _hold_children_in_place(ur, node, old_xf, new_xf)
	ur.commit_action(false)
	node.transform = new_xf
	_apply_child_transforms(kids)
	data.notify_changed()


static func child_transforms_in_place(node: Node3D, old_xf: Transform3D, new_xf: Transform3D) -> Array:
	var out: Array = []
	if absf(new_xf.basis.determinant()) < 1e-12:
		return out
	var shift := new_xf.affine_inverse() * old_xf
	for child in node.get_children():
		var c := child as Node3D
		if c == null or c.top_level:
			continue
		if String(c.name) == UBMeshInstance3D.COLLISION_BODY_NAME:
			continue
		out.append([c, shift * c.transform])
	return out


func _hold_children_in_place(ur: EditorUndoRedoManager, node: Node3D,
		old_xf: Transform3D, new_xf: Transform3D) -> Array:
	var kids := child_transforms_in_place(node, old_xf, new_xf)
	for entry in kids:
		var c: Node3D = entry[0]
		ur.add_do_property(c, "transform", entry[1])
		ur.add_undo_property(c, "transform", c.transform)
	return kids


static func _apply_child_transforms(kids: Array) -> void:
	for entry in kids:
		(entry[0] as Node3D).transform = entry[1]


func _run_freeze() -> void:
	if not _can_pivot():
		return
	_commit_adjust()
	var data := edited.mesh_data
	var node := edited
	if node.transform.is_equal_approx(Transform3D.IDENTITY):
		return
	var before := data.duplicate_data()
	var old_xf := node.transform
	UBOpPivot.apply_transform(data, old_xf)
	var ur := get_undo_redo()
	ur.create_action("Freeze Transform")
	ur.add_do_method(data, "copy_from", data.duplicate_data())
	ur.add_do_property(node, "transform", Transform3D.IDENTITY)
	ur.add_undo_method(data, "copy_from", before)
	ur.add_undo_property(node, "transform", old_xf)
	var kids := _hold_children_in_place(ur, node, old_xf, Transform3D.IDENTITY)
	ur.commit_action(false)
	node.transform = Transform3D.IDENTITY
	_apply_child_transforms(kids)
	data.notify_changed()


func _popup_preferences() -> void:
	if _prefs_panel == null or not is_instance_valid(_prefs_panel):
		_prefs_panel = UBPreferencesPanel.create()
		_prefs_panel.pref_changed.connect(_on_pref_changed)
		_prefs_panel.reset_requested.connect(_on_prefs_reset)
		EditorInterface.get_base_control().add_child(_prefs_panel)
	var merged: Dictionary = UBGizmoPlugin.DEFAULTS.duplicate()
	merged.merge(prefs if prefs is Dictionary else {}, true)
	_prefs_panel.set_values(merged)
	_prefs_panel.popup(Rect2i(Vector2i(DisplayServer.mouse_get_position()), Vector2i(0, 0)))


func _on_pref_changed(key: String, value: Variant) -> void:
	if not (prefs is Dictionary):
		prefs = {}
	prefs[key] = value
	_apply_prefs()
	_save_grid_settings()


func _on_prefs_reset() -> void:
	prefs = {}
	_apply_prefs()
	_save_grid_settings()
	_prefs_panel.set_values(UBGizmoPlugin.DEFAULTS)


func _apply_prefs() -> void:
	var p: Dictionary = prefs if prefs is Dictionary else {}
	if gizmo_plugin != null:
		gizmo_plugin.apply_prefs(p)

	UBMeshInstance3D.live_uv2_texel = (
		p.get("lightmap_texel", UBGizmoPlugin.DEFAULTS.lightmap_texel)
		if p.get("live_uv2", UBGizmoPlugin.DEFAULTS.live_uv2) else 0.0)
	UBMeshInstance3D.uv2_hook = _on_live_uv2

	if UBMeshInstance3D.live_uv2_texel > 0.0 and is_inside_tree():
		UBMeshInstance3D.requeue_live_uv2(get_tree())
	if is_instance_valid(edited):
		edited.update_gizmos()


func _in_edited_scene(node: Node) -> bool:
	var root := EditorInterface.get_edited_scene_root()
	return root != null and (node == root or root.is_ancestor_of(node))


func _on_live_uv2(node: UBMeshInstance3D, result: int) -> void:
	if not is_instance_valid(node):
		return
	if result == UBMeshInstance3D.UV2Result.FAILED:
		_notify_user("Lightmap UV2 unwrap failed on \"%s\". Lightmap bakes will skip or mislight it." % node.name)
	elif _in_edited_scene(node):
		EditorInterface.mark_scene_as_unsaved()


var _uv2_rebuild_running := false


## Tools > Rebuild Lightmap UV2: unwraps every UB mesh of the edited scene again
## at the bake texel, current or not, one mesh per frame so the editor keeps
## drawing. Returns [rebuilt, failed] counts.
func rebuild_scene_uv2() -> Array[int]:
	var counts: Array[int] = [0, 0]
	if _uv2_rebuild_running:
		return counts
	var p: Dictionary = prefs if prefs is Dictionary else {}
	var texel: float = p.get("lightmap_texel", UBGizmoPlugin.DEFAULTS.lightmap_texel)
	if texel <= 0.0:
		_notify_user("Set a bake lightmap texel above 0 in Preferences to build lightmap UV2.")
		return counts
	var root := EditorInterface.get_edited_scene_root()
	var nodes: Array[UBMeshInstance3D] = []
	var stack: Array[Node] = []
	if root != null:
		stack.append(root)
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is UBMeshInstance3D and n.mesh_data != null and n.live_uv2:
			nodes.append(n)
		stack.append_array(n.get_children())
	if nodes.is_empty():
		_notify_user("No Unibuilder meshes in this scene to unwrap.")
		return counts
	_uv2_rebuild_running = true
	var failed := PackedStringArray()
	var tree := get_tree()
	var stopped := false
	for node in nodes:

		if not _uv2_run_still_valid(root):
			stopped = true
			break
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		match node.rebuild_lightmap_uv2(texel, true):
			UBMeshInstance3D.UV2Result.REBUILT:
				counts[0] += 1
			UBMeshInstance3D.UV2Result.FAILED:
				counts[1] += 1
				failed.append(node.name)
		await tree.process_frame
	_uv2_rebuild_running = false
	if counts[0] > 0:
		if _uv2_run_still_valid(root):
			EditorInterface.mark_scene_as_unsaved()
		elif is_instance_valid(root):

			_unsaved_on_return.append(root)
	if not is_inside_tree():
		return counts
	var msg := "Rebuilt lightmap UV2 on %d mesh%s." % [counts[0], "" if counts[0] == 1 else "es"]
	if stopped:
		msg += " Stopped early: the scene changed."
	if counts[1] > 0:
		msg += " %d failed: %s." % [counts[1], ", ".join(failed)]
	elif counts[0] > 0:
		msg += " Bake your lightmaps again."
	_notify_user(msg)
	return counts


var _unsaved_on_return: Array = []


func _uv2_run_still_valid(root: Node) -> bool:
	return (
		is_inside_tree() and is_instance_valid(root) and root.is_inside_tree()
		and EditorInterface.get_edited_scene_root() == root)


func _draw_dimensions(overlay: Control) -> void:
	if not is_instance_valid(edited) or edited.mesh_data == null or not edited.is_inside_tree():
		return
	if input == null or input.last_camera == null:
		return
	var pts := PackedVector3Array()
	if selection.mode == UBSelection.Mode.OBJECT or selection.count() == 0:
		pts = edited.mesh_data.positions
	else:
		for vi in selection.gather_vertices(edited.mesh_data):
			pts.append(edited.mesh_data.positions[vi])
	if pts.is_empty():
		return
	var xf := edited.global_transform
	var lo := xf * pts[0]
	var hi := lo
	for p in pts:
		var w := xf * p
		lo = lo.min(w)
		hi = hi.max(w)
	var center := (lo + hi) * 0.5
	var cam := input.last_camera
	if cam.is_position_behind(center):
		return
	var size := hi - lo
	var text := "%s × %s × %s" % [
		String.num(absf(size.x), 3), String.num(absf(size.y), 3), String.num(absf(size.z), 3)]
	var pos := cam.unproject_position(center) + Vector2(14.0, -14.0)
	var font := overlay.get_theme_font(&"font", &"Label")
	var font_size := overlay.get_theme_font_size(&"font_size", &"Label")
	overlay.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(0, 0, 0, 0.85))
	overlay.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1, 0.95))


func _set_entity_type(type: UBMeshInstance3D.EntityType, title: String) -> void:
	if edited == null:
		_notify_user("Select a Unibuilder mesh first.")
		return
	var target := type if edited.entity_type != type else UBMeshInstance3D.EntityType.NORMAL
	var ur := get_undo_redo()
	ur.create_action(title)
	ur.add_do_property(edited, "entity_type", target)
	ur.add_undo_property(edited, "entity_type", edited.entity_type)
	ur.commit_action(true)


func _bake_edited() -> void:
	if edited == null or edited.mesh == null:
		_notify_user("Select a Unibuilder mesh to bake.")
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null or edited == root:
		_notify_user("Cannot bake the scene root.")
		return

	_commit_adjust()
	var old := edited
	var p: Dictionary = prefs if prefs is Dictionary else {}
	var baked := old.make_baked(p.get("lightmap_texel", UBGizmoPlugin.DEFAULTS.lightmap_texel))
	var ur := get_undo_redo()

	var swapper := UBNodeSwap.new()
	ur.create_action("Bake to MeshInstance3D", UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(swapper, "swap", old, baked, root)
	ur.add_undo_method(swapper, "swap", baked, old, root)
	ur.add_do_reference(baked)
	ur.add_undo_reference(old)
	ur.commit_action(true)


func _export_mesh(default_ext: String) -> void:
	if edited == null or edited.mesh_data == null:
		_notify_user("Select a Unibuilder mesh to export.")
		return
	if _export_dialog == null or not is_instance_valid(_export_dialog):
		_export_dialog = EditorFileDialog.new()
		_export_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_export_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_export_dialog.file_selected.connect(_on_export_path_chosen)
		EditorInterface.get_base_control().add_child(_export_dialog)
	_export_dialog.clear_filters()
	if default_ext == "obj":
		_export_dialog.add_filter("*.obj", "Wavefront OBJ (+ MTL sidecar)")
	else:
		_export_dialog.add_filter("*.glb", "glTF Binary")
		_export_dialog.add_filter("*.gltf", "glTF Text")

	_export_target = edited
	_export_dialog.current_file = String(edited.name) + "." + default_ext
	_export_dialog.popup_centered_ratio(0.5)


func _on_export_path_chosen(path: String) -> void:
	var node: UBMeshInstance3D = _export_target if is_instance_valid(_export_target) else null
	_export_target = null
	if node == null or node.mesh_data == null:
		_notify_user("The mesh this export was opened for is gone. Nothing was exported.")
		return
	var xf: Transform3D = node.global_transform if node.is_inside_tree() else node.transform
	var ext := path.get_extension().to_lower()
	if ext == "glb" or ext == "gltf":

		var gltf := _load_exporter("export_gltf.gd")
		if gltf == null:
			return

		var err: int = gltf.export_file(
			node.mesh_data, String(node.name), path, xf)
		if err != OK:
			_notify_user("glTF export failed (%d) for %s" % [err, path])
			return
		print("Unibuilder: exported " + path)
		return
	var obj := _load_exporter("export_obj.gd")
	if obj == null:
		return

	var mtl_name := path.get_file().get_basename() + ".mtl"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_notify_user("Cannot write " + path)
		return
	f.store_string(obj.to_obj(
		node.mesh_data, String(node.name), mtl_name, xf))
	f.close()
	var mtl_path := path.get_base_dir().path_join(mtl_name)
	var mf := FileAccess.open(mtl_path, FileAccess.WRITE)
	if mf != null:
		mf.store_string(obj.to_mtl(node.mesh_data))
		mf.close()
	print("Unibuilder: exported %s (+ %s)" % [path, mtl_name])


func _load_exporter(file: String) -> GDScript:
	var script_path := "res://addons/unibuilder/core/" + file
	if not ResourceLoader.exists(script_path, "Script"):
		_notify_user("Export is not available in this build.")
		return null
	return load(script_path)


func _convert_selection() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var targets: Array[MeshInstance3D] = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is MeshInstance3D and not (n is UBMeshInstance3D) and n.mesh != null and n != root:
			targets.append(n)
	if targets.is_empty():
		_notify_user("Select a plain MeshInstance3D (not the scene root) to convert.")
		return
	if _demo_node_wall("Converting %d mesh%s" % [targets.size(), "" if targets.size() == 1 else "es"], targets.size()):
		return

	var converted: Array[UBMeshData] = []
	for old in targets:

		var data := UBConvertMesh.from_mesh(old.mesh, true, 0.001, 30.0)
		if _demo_face_wall(0, data.faces.size(), "Converting %s" % old.name):
			return
		converted.append(data)
	var ur := get_undo_redo()

	var swapper := UBNodeSwap.new()
	ur.create_action("Convert to Unibuilder", UndoRedo.MERGE_DISABLE, root)
	var new_nodes: Array = []
	for i in targets.size():
		var old := targets[i]
		var node := UBMeshInstance3D.new()
		node.name = old.name
		node.mesh_data = converted[i]
		new_nodes.append(node)

		ur.add_do_method(swapper, "swap", old, node, root, false)
		ur.add_undo_method(swapper, "swap", node, old, root, false)
		ur.add_do_reference(node)
		ur.add_undo_reference(old)
	ur.add_do_method(swapper, "select_nodes", new_nodes)
	ur.add_undo_method(swapper, "select_nodes", Array(targets))
	ur.commit_action(true)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and _handle_global_undo(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and _handle_global_modal_wheel(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and _handle_global_prop_wheel(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and _handle_global_select_all(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and _handle_global_grid_key(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and _claims_vertex_snap_key(event):
		get_viewport().set_input_as_handled()
		return

	if (
		event is InputEventMouseMotion and paint_tool != null
		and paint_tool.active() and _viewport_under_mouse(event.position).is_empty()
	):
		paint_tool.pointer_left()
	if (
		event is InputEventMouseMotion and material_tool != null
		and material_tool.active() and _viewport_under_mouse(event.position).is_empty()
	):
		material_tool.pointer_left()

	if (
		event is InputEventMouseMotion and input != null and _has_preselect()
		and _viewport_under_mouse(event.position).is_empty()
	):
		input.clear_preselect()
		update_overlays()
	if shape_tool == null or not shape_tool.active():
		return
	if event is InputEventKey:
		var focus := get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:
			return
		if shape_tool.handle_input(_overlay_camera, event) == AFTER_GUI_INPUT_STOP:
			get_viewport().set_input_as_handled()
		refresh_shape_overlay()
		return
	if event is InputEventMouse:
		if event is InputEventMouseButton:
			if event.pressed:
				if _over_floating_panel():
					_panel_press = true
					return
			elif _panel_press:
				_panel_press = false
				return
		var hit := _viewport_under_mouse(event.position)
		if hit.is_empty():
			return
		_attach_shape_overlay(hit.viewport)
		var ev: InputEventMouse = event.duplicate()
		ev.position = event.position - Vector2(hit.origin)
		if shape_tool.handle_input(hit.camera, ev) == AFTER_GUI_INPUT_STOP:
			get_viewport().set_input_as_handled()
		refresh_shape_overlay()


func _handle_global_modal_wheel(event: InputEventMouseButton) -> bool:
	if event.button_index != MOUSE_BUTTON_WHEEL_UP and event.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return false
	if input == null or not input.modal_adjust_active():
		return false
	if _viewport_under_mouse(event.position).is_empty():
		return false

	if event.pressed:
		input.step_modal_segments(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
		update_overlays()
	return true


func _handle_global_prop_wheel(event: InputEventMouseButton) -> bool:
	if event.button_index != MOUSE_BUTTON_WHEEL_UP and event.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return false
	if input == null or not input.prop_drag_active():
		return false
	if _viewport_under_mouse(event.position).is_empty():
		return false
	if event.pressed:
		input.adjust_prop_radius(
			1.25 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8)
		update_overlays()
	return true


func _handle_global_undo(event: InputEventKey) -> bool:
	if not undo_hotkey_matches(event):
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return false
	if input != null and input.cancel_gesture():
		update_overlays()
		return true

	if cut_tool != null and cut_tool.stage == UBCutTool.Stage.DRAW:
		cut_tool.cancel()
		update_overlays()
		return true
	if paint_tool != null and paint_tool.cancel_stroke():
		update_overlays()
		return true

	if material_tool != null and material_tool.cancel_drag():
		update_overlays()
		return true

	if uv_editor != null and is_instance_valid(uv_editor) and uv_editor.cancel_drag():
		update_overlays()
		return true
	_commit_adjust()
	return false


## True for Ctrl+Z, Ctrl+Shift+Z or Ctrl+Y (Cmd on macOS), the editor's own
## undo and redo bindings. Redo counts because it moves history under a live
## session just as undo does. Static so it can be tested without an editor.
static func undo_hotkey_matches(event: InputEventKey) -> bool:
	if not event.pressed or event.echo or event.alt_pressed:
		return false
	if not event.is_command_or_control_pressed():
		return false
	return event.keycode == KEY_Z or event.keycode == KEY_Y


func _handle_global_select_all(event: InputEventKey) -> bool:
	if not select_all_hotkey_matches(event):
		return false
	if not is_instance_valid(edited) or edited.mesh_data == null:
		return false
	if selection == null or selection.mode == UBSelection.Mode.OBJECT:
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return false
	if _viewport_under_mouse(
			EditorInterface.get_base_control().get_global_mouse_position()).is_empty():
		return false
	_on_select_all()
	return true


## True for Ctrl+A alone. Ctrl+Shift+A is the Scene dock's "Instantiate Child
## Scene" and must never be swallowed. Static so it can be tested without an editor.
static func select_all_hotkey_matches(event: InputEventKey) -> bool:
	return (
		event.pressed and not event.echo
		and event.keycode == KEY_A
		and event.is_command_or_control_pressed()
		and not event.shift_pressed
		and not event.alt_pressed
	)


func _handle_global_grid_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo or toolbar == null:
		return false

	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed or event.shift_pressed:
		return false
	if event.keycode not in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT, KEY_COMMA, KEY_PERIOD, KEY_0]:
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return false
	if _viewport_under_mouse(EditorInterface.get_base_control().get_global_mouse_position()).is_empty():
		return false
	match event.keycode:
		KEY_BRACKETLEFT:
			adjust_grid_step(0.5)
		KEY_BRACKETRIGHT:
			adjust_grid_step(2.0)
		KEY_COMMA:
			nudge_grid_offset(-1.0)
		KEY_PERIOD:
			nudge_grid_offset(1.0)
		KEY_0:
			reset_grid_offset()
	return true


func _claims_vertex_snap_key(event: InputEventKey) -> bool:
	if event.keycode != KEY_V or not event.pressed:
		return false
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed or event.shift_pressed:
		return false
	if not is_instance_valid(edited) or edited.mesh_data == null or input == null:
		return false
	if selection.mode == UBSelection.Mode.OBJECT and not input._object_mode_active():
		return false
	if UBViewportInput.freelook_held():
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return false
	return not _viewport_under_mouse(
		EditorInterface.get_base_control().get_global_mouse_position()).is_empty()


func _viewport_under_mouse(window_pos: Vector2) -> Dictionary:
	for i in 4:
		var vp := EditorInterface.get_editor_viewport_3d(i)
		if vp == null:
			continue
		var container := vp.get_parent() as Control
		if container == null or not container.is_visible_in_tree():
			continue
		var rect := container.get_global_rect()
		if rect.has_point(window_pos):
			return {"viewport": vp, "camera": vp.get_camera_3d(), "origin": rect.position}
	return {}


func _attach_shape_overlay(vp: SubViewport) -> void:
	if vp == null:
		return
	var container := vp.get_parent() as Control
	if container == null:
		return
	if shape_overlay == null or not is_instance_valid(shape_overlay):
		shape_overlay = Control.new()
		shape_overlay.name = "_UBShapeOverlay"
		shape_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		shape_overlay.draw.connect(_draw_shape_overlay)
	if shape_overlay.get_parent() != container:
		if shape_overlay.get_parent() != null:
			shape_overlay.get_parent().remove_child(shape_overlay)
		container.add_child(shape_overlay)
		shape_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_camera = vp.get_camera_3d()


func _draw_shape_overlay() -> void:
	if shape_tool != null and shape_tool.active():
		shape_tool.draw_overlay(shape_overlay, _overlay_camera)


func refresh_shape_overlay() -> void:
	if shape_tool == null or not shape_tool.active():
		_detach_shape_overlay()
		return
	if shape_overlay != null and is_instance_valid(shape_overlay):
		shape_overlay.queue_redraw()


func _detach_shape_overlay() -> void:
	if shape_overlay != null and is_instance_valid(shape_overlay):
		shape_overlay.queue_free()
	shape_overlay = null


func _update_grid() -> void:
	if grid == null or toolbar == null:
		return
	var world: World3D = null
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp != null:
		world = vp.find_world_3d()
	grid.update(world, toolbar.grid_visible, toolbar.grid_axis, grid_offset, toolbar.snap_step)


func _on_grid_changed() -> void:
	_update_grid()

	if shape_tool != null and shape_tool.active():
		shape_tool.refresh_plane()
		refresh_shape_overlay()
	_save_grid_settings()


func _on_scene_changed(_root: Node) -> void:

	_commit_adjust()
	_cancel_interactions()
	if shape_tool != null and shape_tool.active():

		shape_tool.cancel()
		refresh_shape_overlay()

	UBTopology.clear_cache()
	UBRayAccel.clear_cache()

	_flush_parked_commits()
	var current := EditorInterface.get_edited_scene_root()
	if current != null and _unsaved_on_return.has(current):
		_unsaved_on_return.erase(current)
		EditorInterface.mark_scene_as_unsaved()
	_unsaved_on_return = _unsaved_on_return.filter(
		func(r) -> bool: return is_instance_valid(r))
	_update_grid()


func adjust_grid_step(factor: float) -> void:
	toolbar.scale_step(factor)


func _on_grid_align() -> void:
	if edited == null or edited.mesh_data == null:
		_notify_user("Align Grid needs a Unibuilder mesh selected. It aligns the grid to that mesh's selection or origin.")
		return
	var data := edited.mesh_data
	var xf := edited.global_transform
	var axis: int = toolbar.grid_axis
	var aligned := false
	if selection.mode == UBSelection.Mode.FACE and not selection.faces.is_empty():
		var normal := Vector3.ZERO
		var center := Vector3.ZERO
		var counted := 0
		for fi in selection.faces:
			if fi < 0 or fi >= data.faces.size():
				continue
			var face: UBFace = data.faces[fi]
			normal += (xf.basis * data.face_normal(face)).normalized()
			center += xf * data.face_center(face)
			counted += 1
		if counted > 0:
			axis = normal.abs().max_axis_index()
			grid_offset = (center / counted)[axis]
			aligned = true
	if not aligned:
		var verts := selection.gather_vertices(data)
		if verts.is_empty():
			grid_offset = xf.origin[axis]
		else:
			var center := Vector3.ZERO
			for vi in verts:
				center += xf * data.positions[vi]
			grid_offset = (center / verts.size())[axis]
	toolbar.set_grid_axis(axis)
	_on_grid_changed()


func nudge_grid_offset(direction: float) -> void:
	grid_offset += direction * toolbar.snap_step
	_on_grid_changed()


func reset_grid_offset() -> void:
	grid_offset = 0.0
	_on_grid_changed()


## Seconds of quiet before a queued settings write happens.
const SETTINGS_SAVE_DELAY := 0.5

var _settings_save_at := -1.0


func _queue_save_settings() -> void:
	_settings_save_at = _now() + SETTINGS_SAVE_DELAY
	set_process(true)


func _save_grid_settings() -> void:
	_settings_save_at = -1.0

	if toolbar == null or not is_instance_valid(toolbar):
		return
	var state := toolbar.get_state()
	state["offset"] = grid_offset

	state["action_options"] = action_options if action_options is Dictionary else {}
	state["prefs"] = prefs if prefs is Dictionary else {}
	if paint_panel != null:
		state["palette"] = paint_panel.get_swatches()
		state["brush"] = paint_panel.get_brush()
	if material_palette != null:
		state["mat_palette"] = material_palette.get_paths()
		state["mat_default"] = material_palette.get_default_path()
	EditorInterface.get_editor_settings().set_project_metadata("unibuilder", "grid", state)


func _load_grid_settings() -> void:
	var state: Dictionary = EditorInterface.get_editor_settings().get_project_metadata(
		"unibuilder", "grid", {})
	if state.is_empty():
		return
	toolbar.apply_state(state)
	grid_offset = state.get("offset", 0.0)
	var loaded = state.get("action_options", {})
	action_options = loaded if loaded is Dictionary else {}
	_migrate_presets(action_options)
	var loaded_prefs = state.get("prefs", {})
	prefs = loaded_prefs if loaded_prefs is Dictionary else {}
	var palette = state.get("palette", null)
	if paint_panel != null and palette is PackedColorArray and palette.size() > 0:
		paint_panel.set_swatches(Array(palette))
	var brush = state.get("brush", null)
	if paint_panel != null and brush is Dictionary:
		paint_panel.set_brush(brush)
	var mats = state.get("mat_palette", null)
	if material_palette != null and mats is PackedStringArray:
		material_palette.set_paths(mats)
	var mat_default = state.get("mat_default", null)
	if material_palette != null and mat_default is String and not mat_default.is_empty():
		material_palette.set_default_path(mat_default)


func _commit_topology_op(name: String, mutator: Callable) -> void:
	_commit_adjust()
	if not is_instance_valid(edited) or edited.mesh_data == null:
		return
	var data := edited.mesh_data
	var before := data.duplicate_data()
	mutator.call()
	_commit_snapshot_op(name, before)


func _commit_snapshot_op(name: String, before: UBMeshData) -> void:
	if not is_instance_valid(edited) or edited.mesh_data == null:
		return
	var data := edited.mesh_data
	if data.matches(before):
		return

	if _demo_face_wall(before.faces.size(), data.faces.size(), name):
		data.copy_from(before)
		data.notify_changed()
		return
	var ur := get_undo_redo()
	ur.create_action(name)
	ur.add_do_method(data, "copy_from", data.duplicate_data())
	ur.add_undo_method(data, "copy_from", before)
	ur.commit_action(false)
	data.notify_changed()
	_refresh_vertex_panel()


func _on_gizmo_changed() -> void:
	_save_grid_settings()
	update_overlays()


func _on_mode_requested(mode: int) -> void:
	var data: UBMeshData = edited.mesh_data if is_instance_valid(edited) else null
	selection.change_mode(mode, data)


var _preselect_mode := -1


func _on_selection_changed() -> void:
	if not adjust.is_empty() and not _adjust_reapplying:
		_commit_adjust()
	if is_instance_valid(edited):
		edited.update_gizmos()
	if toolbar != null:
		toolbar.sync_mode(selection.mode)

	if selection.mode != _preselect_mode:
		_preselect_mode = selection.mode
		if input != null:
			input.clear_preselect()
	_sync_native_gizmo_lock()
	_refresh_face_panel()
	_refresh_vertex_panel()
	if input != null and selection.mode != UBSelection.Mode.EDGE:
		input.end_insert_vert()
	if uv_editor != null:
		uv_editor.refresh()
	update_overlays()


func _refresh_face_panel() -> void:
	if face_panel == null:
		return
	var editing: bool = is_instance_valid(edited) and edited.mesh_data != null
	var show: bool = editing and selection.mode == UBSelection.Mode.FACE
	face_panel.visible = show

	if material_palette != null:
		material_palette.visible = editing
	if show:
		face_panel.set_from(edited.mesh_data, selection.faces)


func _ensure_floating_panels(surface: Control) -> void:
	if surface == null:
		return

	if (
		_float_surface == surface and vertex_panel != null
		and vertex_panel.get_parent() == surface
		and adjust_panel != null and adjust_panel.get_parent() == surface
		and toast != null and is_instance_valid(toast) and toast.get_parent() == surface
	):
		return
	var vp: SubViewport = null
	var parent := surface.get_parent()
	if parent != null:
		for child in parent.get_children():
			if child is SubViewportContainer and child.get_child_count() > 0:
				vp = child.get_child(0) as SubViewport
				break
	if vp == null or vp != EditorInterface.get_editor_viewport_3d(0):
		return
	for panel in [vertex_panel, adjust_panel, toast]:
		if panel == null or not is_instance_valid(panel):
			continue
		if panel.get_parent() == surface:
			continue
		if panel.get_parent() != null:
			panel.get_parent().remove_child(panel)
		surface.add_child(panel)
	_float_surface = surface
	_float_viewport = vp
	set_process(true)


func _process(_delta: float) -> void:
	if _shape_check_at >= 0.0 and _now() >= _shape_check_at:
		_refresh_shape_button()
	if _settings_save_at >= 0.0 and _now() >= _settings_save_at:
		_save_grid_settings()

	if is_instance_valid(edited) and edited.mesh_data != _bound_data:
		_bind_mesh_data()
		_schedule_shape_check()
		if selection != null and edited.mesh_data != null:
			selection.prune_invalid(edited.mesh_data)
		_refresh_face_panel()
		_refresh_vertex_panel()
		if uv_editor != null:
			uv_editor.refresh()
		update_overlays()
	_place_toast()
	if _float_viewport == null or not is_instance_valid(_float_viewport):
		return
	var vs := Vector2(_float_viewport.size)
	var m := 12.0 * EditorInterface.get_editor_scale()
	if vertex_panel != null and is_instance_valid(vertex_panel) and vertex_panel.visible:
		vertex_panel.size = vertex_panel.get_combined_minimum_size()
		vertex_panel.position = Vector2(m, vs.y - vertex_panel.size.y - m)
	if adjust_panel != null and is_instance_valid(adjust_panel) and adjust_panel.visible:
		adjust_panel.size = adjust_panel.get_combined_minimum_size()
		adjust_panel.position = Vector2(
			vs.x - adjust_panel.size.x - m, vs.y - adjust_panel.size.y - m)


func _ensure_panels_discovered() -> void:
	if _float_surface != null and is_instance_valid(_float_surface):
		return
	var found := _find_viewport_surface()
	if found != null:
		_ensure_floating_panels(found)


func _find_viewport_surface() -> Control:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return null
	var svc := vp.get_parent()
	if svc == null or svc.get_parent() == null:
		return null
	for child in svc.get_parent().get_children():
		if child != svc and child is Control and child.get_class() == "Control":
			return child
	return null


func _place_toast() -> void:
	if toast == null or not is_instance_valid(toast) or not toast.visible:
		return
	var host_control := toast.get_parent() as Control
	if host_control == null:
		return
	var m := 12.0 * EditorInterface.get_editor_scale()
	toast.size = toast.get_combined_minimum_size()
	if host_control == _float_surface and _float_viewport != null and is_instance_valid(_float_viewport):
		var host := Vector2(_float_viewport.size)
		toast.position = Vector2((host.x - toast.size.x) * 0.5, host.y - toast.size.y - m)
		return
	var area := Rect2(Vector2.ZERO, host_control.size)
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var cont: Control = null
	if vp != null:
		cont = vp.get_parent() as Control
	if cont != null and cont.is_visible_in_tree():
		area = Rect2(
			cont.get_global_rect().position - host_control.get_global_rect().position,
			cont.get_global_rect().size)
	toast.position = area.position + Vector2(
		(area.size.x - toast.size.x) * 0.5, area.size.y - toast.size.y - m)


func _refresh_vertex_panel() -> void:
	if vertex_panel == null:
		return
	var show: bool = (
		is_instance_valid(edited) and edited.mesh_data != null
		and selection.mode != UBSelection.Mode.OBJECT and selection.count() > 0)
	vertex_panel.visible = show
	if show:
		vertex_panel.show_selection(edited.mesh_data, selection, edited.global_transform)


## The vertex's new local position when one WORLD axis is set to `value`: the
## world-space change along that axis alone, mapped through the inverse basis
## and added to the exact current position. The other two world coordinates
## therefore stay exactly where they were (bit for bit on an unrotated node),
## instead of round-tripping through a 0.001-quantized number field.
static func vertex_with_world_axis(local: Vector3, xf: Transform3D, axis: int, value: float) -> Vector3:
	if axis < 0 or axis > 2 or absf(xf.basis.determinant()) < 1e-12:
		return local
	var world := xf * local
	var delta := Vector3.ZERO
	delta[axis] = value - world[axis]
	if delta == Vector3.ZERO:
		return local
	return local + xf.basis.inverse() * delta


func _on_vertex_position_committed(axis: int, value: float) -> void:
	if not is_instance_valid(edited) or edited.mesh_data == null:
		return
	if selection.mode != UBSelection.Mode.VERTEX or selection.vertices.size() != 1:
		return
	var vi: int = selection.vertices.keys()[0]
	var data := edited.mesh_data
	if vi < 0 or vi >= data.positions.size():
		return
	var local := vertex_with_world_axis(data.positions[vi], edited.global_transform, axis, value)
	if data.positions[vi].distance_to(local) < 1e-6:
		return
	var before := data.positions.duplicate()
	var after := data.positions.duplicate()
	after[vi] = local

	var frames := UBOpUV.drag_uv_frames(data, {vi: true}, before)
	data.positions = after
	UBOpUV.refit_drag_uvs(data, frames)
	var uv_before := UBOpUV.drag_uv_coords(data, frames, true)
	var uv_after := UBOpUV.drag_uv_coords(data, frames, false)
	var axes_before := UBOpUV.drag_uv_axes(data, frames, true)
	var axes_after := UBOpUV.drag_uv_axes(data, frames, false)
	var ur := get_undo_redo()

	ur.create_action("Set Vertex Position", UndoRedo.MERGE_ENDS)
	ur.add_do_property(data, "positions", after)
	ur.add_undo_property(data, "positions", before)
	if not frames.is_empty():
		ur.add_do_method(data, "apply_uv_coords", uv_after)
		ur.add_undo_method(data, "apply_uv_coords", uv_before)
	if not axes_after.is_empty():
		ur.add_do_method(data, "apply_uv_axes", axes_after)
		ur.add_undo_method(data, "apply_uv_axes", axes_before)
	ur.add_do_method(data, "notify_changed")
	ur.add_undo_method(data, "notify_changed")
	ur.commit_action(false)
	data.positions = after
	data.notify_changed()


func _on_paint_toggled(enabled: bool) -> void:
	if enabled:
		_stand_down_tools("paint")
		paint_tool.begin()
	else:
		paint_tool.cancel()

	toolbar.sync_paint(paint_tool.active())
	paint_panel.visible = paint_tool.active()

	if is_instance_valid(edited):
		edited.update_gizmos()
	update_overlays()


func _on_paint_fill_changed() -> void:
	if paint_tool == null or not paint_tool.active():
		return
	paint_tool.apply_mode_changed()
	if is_instance_valid(edited):
		edited.update_gizmos()
	update_overlays()


## The paint tool ended itself (Esc, 5, or a mode key): unpress its mode
## button, let sync_paint re-press the selection mode's, and hide the palette.
func paint_ended() -> void:
	if toolbar != null:
		toolbar.sync_paint(false)
	if paint_panel != null:
		paint_panel.visible = false
	if is_instance_valid(edited):
		edited.update_gizmos()


func _on_material_toggled(enabled: bool) -> void:
	if enabled:
		_stand_down_tools("material")
		material_tool.begin()
	else:
		material_tool.cancel()

	toolbar.sync_material(material_tool.active())

	if is_instance_valid(edited):
		edited.update_gizmos()
	update_overlays()


## The material tool ended itself (Esc, 6, or a mode key): unpress its button,
## let sync_material re-press the selection mode's, and bring the tint back.
func material_ended() -> void:
	if toolbar != null:
		toolbar.sync_material(false)
	if is_instance_valid(edited):
		edited.update_gizmos()


## Shared mode-key handling for the tool modes (paint, material). A live tool
## owns the viewport event stream, so it must handle Esc, Shift+1..4, its own
## key (toggle off) and the other tool's key (hand over) itself. `own_digit` is
## the tool's mode digit (5 paint, 6 material; the key is Shift+digit, see
## UBViewportInput.mode_digit). `cancel_gesture` ends a live stroke or drag and
## reports whether one was live; Esc ends the gesture first and the mode
## second. `exit` leaves the tool. Returns the input verdict, or -1 when the
## key is not a mode key and the tool carries on.
func handle_tool_mode_key(event: InputEventKey, own_digit: int, cancel_gesture: Callable, exit: Callable) -> int:
	if not event.pressed or event.echo:
		return -1
	if event.keycode == KEY_ESCAPE:
		if not cancel_gesture.call():
			exit.call()
		update_overlays()
		return AFTER_GUI_INPUT_STOP
	var digit := UBViewportInput.mode_digit(event)
	if digit == 0:
		return -1
	var data: UBMeshData = edited.mesh_data if is_instance_valid(edited) else null
	if digit <= 4:
		exit.call()
		selection.change_mode(digit - 1, data)
		return AFTER_GUI_INPUT_STOP
	exit.call()
	if digit == own_digit:
		update_overlays()
	elif toolbar != null:
		if digit == 5:
			toolbar.press_paint()
		else:
			toolbar.press_material()
	return AFTER_GUI_INPUT_STOP


func _on_blend_material_requested() -> void:
	if not _can_pivot():
		return
	var data := edited.mesh_data
	var faces := _paint_panel_faces()
	var material := UBBlendMaterial.new()
	_commit_topology_op("Assign Blend Material",
		func() -> void: UBOpSetFaceProps.assign_material(data, faces, material))


func _on_invert_alpha_requested() -> void:
	if not _can_pivot():
		return
	var data := edited.mesh_data
	var faces := _paint_panel_faces()
	_commit_topology_op("Invert Alpha",
		func() -> void: UBOpPaint.invert_alpha(data, faces))


func _paint_panel_faces() -> Dictionary:
	var faces := selection.faces.duplicate()
	if faces.is_empty() or selection.mode != UBSelection.Mode.FACE:
		faces = {}
		for fi in edited.mesh_data.faces.size():
			faces[fi] = true
	return faces


func _target_blend_material() -> UBBlendMaterial:
	if not _can_pivot():
		_notify_user("Select a Unibuilder mesh first.")
		return null
	var data := edited.mesh_data
	var faces := selection.faces
	var scoped := selection.mode == UBSelection.Mode.FACE and not faces.is_empty()
	var found: Array[UBBlendMaterial] = []
	for fi in data.faces.size():
		if scoped and not faces.has(fi):
			continue
		var slot: int = data.faces[fi].material_index
		if slot < 0 or slot >= data.material_slots.size():
			continue
		var mat := data.material_slots[slot] as UBBlendMaterial
		if mat != null and not found.has(mat):
			found.append(mat)
	if found.is_empty():
		_notify_user("No blend material on %s. Make one with the paint panel's \"New Blend Material\" first." % ("the selected faces" if scoped else "this mesh"))
		return null
	if found.size() > 1:
		_notify_user("%d different blend materials here. Select faces using just one." % found.size())
		return null
	return found[0]


func _import_blend_layer(layer: int) -> void:
	if _target_blend_material() == null:
		return
	_blend_layer_target = layer
	if _blend_layer_dialog == null or not is_instance_valid(_blend_layer_dialog):
		_blend_layer_dialog = EditorFileDialog.new()
		_blend_layer_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_blend_layer_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_blend_layer_dialog.add_filter("*.tres,*.res,*.material", "Material")
		_blend_layer_dialog.file_selected.connect(_on_blend_layer_source_chosen)
		EditorInterface.get_base_control().add_child(_blend_layer_dialog)
	_blend_layer_dialog.title = "Blend Layer %s from Material" % (
		"B" if layer == UBBlendMaterial.Layer.B else "A")
	_blend_layer_dialog.popup_centered_ratio(0.5)


func _on_blend_layer_source_chosen(path: String) -> void:

	var mat := _target_blend_material()
	if mat == null:
		return
	var src := ResourceLoader.load(path) as BaseMaterial3D
	if src == null:
		_notify_user("%s is not a StandardMaterial3D or ORMMaterial3D." % path)
		return
	var layer := _blend_layer_target
	var name := "Blend Layer %s from Material" % (
		"B" if layer == UBBlendMaterial.Layer.B else "A")
	var ur := get_undo_redo()
	ur.create_action(name)
	ur.add_do_method(mat, "apply_layer", layer, UBBlendMaterial.layer_from_standard(src))
	ur.add_undo_method(mat, "apply_layer", layer, mat.layer_values(layer))
	ur.commit_action()
	print("Unibuilder: %s ← %s" % [name, path])


func _on_face_props_requested(props: Dictionary) -> void:
	if edited == null or edited.mesh_data == null or selection.faces.is_empty():
		return
	var data := edited.mesh_data
	var faces := selection.faces
	_commit_topology_op("Edit Face Properties",
		func() -> void: UBOpSetFaceProps.apply(data, faces, props))


func _ensure_drop_target(surface: Control) -> void:
	if surface == null or surface.has_node("_UBMaterialDrop"):
		return
	var target := UBMaterialDrop.new()
	target.plugin = self

	var parent := surface.get_parent()
	if parent != null:
		for child in parent.get_children():
			if child is SubViewportContainer and child.get_child_count() > 0:
				var vp := child.get_child(0) as SubViewport
				if vp != null:
					target.viewport = vp
					break
	surface.add_child(target)
	target.set_anchors_preset(Control.PRESET_FULL_RECT)
	_drop_targets.append(target)


## Drag lifecycle, reported by the drop targets' NOTIFICATION_DRAG_BEGIN/END.
## Several targets report; the _drag_material guard makes begin/end idempotent.
func material_drag_began(material: Material) -> void:
	if material == null or _drag_material != null:
		return
	_drag_material = material
	_drop_consumed = false
	_snapshot_overrides()


func material_drag_ended() -> void:
	if _drag_material == null:
		return
	if _drop_consumed:
		_restore_preview_overrides()
	_drag_material = null
	_drag_overrides.clear()


func _snapshot_overrides() -> void:
	_drag_overrides.clear()
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var gi := n as GeometryInstance3D
		if gi == null:
			continue
		var entry := {"node": gi, "override": gi.material_override, "surfaces": []}
		var mi := gi as MeshInstance3D
		if mi != null:
			for i in mi.get_surface_override_material_count():
				entry.surfaces.append(mi.get_surface_override_material(i))
		_drag_overrides.append(entry)


func _restore_preview_overrides() -> void:
	for entry in _drag_overrides:
		var gi: GeometryInstance3D = entry.node
		if not is_instance_valid(gi):
			continue
		if gi.material_override == _drag_material and entry.override != _drag_material:
			gi.material_override = entry.override
		var mi := gi as MeshInstance3D
		if mi == null:
			continue
		var stored: Array = entry.surfaces
		for i in mini(stored.size(), mi.get_surface_override_material_count()):
			if (
				mi.get_surface_override_material(i) == _drag_material
				and stored[i] != _drag_material
			):
				mi.set_surface_override_material(i, stored[i])


func _remove_material_drop_targets() -> void:
	for target in _drop_targets:
		if is_instance_valid(target):
			target.queue_free()
	_drop_targets.clear()


func can_drop_material(viewport: SubViewport, position: Vector2, data: Variant) -> bool:
	if edited == null or edited.mesh_data == null:
		return false
	if UBMaterialDrop.extract_material(data) == null:
		return false
	if viewport == null:
		return false
	return UBPicking.pick_face(edited, viewport.get_camera_3d(), position) >= 0


## Assign the dropped material. Face mode: the face under the cursor, or the
## whole selection when that face is part of it. Object, Vertex or Edge mode:
## the whole mesh. Reuses a slot already holding the material, otherwise
## appends one. One undo entry.
func drop_material(viewport: SubViewport, position: Vector2, data: Variant) -> void:
	var material := UBMaterialDrop.extract_material(data)
	if material == null:
		return
	var target := UBPicking.pick_face(edited, viewport.get_camera_3d(), position)
	if target < 0:
		return
	var mesh_data := edited.mesh_data
	var faces: Dictionary
	var action := "Drop Material on Face"
	if selection != null and selection.mode == UBSelection.Mode.FACE:
		faces = selection.faces.duplicate() if selection.faces.has(target) else {target: true}
	else:
		action = "Drop Material on Object"
		faces = {}
		for fi in mesh_data.faces.size():
			faces[fi] = true
	_commit_topology_op(action, func() -> void:
		UBOpSetFaceProps.assign_material(mesh_data, faces, material))
	_drop_consumed = true
	if material_palette != null:
		material_palette.note_used(material)
	_refresh_face_panel()


func _on_slot_material_changed(slot: int, material: Material) -> void:
	if edited == null or edited.mesh_data == null:
		return
	var data := edited.mesh_data
	_commit_topology_op("Edit Material Slot",
		func() -> void:
			while data.material_slots.size() <= slot:
				data.material_slots.append(null)
			data.material_slots[slot] = material)
	if material_palette != null and material != null:
		material_palette.note_used(material)
	_refresh_face_panel()


func _carry_shape_materials(from: UBMeshData, to: UBMeshData) -> void:
	if from.material_slots.is_empty():
		apply_default_material(to)
		return
	to.material_slots = from.material_slots.duplicate()
	var slot: int = from.faces[0].material_index if not from.faces.is_empty() else 0
	for f in from.faces:
		if f.material_index != slot:

			if adjust.is_empty() or not adjust.get("mat_warned", false):
				_notify_user("Rebuilding the shape reset its per-face"
					+ " material assignment to the first face's material.")
				if not adjust.is_empty():
					adjust["mat_warned"] = true
			break
	slot = clampi(slot, 0, to.material_slots.size() - 1)
	for f in to.faces:
		f.material_index = slot


## Apply the palette's default material, if any, to every face of a freshly
## built shape. Used by the draw tool's preview and commit, and by the
## shape-adjust rebuild of a shape that carries no material of its own.
func apply_default_material(data: UBMeshData) -> void:
	if material_palette == null or data == null:
		return
	var mat := material_palette.default_material()
	if mat == null:
		return

	if data.material_slots.is_empty():
		data.material_slots.append(mat)
		for f in data.faces:
			f.material_index = 0
		return
	var faces := {}
	for fi in data.faces.size():
		faces[fi] = true
	UBOpSetFaceProps.assign_material(data, faces, mat)


func _on_palette_apply(material: Material) -> void:
	if edited == null or edited.mesh_data == null or material == null:
		return
	var mesh_data := edited.mesh_data
	var faces := {}
	if selection != null and selection.mode == UBSelection.Mode.FACE and not selection.faces.is_empty():
		faces = selection.faces.duplicate()
	else:
		for fi in mesh_data.faces.size():
			faces[fi] = true
	_commit_topology_op("Apply Palette Material", func() -> void:
		UBOpSetFaceProps.assign_material(mesh_data, faces, material))
	material_palette.note_used(material)
	_refresh_face_panel()


func _sync_native_gizmo_lock() -> void:
	var target: UBMeshInstance3D = null

	if is_instance_valid(edited) and input != null and input._object_mode_active():
		target = edited

	if _lock_desired == target:
		return
	_lock_desired = target
	var meta_changed := false
	if is_instance_valid(_lock_target):
		_lock_target.set_plugin_lock(false)
		meta_changed = true
	_lock_target = null

	if target != null and not target.has_foreign_lock():
		target.set_plugin_lock(true)
		_lock_target = target
		meta_changed = true
	if meta_changed:
		EditorInterface.get_selection().selection_changed.emit()


func _on_grow() -> void:
	_apply_grow_shrink(true)


func _on_shrink() -> void:
	_apply_grow_shrink(false)


func _on_select_all() -> void:
	if edited == null or edited.mesh_data == null or selection.mode == UBSelection.Mode.OBJECT:
		return
	var data := edited.mesh_data
	match selection.mode:
		UBSelection.Mode.VERTEX:
			var verts := {}
			for vi in data.positions.size():
				verts[vi] = true
			selection.vertices = verts
		UBSelection.Mode.EDGE:
			var topo := UBTopology.build(data)
			var edges := {}
			for e: Vector2i in topo.edge_faces:
				edges[e] = true
			selection.edges = edges
		UBSelection.Mode.FACE:
			var faces := {}
			for fi in data.faces.size():
				faces[fi] = true
			selection.faces = faces
	selection.notify()


func _on_invert() -> void:
	if edited == null or edited.mesh_data == null or selection.mode == UBSelection.Mode.OBJECT:
		return
	var data := edited.mesh_data
	match selection.mode:
		UBSelection.Mode.VERTEX:
			var verts := {}
			for vi in data.positions.size():
				if not selection.vertices.has(vi):
					verts[vi] = true
			selection.vertices = verts
		UBSelection.Mode.EDGE:
			var topo := UBTopology.build(data)
			var edges := {}
			for e: Vector2i in topo.edge_faces:
				if not selection.edges.has(e):
					edges[e] = true
			selection.edges = edges
		UBSelection.Mode.FACE:
			var faces := {}
			for fi in data.faces.size():
				if not selection.faces.has(fi):
					faces[fi] = true
			selection.faces = faces
	selection.notify()


func _apply_grow_shrink(grow: bool) -> void:
	if edited == null or edited.mesh_data == null or selection.count() == 0:
		return
	var data := edited.mesh_data
	var topo := UBTopology.build(data)
	match selection.mode:
		UBSelection.Mode.VERTEX:
			selection.vertices = (
				UBSelectQueries.grow_vertices(topo, selection.vertices) if grow
				else UBSelectQueries.shrink_vertices(topo, selection.vertices))
		UBSelection.Mode.EDGE:
			selection.edges = (
				UBSelectQueries.grow_edges(topo, selection.edges) if grow
				else UBSelectQueries.shrink_edges(topo, selection.edges))
		UBSelection.Mode.FACE:
			var p: Dictionary = prefs if prefs is Dictionary else {}
			var angle: float = p.get("grow_angle", UBGizmoPlugin.DEFAULTS.grow_angle)
			selection.faces = (
				UBSelectQueries.grow_faces(data, topo, selection.faces, angle) if grow
				else UBSelectQueries.shrink_faces(data, topo, selection.faces))
	selection.notify()
