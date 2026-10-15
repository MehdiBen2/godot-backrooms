@tool
class_name UBPaintPanel
extends PanelContainer
## Palette for the vertex-paint mode: Brush/Fill choice, active colour, channel
## mode (RGBA, RGB only, or Alpha only with a 0-1 slider), brush radius,
## strength and softness, and eight swatches. Click a swatch to apply it,
## Ctrl+click to store the current colour. Swatches, brush settings and the
## Brush/Fill choice persist with the grid state. "New Blend Material" creates
## the dual-texture workflow's material in one click; "Invert Alpha" flips a
## painted blend mask so the two layers swap.

signal palette_changed
## Brush/Fill switched. The viewport's paint feedback (reticle, or face
## highlight plus wireframe) swaps at once rather than on the next mouse move.
signal fill_changed
signal blend_material_requested
signal invert_alpha_requested

const SWATCH_COUNT := 8
const DEFAULT_SWATCHES: Array[Color] = [
	Color.WHITE, Color(0.9, 0.2, 0.2), Color(0.2, 0.8, 0.3), Color(0.25, 0.5, 0.95),
	Color(0.95, 0.75, 0.15), Color(0.6, 0.3, 0.8), Color(0.15, 0.8, 0.75), Color(0.15, 0.15, 0.17),
]

const SCENE := "res://addons/unibuilder/editor/paint_panel.tscn"

var _picker: ColorPickerButton
var _brush_button: Button
var _fill_button: Button
var _mode: OptionButton
var _alpha: HSlider
var _alpha_row: HBoxContainer
var _swatch_buttons: Array[Button] = []
var _swatch_colors: Array[Color] = []
var _radius: SpinBox
var _strength: HSlider
var _softness: HSlider


## The one way to make this control (plugin and tests both use it): the
## layout lives in paint_panel.tscn, and the editor-dependent dressing is
## applied here rather than on instantiation, so opening the scene in the
## editor and saving it never bakes run-time styling into the file.
static func create() -> UBPaintPanel:
	var panel := (load(SCENE) as PackedScene).instantiate() as UBPaintPanel
	panel._dress()
	return panel


func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_bind()


func _bind() -> void:
	_picker = %Picker
	_mode = %Mode
	_alpha = %Alpha
	_alpha_row = %AlphaRow
	_radius = %Radius
	_strength = %Strength
	_softness = %Softness

	_brush_button = %BrushButton
	_fill_button = %FillButton
	for b: Button in [_brush_button, _fill_button]:
		b.pressed.connect(func() -> void:
			_sync_apply()
			palette_changed.emit()
			fill_changed.emit())

	_mode.item_selected.connect(func(_i: int) -> void: _sync_mode())
	_radius.value_changed.connect(func(_v: float) -> void: palette_changed.emit())
	_save_on_release(_strength)
	_save_on_release(_softness)

	for b in %SwatchRow.get_children():
		var idx := _swatch_buttons.size()
		(b as Button).pressed.connect(func() -> void: _on_swatch(idx))
		_swatch_buttons.append(b)

	_swatch_colors.assign(DEFAULT_SWATCHES)

	%BlendButton.pressed.connect(func() -> void: blend_material_requested.emit())
	%InvertButton.pressed.connect(func() -> void: invert_alpha_requested.emit())


func _dress() -> void:
	UBPanelStyle.scale_layout(self)
	UBPanelStyle.style_header(%Header, %HeaderIcon, %HeaderTitle, "paint")
	UBOverlayToolbar.dim_toggle(_brush_button)
	UBOverlayToolbar.dim_toggle(_fill_button)
	for i in SWATCH_COUNT:
		_apply_swatch_style(i)


func _save_on_release(slider: HSlider) -> void:
	var dragging := [false]
	slider.drag_started.connect(func() -> void: dragging[0] = true)
	slider.drag_ended.connect(func(value_changed: bool) -> void:
		dragging[0] = false
		if value_changed:
			palette_changed.emit())
	slider.value_changed.connect(func(_v: float) -> void:
		if not dragging[0]:
			palette_changed.emit())


func _sync_mode() -> void:
	_alpha_row.visible = _mode.selected == 2


func _sync_apply() -> void:
	var brush := not fill_mode()
	_radius.editable = brush
	_strength.editable = brush
	_softness.editable = brush


func fill_mode() -> bool:
	return _fill_button != null and _fill_button.button_pressed


func _on_swatch(idx: int) -> void:

	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META):
		_swatch_colors[idx] = _picker.color
		_apply_swatch_style(idx)
		palette_changed.emit()
	else:
		_picker.color = _swatch_colors[idx]


func _apply_swatch_style(idx: int) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(_swatch_colors[idx], 1.0)
	style.set_corner_radius_all(3)
	for state in ["normal", "hover", "pressed"]:
		_swatch_buttons[idx].add_theme_stylebox_override(state, style)


func paint_color() -> Color:
	if _mode.selected == 2:
		return Color(0.0, 0.0, 0.0, _alpha.value)
	return _picker.color


func paint_mask() -> int:
	return [UBOpPaint.MASK_RGBA, UBOpPaint.MASK_RGB, UBOpPaint.MASK_A][_mode.selected]


func set_paint_color(c: Color) -> void:
	_picker.color = c
	if _mode.selected == 2:
		_alpha.set_value_no_signal(c.a)


func brush_radius() -> float:
	return _radius.value


func brush_strength() -> float:
	return _strength.value


func brush_softness() -> float:
	return _softness.value


func get_brush() -> Dictionary:
	return {"radius": _radius.value, "strength": _strength.value,
		"softness": _softness.value, "fill": fill_mode()}


func set_brush(brush: Dictionary) -> void:
	_radius.set_value_no_signal(brush.get("radius", 0.5))
	_strength.set_value_no_signal(brush.get("strength", 1.0))
	_softness.set_value_no_signal(brush.get("softness", 0.5))
	var fill: bool = brush.get("fill", false)
	_fill_button.set_pressed_no_signal(fill)
	_brush_button.set_pressed_no_signal(not fill)
	_sync_apply()


func get_swatches() -> PackedColorArray:
	return PackedColorArray(_swatch_colors)


func set_swatches(colors: Array) -> void:
	_swatch_colors.clear()
	for i in SWATCH_COUNT:
		_swatch_colors.append(colors[i] if i < colors.size() else Color.WHITE)
		_apply_swatch_style(i)
