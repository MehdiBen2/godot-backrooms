extends Control
## Hazard tape HUD (scripts/Player/tape_tool.gd), up while T is held and for a moment after:
## - a "TAPE MODE" chip at the top middle, a hazard-striped square before it
## - on the strip itself: a small diamond on the end stuck down, and on the free end a ring with a
##   tag on a short leader: the length, and what the strip is on (or what stops it: the edge of
##   the surface, a corner, the longest pull, the end of the roll)
## - along the bottom, a metre gauge 0..MAX_STRIP filling with black and yellow hazard stripes,
##   and under it what is left on the roll and how many rolls you carry, then what to do
## - on release, the result under the crosshair: placed (and how long), too short, or nothing
##   in reach
## Drawn inside a crt_layer.gd like the scanner's reticle (scan_readout.gd), so it glows, flickers
## and tears with the rest of the terminal UI.

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")
const TapeTool := preload("res://scripts/Player/tape_tool.gd")
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")

const GAUGE_W := 640.0
const GAUGE_H := 16.0
const GAUGE_BOTTOM := 150.0      # gauge baseline, up from the bottom edge
const CHIP_TOP := 42.0
const LINE_W := 1.5
const YELLOW := Color("f4c21a")  # the tape's own yellow
const STRIPE := 14.0             # px: hazard stripe period
const LIMITS := {
	"MAX": "MAX LENGTH",
	"ROLL": "ROLL RUNNING OUT",
	"CORNER": "CORNER",
	"EDGE": "EDGE OF SURFACE",
}

var tape: Node                   # tape_tool.gd (set by hud.gd)
var inventory: Node
var layer: CrtLayer
var canvas: Control
var font := FontVariation.new()
var wide := FontVariation.new()
var alpha := 0.0
var t := 0.0
var shown_len := 0.0             # the gauge eases after the tape
var last_state := "idle"
var pop := 0.0                   # 0..1 the result text punching in

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 1
	font.variation_embolden = 0.4
	wide.base_font = font.base_font
	wide.spacing_glyph = 4
	wide.variation_embolden = 0.4
	layer = CrtLayer.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layer)
	canvas = Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.draw.connect(_draw_canvas)
	layer.content.add_child(canvas)

func _process(dt: float) -> void:
	if not tape:
		return
	t += dt
	var st: String = tape.state
	if st != last_state:
		if st == "pull":
			layer.burst(0.4)
			shown_len = 0.0
		elif st != "idle":
			pop = 0.0
			layer.burst(0.5 if st == "placed" else 0.3)
		last_state = st
	var want := 0.0 if st == "idle" else 1.0
	alpha = move_toward(alpha, want, dt * (9.0 if want > alpha else 4.0))
	if alpha <= 0.0:
		layer.running = false
		return
	layer.running = true
	shown_len = lerpf(shown_len, tape.length, minf(1.0, dt * 14.0))
	pop = move_toward(pop, 1.0, dt * 6.0)
	canvas.queue_redraw()

# ---- drawing --------------------------------------------------------------------------
func _draw_canvas() -> void:
	if alpha <= 0.001 or not tape:
		return
	var st: String = tape.state
	var c := canvas.size * 0.5
	_draw_chip(c.x)
	if st == "pull":
		_draw_ends()
		_draw_gauge(c.x, canvas.size.y - GAUGE_BOTTOM)
	else:
		_draw_result(c)

## "TAPE MODE", a hazard-striped square before it
func _draw_chip(cx: float) -> void:
	var label := "TAPE MODE"
	var w := _text_w(label, 18, wide)
	var x := cx - (w + 22.0) * 0.5
	_hazard(Rect2(x, CHIP_TOP + 2.0, 13.0, 13.0), 1.0)
	_text(Vector2(x + 22.0, CHIP_TOP + 16.0), label, 18, _a(YELLOW), w + 4.0, HORIZONTAL_ALIGNMENT_LEFT, wide)

## The strip's two ends where they are in the view: a diamond on the stuck end, a ring and the
## length tag on the free one
func _draw_ends() -> void:
	var cam: Camera3D = tape.player.cam
	if cam == null:
		return
	var a: Vector3 = tape.anchor
	var b: Vector3 = tape.tip
	var sa := Vector2.ZERO
	var has_a := not cam.is_position_behind(a)
	if has_a:
		sa = cam.unproject_position(a)
		var d := 7.0
		canvas.draw_colored_polygon(PackedVector2Array([sa + Vector2(0, -d), sa + Vector2(d, 0), sa + Vector2(0, d), sa + Vector2(-d, 0)]), _a(YELLOW, 0.9))
		_text(sa + Vector2(0, 26.0), "START", 14, _a(Term.TEXT, 0.7), 80.0, HORIZONTAL_ALIGNMENT_CENTER, wide)
	if cam.is_position_behind(b):
		return
	var sb := cam.unproject_position(b)
	var lim: String = tape.limit
	var col := Term.ORANGE if lim != "" else YELLOW
	var pulse := 1.0 if lim == "" else 0.6 + 0.4 * absf(sin(t * 7.0))
	canvas.draw_arc(sb, 11.0, 0.0, TAU, 28, _a(col, pulse), 2.0)
	canvas.draw_arc(sb, 3.0, 0.0, TAU, 12, _a(col, pulse), 3.0)
	if has_a and sa.distance_to(sb) > 28.0:
		_dashes(sa, sb, _a(YELLOW, 0.35))
	# the tag, on the side away from the stuck end
	var side := 1.0 if sb.x >= sa.x or not has_a else -1.0
	if sb.x + side * 240.0 > canvas.size.x - 30.0 or sb.x + side * 240.0 < 30.0:
		side = -side
	var p1 := sb + Vector2(12.0 * side, -12.0)
	var p2 := p1 + Vector2(20.0 * side, -18.0)
	var p3 := p2 + Vector2(26.0 * side, 0.0)
	canvas.draw_polyline(PackedVector2Array([p1, p2, p3]), _a(col, 0.7), LINE_W)
	var align := HORIZONTAL_ALIGNMENT_LEFT if side > 0.0 else HORIZONTAL_ALIGNMENT_RIGHT
	var tx := p3.x + 8.0 * side
	_text(Vector2(tx, p3.y + 9.0), "%.2f M" % tape.length, 26, _a(col), 220.0, align)
	var sub: String = "ON " + str(tape.surface) if lim == "" else str(LIMITS.get(lim, lim))
	_text(Vector2(tx, p3.y + 31.0), sub, 15, _a(Term.TEXT if lim == "" else Term.ORANGE, 0.85), 240.0, align, wide)

## The metre gauge, the roll under it, and the hint
func _draw_gauge(cx: float, by: float) -> void:
	var w := GAUGE_W
	var x0 := cx - w * 0.5
	var max_m := TapeTool.MAX_STRIP
	var pulled: float = tape.length
	var short := pulled < TapeTool.MIN_STRIP
	# header: STRIP on the left, the length on the right
	_text(Vector2(x0, by - GAUGE_H - 14.0), "STRIP", 18, _a(YELLOW), 200.0, HORIZONTAL_ALIGNMENT_LEFT, wide)
	_text(Vector2(x0 + w, by - GAUGE_H - 14.0), "%.2f / %d M" % [pulled, int(max_m)], 18, _a(Term.TEXT), 300.0, HORIZONTAL_ALIGNMENT_RIGHT)
	# the gauge: frame, hazard fill, metre ticks
	var r := Rect2(x0, by - GAUGE_H, w, GAUGE_H)
	canvas.draw_rect(r, _a(Term.FILL, 0.6))
	var fw := w * clampf(shown_len / max_m, 0.0, 1.0)
	if fw > 0.5:
		_hazard(Rect2(x0, by - GAUGE_H, fw, GAUGE_H), 1.0)
		canvas.draw_line(Vector2(x0 + fw, by - GAUGE_H - 5.0), Vector2(x0 + fw, by + 5.0), _a(Term.TEXT), 2.0)
	canvas.draw_rect(r, _a(Term.AMBER_DIM), false, LINE_W)
	for m in range(0, int(max_m) + 1):
		var x := x0 + w * m / max_m
		canvas.draw_line(Vector2(x, by), Vector2(x, by + 8.0), _a(Term.TEXT, 0.6), LINE_W)
		_text(Vector2(x, by + 26.0), str(m), 15, _a(Term.TEXT, 0.6), 30.0, HORIZONTAL_ALIGNMENT_CENTER)
	# the roll: what's left after this strip, and the spare rolls
	var ry := by + 52.0
	var left := maxf(0.0, float(tape.roll_left) - pulled)
	var rolls: int = inventory.item_count(TapePickup.ITEM_ID) if inventory else 1
	_text(Vector2(x0, ry), "ROLL", 15, _a(Term.MUTED), 80.0, HORIZONTAL_ALIGNMENT_LEFT, wide)
	var bx := x0 + 78.0
	var bw := w - 78.0 - 170.0
	var frac := clampf(left / TapePickup.ROLL_LENGTH, 0.0, 1.0)
	var rcol := Term.AMBER if frac > 0.1 else Term.ORANGE
	canvas.draw_rect(Rect2(bx, ry - 9.0, bw, 5.0), _a(rcol, 0.18))
	canvas.draw_rect(Rect2(bx, ry - 9.0, bw * frac, 5.0), _a(rcol))
	var spare := " // x%d ROLLS" % rolls if rolls > 1 else ""
	_text(Vector2(x0 + w, ry), "%.1f M%s" % [left, spare], 15, _a(Term.TEXT, 0.85), 170.0, HORIZONTAL_ALIGNMENT_RIGHT)
	# what to do
	var hint := "LOOK ALONG THE SURFACE TO PULL IT OUT" if short else "RELEASE [T] TO STICK IT"
	var hcol := Term.TEXT if short else Term.GREEN
	_text(Vector2(cx, ry + 30.0), hint, 16, _a(hcol, 0.8), w, HORIZONTAL_ALIGNMENT_CENTER, wide)

## The last pull's outcome under the crosshair
func _draw_result(c: Vector2) -> void:
	var st: String = tape.state
	var head := ""
	var sub := ""
	var col := Term.TEXT
	match st:
		"placed":
			head = "STRIP PLACED"
			sub = "%.2f M // %.1f M LEFT ON THE ROLL" % [tape.result_len, tape.roll_left]
			col = Term.GREEN
		"short":
			head = "TOO SHORT"
			sub = "PULL AT LEAST %d CM" % roundi(TapeTool.MIN_STRIP * 100.0)
			col = Term.MUTED
		"no_surface":
			head = "NOTHING IN REACH"
			sub = "AIM AT A WALL OR THE FLOOR WITHIN %d M" % roundi(TapeTool.REACH)
			col = Term.RED
	var k := _smooth(pop)
	var y := c.y + 70.0 - 8.0 * (1.0 - k)
	var hw := _text_w(head, 24, wide)
	if st == "placed":
		_hazard(Rect2(c.x - hw * 0.5 - 30.0, y - 17.0, 16.0, 16.0), k)
	_text(Vector2(c.x + (12.0 if st == "placed" else 0.0), y), head, 24, _a(col, k), 600.0, HORIZONTAL_ALIGNMENT_CENTER, wide)
	_text(Vector2(c.x, y + 26.0), sub, 16, _a(Term.TEXT, 0.75 * k), 700.0, HORIZONTAL_ALIGNMENT_CENTER)

# ---- helpers --------------------------------------------------------------------------
## Black and yellow diagonal stripes filling `r`, like the tape
func _hazard(r: Rect2, k: float) -> void:
	canvas.draw_rect(r, _a(YELLOW, k))
	var h := r.size.y
	var x := r.position.x - h - fposmod(t * 18.0, STRIPE)      # the stripes creep along as it pulls
	while x < r.end.x:
		var poly := PackedVector2Array()
		# one black band: a parallelogram, cut to the rect's left and right edges
		for p in [Vector2(x, r.end.y), Vector2(x + STRIPE * 0.5, r.end.y), Vector2(x + STRIPE * 0.5 + h, r.position.y), Vector2(x + h, r.position.y)]:
			poly.append(p)
		var clipped := Geometry2D.intersect_polygons(poly, PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]))
		for cp in clipped:
			canvas.draw_colored_polygon(cp, _a(Color(0.06, 0.05, 0.03), k))
		x += STRIPE

func _dashes(a: Vector2, b: Vector2, col: Color) -> void:
	var l := a.distance_to(b)
	var dir := (b - a) / l
	var s := 14.0
	while s < l - 14.0:
		canvas.draw_line(a + dir * s, a + dir * minf(s + 8.0, l - 14.0), col, LINE_W)
		s += 16.0

func _a(c: Color, k := 1.0) -> Color:
	return Color(c.r, c.g, c.b, c.a * alpha * k)

func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func _text_w(s: String, px: int, f: Font = null) -> float:
	return (f if f else font).get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x

## Draws `s` left-, right- or centre-aligned on `pos` (baseline), trimmed to `max_w`
func _text(pos: Vector2, s: String, px: int, color: Color, max_w: float, align := HORIZONTAL_ALIGNMENT_LEFT, f: Font = null) -> void:
	if s == "":
		return
	var fnt: Font = f if f else font
	var w := minf(_text_w(s, px, f), max_w)
	var x := pos.x
	if align == HORIZONTAL_ALIGNMENT_RIGHT: x -= w
	elif align == HORIZONTAL_ALIGNMENT_CENTER: x -= w * 0.5
	canvas.draw_string(fnt, Vector2(x, pos.y), s, HORIZONTAL_ALIGNMENT_LEFT, max_w, px, color)
