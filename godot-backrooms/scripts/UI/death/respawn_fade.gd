extends Node
## Respawn: blur to black, wake up. The picture softens, drains of colour and a vignette closes in until
## the screen is black; only then is the level reloaded (you never see the swap). Then it opens again
## from black like waking up: blurred at first, sharpening as the light comes back. Sound is ducked on
## the Master bus the whole way. Also used for a level change and for falling down a pit.
## Child of the Death autoload (Death.respawn_transition / Death.respawn_busy).

const FADE_IN := 0.7
const HOLD := 0.35
const FADE_OUT := 1.4
const DUCK_DB := -40.0
const SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
void fragment() {
	float p = progress;
	vec3 c = textureLod(screen_tex, SCREEN_UV, p * 6.0).rgb;
	float g = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(g), p * 0.85);
	vec2 d = SCREEN_UV - 0.5;
	d.x *= SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	float iris = mix(1.6, 0.0, p);
	c *= 1.0 - smoothstep(iris - 0.45, iris, length(d));
	c *= 1.0 - smoothstep(0.6, 1.0, p);
	COLOR = vec4(c, 1.0);
}
"""

var busy := false
var _layer: CanvasLayer
var _mat: ShaderMaterial

func _ensure() -> void:
	if _layer != null:
		return
	_layer = CanvasLayer.new()
	_layer.layer = 100
	_layer.visible = false
	add_child(_layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("progress", 0.0)
	rect.material = _mat
	_layer.add_child(rect)

func _progress(p: float) -> void:
	_mat.set_shader_parameter("progress", p)

## Draw the (pass-through) fade for a moment so its pipeline is compiled before the first death
func warm() -> void:
	if busy:
		return
	_ensure()
	_progress(0.0)
	_layer.visible = true
	await get_tree().create_timer(0.6).timeout
	if not busy:
		_layer.visible = false

## Fade the screen to black, run `swap` (reload / reset) behind it, then fade back in.
func run(swap: Callable) -> void:
	if busy:
		return
	busy = true
	_ensure()
	_progress(0.0)
	_layer.visible = true
	var bus := AudioServer.get_bus_index("Master")
	var db0 := AudioServer.get_bus_volume_db(bus)
	var duck := func(v: float) -> void: AudioServer.set_bus_volume_db(bus, v)
	var tw := create_tween().set_parallel(true)
	tw.tween_method(_progress, 0.0, 1.0, FADE_IN).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	tw.tween_method(duck, db0, db0 + DUCK_DB, FADE_IN).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_SINE)
	await tw.finished
	swap.call()
	# The reload is a heavy frame. Wait until the new level is up and has rendered a few frames, hold,
	# and only then fade in, so the fade is actually seen instead of being swallowed by the hitch.
	for i in 8:
		await get_tree().process_frame
	await get_tree().create_timer(HOLD).timeout
	var tw2 := create_tween().set_parallel(true)
	tw2.tween_method(_progress, 1.0, 0.0, FADE_OUT).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw2.tween_method(duck, db0 + DUCK_DB, db0, FADE_OUT).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	await tw2.finished
	AudioServer.set_bus_volume_db(bus, db0)
	_layer.visible = false
	busy = false
