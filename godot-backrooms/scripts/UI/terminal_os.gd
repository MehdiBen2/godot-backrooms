extends Control
## The T.S.R.A. field terminal's screen: what the spawn room's CRT (scripts/World/props/terminal_machine.gd)
## shows on its glass. Built into that prop's SubViewport at SIZE, under the tube shader
## (shaders/terminal_crt.gdshader, a ColorRect drawn last so it reads everything under it).
##
## standby (what you walk up to) -> boot (BIOS checks, the OS loading) -> the T.S.R.A. emblem and the
## operative's authentication -> the main menu: ANOMALY ARCHIVE, MISSIONS, SUPPLY EXCHANGE, RECOVERED FILES.
## Every page is one list on the left and the selected entry's sheet on the right.
##
## Input comes from the prop: key() for the keyboard, and mouse events it pushes into the viewport (already in
## screen pixels), with pointer() placing the drawn cursor. Nothing here reads the real mouse or keyboard.

signal logged_off              # ESC on the main menu: the prop powers the tube down and pans back
signal sfx(id: String)         # a terminal_machine.gd SFX key: on / off / select / tab / scan / logged

const Kit = preload("res://scripts/UI/inventory/terminal_kit.gd")
const LOGO_PATH := "res://textures/ui/tsra_logo.png"     # tools/gen_tsra_logo.py
const CRT_SHADER := preload("res://shaders/terminal_crt.gdshader")

const SIZE := Vector2i(1024, 768)             # the PVM's glass is 4:3
const PAD := 50.0                              # clear of the tube's rounded corners
const LIST_W := 400.0

const AMBER := Kit.AMBER
const TEXT := Kit.TEXT
const TEXT_DIM := Kit.TEXT_DIM
const MUTED := Kit.MUTED
const GREEN := Kit.GREEN
const ORANGE := Kit.ORANGE
const RED := Kit.RED
const BG := Color(0.055, 0.036, 0.012)
const INK := Color(0.05, 0.03, 0.0)          # text on an inverse (selected) bar

const MENU := [
	{"id": "archive", "name": "ANOMALY ARCHIVE",
		"desc": "Field dossiers on every entity the agency has catalogued. An entry unlocks once you log the specimen with the field scanner [Q]."},
	{"id": "missions", "name": "MISSIONS",
		"desc": "Standing directives from Surface Command for this sector, with live progress from your field telemetry."},
	{"id": "supply", "name": "SUPPLY EXCHANGE",
		"desc": "Requisition field equipment against your research credits. Dispensed items go straight into your pack."},
	{"id": "files", "name": "RECOVERED FILES",
		"desc": "Memos, survey notes and transcripts recovered in the field, decrypted as your clearance allows."},
]

const CATALOG := [
	{"id": "battery", "name": "AA Battery Pack", "code": "BAT-02", "price": 15, "stack": 6,
		"icon": "res://models/aa_batteries.glb",
		"spec": "CLASS-A POWER CELL // 2x 1.5V ALKALINE",
		"desc": "A shrink-wrapped pair of high-discharge industrial AA cells, fully compatible with standard T.S.R.A. field flashlights. Restores 45% battery life per pack.",
		"protocol": "INSERT VIA BASE CAP COMPARTMENT [R]. DO NOT PUNCTURE HOUSING."},
	{"id": "flash", "name": "Camera Flash Speedlight", "code": "FLSH-01", "price": 25, "stack": 3,
		"icon": "res://models/camera_flash.glb",
		"spec": "CLASS-B DEFENSIVE EMITTER // XENON SPEEDLIGHT",
		"desc": "High-voltage xenon speedlight for perimeter defence. One blinding discharge that briefly disorients an approaching entity.",
		"protocol": "DISCHARGE TOWARD TARGET RETINAE [G]. THE REPORT MAY DRAW DISTANT ANOMALIES."},
	{"id": "tape", "name": "Reflective Hazard Tape", "code": "TAPE-01", "price": 20, "stack": 4,
		"icon": "res://scripts/World/props/tape_roll.gd",
		"spec": "CLASS-A SURVEY UTILITY // 250M RETROREFLECTIVE",
		"desc": "Retroreflective chevron boundary ribbon, 250 m to the spool. For corridor marking, breadcrumb navigation and catching topological loops before they catch you.",
		"protocol": "APPLY TO ANY SURFACE [T]. RETURNS TORCHLIGHT AT LONG RANGE."},
	{"id": "cable_spool", "name": "Heavy Equipment Cable Spool", "code": "CBL-01", "price": 35, "stack": 1,
		"icon": "res://scripts/World/props/cable_roll.gd",
		"spec": "CLASS-C ARTERY LINK // SHIELDED CONDUIT",
		"desc": "Shielded high-tensile power and telemetry cabling, used by exploration squads to run relays and mark primary transit arteries. It stays where it is laid.",
		"protocol": "UNSPOOL ALONG THE ROUTE [U]. COMPATIBLE WITH DRAW TOOLS [Y]."},
]

## Documents on the terminal's own drive. "lock": what decrypts one ("" always readable; an Archive entity id
## once that is logged; "clear:<unlock id>" once the clearance reaching it). The inventory's recovered papers
## (inventory.gd add_lore) are listed after these.
const FILES := [
	{"code": "MEMO-001", "title": "Operative Orientation", "lock": "",
		"text": "Welcome to the threshold. You are standing in a staging area maintained by the agency. It is the only room in this sector we can vouch for.\n\nYour job is to observe, mark and report. Log what you see with the field scanner. Mark your way with tape. Do not run unless you are sure where you are running to.\n\nThis terminal will be here when you come back. Assume nothing else will be."},
	{"code": "MEMO-014", "title": "On Return Paths", "lock": "",
		"text": "A corridor walked once is not guaranteed to lead back the way it came. Return paths on this level close after roughly forty metres of undocumented travel.\n\nMark every junction you pass. Tape is the only map that holds."},
	{"code": "KST-07", "title": "Kestrel Survey Log, Day 3", "lock": "survey_clipboard",
		"text": "Count of rooms on the east loop: 41. Count on the return pass: 40. Nobody remembers which one is missing.\n\nWe have started taping every doorway. Harlow says the tape on the third junction was moved a metre to the left overnight. I told her it was not. I am not sure that was true."},
	{"code": "KST-11", "title": "Kestrel Survey Log, Final", "lock": "mannequin",
		"text": "Do not turn your back on the display room. I am writing this facing the door. I can hear the others behind me arranging themselves."},
	{"code": "CL-ANNEX", "title": "Annex: The Threshold Hypothesis", "lock": "clear:classified",
		"text": "The levels are not built. They are remembered: assembled from the places people pass through without looking at. Every corridor here is somewhere someone once walked without noticing it.\n\nThat is why it notices you."},
]

static var credit_balance := 150
static var booted := false           # once a run has booted the terminal, it resumes in a few lines

var inventory: Control = null        # inventory.gd (the prop hands it over)
var state := "off"                   # off / standby / boot / menu / page
var page := ""
var sel := 0
var rows: Array = []                 # the PanelContainers of the current list
var t := 0.0

var stage: Control                   # the current screen's controls (rebuilt per screen)
var cursor: Control
var logo_tex: Texture2D
var clock_lbl: Label
var credits_lbl: Label
var detail: VBoxContainer
var detail_scroll: ScrollContainer
var status_lbl: Label
var caret: ColorRect
var blink: Array = []                # labels that blink while their screen is up
var pointer_at := Vector2(-1, -1)
var anim: Tween
var dispensing := false

# boot: a list of steps run one after another in _process
var steps: Array = []
var step := 0
var step_t := 0.0
var step_in := false
var boot_log: VBoxContainer
var line_right: Label

func _ready() -> void:
	size = Vector2(SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo_tex = _load_logo()
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	stage = Control.new()
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(stage)
	cursor = Control.new()
	cursor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor.draw.connect(_draw_pointer)
	add_child(cursor)
	var tube := ColorRect.new()
	tube.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tube.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = CRT_SHADER
	tube.material = mat
	add_child(tube)

## The emblem: imported if the editor has seen it, else read straight from the file (a fresh checkout)
func _load_logo() -> Texture2D:
	if ResourceLoader.exists(LOGO_PATH):
		return load(LOGO_PATH)
	var img := Image.load_from_file(ProjectSettings.globalize_path(LOGO_PATH))
	return ImageTexture.create_from_image(img) if img != null else null

# ---------------------------------------------------------------- screens
func _clear() -> void:
	if anim: anim.kill()
	for c in stage.get_children():
		stage.remove_child(c)
		c.queue_free()
	rows.clear()
	blink.clear()
	clock_lbl = null
	credits_lbl = null
	detail = null
	detail_scroll = null
	status_lbl = null
	caret = null

## The screen you walk up to: the emblem breathing, waiting for someone to press E
func standby() -> void:
	state = "standby"
	steps.clear()
	_clear()
	var col := _center_column(18)
	var logo := _logo(220)
	logo.modulate.a = 0.55
	col.add_child(logo)
	col.add_child(_center(Kit.label("T.S.R.A. FIELD TERMINAL FT-07", 26, AMBER, 6)))
	col.add_child(_center(Kit.label("THRESHOLD SPATIAL RESEARCH AGENCY", 17, MUTED, 3)))
	col.add_child(Kit.spacer(26))
	var wait := Kit.label("- STANDBY -", 22, AMBER, 4)
	col.add_child(_center(wait))
	blink.append(wait)
	col.add_child(_center(Kit.label("PRESS [E] TO ACCESS", 18, TEXT_DIM, 3)))

## Power on: BIOS checks and the OS loading, then the emblem, then the menu. ENTER skips to the menu.
func boot() -> void:
	state = "boot"
	_clear()
	boot_log = VBoxContainer.new()
	boot_log.position = Vector2(PAD + 6, PAD)
	boot_log.size = Vector2(SIZE) - Vector2(PAD, PAD) * 2.0
	boot_log.add_theme_constant_override("separation", 5)
	boot_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(boot_log)
	steps = _boot_steps()
	step = 0
	step_in = false

func _boot_steps() -> Array:
	var link_ok: bool = Game.terror < 0.2 and Game.glitch < 0.3
	var integrity := 58 + absi(hash(Game.level_index * 31 + Game.level_floor)) % 24
	var s: Array = []
	if booted:
		s.append({"k": "line", "text": "FT-07 // RESUMING SESSION", "col": AMBER, "wait": 0.12})
		s.append({"k": "check", "text": "SURFACE RELAY UPLINK", "ok": "ESTABLISHED" if link_ok else "DEGRADED", "col": GREEN if link_ok else ORANGE, "wait": 0.3})
		s.append({"k": "bar", "text": "RESTORING FIELD OS", "dur": 0.5})
		s.append({"k": "pause", "wait": 0.15})
		s.append({"k": "logo", "wait": 1.3})
		s.append({"k": "menu"})
		return s
	s.append({"k": "line", "text": "T.S.R.A. FIELD TERMINAL FT-07          BIOS REV 2.71", "col": AMBER, "wait": 0.18})
	s.append({"k": "line", "text": "(C) THRESHOLD SPATIAL RESEARCH AGENCY. PROPERTY OF THE AGENCY.", "col": MUTED, "wait": 0.12})
	s.append({"k": "line", "text": "", "wait": 0.1})
	s.append({"k": "line", "text": "CPU   TSRA-386DX FIELD PROCESSOR   33 MHZ", "wait": 0.1})
	s.append({"k": "count", "text": "MEMORY TEST", "to": 4096, "dur": 0.7})
	s.append({"k": "line", "text": "", "wait": 0.05})
	s.append({"k": "check", "text": "TAPE ARRAY 0", "ok": "OK", "col": GREEN, "wait": 0.22})
	s.append({"k": "check", "text": "ARCHIVE VOLUME /TSRA/FIELD", "ok": "MOUNTED", "col": GREEN, "wait": 0.32})
	s.append({"k": "check", "text": "SPATIAL SENSOR ARRAY", "ok": "CALIBRATED", "col": GREEN, "wait": 0.4})
	s.append({"k": "check", "text": "THRESHOLD INTEGRITY", "ok": "%d%% UNSTABLE" % integrity, "col": ORANGE, "wait": 0.45})
	s.append({"k": "check", "text": "SURFACE RELAY UPLINK", "ok": "ESTABLISHED" if link_ok else "DEGRADED", "col": GREEN if link_ok else ORANGE, "wait": 0.55})
	s.append({"k": "check", "text": "SUPPLY HOPPER", "ok": "PRIMED", "col": GREEN, "wait": 0.25})
	s.append({"k": "line", "text": "", "wait": 0.05})
	s.append({"k": "bar", "text": "LOADING T.S.R.A. FIELD OS 4.2", "dur": 1.1})
	s.append({"k": "line", "text": "", "wait": 0.05})
	s.append({"k": "line", "text": "NOTICE: DO NOT LEAVE THIS TERMINAL UNATTENDED.", "col": RED, "wait": 0.6})
	s.append({"k": "clear"})
	s.append({"k": "pause", "wait": 0.25})
	s.append({"k": "logo", "wait": 2.4})
	s.append({"k": "menu"})
	return s

func _run_steps(dt: float) -> void:
	while state == "boot" and step < steps.size():
		var s: Dictionary = steps[step]
		if not step_in:
			step_in = true
			step_t = 0.0
			_enter_step(s)
		step_t += dt
		dt = 0.0
		if not _step_done(s):
			return
		step += 1
		step_in = false

func _enter_step(s: Dictionary) -> void:
	match str(s.k):
		"line":
			_log(str(s.text), s.get("col", TEXT))
		"check", "count", "bar":
			_log(str(s.text), TEXT)
		"clear":
			for c in boot_log.get_children():
				c.queue_free()
		"logo":
			_emblem()
		"menu":
			booted = true
			open_menu()

func _step_done(s: Dictionary) -> bool:
	match str(s.k):
		"line", "pause", "logo":
			return step_t >= float(s.get("wait", 0.0))
		"check":
			var w := float(s.wait)
			if step_t < w:
				line_right.text = ".".repeat(1 + int(step_t * 9.0) % 3)
				return false
			line_right.text = str(s.ok)
			line_right.add_theme_color_override("font_color", s.col)
			sfx.emit("select")
			return true
		"count":
			var k := clampf(step_t / float(s.dur), 0.0, 1.0)
			line_right.text = "%dK" % int(k * float(s.to)) + (" OK" if k >= 1.0 else "")
			if k >= 1.0:
				line_right.add_theme_color_override("font_color", GREEN)
			return step_t >= float(s.dur) + 0.12
		"bar":
			var k := clampf(step_t / float(s.dur), 0.0, 1.0)
			var n := int(k * 24.0)
			line_right.text = "[%s%s] %3d%%" % ["#".repeat(n), ".".repeat(24 - n), int(k * 100.0)]
			if k >= 1.0:
				line_right.add_theme_color_override("font_color", GREEN)
			return step_t >= float(s.dur) + 0.15
	return true

func _log(text: String, col: Color) -> void:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Kit.label(text, 19, col, 2)
	l.custom_minimum_size.x = 520 if text != "" else 0
	h.add_child(l)
	line_right = Kit.label("", 19, AMBER, 2)
	h.add_child(line_right)
	boot_log.add_child(h)

## The emblem drawn in from the top like a slow raster, the agency's name typed under it, then the operative
## authenticated
func _emblem() -> void:
	sfx.emit("logged")
	var col := _center_column(14)
	var clip := Control.new()
	clip.clip_contents = true
	clip.custom_minimum_size = Vector2(300, 0)
	clip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var logo := _logo(300)
	clip.add_child(logo)
	col.add_child(clip)
	var name_lbl := Kit.label("T.S.R.A.", 64, AMBER, 18)
	col.add_child(_center(name_lbl))
	var full := Kit.label("THRESHOLD SPATIAL RESEARCH AGENCY", 19, TEXT, 4)
	col.add_child(_center(full))
	col.add_child(Kit.spacer(18))
	var auth := Kit.label("AUTHENTICATING OPERATIVE ...", 18, MUTED, 3)
	col.add_child(_center(auth))
	var granted := Kit.label("ACCESS GRANTED // %s" % _tier_code(), 20, GREEN, 3)
	col.add_child(_center(granted))
	for l in [name_lbl, full, auth, granted]:
		l.visible_ratio = 0.0
	var quick := booted
	anim = create_tween()
	anim.tween_property(clip, "custom_minimum_size:y", 300.0, 0.35 if quick else 0.75).set_trans(Tween.TRANS_SINE)
	anim.tween_property(name_lbl, "visible_ratio", 1.0, 0.2 if quick else 0.35)
	anim.tween_property(full, "visible_ratio", 1.0, 0.2 if quick else 0.4)
	anim.tween_property(auth, "visible_ratio", 1.0, 0.15 if quick else 0.3)
	anim.tween_callback(sfx.emit.bind("scan"))
	anim.tween_property(granted, "visible_ratio", 1.0, 0.15 if quick else 0.3).set_delay(0.1 if quick else 0.35)
	anim.tween_callback(sfx.emit.bind("select"))

# ---------------------------------------------------------------- the main menu
func open_menu(at := -1) -> void:
	state = "menu"
	page = ""
	steps.clear()
	_clear()
	var body := _chrome("MAIN MENU", "FIELD OPERATIONS NETWORK // SELECT A SERVICE")
	var box := PanelContainer.new()
	var sb := Kit.box(Color(AMBER, 0.03), Color(AMBER, 0.55), 2, 2)
	sb.set_content_margin_all(14)
	box.add_theme_stylebox_override("panel", sb)
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	list.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(list)
	body.add_child(box)
	for i in MENU.size():
		var r := _row(i, "%02d" % (i + 1), MENU[i].name, _menu_info(MENU[i].id), 30, 64)
		list.add_child(r)
	body.add_child(Kit.spacer(14))
	detail = VBoxContainer.new()
	detail.add_theme_constant_override("separation", 6)
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(detail)
	_footer(["▲▼ SELECT", "ENTER OPEN", "1-4 JUMP", "ESC LOG OFF"])
	sel = -1
	_select(clampi(at, 0, MENU.size() - 1) if at >= 0 else 0, true)

func _menu_info(id: String) -> String:
	match id:
		"archive":
			return "%d/%d LOGGED" % [_logged_count(), _entity_ids().size()]
		"missions":
			var open := 0
			for m in _missions():
				if int(m.have) < int(m.need): open += 1
			return "%d ACTIVE" % open
		"supply":
			return "%d CR" % credit_balance
		"files":
			var n := 0
			for f in _files():
				if f.open: n += 1
			return "%d FILES" % n
	return ""

# ---------------------------------------------------------------- pages
func open_page(id: String) -> void:
	state = "page"
	page = id
	_clear()
	sfx.emit("tab")
	var titles := {"archive": ["ANOMALY ARCHIVE", "ENTITY REGISTRY // %d OF %d LOGGED" % [_logged_count(), _entity_ids().size()]],
		"missions": ["MISSIONS", "SURFACE COMMAND DIRECTIVES // SECTOR %s" % _sector()],
		"supply": ["SUPPLY EXCHANGE", "FIELD REQUISITION // HOPPER ONLINE"],
		"files": ["RECOVERED FILES", "FIELD DRIVE /TSRA/RECOVERED"]}
	var body := _chrome(titles[id][0], titles[id][1])
	var deck := HBoxContainer.new()
	deck.size_flags_vertical = Control.SIZE_EXPAND_FILL
	deck.add_theme_constant_override("separation", 18)
	deck.mouse_filter = Control.MOUSE_FILTER_PASS
	body.add_child(deck)
	var list := VBoxContainer.new()
	list.custom_minimum_size.x = LIST_W
	list.add_theme_constant_override("separation", 4)
	list.mouse_filter = Control.MOUSE_FILTER_PASS
	deck.add_child(list)
	var entries := _page_rows(id)
	var code_w := 0.0
	for e in entries:
		code_w = maxf(code_w, 14.0 * str(e.code).length() + 6.0)
	for i in entries.size():
		var e: Dictionary = entries[i]
		list.add_child(_row(i, e.code, e.name, "", 18, 0, e.get("col", TEXT), code_w))
	var sheet := PanelContainer.new()
	sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := Kit.box(Color(AMBER, 0.035), Color(AMBER, 0.5), 2, 2)
	sb.set_content_margin_all(16)
	sheet.add_theme_stylebox_override("panel", sb)
	sheet.mouse_filter = Control.MOUSE_FILTER_PASS
	deck.add_child(sheet)
	detail_scroll = ScrollContainer.new()
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	detail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	detail_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	sheet.add_child(detail_scroll)
	detail = VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 7)
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail_scroll.add_child(detail)
	var hints := ["▲▼ SELECT", "PGUP/PGDN SCROLL", "ESC BACK"]
	if id == "supply":
		hints.insert(1, "ENTER DISPENSE")
	_footer(hints)
	sel = -1
	_select(0, true)

func _page_rows(id: String) -> Array:
	var out: Array = []
	match id:
		"archive":
			for eid in _entity_ids():
				var info := Archive.entity_info(eid)
				var known: bool = Archive.is_discovered(eid)
				out.append({"code": str(info.get("code", "----")).replace("TSRA-", ""),
					"name": str(info.get("common_name", eid)).to_upper() if known else "UNLOGGED SPECIMEN",
					"col": (AMBER if Archive.is_unread(eid) else TEXT) if known else TEXT_DIM})
		"missions":
			for m in _missions():
				var done: bool = int(m.have) >= int(m.need)
				out.append({"code": m.code, "name": m.name, "col": GREEN if done else TEXT})
		"supply":
			for it in CATALOG:
				out.append({"code": str(it.price) + "CR", "name": str(it.name).to_upper(), "col": TEXT if credit_balance >= int(it.price) else TEXT_DIM})
		"files":
			for f in _files():
				out.append({"code": f.code, "name": str(f.title).to_upper() if f.open else "[ENCRYPTED]", "col": TEXT if f.open else TEXT_DIM})
	return out

## The selected entry's sheet
func _fill_detail() -> void:
	if detail == null:
		return
	Kit.clear(detail)
	if detail_scroll:
		detail_scroll.scroll_vertical = 0
	if state == "menu":
		var m: Dictionary = MENU[sel]
		_d(">> " + str(m.name), 22, AMBER, 3)
		_d(str(m.desc), 18, MUTED, 1, true)
		_type_in()
		return
	match page:
		"archive": _detail_archive(_entity_ids()[sel])
		"missions": _detail_mission(_missions()[sel])
		"supply": _detail_supply(CATALOG[sel])
		"files": _detail_file(_files()[sel])
	_type_in()

func _detail_archive(eid: String) -> void:
	var info := Archive.entity_info(eid)
	var cls := str(info.get("threat_class", "UNKNOWN")).to_upper()
	_d(str(info.get("code", "")), 17, MUTED, 3)
	if not Archive.is_discovered(eid):
		_d("SPECIMEN NOT YET LOGGED", 22, AMBER, 2)
		_d("THREAT CLASS: " + cls, 18, _threat_col(cls), 2)
		_rule()
		for n in [4, 3, 4, 2]:
			detail.add_child(_redacted(eid + str(n), n))
		_rule()
		_d("FILE AN ENTRY: hold the field scanner [Q] on the specimen until the reading completes. The dossier decrypts the moment it is logged.", 17, TEXT_DIM, 1, true)
		return
	Archive.mark_read(eid)
	_d(str(info.get("common_name", eid)).to_upper(), 24, AMBER, 2)
	_d("THREAT CLASS: " + cls, 18, _threat_col(cls), 2)
	var logged := Archive.logged_info(eid)
	if logged.has("t"):
		_d("LOGGED " + Kit.local_time(int(logged.t)), 16, MUTED, 2)
	_rule()
	_d(str(info.get("description", "")), 17, TEXT, 1, true)
	if info.has("behavior_vector"):
		_d("BEHAVIOUR VECTOR", 16, MUTED, 2)
		_d(str(info.behavior_vector), 17, TEXT, 1, true)
	if info.has("directive"):
		_d("FIELD DIRECTIVE", 16, MUTED, 2)
		_d(str(info.directive), 17, AMBER, 1, true)
	var annex: Dictionary = info.get("classified", {})
	if annex.is_empty():
		return
	_rule()
	if not Clearance.has_unlock("classified"):
		_d("CLASSIFIED ANNEX // REQUIRES %s" % Clearance.unlock_code("classified"), 16, RED, 2, true)
		return
	_d("CLASSIFIED ANNEX", 16, RED, 2)
	if annex.has("origin"):
		_d(str(annex.origin), 17, TEXT, 1, true)
	for tip in annex.get("survival", []):
		_d("- " + str(tip), 17, TEXT_DIM, 1, true)

func _detail_mission(m: Dictionary) -> void:
	var done: bool = int(m.have) >= int(m.need)
	_d("DIRECTIVE " + str(m.code), 17, MUTED, 3)
	_d(str(m.name), 24, AMBER, 2)
	_d("STATUS: " + ("COMPLETE" if done else "ACTIVE"), 18, GREEN if done else ORANGE, 2)
	_rule()
	_d(str(m.brief), 17, TEXT, 1, true)
	_d("OBJECTIVE", 16, MUTED, 2)
	_d(str(m.goal), 18, TEXT, 1, true)
	var k := clampf(float(m.have) / float(maxi(int(m.need), 1)), 0.0, 1.0)
	var n := int(k * 20.0)
	_d("[%s%s] %s" % ["#".repeat(n), ".".repeat(20 - n), str(m.get("show", "%d / %d" % [mini(int(m.have), int(m.need)), int(m.need)]))], 18, GREEN if done else AMBER, 1)
	if str(m.get("reward", "")) != "":
		_d("REWARD", 16, MUTED, 2)
		_d(str(m.reward), 17, TEXT_DIM, 1, true)

func _detail_supply(it: Dictionary) -> void:
	var carried := _carried(str(it.id))
	_d("REQUISITION " + str(it.code), 17, MUTED, 3)
	_d(str(it.name).to_upper(), 24, AMBER, 2)
	_d(str(it.spec), 16, MUTED, 1, true)
	_rule()
	_d("COST: %d CR      BALANCE: %d CR" % [int(it.price), credit_balance], 18, GREEN if credit_balance >= int(it.price) else RED, 2)
	_d("CARRIED: %d / %d" % [carried, int(it.stack)], 18, TEXT, 2)
	_rule()
	_d(str(it.desc), 17, TEXT, 1, true)
	_d("PROTOCOL: " + str(it.protocol), 16, TEXT_DIM, 1, true)
	_rule()
	status_lbl = _d("", 18, GREEN, 2, true)
	_status()

func _detail_file(f: Dictionary) -> void:
	_d("FILE " + str(f.code), 17, MUTED, 3)
	if not f.open:
		_d("[ENCRYPTED]", 24, TEXT_DIM, 2)
		_rule()
		for n in [4, 3, 4, 2, 3]:
			detail.add_child(_redacted(str(f.code) + str(n), n))
		_rule()
		_d(str(f.hint), 17, TEXT_DIM, 1, true)
		return
	_d(str(f.title).to_upper(), 24, AMBER, 2)
	_rule()
	_d(str(f.text), 17, TEXT, 1, true)

# ---------------------------------------------------------------- the data behind the pages
func _entity_ids() -> Array:
	return Archive.entities().keys()

func _logged_count() -> int:
	var n := 0
	for id in _entity_ids():
		if Archive.is_discovered(id): n += 1
	return n

func _missions() -> Array:
	var level := Archive.current_level_id()
	var cells: int = (Clearance.surveyed.get(level, {}) as Dictionary).size()
	var open_cells := int(Clearance.survey_open.get(level, 0))
	var mapped := int(round(100.0 * cells / open_cells)) if open_cells > 0 else 0
	var next := Clearance.next_threshold()
	return [
		{"code": "MS-01", "name": "RECOVER KESTREL'S NOTES",
			"brief": "Survey Team KESTREL left their clipboards scattered through this sector before contact was lost. One lies a few steps from this terminal.",
			"goal": "Scan a survey clipboard with the field scanner [Q].",
			"have": 1 if Archive.is_discovered("survey_clipboard") else 0, "need": 1, "reward": "40 %s per clipboard. Decrypts file KST-07." % Clearance.unit},
		{"code": "MS-02", "name": "CATALOGUE THE RESIDENTS",
			"brief": "Every entity logged sharpens the agency's picture of this level. Readings taken closer, or under duress, are worth more.",
			"goal": "Log three entities with the field scanner [Q].",
			"have": _logged_count(), "need": 3, "reward": "100-260 %s per new entity, by threat class." % Clearance.unit},
		{"code": "MS-03", "name": "MAP THE THRESHOLD",
			"brief": "Corridors here do not stay where they were. Tape is the only map that holds. Mark junctions, doorways and dead ends as you go.",
			"goal": "Mark a quarter of the sector's open floor with hazard tape [T].",
			"have": mapped, "need": 25, "show": "%d%% / 25%%" % mapped, "reward": "1 %s per new cell, bonuses at 25 / 50 / 75%%." % Clearance.unit},
		{"code": "MS-04", "name": "DOCUMENT AN EGRESS",
			"brief": "Find the way out of this sector and prove it can be walked again. A route counts once your tape leads to the exit and you leave by it.",
			"goal": "Tape a route to the exit and take it.",
			"have": 1 if Clearance.routes.has(level) else 0, "need": 1, "reward": "40 %s plus 0.5 %s per metre of trail." % [Clearance.unit, Clearance.unit]},
		{"code": "MS-05", "name": "EARN THE NEXT RANK",
			"brief": "Each rank opens more: the classified annexes, the scanner's rangefinder and its deep-scan mode. It is earned in XP, nothing else.",
			"goal": "Reach %s." % ("the top rank" if Clearance.is_max_tier() else str(Clearance.tier(Clearance.tier_index() + 1).get("code", "the next tier"))),
			"have": Clearance.total, "need": next if not Clearance.is_max_tier() else Clearance.total, "show": "%d / %d %s" % [Clearance.total, next, Clearance.unit], "reward": ""},
	]

func _files() -> Array:
	var out: Array = []
	for f in FILES:
		var lock := str(f.lock)
		var open := true
		var hint := ""
		if lock.begins_with("clear:"):
			var id := lock.substr(6)
			open = Clearance.has_unlock(id)
			hint = "DECRYPTION KEY ISSUED AT %s." % Clearance.unlock_code(id)
		elif lock != "":
			open = Archive.is_discovered(lock)
			hint = "KEY FRAGMENT RECOVERABLE IN THE FIELD. LOG: %s." % str(Archive.entity_info(lock).get("code", lock))
		out.append({"code": f.code, "title": f.title, "text": f.text, "open": open, "hint": hint})
	var inv := _inventory()
	if inv:
		for e in inv.lore_entries:
			out.append({"code": "RCV-%02d" % (out.size() + 1), "title": str(e.title), "text": str(e.text), "open": true, "hint": ""})
	return out

func _inventory() -> Control:
	if inventory == null or not is_instance_valid(inventory):
		var ui = Game.main.get_node_or_null("UI") if Game.main else null
		inventory = ui.inventory if ui and ui.get("inventory") else null
	return inventory

func _carried(id: String) -> int:
	var inv := _inventory()
	return inv.item_count(id) if inv and inv.has_method("item_count") else 0

func _tier_code() -> String:
	return str(Clearance.tier().get("code", "RANK 0")) if not Clearance.tiers.is_empty() else "RANK 0"

func _sector() -> String:
	return "L%d-F%d" % [Game.level_index, Game.level_floor]

func _threat_col(cls: String) -> Color:
	var n := cls.to_int()
	if n >= 4: return RED
	if n == 3: return ORANGE
	if n >= 1: return AMBER
	return MUTED

# ---------------------------------------------------------------- the exchange
func _dispense() -> void:
	if dispensing:
		return
	var it: Dictionary = CATALOG[sel]
	if credit_balance < int(it.price):
		_status("REJECTED // INSUFFICIENT CREDITS", RED)
		sfx.emit("tab")
		return
	if _carried(str(it.id)) >= int(it.stack):
		_status("HALTED // CARRY LIMIT REACHED", ORANGE)
		sfx.emit("tab")
		return
	dispensing = true
	_status("ENERGIZING HOPPER // DISPENSING %s ..." % str(it.code), AMBER)
	sfx.emit("scan")
	var at := sel
	var tw := create_tween()
	tw.tween_interval(0.55)
	tw.tween_callback(func():
		dispensing = false
		credit_balance -= int(it.price)
		var inv := _inventory()
		if inv and inv.has_method("add_item"):
			inv.add_item(it.id, it.name, it.desc, 1, it.code, it.stack, it.icon)
		sfx.emit("logged")
		if state == "page" and page == "supply" and sel == at:
			_fill_detail()
			_status("DISPENSED // DELIVERED TO YOUR PACK", GREEN)
		if credits_lbl:
			credits_lbl.text = "%d CR" % credit_balance
	)

func _status(text := "", col := GREEN) -> void:
	if status_lbl == null:
		return
	if text == "":
		text = "DISPENSER: STANDBY // HOPPER READY"
	status_lbl.text = text
	status_lbl.add_theme_color_override("font_color", col)
	status_lbl.visible_ratio = 1.0

# ---------------------------------------------------------------- input (from terminal_machine.gd)
## A key press. Returns false when the terminal had nothing to do with it.
func key(k: Key) -> bool:
	match state:
		"boot":
			if k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
				booted = true
				open_menu()
				return true
			if k in [KEY_ESCAPE, KEY_E, KEY_TAB]:
				logged_off.emit()
				return true
		"menu":
			match k:
				KEY_UP, KEY_W: _select(wrapi(sel - 1, 0, MENU.size()))
				KEY_DOWN, KEY_S: _select(wrapi(sel + 1, 0, MENU.size()))
				KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_D, KEY_RIGHT: _activate(sel)
				KEY_1, KEY_2, KEY_3, KEY_4: _activate(k - KEY_1)
				KEY_ESCAPE, KEY_E, KEY_TAB, KEY_BACKSPACE: logged_off.emit()
				_: return false
			return true
		"page":
			match k:
				KEY_UP, KEY_W: _select(wrapi(sel - 1, 0, rows.size()))
				KEY_DOWN, KEY_S: _select(wrapi(sel + 1, 0, rows.size()))
				KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _activate(sel)
				KEY_PAGEUP: _scroll(-160)
				KEY_PAGEDOWN: _scroll(160)
				KEY_ESCAPE, KEY_E, KEY_TAB, KEY_BACKSPACE, KEY_A, KEY_LEFT: _back()
				_: return false
			return true
	return false

## Where the mouse is on the glass, in screen pixels (outside it: a negative position hides the cursor)
func pointer(at: Vector2) -> void:
	if at != pointer_at:
		pointer_at = at
		cursor.queue_redraw()

func _back() -> void:
	var from := MENU.map(func(m): return m.id).find(page)
	sfx.emit("tab")
	open_menu(from)

func _activate(i: int) -> void:
	if state == "menu":
		if i >= 0 and i < MENU.size():
			open_page(MENU[i].id)
	elif state == "page" and page == "supply":
		if i != sel:
			_select(i)
		_dispense()

func _scroll(px: int) -> void:
	if detail_scroll:
		detail_scroll.scroll_vertical += px

func _select(i: int, quiet := false) -> void:
	if i < 0 or i >= rows.size() or i == sel:
		return
	sel = i
	for j in rows.size():
		_style_row(j)
	if not quiet:
		sfx.emit("select")
	_fill_detail()

# ---------------------------------------------------------------- building blocks
## The frame every menu and page shares: the emblem and title bar, the operative's line, the rule under
## them; returns the column the screen's own content goes in. The footer is added by _footer().
func _chrome(title: String, sub: String) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.position = Vector2(PAD, PAD - 6)
	col.size = Vector2(SIZE) - Vector2(PAD * 2.0, PAD * 2.0 + 30.0)
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	stage.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_logo(58))
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.add_theme_constant_override("separation", 0)
	names.mouse_filter = Control.MOUSE_FILTER_IGNORE
	names.add_child(Kit.label("T.S.R.A. // " + title, 26, AMBER, 3))
	names.add_child(Kit.label(sub, 15, MUTED, 2))
	head.add_child(names)
	var right := VBoxContainer.new()
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_theme_constant_override("separation", 0)
	clock_lbl = Kit.label(Time.get_time_string_from_system(), 22, AMBER, 2)
	clock_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(clock_lbl)
	var term := Kit.label("TERMINAL FT-07", 15, MUTED, 2)
	term.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(term)
	head.add_child(right)
	col.add_child(head)
	col.add_child(Kit.hline(Color(AMBER, 0.8), 3))
	var ops := HBoxContainer.new()
	ops.add_theme_constant_override("separation", 10)
	ops.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for pair in [["OPERATIVE", str(Clearance.tier().get("title", "RECRUIT")), TEXT], ["RANK", _tier_code(), Clearance.tier_color()], ["CREDITS", "%d CR" % credit_balance, GREEN],
			["LINK", "STABLE" if Game.terror < 0.2 else "DEGRADED", GREEN if Game.terror < 0.2 else ORANGE]]:
		ops.add_child(Kit.label(pair[0], 15, MUTED, 2))
		var v := Kit.label(pair[1], 15, pair[2], 2)
		ops.add_child(v)
		if pair[0] == "CREDITS":
			credits_lbl = v
		ops.add_child(Kit.spacer_w(16))
	col.add_child(ops)
	col.add_child(Kit.hline(Color(AMBER, 0.3), 1))
	return col

func _footer(hints: Array) -> void:
	var bar := HBoxContainer.new()
	bar.position = Vector2(PAD, SIZE.y - PAD - 24)
	bar.size = Vector2(SIZE.x - PAD * 2.0, 26)
	bar.add_theme_constant_override("separation", 22)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rule := Kit.hline(Color(AMBER, 0.8), 3)
	rule.position = Vector2(PAD, SIZE.y - PAD - 34)
	rule.size = Vector2(SIZE.x - PAD * 2.0, 3)
	stage.add_child(rule)
	for h in hints:
		bar.add_child(Kit.label(h, 16, MUTED, 2))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(gap)
	bar.add_child(Kit.label("C:\\TSRA>", 16, AMBER, 2))
	caret = ColorRect.new()
	caret.color = AMBER
	caret.custom_minimum_size = Vector2(11, 18)
	caret.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	caret.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(caret)
	stage.add_child(bar)

## One line of a list: inverse video when selected. Hover selects it, a click opens / uses it.
func _row(i: int, code: String, title: String, info: String, px: int, h: float, col := TEXT, code_w := 44.0) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.custom_minimum_size.y = h
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 14)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mark := Kit.label(" ", px, AMBER, 1)
	line.add_child(mark)
	var c := Kit.label(code, px - 2, MUTED, 2)
	c.custom_minimum_size.x = code_w
	line.add_child(c)
	var n := Kit.label(title, px, col, 2)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.clip_text = true
	n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(n)
	var r := Kit.label(info, px - 8, MUTED, 2)
	line.add_child(r)
	for l in [mark, c, n, r]:
		l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_child(line)
	p.set_meta("labels", [mark, c, n, r])
	p.set_meta("col", col)
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseMotion and sel != i:
			_select(i)
		elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select(i)
			_activate(i)
	)
	rows.append(p)
	_style_row(rows.size() - 1)
	return p

func _style_row(j: int) -> void:
	var p: PanelContainer = rows[j]
	var on := j == sel
	var sb := Kit.box(AMBER if on else Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 2)
	sb.content_margin_left = 8
	sb.content_margin_right = 12
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	p.add_theme_stylebox_override("panel", sb)
	var ls: Array = p.get_meta("labels")
	var base: Color = p.get_meta("col")
	ls[0].text = "►" if on else " "
	ls[0].add_theme_color_override("font_color", INK if on else AMBER)
	ls[1].add_theme_color_override("font_color", INK if on else MUTED)
	ls[2].add_theme_color_override("font_color", INK if on else base)
	ls[3].add_theme_color_override("font_color", INK if on else MUTED)
	for l in ls:
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.0 if on else 0.8))

func _d(text: String, px: int, col: Color, spacing := 1.0, wrap := false) -> Label:
	var l := Kit.label(text, px, col, spacing, wrap)
	detail.add_child(l)
	return l

## A line of blacked-out words, narrow enough for the sheet (Kit.redacted's run wider than it)
func _redacted(id: String, bars: int) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rng := RandomNumberGenerator.new()
	rng.seed = id.hash()
	for i in bars:
		var bar := ColorRect.new()
		bar.color = Color(TEXT, 0.22)
		bar.custom_minimum_size = Vector2(rng.randi_range(36, 96), 14)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(bar)
	return h

func _rule() -> void:
	detail.add_child(Kit.hline(Color(AMBER, 0.25), 1))

## The sheet's text comes in like a terminal printing it, top to bottom
func _type_in() -> void:
	if anim: anim.kill()
	anim = create_tween()
	for c in detail.get_children():
		if c is Label and c != status_lbl:
			var l := c as Label
			l.visible_ratio = 0.0
			anim.tween_property(l, "visible_ratio", 1.0, clampf(l.text.length() / 900.0, 0.04, 0.3))

func _logo(px: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = logo_tex
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(px, px)
	r.size = Vector2(px, px)
	r.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

func _center_column(gap: int) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", gap)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(col)
	return col

func _center(l: Label) -> Label:
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

func _draw_pointer() -> void:
	if pointer_at.x < 0.0 or state == "standby" or state == "off":
		return
	var p := pointer_at
	var arrow := PackedVector2Array([p, p + Vector2(0, 22), p + Vector2(6, 16), p + Vector2(11, 25), p + Vector2(15, 23), p + Vector2(10, 14), p + Vector2(17, 14)])
	cursor.draw_colored_polygon(arrow, AMBER)
	arrow.append(p)
	cursor.draw_polyline(arrow, INK, 1.5)

func _process(dt: float) -> void:
	t += dt
	_run_steps(dt)
	var on := fmod(t, 1.0) < 0.55
	for l in blink:
		if is_instance_valid(l):
			l.modulate.a = 1.0 if on else 0.15
	if caret:
		caret.self_modulate.a = 1.0 if on else 0.0
	if clock_lbl and Engine.get_process_frames() % 20 == 0:
		clock_lbl.text = Time.get_time_string_from_system()
