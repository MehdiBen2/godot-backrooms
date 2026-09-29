extends Control
## HUD notification in the terminal's language, kept light so it sits over play without weighing on
## it: a dark card that slides in at the top right, sized to what it says, and types its lines in.
## One bright thing only: the amber bar down its left edge, which is also its life, draining until it
## slides away (the inventory marks its selected row with the same bar). The outline stays faint, the
## title is a small overline, and hints sit dim at the bottom, so the name is what reads first. A line
## that starts with keys ("[R] ...", "[TAB] [F3] ...") shows them as keycaps. It sits in a
## crt_layer.gd, so it glows, flickers and tears like the terminal, with a red / blue split
## (`ABERRATION`) that jumps as it arrives and leaves and widens as sanity goes. hud.gd pushes one when the field scanner logs an entity, an item is
## recovered, yield is filed or clearance goes up; push() queues, so ones that land together follow
## one another.
##
## A line is either the plain [text, color, font size, wrap?] array, or a row dictionary by "kind":
##   head   {code, name, tag?, tag_color?, size?}  a big name over a small code line (tag after it, in its colour)
##   pair   {left, right, color?, strong?}         a name and a value on the sheet's right edge
##   rule   {}                                     a hairline that draws out
##   bar    {left, right, from, to}                a segmented gauge that fills from `from` to `to` (0..1)
##   keys   {keys: [..], text}                     keycaps, then what they do
##   text   {text, color?, size?, wrap?}           the plain line as a dictionary

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")
const W_MIN := 280.0
const W_MAX := 480.0             # the widest it gets; sentences wrap at this
const CHAMFER := 10.0            # the one cut corner, top right
const LINE_W := 1.0
const BAR_W := 3.0               # the life bar down the left edge
const INSET := 20.0              # body text in from the left edge, past the life bar
const RIGHT_PAD := 18.0
const BODY_TOP := 12.0           # top edge to the title
const BODY_BOTTOM := 13.0        # last row to the bottom edge
const ABERRATION := 1.1          # red / blue split at rest, in px (crt_layer.gd)
const BAR_SEGS := 20
const GAUGE_MIN_W := 340.0       # a gauge needs this much room to read
const PAD := 26.0                # room round the sheet for its glow
const SLIDE := 60.0              # how far it slides in from
const HOLD := 5.0
const RIGHT := 42.0              # lines up with the HUD's top-right block (hud.gd)
const TOP := 150.0
const CORRUPT_BELOW := 40.0      # sanity under this and a toast may arrive with a word gone wrong
const WRONG_WORDS := ["BEHIND", "NOT REAL", "STAY", "LOOK", "WAKE UP", "IT SEES", "NO EXIT", "YOU", "LIAR", "HELP"]
const GARBLE := "#%&@$?!/"

var queue: Array = []            # [title, lines]; lines: [[text, color, font size, wrap?], ...]
var busy := false
var layer: CrtLayer
var sheet: Control
var body: VBoxContainer
var home_x := PAD                # the sheet's resting x: its right edge stays put whatever its width
var life := -1.0
var anim: Tween
var chime: AudioStreamPlayer
var font := FontVariation.new()
var wide := FontVariation.new()  # letter-spaced, for the title and codes
var player: Node                 # player.gd (set by hud.gd): its sanity decides the corruption
var _bad := {}                   # {label, real, fake, t}: the corrupted line, flickering back now and then
var _word := RegEx.create_from_string("^[A-Z]{4,}$")
var _stretch: Array = []         # rows laid out to the sheet's inner width once it is known
var _fit: Array = []             # labels trimmed with an ellipsis if the sheet is too narrow for them
var _rules: Array = []           # hairlines that draw out
var _bars: Array = []            # gauges that fill once the rows are in

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
	wide.spacing_glyph = 2
	wide.variation_embolden = 0.2

	# the layer reaches past the sheet on every side for the glow, and further right for the slide
	layer = CrtLayer.new()
	layer.position = Vector2(-PAD, -PAD)
	layer.size = Vector2(W_MAX + SLIDE + PAD * 2.0, 320.0)
	layer.aberration = ABERRATION
	add_child(layer)
	sheet = Control.new()
	sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet.position = Vector2(PAD, PAD)
	sheet.draw.connect(_draw_sheet)
	layer.content.add_child(sheet)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 3)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.position = Vector2(INSET, BODY_TOP)
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
func _key_row(text: String, _px: int, _color: Color) -> Control:
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
	return _keys_row({"keys": keys, "text": rest})

## A quiet keycap: a faint outline round the key's name, so a hint doesn't outshine what it is for
func _keycap(k: String, px: int) -> Control:
	var cap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Term.AMBER, 0.06)
	sb.border_color = Color(Term.AMBER, 0.45)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 5.0; sb.content_margin_right = 4.0
	sb.content_margin_top = 1.0; sb.content_margin_bottom = 0.0
	cap.add_theme_stylebox_override("panel", sb)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cap.add_child(_label(k, px, Term.AMBER))
	return cap

# ---- row dictionaries -------------------------------------------------------------------------
func _dict_row(d: Dictionary, wraps: Array) -> Control:
	match str(d.get("kind", "text")):
		"head": return _head_row(d)
		"pair": return _pair_row(d)
		"rule": return _rule_row()
		"bar": return _bar_row(d)
		"keys": return _keys_row(d)
	var l := _label(str(d.get("text", "")), int(d.get("size", 16)) - 1, d.get("color", Term.TEXT))
	if d.get("wrap", false):
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		wraps.append(l)
	return l

## The name big, then its code in small spaced capitals with the tag after it in its own colour:
## plain text on one line rather than a boxed chip, so the name is the only thing that shouts
func _head_row(d: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := _label(str(d.get("name", "")), int(d.get("size", 24)), Term.TEXT)
	_fit.append(n)
	v.add_child(n)
	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 8)
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tag := str(d.get("tag", ""))
	var code := _label(str(d.get("code", "")), 12, Term.MUTED, wide)
	code.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if tag == "":
		code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_fit.append(code)
	meta.add_child(code)
	if tag != "":
		meta.add_child(_label("//", 12, Color(Term.MUTED, 0.45), wide))
		var t := _label(tag, 12, d.get("tag_color", Term.AMBER), wide)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_fit.append(t)
		meta.add_child(t)
	v.add_child(meta)
	_stretch.append(v)
	return v

## A name on the left, its value on the sheet's right edge
func _pair_row(d: Dictionary) -> Control:
	var strong: bool = d.get("strong", false)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _label(str(d.get("left", "")), 15 if strong else 14, Term.TEXT if strong else Term.TEXT_DIM)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fit.append(l)
	h.add_child(l)
	var r := _label(str(d.get("right", "")), 16 if strong else 15, d.get("color", Term.AMBER))
	r.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(r)
	_stretch.append(h)
	return h

func _rule_row() -> Control:
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_top", 5)
	m.add_theme_constant_override("margin_bottom", 5)
	var r := ColorRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.color = Color(Term.AMBER, 0.3)
	r.custom_minimum_size.y = 1.0
	r.scale.x = 0.001                # never exactly 0: it draws out from the left
	m.add_child(r)
	_rules.append(r)
	_stretch.append(m)
	return m

## Clearance toward the next tier: the tier on the left, the numbers on the right, a segmented gauge
## under them. What was there before shows dim at once; what this filing added fills in bright.
func _bar_row(d: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _label(str(d.get("left", "")), 13, Term.MUTED, wide)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fit.append(l)
	top.add_child(l)
	var r := _label(str(d.get("right", "")), 13, Term.TEXT_DIM)
	r.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top.add_child(r)
	v.add_child(top)
	var g := Control.new()
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.custom_minimum_size.y = 8.0
	g.set_meta("from", clampf(float(d.get("from", 0.0)), 0.0, 1.0))
	g.set_meta("to", clampf(float(d.get("to", 0.0)), 0.0, 1.0))
	g.set_meta("fill", 0.0)          # 0..1 of the way from `from` to `to`
	g.draw.connect(_draw_gauge.bind(g))
	v.add_child(g)
	_bars.append(g)
	_stretch.append(v)
	return v

func _draw_gauge(g: Control) -> void:
	var from: float = g.get_meta("from")
	var fill: float = g.get_meta("fill")
	var now := lerpf(from, float(g.get_meta("to")), fill)
	var gap := 3.0
	var sw := (g.size.x - gap * (BAR_SEGS - 1)) / BAR_SEGS
	var head := int(ceil(now * BAR_SEGS)) - 1
	for i in BAR_SEGS:
		var e := float(i + 1) / BAR_SEGS
		var c := Color(Term.TEXT, 0.1)
		if e <= from + 0.0001:
			c = Color(Term.AMBER, 0.4)               # already had
		elif e <= now + 0.0001 or i == head:
			c = Term.TEXT if (i == head and fill < 1.0) else Term.AMBER   # this filing; the leading segment runs hot
		g.draw_rect(Rect2(i * (sw + gap), 0.0, sw, g.size.y), c)

func _set_fill(v: float, g: Control) -> void:
	if is_instance_valid(g):
		g.set_meta("fill", v)
		g.queue_redraw()

## Keycaps, then what they do, dim and a little apart from the rows above: a hint, not news. More
## than one key is a sequence ("TAB > F3": open the terminal, then its page), joined by an arrow.
func _keys_row(d: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var keys: Array = d.get("keys", [])
	for i in keys.size():
		if i > 0:
			var arrow := _label("›", 13, Color(Term.MUTED, 0.6))
			arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(arrow)
		row.add_child(_keycap(str(keys[i]), 12))
	var t := _label(str(d.get("text", "")), 13, Term.TEXT_DIM)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var tm := MarginContainer.new()
	tm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tm.add_theme_constant_override("margin_left", 4)
	tm.add_child(t)
	row.add_child(tm)
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_top", 6)
	m.add_child(row)
	return m

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
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	var wraps: Array = []
	_stretch.clear()
	_fit.clear()
	_rules.clear()
	_bars.clear()
	# the title: a small amber overline, not a tab of its own
	var title := _label(str(entry[0]).trim_prefix("[").trim_suffix("]"), 12, Term.AMBER, wide)
	var tm := MarginContainer.new()
	tm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tm.add_theme_constant_override("margin_bottom", 3)
	tm.add_child(title)
	body.add_child(tm)
	for ln in entry[1]:
		if ln is Dictionary:
			body.add_child(_dict_row(ln, wraps))
			continue
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

	_corrupt()
	layer.aberration = ABERRATION + 2.5 * _unease()

	# as wide as its widest line (a sentence takes the full width)
	var w := W_MAX if not wraps.is_empty() else W_MIN
	if wraps.is_empty():
		for row in body.get_children():
			w = maxf(w, (row as Control).get_combined_minimum_size().x + INSET + RIGHT_PAD)
	if not _bars.is_empty():
		w = maxf(w, GAUGE_MIN_W + INSET + RIGHT_PAD)
	w = clampf(w, W_MIN, W_MAX)
	var inner := w - INSET - RIGHT_PAD
	# rows that span the sheet (a value on the right edge, a rule, a gauge) take its inner width; the
	# names in them give way with an ellipsis rather than push it wider
	for c in _stretch:
		(c as Control).custom_minimum_size.x = inner
	for l in _fit:
		(l as Label).clip_text = true
		(l as Label).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	var h := BODY_TOP + body.get_combined_minimum_size().y + BODY_BOTTOM
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
	var labels: Array = body.find_children("*", "Label", true, false)
	for i in labels.size():
		var l: Label = labels[i]
		l.visible_ratio = 0.0
		anim.tween_property(l, "visible_ratio", 1.0, clampf(l.text.length() * 0.012, 0.08, 0.3)).set_delay(0.08 + i * 0.06)
	for i in _rules.size():
		anim.tween_property(_rules[i], "scale:x", 1.0, 0.35).set_delay(0.15 + i * 0.1) \
				.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	for g in _bars:                  # last, once the rows are up
		anim.tween_method(_set_fill.bind(g), 0.0, 1.0, 0.7).set_delay(0.2 + labels.size() * 0.06) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	anim.tween_method(_set_life, 1.0, 0.0, HOLD).set_delay(0.3)
	# out: slide back and fade (the colour tearing apart as it goes), then the next one in the queue
	anim.chain().tween_callback(func(): layer.burst(0.35))
	anim.tween_property(sheet, "position:x", home_x + SLIDE, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	anim.tween_property(sheet, "modulate:a", 0.0, 0.25)
	anim.chain().tween_callback(func(): _next.call_deferred())   # not from inside the tween it replaces

## Low sanity: now and then a toast comes in with one word wrong, either garbled or swapped for
## something it never said. The lower the sanity the likelier (none at CORRUPT_BELOW, every toast 30
## under it). The true word shows through for a frame or two every so often (_process).
## 0 at CORRUPT_BELOW sanity and above, 1 at 0
func _unease() -> float:
	if player == null or not is_instance_valid(player):
		return 0.0
	return clampf(1.0 - float(player.get("sanity")) / CORRUPT_BELOW, 0.0, 1.0)

func _corrupt() -> void:
	_bad = {}
	if player == null or not is_instance_valid(player):
		return
	var k := clampf((CORRUPT_BELOW - float(player.get("sanity"))) / 30.0, 0.0, 1.0)
	if k <= 0.0 or randf() > k:
		return
	var picks: Array = []                    # [label, word index]
	for row in body.get_children():
		var l := row as Label
		if l == null or l.autowrap_mode != TextServer.AUTOWRAP_OFF:
			continue
		var words := l.text.split(" ")
		for i in words.size():
			if _word.search(words[i]) != null:
				picks.append([l, i])
	if picks.is_empty():
		return
	var pick: Array = picks[randi() % picks.size()]
	var lab: Label = pick[0]
	var words := lab.text.split(" ")
	var idx := int(pick[1])
	var real: String = words[idx]
	var fake := ""
	var fits: Array = WRONG_WORDS.filter(func(w): return str(w).length() <= real.length() + 1)
	if not fits.is_empty() and randf() < 0.5:
		fake = str(fits[randi() % fits.size()])
	else:
		for ch in real:
			fake += GARBLE[randi() % GARBLE.length()] if randf() < 0.6 else ch
	var real_text := lab.text
	words[idx] = fake
	lab.text = " ".join(words)
	_bad = {"label": lab, "real": real_text, "fake": lab.text, "t": randf_range(0.8, 2.0)}

func _process(dt: float) -> void:
	if _bad.is_empty():
		return
	if not is_instance_valid(_bad.label):      # the next toast cleared it
		_bad = {}
		return
	var l: Label = _bad.label
	_bad.t -= dt
	if _bad.t > 0.0:
		return
	if l.text == _bad.fake:                  # the true line, for a blink
		l.text = _bad.real
		_bad.t = randf_range(0.05, 0.12)
	else:
		l.text = _bad.fake
		_bad.t = randf_range(0.8, 2.0)

func _set_life(v: float) -> void:
	life = v
	sheet.queue_redraw()

## A dark card with its top-right corner cut, outlined faintly; the life bar runs down its left edge
## (a dim track, the bright part draining from the bottom up)
func _draw_sheet() -> void:
	var w := sheet.size.x
	var h := sheet.size.y
	var c := CHAMFER
	if h <= c * 2.0:                 # nothing pushed yet (the first draw comes before any size)
		return
	var shape := PackedVector2Array([Vector2(0, 0), Vector2(w - c, 0), Vector2(w, c), Vector2(w, h), Vector2(0, h)])
	sheet.draw_colored_polygon(shape, Term.FILL)
	shape.append(Vector2(0, 0))
	sheet.draw_polyline(shape, Color(Term.AMBER, 0.28), LINE_W, true)
	sheet.draw_line(Vector2(w - c, 0), Vector2(w, c), Color(Term.AMBER, 0.8), LINE_W + 1.0, true)
	sheet.draw_rect(Rect2(0.0, 0.0, BAR_W, h), Color(Term.AMBER, 0.18))
	if life > 0.0:
		sheet.draw_rect(Rect2(0.0, h * (1.0 - life), BAR_W, h * life), Term.AMBER)
