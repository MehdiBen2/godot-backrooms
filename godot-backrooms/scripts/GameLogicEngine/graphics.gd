extends Node
## Graphics settings (autoload: Gfx), render pipeline v3. Four presets plus per-option overrides, saved to
## user://graphics.cfg and applied at startup. The first launch picks a preset from the GPU (_auto_preset).
##
## What draws the picture, cheapest first, and what the presets turn up:
##   - the tube lights round you (level_light_pool.gd keeps a pool of them following you): `lights` lit at once,
##     the nearest `light_shadows` of them casting a shadow (a spot shadow: one shadow render each), and cheap
##     shadowless `far_lights` further out so distant halls still have their light; with `area_lights` (Medium and
##     up) the lit ones are AreaLight3D rectangles, so glossy things show a tube's glare as a bar, not a disc
##   - `bounce`: the level's bounce light (grid_gi.gd), solved on the CPU over the level's own grid and laid over
##     floors and walls as a light second pass. It is the only global illumination: VoxelGI, SDFGI and SSIL were
##     taken out. Their per-frame compute passes (VoxelGI re-lighting a 512 subdivision grid from every moving
##     light) were the common factor in the GPU resets (DXGI DEVICE_REMOVED / Vulkan device lost) on the RX 5700 XT
##   - `ssao`: contact shadow in corners and where the walls meet the floor
##   - `shadows`: the quality of those shadows (map size, softness; High is contact-hardening PCSS)
##   - `aa`: 0 off, 1 FXAA, 2 TAA (TAA also calms the carpet and ceiling grid shimmer)
##   - `glow` (bloom round the HDR tubes), `post` (the camera shader's tier), `scale` (3D render size, FSR below 100)
##   - `reflections`: how many room captures follow you (render/reflection_pool.gd: ReflectionProbes rendered once
##     each, raster only), what glass, steel and glazed tile reflect; 0 = the ambient only
## Also out for good: volumetric fog (a froxel compute pass fed by the GI; the depth fog and the horizon fog in
## level_lighting.gd carry the haze), screen-space reflections (carpet and wallpaper reflect nothing you can see)
## and MSAA (it does nothing for shader aliasing, which is all this game has; TAA does).
##
## Render buffers (shadow atlas, TAA history, AO buffers, the 3D render size) are reallocated whenever one of their
## settings is written, and that reallocation is what the AMD drivers handle worst. So apply() only ever writes a
## value that changed, and nothing changes them on its own mid-game (no adaptive resolution).

signal changed

const PATH := "user://graphics.cfg"
## Bumped when the settings model changes: a graphics.cfg from an older model is replaced by the auto preset
## (the screen / camera / carpet choices are kept). Rev 3: render pipeline v3 (see above).
const GFX_REV := 3
const ORDER := ["low", "medium", "high", "ultra"]
const SMOOTH_MAX_HZ := 165
## Physics at the display rate (`smooth`) on a PC that can't keep up runs several physics steps per drawn
## frame, which makes the frame slower still. Under this share of the physics rate for PHYS_WINDOW
## seconds, physics drops back to 60 Hz until the settings are applied again.
const PHYS_FALLBACK := 0.6
const PHYS_WINDOW := 2.0

## `aniso` is not in the menu: 16x filtering costs nothing you can measure on a dedicated card and is what keeps
## the carpet and the ceiling grid sharp down a long hall; only Low (built for integrated GPUs) keeps it at 4x.
const PRESETS := {
	"low": {"scale": 100, "aa": 1, "shadows": 0, "ssao": 0, "bounce": false, "glow": false, "post": 0, "aniso": 4,
		"vsync": false, "fps": 60, "lights": 6, "light_shadows": 0, "hidden_shadows": 0, "far_lights": 12, "smooth": true, "banding": false, "reflections": 0, "area_lights": false},
	"medium": {"scale": 100, "aa": 1, "shadows": 1, "ssao": 0, "bounce": false, "glow": false, "post": 0, "aniso": 16,
		"vsync": false, "fps": 0, "lights": 8, "light_shadows": 1, "hidden_shadows": 2, "far_lights": 24, "smooth": true, "banding": false, "reflections": 2, "area_lights": false},
	"high": {"scale": 100, "aa": 1, "shadows": 2, "ssao": 0, "bounce": false, "glow": false, "post": 0, "aniso": 16,
		"vsync": false, "fps": 0, "lights": 10, "light_shadows": 2, "hidden_shadows": 4, "far_lights": 40, "smooth": true, "banding": false, "reflections": 4, "area_lights": false},
	"ultra": {"scale": 100, "aa": 1, "shadows": 3, "ssao": 0, "bounce": false, "glow": false, "post": 0, "aniso": 16,
		"vsync": false, "fps": 0, "lights": 12, "light_shadows": 3, "hidden_shadows": 6, "far_lights": 56, "smooth": true, "banding": false, "reflections": 6, "area_lights": false},
}
## Per shadow tier (0 off .. 3 high): the positional shadow atlas, its filter, and whether the tubes are area
## lights (PCSS: sharp where a thing meets the floor, softer further out, like a real 60 cm diffuser)
const SHADOW_ATLAS := [2048, 2048, 4096, 4096]
const SHADOW_FILTER := [RenderingServer.SHADOW_QUALITY_HARD, RenderingServer.SHADOW_QUALITY_SOFT_LOW,
	RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, RenderingServer.SHADOW_QUALITY_SOFT_HIGH]
const SSAO_QUALITY := [RenderingServer.ENV_SSAO_QUALITY_VERY_LOW, RenderingServer.ENV_SSAO_QUALITY_LOW,
	RenderingServer.ENV_SSAO_QUALITY_MEDIUM, RenderingServer.ENV_SSAO_QUALITY_HIGH]

var s := {}                     # the active settings (same keys as a preset)
var preset := "high"            # a preset name, or "custom" once an option was changed by hand
var fullscreen := false
var compat := false             # OpenGL fallback renderer: no SSAO / bounce light
var post_mat: ShaderMaterial
## Not a quality setting (presets leave it alone): which camera films the game (render_engine.gd)
const CAMERAS := ["bodycam", "camcorder", "auto", "clean"]
var camera := "clean"
## Bumped when the default camera changes, so a saved old default doesn't override the new one
const CAMERA_REV := 2
const CAMERA_SHADER := "res://shaders/render/camera.gdshader"
## [full, lite]. Lite: the same shader without the mip-mapped screen copy (cheaper, Low preset).
var _post_shaders: Array = []
var _phys_acc := 0.0
var _phys_n := 0
var phys_capped := false        # physics fell back to 60 Hz (see PHYS_FALLBACK)
## The render-buffer settings as last written (see apply): a write only happens when the value differs
var _applied := {}
## Temporal AA (TAA, FSR 2) held off while something on screen changes without moving (the field terminal's
## glass, terminal_machine.gd): it rebuilds each frame from the frames before it along the motion vectors, and a
## picture that changes in place has none, so the old frames trail behind the cursor and the text. FXAA stands in.
var _no_temporal := 0

func hold_temporal(on: bool) -> void:
	_no_temporal = maxi(_no_temporal + (1 if on else -1), 0)
	_apply_aa()

## The anti-aliasing in effect: the setting, less temporal AA while it is held off
func _aa() -> int:
	var aa := int(s.get("aa", 1))
	if aa == 3 and compat: aa = 1               # (no FSR 2 on the compatibility renderer: FXAA)
	if aa >= 2 and _no_temporal > 0: aa = 1
	return aa

## Test runs in the background (`-- --bg`, or `-- --bg-offscreen` when the frames must be drawn: Godot draws nothing
## while every window is minimized): the Low preset, in memory only (graphics.cfg is left alone), a window that
## never takes the focus, and no pause when it has none (main.gd)
var background := ""

func _ready() -> void:
	compat = RenderingServer.get_current_rendering_method() == "gl_compatibility"
	for a in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if a == "--bg" or a == "--bg-offscreen":
			background = a.trim_prefix("--")
	_load()
	if background != "":
		fullscreen = false
		preset = "low"
		s = PRESETS["low"].duplicate()
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		if background == "bg":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_position(Vector2i(-20000, -20000))
	apply()
	_build_vhs()

func _process(dt: float) -> void:
	_log_hitch(dt)
	_guard_physics(dt)
	_update_vhs()

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
	f.store_line("%s  %.0f ms  preset=%s physhz=%d  online=%s host=%s peers=%d  level=%d floor=%d  pos=%s  active=%s  fps_cap=%d  vram_tex=%.0fMB" % [
		Time.get_datetime_string_from_system(), dt * 1000.0, preset, Engine.physics_ticks_per_second,
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

## Carpet look (not a quality preset, like the camera): soft = smoother, darker, cheaper than the original pile
var carpet_soft := false
var _carpet_mats: Array = []

## level_geometry.gd hands over each carpet material so the menu option reaches the ones already built
func register_carpet(mat: ShaderMaterial) -> void:
	_carpet_mats = _carpet_mats.filter(func(w: WeakRef): return w.get_ref() != null)
	_carpet_mats.append(weakref(mat))
	mat.set_shader_parameter("soft", 0.0)

func set_carpet_soft(on: bool) -> void:
	carpet_soft = false

var mood := false

func set_mood(on: bool) -> void:
	mood = false

var cctv := false

func set_cctv(on: bool) -> void:
	cctv = false

var vhs := false
const VHS_LAYER := 4
var _vhs_layer: CanvasLayer

func set_vhs(on: bool) -> void:
	vhs = false

func _build_vhs() -> void:
	_vhs_layer = CanvasLayer.new()
	_vhs_layer.layer = VHS_LAYER
	_vhs_layer.visible = false
	add_child(_vhs_layer)

## Only during a run: the title screen has its own VHS layer
func _update_vhs() -> void:
	if _vhs_layer != null and _vhs_layer.visible:
		_vhs_layer.visible = false

func set_camera(c: String) -> void:
	if c in CAMERAS and c != camera:
		camera = c
		_save()
		changed.emit()

## Crash bisecting: `-- --bisect-<name>` on the command line switches one suspect off (nopost, nocrt, noocc)
static func bisect(flag: String) -> bool:
	return OS.get_cmdline_user_args().has("--bisect-" + flag) or OS.get_cmdline_args().has("--bisect-" + flag)

## hud.gd hands over the post-process material so quality changes can reach it. The camera shader is built
## here once with its cheaper no-mipmap twin, so a quality change is just a swap.
func register_post(mat: ShaderMaterial) -> void:
	post_mat = mat
	if _post_shaders.is_empty():
		var sh := load(CAMERA_SHADER) as Shader
		if sh == null:
			push_error("graphics: %s did not load" % CAMERA_SHADER)
			return
		_post_shaders = _with_lite(sh)
	_apply_post()

static func _with_lite(sh: Shader) -> Array:
	var lite: Shader = sh.duplicate()
	lite.code = lite.code.replace("filter_linear_mipmap", "filter_linear")
	return [sh, lite]

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
		# an environment tuned by hand (the hills: "gfx_keep") keeps its own AO; nothing here ever turns the removed
		# compute effects on, and they are forced off in case an old scene or resource still has them
		if not e.has_meta("gfx_keep"):
			e.ssao_enabled = s.ssao > 0 and not compat
		e.ssil_enabled = false
		e.ssr_enabled = false
		e.sdfgi_enabled = false
		e.volumetric_fog_enabled = false
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
## Writes `value` through `setter` only when it differs from what was last written under `key`
func _put(key: String, value: Variant, setter: Callable) -> void:
	if _applied.has(key) and _applied[key] == value:
		return
	_applied[key] = value
	setter.call(value)

func apply() -> void:
	var vp := get_viewport()
	var shadows := clampi(int(s.get("shadows", 1)), 0, 3)
	var ssao := clampi(int(s.get("ssao", 1)), 0, 3)
	_apply_aa()
	_put("occlusion", not bisect("noocc"), func(v): vp.use_occlusion_culling = v)
	_put("msaa", Viewport.MSAA_DISABLED, func(v): vp.msaa_3d = v)
	_put("debanding", true, func(v): vp.use_debanding = v)
	_put("mesh_lod", [3.0, 2.0, 1.5, 1.0][shadows], func(v): vp.mesh_lod_threshold = v)
	var aniso: int = {2: Viewport.ANISOTROPY_2X, 4: Viewport.ANISOTROPY_4X, 8: Viewport.ANISOTROPY_8X,
		16: Viewport.ANISOTROPY_16X}.get(int(s.get("aniso", 16)), Viewport.ANISOTROPY_16X)
	_put("aniso", aniso, func(v): vp.anisotropic_filtering_level = v)
	_put("shadow_atlas", SHADOW_ATLAS[shadows], func(v): vp.positional_shadow_atlas_size = v)
	_put("shadow_filter", SHADOW_FILTER[shadows], _set_shadow_filter)
	if not compat:
		# ambient occlusion at half resolution on every preset: it is blurred anyway, and reads the same in a corner
		# (full resolution on Ultra was ~0.3 ms of GPU a frame for nothing you could see); the quality tier still differs
		_put("ssao_q", ssao, func(v): RenderingServer.environment_set_ssao_quality(SSAO_QUALITY[v], true, 0.5, 2, 50.0, 300.0))
	_put("vsync", DisplayServer.VSYNC_ENABLED if s.vsync else DisplayServer.VSYNC_DISABLED, func(v): DisplayServer.window_set_vsync_mode(v))
	Engine.max_fps = s.fps
	Engine.physics_ticks_per_second = physics_hz()
	phys_capped = false
	_phys_acc = 0.0
	_phys_n = 0
	apply_scene()
	changed.emit()

## Anti-aliasing and the 3D render size (FSR 2 is both)
func _apply_aa() -> void:
	var vp := get_viewport()
	var aa := _aa()
	var taa := aa == 2
	_render_scale()
	_put("taa", taa, func(v): vp.use_taa = v)
	_put("fxaa", Viewport.SCREEN_SPACE_AA_FXAA if aa == 1 else Viewport.SCREEN_SPACE_AA_DISABLED, func(v): vp.screen_space_aa = v)
	# slightly sharper mips keep the wallpaper and carpet readable down a long hall, but only TAA can afford them:
	# without it the sharper mips crawl and shimmer on the far ceiling grid
	# (FSR 2 sets its own, from the render scale)
	_put("mip_bias", -0.35 if taa else 0.0, func(v): vp.texture_mipmap_bias = v)

static func _set_shadow_filter(q: int) -> void:
	RenderingServer.positional_soft_shadow_filter_set_quality(q)
	RenderingServer.directional_soft_shadow_filter_set_quality(q)

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

## The 3D render size: the preset's `scale`. With anti-aliasing "FSR 2" (aa 3) the picture is rendered at that
## size and rebuilt to full size from the frames before it (FSR 2: an upscaler and a temporal AA in one, so it
## replaces TAA): Medium / High / Ultra shade a half to three quarters of the pixels and keep a sharp picture.
## Otherwise, under 100 it is upscaled with FSR 1 (cheap, and sharper than bilinear).
func _render_scale() -> void:
	var vp := get_viewport()
	var live := 1.0
	var mode := Viewport.SCALING_3D_MODE_BILINEAR
	_put("scale_mode", mode, func(v): vp.scaling_3d_mode = v)
	_put("scale", live, func(v): vp.scaling_3d_scale = v)
	_put("fsr_sharp", 0.0, func(v): vp.fsr_sharpness = v)

func _apply_post() -> void:
	if post_mat == null or _post_shaders.is_empty():
		return
	var want: Shader = _post_shaders[0] if s.post >= 1 else _post_shaders[1]
	if post_mat.shader != want:
		# carry every value already set (the lens dirt textures, the live effect levels) across the swap
		var keep := {}
		if post_mat.shader != null:
			for u in post_mat.shader.get_shader_uniform_list():
				var v = post_mat.get_shader_parameter(u.name)
				if v != null:
					keep[u.name] = v
		post_mat.shader = want
		for k in keep:
			post_mat.set_shader_parameter(k, keep[k])
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

## First launch (or a graphics.cfg from an older settings model): integrated, software or virtual GPUs get Low,
## any dedicated card High. Nothing left in the pipeline needs a top-end card; Ultra is the player's choice.
func _auto_preset() -> String:
	return "low" if _weak_gpu() else "high"

## No dedicated graphics card: the OpenGL fallback, an integrated GPU (Intel UHD / Iris, AMD Vega in a Ryzen), a
## virtual machine or a software renderer.
func _weak_gpu() -> bool:
	if compat:
		return true
	match RenderingServer.get_video_adapter_type():
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU, RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU, RenderingDevice.DEVICE_TYPE_CPU:
			return true
	return false

## First launch on a weak GPU: Low is not enough by itself, since an integrated GPU shares system memory and its
## cost grows with the number of pixels. Fewer lit tubes, and a render size that follows the screen (a 1440p / 4K
## display would otherwise be 3-4x the pixels of a 1080p one at the same 70%).
func _tune_for_weak_gpu() -> void:
	if not _weak_gpu():
		return
	var size := DisplayServer.screen_get_size()
	var pixels := size.x * size.y
	if pixels > 3500000:
		s["scale"] = 50
	elif pixels > 2200000:
		s["scale"] = 60
	elif pixels < 1300000:
		s["scale"] = 85               # (1366x768 laptops: already few pixels, and FSR on top of them is mush)
	s["lights"] = 4
	s["far_lights"] = 10
	preset = _matching_preset()
	_save()

func _load() -> void:
	var cf := ConfigFile.new()
	var loaded := cf.load(PATH) == OK
	fullscreen = false
	carpet_soft = false
	mood = false
	cctv = false
	vhs = false
	camera = "clean"
	if loaded:
		fullscreen = bool(cf.get_value("gfx", "fullscreen", false))
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	preset = "high"
	s = PRESETS["high"].duplicate()
	s["scale"] = 100
	s["post"] = 0
	s["glow"] = false
	s["bounce"] = false
	s["banding"] = false

func set_preset_silent(name: String) -> void:
	preset = name
	s = PRESETS[name].duplicate()
	_save()

func _save() -> void:
	if background != "":
		return
	var cf := ConfigFile.new()
	cf.set_value("gfx", "rev", GFX_REV)
	cf.set_value("gfx", "preset", preset)
	cf.set_value("gfx", "fullscreen", fullscreen)
	cf.set_value("gfx", "camera", camera)
	cf.set_value("gfx", "camera_rev", CAMERA_REV)
	cf.set_value("gfx", "carpet_soft", carpet_soft)
	cf.set_value("gfx", "mood", mood)
	cf.set_value("gfx", "cctv", cctv)
	cf.set_value("gfx", "vhs", vhs)
	for k in s:
		cf.set_value("gfx", k, s[k])
	cf.save(PATH)
