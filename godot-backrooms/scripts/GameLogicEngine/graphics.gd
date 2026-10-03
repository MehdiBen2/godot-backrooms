extends Node
## Graphics settings (autoload: Gfx). Four presets plus per-option overrides, saved to
## user://graphics.cfg and applied at startup. The first launch picks a preset from the GPU:
## integrated / unknown -> Low or Medium, discrete -> High. Ultra adds the extras (4x MSAA,
## global illumination, full-size AO, high-res volumetric fog, 8K shadows, 16x filtering).
##
## The biggest costs in this game are the tube lights around you (level_light_pool.gd keeps a pool of
## them following you) and their shadows: `lights` is how many are lit at once and `light_shadows` how
## many of the nearest cast shadows (each one is a cube shadow: six shadow renders a frame). `far_lights` are cheap
## shadowless lights on the tubes further out, so distant tubes still light their walls. `smooth` runs the physics
## (and so the camera) at the display's refresh rate instead of 60 Hz, so a 144 Hz screen moves at 144.
## `scale` is only the ceiling: `adapt` lets the game drop the internal render size below it whenever
## frames miss the target and put it back when the GPU has headroom, which is what keeps a weak PC
## playable without the player picking a preset.

signal changed

const PATH := "user://graphics.cfg"
const ORDER := ["low", "medium", "high", "ultra"]
const SMOOTH_MAX_HZ := 165
## Adaptive resolution: how far below the preset's render scale it may drop, and the frame-time
## slack on each side of the target so the scale settles instead of hunting.
const ADAPT_FLOOR := 0.72       # lower than this and FSR turns the far end of a hall to mush
const ADAPT_SLOW := 1.25
const ADAPT_FAST := 1.06
const ADAPT_DOWN := 0.1          # each change reallocates every screen buffer (~130 ms hitch): few, big steps
const ADAPT_UP := 0.1
const ADAPT_WINDOW := 0.5
const ADAPT_MAX_HZ := 120
## Every change of the render scale frees and rebuilds every render buffer (AO, GI, fog, TAA history,
## MSAA): it used to happen up to twice a second while the frame rate hovered near the target, which is
## a lot of video memory churn for a driver to take (and a hitch each time). Now it waits this long
## between changes, and longer before going back up than down.
const ADAPT_COOLDOWN := 8.0
const ADAPT_UP_WAIT := 40.0      # headroom has to last this long before the picture is sharpened again
## Physics at the display rate (`smooth`) on a PC that can't keep up runs several physics steps per drawn
## frame, which makes the frame slower still. Under this share of the physics rate for PHYS_WINDOW
## seconds, physics drops back to 60 Hz until the settings are applied again.
const PHYS_FALLBACK := 0.6
const PHYS_WINDOW := 2.0

# `scale` is the ceiling; `adapt` lets adaptive resolution drop below it.
const PRESETS := {
	"low": {"scale": 60, "msaa": 0, "fxaa": false, "taa": false, "shadows": 0, "ssao": 0, "ssr": false, "ssil": false,
		"glow": false, "vfog": 0, "post": 0, "aniso": 0, "vsync": true, "fps": 60,
		"lights": 6, "light_shadows": 0, "far_lights": 8, "baked_gi": false, "smooth": false, "adapt": true},
	"medium": {"scale": 80, "msaa": 0, "fxaa": true, "taa": false, "shadows": 1, "ssao": 1, "ssr": false, "ssil": false,
		"glow": true, "vfog": 1, "post": 1, "aniso": 4, "vsync": true, "fps": 0,
		"lights": 8, "light_shadows": 2, "far_lights": 16, "baked_gi": false, "smooth": false, "adapt": true},
	"high": {"scale": 100, "msaa": 0, "fxaa": true, "taa": true, "shadows": 2, "ssao": 2, "ssr": true, "ssil": false,
		"glow": true, "vfog": 2, "post": 2, "aniso": 8, "vsync": true, "fps": 0,
		"lights": 12, "light_shadows": 4, "far_lights": 24, "baked_gi": true, "smooth": true, "adapt": true},
	"ultra": {"scale": 100, "msaa": 4, "fxaa": true, "taa": true, "shadows": 3, "ssao": 3, "ssr": true, "ssil": true,
		"glow": true, "vfog": 3, "post": 2, "aniso": 16, "vsync": true, "fps": 0,
		"lights": 12, "light_shadows": 8, "far_lights": 32, "baked_gi": true, "smooth": true, "adapt": true},
}

var s := {}                     # the active settings (same keys as a preset)
var preset := "high"            # a preset name, or "custom" once an option was changed by hand
var fullscreen := false
var compat := false             # OpenGL fallback renderer: no SSAO / SSR / volumetric fog / GI
var post_mat: ShaderMaterial
var _post_full: Shader
var _post_lite: Shader          # same shader without the mip-mapped screen copy (cheaper)
## Adaptive resolution: the live fraction of the preset scale (1.0 = no reduction), plus the
## frame-time sampler that moves it. Only ever drops below the preset, never above.
var adapt_ratio := 1.0
var _ft_acc := 0.0
var _ft_n := 0
var _adapt_wait := 0.0
var _phys_acc := 0.0
var _phys_n := 0
var phys_capped := false        # physics fell back to 60 Hz (see PHYS_FALLBACK)

func _ready() -> void:
	compat = RenderingServer.get_current_rendering_method() == "gl_compatibility"
	_load()
	apply()

## Ratchets the render scale down when frames miss the target and back up while there is headroom.
## `dt` is the real frame interval, so a GPU- or vsync-bound frame shows up here as a longer dt.
func _process(dt: float) -> void:
	_log_hitch(dt)
	_guard_physics(dt)
	if not bool(s.get("adapt", false)) or compat or float(s.get("scale", 100)) <= 0.0:
		return
	_adapt_wait -= dt
	_ft_acc += dt
	_ft_n += 1
	if _ft_n < 12 or _ft_acc < ADAPT_WINDOW:
		return
	var avg := _ft_acc / _ft_n
	_ft_acc = 0.0
	_ft_n = 0
	if _adapt_wait > 0.0 or avg > 0.2:
		return                                   # (a freeze or load is not a reason to blur the picture)
	var target := 1.0 / float(target_fps())
	if avg > target * ADAPT_SLOW and adapt_ratio > ADAPT_FLOOR:
		adapt_ratio = maxf(ADAPT_FLOOR, adapt_ratio - ADAPT_DOWN)
		_render_scale()
		_adapt_wait = ADAPT_COOLDOWN
	elif avg < target * ADAPT_FAST and adapt_ratio < 1.0:
		adapt_ratio = minf(1.0, adapt_ratio + ADAPT_UP)
		_render_scale()
		_adapt_wait = ADAPT_UP_WAIT

## Every frame longer than HITCH_LOG seconds is appended to user://hitches.log with what the game was
## doing, so a random freeze can be traced afterwards. (The frame time is the freeze's length.)
const HITCH_LOG := 0.12
var _hitch_count := 0

func _log_hitch(dt: float) -> void:
	if dt < HITCH_LOG or _hitch_count >= 200:
		return
	_hitch_count += 1
	var f := FileAccess.open("user://hitches.log", FileAccess.READ_WRITE if FileAccess.file_exists("user://hitches.log") else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	var p: Node = Game.player
	var main: Node = Game.main if Game.main != null and is_instance_valid(Game.main) else null
	var ents := []
	if main != null:
		for nm in ["Entity", "Mannequin", "Mimic", "Grabber", "Eyes"]:
			var e: Node = main.get_node_or_null(nm)
			if e != null and e.is_visible_in_tree():
				ents.append(nm)
	# CPU split: if process + physics are a few ms while the frame was 140, the stall is the GPU / driver
	f.store_string("cpu_process=%.1fms cpu_physics=%.1fms draws=%d objs=%d  " % [
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)), int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))])
	f.store_line("%s  %.0f ms  preset=%s scale=%.2f physhz=%d  online=%s host=%s peers=%d  level=%d floor=%d  pos=%s  active=%s  fps_cap=%d  vram_tex=%.0fMB" % [
		Time.get_datetime_string_from_system(), dt * 1000.0, preset, adapt_ratio, Engine.physics_ticks_per_second,
		Net.is_online(), Net.hosting, Net.remotes.size(), Game.level_index, Game.level_floor,
		p.global_position if p != null and is_instance_valid(p) else Vector3.ZERO, ents, int(s.get("fps", 0)),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0])
	f.close()

func _guard_physics(dt: float) -> void:
	if phys_capped or Engine.physics_ticks_per_second <= 60 or dt > 0.25:
		return                          # (a single long frame is a load or a hitch, not a slow PC)
	_phys_acc += dt
	_phys_n += 1
	if _phys_acc < PHYS_WINDOW:
		return
	var fps := _phys_n / _phys_acc
	_phys_acc = 0.0
	_phys_n = 0
	if fps < Engine.physics_ticks_per_second * PHYS_FALLBACK:
		phys_capped = true
		Engine.physics_ticks_per_second = 60
		print("graphics: %d fps can't keep physics at the display rate: back to 60 Hz" % roundi(fps))

## The frame rate adaptive resolution aims at: the FPS cap if set, else the screen's refresh rate up to
## ADAPT_MAX_HZ. Chasing a 200 Hz screen would pin the render scale at ADAPT_FLOOR for good (a blurry
## picture for frames nobody notices); past 120 the game would rather stay sharp.
func target_fps() -> int:
	var capped := int(s.get("fps", 0))
	if capped > 0:
		return capped
	var hz := roundi(DisplayServer.screen_get_refresh_rate())
	return mini(int(hz), ADAPT_MAX_HZ) if hz > 0 else 60

# ---- public API ------------------------------------------------------------------------
func set_preset(name: String) -> void:
	if not PRESETS.has(name):
		return
	preset = name
	s = PRESETS[name].duplicate()
	adapt_ratio = 1.0
	_commit()

func set_value(key: String, value: Variant) -> void:
	if s.get(key) == value:
		return
	s[key] = value
	if key in ["scale", "adapt", "fps"]:
		adapt_ratio = 1.0
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
		e.glow_enabled = s.glow
		# an environment tuned by hand (the hills: "gfx_keep") keeps its own AO / GI / reflections / fog
		if not e.has_meta("gfx_keep"):
			e.ssao_enabled = s.ssao > 0 and not compat
			e.ssil_enabled = s.ssil and not compat
			e.ssr_enabled = s.ssr and not compat
			e.volumetric_fog_enabled = s.vfog > 0 and not compat
	# only lights that cast shadows in the scene file / level builder are switched; the rest stay off.
	# The tube-light pool manages its own (level_light_pool.gd reads `lights` / `light_shadows`).
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
	_render_scale()
	vp.use_occlusion_culling = true
	vp.use_taa = bool(s.get("taa", false)) and not compat
	vp.use_debanding = true
	vp.mesh_lod_threshold = [4.0, 3.0, 1.5, 1.0][clampi(s.shadows, 0, 3)]     # coarser meshes sooner on low presets
	vp.msaa_3d = {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X}.get(s.msaa, Viewport.MSAA_DISABLED)
	# FXAA blurs the whole frame (distant texture detail first); with MSAA or TAA on the edges are already clean
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if (s.fxaa and s.msaa == 0 and not vp.use_taa) else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.texture_mipmap_bias = -0.35        # slightly sharper mips: wallpaper and carpet stay readable down a long hall
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
	phys_capped = false
	_phys_acc = 0.0
	_phys_n = 0
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

## The live 3D scale: the preset's `scale` (the ceiling) times whatever adaptive resolution settled on.
## FSR needs a scale under 1.0, so the mode follows the live value, not the preset one.
func _render_scale() -> void:
	var vp := get_viewport()
	var live := clampf(float(s.get("scale", 100)) / 100.0, 0.5, 1.0)
	if bool(s.get("adapt", false)) and not compat:
		live *= adapt_ratio
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if (live < 1.0 and not compat) else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = clampf(live, 0.5, 1.0)
	vp.fsr_sharpness = 0.1                # 0 = sharpest: FSR's own sharpening puts back what the upscale softens

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
