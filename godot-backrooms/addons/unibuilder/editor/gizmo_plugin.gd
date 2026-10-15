@tool
class_name UBGizmoPlugin
extends EditorNode3DGizmoPlugin
## Draws mesh elements over the edited UBMeshInstance3D: wireframe edges in every
## element mode, vertex points in vertex mode, a translucent tint on selected faces.
## Drawing only; input goes through _forward_3d_gui_input. Elements draw x-ray (no
## depth test), while picking stays occlusion-aware. Colors and handle size come
## from the preferences dict via apply_prefs.

## Set by plugin.gd after construction; exposes .selection and .edited.
var plugin: EditorPlugin

## Preference keys and factory defaults; the preferences popup edits overrides.
## Teal wire for unselected elements, amber for selected.
const DEFAULTS := {
	"vertex_size": 8.0,

	"grow_angle": 180.0,

	"lightmap_texel": 0.2,

	"live_uv2": true,
	"color_edge": Color(0.369, 0.918, 0.831, 0.55),
	"color_edge_selected": Color(0.984, 0.749, 0.141, 0.95),
	"color_vertex": Color(0.369, 0.918, 0.831),
	"color_vertex_selected": Color(0.984, 0.749, 0.141),
	"color_face_selected": Color(0.984, 0.749, 0.141, 0.28),
}
## Offset of the selected-face overlay along the face normal, to avoid z-fighting.
const FACE_OFFSET := 0.004


var _tint_suppressed := {}


func suppress_face_tint(key: String, on: bool) -> void:
	if on:
		_tint_suppressed[key] = true
	else:
		_tint_suppressed.erase(key)


func face_tint_hidden() -> bool:
	return not _tint_suppressed.is_empty()

var _edge_material: StandardMaterial3D
var _edge_selected_material: StandardMaterial3D
var _vertex_material: StandardMaterial3D
var _vertex_selected_material: StandardMaterial3D
var _face_material: StandardMaterial3D


func _init() -> void:
	_face_material = StandardMaterial3D.new()
	_face_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_face_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_face_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_face_material.render_priority = 1
	apply_prefs({})


## Rebuilds overlay materials from DEFAULTS overridden by `prefs`. The caller
## refreshes gizmos afterwards.
func apply_prefs(prefs: Dictionary) -> void:
	var p := DEFAULTS.duplicate()
	p.merge(prefs, true)
	_edge_material = _make_line_material(p.color_edge)
	_edge_selected_material = _make_line_material(p.color_edge_selected)
	_vertex_material = _make_point_material(p.color_vertex, p.vertex_size)
	_vertex_selected_material = _make_point_material(p.color_vertex_selected, p.vertex_size + 3.0)
	_face_material.albedo_color = p.color_face_selected


static func _make_line_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	m.no_depth_test = true
	m.render_priority = 1
	return m


func _get_gizmo_name() -> String:
	return "Unibuilder"


func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is UBMeshInstance3D


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()

	if plugin == null or not is_instance_valid(plugin):
		return
	var node := gizmo.get_node_3d() as UBMeshInstance3D
	var sel: UBSelection = plugin.selection
	if node == null or node != plugin.edited or node.mesh_data == null:
		return

	var painting: bool = plugin.paint_tool != null and plugin.paint_tool.active()
	var filling: bool = (
		painting and plugin.paint_panel != null and plugin.paint_panel.fill_mode()
	)
	if sel.mode == UBSelection.Mode.OBJECT and not filling:
		return
	var data: UBMeshData = node.mesh_data

	var topo := UBTopology.build_cached(data)

	var lines := PackedVector3Array()
	var lines_selected := PackedVector3Array()
	for key: Vector2i in topo.edge_faces:
		var selected := sel.mode == UBSelection.Mode.EDGE and sel.edges.has(key)
		var target := lines_selected if selected else lines
		target.append(data.positions[key.x])
		target.append(data.positions[key.y])
	if not lines.is_empty():
		gizmo.add_lines(lines, _edge_material)
	if not lines_selected.is_empty():
		gizmo.add_lines(lines_selected, _edge_selected_material)

	if sel.mode == UBSelection.Mode.VERTEX and not painting:
		var points := PackedVector3Array()
		var points_selected := PackedVector3Array()
		for vi in data.positions.size():
			if sel.vertices.has(vi):
				points_selected.append(data.positions[vi])
			else:
				points.append(data.positions[vi])
		if not points.is_empty():
			gizmo.add_mesh(_points_mesh(points), _vertex_material)
		if not points_selected.is_empty():
			gizmo.add_mesh(_points_mesh(points_selected), _vertex_selected_material)

	if sel.mode == UBSelection.Mode.FACE and not sel.faces.is_empty() and not face_tint_hidden():
		var overlay := _face_overlay_mesh(data, sel.faces)
		if overlay != null:
			gizmo.add_mesh(overlay, _face_material)


static func _make_point_material(color: Color, size: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.use_point_size = true
	m.point_size = size
	m.albedo_color = color
	m.no_depth_test = true
	m.render_priority = 2
	return m


static func _points_mesh(points: PackedVector3Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	return mesh


static func _face_overlay_mesh(data: UBMeshData, selected_faces: Dictionary) -> ArrayMesh:
	var verts := PackedVector3Array()
	for fi in selected_faces:
		if fi < 0 or fi >= data.faces.size():
			continue
		var face := data.faces[fi]
		var normal := data.face_normal(face)
		var corners := PackedVector3Array()
		for vi in face.vertices:
			corners.append(data.positions[vi] + normal * FACE_OFFSET)
		var tris := UBTriangulate.triangulate(corners)
		for t in tris:
			verts.append(corners[t])
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
