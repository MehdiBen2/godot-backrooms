extends Control
## Personal-effects inventory panel, same camcorder OSD look as menu.gd / hud.gd: VCR font,
## cream/amber/red palette, blurred backdrop, viewfinder corner brackets instead of a boxed
## dialog, and a scanline/grain/glitch overlay (shaders/ui_vhs_overlay.gdshader) so it reads as
## a camera readout rather than a stock UI card. Toggled with TAB (scripts/GameLogicEngine/main.gd),
## closed by ESC or a click on the veil like the pause menu.
## Empty by default: scripts/World/props pickups can call add_item() to populate it.

signal close_requested

const SLOT_COUNT := 8
const COLS := 4
const CREAM := Color("e4e1c6")
const TAPE := Color("c9bea0")
const TITLE := Color("d8d3bd")
const HINT := Color("9c9268")
const AMBER := Color("ffc107")
const RED := Color("ff3b30")

var font: FontFile = load("res://fonts/vcr.ttf")
var player: Node                     # set by hud.gd; VITALS reads live stats off it
var shown := false
var fade: Tween
var panel_tween: Tween
var selected := -1
var items: Array = []                # {id, name, desc, color, count}
var slot_nodes: Array = []           # {panel, icon, qty}
var name_label: Label
var desc_label: Label
var qty_label: Label
var count_label: Label
var tag_dot: ColorRect
var content_root: Control
var overlay_mat: ShaderMaterial
var t := 0.0
var glitch_left := 0.0
var next_glitch := 3.0

# tabs
var pages := {}                      # tab name -> page Control
var tab_buttons := {}                # tab name -> Button
var active_page := "ITEMS"
var vitals_labels := {}              # stat name -> value Label

# archive / lore (placeholder tab; scripts/World/props pickups can call add_lore())
const ARCHIVE_CAP := 10
var lore_entries: Array = []         # {id, title, text}
var archive_list: VBoxContainer

# A.S.R.A. Field Archive: level dossier + entity catalog, gated by Archive (asra_archive.gd)
var asra_designation_label: Label
var asra_threat_label: Label
var asra_metrics_box: VBoxContainer
var asra_directives_box: VBoxContainer
var asra_entity_list: VBoxContainer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build()

# ---- helpers ------------------------------------------------------------------
func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	return fv

func _label(text: String, size: int, color: Color, spacing := 1.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _box(fill: Color, border := Color(0, 0, 0, 0), bw := Vector4.ZERO) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.border_width_left = int(bw.x); sb.border_width_top = int(bw.y)
	sb.border_width_right = int(bw.z); sb.border_width_bottom = int(bw.w)
	return sb

func _gradient_rect(h: float, from: Color, to: Color, vertical := false) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, from)
	g.set_color(1, to)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 1 if vertical else 256
	gt.height = 256 if vertical else 1
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1) if vertical else Vector2(1, 0)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.custom_minimum_size = Vector2(1, h) if vertical else Vector2(0, h)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s

## Viewfinder bracket: two short lines meeting at a corner, same motif as the HUD frame
func _corner(anchor: Control.LayoutPreset, x: float, y: float, top: bool, left: bool, len := 22.0, col := Color(1, 0.757, 0.027, 0.55)) -> Control:
	var c := Control.new()
	c.set_anchors_and_offsets_preset(anchor)
	c.offset_left = x; c.offset_top = y; c.offset_right = x + len; c.offset_bottom = y + len
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := ColorRect.new(); h.color = col; h.size = Vector2(len, 2); h.position = Vector2(0, 0 if top else len - 2)
	var v := ColorRect.new(); v.color = col; v.size = Vector2(2, len); v.position = Vector2(0 if left else len - 2, 0)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(h)
	c.add_child(v)
	return c

# ---- layout ---------------------------------------------------------------------
func _build() -> void:
	# Blurred, desaturated backdrop (same shader as the pause menu) with a dark tint over it
	var blur := ColorRect.new()
	var blur_mat := ShaderMaterial.new()
	blur_mat.shader = load("res://shaders/menu_blur.gdshader")
	blur.material = blur_mat
	blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blur.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(blur)

	var veil := ColorRect.new()
	veil.color = Color(0.012, 0.012, 0.008, 0.55)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	veil.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			close_requested.emit())
	add_child(veil)

	# content_root: positioned directly via anchors (not a CenterContainer) so its rect is correct
	# the instant _build() runs, rather than waiting on a container's first deferred sort — the
	# CenterContainer version could read a stale (0,0) position on the very first open and get
	# stuck there. Anchored a little below true centre, clear of the HUD meters at the bottom.
	const PANEL_SIZE := Vector2(800, 342)
	content_root = Control.new()
	content_root.anchor_left = 0.5; content_root.anchor_right = 0.5
	content_root.anchor_top = 0.58; content_root.anchor_bottom = 0.58
	content_root.offset_left = -PANEL_SIZE.x * 0.5; content_root.offset_right = PANEL_SIZE.x * 0.5
	content_root.offset_top = -PANEL_SIZE.y * 0.5; content_root.offset_bottom = PANEL_SIZE.y * 0.5
	content_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(content_root)

	# Render the panel's own controls into a SubViewport so the composite shader below can
	# actually warp them (a barrel/fisheye lens needs to resample pixels, not just tint them).
	# The SubViewportContainer forwards mouse input into it (so the slots stay clickable) but is
	# itself invisible; a TextureRect sampling the same viewport texture draws the distorted
	# result on top — a plain SubViewportContainer.material proved unreliable for this shader.
	var vp_container := SubViewportContainer.new()
	vp_container.stretch = true
	vp_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vp_container.modulate.a = 0.0
	content_root.add_child(vp_container)

	var viewport := SubViewport.new()
	viewport.size = Vector2i(PANEL_SIZE)
	viewport.transparent_bg = true
	viewport.disable_3d = true
	vp_container.add_child(viewport)

	var lens := TextureRect.new()
	lens.texture = viewport.get_texture()
	lens.stretch_mode = TextureRect.STRETCH_SCALE
	lens.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lens.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_mat = ShaderMaterial.new()
	overlay_mat.shader = load("res://shaders/ui_vhs_overlay.gdshader")
	overlay_mat.set_shader_parameter("aspect", PANEL_SIZE.x / PANEL_SIZE.y)
	lens.material = overlay_mat
	content_root.add_child(lens)

	var tint := ColorRect.new()
	tint.color = Color(0.043, 0.035, 0.02, 0.62)
	tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(tint)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 26); margin.add_theme_constant_override("margin_right", 26)
	margin.add_theme_constant_override("margin_top", 18); margin.add_theme_constant_override("margin_bottom", 18)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	margin.add_child(col)

	# --- header: blinking tag dot + title + live slot count ---
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag_dot = ColorRect.new()
	tag_dot.color = AMBER
	tag_dot.custom_minimum_size = Vector2(7, 7)
	var dot_c := CenterContainer.new()
	dot_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot_c.add_child(tag_dot)
	head.add_child(dot_c)
	var htitle := _label("INVENTORY", 16, TITLE, 4)
	htitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(htitle)
	count_label = _label("0/8", 12, HINT, 2)
	count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(count_label)
	col.add_child(head)
	col.add_child(_spacer(10))
	col.add_child(_gradient_rect(1, Color(1, 0.757, 0.027, 0.6), Color(1, 0.757, 0.027, 0.05)))
	col.add_child(_spacer(16))

	# --- row: left-side tab list (like the pause menu's nav), a divider, then the active page ---
	# size_flags_vertical EXPAND_FILL: without it, row (and the divider/page area inside it) would
	# shrink to the tab list's short minimum height instead of filling the panel, leaving the
	# divider line too short next to the taller grid content beside it.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(row)

	row.add_child(_build_tab_bar())

	var vdiv := ColorRect.new()
	vdiv.color = Color(0.9, 0.882, 0.804, 0.12)
	vdiv.custom_minimum_size = Vector2(1, 0)
	vdiv.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vdiv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(vdiv)

	var page_host := Control.new()
	page_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(page_host)

	# --- ITEMS page: slot grid (+ its hint row, left-aligned under it) and the detail pane ---
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 22)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page_host.add_child(body)
	pages["ITEMS"] = body

	var left_col := VBoxContainer.new()
	left_col.add_theme_constant_override("separation", 12)
	left_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var grid := GridContainer.new()
	grid.columns = COLS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	for i in SLOT_COUNT:
		grid.add_child(_build_slot(i))
	left_col.add_child(grid)
	var hints := HBoxContainer.new()
	hints.add_theme_constant_override("separation", 10)
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hint_items := ["ARROWS // SELECT", "TAB // CLOSE"]
	for i in hint_items.size():
		hints.add_child(_label(hint_items[i], 10, HINT, 1.5))
		if i < hint_items.size() - 1: hints.add_child(_label("•", 10, HINT))
	left_col.add_child(hints)
	body.add_child(left_col)

	# Detail pane: a single amber accent line on the left, like the pause menu's side panel —
	# no enclosing box, so it reads as a readout column rather than a nested card
	var detail_wrap := PanelContainer.new()
	var dsb := _box(Color(0, 0, 0, 0), Color(1, 0.757, 0.027, 0.35), Vector4(1, 0, 0, 0))
	dsb.content_margin_left = 16
	detail_wrap.add_theme_stylebox_override("panel", dsb)
	detail_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail_wrap.custom_minimum_size = Vector2(210, 0)
	detail_wrap.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 6)
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_child(_label("SELECTED", 11, Color(0.9, 0.882, 0.804, 0.45), 3))
	var uline := ColorRect.new()
	uline.color = Color(0.9, 0.882, 0.804, 0.12)
	uline.custom_minimum_size = Vector2(0, 1)
	uline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_child(uline)
	detail.add_child(_spacer(8))
	name_label = _label("EMPTY", 15, CREAM, 2)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(name_label)
	detail.add_child(_spacer(6))
	desc_label = _label("", 12, Color(0.9, 0.882, 0.804, 0.6))
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(desc_label)
	detail.add_child(_spacer(6))
	qty_label = _label("", 11, HINT, 2)
	detail.add_child(qty_label)
	detail_wrap.add_child(detail)
	body.add_child(detail_wrap)

	# --- VITALS page: live readout off the player, same numbers the HUD meters show ---
	var vitals_page := _build_vitals_page()
	vitals_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vitals_page.visible = false
	page_host.add_child(vitals_page)
	pages["VITALS"] = vitals_page

	# --- ARCHIVE page: recovered lore/papers — placeholder until a pickup system exists ---
	var archive_page := _build_archive_page()
	archive_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	archive_page.visible = false
	page_host.add_child(archive_page)
	pages["ARCHIVE"] = archive_page

	# --- A.S.R.A. page: clinical level dossier + gated entity catalog ---
	var asra_page := _build_asra_page()
	asra_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	asra_page.visible = false
	page_host.add_child(asra_page)
	pages["A.S.R.A."] = asra_page
	Archive.entity_discovered.connect(func(_id: String): _refresh_asra())

	for n in tab_buttons: _style_tab(n)

	# Corner brackets, rendered into the viewport too so the lens warps them along with everything else
	viewport.add_child(_corner(Control.PRESET_TOP_LEFT, 6, 6, true, true))
	viewport.add_child(_corner(Control.PRESET_TOP_RIGHT, -6 - 22, 6, true, false))
	viewport.add_child(_corner(Control.PRESET_BOTTOM_LEFT, 6, -6 - 22, false, true))
	viewport.add_child(_corner(Control.PRESET_BOTTOM_RIGHT, -6 - 22, -6 - 22, false, false))

	_refresh()

# ---- tabs -------------------------------------------------------------------------
func _build_tab_bar() -> VBoxContainer:
	var bar := VBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	bar.custom_minimum_size = Vector2(96, 0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for tab in ["ITEMS", "VITALS", "ARCHIVE", "A.S.R.A."]:
		var b := _tab_button(tab)
		b.pressed.connect(_select_tab.bind(tab))
		tab_buttons[tab] = b
		bar.add_child(b)
	return bar

func _tab_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", _font(3))
	b.add_theme_font_size_override("font_size", 12)
	b.custom_minimum_size = Vector2(0, 28)
	return b

func _style_tab(name: String) -> void:
	var b: Button = tab_buttons[name]
	var active: bool = name == active_page
	var sb := _box(Color(0, 0, 0, 0), RED if active else Color(0.9, 0.882, 0.804, 0.12), Vector4(2, 0, 0, 0))
	sb.content_margin_left = 12
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(s, sb)
	b.add_theme_color_override("font_color", CREAM if active else Color(0.9, 0.882, 0.804, 0.45))
	b.add_theme_color_override("font_hover_color", CREAM)

func _select_tab(name: String) -> void:
	if active_page == name: return
	active_page = name
	for n in pages: pages[n].visible = (n == name)
	for n in tab_buttons: _style_tab(n)
	_refresh_header_count()
	if name == "VITALS": _refresh_vitals()
	elif name == "A.S.R.A.": _refresh_asra()

func _refresh_header_count() -> void:
	if not count_label: return
	match active_page:
		"ITEMS": count_label.text = "%d/%d" % [items.size(), SLOT_COUNT]
		"ARCHIVE": count_label.text = "%d/%d" % [lore_entries.size(), ARCHIVE_CAP]
		"A.S.R.A.":
			var ids: Array = Archive.current_dossier().get("entities", [])
			var found := 0
			for id in ids:
				if Archive.is_discovered(str(id)): found += 1
			count_label.text = "%d/%d" % [found, ids.size()]
		_: count_label.text = ""

# ---- VITALS page: live stats off the player, same numbers the HUD meters already show ----
func _build_vitals_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_label("VITALS", 11, Color(0.9, 0.882, 0.804, 0.45), 3))
	var line := ColorRect.new()
	line.color = Color(0.9, 0.882, 0.804, 0.12)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(line)
	v.add_child(_spacer(8))
	for stat in ["SANITY", "STAMINA", "HEALTH", "BATTERY"]:
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var n := _label(stat, 12, Color(0.9, 0.882, 0.804, 0.7), 2)
		n.custom_minimum_size = Vector2(120, 0)
		row.add_child(n)
		var val := _label("—", 12, CREAM, 1)
		vitals_labels[stat] = val
		row.add_child(val)
		v.add_child(row)
	return v

func _refresh_vitals() -> void:
	if not player: return
	if vitals_labels.has("SANITY"): vitals_labels["SANITY"].text = "%d%%" % int(round(player.sanity))
	if vitals_labels.has("STAMINA"): vitals_labels["STAMINA"].text = "%d%%" % int(round(player.stamina))
	if vitals_labels.has("HEALTH"): vitals_labels["HEALTH"].text = "%d%%" % int(round(player.health))
	if vitals_labels.has("BATTERY"): vitals_labels["BATTERY"].text = "%d%%" % int(round(player.battery))

# ---- ARCHIVE page: recovered lore/papers — placeholder until a pickup system exists ----
func _build_archive_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_label("ARCHIVE PAPERS", 11, Color(0.9, 0.882, 0.804, 0.45), 3))
	var line := ColorRect.new()
	line.color = Color(0.9, 0.882, 0.804, 0.12)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(line)
	v.add_child(_spacer(10))
	archive_list = VBoxContainer.new()
	archive_list.add_theme_constant_override("separation", 6)
	archive_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(archive_list)
	_refresh_archive()
	return v

func _refresh_archive() -> void:
	if not archive_list: return
	for c in archive_list.get_children(): c.queue_free()
	if lore_entries.is_empty():
		archive_list.add_child(_label("NO ENTRIES RECOVERED", 12, Color(0.9, 0.882, 0.804, 0.35), 2))
	else:
		for e in lore_entries:
			archive_list.add_child(_label(str(e.title).to_upper(), 12, CREAM, 1))
	_refresh_header_count()

## World/props pickups can call this once a real archive-paper pickup exists
func add_lore(id: String, title: String, text: String) -> void:
	for e in lore_entries:
		if e.id == id: return
	if lore_entries.size() >= ARCHIVE_CAP: return
	lore_entries.append({"id": id, "title": title, "text": text})
	_refresh_archive()

# ---- A.S.R.A. page: clinical level dossier + entity catalog, gated by Archive (asra_archive.gd) ----
# New levels/entities register in levels/asra_dossiers.json / levels/asra_entities.json — see the
# comment at the top of scripts/GameLogicEngine/asra_archive.gd for where discovery is fired from.
func _build_asra_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)

	asra_designation_label = _label("LEVEL // DESIGNATION PENDING", 12, CREAM, 2)
	asra_designation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(asra_designation_label)
	asra_threat_label = _label("THREAT CLASSIFICATION: UNDETERMINED", 10, RED, 1.5)
	v.add_child(asra_threat_label)
	var line := ColorRect.new()
	line.color = Color(0.9, 0.882, 0.804, 0.12)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_spacer(6))
	v.add_child(line)
	v.add_child(_spacer(8))

	asra_metrics_box = VBoxContainer.new()
	asra_metrics_box.add_theme_constant_override("separation", 3)
	asra_metrics_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(asra_metrics_box)
	v.add_child(_spacer(8))

	asra_directives_box = VBoxContainer.new()
	asra_directives_box.add_theme_constant_override("separation", 2)
	asra_directives_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(asra_directives_box)
	v.add_child(_spacer(10))

	v.add_child(_label("ASSOCIATED ANOMALIES", 10, Color(0.9, 0.882, 0.804, 0.45), 3))
	var line2 := ColorRect.new()
	line2.color = Color(0.9, 0.882, 0.804, 0.12)
	line2.custom_minimum_size = Vector2(0, 1)
	line2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(line2)
	v.add_child(_spacer(6))
	asra_entity_list = VBoxContainer.new()
	asra_entity_list.add_theme_constant_override("separation", 8)
	asra_entity_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(asra_entity_list)

	_refresh_asra()
	return scroll

func _refresh_asra() -> void:
	if not asra_designation_label: return
	var d := Archive.current_dossier()
	asra_designation_label.text = str(d.get("designation", "LEVEL // DESIGNATION PENDING"))
	asra_threat_label.text = "THREAT CLASSIFICATION: %s" % str(d.get("threat_classification", "UNDETERMINED"))

	for c in asra_metrics_box.get_children(): c.queue_free()
	var metrics: Dictionary = d.get("metrics", {})
	var metric_labels := {
		"spatial_reliability": "SPATIAL RELIABILITY",
		"temporal_coherence": "TEMPORAL COHERENCE",
		"cognitive_decay": "COGNITIVE DECAY",
		"atmosphere_substratum": "SUBSTRATUM",
	}
	for key in ["spatial_reliability", "temporal_coherence", "cognitive_decay", "atmosphere_substratum"]:
		if not metrics.has(key): continue
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var n := _label(str(metric_labels[key]), 9, Color(0.9, 0.882, 0.804, 0.5), 1.5)
		n.custom_minimum_size = Vector2(118, 0)
		row.add_child(n)
		var val := _label(str(metrics[key]), 9, TAPE, 0.5)
		val.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(val)
		asra_metrics_box.add_child(row)

	for c in asra_directives_box.get_children(): c.queue_free()
	asra_directives_box.add_child(_label("FIELD DIRECTIVES", 9, Color(0.9, 0.882, 0.804, 0.4), 2))
	for dtext in d.get("directives", []):
		var l := _label("— " + str(dtext), 10, HINT, 0.5)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		asra_directives_box.add_child(l)

	for c in asra_entity_list.get_children(): c.queue_free()
	var entity_ids: Array = d.get("entities", [])
	if entity_ids.is_empty():
		asra_entity_list.add_child(_label("NO ANOMALIES CATALOGUED FOR THIS SITE", 10, Color(0.9, 0.882, 0.804, 0.35), 1))
	else:
		for id in entity_ids:
			asra_entity_list.add_child(_build_asra_entity_entry(str(id)))
	_refresh_header_count()

## Discovered: full profile off Archive.entity_info(). Undiscovered: redacted placeholder — the
## dossier lists that something is catalogued here without saying what until the player sees it.
func _build_asra_entity_entry(id: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Archive.is_discovered(id):
		var info := Archive.entity_info(id)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		head.add_child(_label(str(info.get("code", "ASRA-EN-??")), 10, AMBER, 1))
		head.add_child(_label(str(info.get("common_name", id)).to_upper(), 11, CREAM, 1))
		box.add_child(head)
		var cls := _label(str(info.get("threat_class", "UNDETERMINED")), 9, RED, 1)
		box.add_child(cls)
		var vec := _label("VECTOR // " + str(info.get("behavior_vector", "")), 9, TAPE, 0.5)
		vec.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(vec)
		var dir := _label("DIRECTIVE // " + str(info.get("directive", "")), 9, HINT, 0.5)
		dir.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(dir)
	else:
		box.add_child(_label("[UNREGISTERED ANOMALY // NO DIRECT SIGHTING]", 10, Color(0.9, 0.882, 0.804, 0.3), 1))
		box.add_child(_label("████████████ ████ ██████████", 9, Color(0.9, 0.882, 0.804, 0.15), 1))
	return box

func _build_slot(i: int) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(86, 86)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select(i))
	p.mouse_entered.connect(func(): _style_slot(i, true))
	p.mouse_exited.connect(func(): _style_slot(i, false))

	var inner := VBoxContainer.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_constant_override("separation", 4)

	var idx := _label("%02d" % (i + 1), 9, Color(0.9, 0.882, 0.804, 0.3), 1)
	inner.add_child(idx)

	var icon_c := CenterContainer.new()
	icon_c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	icon_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := ColorRect.new()
	icon.custom_minimum_size = Vector2(24, 24)
	icon.color = Color(0, 0, 0, 0)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_c.add_child(icon)
	inner.add_child(icon_c)

	var qty := _label("", 10, HINT, 1)
	qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	inner.add_child(qty)

	p.add_child(inner)
	slot_nodes.append({"panel": p, "icon": icon, "qty": qty})
	_style_slot(i, false)
	return p

func _style_slot(i: int, hover: bool) -> void:
	if i >= slot_nodes.size(): return
	var p: PanelContainer = slot_nodes[i].panel
	var has_item := i < items.size()
	var is_sel := i == selected
	var border := Color(0.9, 0.882, 0.804, 0.15)
	if is_sel: border = RED
	elif hover: border = Color(0.9, 0.882, 0.804, 0.4)
	var bg_a := 0.5 if (has_item or is_sel) else 0.28
	p.add_theme_stylebox_override("panel", _box(Color(0.059, 0.047, 0.024, bg_a), border, Vector4(1, 1, 1, 1)))

# ---- state ------------------------------------------------------------------------
func _refresh() -> void:
	for i in SLOT_COUNT:
		var s = slot_nodes[i]
		if i < items.size():
			var it = items[i]
			s.icon.color = it.color
			s.qty.text = ("×%d" % it.count) if it.count > 1 else ""
		else:
			s.icon.color = Color(0, 0, 0, 0)
			s.qty.text = ""
		_style_slot(i, false)
	_refresh_header_count()
	_refresh_detail()

func _refresh_detail() -> void:
	if selected >= 0 and selected < items.size():
		var it = items[selected]
		name_label.text = str(it.name).to_upper()
		desc_label.text = it.desc
		qty_label.text = "×%d" % it.count
	else:
		name_label.text = "EMPTY"
		desc_label.text = ""
		qty_label.text = ""

func _select(i: int) -> void:
	if i >= items.size(): return
	selected = i
	_refresh()

func _move_selection(delta: int) -> void:
	if items.is_empty(): return
	var cur := maxi(selected, 0)
	selected = clampi(cur + delta, 0, items.size() - 1)
	_refresh()

func _unhandled_input(e: InputEvent) -> void:
	if not shown or not (e is InputEventKey) or not e.pressed or e.echo: return
	match e.physical_keycode:
		KEY_LEFT: _move_selection(-1)
		KEY_RIGHT: _move_selection(1)
		KEY_UP: _move_selection(-COLS)
		KEY_DOWN: _move_selection(COLS)

## Power-on: the panel slides up from below into its centred resting spot with a back-ease
## settle while its alpha stutters, and the VHS overlay throws a short tear-glitch burst that
## decays away — same flicker curve as the pause menu's side panel (menu.gd _animate_panel_in
## / _flicker), but sliding like the pause menu itself rather than zooming from the centre.
func set_shown(on: bool) -> void:
	if on == shown:
		return
	shown = on
	if fade: fade.kill()
	if panel_tween: panel_tween.kill()
	fade = create_tween()
	if on:
		visible = true
		if selected == -1 and not items.is_empty(): selected = 0
		_refresh()
		var rest_y := content_root.position.y
		content_root.position.y = rest_y + 90.0
		content_root.modulate.a = 0.0
		panel_tween = create_tween()
		panel_tween.set_parallel(true)
		panel_tween.tween_property(content_root, "position:y", rest_y, 0.36).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		panel_tween.tween_method(func(x: float): content_root.modulate.a = _flicker(x), 0.0, 1.0, 0.34)
		if overlay_mat:
			overlay_mat.set_shader_parameter("glitch", 1.0)
			panel_tween.tween_method(func(x: float): overlay_mat.set_shader_parameter("glitch", x), 1.0, 0.0, 0.55).set_delay(0.05)
	else:
		modulate.a = 1.0
		fade.tween_property(self, "modulate:a", 0.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		fade.tween_callback(func(): visible = false; modulate.a = 1.0)

## Alpha curve for the power-on: dim, blink out, flash, settle (matches menu.gd)
func _flicker(x: float) -> float:
	if x < 0.2: return 0.85 * x / 0.2
	if x < 0.35: return 0.15
	if x < 0.5: return 1.0
	if x < 0.62: return 0.45
	return 1.0

func _process(dt: float) -> void:
	if not is_visible_in_tree(): return
	t += dt
	if tag_dot: tag_dot.color.a = 1.0 if fmod(t, 1.1) < 0.55 else 0.0
	_update_idle_glitch(dt)
	if active_page == "VITALS": _refresh_vitals()

## Every few seconds, a brief tear-glitch burst on the overlay — the tape never sits perfectly
## still, echoing the pause menu's random title glitch (menu.gd _update_glitch)
func _update_idle_glitch(dt: float) -> void:
	if not overlay_mat: return
	if glitch_left > 0.0:
		glitch_left -= dt
		overlay_mat.set_shader_parameter("glitch", 0.35 + 0.35 * sin(t * 70.0))
		if glitch_left <= 0.0:
			overlay_mat.set_shader_parameter("glitch", 0.0)
		return
	next_glitch -= dt
	if next_glitch <= 0.0:
		glitch_left = randf_range(0.05, 0.14)
		next_glitch = randf_range(3.0, 7.0)

# ---- public API: World/props pickups can call these -------------------------------------
func add_item(id: String, name: String, desc: String, color: Color, count := 1) -> void:
	for it in items:
		if it.id == id:
			it.count += count
			_refresh()
			return
	if items.size() >= SLOT_COUNT:
		return
	items.append({"id": id, "name": name, "desc": desc, "color": color, "count": count})
	_refresh()

func remove_item(id: String, count := 1) -> void:
	for i in items.size():
		if items[i].id == id:
			items[i].count -= count
			if items[i].count <= 0:
				items.remove_at(i)
				if selected >= items.size(): selected = items.size() - 1
			_refresh()
			return

func has_item(id: String) -> bool:
	for it in items:
		if it.id == id: return true
	return false
