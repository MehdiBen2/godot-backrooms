extends Control
## Inventory as an A.S.R.A. field terminal (TAB): an amber CRT readout laid over the live camera
## feed, a little smaller than the screen (WINDOW_SCALE) so the corridor still shows around it.
## Down the left: icon vitals (POWER / STAMINA / SANITY / TIME) with segmented bars, then the
## carried items as `INV:` rows with a stack gauge, the selection and the torch's battery
## estimate. On the right, a tabbed sheet: [F1] ITEMS (the selected item's record), [F2] DOSSIER (the
## level's threshold dossier and which of its anomalies are logged, from Archive,
## scripts/GameLogicEngine/asra_archive.gd), [F3] ENTRIES (every catalogued entity: pick one with
## the arrows or a click and read its full entry; new ones are marked until opened) and [F4] PAPERS
## (recovered lore).
## Everything is drawn into a SubViewport and composited through shaders/ui_vhs_overlay.gdshader
## (a mild corner-fitted CRT curve, scanlines, grain, tear glitch); mouse input is pushed through the
## same warp (_through_lens) so hover and clicks land on what is drawn. Its bright parts glow: two
## half-resolution blur passes (scripts/UI/crt/crt_bloom.gd) that the lens adds back, flickering like
## a tired tube (crt_flicker.gd). The HUD's scanner reticle and toast share both (crt_layer.gd).
## Sounds are synthesized by tools/gen_terminal_audio.py (audio/terminal/): a relay and static on
## power on / off, a key switch on page switches (which also lift the tab and type the page in behind
## a scan line), a lighter tick on item / entry selection.
## Toggled with TAB (scripts/GameLogicEngine/main.gd -> hud.gd set_inventory), closed by TAB / ESC
## or a click outside the window; arrows, F1-F4 and PgUp/PgDn navigate while it is up.
## Empty by default: scripts/World/props pickups can call add_item() / add_lore() to populate it.

signal close_requested

const PlayerScript := preload("res://scripts/Player/player.gd")
const CrtBloom := preload("res://scripts/UI/crt/crt_bloom.gd")
const CrtFlicker := preload("res://scripts/UI/crt/crt_flicker.gd")

# amber phosphor palette; low / critical states match the HUD meters (hud.gd _set_meter)
const AMBER := Color("e8b64a")
const AMBER_DIM := Color(0.91, 0.714, 0.29, 0.38)
const TEXT := Color("f2e6b8")
const TEXT_DIM := Color(0.949, 0.902, 0.722, 0.5)
const MUTED := Color("b3a57a")
const GREEN := Color("5de08f")
const ORANGE := Color("e59d3a")
const RED := Color("ff4636")
const FILL := Color(0.035, 0.028, 0.014, 0.8)

# layout, in the 1920x1080 canvas (stretch mode canvas_items / expand, so width/height only grow)
const FRAME_INSET := 28.0        # rounded screen border, from the edges
const COL_X := 92.0              # left column: vitals, then the item list
const COL_W := 580.0
const PANEL_W := 830.0           # right-hand tabbed sheet; the middle stays clear for the view
const PANEL_RIGHT := 92.0
const TOP := 118.0
const BOTTOM := 92.0
const ICON_BOX := 84.0
const BAR_H := 36.0
const BAR_SEGMENTS := 20
const TAB_H := 50.0
const TAB_SLANT := 24.0
const CHAMFER := 10.0
const LENS_CURVE := 0.04         # CRT bulge: ui_vhs_overlay `distortion`, corner-fitted
const LINE := 6                  # outline weight: boxes, bars, the sheet and its tabs (shown x WINDOW_SCALE)
const FRAME_LINE := 5            # the rounded screen border
const WINDOW_SCALE := 0.86       # the terminal is laid out for the full canvas, then shown this size
const BLOOM := 1               # phosphor glow strength (ui_vhs_overlay bloom_amt)
const BLOOM_RADIUS := 11.0       # how far the glow reaches, in screen pixels at 1080p
# (BLOOM / BLOOM_RADIUS also drive the HUD's glowing scanner and toast; the flicker's timing is in
# scripts/UI/crt/crt_flicker.gd)
# terminal_<name>.wav -> volume_db (ui_click.wav plays at -6 dB in the menus)
const SFX := {"on": -14.0, "off": -15.0, "tab": -14.0, "select": -16.0}

const SLOT_COUNT := 8            # item kinds carried at once
const STACK_CELLS := 8           # widest stack gauge on an INV row
const ARCHIVE_CAP := 10
const TAPE_SECONDS := 3600.0     # TIME meter: tape left on a one-hour cassette, run off Game.time
const TABS := ["ITEMS", "DOSSIER", "ENTRIES", "PAPERS"]
# short, so four fit on the sheet; the dossier page carries its full title
const TAB_TITLES := {"ITEMS": "[F1] ITEMS", "DOSSIER": "[F2] DOSSIER", "ENTRIES": "[F3] ENTRIES", "PAPERS": "[F4] PAPERS"}
const TAB_KEYS := {KEY_F1: "ITEMS", KEY_F2: "DOSSIER", KEY_F3: "ENTRIES", KEY_F4: "PAPERS"}
const METRICS := {
	"spatial_reliability": "SPATIAL RELIABILITY",
	"temporal_coherence": "TEMPORAL COHERENCE",
	"cognitive_decay": "COGNITIVE DECAY",
	"atmosphere_substratum": "SUBSTRATUM",
}

var font: FontFile = load("res://fonts/vcr.ttf")
var font_cache := {}                 # glyph spacing -> FontVariation
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
var stats := {}                      # key -> {icon, value, cells, shown}
var link_label: Label
var link_state := ""

# items
var items: Array = []                # {id, name, desc, count, code, stack}
var selected := -1
var item_rows: VBoxContainer
var row_nodes: Array = []            # one PanelContainer per item, rebuilt by _refresh_items()
var link_nodes: Array = []           # dossier phenomena rows: a click opens their entry
var selected_label: Label
var battery_label: Label

# right-hand sheet
var readout: Control
var tabs_row: HBoxContainer
var tab_buttons := {}                # tab -> Button
var pages := {}                      # tab -> page Control
var page_scrolls := {}               # tab -> its ScrollContainer (PgUp / PgDn)
var active_page := "DOSSIER"
var tab_lift := 1.0                  # 0..1: the active tab rising out of the row after a switch
var scan_t := -1.0                   # 0..1 down the sheet while a page redraws, < 0 off
var scan_overlay: Control
var item_page: VBoxContainer
var dossier_text: VBoxContainer
var phenomena_title: Label
var phenomena_list: VBoxContainer
# [F3] ENTRIES
var entries_title: Label
var entries_list: VBoxContainer
var entry_detail: VBoxContainer
var entry_ids: Array = []            # every catalogued entity, in code order
var entry_rows: Array = []           # one PanelContainer per entry
var entry_sel := 0
var lore_entries: Array = []         # {id, title, text}
var papers_list: VBoxContainer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build()
	Archive.entity_discovered.connect(_on_entry_logged)
	get_viewport().size_changed.connect(_fit_viewport)

# ---- helpers ------------------------------------------------------------------
func _font(spacing: float) -> FontVariation:
	var key := int(spacing)
	if not font_cache.has(key):
		var fv := FontVariation.new()
		fv.base_font = font
		fv.spacing_glyph = key
		fv.variation_embolden = 0.4
		font_cache[key] = fv
	return font_cache[key]

## VCR OSD Mono has no em/en dash or multiplication sign; anything it lacks would drop to another
## font mid-line, so archive text is folded onto glyphs it does have
func _vcr(s: String) -> String:
	return s.replace("—", "-").replace("–", "-").replace("×", "x")

func _label(text: String, px: int, color: Color, spacing := 1.0, wrap := false) -> Label:
	var l := Label.new()
	l.text = _vcr(text)
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING   # type-in keeps the wrapping
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

func _box(fill: Color, border := Color(0, 0, 0, 0), width := 0, radius := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	return sb

func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s

func _hline(color: Color, h: float) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.custom_minimum_size = Vector2(0, h)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

func _clear(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()

## Scroll area with a thin amber bar, as on the concept sheet
func _scroll() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var bar := s.get_v_scroll_bar()
	bar.custom_minimum_size.x = 12
	bar.add_theme_stylebox_override("scroll", _box(Color(0, 0, 0, 0.35), AMBER_DIM, 2))
	bar.add_theme_stylebox_override("scroll_focus", _box(Color(0, 0, 0, 0.35), AMBER_DIM, 2))
	bar.add_theme_stylebox_override("grabber", _box(Color(AMBER, 0.7)))
	bar.add_theme_stylebox_override("grabber_highlight", _box(AMBER))
	bar.add_theme_stylebox_override("grabber_pressed", _box(AMBER))
	return s

## The VBox a _scroll() holds, kept clear of its bar
func _scroll_body(scroll: ScrollContainer, gap: int) -> VBoxContainer:
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_theme_constant_override("margin_right", 18)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", gap)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(v)
	return v

## Segmented gauge: `filled` of `n` cells lit in `color` (metadata, set through _set_cells). The
## rest are a faint ghost of the same colour, or with `dots` a small square each (the INV rows'
## ". . . .").
func _cells(n: int, gap: float, dots: bool) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.set_meta("filled", 0)
	c.set_meta("color", AMBER)
	c.draw.connect(func():
		var filled: int = c.get_meta("filled")
		var col: Color = c.get_meta("color")
		var w := (c.size.x - gap * (n - 1)) / n
		var h := c.size.y
		for i in n:
			var x := i * (w + gap)
			if i < filled:
				if dots: c.draw_rect(Rect2(x, h * 0.14, w, h * 0.72), col)
				else: c.draw_rect(Rect2(x, 0, w, h), col)
			elif dots:
				var d := minf(w, h) * 0.26
				c.draw_rect(Rect2(x + (w - d) * 0.5, h * 0.86 - d, d, d), Color(col, 0.6))
			else:
				c.draw_rect(Rect2(x, 0, w, h), Color(col, 0.07))
	)
	return c

func _set_cells(c: Control, filled: int, col: Color) -> void:
	if c.get_meta("filled") == filled and c.get_meta("color") == col:
		return
	c.set_meta("filled", filled)
	c.set_meta("color", col)
	c.queue_redraw()

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
	overlay_mat.set_shader_parameter("chroma_amt", 0.004)
	overlay_mat.set_shader_parameter("scan_amt", 0.16)
	overlay_mat.set_shader_parameter("grain_amt", 0.05)
	overlay_mat.set_shader_parameter("vignette_amt", 0.22)
	lens.material = overlay_mat
	lens.scale = Vector2.ONE * WINDOW_SCALE   # about pivot_offset, the centre (_fit_viewport)
	content_root.add_child(lens)

	# Bloom, like phosphor on a CRT: the terminal's bright parts (lines, bar segments, icons, text)
	# blurred horizontally then vertically at half resolution; the lens adds the result back through
	# the same warp, so the glow spills onto the dark panels and the view around them
	bloom = CrtBloom.new(content_root, viewport.get_texture())
	overlay_mat.set_shader_parameter("bloom_tex", bloom.texture())
	overlay_mat.set_shader_parameter("bloom_amt", BLOOM)

	var screen := Control.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(screen)
	screen.add_child(_build_frame())
	screen.add_child(_build_header())
	screen.add_child(_build_vitals())
	screen.add_child(_build_items())
	screen.add_child(_build_readout())
	screen.add_child(_build_footer())

	for n in SFX:
		var sp := AudioStreamPlayer.new()
		sp.stream = load("res://audio/terminal/terminal_%s.wav" % n)
		sp.volume_db = SFX[n]
		add_child(sp)
		sfx[n] = sp

	_fit_viewport()
	_select_tab(active_page, true)
	_refresh_items()
	_refresh_dossier()
	_refresh_entries()
	_refresh_papers()

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
		for c in clickables + row_nodes + link_nodes + entry_rows:
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

## The rounded CRT border around the whole readout
func _build_frame() -> Control:
	var f := Panel.new()
	f.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	f.offset_left = FRAME_INSET; f.offset_top = FRAME_INSET
	f.offset_right = -FRAME_INSET; f.offset_bottom = -FRAME_INSET
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.add_theme_stylebox_override("panel", _box(Color(0.03, 0.024, 0.01, 0.22), Color(AMBER, 0.85), FRAME_LINE, 16))
	return f

func _build_header() -> Control:
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	h.offset_left = FRAME_INSET + 30; h.offset_right = -FRAME_INSET - 30
	h.offset_top = FRAME_INSET + 14; h.offset_bottom = FRAME_INSET + 44
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := _label("A.S.R.A. FIELD TERMINAL // MK-IV BIOS v2.11", 19, MUTED, 2)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(title)
	h.add_child(_label("LINK STATUS: ", 19, MUTED, 2))
	link_label = _label("STABLE", 19, GREEN, 2)
	h.add_child(link_label)
	return h

func _build_footer() -> Control:
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	h.offset_left = FRAME_INSET + 30; h.offset_right = -FRAME_INSET - 30
	h.offset_top = -FRAME_INSET - 42; h.offset_bottom = -FRAME_INSET - 14
	h.alignment = BoxContainer.ALIGNMENT_END
	h.add_theme_constant_override("separation", 14)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for hint in ["UP/DN SELECT", "F1-F4 PAGE", "PGUP/PGDN SCROLL"]:
		h.add_child(_label(hint, 17, MUTED, 2))
		h.add_child(_label("•", 17, MUTED))
	var close := Button.new()
	close.text = "TAB // CLOSE"
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	var sb := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		close.add_theme_stylebox_override(s, sb)
	close.add_theme_font_override("font", _font(2))
	close.add_theme_font_size_override("font_size", 17)
	close.add_theme_color_override("font_color", MUTED)
	close.add_theme_color_override("font_hover_color", TEXT)
	close.add_theme_color_override("font_pressed_color", TEXT)
	close.pressed.connect(func(): close_requested.emit())
	clickables.append(close)
	h.add_child(close)
	return h

# ---- vitals: POWER / STAMINA / SANITY / TIME, live off the player -----------------
func _build_vitals() -> Control:
	var v := VBoxContainer.new()
	v.position = Vector2(COL_X, TOP)
	v.custom_minimum_size = Vector2(COL_W, 0)
	v.add_theme_constant_override("separation", 30)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_stat_row("POWER", "res://textures/ui/terminal_battery.png"))
	v.add_child(_stat_row("STAMINA", "res://textures/ui/terminal_stamina.png"))
	v.add_child(_stat_row("SANITY", "res://textures/ui/terminal_sanity.png"))
	v.add_child(_stat_row("TIME", "res://textures/ui/terminal_time.png"))
	return v

## Icon in a bordered square, then the name / percentage over a segmented bar. The icons are white
## alpha masks (textures/ui/terminal_*.png), tinted here so they follow the bar's state colour.
func _stat_row(key: String, icon_path: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var box := PanelContainer.new()
	var sb := _box(FILL, AMBER, LINE, 6)
	sb.set_content_margin_all(14)
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
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := _label(key, 26, TEXT, 3)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta.add_child(title)
	var val := _label("100%", 26, TEXT, 2)
	meta.add_child(val)
	col.add_child(meta)
	var bar := PanelContainer.new()
	var bsb := _box(FILL, AMBER, LINE, 4)
	bsb.set_content_margin_all(6)
	bar.add_theme_stylebox_override("panel", bsb)
	bar.custom_minimum_size = Vector2(0, BAR_H)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cells := _cells(BAR_SEGMENTS, 4.0, false)
	bar.add_child(cells)
	col.add_child(bar)
	row.add_child(col)

	stats[key] = {"icon": icon, "value": val, "cells": cells, "shown": -1.0}
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
		"low": col = ORANGE
		"critical":
			col = Color(RED, pulse)
			txt = RED
	_set_cells(s.cells, clampi(ceili(eased / 100.0 * BAR_SEGMENTS - 0.01), 0, BAR_SEGMENTS), col)
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
		link_label.text = state
		var col := GREEN
		if state == "UNSTABLE": col = ORANGE
		elif state == "DEGRADED": col = RED
		link_label.add_theme_color_override("font_color", col)
	link_label.modulate.a = (1.0 if fmod(t, 0.5) < 0.3 else 0.25) if state == "DEGRADED" else 1.0

# ---- items: INV rows with a stack gauge, selection, battery estimate ---------------
func _build_items() -> Control:
	var v := VBoxContainer.new()
	v.anchor_top = 1.0; v.anchor_bottom = 1.0
	v.offset_left = COL_X; v.offset_right = COL_X + COL_W
	v.offset_top = -BOTTOM; v.offset_bottom = -BOTTOM
	v.grow_vertical = Control.GROW_DIRECTION_BEGIN
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item_rows = VBoxContainer.new()
	item_rows.add_theme_constant_override("separation", 4)
	item_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(item_rows)
	v.add_child(_spacer(10))
	selected_label = _label("SELECTED: [NONE]", 24, TEXT, 1)
	selected_label.clip_text = true
	selected_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(selected_label)
	battery_label = _label("BATTERY LIFE: 100%", 24, TEXT, 1)
	v.add_child(battery_label)
	return v

func _refresh_items() -> void:
	if not item_rows:
		return
	_clear(item_rows)
	row_nodes.clear()
	if items.is_empty():
		item_rows.add_child(_label("INV: ---- [ NO ITEMS CARRIED ]", 24, TEXT_DIM, 1))
	for i in items.size():
		var row := _item_row(i)
		item_rows.add_child(row)
		row_nodes.append(row)
	_refresh_selection()

## "INV: ALM  [> ▮▮▮ . . . . . ]": code, then one cell per unit up to the item's stack size
func _item_row(i: int) -> Control:
	var it: Dictionary = items[i]
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_meta("hover", false)
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			var quiet := active_page != "ITEMS"   # the page switch plays its own chirp
			_select(i, quiet)
			_select_tab("ITEMS")
	)
	p.mouse_entered.connect(func(): p.set_meta("hover", true); _style_row(i))
	p.mouse_exited.connect(func(): p.set_meta("hover", false); _style_row(i))

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var labels := [
		_label("INV: " + str(it.code).rpad(4), 24, TEXT, 1),
		_label("[>", 24, TEXT, 1),
		_label("]", 24, TEXT, 1),
	]
	var n := mini(it.stack, STACK_CELLS)
	var cells := _cells(n, 6.0, true)
	cells.custom_minimum_size = Vector2(26 * n, 0)
	cells.set_meta("filled", mini(it.count, n))
	h.add_child(labels[0])
	h.add_child(labels[1])
	h.add_child(cells)
	h.add_child(labels[2])
	p.add_child(h)
	p.set_meta("labels", labels)
	return p

func _style_row(i: int) -> void:
	if i >= row_nodes.size():
		return
	var p: PanelContainer = row_nodes[i]
	var sel := i == selected
	var bg := Color(0, 0, 0, 0)
	if sel: bg = Color(AMBER, 0.16)
	elif p.get_meta("hover"): bg = Color(AMBER, 0.07)
	var sb := _box(bg, AMBER)
	sb.border_width_left = LINE + 1 if sel else 0
	sb.content_margin_left = 10; sb.content_margin_right = 10
	sb.content_margin_top = 1; sb.content_margin_bottom = 1
	p.add_theme_stylebox_override("panel", sb)
	for l in p.get_meta("labels"):
		(l as Label).add_theme_color_override("font_color", AMBER if sel else TEXT)

func _refresh_selection() -> void:
	for i in row_nodes.size():
		_style_row(i)
	if selected >= 0 and selected < items.size():
		selected_label.text = _vcr("SELECTED: [%s]" % str(items[selected].name).to_upper())
	else:
		selected_label.text = "SELECTED: [NONE]"
	_refresh_item_page()

## Torch time left at the current drain (player.gd BATTERY_DRAIN, a quarter of it in a power cut)
func _update_battery_line() -> void:
	if not player:
		return
	var bat: float = player.battery
	var txt: String
	if bat <= 0.0:
		txt = "BATTERY LIFE: 0% (DEPLETED)"
	else:
		var drain: float = PlayerScript.BATTERY_DRAIN * (0.25 if player.grid_down else 1.0)
		var secs := int(bat / drain)
		txt = "BATTERY LIFE: %d%% (EST. %d:%02d)" % [int(round(bat)), secs / 60, secs % 60]
	if battery_label.text != txt:
		battery_label.text = txt
		var col := TEXT
		if bat < PlayerScript.BATTERY_CRIT: col = RED
		elif bat < PlayerScript.BATTERY_LOW: col = ORANGE
		battery_label.add_theme_color_override("font_color", col)

func _select(i: int, quiet := false) -> void:
	if i >= items.size():
		return
	if i != selected and not quiet: _sfx("select")
	selected = i
	_refresh_selection()

func _move_selection(delta: int) -> void:
	if items.is_empty():
		return
	_select(clampi(maxi(selected, 0) + delta, 0, items.size() - 1))

# ---- right-hand sheet: [F1] ITEMS / [F2] THRESHOLD DOSSIER / [F3] PAPERS -----------------
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
		b.add_theme_font_override("font", _font(2))
		b.pressed.connect(_select_tab.bind(tab))
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

	var items_scroll := _scroll()
	item_page = _scroll_body(items_scroll, 6)
	pages["ITEMS"] = items_scroll
	page_scrolls["ITEMS"] = items_scroll
	pages["DOSSIER"] = _build_dossier_page()
	pages["ENTRIES"] = _build_entries_page()
	var papers_scroll := _scroll()
	papers_list = _scroll_body(papers_scroll, 8)
	pages["PAPERS"] = papers_scroll
	page_scrolls["PAPERS"] = papers_scroll
	for tab in TABS:
		body.add_child(pages[tab])

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
	for tab in TABS:
		var b: Button = tab_buttons[tab]
		var x0 := tabs_row.position.x + b.position.x
		var x1 := x0 + b.size.x
		var on: bool = tab == active_page
		var y := 8.0 * (1.0 - tab_lift) if on else 8.0
		var shape := PackedVector2Array([Vector2(x0, top), Vector2(x0, y), Vector2(x1 - TAB_SLANT, y), Vector2(x1, top)])
		readout.draw_colored_polygon(shape, FILL if on else Color(FILL, 0.5))
		readout.draw_polyline(shape, AMBER if on else AMBER_DIM, LINE, true)
		if on: gap = Vector2(x0, x1)
		if tab == "ENTRIES" and Archive.has_unread():   # something newly logged and not read yet
			readout.draw_circle(Vector2(x1 - TAB_SLANT - 6.0, y + 10.0), 5.0, AMBER)
	var edge := PackedVector2Array([
		Vector2(gap.y, top), Vector2(w - c, top), Vector2(w, top + c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(c, h), Vector2(0, h - c), Vector2(0, top)])
	if gap.x > 0.5: edge.append(Vector2(gap.x, top))
	readout.draw_polyline(edge, AMBER, LINE, true)

func _style_tab(tab: String) -> void:
	var b: Button = tab_buttons[tab]
	var on := tab == active_page
	b.text = TAB_TITLES[tab]
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = 18
	sb.content_margin_right = 18 + TAB_SLANT
	sb.content_margin_top = 0.0 if on else 8.0
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(s, sb)
	b.add_theme_font_size_override("font_size", 22 if on else 16)
	for s in ["font_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(s, TEXT if on else TEXT_DIM)
	b.add_theme_color_override("font_hover_color", TEXT)

func _select_tab(tab: String, force := false, focus_new := true) -> void:
	if tab == active_page and not force:
		return
	active_page = tab
	for k in pages:
		pages[k].visible = k == tab
	for k in tab_buttons:
		_style_tab(k)
	readout.queue_redraw()
	if tab == "ENTRIES" and focus_new:
		_focus_unread()
	if force:
		return
	_sfx("tab")
	glitch_left = 0.07                        # a short tear on the overlay as the page changes
	if tab_anim: tab_anim.kill()
	tab_anim = create_tween()
	tab_anim.tween_method(_set_tab_lift, 0.0, 1.0, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_reveal_page(tab)

## The page redraws like a terminal screen: it flickers on, a scan line runs down the sheet and each
## line of text types itself in, top to bottom
func _reveal_page(tab: String, delay := 0.0) -> void:
	if page_anim: page_anim.kill()
	var page: Control = pages[tab]
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

func _sfx(n: String) -> void:
	var sp: AudioStreamPlayer = sfx.get(n)
	if sp:
		sp.pitch_scale = randf_range(0.97, 1.03)   # repeats shouldn't sound mechanical
		sp.play()

func _cycle_tab(delta: int) -> void:
	_select_tab(TABS[wrapi(TABS.find(active_page) + delta, 0, TABS.size())])

func _scroll_page(delta: int) -> void:
	var s: ScrollContainer = page_scrolls.get(active_page)
	if s:
		s.scroll_vertical += delta * int(s.size.y * 0.8)

# [F1] the selected item's record
func _refresh_item_page() -> void:
	if not item_page:
		return
	_clear(item_page)
	if selected < 0 or selected >= items.size():
		item_page.add_child(_label("[ITEM RECORD // NO SELECTION]", 21, TEXT, 1))
		item_page.add_child(_spacer(12))
		item_page.add_child(_label("NO ITEMS CARRIED.", 21, TEXT_DIM, 1, true))
		return
	var it: Dictionary = items[selected]
	item_page.add_child(_label("[ITEM RECORD // SLOT %02d OF %02d]" % [selected + 1, SLOT_COUNT], 21, TEXT, 1))
	item_page.add_child(_spacer(12))
	item_page.add_child(_label("DESIGNATION: " + str(it.name).to_upper(), 21, TEXT, 1, true))
	item_page.add_child(_label("CODE: " + str(it.code), 21, TEXT, 1))
	item_page.add_child(_label("QUANTITY: %d / %d" % [it.count, it.stack], 21, TEXT, 1))
	if str(it.desc) != "":
		item_page.add_child(_spacer(12))
		item_page.add_child(_label(str(it.desc), 21, TEXT_DIM, 1, true))

# [F2] level dossier over the logged phenomena. New levels / entities register in
# levels/asra_dossiers.json / levels/asra_entities.json (see the top of asra_archive.gd).
func _build_dossier_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var scroll := _scroll()
	scroll.size_flags_stretch_ratio = 1.6
	dossier_text = _scroll_body(scroll, 4)
	page_scrolls["DOSSIER"] = scroll
	v.add_child(scroll)
	v.add_child(_spacer(12))
	v.add_child(_hline(Color(AMBER, 0.8), LINE))
	v.add_child(_spacer(12))
	phenomena_title = _label("PHENOMENA LOGGED:", 21, TEXT, 1)
	v.add_child(phenomena_title)
	v.add_child(_spacer(10))
	var box := PanelContainer.new()
	var sb := _box(Color(0, 0, 0, 0.3), Color(AMBER, 0.75), LINE, 3)
	sb.content_margin_left = 16; sb.content_margin_right = 6
	sb.content_margin_top = 12; sb.content_margin_bottom = 12
	box.add_theme_stylebox_override("panel", sb)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ps := _scroll()
	phenomena_list = _scroll_body(ps, 16)
	box.add_child(ps)
	v.add_child(box)
	return v

func _refresh_dossier() -> void:
	if not dossier_text:
		return
	var d := Archive.current_dossier()
	var designation := str(d.get("designation", "LEVEL // DESIGNATION PENDING"))
	_clear(dossier_text)
	var sheet_no = d.get("log_sheet", 100 + absi(designation.hash()) % 900)
	dossier_text.add_child(_label("THRESHOLD DOSSIER // LOG SHEET #%s" % str(sheet_no), 21, TEXT, 1))
	dossier_text.add_child(_spacer(14))
	dossier_text.add_child(_label("ZONE: " + designation, 21, TEXT, 1, true))
	dossier_text.add_child(_label("THREAT: <%s>" % str(d.get("threat_classification", "UNDETERMINED")), 21, RED, 1, true))
	dossier_text.add_child(_spacer(14))
	var metrics: Dictionary = d.get("metrics", {})
	for key in METRICS:
		if metrics.has(key):
			dossier_text.add_child(_label("- %s: %s" % [METRICS[key], str(metrics[key])], 21, TEXT, 1, true))
	var directives: Array = d.get("directives", [])
	if not directives.is_empty():
		dossier_text.add_child(_spacer(14))
		dossier_text.add_child(_label("MANDATES:", 21, TEXT, 1))
		for i in directives.size():
			dossier_text.add_child(_label("%d. %s" % [i + 1, str(directives[i])], 21, TEXT, 1, true))

	_clear(phenomena_list)
	link_nodes.clear()
	var ids := Archive.level_entities(Archive.current_level_id())
	var found := 0
	for id in ids:
		if Archive.is_discovered(str(id)): found += 1
		phenomena_list.add_child(_phenomenon(str(id)))
	if ids.is_empty():
		phenomena_list.add_child(_label("NO ANOMALIES CATALOGUED FOR THIS SITE.", 19, TEXT_DIM, 1, true))
	elif found < ids.size():
		# entries only come from the field scanner (scripts/Player/scanner.gd): say how, above them
		var hint := _label("HOLD Q WITH THE FIELD SCANNER ON AN ANOMALY TO LOG IT.", 17, AMBER, 1, true)
		phenomena_list.add_child(hint)
		phenomena_list.move_child(hint, 0)
	if not ids.is_empty():
		phenomena_list.add_child(_label("CLICK AN ENTRY OR PRESS F3 TO READ IT IN FULL.", 15, MUTED, 1, true))
	phenomena_title.text = "PHENOMENA LOGGED: %d/%d" % [found, ids.size()]

## One line per anomaly catalogued for this level: its code and name once it is logged (and the
## protocol to follow), redacted until then. A click opens its full entry on [F3] ENTRIES.
func _phenomenon(id: String) -> Control:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0)))
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_open_entry(id)
	)
	p.mouse_entered.connect(func(): p.add_theme_stylebox_override("panel", _box(Color(AMBER, 0.07))))
	p.mouse_exited.connect(func(): p.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0))))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Archive.is_discovered(id):
		var info := Archive.entity_info(id)
		v.add_child(_label("[CONFIRMED] %s (%s)" % [str(info.get("code", "ASRA-EN-??")), str(info.get("common_name", id)).to_upper()], 19, GREEN, 1, true))
		v.add_child(_label("Protocol: " + str(info.get("directive", "")), 17, TEXT, 1, true))
	else:
		v.add_child(_label("[UNCONFIRMED] NO SCAN ON FILE", 19, TEXT_DIM, 1))
		v.add_child(_redacted(id, 3))
	p.add_child(v)
	link_nodes.append(p)
	return p

## Redaction bars standing in for text not on file yet: the same ones every time for this id
func _redacted(id: String, bars: int) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rng := RandomNumberGenerator.new()
	rng.seed = id.hash() + bars
	for i in bars:
		var bar := ColorRect.new()
		bar.color = Color(TEXT, 0.22)
		bar.custom_minimum_size = Vector2(rng.randi_range(50, 150), 14)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(bar)
	return h

# [F3] every catalogued entity: a list on the left, the chosen entry on the right
func _build_entries_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entries_title = _label("[ANOMALY ENTRIES]", 21, TEXT, 1)
	v.add_child(entries_title)
	v.add_child(_spacer(14))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(row)
	var list_scroll := _scroll()
	list_scroll.custom_minimum_size.x = 250
	entries_list = _scroll_body(list_scroll, 6)
	row.add_child(list_scroll)
	var div := ColorRect.new()
	div.color = Color(AMBER, 0.35)
	div.custom_minimum_size = Vector2(2, 0)
	div.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(div)
	var detail_scroll := _scroll()
	detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entry_detail = _scroll_body(detail_scroll, 6)
	row.add_child(detail_scroll)
	page_scrolls["ENTRIES"] = detail_scroll
	return v

func _refresh_entries() -> void:
	if not entries_list:
		return
	var all := Archive.entities()
	entry_ids = all.keys()
	entry_ids.sort_custom(func(a, b): return str(all[a].get("code", "")) < str(all[b].get("code", "")))
	var logged := 0
	for id in entry_ids:
		if Archive.is_discovered(str(id)): logged += 1
	entries_title.text = "[ANOMALY ENTRIES // %d OF %d LOGGED]" % [logged, entry_ids.size()]
	_clear(entries_list)
	entry_rows.clear()
	for i in entry_ids.size():
		var row := _entry_row(i, str(entry_ids[i]))
		entries_list.add_child(row)
		entry_rows.append(row)
	entry_sel = clampi(entry_sel, 0, maxi(entry_ids.size() - 1, 0))
	for i in entry_rows.size():
		_style_entry_row(i)
	_show_entry()

## A list row: the code (and NEW until it is opened), the name under it; redacted until logged
func _entry_row(i: int, id: String) -> Control:
	var logged := Archive.is_discovered(id)
	var info := Archive.entity_info(id)
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_meta("hover", false)
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select_entry(i)
	)
	p.mouse_entered.connect(func(): p.set_meta("hover", true); _style_entry_row(i))
	p.mouse_exited.connect(func(): p.set_meta("hover", false); _style_entry_row(i))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var code := _label(str(info.get("code", "ASRA-EN-??")) if logged else "ASRA-EN-??", 19, TEXT if logged else TEXT_DIM, 1)
	code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(code)
	var badge := _label("NEW", 15, AMBER, 2)
	badge.visible = Archive.is_unread(id)
	top.add_child(badge)
	v.add_child(top)
	var nm := _label(str(info.get("common_name", id)).to_upper() if logged else "UNREGISTERED", 15, TEXT_DIM, 1)
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(nm)
	p.add_child(v)
	p.set_meta("code", code)
	p.set_meta("badge", badge)
	p.set_meta("logged", logged)
	return p

func _style_entry_row(i: int) -> void:
	if i >= entry_rows.size():
		return
	var p: PanelContainer = entry_rows[i]
	var sel := i == entry_sel
	var bg := Color(0, 0, 0, 0)
	if sel: bg = Color(AMBER, 0.16)
	elif p.get_meta("hover"): bg = Color(AMBER, 0.07)
	var sb := _box(bg, AMBER)
	sb.border_width_left = LINE if sel else 0
	sb.content_margin_left = 12; sb.content_margin_right = 10
	sb.content_margin_top = 5; sb.content_margin_bottom = 5
	p.add_theme_stylebox_override("panel", sb)
	var logged: bool = p.get_meta("logged")
	(p.get_meta("code") as Label).add_theme_color_override("font_color", AMBER if sel else (TEXT if logged else TEXT_DIM))

func _select_entry(i: int, quiet := false) -> void:
	if entry_ids.is_empty():
		return
	i = clampi(i, 0, entry_ids.size() - 1)
	if i != entry_sel and not quiet: _sfx("select")
	entry_sel = i
	for j in entry_rows.size():
		_style_entry_row(j)
	_show_entry()

## [F3] from the dossier's phenomena list: straight to that entity's entry (built before the page
## switch, so it types in with the rest of the page)
func _open_entry(id: String) -> void:
	var i := entry_ids.find(id)
	if i >= 0 and i != entry_sel:
		entry_sel = i
		for j in entry_rows.size():
			_style_entry_row(j)
		_show_entry()
	_select_tab("ENTRIES", false, false)
	_mark_seen()

## The entry on show is no longer new once it has been opened on [F3]
func _mark_seen() -> void:
	if entry_ids.is_empty() or not shown or active_page != "ENTRIES":
		return
	var id := str(entry_ids[entry_sel])
	if Archive.is_discovered(id) and Archive.is_unread(id):
		Archive.mark_read(id)
		(entry_rows[entry_sel].get_meta("badge") as Label).visible = false
		readout.queue_redraw()

## Arriving on [F3] with something new logged: that one first
func _focus_unread() -> void:
	for i in entry_ids.size():
		if Archive.is_unread(str(entry_ids[i])):
			_select_entry(i, true)
			return

func _show_entry() -> void:
	if not entry_detail:
		return
	_clear(entry_detail)
	if entry_ids.is_empty():
		entry_detail.add_child(_label("NO ENTRIES CATALOGUED.", 19, TEXT_DIM, 1))
		return
	var id := str(entry_ids[entry_sel])
	var info := Archive.entity_info(id)
	_mark_seen()
	if Archive.is_discovered(id):
		entry_detail.add_child(_label(str(info.get("code", "ASRA-EN-??")), 26, AMBER, 2))
		entry_detail.add_child(_label(str(info.get("common_name", id)).to_upper(), 21, TEXT, 1, true))
		entry_detail.add_child(_label("THREAT CLASS: " + str(info.get("threat_class", "Undetermined")), 18, RED, 1, true))
		_entry_section("BEHAVIOUR VECTOR", str(info.get("behavior_vector", "")))
		_entry_section("FIELD PROTOCOL", str(info.get("directive", "")))
	else:
		entry_detail.add_child(_label("ASRA-EN-??", 26, TEXT_DIM, 2))
		entry_detail.add_child(_label("UNREGISTERED ANOMALY", 21, TEXT_DIM, 1))
		entry_detail.add_child(_spacer(14))
		for n in [4, 3, 4, 2]:
			entry_detail.add_child(_redacted(id + str(n), n))
		entry_detail.add_child(_spacer(12))
		entry_detail.add_child(_label("NO SCAN ON FILE. HOLD Q WITH THE FIELD SCANNER ON IT TO LOG THIS ENTRY.", 17, AMBER, 1, true))
	var sites := Archive.sites_of(id)
	_entry_section("KNOWN SITES", "\n".join(sites) if not sites.is_empty() else "NONE ON RECORD")
	var when := Archive.logged_info(id)
	if when.has("t"):
		var level_id := str(when.get("level", ""))
		var where := str(Archive.dossiers().get(level_id, {}).get("designation", level_id))
		entry_detail.add_child(_spacer(12))
		entry_detail.add_child(_label("LOGGED %s // %s" % [_local_time(int(when.t)), where], 15, MUTED, 1, true))

func _entry_section(title: String, body: String) -> void:
	entry_detail.add_child(_spacer(12))
	entry_detail.add_child(_label(title, 15, MUTED, 2))
	entry_detail.add_child(_label(body, 18, TEXT, 1, true))

## Unix seconds -> "YYYY-MM-DD HH:MM" on this machine's clock
func _local_time(unix: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(unix + bias)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]

func _on_entry_logged(_id: String) -> void:
	_refresh_dossier()
	_refresh_entries()
	if readout:
		readout.queue_redraw()

# [F4] recovered papers
func _refresh_papers() -> void:
	if not papers_list:
		return
	_clear(papers_list)
	papers_list.add_child(_label("[RECOVERED PAPERS // %d OF %d]" % [lore_entries.size(), ARCHIVE_CAP], 21, TEXT, 1))
	papers_list.add_child(_spacer(12))
	if lore_entries.is_empty():
		papers_list.add_child(_label("NO PAPERS RECOVERED.", 21, TEXT_DIM, 1))
		return
	for i in lore_entries.size():
		var e: Dictionary = lore_entries[i]
		papers_list.add_child(_label("%02d. %s" % [i + 1, str(e.title).to_upper()], 21, AMBER, 1, true))
		if str(e.text) != "":
			papers_list.add_child(_label(str(e.text), 19, TEXT_DIM, 1, true))
		papers_list.add_child(_spacer(10))

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
		_refresh_dossier()
		_refresh_entries()
		_sfx("on")
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
		_sfx("off")
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
				_select_entry(entry_sel + step)
			else:
				_move_selection(step)
		KEY_LEFT: _cycle_tab(-1)
		KEY_RIGHT: _cycle_tab(1)
		KEY_F1, KEY_F2, KEY_F3, KEY_F4: _select_tab(TAB_KEYS[k.physical_keycode])
		KEY_PAGEUP: _scroll_page(-1)
		KEY_PAGEDOWN: _scroll_page(1)
		_: return
	get_viewport().set_input_as_handled()

func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	t += dt
	_update_vitals(dt)
	_update_battery_line()
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
## name); `stack` is the most of this item carried, and its gauge width (up to STACK_CELLS).
func add_item(id: String, title: String, desc: String, count := 1, code := "", stack := STACK_CELLS) -> bool:
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
	items.append({"id": id, "name": title, "desc": desc, "count": mini(count, stack), "code": code.to_upper().left(4), "stack": stack})
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

func add_lore(id: String, title: String, text: String) -> void:
	for e in lore_entries:
		if e.id == id: return
	if lore_entries.size() >= ARCHIVE_CAP: return
	lore_entries.append({"id": id, "title": title, "text": text})
	_refresh_papers()
