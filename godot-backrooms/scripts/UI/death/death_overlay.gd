extends CanvasLayer
## The death screen (the web game's #death-screen): a dark gradient from the bottom, a red-black
## vignette, and bottom-left "[dot] SIGNAL LOST / YOU DIED / <killer>". That holds a moment, then
## tears out like a tape losing tracking and the camcorder's end card comes up in its place:
## "[stop] STOP // LEVEL / RECORDING ENDED" over this life's numbers (Game.run_stats()), counting up
## one row after another, then the respawn prompt. Built by Game.kill_player(); it animates itself
## off its own clock `t` (so skip() can jump it to the end) and is freed on the respawn.

const DIM_CREAM := Color(0.902, 0.882, 0.804, 0.55)
const KILLER_CREAM := Color(0.902, 0.882, 0.804, 0.50)
const BTN_CREAM := Color(0.902, 0.882, 0.804, 0.80)
const LINE_CREAM := Color(0.902, 0.882, 0.804, 0.35)
const RULE_CREAM := Color(0.902, 0.882, 0.804, 0.18)
const VALUE_CREAM := Color(0.902, 0.882, 0.804, 0.92)
const TITLE_COLOR := Color("d8d3bd")
const DOT_RED := Color("c4271f")
const SHADOW_RED := Color(0.627, 0.078, 0.059, 0.55)

const SWAP := 2.7                  # YOU DIED starts to tear out
const TEAR := 0.32                 # ... and is gone after this
const REC_IN := SWAP + 0.22        # the end card flickers on
const ROWS_AT := REC_IN + 0.6      # first stat row
const ROW_STEP := 0.14
const ROW_DUR := 0.6               # each value counts up over this
const SHEET_W := 520.0

var ready_at := 1.6                # seconds before a click is taken (Game.RESPAWN_READY)
var t := 0.0
var done_at := 0.0                 # the whole card is in: the prompt shows, a click respawns
var shown := 1.0                   # eased out while the pause menu is over the death screen
var _root: Control
var _veil: TextureRect
var _anchor: Control
var _box: VBoxContainer
var _title: Label
var _dot: ColorRect
var _rec_anchor: Control
var _rec: VBoxContainer
var _rec_tag: Label
var _rec_title: Label
var _rules: Array[ColorRect] = []
var _rows: Array = []              # [row, value label, target, kind]
var _respawn: Control

func _init(killer: String, respawn_ready: float, stats := {}) -> void:
	layer = 30
	ready_at = respawn_ready
	_build(killer, stats)
	done_at = ROWS_AT + ROW_STEP * maxf(_rows.size() - 1, 0) + ROW_DUR + 0.25

func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	if ResourceLoader.exists("res://fonts/vcr.ttf"):
		fv.base_font = load("res://fonts/vcr.ttf")
	fv.spacing_glyph = int(spacing)
	return fv

func _ignore(c: Control) -> Control:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _label(text: String, spacing: float, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	_ignore(l)
	return l

func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return _ignore(s)

func _gradient(offsets: Array, colors: Array, fill: int, from: Vector2, to: Vector2, w: int, h: int) -> TextureRect:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = w
	tex.height = h
	tex.fill = fill
	tex.fill_from = from
	tex.fill_to = to
	var r := TextureRect.new()
	r.texture = tex
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.stretch_mode = TextureRect.STRETCH_SCALE
	_ignore(r)
	return r

## A block pinned by its bottom-left corner at (8vw, 86vh), growing up and right so it stays on screen
func _corner_box(parent: Control) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.anchor_left = 0.08
	b.anchor_right = 0.08
	b.anchor_top = 0.86
	b.anchor_bottom = 0.86
	b.grow_horizontal = Control.GROW_DIRECTION_END
	b.grow_vertical = Control.GROW_DIRECTION_BEGIN
	parent.add_child(_ignore(b))
	return b

func _build(killer: String, stats: Dictionary) -> void:
	_root = _ignore(Control.new())
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.modulate.a = 0.0
	add_child(_root)
	# linear-gradient(to top, rgba(0,0,0,0.85) 0%, rgba(0,0,0,0.35) 45%, rgba(0,0,0,0) 75%)
	_root.add_child(_gradient([0.0, 0.45, 0.75, 1.0],
		[Color(0, 0, 0, 0.85), Color(0, 0, 0, 0.35), Color(0, 0, 0, 0), Color(0, 0, 0, 0)],
		GradientTexture2D.FILL_LINEAR, Vector2(0, 1), Vector2(0, 0), 64, 256))
	# radial-gradient(circle at center, rgba(0,0,0,0) 45%, rgba(20,0,0,0.7) 100%)
	_root.add_child(_gradient([0.0, 0.45, 1.0], [Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0.08, 0, 0, 0.70)],
		GradientTexture2D.FILL_RADIAL, Vector2(0.5, 0.5), Vector2(1, 1), 256, 256))
	# the end card is taller than YOU DIED: a left-hand shade comes up under it so the rows read over
	# a bright room
	_veil = _gradient([0.0, 0.45, 0.8], [Color(0, 0, 0, 0.6), Color(0, 0, 0, 0.3), Color(0, 0, 0, 0)],
		GradientTexture2D.FILL_LINEAR, Vector2(0, 0), Vector2(1, 0), 256, 1)
	_veil.modulate.a = 0.0
	_root.add_child(_veil)

	# ---- YOU DIED -------------------------------------------------------------------
	_anchor = _ignore(Control.new())
	_anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_anchor)
	_box = _corner_box(_anchor)
	_box.add_theme_constant_override("separation", 6)
	_box.modulate.a = 0.0

	# .death-tag: [dot] SIGNAL LOST
	var tag := HBoxContainer.new()
	tag.add_theme_constant_override("separation", 8)
	_box.add_child(_ignore(tag))
	var dot_c := CenterContainer.new()
	dot_c.custom_minimum_size = Vector2(8, 16)
	tag.add_child(_ignore(dot_c))
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(8, 8)
	_dot.color = DOT_RED
	dot_c.add_child(_ignore(_dot))
	tag.add_child(_label("SIGNAL LOST", 4.0, 13, DIM_CREAM))

	_title = _label("YOU DIED", 2.0, 76, TITLE_COLOR)
	_title.add_theme_color_override("font_shadow_color", SHADOW_RED)
	_title.add_theme_constant_override("shadow_offset_x", 2)
	_title.add_theme_constant_override("shadow_offset_y", 0)
	_box.add_child(_title)
	_box.add_child(_label(killer.to_upper(), 4.0, 14, KILLER_CREAM))

	# ---- RECORDING ENDED ------------------------------------------------------------
	_rec_anchor = _ignore(Control.new())
	_rec_anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_rec_anchor)
	_rec = _corner_box(_rec_anchor)
	_rec.add_theme_constant_override("separation", 0)
	_rec.visible = false

	# the REC dot has stopped: a steady square, like the camcorder's STOP
	var rtag := HBoxContainer.new()
	rtag.add_theme_constant_override("separation", 10)
	_rec.add_child(_ignore(rtag))
	var sq_c := CenterContainer.new()
	sq_c.custom_minimum_size = Vector2(9, 16)
	rtag.add_child(_ignore(sq_c))
	var sq := ColorRect.new()
	sq.custom_minimum_size = Vector2(9, 9)
	sq.color = DOT_RED
	sq_c.add_child(_ignore(sq))
	_rec_tag = _label("STOP  //  %s" % str(stats.get("level", "LEVEL 0")), 4.0, 13, DIM_CREAM)
	rtag.add_child(_rec_tag)
	_rec.add_child(_spacer(8))
	_rec_title = _label("RECORDING ENDED", 2.0, 58, TITLE_COLOR)
	_rec_title.add_theme_color_override("font_shadow_color", SHADOW_RED)
	_rec_title.add_theme_constant_override("shadow_offset_x", 2)
	_rec_title.add_theme_constant_override("shadow_offset_y", 0)
	_rec.add_child(_rec_title)
	_rec.add_child(_spacer(22))

	_rec.add_child(_rule())
	var unit := str(stats.get("unit", "RY"))
	_row("CAUSE", killer.to_upper(), "text")
	_row("TIME ON TAPE", float(stats.get("time", 0.0)), "time")
	_row("DISTANCE", float(stats.get("distance", 0.0)), "metres")
	_row("ENTRIES LOGGED", float(stats.get("logged", 0)), "count")
	_row("RESEARCH YIELD", float(stats.get("yield", 0)), "yield:" + unit)
	_rec.add_child(_rule())
	_rec.add_child(_spacer(30))

	# CLICK OR PRESS SPACE TO RESPAWN, underlined
	var respawn := VBoxContainer.new()
	respawn.add_theme_constant_override("separation", 4)
	respawn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	respawn.modulate.a = 0.0
	_rec.add_child(_ignore(respawn))
	_respawn = respawn
	respawn.add_child(_label("CLICK OR PRESS SPACE TO RESPAWN", 3.0, 13, BTN_CREAM))
	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(0, 1)
	line.color = LINE_CREAM
	respawn.add_child(_ignore(line))

## A hairline across the sheet; it draws out from the left as the card comes on
func _rule() -> Control:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	var r := ColorRect.new()
	r.custom_minimum_size = Vector2(SHEET_W, 1)
	r.color = RULE_CREAM
	r.scale.x = 0.001
	m.add_child(_ignore(r))
	_rules.append(r)
	return _ignore(m)

## One stat: its name on the left, the value right-aligned at the sheet's edge
func _row(caption: String, value, kind: String) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(SHEET_W, 34)
	row.modulate.a = 0.0
	var n := _label(caption, 3.0, 13, DIM_CREAM)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(n)
	var v := _label("", 2.0, 17, VALUE_CREAM)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# numbers count up from 0, so reserve the final width now and the row never reflows
	v.custom_minimum_size.x = v.get_theme_font("font").get_string_size(_format(value, kind, 1.0),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x + 4.0
	row.add_child(v)
	_rec.add_child(_ignore(row))
	_rows.append([row, v, value, kind])

## The value as shown `u` (0..1) of the way through its count-up
func _format(value, kind: String, u: float) -> String:
	match kind:
		"text":
			return str(value)
		"time":
			var s := float(value) * u
			return "%d:%02d:%02d" % [int(s / 3600.0), int(s / 60.0) % 60, int(s) % 60]
		"metres":
			return "%d M" % roundi(float(value) * u)
		"count":
			return "%02d" % roundi(float(value) * u)
	if kind.begins_with("yield:"):
		return "+%d %s" % [roundi(float(value) * u), kind.substr(6)]
	return str(value)

## Game: the first click / Space after RESPAWN_READY brings the whole card in at once
func skip() -> void:
	t = maxf(t, done_at)

func finished() -> bool:
	return t >= done_at

static func _ease_out(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, 3.0)

## Alpha curve for a CRT-style power-on: dim, blink out, flash, settle
static func _flicker(x: float) -> float:
	if x <= 0.0: return 0.0
	if x < 0.2: return 0.85 * x / 0.2
	if x < 0.35: return 0.15
	if x < 0.5: return 1.0
	if x < 0.62: return 0.45
	return 1.0

## Steady noise per frame step, so the tear jitters instead of swimming
static func _hash(n: float) -> float:
	return fposmod(sin(n * 12.9898) * 43758.5453, 1.0)

func _process(dt: float) -> void:
	# The pause menu over the death screen has the input and the bottom-left corner: step out of its
	# way, and hold the clock so the card isn't missed behind it
	var paused := not Game.playing
	shown = move_toward(shown, 0.0 if paused else 1.0, dt * 5.0)
	if not paused:
		t += dt
	# #death-screen transition: opacity 0.5s ease-out
	_root.modulate.a = clampf(t / 0.5, 0.0, 1.0) * shown
	_update_death_block()
	_update_end_card()

func _update_death_block() -> void:
	if t >= SWAP + TEAR:
		_box.visible = false
		return
	# .death-box animation: deathIn 1.2s ease-out (fade + translateY 8px -> 0), a beat after the hit
	var p := _ease_out((t - 0.25) / 1.2)
	_box.modulate.a = p
	_anchor.position = Vector2(0.0, 8.0 * (1.0 - p))
	# .death-tag i blink: 1.1s steps(1) infinite (50% on, 50% off)
	_dot.visible = fmod(t, 1.1) < 0.55
	if t < SWAP:
		return
	# tracking lost: the block jumps sideways in steps, the red shadow tears off, it blinks out
	var k := (t - SWAP) / TEAR
	var step := floorf(t * 30.0)
	_anchor.position.x = (_hash(step) - 0.5) * 28.0 * (1.0 - k * 0.5)
	_title.add_theme_constant_override("shadow_offset_x", int(2.0 + 16.0 * k * _hash(step + 3.0)))
	# a tear frame is either there or mostly not
	_box.modulate.a = (1.0 - k) * (1.0 if _hash(step + 7.0) > 0.35 else 0.25)

func _update_end_card() -> void:
	if t < REC_IN:
		return
	_rec.visible = true
	var u := t - REC_IN
	_veil.modulate.a = _ease_out(u / 0.8)
	_rec.modulate.a = _flicker(u / 0.35)
	_rec_anchor.position.y = 10.0 * (1.0 - _ease_out(u / 0.8))
	_rec_tag.visible_ratio = clampf(u / 0.35, 0.0, 1.0)
	_rec_title.visible_ratio = clampf((u - 0.08) / 0.45, 0.0, 1.0)
	_rules[0].scale.x = maxf(0.001, _ease_out((t - (ROWS_AT - 0.2)) / 0.5))
	_rules[1].scale.x = maxf(0.001, _ease_out((t - (done_at - 0.45)) / 0.5))
	for i in _rows.size():
		var r: Array = _rows[i]
		var ru := clampf((t - (ROWS_AT + i * ROW_STEP)) / ROW_DUR, 0.0, 1.0)
		(r[0] as Control).modulate.a = clampf(ru * 3.0, 0.0, 1.0)
		var lbl: Label = r[1]
		if r[3] == "text":           # the cause types itself out rather than counting
			lbl.text = str(r[2])
			lbl.visible_ratio = ru
		else:
			lbl.text = _format(r[2], r[3], _ease_out(ru))
	# the respawn prompt once the card is in and a click will be taken, then breathes slowly
	var at := maxf(done_at, ready_at)
	var p := clampf((t - at) / 0.6, 0.0, 1.0)
	_respawn.modulate.a = p * (0.75 + 0.25 * cos((t - at) * 2.2))
