extends Control
## HUD notification in the terminal's language, kept light so it sits over play without weighing on
## it: a slim folder-tab sheet that slides in at the top right, sized to what it says, and types its
## lines in. The thin amber bar down its left edge is its life, draining until it slides away (the
## inventory marks its selected row with the same bar). A line that starts with keys ("[R] ...",
## "[TAB] [F3] ...") shows them as keycaps. It sits in a crt_layer.gd, so it glows, flickers and
## tears like the terminal. hud.gd pushes one when the field scanner logs an entity, an item is
## recovered, yield is filed or clearance goes up; push() queues, so ones that land together follow
## one another.

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")
const W_MIN := 300.0
const W_MAX := 500.0             # the widest it gets; sentences wrap at this
const TAB_H := 28.0
const SLANT := 14.0
const CHAMFER := 8.0
const LINE_W := 2.0
const BAR_W := 3.0               # the life bar down the left edge
const INSET := 18.0              # body text in from the left edge, past the life bar
const PAD := 26.0                # room round the sheet for its glow
const SLIDE := 60.0              # how far it slides in from
const HOLD := 5.0
const RIGHT := 42.0              # lines up with the HUD's top-right block (hud.gd)
const TOP := 150.0

var queue: Array = []            # [title, lines]; lines: [[text, color, font size, wrap?], ...]
var busy := false
var layer: CrtLayer
var sheet: Control
var tab_label: Label
var body: VBoxContainer
var tab_w := 0.0
var home_x := PAD                # the sheet's resting x: its right edge stays put whatever its width
var life := -1.0
var anim: Tween
var chime: AudioStreamPlayer
var font := FontVariation.new()
var wide := FontVariation.new()  # letter-spaced, for the tab

func _ready() -> void:
	anchor_left = 1.0; anchor_right = 1.0
	offset_left = -RIGHT - W_MAX; offset_right = -RIGHT
	offset_top = TOP; offset_bottom = TOP
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 1
	font.variation_embolden = 0.4
	wide.base_font = font.base_font
	wide.spacing_glyph = 3
	wide.variation_embolden = 0.4

	# the layer reaches past the sheet on every side for the glow, and further right for the slide
	layer = CrtLayer.new()
	layer.position = Vector2(-PAD, -PAD)
	layer.size = Vector2(W_MAX + SLIDE + PAD * 2.0, 320.0)
	add_child(layer)
	sheet = Control.new()
	sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet.position = Vector2(PAD, PAD)
	sheet.draw.connect(_draw_sheet)
	layer.content.add_child(sheet)
	tab_label = _label("", 14, Term.AMBER, wide)
	tab_label.position = Vector2(12, 6)
	sheet.add_child(tab_label)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 3)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.position = Vector2(INSET, TAB_H + 10.0)
	sheet.add_child(body)

	chime = AudioStreamPlayer.new()
	chime.stream = load("res://audio/terminal/terminal_logged.wav")
	chime.volume_db = -15.0
	add_child(chime)

## Untrimmed, so its minimum width is its text's (the sheet is sized off it)
func _label(text: String, px: int, color: Color, f: Font = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", f if f else font)
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## A line's leading "[KEY]" tokens as keycaps, then the rest of it; null when it doesn't start with one
func _key_row(text: String, px: int, color: Color) -> Control:
	var keys: Array = []
	var rest := text.strip_edges()
	while rest.begins_with("["):
		var close := rest.find("]")
		if close < 2 or close > 6:   # "[NEW ENTRY LOGGED]" and the like are not keys
			break
		keys.append(rest.substr(1, close - 1))
		rest = rest.substr(close + 1).strip_edges()
	if keys.is_empty():
		return null
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in keys:
		var cap := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(Term.AMBER, 0.14)
		sb.border_color = Color(Term.AMBER, 0.9)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 6.0; sb.content_margin_right = 6.0
		sb.content_margin_top = 0.0; sb.content_margin_bottom = 0.0
		cap.add_theme_stylebox_override("panel", sb)
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		cap.add_child(_label(str(k), px - 3, Term.TEXT))
		row.add_child(cap)
	if rest != "":
		row.add_child(_label(rest, px, color))
	return row

func push(title: String, lines: Array) -> void:
	queue.append([title, lines])
	if not busy:
		_next()

func _next() -> void:
	if queue.is_empty():
		busy = false
		visible = false
		layer.running = false
		return
	busy = true
	visible = true
	layer.running = true
	var entry: Array = queue.pop_front()
	tab_label.text = str(entry[0]).trim_prefix("[").trim_suffix("]")
	tab_label.size = Vector2.ZERO            # back down to the new title
	tab_w = tab_label.get_combined_minimum_size().x + 24.0 + SLANT
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	var wraps: Array = []
	for ln in entry[1]:
		var px := int(ln[2]) - 1
		var wrap: bool = ln.size() > 3 and ln[3]
		var row: Control = null
		if not wrap:
			row = _key_row(str(ln[0]), px, ln[1])
		if row == null:
			var l := _label(str(ln[0]), px, ln[1])
			if wrap:                 # a sentence: wraps at the sheet's width instead of widening it
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				wraps.append(l)
			row = l
		body.add_child(row)

	# as wide as its widest line (a sentence takes the full width), and room for the tab
	var w := W_MAX if not wraps.is_empty() else W_MIN
	if wraps.is_empty():
		for row in body.get_children():
			w = maxf(w, (row as Control).get_combined_minimum_size().x + INSET + 20.0)
	w = clampf(maxf(w, tab_w + 60.0), W_MIN, W_MAX)
	var inner := w - INSET - 20.0
	for row in body.get_children():
		var l := row as Label
		if l and l.autowrap_mode == TextServer.AUTOWRAP_OFF and l.get_combined_minimum_size().x > inner:
			l.clip_text = true
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			l.custom_minimum_size.x = inner
	# a wrapping label works out its height from its current width, which is still ~0 before the
	# box lays it out (a letter a line: a sheet down to the floor), so give it its width first
	for l in wraps:
		(l as Label).custom_minimum_size.x = inner
		(l as Label).size = Vector2(inner, 0.0)
		(l as Label).update_minimum_size()
	body.size = Vector2(inner, 0.0)
	var h := TAB_H + 10.0 + body.get_combined_minimum_size().y + 16.0
	sheet.size = Vector2(w, h)
	home_x = PAD + W_MAX - w
	layer.size.y = maxf(320.0, h + PAD * 2.0)   # long entries (a yield breakdown) stay inside the glow
	life = 1.0
	chime.play()
	layer.burst(0.6)

	# in: slide from the right while it flickers on, then each line types itself in
	sheet.position.x = home_x + SLIDE
	sheet.modulate.a = 0.0
	if anim: anim.kill()
	anim = create_tween().set_parallel(true)
	anim.tween_property(sheet, "position:x", home_x, 0.32).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	anim.tween_method(func(x: float): sheet.modulate.a = Term.flicker(x), 0.0, 1.0, 0.3)
	var labels: Array = [tab_label] + body.find_children("*", "Label", true, false)
	for i in labels.size():
		var l: Label = labels[i]
		l.visible_ratio = 0.0
		anim.tween_property(l, "visible_ratio", 1.0, clampf(l.text.length() * 0.012, 0.08, 0.3)).set_delay(0.08 + i * 0.06)
	anim.tween_method(_set_life, 1.0, 0.0, HOLD).set_delay(0.3)
	# out: slide back and fade, then the next one in the queue
	anim.chain().tween_property(sheet, "position:x", home_x + SLIDE, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	anim.tween_property(sheet, "modulate:a", 0.0, 0.25)
	anim.chain().tween_callback(func(): _next.call_deferred())   # not from inside the tween it replaces

func _set_life(v: float) -> void:
	life = v
	sheet.queue_redraw()

## The inventory sheet's folder-tab outline (inventory.gd _draw_readout), drawn thin, with the
## right-hand corners cut; the life bar runs down the inside of the left edge
func _draw_sheet() -> void:
	var w := sheet.size.x
	var h := sheet.size.y
	var top := TAB_H
	var c := CHAMFER
	if h <= top + c * 2.0:           # nothing pushed yet (the first draw comes before any size)
		return
	var edge_col := Color(Term.AMBER, 0.9)
	sheet.draw_colored_polygon(PackedVector2Array([
		Vector2(0, top), Vector2(w - c, top), Vector2(w, top + c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(0, h)]), Term.FILL)
	var tab := PackedVector2Array([Vector2(0, top), Vector2(0, 0), Vector2(tab_w - SLANT, 0), Vector2(tab_w, top)])
	sheet.draw_colored_polygon(tab, Term.FILL)
	sheet.draw_polyline(tab, edge_col, LINE_W, true)
	sheet.draw_polyline(PackedVector2Array([
		Vector2(tab_w, top), Vector2(w - c, top), Vector2(w, top + c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(0, h), Vector2(0, top)]), edge_col, LINE_W, true)
	var y0 := top + 8.0
	var span := h - 8.0 - y0
	sheet.draw_rect(Rect2(7.0, y0, BAR_W, span), Color(Term.AMBER, 0.15))
	if life > 0.0:
		sheet.draw_rect(Rect2(7.0, y0, BAR_W, span * life), Term.AMBER)
