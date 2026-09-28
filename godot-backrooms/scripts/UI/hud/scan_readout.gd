extends Control
## Field scanner reticle (scripts/Player/scanner.gd) in the inventory terminal's amber style: four
## brackets around the crosshair that close in as a reading fills, and a small readout under them
## (state, signal, a segmented progress bar). Shown while Q is held and briefly after a result.

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const LINE := 3.0
const BOX := Vector2(420, 96)
const CELLS := 16

var scanner: Node
var font := FontVariation.new()
var alpha := 0.0
var t := 0.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 2
	font.variation_embolden = 0.4

func _process(dt: float) -> void:
	t += dt
	var want := 1.0 if scanner and (scanner.holding or scanner.result_t > 0.0) else 0.0
	var was := alpha
	alpha = move_toward(alpha, want, dt * 7.0)
	if alpha > 0.0 or was > 0.0:
		queue_redraw()

func _draw() -> void:
	if alpha <= 0.001 or not scanner:
		return
	var st: String = scanner.state
	var p: float = scanner.progress
	var col := Term.AMBER
	if st == "logged": col = Term.GREEN
	elif st == "on_file": col = Term.TEXT
	col.a = alpha
	var c := size * 0.5

	# brackets: wide and breathing while searching, closing in with the reading, tight on a result
	var r := 70.0 + 4.0 * sin(t * 4.0)
	if st == "lock": r = lerpf(64.0, 24.0, p)
	elif st == "logged" or st == "on_file": r = 24.0
	var arm := 16.0
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var k := c + Vector2(sx, sy) * r
			draw_line(k, k - Vector2(sx * arm, 0), col, LINE)
			draw_line(k, k - Vector2(0, sy * arm), col, LINE)

	# readout box under the reticle
	var box := Rect2(c + Vector2(-BOX.x * 0.5, 100.0), BOX)
	draw_rect(box, Color(Term.FILL, Term.FILL.a * alpha))
	draw_rect(box, col, false, LINE)
	var x := box.position.x + 16.0
	var y := box.position.y + 26.0
	var titles := {"idle": "", "search": "SEARCHING", "lock": "LOCKED", "logged": "ENTRY LOGGED", "on_file": "ALREADY ON FILE"}
	draw_string(font, Vector2(x, y), "A.S.R.A. SCANNER // " + str(titles.get(st, "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 17, col)

	var line := ""
	var line_col := Color(Term.TEXT, alpha)
	match st:
		"search":
			line = "NO SIGNAL"
			line_col.a *= 0.45 + 0.35 * sin(t * 6.0)
		"lock":
			if Archive.is_discovered(scanner.target_id):
				line = _name(scanner.target_id)
			else:
				line = "SIGNAL: UNIDENTIFIED  %.1fM" % scanner.target_dist
		"logged", "on_file":
			line = _name(scanner.target_id)
			if st == "logged": line_col = Color(Term.GREEN, alpha)
	draw_string(font, Vector2(x, y + 26.0), line, HORIZONTAL_ALIGNMENT_LEFT, BOX.x - 32.0, 17, line_col)

	# progress: segmented like the terminal's vitals bars, percentage at the end
	var fill := 1.0 if st == "logged" or st == "on_file" else (p if st == "lock" else 0.0)
	var bar := Rect2(x, y + 40.0, BOX.x - 32.0 - 64.0, 14.0)
	var gap := 3.0
	var w := (bar.size.x - gap * (CELLS - 1)) / CELLS
	var lit := ceili(fill * CELLS - 0.01)
	for i in CELLS:
		draw_rect(Rect2(bar.position.x + i * (w + gap), bar.position.y, w, bar.size.y), col if i < lit else Color(col, 0.1 * alpha))
	draw_string(font, Vector2(bar.end.x + 12.0, bar.end.y), "%d%%" % int(round(fill * 100.0)), HORIZONTAL_ALIGNMENT_LEFT, -1, 17, col)

func _name(id: String) -> String:
	var info := Archive.entity_info(id)
	return "%s (%s)" % [str(info.get("code", "ASRA-EN-??")), str(info.get("common_name", id)).to_upper()]
