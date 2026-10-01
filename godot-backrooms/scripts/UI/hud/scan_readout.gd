extends Control
## Field scanner HUD (scripts/Player/scanner.gd): holding Q puts the camcorder in scan mode, built
## like a camera's focus aids rather than a sci-fi panel:
## - the view goes through a fisheye lens and is graded toward the terminal's amber, closed in at the
##   edges (shaders/scan_grade.gdshader). The marks are drawn through the very same lens (the
##   layer's corner-fitted barrel, LENS), so they stay on what they mark; it bends in as scan mode
##   comes on
## - a focus-distance scale along the bottom, 1 to 30 m on a log axis like a lens barrel, with the
##   status over its left end. While searching, a band on it marks roughly how far the signal is
##   (scanner.signal_dist), narrowing as the signal firms up; on a lock a plain needle marks the
##   exact range, its figure over it. The band and the signal's bearing come with clearance C-3 (the
##   range-finder, asra_clearance.gd), along with chevrons by the focus box pointing the way to turn
## - on a lock, corner marks travel out of the focus box onto the target, the way autofocus snaps
##   to a subject. Under them the reading fills a hairline as wide as the box, over the name and how
##   far through it is; a new entry blinks them twice. From C-4 a DEEP SCAN line follows: what the
##   entity is doing right now (its scan_behavior())
## - a signal meter at the top (segments with a peak that holds, then falls back), the sensing
##   field marked out round the middle of the view with the instrument's name and your clearance
##   code on it, and interference in the picture (the grade's grain and slipping lines) that clears
##   as the signal firms up and is gone on a lock
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
const LENS := 0.16               # fisheye strength, the view's and the marks' (ui_vhs_overlay distortion)
const LINE_W := 1.5
const BEARING_AHEAD := 6.0       # degrees: a signal this close to the view reads DEAD AHEAD (C-3)
const METER_SEGS := 20
const METER_TOP := 112.0         # clear of the top edge once LENS pushes the rim out past the screen
const FIELD := Vector2(0.56, 0.56)   # the sensing field's marks, as a share of the screen
const FIELD_ARM := 26.0
const STATUS := {"idle": "", "search": "SEARCHING", "lock": "LOCKED", "logged": "LOGGED", "on_file": "ON FILE"}

var scanner: Node
var layer: CrtLayer
var canvas: Control
var grade: ColorRect
var grade_mat: ShaderMaterial
var font := FontVariation.new()
var wide := FontVariation.new()  # a touch letter-spaced: the tape readout
var alpha := 0.0
var t := 0.0
var last_state := "idle"
var snap := 1.0                  # 0..1: the lock marks travelling from the focus box to the target
var confirm := 0.0               # seconds left of the "logged" double blink
var unfold := 1.0                # 0..1: the scale drawing out from the middle as scan mode comes on
var peak := 0.0                  # the meter's peak-hold segment, 0..1
var peak_hold := 0.0             # seconds before the peak starts to fall back
var interference := 1.0          # eased (1 - signal): the grade's grain and slipping lines
var fit_cache := {}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 1
	font.variation_embolden = 0.4
	wide.base_font = font.base_font
	wide.spacing_glyph = 2
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
	layer.mat.set_shader_parameter("fit_corners", true)
	layer.mat.set_shader_parameter("chroma_amt", 0.004)   # a little colour fringing toward the rim
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
	# the lens bends in with scan mode, the view and the marks together so they stay aligned
	var lens := LENS * _smooth(alpha)
	grade_mat.set_shader_parameter("distortion", lens)
	grade_mat.set_shader_parameter("aspect", size.x / maxf(size.y, 1.0))
	layer.mat.set_shader_parameter("distortion", lens)
	var sig: float = scanner.signal_strength
	interference = move_toward(interference, 1.0 - (1.0 if _locked(st) else sig), dt * 2.5)
	grade_mat.set_shader_parameter("interference", interference)
	if sig >= peak:
		peak = sig
		peak_hold = 0.9
	else:
		peak_hold -= dt
		if peak_hold <= 0.0:
			peak = move_toward(peak, sig, dt * 0.5)
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
	_draw_field(c)
	_draw_meter(c.x, col, st)
	_draw_focus(c, st)
	_draw_lock(c, st, col)
	_draw_tape(c, st)
	_draw_scale(c.x, canvas.size.y - SCALE_BOTTOM, st, col)

## Hazard tape under the crosshair (scanner.tape_info): what it is, how long ago it went down and
## who stuck it, under the focus box. Your own tape says so in green: you have walked this way.
func _draw_tape(c: Vector2, st: String) -> void:
	var info: Dictionary = scanner.tape_info
	if st != "search" or info.is_empty():
		return
	var y := c.y + FOCUS.y * 0.5 + 34.0
	_text(Vector2(c.x, y), "HAZARD TAPE // %.1f M // %d M AWAY" % [float(info.length), roundi(float(info.dist))], 19,
		_a(Term.AMBER), 520.0, HORIZONTAL_ALIGNMENT_CENTER, wide)
	var by := str(info.by)
	var researcher := by == Scanner.TapeMarks.RESEARCHER  # tape that came with the level: nobody knows when
	_text(Vector2(c.x, y + 26.0), "PLACED " + ("UNKNOWN" if researcher else _ago(float(info.age))), 18, _a(Term.TEXT), 520.0, HORIZONTAL_ALIGNMENT_CENTER)
	var mine: bool = info.mine and not researcher  # a level's own tape reads the same to its builder
	var who := "BY YOU // YOU HAVE BEEN HERE" if mine else ("BY " + by if by != "" else "BY ANOTHER SURVIVOR")
	_text(Vector2(c.x, y + 50.0), who, 17, _a(Term.GREEN if mine else Term.MUTED), 520.0, HORIZONTAL_ALIGNMENT_CENTER, wide)

## "12 S AGO", "4 MIN 12 S AGO", "1 H 05 MIN AGO"
static func _ago(secs: float) -> String:
	var s := int(secs)
	if s < 60:
		return "%d S AGO" % s
	if s < 3600:
		return "%d MIN %02d S AGO" % [s / 60, s % 60]
	return "%d H %02d MIN AGO" % [s / 3600, (s / 60) % 60]

func _locked(st: String) -> bool:
	return st == "lock" or st == "logged" or st == "on_file"

## The signal meter at the top middle: SIG, then a row of segments lit to the signal, with the peak
## segment held a moment after the signal drops. On a lock it fills in the result colour.
func _draw_meter(cx: float, col: Color, st: String) -> void:
	var seg := Vector2(8.0, 6.0)
	var gap := 3.0
	var w := METER_SEGS * (seg.x + gap) - gap
	var x0 := cx - w * 0.5 + 16.0
	var y := METER_TOP
	_text(Vector2(x0 - 12.0, y + seg.y + 1.0), "SIG", 13, _a(Term.TEXT, 0.55), 40.0, HORIZONTAL_ALIGNMENT_RIGHT)
	var locked := _locked(st)
	var lit := roundi((1.0 if locked else float(scanner.signal_strength)) * METER_SEGS)
	var pk := clampi(roundi(peak * METER_SEGS) - 1, 0, METER_SEGS - 1)
	for i in METER_SEGS:
		var r := Rect2(x0 + i * (seg.x + gap), y, seg.x, seg.y)
		if i < lit:
			canvas.draw_rect(r, _a(col if locked else Term.AMBER, 0.9))
		elif i == pk and peak > 0.03 and not locked:
			canvas.draw_rect(r, _a(Term.AMBER, 0.6))
		else:
			canvas.draw_rect(r, _a(Term.TEXT, 0.12))

## The sensing field: thin corner marks and centre ticks round the middle of the view, the
## instrument's name over its top-left corner and the clearance it reads at over the top-right
func _draw_field(c: Vector2) -> void:
	var fs := canvas.size * FIELD
	var r := Rect2(c - fs * 0.5, fs)
	var k := _a(Term.TEXT, 0.26)
	_brackets(r, FIELD_ARM, k, LINE_W)
	for m in [Vector2(r.get_center().x, r.position.y), Vector2(r.get_center().x, r.end.y)]:
		canvas.draw_line(m - Vector2(0.0, 5.0), m + Vector2(0.0, 5.0), k, LINE_W)
	for m in [Vector2(r.position.x, r.get_center().y), Vector2(r.end.x, r.get_center().y)]:
		canvas.draw_line(m - Vector2(5.0, 0.0), m + Vector2(5.0, 0.0), k, LINE_W)
	var ty := r.position.y - 10.0
	_text(Vector2(r.position.x, ty), "T.S.R.A. FIELD SCANNER", 13, _a(Term.TEXT, 0.4), fs.x * 0.45)
	_text(Vector2(r.end.x, ty), "CLEARANCE " + str(Clearance.tier().get("code", "C-0")), 13, _a(Term.TEXT, 0.4),
		fs.x * 0.45, HORIZONTAL_ALIGNMENT_RIGHT)

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
	# C-3 range-finder: chevrons beside the box point the way to turn, one to three by how far
	var b: float = scanner.signal_bearing
	if st == "search" and sig > 0.06 and absf(b) >= BEARING_AHEAD and Clearance.has_unlock("rangefinder"):
		var side := signf(b)
		var n := 1 + int(absf(b) > 20.0) + int(absf(b) > 40.0)
		for i in n:
			var x := c.x + side * (FOCUS.x * 0.5 + 22.0 + i * 13.0)
			var blink := 0.35 + 0.65 * absf(sin(t * 6.0 - i * 0.9))
			canvas.draw_polyline(PackedVector2Array([Vector2(x - side * 6.0, c.y - 10.0), Vector2(x + side * 3.0, c.y),
				Vector2(x - side * 6.0, c.y + 10.0)]), _a(Term.AMBER, (0.4 + 0.6 * sig) * blink), 2.0)
	var k := 0.45 if st == "search" else 0.25
	canvas.draw_line(c - Vector2(9.0, 0.0), c + Vector2(9.0, 0.0), _a(Term.TEXT, k), LINE_W)
	canvas.draw_line(c - Vector2(0.0, 9.0), c + Vector2(0.0, 9.0), _a(Term.TEXT, k), LINE_W)

## Corner marks on the target itself; under them (over them near the bottom of the screen) the
## reading as a hairline the box's width, the name and how far through it is, and the C-4 deep scan
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
	var node: Node = scanner.target_node
	var deep: bool = Clearance.has_unlock("deep_scan") and is_instance_valid(node) and node.has_method("scan_behavior")
	var bh: Dictionary = {}
	var parts: Array = []
	if deep:
		bh = node.scan_behavior(scanner.target_pos)
		parts = Array(str(bh.get("detail", "")).replace(" - ", " // ").split(" // ", false))
	var w := maxf(r.size.x, 190.0)
	var x0 := clampf(r.get_center().x - w * 0.5, 40.0, canvas.size.x - 40.0 - w)
	var block := 30.0 + (26.0 + parts.size() * 19.0 if deep else 0.0)
	var y := r.end.y + 12.0
	if y + block > canvas.size.y - SCALE_BOTTOM - 70.0:
		y = r.position.y - 12.0 - block
	var frac: float = scanner.progress if st == "lock" else 1.0
	canvas.draw_rect(Rect2(x0, y, w, 2.0), _a(col, 0.2))
	canvas.draw_rect(Rect2(x0, y, w * frac, 2.0), k)
	var pw := _text(Vector2(x0 + w, y + 22.0), "%d%%" % roundi(frac * 100.0), 15, _a(Term.TEXT, 0.65), 60.0, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(Vector2(x0, y + 22.0), tag, 17, k, w - pw - 12.0)
	if not deep:
		return
	# C-4 deep scan: what it is doing right now, live, from the entity itself; a clause a line
	var danger := int(bh.get("danger", 0))
	var dcol: Color = Term.RED if danger >= 2 else (Term.ORANGE if danger == 1 else Term.GREEN)
	if danger >= 2 and int(t * 4.0) % 2 == 1:
		dcol = Color(dcol, 0.55)
	var dw := maxf(w, 320.0)
	_text(Vector2(x0, y + 48.0), "DEEP SCAN: " + str(bh.get("state", "")), 15, _a(dcol), dw)
	var ly := y + 67.0
	for part in parts:
		_text(Vector2(x0, ly), str(part), 14, _a(Term.TEXT, 0.7), dw)
		ly += 19.0

## The focus-distance scale: the status over its left end and a word or two over its right; the
## signal's band (its rough range over it) or the lock's needle (the exact range over it) on it
func _draw_scale(cx: float, by: float, st: String, col: Color) -> void:
	var w := SCALE_W
	var x0 := cx - w * 0.5
	var half := w * 0.5 * _smooth(unfold)
	var sig: float = scanner.signal_strength
	var ranged := Clearance.has_unlock("rangefinder")

	var detail := ""
	match st:
		"search":
			detail = "NO SIGNAL"
			if sig > 0.06 and scanner.signal_dist > 0.0:
				var word := "FAINT"
				if sig > 0.66: word = "STRONG"
				elif sig > 0.33: word = "MODERATE"
				detail = "SIGNAL " + word
				if ranged:               # C-3: which way to turn (how far is on the band)
					var b: float = scanner.signal_bearing
					detail += "  " + ("DEAD AHEAD" if absf(b) < BEARING_AHEAD else "%d DEG %s" % [roundi(absf(b)), "RIGHT" if b > 0.0 else "LEFT"])
		"logged", "on_file":
			detail = str(Archive.entity_info(scanner.target_id).get("code", "TSRA-EN-??"))
			if scanner.last_yield > 0:
				detail += "  +%d %s" % [scanner.last_yield, Clearance.unit]
	var sw := _text(Vector2(x0, by - 42.0), str(STATUS.get(st, "")), 18, _a(col), w * 0.4)
	_text(Vector2(x0 + w, by - 42.0), detail, 15, _a(Term.TEXT, 0.8), w - sw - 24.0, HORIZONTAL_ALIGNMENT_RIGHT)

	# the band: roughly where the signal is, narrowing as it firms up (C-3 range-finder only)
	if ranged and st == "search" and sig > 0.06 and scanner.signal_dist > 0.0:
		var spread := lerpf(0.55, 0.12, sig)
		var mid := _scale_x(x0, scanner.signal_dist)
		var l := maxf(_scale_x(x0, scanner.signal_dist * exp(-spread)), cx - half)
		var rr := minf(_scale_x(x0, scanner.signal_dist * exp(spread)), cx + half)
		if rr > l:
			canvas.draw_rect(Rect2(l, by - 12.0, rr - l, 12.0), _a(Term.AMBER, 0.12 + 0.18 * sig))
		if absf(mid - cx) <= half:
			canvas.draw_line(Vector2(mid, by - 12.0), Vector2(mid, by), _a(Term.AMBER, 0.8), 2.0)
			_text(Vector2(mid, by - 18.0), "~%d" % roundi(scanner.signal_dist), 14, _a(Term.AMBER, 0.8), 60.0, HORIZONTAL_ALIGNMENT_CENTER)

	canvas.draw_line(Vector2(cx - half, by), Vector2(cx + half, by), _a(Term.TEXT, 0.5), LINE_W)
	for m in MINOR:
		var x := _scale_x(x0, m)
		if absf(x - cx) <= half:
			canvas.draw_line(Vector2(x, by - 6.0), Vector2(x, by), _a(Term.TEXT, 0.35), LINE_W)
	for m in MAJOR:
		var x := _scale_x(x0, m)
		if absf(x - cx) <= half:
			canvas.draw_line(Vector2(x, by - 12.0), Vector2(x, by), _a(Term.TEXT, 0.7), LINE_W)
			_text(Vector2(x, by + 22.0), str(m), 15, _a(Term.TEXT, 0.6), 40.0, HORIZONTAL_ALIGNMENT_CENTER)
	if unfold >= 1.0:
		_text(Vector2(_scale_x(x0, 30.0) + 20.0, by + 22.0), "M", 15, _a(Term.TEXT, 0.6), 20.0)

	if not _locked(st):
		return
	# the needle at the exact range, its figure over it
	var nx := _scale_x(x0, scanner.target_dist)
	if absf(nx - cx) <= half:
		canvas.draw_line(Vector2(nx, by - 16.0), Vector2(nx, by + 4.0), _a(col), 2.0)
		_text(Vector2(nx, by - 22.0), "%.1f" % scanner.target_dist, 15, _a(col), 70.0, HORIZONTAL_ALIGNMENT_CENTER)

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
