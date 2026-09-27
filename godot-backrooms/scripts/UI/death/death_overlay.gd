extends CanvasLayer
## The death screen (the web game's #death-screen): a dark gradient from the bottom, a red-black
## vignette, and bottom-left "[dot] SIGNAL LOST / YOU DIED / <killer>", then the respawn prompt once a
## click will be taken. Built by Game.kill_player(); it animates itself and is freed on the respawn.

const DIM_CREAM := Color(0.902, 0.882, 0.804, 0.55)
const KILLER_CREAM := Color(0.902, 0.882, 0.804, 0.50)
const BTN_CREAM := Color(0.902, 0.882, 0.804, 0.80)
const LINE_CREAM := Color(0.902, 0.882, 0.804, 0.35)
const TITLE_COLOR := Color("d8d3bd")
const DOT_RED := Color("c4271f")
const SHADOW_RED := Color(0.627, 0.078, 0.059, 0.55)

var ready_at := 1.6                # seconds before the respawn prompt shows (Game.RESPAWN_READY)
var t := 0.0
var _root: Control
var _box: VBoxContainer
var _anchor: Control
var _respawn: Control
var _dot: ColorRect

func _init(killer: String, respawn_ready: float) -> void:
	layer = 30
	ready_at = respawn_ready
	_build(killer)

func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	if ResourceLoader.exists("res://fonts/vcr.ttf"):
		fv.base_font = load("res://fonts/vcr.ttf")
	fv.spacing_glyph = int(spacing)
	return fv

func _ignore(c: Control) -> Control:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _label(text: String, spacing: float, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	_ignore(l)
	return l

func _gradient(offsets: Array, colors: Array, fill: int, from: Vector2, to: Vector2, w: int, h: int) -> TextureRect:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = w
	tex.height = h
	tex.fill = fill
	tex.fill_from = from
	tex.fill_to = to
	var r := TextureRect.new()
	r.texture = tex
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.stretch_mode = TextureRect.STRETCH_SCALE
	_ignore(r)
	return r

func _build(killer: String) -> void:
	_root = _ignore(Control.new())
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.modulate.a = 0.0
	add_child(_root)
	# linear-gradient(to top, rgba(0,0,0,0.85) 0%, rgba(0,0,0,0.35) 45%, rgba(0,0,0,0) 75%)
	_root.add_child(_gradient([0.0, 0.45, 0.75, 1.0],
		[Color(0, 0, 0, 0.85), Color(0, 0, 0, 0.35), Color(0, 0, 0, 0), Color(0, 0, 0, 0)],
		GradientTexture2D.FILL_LINEAR, Vector2(0, 1), Vector2(0, 0), 64, 256))
	# radial-gradient(circle at center, rgba(0,0,0,0) 45%, rgba(20,0,0,0.7) 100%)
	_root.add_child(_gradient([0.0, 0.45, 1.0], [Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0.08, 0, 0, 0.70)],
		GradientTexture2D.FILL_RADIAL, Vector2(0.5, 0.5), Vector2(1, 1), 256, 256))

	# .death-box: bottom-left corner at (8vw, 86vh); grows up and right so the whole box stays on screen
	_anchor = _ignore(Control.new())
	_anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_anchor)
	_box = VBoxContainer.new()
	_box.anchor_left = 0.08
	_box.anchor_right = 0.08
	_box.anchor_top = 0.86
	_box.anchor_bottom = 0.86
	_box.grow_horizontal = Control.GROW_DIRECTION_END
	_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_box.add_theme_constant_override("separation", 6)
	_box.modulate.a = 0.0
	_ignore(_box)
	_anchor.add_child(_box)

	# .death-tag: [dot] SIGNAL LOST
	var tag := HBoxContainer.new()
	tag.add_theme_constant_override("separation", 8)
	_box.add_child(_ignore(tag))
	var dot_c := CenterContainer.new()
	dot_c.custom_minimum_size = Vector2(8, 16)
	tag.add_child(_ignore(dot_c))
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(8, 8)
	_dot.color = DOT_RED
	dot_c.add_child(_ignore(_dot))
	tag.add_child(_label("SIGNAL LOST", 4.0, 13, DIM_CREAM))

	var title := _label("YOU DIED", 2.0, 76, TITLE_COLOR)
	title.add_theme_color_override("font_shadow_color", SHADOW_RED)
	title.add_theme_constant_override("shadow_offset_x", 2)
	title.add_theme_constant_override("shadow_offset_y", 0)
	_box.add_child(title)
	_box.add_child(_label(killer.to_upper(), 4.0, 14, KILLER_CREAM))
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 24)
	_box.add_child(_ignore(spacer))

	# CLICK OR PRESS SPACE TO RESPAWN, underlined
	var respawn := VBoxContainer.new()
	respawn.add_theme_constant_override("separation", 4)
	respawn.modulate.a = 0.0
	_box.add_child(_ignore(respawn))
	_respawn = respawn
	respawn.add_child(_label("CLICK OR PRESS SPACE TO RESPAWN", 3.0, 13, BTN_CREAM))
	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(0, 1)
	line.color = LINE_CREAM
	respawn.add_child(_ignore(line))

func _process(dt: float) -> void:
	t += dt
	# #death-screen transition: opacity 0.5s ease-out
	_root.modulate.a = clampf(t / 0.5, 0.0, 1.0)
	# .death-box animation: deathIn 1.2s ease-out (fade + translateY 8px -> 0), a beat after the hit
	var p := 1.0 - pow(1.0 - clampf((t - 0.25) / 1.2, 0.0, 1.0), 3.0)
	_box.modulate.a = p
	_anchor.position.y = 8.0 * (1.0 - p)
	# the respawn prompt only shows once a click will be taken, then breathes slowly
	var r := clampf((t - ready_at) / 0.6, 0.0, 1.0)
	_respawn.modulate.a = r * (0.75 + 0.25 * cos((t - ready_at) * 2.2))
	# .death-tag i blink: 1.1s steps(1) infinite (50% on, 50% off)
	_dot.visible = fmod(t, 1.1) < 0.55
