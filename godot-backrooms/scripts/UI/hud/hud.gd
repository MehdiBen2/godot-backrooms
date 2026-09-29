extends CanvasLayer
## Camcorder HUD + pause menu, replicating the web game's #hud (backrooms.html / style.css):
## REC block + objective (top-left), level / timecode / tape mode (top-right), four meters
## (bottom-left), key hints (bottom-right), viewfinder corner brackets and the crosshair dot.
## Designed for a 1920x1080 canvas so pixel sizes match the browser.
## Also owns the TAB terminal (inventory.gd), the T.S.R.A. field scanner (scanner.gd, hold Q) with
## its reticle (scan_readout.gd), and the "new entry logged" / clearance toasts (terminal_toast.gd).
## And the reflective hazard tape (tape_tool.gd, hold T) with its tape mode HUD (tape_readout.gd).

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const Scanner := preload("res://scripts/Player/scanner.gd")
const ScanReadout := preload("res://scripts/UI/hud/scan_readout.gd")
const TerminalToast := preload("res://scripts/UI/hud/terminal_toast.gd")
const BatteryPickup := preload("res://scripts/World/props/battery_pickup.gd")
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")
const TapeTool := preload("res://scripts/Player/tape_tool.gd")
const TapeReadout := preload("res://scripts/UI/hud/tape_readout.gd")

const SCALE := 1.15                       # --hud-scale in the web CSS
const CREAM := Color("e4e1c6")            # camera OSD off-white
const TAPE := Color("c9bea0")
const HINT := Color("9c9268")
const HINT_STRONG := Color("ded6ad")
const METER_LABEL := Color("b5a975")
const METER_VAL := Color("ded6ad")
const REC_RED := Color("ff3b30")
const DIM := Color(0.9, 0.88, 0.8, 0.55)

var font: FontFile = load("res://fonts/vcr.ttf")
var pause_root: Control
var menu: Control
var inventory: Control
var scanner: Node
var tape: Node
var toast: Control
var hud_root: Control
var hud_fade: Tween
var shown_vals := {}      # meter name -> displayed value (eased toward the real one)
var t := 0.0
var playing_label: Label
var time_label: Label
var rec_dot: Control
var post_mat: ShaderMaterial
var threat_s := 0.0
var fear_s := 0.0
var meters := {}          # name -> {fill, text}
var player: Node
var level: Node
var corners: Array[Control] = []
var shake_seed := randf() * 1000.0
var battery_hint_shown := false   # the "[R] to load it" toast, once per run

func _ready() -> void:
	layer = 5
	player = get_parent().get_node("Player")
	level = get_parent().get_node("Level")

	# Post-process sits under the UI so text stays crisp
	var post_layer := CanvasLayer.new()
	post_layer.layer = 1
	var post := ColorRect.new()
	post.set_anchors_preset(Control.PRESET_FULL_RECT)
	post.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/post.gdshader")
	if ResourceLoader.exists("res://textures/lens_dirt.png"):
		mat.set_shader_parameter("lens_dirt_tex", load("res://textures/lens_dirt.png"))
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

	# Corner brackets (16 px from top/bottom, 18 px from the sides)
	hud.add_child(_corner(Control.PRESET_TOP_LEFT, 18, 16, true, true))
	hud.add_child(_corner(Control.PRESET_TOP_RIGHT, -18 - BRACKET_LEN, 16, true, false))
	hud.add_child(_corner(Control.PRESET_BOTTOM_LEFT, 18, -16 - BRACKET_LEN, false, true))
	hud.add_child(_corner(Control.PRESET_BOTTOM_RIGHT, -18 - BRACKET_LEN, -16 - BRACKET_LEN, false, false))

	# Crosshair: a 3 px dot
	var dot := ColorRect.new()
	dot.color = Color(0.92, 0.882, 0.686, 0.6)
	dot.size = Vector2(3, 3)
	dot.set_anchors_preset(Control.PRESET_CENTER)
	dot.position = Vector2(-1.5, -1.5)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(dot)

	# --- top-left: REC + objective ---
	var tl := _vbox(5)
	tl.position = Vector2(42, 32)
	hud.add_child(tl)
	var rec := _hbox(8)
	rec_dot = _round_dot(8 * SCALE, REC_RED)
	var dot_c := CenterContainer.new()
	dot_c.add_child(rec_dot)
	dot_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rec.add_child(dot_c)
	rec.add_child(_label("REC", 15, REC_RED, 3))
	rec.add_child(_label("CAM 04", 15, CREAM, 2))
	tl.add_child(rec)
	tl.add_child(_gradient_rect(1, Color(1, 0.231, 0.188, 0.8), Color(1, 0.231, 0.188, 0.15)))

	# --- top-right: level title, timecode, tape mode ---
	var tr := _vbox(4)
	tr.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tr.offset_left = -42 - 320; tr.offset_right = -42; tr.offset_top = 32; tr.offset_bottom = 32
	hud.add_child(tr)
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

	# --- bottom-left: meters ---
	var bl := _vbox(16)
	hud.add_child(bl)
	bl.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bl.offset_left = 42; bl.offset_right = 42 + 250 * SCALE; bl.offset_bottom = -32; bl.offset_top = -32
	bl.grow_vertical = Control.GROW_DIRECTION_BEGIN
	for m in [["STAMINA", Color("e0d494")], ["HEALTH", Color("c8503c")], ["SANITY", Color("a89d62")], ["BATTERY", Color("39e58c")]]:
		bl.add_child(_meter(m[0], m[1]))

	# --- bottom-right: key hints ---
	var br := _vbox(6)
	br.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	br.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	br.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hud.add_child(br)
	var row := _hbox(12)
	row.alignment = BoxContainer.ALIGNMENT_END
	var hints := ["Q // SCAN", "T // TAPE", "R // BATTERY", "TAB // ITEMS"]
	for i in hints.size():
		row.add_child(_label(hints[i], 13, HINT))
		if i < hints.size() - 1: row.add_child(_label("•", 13, HINT))
	br.add_child(row)
	br.add_child(_gradient_rect(1, Color(0, 0, 0, 0), Color(0.612, 0.573, 0.408, 0.5)))
	br.offset_left = -42 - 800
	br.offset_top = -32 - 44
	br.offset_right = -42
	br.offset_bottom = -32

func _meter(name: String, color: Color) -> Control:
	var block := _vbox(5)
	var meta := HBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := _label(name, 13, METER_LABEL, 2.5)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := _label("100%", 13, METER_VAL)
	meta.add_child(n)
	meta.add_child(v)
	block.add_child(meta)
	var track := ColorRect.new()
	track.color = Color(1, 1, 1, 0.12)
	track.custom_minimum_size = Vector2(0, 2)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := ColorRect.new()
	fill.color = color
	fill.position = Vector2.ZERO
	fill.size = Vector2(0, 2)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_child(fill)
	block.add_child(track)
	meters[name] = {"fill": fill, "text": v, "track": track, "base": color, "label": n}
	return block

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
	hud_root.add_child(toast)
	Archive.entity_discovered.connect(_on_entity_logged)
	Clearance.yield_filed.connect(_on_yield_filed)

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

## A first contact: the entry with the Research Yield it filed (scanner.gd files it just before)
func _on_entity_logged(id: String) -> void:
	if id == "":                 # Archive.forget_all(): nothing new to announce
		return
	var info := Archive.entity_info(id)
	var lines: Array = [
		["%s (%s)" % [str(info.get("code", "TSRA-EN-??")), str(info.get("common_name", id)).to_upper()], Term.GREEN, 20],
		["THREAT: " + str(info.get("threat_class", "Undetermined")), Term.RED, 18],
	]
	var report: Dictionary = Clearance.last_report
	if report.get("id", "") == id and report.get("kind", "") == "first_contact":
		lines.append_array(_yield_lines(report))
	lines.append(["[TAB] [F3] READ THE ENTRY", Term.MUTED, 16])
	toast.push("[NEW ENTRY LOGGED]", lines)
	_promotion(report)

## New sites get a toast of their own; supplemental readings only show on the reticle.
## A first contact waits for _on_entity_logged; any of them can raise the clearance tier.
func _on_yield_filed(report: Dictionary) -> void:
	match report.get("kind", ""):
		"first_contact":
			return
		"survey":
			# every strip's own yield shows on the tape readout; the milestones get a toast
			if (report.lines as Array).size() > 1:
				var lines: Array = [["%s // %d%% OF THIS LEVEL MAPPED" % [Archive.current_dossier().get("designation", "UNMAPPED SITE"),
					roundi(float(report.get("coverage", 0.0)) * 100.0)], Term.GREEN, 18]]
				lines.append_array(_yield_lines(report))
				toast.push("[SURVEY MILESTONE]", lines)
		"new_site":
			var info := Archive.entity_info(str(report.id))
			var lines: Array = [["%s // %s" % [str(info.get("code", "TSRA-EN-??")), Archive.current_dossier().get("designation", "UNMAPPED SITE")], Term.GREEN, 18]]
			lines.append_array(_yield_lines(report))
			toast.push("[NEW SITE CONFIRMED]", lines)
	_promotion(report)

## "+100 RY  FIRST CONTACT", one row per markup, then the total against the next tier
func _yield_lines(report: Dictionary) -> Array:
	var out: Array = []
	for ln in report.get("lines", []):
		out.append(["+%d %s  %s" % [int(ln[1]), Clearance.unit, str(ln[0])], Term.AMBER, 17])
	var tail := "MAX CLEARANCE" if Clearance.is_max_tier() else "%d / %d" % [Clearance.total, Clearance.next_threshold()]
	out.append(["FILED +%d %s  //  %s" % [int(report.get("total", 0)), Clearance.unit, tail], Term.TEXT, 18])
	return out

func _promotion(report: Dictionary) -> void:
	var to := int(report.get("tier_to", 0))
	if to <= int(report.get("tier_from", 0)):
		return
	var t := Clearance.tier(to)
	var lines: Array = [
		[Clearance.tier_label(to), Term.GREEN, 21],
		[str(t.get("brief", "")), Term.TEXT, 16, true],
	]
	# every tier passed on the way up, in case one filing jumps more than one
	for i in range(int(report.get("tier_from", 0)) + 1, to + 1):
		var u: Dictionary = Clearance.tier(i).get("unlock", {})
		if not u.is_empty():
			lines.append(["UNLOCKED: " + str(u.get("name", "")), Term.AMBER, 18])
			lines.append([str(u.get("text", "")), Term.TEXT, 16, true])
	lines.append(["SCANNER CALIBRATION: READING TIME -%d%%" % roundi(5.0 * to), Term.MUTED, 16])
	toast.push("[CLEARANCE ELEVATED]", lines)

# ---- carried items ------------------------------------------------------------------------
## Floor pickups (World/props) hand themselves in here; false when there's no room, so the
## pickup stays where it is
func pick_up_item(id: String, title: String, desc: String, code: String, stack: int, model: String) -> bool:
	if not inventory.add_item(id, title, desc, 1, code, stack, model):
		return false
	if id == BatteryPickup.ITEM_ID and not battery_hint_shown:
		battery_hint_shown = true
		toast.push("[ITEM RECOVERED]", [
			[title.to_upper(), Term.AMBER, 20],
			["STACKS UP TO %d" % stack, Term.TEXT, 17],
			["[R] LOAD ONE INTO THE FLASHLIGHT", Term.MUTED, 16],
			["[TAB] VIEW INVENTORY", Term.MUTED, 16],
		])
	return true

## R: load a carried battery pack into the flashlight. Nothing to load or a full battery: the
## dead click, so the key still answers.
func use_battery() -> void:
	if player.battery >= 99.5 or not inventory.has_item(BatteryPickup.ITEM_ID):
		player.dead_click.emit()
		return
	inventory.remove_item(BatteryPickup.ITEM_ID)
	player.battery = minf(100.0, player.battery + BatteryPickup.CHARGE)
	var audio: Node = get_parent().get_node_or_null("Audio")
	if audio:
		audio.play_world("flash_click_on.wav")

func _unhandled_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k and k.pressed and not k.echo and k.physical_keycode == KEY_R and Game.playing and not Game.dead \
			and not player.dead and not player.frozen and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		use_battery()
		get_viewport().set_input_as_handled()

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

## Start screen (first launch) and pause share one menu; only the title block differs
func set_paused(on: bool, start := false) -> void:
	menu.show_menu(on, start)
	if hud_root:
		if hud_fade: hud_fade.kill()
		hud_fade = create_tween()
		hud_fade.tween_property(hud_root, "modulate:a", 0.3 if on else 1.0, 0.45)
	if on:
		if start:
			menu.set_text("THE BACKROOMS", "THRESHOLD SECTOR • NON-EUCLIDEAN ZONE", "Unknown area, unknown location.", "CLICK TO ENTER THE LOBBY")
		else:
			menu.set_text("THE BACKROOMS", "THRESHOLD SECTOR • NON-EUCLIDEAN ZONE", "Unknown area, unknown location.", "CLICK OR PRESS ESC TO RESUME")
	else:
		menu.release_focus_all()
	playing_label.text = "|| PAUSE" if on else "► PLAY"

# ---- per-frame values -----------------------------------------------------------------
func _set_meter(name: String, value: float, cls := "") -> void:
	var m: Dictionary = meters[name]
	# Ease the bar toward the real value so drains / recoveries glide instead of stepping
	value = lerpf(shown_vals.get(name, value), value, minf(1.0, get_process_delta_time() * 8.0))
	shown_vals[name] = value
	var fill: ColorRect = m.fill
	var track: ColorRect = m.track
	fill.size = Vector2(track.size.x * clampf(value / 100.0, 0.0, 1.0), track.size.y)
	var txt_s := "%d%%" % int(round(value))
	if (m.text as Label).text != txt_s:          # only on change: a label re-shapes its text when set
		(m.text as Label).text = txt_s
	var col: Color = m.base
	var txt := METER_VAL
	var pulse := 0.65 + 0.35 * sin(t * 15.0)
	match cls:
		"low": col = Color("e59d3a")
		"critical":
			col = Color("ff3b30"); col.a = pulse; txt = Color("ff5545")
		"exhausted":
			col = Color("ff3b30"); col.a = pulse
	fill.color = col
	if m.get("txt_col") != txt:                   # a theme override every frame is a theme update every frame
		m["txt_col"] = txt
		(m.text as Label).add_theme_color_override("font_color", txt)

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
		post_mat.set_shader_parameter("fx_warp", Game.fx_warp)
		post_mat.set_shader_parameter("fx_blink", Game.fx_blink)
		post_mat.set_shader_parameter("exhaust", 0.8 if (player and player.get("exhausted")) else 0.0)
		post_mat.set_shader_parameter("adrenaline", player.adrenaline if player else 0.0)
		post_mat.set_shader_parameter("insanity", player.insanity if player else 0.0)
	rec_dot.modulate.a = 1.0 if fmod(t, 1.2) < 0.6 else 0.0
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
	if not player: return
	_set_meter("STAMINA", player.stamina, "exhausted" if player.exhausted else "")
	_set_meter("HEALTH", player.health, "critical" if player.health < 25.0 else "")
	var san_cls := ""
	if player.sanity < 25.0: san_cls = "critical"
	elif player.sanity < 50.0: san_cls = "low"
	_set_meter("SANITY", player.sanity, san_cls)
	var bat_cls := ""
	if player.battery < 10.0: bat_cls = "critical"
	elif player.battery < 25.0: bat_cls = "low"
	_set_meter("BATTERY", player.battery, bat_cls)
