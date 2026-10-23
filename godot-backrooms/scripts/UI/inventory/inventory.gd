extends Control
## Inventory as a T.S.R.A. field terminal (TAB): an amber CRT readout laid over the live camera
## feed, a little smaller than the screen (WINDOW_SCALE) so the corridor still shows around it.
## Drawn like an old text terminal: a square double border, panels framed by plain lines with their
## titles set into the top edge, the selection a lit bar down its left edge, statuses in [BRACKETS], dotted leaders
## between a name and its figure, and a function-key strip along the bottom. Header: the emblem, the
## clearance tier and the link. Down the left, the vitals (POWER / STAMINA / SANITY / TIME: an icon in
## a bordered square over a segmented bar) and PACK (one numbered line per slot, SLOT_COUNT of them). On
## the right, the sheet under its slanted folder tabs, with the PG UP / PG DN scroll rail beside it. Each
## page is a script of its own in scripts/UI/inventory/pages/ (terminal_page.gd): ITEMS (the selected
## item), SITE (the level's threshold dossier and the phenomena logged there, from Archive,
## scripts/GameLogicEngine/tsra_archive.gd), ARCHIVE (every catalogued entity; new ones are marked until
## opened), FILES (recovered lore), RECORD (the player's clearance, tsra_clearance.gd) and CREW (co-op
## only: hidden when you are on your own). This file is the terminal around them.
## The palette and widget helpers they all use are in terminal_kit.gd.
## Everything is drawn into a SubViewport and composited through shaders/ui_vhs_overlay.gdshader
## (a mild corner-fitted CRT curve, scanlines, grain, tear glitch); mouse input is pushed through the
## same warp (_through_lens) so hover and clicks land on what is drawn. Its bright parts glow: two
## half-resolution blur passes (scripts/UI/crt/crt_bloom.gd) that the lens adds back, flickering like
## a tired tube (crt_flicker.gd). The HUD's scanner reticle and toast share both (crt_layer.gd).
## Sounds are synthesized by tools/gen_terminal_audio.py (audio/terminal/): a relay and static on
## power on / off, a key switch on page switches (which also type the page in behind a scan line), a
## lighter tick on item / entry selection.
## Toggled with TAB (scripts/GameLogicEngine/main.gd -> hud.gd set_inventory), closed by TAB / ESC
## or a click outside the window; arrows, F1-F6 and PgUp/PgDn navigate while it is up.
## Empty by default: scripts/World/props pickups can call add_item() / add_lore() to populate it.

signal close_requested

const PlayerScript := preload("res://scripts/Player/player.gd")
const CrtBloom := preload("res://scripts/UI/crt/crt_bloom.gd")
const CrtFlicker := preload("res://scripts/UI/crt/crt_flicker.gd")
const ItemIcon := preload("res://scripts/UI/inventory/item_icon.gd")
const Kit := preload("res://scripts/UI/inventory/terminal_kit.gd")
const PAGE_SCRIPTS := {
	"ITEMS": preload("res://scripts/UI/inventory/pages/page_items.gd"),
	"DOSSIER": preload("res://scripts/UI/inventory/pages/page_dossier.gd"),
	"ENTRIES": preload("res://scripts/UI/inventory/pages/page_entries.gd"),
	"PAPERS": preload("res://scripts/UI/inventory/pages/page_papers.gd"),
	"CLEARANCE": preload("res://scripts/UI/inventory/pages/page_clearance.gd"),
	"CREW": preload("res://scripts/UI/inventory/pages/page_crew.gd"),
}

# the palette lives in terminal_kit.gd; the HUD's CRT pieces read it from here (Term.AMBER etc.)
const AMBER := Kit.AMBER
const AMBER_DIM := Kit.AMBER_DIM
const TEXT := Kit.TEXT
const TEXT_DIM := Kit.TEXT_DIM
const MUTED := Kit.MUTED
const GREEN := Kit.GREEN
const ORANGE := Kit.ORANGE
const RED := Kit.RED
const FILL := Kit.FILL

# layout, in the 1920x1080 canvas (stretch mode canvas_items / expand, so width/height only grow)
const FRAME_INSET := 28.0        # the screen's double border, from the edges
const HEAD_RULE := 100.0         # y of the double rule under the header
const FOOT_RULE := 92.0          # ... and of the one over the key strip, from the bottom
const COL_X := 84.0              # left column: STATUS, then PACK
const COL_W := 600.0
const PANEL_W := 900.0           # right-hand sheet; the middle stays clear for the view
const PANEL_RIGHT := 84.0
const TOP := 128.0
const BOTTOM := 118.0
const BAR_LEVEL := Color(0.72, 0.72, 0.72, 1.0)   # the meter segments are the densest lit area: kept dimmer so they don't blow out the glow
const BAR_SEGMENTS := 20
const TAB_H := 50.0              # the folder tabs over the sheet
const TAB_SLANT := 24.0
const CHAMFER := 10.0
const ICON_BOX := 74.0           # a vitals icon's bordered square
const BAR_H := 32.0
const VITAL_LINE := 3            # thinner outline on the vitals icon boxes and bars
const BAR_GAP := 4.0             # dark space between a bar's outline and its segments
const LENS_CURVE := 0.04         # CRT bulge: ui_vhs_overlay `distortion`, corner-fitted
const LINE := Kit.LINE
const WINDOW_SCALE := 0.86       # the terminal is laid out for the full canvas, then shown this size
const VHS := 1.0                 # ui_vhs_overlay tape smear (vhs_amt); the HUD's vitals and item strip use it too
const VHS_SMEAR := 0.7           # how far it trails: short enough that the text stays readable
const BLOOM := 0.5               # phosphor glow strength, kept subtle (ui_vhs_overlay bloom_amt)
const BLOOM_WIDE := 0.18         # the neon halo's strength (a broad blur added over the tight glow)
const BLOOM_RADIUS := 10.0      # how far the glow reaches, in screen pixels at 1080p
# (BLOOM / BLOOM_RADIUS also drive the HUD's glowing scanner and toast; the flicker's timing is in
# scripts/UI/crt/crt_flicker.gd)
# terminal_<name>.wav -> volume_db (ui_click.wav plays at -6 dB in the menus)
const SFX := {"on": -14.0, "off": -15.0, "tab": -14.0, "select": -16.0}

const SLOT_COUNT := 8            # item kinds carried at once
const STACK_CELLS := 8           # widest stack gauge (the ITEMS page)
const ROW_H := 34.0              # one line of the pack
const RAIL_W := 64.0             # the sheet's scroll rail, in the gap left of it (fits "PG UP")
const RAIL_GAP := 26.0
const RAIL_END := 70.0           # arrow + key label at each end of the rail
const ROW_ICON := 28.0           # an item's icon on its pack line (rendered from its model, item_icon.gd)
const TAPE_SECONDS := 3600.0     # TIME meter: tape left on a one-hour cassette, run off Game.time
const TABS := ["ITEMS", "DOSSIER", "ENTRIES", "PAPERS", "CLEARANCE", "CREW"]
# what each page is called on the menu bar (the ids stay the pages' script names; F1-F6 jump to them)
const TAB_TITLES := {"ITEMS": "ITEMS", "DOSSIER": "SITE", "ENTRIES": "ARCHIVE", "PAPERS": "FILES",
	"CLEARANCE": "RECORD", "CREW": "CREW"}
const TAB_KEYS := {KEY_F1: "ITEMS", KEY_F2: "DOSSIER", KEY_F3: "ENTRIES", KEY_F4: "PAPERS", KEY_F5: "CLEARANCE", KEY_F6: "CREW"}
const CREW_REFRESH := 1.0            # s between rebuilds of [F6] CREW while it is open (distances, signal)

var player: Node                     # set by hud.gd; the vitals read live stats off it
var shown := false
var anim: Tween
var page_anim: Tween                 # page type-in + scan line (_reveal_page)
var tab_anim: Tween
var sfx := {}                        # name -> AudioStreamPlayer
var t := 0.0
var glitch_left := 0.0
var next_glitch := 3.0
var glow_flicker := CrtFlicker.new()

var backdrop: Control
var content_root: Control
var viewport: SubViewport
var lens: TextureRect
var overlay_mat: ShaderMaterial
var bloom: CrtBloom
var clickables: Array = []           # fixed controls in the viewport that take a click (hand cursor)

# vitals
var stats := {}                      # key -> {value, cells, shown} (POWER: + extra, the torch line)
var link_label: Label
var clock_label: Label
var clearance_label: Label           # header: T.S.R.A. clearance tier's code (tsra_clearance.gd)
var clearance_cells: Control
var link_state := ""

# items
var items: Array = []                # {id, name, desc, count, code, stack, icon (model path or "")}
var selected := -1
var pack_frame: PanelContainer
var item_rows: VBoxContainer
var row_nodes: Array = []            # one PanelContainer per item, rebuilt by _refresh_items()
var rail: Control                    # scroll track beside the sheet (_draw_rail)

# right-hand sheet
var readout: Control
var tabs_row: HBoxContainer
var tab_buttons := {}                # tab -> Button
var _crew_t := 0.0                   # [F6] CREW: time to its next rebuild
var pages := {}                      # tab -> its page (terminal_page.gd), built by _build_readout()
var page_scrolls := {}               # tab -> its ScrollContainer (PgUp / PgDn)
var active_page := "DOSSIER"
var tab_lift := 1.0                  # 0..1: the active tab rising out of the row after a switch
var scan_t := -1.0                   # 0..1 down the sheet while a page redraws, < 0 off
var scan_overlay: Control
var lore_entries: Array = []         # {id, title, text}, shown on [F4] PAPERS
var clearance_new := false           # promoted since RECORD was last opened: a * on its menu entry

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build()
	Archive.entity_discovered.connect(_on_entry_logged)
	Clearance.yield_filed.connect(_refresh_clearance)
	get_viewport().size_changed.connect(_fit_viewport)

# ---- layout ---------------------------------------------------------------------
func _build() -> void:
	# Over the live view: the pause menu's soft blur plus a warm dim, so the corridor still reads
	# through the terminal like the camera feed behind a CRT overlay
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
	veil.color = Color(0.035, 0.028, 0.01, 0.45)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.add_child(veil)

	# The terminal renders into a SubViewport so the lens pass can resample it (a CRT curve has to
	# move pixels, not just tint them) and a TextureRect draws it back through the shader. No
	# SubViewportContainer: it forwards the mouse 1:1, which drifts off the curved picture toward the
	# edges, so content_root pushes mouse events in itself, warped the same way (_forward_mouse).
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
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
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
	lens.scale = Vector2.ONE * WINDOW_SCALE   # about pivot_offset, the centre (_fit_viewport)
	content_root.add_child(lens)

	# Bloom, like phosphor on a CRT: the terminal's bright parts (lines, bar segments, icons, text)
	# blurred horizontally then vertically at half resolution; the lens adds the result back through
	# the same warp, so the glow spills onto the dark panels and the view around them
	bloom = CrtBloom.new(content_root, viewport.get_texture(), true)
	overlay_mat.set_shader_parameter("bloom_tex", bloom.texture())
	overlay_mat.set_shader_parameter("bloom_amt", BLOOM)
	overlay_mat.set_shader_parameter("bloom_damp", 0.96)   # lit segments keep their colour, not glow to white
	# neon: the tight glow plus a broad soft halo, and a slightly whiter hot core
	overlay_mat.set_shader_parameter("bloom_wide_tex", bloom.texture_wide())
	overlay_mat.set_shader_parameter("bloom_wide_amt", BLOOM_WIDE)
	overlay_mat.set_shader_parameter("bloom_hot", 0.0)
	overlay_mat.set_shader_parameter("bloom_tint", 0.85)   # glow in the pure amber, not washed out
	overlay_mat.set_shader_parameter("saturation", 1.25)
	overlay_mat.set_shader_parameter("vhs_amt", VHS)
	overlay_mat.set_shader_parameter("vhs_smear", VHS_SMEAR)

	var screen := Control.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(screen)
	screen.add_child(_build_frame())
	screen.add_child(_build_header())
	screen.add_child(_build_left())
	screen.add_child(_build_readout())
	screen.add_child(_build_rail())
	screen.add_child(_build_footer())

	for n in SFX:
		var sp := AudioStreamPlayer.new()
		sp.stream = load("res://audio/terminal/terminal_%s.wav" % n)
		sp.volume_db = SFX[n]
		add_child(sp)
		sfx[n] = sp

	_fit_viewport()
	select_tab(active_page, true)
	_refresh_items()
	for tab in TABS:
		_refresh_page(tab)

## Size the SubViewport to the screen: laid out in canvas units (size_2d_override) but rendered at
## the pixel size it is shown at (window resolution x WINDOW_SCALE), so the VCR text stays sharp
func _fit_viewport() -> void:
	if not (content_root and viewport and lens and overlay_mat):   # resized can fire mid-_build()
		return
	var logical := content_root.size
	if logical.x < 16.0 or logical.y < 16.0:
		return
	var k := get_viewport().get_final_transform().get_scale()
	var px := clampf(maxf(k.x, k.y), 0.5, 3.0)
	viewport.size = Vector2i((logical * px * WINDOW_SCALE).round())
	if bloom:
		bloom.resize(viewport.size, BLOOM_RADIUS * px)   # texture pixels: the terminal is shown 1:1
	viewport.size_2d_override = Vector2i(logical.round())
	overlay_mat.set_shader_parameter("aspect", logical.x / logical.y)
	lens.pivot_offset = logical * 0.5

## Screen-space mouse events land on content_root; push them into the terminal's viewport at the
## point the lens actually shows there, so hover / click / wheel match the curved picture
func _forward_mouse(e: InputEvent) -> void:
	var m := e as InputEventMouse
	if m == null or not shown:
		return
	var p := _through_lens(m.position)
	if not Rect2(Vector2.ZERO, content_root.size).has_point(p):
		# outside the window: a click there closes the terminal, like the pause menu's backdrop
		var mb := e as InputEventMouseButton
		if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			close_requested.emit()
	var ev := m.duplicate() as InputEventMouse
	ev.position = p
	ev.global_position = p
	viewport.push_input(ev, true)
	content_root.accept_event()
	if ev is InputEventMouseMotion:
		var hand := false
		var hover: Array = clickables + row_nodes
		for tab in pages:
			hover += pages[tab].hoverables()
		for c in hover:
			if is_instance_valid(c) and c.is_visible_in_tree() and c.get_global_rect().has_point(p):
				hand = true
				break
		content_root.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hand else Control.CURSOR_ARROW

## Same mapping as ui_vhs_overlay.gdshader (barrel bulge, fit_corners) after undoing the lens's
## WINDOW_SCALE about the centre: the viewport point that is drawn at `pos` on screen
func _through_lens(pos: Vector2) -> Vector2:
	var sz := content_root.size
	var aspect := sz.x / sz.y
	var p := (pos - sz * 0.5) / WINDOW_SCALE / sz
	p.x *= aspect
	p *= (1.0 + LENS_CURVE * p.dot(p)) / (1.0 + LENS_CURVE * (0.25 * aspect * aspect + 0.25))
	p.x /= aspect
	return (p + Vector2(0.5, 0.5)) * sz

## The screen's border, the old way: a square double line round the whole readout, and a double rule
## under the header and over the key strip
func _build_frame() -> Control:
	var f := Control.new()
	f.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.draw.connect(func():
		var r := Rect2(Vector2(FRAME_INSET, FRAME_INSET), f.size - Vector2(FRAME_INSET, FRAME_INSET) * 2.0)
		f.draw_rect(r, Color(0.03, 0.022, 0.008, 0.55))
		f.draw_rect(r, Color(AMBER, 0.85), false, 3.0)
		f.draw_rect(r.grow(-7.0), Color(AMBER, 0.35), false, 1.0)
		for y in [HEAD_RULE, f.size.y - FOOT_RULE]:
			f.draw_rect(Rect2(r.position.x + 7.0, y, r.size.x - 14.0, 2.0), Color(AMBER, 0.55))
			f.draw_rect(Rect2(r.position.x + 7.0, y + 5.0, r.size.x - 14.0, 1.0), Color(AMBER, 0.3))
	)
	f.resized.connect(f.queue_redraw)
	return f

## One line of text across the top: the emblem and the terminal's name, then clearance and link
func _build_header() -> Control:
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	h.offset_left = FRAME_INSET + 26; h.offset_right = -FRAME_INSET - 30
	h.offset_top = FRAME_INSET + 14; h.offset_bottom = HEAD_RULE - 10
	h.add_theme_constant_override("separation", 14)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(Kit.logo(40))
	h.add_child(_centered(Kit.label("T.S.R.A.", 24, AMBER, 7)))
	var sub := Kit.label("FIELD TERMINAL  //  MK-IV", 15, MUTED, 3)
	sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(_centered(sub))
	h.add_child(_centered(Kit.label("RANK:", 15, MUTED, 3)))
	clearance_label = Kit.label("", 18, AMBER, 2)
	h.add_child(_centered(clearance_label))
	clearance_cells = Kit.cells(10, 3.0, false)
	clearance_cells.custom_minimum_size = Vector2(120, 12)
	clearance_cells.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(clearance_cells)
	h.add_child(Kit.spacer_w(30))
	h.add_child(_centered(Kit.label("LINK:", 15, MUTED, 3)))
	link_label = Kit.label("[STABLE]", 18, GREEN, 2)
	h.add_child(_centered(link_label))
	_refresh_clearance()
	return h

func _centered(l: Control) -> Control:
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l

func _refresh_clearance(report := {}) -> void:
	if not clearance_label:
		return
	if int(report.get("tier_to", 0)) != int(report.get("tier_from", 0)):
		_refresh_page("DOSSIER")
		_refresh_page("ENTRIES")
		if int(report.get("tier_to", 0)) > int(report.get("tier_from", 0)) and active_page != "CLEARANCE":
			clearance_new = true
			if readout: readout.queue_redraw()
	_refresh_page("CLEARANCE")
	clearance_label.text = Clearance.tier_label()
	clearance_label.add_theme_color_override("font_color", Clearance.tier_color())
	Kit.set_cells(clearance_cells, roundi(Clearance.tier_progress() * 10.0), GREEN if Clearance.is_max_tier() else AMBER)

## The function-key strip along the bottom: each [KEY] lit, then what it does; the clock
## at the far end
func _build_footer() -> Control:
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	h.offset_left = FRAME_INSET + 26; h.offset_right = -FRAME_INSET - 30
	h.offset_top = -FOOT_RULE + 14; h.offset_bottom = -FRAME_INSET - 12
	h.add_theme_constant_override("separation", 12)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(Kit.keycap("TAB"))
	var close := Button.new()
	close.text = "CLOSE"
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	var sb := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		close.add_theme_stylebox_override(s, sb)
	close.add_theme_font_override("font", Kit.font(3))
	close.add_theme_font_size_override("font_size", 15)
	close.add_theme_color_override("font_color", MUTED)
	close.add_theme_color_override("font_hover_color", AMBER)
	close.add_theme_color_override("font_pressed_color", AMBER)
	close.pressed.connect(func(): close_requested.emit())
	clickables.append(close)
	h.add_child(close)
	for k in [["◄ ►", "PAGE"], ["▲ ▼", "SELECT"], ["PG UP / DN", "SCROLL"]]:
		h.add_child(Kit.spacer_w(14))
		h.add_child(Kit.keycap(k[0]))
		h.add_child(_centered(Kit.label(k[1], 15, MUTED, 3)))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(gap)
	clock_label = Kit.label("", 15, MUTED, 3)
	h.add_child(_centered(clock_label))
	return h

# ---- the left column: STATUS (POWER / STAMINA / SANITY / TIME, live off the player), then PACK ----
func _build_left() -> Control:
	var v := VBoxContainer.new()
	v.anchor_bottom = 1.0
	v.offset_left = COL_X; v.offset_right = COL_X + COL_W
	v.offset_top = TOP; v.offset_bottom = -BOTTOM
	v.add_theme_constant_override("separation", 24)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_build_vitals())
	v.add_child(_build_items())
	return v

## The four meters as they always were: the icon in a bordered square, then the name and figure over
## a segmented bar. The icons are white alpha masks (textures/ui/terminal_*.png), tinted to follow the
## bar's state colour. POWER's line also carries the torch's time left.
func _build_vitals() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 22)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_stat_row("POWER", "res://textures/ui/terminal_battery.png"))
	v.add_child(_stat_row("STAMINA", "res://textures/ui/terminal_stamina.png"))
	v.add_child(_stat_row("SANITY", "res://textures/ui/terminal_sanity.png"))
	v.add_child(_stat_row("TIME", "res://textures/ui/terminal_time.png"))
	return v

func _stat_row(key: String, icon_path: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var box := PanelContainer.new()
	var sb := Kit.box(FILL, AMBER, VITAL_LINE)
	sb.set_content_margin_all(12)
	box.add_theme_stylebox_override("panel", sb)
	box.custom_minimum_size = Vector2(ICON_BOX, ICON_BOX)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.texture = load(icon_path)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.self_modulate = AMBER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(icon)
	row.add_child(box)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 16)
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := Kit.label(key, 24, TEXT, 3)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta.add_child(title)
	var extra := Kit.label("", 16, TEXT_DIM, 2)           # POWER: the torch's time left
	extra.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	meta.add_child(extra)
	var val := Kit.label("100%", 24, TEXT, 2)
	meta.add_child(val)
	col.add_child(meta)
	var bar := PanelContainer.new()
	var bsb := Kit.box(FILL, AMBER, VITAL_LINE)
	bsb.set_content_margin_all(VITAL_LINE + BAR_GAP)
	bar.add_theme_stylebox_override("panel", bsb)
	bar.custom_minimum_size = Vector2(0, BAR_H)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cells := Kit.cells(BAR_SEGMENTS, 4.0, false)
	bar.add_child(cells)
	col.add_child(bar)
	row.add_child(col)

	stats[key] = {"icon": icon, "value": val, "cells": cells, "extra": extra, "shown": -1.0}
	return row

func _update_vitals(dt: float) -> void:
	if not player:
		return
	var pulse := 0.65 + 0.35 * sin(t * 15.0)
	var bat: float = player.battery
	var bat_state := ""
	if bat < PlayerScript.BATTERY_CRIT: bat_state = "critical"
	elif bat < PlayerScript.BATTERY_LOW: bat_state = "low"
	_set_stat("POWER", bat, bat_state, dt, pulse)
	_set_stat("STAMINA", player.stamina, "critical" if player.exhausted else "", dt, pulse)
	var san: float = player.sanity
	var san_state := ""
	if san < 25.0: san_state = "critical"
	elif san < 50.0: san_state = "low"
	_set_stat("SANITY", san, san_state, dt, pulse)
	var tape := 100.0 * (1.0 - Game.time / TAPE_SECONDS)
	_set_stat("TIME", tape, "low" if tape < 10.0 else "", dt, pulse)

func _set_stat(key: String, value: float, state: String, dt: float, pulse: float) -> void:
	var s: Dictionary = stats[key]
	value = clampf(value, 0.0, 100.0)
	# ease toward the real value so drains and recoveries glide, like the HUD meters
	var eased: float = value if s.shown < 0.0 else lerpf(s.shown, value, minf(1.0, dt * 8.0))
	s.shown = eased
	var col := AMBER
	var txt := TEXT
	match state:
		"low":
			col = ORANGE
			txt = ORANGE
		"critical":
			col = Color(RED, pulse)
			txt = RED
	Kit.set_cells(s.cells, clampi(ceili(eased / 100.0 * BAR_SEGMENTS - 0.01), 0, BAR_SEGMENTS), col * BAR_LEVEL)
	(s.icon as TextureRect).self_modulate = col
	var v: Label = s.value
	var vt := "%d%%" % int(round(eased))
	if v.text != vt:                          # only on change: a label re-shapes its text when set
		v.text = vt
	if s.get("txt") != txt:
		s["txt"] = txt
		v.add_theme_color_override("font_color", txt)

## Header link status: the feed degrades as something closes in (Game.terror / Game.glitch)
func _update_link() -> void:
	var state := "STABLE"
	if Game.terror > 0.6 or Game.glitch > 0.6: state = "DEGRADED"
	elif Game.terror > 0.15: state = "UNSTABLE"
	if state != link_state:
		link_state = state
		link_label.text = "[%s]" % state
		var col := GREEN
		if state == "UNSTABLE": col = ORANGE
		elif state == "DEGRADED": col = RED
		link_label.add_theme_color_override("font_color", col)
	link_label.modulate.a = (1.0 if fmod(t, 0.5) < 0.3 else 0.25) if state == "DEGRADED" else 1.0

# ---- the pack: one numbered line per slot, the selected one lit ----------------------------------
func _build_items() -> Control:
	pack_frame = Kit.frame("PACK", "0/%d" % SLOT_COUNT)
	pack_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pack_frame.mouse_filter = Control.MOUSE_FILTER_STOP     # the wheel over the pack steps the selection
	pack_frame.gui_input.connect(func(e: InputEvent):
		if _wheel_items(e): pack_frame.accept_event()
	)
	item_rows = VBoxContainer.new()
	item_rows.add_theme_constant_override("separation", 2)
	item_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pack_frame.add_child(item_rows)
	return pack_frame

func _refresh_items() -> void:
	if not item_rows:
		return
	Kit.clear(item_rows)
	row_nodes.clear()
	Kit.set_frame_right(pack_frame, "%d/%d" % [items.size(), SLOT_COUNT])
	for i in SLOT_COUNT:
		if i < items.size():
			var row := _item_row(i)
			item_rows.add_child(row)
			row_nodes.append(row)
		else:
			item_rows.add_child(_empty_row(i))
	_refresh_selection()

## "01  AA BATTERY PACK ............... 3/6". A click selects it and turns the sheet to ITEMS.
func _item_row(i: int) -> Control:
	var it: Dictionary = items[i]
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_meta("hover", false)
	p.gui_input.connect(func(e: InputEvent):
		if _wheel_items(e):
			p.accept_event()
		elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			var quiet := active_page != "ITEMS"   # the page switch plays its own chirp
			_select(i, quiet)
			select_tab("ITEMS")
	)
	p.mouse_entered.connect(func(): p.set_meta("hover", true); _style_row(i))
	p.mouse_exited.connect(func(): p.set_meta("hover", false); _style_row(i))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	h.custom_minimum_size.y = ROW_H
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var slot := Kit.label("%02d" % (i + 1), 16, MUTED, 2)
	h.add_child(_centered(slot))
	# icon slot on every line, empty for items without a model, so the names stay in a column
	var icon: Control = ItemIcon.outlined(it.icon, ROW_ICON, AMBER, 1.0) if it.icon != "" else null
	if icon == null or (icon as TextureRect).texture == null:
		icon = Control.new()
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = Vector2(ROW_ICON, ROW_ICON)
	h.add_child(_centered(icon))
	var name_l := Kit.label(str(it.name).to_upper(), 18, TEXT, 2)
	h.add_child(_centered(name_l))
	var d := Kit.dots()
	h.add_child(d)
	var count := Kit.label("%d/%d" % [it.count, it.stack], 17, TEXT, 2)
	h.add_child(_centered(count))
	p.add_child(h)
	p.set_meta("labels", [slot, name_l, count])
	p.set_meta("dots", d)
	return p

## A free slot: its number and an empty run of dots, faint
func _empty_row(i: int) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	h.custom_minimum_size.y = ROW_H + 8.0
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pad := MarginContainer.new()          # lines up with the item rows' margin
	pad.add_theme_constant_override("margin_left", 10)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(Kit.label("%02d" % (i + 1), 16, Color(MUTED, 0.3), 2))
	h.add_child(_centered(pad))
	h.add_child(Kit.spacer_w(ROW_ICON))
	h.add_child(Kit.dots(Color(MUTED, 0.14)))
	return h

func _style_row(i: int) -> void:
	if i >= row_nodes.size():
		return
	var p: PanelContainer = row_nodes[i]
	var sel := i == selected
	p.add_theme_stylebox_override("panel", Kit.row_box(sel, p.get_meta("hover")))
	var ls: Array = p.get_meta("labels")
	for j in ls.size():
		var l: Label = ls[j]
		l.add_theme_color_override("font_color", AMBER if sel else (MUTED if j == 0 else TEXT))
	var d: Control = p.get_meta("dots")
	d.set_meta("color", Color(AMBER, 0.6) if sel else Color(MUTED, 0.5))
	d.queue_redraw()

func _refresh_selection() -> void:
	for i in row_nodes.size():
		_style_row(i)
	_refresh_page("ITEMS")

## STATUS's last line: torch time left at the current drain (player.gd BATTERY_DRAIN, a quarter of it
## in a power cut)
func _update_battery_line() -> void:
	if not player:
		return
	var bat: float = player.battery
	var txt := "DEPLETED"
	if bat > 0.0:
		var drain: float = PlayerScript.BATTERY_DRAIN * (0.25 if player.grid_down else 1.0)
		var secs := int(bat / drain)
		txt = "%d:%02d LEFT" % [secs / 60, secs % 60]
	var l: Label = stats.POWER.extra
	if l.text != txt:
		l.text = txt
		var col := TEXT
		if bat < PlayerScript.BATTERY_CRIT: col = RED
		elif bat < PlayerScript.BATTERY_LOW: col = ORANGE
		l.add_theme_color_override("font_color", col)

func _select(i: int, quiet := false) -> void:
	if i >= items.size():
		return
	if i != selected and not quiet: play_sfx("select")
	selected = i
	_refresh_selection()

## Mouse wheel over the pack: down to the next item, up to the previous, and the sheet turns to ITEMS
## to show it, as a click would. True when `e` was a wheel step (the caller eats it)
func _wheel_items(e: InputEvent) -> bool:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		return false
	var step := 0
	if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN: step = 1
	elif mb.button_index == MOUSE_BUTTON_WHEEL_UP: step = -1
	if step == 0:
		return false
	var was := selected
	_move_selection(step)
	if selected != was:
		select_tab("ITEMS")
	return true

func _move_selection(delta: int) -> void:
	if items.is_empty():
		return
	_select(clampi(maxi(selected, 0) + delta, 0, items.size() - 1))

# ---- right-hand sheet: ITEMS / SITE / ARCHIVE / FILES / RECORD / CREW ------------------------------
func _build_readout() -> Control:
	readout = Control.new()
	readout.anchor_left = 1.0; readout.anchor_right = 1.0; readout.anchor_bottom = 1.0
	readout.offset_left = -PANEL_RIGHT - PANEL_W; readout.offset_right = -PANEL_RIGHT
	readout.offset_top = TOP; readout.offset_bottom = -BOTTOM
	readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	readout.draw.connect(_draw_readout)
	readout.resized.connect(readout.queue_redraw)

	tabs_row = HBoxContainer.new()
	tabs_row.custom_minimum_size = Vector2(0, TAB_H)
	tabs_row.add_theme_constant_override("separation", 4)
	tabs_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tabs_row.sort_children.connect(readout.queue_redraw)
	readout.add_child(tabs_row)
	for tab in TABS:
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, TAB_H)
		b.add_theme_font_override("font", Kit.font(2))
		b.pressed.connect(select_tab.bind(tab))
		tab_buttons[tab] = b
		clickables.append(b)
		tabs_row.add_child(b)

	var body := MarginContainer.new()
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.offset_top = TAB_H
	body.add_theme_constant_override("margin_left", 24)
	body.add_theme_constant_override("margin_right", 12)
	body.add_theme_constant_override("margin_top", 20)
	body.add_theme_constant_override("margin_bottom", 18)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	readout.add_child(body)

	for tab in TABS:
		var page = PAGE_SCRIPTS[tab].new(self)
		pages[tab] = page
		body.add_child(page.build())
		if page.scroll_box:
			page_scrolls[tab] = page.scroll_box

	# drawn over the page text while it redraws (_reveal_page): a bright line with a faint trail
	scan_overlay = Control.new()
	scan_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scan_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scan_overlay.draw.connect(func():
		if scan_t < 0.0:
			return
		var w := scan_overlay.size.x
		var y := TAB_H + 6.0 + scan_t * (scan_overlay.size.y - TAB_H - 12.0)
		scan_overlay.draw_rect(Rect2(3, y - 26.0, w - 6, 26.0), Color(AMBER, 0.07))
		scan_overlay.draw_line(Vector2(3, y), Vector2(w - 3, y), Color(AMBER, 0.75), LINE)
	)
	readout.add_child(scan_overlay)
	return readout

## The sheet's outline, drawn by hand so the front tab opens into it like a file folder: the top
## edge leaves a gap under the active tab, and the others sit a little lower, behind the border
func _draw_readout() -> void:
	var w := readout.size.x
	var h := readout.size.y
	var top := TAB_H
	var c := CHAMFER
	readout.draw_colored_polygon(PackedVector2Array([
		Vector2(0, top), Vector2(w - c, top), Vector2(w, top + c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(c, h), Vector2(0, h - c)]), FILL)
	var gap := Vector2.ZERO
	var gap_y := top
	for tab in TABS:
		var b: Button = tab_buttons[tab]
		if not b.visible:
			continue
		var x0 := tabs_row.position.x + b.position.x
		var x1 := x0 + b.size.x
		var on: bool = tab == active_page
		var y := 8.0 * (1.0 - tab_lift) if on else 8.0
		var shape := PackedVector2Array([Vector2(x0, top), Vector2(x0, y), Vector2(x1 - TAB_SLANT, y), Vector2(x1, top)])
		readout.draw_colored_polygon(shape, FILL if on else Color(FILL, 0.5))
		if on:
			gap = Vector2(x0, x1)
			gap_y = y
		else:
			readout.draw_polyline(shape, AMBER_DIM, LINE, true)
		if (tab == "ENTRIES" and Archive.has_unread()) or (tab == "CLEARANCE" and clearance_new):
			readout.draw_circle(Vector2(x1 - TAB_SLANT - 6.0, y + 10.0), 5.0, AMBER)   # something new, not seen yet
	# one closed loop through the active tab, started mid-bottom, so no line end shows at the tab's feet
	var edge := PackedVector2Array([
		Vector2(w * 0.5, h), Vector2(c, h), Vector2(0, h - c), Vector2(0, top)])
	if gap.y > 0.0:
		edge.append_array(PackedVector2Array([Vector2(gap.x, top), Vector2(gap.x, gap_y),
			Vector2(gap.y - TAB_SLANT, gap_y), Vector2(gap.y, top)]))
	edge.append_array(PackedVector2Array([Vector2(w - c, top), Vector2(w, top + c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(w * 0.5, h)]))
	readout.draw_polyline(edge, AMBER, LINE, true)

func _style_tab(tab: String) -> void:
	var b: Button = tab_buttons[tab]
	var on := tab == active_page
	b.text = TAB_TITLES[tab]
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = 14
	sb.content_margin_right = 10 + TAB_SLANT
	sb.content_margin_top = 0.0 if on else 8.0
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(s, sb)
	b.add_theme_font_override("font", Kit.font(2 if on else 1))
	b.add_theme_font_size_override("font_size", 18 if on else 14)
	for s in ["font_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(s, TEXT if on else TEXT_DIM)
	b.add_theme_color_override("font_hover_color", TEXT)

func select_tab(tab: String, force := false, focus_new := true) -> void:
	if tab == active_page and not force:
		return
	active_page = tab
	for k in pages:
		pages[k].root.visible = k == tab
	for k in tab_buttons:
		_style_tab(k)
	readout.queue_redraw()
	if tab == "ENTRIES" and focus_new:
		pages.ENTRIES.focus_unread()
	if tab == "CLEARANCE":
		clearance_new = false
		_refresh_page("CLEARANCE")            # the re-read cooldowns tick while it is closed
	if tab == "CREW":
		_crew_t = CREW_REFRESH
		_refresh_page("CREW")
	if force:
		return
	play_sfx("tab")
	glitch_left = 0.07                        # a short tear on the overlay as the page changes
	if tab_anim: tab_anim.kill()
	tab_anim = create_tween()
	tab_anim.tween_method(_set_tab_lift, 0.0, 1.0, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_reveal_page(tab)

## The page redraws like a terminal screen: it flickers on, a scan line runs down the sheet and each
## line of text types itself in, top to bottom
func _reveal_page(tab: String, delay := 0.0) -> void:
	if page_anim: page_anim.kill()
	var page: Control = pages[tab].root
	var labels := page.find_children("*", "Label", true, false)
	page_anim = create_tween().set_parallel(true)
	page.modulate.a = 0.0
	page_anim.tween_method(func(x: float): page.modulate.a = flicker(x), 0.0, 1.0, 0.22).set_delay(delay)
	for i in labels.size():
		var l: Label = labels[i]
		l.visible_ratio = 0.0
		var dur := clampf(l.text.length() * 0.007, 0.06, 0.3)
		page_anim.tween_method(_type_label.bind(l), 0.0, 1.0, dur).set_delay(delay + minf(i * 0.022, 0.45))
	scan_t = 0.0
	page_anim.tween_method(_set_scan, 0.0, 1.0, 0.4).set_delay(delay).set_trans(Tween.TRANS_SINE)
	page_anim.tween_callback(_set_scan.bind(-1.0)).set_delay(delay + 0.4)   # off once it reaches the bottom

# `l` untyped: a page can be rebuilt mid-reveal (selection change, new sighting) and a freed label
# must reach the is_instance_valid() check rather than fail the argument's type check
func _type_label(ratio: float, l) -> void:
	if is_instance_valid(l):
		l.visible_ratio = ratio

func _set_tab_lift(v: float) -> void:
	tab_lift = v
	readout.queue_redraw()

func _set_scan(v: float) -> void:
	scan_t = v
	scan_overlay.queue_redraw()

## Rebuild one page of the sheet (nothing before _build_readout() has made them)
func _refresh_page(tab: String) -> void:
	if pages.has(tab):
		pages[tab].refresh()

## [F3] straight to this entity's entry (the dossier's phenomena rows)
func open_entry(id: String) -> void:
	pages.ENTRIES.open_entry(id)

func _on_entry_logged(_id: String) -> void:
	_refresh_page("DOSSIER")
	_refresh_page("ENTRIES")
	if readout:
		readout.queue_redraw()

func play_sfx(n: String) -> void:
	var sp: AudioStreamPlayer = sfx.get(n)
	if sp:
		sp.pitch_scale = randf_range(0.97, 1.03)   # repeats shouldn't sound mechanical
		sp.play()

func _cycle_tab(delta: int) -> void:
	var shown_tabs := TABS.filter(func(k): return tab_buttons[k].visible)
	select_tab(shown_tabs[wrapi(shown_tabs.find(active_page) + delta, 0, shown_tabs.size())])

## CREW only means something with others on the channel: its tab is hidden when you are on your own
func _update_crew_tab() -> void:
	var on: bool = Net.is_online() or not Net.phantoms.is_empty()
	tab_buttons.CREW.visible = on
	if not on and active_page == "CREW":
		select_tab("ITEMS", true)

## Scroll rail in the gap left of the sheet: the active page's position, with PG UP / PG DN at its
## ends, lit when there is more that way. Click an end to page, the track to jump, or use the wheel
## over it. It stands in for the pages' own scrollbars, which are hidden (they still scroll).
func _build_rail() -> Control:
	rail = Control.new()
	rail.anchor_left = 1.0; rail.anchor_right = 1.0; rail.anchor_bottom = 1.0
	rail.offset_right = -PANEL_RIGHT - PANEL_W - RAIL_GAP
	rail.offset_left = rail.offset_right - RAIL_W
	rail.offset_top = TOP + TAB_H; rail.offset_bottom = -BOTTOM
	rail.mouse_filter = Control.MOUSE_FILTER_STOP
	rail.draw.connect(_draw_rail)
	rail.gui_input.connect(_rail_input)
	clickables.append(rail)
	for k in page_scrolls:
		(page_scrolls[k] as ScrollContainer).vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	return rail

## {ratio: visible part of the page, pos: 0 top .. 1 bottom}; ratio 1 when it all fits
func _page_extent() -> Dictionary:
	var sc: ScrollContainer = page_scrolls.get(active_page)
	if sc == null:
		return {"ratio": 1.0, "pos": 0.0}
	var bar := sc.get_v_scroll_bar()
	if bar.max_value <= bar.page + 0.5:
		return {"ratio": 1.0, "pos": 0.0}
	return {"ratio": bar.page / bar.max_value, "pos": clampf(bar.value / (bar.max_value - bar.page), 0.0, 1.0)}

func _draw_rail() -> void:
	var w := rail.size.x
	var h := rail.size.y
	var cx := w * 0.5
	var ext := _page_extent()
	var ratio: float = ext.ratio
	var pos: float = ext.pos
	var more_up := ratio < 1.0 and pos > 0.005
	var more_down := ratio < 1.0 and pos < 0.995
	var f := Kit.font(2)
	rail.draw_colored_polygon(PackedVector2Array([Vector2(cx - 12, 30), Vector2(cx + 12, 30), Vector2(cx, 12)]),
		AMBER if more_up else AMBER_DIM)
	rail.draw_string(f, Vector2(0, 54), "PG UP", HORIZONTAL_ALIGNMENT_CENTER, w, 13, MUTED if more_up else TEXT_DIM)
	rail.draw_string(f, Vector2(0, h - 44), "PG DN", HORIZONTAL_ALIGNMENT_CENTER, w, 13, MUTED if more_down else TEXT_DIM)
	rail.draw_colored_polygon(PackedVector2Array([Vector2(cx - 12, h - 30), Vector2(cx + 12, h - 30), Vector2(cx, h - 12)]),
		AMBER if more_down else AMBER_DIM)
	var y0 := RAIL_END
	var track := h - RAIL_END * 2.0
	rail.draw_line(Vector2(cx, y0), Vector2(cx, y0 + track), Color(AMBER, 0.3), 2.0)
	var th := maxf(40.0, track * ratio)
	var ty := y0 + (track - th) * pos
	rail.draw_rect(Rect2(cx - 5, ty, 10, th), AMBER if ratio < 1.0 else AMBER_DIM)

func _rail_input(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	var sc: ScrollContainer = page_scrolls.get(active_page)
	if sc == null:
		return
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP: sc.scroll_vertical -= 60
		MOUSE_BUTTON_WHEEL_DOWN: sc.scroll_vertical += 60
		MOUSE_BUTTON_LEFT:
			var y := mb.position.y
			if y < RAIL_END:
				_scroll_page(-1)
			elif y > rail.size.y - RAIL_END:
				_scroll_page(1)
			else:
				var bar := sc.get_v_scroll_bar()
				var k := clampf((y - RAIL_END) / (rail.size.y - RAIL_END * 2.0), 0.0, 1.0)
				sc.scroll_vertical = int(k * maxf(0.0, bar.max_value - bar.page))

func _scroll_page(delta: int) -> void:
	var s: ScrollContainer = page_scrolls.get(active_page)
	if s:
		s.scroll_vertical += delta * int(s.size.y * 0.8)

# ---- open / close, input, per frame ------------------------------------------------------
## Power-on: the picture opens out of a bright line like a CRT warming up, its alpha stuttering
## (same flicker curve as the pause menu, menu.gd _flicker) while the overlay throws a short
## tear-glitch burst, the vitals bars sweep up from empty and the open page types itself in.
## Power-off collapses it back into the line.
func set_shown(on: bool) -> void:
	if on == shown:
		return
	shown = on
	if anim: anim.kill()
	anim = create_tween().set_parallel(true)
	if on:
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		bloom.set_running(true)
		visible = true
		modulate.a = 1.0
		_fit_viewport()
		if selected == -1 and not items.is_empty(): selected = 0
		_refresh_selection()
		_refresh_page("DOSSIER")
		_refresh_page("ENTRIES")
		_refresh_page("CLEARANCE")
		_refresh_page("CREW")
		_update_crew_tab()
		clock_label.text = Time.get_time_string_from_system().left(5)
		play_sfx("on")
		for k in stats: stats[k].shown = 0.0
		backdrop.modulate.a = 0.0
		lens.scale = Vector2(WINDOW_SCALE, WINDOW_SCALE * 0.01)
		overlay_mat.set_shader_parameter("fade", 0.0)
		overlay_mat.set_shader_parameter("glitch", 1.0)
		anim.tween_property(backdrop, "modulate:a", 1.0, 0.2)
		anim.tween_property(lens, "scale:y", WINDOW_SCALE, 0.26).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		anim.tween_method(func(x: float): overlay_mat.set_shader_parameter("fade", flicker(x)), 0.0, 1.0, 0.34)
		anim.tween_method(func(x: float): overlay_mat.set_shader_parameter("glitch", x), 1.0, 0.0, 0.55).set_delay(0.05)
		_reveal_page(active_page, 0.2)
		glow_flicker.kick(0.45, true)       # the glow stutters up as the tube warms
	else:
		play_sfx("off")
		anim.tween_property(lens, "scale:y", WINDOW_SCALE * 0.01, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		anim.tween_property(self, "modulate:a", 0.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		anim.chain().tween_callback(_finish_hide)

func _finish_hide() -> void:
	visible = false
	modulate.a = 1.0
	lens.scale = Vector2.ONE * WINDOW_SCALE
	if page_anim: page_anim.kill()
	_set_scan(-1.0)
	overlay_mat.set_shader_parameter("fade", 1.0)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	bloom.set_running(false)

## Alpha curve for the power-on: dim, blink out, flash, settle (matches menu.gd). Static: the HUD
## toast (terminal_toast.gd) flickers on with it too.
static func flicker(x: float) -> float:
	if x < 0.2: return 0.85 * x / 0.2
	if x < 0.35: return 0.15
	if x < 0.5: return 1.0
	if x < 0.62: return 0.45
	return 1.0

## _input, not _unhandled_input: dev builds bind plain F1-F3 to level changes (level_builder.gd),
## which must not fire while the terminal has them
func _input(e: InputEvent) -> void:
	if not shown:
		return
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.physical_keycode:
		KEY_UP, KEY_DOWN:            # the arrows move whichever list the page shows
			var step := -1 if k.physical_keycode == KEY_UP else 1
			if active_page == "ENTRIES":
				pages.ENTRIES.step(step)
			else:
				_move_selection(step)
		KEY_LEFT: _cycle_tab(-1)
		KEY_RIGHT: _cycle_tab(1)
		KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6:
			if tab_buttons[TAB_KEYS[k.physical_keycode]].visible:
				select_tab(TAB_KEYS[k.physical_keycode])
		KEY_PAGEUP: _scroll_page(-1)
		KEY_PAGEDOWN: _scroll_page(1)
		_: return
	if is_inside_tree(): get_viewport().set_input_as_handled()

func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	t += dt
	if active_page == "CREW":
		_crew_t -= dt
		if _crew_t <= 0.0:
			_crew_t = CREW_REFRESH
			_refresh_page("CREW")
	_update_vitals(dt)
	_update_battery_line()
	if Engine.get_process_frames() % 30 == 0:
		clock_label.text = Time.get_time_string_from_system().left(5)
	rail.queue_redraw()
	_update_link()
	_update_glitch(dt)
	overlay_mat.set_shader_parameter("bloom_amt", BLOOM * glow_flicker.update(dt))

## Every few seconds a brief tear-glitch burst — the tape never sits perfectly still (menu.gd
## _update_glitch) — plus whatever the events are throwing at the camera (Game.glitch)
func _update_glitch(dt: float) -> void:
	var g := 0.0
	if glitch_left > 0.0:
		glitch_left -= dt
		g = 0.35 + 0.35 * sin(t * 70.0)
	else:
		next_glitch -= dt
		if next_glitch <= 0.0:
			glitch_left = randf_range(0.05, 0.14)
			next_glitch = randf_range(3.0, 7.0)
			if randf() < 0.5: glow_flicker.kick(randf_range(0.1, 0.25))   # the tear jolts the glow too
	if shown and not (anim and anim.is_running()):     # the power-on burst drives it while it plays
		overlay_mat.set_shader_parameter("glitch", maxf(g, Game.glitch * 0.8))

# ---- public API: World/props pickups can call these -------------------------------------
## Returns false when nothing fits (SLOT_COUNT kinds already carried, or this stack is full), so a
## pickup can stay on the floor. `code` is the 3-4 letter tag on the INV row (default: from the
## name); `stack` is the most of this item carried, and its gauge width (up to STACK_CELLS);
## `icon` is the item's model (res:// .glb): its icon is rendered from it, with an orange outline.
func add_item(id: String, title: String, desc: String, count := 1, code := "", stack := STACK_CELLS, icon := "") -> bool:
	for it in items:
		if it.id == id:
			if it.count >= it.stack:
				return false
			it.count = mini(it.count + count, it.stack)
			_refresh_items()
			return true
	if items.size() >= SLOT_COUNT:
		return false
	if code == "":
		code = title.replace(" ", "")
	stack = maxi(stack, 1)
	items.append({"id": id, "name": title, "desc": desc, "count": mini(count, stack), "code": code.to_upper().left(4), "stack": stack, "icon": icon})
	if selected == -1:
		selected = 0
	_refresh_items()
	return true

func remove_item(id: String, count := 1) -> void:
	for i in items.size():
		if items[i].id == id:
			items[i].count -= count
			if items[i].count <= 0:
				items.remove_at(i)
				selected = mini(selected, items.size() - 1)
			_refresh_items()
			return

func has_item(id: String) -> bool:
	for it in items:
		if it.id == id: return true
	return false

func item_count(id: String) -> int:
	for it in items:
		if it.id == id: return it.count
	return 0

func add_lore(id: String, title: String, text: String) -> void:
	for e in lore_entries:
		if e.id == id: return
	if lore_entries.size() >= PAGE_SCRIPTS.PAPERS.CAP: return
	lore_entries.append({"id": id, "title": title, "text": text})
	_refresh_page("PAPERS")
