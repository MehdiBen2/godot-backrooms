extends Control
## Hazard tape readout (scripts/Player/tape_tool.gd), up while T is held and for a moment after.
## Two parts, both in the camcorder OSD's VCR lettering, on dark backing so they read over the
## bright carpet and wallpaper:
## - on the strip's free end in the view: a ring, a short leader and a tag with the length (and,
##   in orange, what stops the strip growing: EDGE / CORNER / MAX / ROLL LOW)
## - under the crosshair, a small panel: TAPE and the length over a bar, the roll under it; after
##   a pull, PLACED and the Research Yield the strip earned for mapping
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
const BELOW := 70.0              # px from the crosshair down to the panel
const PX := 15                   # text size before SCALE
const TEXT := Color("f2ecd2")    # brighter than the meters: this sits mid-screen over lit carpet
const LABEL := Color("e8d9a0")
const DIM := Color("cfc49a")
const FILL := Color("f4c21a")    # the tape's yellow
const LOW := Color("ff9a3a")
const GOOD := Color("9fe08a")
const BACK := Color(0.02, 0.02, 0.015, 0.62)
const LIMITS := {"MAX": "MAX", "ROLL": "ROLL LOW", "CORNER": "CORNER", "EDGE": "EDGE"}

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
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.anchor_top = 0.5; panel.anchor_bottom = 0.5
	var w := WIDTH * SCALE
	panel.offset_left = -w * 0.5; panel.offset_right = w * 0.5
	panel.offset_top = BELOW; panel.offset_bottom = BELOW
	panel.grow_vertical = Control.GROW_DIRECTION_END
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
	var roll := "ROLL %.1f M" % maxf(0.0, float(tape.roll_left) - float(tape.length))
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
	_color(foot, foot_col)
	shown = lerpf(shown, clampf(frac, 0.0, 1.0), minf(1.0, dt * 14.0))
	fill.color = fill_col
	fill.size = Vector2(track.size.x * shown, track.size.y)

## The ring on the strip's free end, a leader up and out, and the length on a dark tag
func _draw_marker() -> void:
	if alpha <= 0.0 or not tape or tape.state != "pull":
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
	# leader: up and to the side with room on screen
	var side := 1.0 if p.x < size.x - 260.0 else -1.0
	var k := p + Vector2(side * 30.0, -34.0)
	var e := k + Vector2(side * 70.0, 0.0)
	var pts := PackedVector2Array([p + Vector2(side * 7.0, -7.0), k, e])
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
	var x := e.x + 6.0 if side > 0.0 else e.x - 6.0 - tw - 16.0
	var box := Rect2(x, e.y - big * 0.5 - 6.0, tw + 16.0, h)
	marker.draw_rect(box, Color(BACK, BACK.a * a))
	marker.draw_rect(Rect2(box.position.x if side > 0.0 else box.end.x - 3.0, box.position.y, 3.0, box.size.y), Color(col, a))
	var tx := box.position.x + 8.0 + (1.0 if side > 0.0 else 0.0)
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
