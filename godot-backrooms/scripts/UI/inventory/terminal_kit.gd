extends RefCounted
## The TAB terminal's palette and widget helpers, shared by the terminal itself (inventory.gd, as
## Kit.label(...) etc.) and its sheet pages (scripts/UI/inventory/pages/, which extend this through
## terminal_page.gd and call them bare). All static: nothing here holds state but the font cache.

# amber phosphor palette; low / critical states match the HUD meters (hud.gd _set_meter)
const AMBER := Color("f0a838")
const AMBER_DIM := Color(0.941, 0.659, 0.22, 0.38)
const TEXT := Color("dccd9f")
const TEXT_DIM := Color(0.949, 0.902, 0.722, 0.5)
const MUTED := Color("b3a57a")
const GREEN := Color("5de08f")
const ORANGE := Color("e8702c")      # low: pulled toward red so it still reads apart from AMBER
const RED := Color("ff4636")
const FILL := Color(0.035, 0.028, 0.014, 0.8)

const LINE := 4                  # outline weight: boxes, bars, the sheet and its tabs (shown x WINDOW_SCALE)

const FONT := preload("res://fonts/vcr.ttf")
static var font_cache := {}          # glyph spacing -> FontVariation

static func font(spacing: float) -> FontVariation:
	var key := int(spacing)
	if not font_cache.has(key):
		var fv := FontVariation.new()
		fv.base_font = FONT
		fv.spacing_glyph = key
		fv.variation_embolden = 0.4
		font_cache[key] = fv
	return font_cache[key]

## VCR OSD Mono has no em/en dash or multiplication sign; anything it lacks would drop to another
## font mid-line, so archive text is folded onto glyphs it does have
static func vcr(s: String) -> String:
	return s.replace("—", "-").replace("–", "-").replace("×", "x")

static func label(text: String, px: int, color: Color, spacing := 1.0, wrap := false) -> Label:
	var l := Label.new()
	l.text = vcr(text)
	l.add_theme_font_override("font", font(spacing))
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING   # type-in keeps the wrapping
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

static func box(fill: Color, border := Color(0, 0, 0, 0), width := 0, radius := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	return sb

static func spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s

static func spacer_w(w: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.x = w
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

static func hline(color: Color, h: float) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.custom_minimum_size = Vector2(0, h)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

static func clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()

## Scroll area with a thin amber bar, as on the concept sheet
static func scroll() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var bar := s.get_v_scroll_bar()
	bar.custom_minimum_size.x = 12
	bar.add_theme_stylebox_override("scroll", box(Color(0, 0, 0, 0.35), AMBER_DIM, 2))
	bar.add_theme_stylebox_override("scroll_focus", box(Color(0, 0, 0, 0.35), AMBER_DIM, 2))
	bar.add_theme_stylebox_override("grabber", box(Color(AMBER, 0.7)))
	bar.add_theme_stylebox_override("grabber_highlight", box(AMBER))
	bar.add_theme_stylebox_override("grabber_pressed", box(AMBER))
	return s

## The VBox a scroll() holds, kept clear of its bar
static func scroll_body(s: ScrollContainer, gap: int) -> VBoxContainer:
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_theme_constant_override("margin_right", 18)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", gap)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(v)
	return v

## Segmented gauge: `filled` of `n` cells lit in `color` (metadata, set through set_cells). The
## rest are a faint ghost of the same colour, or with `dots` a small square each (the INV rows'
## ". . . ."). Optional extras (set_extras): `trail` cells past the lit ones drawn in `trail_color`,
## and a `dead` cell drawn as nothing at all.
static func cells(n: int, gap: float, dots: bool) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.set_meta("filled", 0)
	c.set_meta("color", AMBER)
	c.draw.connect(func():
		var filled: int = c.get_meta("filled")
		var col: Color = c.get_meta("color")
		var trail: int = c.get_meta("trail", 0)
		var trail_col: Color = c.get_meta("trail_color", Color(col, 0.35))
		var dead: int = c.get_meta("dead", -1)
		var w := (c.size.x - gap * (n - 1)) / n
		var h := c.size.y
		for i in n:
			var x := i * (w + gap)
			if i == dead:
				continue
			if i < filled:
				if dots: c.draw_rect(Rect2(x, h * 0.14, w, h * 0.72), col)
				else: c.draw_rect(Rect2(x, 0, w, h), col)
			elif i < trail and not dots:
				c.draw_rect(Rect2(x, 0, w, h), trail_col)
			elif dots:
				var d := minf(w, h) * 0.26
				c.draw_rect(Rect2(x + (w - d) * 0.5, h * 0.86 - d, d, d), Color(col, 0.6))
			else:
				c.draw_rect(Rect2(x, 0, w, h), Color(col, 0.07))
	)
	return c

static func set_cells(c: Control, filled: int, col: Color) -> void:
	if c.get_meta("filled") == filled and c.get_meta("color") == col:
		return
	c.set_meta("filled", filled)
	c.set_meta("color", col)
	c.queue_redraw()

## A bar's extras (vitals_panel.gd): `trail` cells lit dim past the filled ones in `trail_col` (what
## was just lost), and `dead` the one cell showing nothing (-1 for none)
static func set_extras(c: Control, trail: int, trail_col: Color, dead: int) -> void:
	if c.get_meta("trail", 0) == trail and c.get_meta("dead", -1) == dead and c.get_meta("trail_color", Color()) == trail_col:
		return
	c.set_meta("trail", trail)
	c.set_meta("trail_color", trail_col)
	c.set_meta("dead", dead)
	c.queue_redraw()

## Redaction bars standing in for text not on file yet: the same ones every time for this id
static func redacted(id: String, bars: int) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rng := RandomNumberGenerator.new()
	rng.seed = id.hash() + bars
	for i in bars:
		var bar := ColorRect.new()
		bar.color = Color(TEXT, 0.22)
		bar.custom_minimum_size = Vector2(rng.randi_range(50, 150), 14)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(bar)
	return h

## Unix seconds -> "YYYY-MM-DD HH:MM" on this machine's clock
static func local_time(unix: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(unix + bias)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]
