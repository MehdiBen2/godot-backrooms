extends Control
## Field scanner HUD (scripts/Player/scanner.gd): holding Q puts the camcorder in scan mode, built
## like a camera's focus aids rather than a sci-fi panel:
## - the view is graded toward the terminal's amber and closed in at the edges like a lens
##   (shaders/scan_grade.gdshader), with a "SCAN MODE" chip at the top
## - a focus-distance scale along the bottom, 1 to 30 m on a log axis like a lens barrel. While
##   searching, a band on it marks roughly how far the signal is (scanner.signal_dist); it narrows
##   as the signal firms up. On a lock a needle marks the exact range, and a hairline under the
##   scale fills with the reading
## - on a lock, corner marks travel out of the focus box onto the target, the way autofocus snaps
##   to a subject, with a small tag beside it (name, range); a new entry blinks them twice
## The marks, scale and text are drawn inside a crt_layer.gd so they glow, flicker and tear like
## the TAB terminal. Lines are thin (LINE_W): it sits over the view while you play. Every string is
## measured and trimmed to the room it has (_fit).

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")
const Scanner := preload("res://scripts/Player/scanner.gd")

const FOCUS := Vector2(124.0, 88.0)   # the focus box round the crosshair
const SCALE_W := 840.0           # the focus-distance scale, centred along the bottom
const SCALE_BOTTOM := 123.0      # its baseline, up from the bottom edge
const SCALE_MAX := 32.0          # metres at the right end (scanner RANGE)
const MAJOR := [1, 2, 5, 10, 20, 30]
const MINOR := [3, 4, 7, 15, 25]
const CHIP_TOP := 42.0
const LINE_W := 1.5
const STATUS := {"idle": "", "search": "SEARCHING", "lock": "LOCKED ON", "logged": "ENTRY LOGGED", "on_file": "ALREADY ON FILE"}
const HINT := {
	"idle": "",
	"search": "",
	"lock": "KEEP IT IN VIEW",
	"logged": "TAB // F3 TO READ IT",
	"on_file": "NOTHING NEW RECORDED",
}

var scanner: Node
var layer: CrtLayer
var canvas: Control
var grade: ColorRect
var grade_mat: ShaderMaterial
var font := FontVariation.new()
var wide := FontVariation.new()  # letter-spaced: the chip and the status word
var alpha := 0.0
var t := 0.0
var last_state := "idle"
var snap := 1.0                  # 0..1: the lock marks travelling from the focus box to the target
var confirm := 0.0               # seconds left of the "logged" double blink
var unfold := 1.0                # 0..1: the scale drawing out from the middle as scan mode comes on
var fit_cache := {}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 1
	font.variation_embolden = 0.4
	wide.base_font = font.base_font
	wide.spacing_glyph = 4
	wide.variation_embolden = 0.4
	# the grade reads the screen, so it goes under the layer: the marks stay their own colour
	grade = ColorRect.new()
	grade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grade_mat = ShaderMaterial.new()
	grade_mat.shader = load("res://shaders/scan_grade.gdshader")
	grade.material = grade_mat
	grade.visible = false
	add_child(grade)
	layer = CrtLayer.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layer)
	canvas = Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.draw.connect(_draw_canvas)
	layer.content.add_child(canvas)

func _process(dt: float) -> void:
	if not scanner:
		return
	t += dt
	var want := 1.0 if scanner.holding or scanner.result_t > 0.0 else 0.0
	alpha = move_toward(alpha, want, dt * (8.0 if want > alpha else 5.0))
	var st: String = scanner.state
	if st != last_state:
		_on_state(last_state, st)
		last_state = st
	grade.visible = alpha > 0.0
	if alpha <= 0.0:
		layer.running = false
		return
	grade_mat.set_shader_parameter("amount", _smooth(alpha))
	if not layer.running:        # coming on: the scale draws out through a tear
		layer.running = true
		unfold = 0.0
		layer.burst(0.5)
	unfold = move_toward(unfold, 1.0, dt * 5.0)
	snap = move_toward(snap, 1.0, dt * 4.5)
	confirm = maxf(0.0, confirm - dt)
	canvas.queue_redraw()

func _on_state(from: String, to: String) -> void:
	if to == "lock" and from != "lock":
		snap = 0.0
		layer.burst(0.25)
	elif to == "logged":
		confirm = 0.3
		layer.burst(0.6)
	elif to == "on_file":
		confirm = 0.3

# ---- drawing --------------------------------------------------------------------------
func _draw_canvas() -> void:
	if alpha <= 0.001 or not scanner:
		return
	var st: String = scanner.state
	var col := Term.AMBER
	if st == "logged": col = Term.GREEN
	elif st == "on_file": col = Term.TEXT
	var c := canvas.size * 0.5
	_draw_chip(c.x)
	_draw_focus(c, st)
	_draw_lock(c, st, col)
	_draw_scale(c.x, canvas.size.y - SCALE_BOTTOM, st, col)

func _locked(st: String) -> bool:
	return st == "lock" or st == "logged" or st == "on_file"

## "SCAN MODE" at the top middle, a small square before it
func _draw_chip(cx: float) -> void:
	var label := "SCAN MODE"
	var w := _text_w(label, 18, wide)
	var x := cx - (w + 18.0) * 0.5
	canvas.draw_rect(Rect2(x, CHIP_TOP + 4.0, 9.0, 9.0), _a(Term.AMBER))
	_text(Vector2(x + 18.0, CHIP_TOP + 16.0), label, 18, _a(Term.AMBER), w + 4.0, HORIZONTAL_ALIGNMENT_LEFT, wide)

## Four corner brackets: the box, and how long their arms are
func _brackets(r: Rect2, arm: float, color: Color, width: float) -> void:
	for corner in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		var sx := 1.0 if corner.x < r.get_center().x else -1.0
		var sy := 1.0 if corner.y < r.get_center().y else -1.0
		canvas.draw_line(corner, corner + Vector2(sx * arm, 0.0), color, width)
		canvas.draw_line(corner, corner + Vector2(0.0, sy * arm), color, width)

## A faint focus box round the crosshair while searching, hunting a little and firming up with the
## signal; once locked only the centre tick stays, the marks having gone out to the target
func _draw_focus(c: Vector2, st: String) -> void:
	var sig: float = scanner.signal_strength
	if st == "search":
		var size_now := FOCUS + Vector2(6.0, 4.0) * sin(t * 5.0) * (1.0 - sig)
		_brackets(Rect2(c - size_now * 0.5, size_now), 16.0, _a(Term.TEXT, 0.3 + 0.35 * sig), LINE_W)
	var k := 0.45 if st == "search" else 0.25
	canvas.draw_line(c - Vector2(9.0, 0.0), c + Vector2(9.0, 0.0), _a(Term.TEXT, k), LINE_W)
	canvas.draw_line(c - Vector2(0.0, 9.0), c + Vector2(0.0, 9.0), _a(Term.TEXT, k), LINE_W)

## Corner marks on the target itself, and a tag beside them on a short leader: name, then range
func _draw_lock(c: Vector2, st: String, col: Color) -> void:
	if not _locked(st):
		return
	var cam: Camera3D = scanner.player.cam
	var wp: Vector3 = scanner.target_pos
	if cam == null or cam.is_position_behind(wp):
		return
	var sp := cam.unproject_position(wp)
	var dist: float = scanner.target_dist
	var hs := clampf(1100.0 / maxf(dist, 1.0), 26.0, 110.0)
	# travel out of the focus box to the target, like autofocus finding its subject
	var e := _smooth(snap)
	var from := Rect2(c - FOCUS * 0.5, FOCUS)
	var to := Rect2(sp - Vector2(hs, hs), Vector2(hs, hs) * 2.0)
	var r := Rect2(from.position.lerp(to.position, e), from.size.lerp(to.size, e))
	if confirm > 0.0 and int(confirm * 13.0) % 2 == 1:
		return                       # the confirm blink: off
	var k := _a(col)
	_brackets(r, minf(18.0, r.size.x * 0.3), k, LINE_W * 1.5)
	if e < 0.99:
		return
	var tag := "UNIDENTIFIED"
	if Archive.is_discovered(scanner.target_id):
		tag = str(Archive.entity_info(scanner.target_id).get("common_name", scanner.target_id)).to_upper()
	var tw := minf(_text_w(tag, 19), 320.0)
	# on the right of the marks, or the left when the right runs off the screen
	var side := 1.0
	var ax := r.end.x + 4.0
	if ax + 68.0 + tw > canvas.size.x - 40.0:
		side = -1.0
		ax = r.position.x - 4.0
	var a := Vector2(ax, r.position.y + 9.0)
	var b := a + Vector2(33.0 * side, -24.0)
	var d := b + Vector2(27.0 * side, 0.0)
	canvas.draw_polyline(PackedVector2Array([a, b, d]), _a(col, 0.6), LINE_W)
	var align := HORIZONTAL_ALIGNMENT_LEFT if side > 0.0 else HORIZONTAL_ALIGNMENT_RIGHT
	_text(Vector2(d.x + 8.0 * side, d.y + 7.0), tag, 19, k, 320.0, align)
	_text(Vector2(d.x + 8.0 * side, d.y + 28.0), "%.1f M" % dist, 16, _a(Term.TEXT, 0.7), 160.0, align)

## The focus-distance scale: status over it on the left, the detail on the right; the signal's band
## or the lock's needle on it; the reading's hairline and the next step under it
func _draw_scale(cx: float, by: float, st: String, col: Color) -> void:
	var w := SCALE_W
	var x0 := cx - w * 0.5
	var half := w * 0.5 * _smooth(unfold)
	var sig: float = scanner.signal_strength

	var detail := ""
	match st:
		"search":
			detail = "NO SIGNAL"
			if sig > 0.06 and scanner.signal_dist > 0.0:
				var word := "FAINT"
				if sig > 0.66: word = "STRONG"
				elif sig > 0.33: word = "MODERATE"
				detail = "SIGNAL %s // ABOUT %d M AHEAD" % [word, roundi(scanner.signal_dist)]
		"lock": detail = "READING %d%%" % roundi(scanner.progress * 100.0)
		"logged", "on_file":
			detail = str(Archive.entity_info(scanner.target_id).get("code", "ASRA-EN-??"))
	var sw := _text(Vector2(x0, by - 36.0), str(STATUS.get(st, "")), 20, _a(col), w * 0.45, HORIZONTAL_ALIGNMENT_LEFT, wide)
	_text(Vector2(x0 + w, by - 36.0), detail, 17, _a(Term.TEXT, 0.9), w - sw - 24.0, HORIZONTAL_ALIGNMENT_RIGHT)

	# the band: roughly where the signal is, narrowing as it firms up
	if st == "search" and sig > 0.06 and scanner.signal_dist > 0.0:
		var spread := lerpf(0.55, 0.12, sig)
		var mid := _scale_x(x0, scanner.signal_dist)
		var l := maxf(_scale_x(x0, scanner.signal_dist * exp(-spread)), cx - half)
		var rr := minf(_scale_x(x0, scanner.signal_dist * exp(spread)), cx + half)
		if rr > l:
			canvas.draw_rect(Rect2(l, by - 15.0, rr - l, 15.0), _a(Term.AMBER, 0.12 + 0.18 * sig))
		if absf(mid - cx) <= half:
			canvas.draw_rect(Rect2(mid - 2.0, by - 15.0, 4.0, 15.0), _a(Term.AMBER, 0.7))

	canvas.draw_line(Vector2(cx - half, by), Vector2(cx + half, by), _a(Term.TEXT, 0.55), LINE_W)
	for m in MINOR:
		var x := _scale_x(x0, m)
		if absf(x - cx) <= half:
			canvas.draw_line(Vector2(x, by - 7.0), Vector2(x, by), _a(Term.TEXT, 0.4), LINE_W)
	for m in MAJOR:
		var x := _scale_x(x0, m)
		if absf(x - cx) <= half:
			canvas.draw_line(Vector2(x, by - 15.0), Vector2(x, by), _a(Term.TEXT, 0.75), 2.0)
			_text(Vector2(x, by + 26.0), str(m), 16, _a(Term.TEXT, 0.7), 40.0, HORIZONTAL_ALIGNMENT_CENTER)
	if unfold >= 1.0:
		_text(Vector2(_scale_x(x0, 30.0) + 22.0, by + 26.0), "M", 16, _a(Term.TEXT, 0.7), 20.0)

	if not _locked(st):
		return
	# the needle at the exact range
	var nx := _scale_x(x0, scanner.target_dist)
	if absf(nx - cx) <= half:
		canvas.draw_line(Vector2(nx, by - 27.0), Vector2(nx, by + 3.0), _a(col), 3.0)
		canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(nx - 9.0, by - 39.0), Vector2(nx + 9.0, by - 39.0), Vector2(nx, by - 27.0)]), _a(col))
	# the reading, then what to do next
	var frac: float = scanner.progress if st == "lock" else 1.0
	var py := by + 42.0
	canvas.draw_rect(Rect2(cx - half, py, half * 2.0, 3.0), _a(col, 0.18))
	canvas.draw_rect(Rect2(cx - half, py, half * 2.0 * frac, 3.0), _a(col))
	_text(Vector2(cx, py + 28.0), str(HINT.get(st, "")), 16, _a(Term.TEXT, 0.6), w, HORIZONTAL_ALIGNMENT_CENTER, wide)

## Where `metres` sits on the scale (log axis, 1 m at the left end)
func _scale_x(x0: float, metres: float) -> float:
	return x0 + log(clampf(metres, 1.0, SCALE_MAX)) / log(SCALE_MAX) * SCALE_W

# ---- helpers --------------------------------------------------------------------------
## Colour with the readout's fade applied
func _a(c: Color, k := 1.0) -> Color:
	return Color(c.r, c.g, c.b, c.a * alpha * k)

func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func _text_w(s: String, px: int, f: Font = null) -> float:
	return (f if f else font).get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x

## `s` trimmed with an ellipsis until it fits `max_w` (VCR has the glyph); cached per string
func _fit(s: String, px: int, max_w: float, f: Font = null) -> String:
	var key := "%s|%d|%d|%d" % [s, px, int(max_w), 1 if f else 0]
	if fit_cache.has(key):
		return fit_cache[key]
	var out := s
	if _text_w(s, px, f) > max_w:
		while out.length() > 1 and _text_w(out + "…", px, f) > max_w:
			out = out.left(out.length() - 1)
		out = out.strip_edges() + "…"
	if fit_cache.size() > 256:
		fit_cache.clear()
	fit_cache[key] = out
	return out

## Draws `s` fitted to `max_w`, left-, right- or centre-aligned on `pos` (baseline), in `font` or
## `f` when given; returns its width
func _text(pos: Vector2, s: String, px: int, color: Color, max_w: float, align := HORIZONTAL_ALIGNMENT_LEFT, f: Font = null) -> float:
	if s == "":
		return 0.0
	s = _fit(s, px, max_w, f)
	var w := _text_w(s, px, f)
	var x := pos.x
	if align == HORIZONTAL_ALIGNMENT_RIGHT: x -= w
	elif align == HORIZONTAL_ALIGNMENT_CENTER: x -= w * 0.5
	canvas.draw_string(f if f else font, Vector2(x, pos.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)
	return w
