extends Control
## Personal-effects inventory panel, same camcorder OSD look as menu.gd / hud.gd: VCR font,
## cream/amber/red palette, blurred backdrop, viewfinder corner brackets instead of a boxed
## dialog, and a scanline/grain/glitch overlay (shaders/ui_vhs_overlay.gdshader) so it reads as
## a camera readout rather than a stock UI card. Toggled with TAB (scripts/GameLogicEngine/main.gd),
## closed by ESC or a click on the veil like the pause menu.
## Empty by default: scripts/World/props pickups can call add_item() to populate it.

signal close_requested

const SLOT_COUNT := 8
const COLS := 4
const CREAM := Color("e4e1c6")
const TAPE := Color("c9bea0")
const TITLE := Color("d8d3bd")
const HINT := Color("9c9268")
const AMBER := Color("ffc107")
const RED := Color("ff3b30")

var font: FontFile = load("res://fonts/vcr.ttf")
var shown := false
var fade: Tween
var panel_tween: Tween
var selected := -1
var items: Array = []                # {id, name, desc, color, count}
var slot_nodes: Array = []           # {panel, icon, qty}
var name_label: Label
var desc_label: Label
var qty_label: Label
var count_label: Label
var tag_dot: ColorRect
var content_root: Control
var overlay_mat: ShaderMaterial
var t := 0.0
var glitch_left := 0.0
var next_glitch := 3.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build()

# ---- helpers ------------------------------------------------------------------
func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	return fv

func _label(text: String, size: int, color: Color, spacing := 1.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _box(fill: Color, border := Color(0, 0, 0, 0), bw := Vector4.ZERO) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.border_width_left = int(bw.x); sb.border_width_top = int(bw.y)
	sb.border_width_right = int(bw.z); sb.border_width_bottom = int(bw.w)
	return sb

func _gradient_rect(h: float, from: Color, to: Color, vertical := false) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, from)
	g.set_color(1, to)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 1 if vertical else 256
	gt.height = 256 if vertical else 1
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1) if vertical else Vector2(1, 0)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.custom_minimum_size = Vector2(1, h) if vertical else Vector2(0, h)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s

## Viewfinder bracket: two short lines meeting at a corner, same motif as the HUD frame
func _corner(anchor: Control.LayoutPreset, x: float, y: float, top: bool, left: bool, len := 22.0, col := Color(1, 0.757, 0.027, 0.55)) -> Control:
	var c := Control.new()
	c.set_anchors_and_offsets_preset(anchor)
	c.offset_left = x; c.offset_top = y; c.offset_right = x + len; c.offset_bottom = y + len
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := ColorRect.new(); h.color = col; h.size = Vector2(len, 2); h.position = Vector2(0, 0 if top else len - 2)
	var v := ColorRect.new(); v.color = col; v.size = Vector2(2, len); v.position = Vector2(0 if left else len - 2, 0)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(h)
	c.add_child(v)
	return c

# ---- layout ---------------------------------------------------------------------
func _build() -> void:
	# Blurred, desaturated backdrop (same shader as the pause menu) with a dark tint over it
	var blur := ColorRect.new()
	var blur_mat := ShaderMaterial.new()
	blur_mat.shader = load("res://shaders/menu_blur.gdshader")
	blur.material = blur_mat
	blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blur.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(blur)

	var veil := ColorRect.new()
	veil.color = Color(0.012, 0.012, 0.008, 0.55)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	veil.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			close_requested.emit())
	add_child(veil)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	# content_root: sized to match the SubViewport below; its position is what the open/close
	# animation slides, while everything visual (fisheye + VHS look) lives in the viewport texture
	const PANEL_SIZE := Vector2(660, 342)
	content_root = Control.new()
	content_root.custom_minimum_size = PANEL_SIZE
	content_root.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(content_root)

	# Render the panel's own controls into a SubViewport so the composite shader below can
	# actually warp them (a barrel/fisheye lens needs to resample pixels, not just tint them).
	# SubViewportContainer forwards mouse input into it, so the slots stay clickable.
	var vp_container := SubViewportContainer.new()
	vp_container.stretch = true
	vp_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay_mat = ShaderMaterial.new()
	overlay_mat.shader = load("res://shaders/ui_vhs_overlay.gdshader")
	overlay_mat.set_shader_parameter("aspect", PANEL_SIZE.x / PANEL_SIZE.y)
	vp_container.material = overlay_mat
	content_root.add_child(vp_container)

	var viewport := SubViewport.new()
	viewport.size = Vector2i(PANEL_SIZE)
	viewport.transparent_bg = true
	viewport.disable_3d = true
	vp_container.add_child(viewport)

	var tint := ColorRect.new()
	tint.color = Color(0.043, 0.035, 0.02, 0.62)
	tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(tint)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 26); margin.add_theme_constant_override("margin_right", 26)
	margin.add_theme_constant_override("margin_top", 18); margin.add_theme_constant_override("margin_bottom", 18)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	margin.add_child(col)

	# --- header: blinking tag dot + title + live slot count ---
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag_dot = ColorRect.new()
	tag_dot.color = AMBER
	tag_dot.custom_minimum_size = Vector2(7, 7)
	var dot_c := CenterContainer.new()
	dot_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot_c.add_child(tag_dot)
	head.add_child(dot_c)
	var htitle := _label("INVENTORY", 16, TITLE, 4)
	htitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(htitle)
	count_label = _label("0/8", 12, HINT, 2)
	count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(count_label)
	col.add_child(head)
	col.add_child(_spacer(10))
	col.add_child(_gradient_rect(1, Color(1, 0.757, 0.027, 0.6), Color(1, 0.757, 0.027, 0.05)))
	col.add_child(_spacer(16))

	# --- body: slot grid (+ its hint row, left-aligned under it) and the detail pane ---
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 22)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(body)

	var left_col := VBoxContainer.new()
	left_col.add_theme_constant_override("separation", 12)
	left_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var grid := GridContainer.new()
	grid.columns = COLS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	for i in SLOT_COUNT:
		grid.add_child(_build_slot(i))
	left_col.add_child(grid)
	var hints := HBoxContainer.new()
	hints.add_theme_constant_override("separation", 10)
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hint_items := ["ARROWS // SELECT", "TAB // CLOSE"]
	for i in hint_items.size():
		hints.add_child(_label(hint_items[i], 10, HINT, 1.5))
		if i < hint_items.size() - 1: hints.add_child(_label("•", 10, HINT))
	left_col.add_child(hints)
	body.add_child(left_col)

	# Detail pane: a single amber accent line on the left, like the pause menu's side panel —
	# no enclosing box, so it reads as a readout column rather than a nested card
	var detail_wrap := PanelContainer.new()
	var dsb := _box(Color(0, 0, 0, 0), Color(1, 0.757, 0.027, 0.35), Vector4(1, 0, 0, 0))
	dsb.content_margin_left = 16
	detail_wrap.add_theme_stylebox_override("panel", dsb)
	detail_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail_wrap.custom_minimum_size = Vector2(210, 0)
	detail_wrap.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 6)
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_child(_label("SELECTED", 11, Color(0.9, 0.882, 0.804, 0.45), 3))
	var uline := ColorRect.new()
	uline.color = Color(0.9, 0.882, 0.804, 0.12)
	uline.custom_minimum_size = Vector2(0, 1)
	uline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_child(uline)
	detail.add_child(_spacer(8))
	name_label = _label("EMPTY", 15, CREAM, 2)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(name_label)
	detail.add_child(_spacer(6))
	desc_label = _label("", 12, Color(0.9, 0.882, 0.804, 0.6))
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(desc_label)
	detail.add_child(_spacer(6))
	qty_label = _label("", 11, HINT, 2)
	detail.add_child(qty_label)
	detail_wrap.add_child(detail)
	body.add_child(detail_wrap)

	# Corner brackets, rendered into the viewport too so the lens warps them along with everything else
	viewport.add_child(_corner(Control.PRESET_TOP_LEFT, 6, 6, true, true))
	viewport.add_child(_corner(Control.PRESET_TOP_RIGHT, -6 - 22, 6, true, false))
	viewport.add_child(_corner(Control.PRESET_BOTTOM_LEFT, 6, -6 - 22, false, true))
	viewport.add_child(_corner(Control.PRESET_BOTTOM_RIGHT, -6 - 22, -6 - 22, false, false))

	_refresh()

func _build_slot(i: int) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(86, 86)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select(i))
	p.mouse_entered.connect(func(): _style_slot(i, true))
	p.mouse_exited.connect(func(): _style_slot(i, false))

	var inner := VBoxContainer.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_constant_override("separation", 4)

	var idx := _label("%02d" % (i + 1), 9, Color(0.9, 0.882, 0.804, 0.3), 1)
	inner.add_child(idx)

	var icon_c := CenterContainer.new()
	icon_c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	icon_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := ColorRect.new()
	icon.custom_minimum_size = Vector2(24, 24)
	icon.color = Color(0, 0, 0, 0)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_c.add_child(icon)
	inner.add_child(icon_c)

	var qty := _label("", 10, HINT, 1)
	qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	inner.add_child(qty)

	p.add_child(inner)
	slot_nodes.append({"panel": p, "icon": icon, "qty": qty})
	_style_slot(i, false)
	return p

func _style_slot(i: int, hover: bool) -> void:
	if i >= slot_nodes.size(): return
	var p: PanelContainer = slot_nodes[i].panel
	var has_item := i < items.size()
	var is_sel := i == selected
	var border := Color(0.9, 0.882, 0.804, 0.15)
	if is_sel: border = RED
	elif hover: border = Color(0.9, 0.882, 0.804, 0.4)
	var bg_a := 0.5 if (has_item or is_sel) else 0.28
	p.add_theme_stylebox_override("panel", _box(Color(0.059, 0.047, 0.024, bg_a), border, Vector4(1, 1, 1, 1)))

# ---- state ------------------------------------------------------------------------
func _refresh() -> void:
	for i in SLOT_COUNT:
		var s = slot_nodes[i]
		if i < items.size():
			var it = items[i]
			s.icon.color = it.color
			s.qty.text = ("×%d" % it.count) if it.count > 1 else ""
		else:
			s.icon.color = Color(0, 0, 0, 0)
			s.qty.text = ""
		_style_slot(i, false)
	if count_label: count_label.text = "%d/%d" % [items.size(), SLOT_COUNT]
	_refresh_detail()

func _refresh_detail() -> void:
	if selected >= 0 and selected < items.size():
		var it = items[selected]
		name_label.text = str(it.name).to_upper()
		desc_label.text = it.desc
		qty_label.text = "×%d" % it.count
	else:
		name_label.text = "EMPTY"
		desc_label.text = ""
		qty_label.text = ""

func _select(i: int) -> void:
	if i >= items.size(): return
	selected = i
	_refresh()

func _move_selection(delta: int) -> void:
	if items.is_empty(): return
	var cur := maxi(selected, 0)
	selected = clampi(cur + delta, 0, items.size() - 1)
	_refresh()

func _unhandled_input(e: InputEvent) -> void:
	if not shown or not (e is InputEventKey) or not e.pressed or e.echo: return
	match e.physical_keycode:
		KEY_LEFT: _move_selection(-1)
		KEY_RIGHT: _move_selection(1)
		KEY_UP: _move_selection(-COLS)
		KEY_DOWN: _move_selection(COLS)

## Power-on: the panel slides up from below into its centred resting spot with a back-ease
## settle while its alpha stutters, and the VHS overlay throws a short tear-glitch burst that
## decays away — same flicker curve as the pause menu's side panel (menu.gd _animate_panel_in
## / _flicker), but sliding like the pause menu itself rather than zooming from the centre.
func set_shown(on: bool) -> void:
	if on == shown:
		return
	shown = on
	if fade: fade.kill()
	if panel_tween: panel_tween.kill()
	fade = create_tween()
	if on:
		visible = true
		if selected == -1 and not items.is_empty(): selected = 0
		_refresh()
		var rest_y := content_root.position.y
		content_root.position.y = rest_y + 90.0
		content_root.modulate.a = 0.0
		panel_tween = create_tween()
		panel_tween.set_parallel(true)
		panel_tween.tween_property(content_root, "position:y", rest_y, 0.36).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		panel_tween.tween_method(func(x: float): content_root.modulate.a = _flicker(x), 0.0, 1.0, 0.34)
		if overlay_mat:
			overlay_mat.set_shader_parameter("glitch", 1.0)
			panel_tween.tween_method(func(x: float): overlay_mat.set_shader_parameter("glitch", x), 1.0, 0.0, 0.55).set_delay(0.05)
	else:
		modulate.a = 1.0
		fade.tween_property(self, "modulate:a", 0.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		fade.tween_callback(func(): visible = false; modulate.a = 1.0)

## Alpha curve for the power-on: dim, blink out, flash, settle (matches menu.gd)
func _flicker(x: float) -> float:
	if x < 0.2: return 0.85 * x / 0.2
	if x < 0.35: return 0.15
	if x < 0.5: return 1.0
	if x < 0.62: return 0.45
	return 1.0

func _process(dt: float) -> void:
	if not is_visible_in_tree(): return
	t += dt
	if tag_dot: tag_dot.color.a = 1.0 if fmod(t, 1.1) < 0.55 else 0.0
	_update_idle_glitch(dt)

## Every few seconds, a brief tear-glitch burst on the overlay — the tape never sits perfectly
## still, echoing the pause menu's random title glitch (menu.gd _update_glitch)
func _update_idle_glitch(dt: float) -> void:
	if not overlay_mat: return
	if glitch_left > 0.0:
		glitch_left -= dt
		overlay_mat.set_shader_parameter("glitch", 0.35 + 0.35 * sin(t * 70.0))
		if glitch_left <= 0.0:
			overlay_mat.set_shader_parameter("glitch", 0.0)
		return
	next_glitch -= dt
	if next_glitch <= 0.0:
		glitch_left = randf_range(0.05, 0.14)
		next_glitch = randf_range(3.0, 7.0)

# ---- public API: World/props pickups can call these -------------------------------------
func add_item(id: String, name: String, desc: String, color: Color, count := 1) -> void:
	for it in items:
		if it.id == id:
			it.count += count
			_refresh()
			return
	if items.size() >= SLOT_COUNT:
		return
	items.append({"id": id, "name": name, "desc": desc, "color": color, "count": count})
	_refresh()

func remove_item(id: String, count := 1) -> void:
	for i in items.size():
		if items[i].id == id:
			items[i].count -= count
			if items[i].count <= 0:
				items.remove_at(i)
				if selected >= items.size(): selected = items.size() - 1
			_refresh()
			return

func has_item(id: String) -> bool:
	for it in items:
		if it.id == id: return true
	return false
