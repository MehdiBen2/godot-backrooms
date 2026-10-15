@tool
class_name UBOverlayToolbar
extends HFlowContainer
## Mode switcher plus the selection, grid and shape controls shown above the
## 3D viewport. Emits requests; plugin.gd owns the state changes.
## An HFlowContainer, so buttons wrap instead of widening the window.

signal mode_requested(mode: int)
## Element gizmo switch: 0 move, 1 rotate, 2 scale. Shift+W/E/R also
## route here through plugin.set_gizmo_mode.
signal gizmo_mode_requested(mode: int)
## Gizmo orientation changed; persisted with the grid state.
signal gizmo_changed
signal grow_requested
signal shrink_requested
signal invert_requested
signal select_all_requested
## Vertex-paint mode toggled on or off.
signal paint_toggled(enabled: bool)
## Material mode (the face-UV gizmo) toggled on or off.
signal material_toggled(enabled: bool)
signal action_requested(id: String)
## Any grid setting changed: step, plane, or visibility.
signal grid_changed
## Align Grid button: move the grid plane onto the current element selection.
signal grid_align_requested
## Reset button: return the grid plane offset to zero. Same as the 0 hotkey.
signal grid_reset_requested
## Add-menu shape chosen; the item id matches UBShapeTool.Kind.
signal shape_requested(kind: int)
## Reopen the edited shape's parametric controls in the adjust panel.
signal shape_edit_requested
## Tools-menu entry chosen; ids in TOOL_IDS.
signal tool_requested(id: String)

## A power of two, so halving from 1 reaches it exactly (1/512, the finest
## the fields display exactly: see UBAdjustPanel.free_float_field).
const STEP_MIN := 1.0 / 512.0
const STEP_MAX := 64.0
const PROP_MIN := 0.01
const PROP_MAX := 64.0
## Falloff-curve icon per UBSoftSelect.Falloff value, in enum order.
const FALLOFF_ICONS: PackedStringArray = ["prop_smooth", "prop_sphere", "prop_root",
	"prop_invsquare", "prop_sharp", "prop_linear", "prop_constant"]
const TOOL_IDS := {0: "bake", 1: "export_obj", 2: "convert", 3: "toggle_dims", 4: "preferences",
	5: "center_pivot", 6: "pivot_to_selection", 7: "freeze_transform", 8: "toggle_snap_each",
	9: "merge_objects", 10: "mirror_x", 11: "mirror_y", 12: "mirror_z",
	13: "triangulate_object", 14: "subdivide_object", 15: "conform_normals",
	16: "boolean_union", 17: "boolean_subtract", 18: "boolean_intersect",
	19: "export_gltf", 20: "set_collider", 21: "set_trigger",
	22: "blend_layer_a", 23: "blend_layer_b", 24: "toggle_snap_absolute",
	25: "rebuild_uv2"}
const ICON_DIR := "res://addons/unibuilder/icons/"
## One row per drawable shape: [label, UBShapeTool.Kind, icon name]. Drives
## the Add menu and the repeat-last-shape button.
const SHAPES := [
	["Cube", UBShapeTool.Kind.CUBE, "shape_cube"],
	["Plane", UBShapeTool.Kind.PLANE, "shape_plane"],
	["Cylinder", UBShapeTool.Kind.CYLINDER, "shape_cylinder"],
	["Cone", UBShapeTool.Kind.CONE, "shape_cone"],
	["Prism", UBShapeTool.Kind.PRISM, "shape_prism"],
	["Stairs", UBShapeTool.Kind.STAIRS, "shape_stairs"],
	["Arch", UBShapeTool.Kind.ARCH, "shape_arch"],
	["Door", UBShapeTool.Kind.DOOR, "shape_door"],
	["Sphere", UBShapeTool.Kind.SPHERE, "shape_sphere"],
	["Torus", UBShapeTool.Kind.TORUS, "shape_torus"],
	["Pipe", UBShapeTool.Kind.PIPE, "shape_pipe"],
	["Curved Stairs", UBShapeTool.Kind.CURVED_STAIRS, "shape_curved_stairs"],
	["Wall", UBShapeTool.Kind.WALL, "shape_wall"],
	["Trim", UBShapeTool.Kind.TRIM, "shape_trim"],
	["Trim Walls", UBShapeTool.Kind.TRIM_WALLS, "shape_trim_walls"],
	["Poly Shape", UBShapeTool.Kind.POLY, "shape_poly"],
]

## When true, marquee selects through geometry instead of visible-only.
var xray := false
## Grid snapping for element transforms (Ctrl inverts while dragging).
var snap_enabled := true
## One value drives both the snap increment and the grid density.
var snap_step := 1.0
var grid_visible := true
var grid_axis := 1
## When true, the viewport overlay shows the selection's world-space size.
var dims_visible := false
## When true, element move-drags snap every vertex to the grid individually
## instead of snapping the drag delta as a group.
var snap_each := false
## When true, move-drags land the selection on the grid: its low bounds corner
## snaps to grid lines along the moved axes instead of moving in whole steps
## from where it started. The move stays rigid, unlike snap_each.
var snap_absolute := false
## When true, armed shape draws use the face under the cursor as the drawing
## plane instead of the grid plane.
var draw_on_surface := false
## Kind of the last committed shape; the repeat button re-arms it.
var last_shape_kind: int = UBShapeTool.Kind.CUBE
## Element gizmo: 0 move, 1 rotate, 2 scale. Transient; Shift+W/E/R switch it.
var gizmo_mode := 0
## Gizmo orientation: 0 global, 1 local, 2 normal (persisted).
var gizmo_orient := 0
## Proportional editing (persisted): element transform drags also pull
## unselected vertices within prop_radius, weighted by the chosen falloff curve.
## One dropdown drives both members. Off clears prop_enabled; a mode sets it
## and selects the curve (UBSoftSelect.Falloff).
var prop_enabled := false
var prop_falloff: int = UBSoftSelect.Falloff.SMOOTH
var prop_radius := 2.0

var _mode_buttons: Array[Button] = []


var _synced_mode := 0
var _gizmo_buttons: Array[Button] = []
var _orient_option: OptionButton
var _paint_button: Button
var _material_button: Button
var _tools_popup: PopupMenu
var _actions_sep: VSeparator
var _action_buttons: Array[Dictionary] = []


var _sel_action_buttons: Array[Button] = []
var _step_spin: SpinBox
var _plane_option: OptionButton
var _grid_button: Button
var _surface_button: Button
var _snap_button: Button
var _repeat_button: Button
var _shape_edit_button: Button
var _prop_button: MenuButton
var _prop_spin: SpinBox


static func _icon(name: String, oversample := 1.0) -> Texture2D:
	var path := ICON_DIR + name + ".svg"
	if FileAccess.file_exists(path):
		var img := Image.new()
		var scale := EditorInterface.get_editor_scale() * oversample
		var svg := FileAccess.get_file_as_string(path)
		if editor_is_light():
			svg = recolor_for_light(svg)
		if img.load_svg_from_string(svg, scale) == OK:
			if oversample > 1.0:
				img.generate_mipmaps()
			return ImageTexture.create_from_image(img)
	return load(path) if ResourceLoader.exists(path) else null


## Darker stand-ins for the two brand colours, used only on a light editor.
## The palette is tuned for the dark editor; on a light theme the same teal and
## amber fall far below the 3:1 contrast WCAG 2.1 SC 1.4.11 asks of graphical
## objects. These are darker values of the same hues, so the identity survives
## and both pass against a light panel and against pure white.
const LIGHT_SWAP := {
	"#5eead4": "#0d6e63",
	"#fbbf24": "#92400e",
}

## Returns [param svg] with the brand colours swapped per LIGHT_SWAP. Known
## cosmetic compromise: logo.svg already fills its shaded facet with #0d6e63,
## the colour the primary teal becomes here, so on a light editor the logo's
## dashed top-face outline merges with that facet along their shared edge.
static func recolor_for_light(svg: String) -> String:
	for from: String in LIGHT_SWAP:
		svg = svg.replace(from, LIGHT_SWAP[from])
	return svg


## True when the editor's base colour is bright. Reads the setting rather than
## the theme so it works before the theme is built. Icons are made once at
## toolbar construction, so a theme switch needs a plugin reload to take effect.
static func editor_is_light() -> bool:
	var settings := EditorInterface.get_editor_settings()
	if settings == null:
		return false
	var base: Variant = settings.get_setting("interface/theme/base_color")
	return base is Color and (base as Color).get_luminance() > 0.5


static func _iconify(b: Button, icon_name: String, fallback_text: String) -> void:
	var tex := _icon(icon_name)
	if tex != null:
		b.icon = tex
		b.text = ""
	else:
		b.text = fallback_text


## Dim a toggle button's glyph while it is off and restore it while on. The
## editor's pressed stylebox alone is too subtle to read at a glance.
static func dim_toggle(b: Button) -> void:

	b.add_theme_color_override("icon_normal_color", Color(1, 1, 1, 0.35))
	b.add_theme_color_override("icon_hover_color", Color(1, 1, 1, 0.6))
	b.add_theme_color_override("icon_pressed_color", Color.WHITE)
	b.add_theme_color_override("icon_hover_pressed_color", Color.WHITE)

	var fc := EditorInterface.get_base_control().get_theme_color("font_color", "Button")
	b.add_theme_color_override("font_color", Color(fc, fc.a * 0.4))
	b.add_theme_color_override("font_hover_color", Color(fc, fc.a * 0.65))


const SCENE := "res://addons/unibuilder/editor/overlay_toolbar.tscn"


## The one way to make this control (plugin and tests both use it). The fixed
## layout lives in overlay_toolbar.tscn; load(), not preload(), since the
## scene references this script. The dressing runs here rather than on
## NOTIFICATION_SCENE_INSTANTIATED: the script is @tool, so that notification
## also fires when the scene is opened in the editor, and a save there would
## bake the rasterized icons and theme colours into the file.
static func create() -> UBOverlayToolbar:
	var toolbar := (load(SCENE) as PackedScene).instantiate() as UBOverlayToolbar
	toolbar._setup()
	return toolbar


func _setup() -> void:

	var pad: Control = %Pad
	pad.custom_minimum_size.x *= EditorInterface.get_editor_scale()

	(%Logo as TextureRect).texture = _icon("logo")
	var wordmark: TextureRect = %Wordmark
	var wm_tex := _icon("wordmark", 4.0)
	wordmark.texture = wm_tex
	if wm_tex != null:
		wordmark.custom_minimum_size = wm_tex.get_size() / 4.0

	var demo_chip: Button = %DemoChip
	if UBEdition.DEMO:
		var amber := Color("#92400e") if editor_is_light() else Color("#fbbf24")
		demo_chip.add_theme_color_override("font_color", amber)
		demo_chip.add_theme_color_override("font_hover_color", amber.lightened(0.2))
		demo_chip.add_theme_color_override("font_pressed_color", amber)
		demo_chip.add_theme_color_override("font_focus_color", amber)
		demo_chip.pressed.connect(func() -> void: OS.shell_open(UBEdition.STORE_URL))
	else:
		remove_child(demo_chip)
		demo_chip.free()

	var add_menu: MenuButton = %AddMenu
	_iconify(add_menu, "add", add_menu.text)
	var popup := add_menu.get_popup()
	for entry in SHAPES:
		var tex := _icon(entry[2])
		if tex != null:
			popup.add_icon_item(tex, entry[0], entry[1])
		else:
			popup.add_item(entry[0], entry[1])
	popup.id_pressed.connect(func(id: int) -> void: shape_requested.emit(id))

	_repeat_button = %RepeatShape
	_repeat_button.pressed.connect(func() -> void: shape_requested.emit(last_shape_kind))
	set_last_shape(last_shape_kind)

	_shape_edit_button = %EditShape
	_iconify(_shape_edit_button, "shape_params", _shape_edit_button.text)
	_shape_edit_button.pressed.connect(func() -> void: shape_edit_requested.emit())
	sync_shape_edit(false, false)

	var tools_menu: MenuButton = %ToolsMenu
	_iconify(tools_menu, "tools", tools_menu.text)
	_tools_popup = tools_menu.get_popup()
	_tools_popup.id_pressed.connect(_on_tools_menu)

	_mode_buttons.assign([%ModeObject, %ModeVertex, %ModeEdge, %ModeFace])
	_paint_button = %ModePaint
	_material_button = %ModeMaterial
	_gizmo_buttons.assign([%GizmoMove, %GizmoRotate, %GizmoScale])
	for pair in [
		[%ModeObject, "mode_object"], [%ModeVertex, "mode_vertex"],
		[%ModeEdge, "mode_edge"], [%ModeFace, "mode_face"],
		[_paint_button, "paint"], [_material_button, "mode_material"],
		[%GizmoMove, "gizmo_move"], [%GizmoRotate, "gizmo_rotate"],
		[%GizmoScale, "gizmo_scale"],
	]:
		var b: Button = pair[0]
		_iconify(b, pair[1], b.text)
		dim_toggle(b)
	for i in _mode_buttons.size():
		var mode := i
		_mode_buttons[i].pressed.connect(func() -> void: mode_requested.emit(mode))
	_paint_button.toggled.connect(func(on: bool) -> void: paint_toggled.emit(on))
	_material_button.toggled.connect(func(on: bool) -> void: material_toggled.emit(on))
	for i in _gizmo_buttons.size():
		var mode := i
		_gizmo_buttons[i].pressed.connect(func() -> void: gizmo_mode_requested.emit(mode))

	_orient_option = %Orientation
	_orient_option.item_selected.connect(func(idx: int) -> void:
		gizmo_orient = idx
		gizmo_changed.emit())

	_prop_button = %Proportional
	var prop_popup := _prop_button.get_popup()

	var prop_items: Array = [["Off", "prop_off"]]
	for i in UBSoftSelect.FALLOFF_NAMES.size():
		prop_items.append([UBSoftSelect.FALLOFF_NAMES[i], FALLOFF_ICONS[i]])
	for id in prop_items.size():
		var tex := _icon(prop_items[id][1])
		if tex != null:
			prop_popup.add_icon_radio_check_item(tex, prop_items[id][0], id)
		else:
			prop_popup.add_radio_check_item(prop_items[id][0], id)
	prop_popup.id_pressed.connect(func(id: int) -> void:
		prop_enabled = id > 0
		if id > 0:
			prop_falloff = id - 1
		_sync_prop_ui())
	_sync_prop_ui()

	_prop_spin = %PropRadius
	_prop_spin.value_changed.connect(func(v: float) -> void: prop_radius = v)

	var grow: Button = %Grow
	var shrink: Button = %Shrink
	var select_all: Button = %SelectAll
	var invert: Button = %Invert
	_sel_action_buttons.assign([grow, shrink, select_all, invert])
	for pair in [[grow, "grow"], [shrink, "shrink"], [select_all, "select_all"],
			[invert, "invert"]]:
		var b: Button = pair[0]
		_iconify(b, pair[1], b.text)
	grow.pressed.connect(func() -> void: grow_requested.emit())
	shrink.pressed.connect(func() -> void: shrink_requested.emit())
	select_all.pressed.connect(func() -> void: select_all_requested.emit())
	invert.pressed.connect(func() -> void: invert_requested.emit())

	var x: Button = %XRay
	_iconify(x, "xray", x.text)
	dim_toggle(x)
	x.toggled.connect(func(on: bool) -> void: xray = on)

	_snap_button = %Snap
	_iconify(_snap_button, "snap", _snap_button.text)
	dim_toggle(_snap_button)
	_snap_button.toggled.connect(func(on: bool) -> void: snap_enabled = on)

	_step_spin = %Step

	UBAdjustPanel.free_float_field(_step_spin, 0.001)
	_step_spin.value = snap_step
	_step_spin.value_changed.connect(func(v: float) -> void:
		snap_step = v
		grid_changed.emit())

	var halve: Button = %StepHalve
	var double_step: Button = %StepDouble
	_iconify(halve, "step_halve", halve.text)
	_iconify(double_step, "step_double", double_step.text)
	halve.pressed.connect(func() -> void: scale_step(0.5))
	double_step.pressed.connect(func() -> void: scale_step(2.0))

	_plane_option = %GridPlane
	_plane_option.item_selected.connect(func(idx: int) -> void:
		grid_axis = idx
		grid_changed.emit())

	_grid_button = %Grid
	_iconify(_grid_button, "grid", _grid_button.text)
	dim_toggle(_grid_button)
	_grid_button.toggled.connect(func(on: bool) -> void:
		grid_visible = on
		grid_changed.emit())

	_surface_button = %Surface
	_iconify(_surface_button, "surface_draw", _surface_button.text)
	dim_toggle(_surface_button)
	_surface_button.toggled.connect(func(on: bool) -> void:
		draw_on_surface = on
		grid_changed.emit())

	var align: Button = %GridAlign
	_iconify(align, "grid_align", align.text)
	align.pressed.connect(func() -> void: grid_align_requested.emit())

	var grid_reset: Button = %GridReset
	_iconify(grid_reset, "grid_reset", grid_reset.text)
	grid_reset.pressed.connect(func() -> void: grid_reset_requested.emit())

	_actions_sep = %ActionsSeparator
	for action in UBActions.list():
		var b := Button.new()
		_iconify(b, action.id, action.label)
		b.tooltip_text = action.tooltip
		b.focus_mode = Control.FOCUS_NONE
		b.visible = false
		var id: String = action.id
		b.pressed.connect(func() -> void: action_requested.emit(id))
		add_child(b)
		_action_buttons.append({"button": b, "mode": action.mode})


func _on_tools_menu(id: int) -> void:
	if id == 3:
		dims_visible = not dims_visible
		_tools_popup.set_item_checked(_tools_popup.get_item_index(3), dims_visible)
	elif id == 8:
		snap_each = not snap_each
		_tools_popup.set_item_checked(_tools_popup.get_item_index(8), snap_each)
	elif id == 24:
		snap_absolute = not snap_absolute
		_tools_popup.set_item_checked(_tools_popup.get_item_index(24), snap_absolute)
	tool_requested.emit(TOOL_IDS[id])


## Point the repeat button at a shape kind; its icon and tooltip follow.
func set_last_shape(kind: int) -> void:
	for entry in SHAPES:
		if entry[1] == kind:
			last_shape_kind = kind
			if _repeat_button != null:
				_iconify(_repeat_button, entry[2], entry[0])
				_repeat_button.tooltip_text = "Draw another %s" % entry[0]
			return


## Shape-parameters button state: shown while a UB mesh is edited, enabled only
## while that mesh is still what its shape parameters build.
func sync_shape_edit(shown: bool, editable: bool) -> void:
	if _shape_edit_button == null:
		return
	_shape_edit_button.visible = shown
	_shape_edit_button.disabled = not editable
	_shape_edit_button.tooltip_text = (
		"Edit shape parameters" if editable else
		"Edit shape parameters (unavailable: the mesh was edited since drawing)")


## Reflect the paint tool's state without re-emitting. On hides the action
## strip and disables the selection-set buttons, since paint keeps the
## selection underneath and they would otherwise stay clickable.
func sync_paint(on: bool) -> void:
	_sync_tool_mode(_paint_button, on, true)


## Reflect material mode's state without re-emitting. The action strip hides
## as for paint, but the selection-set buttons stay live: the face selection
## is the gizmo's working set, and Grow/Select All/Invert pick what to texture.
func sync_material(on: bool) -> void:
	_sync_tool_mode(_material_button, on, false)


func _sync_tool_mode(btn: Button, on: bool, disable_sel_strip: bool) -> void:
	if btn == null:
		return
	if on:
		_press_exclusive(btn)
	else:
		btn.set_pressed_no_signal(false)
	if on:
		if _actions_sep != null:
			_actions_sep.visible = false
			for entry in _action_buttons:
				entry.button.visible = false
		for b in _sel_action_buttons:
			b.disabled = disable_sel_strip
	else:

		_restore_mode_press.call_deferred()


func _press_exclusive(btn: Button) -> void:
	var group := btn.button_group
	if group != null:
		for other in group.get_buttons():
			if other != btn:
				other.set_pressed_no_signal(false)
	btn.set_pressed_no_signal(true)


func _tool_mode_pressed() -> bool:
	return (
		(_paint_button != null and _paint_button.button_pressed)
		or (_material_button != null and _material_button.button_pressed)
	)


func _restore_mode_press() -> void:
	if not _tool_mode_pressed():
		sync_mode(_synced_mode)


## Enter paint mode as if its button were clicked (the key-5 path).
func press_paint() -> void:
	if _paint_button != null and not _paint_button.button_pressed:
		_paint_button.button_pressed = true


## Enter material mode as if its button were clicked (the key-6 path).
func press_material() -> void:
	if _material_button != null and not _material_button.button_pressed:
		_material_button.button_pressed = true


## Reflect a gizmo switch (Shift+W/E/R) without re-emitting. Presses the
## button exclusively so no other gizmo button stays lit.
func sync_gizmo_mode(mode: int) -> void:
	if mode >= 0 and mode < _gizmo_buttons.size():
		_press_exclusive(_gizmo_buttons[mode])


## Reflect a mode change without re-emitting and show the mode's actions. While
## a tool mode (paint, material) holds the group press, only the mode is
## recorded; pressing its button would unpress the tool and cancel it mid-use.
func sync_mode(mode: int) -> void:
	if mode >= 0 and mode < _mode_buttons.size():
		_synced_mode = mode
	if _tool_mode_pressed():
		return
	if mode >= 0 and mode < _mode_buttons.size():
		_press_exclusive(_mode_buttons[mode])
	if _actions_sep != null:
		_actions_sep.visible = mode != UBSelection.Mode.OBJECT
		for entry in _action_buttons:
			entry.button.visible = entry.mode == mode
	for b in _sel_action_buttons:
		b.disabled = mode == UBSelection.Mode.OBJECT


func set_snap_step(v: float) -> void:
	v = clampf(v, STEP_MIN, STEP_MAX)
	if is_equal_approx(v, snap_step):
		return
	snap_step = v
	_step_spin.set_value_no_signal(v)
	grid_changed.emit()


func scale_step(factor: float) -> void:
	set_snap_step(snap_step * factor)


func _sync_prop_ui() -> void:
	if _prop_button == null:
		return

	_iconify(_prop_button,
		FALLOFF_ICONS[prop_falloff] if prop_enabled else "prop_off", "Prop")
	var popup := _prop_button.get_popup()
	var active_id := (prop_falloff + 1) if prop_enabled else 0
	for idx in popup.item_count:
		popup.set_item_checked(idx, popup.get_item_id(idx) == active_id)
	_prop_button.add_theme_color_override("icon_normal_color",
		Color.WHITE if prop_enabled else Color(1, 1, 1, 0.35))
	_prop_button.add_theme_color_override("icon_hover_color",
		Color.WHITE if prop_enabled else Color(1, 1, 1, 0.6))
	_prop_button.tooltip_text = "Proportional editing (%s)" % (
		UBSoftSelect.FALLOFF_NAMES[prop_falloff] if prop_enabled else "off")


## Set the proportional radius programmatically: clamps and syncs the spinbox
## without a signal. The caller re-applies the drag itself.
func set_prop_radius(v: float) -> void:
	prop_radius = clampf(v, PROP_MIN, PROP_MAX)
	if _prop_spin != null:
		_prop_spin.set_value_no_signal(prop_radius)


## Set the grid plane programmatically: syncs the selector without a signal.
## The caller drives the grid update itself.
func set_grid_axis(axis: int) -> void:
	grid_axis = clampi(axis, 0, 2)
	_plane_option.selected = grid_axis


static func _stored_bool(state: Dictionary, key: String, current: bool) -> bool:
	var v: Variant = state.get(key)
	return v if v is bool else current


static func _stored_num(state: Dictionary, key: String, current: float) -> float:
	var v: Variant = state.get(key)
	return float(v) if (v is int or v is float) else current


## Restore persisted state without emitting change signals.
func apply_state(state: Dictionary) -> void:
	snap_enabled = _stored_bool(state, "snap_enabled", snap_enabled)
	_snap_button.set_pressed_no_signal(snap_enabled)
	snap_step = clampf(_stored_num(state, "step", snap_step), STEP_MIN, STEP_MAX)
	_step_spin.set_value_no_signal(snap_step)
	grid_axis = clampi(int(_stored_num(state, "axis", grid_axis)), 0, 2)
	_plane_option.selected = grid_axis
	grid_visible = _stored_bool(state, "grid_visible", grid_visible)
	_grid_button.set_pressed_no_signal(grid_visible)
	dims_visible = _stored_bool(state, "dims", dims_visible)
	_tools_popup.set_item_checked(_tools_popup.get_item_index(3), dims_visible)
	snap_each = _stored_bool(state, "snap_each", snap_each)
	_tools_popup.set_item_checked(_tools_popup.get_item_index(8), snap_each)
	snap_absolute = _stored_bool(state, "snap_absolute", snap_absolute)
	_tools_popup.set_item_checked(_tools_popup.get_item_index(24), snap_absolute)
	draw_on_surface = _stored_bool(state, "surface", draw_on_surface)
	_surface_button.set_pressed_no_signal(draw_on_surface)
	set_last_shape(int(_stored_num(state, "last_shape", last_shape_kind)))
	gizmo_orient = clampi(int(_stored_num(state, "gizmo_orient", gizmo_orient)), 0, 2)
	_orient_option.selected = gizmo_orient
	prop_enabled = _stored_bool(state, "prop", prop_enabled)
	prop_falloff = clampi(int(_stored_num(state, "prop_falloff", prop_falloff)), 0,
		UBSoftSelect.FALLOFF_NAMES.size() - 1)
	_sync_prop_ui()
	prop_radius = clampf(_stored_num(state, "prop_radius", prop_radius), PROP_MIN, PROP_MAX)
	_prop_spin.set_value_no_signal(prop_radius)


func get_state() -> Dictionary:
	return {

		"snap_enabled": snap_enabled == true,
		"step": snap_step,
		"axis": grid_axis,
		"grid_visible": grid_visible == true,
		"dims": dims_visible == true,
		"snap_each": snap_each == true,
		"snap_absolute": snap_absolute == true,
		"surface": draw_on_surface == true,
		"last_shape": last_shape_kind,
		"gizmo_orient": gizmo_orient,
		"prop": prop_enabled == true,
		"prop_falloff": prop_falloff if prop_falloff is int else UBSoftSelect.Falloff.SMOOTH,
		"prop_radius": prop_radius if prop_radius is float else 2.0,
	}
