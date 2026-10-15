@tool
class_name UBFacePanel
extends PanelContainer
## Face properties panel, shown at the viewport's right edge in Face mode:
## material slots, auto-UV settings, face colour, smoothing group. Emits
## requests; plugin.gd owns the undo-wrapped application. Widget values
## reflect the first selected face; edits apply to the whole selection live.

## Apply these properties to the selected faces.
signal props_requested(props: Dictionary)
## Assign a material resource into a slot of the edited mesh.
signal slot_material_changed(slot: int, material: Material)

var current_slot := 0

var _slot_option: OptionButton
var _picker: EditorResourcePicker
var _offset_u: SpinBox
var _offset_v: SpinBox
var _rotation: SpinBox
var _scale_u: SpinBox
var _scale_v: SpinBox
var _scale_link: Button
var _world_space: CheckBox
## Projection dropdown: UBOpSetFaceProps.UVProjection order, then this extra item.
const PROJECTION_CUSTOM := 4
var _projection: OptionButton
var _color: ColorPickerButton
var _smoothing: SpinBox

var _refreshing := false


const SCENE := "res://addons/unibuilder/editor/face_panel.tscn"


## The one way to make this control (plugin and tests both use it): the
## layout lives in face_panel.tscn, and the editor-dependent dressing is
## applied here rather than on instantiation, so opening the scene in the
## editor and saving it never bakes run-time styling into the file.
static func create() -> UBFacePanel:
	var panel := (load(SCENE) as PackedScene).instantiate() as UBFacePanel
	panel._dress()
	return panel


func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_bind()


func _bind() -> void:
	_slot_option = %SlotOption
	_picker = %Picker
	_offset_u = %OffsetU
	_offset_v = %OffsetV
	_rotation = %Rotation
	_scale_u = %ScaleU
	_scale_v = %ScaleV
	_scale_link = %ScaleLink
	_projection = %Projection
	_world_space = %WorldSpace
	_color = %Color
	_smoothing = %Smoothing

	_slot_option.item_selected.connect(func(idx: int) -> void:
		current_slot = idx
		_emit_slot_to_picker.call_deferred())
	%AddSlot.pressed.connect(_add_slot)
	_picker.resource_changed.connect(func(res: Resource) -> void:
		if not _refreshing:
			slot_material_changed.emit(current_slot, res as Material))
	%ApplyMaterial.pressed.connect(func() -> void:
		props_requested.emit({"material_index": current_slot}))

	_offset_u.value_changed.connect(func(v: float) -> void: _emit({"uv_offset_u": v}))
	_offset_v.value_changed.connect(func(v: float) -> void: _emit({"uv_offset_v": v}))
	_rotation.value_changed.connect(func(v: float) -> void: _emit({"uv_rotation": v}))
	_scale_u.value_changed.connect(func(_v: float) -> void: _on_tiling_changed(_scale_u, _scale_v))
	_scale_v.value_changed.connect(func(_v: float) -> void: _on_tiling_changed(_scale_v, _scale_u))

	_scale_link.toggled.connect(func(on: bool) -> void:
		if on and _tiling_unequal():
			_scale_v.set_value_no_signal(_scale_u.value)
			_emit({"uv_scale_equalize": true}))

	%TileHalve.pressed.connect(_scale_tiling.bind(0.5))
	%TileDouble.pressed.connect(_scale_tiling.bind(2.0))

	_projection.item_selected.connect(func(index: int) -> void:
		if index != PROJECTION_CUSTOM:
			_emit({"uv_projection": index}))
	_world_space.toggled.connect(func(on: bool) -> void: _emit({"uv_world_space": on}))

	_color.popup_closed.connect(func() -> void: _emit({"color": _color.color}))
	_smoothing.value_changed.connect(func(v: float) -> void: _emit({"smoothing_group": int(v)}))


func _dress() -> void:
	for spin: SpinBox in [_offset_u, _offset_v, _scale_u, _scale_v]:
		UBAdjustPanel.free_float_field(spin, spin.custom_arrow_step)
	UBPanelStyle.scale_layout(self)
	UBPanelStyle.style_header(%Header, %HeaderIcon, %HeaderTitle, "mode_face")
	UBOverlayToolbar._iconify(_scale_link, "link", "=")
	UBOverlayToolbar.dim_toggle(_scale_link)


## Populate the widgets from the first selected face, without emitting.
func set_from(data, face_set: Dictionary) -> void:
	_refreshing = true
	_refresh_slots(data)
	_last_faces = face_set
	if not face_set.is_empty():
		var fi: int = face_set.keys().min()
		if fi >= 0 and fi < data.faces.size():
			var f: UBFace = data.faces[fi]
			_offset_u.set_value_no_signal(UBAdjustPanel.display_value(f.uv_offset.x))
			_offset_v.set_value_no_signal(UBAdjustPanel.display_value(f.uv_offset.y))
			_rotation.set_value_no_signal(f.uv_rotation)
			_scale_u.set_value_no_signal(UBAdjustPanel.display_value(f.uv_scale.x))
			_scale_v.set_value_no_signal(UBAdjustPanel.display_value(f.uv_scale.y))
			_world_space.set_pressed_no_signal(f.uv_world_space)
			var projection := UBOpSetFaceProps.projection_of(f)
			_projection.select(projection if projection >= 0 else PROJECTION_CUSTOM)
			_color.color = f.color
			_smoothing.set_value_no_signal(f.smoothing_group)
			if f.material_index >= 0 and f.material_index < _slot_option.item_count:
				current_slot = f.material_index
				_slot_option.select(current_slot)
	_sync_picker(data)
	_refreshing = false


func _refresh_slots(data) -> void:
	_slot_option.clear()
	var count: int = maxi(1, data.material_slots.size())
	for i in count:
		var mat: Material = data.material_slots[i] if i < data.material_slots.size() else null
		var name := "empty" if mat == null else mat.resource_path.get_file()
		if mat != null and name.is_empty():
			name = "built-in"
		_slot_option.add_item("%d: %s" % [i, name])
	current_slot = clampi(current_slot, 0, count - 1)
	_slot_option.select(current_slot)
	_last_data = data


var _last_data

var _last_faces := {}


func _add_slot() -> void:
	current_slot = _last_data.material_slots.size() if _last_data != null else _slot_option.item_count
	slot_material_changed.emit(current_slot, null)


func _sync_picker(data) -> void:
	_picker.edited_resource = (
		data.material_slots[current_slot]
		if current_slot < data.material_slots.size() else null)


func _emit_slot_to_picker() -> void:
	if _last_data != null:
		_refreshing = true
		_sync_picker(_last_data)
		_refreshing = false


func _emit(props: Dictionary) -> void:
	if not _refreshing:
		props_requested.emit(props)


func _tiling_unequal() -> bool:
	if _last_data == null:
		return not is_equal_approx(_scale_v.value, _scale_u.value)
	for fi in UBOpUtils.valid_faces(_last_data, _last_faces):
		var s: Vector2 = _last_data.faces[fi].uv_scale
		if s.x != s.y:
			return true
	return false


func _on_tiling_changed(changed: SpinBox, other: SpinBox) -> void:
	var linked := _scale_link != null and _scale_link.button_pressed
	if linked and not is_equal_approx(other.value, changed.value):
		other.set_value_no_signal(changed.value)
	if linked:
		_emit({"uv_scale_u": changed.value, "uv_scale_v": changed.value})
	elif changed == _scale_u:
		_emit({"uv_scale_u": changed.value})
	else:
		_emit({"uv_scale_v": changed.value})


func _scale_tiling(factor: float) -> void:
	var k := Vector2(factor, factor)
	if _last_data != null and not _last_faces.is_empty() \
			and not UBOpSetFaceProps.scale_mul_changes(_last_data, _last_faces, k):
		return
	_scale_u.set_value_no_signal(UBAdjustPanel.display_value(clampf(
		_scale_u.value * factor, UBOpSetFaceProps.UV_SCALE_MIN, UBOpSetFaceProps.UV_SCALE_MAX)))
	_scale_v.set_value_no_signal(UBAdjustPanel.display_value(clampf(
		_scale_v.value * factor, UBOpSetFaceProps.UV_SCALE_MIN, UBOpSetFaceProps.UV_SCALE_MAX)))
	_emit({"uv_scale_mul": k})
