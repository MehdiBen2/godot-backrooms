@tool
class_name UBPanelStyle
extends RefCounted
## Shared look for the dock panels (face, adjust, vertex, paint, palette):
## an inspector-style header strip, a padded body with consistent spacing,
## teal uppercase section labels, and aligned label plus control rows. The
## brand teal is the only accent.

const TEAL := Color(0.369, 0.918, 0.831)
const LABEL_MIN := 74.0


## Style a panel as a floating viewport card: translucent dark rounded
## background, dimmed-teal hairline border, and a drop shadow. The card keeps
## the dark look on both editor themes.
static func float_card(panel: PanelContainer) -> void:
	var scale := EditorInterface.get_editor_scale()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.086, 0.094, 0.11, 0.94)
	sb.set_corner_radius_all(roundi(5.0 * scale))
	sb.border_color = Color(TEAL, 0.45)
	sb.set_border_width_all(1)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = roundi(8.0 * scale)
	sb.shadow_offset = Vector2(0.0, 2.0 * scale)
	panel.add_theme_stylebox_override("panel", sb)


## Give a PanelContainer a padded body VBox with breathing room between rows.
static func body(panel: PanelContainer) -> VBoxContainer:
	var scale := EditorInterface.get_editor_scale()
	var margin := MarginContainer.new()
	var pad := roundi(8.0 * scale)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, pad)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", roundi(6.0 * scale))
	margin.add_child(box)
	return box


## Centered icon and bold title on a darker strip, matching the inspector's
## category bars. Returns the Label so callers can retitle it.
static func header(box: Control, text: String, icon := "") -> Label:
	var strip := PanelContainer.new()
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", roundi(6.0 * EditorInterface.get_editor_scale()))
	strip.add_child(row)
	var rect := TextureRect.new()
	rect.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(rect)
	var label := Label.new()
	label.text = text
	row.add_child(label)
	style_header(strip, rect, label, icon)
	box.add_child(strip)
	return label


## Dress a header strip (PanelContainer > HBox > icon TextureRect + title
## Label, built by header() or authored in a panel scene): the darker rounded
## strip, the editor's bold font, and the runtime-rasterized icon. The icon
## rect hides when there is no icon or it fails to load.
static func style_header(strip: PanelContainer, icon_rect: TextureRect, title: Label, icon: String) -> void:
	var scale := EditorInterface.get_editor_scale()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.25)
	sb.set_corner_radius_all(roundi(3.0 * scale))
	sb.content_margin_left = 8.0 * scale
	sb.content_margin_right = 8.0 * scale
	sb.content_margin_top = 4.0 * scale
	sb.content_margin_bottom = 4.0 * scale
	strip.add_theme_stylebox_override("panel", sb)
	var tex := UBOverlayToolbar._icon(icon) if not icon.is_empty() else null
	icon_rect.texture = tex
	icon_rect.visible = tex != null
	var bold := EditorInterface.get_base_control().get_theme_font("bold", "EditorFonts")
	if bold != null:
		title.add_theme_font_override("font", bold)


## Theme constants a panel scene may override; scale_layout scales each one.
const SCALED_CONSTANTS: Array[StringName] = [
	&"separation", &"h_separation", &"v_separation",
	&"margin_left", &"margin_right", &"margin_top", &"margin_bottom",
]


## Bring a panel scene's sizes, authored at editor scale 1, to the live editor
## scale, the way the code-built panels computed them: every spacing and margin
## constant override, every font size override, and the minimum size of Labels
## and bare Controls (row labels, spacers). Buttons and pickers keep their
## authored minimum sizes, and so does the root (callers decide). Only nodes the
## scene owns are touched, so rows a panel adds at run time, already built at
## scale, are never scaled twice.
static func scale_layout(root: Node) -> void:
	var scale := EditorInterface.get_editor_scale()
	for node in root.find_children("*", "Control", true, true):
		var c := node as Control
		for key in SCALED_CONSTANTS:
			if c.has_theme_constant_override(key):
				c.add_theme_constant_override(key, roundi(c.get_theme_constant(key) * scale))
		if c.has_theme_font_size_override(&"font_size"):
			c.add_theme_font_size_override(&"font_size", roundi(c.get_theme_font_size(&"font_size") * scale))
		if c is Label or c.get_class() == "Control":
			c.custom_minimum_size *= scale


## Teal small-caps section label with a little air above it.
static func section(box: Control, text: String) -> Label:
	var scale := EditorInterface.get_editor_scale()
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 2.0 * scale
	box.add_child(spacer)
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_color_override("font_color", TEAL)
	label.add_theme_font_size_override("font_size", roundi(11.0 * scale))
	box.add_child(label)
	return label


## Aligned property row: fixed-width label, expanding control.
static func row(box: Control, text: String, control: Control, label_min := LABEL_MIN) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", roundi(6.0 * EditorInterface.get_editor_scale()))
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = label_min * EditorInterface.get_editor_scale()
	r.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(control)
	box.add_child(r)
	return r
