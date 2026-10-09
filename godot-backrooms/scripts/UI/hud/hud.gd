extends CanvasLayer
## Camcorder HUD + pause menu, replicating the web game's #hud (backrooms.html / style.css):
## REC block + objective (top-left), level / timecode / tape mode (top-right), the vitals on the
## terminal's amber CRT (bottom-left, vitals_panel.gd), key hints (bottom-right), viewfinder corner
## brackets and the crosshair dot.
## Designed for a 1920x1080 canvas so pixel sizes match the browser.
## Also owns the TAB terminal (inventory.gd), the T.S.R.A. field scanner (scanner.gd, hold Q) with
## its reticle (scan_readout.gd), and the "new entry logged" / clearance toasts (terminal_toast.gd).
## And the reflective hazard tape (tape_tool.gd, hold T) with its tape mode HUD (tape_readout.gd), and
## the camera flash (flash_tool.gd, G or right click).

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const Scanner := preload("res://scripts/Player/scanner.gd")
const ScanReadout := preload("res://scripts/UI/hud/scan_readout.gd")
const TerminalToast := preload("res://scripts/UI/hud/terminal_toast.gd")
const BatteryPickup := preload("res://scripts/World/props/battery_pickup.gd")
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")
const DrawUI := preload("res://scripts/UI/hud/draw_ui.gd")
const SketchTool := preload("res://scripts/Player/sketch_tool.gd")
const TapeTool := preload("res://scripts/Player/tape_tool.gd")
const CableTool := preload("res://scripts/Player/cable_tool.gd")
const FlashTool := preload("res://scripts/Player/flash_tool.gd")
const FlashPickup := preload("res://scripts/World/props/flash_pickup.gd")
const ZoomTool := preload("res://scripts/Player/zoom_tool.gd")
const ZoomReadout := preload("res://scripts/UI/hud/zoom_readout.gd")
const TapeReadout := preload("res://scripts/UI/hud/tape_readout.gd")
const VitalsPanel := preload("res://scripts/UI/hud/vitals_panel.gd")
const PlayerScript := preload("res://scripts/Player/player.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")
const EventTrigger := preload("res://scripts/World/props/event_trigger.gd")

const SCALE := 1.15                       # --hud-scale in the web CSS
const CREAM := Color("d6cfb2")            # camera OSD off-white, a little dirty: never paper white
const TAPE := Color("c9bea0")
const HINT := Color("9c9268")
const HINT_STRONG := Color("ded6ad")
const REC_RED := Color("ff3b30")
const DIM := Color(0.9, 0.88, 0.8, 0.55)

var font: FontFile = load("res://fonts/vcr.ttf")
var pause_root: Control
var menu: Control
var inventory: Control
var scanner: Node
var tape: Node
var flash: Node                          # flash_tool.gd: the camera flash (G / right click)
var zoom: Node                           # zoom_tool.gd: the camcorder raised to the eye (hold X, wheel zooms)
var toast: Control
var hud_root: Control
var hud_fade: Tween
var t := 0.0
var playing_label: Label
var time_label: Label
var rec_dot: Control
var rec_label: Label      # "REC", or "LOW BATT" now and then once the torch battery is critical
var osd: CrtLayer         # the camcorder's burned-in text and viewfinder corners, dirtied (_build_hud)
var post_mat: ShaderMaterial
var threat_s := 0.0
var fear_s := 0.0
var vitals: Control       # vitals_panel.gd: POWER / STAMINA / SANITY / HEALTH / NOISE
var player: Node
var level: Node
var corners: Array[Control] = []
var shake_seed := randf() * 1000.0
var battery_hint_shown := false   # the "[R] to load it" toast, once per run
var door_prompt: Label

func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	player = get_parent().get_node("Player")
	level = get_parent().get_node("Level")

	# Post-process sits under the UI so text stays crisp
	var post_layer := CanvasLayer.new()
	post_layer.layer = 1
	var post := ColorRect.new()
	post.set_anchors_preset(Control.PRESET_FULL_RECT)
	post.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(Gfx.CAMERA_SHADER)       # the camera (render_engine.gd drives it)
	if ResourceLoader.exists("res://textures/lens_dirt.png"):
		mat.set_shader_parameter("lens_dirt_tex", load("res://textures/lens_dirt.png"))
	if ResourceLoader.exists("res://textures/lens_smudge.png"):
		mat.set_shader_parameter("lens_smudge_tex", load("res://textures/lens_smudge.png"))
	post.material = mat
	post_mat = mat
	Gfx.register_post(mat)
	post_layer.add_child(post)
	get_parent().add_child.call_deferred(post_layer)

	_build_hud()
	_build_pause()
	_build_inventory()
	_build_scanner()
	_build_tape()
	_build_flash()
	_build_zoom()
	_show_pending_route.call_deferred()

	Game.hud_visibility_changed.connect(_on_hud_visibility_changed)
	if hud_root:
		hud_root.visible = not Game.hide_hud

func _on_hud_visibility_changed(hud_visible: bool) -> void:
	if hud_root:
		hud_root.visible = hud_visible
		if hud_visible:
			var in_menu: bool = menu != null and menu.shown
			var in_inv: bool = inventory != null and inventory.shown
			if not in_menu and not in_inv:
				hud_root.modulate.a = 1.0

func set_hud_visible(show: bool) -> void:
	Game.hide_hud = not show

# ---- helpers ------------------------------------------------------------------
func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	fv.variation_embolden = 0.6
	return fv

func _label(text: String, size: float, color: Color, spacing := 1.5) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", int(size * SCALE))
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _round_dot(diameter: float, color: Color) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(diameter, diameter)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func():
		c.draw_circle(Vector2(diameter, diameter) * 0.5, diameter * 0.5, color)
	)
	return c

func _gradient_rect(h: float, from: Color, to: Color) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, from)
	g.set_color(1, to)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 256
	gt.height = 1
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.custom_minimum_size = Vector2(0, h)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

func _vbox(gap: float) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", int(gap * SCALE))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v

func _hbox(gap: float) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", int(gap * SCALE))
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h

const BRACKET_LEN := 42.0
const BRACKET_THICK := 3.0
const CHROMA_OFFSET := 1.6

func _corner(anchor: Control.LayoutPreset, x: float, y: float, top: bool, left: bool) -> Control:
	# Viewfinder bracket: thick L-shaped lines with a subtle red/cyan chromatic fringe
	var c := Control.new()
	c.set_anchors_and_offsets_preset(anchor)
	c.offset_left = x; c.offset_top = y
	c.offset_right = x + BRACKET_LEN; c.offset_bottom = y + BRACKET_LEN
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.set_meta("base_offset", Vector2(x, y))

	var len := BRACKET_LEN
	var thick := BRACKET_THICK
	var y_bar := 0.0 if top else len - thick
	var x_bar := 0.0 if left else len - thick

	var fringes := [
		[Color(1.0, 0.28, 0.24, 0.35), Vector2(-CHROMA_OFFSET, 0)],   # red, shifted left
		[Color(0.3, 0.9, 1.0, 0.35), Vector2(CHROMA_OFFSET, 0)],      # cyan, shifted right
		[Color(0.894, 0.882, 0.776, 0.85), Vector2.ZERO],             # core cream line, on top
	]
	for f in fringes:
		var col: Color = f[0]
		var off: Vector2 = f[1]
		var h := ColorRect.new(); h.color = col
		h.size = Vector2(len, thick); h.position = Vector2(0, y_bar) + off
		var v := ColorRect.new(); v.color = col
		v.size = Vector2(thick, len); v.position = Vector2(x_bar, 0) + off
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(h)
		c.add_child(v)

	corners.append(c)
	return c

# ---- HUD ------------------------------------------------------------------------
func _build_hud() -> void:
	var hud := Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	hud_root = hud

	# The camcorder's own text and corners are burned into the tape, not drawn over it: they go
	# through a CRT layer with a sideways red / blue split, a faint ghost trailing to the right,
	# grain, scanlines and a little flicker, like the co-op name tags seen through the camera
	osd = CrtLayer.new()
	osd.set_anchors_preset(Control.PRESET_FULL_RECT)
	osd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(osd)
	osd.mat.set_shader_parameter("split_px", 1.6)
	osd.mat.set_shader_parameter("ghost_px", 5.0)
	osd.mat.set_shader_parameter("ghost_amt", 0.22)
	osd.mat.set_shader_parameter("flicker_amt", 0.07)
	osd.mat.set_shader_parameter("scan_amt", 0.12)
	osd.mat.set_shader_parameter("grain_amt", 0.08)
	osd.mat.set_shader_parameter("bloom_tint", 0.0)      # its glow stays the text's own colour
	osd.glow_scale = 0.4
	osd.running = true
	var osd_root := osd.content

	# Corner brackets (16 px from top/bottom, 18 px from the sides)
	# osd_root.add_child(_corner(Control.PRESET_TOP_LEFT, 18, 16, true, true))
	# osd_root.add_child(_corner(Control.PRESET_TOP_RIGHT, -18 - BRACKET_LEN, 16, true, false))
	# osd_root.add_child(_corner(Control.PRESET_BOTTOM_LEFT, 18, -16 - BRACKET_LEN, false, true))
	# osd_root.add_child(_corner(Control.PRESET_BOTTOM_RIGHT, -18 - BRACKET_LEN, -16 - BRACKET_LEN, false, false))

	# Crosshair: a small solid round dot in the HUD cream
	var dot := Control.new()
	dot.size = Vector2(8, 8)
	dot.set_anchors_preset(Control.PRESET_CENTER)
	dot.position = Vector2(-4, -4)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.draw.connect(func():
		dot.draw_circle(dot.size * 0.5, 2.0, Color(0.92, 0.882, 0.686, 1.0))
	)
	hud.add_child(dot)

	# Door interaction prompt: subtle retro HUD prompt below the crosshair
	door_prompt = Label.new()
	door_prompt.text = "[E] OPEN"
	door_prompt.add_theme_font_override("font", _font(2.0))
	door_prompt.add_theme_font_size_override("font_size", 14)
	door_prompt.add_theme_color_override("font_color", CREAM)
	door_prompt.set_anchors_preset(Control.PRESET_CENTER)
	door_prompt.position = Vector2(-75, 18)
	door_prompt.custom_minimum_size = Vector2(150, 24)
	door_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	door_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	door_prompt.modulate.a = 0.0
	hud.add_child(door_prompt)

	# --- top-left: REC + objective ---
	var tl := _vbox(5)
	tl.position = Vector2(42, 32)
	osd_root.add_child(tl)
	var rec := _hbox(8)
	rec_dot = _round_dot(8 * SCALE, REC_RED)
	var dot_c := CenterContainer.new()
	dot_c.add_child(rec_dot)
	dot_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rec.add_child(dot_c)
	rec_label = _label("REC", 15, REC_RED, 3)
	rec.add_child(rec_label)
	rec.add_child(_label("CAM 04", 15, CREAM, 2))
	tl.add_child(rec)
	tl.add_child(_gradient_rect(1, Color(1, 0.231, 0.188, 0.8), Color(1, 0.231, 0.188, 0.15)))

	# --- top-right: level title, timecode, tape mode ---
	var tr := _vbox(4)
	tr.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tr.offset_left = -42 - 320; tr.offset_right = -42; tr.offset_top = 32; tr.offset_bottom = 32
	osd_root.add_child(tr)
	var title := _label(str(level.level_name).to_upper(), 13, TAPE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tr.add_child(title)
	time_label = _label("00:00:00", 13, TAPE)
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tr.add_child(time_label)
	var mode := _hbox(14)
	mode.alignment = BoxContainer.ALIGNMENT_END
	playing_label = _label("► PLAY", 13, CREAM)
	mode.add_child(playing_label)
	mode.add_child(_label("SP", 13, CREAM))
	tr.add_child(mode)
	tr.add_child(_gradient_rect(1, Color(0, 0, 0, 0), Color(0.788, 0.745, 0.627, 0.6)))

	# --- bottom-left: vitals, on the terminal's amber CRT (vitals_panel.gd) ---
	vitals = VitalsPanel.new()
	vitals.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	vitals.offset_left = 44; vitals.offset_right = 44 + VitalsPanel.PANEL.x       # inside the corner brackets
	vitals.offset_top = -34 - VitalsPanel.PANEL.y; vitals.offset_bottom = -34
	vitals.player = player
	vitals.entity = get_parent().get_node_or_null("Entity")
	vitals.fade_src = hud
	hud.add_child(vitals)

	# --- bottom-right: key hints ---
	var br := _vbox(6)
	br.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	br.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	br.grow_vertical = Control.GROW_DIRECTION_BEGIN
	osd_root.add_child(br)
	var row := _hbox(12)
	row.alignment = BoxContainer.ALIGNMENT_END
	var hints := ["TAB // T.S.R.A Terminal"]
	for i in hints.size():
		row.add_child(_label(hints[i], 13, HINT))
		if i < hints.size() - 1: row.add_child(_label("•", 13, HINT))
	br.add_child(row)
	br.add_child(_gradient_rect(1, Color(0, 0, 0, 0), Color(0.612, 0.573, 0.408, 0.5)))
	br.offset_left = -42 - 360
	br.offset_top = -32 - 44
	br.offset_right = -42
	br.offset_bottom = -32

# ---- pause menu (same look as the web menu) ----------------------------------------
func _build_pause() -> void:
	menu = load("res://scripts/UI/menu/menu.gd").new()
	pause_root = menu
	menu.modulate.a = 0.0
	pause_root.visible = false
	add_child(pause_root)
	menu.settings_changed.connect(apply_settings)
	apply_settings()

func _build_inventory() -> void:
	inventory = load("res://scripts/UI/inventory/inventory.gd").new()
	inventory.player = player
	add_child(inventory)
	# the torch in your hand (torch_model.gd) is always carried: first on the list
	inventory.add_item("torch", "Flashlight",
		"Your hand torch. F switches it on and off; about 75 s of light on a full charge, a quarter "
		+ "of the drain in a power cut. R loads a carried battery pack into it.", 1, "TRC", 1,
		"res://models/flashlight.glb")

## The field scanner is the only way to log an entity, so every run starts with one in the
## terminal. Reticle and toast live in hud_root: they fade with the OSD under the pause menu and the
## terminal (a scan only runs in play, and the dossier shows the entry anyway).
func _build_scanner() -> void:
	inventory.add_item("scanner", "T.S.R.A. Field Scanner",
		"Hold Q while an anomaly is near the middle of your view and in plain sight. A complete "
		+ "reading logs it to the Threshold Dossier [F2]. Range about 30 m.", 1, "SCN", 1,
		"res://scripts/Player/scanner_model.gd")
	scanner = Scanner.new()
	scanner.player = player
	scanner.inventory = inventory
	add_child(scanner)
	var readout := ScanReadout.new()
	readout.scanner = scanner
	hud_root.add_child(readout)
	toast = TerminalToast.new()
	toast.player = player
	hud_root.add_child(toast)
	Archive.entity_discovered.connect(_on_entity_logged)
	Clearance.yield_filed.connect(_on_yield_filed)
	Net.survivor_joined.connect(_on_survivor_joined)
	Net.survivor_left.connect(_on_survivor_left)
	Net.survivor_died.connect(_on_survivor_died)

## Every run starts with one roll of hazard tape. Its HUD (tape_readout.gd) is only up while T is
## held and for a moment after.
func _build_tape() -> void:
	inventory.add_item(TapePickup.ITEM_ID, TapePickup.ITEM_NAME, TapePickup.ITEM_DESC, 1,
		TapePickup.ITEM_CODE, TapePickup.STACK, TapePickup.MODEL_PATH)
	tape = TapeTool.new()
	tape.player = player
	tape.inventory = inventory
	add_child(tape)
	var readout := TapeReadout.new()
	readout.tape = tape
	readout.inventory = inventory
	hud_root.add_child(readout)
	var sketch := SketchTool.new()
	sketch.player = player
	add_child(sketch)
	var cable_tool := CableTool.new()
	cable_tool.player = player
	add_child(cable_tool)
	if Game.test_level != "" or Game.dev_keys:      # the mouse-driven draw tools panel (Y)
		inventory.add_item("cable_spool", "Equipment Cable Spool",
			"Heavy-duty industrial equipment cables for field machinery, relays, and portable equipment. " \
			+ "Hold U looking at floors or walls to unspool and place permanent 3D cables, or press Y to open the Draw Tools panel. " \
			+ "Cables roll, stack in 3D piles, and remain permanent on the level.", 1, "CBL", 1,
			"res://scripts/World/props/cable_roll.gd")
		var draw := DrawUI.new()
		draw.player = player
		draw.tape = tape
		draw.sketch = sketch
		draw.cable = cable_tool
		sketch.ui = draw
		cable_tool.ui = draw
		add_child(draw)

## Every run starts with START camera flashes, one charge each: a way to break a chase, not to win it
func _build_flash() -> void:
	inventory.add_item(FlashPickup.ITEM_ID, FlashPickup.ITEM_NAME, FlashPickup.ITEM_DESC, FlashPickup.START,
		FlashPickup.ITEM_CODE, FlashPickup.STACK, FlashPickup.MODEL_PATH)
	flash = FlashTool.new()
	flash.player = player
	flash.inventory = inventory
	add_child(flash)
	vitals.flash = flash

## The camcorder's zoom lens (zoom_tool.gd). Its lens grade reads the finished picture, so it gets a canvas
## layer of its own between the post pass and the HUD: the OSD's text and brackets stay sharp under it. The
## viewfinder marks (zoom_readout.gd) live in hud_root and fade with the OSD.
func _build_zoom() -> void:
	zoom = ZoomTool.new()
	zoom.player = player
	zoom.scanner = scanner
	zoom.tape = tape
	add_child(zoom)
	var grade_layer := CanvasLayer.new()
	grade_layer.layer = 2
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/cam_zoom.gdshader")
	rect.material = mat
	grade_layer.add_child(rect)
	get_parent().add_child.call_deferred(grade_layer)
	var readout := ZoomReadout.new()
	readout.zoom = zoom
	readout.player = player
	readout.grade_mat = mat
	readout.grade_rect = rect
	hud_root.add_child(readout)

## A first contact: the entry with the Research Yield it filed (scanner.gd files it just before)
func _on_entity_logged(id: String) -> void:
	if id == "":                 # Archive.forget_all(): nothing new to announce
		return
	var info := Archive.entity_info(id)
	var lines: Array = [{"kind": "head", "code": str(info.get("code", "TSRA-EN-??")),
		"name": str(info.get("common_name", id)).to_upper(),
		"tag": str(info.get("threat_class", "Undetermined")).to_upper(), "tag_color": Term.RED}]
	var report: Dictionary = Clearance.last_report
	if report.get("id", "") == id and report.get("kind", "") == "first_contact":
		lines.append_array(_yield_lines(report))
	lines.append({"kind": "keys", "keys": ["TAB", "F3"], "text": "READ ENTRY"})
	toast.push("NEW ENTRY LOGGED", lines)
	_promotion(report)

## New sites get a toast of their own; supplemental readings only show on the reticle.
## A first contact waits for _on_entity_logged; any of them can raise the clearance tier.
func _on_yield_filed(report: Dictionary) -> void:
	var site := str(Archive.current_dossier().get("designation", "UNMAPPED SITE")).to_upper()
	match report.get("kind", ""):
		"first_contact", "route":
			return                   # a route is shown by the next level's HUD (_show_pending_route)
		"survey":
			# every strip's own yield shows on the tape readout; the milestones get a toast
			if (report.lines as Array).size() > 1:
				var lines: Array = [{"kind": "head", "code": site,
					"name": "%d%% OF THIS LEVEL MAPPED" % roundi(float(report.get("coverage", 0.0)) * 100.0), "size": 22}]
				lines.append_array(_yield_lines(report))
				toast.push("SURVEY MILESTONE", lines)
		"new_site":
			var info := Archive.entity_info(str(report.id))
			var lines: Array = [{"kind": "head", "code": "%s  //  %s" % [str(info.get("code", "TSRA-EN-??")), site],
				"name": str(info.get("common_name", report.id)).to_upper()}]
			lines.append_array(_yield_lines(report))
			toast.push("NEW SITE CONFIRMED", lines)
	_promotion(report)

## The level before was left with a taped trail to its exit (Clearance.file_route, filed as the
## level changed): announce it here, once the new level is up
func _show_pending_route() -> void:
	var report: Dictionary = Clearance.pending_route
	if report.is_empty():
		return
	Clearance.pending_route = {}
	var lines: Array = [{"kind": "head", "code": str(report.get("designation", "UNMAPPED SITE")).to_upper(),
		"name": "TRAIL TO THE EXIT FILED", "size": 20}]
	lines.append_array(_yield_lines(report))
	toast.push("ROUTE DOCUMENTED", lines)
	_promotion(report)

## One row per markup ("FIRST CONTACT ... +100 RY"), what the filing came to, then clearance toward
## the next tier as a gauge that fills with what this filing added
func _yield_lines(report: Dictionary) -> Array:
	var unit := Clearance.unit
	var out: Array = [{"kind": "rule"}]
	for ln in report.get("lines", []):
		out.append({"kind": "pair", "left": str(ln[0]), "right": "+%d %s" % [int(ln[1]), unit]})
	var filed := int(report.get("total", 0))
	out.append({"kind": "pair", "left": "FILED", "right": "+%d %s" % [filed, unit], "color": Term.TEXT, "strong": true})
	var i := Clearance.tier_index()
	var code := str(Clearance.tier().get("code", ""))
	if Clearance.is_max_tier():
		out.append({"kind": "bar", "left": code + "  //  MAX CLEARANCE", "right": "%d %s" % [Clearance.total, unit],
			"from": 1.0, "to": 1.0})
		return out
	var lo := int(Clearance.tier(i).get("yield", 0))
	var span := float(maxi(Clearance.next_threshold() - lo, 1))
	var before := Clearance.total - filed
	# a filing that crossed into this tier starts its gauge empty
	var from := 0.0 if Clearance.tier_index(before) < i else float(before - lo) / span
	out.append({"kind": "bar", "left": "CLEARANCE " + code, "from": from, "to": Clearance.tier_progress(),
		"right": "%d / %d %s" % [Clearance.total, Clearance.next_threshold(), unit]})
	return out

func _promotion(report: Dictionary) -> void:
	var to := int(report.get("tier_to", 0))
	if to <= int(report.get("tier_from", 0)):
		return
	var t := Clearance.tier(to)
	var lines: Array = [
		{"kind": "head", "code": str(t.get("code", "")), "name": str(t.get("title", "")).to_upper(), "size": 22},
		{"kind": "text", "text": str(t.get("brief", "")), "wrap": true},
	]
	# every tier passed on the way up, in case one filing jumps more than one
	for i in range(int(report.get("tier_from", 0)) + 1, to + 1):
		var u: Dictionary = Clearance.tier(i).get("unlock", {})
		if not u.is_empty():
			lines.append({"kind": "rule"})
			lines.append({"kind": "pair", "left": "UNLOCKED", "right": str(u.get("name", "")).to_upper(), "color": Term.GREEN})
			lines.append({"kind": "text", "text": str(u.get("text", "")), "size": 15, "color": Term.TEXT_DIM, "wrap": true})
	lines.append({"kind": "rule"})
	lines.append({"kind": "pair", "left": "SCANNER CALIBRATION", "right": "READING TIME -%d%%" % roundi(5.0 * to)})
	toast.push("CLEARANCE ELEVATED", lines)

# ---- the expedition roster ------------------------------------------------------------------
## Someone came into the co-op game: their callsign big, as a field researcher, and how many are out here now
func _on_survivor_joined(id: int, callsign: String, already: bool) -> void:
	toast.push("EXPEDITION ROSTER", [
		{"kind": "head", "code": "FIELD RESEARCHER  #%02d" % (id % 100), "name": callsign, "size": 22,
			"tag": "ON SITE" if already else "LINK ESTABLISHED", "tag_color": Term.GREEN},
		{"kind": "text", "text": "IS ON THE EXPEDITION" if already else "HAS JOINED THE EXPEDITION", "size": 15, "color": Term.TEXT_DIM},
		{"kind": "rule"},
		{"kind": "pair", "left": "SURVIVORS IN THE FIELD", "right": "%d" % (multiplayer.get_peers().size() + 1)},
	])
	var alert_text: String
	if already:
		alert_text = "[ T.S.R.A. ON SITE ] // %s CONFIRMED IN FIELD" % callsign.to_upper()
	else:
		alert_text = "[ T.S.R.A. LINK ESTABLISHED ] // %s JOINED THE EXPEDITION" % callsign.to_upper()
	EventTrigger.show_alert_bar(get_tree(), alert_text, 5.0)

func _on_survivor_left(id: int, callsign: String) -> void:
	var left := multiplayer.get_peers().size() + 1
	if multiplayer.get_peers().has(id):
		left -= 1                                    # (still listed while it is being dropped)
	toast.push("EXPEDITION ROSTER", [
		{"kind": "head", "code": "FIELD RESEARCHER  #%02d" % (id % 100), "name": callsign, "size": 22,
			"tag": "SIGNAL LOST", "tag_color": Term.RED},
		{"kind": "text", "text": "HAS LEFT THE EXPEDITION", "size": 15, "color": Term.TEXT_DIM},
		{"kind": "rule"},
		{"kind": "pair", "left": "SURVIVORS IN THE FIELD", "right": "%d" % left, "color": Term.RED},
	])
	var alert_text := "[ T.S.R.A. SIGNAL LOST ] // %s HAS LEFT THE EXPEDITION" % callsign.to_upper()
	EventTrigger.show_alert_bar(get_tree(), alert_text, 5.0)

## A teammate flatlined: their name, the flatline in red, and what did it
func _on_survivor_died(id: int, callsign: String, cause: String) -> void:
	var alive := 0 if player.dead else 1
	for r in Net.remotes.values():
		if is_instance_valid(r) and not r.dead:
			alive += 1
	toast.push("VITALS ALERT", [
		{"kind": "head", "code": "FIELD RESEARCHER  #%02d" % (id % 100), "name": callsign, "size": 22,
			"tag": "VITALS FLATLINED", "tag_color": Term.RED},
		{"kind": "rule"},
		{"kind": "pair", "left": "CAUSE OF DEATH", "right": cause, "color": Term.RED, "strong": true},
		{"kind": "pair", "left": "SURVIVORS STILL BREATHING", "right": "%d" % alive},
	])
	var alert_text := "[ T.S.R.A. VITALS FLATLINE ] // %s LOST (%s)" % [callsign.to_upper(), cause.to_upper()]
	EventTrigger.show_alert_bar(get_tree(), alert_text, 5.0)

# ---- carried items ------------------------------------------------------------------------
## Floor pickups (World/props) hand themselves in here; false when there's no room, so the
## pickup stays where it is
func pick_up_item(id: String, title: String, desc: String, code: String, stack: int, model: String) -> bool:
	if not inventory.add_item(id, title, desc, 1, code, stack, model):
		return false
	if id == BatteryPickup.ITEM_ID and not battery_hint_shown:
		battery_hint_shown = true
		toast.push("ITEM RECOVERED", [
			{"kind": "head", "code": code, "name": title.to_upper(), "tag": "STACKS TO %d" % stack, "tag_color": Term.AMBER},
			{"kind": "rule"},
			{"kind": "keys", "keys": ["R"], "text": "LOAD ONE INTO THE FLASHLIGHT"},
			{"kind": "keys", "keys": ["TAB"], "text": "VIEW INVENTORY"},
		])
	return true

## R: load a carried battery pack into the flashlight: the player's hands change the cells
## (player.gd swap_battery), and the charge is in when they're done. Nothing to load, a full battery or
## a swap already under way: the dead click, so the key still answers.
func use_battery() -> void:
	if player.battery >= 99.5 or player.swapping() or not inventory.has_item(BatteryPickup.ITEM_ID):
		player.dead_click.emit()
		return
	inventory.remove_item(BatteryPickup.ITEM_ID)
	player.swap_battery(BatteryPickup.CHARGE)

func _unhandled_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	var is_batt: bool = e.is_action_pressed("battery")
	if is_batt and Game.playing and not Game.dead and player.lens_up <= 0.0 \
			and not player.dead and not player.frozen and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		use_battery()
		get_viewport().set_input_as_handled()

## The REC dot blinks every 1.2 s; like a real camcorder it hurries as the battery runs down (low:
## 0.8 s), and once it is critical it blinks every 0.5 s and flips REC to LOW BATT for a moment in
## every four seconds
func _update_rec() -> void:
	var bat: float = float(player.get("battery")) if player else 100.0
	var period := 1.2
	var text := "REC"
	if bat < PlayerScript.BATTERY_CRIT:
		period = 0.5
		if fmod(t, 4.0) > 2.6:
			text = "LOW BATT"
	elif bat < PlayerScript.BATTERY_LOW:
		period = 0.8
	rec_dot.modulate.a = 1.0 if fmod(t, period) < period * 0.5 else 0.0
	if rec_label.text != text:
		rec_label.text = text

## TAB terminal (inventory.gd) fills the screen, so the camcorder OSD steps out while it is up.
## Opening the pause menu closes the terminal first, then set_paused() takes the fade over.
func set_inventory(on: bool) -> void:
	inventory.set_shown(on)
	if not hud_root or menu.shown:
		return
	if hud_fade: hud_fade.kill()
	hud_fade = create_tween()
	hud_fade.tween_property(hud_root, "modulate:a", 0.0 if on else 1.0, 0.2)

## Push the menu's saved settings into the audio buses / player (js/game/settings.js)
func apply_settings() -> void:
	var v: Dictionary = menu.volumes
	AudioServer.set_bus_volume_linear(AudioServer.get_bus_index("Master"), v.master)
	var steps := AudioServer.get_bus_index("Steps")
	if steps >= 0: AudioServer.set_bus_volume_linear(steps, v.footsteps)
	var audio := get_parent().get_node_or_null("Audio")
	if audio:
		audio.vol.hum = v.hum
		audio.vol.breathing = v.breathing
		audio.vol.ambient = v.get("ambient", 1.0)
	if player:
		player.sens = menu.mouse_sens()
		player.base_fov = float(menu.fov)
		player.head_bob = 1.0 if menu.head_bob else 0.0
		player.cam_shake = 1.0 if menu.cam_shake else 0.0

## Start screen (first launch) and pause share one menu; only the title block differs
func set_paused(on: bool, start := false) -> void:
	menu.show_menu(on, start)
	if hud_root:
		if hud_fade: hud_fade.kill()
		hud_fade = create_tween()
		hud_fade.tween_property(hud_root, "modulate:a", 0.3 if on else 1.0, 0.45)
	if on:
		var sub := "T.S.R.A // THRESHOLD SPATIAL RESEARCH AGENCY"
		if start:
			menu.set_text("THE BACKROOMS", sub, "CLICK TO ENTER THE LOBBY")
		else:
			menu.set_text("THE BACKROOMS", sub, "CLICK OR PRESS ESC TO RESUME")
	else:
		menu.release_focus_all()
	playing_label.text = "|| PAUSE" if on else "► PLAY"

# ---- per-frame values -----------------------------------------------------------------
func _process(dt: float) -> void:
	t += dt
	# fear channels for the post shader (game.fear / terror / glitch in the web pipeline)
	threat_s += (Game.terror - threat_s) * minf(1.0, dt * 3.0)
	fear_s += (Game.fear - fear_s) * minf(1.0, dt * 6.0)
	if post_mat:
		post_mat.set_shader_parameter("fear", fear_s)
		post_mat.set_shader_parameter("threat", threat_s)
		post_mat.set_shader_parameter("glitch", Game.glitch)
		post_mat.set_shader_parameter("pulse", Game.pulse)
		post_mat.set_shader_parameter("classic", Game.fx_classic)
		post_mat.set_shader_parameter("fx_blur", Game.fx_blur)
		post_mat.set_shader_parameter("fx_contrast", Game.fx_contrast)
		post_mat.set_shader_parameter("fx_sat", Game.fx_sat)
		post_mat.set_shader_parameter("fx_hue", Game.fx_hue)
		post_mat.set_shader_parameter("fx_zoom", Game.fx_zoom)
		post_mat.set_shader_parameter("fx_skew", Game.fx_skew)
		post_mat.set_shader_parameter("fx_fade", Game.fx_fade)
		post_mat.set_shader_parameter("fx_flash", Game.fx_flash)
		post_mat.set_shader_parameter("fx_shock", Game.fx_shock)
		post_mat.set_shader_parameter("fx_blood", Game.fx_blood)
		post_mat.set_shader_parameter("fx_static", Game.fx_static)
		post_mat.set_shader_parameter("corrupt", Game.fx_corrupt)
		post_mat.set_shader_parameter("fx_warp", Game.fx_warp)
		post_mat.set_shader_parameter("fx_blink", Game.fx_blink)
		post_mat.set_shader_parameter("exhaust", 0.8 if (player and player.get("exhausted")) else 0.0)
		post_mat.set_shader_parameter("adrenaline", player.adrenaline if player else 0.0)
		post_mat.set_shader_parameter("insanity", player.insanity if player else 0.0)
	_update_rec()
	osd.running = hud_root.visible and hud_root.modulate.a > 0.01     # nothing to render while the OSD is faded out or hidden
	# Handheld-camera jitter on the viewfinder brackets
	for i in corners.size():
		var c := corners[i]
		var n := shake_seed + i * 41.7
		var jx := sin(t * 13.0 + n) * 0.35 + sin(t * 27.0 + n * 1.7) * 0.2
		var jy := cos(t * 11.0 + n) * 0.35 + cos(t * 23.0 + n * 1.3) * 0.2
		var base: Vector2 = c.get_meta("base_offset")
		var ox := base.x + jx
		var oy := base.y + jy
		c.offset_left = ox; c.offset_top = oy
		c.offset_right = ox + BRACKET_LEN; c.offset_bottom = oy + BRACKET_LEN
	var s := int(t)
	time_label.text = "%02d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]

	if door_prompt != null:
		var show_door := false
		if player != null and "focused_door" in player and player.focused_door != null:
			var d = player.focused_door
			if is_instance_valid(d) and d.has_method("get_interact_prompt"):
				door_prompt.text = d.get_interact_prompt()
				show_door = true
		door_prompt.modulate.a = move_toward(door_prompt.modulate.a, 1.0 if show_door else 0.0, dt * 8.0)
