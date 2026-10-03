extends "res://scripts/UI/menu/menu_widgets.gd"
## The menu, part 2: the side panels. Settings (mouse, FOV, volumes), Multiplayer (host / join), Graphics
## (preset, resolution scale and each option), Voice (mode, levels, live meter) and Controls, each built
## from menu_widgets.gd and kept in sync with Gfx / Voice. menu.gd puts them in the menu shell.

signal settings_changed

const VOLUME_CHANNELS := [["master", "Master"], ["ambient", "Ambience"], ["footsteps", "Footsteps"], ["hum", "Hum"], ["breathing", "Breathing"]]
const CONTROLS := [
	[["W", "A", "S", "D"], "Move", "ZQSD and arrows work too"],
	[["Mouse"], "Look", ""],
	[["Shift"], "Sprint", "30 s of stamina"],
	[["Space"], "Jump", ""],
	[["C"], "Crouch", "Ctrl works too. Quieter, and harder to see"],
	[["F"], "Flashlight", "Pick up battery packs from the floor"],
	[["R"], "Load battery", "Uses one carried battery pack: +45%"],
	[["G"], "Camera flash", "Right click works too. Blinds the Bacteria for a few seconds: get out of its sight"],
	[["T"], "Hazard tape", "Hold on a wall or the floor, look along it, let go to stick. Hold on a strip to peel it off"],
	[["Tab"], "Inventory", "Check what you're carrying"],
	[["V"], "Push to talk", "Co-op voice chat"],
	[["F11"], "Fullscreen", "Alt+Enter works too"],
	[["Esc"], "Pause", ""],
]

var mp_addr: LineEdit
var mp_link: LineEdit
var mp_status: Label
var open_section := ""
func _build_settings() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.add_child(_section_title("AUDIO", true))
	for ch in VOLUME_CHANNELS:
		var key: String = ch[0]
		v.add_child(_slider_row(ch[1], 0, 100, int(round(volumes[key] * 100.0)), func(x: int):
			volumes[key] = x / 100.0
			_save()
			settings_changed.emit()))
	v.add_child(_section_title("CONTROLS"))
	v.add_child(_slider_row("Mouse Sens", SENS_MIN, SENS_MAX, sensitivity, func(x: int):
		sensitivity = x
		_save()
		settings_changed.emit()))
	var kb_btn := _link_button("REBIND KEYS →")
	kb_btn.custom_minimum_size = Vector2(96, 0)
	kb_btn.pressed.connect(func():
		if has_method("_show_panel"):
			call("_show_panel", "controls")
	)
	v.add_child(_gfx_row("Keybinds", kb_btn))
	v.add_child(_section_title("CAMERA"))
	v.add_child(_slider_row("Field of view", FOV_MIN, FOV_MAX, fov, func(x: int):
		fov = x
		_save()
		settings_changed.emit()))
	var bob := _link_button("")
	bob.custom_minimum_size = Vector2(96, 0)
	bob.text = "ON" if head_bob else "OFF"
	bob.pressed.connect(func():
		head_bob = not head_bob
		bob.text = "ON" if head_bob else "OFF"
		_save()
		settings_changed.emit())
	v.add_child(_gfx_row("Head bob", bob))
	var shake := _link_button("")
	shake.custom_minimum_size = Vector2(96, 0)
	shake.text = "ON" if cam_shake else "OFF"
	shake.pressed.connect(func():
		cam_shake = not cam_shake
		shake.text = "ON" if cam_shake else "OFF"
		_save()
		settings_changed.emit())
	v.add_child(_gfx_row("Camera shake", shake))
	v.add_child(_hint("Head bob is the step bounce; camera shake is the handheld camcorder wobble while walking. Turn them off if the camera makes you feel sick."))
	return v

func _build_multiplayer() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.add_child(_section_title("JOIN A GAME", true))
	v.add_child(_hint("Input the room code to join that session."))
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 12)
	mp_addr = _text_field("TYPE THE HOST'S ROOM CODE", last_address)
	mp_addr.text_changed.connect(func(s: String):
		last_address = s.strip_edges()
		_save())
	mp_addr.text_submitted.connect(func(_s): _do_join())
	join_row.add_child(mp_addr)
	var join_btn := _link_button("join")
	join_btn.pressed.connect(_do_join)
	join_row.add_child(join_btn)
	v.add_child(join_row)

	v.add_child(_spacer(4))
	mp_status = _label(Net.status, 12, Color(0.9, 0.882, 0.804, 0.7), 2)
	mp_status.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	mp_status.custom_minimum_size = Vector2(300, 0)
	v.add_child(mp_status)
	Net.status_changed.connect(func(s: String): mp_status.text = s)
	Net.share_link_changed.connect(func(u: String): mp_link.text = u)

	v.add_child(_spacer(14))
	v.add_child(_section_title("HOST A GAME"))
	v.add_child(_hint("Start a game and send the room code to your friends."))
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override("separation", 22)
	var host_btn := _link_button("host game")
	host_btn.pressed.connect(func(): Net.host())
	var stop_btn := _link_button("disconnect")
	stop_btn.pressed.connect(func(): Net.leave())
	host_row.add_child(host_btn)
	host_row.add_child(stop_btn)
	v.add_child(host_row)

	var link_row := HBoxContainer.new()
	link_row.add_theme_constant_override("separation", 12)
	mp_link = _text_field("ROOM CODE APPEARS HERE", Net.share_link)
	mp_link.editable = false
	link_row.add_child(mp_link)
	var copy_btn := _link_button("copy")
	copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(mp_link.text))
	link_row.add_child(copy_btn)
	v.add_child(link_row)
	return v

func _do_join() -> void:
	mp_addr.release_focus()
	Net.join(mp_addr.text)

# ---- graphics section (scripts/GameLogicEngine/graphics.gd) ------------------------------------------
var gfx_refresh: Array[Callable] = []
var gfx_preset_buttons := {}
var gfx_note: Label
var gfx_scale_slider: HSlider

# One setting: the value is a link that steps to the next option on each click
func _cycle_row(title: String, key: String, opts: Array) -> Control:
	var b := _link_button("")
	b.custom_minimum_size = Vector2(96, 0)
	b.pressed.connect(func(): Gfx.set_value(key, opts[(_opt_index(opts, key) + 1) % opts.size()][0]))
	gfx_refresh.append(func(): b.text = str(opts[_opt_index(opts, key)][1]).to_upper())
	return _gfx_row(title, b)

## A setting that lives outside the presets (Gfx.camera): steps through `opts` on each click
func _choice_row(title: String, get_v: Callable, opts: Array, set_v: Callable, labels: Dictionary) -> Control:
	var b := _link_button("")
	b.custom_minimum_size = Vector2(96, 0)
	b.pressed.connect(func(): set_v.call(opts[(opts.find(get_v.call()) + 1) % opts.size()]))
	gfx_refresh.append(func(): b.text = str(labels.get(get_v.call(), get_v.call())).to_upper())
	return _gfx_row(title, b)

func _build_graphics() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.add_child(_section_title("QUALITY PRESET", true))
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 20)
	for n in Gfx.ORDER:
		var b := _link_button(n)
		b.pressed.connect(func(): Gfx.set_preset(n))
		presets.add_child(b)
		gfx_preset_buttons[n] = b
	v.add_child(_padded(presets, 8))
	gfx_note = _label("", 11, Color(0.9, 0.882, 0.804, 0.45))
	gfx_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gfx_note.custom_minimum_size = Vector2(300, 0)
	v.add_child(gfx_note)

	v.add_child(_section_title("DISPLAY"))
	var sl := _slider_row("Render scale", 50, 100, int(Gfx.s.scale), func(x: int): Gfx.set_value("scale", x))
	gfx_scale_slider = sl.find_children("*", "HSlider", true, false)[0]
	v.add_child(sl)
	var fs := _link_button("")
	fs.custom_minimum_size = Vector2(96, 0)
	fs.pressed.connect(func(): Gfx.set_fullscreen(DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN))
	gfx_refresh.append(func(): fs.text = "ON" if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else "OFF")
	v.add_child(_gfx_row("Fullscreen", fs))
	var off_on := [[false, "Off"], [true, "On"]]
	v.add_child(_cycle_row("VSync", "vsync", off_on))
	v.add_child(_cycle_row("FPS limit", "fps", [[30, "30"], [60, "60"], [80, "80"], [100, "100"], [120, "120"], [0, "Unlimited"]]))
	v.add_child(_cycle_row("Smooth motion", "smooth", off_on))
	v.add_child(_cycle_row("Adaptive resolution", "adapt", off_on))

	v.add_child(_section_title("CAMERA"))
	v.add_child(_choice_row("Camera", func(): return Gfx.camera, Gfx.CAMERAS, func(x: String): Gfx.set_camera(x),
		{"auto": "Auto", "bodycam": "Bodycam", "camcorder": "Camcorder"}))

	v.add_child(_section_title("IMAGE"))
	v.add_child(_cycle_row("Anti-aliasing (MSAA)", "msaa", [[0, "Off"], [2, "2x"], [4, "4x"]]))
	v.add_child(_cycle_row("Temporal AA (TAA)", "taa", off_on))
	v.add_child(_cycle_row("Edge smoothing (FXAA)", "fxaa", off_on))
	v.add_child(_cycle_row("Texture filtering", "aniso", [[0, "Off"], [2, "2x"], [4, "4x"], [8, "8x"], [16, "16x"]]))
	v.add_child(_cycle_row("Camera effects", "post", [[0, "Low"], [1, "Medium"], [2, "Full"]]))
	v.add_child(_cycle_row("Bloom", "glow", off_on))

	v.add_child(_section_title("LIGHTING"))
	var quality := [[0, "Off"], [1, "Low"], [2, "Medium"], [3, "High"]]
	v.add_child(_cycle_row("Shadows", "shadows", quality))
	v.add_child(_cycle_row("Tube lights", "lights", [[6, "6"], [8, "8"], [10, "10"], [12, "12"]]))
	v.add_child(_cycle_row("Tube light shadows", "light_shadows", [[0, "Off"], [2, "2"], [4, "4"], [8, "8"]]))
	v.add_child(_cycle_row("Ambient occlusion", "ssao", quality))
	v.add_child(_cycle_row("Global illumination", "ssil", off_on))
	v.add_child(_cycle_row("Reflections", "ssr", off_on))
	v.add_child(_cycle_row("Volumetric fog", "vfog", quality))
	Gfx.changed.connect(_gfx_sync)
	_gfx_sync()
	return v

func _gfx_sync() -> void:
	for c in gfx_refresh:
		c.call()
	for n in gfx_preset_buttons:
		_set_link_active(gfx_preset_buttons[n], Gfx.preset == n)
	if gfx_scale_slider and int(gfx_scale_slider.value) != int(Gfx.s.scale):
		gfx_scale_slider.value = Gfx.s.scale
	var note := "CUSTOM SETTINGS. Pick a preset to reset them." if Gfx.preset == "custom" else "Low is for weak PCs. Tube lights and their shadows cost the most. Smooth motion runs the camera at your screen's refresh rate. Adaptive resolution quietly lowers the render size when frames start dropping, and puts it back when they recover."
	if Gfx.compat:
		note = "Compatibility renderer: ambient occlusion, reflections, global illumination and volumetric fog are unavailable on this PC."
	gfx_note.text = note

# ---- voice section (scripts/Voice/voice.gd) ----------------------------------------------------------
var voice_refresh: Array[Callable] = []
var voice_meter_bg: ColorRect
var voice_meter_fill: ColorRect
var voice_meter_gate: ColorRect

func _voice_row(title: String, get_text: Callable, on_press: Callable) -> Control:
	var b := _link_button("")
	b.custom_minimum_size = Vector2(150, 0)
	b.pressed.connect(on_press)
	voice_refresh.append(func(): b.text = str(get_text.call()).to_upper())
	return _gfx_row(title, b)

func _build_voice() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.add_child(_section_title("PROXIMITY VOICE", true))
	v.add_child(_hint("Players hear you by distance, from where you stand, and walls muffle you. Hold V to talk in push-to-talk."))
	v.add_child(_padded(Control.new(), 4))
	v.add_child(_voice_row("Mode", func(): return Voice.MODE_NAMES[Voice.mode], func(): Voice.cycle_mode()))
	v.add_child(_voice_row("Microphone", func(): return Voice.device_label().left(22), func(): Voice.cycle_device()))
	v.add_child(_voice_row("Mute microphone", func(): return "ON" if Voice.muted else "OFF", func(): Voice.toggle_mute()))
	v.add_child(_voice_row("Deafen", func(): return "ON" if Voice.deafened else "OFF", func(): Voice.toggle_deafen()))

	v.add_child(_section_title("MICROPHONE LEVEL"))
	voice_meter_bg = ColorRect.new()
	voice_meter_bg.color = Color(0.9, 0.882, 0.804, 0.12)
	voice_meter_bg.custom_minimum_size = Vector2(300, 10)
	voice_meter_fill = ColorRect.new()
	voice_meter_fill.color = Color("7fae72")
	voice_meter_bg.add_child(voice_meter_fill)
	voice_meter_gate = ColorRect.new()
	voice_meter_gate.color = RED
	voice_meter_gate.size = Vector2(2, 10)
	voice_meter_bg.add_child(voice_meter_gate)
	v.add_child(_padded(voice_meter_bg, 8))
	v.add_child(_hint("The bar turns green while you are transmitting. Voice activity opens when it passes the red line."))

	v.add_child(_section_title("LEVELS"))
	v.add_child(_slider_row("Sensitivity", 0, 100, Voice.sensitivity, func(x: int): Voice.set_sensitivity(x)))
	v.add_child(_slider_row("Mic volume", 0, 300, int(Voice.mic_gain * 100.0), func(x: int): Voice.set_gain(x)))
	v.add_child(_slider_row("Voice volume", 0, 150, int(Voice.voice_volume * 100.0), func(x: int): Voice.set_volume(x)))
	v.add_child(_voice_row("Hear yourself", func(): return "ON" if Voice.loopback else "OFF", func(): Voice.toggle_loopback()))
	Voice.changed.connect(_voice_sync)
	_voice_sync()
	return v

func _voice_sync() -> void:
	for c in voice_refresh:
		c.call()

func _voice_meter_tick() -> void:
	if voice_meter_bg == null or open_section != "voice":
		return
	var w := maxf(voice_meter_bg.size.x, 300.0)
	voice_meter_fill.size = Vector2(w * Voice.level, 10.0)
	voice_meter_fill.color = Color("7fae72") if Voice.transmitting else Color(0.9, 0.882, 0.804, 0.45)
	voice_meter_gate.position = Vector2(w * clampf((Voice.gate_db() + 70.0) / 70.0, 0.0, 1.0), 0.0)

# ---- controls / keybinds section ----------------------------------------------------
var rebinding_action := ""
var rebinding_btn: Button = null
var controls_hint: Label = null
var keybind_buttons := {}

func _input(e: InputEvent) -> void:
	if rebinding_action == "":
		return
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	var k := e as InputEventKey
	get_viewport().set_input_as_handled()
	if k.keycode == KEY_ESCAPE:
		_cancel_rebind()
		return
	var key_code: Key = k.keycode if k.keycode != KEY_NONE else DisplayServer.keyboard_get_keycode_from_physical(k.physical_keycode)
	Keybinds.set_key(rebinding_action, key_code)
	_finish_rebind()

func _keybind_button(act_id: String) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.custom_minimum_size = Vector2(74, 22)
	_style_keybind_btn(b, false)
	b.text = Keybinds.get_key_name(act_id)
	b.pressed.connect(_on_keybind_btn_pressed.bind(act_id, b))
	keybind_buttons[act_id] = b
	return b

func _style_keybind_btn(b: Button, active: bool) -> void:
	var bg := Color(0.627, 0.078, 0.059, 0.35) if active else Color(0.9, 0.882, 0.804, 0.06)
	var border := RED if active else Color(0.9, 0.882, 0.804, 0.25)
	var sb := _box(bg, border, Vector4(1, 1, 1, 3))
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6; sb.content_margin_right = 6
	sb.content_margin_top = 2; sb.content_margin_bottom = 2
	
	var sb_hover := _box(bg, RED if active else Color(0.9, 0.882, 0.804, 0.6), Vector4(1, 1, 1, 3))
	sb_hover.set_corner_radius_all(3)
	sb_hover.content_margin_left = 6; sb_hover.content_margin_right = 6
	sb_hover.content_margin_top = 2; sb_hover.content_margin_bottom = 2

	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb_hover)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_stylebox_override("focus", sb)
	b.add_theme_font_override("font", _font(2))
	b.add_theme_font_size_override("font_size", 11)
	b.add_theme_color_override("font_color", RED if active else TITLE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)

func _on_keybind_btn_pressed(act_id: String, b: Button) -> void:
	if rebinding_btn != null and rebinding_btn != b:
		_cancel_rebind()
	rebinding_action = act_id
	rebinding_btn = b
	_style_keybind_btn(b, true)
	b.text = "PRESS..."
	if controls_hint != null:
		var act_name := act_id
		for a in Keybinds.ACTIONS:
			if a.id == act_id:
				act_name = a.name
				break
		controls_hint.text = "PRESS KEY FOR %s  //  ESC CANCELS" % act_name.to_upper()
		controls_hint.modulate = RED
	_click()

func _finish_rebind() -> void:
	if rebinding_btn != null:
		_style_keybind_btn(rebinding_btn, false)
		rebinding_btn.text = Keybinds.get_key_name(rebinding_action)
	rebinding_action = ""
	rebinding_btn = null
	if controls_hint != null:
		controls_hint.text = "CLICK A KEY TO REBIND. ESC CANCELS."
		controls_hint.modulate = Color(0.9, 0.882, 0.804, 0.45)
	_click()

func _cancel_rebind() -> void:
	if rebinding_btn != null:
		_style_keybind_btn(rebinding_btn, false)
		rebinding_btn.text = Keybinds.get_key_name(rebinding_action)
	rebinding_action = ""
	rebinding_btn = null
	if controls_hint != null:
		controls_hint.text = "CLICK A KEY TO REBIND. ESC CANCELS."
		controls_hint.modulate = Color(0.9, 0.882, 0.804, 0.45)
	_click()

func _refresh_keybind_buttons() -> void:
	for act_id in keybind_buttons:
		var b: Button = keybind_buttons[act_id]
		if is_instance_valid(b):
			_style_keybind_btn(b, false)
			b.text = Keybinds.get_key_name(act_id)

func _build_controls() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	
	v.add_child(_section_title("LAYOUT PRESETS", true))
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 14)
	
	var azerty_btn := _link_button("AZERTY (ZQSD)")
	azerty_btn.pressed.connect(func():
		_cancel_rebind()
		Keybinds.apply_preset("azerty")
		_refresh_keybind_buttons()
		if controls_hint != null:
			controls_hint.text = "APPLIED AZERTY PRESET (ZQSD)."
			controls_hint.modulate = Color("7fae72")
	)
	presets.add_child(azerty_btn)

	var qwerty_btn := _link_button("QWERTY (WASD)")
	qwerty_btn.pressed.connect(func():
		_cancel_rebind()
		Keybinds.apply_preset("qwerty")
		_refresh_keybind_buttons()
		if controls_hint != null:
			controls_hint.text = "APPLIED QWERTY PRESET (WASD)."
			controls_hint.modulate = Color("7fae72")
	)
	presets.add_child(qwerty_btn)

	var reset_btn := _link_button("RESET")
	reset_btn.pressed.connect(func():
		_cancel_rebind()
		Keybinds.reset_defaults()
		_refresh_keybind_buttons()
		if controls_hint != null:
			controls_hint.text = "RESET ALL KEYBINDS."
			controls_hint.modulate = Color("7fae72")
	)
	presets.add_child(reset_btn)
	v.add_child(presets)

	controls_hint = _label("CLICK A KEY TO REBIND. ESC CANCELS.", 11, Color(0.9, 0.882, 0.804, 0.45))
	controls_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(controls_hint)

	v.add_child(_section_title("KEYBINDS"))
	
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	for act in Keybinds.ACTIONS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		
		var b := _keybind_button(act.id)
		row.add_child(b)
		
		var labels := VBoxContainer.new()
		labels.add_theme_constant_override("separation", 1)
		labels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		labels.add_child(_label(act.name.to_upper(), 12, Color(0.9, 0.882, 0.804, 0.85)))
		if act.desc != "":
			labels.add_child(_label(act.desc, 10, Color(0.9, 0.882, 0.804, 0.4)))
		row.add_child(labels)
		list.add_child(row)
	
	scroll.add_child(list)
	v.add_child(scroll)
	
	v.add_child(_section_title("OTHER CONTROLS"))
	var other_box := VBoxContainer.new()
	other_box.add_theme_constant_override("separation", 6)
	for item in [
		[["Mouse"], "Look", "Aim camera / flashlight"],
		[["Wheel"], "Zoom", "While the camcorder is raised"],
		[["F11"], "Fullscreen", "Alt+Enter works too"],
		[["Esc"], "Pause", "Resume or open settings"]
	]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var kbd_box := HBoxContainer.new()
		kbd_box.custom_minimum_size = Vector2(74, 0)
		kbd_box.alignment = BoxContainer.ALIGNMENT_CENTER
		for k in item[0]:
			kbd_box.add_child(_kbd(k))
		row.add_child(kbd_box)
		var lbls := VBoxContainer.new()
		lbls.add_theme_constant_override("separation", 1)
		lbls.add_child(_label(item[1].to_upper(), 12, Color(0.9, 0.882, 0.804, 0.75)))
		if item[2] != "":
			lbls.add_child(_label(item[2], 10, Color(0.9, 0.882, 0.804, 0.4)))
		row.add_child(lbls)
		other_box.add_child(row)
	v.add_child(other_box)

	Keybinds.keybinds_changed.connect(_refresh_keybind_buttons)
	return v
