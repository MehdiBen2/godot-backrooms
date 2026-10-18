extends CanvasLayer
## Blood on the lens (THE TALL ONE's claws: tall_one.gd, through Death.lens_splat). Splats thrown onto the glass,
## droplets flung on past them, runs sliding down over the next seconds (shaders/lens_blood.gdshader). Drawn over the
## camera pass (hud.gd's post 1 and grade 2), which drains the colour out of the picture: the blood stays red. Under
## the VHS smear (4) and the HUD (5). It darkens with the eyelids and the closing edges (Game.fx_blink, fx_fade).
## Up to MAX at once: a new one takes the oldest one's place.

const SHADER := preload("res://shaders/lens_blood.gdshader")
const MAX := 12

var _mat: ShaderMaterial
var _splat := PackedVector4Array()
var _info := PackedVector4Array()
var _next := 0
var _fade := 1.0
var _fade_rate := 0.0

func _ready() -> void:
	layer = 3
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	var rect := ColorRect.new()
	rect.material = _mat
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
	clear()

## A splat at `uv` (0..1 of the screen), thrown along `dir` (screen space, y down); `size` a fraction of its height
func splat(uv: Vector2, dir: Vector2, size: float) -> void:
	_splat[_next] = Vector4(uv.x, uv.y, size, randf() * 100.0)
	_info[_next] = Vector4(dir.x, dir.y, 0.0, 1.0)
	_next = (_next + 1) % MAX
	_fade = 1.0
	_fade_rate = 0.0
	visible = true

## Fade it all out over `seconds`
func wipe(seconds: float) -> void:
	if visible:
		_fade_rate = 1.0 / maxf(seconds, 0.01)

func clear() -> void:
	_splat.resize(MAX)
	_info.resize(MAX)
	_splat.fill(Vector4.ZERO)
	_info.fill(Vector4.ZERO)
	_next = 0
	_fade = 1.0
	_fade_rate = 0.0
	visible = false
	_push()

func _process(delta: float) -> void:
	if not visible:
		return
	for i in MAX:
		var f := _info[i]
		if f.w > 0.0:
			f.z += delta
			_info[i] = f
	_fade = maxf(0.0, _fade - _fade_rate * delta)
	if _fade <= 0.0:
		clear()
		return
	_push()

func _push() -> void:
	var vs := get_viewport().get_visible_rect().size
	_mat.set_shader_parameter("splat", _splat)
	_mat.set_shader_parameter("info", _info)
	_mat.set_shader_parameter("fade", _fade)
	_mat.set_shader_parameter("dark", maxf(Game.fx_blink, Game.fx_fade))
	_mat.set_shader_parameter("aspect", vs.x / maxf(vs.y, 1.0))
