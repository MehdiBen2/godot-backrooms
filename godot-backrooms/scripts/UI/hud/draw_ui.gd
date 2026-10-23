extends CanvasLayer
## The draw tools panel, for test launches and dev builds (hud.gd builds it when Game.test_level is set or
## Game.dev_keys is on). Y opens and closes it. With it open the mouse cursor is the pen, so tape and
## sketches are drawn with the mouse instead of by aiming the middle of the screen:
##  - TAPE: hold the left button and drag to pull a strip out (tape_tool.gd); click a strip to peel it back
##  - MARKER: hold the left button and drag to draw (sketch_tool.gd), with a colour, width, wobble, opacity,
##    solid / dashed / dotted, and FREEHAND or a straight LINE (hold SHIFT while you drag for a line)
##  - ERASER: hold the left button over a sketch line to rub it out, as wide as the ERASER SIZE slider
##  - STAMP: click to press a scary design on (an eye, a grin, a figure, scratched words ...; scary_stamps.gd),
##    with a size, a rotation and a searchable list of designs
##  - CABLE / PORTAL: 3D cables and the glowing doorways (cable_tool.gd, portal_tool.gd)
## While it is open you fly like noclip (WASD, Space up, C down, Shift fast); hold the right button to look.
## Ctrl+H hides the panel (the pen keeps working, the canvas is clear) and Ctrl+H again brings it back; drag
## its title bar to move it. SAVE writes the tape and the sketches to disk now (they are also written as each
## one is placed).
##
## The panel draws a live preview of the pen (a sample stroke in the current colour, width, wobble and style)
## and a ring follows the mouse in the world showing the line's real width on the surface it will land on
## (draw_cursor.gd). Presets (NEEDLE / FINE / MARKER / FAT / CHALK / SPRAY) set the whole pen in one click.

const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const SketchMarks := preload("res://scripts/World/props/sketch_marks.gd")
const CableMarks := preload("res://scripts/World/props/cable_marks.gd")
const PortalMarks := preload("res://scripts/World/props/portal_marks.gd")
const MarkStore := preload("res://scripts/World/props/mark_store.gd")
const Stamps := preload("res://scripts/World/props/scary_stamps.gd")
const DrawCursor := preload("res://scripts/UI/hud/draw_cursor.gd")

const KEY := KEY_Y
const PANEL_KEY := KEY_H          # Ctrl+H: hide the panel and keep drawing (F1 is the debug console)
const INK := Color("c9bea0")
const DIM := Color(0.62, 0.59, 0.5)
const AMBER := Color("e0a33c")
const PANEL_W := 322.0
const TOOLS := ["tape", "marker", "cable", "eraser", "stamp", "portal"]
const TOOL_NAMES := {"tape": "TAPE", "marker": "MARKER", "cable": "CABLE",
	"eraser": "ERASER", "stamp": "STAMP", "portal": "PORTAL"}
const TIPS := {
	"stamp": "Pick a design, then click a wall, floor or ceiling to press it on. Colour, width and wobble come from the pen.",
	"tape": "Hold the left mouse on a wall or floor and drag to pull tape out; let go to stick it. Click a strip to peel it off.",
	"marker": "Hold the left mouse and drag to draw on a wall, floor or ceiling. Hold SHIFT while you start to draw a straight line.",
	"cable": "Hold left mouse on a floor or wall and drag to lay 3D equipment cables. They roll and stack in 3D piles the more you draw.",
	"eraser": "Hold the left mouse over a sketch line or equipment cable to rub it out. The ERASER SIZE slider sets how wide it rubs.",
	"portal": "Click and drag to draw a portal onto a wall. Release to tear open a glowing void."}
## One click sets the whole pen: width (m), wobble, opacity, style
const PRESETS := [
	{"name": "NEEDLE", "w": 0.006, "wob": 0.15, "op": 1.0, "style": "solid"},
	{"name": "FINE", "w": 0.012, "wob": 0.5, "op": 1.0, "style": "solid"},
	{"name": "MARKER", "w": 0.03, "wob": 1.0, "op": 1.0, "style": "solid"},
	{"name": "FAT", "w": 0.07, "wob": 0.9, "op": 1.0, "style": "solid"},
	{"name": "CHALK", "w": 0.045, "wob": 1.0, "op": 0.6, "style": "dashed"},
	{"name": "SPRAY", "w": 0.08, "wob": 1.0, "op": 0.35, "style": "dotted"},
]

var player                       # player.gd
var tape                         # tape_tool.gd
var sketch                       # sketch_tool.gd
var cable                        # cable_tool.gd
var portal                       # portal_tool.gd

var open := false
var cursor_mode := false         # the mouse is a free cursor (not captured, not looking around)
var tool := "marker"             # tape / marker / cable / eraser / stamp / portal
var world_lmb := false           # the left button is held, and it went down over the world, not the panel

var _panel: PanelContainer
var _body: VBoxContainer
var _head_title: Label
var _pill: Button
var _fold: Button
var _tip: Label
var _counts: Label
var _status: Label
var _recover_btn: Button
var _picker: ColorPickerButton
var _preview                     # PenPreview (the inner class below)
var _stamp_preview                # StampPreview (the inner class below)
var _stamp_search: LineEdit
var _tool_btns := {}
var _marker_box: VBoxContainer
var _eraser_box: VBoxContainer
var _stamp_box: VBoxContainer
var _shape_box: VBoxContainer
var _cable_box: VBoxContainer
var _cable_type_btns := {}
var _cable_shape_btns := {}
var _cable_sliders := {}
var _stamp_btns := {}
var _stamp_names := {}
var _swatches: Array = []
var _sliders := {}
var _style_btns := {}
var _shape_btns := {}
var _clear_btn: Button
var _clear_armed := false
var _clear_cables_btn: Button
var _clear_cables_armed := false
var _rmb_look := false
var _lmb_prev := false
var _lmb_ui := false
var _dragging := false
var _drag_off := Vector2.ZERO
var _syncing := false
var _count_t := 0.0

func _ready() -> void:
	layer = 60
	visible = false
	_build()
	sync_from_tool()

# ---------------------------------------------------------------- building
func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var ring := DrawCursor.new()          # under the panel: the pen's width on the surface
	ring.ui = self
	ring.sketch = sketch
	root.add_child(ring)
	_panel = PanelContainer.new()
	_panel.position = Vector2(16, 70)
	_panel.custom_minimum_size = Vector2(PANEL_W, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.035, 0.038, 0.03, 0.95)
	sb.border_color = Color(0.42, 0.38, 0.3)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(2)
	sb.set_content_margin_all(9)
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().gui_release_focus())
	root.add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	_panel.add_child(v)

	# --- title bar (drag it to move the panel, – folds the body away)
	var head := PanelContainer.new()
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = Color(0.10, 0.10, 0.08, 0.98)
	hsb.border_color = Color(0.32, 0.29, 0.22)
	hsb.border_width_bottom = 1
	hsb.content_margin_left = 6
	hsb.content_margin_right = 4
	hsb.content_margin_top = 3
	hsb.content_margin_bottom = 3
	head.add_theme_stylebox_override("panel", hsb)
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	head.tooltip_text = "Drag to move the panel"
	head.gui_input.connect(_header_input)
	v.add_child(head)
	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", 4)
	head_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(head_row)
	_head_title = _label("DRAW TOOLS", 14, INK)
	_head_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head_row.add_child(_head_title)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head_row.add_child(sp)
	var hide_btn := _button("HIDE", _toggle_panel_visible)
	hide_btn.add_theme_font_size_override("font_size", 10)
	hide_btn.tooltip_text = "Hide the panel and keep drawing (Ctrl+H)"
	head_row.add_child(hide_btn)
	_fold = _button("–", _toggle_fold)
	_fold.add_theme_font_size_override("font_size", 12)
	_fold.custom_minimum_size = Vector2(24, 20)
	_fold.tooltip_text = "Fold the panel"
	head_row.add_child(_fold)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 7)
	v.add_child(_body)

	# --- tools: 3 x 2 so every name fits
	var tools := GridContainer.new()
	tools.columns = 3
	tools.add_theme_constant_override("h_separation", 4)
	tools.add_theme_constant_override("v_separation", 4)
	_body.add_child(tools)
	var group := ButtonGroup.new()
	for i in TOOLS.size():
		var t: String = TOOLS[i]
		var b := _button(TOOL_NAMES[t], func(): _set_tool(t))
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0, 26)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = "%s tool  (Ctrl+%d)" % [TOOL_NAMES[t].capitalize(), i + 1]
		tools.add_child(b)
		_tool_btns[t] = b
	_tool_btns[tool].button_pressed = true
	_tip = _label("", 12, DIM)
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip.custom_minimum_size = Vector2(PANEL_W - 20, 0)
	_body.add_child(_tip)

	# --- the pen (MARKER and STAMP): live preview, presets, colour, size, style
	_marker_box = VBoxContainer.new()
	_marker_box.add_theme_constant_override("separation", 6)
	_body.add_child(_marker_box)
	_preview = PenPreview.new()
	_preview.custom_minimum_size = Vector2(PANEL_W - 20, 54)
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker_box.add_child(_preview)
	var pgrid := GridContainer.new()
	pgrid.columns = 3
	pgrid.add_theme_constant_override("h_separation", 3)
	pgrid.add_theme_constant_override("v_separation", 3)
	_marker_box.add_child(pgrid)
	for p in PRESETS:
		var b := _button(str(p.name), func(): _apply_preset(p))
		b.add_theme_font_size_override("font_size", 10)
		b.clip_text = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = "%.1f cm, wobble %.0f%%, %d%% opacity, %s" % [float(p.w) * 100.0, float(p.wob) * 100.0, float(p.op) * 100.0, str(p.style)]
		pgrid.add_child(b)
	_marker_box.add_child(_label("COLOUR", 11, INK))
	var cgrid := GridContainer.new()
	cgrid.columns = 8
	cgrid.add_theme_constant_override("h_separation", 4)
	_marker_box.add_child(cgrid)
	for i in SketchMarks.COLORS.size():
		var sw := Button.new()
		sw.custom_minimum_size = Vector2(26, 26)
		sw.focus_mode = Control.FOCUS_NONE
		sw.tooltip_text = SketchMarks.COLOR_NAMES[i] + "  (%d)" % (i + 1)
		sw.pressed.connect(func(): _set_colour(i))
		cgrid.add_child(sw)
		_swatches.append(sw)
	_picker = ColorPickerButton.new()
	_picker.edit_alpha = false
	_picker.focus_mode = Control.FOCUS_NONE
	_picker.custom_minimum_size = Vector2(0, 24)
	_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker.tooltip_text = "Any colour the eight swatches don't have"
	_picker.pressed.connect(func(): get_viewport().gui_release_focus())
	_picker.color_changed.connect(func(c: Color):
		if _syncing or sketch == null:
			return
		sketch.color = c
		sync_from_tool())
	_marker_box.add_child(_picker)
	_add_slider("WIDTH", "width", 0.5, 20.0, 0.25, 100.0, " cm")
	_add_slider("WOBBLE", "wobble", 0.0, 1.0, 0.05, 1.0, "")
	_add_slider("OPACITY", "opacity", 0.1, 1.0, 0.05, 1.0, "")
	_marker_box.add_child(_label("STYLE", 11, INK))
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 4)
	_marker_box.add_child(srow)
	var sgroup := ButtonGroup.new()
	for st in SketchMarks.STYLES:
		var b := _button(st.to_upper(), func(): _set_style(st))
		b.toggle_mode = true
		b.button_group = sgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		srow.add_child(b)
		_style_btns[st] = b
	_shape_box = VBoxContainer.new()
	_shape_box.add_theme_constant_override("separation", 4)
	_marker_box.add_child(_shape_box)
	_shape_box.add_child(_label("SHAPE", 11, INK))
	var shape_row := HBoxContainer.new()
	shape_row.add_theme_constant_override("separation", 4)
	_shape_box.add_child(shape_row)
	var hgroup := ButtonGroup.new()
	for sh in ["freehand", "line"]:
		var b := _button(sh.to_upper(), func(): _set_shape(sh))
		b.toggle_mode = true
		b.button_group = hgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		shape_row.add_child(b)
		_shape_btns[sh] = b
	var shint := _label("Hold SHIFT while you start a stroke for a straight line.", 10, DIM)
	shint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_shape_box.add_child(shint)

	# --- eraser
	_eraser_box = VBoxContainer.new()
	_eraser_box.add_theme_constant_override("separation", 6)
	_body.add_child(_eraser_box)
	_eraser_box.add_child(_label("ERASER", 11, INK))
	_add_slider("SIZE", "erase_radius", 3.0, 50.0, 1.0, 100.0, " cm", _eraser_box)
	var ehint := _label("A line within the ring of that size goes; so do cables and portals under it.", 10, DIM)
	ehint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_eraser_box.add_child(ehint)

	# --- stamps: preview of the design, search, the list, size and rotation
	_stamp_box = VBoxContainer.new()
	_stamp_box.add_theme_constant_override("separation", 6)
	_body.add_child(_stamp_box)
	_stamp_preview = StampPreview.new()
	_stamp_preview.custom_minimum_size = Vector2(PANEL_W - 20, 62)
	_stamp_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamp_box.add_child(_stamp_preview)
	_stamp_search = LineEdit.new()
	_stamp_search.placeholder_text = "search designs"
	_stamp_search.clear_button_enabled = true
	_stamp_search.custom_minimum_size = Vector2(0, 24)
	_stamp_search.add_theme_font_size_override("font_size", 11)
	_stamp_search.text_changed.connect(_filter_stamps)
	_stamp_box.add_child(_stamp_search)
	var stgrid := GridContainer.new()
	stgrid.columns = 3
	stgrid.add_theme_constant_override("h_separation", 3)
	stgrid.add_theme_constant_override("v_separation", 3)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(PANEL_W - 20, 150)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_stamp_box.add_child(scroll)
	stgrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(stgrid)
	var stgroup := ButtonGroup.new()
	for d in Stamps.LIST:
		var id: String = d[0]
		var b := _button(d[1], func(): _select_stamp(id))
		b.add_theme_font_size_override("font_size", 10)
		b.clip_text = true
		b.toggle_mode = true
		b.button_group = stgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = d[1]
		stgrid.add_child(b)
		_stamp_btns[id] = b
		_stamp_names[id] = d[1]
	_add_slider("SIZE", "stamp_size", 20.0, 300.0, 5.0, 100.0, " cm", _stamp_box)
	_add_slider("ROTATE", "stamp_rotation", -180.0, 180.0, 5.0, 1.0, "°", _stamp_box, 0)
	var jitter := CheckButton.new()
	jitter.text = "random tilt"
	jitter.button_pressed = true
	jitter.focus_mode = Control.FOCUS_NONE
	jitter.add_theme_font_size_override("font_size", 11)
	jitter.toggled.connect(func(on: bool):
		if sketch != null:
			sketch.stamp_jitter = on)
	_stamp_box.add_child(jitter)
	var surprise := _button("SURPRISE ME", _random_stamp)
	surprise.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stamp_box.add_child(surprise)

	# --- cables
	_cable_box = VBoxContainer.new()
	_cable_box.add_theme_constant_override("separation", 6)
	_body.add_child(_cable_box)
	_cable_box.add_child(_label("CABLE TYPE", 11, INK))
	var type_grid := GridContainer.new()
	type_grid.columns = 3
	type_grid.add_theme_constant_override("h_separation", 3)
	type_grid.add_theme_constant_override("v_separation", 3)
	_cable_box.add_child(type_grid)
	var cgroup := ButtonGroup.new()
	var type_labels := {
		"random": "RANDOM",
		"heavy_black": "BLACK",
		"yellow_ext": "YELLOW",
		"hi_volt_orange": "ORANGE",
		"data_snake": "DATA BLUE",
		"ribbed_conduit": "CONDUIT",
		"hazard_striped": "STRIPED"
	}
	for tk in ["random", "heavy_black", "yellow_ext", "hi_volt_orange", "data_snake", "ribbed_conduit", "hazard_striped"]:
		var b := _button(type_labels[tk], func():
			if cable != null:
				cable.cable_type = tk)
		b.add_theme_font_size_override("font_size", 10)
		b.toggle_mode = true
		b.button_group = cgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		type_grid.add_child(b)
		_cable_type_btns[tk] = b
	_add_cable_slider("GAUGE", "radius", 1.5, 10.0, 0.5, 100.0, " cm", _cable_box)
	_add_cable_slider("ROLL & COIL", "roll_slack", 0.0, 1.0, 0.05, 1.0, "", _cable_box)
	_add_cable_slider("STACK ELEV", "stack_mult", 0.5, 2.5, 0.1, 1.0, "x", _cable_box)
	_cable_box.add_child(_label("SHAPE", 11, INK))
	var chrow := HBoxContainer.new()
	chrow.add_theme_constant_override("separation", 4)
	_cable_box.add_child(chrow)
	var chgroup := ButtonGroup.new()
	for sh in ["freehand", "line"]:
		var b := _button(sh.to_upper(), func():
			if cable != null:
				cable.shape = sh)
		b.toggle_mode = true
		b.button_group = chgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chrow.add_child(b)
		_cable_shape_btns[sh] = b
	_clear_cables_btn = _button("CLEAR CABLES", _clear_cables)
	_clear_cables_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cable_box.add_child(_clear_cables_btn)

	# --- what was done, undo, save
	_body.add_child(HSeparator.new())
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 4)
	_body.add_child(arow)
	var undo := _button("UNDO", _undo)
	undo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	undo.tooltip_text = "Take back the last line, stamp, cable or portal  (Ctrl+Z)"
	arow.add_child(undo)
	var redo := _button("REDO", _redo)
	redo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	redo.tooltip_text = "Put it back  (Ctrl+Y)"
	arow.add_child(redo)
	_clear_btn = _button("CLEAR LINES", _clear)
	_clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_clear_btn)
	_recover_btn = _button("RECOVER CLEARED LINES", _recover)
	_recover_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_recover_btn)
	var save := _button("SAVE", _save)
	save.add_theme_color_override("font_color", Color("2fd968"))
	save.add_theme_color_override("font_hover_color", Color("6dffa0"))
	save.add_theme_color_override("font_pressed_color", Color("2fd968"))
	_body.add_child(save)
	_counts = _label("", 11, DIM)
	_body.add_child(_counts)
	_status = _label("", 12, Color(0.78, 0.74, 0.62))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(PANEL_W - 20, 0)
	_body.add_child(_status)
	var keys := _label("WASD fly · Space up, C down, Shift fast\nRight mouse held: look · Ctrl+H hide panel · Y close\n[ ] width · - = opacity · 1-8 colour · Ctrl+1-6 tool", 10, DIM)
	keys.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	keys.custom_minimum_size = Vector2(PANEL_W - 20, 0)
	_body.add_child(keys)

	# --- the small bar that stands in for the panel while it is hidden (Ctrl+H)
	_pill = _button("DRAW TOOLS  ·  Ctrl+H shows the panel  ·  Y closes", _toggle_panel_visible)
	_pill.position = Vector2(16, 16)
	_pill.visible = false
	_pill.add_theme_font_size_override("font_size", 11)
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color(0.035, 0.038, 0.03, 0.9)
	psb.border_color = AMBER
	psb.set_border_width_all(1)
	psb.content_margin_left = 8
	psb.content_margin_right = 8
	psb.content_margin_top = 4
	psb.content_margin_bottom = 4
	_pill.add_theme_stylebox_override("normal", psb)
	root.add_child(_pill)

	_set_tool(tool)

func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(func():
		get_viewport().gui_release_focus()      # so the stamp search doesn't keep the keys
		cb.call())
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.10, 0.10, 0.08, 0.95)
	normal.border_color = Color(0.30, 0.28, 0.22)
	normal.set_border_width_all(1)
	normal.content_margin_left = 6
	normal.content_margin_right = 6
	normal.content_margin_top = 3
	normal.content_margin_bottom = 3
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.17, 0.16, 0.12, 0.98)
	hover.border_color = AMBER
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.24, 0.20, 0.12, 0.98)
	pressed.border_color = AMBER
	pressed.set_border_width_all(1)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", hover)
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_hover_color", Color(1.0, 0.92, 0.72))
	b.add_theme_color_override("font_pressed_color", Color(1.0, 0.94, 0.78))
	return b

## `dec`: fixed decimals for the readout (-1: one for cm, two for the rest)
func _add_slider(title: String, prop: String, lo: float, hi: float, step: float, scale: float, unit: String,
		box: Control = null, dec := -1) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	(box if box != null else _marker_box).add_child(row)
	var name_l := _label(title, 11, INK)
	name_l.custom_minimum_size = Vector2(62, 0)
	row.add_child(name_l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(90, 0)
	row.add_child(s)
	var val := _label("", 11, INK)
	val.custom_minimum_size = Vector2(50, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	s.drag_started.connect(func(): get_viewport().gui_release_focus())
	s.value_changed.connect(func(x: float):
		if _syncing:
			return
		if sketch != null:
			sketch.set(prop, x / scale)
		val.text = _fmt(x, scale, unit, dec)
		_refresh_pen())
	_sliders[prop] = {"slider": s, "label": val, "scale": scale, "unit": unit, "dec": dec}

func _fmt(x: float, scale: float, unit: String, dec := -1) -> String:
	var text := ""
	if dec >= 0:
		text = ("%." + str(dec) + "f") % x
	elif is_equal_approx(scale, 100.0):
		text = "%.1f" % x
	else:
		text = "%.2f" % x
	return text + unit

## Show the sketch tool's pen in the panel (after N changed the colour, or on opening)
func sync_from_tool() -> void:
	if sketch == null or _panel == null:
		return
	_syncing = true
	for i in _swatches.size():
		var sw: Button = _swatches[i]
		var c: Color = SketchMarks.COLORS[i]
		var on: bool = sketch.color.is_equal_approx(c)
		for n in ["normal", "hover", "pressed"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = c
			sb.set_border_width_all(3 if on else 1)
			sb.border_color = Color.WHITE if on else Color(0.5, 0.5, 0.45)
			if c.get_luminance() > 0.7 and on:
				sb.border_color = Color("d92b2b")
			sw.add_theme_stylebox_override(n, sb)
	if _picker != null and not _picker.color.is_equal_approx(sketch.color):
		_picker.color = sketch.color
	for prop in _sliders:
		var d: Dictionary = _sliders[prop]
		var x: float = float(sketch.get(prop)) * float(d.scale)
		(d.slider as HSlider).set_value_no_signal(x)
		(d.label as Label).text = _fmt(x, float(d.scale), str(d.unit), int(d.dec))
	_style_btns[sketch.style].button_pressed = true
	_shape_btns[sketch.shape].button_pressed = true
	if _stamp_btns.has(sketch.stamp):
		_stamp_btns[sketch.stamp].button_pressed = true
	if cable != null:
		if _cable_type_btns.has(cable.cable_type):
			_cable_type_btns[cable.cable_type].button_pressed = true
		if _cable_shape_btns.has(cable.shape):
			_cable_shape_btns[cable.shape].button_pressed = true
		for prop in _cable_sliders:
			var d: Dictionary = _cable_sliders[prop]
			var x: float = float(cable.get(prop)) * float(d.scale)
			(d.slider as HSlider).set_value_no_signal(x)
			(d.label as Label).text = _fmt(x, float(d.scale), str(d.unit), int(d.dec))
	_syncing = false
	_refresh_pen()

func _add_cable_slider(title: String, prop: String, lo: float, hi: float, step: float, scale: float, unit: String, box: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	var name_l := _label(title, 11, INK)
	name_l.custom_minimum_size = Vector2(62, 0)
	row.add_child(name_l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(90, 0)
	row.add_child(s)
	var val := _label("", 11, INK)
	val.custom_minimum_size = Vector2(50, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	s.drag_started.connect(func(): get_viewport().gui_release_focus())
	s.value_changed.connect(func(x: float):
		if _syncing:
			return
		if cable != null:
			cable.set(prop, x / scale)
		val.text = _fmt(x, scale, unit))
	_cable_sliders[prop] = {"slider": s, "label": val, "scale": scale, "unit": unit, "dec": -1}

## The sample stroke in the panel and the stamp preview take the pen's current colour and settings
func _refresh_pen() -> void:
	if _preview == null or sketch == null:
		return
	var c: Color = sketch.color
	_preview.ink = Color(c, float(sketch.opacity))
	_preview.width_m = float(sketch.width)
	_preview.wobble = float(sketch.wobble)
	_preview.style = str(sketch.style)
	_preview.shape = str(sketch.shape)
	_preview.queue_redraw()
	if _stamp_preview != null:
		_stamp_preview.ink = Color(c, maxf(0.4, float(sketch.opacity)))
		_stamp_preview.queue_redraw()

func _refresh_stamp_preview() -> void:
	if _stamp_preview == null or sketch == null:
		return
	_stamp_preview.lines = Stamps.make(sketch.stamp)
	_refresh_pen()

func _set_tool(t: String) -> void:
	tool = t
	if _tool_btns.has(t):
		_tool_btns[t].button_pressed = true
	if _head_title != null:
		_head_title.text = "DRAW TOOLS · " + str(TOOL_NAMES.get(t, t))
	if _marker_box != null:
		_marker_box.visible = t == "marker" or t == "stamp"
		_preview.visible = t == "marker"
		_shape_box.visible = t == "marker"
		_stamp_box.visible = t == "stamp"
		_eraser_box.visible = t == "eraser"
	if _cable_box != null:
		_cable_box.visible = t == "cable"
	if _tip != null:
		_tip.text = str(TIPS.get(t, ""))
	if t == "stamp":
		_refresh_stamp_preview()
	if _panel != null:
		_clamp_panel()

func _apply_preset(p: Dictionary) -> void:
	if sketch == null:
		return
	sketch.width = float(p.w)
	sketch.wobble = float(p.wob)
	sketch.opacity = float(p.op)
	sketch.style = str(p.style)
	sync_from_tool()
	_say("PRESET  " + str(p.name))

func _set_colour(i: int) -> void:
	if sketch == null or i < 0 or i >= SketchMarks.COLORS.size():
		return
	sketch.color = SketchMarks.COLORS[i]
	sync_from_tool()
	_say(SketchMarks.COLOR_NAMES[i])

func _set_style(st: String) -> void:
	if sketch != null:
		sketch.style = st
	sync_from_tool()

func _set_shape(sh: String) -> void:
	if sketch != null:
		sketch.shape = sh
	sync_from_tool()

func _select_stamp(id: String) -> void:
	if sketch == null:
		return
	sketch.stamp = id
	_refresh_stamp_preview()
	sync_from_tool()
	_say("STAMP  " + str(_stamp_names.get(id, id)))

func _filter_stamps(q: String) -> void:
	var s := q.strip_edges().to_upper()
	for id in _stamp_btns:
		var b: Button = _stamp_btns[id]
		b.visible = s == "" or str(_stamp_names[id]).contains(s)

func _random_stamp() -> void:
	var ids: Array = _stamp_btns.keys()
	if ids.is_empty() or sketch == null:
		return
	_select_stamp(str(ids.pick_random()))

# ---------------------------------------------------------------- actions
func _undo() -> void:
	if tool == "cable":
		if CableMarks.live != null and CableMarks.live.undo():
			_say("Undone cable")
			return
	if tool == "portal":
		if portal != null and portal.has_method("undo") and portal.undo():
			_say("Undone portal")
			return
	if SketchMarks.live != null and SketchMarks.live.undo():
		_say("Undone line")
		return
	if CableMarks.live != null and CableMarks.live.undo():
		_say("Undone cable")
		return
	_say("Nothing to undo")

func _redo() -> void:
	if tool == "cable":
		if CableMarks.live != null and CableMarks.live.redo():
			_say("Redone cable")
			return
	if tool == "portal":
		if portal != null and portal.has_method("redo") and portal.redo():
			_say("Redone portal")
			return
	if SketchMarks.live != null and SketchMarks.live.redo():
		_say("Redone line")
		return
	if CableMarks.live != null and CableMarks.live.redo():
		_say("Redone cable")
		return
	_say("Nothing to redo")

func _clear_cables() -> void:
	var m = CableMarks.live
	if m == null:
		return
	if not _clear_cables_armed:
		_clear_cables_armed = true
		_clear_cables_btn.text = "SURE?"
		get_tree().create_timer(2.0).timeout.connect(func():
			_clear_cables_armed = false
			_clear_cables_btn.text = "CLEAR CABLES")
		return
	_clear_cables_armed = false
	_clear_cables_btn.text = "CLEAR CABLES"
	m.clear_all()
	_refresh_counts(true)
	_say("Cleared every equipment cable on this floor")

func _clear() -> void:
	var m = SketchMarks.live
	if m == null:
		return
	if not _clear_armed:
		_clear_armed = true
		_clear_btn.text = "SURE?"
		get_tree().create_timer(2.0).timeout.connect(func():
			_clear_armed = false
			_clear_btn.text = "CLEAR LINES")
		return
	_clear_armed = false
	_clear_btn.text = "CLEAR LINES"
	m.clear_all()
	_refresh_counts(true)
	_say("Cleared every sketch line on this floor")

func _recover() -> void:
	var m = SketchMarks.live
	if m == null:
		return
	var n: int = m.recover()
	_refresh_counts(true)
	_say("Recovered %d lines" % n if n > 0 else "Nothing to recover")

func _save() -> void:
	var ok := true
	var strips := 0
	var lines := 0
	var cables_n := 0
	var file := ""
	if TapeMarks.live != null:
		ok = TapeMarks.live.save() and ok
		strips = TapeMarks.placed.get(MarkStore.key(), []).size()
		file = TapeMarks.live.level_id
	if SketchMarks.live != null:
		ok = SketchMarks.live.save() and ok
		lines = SketchMarks.live.count()
		file = SketchMarks.live.level_id
	if CableMarks.live != null:
		ok = CableMarks.live.save() and ok
		cables_n = CableMarks.live.count()
		file = CableMarks.live.level_id
	var portals_n := 0
	if PortalMarks.live != null:
		ok = PortalMarks.live.save() and ok
		portals_n = PortalMarks.live.count()
		file = PortalMarks.live.level_id
	_refresh_counts(true)
	if ok:
		_say("SAVED  %d tape, %d lines, %d cables, %d portals  (%s.json)" % [strips, lines, cables_n, portals_n, file])
	else:
		_say("SAVE FAILED: could not write the marks file")

func _say(text: String) -> void:
	if _status != null:
		_status.text = text

## How much is on the floor. `full` also counts the wiped lines (a disk read: only on opening and after
## something was cleared or recovered, not every second)
func _refresh_counts(full := false) -> void:
	if _counts == null:
		return
	var lines: int = SketchMarks.live.count() if SketchMarks.live != null else 0
	var cables_n: int = CableMarks.live.count() if CableMarks.live != null else 0
	var portals_n: int = PortalMarks.live.count() if PortalMarks.live != null else 0
	var strips: int = TapeMarks.placed.get(MarkStore.key(), []).size() if TapeMarks.live != null else 0
	_counts.text = "Lines %d · Cables %d · Portals %d · Tape %d" % [lines, cables_n, portals_n, strips]
	if full and _recover_btn != null:
		var trash: int = SketchMarks.live.trash_count() if SketchMarks.live != null else 0
		_recover_btn.text = "RECOVER CLEARED LINES" + (("  (%d)" % trash) if trash > 0 else "")

# ---------------------------------------------------------------- open / close, mouse
func _unhandled_input(e: InputEvent) -> void:
	if not is_inside_tree():
		return
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY:
		if open and _typing():
			return                      # a Y typed into the stamp search
		if open:
			_close(true)
		elif Game.playing and not Game.dead and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_open()
		get_viewport().set_input_as_handled()
		return
	if not open:
		return
	if e is InputEventMouseButton and e.pressed and not _rmb_look and cursor_mode and not over_panel() \
			and (e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		if _wheel(1.0 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0):
			get_viewport().set_input_as_handled()
		return
	if not (e is InputEventKey) or not e.pressed or e.echo:
		return
	var k: int = e.physical_keycode
	if (e.ctrl_pressed or e.meta_pressed) and k in [KEY_Z, KEY_Y]:
		if k == KEY_Y or e.shift_pressed:
			_redo()
		else:
			_undo()
		get_viewport().set_input_as_handled()
		return
	if _typing():
		if k == KEY_ESCAPE:
			get_viewport().gui_release_focus()
			get_viewport().set_input_as_handled()
		return
	if (e.ctrl_pressed or e.meta_pressed) and k == PANEL_KEY:
		_toggle_panel_visible()
		get_viewport().set_input_as_handled()
		return
	if e.ctrl_pressed or e.meta_pressed:
		var idx := -1
		match k:
			KEY_1: idx = 0
			KEY_2: idx = 1
			KEY_3: idx = 2
			KEY_4: idx = 3
			KEY_5: idx = 4
			KEY_6: idx = 5
		if idx >= 0:
			_set_tool(TOOLS[idx])
			get_viewport().set_input_as_handled()
		return
	if k >= KEY_1 and k <= KEY_8:
		_set_colour(k - KEY_1)
		get_viewport().set_input_as_handled()
		return
	match k:
		KEY_BRACKETLEFT:
			_nudge("width", -0.0025)
			get_viewport().set_input_as_handled()
		KEY_BRACKETRIGHT:
			_nudge("width", 0.0025)
			get_viewport().set_input_as_handled()
		KEY_MINUS:
			_nudge("opacity", -0.05)
			get_viewport().set_input_as_handled()
		KEY_EQUAL:
			_nudge("opacity", 0.05)
			get_viewport().set_input_as_handled()

## True while a text field in the panel has the keyboard (then keys are text, not tools)
func _typing() -> bool:
	var f: Control = get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit

## The mouse wheel sizes the pen of the tool in hand (the panel has the wheel when the cursor is over it)
func _wheel(dir: float) -> bool:
	if sketch == null and tool in ["marker", "stamp", "eraser"]:
		return false
	match tool:
		"marker":
			sketch.width = clampf(sketch.width + 0.0025 * dir, 0.005, 0.2)
			_say("WIDTH  %.1f cm" % (sketch.width * 100.0))
		"stamp":
			sketch.stamp_size = clampf(sketch.stamp_size + 0.1 * dir, 0.2, 3.0)
			_say("STAMP  %d cm" % roundi(sketch.stamp_size * 100.0))
		"eraser":
			sketch.erase_radius = clampf(sketch.erase_radius + 0.02 * dir, 0.03, 0.5)
			_say("ERASER  %d cm" % roundi(sketch.erase_radius * 100.0))
		"cable":
			if cable == null:
				return false
			cable.radius = clampf(cable.radius + 0.005 * dir, 0.015, 0.1)
			_say("GAUGE  %.1f cm" % (cable.radius * 100.0))
		_:
			return false
	sync_from_tool()
	return true

func _nudge(prop: String, delta: float) -> void:
	if sketch == null:
		return
	match prop:
		"width":
			sketch.width = clampf(sketch.width + delta, 0.005, 0.2)
			_say("WIDTH  %.1f cm" % (sketch.width * 100.0))
		"opacity":
			sketch.opacity = clampf(sketch.opacity + delta, 0.1, 1.0)
			_say("OPACITY  %d%%" % roundi(sketch.opacity * 100.0))
	sync_from_tool()

func _open() -> void:
	open = true
	visible = true
	_panel.visible = true
	_pill.visible = false
	_rmb_look = false
	_lmb_ui = false
	_lmb_prev = true              # the click that opened it doesn't also draw
	sync_from_tool()
	_refresh_counts(true)
	_clamp_panel()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## `recapture`: give the mouse back to the player (not when the pause menu or death screen took it)
func _close(recapture: bool) -> void:
	open = false
	visible = false
	_panel.visible = true
	_pill.visible = false
	Game.draw_mode = false
	cursor_mode = false
	world_lmb = false
	_rmb_look = false
	_dragging = false
	get_viewport().gui_release_focus()
	if tape != null:
		tape.cursor_aim = false
		tape.ui_down = false
	if cable != null:
		cable.ui_down = false
	if portal != null:
		portal.ui_down = false
	if recapture:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Ctrl+H / HIDE: the panel goes away but the pen keeps working and the view is clear
func _toggle_panel_visible() -> void:
	_panel.visible = not _panel.visible
	_pill.visible = not _panel.visible
	get_viewport().gui_release_focus()
	if not _panel.visible:
		_lmb_ui = false
	_dragging = false

func _toggle_fold() -> void:
	_body.visible = not _body.visible
	_fold.text = "–" if _body.visible else "+"
	get_viewport().gui_release_focus()
	_clamp_panel()

func _header_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_dragging = e.pressed
		if e.pressed:
			_drag_off = Gfx.mouse_position() - _panel.position
	elif e is InputEventMouseMotion and _dragging:
		var vp := get_viewport().get_visible_rect().size
		var p: Vector2 = Gfx.mouse_position() - _drag_off
		p.x = clampf(p.x, 0.0, maxf(0.0, vp.x - _panel.size.x))
		p.y = clampf(p.y, 0.0, maxf(0.0, vp.y - _panel.size.y))
		_panel.position = p

## Keep the panel on screen after it changed size, folded, or the window was resized
func _clamp_panel() -> void:
	if _panel == null:
		return
	_panel.reset_size()
	var vp := get_viewport().get_visible_rect().size
	var p := _panel.position
	p.x = clampf(p.x, 0.0, maxf(0.0, vp.x - _panel.size.x))
	p.y = clampf(p.y, 0.0, maxf(0.0, vp.y - _panel.size.y))
	_panel.position = p

func over_panel() -> bool:
	var m := Gfx.mouse_position()
	if _panel.visible and _panel.get_global_rect().has_point(m):
		return true
	if _pill.visible and _pill.get_global_rect().has_point(m):
		return true
	return false

func _process(dt: float) -> void:
	if not open:
		return
	if Game.dead or not Game.playing:
		_close(false)
		return
	if _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging = false
	var rmb := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if rmb and not _rmb_look and not over_panel():
		_rmb_look = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif not rmb and _rmb_look:
		_rmb_look = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().warp_mouse(get_viewport().get_visible_rect().size * 0.5)
	elif not _rmb_look and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE      # the inventory or console gave it back: the panel is still open
	cursor_mode = not _rmb_look and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
	Game.draw_mode = true
	var lmb := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if lmb and not _lmb_prev:
		_lmb_ui = over_panel()
	_lmb_prev = lmb
	world_lmb = lmb and not _lmb_ui and cursor_mode
	if tape != null:
		tape.cursor_aim = cursor_mode
		tape.ui_down = world_lmb and tool == "tape"
	if cable != null:
		cable.ui_down = world_lmb and tool == "cable"
	if portal != null:
		portal.ui_down = world_lmb and tool == "portal"
	_count_t -= dt
	if _count_t <= 0.0:
		_count_t = 1.0
		_refresh_counts()
	if tool == "eraser" and world_lmb:
		if sketch != null:
			var hit: Dictionary = sketch._aim()
			if not hit.is_empty():
				if CableMarks.live != null:
					CableMarks.live.remove_near(hit.position, maxf(0.35, float(sketch.erase_radius)))
				if portal != null and portal.has_method("remove_near"):
					portal.remove_near(hit.position, maxf(0.6, float(sketch.erase_radius) * 2.0))

# ---------------------------------------------------------------- the little drawing surfaces

## A sample stroke in the panel: the pen's colour, width, wobble, opacity and solid / dashed / dotted,
## so the line's look is chosen before it is drawn instead of after.
class PenPreview extends Control:
	var ink := Color.WHITE
	var width_m := 0.03
	var wobble := 1.0
	var style := "solid"
	var shape := "freehand"

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if w < 24.0 or h < 12.0:
			return
		var mid := h * 0.5
		draw_line(Vector2(6.0, mid), Vector2(w - 6.0, mid), Color(1.0, 1.0, 1.0, 0.06), 1.0)
		var px := clampf(width_m * 260.0, 1.5, h * 0.42)
		var pts := PackedVector2Array()
		var steps := 64
		for i in steps + 1:
			var t := float(i) / float(steps)
			var x := 8.0 + (w - 16.0) * t
			var y := mid
			if shape == "line":
				y = mid + (t - 0.5) * h * 0.32
			else:
				y = mid + (sin(t * 8.0 + 0.6) * 0.55 + sin(t * 19.0 + 2.1) * 0.18) * h * 0.32 * wobble
			pts.append(Vector2(x, y))
		match style:
			"dotted":
				var step := maxi(3, roundi(px * 2.6))
				for i in range(0, pts.size(), step):
					draw_circle(pts[i], px * 0.5, ink)
			"dashed":
				var d0 := 0
				while d0 < pts.size() - 1:
					var d1 := mini(d0 + 7, pts.size() - 1)
					draw_polyline(_part(pts, d0, d1), ink, px, true)
					d0 += 12
			_:
				draw_polyline(pts, ink, px, true)
				draw_circle(pts[0], px * 0.5, ink)
				draw_circle(pts[pts.size() - 1], px * 0.5, ink)

	func _part(pts: PackedVector2Array, a: int, b: int) -> PackedVector2Array:
		var out := PackedVector2Array()
		for i in range(a, b + 1):
			out.append(pts[i])
		return out

## The STAMP design as it will be pressed on: its polylines in the pen's colour
class StampPreview extends Control:
	var lines: Array = []
	var ink := Color.WHITE

	func _draw() -> void:
		if lines.is_empty():
			return
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for poly in lines:
			for v in poly:
				var p: Vector2 = v
				lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
				hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		var span := hi - lo
		if span.x < 0.001 or span.y < 0.001:
			return
		var s: float = minf((size.x - 16.0) / span.x, (size.y - 12.0) / span.y)
		var off: Vector2 = (size - span * s) * 0.5 - lo * s
		for poly in lines:
			var pts := PackedVector2Array()
			for v in poly:
				var p: Vector2 = v
				pts.append(p * s + off)
			if pts.size() >= 2:
				draw_polyline(pts, ink, 1.6, true)
