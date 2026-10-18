extends "res://scripts/UI/crt/crt_layer.gd"
## The hotbar, bottom-right: one pixel icon per carried tool (inventory.gd items), its key and its count under
## it, drawn on the same amber CRT as the vitals (vitals_panel.gd) and riding with the camera the same way, so
## what you carry reads at a glance and the TAB terminal never has to open.
##   torch [F]  (battery pack icon, count and [R] under it)   scanner [Q]   tape [T] x2   flash [G] x2
## The mouse wheel picks the item in hand (an underline marks it) and LEFT CLICK uses it: the torch switches,
## the flash fires, the scanner scans and the tape lays for as long as the button is held. The old keys still
## work as shortcuts whatever is selected. Battery packs have no slot of their own: they hang off the torch
## (ATTACH), because loading one is something you do to the torch (R).
## It keeps out of the way like the vitals: a slot sits faint (IDLE_A) until it has something to say: its count
## just changed (a pickup pops the icon and names the item), or it is worth reaching for (the torch and its
## spare battery as the charge runs low, the flash on its last charge), and HOLD seconds after. The selected
## slot stays a little brighter, and wakes up fully while you scroll.
## Built by hud.gd into hud_root, so it fades with the rest of the OSD under the terminal and the pause menu.

const Kit := preload("res://scripts/UI/inventory/terminal_kit.gd")
const PlayerScript := preload("res://scripts/Player/player.gd")

const PANEL := Vector2(560, 176)     # canvas px (1920x1080 layout)
const CURVE := 0.045                 # lens bulge, as the vitals
const LENS_CROP := 16.0              # px kept clear at the bottom: the corner-fitted bulge shows only the top ~90% of the picture there
const ICON := 30.0
const SUB_ICON := 16.0               # the battery pack under the torch
const SUB_H := 18.0
const SLOT_W := 64.0
const SLOT_GAP := 6
const IDLE_A := 0.3                  # a slot with nothing to say
const SELECTED_A := 0.7              # the one in hand, at rest
const SCROLL_A := 0.6                # the others while you scroll
const HINT_A := 0.4                  # the terminal hint at rest
const HOLD := 2.5                    # s a slot stays up after it goes quiet
const SELECT_HOLD := 3.0             # s the item's name stays up after the last wheel step
const POP := 0.3                     # how far an icon swells when its count goes up
const GLOW := 0.6                    # of the terminal's glow, as the vitals
const WEAR_FROM := 60.0              # sanity under this wears the picture, as the vitals
const SWAY_K := 4.5
const SWAY_MAX := Vector2(10.0, 7.0)
const BOB_K := 35.0
const SHAKE_PX := 3.0
const ICON_DIR := "res://textures/ui/item_%s.png"
const ICONS := ["torch", "scanner", "battery", "flash", "tape"]   # the rest get item_crate.png
const ACTIONS := {"torch": "flashlight", "scanner": "scanner", "battery": "battery", "flash": "flash", "tape": "tape"}
const ATTACH := {"battery": "torch"}   # items shown under another slot instead of in one of their own
const HIDDEN := ["cable_spool"]        # level-building tools, not something you carry: never on the hotbar
# what a click does with each item in hand, shown with its name while you scroll
const VERBS := {"torch": "SWITCH", "scanner": "HOLD TO SCAN", "tape": "HOLD TO LAY", "flash": "FIRE"}

var player: Node                     # player.gd (set by hud.gd)
var inventory: Node                  # inventory.gd (set by hud.gd)
var flash: Node                      # flash_tool.gd: its icon dims while it charges; a click fires it (set by hud.gd)
var fade_src: CanvasItem             # hud_root: nothing to render while it is faded out
var slots: Array = []                # {id, box, icon, key, count_l, bar, sub, count, att, hold, pop, state, stack}
var sel_id := ""                     # the item in hand
var sel_t := 0.0                     # s the selection's name is still showing
var _row: HBoxContainer
var _hint_key: Label                 # the terminal's key, under the row
var _hint_new: Label                 # NEW: something unread in the terminal
var _hint: Control
var _built := false                  # the first list is the starting kit
var _sub_counts := {}                # attached item id -> its count, kept across rebuilds
var _name: Label
var _name_hold := 0.0
var _name_att := 0.0
var _t := 0.0
var _prev_f := Vector3.ZERO
var _eye := -1.0
var _sway := Vector2.ZERO

func _ready() -> void:
	super()
	mat.set_shader_parameter("distortion", CURVE)
	mat.set_shader_parameter("fit_corners", true)
	mat.set_shader_parameter("vignette_amt", 0.1)
	mat.set_shader_parameter("chroma_amt", 0.0012)
	mat.set_shader_parameter("bloom_damp", 0.88)
	mat.set_shader_parameter("vhs_amt", Term.VHS)           # the terminal's tape smear
	mat.set_shader_parameter("vhs_smear", Term.VHS_SMEAR)
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 4; v.offset_top = 4; v.offset_right = -4; v.offset_bottom = -LENS_CROP
	v.alignment = BoxContainer.ALIGNMENT_END
	v.add_theme_constant_override("separation", 8)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(v)
	_name = Kit.label("", 16, Kit.AMBER, 2)
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_name.modulate.a = 0.0
	v.add_child(_name)
	_row = HBoxContainer.new()
	_row.alignment = BoxContainer.ALIGNMENT_END
	_row.add_theme_constant_override("separation", SLOT_GAP)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_row)
	v.add_child(_build_hint())
	Keybinds.keybinds_changed.connect(_rebuild)
	running = true

## The last line, right-aligned: [TAB] TERMINAL, and NEW beside it while the terminal has something unread
func _build_hint() -> Control:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_END
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.custom_minimum_size = Vector2(0, 24)
	_hint_new = Kit.label("NEW", 13, Kit.ORANGE, 2)
	_hint_new.visible = false
	h.add_child(_hint_new)
	_hint_key = Kit.keycap(Keybinds.get_key_name("inventory"))
	h.add_child(_hint_key)
	h.add_child(_centered(Kit.label("T.S.R.A. TERMINAL", 14, Kit.MUTED, 2)))
	h.modulate.a = HINT_A
	_hint = h
	return h

func _centered(l: Control) -> Control:
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l

## Brighter, and NEW pulsing, while the terminal has an unread entry or a promotion waiting
func _update_hint(dt: float, pulse: float) -> void:
	var fresh: bool = Archive.has_unread() or bool(inventory.clearance_new)
	_hint_new.visible = fresh
	_hint_new.modulate.a = pulse
	_hint_key.text = "[%s]" % Keybinds.get_key_name("inventory")
	_hint.modulate.a = move_toward(_hint.modulate.a, 1.0 if fresh else HINT_A, dt * 4.0)

func _icon_for(id: String) -> Texture2D:
	return load(ICON_DIR % (id if id in ICONS else "crate"))

func _key_name(id: String) -> String:
	return Keybinds.get_key_name(ACTIONS[id]) if ACTIONS.has(id) else ""

func _attached_to(id: String) -> String:
	for att in ATTACH:
		if ATTACH[att] == id:
			return att
	return ""

func _slot(it: Dictionary) -> Dictionary:
	var id: String = it.id
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(SLOT_W, 0)
	box.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(col)
	var icon := TextureRect.new()
	icon.texture = _icon_for(id)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(0, ICON)
	icon.self_modulate = Kit.AMBER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(icon)
	var line := HBoxContainer.new()
	line.alignment = BoxContainer.ALIGNMENT_CENTER
	line.add_theme_constant_override("separation", 5)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(line)
	var key := Kit.label(_key_name(id), 13, Kit.MUTED, 1)
	line.add_child(key)
	var count_l := Kit.label("", 16, Kit.TEXT, 1)
	line.add_child(count_l)
	# the row under it: an attached item's icon, count and key (every slot keeps the height, so the bars line up)
	var subrow := HBoxContainer.new()
	subrow.alignment = BoxContainer.ALIGNMENT_CENTER
	subrow.add_theme_constant_override("separation", 3)
	subrow.custom_minimum_size = Vector2(0, SUB_H)
	subrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(subrow)
	var sub := {}
	var att := _attached_to(id)
	if att != "":
		var si := TextureRect.new()
		si.texture = _icon_for(att)
		si.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		si.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		si.custom_minimum_size = Vector2(SUB_ICON, SUB_ICON)
		si.self_modulate = Kit.AMBER
		si.mouse_filter = Control.MOUSE_FILTER_IGNORE
		subrow.add_child(si)
		var sc := Kit.label("x0", 13, Kit.TEXT, 1)
		subrow.add_child(sc)
		var sk := Kit.label(_key_name(att), 13, Kit.MUTED, 1)
		subrow.add_child(sk)
		sub = {"id": att, "icon": si, "count_l": sc, "key": sk,
			"count": int(_sub_counts.get(att, inventory.item_count(att))), "pop": 0.0, "hold": 0.0}
	var bar := ColorRect.new()               # the item in hand: a lit bar under its slot
	bar.color = Kit.AMBER
	bar.custom_minimum_size = Vector2(0, 3)
	bar.modulate.a = 0.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(bar)
	box.modulate.a = IDLE_A
	return {"id": id, "box": box, "icon": icon, "key": key, "count_l": count_l, "bar": bar, "sub": sub, "count": -1,
		"att": 0.0, "hold": 0.0, "pop": 0.0, "state": "", "stack": 1}

## The slots follow the pack's item list (less the attached items); rebuilt when a kind comes or goes
## (or a key is rebound)
func _rebuild() -> void:
	var seen := {}                          # kinds already on the strip: a kind that is new now was just picked up
	for s in slots:
		seen[s.id] = s.count
	for c in _row.get_children():
		_row.remove_child(c)
		c.queue_free()
	slots.clear()
	for it in inventory.items:
		if ATTACH.has(it.id) or it.id in HIDDEN:
			continue
		var s := _slot(it)
		s.count = int(seen.get(it.id, int(it.count) if not _built else 0))   # what is there at the start is not news
		s.stack = int(it.stack)
		_row.add_child(s.box)
		slots.append(s)
		_paint_count(s)
	_built = true
	if sel_id == "" or not _has(sel_id):
		sel_id = slots[0].id if not slots.is_empty() else ""

func _has(id: String) -> bool:
	for s in slots:
		if s.id == id:
			return true
	return false

func _item(id: String) -> Dictionary:
	for it in inventory.items:
		if it.id == id:
			return it
	return {}

func _same_kinds() -> bool:
	var i := 0
	for it in inventory.items:
		if ATTACH.has(it.id) or it.id in HIDDEN:
			continue
		if i >= slots.size() or slots[i].id != it.id:
			return false
		i += 1
	return i == slots.size()

func _paint_count(s: Dictionary) -> void:
	var txt := "x%d" % s.count if s.stack > 1 else ""
	var l: Label = s.count_l
	if l.text != txt:
		l.text = txt

## True while the player's hands are free: the wheel, a click and `using()` all need it
func _can_use() -> bool:
	return player != null and inventory != null and Game.playing and not Game.dead and not player.dead \
		and not player.frozen and player.lens_up <= 0.0 and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

## True while the left button is held with `id` in hand: the tools that work by holding (scanner, tape) ask this
func using(id: String) -> bool:
	return sel_id == id and _can_use() and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

func _unhandled_input(e: InputEvent) -> void:
	if not is_inside_tree():
		return
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed or not _can_use():
		return
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_DOWN: _step(1)
		MOUSE_BUTTON_WHEEL_UP: _step(-1)
		MOUSE_BUTTON_LEFT:
			if not _click():
				return
		_: return
	get_viewport().set_input_as_handled()

## A click with the selected item: the ones that act once (the held ones, scanner and tape, are read in
## their tools through using()). True when the click was taken
func _click() -> bool:
	match sel_id:
		"torch":
			player.toggle_flashlight()
			return true
		"flash":
			if flash != null:
				flash.use()
			return true
		"scanner", "tape":
			return true             # held: their tools see the button
	return false

func _step(delta: int) -> void:
	if slots.size() < 2:
		return
	var i := 0
	for j in slots.size():
		if slots[j].id == sel_id:
			i = j
	sel_id = slots[wrapi(i + delta, 0, slots.size())].id
	sel_t = SELECT_HOLD
	_name_hold = 0.0
	if inventory.has_method("play_sfx"):
		inventory.play_sfx("select")

func _process(dt: float) -> void:
	# nothing to show while it is faded out, or once you are dead (the death card has the corner)
	running = (fade_src == null or fade_src.modulate.a > 0.01) and not Game.dead
	super(dt)
	if not running or player == null or inventory == null:
		return
	_t += dt
	if not _same_kinds():
		_rebuild()
	sel_t = maxf(0.0, sel_t - dt)
	_name_hold = maxf(0.0, _name_hold - dt)
	var pulse := 0.65 + 0.35 * sin(_t * 15.0)
	for s in slots:
		_update_slot(s, _item(s.id), dt, pulse)
	_update_name(dt)
	_update_hint(dt, pulse)
	_wear_update()
	_sway_update(dt)
	mat.set_shader_parameter("bloom_amt", float(mat.get_shader_parameter("bloom_amt")) * GLOW)

func _state_color(state: String, pulse: float) -> Color:
	match state:
		"low": return Kit.ORANGE
		"critical": return Color(Kit.RED, pulse)
	return Kit.AMBER

func _update_slot(s: Dictionary, it: Dictionary, dt: float, pulse: float) -> void:
	var count := int(it.get("count", 0))
	s.stack = int(it.get("stack", s.stack))
	if count != s.count:
		if count > s.count and not it.is_empty():     # picked up: the icon swells and the item is named
			s.pop = 1.0
			_say("+%d  %s  %d/%d" % [count - s.count, str(it.name).to_upper(), count, s.stack], HOLD)
			burst(0.3)
		s.count = count
		s.hold = HOLD
		_paint_count(s)
	s.hold = maxf(0.0, float(s.hold) - dt)
	s.pop = maxf(0.0, float(s.pop) - dt * 3.0)
	s.state = _state(s)
	var col := _state_color(s.state, pulse)
	var txt := Kit.TEXT if s.state == "" else (Kit.ORANGE if s.state == "low" else Kit.RED)
	var dim := 1.0
	if s.id == "flash" and flash != null and float(flash.charging) > 0.0:
		dim = 0.45                      # charging
	elif s.id == "torch" and not bool(player.flash_on):
		dim = 0.55                      # switched off
	var icon: TextureRect = s.icon
	icon.self_modulate = col.lerp(Kit.TEXT, float(s.pop)) * Color(1, 1, 1, dim)
	icon.pivot_offset = icon.size * 0.5
	icon.scale = Vector2.ONE * (1.0 + POP * float(s.pop))
	(s.count_l as Label).add_theme_color_override("font_color", txt)
	(s.key as Label).add_theme_color_override("font_color", col if s.state != "" else Kit.MUTED)
	if not (s.sub as Dictionary).is_empty():
		_update_sub(s, dt, pulse)
	var selected: bool = s.id == sel_id
	var want := 0.0
	if (selected and sel_t > 0.0) or s.state != "" or float(s.hold) > 0.0 or float(s.sub.get("hold", 0.0)) > 0.0:
		want = 1.0
	elif selected:
		want = (SELECTED_A - IDLE_A) / (1.0 - IDLE_A)
	elif sel_t > 0.0:
		want = (SCROLL_A - IDLE_A) / (1.0 - IDLE_A)
	s.att = move_toward(float(s.att), want, dt * (6.0 if want > s.att else 1.2))
	(s.box as Control).modulate.a = lerpf(IDLE_A, 1.0, float(s.att))
	(s.bar as Control).modulate.a = 1.0 if selected else 0.0

## The battery pack hanging under the torch: its count (a pickup pops it), its key, lit as the charge runs low
func _update_sub(s: Dictionary, dt: float, pulse: float) -> void:
	var sub: Dictionary = s.sub
	var it := _item(sub.id)
	var count := int(it.get("count", 0))
	if count != sub.count:
		if count > sub.count:
			sub.pop = 1.0
			_say("+%d  %s  %d/%d" % [count - sub.count, str(it.name).to_upper(), count, int(it.stack)], HOLD)
			burst(0.3)
		sub.count = count
		sub.hold = HOLD
	_sub_counts[sub.id] = count
	sub.hold = maxf(0.0, float(sub.hold) - dt)
	sub.pop = maxf(0.0, float(sub.pop) - dt * 3.0)
	var state := _power_state()
	var col := _state_color(state, pulse)
	if count == 0 and state == "":
		col = Kit.MUTED                 # none spare and none needed: just faint
	var si: TextureRect = sub.icon
	si.self_modulate = col.lerp(Kit.TEXT, float(sub.pop))
	si.pivot_offset = si.size * 0.5
	si.scale = Vector2.ONE * (1.0 + POP * float(sub.pop))
	var cl: Label = sub.count_l
	var ct := "x%d" % count
	if cl.text != ct:
		cl.text = ct
	cl.add_theme_color_override("font_color", col if count > 0 or state != "" else Kit.TEXT_DIM)
	(sub.key as Label).add_theme_color_override("font_color", col if (state != "" and count > 0) else Kit.MUTED)

func _power_state() -> String:
	var bat: float = player.battery
	if bat < PlayerScript.BATTERY_CRIT: return "critical"
	if bat < PlayerScript.BATTERY_LOW: return "low"
	return ""

## Worth reaching for: the torch as its charge runs low (and the spare under it), the flash on its last charge
func _state(s: Dictionary) -> String:
	match s.id:
		"torch": return _power_state()
		"flash":
			if s.count <= 1: return "low"
	return ""

func _say(text: String, hold: float) -> void:
	_name.text = text
	_name_hold = hold

## The line over the row: the item in hand and what a click does with it while you scroll, or what was just
## picked up
func _update_name(dt: float) -> void:
	if _name_hold <= 0.0 and sel_t > 0.0:
		var it := _item(sel_id)
		if not it.is_empty():
			var txt := str(it.name).to_upper()
			if int(it.stack) > 1:
				txt += "  %d/%d" % [it.count, it.stack]
			if VERBS.has(sel_id):
				txt += "   [CLICK] " + VERBS[sel_id]
			if _name.text != txt:
				_name.text = txt
	var want := 1.0 if (_name_hold > 0.0 or sel_t > 0.0) else 0.0
	_name_att = move_toward(_name_att, want, dt * (6.0 if want > _name_att else 1.5))
	_name.modulate.a = _name_att

## Low sanity wears the picture down, as the vitals' does (a lighter version: no slipping rows)
func _wear_update() -> void:
	var k := clampf((WEAR_FROM - float(player.sanity)) / WEAR_FROM, 0.0, 1.0)
	mat.set_shader_parameter("scan_amt", 0.14 + 0.32 * k)
	mat.set_shader_parameter("grain_amt", 0.04 + 0.14 * k)
	mat.set_shader_parameter("chroma_amt", 0.0012 + 0.012 * k)
	if randf() < k * k * 1.2 * get_process_delta_time():
		burst(0.2 + 0.5 * k)
	content.modulate.a = 1.0 - k * k * 0.35 * (0.5 + 0.5 * sin(_t * 1.7 + sin(_t * 4.3)))

## Shifts the CRT picture like the vitals: behind a turn, off the eye's bob, trembling when scared or winded
func _sway_update(dt: float) -> void:
	var cam: Camera3D = player.get("cam")
	if cam == null or dt <= 0.0:
		return
	if bool(player.get("dead")):
		_prev_f = Vector3.ZERO
		_eye = -1.0
		_sway = _sway.lerp(Vector2.ZERO, minf(1.0, dt * 10.0))
		screen.position = _sway
		screen.rotation = 0.0
		return
	var f := -cam.global_transform.basis.z
	var target := Vector2.ZERO
	if _prev_f != Vector3.ZERO:
		var yaw_rate := wrapf(atan2(f.x, f.z) - atan2(_prev_f.x, _prev_f.z), -PI, PI) / dt
		var pitch_rate := (asin(clampf(f.y, -1.0, 1.0)) - asin(clampf(_prev_f.y, -1.0, 1.0))) / dt
		target = Vector2(yaw_rate, pitch_rate) * SWAY_K
	_prev_f = f
	var eye: float = cam.global_position.y - (player as Node3D).global_position.y
	_eye = eye if _eye < 0.0 else lerpf(_eye, eye, minf(1.0, dt * 4.0))
	target.y += (eye - _eye) * BOB_K
	_sway = _sway.lerp(target.clamp(-SWAY_MAX, SWAY_MAX), minf(1.0, dt * 10.0))
	var fear := 0.0
	if Game.heart != null and is_instance_valid(Game.heart):
		fear = smoothstep(0.35, 1.0, float(Game.heart.get("stress")))
	var winded := 1.0 if bool(player.get("exhausted")) else clampf((30.0 - float(player.get("stamina"))) / 30.0, 0.0, 1.0)
	var shake := maxf(fear, winded * 0.8)
	var tremor := Vector2(sin(_t * 47.0) + 0.6 * sin(_t * 73.0 + 1.3), sin(_t * 53.0 + 0.7) + 0.6 * sin(_t * 67.0 + 2.1))
	screen.position = _sway + tremor * 0.6 * SHAKE_PX * shake
	screen.pivot_offset = screen.size * 0.5
	screen.rotation = sin(_t * 41.0) * 0.004 * shake
