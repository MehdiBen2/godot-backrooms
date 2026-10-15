@tool
class_name UBVertexPanel
extends PanelContainer
## Selection info panel: what is selected plus its world and local coordinates.
## Single selections get per-element details (position, edge length, face
## center, normal and area); larger ones get the centroid and bounds. With
## exactly one vertex selected the world X/Y/Z rows are editable, and every
## committed edit is one undo entry (the plugin owns the mutation). Values are
## shown in read-only fields so they can be copied.

## One world axis (0 X, 1 Y, 2 Z) of the single selected vertex was edited.
## Only the CHANGED axis travels: the fields hold values quantized to their
## 0.001 step, so re-emitting all three moved the vertex on the two axes the
## user never touched (an X of 0.70710678 came back as 0.707).
signal position_committed(axis: int, value: float)

const SCENE := "res://addons/unibuilder/editor/vertex_panel.tscn"

var _summary: Label
var _spin_rows: VBoxContainer
var _spins: Array[SpinBox] = []
var _info_rows: VBoxContainer


var _info_fields: Array[LineEdit] = []
var _info_labels := PackedStringArray()
var _updating := false


## The one way to make this control (plugin and tests both use it): the
## layout lives in vertex_panel.tscn, and the editor-dependent dressing is
## applied here rather than on instantiation, so opening the scene in the
## editor and saving it never bakes run-time styling into the file.
static func create() -> UBVertexPanel:
	var panel := (load(SCENE) as PackedScene).instantiate() as UBVertexPanel
	panel._dress()
	return panel


func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_summary = %Summary
		_spin_rows = %SpinRows
		_info_rows = %InfoRows
		_spins.assign([%X, %Y, %Z])
		for axis in 3:
			_spins[axis].value_changed.connect(_emit.bind(axis))


func _dress() -> void:
	UBPanelStyle.float_card(self)
	UBPanelStyle.scale_layout(self)
	custom_minimum_size.x *= EditorInterface.get_editor_scale()
	UBPanelStyle.style_header(%Header, %HeaderIcon, %HeaderTitle, "select_all")


func _emit(value: float, axis: int) -> void:
	if _updating:
		return
	position_committed.emit(axis, value)


func set_position_value(world_pos: Vector3) -> void:
	_updating = true
	for i in 3:
		_spins[i].set_value_no_signal(snappedf(world_pos[i], 0.001))
	_updating = false


## Selections above this size report their count and skip the per-element
## maths. The readout refreshes on every data change, including every frame
## of a gizmo drag, and walks the whole selection, face areas included.
const MAX_DETAIL_ELEMENTS := 2000


## Refresh the readout for the current selection. The position fields are
## editable only when exactly one vertex is selected.
func show_selection(data: UBMeshData, sel, xf: Transform3D) -> void:
	if sel.count() > MAX_DETAIL_ELEMENTS:
		_spin_rows.visible = false
		_summary.text = "%d elements selected" % sel.count()
		_set_info_rows([])
		return
	var rows: Array = []
	match sel.mode:
		UBSelection.Mode.VERTEX:
			var count: int = sel.vertices.size()
			_spin_rows.visible = count == 1
			if count == 1:
				var vi: int = sel.vertices.keys()[0]
				_summary.text = "1 vertex (world, editable)"
				set_position_value(xf * data.positions[vi])
				rows.append(["Local", _fmt(data.positions[vi])])
			else:
				_summary.text = "%d vertices" % count
				var pts := _vertex_points(data, sel.vertices.keys())
				_append_aggregate(rows, pts, xf)
		UBSelection.Mode.EDGE:
			_spin_rows.visible = false
			var count: int = sel.edges.size()
			var total := 0.0
			for e: Vector2i in sel.edges:
				total += (xf * data.positions[e.x]).distance_to(xf * data.positions[e.y])
			if count == 1:
				var e: Vector2i = sel.edges.keys()[0]
				_summary.text = "1 edge"
				var mid_local: Vector3 = (data.positions[e.x] + data.positions[e.y]) * 0.5
				rows.append(["Length", "%.3f" % total])
				rows.append(["Mid W", _fmt(xf * mid_local)])
				rows.append(["Mid L", _fmt(mid_local)])
			else:
				_summary.text = "%d edges" % count
				rows.append(["Total len", "%.3f" % total])
				var verts := {}
				for e: Vector2i in sel.edges:
					verts[e.x] = true
					verts[e.y] = true
				_append_aggregate(rows, _vertex_points(data, verts.keys()), xf)
		UBSelection.Mode.FACE:
			_spin_rows.visible = false
			var count: int = sel.faces.size()
			var area := 0.0
			for fi in sel.faces:
				area += _world_face_area(data, fi, xf)
			if count == 1:
				var fi: int = sel.faces.keys()[0]
				var face: UBFace = data.faces[fi]
				_summary.text = "1 face (%d corners)" % face.vertices.size()
				var center_local := Vector3.ZERO
				for vi in face.vertices:
					center_local += data.positions[vi]
				center_local /= face.vertices.size()
				rows.append(["Center W", _fmt(xf * center_local)])
				rows.append(["Center L", _fmt(center_local)])
				rows.append(["Normal", _fmt((xf.basis * data.face_normal(face)).normalized())])
				rows.append(["Area", "%.3f" % area])
			else:
				_summary.text = "%d faces" % count
				rows.append(["Total area", "%.3f" % area])
				var verts := {}
				for fi in sel.faces:
					for vi in data.faces[fi].vertices:
						verts[vi] = true
				_append_aggregate(rows, _vertex_points(data, verts.keys()), xf)
		_:
			_spin_rows.visible = false
			_summary.text = ""
	_set_info_rows(rows)


func _set_info_rows(rows: Array) -> void:
	var same := rows.size() == _info_labels.size()
	if same:
		for i in rows.size():
			if rows[i][0] != _info_labels[i]:
				same = false
				break
	if same:
		for i in rows.size():
			var field := _info_fields[i]
			if field.has_focus():
				continue
			if field.text != rows[i][1]:
				field.text = rows[i][1]
		return
	for child in _info_rows.get_children():
		child.queue_free()
	_info_fields.clear()
	_info_labels.clear()
	for entry in rows:
		var field := LineEdit.new()
		field.editable = false
		field.flat = true
		field.text = entry[1]
		field.tooltip_text = "Read-only; select to copy"
		UBPanelStyle.row(_info_rows, entry[0], field, 62.0)
		_info_fields.append(field)
		_info_labels.append(entry[0])


static func _vertex_points(data: UBMeshData, indices: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for vi in indices:
		if vi >= 0 and vi < data.positions.size():
			out.append(data.positions[vi])
	return out


func _append_aggregate(rows: Array, local_pts: PackedVector3Array, xf: Transform3D) -> void:
	if local_pts.is_empty():
		return
	var centroid := Vector3.ZERO
	var lo := xf * local_pts[0]
	var hi := lo
	for p in local_pts:
		centroid += p
		var wp := xf * p
		lo = lo.min(wp)
		hi = hi.max(wp)
	centroid /= local_pts.size()
	rows.append(["Center W", _fmt(xf * centroid)])
	rows.append(["Center L", _fmt(centroid)])
	rows.append(["Size", _fmt(hi - lo)])


static func _world_face_area(data: UBMeshData, fi: int, xf: Transform3D) -> float:
	var pts := PackedVector3Array()
	for vi in data.faces[fi].vertices:
		pts.append(xf * data.positions[vi])
	return UBTriangulate.newell_normal(pts).length() * 0.5


static func _fmt(v: Vector3) -> String:
	return "%.3f, %.3f, %.3f" % [v.x, v.y, v.z]
