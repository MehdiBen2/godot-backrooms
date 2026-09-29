extends CanvasLayer
## The death screen, as the end of the tape: the picture drops into a burst of static the moment the
## tape stops, the static settles to a faint snow, and a found-footage end card comes up bottom-left
## over a dark gradient and a red-black vignette:
##   ■ STOP
##   RECORDING ENDED
##   CAM 04 // 00:14:37          (the tape counter when it stopped: Game.time)
##   CAUSE           THE HOWLER
##   ENTRIES LOGGED  2           (this life: the archive starts empty every level start)
##   RESEARCH YIELD  +340 RY     (Clearance.total since main.gd noted it at the start: Game.run_yield)
##   TAPE LAID       46 M        (your strips still up from this life: TapeMarks.laid_since)
## then the respawn prompt once a click will be taken. Built by Game.kill_player(); it animates itself
## and is freed on the respawn.

const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const DIM_CREAM := Color(0.902, 0.882, 0.804, 0.55)
const VALUE_CREAM := Color(0.902, 0.882, 0.804, 0.85)
const BTN_CREAM := Color(0.902, 0.882, 0.804, 0.80)
const LINE_CREAM := Color(0.902, 0.882, 0.804, 0.35)
const TITLE_COLOR := Color("d8d3bd")
const DOT_RED := Color("c4271f")
const SHADOW_RED := Color(0.627, 0.078, 0.059, 0.55)
const STOP_BURST := 0.28             # s of full static as the tape stops
const SNOW := 0.07                   # the static that stays under the card
const LABEL_W := 190.0               # the stat names' column
const STAT_STEP := 0.14              # s between the stat lines coming up

const STATIC_SHADER := """
shader_type canvas_item;
// tape static: fresh snow every frame in 2 px grains, rows jittering in brightness, and a darker
// tracking band rolling up the picture
uniform float amount = 1.0;
float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 px = floor(FRAGCOORD.xy / 2.0);
	float n = h(px + fract(TIME * 13.7) * 311.0);
	float row = h(vec2(px.y, floor(TIME * 30.0)));
	float band = 1.0 - 0.45 * smoothstep(0.1, 0.0, abs(fract(UV.y + TIME * 0.35) - 0.5));
	COLOR = vec4(vec3(n * (0.55 + 0.45 * row) * band), amount);
}
"""

var ready_at := 1.6                # seconds before the respawn prompt shows (Game.RESPAWN_READY)
var t := 0.0
var _root: Control
var _static_mat: ShaderMaterial
var _box: VBoxContainer
var _anchor: Control
var _stats: Array = []             # the stat rows, faded in one after another
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

## "00:14:37", the HUD's tape counter
static func _counter(seconds: float) -> String:
	var s := int(seconds)
	return "%02d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]

func _build(killer: String) -> void:
	_root = _ignore(Control.new())
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	# the tape stopping: static over everything, settling to a faint snow
	var snow := ColorRect.new()
	snow.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sh := Shader.new()
	sh.code = STATIC_SHADER
	_static_mat = ShaderMaterial.new()
	_static_mat.shader = sh
	snow.material = _static_mat
	_root.add_child(_ignore(snow))
	# linear-gradient(to top, rgba(0,0,0,0.85) 0%, rgba(0,0,0,0.35) 45%, rgba(0,0,0,0) 75%)
	_root.add_child(_gradient([0.0, 0.45, 0.75, 1.0],
		[Color(0, 0, 0, 0.85), Color(0, 0, 0, 0.35), Color(0, 0, 0, 0), Color(0, 0, 0, 0)],
		GradientTexture2D.FILL_LINEAR, Vector2(0, 1), Vector2(0, 0), 64, 256))
	# radial-gradient(circle at center, rgba(0,0,0,0) 45%, rgba(20,0,0,0.7) 100%)
	_root.add_child(_gradient([0.0, 0.45, 1.0], [Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0.08, 0, 0, 0.70)],
		GradientTexture2D.FILL_RADIAL, Vector2(0.5, 0.5), Vector2(1, 1), 256, 256))

	# the card: bottom-left corner at (8vw, 86vh); grows up and right so it stays on screen
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

	# ■ STOP, where the camcorder's REC was
	var tag := HBoxContainer.new()
	tag.add_theme_constant_override("separation", 8)
	_box.add_child(_ignore(tag))
	var dot_c := CenterContainer.new()
	dot_c.custom_minimum_size = Vector2(10, 16)
	tag.add_child(_ignore(dot_c))
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(10, 10)
	_dot.color = DOT_RED
	dot_c.add_child(_ignore(_dot))
	tag.add_child(_label("STOP", 4.0, 14, DIM_CREAM))

	var title := _label("RECORDING ENDED", 2.0, 64, TITLE_COLOR)
	title.add_theme_color_override("font_shadow_color", SHADOW_RED)
	title.add_theme_constant_override("shadow_offset_x", 2)
	title.add_theme_constant_override("shadow_offset_y", 0)
	_box.add_child(title)
	_box.add_child(_label("CAM 04 // " + _counter(Game.time), 4.0, 16, DIM_CREAM))
	var rule := ColorRect.new()
	rule.custom_minimum_size = Vector2(0, 1)
	rule.color = LINE_CREAM
	_box.add_child(_ignore(rule))

	var filed := maxi(0, Clearance.total - Game.run_yield)
	var tape := TapeMarks.laid_since(float(Game.run_unix)) if Game.run_unix > 0 else 0.0
	for row in [
		["CAUSE", killer.to_upper()],
		["ENTRIES LOGGED", str(Archive.discovered.size())],
		["RESEARCH YIELD", ("+%d %s" % [filed, Clearance.unit]) if filed > 0 else "NONE FILED"],
		["TAPE LAID", ("%d M" % roundi(tape)) if tape >= 0.5 else "NONE"],
	]:
		var h := HBoxContainer.new()
		h.modulate.a = 0.0
		var name_label := _label(str(row[0]), 3.0, 13, DIM_CREAM)
		name_label.custom_minimum_size.x = LABEL_W
		h.add_child(name_label)
		h.add_child(_label(str(row[1]), 2.0, 16, VALUE_CREAM))
		_box.add_child(_ignore(h))
		_stats.append(h)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
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
	# full static as the tape stops, easing down to a faint snow under the card
	var burst := 1.0 if t < STOP_BURST else lerpf(1.0, SNOW, clampf((t - STOP_BURST) / 0.5, 0.0, 1.0))
	_static_mat.set_shader_parameter("amount", burst)
	# the card comes up out of the static (fade + 8 px rise), then its stat lines one by one
	var p := 1.0 - pow(1.0 - clampf((t - STOP_BURST) / 0.9, 0.0, 1.0), 3.0)
	_box.modulate.a = p
	_anchor.position.y = 8.0 * (1.0 - p)
	for i in _stats.size():
		(_stats[i] as Control).modulate.a = clampf((t - STOP_BURST - 0.5 - i * STAT_STEP) / 0.25, 0.0, 1.0)
	# the respawn prompt only shows once a click will be taken, then breathes slowly
	var r := clampf((t - ready_at) / 0.6, 0.0, 1.0)
	_respawn.modulate.a = r * (0.75 + 0.25 * cos((t - ready_at) * 2.2))
	# the stop square blinks like the REC dot did: 1.1 s, half on
	_dot.visible = fmod(t, 1.1) < 0.55
