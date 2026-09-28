extends Control
## Personal-effects inventory panel, same camcorder OSD look as menu.gd / hud.gd: VCR font,
## cream/amber/red palette, flat hairline panels instead of boxed ones. Toggled with TAB
## (scripts/GameLogicEngine/main.gd), closed by ESC or a click on the veil like the pause menu.
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
var selected := -1
var items: Array = []                # {id, name, desc, color, count}
var slot_nodes: Array = []           # {panel, icon, qty}
var name_label: Label
var desc_label: Label
var qty_label: Label

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

# ---- layout ---------------------------------------------------------------------
func _build() -> void:
	var veil := ColorRect.new()
	veil.color = Color(0.012, 0.012, 0.008, 0.6)
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

	var panel := PanelContainer.new()
	var sb := _box(Color(0.059, 0.047, 0.024, 0.88), Color(1, 0.757, 0.027, 0.25), Vector4(1, 1, 1, 1))
	sb.content_margin_left = 26; sb.content_margin_right = 26
	sb.content_margin_top = 22; sb.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.custom_minimum_size = Vector2(640, 0)
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	panel.add_child(col)

	# --- header: tag dot + title + close hint ---
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	var dot := ColorRect.new()
	dot.color = AMBER
	dot.custom_minimum_size = Vector2(7, 7)
	var dot_c := CenterContainer.new()
	dot_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot_c.add_child(dot)
	head.add_child(dot_c)
	var htitle := VBoxContainer.new()
	htitle.add_theme_constant_override("separation", 2)
	htitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	htitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	htitle.add_child(_label("INVENTORY", 16, TITLE, 4))
	htitle.add_child(_label("PERSONAL EFFECTS", 11, Color(0.9, 0.882, 0.804, 0.45), 3))
	head.add_child(htitle)
	var close_hint := _label("TAB / ESC — CLOSE", 11, HINT, 2)
	close_hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(close_hint)
	col.add_child(head)
	col.add_child(_spacer(12))
	col.add_child(_gradient_rect(1, Color(1, 0.757, 0.027, 0.6), Color(1, 0.757, 0.027, 0.05)))
	col.add_child(_spacer(20))

	# --- body: slot grid + detail pane ---
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 26)
	col.add_child(body)

	var grid := GridContainer.new()
	grid.columns = COLS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	for i in SLOT_COUNT:
		grid.add_child(_build_slot(i))
	body.add_child(grid)

	body.add_child(_gradient_rect(200, Color(0.9, 0.882, 0.804, 0.0), Color(0.9, 0.882, 0.804, 0.18), true))

	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 6)
	detail.custom_minimum_size = Vector2(210, 0)
	detail.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_child(_label("SELECTED", 11, Color(0.9, 0.882, 0.804, 0.45), 3))
	var uline := ColorRect.new()
	uline.color = Color(0.9, 0.882, 0.804, 0.12)
	uline.custom_minimum_size = Vector2(0, 1)
	uline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_child(uline)
	detail.add_child(_spacer(8))
	name_label = _label("— NONE —", 15, CREAM, 2)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(name_label)
	detail.add_child(_spacer(8))
	desc_label = _label("", 12, Color(0.9, 0.882, 0.804, 0.6))
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(desc_label)
	detail.add_child(_spacer(8))
	qty_label = _label("", 11, HINT, 2)
	detail.add_child(qty_label)
	body.add_child(detail)

	col.add_child(_spacer(20))
	var hints := HBoxContainer.new()
	hints.add_theme_constant_override("separation", 12)
	hints.alignment = BoxContainer.ALIGNMENT_CENTER
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hint_items := ["ARROWS // SELECT", "TAB // CLOSE"]
	for i in hint_items.size():
		hints.add_child(_label(hint_items[i], 10, HINT, 1.5))
		if i < hint_items.size() - 1: hints.add_child(_label("•", 10, HINT))
	col.add_child(hints)

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
	_refresh_detail()

func _refresh_detail() -> void:
	if selected >= 0 and selected < items.size():
		var it = items[selected]
		name_label.text = str(it.name).to_upper()
		desc_label.text = it.desc
		qty_label.text = "QTY: %d" % it.count
	else:
		name_label.text = "— NONE —"
		desc_label.text = "No item selected."
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

## Fade in (0.22 s) / fade out (0.18 s), matching the pause menu's transition feel
func set_shown(on: bool) -> void:
	if on == shown:
		return
	shown = on
	if fade: fade.kill()
	fade = create_tween()
	if on:
		visible = true
		modulate.a = 0.0
		if selected == -1 and not items.is_empty(): selected = 0
		_refresh()
		fade.tween_property(self, "modulate:a", 1.0, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	else:
		fade.tween_property(self, "modulate:a", 0.0, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		fade.tween_callback(func(): visible = false)

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
