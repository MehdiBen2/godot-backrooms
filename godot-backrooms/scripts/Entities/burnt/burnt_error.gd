extends CanvasLayer
## What the tape shows after the Burnt (burnt.gd): not the picture but the camera's own firmware failing on the
## frame it was recording. Black, dying static, and fault lines typing themselves out, their characters rotting
## as they go; the last of them should not be there at all. It holds a few seconds over the death screen
## (death_overlay.gd, which carries on underneath), then breaks up like the tape losing tracking and lets it through.

const HOLD := 5.6                   # seconds it covers the screen
const BREAK := 0.9                  # ...then breaks up over this
const LINE_AT := 0.45               # the first line starts
const LINE_STEP := 0.62             # one after another
const TYPE := 0.4                   # each types out over this
const GARBAGE := "#%&@$?/\\|<>*^~=+0123456789"
const CREAM := Color(0.902, 0.882, 0.804)
const RED := Color("c4271f")
const LINES := [
	["CAM 04 :: FATAL ERROR 0x0000B07N", CREAM],
	["SUBJECT VITALS ............. NONE", CREAM],
	["IMAGE SENSOR OBSTRUCTED (FACE)", CREAM],
	["FRAMES RECOVERED: 1 OF 1", CREAM],
	["RECORDING CONTINUES WITHOUT SUBJECT", CREAM],
	["IT IS WEARING YOUR CAMERA NOW", RED],
]
const STATIC := """shader_type canvas_item;
uniform float amount = 1.0;
float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 px = floor(FRAGCOORD.xy * 0.5);
	float n = h(px + floor(TIME * 30.0) * 17.0);
	float row = h(vec2(floor(FRAGCOORD.y * 0.25), floor(TIME * 12.0)));
	COLOR = vec4(vec3(n * (0.6 + 0.4 * row)) * amount, 1.0);
}
"""

var t := 0.0
var _root: Control
var _static: ShaderMaterial
var _flash: ColorRect
var _labels: Array[Label] = []
var _blocks: Array[ColorRect] = []
const BLOCKS := 14
const BLOCK_COLORS := [Color(0.902, 0.882, 0.804), Color("c4271f"), Color(0.05, 0.05, 0.06), Color(0.2, 0.9, 0.35), Color(0.55, 0.2, 0.75), Color(1, 1, 1)]

func _ready() -> void:
	layer = 40                          # over the death screen
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE   # (the click to respawn goes through)
	add_child(_root)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = STATIC
	_static = ShaderMaterial.new()
	_static.shader = sh
	bg.material = _static
	_root.add_child(bg)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.position = Vector2(64, 64)
	box.add_theme_constant_override("separation", 10)
	_root.add_child(box)
	var font := FontVariation.new()
	if ResourceLoader.exists("res://fonts/vcr.ttf"): font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 2
	for l: Array in LINES:
		var lb := Label.new()
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lb.add_theme_font_override("font", font)
		lb.add_theme_font_size_override("font_size", 26)
		lb.add_theme_color_override("font_color", l[1])
		lb.add_theme_color_override("font_shadow_color", Color(0.63, 0.08, 0.06, 0.6))
		lb.add_theme_constant_override("shadow_offset_x", 2)
		lb.text = ""
		box.add_child(lb)
		_labels.append(lb)
	# broken macroblocks over the error screen: squares of wrong colour that jump about on a coarse grid
	for i in BLOCKS:
		var b := ColorRect.new()
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.visible = false
		_root.add_child(b)
		_blocks.append(b)
	_flash = ColorRect.new()
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.color = Color(1, 1, 1, 0)
	_root.add_child(_flash)

static func _hash(n: float) -> float:
	return fposmod(sin(n * 12.9898) * 43758.5453, 1.0)

## `text` as far as it has typed, with characters rotting: more while it types, a few for good after
func _rot(text: String, shown: float, step: float, line: int) -> String:
	var out := ""
	var n := int(ceil(text.length() * clampf(shown, 0.0, 1.0)))
	for i in n:
		var c := text[i]
		var r := _hash(step * 1.37 + i * 7.1 + line * 31.0)
		var rot_p := 0.35 if shown < 1.0 else 0.04
		if c != " " and r < rot_p:
			c = GARBAGE[int(_hash(r * 91.0 + step) * GARBAGE.length()) % GARBAGE.length()]
		out += c
	return out

func _process(dt: float) -> void:
	t += dt
	var step := floorf(t * 24.0)
	# the static: a burst as the picture dies, a low snow under the text, a burst again as it breaks up
	var snow := lerpf(1.0, 0.12, clampf(t / 0.5, 0.0, 1.0))
	var out := clampf((t - HOLD) / BREAK, 0.0, 1.0)
	_static.set_shader_parameter("amount", maxf(snow, 0.6 * sin(out * PI)))
	for i in _labels.size():
		var lb := _labels[i]
		var at := LINE_AT + i * LINE_STEP
		lb.text = _rot(String(LINES[i][0]), (t - at) / TYPE, step, i)
		# tracking trouble: a line jumps sideways now and then
		lb.position.x = (_hash(step + i * 13.0) - 0.5) * 30.0 if _hash(step * 0.7 + i) > 0.93 else 0.0
	# the last line blinks once it is in
	var last := _labels[-1]
	if t > LINE_AT + (LINES.size() - 1) * LINE_STEP + TYPE:
		last.visible = fmod(t, 0.9) < 0.6
	# the squares: a burst of them as the picture dies, a few twitching about after, a storm as it breaks up
	var size := get_viewport().get_visible_rect().size
	var heavy := maxf(1.0 - clampf(t / 0.8, 0.0, 1.0), out)
	var block_step := floorf(t * 9.0)
	for i in _blocks.size():
		var b := _blocks[i]
		var hv := _hash(block_step * 3.1 + i * 17.0)
		b.visible = hv < 0.18 + 0.7 * heavy
		if not b.visible: continue
		var grid := 32.0
		var w := grid * (1.0 + floorf(_hash(hv * 41.0 + i) * 5.0))
		var hh := grid * (1.0 + floorf(_hash(hv * 59.0 + i) * 3.0))
		b.position = Vector2(floorf(_hash(hv * 7.0 + i) * size.x / grid) * grid, floorf(_hash(hv * 13.0 + i) * size.y / grid) * grid)
		b.size = Vector2(w, hh)
		var c: Color = BLOCK_COLORS[int(_hash(hv * 23.0 + i) * BLOCK_COLORS.size()) % BLOCK_COLORS.size()]
		b.color = Color(c.r, c.g, c.b, 0.35 + 0.5 * _hash(hv * 31.0))
	# a white frame now and then: the sensor flaring
	_flash.color.a = 0.85 if _hash(step + 99.0) > 0.985 else 0.0
	# breaking up: the whole thing tears sideways in steps and drops away
	if out > 0.0:
		_root.position.x = (_hash(step) - 0.5) * 60.0 * out
		_root.modulate.a = (1.0 - out) * (1.0 if _hash(step + 5.0) > 0.3 else 0.35)
	if out >= 1.0:
		queue_free()
