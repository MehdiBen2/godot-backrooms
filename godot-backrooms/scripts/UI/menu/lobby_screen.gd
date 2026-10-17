extends Control
## PLAY's lobby screen (main_menu.gd), between the title and the mission briefing. On the right, live, the
## corridor (lobby_corridor.gd, on its own world in a SubViewport): a stretch of Level 0 under failing tubes,
## you standing in it in your suit, and a place lit for every survivor who joins, up to Net.MAX_PLAYERS. On
## the left, over a see-through gradient, the same VCR column as the title: the three save tapes (save_game.gd)
## with the picked one's label, the crew and the room code, and BEGIN / ERASE TAPE / BACK.
##
## The host (or a player on their own) picks the tape; it is the run (Saves.begin). A guest who joined from
## the title lands here too, without the tapes: they wait in the host's lobby until the host's BEGIN takes them
## along (Net.lobby_changed), or go straight in if the host is already in a run.
## The title screen's lens and VHS layers stay over all of it (main_menu.gd adds this under them).

signal begin_requested          # BEGIN (or, on a guest, the host's): main_menu.gd plays out and opens the briefing
signal back_requested           # BACK: main_menu.gd brings the title back

const Corridor := preload("res://scripts/UI/menu/lobby_corridor.gd")
const W := preload("res://scripts/UI/menu/menu_widgets.gd")
const CREAM := Color("e6e1cd")
const TITLE := Color("d8d3bd")
const RED := Color("c4271f")
const AMBER := Color("f5a623")
const DIM := Color(0.9, 0.882, 0.804, 0.6)
const ROW_H := 40.0
const SLIDE := 26.0
const ENTRY_PX := 28
const VIEW_IN := 0.9                    # s the corridor takes to come up through the pushing title still

var font: FontFile = load("res://fonts/vcr.ttf")
var shown := false
var guest := false
var view: SubViewportContainer
var sub: SubViewport
var corridor: Corridor
var panel: Control
var column: VBoxContainer
var entries: Array[Dictionary] = []     # {button, inner, label, mark, hint, action, key, always, tw}
var sel := -1
var tape_sel := 0                       # the tape BEGIN plays (host / solo)
var erase_armed := false
var am_ready := false                   # guest: pressed READY
var tag_label: Label
var rec_dot: ColorRect
var title_label: Label
var fringes: Array = []
var sub_label: Label
var tapes_box: Control
var card: VBoxContainer
var card_lines: Array[Label] = []
var crew_label: Label
var crew_dots: HBoxContainer
var room_label: Label
var status_label: Label
var wait_label: Label
var footer: Label
var click: AudioStreamPlayer
var tick: AudioStreamPlayer
var last_tick := 0.0
var anim: Tween
var t := 0.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build()
	Net.survivor_joined.connect(func(_id: int, _n: String, _a: bool) -> void: _refresh_crew())
	Net.survivor_left.connect(func(_id: int, _n: String) -> void: _refresh_crew())
	Net.status_changed.connect(_on_net_status)
	Net.share_link_changed.connect(func(_s: String) -> void: _refresh_room())
	Net.lobby_changed.connect(_on_lobby_changed)
	Net.ready_changed.connect(_refresh_crew)
	Saves.changed.connect(_refresh_tapes)
	# a frame of the corridor while the title is up, hidden: its shaders compile then, not in the PLAY push
	get_tree().create_timer(1.5).timeout.connect(func() -> void:
		if not shown:
			sub.render_target_update_mode = SubViewport.UPDATE_ONCE)

# ---- helpers (the title's own look, main_menu.gd) ----------------------------------------------
func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	return fv

func _label(text: String, size: int, color: Color, spacing := 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _spacer(h: float) -> Control:
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, h)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return sp

func _full(c: Control) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE

# ---- layout ---------------------------------------------------------------------------------
func _build() -> void:
	view = SubViewportContainer.new()
	view.stretch = true
	add_child(view)
	_full(view)
	view.modulate.a = 0.0
	sub = SubViewport.new()
	sub.own_world_3d = true
	sub.msaa_3d = Viewport.MSAA_2X
	sub.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	sub.use_debanding = true
	sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	view.add_child(sub)
	corridor = Corridor.new()
	sub.add_child(corridor)

	panel = Control.new()
	add_child(panel)
	_full(panel)
	# the left of the picture darkened for the column, clearing to nothing by the middle: the corridor shows through
	var veil := TextureRect.new()
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.26, 0.42, 0.56])
	g.colors = PackedColorArray([Color(0.012, 0.011, 0.007, 0.9), Color(0.012, 0.011, 0.007, 0.72), Color(0.012, 0.011, 0.007, 0.3), Color(0.012, 0.011, 0.007, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 512
	gt.height = 1
	veil.texture = gt
	veil.stretch_mode = TextureRect.STRETCH_SCALE
	panel.add_child(veil)
	_full(veil)
	var fade := TextureRect.new()                 # and a soft fall-off top and bottom, like a lens vignette
	var vg := Gradient.new()
	vg.offsets = PackedFloat32Array([0.0, 0.18, 0.82, 1.0])
	vg.colors = PackedColorArray([Color(0, 0, 0, 0.55), Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0.6)])
	var vt := GradientTexture2D.new()
	vt.gradient = vg
	vt.width = 1
	vt.height = 256
	vt.fill_from = Vector2(0, 0)
	vt.fill_to = Vector2(0, 1)
	fade.texture = vt
	fade.stretch_mode = TextureRect.STRETCH_SCALE
	panel.add_child(fade)
	_full(fade)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 110 if side in ["left", "right"] else 72)
	panel.add_child(margin)
	_full(margin)
	column = VBoxContainer.new()
	column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_theme_constant_override("separation", 0)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)

	var tag := HBoxContainer.new()
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_constant_override("separation", 10)
	rec_dot = ColorRect.new()
	rec_dot.color = RED
	rec_dot.custom_minimum_size = Vector2(8, 8)
	rec_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot_c := CenterContainer.new()
	dot_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot_c.add_child(rec_dot)
	tag.add_child(dot_c)
	tag_label = _label("SURVIVOR LOBBY", 12, Color(CREAM, 0.55), 4)
	tag.add_child(tag_label)
	column.add_child(tag)
	column.add_child(_spacer(14))
	title_label = _label("FIELD TAPES", 58, TITLE, 14)
	title_label.add_theme_constant_override("outline_size", 3)
	title_label.add_theme_color_override("font_outline_color", TITLE)
	for f in [[Vector2(2, 0), Color(0.627, 0.078, 0.059, 0.4)], [Vector2(-2, 0), Color(0.157, 0.353, 0.431, 0.28)]]:
		var s := _label("FIELD TAPES", 58, f[1], 14)
		s.add_theme_constant_override("outline_size", 3)
		s.add_theme_color_override("font_outline_color", f[1])
		s.position = f[0]
		s.show_behind_parent = true
		title_label.add_child(s)
		fringes.append(s)
	column.add_child(title_label)
	column.add_child(_spacer(8))
	sub_label = _label("", 12, Color(CREAM, 0.5), 4)
	column.add_child(sub_label)
	column.add_child(_spacer(30))

	# the tapes, then the picked one's label
	tapes_box = VBoxContainer.new()
	tapes_box.add_theme_constant_override("separation", 0)
	tapes_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(tapes_box)
	for i in Saves.SLOTS:
		_entry(tapes_box, "TAPE %02d" % (i + 1), "", _pick_tape.bind(i), "tape%d" % i, true)
	tapes_box.add_child(_spacer(10))
	var card_row := HBoxContainer.new()
	card_row.add_theme_constant_override("separation", 16)
	card_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var accent := ColorRect.new()
	accent.color = Color(AMBER, 0.8)
	accent.custom_minimum_size = Vector2(2, 0)
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_row.add_child(accent)
	card = VBoxContainer.new()
	card.add_theme_constant_override("separation", 6)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_row.add_child(card)
	for i in 4:
		var l := _label("", 15 if i == 0 else 12, Color(AMBER, 0.85) if i == 0 else Color(CREAM, 0.62), 5 if i == 0 else 3)
		card.add_child(l)
		card_lines.append(l)
	tapes_box.add_child(card_row)
	tapes_box.add_child(_spacer(30))

	# the crew: one mark per place in the corridor, and the room
	var crew_row := HBoxContainer.new()
	crew_row.add_theme_constant_override("separation", 14)
	crew_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crew_label = _label("CREW  1 / %d" % Net.MAX_PLAYERS, 13, Color(CREAM, 0.75), 6)
	crew_row.add_child(crew_label)
	crew_dots = HBoxContainer.new()
	crew_dots.add_theme_constant_override("separation", 6)
	crew_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in Net.MAX_PLAYERS:
		var d := ColorRect.new()
		d.custom_minimum_size = Vector2(10, 10)
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var c := CenterContainer.new()
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(d)
		crew_dots.add_child(c)
	crew_row.add_child(crew_dots)
	column.add_child(crew_row)
	column.add_child(_spacer(8))
	room_label = _label("", 20, Color(AMBER, 0.9), 8)
	column.add_child(room_label)
	_entry(column, "OPEN ROOM", "INVITE UP TO %d SURVIVORS" % (Net.MAX_PLAYERS - 1), func() -> void: Net.host(), "host")
	_entry(column, "COPY CODE", "TO THE CLIPBOARD", func() -> void: DisplayServer.clipboard_set(Net.share_link), "copy")
	_entry(column, "CLOSE ROOM", "SEND EVERYONE HOME", func() -> void: Net.leave(), "close")
	status_label = _label("", 11, Color(CREAM, 0.42), 3)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(560, 0)
	column.add_child(status_label)
	column.add_child(_spacer(30))

	wait_label = _label("WAITING FOR THE HOST TO BEGIN", 16, Color(CREAM, 0.8), 6)
	column.add_child(wait_label)
	_entry(column, "READY", "TELL THE HOST YOU ARE SET", _on_ready, "ready")
	_entry(column, "BEGIN", "", _on_begin, "begin")
	_entry(column, "ERASE TAPE", "", _on_erase, "erase")
	_entry(column, "BACK", "MAIN MENU", _on_back, "back")
	column.add_child(_spacer(26))
	footer = _label("UP / DOWN  SELECT    ENTER  CONFIRM    ESC  BACK", 11, Color(CREAM, 0.3), 3)
	column.add_child(footer)

	click = AudioStreamPlayer.new()
	click.stream = load("res://audio/ui/ui_click.wav")
	click.volume_db = -6.0
	add_child(click)
	tick = AudioStreamPlayer.new()
	tick.stream = click.stream
	tick.volume_db = -22.0
	add_child(tick)

## One entry, the title's own (main_menu.gd _menu_item): a red ► and the word, which steps right when
## selected, and a caption beside it. `always`: the caption stays up, dim (a tape's label); else it types
## itself out on selection.
func _entry(parent: Control, text: String, hint: String, action: Callable, key: String, always := false) -> void:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	for n in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(n, StyleBoxEmpty.new())
	b.custom_minimum_size = Vector2(600, ROW_H)
	parent.add_child(b)
	var inner := Control.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(inner)
	var mark := _label("►", ENTRY_PX, RED)
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mark.size = Vector2(SLIDE, ROW_H)
	mark.position.x = -10.0
	mark.modulate.a = 0.0
	inner.add_child(mark)
	var l := _label(text, ENTRY_PX, Color.WHITE, 7)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(0, ROW_H)
	l.self_modulate = DIM
	inner.add_child(l)
	var h := _label(hint, 12, Color(CREAM, 0.4), 4)
	h.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.size = Vector2(0, ROW_H)
	h.modulate.a = 0.45 if always else 0.0
	h.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	inner.add_child(h)
	var i := entries.size()
	entries.append({"button": b, "inner": inner, "label": l, "mark": mark, "hint": h, "action": action, "key": key, "always": always, "tw": null})
	_place_hint(i)
	b.mouse_entered.connect(func() -> void: _select(i))
	b.mouse_exited.connect(func() -> void:
		if sel == i:
			_select(-1))
	b.pressed.connect(_activate.bind(i))

## The caption sits after the word, on its baseline
func _place_hint(i: int) -> void:
	var e: Dictionary = entries[i]
	var l: Label = e.label
	var w := _font(7).get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, ENTRY_PX).x
	l.size.x = w + 12
	e.hint.position = Vector2(w + SLIDE + 30, (font.get_ascent(ENTRY_PX) - font.get_ascent(12)) * 0.5)

func _entry_of(key: String) -> int:
	for i in entries.size():
		if entries[i].key == key:
			return i
	return -1

func _set_entry(key: String, text := "", hint := "", show := true) -> void:
	var i := _entry_of(key)
	var e: Dictionary = entries[i]
	e.button.visible = show
	if text != "":
		e.label.text = text
	e.hint.text = hint
	_place_hint(i)

# ---- selection ------------------------------------------------------------------------------
func _select(i: int) -> void:
	if i == sel:
		return
	var prev := sel
	sel = i
	if prev >= 0:
		_entry_state(prev)
	if i >= 0:
		_entry_state(i)
		var now := Time.get_ticks_msec() / 1000.0
		if now - last_tick >= 0.08:
			last_tick = now
			tick.pitch_scale = randf_range(1.45, 1.55)
			tick.play()
	if erase_armed and (i < 0 or entries[i].key != "erase"):
		erase_armed = false
		_refresh_tapes()

## Lit = under the cursor, or the tape BEGIN plays
func _entry_state(i: int) -> void:
	var e: Dictionary = entries[i]
	var hovered := i == sel
	var lit: bool = hovered or e.key == "tape%d" % tape_sel
	var old: Tween = e.tw
	if old and old.is_valid():
		old.kill()
	var tw := create_tween().set_parallel(true)
	var red: bool = e.key == "erase" and erase_armed
	tw.tween_property(e.label, "position:x", SLIDE if lit else 0.0, 0.32).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(e.label, "self_modulate", (Color(1.0, 0.45, 0.4) if red else Color.WHITE) if lit else DIM, 0.2)
	tw.tween_property(e.mark, "position:x", 0.0 if lit else -10.0, 0.32).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(e.mark, "modulate:a", 1.0 if lit else 0.0, 0.18)
	var h: Label = e.hint
	if e.always:
		tw.tween_property(h, "modulate:a", 0.95 if lit else 0.45, 0.2)
	else:
		if hovered and h.modulate.a < 0.05:
			h.visible_ratio = 0.0
		tw.tween_property(h, "modulate:a", 1.0 if hovered else 0.0, 0.2 if hovered else 0.15)
		if hovered:
			tw.tween_property(h, "visible_ratio", 1.0, 0.3).set_delay(0.08)
	e.tw = tw

func _visible_entries() -> Array[int]:
	var ids: Array[int] = []
	for i in entries.size():
		if entries[i].button.is_visible_in_tree():
			ids.append(i)
	return ids

func _step(d: int) -> void:
	var ids := _visible_entries()
	if ids.is_empty():
		return
	var at := ids.find(sel)
	_select(ids[0 if d > 0 else -1] if at < 0 else ids[posmod(at + d, ids.size())])

func _activate(i: int) -> void:
	if not shown:
		return
	W._finish(anim)
	click.pitch_scale = randf_range(0.96, 1.04)
	click.play()
	var l: Label = entries[i].label
	var tw := create_tween()
	tw.tween_method(func(x: float) -> void: l.modulate.a = 1.0 if fmod(x * 3.0, 1.0) > 0.45 else 0.3, 0.0, 1.0, 0.3)
	tw.tween_callback(func() -> void: l.modulate.a = 1.0)
	entries[i].action.call()

# ---- open / close ---------------------------------------------------------------------------
## Up out of the title's push: the corridor fades in under it while its camera carries the move on down
## the hall, then the column builds itself like the title's
func open(as_guest: bool) -> void:
	shown = true
	visible = true
	guest = as_guest
	erase_armed = false
	sel = -1
	if guest:
		Saves.eject()                       # the host's tape is the run
	else:
		tape_sel = _default_tape()
		Net.set_lobby(true)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_refresh_tapes()
	_refresh_crew(true)
	_refresh_room()
	for i in entries.size():
		_entry_state(i)
	view.modulate.a = 0.0
	corridor.set_sound(true)
	corridor.from_menu(2.8)
	W._finish(anim)
	anim = create_tween().set_parallel(true)
	anim.tween_property(view, "modulate:a", 1.0, VIEW_IN).set_delay(0.45).set_trans(Tween.TRANS_SINE)
	panel.modulate.a = 1.0
	var parts: Array = [tag_label.get_parent(), sub_label, tapes_box, crew_label.get_parent(), room_label, status_label, wait_label, footer]
	for c in parts:
		c.modulate.a = 0.0
	W._lock_in(anim, title_label, fringes, 1.3, 1.0, 34.0)
	W._stagger(anim, [tag_label.get_parent()], 1.2, 0.0, 0.3)
	W._type_in(anim, tag_label, 1.2, 0.4)
	anim.tween_property(sub_label, "modulate:a", 1.0, 0.3).set_delay(1.6)
	W._type_in(anim, sub_label, 1.6, 0.6)
	var n := 0
	for e in entries:
		var inner: Control = e.inner
		inner.position.x = -24.0
		inner.modulate.a = 0.0
		var d := 1.75 + n * 0.06
		anim.tween_property(inner, "position:x", 0.0, 0.5).set_delay(d).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		anim.tween_property(inner, "modulate:a", 1.0, 0.35).set_delay(d)
		n += 1
	W._stagger(anim, [tapes_box, crew_label.get_parent(), room_label, status_label, wait_label, footer], 1.8, 0.08, 0.5)

## BACK: the column goes, the camera backs away up the hall and the picture fades back to the title's
func close() -> void:
	shown = false
	if Net.hosting:
		Net.leave()                         # the room was this lobby's
	elif guest:
		Net.leave()
	Net.lobby_open = false
	W._finish(anim)
	corridor.set_sound(false)
	corridor.pull_back(1.0)
	anim = create_tween().set_parallel(true)
	anim.tween_property(panel, "modulate:a", 0.0, 0.3)
	anim.tween_property(view, "modulate:a", 0.0, 0.8).set_delay(0.2).set_trans(Tween.TRANS_SINE)
	anim.chain().tween_callback(func() -> void:
		visible = false
		sub.render_target_update_mode = SubViewport.UPDATE_DISABLED)

## BEGIN: the column goes and the camera pushes on past the group into the dark (main_menu.gd blacks it out)
func play_out() -> void:
	shown = false
	W._finish(anim)
	corridor.set_sound(false)
	corridor.push_in(1.9)
	anim = create_tween()
	anim.tween_property(panel, "modulate:a", 0.0, 0.4)

## Once the screen is black: stop drawing the corridor
func hide_now() -> void:
	visible = false
	sub.render_target_update_mode = SubViewport.UPDATE_DISABLED

# ---- tapes ----------------------------------------------------------------------------------
## The last tape written, else the first
func _default_tape() -> int:
	var best := 0
	var newest := -1
	for i in Saves.SLOTS:
		var inf := Saves.info(i)
		if int(inf.get("saved_unix", -1)) > newest:
			newest = int(inf.get("saved_unix", -1))
			best = i
	return best

func _pick_tape(i: int) -> void:
	tape_sel = i
	erase_armed = false
	_refresh_tapes()

func _refresh_tapes() -> void:
	tapes_box.visible = not guest
	for i in Saves.SLOTS:
		var inf := Saves.info(i)
		var hint := "BLANK TAPE"
		if inf.get("broken", false):
			hint = "DAMAGED // UNREADABLE"
		elif not inf.is_empty():
			hint = "%s  //  %s" % [str(inf.get("level_tag", "LEVEL ?")), _runtime(float(inf.get("play_time", 0.0)))]
		_set_entry("tape%d" % i, "", hint, true)
	var inf := Saves.info(tape_sel)
	var written: bool = not inf.is_empty() and not inf.get("broken", false)
	if written:
		card_lines[0].text = str(inf.get("level_name", "")).to_upper()
		card_lines[1].text = "RESUMES WHERE YOU LEFT OFF"
		card_lines[2].text = "RUNTIME %s" % _runtime(float(inf.get("play_time", 0.0)))
		card_lines[3].text = "LAST RECORDED  " + _date(int(inf.get("saved_unix", 0)))
	else:
		card_lines[0].text = "BLANK TAPE" if not inf.get("broken", false) else "DAMAGED TAPE"
		card_lines[1].text = "A NEW RECORDING STARTS AT THE THRESHOLD"
		card_lines[2].text = ""
		card_lines[3].text = "" if not inf.get("broken", false) else "BEGIN RECORDS OVER IT"
	card_lines[2].visible = card_lines[2].text != ""
	card_lines[3].visible = card_lines[3].text != ""
	if not guest:
		sub_label.text = "PICK A TAPE  //  A WRITTEN ONE PICKS UP WHERE IT STOPPED"
		_set_entry("begin", "BEGIN", ("CONTINUE TAPE %02d" if written else "RECORD ON TAPE %02d") % (tape_sel + 1))
		_set_entry("erase", "ERASE TAPE", ("PRESS AGAIN TO ERASE TAPE %02d" if erase_armed else "TAPE %02d") % (tape_sel + 1), Saves.exists(tape_sel))
	for i in entries.size():
		if entries[i].button.visible:
			_entry_state(i)

static func _runtime(secs: float) -> String:
	var s := int(secs)
	return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]

## Local time, the way the camcorder stamps it: 14 OCT 2026  18:20
static func _date(unix: int) -> String:
	if unix <= 0:
		return "--"
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(unix + bias)
	var months := ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
	return "%02d %s %d  %02d:%02d" % [d.day, months[clampi(d.month - 1, 0, 11)], d.year, d.hour, d.minute]

# ---- crew / room ----------------------------------------------------------------------------
## You, then everyone in the room who has said hello, in the order they came (peer ids grow)
func _roster() -> Array:
	var me_id := multiplayer.get_unique_id() if Net.is_online() else 1
	var me := Net.my_name()
	var out := [{"id": 0, "name": me if me != "" else "YOU", "color": Net.PEER_COLORS[me_id % Net.PEER_COLORS.size()], "local": true,
		"ready": guest and am_ready}]
	var ids: Array = Net.names.keys()
	ids.sort()
	for id in ids:
		if str(Net.names[id]) == "":
			continue
		out.append({"id": int(id), "name": Net.label_for(int(id)), "color": Net.PEER_COLORS[int(id) % Net.PEER_COLORS.size()], "local": false,
			"ready": Net.ready_peers.has(int(id)) and int(id) != 1})
	return out.slice(0, Net.MAX_PLAYERS)

func _refresh_crew(instant := false) -> void:
	var roster := _roster()
	if visible:
		corridor.set_roster(roster, instant)
	var guests_ready := 0
	for r in roster.slice(1):
		if r.ready:
			guests_ready += 1
	crew_label.text = "CREW  %d / %d" % [roster.size(), Net.MAX_PLAYERS]
	if roster.size() > 1:
		crew_label.text += "   READY  %d / %d" % [guests_ready, roster.size() - 1]
	for i in crew_dots.get_child_count():
		var d: ColorRect = crew_dots.get_child(i).get_child(0)
		d.color = (roster[i].color as Color) if i < roster.size() else Color(CREAM, 0.15)
	_refresh_room()

func _refresh_room() -> void:
	var online := Net.is_online()
	if guest:
		room_label.text = "IN THE HOST'S ROOM"
	elif Net.hosting and Net.share_link != "":
		room_label.text = "ROOM CODE   " + Net.share_link
	elif Net.hosting:
		room_label.text = "OPENING THE ROOM ..."
	else:
		room_label.text = ""
	room_label.visible = room_label.text != ""
	_set_entry("host", "", "INVITE UP TO %d SURVIVORS" % (Net.MAX_PLAYERS - 1), not guest and not Net.hosting)
	_set_entry("copy", "", "TO THE CLIPBOARD", not guest and Net.hosting and Net.share_link != "")
	_set_entry("close", "", "SEND EVERYONE HOME" if multiplayer.get_peers().size() > 0 else "PLAY ON YOUR OWN", not guest and Net.hosting)
	var waiting := 0
	for id in multiplayer.get_peers():
		if Net.names.has(id) and not Net.ready_peers.has(id):
			waiting += 1
	_set_entry("begin", "", entries[_entry_of("begin")].hint.text if waiting == 0 else "WAITING FOR %d SURVIVOR%s TO READY UP" % [waiting, "" if waiting == 1 else "S"], not guest)
	entries[_entry_of("begin")].label.modulate.a = 1.0 if waiting == 0 else 0.4
	wait_label.visible = guest
	wait_label.text = "READY  //  WAITING FOR THE HOST TO BEGIN" if am_ready else "PRESS READY WHEN YOU ARE SET"
	_set_entry("ready", "READY" if not am_ready else "NOT READY", "TELL THE HOST YOU ARE SET" if not am_ready else "STAND DOWN", guest)
	_set_entry("back", "", "LEAVE THE ROOM" if guest else "MAIN MENU")
	tag_label.text = "SURVIVOR LOBBY  //  GUEST" if guest else ("SURVIVOR LOBBY  //  HOST" if Net.hosting and online else "SURVIVOR LOBBY")
	title_label.text = "STAND BY" if guest else "FIELD TAPES"
	for f in fringes:
		f.text = title_label.text
	if guest:
		sub_label.text = "THE HOST'S TAPE RUNS THIS RECORDING"
	status_label.text = Net.status if (Net.hosting or guest or Net.status != "OFFLINE") else ""
	status_label.visible = status_label.text != ""

func _on_net_status(_s: String) -> void:
	if guest and not Net.is_online() and shown:
		guest = false                        # dropped out of the host's room: on your own again, with your tapes
		tape_sel = _default_tape()
		_refresh_tapes()
	_refresh_crew()

## Guest: the host pressed BEGIN, or was in a run already when we came in
func _on_lobby_changed(open: bool, start: bool) -> void:
	if shown and guest and (start or not open):
		begin_requested.emit()

# ---- actions --------------------------------------------------------------------------------
func _on_ready() -> void:
	if not guest:
		return
	am_ready = not am_ready
	Net.set_ready(am_ready)
	_refresh_room()

func _on_begin() -> void:
	if guest or not Net.all_ready():
		return
	Saves.begin(tape_sel)
	Net.start_lobby()
	begin_requested.emit()

func _on_erase() -> void:
	if not Saves.exists(tape_sel):
		return
	if not erase_armed:
		erase_armed = true
		_refresh_tapes()
		return
	erase_armed = false
	Saves.erase(tape_sel)
	_refresh_tapes()

func _on_back() -> void:
	back_requested.emit()

func _unhandled_input(e: InputEvent) -> void:
	if not shown or not (e is InputEventKey and e.pressed):
		return
	var k: Key = e.physical_keycode
	get_viewport().set_input_as_handled()
	if anim and anim.is_valid():
		W._finish(anim)                     # a key skips the build-up first
	match k:
		KEY_ESCAPE:
			if not e.echo:
				_on_back()
		KEY_UP, KEY_W, KEY_Z:
			_step(-1)
		KEY_DOWN, KEY_S:
			_step(1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if not e.echo:
				_activate(sel if sel >= 0 else _entry_of("back" if guest else "begin"))     # nothing picked: Enter is BEGIN

func _process(dt: float) -> void:
	t += dt
	if not visible:
		return
	rec_dot.color.a = 1.0 if fmod(t, 1.1) < 0.55 else 0.0
	if wait_label.visible:
		wait_label.modulate.a = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 2.4))
