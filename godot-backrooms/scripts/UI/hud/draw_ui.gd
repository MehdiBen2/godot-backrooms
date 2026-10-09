extends CanvasLayer
## The draw tools panel, for test launches and dev builds (hud.gd builds it when Game.test_level is set or
## Game.dev_keys is on). Y opens and closes it. With it open the mouse cursor is the pen, so tape and
## sketches are drawn with the mouse instead of by aiming the middle of the screen:
##  - TAPE: hold the left button and drag to pull a strip out (tape_tool.gd); click a strip to peel it back
##  - MARKER: hold the left button and drag to draw (sketch_tool.gd), with a colour, width, wobble, opacity,
##    solid / dashed / dotted, and FREEHAND or a straight LINE
##  - ERASER: hold the left button over a sketch line to rub it out
##  - STAMP: click to press a scary design on (an eye, a grin, a figure, scratched words ...; scary_stamps.gd)
## While it is open you fly like noclip (WASD, Space up, C down, Shift fast); hold the right button to look. SAVE writes the tape
## and the sketches to disk now (they are also written as each one is placed).

const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const SketchMarks := preload("res://scripts/World/props/sketch_marks.gd")
const CableMarks := preload("res://scripts/World/props/cable_marks.gd")
const PortalMarks := preload("res://scripts/World/props/portal_marks.gd")
const MarkStore := preload("res://scripts/World/props/mark_store.gd")
const Stamps := preload("res://scripts/World/props/scary_stamps.gd")

const KEY := KEY_Y
const INK := Color("c9bea0")
const PANEL_W := 262.0

var player: Node
var tape: Node                   # tape_tool.gd
var sketch: Node                 # sketch_tool.gd
var cable: Node                  # cable_tool.gd
var portal: Node                 # portal_tool.gd

var open := false
var cursor_mode := false         # the mouse is a free cursor (not captured, not looking around)
var tool := "marker"             # tape / marker / eraser
var world_lmb := false           # the left button is held, and it went down over the world, not the panel

var _panel: PanelContainer
var _tool_btns := {}
var _marker_box: VBoxContainer
var _stamp_box: VBoxContainer
var _shape_box: VBoxContainer
var _cable_box: VBoxContainer
var _cable_type_btns := {}
var _cable_shape_btns := {}
var _cable_sliders := {}
var _stamp_btns := {}
var _tip: Label
var _status: Label
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
	_panel = PanelContainer.new()
	_panel.position = Vector2(16, 70)
	_panel.custom_minimum_size = Vector2(PANEL_W, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.04, 0.03, 0.93)
	sb.border_color = INK
	sb.set_border_width_all(2)
	sb.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", sb)
	root.add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_panel.add_child(v)

	v.add_child(_label("DRAW TOOLS", 16, INK))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	v.add_child(row)
	var group := ButtonGroup.new()
	for t in ["tape", "marker", "cable", "eraser", "stamp", "portal"]:
		var b := _button(t.to_upper(), func(): _set_tool(t))
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
		_tool_btns[t] = b
	_tool_btns[tool].button_pressed = true
	_tip = _label("", 12, Color(0.75, 0.72, 0.62))
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip.custom_minimum_size = Vector2(PANEL_W - 24, 0)
	v.add_child(_tip)

	_stamp_box = VBoxContainer.new()
	_stamp_box.add_theme_constant_override("separation", 6)
	v.add_child(_stamp_box)
	var stgrid := GridContainer.new()
	stgrid.columns = 3
	stgrid.add_theme_constant_override("h_separation", 3)
	stgrid.add_theme_constant_override("v_separation", 3)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(PANEL_W - 24, 150)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_stamp_box.add_child(scroll)
	stgrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(stgrid)
	var stgroup := ButtonGroup.new()
	for d in Stamps.LIST:
		var id: String = d[0]
		var b := _button(d[1], func():
			sketch.stamp = id)
		b.add_theme_font_size_override("font_size", 10)
		b.clip_text = true
		b.toggle_mode = true
		b.button_group = stgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		stgrid.add_child(b)
		_stamp_btns[id] = b
	_add_slider("SIZE", "stamp_size", 20.0, 300.0, 5.0, 100.0, " cm", _stamp_box)

	_marker_box = VBoxContainer.new()
	_marker_box.add_theme_constant_override("separation", 6)
	v.add_child(_marker_box)
	_marker_box.add_child(_label("COLOUR", 12, INK))
	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 4)
	_marker_box.add_child(grid)
	for i in SketchMarks.COLORS.size():
		var sw := Button.new()
		sw.custom_minimum_size = Vector2(24, 24)
		sw.focus_mode = Control.FOCUS_NONE
		sw.tooltip_text = SketchMarks.COLOR_NAMES[i]
		sw.pressed.connect(func():
			sketch.color = SketchMarks.COLORS[i]
			sync_from_tool())
		grid.add_child(sw)
		_swatches.append(sw)
	_add_slider("WIDTH", "width", 1.0, 15.0, 0.5, 100.0, " cm")
	_add_slider("WOBBLE", "wobble", 0.0, 1.0, 0.05, 1.0, "")
	_add_slider("OPACITY", "opacity", 0.1, 1.0, 0.05, 1.0, "")
	_marker_box.add_child(_label("STYLE", 12, INK))
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 4)
	_marker_box.add_child(srow)
	var sgroup := ButtonGroup.new()
	for st in SketchMarks.STYLES:
		var b := _button(st.to_upper(), func():
			sketch.style = st)
		b.toggle_mode = true
		b.button_group = sgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		srow.add_child(b)
		_style_btns[st] = b
	_shape_box = VBoxContainer.new()
	_shape_box.add_theme_constant_override("separation", 6)
	_marker_box.add_child(_shape_box)
	_shape_box.add_child(_label("SHAPE", 12, INK))
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 4)
	_shape_box.add_child(hrow)
	var hgroup := ButtonGroup.new()
	for sh in ["freehand", "line"]:
		var b := _button(sh.to_upper(), func():
			sketch.shape = sh)
		b.toggle_mode = true
		b.button_group = hgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hrow.add_child(b)
		_shape_btns[sh] = b

	_cable_box = VBoxContainer.new()
	_cable_box.add_theme_constant_override("separation", 6)
	v.add_child(_cable_box)
	_cable_box.add_child(_label("CABLE TYPE", 12, INK))
	var cgrid := GridContainer.new()
	cgrid.columns = 3
	cgrid.add_theme_constant_override("h_separation", 3)
	cgrid.add_theme_constant_override("v_separation", 3)
	_cable_box.add_child(cgrid)
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
			if cable != null: cable.cable_type = tk)
		b.add_theme_font_size_override("font_size", 10)
		b.toggle_mode = true
		b.button_group = cgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cgrid.add_child(b)
		_cable_type_btns[tk] = b
	_add_cable_slider("GAUGE", "radius", 1.5, 10.0, 0.5, 100.0, " cm", _cable_box)
	_add_cable_slider("ROLL & COIL", "roll_slack", 0.0, 1.0, 0.05, 1.0, "", _cable_box)
	_add_cable_slider("STACK ELEV", "stack_mult", 0.5, 2.5, 0.1, 1.0, "x", _cable_box)
	_cable_box.add_child(_label("SHAPE", 12, INK))
	var chrow := HBoxContainer.new()
	chrow.add_theme_constant_override("separation", 4)
	_cable_box.add_child(chrow)
	var chgroup := ButtonGroup.new()
	for sh in ["freehand", "line"]:
		var b := _button(sh.to_upper(), func():
			if cable != null: cable.shape = sh)
		b.toggle_mode = true
		b.button_group = chgroup
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chrow.add_child(b)
		_cable_shape_btns[sh] = b
	_clear_cables_btn = _button("CLEAR CABLES", _clear_cables)
	_clear_cables_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cable_box.add_child(_clear_cables_btn)

	v.add_child(HSeparator.new())
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 4)
	v.add_child(arow)
	var undo := _button("UNDO", _undo)
	undo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arow.add_child(undo)
	var redo := _button("REDO", _redo)
	redo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arow.add_child(redo)
	_clear_btn = _button("CLEAR LINES", _clear)
	_clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_clear_btn)
	var rec := _button("RECOVER CLEARED LINES", _recover)
	rec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(rec)
	var save := _button("SAVE", _save)
	save.add_theme_color_override("font_color", Color("2fd968"))
	save.add_theme_color_override("font_hover_color", Color("6dffa0"))
	v.add_child(save)
	_status = _label("", 12, Color(0.75, 0.72, 0.62))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(PANEL_W - 24, 0)
	v.add_child(_status)
	v.add_child(_label("WASD move (Space up, C down, Shift fast)\nRight mouse held: look\nCtrl+Z undo, Ctrl+Y redo (lines)\nY: close", 11, Color(0.6, 0.58, 0.5)))
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
	b.pressed.connect(cb)
	return b

func _add_slider(title: String, prop: String, lo: float, hi: float, step: float, scale: float, unit: String, box: Control = null) -> void:
	var row := HBoxContainer.new()
	(box if box != null else _marker_box).add_child(row)
	var name_l := _label(title, 12, INK)
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
	var val := _label("", 12, INK)
	val.custom_minimum_size = Vector2(46, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	s.value_changed.connect(func(x: float):
		sketch.set(prop, x / scale)
		val.text = ("%.1f" if scale == 100.0 else "%.2f") % x + unit)
	_sliders[prop] = {"slider": s, "label": val, "scale": scale, "unit": unit}

## Show the sketch tool's pen in the panel (after N changed the colour, or on opening)
func sync_from_tool() -> void:
	if sketch == null or _panel == null:
		return
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
	for prop in _sliders:
		var d: Dictionary = _sliders[prop]
		var x: float = float(sketch.get(prop)) * float(d.scale)
		(d.slider as HSlider).set_value_no_signal(x)
		(d.label as Label).text = (("%.1f" if d.scale == 100.0 else "%.2f") % x) + str(d.unit)
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
			(d.label as Label).text = (("%.1f" if d.scale == 100.0 else "%.2f") % x) + str(d.unit)

func _add_cable_slider(title: String, prop: String, lo: float, hi: float, step: float, scale: float, unit: String, box: Control) -> void:
	var row := HBoxContainer.new()
	box.add_child(row)
	var name_l := _label(title, 12, INK)
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
	var val := _label("", 12, INK)
	val.custom_minimum_size = Vector2(46, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	s.value_changed.connect(func(x: float):
		if cable != null:
			cable.set(prop, x / scale)
		val.text = ("%.1f" if scale == 100.0 else "%.2f") % x + unit)
	_cable_sliders[prop] = {"slider": s, "label": val, "scale": scale, "unit": unit}

func _set_tool(t: String) -> void:
	tool = t
	if _marker_box != null:
		_marker_box.visible = t == "marker" or t == "stamp"
		_shape_box.visible = t == "marker"
		_stamp_box.visible = t == "stamp"
	if _cable_box != null:
		_cable_box.visible = t == "cable"
	if _tip != null:
		_tip.text = {
			"stamp": "Pick a design, then click a wall, floor or ceiling to press it on. Colour, width and wobble come from the pen.",
			"tape": "Hold the left mouse on a wall or floor and drag to pull tape out; let go to stick it. Click a strip to peel it off.",
			"marker": "Hold the left mouse and drag to draw on a wall, floor or ceiling.",
			"cable": "Hold left mouse on a floor or wall and drag to lay 3D equipment cables. They roll and stack in 3D piles the more you draw.",
			"eraser": "Hold the left mouse over a sketch line or equipment cable to rub it out.",
			"portal": "Click and drag to draw a portal onto a wall. Release to tear open a glowing void."}[t]
	if _panel != null:
		_panel.reset_size()

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
	_say("Cleared every sketch line on this floor")

func _recover() -> void:
	var m = SketchMarks.live
	if m == null:
		return
	var n: int = m.recover()
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
	if ok:
		_say("SAVED  %d tape, %d lines, %d cables, %d portals  (%s.json)" % [strips, lines, cables_n, portals_n, file])
	else:
		_say("SAVE FAILED: could not write the marks file")

func _say(text: String) -> void:
	_status.text = text

# ---------------------------------------------------------------- open / close, mouse
func _unhandled_input(e: InputEvent) -> void:
	if open and e is InputEventKey and e.pressed and e.ctrl_pressed and e.physical_keycode in [KEY_Z, KEY_Y]:
		if e.physical_keycode == KEY_Y or e.shift_pressed:
			_redo()
		else:
			_undo()
		get_viewport().set_input_as_handled()
		return
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY:
		if open:
			_close(true)
		elif Game.playing and not Game.dead and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_open()
		get_viewport().set_input_as_handled()

func _open() -> void:
	open = true
	visible = true
	_rmb_look = false
	sync_from_tool()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## `recapture`: give the mouse back to the player (not when the pause menu or death screen took it)
func _close(recapture: bool) -> void:
	open = false
	visible = false
	Game.draw_mode = false
	cursor_mode = false
	world_lmb = false
	_rmb_look = false
	if tape != null:
		tape.cursor_aim = false
		tape.ui_down = false
	if recapture:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _over_panel() -> bool:
	return _panel.get_global_rect().has_point(get_viewport().get_mouse_position())

func _process(_dt: float) -> void:
	if not open:
		return
	if Game.dead or not Game.playing:
		_close(false)
		return
	var rmb := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if rmb and not _rmb_look and not _over_panel():
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
		_lmb_ui = _over_panel()
	_lmb_prev = lmb
	world_lmb = lmb and not _lmb_ui and cursor_mode
	if tape != null:
		tape.cursor_aim = cursor_mode
		tape.ui_down = world_lmb and tool == "tape"
	if cable != null:
		cable.ui_down = world_lmb and tool == "cable"
	if portal != null:
		portal.ui_down = world_lmb and tool == "portal"
	if tool == "eraser" and world_lmb:
		if sketch != null:
			var hit: Dictionary = sketch._aim()
			if not hit.is_empty():
				if CableMarks.live != null:
					CableMarks.live.remove_near(hit.position, 0.35)
				if portal != null and portal.has_method("remove_near"):
					portal.remove_near(hit.position, 0.6)
