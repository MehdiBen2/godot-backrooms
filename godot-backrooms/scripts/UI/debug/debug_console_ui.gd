extends "res://scripts/UI/debug/debug_console_handlers.gd"
## The debug menu: panels and tabs, helpers, handlers, the input gate.

# ---------------------------------------------------------------- the event director panel (WORLD & EVENTS)
## Every event, by what it does to you. Button label, events.gd name.
const EVENT_GROUPS := [
	["LIGHTS & POWER", Color("e0a63c"), [["BLACKOUT", "powerCut"], ["RED ALERT", "redAlert"], ["EMERGENCY PULSE", "emergencyPulse"],
		["LIGHTS OUT", "lightsOut"], ["ONE LAMP", "oneLamp"], ["RUN", "run"]]],
	["VOICES & SOUND", Color("5fc9b8"), [["MACHINE VOICE", "machineVoice"], ["SAY YOUR NAME", "sayYourName"],
		["PREACHER WHISPER", "preacherWhisper"], ["DEAD AIR", "deadAir"], ["HUM RISES", "humRises"], ["DOORBELL", "doorbell"]]],
	["IT HEARS YOU (MIC)", Color("b98cf0"), [["IT HEARD YOU", "itHeardYou"], ["ANSWER BACK", "answerBack"],
		["YOUR OWN VOICE", "yourOwnVoice"]]],
	["SOMETHING NEARBY", Color("d0574a"), [["WALL KNOCK", "wallKnock"], ["HOUND PACING", "houndPacing"],
		["WALL FOOTSTEPS", "wallFootsteps"], ["PARTY WALL", "partyWall"], ["PHONE RING", "phoneRing"]]],
	["SIGNAL & TERMINAL", Color("7fc77a"), [["GHOST ROSTER", "ghostRoster"], ["LOOK UP", "lookTogether"],
		["SOUNDS TO AVOID", "soundsToAvoid"], ["COUNTDOWN", "countdown"]]],
]
var _ev_status: Label
var _ev_buttons := {}            # event name -> [Button, group colour, label, description]
var _ev_groups: Array = []       # [header row, flow] per group, for the filter
var _ev_last := ""
var _mic_label: Label            # the IT HEARS YOU group's live readout of the mic

func _events_node() -> Node:
	return root.get_node_or_null("Events") if root != null else null

func _event_desc(ev_name: String) -> String:
	var e = EVENTS.get(ev_name.to_lower())
	return str(e[1]) if e is Array else ""

func _fire_event(ev_name: String) -> void:
	var ev := _events_node()
	if ev == null:
		_print("[color=#e8702c]no event director in this scene[/color]")
		return
	if ev.run_event(ev_name):
		_ev_last = ev_name
		_print("[color=#5fc9b8]event[/color] %s  [color=#b3a57a]%s[/color]" % [ev_name, _event_desc(ev_name)])
	else:
		_print("[color=#e8702c]event %s didn't start[/color]" % ev_name)

func _ev_style(b: Button, col: Color, on: bool) -> void:
	b.add_theme_stylebox_override("normal", _make_box(Color(col, 0.16) if on else Color(0.110, 0.086, 0.044, 0.9), Color(col, 1.0 if on else 0.45), 2 if on else 1, 3, 7))
	b.add_theme_stylebox_override("hover", _make_box(Color(col, 0.12), Color(col, 0.95), 1, 3, 7))
	b.add_theme_stylebox_override("pressed", _make_box(Color(col, 0.25), col, 2, 3, 7))
	b.add_theme_color_override("font_color", col.lightened(0.25) if on else Color(0.82, 0.86, 0.84))
	b.add_theme_color_override("font_hover_color", col.lightened(0.3))

func _build_event_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _make_box(Color(0.050, 0.039, 0.020, 0.75), Color(0.450, 0.306, 0.099, 0.45), 1, 4, 12))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	# status, and what you reach for most
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	v.add_child(bar)
	_ev_status = _label("IDLE", 12, Color(0.712, 0.675, 0.525))
	_ev_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ev_status.clip_text = true
	bar.add_child(_ev_status)
	var rnd := _action_btn("RANDOM EVENT", func():
		var ev := _events_node()
		if ev:
			var picked: String = ev.trigger_random(true)
			if picked != "":
				_ev_last = picked
				_print("[color=#5fc9b8]event[/color] %s (random)" % picked))
	rnd.tooltip_text = "Fire a random event (any of them, cooldowns ignored)"
	bar.add_child(rnd)
	var again := _action_btn("REPEAT LAST", func():
		if _ev_last != "": _fire_event(_ev_last)
		else: _print("[color=#b3a57a]nothing fired yet[/color]"))
	again.tooltip_text = "Fire the last event again"
	bar.add_child(again)
	var stop := _action_btn("STOP ALL EVENTS", func():
		var ev := _events_node()
		if ev: ev.stop_all()
		_print("all events stopped"))
	stop.tooltip_text = "End every running event: lights, tint, sounds and screen effects back to normal"
	stop.add_theme_stylebox_override("normal", _make_box(Color(0.25, 0.05, 0.05, 0.85), Color(0.9, 0.3, 0.25, 0.8), 1, 3, 7))
	stop.add_theme_stylebox_override("hover", _make_box(Color(0.4, 0.07, 0.06, 0.95), Color(1.0, 0.4, 0.35), 1, 3, 7))
	stop.add_theme_color_override("font_color", Color(1.0, 0.7, 0.65))
	bar.add_child(stop)
	# filter
	var find := LineEdit.new()
	find.placeholder_text = "filter events... (name or what it does)"
	find.clear_button_enabled = true
	if font: find.add_theme_font_override("font", font)
	find.add_theme_font_size_override("font_size", 11)
	find.add_theme_stylebox_override("normal", _make_box(Color(0.060, 0.047, 0.024, 0.9), Color(0.450, 0.306, 0.099, 0.4), 1, 3, 6))
	find.text_changed.connect(_filter_events)
	v.add_child(find)
	# the groups
	_ev_buttons.clear()
	_ev_groups.clear()
	for g in EVENT_GROUPS:
		var col: Color = g[1]
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		var swatch := ColorRect.new()
		swatch.color = col
		swatch.custom_minimum_size = Vector2(3, 14)
		head.add_child(swatch)
		head.add_child(_label(str(g[0]), 12, col))
		head.add_child(_label("%d" % (g[2] as Array).size(), 10, Color(col, 0.5)))
		v.add_child(head)
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		v.add_child(flow)
		for pair in g[2]:
			var ev_name: String = pair[1]
			var b := _action_btn(str(pair[0]), func(): _fire_event(ev_name))
			b.tooltip_text = _event_desc(ev_name)
			if ev_name == "machineVoice":                  # this one asks which voice and which line first
				b = _action_btn(str(pair[0]) + "...", func(): _open_voice_picker())
				b.tooltip_text = "Choose a voice and a line to play (or let the director pick)"
			_ev_style(b, col, false)
			flow.add_child(b)
			_ev_buttons[ev_name] = [b, col, str(pair[0]), _event_desc(ev_name)]
		if str(g[0]).begins_with("IT HEARS YOU"):
			_mic_label = _label("MIC: ...", 11, Color(0.7, 0.6, 0.85))
			v.add_child(_mic_label)
		if g[0] == "LIGHTS & POWER":
			var restore := _action_btn("RESTORE GRID", func(): _restore_grid())
			restore.tooltip_text = "Every tube back on, white, right now (doesn't stop the event that cut them)"
			flow.add_child(restore)
		_ev_groups.append([head, flow])
	v.add_child(_label("Hover a button for what it does. In co-op, the host's events play for everyone; each one is logged on the CONSOLE tab.", 10, Color(0.570, 0.540, 0.420)))
	return panel

func _filter_events(q: String) -> void:
	q = q.strip_edges().to_lower()
	for k in _ev_buttons:
		var e: Array = _ev_buttons[k]
		(e[0] as Button).visible = q == "" or str(e[2]).to_lower().contains(q) or str(e[3]).to_lower().contains(q) or str(k).to_lower().contains(q)
	for gr in _ev_groups:
		var any := false
		for c in (gr[1] as Control).get_children():
			if (c as Control).visible and _ev_buttons.values().any(func(e): return e[0] == c):
				any = true
		(gr[0] as Control).visible = any or q == ""
		(gr[1] as Control).visible = any or q == ""

## What the director is doing, under the buttons' row: the running event and how long it has run, or idle and
## how close the next one is; the running event's button lit in its colour
func _update_event_status() -> void:
	var ev := _events_node()
	if ev == null or _ev_status == null:
		return
	if _mic_label != null:
		_mic_label.text = _mic_readout()
	var running: bool = not (ev.watchers as Array).is_empty() or not (ev.queue as Array).is_empty()
	var cur: String = str(ev.last)
	if running and cur != "":
		var label: String = (_ev_buttons[cur][2] if _ev_buttons.has(cur) else cur)
		_ev_status.text = "RUNNING   %s   //   %ds" % [label, int(Game.time - float(ev.last_at))]
		_ev_status.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	else:
		var th: float = float(ev.threshold)
		var k := clampf(float(ev.tension) / th, 0.0, 1.0) if th > 0.0 else 0.0
		var tail := ("   //   LAST: %s" % (_ev_buttons[cur][2] if _ev_buttons.has(cur) else cur)) if cur != "" else ""
		_ev_status.text = "IDLE   //   NEXT EVENT %d%%%s" % [roundi(k * 100.0), tail]
		_ev_status.add_theme_color_override("font_color", Color(0.712, 0.675, 0.525))
	for k2 in _ev_buttons:
		var e: Array = _ev_buttons[k2]
		var on: bool = running and k2 == cur
		if (e[0] as Button).get_meta("on", false) != on:
			(e[0] as Button).set_meta("on", on)
			_ev_style(e[0], e[1], on)

# ---------------------------------------------------------------- the machine voice picker
const MachineVoice := preload("res://scripts/Audio/machine_voice_lines.gd")
const VOICE_COL := Color("5fc9b8")
var _mv_panel: PanelContainer
var _mv_voice := "sam"
var _mv_voice_btns := {}
var _mv_rows: Array = []          # [Button, text, tag]

func _open_voice_picker() -> void:
	if _mv_panel == null:
		_build_voice_picker()
	_mv_panel.visible = true

func _build_voice_picker() -> void:
	_mv_panel = PanelContainer.new()
	_mv_panel.add_theme_stylebox_override("panel", _make_box(Color(0.045, 0.035, 0.018, 0.98), Color(VOICE_COL, 0.6), 1, 4, 16))
	_mv_panel.visible = false
	menu_window.add_child(_mv_panel)                    # (a PanelContainer: it lies over the whole menu)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_mv_panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var title := _label("MACHINE VOICE  //  CHOOSE A VOICE, THEN A LINE", 14, VOICE_COL)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(_action_btn("LET THE DIRECTOR PICK", func(): _fire_event("machineVoice")))
	head.add_child(_action_btn("CLOSE", func(): _mv_panel.visible = false))
	v.add_child(head)
	# the voices
	v.add_child(_label("VOICE", 11, Color(0.665, 0.630, 0.490)))
	var voices := HFlowContainer.new()
	voices.add_theme_constant_override("h_separation", 6)
	voices.add_theme_constant_override("v_separation", 6)
	v.add_child(voices)
	_mv_voice_btns.clear()
	for e in MachineVoice.VOICES:
		var vid: String = e[0]
		var vb := _action_btn(str(e[1]), func(): _pick_voice(vid))
		voices.add_child(vb)
		_mv_voice_btns[vid] = vb
	_pick_voice(_mv_voice)
	# the lines
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label("LINE", 11, Color(0.665, 0.630, 0.490)))
	var find := LineEdit.new()
	find.placeholder_text = "filter lines... (words, or a tag: dark, alone, group...)"
	find.clear_button_enabled = true
	find.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if font: find.add_theme_font_override("font", font)
	find.add_theme_font_size_override("font_size", 11)
	find.add_theme_stylebox_override("normal", _make_box(Color(0.060, 0.047, 0.024, 0.9), Color(VOICE_COL, 0.35), 1, 3, 6))
	find.text_changed.connect(_filter_lines)
	row.add_child(find)
	row.add_child(_action_btn("RANDOM LINE", func(): _play_line(randi() % MachineVoice.LINES.size())))
	v.add_child(row)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 3)
	scroll.add_child(list)
	_mv_rows.clear()
	for i in MachineVoice.LINES.size():
		var line: Dictionary = MachineVoice.LINES[i]
		var tag := str(line.tag)
		var text := "%02d   %s" % [i + 1, str(line.text)]
		if tag != "":
			text += "      [%s]" % tag.to_upper()
		var idx := i
		var lb := Button.new()
		lb.text = text
		lb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		lb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		lb.clip_text = true
		lb.focus_mode = Control.FOCUS_NONE
		lb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		if font: lb.add_theme_font_override("font", font)
		lb.add_theme_font_size_override("font_size", 11)
		lb.add_theme_stylebox_override("normal", _make_box(Color(0.070, 0.055, 0.028, 0.7), Color(0, 0, 0, 0), 0, 2, 6))
		lb.add_theme_stylebox_override("hover", _make_box(Color(VOICE_COL, 0.12), Color(VOICE_COL, 0.7), 1, 2, 6))
		lb.add_theme_stylebox_override("pressed", _make_box(Color(VOICE_COL, 0.25), VOICE_COL, 1, 2, 6))
		lb.add_theme_color_override("font_color", Color(0.9, 0.55, 0.45) if tag != "" else Color(0.82, 0.86, 0.84))
		lb.tooltip_text = ("Said when this is true of you: %s" % tag) if tag != "" else "Any time"
		lb.pressed.connect(func(): _play_line(idx))
		list.add_child(lb)
		_mv_rows.append([lb, str(line.text), tag])
	v.add_child(_label("In co-op the host's line plays for everyone. Lines in red have a tag: the director prefers them when that is true of you.", 10, Color(0.570, 0.540, 0.420)))

func _pick_voice(vid: String) -> void:
	_mv_voice = vid
	for k in _mv_voice_btns:
		_ev_style(_mv_voice_btns[k], VOICE_COL, k == vid)

func _play_line(idx: int) -> void:
	var ev := _events_node()
	if ev == null or not ev.has_method("play_machine_voice"):
		return
	if ev.play_machine_voice(_mv_voice, idx):
		_print("[color=#5fc9b8]voice[/color] %s  [color=#b3a57a]%s[/color]" % [_mv_voice, str(MachineVoice.LINES[idx].text)])
	else:
		_print("[color=#e8702c]that line isn't imported yet: open the project in the Godot editor once[/color]")

func _filter_lines(q: String) -> void:
	q = q.strip_edges().to_lower()
	for r in _mv_rows:
		(r[0] as Button).visible = q == "" or str(r[1]).to_lower().contains(q) or str(r[2]).contains(q)

## The mic, as the listening events hear it: on or off, its level against the room's floor, when it last heard you
func _mic_readout() -> String:
	if not Voice.mic_live():
		return "MIC: OFF  //  set Voice mode to Voice activity or Push to talk in Settings (the events listen locally, solo too)"
	var cells := clampi(roundi(Voice.level * 12.0), 0, 12)
	var bar := "|".repeat(cells) + ".".repeat(12 - cells)
	var ago: float = Time.get_ticks_msec() / 1000.0 - Voice.heard_at
	var heard := "HEARING YOU NOW" if Voice.speaking_now else ("LAST HEARD %ds AGO" % int(ago) if ago < 600.0 else "NOT HEARD YET")
	return "MIC: LIVE  [%s]  //  %s  //  %d CLIP(S) OF YOUR VOICE KEPT" % [bar, heard, Voice.my_clips.size()]

## In co-op only the host may use the console (a guest's spawns and events would only half-happen, on their own screen)
func _process(_dt: float) -> void:
	var _pt := Time.get_ticks_usec()
	_process_timed(_dt)
	Perf.add("Console", _pt)

func _process_timed(_dt: float) -> void:
	if _guest_locked() and menu_window.visible:
		_toggle(false)                          # joined someone's game with it open
	if menu_window.visible and current_tab == "world":
		_update_event_status()
	if Game.show_debug_overlay and not Game.hide_hud:
		screen_overlay.visible = true
		_update_overlay_text()
	else:
		screen_overlay.visible = false

# ---------------------------------------------------------------- UI Building
func _build_ui() -> void:
	var root_ctrl := Control.new()
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_ctrl)

	_build_screen_overlay(root_ctrl)
	_build_quick_badge(root_ctrl)
	_build_menu_window(root_ctrl)
	_build_gate(root_ctrl)

# Top-Left Live Telemetry HUD Overlay
func _build_screen_overlay(parent: Control) -> void:
	screen_overlay = PanelContainer.new()
	screen_overlay.position = Vector2(20, 20)
	screen_overlay.custom_minimum_size = Vector2(340, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.070, 0.055, 0.028, 0.82)
	sb.border_color = Color(0.800, 0.544, 0.176, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(8)
	screen_overlay.add_theme_stylebox_override("panel", sb)
	screen_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(screen_overlay)

	overlay_label = Label.new()
	if font: overlay_label.add_theme_font_override("font", font)
	overlay_label.add_theme_font_size_override("font_size", 12)
	overlay_label.add_theme_color_override("font_color", Color(0.902, 0.855, 0.665))
	screen_overlay.add_child(overlay_label)

# Top-Right On-Screen Clickable Badge Button
func _build_quick_badge(parent: Control) -> void:
	quick_badge_btn = Button.new()
	quick_badge_btn.text = "DEBUG [F1]"
	quick_badge_btn.visible = false
	if font: quick_badge_btn.add_theme_font_override("font", font)
	quick_badge_btn.add_theme_font_size_override("font_size", 12)
	quick_badge_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	quick_badge_btn.offset_left = -140
	quick_badge_btn.offset_top = 16
	quick_badge_btn.offset_right = -20
	quick_badge_btn.offset_bottom = 44
	quick_badge_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var normal_sb := _make_box(Color(0.110, 0.086, 0.044, 0.75), Color(0.800, 0.544, 0.176, 0.6), 1, 4, 6)
	var hover_sb := _make_box(Color(0.200, 0.156, 0.080, 0.9), Color(1.000, 0.680, 0.220, 0.95), 1, 4, 6)
	quick_badge_btn.add_theme_stylebox_override("normal", normal_sb)
	quick_badge_btn.add_theme_stylebox_override("hover", hover_sb)
	quick_badge_btn.add_theme_stylebox_override("pressed", hover_sb)
	quick_badge_btn.add_theme_color_override("font_color", Color(0.902, 0.855, 0.665))
	quick_badge_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	quick_badge_btn.pressed.connect(toggle_menu)
	parent.add_child(quick_badge_btn)

# Main Centered Modal Window
func _build_menu_window(parent: Control) -> void:
	menu_window = PanelContainer.new()
	menu_window.set_anchors_preset(Control.PRESET_CENTER)
	menu_window.custom_minimum_size = Vector2(1000, 660)
	menu_window.grow_horizontal = Control.GROW_DIRECTION_BOTH
	menu_window.grow_vertical = Control.GROW_DIRECTION_BOTH
	menu_window.position = Vector2(-500, -330)

	var win_sb := StyleBoxFlat.new()
	win_sb.bg_color = Color(0.075, 0.058, 0.030, 0.96)
	win_sb.border_color = Color(0.800, 0.544, 0.176, 0.9)
	win_sb.set_border_width_all(2)
	win_sb.set_corner_radius_all(0)
	win_sb.set_content_margin_all(14)
	win_sb.shadow_color = Color(0, 0, 0, 0.6)
	win_sb.shadow_size = 16
	menu_window.add_theme_stylebox_override("panel", win_sb)
	parent.add_child(menu_window)

	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	menu_window.add_child(main_vbox)

	# --- Header Bar ---
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	main_vbox.add_child(header)

	var title_vbox := VBoxContainer.new()
	title_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_vbox)

	var title_lbl := Label.new()
	title_lbl.text = "T.S.R.A.  FIELD DIAGNOSTIC  //  MK-IV"
	if font: title_lbl.add_theme_font_override("font", font)
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", Color(0.950, 0.646, 0.209))
	title_vbox.add_child(title_lbl)

	var subtitle_lbl := Label.new()
	subtitle_lbl.text = "[F1] [~] [ESC] TOGGLE   //   [1] COMMAND LINE   //   THE GAME KEEPS RUNNING BEHIND IT"
	if font: subtitle_lbl.add_theme_font_override("font", font)
	subtitle_lbl.add_theme_font_size_override("font_size", 10)
	subtitle_lbl.add_theme_color_override("font_color", Color(0.712, 0.675, 0.525, 0.75))
	title_vbox.add_child(subtitle_lbl)

	btn_header_hud = Button.new()
	btn_header_hud.text = "HIDE HUD & HANDS"
	if font: btn_header_hud.add_theme_font_override("font", font)
	btn_header_hud.add_theme_font_size_override("font_size", 12)
	btn_header_hud.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn_header_hud.pressed.connect(func():
		Game.hide_hud = not Game.hide_hud
		_sync_hud_state()
		_print("HUD & Hands: " + ("[color=#e8702c]HIDDEN (Screenshot Mode)[/color]" if Game.hide_hud else "[color=#5de08f]VISIBLE[/color]"))
	)
	header.add_child(btn_header_hud)

	var close_btn := Button.new()
	close_btn.text = "[ESC] CLOSE"
	if font: close_btn.add_theme_font_override("font", font)
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_btn.add_theme_stylebox_override("normal", _make_box(Color(0.2, 0.08, 0.08, 0.8), Color(0.8, 0.3, 0.3, 0.8), 1, 4, 8))
	close_btn.add_theme_stylebox_override("hover", _make_box(Color(0.35, 0.1, 0.1, 0.95), Color(1.0, 0.4, 0.4, 1.0), 1, 4, 8))
	close_btn.pressed.connect(func(): _toggle(false))
	header.add_child(close_btn)

	# --- Quick Cheats Bar ---
	var quick_bar := HBoxContainer.new()
	quick_bar.add_theme_constant_override("separation", 6)
	main_vbox.add_child(quick_bar)

	btn_noclip = _make_toggle_btn("NOCLIP (FLY)", Color(1.000, 0.680, 0.220), func(on):
		Game.noclip = on
		_sync_quick_buttons()
	)
	btn_fullbright = _make_toggle_btn("FULLBRIGHT", Color(1.0, 0.95, 0.3), func(on):
		var pl := _get_player()
		if pl != null and pl.has_method("set_fullbright"):
			pl.set_fullbright(on)
		else:
			Game.fullbright = on
		_sync_quick_buttons()
	)
	btn_godmode = _make_toggle_btn("GOD MODE", Color(1.0, 0.7, 0.15), func(on):
		Game.god_mode = on
		_sync_quick_buttons()
	)
	btn_inf_stamina = _make_toggle_btn("INF STAMINA", Color(0.3, 1.0, 0.45), func(on):
		Game.infinite_stamina = on
		_sync_quick_buttons()
	)
	btn_inf_sanity = _make_toggle_btn("INF SANITY", Color(0.85, 0.4, 1.0), func(on):
		Game.infinite_sanity = on
		var pl := _get_player()
		if pl != null:
			pl.sanity = 100.0
			pl.sanity_lock = 100.0 if on else -1.0
		_sync_quick_buttons()
	)
	btn_inf_torch = _make_toggle_btn("INF TORCH", Color(1.0, 0.8, 0.25), func(on):
		Game.infinite_battery = on
		var pl := _get_player()
		if pl != null and on: pl.battery = 100.0
		_sync_quick_buttons()
	)

	quick_bar.add_child(btn_noclip)
	quick_bar.add_child(btn_fullbright)
	quick_bar.add_child(btn_godmode)
	quick_bar.add_child(btn_inf_stamina)
	quick_bar.add_child(btn_inf_sanity)
	quick_bar.add_child(btn_inf_torch)

	# --- Tab Navigation Bar ---
	var nav_bar := HBoxContainer.new()
	nav_bar.add_theme_constant_override("separation", 6)
	main_vbox.add_child(nav_bar)

	var tabs := [
		{"id": "cheats", "label": "PLAYER"},
		{"id": "entities", "label": "ENTITIES"},
		{"id": "world", "label": "EVENTS"},
		{"id": "teleport", "label": "TELEPORT"},
		{"id": "game", "label": "LEVEL & GAME"},
		{"id": "anim", "label": "ANIMATION"},
		{"id": "console", "label": "CONSOLE"}
	]
	for t in tabs:
		var tb := Button.new()
		tb.text = t["label"]
		if font: tb.add_theme_font_override("font", font)
		tb.add_theme_font_size_override("font_size", 12)
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tb.pressed.connect(_switch_tab.bind(t["id"]))
		nav_bar.add_child(tb)
		tab_buttons[t["id"]] = tb

	# --- Tab Content Container ---
	var tab_content := PanelContainer.new()
	tab_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var content_sb := _make_box(Color(0.050, 0.039, 0.020, 0.7), Color(0.400, 0.272, 0.088, 0.4), 1, 4, 10)
	tab_content.add_theme_stylebox_override("panel", content_sb)
	main_vbox.add_child(tab_content)

	tab_panels["cheats"] = _build_cheats_tab()
	tab_panels["entities"] = _build_entities_tab()
	tab_panels["world"] = _build_world_tab()
	tab_panels["teleport"] = _build_teleport_tab()
	tab_panels["game"] = _build_game_tab()
	tab_panels["anim"] = _build_anim_tab()
	tab_panels["console"] = _build_console_tab()

	for k in tab_panels:
		tab_content.add_child(tab_panels[k])

	_switch_tab("cheats")
	_sync_quick_buttons()

# ---------------------------------------------------------------- Tabs Content
# TAB: Animation test. A survivor suit walking on the same Locomotion teammates use, pacing a short lane
# beside you. The window would hide it: a move or head test closes the menu; gait / slow motion don't.
func _build_anim_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	scroll.add_child(v)

	v.add_child(_label("A survivor walks a %d m lane in front of you, turns round at each end and keeps the same step." % int(AnimWalker.LANE), 12, Color(0.807, 0.765, 0.595)))
	v.add_child(_label("Menu closed:  [ ]  previous / next move     ;  walk / run / crouch     '  next head test     /  slow motion", 11, Color(0.617, 0.585, 0.455)))
	walker_status = _label("WALKER: none", 12, Color(0.95, 0.85, 0.5))
	v.add_child(walker_status)

	v.add_child(_section_header("WALKER"))
	var top := HFlowContainer.new()
	top.add_theme_constant_override("h_separation", 8)
	top.add_theme_constant_override("v_separation", 6)
	v.add_child(top)
	top.add_child(_action_btn("SUMMON HERE", func(): _walker_summon(true)))
	top.add_child(_action_btn("DISMISS", func(): _walker_off()))
	top.add_child(_action_btn("DIE", func(): _walker_do(func(w): w.dead = true, true)))
	top.add_child(_action_btn("NECK SNAP (MANNEQUIN)", func(): _walker_do(_walker_snap, true)))
	top.add_child(_action_btn("REVIVE", func(): _walker_do(func(w): w.revive(), true)))
	btn_walker_slow = _make_toggle_btn("SLOW MOTION 0.25x", Color(0.85, 0.6, 1.0), func(on):
		_walker_do(func(w): w.time_scale = 0.25 if on else 1.0, false))
	top.add_child(btn_walker_slow)

	v.add_child(_section_header("GAIT"))
	var gaits := HFlowContainer.new()
	gaits.add_theme_constant_override("h_separation", 8)
	v.add_child(gaits)
	for g in AnimWalker.GAITS:
		gaits.add_child(_action_btn(str(g).to_upper(), func(): _walker_do(func(w): w.set_gait(g), false)))

	v.add_child(_section_header("MOVES (MENU CLOSES TO WATCH)"))
	var moves := HFlowContainer.new()
	moves.add_theme_constant_override("h_separation", 8)
	moves.add_theme_constant_override("v_separation", 6)
	v.add_child(moves)
	for m in AnimWalker.MOVES:
		moves.add_child(_action_btn(AnimWalker.MOVES[m][0], func(): _walker_do(func(w): w.set_move(m), true)))

	v.add_child(_section_header("HEAD (STANDS, FACES YOU, THEN LOOKS)"))
	var looks := HFlowContainer.new()
	looks.add_theme_constant_override("h_separation", 8)
	looks.add_theme_constant_override("v_separation", 6)
	v.add_child(looks)
	for l in AnimWalker.LOOKS:
		looks.add_child(_action_btn(AnimWalker.LOOKS[l][0], func(): _walker_do(func(w): w.set_look(l), true)))

	v.add_child(_section_header("RAW CLIPS (IN PLACE, NO BLENDING)"))
	var raw := HFlowContainer.new()
	raw.add_theme_constant_override("h_separation", 8)
	v.add_child(raw)
	raw.add_child(_action_btn("SHOW / HIDE  (M)", func(): _model_command("")))
	raw.add_child(_action_btn("PREVIOUS CLIP  (,)", func(): _model_command("prev")))
	raw.add_child(_action_btn("NEXT CLIP  (.)", func(): _model_command("next")))
	return scroll

# TAB 1: Cheats & Player
func _build_cheats_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	scroll.add_child(v)

	v.add_child(_section_header("MOVEMENT & SPEED BOOSTS"))

	# Speed Slider & Presets
	var speed_box := VBoxContainer.new()
	speed_box.add_theme_constant_override("separation", 4)
	v.add_child(speed_box)

	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 10)
	speed_box.add_child(speed_row)

	speed_label = Label.new()
	speed_label.text = "MOVEMENT / FLY SPEED: 1.0x"
	if font: speed_label.add_theme_font_override("font", font)
	speed_label.add_theme_font_size_override("font_size", 12)
	speed_label.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	speed_row.add_child(speed_label)

	for s in [1.0, 1.5, 2.0, 3.0, 5.0]:
		var pb := Button.new()
		pb.text = "%.1fx" % s
		if font: pb.add_theme_font_override("font", font)
		pb.add_theme_font_size_override("font_size", 11)
		pb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		pb.pressed.connect(func(): _set_speed(s))
		speed_row.add_child(pb)

	speed_slider = HSlider.new()
	speed_slider.min_value = 0.5
	speed_slider.max_value = 5.0
	speed_slider.step = 0.25
	speed_slider.value = Game.speed_mult
	speed_slider.value_changed.connect(func(val): _set_speed(val))
	speed_box.add_child(speed_slider)

	# Jump Slider & Presets
	var jump_box := VBoxContainer.new()
	jump_box.add_theme_constant_override("separation", 4)
	v.add_child(jump_box)

	var jump_row := HBoxContainer.new()
	jump_row.add_theme_constant_override("separation", 10)
	jump_box.add_child(jump_row)

	jump_label = Label.new()
	jump_label.text = "JUMP HEIGHT BOOST: 1.0x"
	if font: jump_label.add_theme_font_override("font", font)
	jump_label.add_theme_font_size_override("font_size", 12)
	jump_label.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	jump_row.add_child(jump_label)

	for j in [1.0, 1.5, 2.0, 3.0]:
		var jb := Button.new()
		jb.text = "%.1fx" % j
		if font: jb.add_theme_font_override("font", font)
		jb.add_theme_font_size_override("font_size", 11)
		jb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		jb.pressed.connect(func(): _set_jump(j))
		jump_row.add_child(jb)

	jump_slider = HSlider.new()
	jump_slider.min_value = 1.0
	jump_slider.max_value = 3.0
	jump_slider.step = 0.25
	jump_slider.value = Game.jump_mult
	jump_slider.value_changed.connect(func(val): _set_jump(val))
	jump_box.add_child(jump_slider)

	v.add_child(_section_header("INSTANT RESTORE & EQUIPMENT REFILLS"))

	var refills := HBoxContainer.new()
	refills.add_theme_constant_override("separation", 8)
	v.add_child(refills)

	refills.add_child(_action_btn("RESTORE 100% HEALTH", func():
		var pl := _get_player()
		if pl != null: pl.health = 100.0
	))
	refills.add_child(_action_btn("RESTORE 100% SANITY", func():
		var pl := _get_player()
		if pl != null:
			pl.sanity = 100.0
			pl.insanity = 0.0
	))
	refills.add_child(_action_btn("+5 CAMERA FLASHES", func(): _refill_flash()))
	refills.add_child(_action_btn("+300M HAZARD TAPE", func(): _refill_tape()))

	# The arms can't be seen behind this window: a button closes it, then plays its clip
	v.add_child(_section_header("HAND ANIMATION TEST (MENU CLOSES TO PLAY • PRESS P TO PLAY THE LAST ONE AGAIN)"))
	var hands_row := HBoxContainer.new()
	hands_row.add_theme_constant_override("separation", 8)
	v.add_child(hands_row)
	for what in HAND_ANIMS:
		hands_row.add_child(_action_btn(HAND_ANIM_LABELS[what], func(): _hand_anim(what)))

	v.add_child(_section_header("HUD & SCREENSHOTS"))
	var hud_row := HBoxContainer.new()
	hud_row.add_theme_constant_override("separation", 8)
	v.add_child(hud_row)

	btn_toggle_hud = _make_toggle_btn("HIDE ALL HUD & HANDS (SCREENSHOT MODE)", Color(1.000, 0.680, 0.220), func(on):
		Game.hide_hud = on
		_sync_hud_state()
		_print("HUD & Hands: " + ("[color=#e8702c]HIDDEN (Screenshot Mode)[/color]" if Game.hide_hud else "[color=#5de08f]VISIBLE[/color]"))
	)
	hud_row.add_child(btn_toggle_hud)

	var snap_btn := _action_btn("TAKE SCREENSHOT", func():
		_take_screenshot()
	)
	hud_row.add_child(snap_btn)

	var hud_btn := _action_btn("TOGGLE TELEMETRY OVERLAY", func():
		Game.show_debug_overlay = not Game.show_debug_overlay
	)
	hud_row.add_child(hud_btn)

	var crash_btn := _action_btn("SHOW LAST CRASH", func():
		if not Crash.show_last_crash():
			_print("[color=#e8702c]no crash report saved yet[/color]")
	)
	hud_row.add_child(crash_btn)

	return scroll

# TAB 2: Entities & Behavior
func _build_entities_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)

	v.add_child(_section_header("MASTER MONSTER CONTROLS"))
	btn_freeze_ai = _make_toggle_btn("FREEZE ALL MONSTERS (PAUSE)", Color(1.000, 0.680, 0.220), func(on):
		Game.freeze_ai = on
		_sync_quick_buttons()
	)
	v.add_child(btn_freeze_ai)

	v.add_child(_section_header("INDIVIDUAL ENTITY SPAWN & CONTROLS"))

	# Bacteria Row
	var bac_box := HBoxContainer.new()
	bac_box.add_theme_constant_override("separation", 8)
	v.add_child(bac_box)
	bac_box.add_child(_label("BACTERIA (HOWLER):", 12, Color(0.9, 0.8, 0.6), 160))
	bac_box.add_child(_action_btn("SPAWN", func(): _apply("bacteria", true)))
	bac_box.add_child(_action_btn("DESPAWN", func(): _apply("bacteria", false)))
	bac_box.add_child(_action_btn("FORCE STALK", func():
		var ent = root.get_node_or_null("Entity")
		if ent and ent.has_method("debug_stalk"):
			_print("Bacteria stalk: %s" % str(ent.debug_stalk()))
	))

	# Mannequin Row
	var man_box := HBoxContainer.new()
	man_box.add_theme_constant_override("separation", 8)
	v.add_child(man_box)
	man_box.add_child(_label("MANNEQUIN:", 12, Color(0.9, 0.8, 0.6), 160))
	man_box.add_child(_action_btn("SPAWN / WARP", func():
		var m = root.get_node_or_null("Mannequin")
		if m and m.has_method("warp_to_room"): m.warp_to_room()
	))
	man_box.add_child(_action_btn("DESPAWN", func(): _apply("mannequin", false)))
	man_box.add_child(_action_btn("SNAP MY NECK NOW", func():
		var m = root.get_node_or_null("Mannequin")
		if m == null or not m.has_method("debug_snap_now"): return
		if not m.debug_snap_now(): _print("Mannequin: no mannequin in this level to snap with")
	))
	man_box.add_child(_action_btn("WATCH A FRIEND DIE", func(): _watch_kill()))
	man_box.add_child(_action_btn("FAR DEATH", func(): _friend_death_sound(true)))
	man_box.add_child(_action_btn("NEAR DEATH", func(): _friend_death_sound(false)))

	# Mimic Row
	var mim_box := HBoxContainer.new()
	mim_box.add_theme_constant_override("separation", 8)
	v.add_child(mim_box)
	mim_box.add_child(_label("MIMIC (SURVIVOR):", 12, Color(0.9, 0.8, 0.6), 160))
	mim_box.add_child(_action_btn("SPAWN", func(): _apply("mimic", true)))
	mim_box.add_child(_action_btn("DESPAWN", func(): _apply("mimic", false)))

	# Eyes Row
	var eyes_box := VBoxContainer.new()
	eyes_box.add_theme_constant_override("separation", 4)
	v.add_child(eyes_box)

	var eyes_row := HBoxContainer.new()
	eyes_row.add_theme_constant_override("separation", 8)
	eyes_box.add_child(eyes_row)
	eyes_row.add_child(_label("EYES IN THE DARK:", 12, Color(0.9, 0.8, 0.6), 160))

	eyes_count_label = _label("COUNT: AUTO", 12, Color(0.855, 0.810, 0.630), 110)
	eyes_row.add_child(eyes_count_label)
	eyes_row.add_child(_action_btn("AUTO (SANITY)", func():
		var ey = root.get_node_or_null("Eyes")
		if ey: ey.debug_auto(); eyes_count_label.text = "COUNT: AUTO"
	))
	eyes_row.add_child(_action_btn("CLEAR ALL", func():
		var ey = root.get_node_or_null("Eyes")
		if ey: ey.debug_clear(); eyes_count_label.text = "COUNT: 0"
	))

	eyes_slider = HSlider.new()
	eyes_slider.min_value = 0
	eyes_slider.max_value = 8
	eyes_slider.step = 1
	eyes_slider.value_changed.connect(func(v):
		var ey = root.get_node_or_null("Eyes")
		if ey:
			ey.debug_set(int(v))
			eyes_count_label.text = "COUNT: %d" % int(v)
	)
	eyes_box.add_child(eyes_slider)

	# Killer Row
	var kil_box := HBoxContainer.new()
	kil_box.add_theme_constant_override("separation", 8)
	v.add_child(kil_box)
	kil_box.add_child(_label("KILLER (TEST MESH):", 12, Color(0.9, 0.8, 0.6), 160))
	kil_box.add_child(_action_btn("SPAWN", func(): _apply("killer", true)))
	kil_box.add_child(_action_btn("DESPAWN", func(): _apply("killer", false)))

	# Skin Stealer (a model only for now) & the Burnt (stalks you; burnt.gd), stood in front of you
	for row in [["SKIN STEALER (MODEL):", "skinstealer"], ["THE BURNT:", "burnt"]]:
		var mdl_box := HBoxContainer.new()
		mdl_box.add_theme_constant_override("separation", 8)
		v.add_child(mdl_box)
		mdl_box.add_child(_label(row[0], 12, Color(0.9, 0.8, 0.6), 160))
		mdl_box.add_child(_action_btn("SPAWN", func(): _apply(row[1], true)))
		mdl_box.add_child(_action_btn("DESPAWN", func(): _apply(row[1], false)))
		if row[1] == "burnt":
			for act in BURNT_ACTIONS:
				mdl_box.add_child(_action_btn(act.to_upper(), func(): _burnt(act)))

	# the model-only entities and characters (entity_roster.gd): stood in front of you, no AI
	for grp in [["entity", "MODEL ENTITIES (NO AI)"], ["new", "NEW ENTITIES (NO AI YET)"], ["character", "CHARACTERS (NO AI)"]]:
		v.add_child(_label(grp[1], 12, Color(0.902, 0.855, 0.665)))
		for id: String in EntityRoster.ROSTER:
			var e: Array = EntityRoster.ROSTER[id]
			if e[3] != grp[0]: continue
			var r_box := HBoxContainer.new()
			r_box.add_theme_constant_override("separation", 8)
			v.add_child(r_box)
			r_box.add_child(_label(str(e[0]).to_upper() + ":", 12, Color(0.9, 0.8, 0.6), 160))
			r_box.add_child(_action_btn("SPAWN", func(): _roster_apply(id, true)))
			r_box.add_child(_action_btn("DESPAWN", func(): _roster_apply(id, false)))

	# Grabber Row: spawn it on the ceiling ahead, or drop it straight into a state
	var grb_box := HBoxContainer.new()
	grb_box.add_theme_constant_override("separation", 8)
	v.add_child(grb_box)
	grb_box.add_child(_label("GRABBER:", 12, Color(0.9, 0.8, 0.6), 160))
	grb_box.add_child(_action_btn("SPAWN", func(): _apply("grabber", true)))
	grb_box.add_child(_action_btn("DESPAWN", func(): _apply("grabber", false)))
	for st in GRABBER_STATES:
		grb_box.add_child(_action_btn(st.to_upper(), func(): _grabber_state(st)))

	# The Tall One (tall_one.gd): spawn it ahead (it sees you and runs), or drop into the scream / the hunt
	var tal_box := HBoxContainer.new()
	tal_box.add_theme_constant_override("separation", 8)
	v.add_child(tal_box)
	tal_box.add_child(_label("THE TALL ONE:", 12, Color(0.9, 0.8, 0.6), 160))
	tal_box.add_child(_action_btn("SPAWN", func(): _apply("tallone", true)))
	tal_box.add_child(_action_btn("DESPAWN", func(): _apply("tallone", false)))
	tal_box.add_child(_action_btn("SCREAM", func(): _tallone("debug_scream")))
	tal_box.add_child(_action_btn("HUNT", func(): _tallone("debug_hunt")))

	# All Monsters Action
	var all_box := HBoxContainer.new()
	all_box.add_theme_constant_override("separation", 8)
	v.add_child(all_box)
	all_box.add_child(_label("BATCH ACTIONS:", 12, Color(0.9, 0.8, 0.6), 160))
	all_box.add_child(_action_btn("SPAWN ALL", func(): _each("all", true)))
	all_box.add_child(_action_btn("DESPAWN ALL", func(): _each("all", false)))

	return scroll

# TAB 3: World & Events
func _build_world_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)

	v.add_child(_section_header("LEVEL"))
	var level_row := HBoxContainer.new()
	level_row.add_theme_constant_override("separation", 8)
	v.add_child(level_row)
	# Re-reads the .lvl from disk, so the latest level editor save shows up without restarting the game.
	level_row.add_child(_action_btn("RELOAD LEVEL (LATEST EDITOR SAVE)", func():
		Game.change_level(Game.level_index)
	))

	v.add_child(_section_header("EVENT DIRECTOR"))
	v.add_child(_build_event_panel())

	v.add_child(_section_header("T.S.R.A. PROGRESSION & ARCHIVES"))
	var prog_row := HBoxContainer.new()
	prog_row.add_theme_constant_override("separation", 8)
	v.add_child(prog_row)

	prog_row.add_child(_action_btn("GRANT MAX CLEARANCE (TIER 4)", func():
		Clearance.grant(1200)
		_print("Granted Clearance Tier 4.")
	))
	prog_row.add_child(_action_btn("UNLOCK ALL DOSSIERS", func():
		for id in Archive.entities():
			Archive.discover(str(id))
		_print("Unlocked all entity dossiers in Archive.")
	))
	prog_row.add_child(_action_btn("RESET CLEARANCE & ARCHIVE", func():
		Clearance.reset()
		Archive.forget_all()
		_print("Clearance and Archive reset.")
	))

	return scroll

# TAB 4: Teleportation
func _build_teleport_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)

	v.add_child(_section_header("WARP DESTINATIONS"))
	var warp_row := HBoxContainer.new()
	warp_row.add_theme_constant_override("separation", 8)
	v.add_child(warp_row)

	warp_row.add_child(_action_btn("WARP: LEVEL SPAWN", func():
		var pl := _get_player()
		var lvl = root.get_node_or_null("Level")
		if pl != null and lvl != null and "spawn_pos" in lvl:
			pl.global_position = lvl.spawn_pos
	))
	warp_row.add_child(_action_btn("WARP: MANNEQUIN ROOM", func():
		var man = root.get_node_or_null("Mannequin")
		if man and man.has_method("warp_to_room"): man.warp_to_room()
	))
	warp_row.add_child(_action_btn("WARP: TO BACTERIA", func():
		var pl := _get_player()
		var ent = root.get_node_or_null("Entity")
		if pl != null and ent != null and ent.is_inside_tree():
			pl.global_position = ent.global_position + Vector3(0, 0, 5)
	))
	warp_row.add_child(_action_btn("WARP: +5M UP (CEILING)", func():
		var pl := _get_player()
		if pl != null: pl.global_position.y += 5.0
	))

	v.add_child(_section_header("WARP TO CUSTOM COORDINATES"))
	var coord_row := HBoxContainer.new()
	coord_row.add_theme_constant_override("separation", 8)
	v.add_child(coord_row)

	coord_row.add_child(_label("X:", 12, Color.WHITE, 20))
	tp_x_input = LineEdit.new()
	tp_x_input.placeholder_text = "0.0"
	tp_x_input.custom_minimum_size = Vector2(80, 0)
	coord_row.add_child(tp_x_input)

	coord_row.add_child(_label("Z:", 12, Color.WHITE, 20))
	tp_z_input = LineEdit.new()
	tp_z_input.placeholder_text = "0.0"
	tp_z_input.custom_minimum_size = Vector2(80, 0)
	coord_row.add_child(tp_z_input)

	coord_row.add_child(_action_btn("TELEPORT TO (X, Z)", func():
		var pl := _get_player()
		if pl != null and tp_x_input.text.is_valid_float() and tp_z_input.text.is_valid_float():
			_tp_to(Vector3(tp_x_input.text.to_float(), pl.global_position.y, tp_z_input.text.to_float()))
	))
	coord_row.add_child(_action_btn("FILL FROM ME", func():
		var pl := _get_player() as Node3D
		if pl != null:
			tp_x_input.text = "%.1f" % pl.global_position.x
			tp_z_input.text = "%.1f" % pl.global_position.z
	))
	coord_row.add_child(_action_btn("COPY POSITION", func(): _copy_position()))

	v.add_child(_section_header("NUDGE (METRES, RELATIVE TO WHERE YOU FACE)"))
	var nudge := HFlowContainer.new()
	nudge.add_theme_constant_override("h_separation", 6)
	v.add_child(nudge)
	for d in [["FWD 5", Vector3(0, 0, -5)], ["BACK 5", Vector3(0, 0, 5)], ["LEFT 5", Vector3(-5, 0, 0)], ["RIGHT 5", Vector3(5, 0, 0)],
			["UP 2", Vector3(0, 2, 0)], ["DOWN 2", Vector3(0, -2, 0)], ["FWD 20", Vector3(0, 0, -20)]]:
		nudge.add_child(_action_btn(d[0], func():
			var pl := _get_player() as Node3D
			if pl != null:
				_tp_to(pl.global_position + pl.global_transform.basis * (d[1] as Vector3))))
	nudge.add_child(_action_btn("BACK TO BEFORE LAST WARP", func(): _tp_undo()))

	v.add_child(_section_header("BOOKMARKS (THIS RUN)"))
	var mark_row := HBoxContainer.new()
	mark_row.add_theme_constant_override("separation", 8)
	v.add_child(mark_row)
	var mark_name := LineEdit.new()
	mark_name.placeholder_text = "name (optional)"
	mark_name.custom_minimum_size = Vector2(180, 0)
	_style_line_edit(mark_name)
	mark_row.add_child(mark_name)
	mark_row.add_child(_action_btn("MARK HERE", func():
		_mark_here(mark_name.text.strip_edges())
		mark_name.clear()))
	mark_row.add_child(_action_btn("CLEAR ALL", func():
		marks.clear()
		_refresh_marks()))
	marks_flow = HFlowContainer.new()
	marks_flow.add_theme_constant_override("h_separation", 6)
	marks_flow.add_theme_constant_override("v_separation", 6)
	v.add_child(marks_flow)
	_refresh_marks()

	return scroll

# TAB: command line
func _build_console_tab() -> Control:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 6)

	var log_box := PanelContainer.new()
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_box.add_theme_stylebox_override("panel", _make_box(Kit.FILL, Color(AMBER, 0.35), 1, 0, 8))
	v.add_child(log_box)
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.scroll_following = true
	log_label.selection_enabled = true
	log_label.add_theme_font_override("normal_font", Kit.font(1))
	log_label.add_theme_font_override("bold_font", Kit.font(1))
	log_label.add_theme_font_override("mono_font", Kit.font(0))
	log_label.add_theme_font_size_override("normal_font_size", 15)
	log_label.add_theme_font_size_override("bold_font_size", 15)
	log_label.add_theme_font_size_override("mono_font_size", 15)
	log_label.add_theme_color_override("default_color", TEXT)
	log_box.add_child(log_label)

	hint_label = _label("", 12, MUTED)
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint_label)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	v.add_child(line)
	line.add_child(_label(">", 18, AMBER))
	input = LineEdit.new()
	input.placeholder_text = "type a command  (TAB completes, UP/DOWN recalls, help lists)"
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.text_submitted.connect(_submit)
	input.text_changed.connect(_update_hint)
	_style_line_edit(input)
	line.add_child(input)

	var chips_row := HFlowContainer.new()
	chips_row.add_theme_constant_override("h_separation", 6)
	chips_row.add_theme_constant_override("v_separation", 4)
	v.add_child(chips_row)
	for cmd in ["help", "list", "pos", "marks", "levels", "events", "hud", "spawn all", "kill all", "screenshot", "lightout", "lighton", "entities", "clear"]:
		chips_row.add_child(_action_btn(cmd, func():
			input.text = cmd
			_submit(cmd)))
	_update_hint("")
	return v

func _style_line_edit(le: LineEdit) -> void:
	le.add_theme_font_override("font", Kit.font(1))
	le.add_theme_font_size_override("font_size", 15)
	le.add_theme_color_override("font_color", TEXT)
	le.add_theme_color_override("caret_color", AMBER)
	le.add_theme_color_override("font_placeholder_color", Color(TEXT, 0.3))
	le.add_theme_stylebox_override("normal", _make_box(Kit.FILL, Color(AMBER, 0.35), 1, 0, 6))
	le.add_theme_stylebox_override("focus", _make_box(Kit.FILL, AMBER, 1, 0, 6))

# ---------------------------------------------------------------- command table, completion
## name -> [usage, what it does]; grouped for `help`
const COMMANDS := {
	"help": ["[command]", "list the commands, or describe one"],
	"clear": ["", "empty the log"],
	"copy": ["", "copy the log to the clipboard"],
	"echo": ["<text>", "print text (a note for a screenshot)"],
	"noclip": ["", "fly through walls"],
	"god": ["", "nothing can kill you"],
	"invisible": ["", "hidden from players and monsters (god too)"],
	"fullbright": ["", "light everything"],
	"stamina": ["", "infinite stamina"],
	"sanity": ["<0-100|off>", "set or pin sanity"],
	"health": ["<0-100>", "set health"],
	"heal": ["", "health, sanity, stamina, torch to full"],
	"battery": ["<0-100>", "torch charge"],
	"speed": ["<0.5-10>", "movement multiplier"],
	"suicide": ["", "kill yourself (the death screen)"],
	"spawn": ["<entity|all>", "stand an entity in front of you"],
	"despawn": ["<entity|all>", "take it away"],
	"kill": ["<entity|all>", "same as despawn"],
	"list": ["", "which entities are active"],
	"entities": ["", "every entity's tier and distance"],
	"freeze": ["", "stop every monster"],
	"stalk": ["", "send the bacteria stalking"],
	"eyes": ["[n|off|auto|clear]", "the watchers in the dark"],
	"grabber": ["<hunch|peek|chase|drag>", "the grabber, into a state"],
	"burnt": ["<peek|retreat|hide|charge|flank|commit|grab|status>", "the burnt, into a move (status: why it isn't)"],
	"tallone": ["<scream|hunt>", "the tall one, into a state"],
	"events": ["", "list the scare events"],
	"event": ["<name|stop>", "fire a scare event, or end them all"],
	"lightout": ["", "blackout"],
	"lighton": ["", "restore the grid"],
	"tp": ["<x z | spawn | mannequin>", "teleport"],
	"pos": ["", "where you are (copied too)"],
	"mark": ["[name]", "bookmark this spot"],
	"goto": ["<name>", "go to a bookmark"],
	"back": ["", "return to before the last teleport"],
	"marks": ["", "list the bookmarks"],
	"levels": ["", "list the playlist"],
	"level": ["<number|id|next>", "load a level"],
	"reload": ["", "reload this level from disk"],
	"timescale": ["<0.05-4>", "slow motion / fast forward"],
	"gfx": ["[low|medium|high|ultra]", "graphics preset"],
	"overlay": ["", "toggle the telemetry overlay"],
	"hud": ["[on|off]", "hide / show the HUD and hands"],
	"hands": ["[on|off]", "hide / show the hands"],
	"screenshot": ["", "save a PNG to user://screenshots"],
	"amb": ["[status|silence <s>|bed]", "ambience"],
	"archive": ["[list|reset]", "entity dossiers"],
	"clearance": ["[reset|add <n>]", "clearance tier"],
	"anim": ["<name>", "play a first-person hand clip"],
	"walker": ["[move|gait|look|die|snap|revive|slow|off]", "animation test survivor"],
	"model": ["[next|prev|off|clip]", "raw survivor clips"],
	"watchkill": ["", "a friend's death by the mannequin"],
	"fardeath": ["", "a friend dies far away"],
	"neardeath": ["", "a friend dies near you"],
	"lastcrash": ["", "show the last crash report"],
	"crash": ["", "take the game down on purpose"],
}
const HELP_GROUPS := [
	["CONSOLE", ["help", "clear", "copy", "echo"]],
	["PLAYER", ["noclip", "god", "invisible", "fullbright", "stamina", "sanity", "health", "heal", "battery", "speed", "suicide"]],
	["ENTITIES", ["spawn", "despawn", "kill", "list", "entities", "freeze", "stalk", "eyes", "grabber", "burnt", "tallone"]],
	["EVENTS & WORLD", ["events", "event", "lightout", "lighton"]],
	["MOVEMENT", ["tp", "pos", "mark", "goto", "back", "marks"]],
	["LEVEL & GAME", ["levels", "level", "reload", "timescale", "gfx", "overlay"]],
	["SCREEN", ["hud", "hands", "screenshot"]],
	["TESTING", ["amb", "archive", "clearance", "anim", "walker", "model", "watchkill", "fardeath", "neardeath", "lastcrash", "crash"]],
]

func _matches(prefix: String) -> Array:
	var out: Array = []
	for k in COMMANDS:
		if str(k).begins_with(prefix):
			out.append(k)
	out.sort()
	return out

func _update_hint(text: String) -> void:
	if hint_label == null:
		return
	var t := text.strip_edges(false, true).to_lower()
	if t == "":
		hint_label.text = "TAB complete   //   UP / DOWN history   //   help"
		return
	var first := t.get_slice(" ", 0)
	if t.contains(" ") and COMMANDS.has(first):
		hint_label.text = "%s %s   -   %s" % [first, COMMANDS[first][0], COMMANDS[first][1]]
		return
	var m := _matches(first)
	if m.is_empty():
		hint_label.text = "no command starts with '%s'" % first
		return
	var bits: PackedStringArray = []
	for k in m.slice(0, 8):
		bits.append("%s %s" % [k, COMMANDS[k][0]])
	hint_label.text = "   |   ".join(bits) + ("   ..." if m.size() > 8 else "")

func _complete() -> void:
	var t := input.text.to_lower()
	if t.contains(" "):
		var cmd := t.get_slice(" ", 0)
		var arg := t.substr(cmd.length() + 1)
		var pool: Array = []
		match cmd:
			"spawn", "despawn", "kill": pool = ORDER + EntityRoster.ROSTER.keys() + ["all"]
			"event": pool = EVENTS.keys() + ["stop"]
			"goto": pool = marks.keys()
			"gfx": pool = Gfx.PRESETS.keys()
			"grabber": pool = GRABBER_STATES
			"anim": pool = HAND_ANIMS.keys()
		var hits := pool.filter(func(k): return str(k).begins_with(arg))
		if hits.size() == 1:
			input.text = "%s %s" % [cmd, hits[0]]
		elif hits.size() > 1:
			_print("[color=#b3a57a]%s[/color]" % "  ".join(hits))
	else:
		var m := _matches(t)
		if m.size() == 1:
			input.text = str(m[0]) + " "
		elif m.size() > 1:
			var common := str(m[0])
			for k in m:
				while not str(k).begins_with(common):
					common = common.left(common.length() - 1)
			input.text = common
			_print("[color=#b3a57a]%s[/color]" % "  ".join(m))
	input.caret_column = input.text.length()
	_update_hint(input.text)

func _help(arg: String) -> void:
	if arg != "" and COMMANDS.has(arg):
		_print("[color=#f0a838]%s[/color] %s" % [arg, COMMANDS[arg][0]])
		_print("  " + str(COMMANDS[arg][1]))
		return
	for g in HELP_GROUPS:
		_print("[color=#f0a838]-- %s --[/color]" % g[0])
		for k in g[1]:
			_print("  [color=#dccd9f]%-10s[/color] [color=#b3a57a]%-26s[/color] %s" % [k, COMMANDS[k][0], COMMANDS[k][1]])
	_print("Entities: " + ", ".join(ORDER) + "   Models: " + ", ".join(EntityRoster.ROSTER.keys()))
	_print("Hands: " + ", ".join(HAND_ANIMS.keys()))

# ---------------------------------------------------------------- LEVEL & GAME tab
func _build_game_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)

	v.add_child(_section_header("LEVELS"))
	var lv := HFlowContainer.new()
	lv.add_theme_constant_override("h_separation", 6)
	lv.add_theme_constant_override("v_separation", 6)
	v.add_child(lv)
	level_buttons.clear()
	var idx := 0
	for l in LevelData.read_index():
		var i := idx
		var b := _action_btn("%d  %s" % [i, str(l.get("name", l.get("id", "?")))], func(): _load_level(i))
		lv.add_child(b)
		level_buttons.append(b)
		idx += 1
	var lrow := HBoxContainer.new()
	lrow.add_theme_constant_override("separation", 8)
	v.add_child(lrow)
	lrow.add_child(_action_btn("RELOAD (LATEST EDITOR SAVE)", func(): _load_level(Game.level_index)))
	lrow.add_child(_action_btn("NEXT LEVEL", func(): _load_level(Game.level_index + 1)))

	v.add_child(_section_header("TIME"))
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 8)
	v.add_child(trow)
	time_label = _label("TIME SCALE: 1.00x", 12, TEXT, 190)
	trow.add_child(time_label)
	for t in [0.1, 0.25, 0.5, 1.0, 2.0, 4.0]:
		trow.add_child(_action_btn("%sx" % str(t), func(): _set_time_scale(t)))
	time_slider = HSlider.new()
	time_slider.min_value = 0.05
	time_slider.max_value = 4.0
	time_slider.step = 0.05
	time_slider.value = Engine.time_scale
	time_slider.value_changed.connect(func(x): _set_time_scale(x))
	v.add_child(time_slider)

	v.add_child(_section_header("GRAPHICS PRESET"))
	var grow := HBoxContainer.new()
	grow.add_theme_constant_override("separation", 8)
	v.add_child(grow)
	for k in Gfx.PRESETS:
		grow.add_child(_action_btn(str(k).to_upper(), func():
			Gfx.set_preset(k)
			_print("graphics: " + k)))
	grow.add_child(_action_btn("TOGGLE VHS", func(): Gfx.set_vhs(not Gfx.vhs)))
	grow.add_child(_action_btn("TOGGLE CCTV", func(): Gfx.set_cctv(not Gfx.cctv)))

	v.add_child(_section_header("RUN"))
	var rrow := HFlowContainer.new()
	rrow.add_theme_constant_override("h_separation", 8)
	rrow.add_theme_constant_override("v_separation", 6)
	v.add_child(rrow)
	rrow.add_child(_action_btn("FULL HEAL", func(): _heal()))
	rrow.add_child(_action_btn("KILL ME (DEATH SCREEN)", func(): Game.kill_player("debug console")))
	rrow.add_child(_action_btn("ENTITY REPORT", func(): _entity_report()))
	rrow.add_child(_action_btn("PRINT POSITION", func(): _copy_position()))
	rrow.add_child(_action_btn("OPEN SCREENSHOT FOLDER", func():
		DirAccess.make_dir_recursive_absolute("user://screenshots")
		OS.shell_open(ProjectSettings.globalize_path("user://screenshots"))))
	return scroll

func _refresh_game_tab() -> void:
	for i in level_buttons.size():
		var on: bool = i == Game.level_index
		var b: Button = level_buttons[i]
		b.add_theme_stylebox_override("normal", _make_box(Color(AMBER, 0.2) if on else Color(0.06, 0.05, 0.03, 0.85), Color(AMBER, 1.0 if on else 0.4), 1, 0, 6))
	if time_label:
		time_label.text = "TIME SCALE: %.2fx" % Engine.time_scale

func _load_level(i: int) -> void:
	var n := LevelData.read_index().size()
	if n == 0:
		return
	i = posmod(i, n)
	var meta: Dictionary = LevelData.read_index()[i]
	_print("loading level %d: %s" % [i, str(meta.get("name", meta.get("id", "?")))])
	_toggle(false)
	Game.change_level(i)

func _set_time_scale(x: float) -> void:
	Engine.time_scale = clampf(x, 0.05, 4.0)
	if time_label: time_label.text = "TIME SCALE: %.2fx" % Engine.time_scale
	if time_slider and not is_equal_approx(time_slider.value, Engine.time_scale): time_slider.value = Engine.time_scale

func _exit_tree() -> void:
	Engine.time_scale = 1.0

func _heal() -> void:
	var pl := _get_player()
	if pl == null: return
	pl.health = 100.0
	pl.sanity = 100.0
	pl.insanity = 0.0
	pl.stamina = 100.0
	pl.battery = 100.0
	_print("health, sanity, stamina and torch restored")

func _entity_report() -> void:
	var any := false
	for e in EntityLOD.entities:
		if is_instance_valid(e):
			any = true
			var tier := EntityLOD.tier_name(e) if e.is_visible_in_tree() or not EntityLOD.is_spawned(e) else "hidden"
			_print("  %-12s %-10s %6.1f m" % [e.name, tier, EntityLOD.distance_of(e)])
	if not any:
		_print("[color=#b3a57a]no entities registered[/color]")

# ---------------------------------------------------------------- teleport helpers, bookmarks
var _tp_back: Array = []          # [position, yaw] before the last teleport

func _tp_to(pos: Vector3) -> void:
	var pl := _get_player() as Node3D
	if pl == null: return
	_tp_back = [pl.global_position, pl.rotation.y]
	pl.global_position = pos
	if "velocity" in pl: pl.velocity = Vector3.ZERO

func _copy_position() -> void:
	var pl := _get_player() as Node3D
	if pl == null: return
	var p := pl.global_position
	var text := "%.2f, %.2f, %.2f" % [p.x, p.y, p.z]
	DisplayServer.clipboard_set(text)
	_print("pos %s  yaw %d  [color=#b3a57a](copied)[/color]" % [text, roundi(rad_to_deg(pl.rotation.y))])

func _mark_here(mark_name: String) -> void:
	var pl := _get_player() as Node3D
	if pl == null: return
	if mark_name == "":
		mark_name = "m%d" % (marks.size() + 1)
	marks[mark_name] = [pl.global_position, pl.rotation.y]
	_refresh_marks()
	_print("marked '%s' at %.1f, %.1f, %.1f" % [mark_name, pl.global_position.x, pl.global_position.y, pl.global_position.z])

func _goto_mark(mark_name: String) -> void:
	if not marks.has(mark_name):
		_print("[color=#e8702c]no bookmark '%s'. marks lists them[/color]" % mark_name)
		return
	var pl := _get_player() as Node3D
	_tp_to(marks[mark_name][0])
	if pl != null: pl.rotation.y = marks[mark_name][1]
	_print("at '%s'" % mark_name)

func _refresh_marks() -> void:
	if marks_flow == null: return
	Kit.clear(marks_flow)
	if marks.is_empty():
		marks_flow.add_child(_label("none yet: MARK HERE, or  mark <name>  on the command line", 11, MUTED))
	for k in marks:
		var name_k: String = k
		marks_flow.add_child(_action_btn("GO: " + name_k, func(): _goto_mark(name_k)))

func _tp_undo() -> void:
	if _tp_back.is_empty():
		_print("[color=#b3a57a]nowhere to go back to[/color]")
		return
	var pl := _get_player() as Node3D
	var to: Vector3 = _tp_back[0]
	_tp_back = [pl.global_position, pl.rotation.y] if pl != null else []
	if pl != null:
		pl.global_position = to
		if "velocity" in pl: pl.velocity = Vector3.ZERO
	_print("back")

# ---------------------------------------------------------------- Quick Helpers & Styles
func _switch_tab(id: String) -> void:
	current_tab = id
	if id == "game" and not level_buttons.is_empty():
		_refresh_game_tab()
	for k in tab_panels:
		tab_panels[k].visible = (k == id)
	for k in tab_buttons:
		var tb: Button = tab_buttons[k]
		var active: bool = (str(k) == id)
		var bg := Color(0.260, 0.203, 0.104, 0.95) if active else Color(0.100, 0.078, 0.040, 0.8)
		var bdr := Color(0.950, 0.646, 0.209, 0.95) if active else Color(0.350, 0.238, 0.077, 0.5)
		tb.add_theme_stylebox_override("normal", _make_box(bg, bdr, 1, 4, 6))
		tb.add_theme_stylebox_override("hover", _make_box(Color(0.300, 0.204, 0.066, 0.95), Color(1.000, 0.680, 0.220, 1.0), 1, 4, 6))
		tb.add_theme_stylebox_override("pressed", _make_box(bg, bdr, 1, 4, 6))
		tb.add_theme_color_override("font_color", Color(0.950, 0.900, 0.700) if active else Color(0.712, 0.675, 0.525))

func _make_toggle_btn(label: String, tint: Color, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = "○ " + label
	if font: btn.add_theme_font_override("font", font)
	btn.add_theme_font_size_override("font_size", 11)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(func():
		var cur := false
		match label:
			"NOCLIP (FLY)": cur = not Game.noclip
			"FULLBRIGHT": cur = not Game.fullbright
			"GOD MODE": cur = not Game.god_mode
			"INF STAMINA": cur = not Game.infinite_stamina
			"INF SANITY": cur = not Game.infinite_sanity
			"INF TORCH": cur = not Game.infinite_battery
			_: cur = not Game.freeze_ai
		callback.call(cur)
	)
	return btn

func _action_btn(label: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = label
	if font: b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", 11)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_stylebox_override("normal", _make_box(Color(0.150, 0.117, 0.060, 0.85), Color(0.450, 0.306, 0.099, 0.7), 1, 4, 6))
	b.add_theme_stylebox_override("hover", _make_box(Color(0.250, 0.195, 0.100, 0.95), Color(0.900, 0.612, 0.198, 1.0), 1, 4, 6))
	b.pressed.connect(callback)
	return b

func _section_header(title: String) -> Control:
	var h := Label.new()
	h.text = "— " + title + " —"
	if font: h.add_theme_font_override("font", font)
	h.add_theme_font_size_override("font_size", 12)
	h.add_theme_color_override("font_color", Color(0.850, 0.578, 0.187))
	return h

func _label(text: String, size := 12, color := Color.WHITE, min_w := 0) -> Label:
	var l := Label.new()
	l.text = text
	if font: l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if min_w > 0: l.custom_minimum_size = Vector2(min_w, 0)
	return l

# ---------------------------------------------------------------- Telemetry Overlay Text
func _update_overlay_text() -> void:
	var fps: int = Engine.get_frames_per_second()
	var pl: Node = _get_player()
	var pos: Vector3 = pl.global_position if pl != null and "global_position" in pl else Vector3.ZERO
	var rot_y: int = roundi(rad_to_deg(pl.rotation.y)) if pl != null and "rotation" in pl else 0
	var spd: float = Vector2(pl.velocity.x, pl.velocity.z).length() if pl != null and "velocity" in pl else 0.0
	var hp: int = int(pl.health) if pl != null and "health" in pl else 100
	var san: int = int(pl.sanity) if pl != null and "sanity" in pl else 100
	var stm: int = int(pl.stamina) if pl != null and "stamina" in pl else 100
	var bat: int = int(pl.battery) if pl != null and "battery" in pl else 100

	var cheats: Array[String] = []
	if Game.noclip: cheats.append("NOCLIP")
	if Game.fullbright: cheats.append("FULLBRIGHT")
	if Game.god_mode: cheats.append("GOD")
	if Game.infinite_stamina: cheats.append("INF-STAM")
	if Game.infinite_sanity: cheats.append("INF-SAN")
	if Game.infinite_battery: cheats.append("INF-BATT")
	if Game.freeze_ai: cheats.append("FROZEN")
	var cheats_str: String = ", ".join(cheats) if not cheats.is_empty() else "NONE"

	var ent: Node = root.get_node_or_null("Entity")
	var ent_str := "AWAY"
	if ent != null and ent.is_inside_tree() and ent.is_visible_in_tree() and pl != null:
		var d: float = ent.global_position.distance_to(pl.global_position)
		ent_str = "%s (%.1fm)" % [str(ent.get("state")), d]

	overlay_label.text = "FPS: %d | POS: (%.1f, %.1f, %.1f) | YAW: %d°\nSPEED: %.1f m/s (x%.1f) | HP: %d%% | SAN: %d%% | STM: %d%% | TORCH: %d%%\nCHEATS: [%s]\nBACTERIA: %s\nLEVEL: %s | TIME x%.2f | PLAY %ds | MARKS %d" % [
		fps, pos.x, pos.y, pos.z, rot_y,
		spd, Game.speed_mult, hp, san, stm, bat,
		cheats_str,
		ent_str,
		LevelData.current_level_tag(), Engine.time_scale, int(Game.time), marks.size()
	]

# ---------------------------------------------------------------- Controls & Handlers
func _set_speed(s: float) -> void:
	Game.speed_mult = s
	if speed_label: speed_label.text = "MOVEMENT / FLY SPEED: %.1fx" % s
	if speed_slider: speed_slider.value = s

func _set_jump(j: float) -> void:
	Game.jump_mult = j
	if jump_label: jump_label.text = "JUMP HEIGHT BOOST: %.1fx" % j
	if jump_slider: jump_slider.value = j

func _refill_flash() -> void:
	var pl := _get_player()
	if pl == null: return
	var ui_node = root.get_node_or_null("UI")
	if ui_node and "inventory" in ui_node and ui_node.inventory != null:
		ui_node.inventory.add_item(FlashPickup.ITEM_ID, FlashPickup.ITEM_NAME, FlashPickup.ITEM_DESC, 5,
			FlashPickup.ITEM_CODE, FlashPickup.STACK, FlashPickup.MODEL_PATH)
		_print("Added 5 Camera Flash charges to inventory.")

func _refill_tape() -> void:
	var pl := _get_player()
	if pl == null: return
	var ui_node = root.get_node_or_null("UI")
	if ui_node and "inventory" in ui_node and ui_node.inventory != null:
		ui_node.inventory.add_item(TapePickup.ITEM_ID, TapePickup.ITEM_NAME, TapePickup.ITEM_DESC, 300,
			TapePickup.ITEM_CODE, TapePickup.STACK, TapePickup.MODEL_PATH)
		_print("Added 300m Reflective Hazard Tape to inventory.")

func _trigger_blackout() -> void:
	var ev = root.get_node_or_null("Events")
	if ev != null and ev.has_method("run_event"):
		var ok = ev.run_event("powerCut")
		_print("grid blackout: %s" % str(ok))
	else:
		var lvl = root.get_node_or_null("Level")
		if lvl != null and lvl.has_method("cut_power"):
			lvl.cut_power(60.0)
			_print("grid power cut (direct)")
		else:
			_print("[color=#e8702c]Events/Level node not found[/color]")

func _restore_grid() -> void:
	var lvl = root.get_node_or_null("Level")
	if lvl != null:
		if lvl.has_method("restore_all"):
			lvl.restore_all()
		elif lvl.has_method("restore_power"):
			lvl.restore_power()
			if lvl.has_method("set_tint"):
				lvl.set_tint(Color.WHITE)
	var ev = root.get_node_or_null("Events")
	if ev != null and ev.has_method("clear_events"):
		ev.clear_events()
	var pl = _get_player()
	if pl != null and "grid_down" in pl:
		pl.grid_down = false
	var sc = root.get_node_or_null("Scares")
	if sc != null and sc.has_method("grid_on"):
		sc.grid_on()
	_print("grid restored")

func toggle_menu() -> void:
	_toggle(not menu_window.visible)

func open_menu() -> void:
	_toggle(true)

func close_menu() -> void:
	_toggle(false)

func _build_gate(parent: Control) -> void:
	gate = PanelContainer.new()
	gate.set_anchors_preset(Control.PRESET_CENTER)
	gate.custom_minimum_size = Vector2(380, 0)
	gate.grow_horizontal = Control.GROW_DIRECTION_BOTH
	gate.grow_vertical = Control.GROW_DIRECTION_BOTH
	gate.position = Vector2(-190, -60)
	gate.add_theme_stylebox_override("panel", _make_box(Color(0.075, 0.058, 0.030, 0.97), Color(0.800, 0.544, 0.176, 0.9), 2, 6, 14))
	gate.visible = false
	parent.add_child(gate)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	gate.add_child(v)
	v.add_child(_label("T.S.R.A. DIAGNOSTIC // ACCESS CODE", 14, Color(0.950, 0.646, 0.209)))

	gate_input = LineEdit.new()
	gate_input.secret = true
	gate_input.placeholder_text = "enter code"
	gate_input.text_submitted.connect(_try_unlock)
	v.add_child(gate_input)

	gate_msg = _label("ENTER to confirm, ESC to cancel", 10, Color(0.712, 0.675, 0.525))
	v.add_child(gate_msg)

func _try_unlock(code: String) -> void:
	if code.strip_edges() == ACCESS_CODE:
		unlocked = true
		gate.visible = false
		gate_input.release_focus()
		_toggle(true)
	else:
		gate_input.clear()
		gate_msg.text = "ACCESS DENIED"
		gate_msg.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))

func _input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if not is_inside_tree():
		return

	# code prompt up: only F1 / ESC are ours, everything else is typing into it
	if gate.visible:
		if e.physical_keycode == KEY_F1 or e.physical_keycode == KEY_ESCAPE:
			_toggle(false)
			get_viewport().set_input_as_handled()
		return
	# locked: the console and its hotkeys stay out of the way except to ask for the code
	if not unlocked and e.physical_keycode == KEY_1:
		return

	# Special toggle buttons: F1, Tilde (`~`), F3
	if e.physical_keycode == KEY_F1 or e.physical_keycode == KEY_QUOTELEFT or e.physical_keycode == KEY_SECTION:
		toggle_menu()
		get_viewport().set_input_as_handled()
		return
	elif e.physical_keycode == KEY_1:
		if not menu_window.visible:
			_switch_tab("console")
			_toggle(true)
		else:
			_toggle(false)
		get_viewport().set_input_as_handled()
		return
	elif menu_window.visible and e.physical_keycode == KEY_ESCAPE:
		_toggle(false)
		get_viewport().set_input_as_handled()
		return
	elif menu_window.visible and current_tab == "console" and e.physical_keycode == KEY_TAB:
		_complete()
		get_viewport().set_input_as_handled()
		return
	elif menu_window.visible and current_tab == "console" and e.physical_keycode == KEY_UP:
		_recall(-1)
		get_viewport().set_input_as_handled()
		return
	elif menu_window.visible and current_tab == "console" and e.physical_keycode == KEY_DOWN:
		_recall(1)
		get_viewport().set_input_as_handled()
		return

	if not Game.dev_keys or not unlocked or _guest_locked():
		return

	# Animation test walker hotkeys (only while one is out)
	if not menu_window.visible and is_instance_valid(walker):
		var keys := {KEY_BRACKETRIGHT: "next", KEY_BRACKETLEFT: "prev", KEY_SEMICOLON: "gait", KEY_APOSTROPHE: "look", KEY_SLASH: "slow"}
		if keys.has(e.physical_keycode):
			_walker_command(keys[e.physical_keycode])
			get_viewport().set_input_as_handled()
			return

	# Survivor model preview hotkeys
	if not menu_window.visible and e.physical_keycode == KEY_M:
		_model_command("")
		get_viewport().set_input_as_handled()
	elif not menu_window.visible and e.physical_keycode == KEY_COMMA:
		_model_command("prev")
		get_viewport().set_input_as_handled()
	elif not menu_window.visible and e.physical_keycode == KEY_PERIOD:
		_model_command("next")
		get_viewport().set_input_as_handled()
	# the arm clip tested last, again
	elif not menu_window.visible and e.physical_keycode == KEY_P:
		_hand_anim(hand_anim_last)
		get_viewport().set_input_as_handled()

