extends RefCounted
## Phosphor bloom shared by the CRT-styled UI (the TAB terminal, inventory.gd, and the HUD's
## crt_layer.gd): a source texture's bright parts blurred in two separable passes at half
## resolution (shaders/ui_bloom.gdshader), horizontal then vertical, each in its own SubViewport.
## ui_vhs_overlay.gdshader adds texture() back (bloom_tex / bloom_amt).

const DOWNSCALE := 2             # keep it 2: ui_bloom.gdshader relies on it

const WIDE_REACH := 2.5          # the halo's reach, times the tight glow's
const PASS_DIV := [2, 2, 4, 8]   # size divisors of the passes: tight h, tight v (half), halo h, halo v (quarter, eighth)

var vps: Array = []              # [tight h, tight v] SubViewports, then [halo h, halo v] when `wide`
var mats: Array = []
var wide := false

## `wide` adds a second, much broader blur of the tight glow: neon's hot core plus a soft halo that
## reaches far across the dark (texture_wide())
func _init(parent: Node, src: Texture2D, with_halo := false) -> void:
	wide = with_halo
	var h := _pass(parent, src, Vector2(1, 0), true)
	var v := _pass(parent, h.get_texture(), Vector2(0, 1), false)
	if wide:
		var wh := _pass(parent, v.get_texture(), Vector2(1, 0), false)
		_pass(parent, wh.get_texture(), Vector2(0, 1), false)

func texture_wide() -> Texture2D:
	return (vps[3] as SubViewport).get_texture()

func texture() -> Texture2D:
	return (vps[1] as SubViewport).get_texture()

## `full`: the source's size in pixels; `reach`: how far the glow spreads, in those pixels
func resize(full: Vector2i, reach: float) -> void:
	for i in vps.size():
		var div: int = PASS_DIV[i]
		(vps[i] as SubViewport).size = Vector2i((Vector2(full) / float(div)).ceil())
		# 13 taps span +-6 steps, in texels of the pass's source (full size for pass 0, else the previous pass)
		var src_div: int = 1 if i == 0 else PASS_DIV[i - 1]
		var r := reach * (WIDE_REACH if i >= 2 else 1.0)
		(mats[i] as ShaderMaterial).set_shader_parameter("spacing", r / 6.0 / float(src_div))

## Render only while the owner is on screen
func set_running(on: bool) -> void:
	for vp in vps:
		(vp as SubViewport).render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED

## One blur pass: `src` drawn at half resolution through ui_bloom.gdshader along `dir`
func _pass(parent: Node, src: Texture2D, dir: Vector2, bright_pass: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	parent.add_child(vp)
	var r := TextureRect.new()
	r.texture = src
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/ui_bloom.gdshader")
	m.set_shader_parameter("direction", dir)
	m.set_shader_parameter("bright_pass", bright_pass)
	r.material = m
	vp.add_child(r)
	vps.append(vp)
	mats.append(m)
	return vp
