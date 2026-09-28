extends Control
## Field scanner HUD (scripts/Player/scanner.gd), drawn inside a crt_layer.gd so it glows, flickers,
## scans and tears like the TAB terminal:
## - a segmented ring round the crosshair that turns while searching (faster as the signal rises),
##   with a radar sweep inside it; it tightens on a lock and an arc fills round it as the reading
##   completes
## - lock brackets that snap onto the target where it really is on screen, a dashed leader from the
##   ring and a tag (UNIDENTIFIED and the range, or the entry code once it is logged)
## - a folder-tab readout under the crosshair: status with a blinking cursor and signal bars, an
##   oscilloscope trace that settles from noise into a clean wave as the reading locks in, the
##   signal line, a segmented progress bar and a running data stream
## - a new entry sends a pulse ring out and a tear through the layer
## Every string is measured and trimmed to the box it sits in (_fit).

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")
const Scanner := preload("res://scripts/Player/scanner.gd")

const RING_SEARCH := 96.0
const RING_LOCK := 64.0
const DASHES := 40
const PANEL_W := 500.0
const PANEL_GAP := 64.0          # crosshair ring to the readout's tab
const TAB_H := 34.0
const SLANT := 18.0
const CHAMFER := 8.0
const PAD := 18.0
const SCOPE_H := 46.0
const SCOPE_PTS := 72
const CELLS := 20
const STATUS := {"idle": "", "search": "SEARCHING", "lock": "LOCKED // HOLD Q", "logged": "ENTRY LOGGED", "on_file": "ALREADY ON FILE"}

var scanner: Node
var layer: CrtLayer
var canvas: Control
var font := FontVariation.new()
var line_w: float = Term.LINE * Term.WINDOW_SCALE   # the terminal's outline weight, as it shows on screen
var alpha := 0.0
var t := 0.0
var spin := 0.0
var sweep := 0.0
var last_state := "idle"
var snap := 1.0                  # 0..1: lock brackets settling onto the target
var pulse := -1.0                # 0..1: "entry logged" ring going out, < 0 off
var unfold := 1.0                # 0..1: the readout opening out as the scanner comes on
var fit_cache := {}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 1
	font.variation_embolden = 0.4
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
	if alpha <= 0.0:
		layer.running = false
		return
	if not layer.running:        # coming on: the readout unfolds through a tear
		layer.running = true
		unfold = 0.0
		layer.burst(0.6)
	unfold = move_toward(unfold, 1.0, dt * 6.0)
	snap = move_toward(snap, 1.0, dt * 5.0)
	if pulse >= 0.0:
		pulse += dt * 1.6
		if pulse > 1.0:
			pulse = -1.0
	var sig: float = scanner.signal_strength
	spin += dt * (0.5 + 3.0 * sig) * (0.3 if st == "lock" else 1.0)
	sweep += dt * (2.2 + 4.0 * sig)
	canvas.queue_redraw()

func _on_state(from: String, to: String) -> void:
	if to == "lock" and from != "lock":
		snap = 0.0
		layer.burst(0.35)
	elif to == "logged":
		pulse = 0.0
		layer.burst(1.0)
	elif to == "on_file":
		layer.burst(0.4)

# ---- drawing --------------------------------------------------------------------------
func _draw_canvas() -> void:
	if alpha <= 0.001 or not scanner:
		return
	var st: String = scanner.state
	var col := Term.AMBER
	if st == "logged": col = Term.GREEN
	elif st == "on_file": col = Term.TEXT
	var c := canvas.size * 0.5
	var r := _ring_radius(st)
	_draw_ring(c, r, st, col)
	_draw_lock(c, r, st, col)
	_draw_panel(Vector2(c.x - PANEL_W * 0.5, c.y + RING_SEARCH + PANEL_GAP), st, col)

func _ring_radius(st: String) -> float:
	if st == "lock":
		return lerpf(RING_SEARCH, RING_LOCK, _smooth(snap))
	if st == "logged" or st == "on_file":
		return RING_LOCK
	return RING_SEARCH + 3.0 * sin(t * 3.0)

func _draw_ring(c: Vector2, r: float, st: String, col: Color) -> void:
	var sig: float = scanner.signal_strength
	var done := st == "logged" or st == "on_file"
	var locked := st == "lock"
	# dashes: brighter as the signal rises, brightest where the sweep passes
	var seg := TAU / DASHES
	for i in DASHES:
		var a0 := spin + i * seg
		var near := pow(maxf(0.0, cos(a0 + seg * 0.3 - sweep)), 12.0) if st == "search" else 0.0
		var lit := 1.0 if done else clampf(0.3 + 0.5 * sig + 0.6 * near, 0.0, 1.0)
		canvas.draw_arc(c, r, a0, a0 + seg * 0.55, 4, _a(col, lit), 2.5, true)
	# radar sweep: a spoke with a fading trail, only while searching
	if st == "search":
		for k in 7:
			var d := Vector2.from_angle(sweep - k * 0.08)
			canvas.draw_line(c + d * 16.0, c + d * (r - 8.0), _a(col, (0.25 + 0.45 * sig) * (1.0 - k / 7.0)), 2.0, true)
	# the crosshair's fixed frame: four ticks outside the ring
	for k in 4:
		var d := Vector2.from_angle(k * PI * 0.5)
		canvas.draw_line(c + d * (r + 6.0), c + d * (r + 20.0), _a(col, 0.9), line_w * 0.6)
	# progress round the outside: a faint track, the reading filling it clockwise from the top
	if locked or done:
		var frac: float = 1.0 if done else scanner.progress
		canvas.draw_arc(c, r + 13.0, 0.0, TAU, 72, _a(col, 0.14), line_w, true)
		if frac > 0.001:
			canvas.draw_arc(c, r + 13.0, -PI * 0.5, -PI * 0.5 + TAU * frac, maxi(4, int(72 * frac)), _a(col), line_w, true)
	if pulse >= 0.0:
		canvas.draw_arc(c, r + 13.0 + pulse * 150.0, 0.0, TAU, 96, _a(col, (1.0 - pulse) * 0.9), line_w * (1.0 - 0.6 * pulse), true)

## Brackets on the target itself, a dashed leader from the ring, and its tag
func _draw_lock(c: Vector2, r: float, st: String, col: Color) -> void:
	if not (st == "lock" or st == "logged" or st == "on_file"):
		return
	var cam: Camera3D = scanner.player.cam
	var wp: Vector3 = scanner.target_pos
	if cam == null or cam.is_position_behind(wp):
		return
	var sp := cam.unproject_position(wp)
	var dist: float = scanner.target_dist
	var e := _smooth(snap)
	var hs := clampf(1100.0 / maxf(dist, 1.0), 22.0, 110.0) * lerpf(2.2, 1.0, e)
	var k := _a(col, lerpf(0.25, 1.0, e))
	var arm := minf(18.0, hs * 0.6)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var q := sp + Vector2(sx, sy) * hs
			canvas.draw_line(q, q - Vector2(sx * arm, 0.0), k, line_w)
			canvas.draw_line(q, q - Vector2(0.0, sy * arm), k, line_w)
	var d := sp - c
	if d.length() > r + hs + 24.0:
		var dir := d.normalized()
		var a0 := c + dir * (r + 22.0)
		var a1 := sp - dir * hs * 1.2
		var n := int(a0.distance_to(a1) / 10.0)
		for i in range(0, n, 2):
			canvas.draw_line(a0.lerp(a1, float(i) / n), a0.lerp(a1, float(i + 1) / n), _a(col, 0.55 * e), 2.0)
	# tag beside the brackets, flipped to the left near the screen's right edge
	var tag := "UNIDENTIFIED"
	if Archive.is_discovered(scanner.target_id):
		tag = str(Archive.entity_info(scanner.target_id).get("code", "ASRA-EN-??"))
	var right := sp.x + hs + 230.0 < canvas.size.x
	var tx := sp.x + hs + 12.0 if right else sp.x - hs - 12.0
	var align := HORIZONTAL_ALIGNMENT_LEFT if right else HORIZONTAL_ALIGNMENT_RIGHT
	_text(Vector2(tx, sp.y - hs + 14.0), tag, 16, k, 210.0, align)
	_text(Vector2(tx, sp.y - hs + 34.0), "%.1fM" % dist, 15, _a(col, 0.7 * e), 210.0, align)

## Folder-tab readout (the toast's and the dossier's shape)
func _draw_panel(o: Vector2, st: String, col: Color) -> void:
	var sig: float = scanner.signal_strength
	var p: float = scanner.progress
	var w := PANEL_W
	var inner := w - PAD * 2.0
	var body_h := PAD + 22.0 + 10.0 + SCOPE_H + 12.0 + 20.0 + 10.0 + 16.0 + 10.0 + 14.0 + PAD
	var top := o.y + TAB_H
	var h := body_h
	# unfold from the tab down as the scanner comes on
	var s := _smooth(unfold)
	canvas.draw_set_transform(Vector2(0.0, o.y * (1.0 - s)), 0.0, Vector2(1.0, maxf(s, 0.02)))

	var title := "A.S.R.A. SCANNER"
	var tab_w := _text_w(title, 16) + 34.0 + SLANT
	var fill := Color(Term.FILL, Term.FILL.a * alpha)
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(o.x, top), Vector2(o.x + w - CHAMFER, top), Vector2(o.x + w, top + CHAMFER), Vector2(o.x + w, top + h - CHAMFER),
		Vector2(o.x + w - CHAMFER, top + h), Vector2(o.x + CHAMFER, top + h), Vector2(o.x, top + h - CHAMFER)]), fill)
	var tab := PackedVector2Array([Vector2(o.x, top), Vector2(o.x, o.y), Vector2(o.x + tab_w - SLANT, o.y), Vector2(o.x + tab_w, top)])
	canvas.draw_colored_polygon(tab, fill)
	canvas.draw_polyline(tab, _a(col), line_w, true)
	canvas.draw_polyline(PackedVector2Array([
		Vector2(o.x + tab_w, top), Vector2(o.x + w - CHAMFER, top), Vector2(o.x + w, top + CHAMFER), Vector2(o.x + w, top + h - CHAMFER),
		Vector2(o.x + w - CHAMFER, top + h), Vector2(o.x + CHAMFER, top + h), Vector2(o.x, top + h - CHAMFER), Vector2(o.x, top)]), _a(col), line_w, true)
	_text(Vector2(o.x + 17.0, o.y + 23.0), title, 16, _a(Term.TEXT), tab_w - SLANT - 20.0)
	_text(Vector2(o.x + w - 4.0, o.y + 23.0), "RNG %dM" % int(Scanner.RANGE), 13, _a(Term.MUTED), w - tab_w - 16.0, HORIZONTAL_ALIGNMENT_RIGHT)

	var x := o.x + PAD
	var y := top + PAD
	# 1: status, blinking cursor, signal bars
	var status := str(STATUS.get(st, ""))
	if st == "search":
		status += ".".repeat(int(t * 3.0) % 4)
	var bars_w := 5 * 9.0 + 34.0
	var sw := _text(Vector2(x, y + 17.0), status, 19, _a(col), inner - bars_w - 20.0)
	if fmod(t, 0.9) < 0.5:
		canvas.draw_rect(Rect2(x + sw + 6.0, y + 2.0, 10.0, 17.0), _a(col, 0.85))
	_text(Vector2(o.x + w - PAD - 5 * 9.0 - 6.0, y + 16.0), "SIG", 13, _a(Term.MUTED), 40.0, HORIZONTAL_ALIGNMENT_RIGHT)
	for i in 5:
		var bh := 5.0 + i * 3.5
		var lit := sig > (i + 0.5) / 5.0 or st == "logged" or st == "on_file"
		canvas.draw_rect(Rect2(o.x + w - PAD - (5 - i) * 9.0, y + 19.0 - bh, 6.0, bh), _a(col, 1.0 if lit else 0.15))
	y += 22.0 + 10.0

	# 2: oscilloscope: noise while searching, a clean wave coming through as the reading locks in
	var box := Rect2(x, y, inner, SCOPE_H)
	canvas.draw_rect(box, _a(Color(0, 0, 0, 0.35)))
	canvas.draw_rect(box, _a(col, 0.35), false, 1.5)
	for i in range(1, 6):
		var gx := x + inner * i / 6.0
		for j in range(0, int(SCOPE_H), 6):
			canvas.draw_line(Vector2(gx, y + j), Vector2(gx, y + j + 2.0), _a(col, 0.12), 1.0)
	canvas.draw_line(Vector2(x, y + SCOPE_H * 0.5), Vector2(x + inner, y + SCOPE_H * 0.5), _a(col, 0.12), 1.0)
	var clean := 0.0
	var amp := 0.15 + 0.7 * sig
	if st == "lock":
		clean = _smooth(p)
		amp = 0.8
	elif st == "logged" or st == "on_file":
		clean = 1.0
		amp = 0.75
	var frame := floor(t * 24.0)
	var pts := PackedVector2Array()
	for i in SCOPE_PTS:
		var u := float(i) / (SCOPE_PTS - 1)
		var noise := 0.5 * sin(u * 37.0 + t * 23.0) + 0.3 * sin(u * 91.0 - t * 41.0) + 0.6 * (_hash(i + frame * 97.0) - 0.5)
		var wave := sin(u * TAU * 3.0 - t * 9.0)
		var v := lerpf(noise, wave, clean) * amp
		pts.append(Vector2(x + u * inner, y + SCOPE_H * 0.5 - v * SCOPE_H * 0.42))
	canvas.draw_polyline(pts, _a(col), 2.0, true)
	var head := x + fmod(t * 0.8, 1.0) * inner           # the write head crossing the scope
	canvas.draw_line(Vector2(head, y + 3.0), Vector2(head, y + SCOPE_H - 3.0), _a(col, 0.35), 2.0)
	y += SCOPE_H + 12.0

	# 3: what is on the other end, and how far
	var line := "NO SIGNAL"
	if st == "search":
		if sig > 0.66: line = "SIGNAL: STRONG"
		elif sig > 0.33: line = "SIGNAL: WEAK"
		elif sig > 0.06: line = "SIGNAL: FAINT"
	elif st == "lock" and not Archive.is_discovered(scanner.target_id):
		line = "SIGNAL: UNIDENTIFIED"
	elif st != "idle":
		line = _entity_name(scanner.target_id)
	var range_txt := "--.-M" if st == "search" or st == "idle" else "%.1fM" % scanner.target_dist
	var rw := _text(Vector2(x + inner, y + 15.0), range_txt, 16, _a(Term.MUTED), 90.0, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(Vector2(x, y + 15.0), line, 17, _a(Term.GREEN if st == "logged" else Term.TEXT), inner - rw - 16.0)
	y += 20.0 + 10.0

	# 4: segmented progress and its percentage
	var fill_frac := 0.0
	if st == "lock": fill_frac = p
	elif st == "logged" or st == "on_file": fill_frac = 1.0
	var pct := "%d%%" % int(round(fill_frac * 100.0))
	var pw := _text_w("100%", 16)
	_text(Vector2(x + inner, y + 14.0), pct, 16, _a(col), pw, HORIZONTAL_ALIGNMENT_RIGHT)
	var bw := inner - pw - 12.0
	var gap := 3.0
	var cw := (bw - gap * (CELLS - 1)) / CELLS
	var lit_cells := ceili(fill_frac * CELLS - 0.01)
	for i in CELLS:
		canvas.draw_rect(Rect2(x + i * (cw + gap), y, cw, 16.0), _a(col, 1.0 if i < lit_cells else 0.1))
	y += 16.0 + 10.0

	# 5: data stream: bytes running while it reads, a verdict once it is done
	var data := ""
	match st:
		"lock":
			for i in 16:
				data += "%02X " % int(_hash(i + floor(t * 14.0) * 31.0) * 255.0)
		"logged": data = "CHECKSUM OK // WRITTEN TO THRESHOLD DOSSIER"
		"on_file": data = "MATCHES AN ENTRY ON FILE // NOTHING WRITTEN"
		_:
			for i in 16:
				data += ("%02X " % int(_hash(i + floor(t * 5.0) * 17.0) * 255.0)) if _hash(i * 3.0 + floor(t * 5.0)) > 0.8 else "-- "
	_text(Vector2(x, y + 11.0), data, 13, _a(Term.MUTED, 0.8), inner)
	canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# ---- helpers --------------------------------------------------------------------------
## Colour with the readout's fade applied
func _a(c: Color, k := 1.0) -> Color:
	return Color(c.r, c.g, c.b, c.a * alpha * k)

func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func _hash(n: float) -> float:
	return fposmod(sin(n * 12.9898) * 43758.5453, 1.0)

func _entity_name(id: String) -> String:
	var info := Archive.entity_info(id)
	return "%s (%s)" % [str(info.get("code", "ASRA-EN-??")), str(info.get("common_name", id)).to_upper()]

func _text_w(s: String, px: int) -> float:
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x

## `s` trimmed with an ellipsis until it fits `max_w` (VCR has the glyph); cached per string
func _fit(s: String, px: int, max_w: float) -> String:
	var key := "%s|%d|%d" % [s, px, int(max_w)]
	if fit_cache.has(key):
		return fit_cache[key]
	var out := s
	if _text_w(s, px) > max_w:
		while out.length() > 1 and _text_w(out + "…", px) > max_w:
			out = out.left(out.length() - 1)
		out = out.strip_edges() + "…"
	if fit_cache.size() > 256:
		fit_cache.clear()
	fit_cache[key] = out
	return out

## Draws `s` fitted to `max_w`, left- or right-aligned at `pos` (baseline); returns its width
func _text(pos: Vector2, s: String, px: int, color: Color, max_w: float, align := HORIZONTAL_ALIGNMENT_LEFT) -> float:
	s = _fit(s, px, max_w)
	var w := _text_w(s, px)
	var x := pos.x - w if align == HORIZONTAL_ALIGNMENT_RIGHT else pos.x
	canvas.draw_string(font, Vector2(x, pos.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)
	return w
