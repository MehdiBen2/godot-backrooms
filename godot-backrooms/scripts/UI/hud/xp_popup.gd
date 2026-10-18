extends Control
## XP pop-up: what a field scanner reading just earned (scanner.gd reading_filed), bottom right, on top of the item
## strip (item_strip.gd), right-aligned with it: there when you look for it, out of the way of the view. One thing
## at a time:
##   gain   a small spaced caption (what the reading was), the figure under it punching in and counting up with a
##          tick on each step, then each bonus in turn on one line under it ("+65  PROXIMITY PREMIUM"), each
##          adding to the figure as it lands; under that a hairline filling toward the next rank in its colour.
##          Readings that land close together run on into one total.
##   rank   if the count went past a rank, once it ends the gain gives way to the rank-up on its own: RANK UP
##          between two rules, the rank's name big in its colour with its effects (Clearance.tier_color /
##          tier_effects: glow, shine, wave, pulse, flicker; more the higher it is), its number under it; a tear,
##          a flash round the screen's edge in the rank's colour and a chime, all growing with the rank. (hud.gd
##          _promotion's RANK UP toast, with the unlocks, comes in at the side on its own.)
##   out    it drifts up a little and fades.
## Only scanner readings show here: tape, routes and the debug console file quietly (their toasts say so).
## While you are dead or held (a kill, a grab) readings wait, and show once you are free.
## Each sits on a dark card cut like the terminal toast's (terminal_toast.gd: a cut corner, a faint outline, a bar
## down its left edge in the gain's or the rank's colour), so it reads over a lit wall. Drawn in a crt_layer.gd like
## the reticle and the toast, but with its glow, colour split and scanlines turned down: small text has to stay
## sharp. At low sanity the figure slips for a frame now and then.
## Built by hud.gd, in hud_root (it fades with the OSD).

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")
const ItemStrip := preload("res://scripts/UI/hud/item_strip.gd")

const BOX := Vector2(600.0, 250.0)   # the layer: its bottom-right corner is the cards'
const RIGHT := 44.0                  # the item strip's right margin (hud.gd _build_item_strip) ...
const BOTTOM := 22.0                 # ... and its bottom one
const OVER_STRIP := 14.0             # gap between the cards and the top of the strip
const BIG_PX := 40.0                 # the figure's size for a reading worth BIG_AT or more...
const BIG_AT := 260.0
const SMALL_K := 0.55                # ...and the share of it one worth 1 gets
const UNIT_PX := 18
const LABEL_PX := 14
const BONUS_PX := 16
const CARD_MIN := 280.0              # the card's narrowest
const CARD_PAD := 28.0               # room either side of what is on it
const CHAMFER := 12.0
const ACCENT_W := 3.0
const FILL := Color(0.035, 0.028, 0.014, 0.88)
const SPLIT := 0.4                   # px of red / blue split at rest (the toast's 1.1 smears small text)
const GOLD_OVER := 200               # the figure turns gold as it counts past this
const GOLD := Color("ffd94a")
const PUNCH := 1.2                   # the figure lands this big and settles, overshooting a little
const BUMP := 1.1                    # ...and kicks this much as each bonus lands on it
const PUNCH_T := 0.38
const COUNT_T := 0.6                 # the first line's count-up
const BONUS_T := 0.3                 # each bonus's
const LINE_GAP := 0.5                # between one line landing and the next: long enough to read each bonus
const MERGE := 1.0                   # seconds into the hold that a new reading still joins this one
const HOLD := 1.4
const FADE_T := 0.45
const FLOAT_UP := 16.0
const BAR_W := 220.0
const TICKS := 14                    # count-up ticks a line makes at most
const RANK_T := 2.6                  # the rank-up's hold (a little longer the higher the rank)
const RANK_PX := 36
const UNEASE_BELOW := 40.0           # sanity under this and the figure starts to slip
const GARBLE := "#%&@$?!/"

var player: Node                     # player.gd (set by hud.gd): dead / frozen hold readings back, sanity garbles them
var layer: CrtLayer
var canvas: Control
var edge: Control                    # the flash round the screen (outside the layer: the whole screen)
var font := FontVariation.new()
var wide := FontVariation.new()      # spaced out: captions
var tick: AudioStreamPlayer
var chime: AudioStreamPlayer

var _held: Array = []                # reports waiting while the player is dead or held
var _active := false
var _phase := ""                     # count, hold, rank, out
var _phase_t := 0.0
var _life := 0.0
var _lines: Array = []               # [label, amount, seconds since it landed (-1: not yet)], in landing order
var _landed := 0
var _land_t := 0.0                   # seconds to the next line landing
var _gain := 0                       # what the landed lines add up to
var _total := 0                      # what every line adds up to
var _base := 0                       # lifetime XP before this run of readings
var _from_v := 0.0                   # the count: from...
var _shown := 0.0                    # ...the figure now
var _seg_t := 0.0
var _seg_dur := COUNT_T
var _last_tick := 0
var _first := false                  # a first contact in it: green
var _punch := 1.0
var _punch_t := PUNCH_T
var _punch_from := PUNCH
var _out := 0.0                      # 0..1 fading away
var _tier := 0                       # the rank the hairline is filling toward the next of
var _rank_to := -1                   # a rank the count went past: shown once the count ends
var _flash := 0.0                    # seconds left of the hairline full and blinking
var _edge := 0.0                     # 0..1 the screen-edge flash
var _edge_col := Color.WHITE
var _rank_len := RANK_T
var _garble := 0.0                   # seconds left of a slipped figure
var _garbled := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 1
	font.variation_embolden = 0.4
	wide.base_font = font.base_font
	wide.spacing_glyph = 2
	wide.variation_embolden = 0.35
	edge = Control.new()
	edge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	edge.draw.connect(_draw_edge)
	add_child(edge)
	layer = CrtLayer.new()
	layer.size = BOX
	layer.aberration = SPLIT
	layer.glow_scale = 0.35          # a little phosphor glow, not enough to bloom the text out
	add_child(layer)
	layer.mat.set_shader_parameter("scan_amt", 0.05)
	layer.mat.set_shader_parameter("grain_amt", 0.015)
	canvas = Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.draw.connect(_draw_canvas)
	layer.content.add_child(canvas)
	tick = AudioStreamPlayer.new()
	tick.stream = load("res://audio/terminal/terminal_select.wav")   # not the scan's own Geiger tick
	tick.max_polyphony = 4
	add_child(tick)
	chime = AudioStreamPlayer.new()
	chime.stream = load("res://audio/terminal/terminal_logged.wav")
	chime.volume_db = -17.0
	add_child(chime)
	resized.connect(_place)
	_place()

func _place() -> void:
	layer.position = Vector2(size.x - RIGHT - BOX.x, size.y - BOTTOM - ItemStrip.PANEL.y - OVER_STRIP - BOX.y)

## scanner.gd reading_filed: one reading's report (Clearance.file / grant); shown once the player is free
func show_report(report: Dictionary) -> void:
	if int(report.get("total", 0)) > 0:
		_held.append(report)

func _free() -> bool:
	return is_instance_valid(player) and not player.dead and not player.frozen and not Game.dead

## The waiting readings, oldest first. The hairline starts from lifetime XP without them (and without any
## filed after them that are still to come in here)
func _flush() -> void:
	var rest := 0
	for r in _held:
		rest += int(r.total)
	for r in _held:
		_take(r, Clearance.total - rest)
		rest -= int(r.total)
	_held.clear()

func _take(r: Dictionary, base: int) -> void:
	var joins := _active and (_phase == "count" or (_phase == "hold" and _phase_t < MERGE))
	if not joins:
		_lines.clear()
		_landed = 0
		_land_t = 0.0
		_gain = 0
		_total = 0
		_base = base
		_from_v = 0.0
		_shown = 0.0
		_seg_t = 0.0
		_last_tick = 0
		_first = false
		_life = 0.0
		_out = 0.0
		_tier = Clearance.tier_index(base)
		_rank_to = -1
		_flash = 0.0
		_active = true
		layer.running = true
		layer.burst(0.3)
	for ln in r.get("lines", []):
		_lines.append([str(ln[0]), int(ln[1]), -1.0])
	_total += int(r.total)
	if str(r.get("kind", "")) == "first_contact":
		_first = true
	_go("count")

func _go(phase: String) -> void:
	_phase = phase
	_phase_t = 0.0

func _process(dt: float) -> void:
	if not _held.is_empty() and _free():
		_flush()
	if _edge > 0.0:
		_edge = maxf(0.0, _edge - dt * 1.2)
		edge.queue_redraw()
	if not _active:
		if layer.running:
			layer.running = false
		return
	_life += dt
	_phase_t += dt
	for ln in _lines:
		if ln[2] >= 0.0:
			ln[2] += dt
	_count(dt)
	_flash = maxf(0.0, _flash - dt)
	_punch_t += dt
	_punch = Tween.interpolate_value(_punch_from, 1.0 - _punch_from, minf(_punch_t, PUNCH_T), PUNCH_T,
		Tween.TRANS_BACK, Tween.EASE_OUT)
	match _phase:
		"count":
			if _landed == _lines.size() and _seg_t >= _seg_dur:
				chime.pitch_scale = 1.0
				chime.play()
				_go("hold")
		"hold":
			if _rank_to > 0 and _phase_t > 0.5:
				_rank_up()
			elif _phase_t > HOLD:
				_go("out")
		"rank":
			if _phase_t > _rank_len:
				_go("out")
		"out":
			_out += dt / FADE_T
	if not _free() and _phase != "out":
		_go("out")                    # killed or grabbed with it up: it gets out of the way
	_slip(dt)
	if _out >= 1.0:
		_active = false
	canvas.queue_redraw()

## The next line lands and its amount counts onto the figure, which kicks; a tick each step of the count
func _count(dt: float) -> void:
	if _landed < _lines.size():
		_land_t -= dt
		if _land_t <= 0.0:
			var ln: Array = _lines[_landed]
			_landed += 1
			ln[2] = 0.0
			_from_v = _shown
			_last_tick = int(_shown)
			_gain += int(ln[1])
			_seg_t = 0.0
			_seg_dur = COUNT_T if _landed == 1 else BONUS_T
			_land_t = LINE_GAP + (COUNT_T * 0.4 if _landed == 1 else 0.0)
			_punch_from = PUNCH if _landed == 1 else BUMP
			_punch_t = 0.0
	_seg_t += dt
	var u := clampf(_seg_t / _seg_dur, 0.0, 1.0)
	_shown = lerpf(_from_v, float(_gain), 1.0 - pow(1.0 - u, 3.0))     # fast at first, slowing at the end
	var v := int(_shown)
	var step := maxi(1, ceili(float(_gain - int(_from_v)) / TICKS))
	if v - _last_tick >= step or (v == _gain and v != _last_tick):
		_last_tick = v
		tick.pitch_scale = 0.85 + 0.7 * clampf(_shown / maxf(float(_total), 1.0), 0.0, 1.0)
		tick.volume_db = lerpf(-26.0, -16.0, _size_k())
		tick.play()
	# went past a rank: the hairline fills and blinks, and the rank-up waits for the count to end
	var i := Clearance.tier_index(_base + v)
	if i > _tier:
		_tier = i
		_rank_to = i
		_flash = 0.45

func _rank_up() -> void:
	_go("rank")
	_rank_len = RANK_T + 0.06 * _rank_to
	_edge = 1.0
	_edge_col = Clearance.tier_color(_rank_to)
	layer.burst(0.6 + 0.03 * _rank_to)
	chime.pitch_scale = 0.8 + 0.025 * _rank_to
	chime.play()

## Low sanity: now and then the figure shows wrong for a frame or two, and the picture splits wider
func _slip(dt: float) -> void:
	var unease := 0.0
	if is_instance_valid(player):
		unease = clampf(1.0 - float(player.get("sanity")) / UNEASE_BELOW, 0.0, 1.0)
	layer.aberration = SPLIT + 2.5 * unease
	_garble = maxf(0.0, _garble - dt)
	if _garble <= 0.0 and randf() < unease * dt * 1.5:
		_garble = randf_range(0.05, 0.12)
		_garbled = ""
		for ch in _figure():
			_garbled += GARBLE[randi() % GARBLE.length()] if randf() < 0.6 else ch

# ---- drawing --------------------------------------------------------------------------
func _figure() -> String:
	return "+%d" % roundi(_shown)

## 0..1: how big a reading this is (log scale, so a +3 is small but still reads)
func _size_k() -> float:
	return clampf(SMALL_K + (1.0 - SMALL_K) * log(1.0 + _total) / log(1.0 + BIG_AT), SMALL_K, 1.0)

func _color() -> Color:
	if roundi(_shown) > GOLD_OVER: return GOLD
	return Term.GREEN if _first else Term.AMBER

## The current rank's share filled at `xp` (1 at the top)
func _frac(xp: int) -> float:
	var i := Clearance.tier_index(xp)
	if i + 1 >= Clearance.tiers.size():
		return 1.0
	var lo := int(Clearance.tier(i).get("yield", 0))
	var hi := int(Clearance.tier(i + 1).get("yield", lo + 1))
	return clampf(float(xp - lo) / float(maxi(hi - lo, 1)), 0.0, 1.0)

func _draw_canvas() -> void:
	if not _active or _lines.is_empty():
		return
	var drift := FLOAT_UP * _out * _out
	var a := Term.flicker(clampf(_life / 0.2, 0.0, 1.0)) * (1.0 - clampf(_out, 0.0, 1.0))
	if _phase == "rank":
		_draw_rank(drift, a)
		var gone := clampf(_phase_t / 0.2, 0.0, 1.0)      # the gain gives way to it
		if gone >= 1.0:
			return
		a *= 1.0 - gone
	_draw_gain(drift, a)

## On its card: the caption, the figure (its unit small after it), the latest bonus, the hairline
func _draw_gain(drift: float, a: float) -> void:
	var col := _color()
	var px := int(round(BIG_PX * _size_k()))
	var unit := Clearance.unit
	var gap := 8.0
	var uw := font.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, UNIT_PX).x
	# the card is as wide as the widest thing it will hold (the final figure, the longest bonus), so it never jumps
	var w := font.get_string_size("+%d" % _total, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x + gap + uw
	w = maxf(w, wide.get_string_size(str(_lines[0][0]), HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_PX).x)
	for ln in _lines.slice(1):
		w = maxf(w, _bonus_w(ln))
	w = clampf(w + CARD_PAD * 2.0, CARD_MIN, BOX.x)
	var cx := BOX.x - w * 0.5                   # right-aligned with the strip
	var y := BOX.y - 60.0 - drift               # the figure's baseline
	var top := y - px * 0.8 - 42.0
	_draw_card(Rect2(cx - w * 0.5, top, w, y + 60.0 - top), col, a)
	_text(Vector2(cx, top + 26.0), str(_lines[0][0]), LABEL_PX, Color(Term.TEXT, 0.75 * a), HORIZONTAL_ALIGNMENT_CENTER, wide, w - 40.0)
	var num := _garbled if _garble > 0.0 else _figure()
	var nw := font.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	var mid := Vector2(cx, y - px * 0.35)
	canvas.draw_set_transform(mid, 0.0, Vector2.ONE * _punch)
	var x0 := -(nw + gap + uw) * 0.5
	_text(Vector2(x0, y - mid.y), num, px, Color(col, a))
	_text(Vector2(x0 + nw + gap, y - mid.y), unit, UNIT_PX, Color(col.lerp(Term.TEXT, 0.4), 0.85 * a))
	canvas.draw_set_transform(Vector2.ZERO)
	# the newest bonus on its own line, rising in as it lands; the one before it rises on out of the way
	if _landed >= 2:
		var ln: Array = _lines[_landed - 1]
		var u := clampf(float(ln[2]) / 0.2, 0.0, 1.0)
		if _landed >= 3 and u < 1.0:
			_bonus(_lines[_landed - 2], cx, y + 30.0 - 8.0 * u, col, (1.0 - u) * a)
		_bonus(ln, cx, y + 30.0 + 6.0 * (1.0 - u), col, u * a)
	_draw_bar(Vector2(cx - BAR_W * 0.5, y + 45.0), a)

## The toast's card (terminal_toast.gd _draw_sheet): dark, its top-right corner cut, a faint outline, the cut
## edge and a bar down the left side in `col`
func _draw_card(r: Rect2, col: Color, a: float) -> void:
	var c := CHAMFER
	var p := r.position
	var e := r.end
	var shape := PackedVector2Array([p, Vector2(e.x - c, p.y), Vector2(e.x, p.y + c), e, Vector2(p.x, e.y)])
	canvas.draw_colored_polygon(shape, Color(FILL, FILL.a * a))
	shape.append(p)
	canvas.draw_polyline(shape, Color(col, 0.3 * a), 1.0, true)
	canvas.draw_line(Vector2(e.x - c, p.y), Vector2(e.x, p.y + c), Color(col, 0.85 * a), 2.0, true)
	canvas.draw_rect(Rect2(p, Vector2(ACCENT_W, r.size.y)), Color(col, a))

func _bonus_w(ln: Array) -> float:
	return font.get_string_size("+%d" % int(ln[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, BONUS_PX).x + 14.0 		+ font.get_string_size(str(ln[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, BONUS_PX - 2).x

## "+65  PROXIMITY PREMIUM", centred on `cx`, baseline `y`
func _bonus(ln: Array, cx: float, y: float, col: Color, a: float) -> void:
	var amt := "+%d" % int(ln[1])
	var lab := str(ln[0])
	var aw := font.get_string_size(amt, HORIZONTAL_ALIGNMENT_LEFT, -1, BONUS_PX).x
	var lw := minf(font.get_string_size(lab, HORIZONTAL_ALIGNMENT_LEFT, -1, BONUS_PX - 2).x, BOX.x - 200.0)
	var bx := cx - (aw + 14.0 + lw) * 0.5
	_text(Vector2(bx, y), amt, BONUS_PX, Color(col, a))
	_text(Vector2(bx + aw + 14.0, y), lab, BONUS_PX - 2, Color(Term.TEXT, 0.85 * a), HORIZONTAL_ALIGNMENT_LEFT, null, BOX.x - 200.0)

## A hairline toward the next rank, in the rank's colour: what was there before dim, what the count adds bright,
## a bright tip where it has got to. Full and blinking for a moment when the count goes past a rank.
func _draw_bar(at: Vector2, a: float) -> void:
	var rc := Clearance.tier_color(_tier)
	canvas.draw_rect(Rect2(at, Vector2(BAR_W, 2.0)), Color(Term.TEXT, 0.12 * a))
	if _flash > 0.0:
		canvas.draw_rect(Rect2(at, Vector2(BAR_W, 2.0)), Color(Term.TEXT if int(_flash * 14.0) % 2 == 0 else rc, a))
		return
	var had := _frac(_base) if Clearance.tier_index(_base) == _tier else 0.0
	var now := _frac(_base + roundi(_shown))
	canvas.draw_rect(Rect2(at, Vector2(BAR_W * had, 2.0)), Color(rc, 0.45 * a))
	canvas.draw_rect(Rect2(at + Vector2(BAR_W * had, 0.0), Vector2(BAR_W * (now - had), 2.0)), Color(rc, a))
	canvas.draw_rect(Rect2(at + Vector2(BAR_W * now - 2.0, -1.0), Vector2(4.0, 4.0)), Color(Term.TEXT, a))

## RANK UP between two rules, the rank's name big in its colour with its effects, its number under it.
## Lands big and settles; the whole of it breathes if the rank pulses.
func _draw_rank(drift: float, a: float) -> void:
	var t := _phase_t
	var fx: Array = Clearance.tier_effects(_rank_to)
	var col := Clearance.tier_color(_rank_to)
	var k: float = Tween.interpolate_value(1.25, -0.25, minf(t, 0.32), 0.32, Tween.TRANS_BACK, Tween.EASE_OUT)
	if "pulse" in fx:
		k *= 1.0 + 0.04 * sin(t * 8.0)
	var fade := clampf((_rank_len - t) / 0.4, 0.0, 1.0) * Term.flicker(clampf(t / 0.2, 0.0, 1.0)) * a
	var title := str(Clearance.tier(_rank_to).get("title", ""))
	var w := clampf(font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, RANK_PX).x + CARD_PAD * 2.0 + 40.0, CARD_MIN, BOX.x)
	var cx := BOX.x - w * 0.5
	var y := BOX.y - 46.0 - drift              # the name's baseline
	var top := y - RANK_PX - 54.0
	_draw_card(Rect2(cx - w * 0.5, top, w, y + 46.0 - top), col, fade)
	var mid := Vector2(cx, y - RANK_PX * 0.35)
	canvas.draw_set_transform(mid, 0.0, Vector2.ONE * k)
	var o := Vector2(0.0, y - mid.y)
	var head := "RANK UP"
	var hw := wide.get_string_size(head, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_PX).x
	var hy := o.y - RANK_PX - 16.0
	_text(Vector2(0.0, hy), head, LABEL_PX, Color(col.lerp(Term.TEXT, 0.3), 0.9 * fade), HORIZONTAL_ALIGNMENT_CENTER, wide)
	var rule := Color(col, 0.5 * fade)
	var ry := hy - LABEL_PX * 0.35
	canvas.draw_line(Vector2(-hw * 0.5 - 60.0, ry), Vector2(-hw * 0.5 - 12.0, ry), rule, 1.0)
	canvas.draw_line(Vector2(hw * 0.5 + 12.0, ry), Vector2(hw * 0.5 + 60.0, ry), rule, 1.0)
	_fx_text(o, title, RANK_PX, col, fade, t, fx)
	_text(Vector2(0.0, o.y + 28.0), str(Clearance.tier(_rank_to).get("code", "")), LABEL_PX, Color(Term.MUTED, 0.85 * fade),
		HORIZONTAL_ALIGNMENT_CENTER, wide)
	canvas.draw_set_transform(Vector2.ZERO)

## `s` centred on `at` (baseline), a letter at a time so the rank's effects can move each one:
##   glow     a soft halo round every letter
##   shine    a white glint sweeping along the word
##   wave     the letters bob, one after another
##   pulse    (the whole rank-up breathes: _draw_rank)
##   flicker  a letter drops out or shows wrong now and then (the top ranks: the place has noticed you)
func _fx_text(at: Vector2, s: String, px: int, col: Color, fade: float, t: float, fx: Array) -> void:
	var widths: Array = []
	var w := 0.0
	for ch in s:
		var cw := font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
		widths.append(cw)
		w += cw
	var x := at.x - w * 0.5
	var n := s.length()
	var head := fmod(t * 14.0, n + 8.0) - 4.0       # where the glint is along the word
	for i in n:
		var ch := s[i]
		var p := Vector2(x, at.y)
		if "wave" in fx:
			p.y -= 4.0 * sin(t * 6.0 - i * 0.55)
		var c := col
		if "shine" in fx:
			c = col.lerp(Color.WHITE, clampf(1.0 - absf(i - head) / 1.6, 0.0, 1.0) * 0.85)
		var alpha := fade
		if "flicker" in fx and ch != " " and randf() < 0.05:
			if randf() < 0.5:
				alpha *= 0.15
			else:
				ch = GARBLE[randi() % GARBLE.length()]
		if "glow" in fx:
			for o in [Vector2(-2, 0), Vector2(2, 0), Vector2(0, -2), Vector2(0, 2)]:
				canvas.draw_string(font, p + o, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(col, 0.2 * alpha))
		canvas.draw_string(font, p + Vector2(0.0, 2.0), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, 0.8 * alpha))
		canvas.draw_string(font, p, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(c, alpha))
		x += widths[i]

## A faint glow in the new rank's colour drawn in round the screen's edge, fading out
func _draw_edge() -> void:
	if _edge <= 0.0:
		return
	var r := Rect2(Vector2.ZERO, edge.size)
	for i in 12:
		var w := 4.0
		var k := (1.0 - float(i) / 12.0)
		edge.draw_rect(r.grow(-w * (i + 0.5)), Color(_edge_col, 0.16 * _edge * k * k), false, w)

## Draws `s` on the baseline at `pos`, aligned on it, with the HUD's drop shadow; trimmed to `max_w` if given
func _text(pos: Vector2, s: String, px: int, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT, f: Font = null, max_w := -1.0) -> void:
	if s == "" or color.a <= 0.002:
		return
	var fnt: Font = f if f else font
	var w := fnt.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	if max_w > 0.0 and w > max_w:
		while s.length() > 1 and fnt.get_string_size(s + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > max_w:
			s = s.left(s.length() - 1)
		s += "…"
		w = fnt.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	var x := pos.x
	if align == HORIZONTAL_ALIGNMENT_RIGHT: x -= w
	elif align == HORIZONTAL_ALIGNMENT_CENTER: x -= w * 0.5
	canvas.draw_string(fnt, Vector2(x, pos.y + 2.0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, 0.8 * color.a))
	canvas.draw_string(fnt, Vector2(x, pos.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)
