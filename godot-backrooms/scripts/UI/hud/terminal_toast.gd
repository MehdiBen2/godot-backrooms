extends Control
## HUD notification in the inventory terminal's style: a folder-tab sheet that slides in at the top
## right, types its lines in, shows a shrinking life bar and slides out. hud.gd pushes a
## "[NEW ENTRY LOGGED]" one when the field scanner logs an entity; push() queues, so entries that
## land together follow one another.

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const W := 560.0
const TAB_H := 40.0
const SLANT := 22.0
const CHAMFER := 10.0
const LINE := 3.0
const HOLD := 5.0
const RIGHT := 42.0              # lines up with the HUD's top-right block (hud.gd)
const TOP := 150.0

var queue: Array = []            # [title, lines]; lines: [[text, color, font size], ...]
var busy := false
var sheet: Control
var tab_label: Label
var body: VBoxContainer
var tab_w := 0.0
var life := -1.0
var anim: Tween
var chime: AudioStreamPlayer
var font := FontVariation.new()

func _ready() -> void:
	anchor_left = 1.0; anchor_right = 1.0
	offset_left = -RIGHT - W; offset_right = -RIGHT
	offset_top = TOP; offset_bottom = TOP
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 1
	font.variation_embolden = 0.4

	sheet = Control.new()
	sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet.draw.connect(_draw_sheet)
	add_child(sheet)
	tab_label = _label("", 19, Term.TEXT)
	tab_label.custom_minimum_size = Vector2.ZERO   # sized to its text: the tab's width follows it
	tab_label.clip_text = false
	tab_label.position = Vector2(18, 9)
	sheet.add_child(tab_label)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.position = Vector2(22, TAB_H + 14)
	sheet.add_child(body)

	chime = AudioStreamPlayer.new()
	chime.stream = load("res://audio/terminal/terminal_logged.wav")
	chime.volume_db = -8.0
	add_child(chime)

func _label(text: String, px: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size.x = W - 44.0
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func push(title: String, lines: Array) -> void:
	queue.append([title, lines])
	if not busy:
		_next()

func _next() -> void:
	if queue.is_empty():
		busy = false
		visible = false
		return
	busy = true
	visible = true
	var entry: Array = queue.pop_front()
	tab_label.text = entry[0]
	tab_w = tab_label.get_combined_minimum_size().x + 36.0 + SLANT
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	for ln in entry[1]:
		body.add_child(_label(str(ln[0]), int(ln[2]), ln[1]))
	var h := TAB_H + 14.0 + body.get_combined_minimum_size().y + 22.0
	sheet.size = Vector2(W, h)
	life = 1.0
	chime.play()

	# in: slide from the right while it flickers on, then each line types itself in
	sheet.position.x = 70.0
	sheet.modulate.a = 0.0
	if anim: anim.kill()
	anim = create_tween().set_parallel(true)
	anim.tween_property(sheet, "position:x", 0.0, 0.32).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	anim.tween_method(func(x: float): sheet.modulate.a = Term.flicker(x), 0.0, 1.0, 0.3)
	var labels: Array = [tab_label] + body.get_children()
	for i in labels.size():
		var l: Label = labels[i]
		l.visible_ratio = 0.0
		anim.tween_property(l, "visible_ratio", 1.0, clampf(l.text.length() * 0.012, 0.1, 0.35)).set_delay(0.08 + i * 0.07)
	anim.tween_method(_set_life, 1.0, 0.0, HOLD).set_delay(0.3)
	# out: slide back and fade, then the next one in the queue
	anim.chain().tween_property(sheet, "position:x", 70.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	anim.tween_property(sheet, "modulate:a", 0.0, 0.25)
	anim.chain().tween_callback(func(): _next.call_deferred())   # not from inside the tween it replaces

func _set_life(v: float) -> void:
	life = v
	sheet.queue_redraw()

## Same folder-tab outline as the inventory's right-hand sheet (inventory.gd _draw_readout)
func _draw_sheet() -> void:
	var w := sheet.size.x
	var h := sheet.size.y
	var top := TAB_H
	var c := CHAMFER
	sheet.draw_colored_polygon(PackedVector2Array([
		Vector2(0, top), Vector2(w - c, top), Vector2(w, top + c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(c, h), Vector2(0, h - c)]), Term.FILL)
	var tab := PackedVector2Array([Vector2(0, top), Vector2(0, 0), Vector2(tab_w - SLANT, 0), Vector2(tab_w, top)])
	sheet.draw_colored_polygon(tab, Term.FILL)
	sheet.draw_polyline(tab, Term.AMBER, LINE, true)
	sheet.draw_polyline(PackedVector2Array([
		Vector2(tab_w, top), Vector2(w - c, top), Vector2(w, top + c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(c, h), Vector2(0, h - c), Vector2(0, top)]), Term.AMBER, LINE, true)
	if life > 0.0:                   # time left before it slides away
		sheet.draw_line(Vector2(16, h - 10), Vector2(16 + (w - 32) * life, h - 10), Color(Term.AMBER, 0.5), 2.0)
