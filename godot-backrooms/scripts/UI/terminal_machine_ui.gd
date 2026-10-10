extends Control
## T.S.R.A. Field Requisition Terminal: an authentic amber CRT logistics interface laid over
## the camera feed, rendered inside a SubViewport with VHS distortion, phosphor bloom, CRT warmup
## animation, scanlines, and 3D item icon previews.
## Powered by T.S.R.A. Clearance and field requisition credits.

signal closed

const Kit = preload("res://scripts/UI/inventory/terminal_kit.gd")
const CrtBloom = preload("res://scripts/UI/crt/crt_bloom.gd")
const CrtFlicker = preload("res://scripts/UI/crt/crt_flicker.gd")
const ItemIcon = preload("res://scripts/UI/inventory/item_icon.gd")

const AMBER = Kit.AMBER
const AMBER_DIM = Kit.AMBER_DIM
const TEXT = Kit.TEXT
const TEXT_DIM = Kit.TEXT_DIM
const MUTED = Kit.MUTED
const GREEN = Kit.GREEN
const ORANGE = Kit.ORANGE
const RED = Kit.RED
const FILL = Kit.FILL

const FRAME_INSET := 26.0
const LENS_CURVE := 0.04
const WINDOW_SCALE := 0.88
const BLOOM := 1.15
const BLOOM_WIDE := 0.42
const BLOOM_RADIUS := 10.0
const LINE := Kit.LINE
const FRAME_LINE := 5

const SFX_FILES := {
	"on": "res://audio/terminal/terminal_on.wav",
	"off": "res://audio/terminal/terminal_off.wav",
	"select": "res://audio/terminal/terminal_select.wav",
	"tab": "res://audio/terminal/terminal_tab.wav",
	"scan": "res://audio/terminal/terminal_scan.wav",
	"logged": "res://audio/terminal/terminal_logged.wav"
}

const CATALOG := [
	{
		"id": "battery",
		"name": "AA Battery Pack",
		"code": "BAT-02",
		"price": 15,
		"stack": 6,
		"icon": "res://models/aa_batteries.glb",
		"spec": "CLASS-A POWER CELL // 2x 1.5V ALKALINE",
		"desc": "A shrink-wrapped pair of high-discharge industrial AA cells. Fully compatible with standard T.S.R.A. field flashlights.\n\nRestores +45% battery life per pack. Essential for prolonged low-light reconnaissance.",
		"protocol": "INSERT VIA BASE CAP COMPARTMENT [KEY: R]. DO NOT PUNCTURE HOUSING."
	},
	{
		"id": "flash",
		"name": "Camera Flash Speedlight",
		"code": "FLSH-01",
		"price": 25,
		"stack": 3,
		"icon": "res://models/camera_flash.glb",
		"spec": "CLASS-B DEFENSIVE EMITTER // XENON SPEEDLIGHT",
		"desc": "High-voltage xenon flash speedlight designed for perimeter defense and entity deterrence.\n\nFires an intense blinding discharge capable of temporarily disorienting approaching entities. Single discharge per unit.",
		"protocol": "DISCHARGE TOWARDS TARGET RETINAE [KEY: G]. AUDIO SIGNATURE MAY ATTRACT DISTANT ANOMALIES."
	},
	{
		"id": "tape",
		"name": "Reflective Hazard Tape",
		"code": "TAPE-01",
		"price": 20,
		"stack": 4,
		"icon": "res://scripts/World/props/tape_roll.gd",
		"spec": "CLASS-A SURVEY UTILITY // 250m RETROREFLECTIVE",
		"desc": "Industrial-grade 20cm retroreflective chevron boundary ribbon. 250 meters per spool.\n\nCrucial for corridor marking, breadcrumb navigation, and avoiding topological loops in non-Euclidean spatial sectors.",
		"protocol": "APPLY TO VERTICAL OR HORIZONTAL SURFACES [KEY: T]. HIGH TORCH RETROREFLECTION."
	},
	{
		"id": "cable_spool",
		"name": "Heavy Equipment Cable Spool",
		"code": "CBL-01",
		"price": 35,
		"stack": 1,
		"icon": "res://scripts/World/props/cable_roll.gd",
		"spec": "CLASS-C ARTERY LINK // SHIELDED CONDUIT",
		"desc": "Shielded high-tensile power and telemetry cabling. Used by T.S.R.A. exploration squads to establish relay connections and mark primary transit arteries.\n\nRigid physical presence remains permanent in level space.",
		"protocol": "UNSPOOL ALONG EXPLORATION ROUTE [KEY: U]. COMPATIBLE WITH DRAW TOOLS [KEY: Y]."
	}
]

static var credit_balance: int = 150

var player: Node3D = null
var inventory: Control = null

var backdrop: Control
var content_root: Control
var viewport: SubViewport
var lens: TextureRect
var overlay_mat: ShaderMaterial
var bloom: CrtBloom
var clickables: Array = []
var shown := false
var anim: Tween
var scan_anim: Tween
var sfx: Dictionary = {}
var t := 0.0
var glitch_left := 0.0
var next_glitch := 3.5
var glow_flicker := CrtFlicker.new()
var scan_t := -1.0
var scan_overlay: Control

var selected_index: int = 0
var catalog_rows: Array = []
var list_container: VBoxContainer

# UI nodes on right spec sheet
var spec_panel: Control
var spec_title: Label
var spec_icon_frame: PanelContainer
var spec_icon_rect: TextureRect
var spec_code_lbl: Label
var spec_classification_lbl: Label
var spec_cost_lbl: Label
var spec_stock_lbl: Label
var spec_auth_lbl: Label
var spec_desc_lbl: Label
var spec_protocol_lbl: Label
var status_lbl: Label
var dispense_btn: Button
var balance_lbl: Label
var balance_cells: Control
var clearance_lbl: Label
var link_lbl: Label
var clock_lbl: Label
var cursor_rect: ColorRect

var is_dispensing := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	_load_sfx()
	_build()
	get_viewport().size_changed.connect(_fit_viewport)
	_fit_viewport()
	
	_select_item(0, true)
	_refresh_account()
	if bloom: bloom.set_running(true)
	_power_on()

func _load_sfx() -> void:
	for k in SFX_FILES:
		var sp := AudioStreamPlayer.new()
		sp.stream = load(SFX_FILES[k])
		sp.volume_db = -14.0
		add_child(sp)
		sfx[k] = sp

func play_sfx(k: String) -> void:
	var sp: AudioStreamPlayer = sfx.get(k)
	if sp:
		sp.pitch_scale = randf_range(0.97, 1.03)
		sp.play()

func _build() -> void:
	# 1. Backdrop with blur and warm dark veil
	backdrop = Control.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	
	var blur := ColorRect.new()
	var blur_mat := ShaderMaterial.new()
	blur_mat.shader = load("res://shaders/menu_blur.gdshader")
	blur.material = blur_mat
	blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blur.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.add_child(blur)
	
	var veil := ColorRect.new()
	veil.color = Color(0.035, 0.028, 0.01, 0.5)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.add_child(veil)
	
	# 2. Content Root & Warped Viewport
	content_root = Control.new()
	content_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content_root.mouse_filter = Control.MOUSE_FILTER_STOP
	content_root.gui_input.connect(_forward_mouse)
	content_root.resized.connect(_fit_viewport)
	add_child(content_root)
	
	viewport = SubViewport.new()
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.size_2d_override_stretch = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	content_root.add_child(viewport)
	
	lens = TextureRect.new()
	lens.texture = viewport.get_texture()
	lens.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	lens.stretch_mode = TextureRect.STRETCH_SCALE
	lens.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lens.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_mat = ShaderMaterial.new()
	overlay_mat.shader = load("res://shaders/ui_vhs_overlay.gdshader")
	overlay_mat.set_shader_parameter("distortion", LENS_CURVE)
	overlay_mat.set_shader_parameter("fit_corners", true)
	overlay_mat.set_shader_parameter("chroma_amt", 0.0015)
	overlay_mat.set_shader_parameter("scan_amt", 0.16)
	overlay_mat.set_shader_parameter("grain_amt", 0.05)
	overlay_mat.set_shader_parameter("vignette_amt", 0.22)
	lens.material = overlay_mat
	lens.scale = Vector2.ONE * WINDOW_SCALE
	content_root.add_child(lens)
	
	bloom = CrtBloom.new(content_root, viewport.get_texture(), true)
	overlay_mat.set_shader_parameter("bloom_tex", bloom.texture())
	overlay_mat.set_shader_parameter("bloom_amt", BLOOM)
	overlay_mat.set_shader_parameter("bloom_damp", 0.96)
	overlay_mat.set_shader_parameter("bloom_wide_tex", bloom.texture_wide())
	overlay_mat.set_shader_parameter("bloom_wide_amt", BLOOM_WIDE)
	overlay_mat.set_shader_parameter("bloom_hot", 0.0)
	overlay_mat.set_shader_parameter("bloom_tint", 0.85)
	overlay_mat.set_shader_parameter("saturation", 1.25)
	
	# 3. Screen inside viewport
	var screen := Control.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(screen)
	
	# Rounded phosphor frame with dark tube background
	screen.add_child(_build_frame())
	screen.add_child(_build_header())
	screen.add_child(_build_body())
	screen.add_child(_build_footer())

func _build_frame() -> Control:
	var f := Panel.new()
	f.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	f.offset_left = FRAME_INSET; f.offset_top = FRAME_INSET
	f.offset_right = -FRAME_INSET; f.offset_bottom = -FRAME_INSET
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.add_theme_stylebox_override("panel", Kit.box(Color(0.025, 0.02, 0.01, 1.0), Color(AMBER, 0.85), FRAME_LINE, 22))

	
	for top in [true, false]:
		var rule := ColorRect.new()
		rule.color = Color(AMBER, 0.3)
		rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rule.anchor_right = 1.0
		rule.offset_left = 30.0; rule.offset_right = -30.0
		if top:
			rule.offset_top = 56.0; rule.offset_bottom = 58.0
		else:
			rule.anchor_top = 1.0; rule.anchor_bottom = 1.0
			rule.offset_top = -54.0; rule.offset_bottom = -52.0
		f.add_child(rule)
	return f

func _build_header() -> Control:
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	h.offset_left = FRAME_INSET + 32; h.offset_right = -FRAME_INSET - 32
	h.offset_top = FRAME_INSET + 14; h.offset_bottom = FRAME_INSET + 48
	h.alignment = BoxContainer.ALIGNMENT_BEGIN
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var title_col := VBoxContainer.new()
	title_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_col.add_theme_constant_override("separation", 2)
	
	var title := Kit.label("T.S.R.A. FIELD REQUISITION TERMINAL // MK-IV LOGISTICS NODE", 20, AMBER, 2)
	title.clip_text = true
	title_col.add_child(title)
	
	var sub := Kit.label("THRESHOLD SPATIAL RESEARCH AGENCY • AUTONOMOUS SUPPLY DEPOT", 14, MUTED, 1)
	title_col.add_child(sub)
	h.add_child(title_col)
	
	# Clearance tier badge
	h.add_child(Kit.label("CLEARANCE: ", 17, MUTED, 2))
	clearance_lbl = Kit.label("C-1 SURVEYOR", 17, AMBER, 2)
	h.add_child(clearance_lbl)
	h.add_child(Kit.spacer_w(20))
	
	# Balance & segmented cells
	h.add_child(Kit.label("BALANCE: ", 17, MUTED, 2))
	balance_lbl = Kit.label("150 CR", 18, GREEN, 2)
	h.add_child(balance_lbl)
	h.add_child(Kit.spacer_w(8))
	
	balance_cells = Kit.cells(10, 3.0, false)
	balance_cells.custom_minimum_size = Vector2(100, 18)
	balance_cells.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(balance_cells)
	h.add_child(Kit.spacer_w(28))
	
	# Link status
	h.add_child(Kit.label("LINK: ", 17, MUTED, 2))
	link_lbl = Kit.label("ONLINE [STABLE]", 17, GREEN, 2)
	h.add_child(link_lbl)
	
	return h

func _build_body() -> Control:
	var deck := HBoxContainer.new()
	deck.anchor_right = 1.0
	deck.anchor_bottom = 1.0
	deck.offset_left = FRAME_INSET + 32; deck.offset_right = -FRAME_INSET - 32
	deck.offset_top = FRAME_INSET + 76; deck.offset_bottom = -FRAME_INSET - 70
	deck.add_theme_constant_override("separation", 32)
	deck.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# LEFT PANE: CATALOG MANIFEST
	deck.add_child(_build_catalog_pane())
	
	# VERTICAL DIVIDER
	var vline := ColorRect.new()
	vline.color = Color(AMBER, 0.35)
	vline.custom_minimum_size = Vector2(2, 0)
	vline.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	deck.add_child(vline)
	
	# RIGHT PANE: SPECIFICATION DOSSIER & DISPENSER
	deck.add_child(_build_spec_pane())
	
	return deck

func _build_catalog_pane() -> Control:
	var pane := VBoxContainer.new()
	pane.custom_minimum_size.x = 680
	pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pane.add_theme_constant_override("separation", 10)
	pane.mouse_filter = Control.MOUSE_FILTER_STOP
	pane.gui_input.connect(_wheel_catalog)
	
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h_title := Kit.label("REQUISITION MANIFEST", 20, AMBER, 2)
	h_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(h_title)
	var count_lbl := Kit.label("[%02d ITEMS AVAILABLE]" % CATALOG.size(), 16, MUTED, 2)
	head.add_child(count_lbl)
	pane.add_child(head)
	
	# Table Column Headers
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	cols.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(Kit.label("SLOT", 16, TEXT_DIM, 2))
	cols.add_child(Kit.spacer_w(44))
	var col_des := Kit.label("ITEM DESIGNATION", 16, TEXT_DIM, 2)
	col_des.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(col_des)
	cols.add_child(Kit.label("CODE", 16, TEXT_DIM, 2))
	cols.add_child(Kit.spacer_w(20))
	cols.add_child(Kit.label("PRICE", 16, TEXT_DIM, 2))
	cols.add_child(Kit.spacer_w(30))
	pane.add_child(cols)
	
	pane.add_child(Kit.hline(Color(AMBER, 0.45), 2))
	
	list_container = VBoxContainer.new()
	list_container.add_theme_constant_override("separation", 8)
	list_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pane.add_child(list_container)
	
	catalog_rows.clear()
	for i in CATALOG.size():
		var row := _create_catalog_row(i)
		list_container.add_child(row)
		catalog_rows.append(row)
	
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pane.add_child(spacer)
	
	var guide := Kit.label("▲ / ▼ ARROWS OR MOUSE WHEEL TO SELECT ITEM", 16, MUTED, 2)
	pane.add_child(guide)
	
	return pane

func _create_catalog_row(idx: int) -> Control:
	var item: Dictionary = CATALOG[idx]
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_meta("idx", idx)
	p.set_meta("hover", false)
	
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select_item(idx)
	)
	p.mouse_entered.connect(func():
		p.set_meta("hover", true)
		_style_row(idx)
	)
	p.mouse_exited.connect(func():
		p.set_meta("hover", false)
		_style_row(idx)
	)
	
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 52
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var cursor_lbl := Kit.label("►" if idx == selected_index else " ", 18, AMBER, 1)
	cursor_lbl.custom_minimum_size.x = 14
	row.add_child(cursor_lbl)
	p.set_meta("cursor_lbl", cursor_lbl)
	
	var slot_lbl := Kit.label("[%02d]" % (idx + 1), 18, TEXT_DIM, 1)
	row.add_child(slot_lbl)
	
	# Mini 3D icon
	var icon: Control = ItemIcon.outlined(item.icon, 38.0, AMBER, 1.2) if item.icon != "" else null
	if icon == null:
		icon = Control.new()
		icon.custom_minimum_size = Vector2(38, 38)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)
	
	var name_lbl := Kit.label(str(item.name).to_upper(), 19, TEXT, 1)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	row.add_child(name_lbl)
	p.set_meta("name_lbl", name_lbl)
	
	var code_lbl := Kit.label(str(item.code), 17, MUTED, 1)
	code_lbl.custom_minimum_size.x = 80
	row.add_child(code_lbl)
	
	var price_lbl := Kit.label("%d CR" % int(item.price), 19, AMBER, 2)
	price_lbl.custom_minimum_size.x = 75
	price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(price_lbl)
	p.set_meta("price_lbl", price_lbl)
	
	p.add_child(row)
	clickables.append(p)
	_style_row(idx, p)
	return p

func _style_row(idx: int, p: PanelContainer = null) -> void:
	if p == null:
		if idx >= catalog_rows.size(): return
		p = catalog_rows[idx]
	var sel := (idx == selected_index)
	var hov: bool = p.get_meta("hover", false)
	
	var bg_color := Color(0, 0, 0, 0)
	if sel:
		bg_color = Color(AMBER, 0.22)
	elif hov:
		bg_color = Color(AMBER, 0.08)
	
	var sb := Kit.box(bg_color, AMBER if sel else Color(AMBER_DIM, 0.3), 1, 4)
	if sel:
		sb.border_width_left = 5
		sb.border_color = AMBER
	sb.content_margin_left = 12
	sb.content_margin_right = 14
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	p.add_theme_stylebox_override("panel", sb)
	
	var cursor_lbl: Label = p.get_meta("cursor_lbl")
	if cursor_lbl:
		cursor_lbl.text = "►" if sel else " "
	var name_lbl: Label = p.get_meta("name_lbl")
	if name_lbl:
		name_lbl.add_theme_color_override("font_color", AMBER if sel else (TEXT if not hov else Color.WHITE))
	var price_lbl: Label = p.get_meta("price_lbl")
	if price_lbl:
		price_lbl.add_theme_color_override("font_color", GREEN if sel else AMBER)

func _build_spec_pane() -> Control:
	spec_panel = PanelContainer.new()
	spec_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spec_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spec_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var sb := Kit.box(FILL, AMBER_DIM, LINE, 14)
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	spec_panel.add_theme_stylebox_override("panel", sb)
	
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spec_panel.add_child(col)
	
	# Header
	spec_title = Kit.label("SPECIFICATION DOSSIER // [BAT-02]", 21, AMBER, 2)
	col.add_child(spec_title)
	col.add_child(Kit.hline(Color(AMBER, 0.45), 2))
	
	# Upper Details Block (3D Preview Box + Technical Specs)
	var upper_h := HBoxContainer.new()
	upper_h.add_theme_constant_override("separation", 24)
	upper_h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(upper_h)
	
	# 3D Icon Preview Frame
	spec_icon_frame = PanelContainer.new()
	var fsb := Kit.box(Color(AMBER, 0.05), AMBER, 2, 14)
	fsb.set_content_margin_all(14)
	spec_icon_frame.add_theme_stylebox_override("panel", fsb)

	spec_icon_frame.custom_minimum_size = Vector2(210, 210)
	spec_icon_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	spec_icon_rect = ItemIcon.outlined("", 180.0, ORANGE, 3.5)
	spec_icon_frame.add_child(spec_icon_rect)
	upper_h.add_child(spec_icon_frame)
	
	# Spec Data Column
	var spec_data := VBoxContainer.new()
	spec_data.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spec_data.add_theme_constant_override("separation", 8)
	spec_data.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	spec_code_lbl = Kit.label("DESIGNATION: AA BATTERY PACK", 20, TEXT, 1)
	spec_data.add_child(spec_code_lbl)
	
	spec_classification_lbl = Kit.label("SPEC: CLASS-A EXPEDITION POWER CELL", 17, MUTED, 1)
	spec_data.add_child(spec_classification_lbl)
	
	spec_cost_lbl = Kit.label("REQUISITION COST: 15 CR", 19, GREEN, 2)
	spec_data.add_child(spec_cost_lbl)
	
	spec_stock_lbl = Kit.label("INVENTORY STATUS: 0 / 6 CARRIED", 18, TEXT, 1)
	spec_data.add_child(spec_stock_lbl)
	
	spec_auth_lbl = Kit.label("CLEARANCE STATUS: UNRESTRICTED ISSUE", 17, AMBER, 2)
	spec_data.add_child(spec_auth_lbl)
	
	upper_h.add_child(spec_data)
	
	col.add_child(Kit.hline(Color(AMBER, 0.3), 1))
	
	# Middle Section: Operational Protocol & Lore
	var lore_head := Kit.label("TECHNICAL BRIEFING & DEPLOYMENT PROTOCOL:", 18, AMBER, 2)
	col.add_child(lore_head)
	
	spec_desc_lbl = Kit.label("", 18, TEXT, 1, true)
	spec_desc_lbl.custom_minimum_size.y = 80
	col.add_child(spec_desc_lbl)
	
	col.add_child(Kit.spacer(4))
	spec_protocol_lbl = Kit.label("", 17, MUTED, 1, true)
	col.add_child(spec_protocol_lbl)
	
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(spacer)
	
	# Bottom Section: Dispense Action Deck
	col.add_child(Kit.hline(Color(AMBER, 0.45), 2))
	
	var action_bar := HBoxContainer.new()
	action_bar.add_theme_constant_override("separation", 20)
	action_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(action_bar)
	
	var status_col := VBoxContainer.new()
	status_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_col.add_theme_constant_override("separation", 2)
	
	var st_title := Kit.label("DISPENSER STATUS:", 15, MUTED, 2)
	status_col.add_child(st_title)
	
	status_lbl = Kit.label("STANDBY // HOPPER READY", 19, GREEN, 2)
	status_col.add_child(status_lbl)
	action_bar.add_child(status_col)
	
	# Big Dispense Button
	dispense_btn = Button.new()
	dispense_btn.text = "[ ENTER ] DISPENSE REQUISITION"
	dispense_btn.focus_mode = Control.FOCUS_NONE
	dispense_btn.custom_minimum_size = Vector2(340, 52)
	dispense_btn.add_theme_font_override("font", Kit.font(2))
	dispense_btn.add_theme_font_size_override("font_size", 19)
	dispense_btn.add_theme_color_override("font_color", Color(0.04, 0.03, 0.01))
	dispense_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	dispense_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	
	var btn_normal := Kit.box(AMBER, Color(AMBER, 0.9), 2, 10)
	var btn_hover := Kit.box(Color("f4be5e"), Color.WHITE, 2, 10)
	var btn_pressed := Kit.box(Color("d68d1b"), Color.WHITE, 2, 10)
	dispense_btn.add_theme_stylebox_override("normal", btn_normal)
	dispense_btn.add_theme_stylebox_override("hover", btn_hover)
	dispense_btn.add_theme_stylebox_override("pressed", btn_pressed)

	dispense_btn.pressed.connect(_dispense_current)
	clickables.append(dispense_btn)
	action_bar.add_child(dispense_btn)
	
	# Scan Overlay for right pane
	scan_overlay = Control.new()
	scan_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scan_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scan_overlay.draw.connect(func():
		if scan_t < 0.0: return
		var w := scan_overlay.size.x
		var y := scan_t * scan_overlay.size.y
		scan_overlay.draw_rect(Rect2(3, y - 24.0, w - 6, 24.0), Color(AMBER, 0.09))
		scan_overlay.draw_line(Vector2(3, y), Vector2(w - 3, y), Color(AMBER, 0.8), LINE)
	)
	spec_panel.add_child(scan_overlay)
	
	return spec_panel

func _build_footer() -> Control:
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	h.offset_left = FRAME_INSET + 32; h.offset_right = -FRAME_INSET - 32
	h.offset_top = -FRAME_INSET - 44; h.offset_bottom = -FRAME_INSET - 14
	h.alignment = BoxContainer.ALIGNMENT_END
	h.add_theme_constant_override("separation", 18)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var agency := Kit.label("T.S.R.A. LOGISTICS DIVISION // PROPERTY OF THE AGENCY // HOPPER ACTIVE", 16, MUTED, 2)
	agency.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	agency.clip_text = true
	h.add_child(agency)
	
	cursor_rect = ColorRect.new()
	cursor_rect.color = AMBER
	cursor_rect.custom_minimum_size = Vector2(10, 18)
	cursor_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cursor_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(cursor_rect)
	
	for hint in ["▲/▼ SELECT", "ENTER DISPENSE"]:
		h.add_child(Kit.label(hint, 16, MUTED, 2))
		h.add_child(Kit.label("•", 16, MUTED))
	
	var close_btn := Button.new()
	close_btn.text = "[ESC] DISCONNECT"
	close_btn.flat = true
	close_btn.focus_mode = Control.FOCUS_NONE
	var sb := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "focus"]:
		close_btn.add_theme_stylebox_override(s, sb)
	close_btn.add_theme_font_override("font", Kit.font(2))
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.add_theme_color_override("font_color", AMBER)
	close_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	close_btn.pressed.connect(close)
	clickables.append(close_btn)
	h.add_child(close_btn)
	
	return h

func _select_item(idx: int, force := false) -> void:
	if idx < 0 or idx >= CATALOG.size(): return
	if idx == selected_index and not force: return
	
	selected_index = idx
	for i in catalog_rows.size():
		_style_row(i)
	
	var item: Dictionary = CATALOG[selected_index]
	play_sfx("select")
	
	# Update spec sheet
	spec_title.text = "SPECIFICATION DOSSIER // [%s]" % str(item.code)
	spec_code_lbl.text = "DESIGNATION: " + str(item.name).to_upper()
	spec_classification_lbl.text = "SPEC: " + str(item.spec)
	spec_cost_lbl.text = "REQUISITION COST: %d CR" % int(item.price)
	
	var carried := _get_carried_count(item.id)
	spec_stock_lbl.text = "INVENTORY STATUS: %d / %d CARRIED" % [carried, int(item.stack)]
	
	spec_desc_lbl.text = str(item.desc)
	spec_protocol_lbl.text = "FIELD DIRECTIVE: " + str(item.protocol)
	
	# Update 3D Icon in preview
	if is_instance_valid(spec_icon_rect):
		spec_icon_rect.texture = ItemIcon.texture(item.icon)
	
	dispense_btn.text = "[ ENTER ] DISPENSE // %d CR" % int(item.price)
	_reset_status()
	_reveal_spec_pane()

func _reset_status() -> void:
	if not is_dispensing:
		status_lbl.text = "STANDBY // HOPPER READY"
		status_lbl.add_theme_color_override("font_color", GREEN)

func _reveal_spec_pane() -> void:
	if scan_anim: scan_anim.kill()
	scan_anim = create_tween().set_parallel(true)
	
	# Scan line sweep
	scan_t = 0.0
	scan_anim.tween_property(self, "scan_t", 1.0, 0.32).set_trans(Tween.TRANS_SINE)
	scan_anim.chain().tween_callback(func():
		scan_t = -1.0
		scan_overlay.queue_redraw()
	)
	
	# Typewriter effect on labels
	for l in [spec_title, spec_code_lbl, spec_desc_lbl, spec_protocol_lbl]:
		l.visible_ratio = 0.0
		scan_anim.tween_property(l, "visible_ratio", 1.0, 0.24)

func _get_carried_count(item_id: String) -> int:
	var inv = _resolve_inventory()
	if inv and inv.has_method("item_count"):
		return inv.item_count(item_id)
	return 0

func _resolve_inventory() -> Control:
	if inventory and is_instance_valid(inventory):
		return inventory
	var ui = Game.main.get_node_or_null("UI")
	if ui and ui.get("inventory"):
		inventory = ui.inventory
		return inventory
	return null

func _refresh_account() -> void:
	# Clearance tier
	var tier_txt := "C-1 SURVEYOR"
	if Engine.has_singleton("Clearance") or has_node("/root/Clearance"):
		var cl = get_node_or_null("/root/Clearance")
		if cl and cl.has_method("tier_label"):
			tier_txt = cl.tier_label()
	if clearance_lbl:
		clearance_lbl.text = tier_txt
	
	# Balance
	if balance_lbl:
		balance_lbl.text = "%d CR" % credit_balance
	if balance_cells:
		var fill_ratio := clampf(float(credit_balance) / 200.0, 0.0, 1.0)
		Kit.set_cells(balance_cells, roundi(fill_ratio * 10.0), GREEN if credit_balance > 0 else RED)

func _dispense_current() -> void:
	if is_dispensing: return
	var item: Dictionary = CATALOG[selected_index]
	var price: int = int(item.price)
	
	if credit_balance < price:
		play_sfx("tab")
		status_lbl.text = "REQUISITION REJECTED // INSUFFICIENT RESEARCH CREDITS"
		status_lbl.add_theme_color_override("font_color", RED)
		_flash_error()
		return
	
	var inv = _resolve_inventory()
	var carried := _get_carried_count(item.id)
	if carried >= int(item.stack):
		play_sfx("tab")
		status_lbl.text = "DISPENSER HALT // MAXIMUM CAPACITY ALREADY CARRIED"
		status_lbl.add_theme_color_override("font_color", ORANGE)
		_flash_error()
		return
	
	# Start dispensing sequence
	is_dispensing = true
	dispense_btn.disabled = true
	dispense_btn.text = "DISPENSING IN PROGRESS..."
	status_lbl.text = "ENERGIZING HOPPER // DISPENSING [%s]..." % str(item.code)
	status_lbl.add_theme_color_override("font_color", AMBER)
	play_sfx("scan")
	
	var dtween := create_tween()
	dtween.tween_interval(0.4)
	dtween.tween_callback(func():
		# Deduct balance
		credit_balance -= price
		_refresh_account()
		
		# Add item to player inventory
		if inv and inv.has_method("add_item"):
			inv.add_item(item.id, item.name, item.desc, 1, item.code, item.stack, item.icon)
		
		play_sfx("logged")
		status_lbl.text = "DISPENSE COMPLETE // ITEM DELIVERED TO INVENTORY"
		status_lbl.add_theme_color_override("font_color", GREEN)
		
		is_dispensing = false
		dispense_btn.disabled = false
		dispense_btn.text = "[ ENTER ] DISPENSE // %d CR" % int(item.price)
		
		# Refresh stock display
		var now_carried := _get_carried_count(item.id)
		spec_stock_lbl.text = "INVENTORY STATUS: %d / %d CARRIED" % [now_carried, int(item.stack)]
		for i in catalog_rows.size():
			_style_row(i)
	)

func _flash_error() -> void:
	var tw := create_tween()
	tw.tween_property(status_lbl, "modulate:a", 0.2, 0.08)
	tw.tween_property(status_lbl, "modulate:a", 1.0, 0.08)
	tw.tween_property(status_lbl, "modulate:a", 0.2, 0.08)
	tw.tween_property(status_lbl, "modulate:a", 1.0, 0.08)

# ---- CRT Power-on & Power-off Sequences ----------------------------------------
func _power_on() -> void:
	shown = true
	if viewport: viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if bloom: bloom.set_running(true)
	play_sfx("on")
	if anim: anim.kill()
	anim = create_tween().set_parallel(true)
	
	backdrop.modulate.a = 0.0
	lens.scale = Vector2(WINDOW_SCALE, WINDOW_SCALE * 0.01)
	overlay_mat.set_shader_parameter("fade", 0.0)
	overlay_mat.set_shader_parameter("glitch", 1.0)
	
	anim.tween_property(backdrop, "modulate:a", 1.0, 0.2)
	anim.tween_property(lens, "scale:y", WINDOW_SCALE, 0.26).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	anim.tween_method(func(x: float): overlay_mat.set_shader_parameter("fade", flicker(x)), 0.0, 1.0, 0.34)
	anim.tween_method(func(x: float): overlay_mat.set_shader_parameter("glitch", x), 1.0, 0.0, 0.55).set_delay(0.05)
	
	glow_flicker.kick(0.45, true)
	_reveal_spec_pane()

func close() -> void:
	if not shown: return
	shown = false
	play_sfx("off")
	if anim: anim.kill()
	anim = create_tween().set_parallel(true)
	anim.tween_property(lens, "scale:y", WINDOW_SCALE * 0.01, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	anim.tween_property(self, "modulate:a", 0.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	anim.chain().tween_callback(func():
		if bloom: bloom.set_running(false)
		if viewport: viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		emit_signal("closed")
		queue_free()
	)

static func flicker(x: float) -> float:
	if x < 0.2: return 0.85 * x / 0.2
	if x < 0.35: return 0.15
	if x < 0.5: return 1.0
	if x < 0.62: return 0.45
	return 1.0

# ---- Input Handling -----------------------------------------------------------
func _input(e: InputEvent) -> void:
	if not shown: return
	var k := e as InputEventKey
	if k and k.pressed and not k.echo:
		match k.physical_keycode:
			KEY_UP:
				_cycle_selection(-1)
				get_viewport().set_input_as_handled()
			KEY_DOWN:
				_cycle_selection(1)
				get_viewport().set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				_dispense_current()
				get_viewport().set_input_as_handled()
			KEY_ESCAPE, KEY_TAB, KEY_E:
				get_viewport().set_input_as_handled()
				close()

func _wheel_catalog(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb and mb.pressed:
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cycle_selection(-1)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cycle_selection(1)
			get_viewport().set_input_as_handled()

func _cycle_selection(delta: int) -> void:
	var next := wrapi(selected_index + delta, 0, CATALOG.size())
	_select_item(next)

# ---- Mouse Forwarding into SubViewport ----------------------------------------
func _fit_viewport() -> void:
	if not (content_root and viewport and lens and overlay_mat):
		return
	var logical := content_root.size
	if logical.x < 16.0 or logical.y < 16.0:
		return
	var k := get_viewport().get_final_transform().get_scale()
	var px := clampf(maxf(k.x, k.y), 0.5, 3.0)
	viewport.size = Vector2i((logical * px * WINDOW_SCALE).round())
	if bloom:
		bloom.resize(viewport.size, BLOOM_RADIUS * px)
	viewport.size_2d_override = Vector2i(logical.round())
	overlay_mat.set_shader_parameter("aspect", logical.x / logical.y)
	lens.pivot_offset = logical * 0.5

func _forward_mouse(e: InputEvent) -> void:
	var m := e as InputEventMouse
	if m == null or not shown:
		return
	var p := _through_lens(m.position)
	if not Rect2(Vector2.ZERO, content_root.size).has_point(p):
		var mb := e as InputEventMouseButton
		if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			close()
	var ev := m.duplicate() as InputEventMouse
	ev.position = p
	ev.global_position = p
	viewport.push_input(ev, true)
	content_root.accept_event()
	
	if ev is InputEventMouseMotion:
		var hand := false
		for c in clickables:
			if is_instance_valid(c) and c.is_visible_in_tree() and c.get_global_rect().has_point(p):
				hand = true
				break
		content_root.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hand else Control.CURSOR_ARROW

func _through_lens(pos: Vector2) -> Vector2:
	var sz := content_root.size
	if sz.y == 0 or sz.x == 0: return pos
	var aspect := sz.x / sz.y
	var p := (pos - sz * 0.5) / WINDOW_SCALE / sz
	p.x *= aspect
	p *= (1.0 + LENS_CURVE * p.dot(p)) / (1.0 + LENS_CURVE * (0.25 * aspect * aspect + 0.25))
	p.x /= aspect
	return (p + Vector2(0.5, 0.5)) * sz

# ---- Process Loop: CRT Glitches, Bloom Flicker, Blinking Cursor -----------------
func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	t += dt
	
	# Blinking terminal cursor
	if cursor_rect:
		cursor_rect.self_modulate.a = 1.0 if fmod(t, 1.0) < 0.5 else 0.0
	
	# CRT phosphor bloom flicker
	overlay_mat.set_shader_parameter("bloom_amt", BLOOM * glow_flicker.update(dt))
	
	# Tape tear glitches
	_update_glitch(dt)
	
	# Scan overlay animation
	if scan_t >= 0.0 and scan_overlay:
		scan_overlay.queue_redraw()
	
	# Telemetry link status
	_update_link()

func _update_glitch(dt: float) -> void:
	var g := 0.0
	if glitch_left > 0.0:
		glitch_left -= dt
		g = 0.35 + 0.35 * sin(t * 70.0)
	else:
		next_glitch -= dt
		if next_glitch <= 0.0:
			glitch_left = randf_range(0.05, 0.12)
			next_glitch = randf_range(3.0, 7.0)
			if randf() < 0.4:
				glow_flicker.kick(randf_range(0.1, 0.25))
	if shown and not (anim and anim.is_running()):
		overlay_mat.set_shader_parameter("glitch", maxf(g, Game.glitch * 0.7))

func _update_link() -> void:
	if not link_lbl: return
	var state := "ONLINE [STABLE]"
	var col := GREEN
	if Game.terror > 0.6 or Game.glitch > 0.6:
		state = "LINK [DEGRADED]"
		col = RED
	elif Game.terror > 0.2:
		state = "LINK [UNSTABLE]"
		col = ORANGE
	if link_lbl.text != state:
		link_lbl.text = state
		link_lbl.add_theme_color_override("font_color", col)
