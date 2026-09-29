extends Control
## Hazard tape readout (scripts/Player/tape_tool.gd), up while T is held and for a moment after.
## Two parts, both in the camcorder OSD's VCR lettering, on dark backing so they read over the
## bright carpet and wallpaper:
## - on the strip's free end in the view: a ring, a short leader and a tag with the length (and,
##   in orange, what stops the strip growing: EDGE / CORNER / MAX / ROLL LOW)
## - beside the crosshair, a small panel: TAPE and the length over a bar, the roll under it; after
##   a pull, PLACED and the Research Yield the strip earned for mapping; PEELING / RECOVERED when
##   a strip comes back off (tape_tool.gd). It sits on the side of the
##   crosshair away from the strip (the left, unless the strip runs off to the left), so it never
##   covers the tape; the length tag goes on the other side.
##
##   ┌──────────────────────────────┐
##   │ TAPE                  3.42 M │
##   │ ██████████░░░░░░░░░░░░░░░░░░ │
##   │ ROLL 239.1 M            EDGE │
##   └──────────────────────────────┘

const TapeTool := preload("res://scripts/Player/tape_tool.gd")
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")

const SCALE := 1.15              # hud.gd SCALE
const WIDTH := 270.0
const GAP := 44.0                # px between the crosshair and the panel's near edge
const RAISE := 20.0              # the panel's middle sits this far above the crosshair
const FLIP_MARGIN := 90.0        # px the strip has to be over on the panel's side before it moves
const PX := 15                   # text size before SCALE
const TEXT := Color("f2ecd2")    # brighter than the meters: this sits mid-screen over lit carpet
const LABEL := Color("e8d9a0")
const DIM := Color("cfc49a")
const FILL := Color("f4c21a")    # the tape's yellow
const LOW := Color("ff9a3a")
const GOOD := Color("9fe08a")
const BACK := Color(0.02, 0.02, 0.015, 0.62)
const LIMITS := {"MAX": "MAX", "ROLL": "ROLL LOW", "CORNER": "CORNER", "EDGE": "EDGE", "PEEL": "PEELING"}

var tape: Node                   # tape_tool.gd (set by hud.gd)
var inventory: Node
var font := FontVariation.new()
var panel: PanelContainer
var title: Label
var value: Label
var track: ColorRect
var fill: ColorRect
var foot: Label
var status: Label
var marker: Control              # the ring and tag on the strip's end
var shown := 0.0                 # the bar, eased after the tape
var alpha := 0.0
var side := -1.0                 # the panel's side of the crosshair: -1 left, 1 right
var panel_x := 0.0               # eased left edge of the panel, from the crosshair

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 1
	font.variation_embolden = 0.6
	marker = Control.new()
	marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.draw.connect(_draw_marker)
	add_child(marker)
	_build_panel()

func _build_panel() -> void:
	panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = BACK
	sb.border_color = Color(FILL, 0.55)
	sb.border_width_left = 3
	sb.set_content_margin_all(10)
	sb.content_margin_left = 14
	panel.add_theme_stylebox_override("panel", sb)
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top = 0.5; panel.anchor_bottom = 0.5
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel_x = -GAP - WIDTH * SCALE
	_place_panel()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(v)
	var top := _row()
	title = _label("TAPE", LABEL, 3)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value = _label("", TEXT)
	top.add_child(title)
	top.add_child(value)
	v.add_child(top)
	track = ColorRect.new()
	track.color = Color(1, 1, 1, 0.18)
	track.custom_minimum_size = Vector2(0, 5)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill = ColorRect.new()
	fill.color = FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_child(fill)
	v.add_child(track)
	var bottom := _row()
	foot = _label("", DIM, 1, PX - 2)
	foot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status = _label("", LOW, 2, PX - 2)
	bottom.add_child(foot)
	bottom.add_child(status)
	v.add_child(bottom)

func _row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h

func _label(text: String, color: Color, spacing := 1, px := PX) -> Label:
	var fv := FontVariation.new()
	fv.base_font = font.base_font
	fv.spacing_glyph = spacing
	fv.variation_embolden = 0.6
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", fv)
	l.add_theme_font_size_override("font_size", int(px * SCALE))
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _process(dt: float) -> void:
	if not tape:
		return
	var st: String = tape.state
	var want := 0.0 if st == "idle" else 1.0
	alpha = move_toward(alpha, want, dt * (10.0 if want > alpha else 3.0))
	panel.modulate.a = alpha
	marker.queue_redraw()
	if alpha <= 0.0:
		return
	if st == "pull" or st == "peel":
		_pick_side()
	var goal := -GAP - WIDTH * SCALE if side < 0.0 else GAP
	panel_x = goal if alpha < 0.05 else lerpf(panel_x, goal, minf(1.0, dt * 10.0))
	_place_panel()
	var on_roll := float(tape.roll_left) - float(tape.length)
	if st == "peel":                              # peeling winds it back on
		on_roll = minf(TapePickup.ROLL_LENGTH, float(tape.roll_left) + float(tape.peel_full) - float(tape.length))
	var roll := "ROLL %.1f M" % maxf(0.0, on_roll)
	var rolls: int = inventory.item_count(TapePickup.ITEM_ID) if inventory else 1
	if rolls > 1:
		roll += "  x%d" % rolls
	var frac := 0.0
	var fill_col := FILL
	var foot_col := DIM
	match st:
		"pull":
			var lim: String = tape.limit
			_text(title, "TAPE")
			_text(value, "%.2f M" % tape.length)
			_text(foot, roll)
			var word: String = LIMITS.get(lim, "")
			if lim == "" and tape.length < TapeTool.MIN_STRIP:
				word = "PULL"
			_text(status, word)
			_color(status, LOW if lim != "" else DIM)
			frac = tape.length / TapeTool.MAX_STRIP
			if lim != "":
				fill_col = LOW
		"placed":
			var ry: int = tape.result_ry
			_text(title, "PLACED")
			_text(value, "%.2f M" % tape.result_len)
			_text(foot, "+%d %s  CORRIDOR MAPPED" % [ry, Clearance.unit] if ry > 0 else roll)
			if ry > 0:
				foot_col = GOOD
			_text(status, "")
			frac = tape.result_len / TapeTool.MAX_STRIP
		"short":
			_text(title, "TOO SHORT")
			_text(value, "")
			_text(foot, roll)
			_text(status, "")
		"no_surface":
			_text(title, "TAPE")
			_text(value, "--")
			_text(foot, "NOTHING IN REACH")
			_text(status, "")
		"no_tape":
			_text(title, "NO TAPE")
			_text(value, "")
			_text(foot, "FIND A ROLL, OR PEEL A STRIP BACK")
			_text(status, "")
		"peel":
			_text(title, "PEELING")
			_text(value, "%.2f M" % tape.length)
			_text(foot, roll)
			_text(status, "HOLD")
			_color(status, DIM)
			frac = tape.length / maxf(float(tape.peel_full), 0.01)
			fill_col = LOW
		"peeled":
			_text(title, "RECOVERED")
			_text(value, "%.2f M" % tape.result_len)
			_text(foot, roll)
			_text(status, "")
	_color(foot, foot_col)
	shown = lerpf(shown, clampf(frac, 0.0, 1.0), minf(1.0, dt * 14.0))
	fill.color = fill_col
	fill.size = Vector2(track.size.x * shown, track.size.y)

func _place_panel() -> void:
	panel.offset_left = panel_x
	panel.offset_right = panel_x + WIDTH * SCALE
	panel.offset_top = -RAISE
	panel.offset_bottom = -RAISE

## The panel goes on the side of the crosshair the strip isn't on: where the stuck end shows on
## screen (or, off screen / behind you, which way it lies), with some slack so it doesn't flicker
## across as the strip swings past the middle
func _pick_side() -> void:
	var cam: Camera3D = tape.player.cam
	if cam == null:
		return
	var a: Vector3 = tape.anchor
	var cx := size.x * 0.5
	var dx := 0.0
	if not cam.is_position_behind(a):
		dx = cam.unproject_position(a).x - cx
	else:
		dx = (cam.global_transform.affine_inverse() * a).x * 1000.0
	if side < 0.0 and dx < -FLIP_MARGIN:
		side = 1.0
	elif side > 0.0 and dx > FLIP_MARGIN:
		side = -1.0

## The ring on the strip's free end, a leader up and out, and the length on a dark tag
func _draw_marker() -> void:
	if alpha <= 0.0 or not tape or not (tape.state == "pull" or tape.state == "peel"):
		return
	var cam: Camera3D = tape.player.cam
	var tip: Vector3 = tape.tip
	if cam == null or cam.is_position_behind(tip):
		return
	var p := cam.unproject_position(tip)
	var lim: String = tape.limit
	var col := LOW if lim != "" else FILL
	var a := alpha
	var shadow := Color(0, 0, 0, 0.7 * a)
	# ring with a dark rim so it holds on bright carpet
	marker.draw_arc(p, 10.0, 0.0, TAU, 32, shadow, 5.0, true)
	marker.draw_arc(p, 10.0, 0.0, TAU, 32, Color(col, a), 2.5, true)
	marker.draw_circle(p, 2.5, Color(col, a))
	# leader: up and to the side, away from the panel
	var tag_side := -side                   # the other side from the panel ...
	if p.x + tag_side * 260.0 > size.x - 20.0 or p.x + tag_side * 260.0 < 20.0:
		tag_side = -tag_side                         # ... unless the screen ends there
	var k := p + Vector2(tag_side * 30.0, -34.0)
	var e := k + Vector2(tag_side * 70.0, 0.0)
	var pts := PackedVector2Array([p + Vector2(tag_side * 7.0, -7.0), k, e])
	marker.draw_polyline(pts, shadow, 4.5, true)
	marker.draw_polyline(pts, Color(col, a), 2.0, true)
	# the tag: length, and what stops it in orange under it
	var big := int(22 * SCALE)
	var small := int(13 * SCALE)
	var txt := "%.1f M" % tape.length
	var sub: String = LIMITS.get(lim, "")
	var tw := maxf(font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x,
		font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, small).x)
	var h := float(big) + (float(small) + 4.0 if sub != "" else 0.0) + 10.0
	var x := e.x + 6.0 if tag_side > 0.0 else e.x - 6.0 - tw - 16.0
	var box := Rect2(x, e.y - big * 0.5 - 6.0, tw + 16.0, h)
	marker.draw_rect(box, Color(BACK, BACK.a * a))
	marker.draw_rect(Rect2(box.position.x if tag_side > 0.0 else box.end.x - 3.0, box.position.y, 3.0, box.size.y), Color(col, a))
	var tx := box.position.x + 8.0 + (1.0 if tag_side > 0.0 else 0.0)
	marker.draw_string_outline(font, Vector2(tx, box.position.y + 5.0 + big * 0.85), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, big, 4, Color(0, 0, 0, 0.9 * a))
	marker.draw_string(font, Vector2(tx, box.position.y + 5.0 + big * 0.85), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, big, Color(TEXT, a))
	if sub != "":
		var sy := box.position.y + 5.0 + big + 4.0 + small * 0.85
		marker.draw_string(font, Vector2(tx, sy), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, small, Color(LOW, a))

## Only on change: a label re-shapes its text when set, and a theme override is a theme update
func _text(l: Label, text: String) -> void:
	if l.text != text:
		l.text = text

func _color(l: Label, c: Color) -> void:
	if l.get_meta("col", Color.TRANSPARENT) != c:
		l.set_meta("col", c)
		l.add_theme_color_override("font_color", c)
