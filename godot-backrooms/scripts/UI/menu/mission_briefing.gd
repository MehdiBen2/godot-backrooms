extends Control
## T.S.R.A. mission briefing: the screen between PLAY and the loading bar (main_menu.gd _on_play).
## Reads the current level's block of levels/tsra_briefings.json ("_default" when it has none). A secure uplink
## boots and decrypts the file, then the page types out like a terminal: assignment, objective, hearsay from the
## field, anomalies to look into, standing orders. All of it is seen through shaders/briefing_crt.gdshader (curve,
## scanlines, light grain, tracking tears) over a low ambience bed and key ticks.
## Any key or click skips ahead (boot -> page, typing -> all text); once it is all up, Enter / Space / click
## accepts, the page fades and `accepted` fires. The briefing only hints; the dossier and the scanner have the facts.

signal accepted

const DATA_PATH := "res://levels/tsra_briefings.json"
const CRT_SHADER := preload("res://shaders/briefing_crt.gdshader")
const BED_DEFAULT := "res://audio/ambients/creepy-ambience-long-hollow-loop_130bpm.wav"
const SND_ON := "res://audio/terminal/terminal_on.wav"
const SND_KEY := "res://audio/terminal/terminal_select.wav"
const SND_TAB := "res://audio/terminal/terminal_tab.wav"
const SND_OK := "res://audio/terminal/terminal_logged.wav"
const BED_DB := -24.0
const KEY_DB := -26.0
const CREAM := Color("e6e1cd")
const DIMC := Color(0.9, 0.882, 0.804, 0.55)
const AMBER := Color("d9a441")
const RED := Color("c4271f")
const CPS := 95.0                       # page typing speed, characters per second
const BOOT_CPS := 170.0
const DECRYPT_TIME := 1.1
const LEFT_X := 110.0
const RIGHT_X := 1130.0
const LEFT_W := 900.0
const RIGHT_W := 680.0

var font: FontFile = load("res://fonts/vcr.ttf")
var phase := ""                          # boot, decrypt, page, ready, out
var rows: Array[Label] = []              # the rows typing now, in reading order
var row_pause: Array[float] = []         # beat before each row starts
var row_kick: Array[bool] = []           # section headers: a small tear and a tab click as they start
var boot_rows: Array[Label] = []
var boot_pause: Array[float] = []
var boot_kick: Array[bool] = []
var page_rows: Array[Label] = []
var page_pause: Array[float] = []
var page_kick: Array[bool] = []
var cur := 0
var budget := 0.0
var wait := 0.0
var key_chars := 0
var t := 0.0
var data := {}
var dossier := {}

var boot: Control
var page: Control
var decrypt_bar: ColorRect
var decrypt_pct: Label
var decrypt_t := 0.0
var prompt: Label
var rec_dot: ColorRect
var scope: Control
var crt_mat: ShaderMaterial
var glitch := 0.0
var next_glitch := 4.0

var bed: AudioStreamPlayer
var key_snd: AudioStreamPlayer
var tab_snd: AudioStreamPlayer
var ok_snd: AudioStreamPlayer
var on_snd: AudioStreamPlayer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

## Builds the screen for the level and starts the uplink
func open(level_id: String, level_name: String) -> void:
	for c in get_children():
		c.queue_free()
	data = _briefing(level_id)
	dossier = Archive.dossiers().get(level_id, {})

	var black := ColorRect.new()
	black.color = Color(0.008, 0.008, 0.005)
	add_child(black)
	_full(black)
	_build_chrome()
	_build_boot()
	_build_page(level_name)
	_build_crt()
	_build_audio()

	_start_rows(boot_rows, boot_pause, boot_kick)
	phase = "boot"
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.5).set_trans(Tween.TRANS_SINE)
	_kick(0.7)
	on_snd.play()

func _briefing(level_id: String) -> Dictionary:
	var all = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	if not (all is Dictionary):
		return {}
	return all.get(level_id, all.get("_default", {}))

# ---- building ---------------------------------------------------------------------------

## REC dot, agency line, the signal trace and the CONTRACTOR COPY stamp along the top
func _build_chrome() -> void:
	var dot_row := HBoxContainer.new()
	dot_row.add_theme_constant_override("separation", 10)
	dot_row.position = Vector2(LEFT_X, 72)
	add_child(dot_row)
	rec_dot = ColorRect.new()
	rec_dot.color = RED
	rec_dot.custom_minimum_size = Vector2(9, 9)
	var dc := CenterContainer.new()
	dc.add_child(rec_dot)
	dot_row.add_child(dc)
	dot_row.add_child(_label("REC", 13, DIMC, 4))
	var file := _label("T.S.R.A. // CONTRACTOR SERVICES // DEPLOYMENT FILE %s" % str(data.get("file_no", "SR-0000")), 14, DIMC, 3)
	file.position = Vector2(LEFT_X + 150, 70)
	add_child(file)
	# the uplink's carrier: a wavering trace that jumps when the picture tears
	scope = Control.new()
	scope.position = Vector2(1010, 60)
	scope.size = Vector2(250, 36)
	scope.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scope.draw.connect(_draw_scope)
	add_child(scope)
	var stamp := _label("CONFIDENTIAL // CONTRACTOR COPY", 13, RED, 4)
	stamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stamp.position = Vector2(1920 - LEFT_X - 520, 72)
	stamp.size = Vector2(520, 20)
	add_child(stamp)
	var rule := ColorRect.new()
	rule.color = Color(0.9, 0.882, 0.804, 0.15)
	rule.position = Vector2(LEFT_X, 112)
	rule.size = Vector2(1920 - LEFT_X * 2, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rule)

## The uplink: a few status lines, then the decrypt bar
func _build_boot() -> void:
	boot = Control.new()
	add_child(boot)
	_full(boot)
	var box := _column(boot, Vector2(660, 380), 600)
	boot_rows.clear()
	boot_pause.clear()
	boot_kick.clear()
	var tier: Dictionary = Clearance.tier()
	for line in [
			["T.S.R.A. // CONTRACTOR SERVICES", 22, CREAM, 0.2],
			["ROUTING ............. RELAY %d" % (3 + absi(str(data.get("file_no", "")).hash()) % 9), 16, DIMC, 0.25],
			["CONTRACTOR .......... %s" % str(tier.get("code", "C-0")), 16, DIMC, 0.15],
			["LIABILITY WAIVER .... ON FILE", 16, DIMC, 0.15],
			["NEXT OF KIN ......... NOT REQUIRED", 16, DIMC, 0.2],
			["RETRIEVING DEPLOYMENT FILE %s" % str(data.get("file_no", "SR-0000")), 16, CREAM, 0.3]]:
		boot_rows.append(_row(box, line[0], line[1], line[2], 3, 0))
		boot_pause.append(line[3])
		boot_kick.append(false)
	var track := ColorRect.new()
	track.color = Color(0.9, 0.882, 0.804, 0.15)
	track.custom_minimum_size = Vector2(600, 2)
	box.add_child(track)
	decrypt_bar = ColorRect.new()
	decrypt_bar.color = CREAM
	decrypt_bar.size = Vector2(0, 2)
	track.add_child(decrypt_bar)
	decrypt_pct = _label("", 12, DIMC, 4)
	box.add_child(decrypt_pct)

## The briefing itself, hidden until the file is decrypted
func _build_page(level_name: String) -> void:
	page = Control.new()
	page.visible = false
	add_child(page)
	_full(page)
	page_rows.clear()
	page_pause.clear()
	page_kick.clear()

	# left column: who, where, what, and on what terms
	var left := _column(page, Vector2(LEFT_X, 150), LEFT_W)
	var designation := str(dossier.get("designation", level_name.to_upper()))
	var threat := str(dossier.get("threat_classification", "UNDETERMINED"))
	_page_row(left, "DEPLOYMENT NOTICE", 34, CREAM, 6, 0.2, true)
	_page_row(left, "ASSIGNMENT  %s" % str(data.get("assignment", "UNSCHEDULED SURVEY")), 18, AMBER, 3, 0.1, false, 6)
	_page_row(left, "CONTRACTOR  %s" % Clearance.tier_label(), 16, DIMC, 3, 0.05)
	_page_row(left, "SITE        %s" % designation, 16, DIMC, 3, 0.05)
	_page_row(left, "THREAT      <%s>" % threat, 16, RED, 3, 0.05, false, 18)
	_page_row(left, "OBJECTIVE", 15, DIMC, 5, 0.3, true)
	_page_row(left, str(data.get("objective", "")), 20, CREAM, 1, 0.1, false, 18)
	_page_row(left, "SITUATION", 15, DIMC, 5, 0.25, true)
	_page_row(left, str(data.get("situation", "")), 18, CREAM, 1, 0.1, false, 18)
	var terms: Array = data.get("terms", [])
	if not terms.is_empty():
		_page_row(left, "TERMS OF DEPLOYMENT", 15, DIMC, 5, 0.25, true)
		for s in terms:
			_page_row(left, "- %s" % str(s), 16, DIMC, 1, 0.05, false, 2)

	# right column: material from earlier deployments, what to record, conduct
	var right := _column(page, Vector2(RIGHT_X, 150), RIGHT_W)
	_page_row(right, "PRIOR MATERIAL // UNREVIEWED", 15, DIMC, 5, 0.3, true)
	for r in data.get("reports", []):
		_page_row(right, "[%s // %s]" % [str(r.get("source", "UNKNOWN")), str(r.get("reliability", "UNVERIFIED"))], 14, AMBER, 2, 0.15, false, 2)
		_page_row(right, str(r.get("text", "")), 16, CREAM, 1, 0.05, false, 10)
	var look: Array = data.get("investigate", [])
	if not look.is_empty():
		_page_row(right, "DATA REQUIREMENTS", 15, DIMC, 5, 0.3, true, 0, 4)
		for s in look:
			_page_row(right, "[ ] %s" % str(s), 16, CREAM, 1, 0.05, false, 4)
	var orders: Array = data.get("orders", [])
	if not orders.is_empty():
		_page_row(right, "CONDUCT POLICY", 15, DIMC, 5, 0.3, true, 0, 10)
		for i in orders.size():
			_page_row(right, "%d. %s" % [i + 1, str(orders[i])], 16, CREAM, 1, 0.05, false, 2)

	var sign_line := _label(str(data.get("sign_off", "")), 15, DIMC, 2)
	sign_line.position = Vector2(LEFT_X, 930)
	sign_line.visible_characters = 0
	page.add_child(sign_line)
	page_rows.append(sign_line)
	page_pause.append(0.5)
	page_kick.append(false)

	prompt = _label("[ ENTER ]  ACKNOWLEDGE AND PROCEED", 20, CREAM, 5)
	prompt.position = Vector2(LEFT_X, 980)
	prompt.modulate.a = 0.0
	page.add_child(prompt)
	var legal := _label("THIS NOTICE REMAINS T.S.R.A. PROPERTY. UNAUTHORISED RETENTION IS A BREACH OF CONTRACT.", 11, Color(0.9, 0.882, 0.804, 0.3), 2)
	legal.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	legal.position = Vector2(1920 - LEFT_X - 1100, 1000)
	legal.size = Vector2(1100, 16)
	page.add_child(legal)

## The tube over everything drawn before it. The title screen's own blur already took the frame's screen copy
## (the menu picture); without a fresh copy here the tube would show that instead of the page.
func _build_crt() -> void:
	var copy := BackBufferCopy.new()
	copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(copy)
	var crt := ColorRect.new()
	add_child(crt)
	_full(crt)
	crt_mat = ShaderMaterial.new()
	crt_mat.shader = CRT_SHADER
	crt.material = crt_mat

func _build_audio() -> void:
	var bed_path := str(data.get("ambience", BED_DEFAULT))
	if not ResourceLoader.exists(bed_path):
		bed_path = BED_DEFAULT
	bed = _player(bed_path, -50.0)
	bed.stream = _looped(bed.stream)
	bed.finished.connect(bed.play)          # (belt and braces: a stream that still ends starts over)
	bed.play()
	create_tween().tween_property(bed, "volume_db", BED_DB, 2.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	key_snd = _player(SND_KEY, KEY_DB)
	key_snd.max_polyphony = 3
	tab_snd = _player(SND_TAB, -18.0)
	ok_snd = _player(SND_OK, -10.0)
	on_snd = _player(SND_ON, -12.0)

## A copy of `s` set to loop end to end, whatever its import settings say (the in-game ambience shares the file)
func _looped(s: AudioStream) -> AudioStream:
	if s is AudioStreamWAV:
		var w := s.duplicate() as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(w.get_length() * w.mix_rate)
		return w
	if s is AudioStreamMP3 or s is AudioStreamOggVorbis:
		var c := s.duplicate()
		c.loop = true
		return c
	return s

func _player(path: String, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = load(path)
	p.volume_db = db
	add_child(p)
	return p

func _column(parent: Control, pos: Vector2, w: float) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.position = pos
	box.custom_minimum_size = Vector2(w, 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(box)
	return box

func _page_row(box: VBoxContainer, text: String, size: int, color: Color, spacing: float, pause: float,
		kick := false, gap := 0, pre := 0) -> void:
	page_rows.append(_row(box, text, size, color, spacing, gap, pre))
	page_pause.append(pause)
	page_kick.append(kick)

## One line / paragraph in a column, hidden until typed. `gap`: space after, `pre`: space before
func _row(box: VBoxContainer, text: String, size: int, color: Color, spacing: float, gap := 0, pre := 0) -> Label:
	if pre > 0:
		var sp := Control.new()
		sp.custom_minimum_size = Vector2(0, pre)
		box.add_child(sp)
	var l := _label(text, size, color, spacing)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(box.custom_minimum_size.x, 0)
	l.visible_characters = 0
	box.add_child(l)
	if gap > 0:
		var sp2 := Control.new()
		sp2.custom_minimum_size = Vector2(0, gap)
		box.add_child(sp2)
	return l

func _label(text: String, size: int, color: Color, spacing := 0.0) -> Label:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", fv)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _full(c: Control) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE

# ---- running ----------------------------------------------------------------------------

func _start_rows(r: Array[Label], p: Array[float], k: Array[bool]) -> void:
	rows = r
	row_pause = p
	row_kick = k
	cur = 0
	budget = 0.0
	wait = row_pause[0] if not row_pause.is_empty() else 0.0

func _kick(amount: float) -> void:
	glitch = maxf(glitch, amount)

func _process(dt: float) -> void:
	if not visible:
		return
	t += dt
	rec_dot.color.a = 1.0 if fmod(t, 1.1) < 0.55 else 0.0
	glitch = move_toward(glitch, 0.0, dt * 2.2)
	next_glitch -= dt
	if next_glitch <= 0.0 and phase != "out":
		_kick(randf_range(0.2, 0.55))
		next_glitch = randf_range(3.5, 9.0)
	crt_mat.set_shader_parameter("glitch", glitch)
	scope.queue_redraw()

	match phase:
		"boot", "page":
			_type(dt, BOOT_CPS if phase == "boot" else CPS)
		"decrypt":
			decrypt_t += dt
			var p := clampf(decrypt_t / DECRYPT_TIME, 0.0, 1.0)
			p = floor(p * 24.0) / 24.0              # it jumps in blocks, like a real one
			decrypt_bar.size.x = 600.0 * p
			decrypt_pct.text = "%d%%" % int(p * 100.0)
			if decrypt_t >= DECRYPT_TIME + 0.25:
				_show_page()
		"ready":
			prompt.modulate.a = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 2.4))

func _type(dt: float, cps: float) -> void:
	if cur >= rows.size():
		return
	if wait > 0.0:
		wait -= dt
		if wait <= 0.0 and row_kick[cur]:
			_kick(0.3)
			tab_snd.play()
		return
	budget += dt * cps
	var n := int(budget)
	if n <= 0:
		return
	budget -= n
	var l := rows[cur]
	l.visible_characters = mini(l.visible_characters + n, l.text.length())
	key_chars += n
	if key_chars >= 4:
		key_chars = 0
		key_snd.pitch_scale = randf_range(0.85, 1.3)
		key_snd.play()
	if l.visible_characters >= l.text.length():
		cur += 1
		if cur >= rows.size():
			_rows_done()
		else:
			wait = row_pause[cur]

func _rows_done() -> void:
	for l in rows:
		l.visible_characters = -1
	cur = rows.size()
	if phase == "boot":
		phase = "decrypt"
		decrypt_t = 0.0
	elif phase == "page":
		phase = "ready"

func _show_page() -> void:
	if not is_instance_valid(boot):
		return
	boot.queue_free()
	page.visible = true
	_kick(1.0)
	tab_snd.play()
	_start_rows(page_rows, page_pause, page_kick)
	phase = "page"

func _accept() -> void:
	if phase == "out":
		return
	phase = "out"
	prompt.text = "ACKNOWLEDGED. DEPLOYMENT LOGGED."
	prompt.modulate.a = 1.0
	prompt.add_theme_color_override("font_color", AMBER)
	ok_snd.play()
	_kick(0.85)
	# the bed keeps fading under the loading screen; the page goes first
	create_tween().tween_property(bed, "volume_db", -60.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.7).set_delay(0.45).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(accepted.emit)
	tw.tween_callback(hide)

## The carrier trace: a slow wave with noise on it, thrown about by the tears
func _draw_scope() -> void:
	var w := scope.size.x
	var h := scope.size.y
	scope.draw_rect(Rect2(0, h * 0.5, w, 1), Color(0.9, 0.882, 0.804, 0.12))
	var pts := PackedVector2Array()
	var amp := h * (0.12 + glitch * 0.35)
	for i in 64:
		var x := w * i / 63.0
		var y := h * 0.5 + sin(i * 0.45 + t * 5.0) * amp * 0.6 + randf_range(-1.0, 1.0) * amp * (0.3 + glitch)
		pts.append(Vector2(x, clampf(y, 0.0, h)))
	scope.draw_polyline(pts, Color(0.851, 0.643, 0.255, 0.75), 1.5)

func _input(e: InputEvent) -> void:
	if not visible or not e.is_pressed() or e.is_echo():
		return
	if not (e is InputEventKey or e is InputEventMouseButton):
		return
	get_viewport().set_input_as_handled()
	match phase:
		"boot", "decrypt":
			_show_page()
		"page":
			_rows_done()
		"ready":
			_accept()
