extends Control
## HUD notification in the inventory terminal's style: a folder-tab sheet that slides in at the top
## right, builds its rows in, shows a shrinking life bar and slides out. It sits in a crt_layer.gd,
## so it glows, flickers and tears like the terminal. hud.gd pushes a "NEW ENTRY LOGGED" one when
## the field scanner logs an entity; push() queues, so entries that land together follow one another.
##
## Rows (the `lines` of push()) are dictionaries by "kind":
##   head   {code, name, tag?, tag_color?, size?}  a small code line (tag boxed on its right) over a big name
##   pair   {left, right, color?, strong?}         a name and a right-aligned value
##   rule   {}                                     a hairline
##   bar    {left, right, from, to}                a segmented gauge that fills from `from` to `to` (0..1)
##   keys   {keys: [..], text}                     key caps, then what they do
##   text   {text, color?, size?, wrap?}           a line, or a wrapped sentence
## A plain [text, color, size, wrap?] array still works as a text row.

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")
const W := 560.0
const TAB_H := 38.0
const SLANT := 22.0
const CHAMFER := 10.0
const PAD := 26.0                # room round the sheet for its glow
const PAD_X := 26.0              # the rows' inset from the sheet's sides
const BODY_TOP := 20.0           # from the tab's baseline to the first row
const BODY_BOTTOM := 34.0        # under the last row: the life bar sits in here
const SLIDE := 70.0              # how far it slides in from
const HOLD := 5.5
const RIGHT := 42.0              # lines up with the HUD's top-right block (hud.gd)
const TOP := 150.0
const BAR_SEGS := 24

var queue: Array = []            # [title, lines]
var busy := false
var layer: CrtLayer
var sheet: Control
var line_w: float = Term.LINE * Term.WINDOW_SCALE   # the terminal's outline weight, as it shows on screen
var tab_label: Label
var body: VBoxContainer
var tab_w := 0.0
var life := -1.0
var anim: Tween
var chime: AudioStreamPlayer
var font := FontVariation.new()
var wide := FontVariation.new()  # letter-spaced: the tab and the small code lines
var _typed: Array = []           # labels that type in, in order
var _rules: Array = []           # hairlines that draw out
var _bars: Array = []            # gauges that fill once the rows are in

func _ready() -> void:
	anchor_left = 1.0; anchor_right = 1.0
	offset_left = -RIGHT - W; offset_right = -RIGHT
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
	layer.size = Vector2(W + SLIDE + PAD * 2.0, 320.0)
	add_child(layer)
	sheet = Control.new()
	sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet.position = Vector2(PAD, PAD)
	sheet.draw.connect(_draw_sheet)
	layer.content.add_child(sheet)
	tab_label = _label("", 16, Term.TEXT, wide)
	tab_label.clip_text = false
	tab_label.position = Vector2(18, 10)
	sheet.add_child(tab_label)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.position = Vector2(PAD_X, TAB_H + BODY_TOP)
	sheet.add_child(body)

	chime = AudioStreamPlayer.new()
	chime.stream = load("res://audio/terminal/terminal_logged.wav")
	chime.volume_db = -15.0
	add_child(chime)

func _label(text: String, px: int, color: Color, f: Font = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", f if f else font)
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _typing(l: Label) -> Label:
	_typed.append(l)
	return l

func push(title: String, lines: Array) -> void:
	queue.append([title, lines])
	if not busy:
		_next()

# ---- rows -------------------------------------------------------------------------------
func _row(ln) -> Control:
	if ln is Array:                  # the old [text, color, size, wrap?] form
		var a: Array = ln
		return _text_row({"text": a[0], "color": a[1], "size": a[2], "wrap": a.size() > 3 and a[3]})
	var d: Dictionary = ln
	match str(d.get("kind", "text")):
		"head": return _head_row(d)
		"pair": return _pair_row(d)
		"rule": return _rule_row()
		"bar": return _bar_row(d)
		"keys": return _keys_row(d)
	return _text_row(d)

func _text_row(d: Dictionary) -> Control:
	var l := _typing(_label(str(d.get("text", "")), int(d.get("size", 16)), d.get("color", Term.TEXT)))
	l.custom_minimum_size.x = W - PAD_X * 2.0
	if d.get("wrap", false):         # a sentence: wraps instead of trailing off
		l.clip_text = false
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

## The entry's code in small spaced capitals, its threat boxed on the right, the name under them
func _head_row(d: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var code := _typing(_label(str(d.get("code", "")), 14, Term.MUTED, wide))
	code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(code)
	var tag := str(d.get("tag", ""))
	if tag != "":
		var tc: Color = d.get("tag_color", Term.AMBER)
		var chip := PanelContainer.new()
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(tc, 0.08)
		sb.border_color = Color(tc, 0.75)
		sb.set_border_width_all(2)
		sb.content_margin_left = 9; sb.content_margin_right = 7
		sb.content_margin_top = 3; sb.content_margin_bottom = 1
		chip.add_theme_stylebox_override("panel", sb)
		chip.add_child(_typing(_label(tag, 13, tc, wide)))
		top.add_child(chip)
	v.add_child(top)
	var n := _typing(_label(str(d.get("name", "")), int(d.get("size", 26)), Term.TEXT))
	n.custom_minimum_size.x = W - PAD_X * 2.0
	v.add_child(n)
	return v

## "FIRST CONTACT ............ +100 RY": the name dim, the value in its colour on the right
func _pair_row(d: Dictionary) -> Control:
	var strong: bool = d.get("strong", false)
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.custom_minimum_size.x = W - PAD_X * 2.0
	var l := _typing(_label(str(d.get("left", "")), 16 if strong else 15, Term.TEXT if strong else Term.TEXT_DIM))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	var r := _typing(_label(str(d.get("right", "")), 17 if strong else 16, d.get("color", Term.AMBER)))
	r.clip_text = false
	r.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(r)
	return h

func _rule_row() -> Control:
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_top", 4)
	m.add_theme_constant_override("margin_bottom", 4)
	var r := ColorRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.color = Term.AMBER_DIM
	r.custom_minimum_size = Vector2(W - PAD_X * 2.0, 2)
	r.scale.x = 0.001
	m.add_child(r)
	_rules.append(r)
	return m

## Clearance toward the next tier: the tier code, a segmented gauge, the numbers. What this filing
## added fills in bright after the rows are up; what was there before shows dim from the start.
func _bar_row(d: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _typing(_label(str(d.get("left", "")), 14, Term.MUTED, wide))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(l)
	var r := _typing(_label(str(d.get("right", "")), 14, Term.TEXT_DIM))
	r.clip_text = false
	r.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top.add_child(r)
	v.add_child(top)
	var g := Control.new()
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.custom_minimum_size = Vector2(W - PAD_X * 2.0, 10)
	g.set_meta("from", clampf(float(d.get("from", 0.0)), 0.0, 1.0))
	g.set_meta("to", clampf(float(d.get("to", 0.0)), 0.0, 1.0))
	g.set_meta("fill", 0.0)          # 0..1 of the way from `from` to `to`
	g.draw.connect(_draw_gauge.bind(g))
	v.add_child(g)
	_bars.append(g)
	return v

func _draw_gauge(g: Control) -> void:
	var from: float = g.get_meta("from")
	var to: float = g.get_meta("to")
	var now := lerpf(from, to, float(g.get_meta("fill")))
	var gap := 3.0
	var sw := (g.size.x - gap * (BAR_SEGS - 1)) / BAR_SEGS
	var head := int(ceil(now * BAR_SEGS)) - 1
	for i in BAR_SEGS:
		var r := Rect2(i * (sw + gap), 0.0, sw, g.size.y)
		var e := float(i + 1) / BAR_SEGS
		var c := Color(Term.TEXT, 0.1)
		if e <= from + 0.0001:
			c = Color(Term.AMBER, 0.45)          # already had
		elif e <= now + 0.0001 or i == head:
			c = Term.AMBER                       # this filing
			if i == head and float(g.get_meta("fill")) < 1.0:
				c = Term.TEXT                    # the leading segment runs hot while it fills
		g.draw_rect(r, c)

## Key caps like the terminal's: an outlined box per key, then what they do
func _keys_row(d: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in d.get("keys", []):
		var cap := PanelContainer.new()
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(Term.TEXT, 0.05)
		sb.border_color = Color(Term.MUTED, 0.7)
		sb.set_border_width_all(2)
		sb.border_width_bottom = 3
		sb.content_margin_left = 7; sb.content_margin_right = 7
		sb.content_margin_top = 2; sb.content_margin_bottom = 0
		cap.add_theme_stylebox_override("panel", sb)
		cap.add_child(_label(str(k), 13, Term.TEXT))
		h.add_child(cap)
	var t := _typing(_label(str(d.get("text", "")), 14, Term.MUTED))
	t.clip_text = false
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_left", 6)
	m.add_child(t)
	h.add_child(m)
	return h

# ---- showing one --------------------------------------------------------------------------
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
	tab_label.text = entry[0]
	tab_w = tab_label.get_combined_minimum_size().x + 36.0 + SLANT
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	_typed.clear()
	_rules.clear()
	_bars.clear()
	for ln in entry[1]:
		body.add_child(_row(ln))
	var h := TAB_H + BODY_TOP + body.get_combined_minimum_size().y + BODY_BOTTOM
	sheet.size = Vector2(W, h)
	layer.size.y = maxf(320.0, h + PAD * 2.0)   # long entries (a yield breakdown) stay inside the glow
	life = 1.0
	chime.play()
	layer.burst(0.8)

	# in: slide from the right while it flickers on; the tab types, then the rows come up in order
	# (rules draw out, text types), and last the clearance gauge fills with what this filing added
	sheet.position.x = PAD + SLIDE
	sheet.modulate.a = 0.0
	if anim: anim.kill()
	anim = create_tween().set_parallel(true)
	anim.tween_property(sheet, "position:x", PAD, 0.36).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	anim.tween_method(func(x: float): sheet.modulate.a = Term.flicker(x), 0.0, 1.0, 0.3)
	var labels: Array = [tab_label] + _typed
	var at := 0.08
	for i in labels.size():
		var l: Label = labels[i]
		l.visible_ratio = 0.0
		var dur := clampf(l.text.length() * 0.012, 0.08, 0.32)
		anim.tween_property(l, "visible_ratio", 1.0, dur).set_delay(at)
		at += 0.045
	for i in _rules.size():
		anim.tween_property(_rules[i], "scale:x", 1.0, 0.35).set_delay(0.18 + i * 0.12) \
				.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	for g in _bars:
		anim.tween_method(_set_fill.bind(g), 0.0, 1.0, 0.7).set_delay(at + 0.15) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	anim.tween_method(_set_life, 1.0, 0.0, HOLD).set_delay(0.3)
	# out: slide back and fade, then the next one in the queue
	anim.chain().tween_property(sheet, "position:x", PAD + SLIDE, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	anim.tween_property(sheet, "modulate:a", 0.0, 0.25)
	anim.chain().tween_callback(func(): _next.call_deferred())   # not from inside the tween it replaces

func _set_fill(v: float, g: Control) -> void:
	if is_instance_valid(g):
		g.set_meta("fill", v)
		g.queue_redraw()

func _set_life(v: float) -> void:
	life = v
	sheet.queue_redraw()

## Same folder-tab outline as the inventory's right-hand sheet (inventory.gd _draw_readout)
func _draw_sheet() -> void:
	var w := sheet.size.x
	var h := sheet.size.y
	var top := TAB_H
	var c := CHAMFER
	if h <= top + c * 2.0:           # nothing pushed yet (the first draw comes before any size)
		return
	sheet.draw_colored_polygon(PackedVector2Array([
		Vector2(0, top), Vector2(w - c, top), Vector2(w, top + c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(c, h), Vector2(0, h - c)]), Term.FILL)
	var tab := PackedVector2Array([Vector2(0, top), Vector2(0, 0), Vector2(tab_w - SLANT, 0), Vector2(tab_w, top)])
	sheet.draw_colored_polygon(tab, Term.FILL)
	sheet.draw_polyline(tab, Term.AMBER, line_w, true)
	sheet.draw_polyline(PackedVector2Array([
		Vector2(tab_w, top), Vector2(w - c, top), Vector2(w, top + c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(c, h), Vector2(0, h - c), Vector2(0, top)]), Term.AMBER, line_w, true)
	if life > 0.0:                   # time left before it slides away: a thin track, draining to the left
		var y := h - 14.0
		var x0 := PAD_X
		var x1 := w - PAD_X
		sheet.draw_line(Vector2(x0, y), Vector2(x1, y), Color(Term.AMBER, 0.12), 2.0)
		sheet.draw_line(Vector2(x0, y), Vector2(x0 + (x1 - x0) * life, y), Color(Term.AMBER, 0.5), 2.0)
