extends Control
## A patch of HUD drawn like the TAB terminal's CRT: whatever is added under `content` renders into
## its own transparent SubViewport, gets the same phosphor bloom (crt_bloom.gd, strength and reach
## from inventory.gd BLOOM / BLOOM_RADIUS) flickering the same way (crt_flicker.gd), and goes back
## on screen through shaders/ui_vhs_overlay.gdshader without the lens curve, so it also picks up the
## terminal's scanlines, grain and tear glitches. Used by the scanner reticle (scan_readout.gd) and
## the new-entry toast (terminal_toast.gd).
## Place and size it like any Control; `content` is laid out in the same size. It only renders while
## `running` is on, so owners switch it on while they have something to show.

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const CrtBloom := preload("res://scripts/UI/crt/crt_bloom.gd")
const CrtFlicker := preload("res://scripts/UI/crt/crt_flicker.gd")

var content: Control             # add children here
var viewport: SubViewport
var screen: TextureRect
var mat: ShaderMaterial
var bloom: CrtBloom
var glow := CrtFlicker.new()
var glow_scale := 1.0                # of the terminal's glow this layer gets
var glitch := 0.0                # 0..1 tear burst, decays on its own (burst())
var running := false: set = set_running

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport = SubViewport.new()
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.size_2d_override_stretch = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	content = Control.new()
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(content)
	bloom = CrtBloom.new(self, viewport.get_texture())

	screen = TextureRect.new()
	screen.texture = viewport.get_texture()
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.visible = false
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/ui_vhs_overlay.gdshader")
	mat.set_shader_parameter("distortion", 0.0)
	mat.set_shader_parameter("chroma_amt", 0.0)
	mat.set_shader_parameter("scan_amt", 0.14)
	mat.set_shader_parameter("grain_amt", 0.04)
	mat.set_shader_parameter("vignette_amt", 0.0)
	mat.set_shader_parameter("bloom_tex", bloom.texture())
	screen.material = mat
	add_child(screen)

	resized.connect(_fit)
	get_viewport().size_changed.connect(_fit)
	_fit()
	if running:                  # switched on before it was built: apply it now
		running = false
		set_running(true)

## Render at the pixel size it is shown at, so the text stays sharp above 1080p
func _fit() -> void:
	if not viewport or size.x < 2.0 or size.y < 2.0:
		return
	var k := get_viewport().get_final_transform().get_scale()
	var px := clampf(maxf(k.x, k.y), 0.5, 3.0)
	var s := (size * px).round()
	viewport.size = Vector2i(maxi(int(s.x), 1), maxi(int(s.y), 1))
	viewport.size_2d_override = Vector2i(size.round())
	bloom.resize(viewport.size, Term.BLOOM_RADIUS * px)
	mat.set_shader_parameter("aspect", size.x / size.y)

func set_running(on: bool) -> void:
	if on == running:
		return
	running = on
	if not viewport:
		return
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	bloom.set_running(on)
	screen.visible = on          # never show a stale frame from last time
	if on:
		glow.kick(0.3, true)     # the glow stutters up as it comes on

## A short tear-glitch burst over this layer (and a jolt in its glow)
func burst(amount := 1.0) -> void:
	glitch = maxf(glitch, amount)
	glow.kick(randf_range(0.1, 0.25))

func _process(dt: float) -> void:
	if not running:
		return
	glitch = maxf(0.0, glitch - dt * 2.5)
	mat.set_shader_parameter("glitch", maxf(glitch, Game.glitch * 0.8))
	mat.set_shader_parameter("bloom_amt", Term.BLOOM * glow_scale * glow.update(dt))
