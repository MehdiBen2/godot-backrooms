extends Control
## Hazard tape readout (scripts/Player/tape_tool.gd), in the camcorder OSD's own style: the same
## small VCR lettering, colours and 2 px bar as the meters bottom-left (hud.gd _meter), sitting
## under the crosshair while T is held and for a moment after. Nothing more: the strip itself, in
## the world, is the real feedback.
##
##   TAPE                 3.42 M       PLACED               3.42 M
##   ============------------------    ==============================
##   ROLL 239.1 M           EDGE       +3 RY  CORRIDOR MAPPED

const TapeTool := preload("res://scripts/Player/tape_tool.gd")
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")

const SCALE := 1.15              # hud.gd SCALE
const WIDTH := 250.0             # like the meters
const BELOW := 64.0              # px under the crosshair
const METER_LABEL := Color("b5a975")
const METER_VAL := Color("ded6ad")
const HINT := Color("9c9268")
const FILL := Color("e0c341")
const LOW := Color("e59d3a")     # hud.gd's "low" meter colour
const GOOD := Color("a8d08d")
const LIMITS := {"MAX": "MAX", "ROLL": "ROLL LOW", "CORNER": "CORNER", "EDGE": "EDGE"}

var tape: Node                   # tape_tool.gd (set by hud.gd)
var inventory: Node
var font: FontFile = load("res://fonts/vcr.ttf")
var title: Label
var value: Label
var track: ColorRect
var fill: ColorRect
var foot: Label
var status: Label
var shown := 0.0                 # the bar, eased after the tape

func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER)
	var w := WIDTH * SCALE
	offset_left = -w * 0.5; offset_right = w * 0.5
	offset_top = BELOW; offset_bottom = BELOW + 60.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	modulate.a = 0.0
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", int(5 * SCALE))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(v)
	var top := _row()
	title = _label("TAPE", METER_LABEL, 2.5)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value = _label("", METER_VAL)
	top.add_child(title)
	top.add_child(value)
	v.add_child(top)
	track = ColorRect.new()
	track.color = Color(1, 1, 1, 0.12)
	track.custom_minimum_size = Vector2(0, 2)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill = ColorRect.new()
	fill.color = FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_child(fill)
	v.add_child(track)
	var bottom := _row()
	foot = _label("", HINT)
	foot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status = _label("", LOW)
	bottom.add_child(foot)
	bottom.add_child(status)
	v.add_child(bottom)

func _row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h

func _label(text: String, color: Color, spacing := 1.5) -> Label:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	fv.variation_embolden = 0.6
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", fv)
	l.add_theme_font_size_override("font_size", int(13 * SCALE))
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _process(dt: float) -> void:
	if not tape:
		return
	var st: String = tape.state
	var want := 0.0 if st == "idle" else 1.0
	modulate.a = move_toward(modulate.a, want, dt * (10.0 if want > modulate.a else 3.0))
	if modulate.a <= 0.0:
		return
	var roll := "ROLL %.1f M" % maxf(0.0, float(tape.roll_left) - float(tape.length))
	var rolls: int = inventory.item_count(TapePickup.ITEM_ID) if inventory else 1
	if rolls > 1:
		roll += "  x%d" % rolls
	var frac := 0.0
	var fill_col := FILL
	var foot_col := HINT
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
			_color(status, LOW if lim != "" else HINT)
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

## Only on change: a label re-shapes its text when set, and a theme override is a theme update
func _text(l: Label, text: String) -> void:
	if l.text != text:
		l.text = text

func _color(l: Label, c: Color) -> void:
	if l.get_meta("col", Color.TRANSPARENT) != c:
		l.set_meta("col", c)
		l.add_theme_color_override("font_color", c)
