extends Control
## Field scanner HUD (scripts/Player/scanner.gd), drawn inside a crt_layer.gd so it glows, flickers
## and tears like the TAB terminal. Built like the camcorder's own viewfinder rather than sci-fi
## chrome:
## - a focus box round the crosshair that hunts a little while searching and brightens with the
##   signal (warmer / colder)
## - on a lock, a heavier frame travels out of it onto the target, the way autofocus snaps to a
##   subject, with the entry tag above it and a thin progress gauge under it; a new entry blinks it
##   twice, like a camera confirming focus
## - a small folder-tab readout under the crosshair where every line is something real: the status,
##   the signal strength (a meter and a word), the target and its range, the reading's progress,
##   and what to do next. Nothing on it is decoration.
## Lines are thinner than the terminal's (LINE_W): it sits over the view while you play.
## Every string is measured and trimmed to the box it sits in (_fit).

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")
const Scanner := preload("res://scripts/Player/scanner.gd")

const FOCUS := Vector2(124.0, 88.0)   # the focus box round the crosshair
const PANEL_W := 430.0
const PANEL_GAP := 64.0          # focus box to the readout's tab
const TAB_H := 30.0
const SLANT := 16.0
const CHAMFER := 7.0
const PAD := 16.0
const ROW_H := 30.0
const LABEL_W := 92.0            # the row labels' column
const CELLS := 12
const LINE_W := 2.0              # panel outline; the lock frame is a little heavier, the focus box lighter
const STATUS := {"idle": "", "search": "SEARCHING", "lock": "LOCKED ON", "logged": "ENTRY LOGGED", "on_file": "ALREADY ON FILE"}
const HINT := {
	"idle": "",
	"search": "AIM AT AN ANOMALY AND KEEP IT CENTRED",
	"lock": "KEEP IT IN VIEW UNTIL THE READING COMPLETES",
	"logged": "NEW ENTRY // TAB, THEN F3 TO READ IT",
	"on_file": "ALREADY LOGGED // NOTHING NEW RECORDED",
}

var scanner: Node
var layer: CrtLayer
var canvas: Control
var font := FontVariation.new()
var alpha := 0.0
var t := 0.0
var last_state := "idle"
var snap := 1.0                  # 0..1: the lock frame travelling from the focus box to the target
var confirm := 0.0               # seconds left of the "logged" double blink
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
		layer.burst(0.5)
	unfold = move_toward(unfold, 1.0, dt * 6.0)
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
	_draw_focus(c, st, col)
	_draw_lock(c, st, col)
	_draw_panel(Vector2(c.x - PANEL_W * 0.5, c.y + FOCUS.y * 0.5 + PANEL_GAP), st, col)

## Four corner brackets: the box, and how long their arms are
func _brackets(r: Rect2, arm: float, color: Color, width: float) -> void:
	for corner in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		var sx := 1.0 if corner.x < r.get_center().x else -1.0
		var sy := 1.0 if corner.y < r.get_center().y else -1.0
		canvas.draw_line(corner, corner + Vector2(sx * arm, 0.0), color, width)
		canvas.draw_line(corner, corner + Vector2(0.0, sy * arm), color, width)

## The focus box round the crosshair: hunting a little while it searches, brighter as the signal
## rises; a faint centre tick so the eye keeps the crosshair
func _draw_focus(c: Vector2, st: String, col: Color) -> void:
	var sig: float = scanner.signal_strength
	var size_now := FOCUS
	if st == "search":
		size_now += Vector2(6.0, 4.0) * sin(t * 5.0) * (1.0 - sig)
	var k := 0.45 + 0.45 * sig if st == "search" else 0.35
	var r := Rect2(c - size_now * 0.5, size_now)
	_brackets(r, 16.0, _a(col, k), LINE_W * 0.75)
	canvas.draw_line(c - Vector2(7.0, 0.0), c + Vector2(7.0, 0.0), _a(col, k * 0.8), 1.5)
	canvas.draw_line(c - Vector2(0.0, 7.0), c + Vector2(0.0, 7.0), _a(col, k * 0.8), 1.5)

## The lock frame on the target itself, its tag above and a progress gauge under it
func _draw_lock(c: Vector2, st: String, col: Color) -> void:
	if not (st == "lock" or st == "logged" or st == "on_file"):
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
	_brackets(r, minf(20.0, r.size.x * 0.3), k, LINE_W * 1.25)
	if e < 0.99:
		return
	# tag above, range on the right; gauge under, as wide as the frame
	var tag := "UNIDENTIFIED"
	if Archive.is_discovered(scanner.target_id):
		tag = str(Archive.entity_info(scanner.target_id).get("code", "ASRA-EN-??"))
	var w := maxf(r.size.x, 220.0)       # the frame's colour and the readout say logged / on file
	var x0 := r.get_center().x - w * 0.5
	var rw := _text(Vector2(x0 + w, r.position.y - 10.0), "%.1fM" % dist, 14, _a(Term.MUTED), 70.0, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(Vector2(x0, r.position.y - 10.0), tag, 15, k, w - rw - 10.0)
	var frac: float = 1.0 if st != "lock" else scanner.progress
	var bar := Rect2(r.position.x, r.end.y + 10.0, r.size.x, 4.0)
	canvas.draw_rect(bar, _a(col, 0.18))
	canvas.draw_rect(Rect2(bar.position, Vector2(bar.size.x * frac, bar.size.y)), k)

## Folder-tab readout (the toast's and the dossier's shape). Rows: status; SIGNAL (how strongly
## anything scannable is ahead, scanner.signal_strength); TARGET (what is locked and how far);
## READING (the scan's progress); and a hint saying what to do next.
func _draw_panel(o: Vector2, st: String, col: Color) -> void:
	var sig: float = scanner.signal_strength
	var w := PANEL_W
	var inner := w - PAD * 2.0
	var h := PAD + 24.0 + 8.0 + ROW_H * 3.0 + 6.0 + 16.0 + PAD
	var top := o.y + TAB_H
	# unfold from the tab down as the scanner comes on
	var s := _smooth(unfold)
	canvas.draw_set_transform(Vector2(0.0, o.y * (1.0 - s)), 0.0, Vector2(1.0, maxf(s, 0.02)))

	var title := "FIELD SCANNER"
	var tab_w := _text_w(title, 15) + 30.0 + SLANT
	var fill := Color(Term.FILL, Term.FILL.a * alpha)
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(o.x, top), Vector2(o.x + w - CHAMFER, top), Vector2(o.x + w, top + CHAMFER), Vector2(o.x + w, top + h - CHAMFER),
		Vector2(o.x + w - CHAMFER, top + h), Vector2(o.x + CHAMFER, top + h), Vector2(o.x, top + h - CHAMFER)]), fill)
	var tab := PackedVector2Array([Vector2(o.x, top), Vector2(o.x, o.y), Vector2(o.x + tab_w - SLANT, o.y), Vector2(o.x + tab_w, top)])
	canvas.draw_colored_polygon(tab, fill)
	canvas.draw_polyline(tab, _a(col), LINE_W, true)
	canvas.draw_polyline(PackedVector2Array([
		Vector2(o.x + tab_w, top), Vector2(o.x + w - CHAMFER, top), Vector2(o.x + w, top + CHAMFER), Vector2(o.x + w, top + h - CHAMFER),
		Vector2(o.x + w - CHAMFER, top + h), Vector2(o.x + CHAMFER, top + h), Vector2(o.x, top + h - CHAMFER), Vector2(o.x, top)]), _a(col), LINE_W, true)
	_text(Vector2(o.x + 15.0, o.y + 21.0), title, 15, _a(Term.TEXT), tab_w - SLANT - 18.0)

	var x := o.x + PAD
	var vx := x + LABEL_W            # where the values start
	var vw := inner - LABEL_W
	var y := top + PAD
	# status; the cursor blinks while it is still working
	var sw := _text(Vector2(x, y + 18.0), str(STATUS.get(st, "")), 19, _a(col), inner - 20.0)
	if (st == "search" or st == "lock") and fmod(t, 0.9) < 0.5:
		canvas.draw_rect(Rect2(x + sw + 6.0, y + 3.0, 9.0, 16.0), _a(col, 0.85))
	y += 24.0 + 8.0

	# SIGNAL: how strongly something scannable is ahead (through walls), in cells and in words
	var word := "NONE"
	if st == "lock" or st == "logged" or st == "on_file": word = "LOCKED"
	elif sig > 0.66: word = "STRONG"
	elif sig > 0.33: word = "MODERATE"
	elif sig > 0.06: word = "FAINT"
	_row_label(x, y, "SIGNAL")
	var ww := _text_w("MODERATE", 15)
	_meter(Rect2(vx, y + 5.0, vw - ww - 14.0, 12.0), sig if word != "LOCKED" else 1.0, col)
	_text(Vector2(x + inner, y + 16.0), word, 15, _a(col if sig > 0.06 or word == "LOCKED" else Term.MUTED), ww, HORIZONTAL_ALIGNMENT_RIGHT)
	y += ROW_H

	# TARGET: what is locked, and how far
	_row_label(x, y, "TARGET")
	var target := "NONE IN VIEW"
	var target_col := _a(Term.MUTED)
	if st != "search" and st != "idle":
		# the name here, the code on the lock frame's tag
		target = "UNIDENTIFIED"
		if Archive.is_discovered(scanner.target_id):
			target = str(Archive.entity_info(scanner.target_id).get("common_name", scanner.target_id)).to_upper()
		target_col = _a(Term.GREEN if st == "logged" else Term.TEXT)
		var dw := _text(Vector2(x + inner, y + 16.0), "%.1f M" % scanner.target_dist, 15, _a(Term.MUTED), 80.0, HORIZONTAL_ALIGNMENT_RIGHT)
		_text(Vector2(vx, y + 16.0), target, 16, target_col, vw - dw - 12.0)
	else:
		_text(Vector2(vx, y + 16.0), target, 16, target_col, vw)
	y += ROW_H

	# READING: the scan itself
	_row_label(x, y, "READING")
	var frac := 0.0
	if st == "lock": frac = scanner.progress
	elif st == "logged" or st == "on_file": frac = 1.0
	var pw := _text_w("100%", 15)
	_meter(Rect2(vx, y + 5.0, vw - ww - 14.0, 12.0), frac, col)
	var pct := "%d%%" % int(round(frac * 100.0)) if st != "search" else "--"
	_text(Vector2(x + inner, y + 16.0), pct, 15, _a(col if st != "search" else Term.MUTED), maxf(pw, ww), HORIZONTAL_ALIGNMENT_RIGHT)
	y += ROW_H + 6.0

	# what to do next
	canvas.draw_line(Vector2(x, y - 4.0), Vector2(x + inner, y - 4.0), _a(col, 0.25), 1.0)
	_text(Vector2(x, y + 14.0), str(HINT.get(st, "")), 13, _a(Term.MUTED), inner)
	canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _row_label(x: float, y: float, label: String) -> void:
	_text(Vector2(x, y + 16.0), label, 14, _a(Term.MUTED), LABEL_W - 8.0)

## A segmented meter: `frac` of its cells lit
func _meter(r: Rect2, frac: float, col: Color) -> void:
	var gap := 3.0
	var cw := (r.size.x - gap * (CELLS - 1)) / CELLS
	var lit := ceili(clampf(frac, 0.0, 1.0) * CELLS - 0.01)
	for i in CELLS:
		canvas.draw_rect(Rect2(r.position.x + i * (cw + gap), r.position.y, cw, r.size.y), _a(col, 1.0 if i < lit else 0.12))

# ---- helpers --------------------------------------------------------------------------
## Colour with the readout's fade applied
func _a(c: Color, k := 1.0) -> Color:
	return Color(c.r, c.g, c.b, c.a * alpha * k)

func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

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
