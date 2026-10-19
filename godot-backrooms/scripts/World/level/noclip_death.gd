extends Node3D
## NOCLIP DEATH / VOID FALL (level_data.gd `noclip_death`):
## A pain area / hazard zone painted on floor or pits, or placed as an event trigger.
## When the player steps on or falls through it:
##   1. The floor gives way / destabilizes, slipping the player straight through reality.
##   2. The player plunges into the bottomless void beneath the Backrooms.
##   3. They keep falling through the void with howling rushing wind, abyssal hums, and a terror scream.
##   4. Reality corrupts, the screen fades to black, and the player dies: "FALLING INTO THE VOID".

const FALL_SCREAM_PATH := "res://audio/player/death/fall/fall_scream.mp3"
const HUM_PATH := "res://audio/world/lights/hum_diffuse.wav"
const DRONE_PATH := "res://audio/ambients/drone.wav"

const STAND := 0.20           # s standing on floor before the floor gives under you
const SINK := 0.35            # feet sinking into the surface
const DROP := 0.45            # dropping through the floor into the void
const VOID_FALL_SECS := 4.4   # total seconds falling in the void before death
const FADE_OUT := 1.4         # fade to black duration at the end of the fall
const SPEED_MAX := 60.0       # terminal falling speed (m/s)

var level: Node3D
var _on := 0.0
var _t := -1.0
var _y0 := 0.0
var _eye := 1.6

var _falling := false
var _fall_t := 0.0
var _fade := 0.0
var _scream_played := false
var _level_hidden := false
var _hidden: Array = []
var _saved := {}

var _wind: AudioStreamPlayer
var _hum: AudioStreamPlayer
var _drone: AudioStreamPlayer
var _scream: AudioStreamPlayer
var _dome: MeshInstance3D
var _gust := FastNoiseLite.new()

static var _wind_stream: AudioStreamWAV

func setup(l: Node3D) -> void:
	level = l
	process_physics_priority = 100
	_gust.frequency = 0.35

static func trigger_void_fall(p: CharacterBody3D, lvl: Node3D) -> void:
	if lvl == null or p == null or not is_instance_valid(p) or p.dead or Game.dead:
		return
	var nd: Node = lvl.get_node_or_null("NoclipDeath")
	if nd == null or not is_instance_valid(nd):
		var noclip_death_script = load("res://scripts/World/level/noclip_death.gd")
		if noclip_death_script != null:
			nd = noclip_death_script.new()
			nd.name = "NoclipDeath"
			lvl.add_child(nd)
			nd.setup(lvl)
	if nd != null and nd.has_method("start_void_fall_direct"):
		nd.start_void_fall_direct(p)

func start_void_fall_direct(p: CharacterBody3D) -> void:
	if _falling or Game.dead or Death.respawn_busy:
		return
	_start_freefall(p)

func _physics_process(dt: float) -> void:
	if level == null:
		return
	var p = level.player as CharacterBody3D
	if p == null or not is_instance_valid(p) or p.dead:
		if _falling:
			_end(p, false)
		return

	if _falling:
		_process_void_fall(dt, p)
		return

	if _t >= 0.0:
		_process_slip(dt, p)
		return

	if _t < -1.5:
		return
	if Game.noclip or Game.draw_mode or Game.dead or Game.freefall or Death.respawn_busy:
		return

	var cell: Vector2i = level.cell_of(p.global_position)
	if level.get("noclip_death") != null and (level.noclip_death as Dictionary).has(cell):
		if p.is_on_floor():
			_on += dt
			if _on >= STAND:
				_start_slip(p)
		elif p.global_position.y < -0.4:
			# Player stepped or fell into an open pit/hole with noclip death
			_start_freefall(p)
		else:
			_on += dt * 0.5
			if _on >= STAND:
				_start_slip(p)
	else:
		_on = 0.0

func _start_slip(p: CharacterBody3D) -> void:
	_t = 0.0
	_on = 0.0
	_y0 = p.global_position.y
	var cam: Camera3D = p.cam
	_eye = maxf(0.6, cam.global_position.y - _y0) if cam != null else 1.6
	p.frozen = true
	p.velocity = Vector3.ZERO
	Game.fx_shock = 0.45
	Game.fx_corrupt = maxf(Game.fx_corrupt, 0.3)

func _process_slip(dt: float, p: CharacterBody3D) -> void:
	_t += dt
	p.frozen = true
	p.velocity = Vector3.ZERO
	var depth := 0.0
	if _t < SINK:
		var k: float = _t / SINK
		depth = 0.32 * k * k
	elif _t < SINK + DROP:
		var k: float = (_t - SINK) / DROP
		depth = 0.32 + (_eye + 0.4) * k * k
		if k > 0.25:
			Game.fx_corrupt = maxf(Game.fx_corrupt, 0.35 + 0.3 * randf())
	else:
		p.global_position.y = _y0 - (0.32 + _eye + 0.4)
		_start_freefall(p)
		return

	p.global_position.y = _y0 - depth
	if Gfx.post_mat:
		Gfx.post_mat.set_shader_parameter("fall_fade", smoothstep(_eye - 0.6, _eye - 0.1, depth) * 0.4)

func _start_freefall(p: CharacterBody3D) -> void:
	_t = -1.0
	_falling = true
	_fall_t = 0.0
	_fade = 0.0
	_scream_played = false
	Game.freefall = true

	# Save player parameters
	_saved = {
		"far": p.cam.far if p.cam != null else 90.0,
		"fov": p.cam.fov if p.cam != null else 75.0,
		"speed": p.fall_speed_max,
		"shadow": p.flash.shadow_enabled if p.flash != null else true,
		"shape_disabled": p.shape.disabled if p.shape != null else false
	}

	# Let the player look around and fall into the void
	p.frozen = false
	p.fall_speed_max = SPEED_MAX
	p.velocity.x = 0.0
	p.velocity.z = 0.0
	p.velocity.y = -6.0
	if p.shape != null:
		p.shape.disabled = true
	if p.flash != null:
		p.flash.shadow_enabled = false

	# Environment void settings
	var env: Environment = level.env
	if env != null:
		_saved["env"] = {
			"vfog": env.volumetric_fog_enabled,
			"ssao": env.ssao_enabled,
			"ssil": env.ssil_enabled,
			"ssr": env.ssr_enabled,
			"fog": env.fog_density,
			"fog_color": env.fog_light_color,
			"bg": env.background_color,
			"mode": env.background_mode
		}
		env.volumetric_fog_enabled = false
		env.ssao_enabled = false
		env.ssil_enabled = false
		env.ssr_enabled = false
		env.background_mode = Environment.BG_COLOR
		var void_col := Color(0.008, 0.006, 0.012)
		env.background_color = void_col
		env.fog_density = 0.06
		env.fog_light_color = void_col

	# Void dome: pure infinite void wrapping the camera
	_dome = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 1.0
	sph.height = 2.0
	sph.radial_segments = 24
	sph.rings = 12
	_dome.mesh = sph
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.cull_mode = BaseMaterial3D.CULL_FRONT
	dm.albedo_color = Color(0.006, 0.004, 0.009)
	_dome.material_override = dm
	_dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dome.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_dome.extra_cull_margin = 16384.0
	add_child(_dome)

	# Sound effects
	var bus := "Ambience" if AudioServer.get_bus_index("Ambience") >= 0 else "Master"
	if _wind_stream == null:
		_wind_stream = _make_wind()
	_wind = AudioStreamPlayer.new()
	_wind.stream = _wind_stream
	_wind.bus = bus
	_wind.volume_db = -35.0
	add_child(_wind)
	_wind.play()

	_hum = AudioStreamPlayer.new()
	if ResourceLoader.exists(HUM_PATH):
		_hum.stream = load(HUM_PATH)
	_hum.bus = bus
	_hum.volume_db = -30.0
	_hum.pitch_scale = 0.55
	add_child(_hum)
	_hum.play()

	if ResourceLoader.exists(DRONE_PATH):
		_drone = AudioStreamPlayer.new()
		_drone.stream = load(DRONE_PATH)
		_drone.bus = bus
		_drone.volume_db = -24.0
		_drone.pitch_scale = 0.7
		add_child(_drone)
		_drone.play()

func _process_void_fall(dt: float, p: CharacterBody3D) -> void:
	_fall_t += dt

	# Gravity acceleration down into the void
	p.velocity.y = maxf(p.velocity.y - 30.0 * dt, -SPEED_MAX)
	p.global_position.y += p.velocity.y * dt

	# Dome follows camera
	if _dome != null and p.cam != null:
		_dome.global_position = p.cam.global_position
		_dome.scale = Vector3.ONE * maxf(p.cam.far * 0.92, 10.0)

	# Once fallen past the floor slab, hide the level above
	if p.global_position.y < -10.0 and not _level_hidden:
		_hide_level(true)

	# Fall speed calculations
	var speed_ratio := clampf(absf(p.velocity.y) / SPEED_MAX, 0.0, 1.0)
	var noise_flutter := _gust.get_noise_1d(_fall_t * 9.0)

	# Rushing wind sound effect
	if _wind != null and is_instance_valid(_wind):
		var wind_vol := speed_ratio * (0.8 + 0.2 * noise_flutter) * (1.0 - _fade)
		_wind.volume_db = linear_to_db(clampf(wind_vol, 0.0001, 1.2))
		_wind.pitch_scale = clampf(0.75 + 0.6 * speed_ratio, 0.6, 1.4)

	# Deep void hum
	if _hum != null and is_instance_valid(_hum):
		_hum.volume_db = linear_to_db(clampf(0.85 * (1.0 - _fade), 0.0001, 1.0))

	# Player terror scream after falling into the void
	if _fall_t >= 0.85 and not _scream_played:
		_scream_played = true
		_play_scream()

	# High-speed camera rush & jitter
	if p.cam != null:
		var base_fov: float = float(_saved.get("fov", 75.0))
		p.cam.fov = lerpf(base_fov, base_fov + 10.0, speed_ratio)
		var shake := speed_ratio * 0.018 * (1.0 - _fade)
		p.cam.h_offset = randf_range(-shake, shake)
		p.cam.v_offset = randf_range(-shake, shake)

	# VHS tape corruption & glitch from falling out of bounds
	Game.fx_corrupt = maxf(Game.fx_corrupt, 0.15 + 0.35 * speed_ratio * (0.5 + 0.5 * randf()))
	if randf() < dt * 4.0:
		Game.glitch = maxf(Game.glitch, 0.4)

	# Fade to black over FADE_OUT seconds
	if _fall_t >= VOID_FALL_SECS - FADE_OUT:
		_fade = minf(1.0, _fade + dt / FADE_OUT)
		if Gfx.post_mat:
			Gfx.post_mat.set_shader_parameter("fall_fade", _fade)

	# Fatal void death
	if _fade >= 1.0 or _fall_t >= VOID_FALL_SECS:
		_die(p)

func _play_scream() -> void:
	var sc: Node = level.get_parent().get_node_or_null("Scares") if level.get_parent() != null else null
	if sc != null and sc.has_method("fall_scream"):
		_scream = sc.fall_scream()
	elif ResourceLoader.exists(FALL_SCREAM_PATH):
		_scream = AudioStreamPlayer.new()
		_scream.stream = load(FALL_SCREAM_PATH)
		_scream.bus = "Voice" if AudioServer.get_bus_index("Voice") >= 0 else "Master"
		_scream.volume_db = 2.0
		add_child(_scream)
		_scream.play()

func _die(p: CharacterBody3D) -> void:
	_end(p, true)

func _end(p: CharacterBody3D, kill := false) -> void:
	_falling = false
	_t = -2.0
	Game.freefall = false

	# Restore environment
	var env: Environment = level.env if level != null else null
	if env != null and _saved.has("env"):
		var e: Dictionary = _saved.env
		env.volumetric_fog_enabled = e.vfog
		env.ssao_enabled = e.ssao
		env.ssil_enabled = e.ssil
		env.ssr_enabled = e.ssr
		env.fog_density = e.fog
		env.fog_light_color = e.fog_color
		env.background_color = e.bg
		env.background_mode = e.mode

	# Restore player
	if p != null and is_instance_valid(p):
		if p.cam != null:
			p.cam.far = _saved.get("far", p.cam.far)
			p.cam.fov = _saved.get("fov", p.cam.fov)
			p.cam.h_offset = 0.0
			p.cam.v_offset = 0.0
		p.fall_speed_max = _saved.get("speed", p.FALL_SPEED_MAX)
		if p.flash != null:
			p.flash.shadow_enabled = _saved.get("shadow", true)
		if p.shape != null:
			p.shape.disabled = _saved.get("shape_disabled", false)

	_hide_level(false)

	# Clean up dome & audio
	if _dome != null:
		_dome.queue_free()
		_dome = null
	for a: AudioStreamPlayer in [_wind, _hum, _drone]:
		if a != null and is_instance_valid(a):
			a.queue_free()
	_wind = null
	_hum = null
	_drone = null

	if kill:
		Game.kill_player("FALLING INTO THE VOID", Game.DeathType.NONE)
	else:
		if Gfx.post_mat:
			Gfx.post_mat.set_shader_parameter("fall_fade", 0.0)

func _hide_level(hide: bool) -> void:
	if hide == _level_hidden:
		return
	_level_hidden = hide
	if level == null:
		return
	if hide:
		_hidden.clear()
		for c in level.get_children():
			if c == self or not (c is Node3D) or not (c as Node3D).visible:
				continue
			(c as Node3D).visible = false
			_hidden.append(c)
	else:
		for c in _hidden:
			if is_instance_valid(c):
				(c as Node3D).visible = true
		_hidden.clear()

func _exit_tree() -> void:
	if _falling:
		var p = level.player as CharacterBody3D if level != null else null
		_end(p, false)
	if Gfx.post_mat:
		Gfx.post_mat.set_shader_parameter("fall_fade", 0.0)

static func _make_wind() -> AudioStreamWAV:
	var rate := 22050
	var secs := 2.5
	var n := int(rate * secs)
	var fade := int(rate * 0.2)
	var r := RandomNumberGenerator.new()
	r.seed = 1971
	var s := PackedFloat32Array()
	s.resize(n + fade)
	var a := 0.0
	var b := 0.0
	var peak := 0.0
	for i in n + fade:
		a += (r.randf() * 2.0 - 1.0 - a) * 0.09
		b += (a - b) * 0.2
		s[i] = b
	for i in fade:
		var t := float(i) / fade
		s[i] = s[i] * t + s[n + i] * (1.0 - t)
	for i in n:
		peak = maxf(peak, absf(s[i]))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		data.encode_s16(i * 2, int(clampf(s[i] / maxf(peak, 0.0001), -1.0, 1.0) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w
