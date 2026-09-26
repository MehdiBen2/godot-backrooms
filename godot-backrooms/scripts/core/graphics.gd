extends Node
## Graphics settings (autoload: Gfx). Four presets plus per-option overrides, saved to
## user://graphics.cfg and applied at startup. The first launch picks a preset from the GPU:
## integrated / unknown -> Low or Medium, discrete -> High. Ultra adds the extras (4x MSAA,
## global illumination, full-size AO, high-res volumetric fog, 8K shadows, 16x filtering).
##
## The biggest costs in this game are the tube lights around you (level_lighting.gd keeps a pool of
## them following you) and their shadows: `lights` is how many are lit at once and `light_shadows` how
## many of the nearest cast shadows (each one is six shadow renders a frame). `smooth` runs the physics
## (and so the camera) at the display's refresh rate instead of 60 Hz, so a 144 Hz screen moves at 144.

signal changed

const PATH := "user://graphics.cfg"
const ORDER := ["low", "medium", "high", "ultra"]
const SMOOTH_MAX_HZ := 165

const PRESETS := {
	"low": {"scale": 60, "msaa": 0, "fxaa": false, "shadows": 0, "ssao": 0, "ssr": false, "ssil": false,
		"glow": false, "vfog": 0, "post": 0, "aniso": 0, "vsync": true, "fps": 60,
		"lights": 6, "light_shadows": 0, "smooth": false},
	"medium": {"scale": 80, "msaa": 0, "fxaa": true, "shadows": 1, "ssao": 1, "ssr": false, "ssil": false,
		"glow": true, "vfog": 1, "post": 1, "aniso": 4, "vsync": true, "fps": 0,
		"lights": 8, "light_shadows": 2, "smooth": false},
	"high": {"scale": 100, "msaa": 2, "fxaa": true, "shadows": 2, "ssao": 2, "ssr": true, "ssil": false,
		"glow": true, "vfog": 2, "post": 2, "aniso": 8, "vsync": true, "fps": 0,
		"lights": 12, "light_shadows": 4, "smooth": true},
	"ultra": {"scale": 100, "msaa": 4, "fxaa": true, "shadows": 3, "ssao": 3, "ssr": true, "ssil": true,
		"glow": true, "vfog": 3, "post": 2, "aniso": 16, "vsync": true, "fps": 0,
		"lights": 12, "light_shadows": 8, "smooth": true},
}

var s := {}                     # the active settings (same keys as a preset)
var preset := "high"            # a preset name, or "custom" once an option was changed by hand
var fullscreen := false
var compat := false             # OpenGL fallback renderer: no SSAO / SSR / volumetric fog / GI
var post_mat: ShaderMaterial
var _post_full: Shader
var _post_lite: Shader          # same shader without the mip-mapped screen copy (cheaper)

func _ready() -> void:
	compat = RenderingServer.get_current_rendering_method() == "gl_compatibility"
	_load()
	apply()

# ---- public API ------------------------------------------------------------------------
func set_preset(name: String) -> void:
	if not PRESETS.has(name):
		return
	preset = name
	s = PRESETS[name].duplicate()
	_commit()

func set_value(key: String, value: Variant) -> void:
	if s.get(key) == value:
		return
	s[key] = value
	preset = _matching_preset()
	_commit()

func set_fullscreen(on: bool) -> void:
	fullscreen = on
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)
	_save()
	changed.emit()

## How many one-shot particles an effect should use, as a fraction of its full count
func particle_scale() -> float:
	return [0.45, 0.75, 1.0][clampi(int(s.get("post", 2)), 0, 2)]

## ui.gd hands over the post-process material so quality changes can reach it
func register_post(mat: ShaderMaterial) -> void:
	post_mat = mat
	_post_full = mat.shader
	_post_lite = mat.shader.duplicate()
	_post_lite.code = _post_lite.code.replace("filter_linear_mipmap", "filter_linear")
	_apply_post()

## World-side settings: environment effects and light shadows of the scene that is running
func apply_scene(root: Node = null) -> void:
	if root == null:
		root = Game.main if Game.main else get_tree().current_scene
	if root == null:
		return
	var we := root.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and we.environment:
		var e := we.environment
		e.ssao_enabled = s.ssao > 0 and not compat
		e.ssil_enabled = s.ssil and not compat
		e.ssr_enabled = s.ssr and not compat
		e.glow_enabled = s.glow
		e.volumetric_fog_enabled = s.vfog > 0 and not compat
	# only lights that cast shadows in the scene file / level builder are switched; the rest stay off.
	# The tube-light pool manages its own (level_lighting.gd reads `lights` / `light_shadows`).
	for l in root.find_children("*", "Light3D", true, false):
		if l.has_meta("gfx_managed"):
			continue
		if not l.has_meta("gfx_shadow"):
			l.set_meta("gfx_shadow", l.shadow_enabled)
		l.shadow_enabled = l.get_meta("gfx_shadow") and s.shadows > 0
	_apply_post()

# ---- applying ----------------------------------------------------------------------------
func apply() -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if (s.scale < 100 and not compat) else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = clampf(s.scale / 100.0, 0.5, 1.0)
	vp.msaa_3d = {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X}.get(s.msaa, Viewport.MSAA_DISABLED)
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if s.fxaa else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.anisotropic_filtering_level = {0: Viewport.ANISOTROPY_DISABLED, 2: Viewport.ANISOTROPY_2X, 4: Viewport.ANISOTROPY_4X,
		8: Viewport.ANISOTROPY_8X, 16: Viewport.ANISOTROPY_16X}.get(s.aniso, Viewport.ANISOTROPY_DISABLED)

	# shadows: map size and how soft the edges are
	var atlas: int = [1024, 2048, 4096, 8192][clampi(s.shadows, 0, 3)]
	vp.positional_shadow_atlas_size = atlas
	var soft: int = [RenderingServer.SHADOW_QUALITY_HARD, RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, RenderingServer.SHADOW_QUALITY_SOFT_HIGH][clampi(s.shadows, 0, 3)]
	RenderingServer.positional_soft_shadow_filter_set_quality(soft)
	RenderingServer.directional_soft_shadow_filter_set_quality(soft)

	if not compat:
		# ambient occlusion / global illumination detail
		var q: int = [RenderingServer.ENV_SSAO_QUALITY_VERY_LOW, RenderingServer.ENV_SSAO_QUALITY_VERY_LOW,
			RenderingServer.ENV_SSAO_QUALITY_MEDIUM, RenderingServer.ENV_SSAO_QUALITY_HIGH][clampi(s.ssao, 0, 3)]
		RenderingServer.environment_set_ssao_quality(q, s.ssao < 3, 0.5, 2, 50.0, 300.0)
		RenderingServer.environment_set_ssil_quality(RenderingServer.ENV_SSIL_QUALITY_MEDIUM, s.ssao < 3, 0.5, 4, 50.0, 300.0)
		# volumetric fog resolution
		var vf: Vector2i = [Vector2i(32, 32), Vector2i(40, 40), Vector2i(64, 64), Vector2i(128, 96)][clampi(s.vfog, 0, 3)]
		RenderingServer.environment_set_volumetric_fog_volume_size(vf.x, vf.y)
		RenderingServer.environment_set_volumetric_fog_filter_active(s.vfog >= 2)

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if s.vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = s.fps
	Engine.physics_ticks_per_second = physics_hz()
	apply_scene()
	changed.emit()

## Physics (and camera) rate: 60 Hz, or with `smooth` the display's refresh rate (the FPS cap if lower)
func physics_hz() -> int:
	if not s.get("smooth", false):
		return 60
	var hz := roundi(DisplayServer.screen_get_refresh_rate())
	if hz <= 0:
		hz = 60
	if int(s.fps) > 0:
		hz = mini(hz, int(s.fps))
	return clampi(hz, 60, SMOOTH_MAX_HZ)

func _apply_post() -> void:
	if post_mat == null:
		return
	post_mat.shader = _post_full if s.post >= 1 else _post_lite
	post_mat.set_shader_parameter("post_quality", s.post)

func _commit() -> void:
	apply()
	_save()

# ---- presets / persistence ---------------------------------------------------------------------
func _matching_preset() -> String:
	for n in ORDER:
		var same := true
		for k in PRESETS[n]:
			if PRESETS[n][k] != s.get(k):
				same = false
				break
		if same:
			return n
	return "custom"

func _auto_preset() -> String:
	if compat:
		return "low"
	match RenderingServer.get_video_adapter_type():
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU: return "low"
		RenderingDevice.DEVICE_TYPE_DISCRETE_GPU: return "high"
	return "medium"

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		set_preset_silent(_auto_preset())
		return
	preset = str(cf.get_value("gfx", "preset", _auto_preset()))
	s = PRESETS.get(preset, PRESETS["high"]).duplicate()
	for k in s:
		if cf.has_section_key("gfx", k):
			var v = cf.get_value("gfx", k)
			if typeof(v) == typeof(s[k]):
				s[k] = v
	fullscreen = bool(cf.get_value("gfx", "fullscreen", false))
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

func set_preset_silent(name: String) -> void:
	preset = name
	s = PRESETS[name].duplicate()
	_save()

func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("gfx", "preset", preset)
	cf.set_value("gfx", "fullscreen", fullscreen)
	for k in s:
		cf.set_value("gfx", k, s[k])
	cf.save(PATH)
