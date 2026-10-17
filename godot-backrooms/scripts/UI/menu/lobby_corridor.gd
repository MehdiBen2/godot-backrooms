extends Node3D
## The lobby screen's backdrop (lobby_screen.gd): a short stretch of Level 0 corridor on a world of its own
## (the screen's SubViewport), the troffers humming and failing overhead, and the survivors in the lobby
## standing under them in their suits (models/player/survivor.glb, the same rig and clips as a teammate in
## the run, remote_player.gd).
##
## The places adapt to the lobby: place 0 is you, lit from the start. Each survivor who joins takes the next
## free place: the tube over it strikes (a stutter, then the light), and they walk up out of the dark into
## its pool. One who leaves turns and walks back into the dark, and their tube goes out behind them. The
## other tubes fail now and then like the level's (level_fixtures.gd: long steady stretches, then a burst),
## and the ones further down the hall are dead or dying.
##
## The camera: from_menu() picks up the title screen's push-in and carries on forward down the hall, easing
## to rest on the group; it then drifts like a camcorder held still. push_in() goes on past them into the
## dark (BEGIN), pull_back() backs away (BACK).

const SurvivorAnim := preload("res://scripts/Entities/survivor_anim.gd")
const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const CarpetShader := preload("res://shaders/carpet_pom.gdshader")
const CeilingShader := preload("res://shaders/acoustic_ceiling.gdshader")
const SkirtMaterial := preload("res://scripts/World/level/skirt_material.gd")
## level_trim.gd SKIRT: the cove base's cross-section, top edge at the wall down to the toe on the carpet
## (x out from the wall, y up; metres)
const SKIRT := [Vector2(0.0, 0.102), Vector2(0.0015, 0.1019), Vector2(0.0033, 0.1011), Vector2(0.0047, 0.0997),
	Vector2(0.0054, 0.0978), Vector2(0.0056, 0.0955), Vector2(0.0052, 0.0935), Vector2(0.0046, 0.0918),
	Vector2(0.0050, 0.0902), Vector2(0.0062, 0.0890), Vector2(0.0080, 0.0882), Vector2(0.0098, 0.0872),
	Vector2(0.0108, 0.0850), Vector2(0.0112, 0.0820), Vector2(0.0112, 0.022), Vector2(0.0116, 0.0135),
	Vector2(0.0124, 0.0075), Vector2(0.0134, 0.0030), Vector2(0.0146, 0.0)]

const CELL := 4.5                       # level_data.gd CELL / WALL_H: the level's own scale
const WALL_H := 5.4
const WALL_T := 0.3
const MODEL_HEIGHT := 2.0               # remote_player.gd: visor level with the 1.7 m camera
## Open cells (x, z) of the stretch: the hall runs down -Z; on its right near the camera it opens into a room
## where the survivors stand, and further down there are two dark side bays
const CELLS := [
	Vector2i(0, 2), Vector2i(0, 1), Vector2i(0, 0), Vector2i(0, -1), Vector2i(0, -2), Vector2i(0, -3),
	Vector2i(0, -4), Vector2i(0, -5), Vector2i(0, -6), Vector2i(0, -7), Vector2i(0, -8), Vector2i(0, -9),
	Vector2i(1, 1), Vector2i(1, 0), Vector2i(1, -1), Vector2i(-1, -3), Vector2i(1, -4),
]
## Where each survivor stands (feet, x / z): place 0 is you, out in front; the others fill in behind in a loose
## group, so a full lobby still reads as five people. Each faces the camera, turned off it by FACING (rad).
const PLACES := [
	Vector3(1.25, 0.0, -1.0), Vector3(3.3, 0.0, -2.0), Vector3(-0.1, 0.0, -2.9),
	Vector3(1.2, 0.0, -5.6), Vector3(5.2, 0.0, -3.4),
]
const FACING := [0.12, -0.3, 0.35, -0.1, -0.45]
## How a survivor stands while they wait (survivor_anim.gd's lobby_idle_* clips: each takes one nobody else in the
## lobby has) and the colour of the suit at each place (SurvivorAnim.apply_suit_variant; "" = the yellow it comes in):
## so no two of them stand or look alike
const IDLES := ["lobby_idle_shift", "lobby_idle_hips", "lobby_idle_hood", "lobby_idle_slump", "lobby_idle_glance",
	"lobby_idle_crossed", "lobby_idle_wrist", "lobby_idle_lookup", "lobby_idle_straps"]
const SUITS := ["", "blue", "orange", "green", "red"]
## The tubes down the hall that belong to no one: [x, z, state] (on / flicker: failing most of the time /
## dying: dim and unsteady / dead)
const HALL_TUBES := [
	[0.0, 4.5, "on"], [0.0, -10.5, "flicker"], [0.0, -15.0, "dead"], [0.0, -19.5, "dying"],
	[0.0, -25.0, "dead"], [CELL, 3.0, "dead"], [CELL + 1.5, -5.5, "dying"], [-CELL, -13.5, "dying"],
	[CELL, -18.0, "dead"],
]
const WALK_FROM := -13.0                # z a newcomer walks up from (in the dark past the last lit tube)
const WALK_SPEED := 1.6
const LIGHT_ENERGY := 3.4               # level_fixtures.gd LIGHT_ENERGY x SPOT_GAIN, a little up: nothing else lights the hall
const LIT_DIFFUSER := Color(3.2, 3.0, 2.55)
const TUBE_COLOR := Color(1.0, 0.95, 0.8)
const TROFFER_TOP_Y := 0.1432132        # level_fixtures.gd TOP_Y: the model's housing top
const STRIKE_TIME := 0.9                # s a tube stutters before it holds
## The camera's rest: on the left of the hall, looking down it, with the room and the group in the right half
## of the picture and the hall running off into the dark behind the lobby's panel
const CAM_REST_POS := Vector3(-1.2, 1.6, 5.0)
const CAM_REST_LOOK := Vector3(0.2, 1.25, -6.0)
const CAM_FROM_POS := Vector3(-0.3, 1.75, 10.6)    # from_menu(): far back up the hall, square to it
const CAM_FROM_LOOK := Vector3(-0.2, 1.6, -20.0)
const CAM_FOV := 52.0

var cam: Camera3D
var env: Environment
var tubes: Array = []                   # Tube: the places' (index = place), then the hall's
var people := {}                        # peer id -> Person
var hum: AudioStreamPlayer
var strike_sfx: AudioStreamPlayer
var _t := 0.0
var _cam_tw: Tween
var _cam_pos := CAM_REST_POS            # where the camera is meant to be; the drift rides on top
var _cam_look := CAM_REST_LOOK
var _drift := 1.0                       # 0..1 how much camcorder drift is on (none while it travels)
var _roll := 0.0                        # rad the camera is tipped on its side (drop_camera)
var _shake := 0.0                       # 0..1 the knock of a fall or a grab, dying away
var _egg := false                       # the camera is down or being picked up
var thud_sfx: AudioStreamPlayer
var _model: PackedScene
var _troffer_scene: PackedScene
var _sound := true                      # false: the hum fades out (BEGIN, BACK) and the tubes stop clicking

## One fixture: a lamp in the ceiling, its diffuser and the light it throws
class Tube:
	var light: SpotLight3D
	var fill: OmniLight3D
	var glow_tubes: ShaderMaterial          # the lit tubes' and lens's colour (a dead one has neither)
	var glow_lens: ShaderMaterial
	var energy := 1.0                   # this tube's own output (age)
	var on := false                     # where it is headed
	var state := "on"                   # on / flicker / dying / dead (the hall's), "place" for a survivor's
	var value := 0.0                    # 0..1 output now
	var burst := 0.0                    # s of stutter left
	var step := 0.0                     # s until the stutter picks its next value
	var step_v := 0.0
	var next := 6.0                     # s until the next spontaneous burst

## One survivor in the lobby
class Person:
	var id := 0
	var place := 0
	var root: Node3D
	var anim: AnimationPlayer
	var clips := {}
	var tag: Label3D
	var walk_tw: Tween
	var idle := ""                          # the lobby_idle_* clip they stand in
	var leaving := false

func _ready() -> void:
	_model = load(SurvivorAnim.MODEL)
	_build_env()
	_build_hall()
	for i in PLACES.size():
		var p: Vector3 = PLACES[i]
		var tb := _tube(Vector3(p.x, WALL_H, p.z), "place")
		tubes.append(tb)
	for h in HALL_TUBES:
		var tb := _tube(Vector3(h[0], WALL_H, h[1]), h[2])
		tb.on = h[2] != "dead"
		tb.value = 1.0 if tb.on else 0.0
		tubes.append(tb)
	cam = Camera3D.new()
	cam.fov = CAM_FOV
	cam.near = 0.05
	cam.far = 120.0
	add_child(cam)
	cam.current = true
	_place_cam(CAM_REST_POS, CAM_REST_LOOK)
	hum = AudioStreamPlayer.new()
	hum.stream = load("res://audio/world/lights/hum_diffuse.wav")
	hum.volume_db = -80.0
	hum.bus = "Master"
	add_child(hum)
	hum.finished.connect(hum.play)
	strike_sfx = AudioStreamPlayer.new()
	strike_sfx.stream = load("res://audio/world/lights/tube_restrike.wav")
	strike_sfx.volume_db = -34.0
	strike_sfx.bus = "Master"
	add_child(strike_sfx)
	thud_sfx = AudioStreamPlayer.new()
	thud_sfx.stream = load("res://audio/player/body/land_thud.wav")
	thud_sfx.volume_db = -6.0
	thud_sfx.bus = "Master"
	add_child(thud_sfx)

# ---- the hall ---------------------------------------------------------------------------
## main.tscn's WorldEnvironment, as the level starts it (dim): the same tonemap, glow, fog and SSAO
func _build_env() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.024, 0.012)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.26, 0.227, 0.133)
	env.ambient_light_energy = 0.22
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 0.95
	env.tonemap_agx_white = 6.0
	env.tonemap_agx_contrast = 1.3
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 2.2
	env.ssao_light_affect = 0.15
	env.glow_enabled = true
	for i in 7:
		env.set_glow_level(i, [0.0, 0.6, 1.0, 1.0, 0.8, 0.8, 0.4][i])
	env.glow_normalized = true
	env.glow_intensity = 1.7
	env.glow_strength = 1.25
	env.glow_bloom = 0.18
	env.glow_hdr_scale = 2.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.065, 0.052, 0.026)
	env.fog_density = 0.04
	env.fog_aerial_perspective = 0.15
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func _build_hall() -> void:
	var open := {}
	for c in CELLS:
		open[c] = true
	var carpet := _carpet()
	var ceiling := _ceiling()
	var paper := _wallpaper()
	var floor_st := SurfaceTool.new()
	var ceil_st := SurfaceTool.new()
	var skirt_st := SurfaceTool.new()
	skirt_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	floor_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	ceil_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for c: Vector2i in CELLS:
		var x0 := (c.x - 0.5) * CELL
		var z0 := (c.y - 0.5) * CELL
		_quad(floor_st, Vector3(x0, 0, z0), Vector3(x0 + CELL, 0, z0), Vector3(x0 + CELL, 0, z0 + CELL), Vector3(x0, 0, z0 + CELL), Vector3.UP)
		_quad(ceil_st, Vector3(x0, WALL_H, z0 + CELL), Vector3(x0 + CELL, WALL_H, z0 + CELL), Vector3(x0 + CELL, WALL_H, z0), Vector3(x0, WALL_H, z0), Vector3.DOWN)
		# a wall on every side that has no open cell beyond it
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if open.has(c + d) or (c + d).y < -9:          # past the last cell the hall runs on into the dark
				continue
			var wall := MeshInstance3D.new()
			var box := BoxMesh.new()
			var along_x: bool = d.y != 0
			box.size = Vector3(CELL + WALL_T if along_x else WALL_T, WALL_H, WALL_T if along_x else CELL + WALL_T)
			wall.mesh = box
			wall.material_override = paper
			wall.position = Vector3((c.x + d.x * 0.5) * CELL + d.x * WALL_T * 0.5, WALL_H * 0.5, (c.y + d.y * 0.5) * CELL + d.y * WALL_T * 0.5)
			add_child(wall)
			_skirt(skirt_st, Vector3((c.x + d.x * 0.5) * CELL, 0.0, (c.y + d.y * 0.5) * CELL), Vector3(d.x, 0, d.y), CELL)
	var skirting := MeshInstance3D.new()
	skirting.mesh = skirt_st.commit()
	skirting.material_override = SkirtMaterial.get_material()
	add_child(skirting)
	for pair in [[floor_st, carpet], [ceil_st, ceiling]]:
		var st: SurfaceTool = pair[0]
		st.generate_tangents()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = pair[1]
		add_child(mi)

## The vinyl cove base (level_trim.gd SKIRT, the level's own profile and material) along the foot of a wall: `at`
## the middle of its face on the floor, `toward` the way the wall lies from the room, `length` along it
func _skirt(st: SurfaceTool, at: Vector3, toward: Vector3, length: float) -> void:
	var along := Vector3.UP.cross(toward).normalized()
	var n := SKIRT.size()
	var nrm: Array[Vector2] = []
	for k in n:                                  # the profile's normals, smoothed: out from the wall, up the cove
		var a: Vector2 = SKIRT[maxi(k - 1, 0)]
		var b: Vector2 = SKIRT[mini(k + 1, n - 1)]
		var tan := (b - a).normalized()
		nrm.append(Vector2(-tan.y, tan.x))
	for k in n - 1:
		var p0: Vector2 = SKIRT[k]
		var p1: Vector2 = SKIRT[k + 1]
		var a0 := at - toward * p0.x + Vector3.UP * p0.y
		var a1 := at - toward * p1.x + Vector3.UP * p1.y
		var lo := -along * length * 0.5
		var hi := along * length * 0.5
		var n0 := -toward * nrm[k].x + Vector3.UP * nrm[k].y
		var n1 := -toward * nrm[k + 1].x + Vector3.UP * nrm[k + 1].y
		var v := [a0 + lo, a0 + hi, a1 + hi, a1 + lo]
		var nn := [n0, n0, n1, n1]
		var tri := [0, 1, 2, 0, 2, 3]
		var face: Vector3 = (v[1] - v[0]).cross(v[2] - v[0])
		if face.dot(n0 + n1) > 0.0:              # Godot's front face winds clockwise
			tri = [0, 2, 1, 0, 3, 2]
		for idx in tri:
			st.set_normal(nn[idx])
			st.add_vertex(v[idx])

## A quad with its UV in world x / z metres (the level's floor and ceiling shaders tile by it)
func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	for v in [a, b, c, a, c, d]:
		st.set_normal(n)
		st.set_uv(Vector2(v.x, v.z))
		st.add_vertex(v)

## level_geometry.gd _carpet_material, without the level's wear map
func _carpet() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = CarpetShader
	sm.set_shader_parameter("albedo_tex", load("res://textures/l0_carpet_color.webp"))
	sm.set_shader_parameter("normal_tex", load("res://textures/l0_carpet_normal.webp"))
	sm.set_shader_parameter("roughness_tex", load("res://textures/l0_carpet_rough.webp"))
	sm.set_shader_parameter("ao_tex", load("res://textures/l0_carpet_ao.webp"))
	sm.set_shader_parameter("height_tex", load("res://textures/l0_carpet_height.png"))
	sm.set_shader_parameter("albedo_tint", Color(1.0, 0.94, 0.75))
	sm.set_shader_parameter("uv_scale", Vector2(0.5, 0.5))
	sm.set_shader_parameter("normal_scale", 1.5)
	sm.set_shader_parameter("roughness_mult", 0.94)
	sm.set_shader_parameter("metallic_specular", 0.2)
	sm.set_shader_parameter("ao_light_affect", 0.75)
	sm.set_shader_parameter("height_scale", 0.025)
	var q := clampi(int(Gfx.s.get("post", 2)), 0, 2)
	sm.set_shader_parameter("min_layers", [0, 4, 6][q])
	sm.set_shader_parameter("max_layers", [0, 8, 14][q])
	return sm

## level_geometry.gd _acoustic_ceiling
func _ceiling() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = CeilingShader
	sm.set_shader_parameter("albedo_tex", load("res://textures/l0_ceiling_color.webp"))
	sm.set_shader_parameter("normal_tex", load("res://textures/l0_ceiling_normal.webp"))
	sm.set_shader_parameter("rough_tex", load("res://textures/l0_ceiling_rough.webp"))
	sm.set_shader_parameter("ao_tex", load("res://textures/l0_ceiling_ao.webp"))
	sm.set_shader_parameter("albedo_tint", Color(0.89, 0.85, 0.74))
	sm.set_shader_parameter("ao_light_affect", 0.2)
	return sm

## level_geometry.gd _mat("l0_wallpaper"): world triplanar, one repeat every 2.25 m
func _wallpaper() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://textures/l0_wallpaper_color.webp")
	m.albedo_color = Color(1.0, 0.98, 0.88)
	m.normal_enabled = true
	m.normal_texture = load("res://textures/l0_wallpaper_normal.webp")
	m.roughness = 0.88
	m.roughness_texture = load("res://textures/l0_wallpaper_rough.webp")
	m.ao_enabled = true
	m.ao_texture = load("res://textures/l0_wallpaper_ao.webp")
	m.ao_light_affect = 0.2
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE / 2.25
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.metallic_specular = 0.35
	return m

## A 2 x 4 ft troffer set into the ceiling at `at`: the housing, the diffuser that glows, the cone of light
## down (level_fixtures.gd: a spot close to a diffuser's cosine) and a faint fill for the bounce off the carpet
func _tube(at: Vector3, state: String) -> Tube:
	var tb := Tube.new()
	tb.state = state
	tb.energy = randf_range(0.85, 1.0) if state != "dying" else 0.4
	tb.next = randf_range(3.0, 12.0)
	_troffer(tb, at, state == "dead")
	tb.light = SpotLight3D.new()
	tb.light.position = at - Vector3(0, 0.12, 0)
	tb.light.rotation_degrees = Vector3(-90, 0, 0)
	tb.light.light_color = TUBE_COLOR
	tb.light.spot_range = 11.0
	tb.light.spot_angle = 72.0
	tb.light.spot_angle_attenuation = 1.6
	tb.light.shadow_enabled = state == "place" and int(Gfx.s.get("shadows", 1)) > 0
	tb.light.shadow_bias = 0.04
	tb.light.shadow_normal_bias = 1.5
	add_child(tb.light)
	tb.fill = OmniLight3D.new()
	tb.fill.position = Vector3(at.x, 0.6, at.z + 0.8)
	tb.fill.light_color = Color(1.0, 0.86, 0.55)
	tb.fill.omni_range = 5.0
	tb.fill.shadow_enabled = false
	add_child(tb.fill)
	_show_tube(tb)
	return tb

## The level's troffer (level_fixtures.gd _build_fixture_meshes): the same model and materials, one instance.
## Object_3 housing, Object_4 tray, Object_5 tubes, Object_2 diffuser lens; a dead one has the burnt tubes
## and lens, a live one's tubes and lens are unshaded and take their colour from `glow` (_show_tube).
func _troffer(tb: Tube, at: Vector3, burnt: bool) -> void:
	if _troffer_scene == null:
		_troffer_scene = load("res://models/lights/office_lighting_troffer_light_1x4.glb")
	var root: Node3D = _troffer_scene.instantiate()
	var parts := {}
	for n in root.find_children("Object_*", "MeshInstance3D", true, false):
		parts[String(n.name)] = n
	var housing := StandardMaterial3D.new()
	housing.albedo_color = Color("cfcabf")
	housing.roughness = 0.65
	housing.metallic = 0.2
	var tray := StandardMaterial3D.new()
	tray.albedo_color = Color("eeece4")
	tray.roughness = 0.45
	tray.metallic = 0.25
	var tubes_mat: Material
	var lens_mat: Material
	if burnt:
		var bt := StandardMaterial3D.new()
		bt.albedo_color = Color("221f1a")
		bt.roughness = 0.9
		bt.metallic = 0.1
		tubes_mat = bt
		var bl := StandardMaterial3D.new()
		bl.albedo_color = Color(0.2, 0.188, 0.157, 0.65)
		bl.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		bl.roughness = 0.85
		lens_mat = bl
	else:
		var tsh := Shader.new()
		tsh.code = "shader_type spatial;\nrender_mode unshaded, shadows_disabled;\nuniform vec3 glow;\nvoid fragment() { ALBEDO = glow; }"
		var tm := ShaderMaterial.new()
		tm.shader = tsh
		tubes_mat = tm
		var lsh := Shader.new()
		lsh.code = "shader_type spatial;\nrender_mode unshaded, blend_add, depth_draw_never, shadows_disabled;\nuniform vec3 glow;\nvoid fragment() { ALBEDO = glow; ALPHA = 0.35; }"
		var lm := ShaderMaterial.new()
		lm.shader = lsh
		lens_mat = lm
		tb.glow_tubes = tm
		tb.glow_lens = lm
	var mats := {"Object_3": housing, "Object_4": tray, "Object_5": tubes_mat, "Object_2": lens_mat}
	var base := Transform3D(Basis(), at + Vector3(0, 0.03 - TROFFER_TOP_Y, 0))
	for part in mats:
		if not parts.has(part):
			continue
		var node: MeshInstance3D = parts[part]
		var mi := MeshInstance3D.new()
		mi.mesh = node.mesh
		mi.material_override = mats[part]
		mi.transform = base * _mesh_world(root, node)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	root.queue_free()

func _mesh_world(root: Node, node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null:
		if n is Node3D:
			t = (n as Node3D).transform * t
		if n == root:
			break
		n = n.get_parent()
	return t

func _show_tube(tb: Tube) -> void:
	var v := tb.value * tb.energy
	tb.light.light_energy = LIGHT_ENERGY * v
	tb.light.visible = v > 0.002
	tb.fill.light_energy = 0.35 * v
	tb.fill.visible = v > 0.002
	if tb.glow_tubes:
		var g := Vector3(LIT_DIFFUSER.r * 1.0, LIT_DIFFUSER.g * 0.95, LIT_DIFFUSER.b * 0.85) * v
		tb.glow_tubes.set_shader_parameter("glow", g)
		tb.glow_lens.set_shader_parameter("glow", g * 0.45)

## Set a tube going on or off: it stutters for a moment either way, like a starter that won't take at once
func _switch(tb: Tube, on: bool, quiet := false) -> void:
	if tb.on == on:
		return
	tb.on = on
	tb.burst = STRIKE_TIME * (1.0 if on else 0.45) * randf_range(0.8, 1.2)
	tb.step = 0.0
	if not quiet:
		strike_sfx.pitch_scale = randf_range(0.92, 1.08)
		if _sound:
			strike_sfx.play()

func _update_tubes(dt: float) -> void:
	var lit := 0.0
	for tb: Tube in tubes:
		if tb.state == "dead":
			continue
		if tb.on and tb.burst <= 0.0:
			tb.next -= dt
			if tb.next <= 0.0:
				# a burst of dropouts: the failing hall tube nearly all the time, any other now and then
				tb.burst = randf_range(0.6, 2.4) if tb.state == "flicker" else randf_range(0.12, 0.5)
				tb.next = randf_range(0.6, 3.0) if tb.state == "flicker" else randf_range(7.0, 22.0)
				if tb.state == "place" and randf() < 0.5:
					strike_sfx.pitch_scale = randf_range(1.1, 1.3)
					strike_sfx.play()
		if tb.burst > 0.0:
			tb.burst -= dt
			tb.step -= dt
			if tb.step <= 0.0:
				tb.step = randf_range(0.03, 0.09)
				tb.step_v = [0.0, 0.0, 0.12, 0.4, 1.0, 1.0][randi() % 6]
			tb.value = tb.step_v
			if tb.burst <= 0.0:
				tb.value = 1.0 if tb.on else 0.0
		else:
			tb.value = 1.0 if tb.on else 0.0
		if tb.state == "dying" and tb.on:
			tb.value *= 0.55 + 0.45 * (0.5 + 0.5 * sin(_t * 7.3 + tb.energy * 40.0)) * (0.7 + 0.3 * sin(_t * 1.9))
		elif tb.on:
			tb.value *= 0.97 + 0.03 * sin(_t * 120.0 + tb.energy * 10.0)      # the mains ripple, barely
		_show_tube(tb)
		if tb.state == "place":
			lit += tb.value
	# the hum swells with every tube that is lit over the group
	var want := -56.0 + 2.0 * lit if lit > 0.05 and _sound else -80.0
	hum.volume_db = lerpf(hum.volume_db, want, minf(1.0, dt * (3.0 if _sound else 1.6)))
	if not hum.playing and want > -79.0:
		hum.play()
	elif hum.playing and not _sound and hum.volume_db < -70.0:
		hum.stop()

# ---- the survivors ------------------------------------------------------------------------
## `roster`: [{id, name, color, local}], you first. New ones take a place (you always place 0, at once the
## first time), gone ones walk off. `instant`: everyone already there just stands in their light (the lobby
## opening on a room that already has people in it).
func set_roster(roster: Array, instant := false) -> void:
	var keep := {}
	for r: Dictionary in roster:
		keep[int(r.id)] = true
	for id in people.keys():
		if not keep.has(id) and not people[id].leaving:
			_leave(people[id])
	for r: Dictionary in roster:
		var id := int(r.id)
		if people.has(id) and not people[id].leaving:
			_tag(people[id], r)
			continue
		var place := 0 if r.get("local", false) else _free_place()
		if place < 0:
			continue
		var pr := _person(id, place, r)
		if instant or place == 0:
			_switch(tubes[place], true, true)
			tubes[place].burst = 0.0
		else:
			_arrive(pr)

## Yaw for place `i`: towards the camera's rest, turned off it a little (the suit faces its own +Z)
func _facing(i: int) -> float:
	var p: Vector3 = PLACES[i]
	return atan2(CAM_REST_POS.x - p.x, CAM_REST_POS.z - p.z) + FACING[i]

func _free_place() -> int:
	var taken := {}
	for pr: Person in people.values():
		if not pr.leaving:
			taken[pr.place] = true
	for i in range(1, PLACES.size()):
		if not taken.has(i) and tubes[i].value < 0.01:       # (a place whose tube is still going out isn't free yet)
			return i
	for i in range(1, PLACES.size()):
		if not taken.has(i):
			return i
	return -1

## A standing idle nobody in the lobby is in yet (any, once there are more people than clips)
func _pick_idle() -> String:
	var taken := {}
	for pr: Person in people.values():
		taken[pr.idle] = true
	var free: Array = IDLES.filter(func(n: String) -> bool: return not taken.has(n))
	if free.is_empty():
		free = IDLES
	return free[randi() % free.size()]

func _person(id: int, place: int, r: Dictionary) -> Person:
	var pr := Person.new()
	pr.id = id
	pr.place = place
	pr.root = Node3D.new()
	add_child(pr.root)
	var p: Vector3 = PLACES[place]
	pr.root.position = p
	pr.root.rotation.y = _facing(place)
	if _model:
		var holder := Node3D.new()
		pr.root.add_child(holder)
		var suit: Node3D = _model.instantiate()
		holder.add_child(suit)
		suit.transform = HazmatFit.fit(suit, holder, MODEL_HEIGHT)
		SurvivorAnim.apply_suit_variant(suit, SUITS[place])
		_tint(suit, r.get("color", Color.WHITE))
		var aps := suit.find_children("*", "AnimationPlayer", true, false)
		if not aps.is_empty():
			pr.anim = aps[0]
			pr.clips = SurvivorAnim.find_clips(pr.anim)
			pr.idle = _pick_idle()
			_play(pr, pr.idle, 0.0)
			pr.anim.seek(randf() * pr.anim.current_animation_length, true)    # nobody breathes in step
	pr.tag = Label3D.new()
	pr.tag.font = load("res://fonts/vcr.ttf")
	pr.tag.font_size = 40
	pr.tag.pixel_size = 0.0032
	pr.tag.outline_size = 10
	pr.tag.outline_modulate = Color(0, 0, 0, 0.7)
	pr.tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	pr.tag.position = Vector3(0, MODEL_HEIGHT + 0.28, 0)
	pr.tag.fixed_size = false
	pr.tag.line_spacing = -6.0
	pr.root.add_child(pr.tag)
	_tag(pr, r)
	people[id] = pr
	return pr

func _tag(pr: Person, r: Dictionary) -> void:
	var nm := str(r.get("name", "SURVIVOR"))
	pr.tag.text = ("► " + nm) if r.get("local", false) else nm
	if r.get("ready", false):
		pr.tag.text += "\nREADY"
	pr.tag.modulate = Color(0.9, 0.882, 0.804, 0.9) if not r.get("local", false) else Color(0.95, 0.85, 0.6, 1.0)

## remote_player.gd _tint: the suit takes a little of the survivor's colour
func _tint(root: Node, color: Color) -> void:
	var tint := Color.WHITE.lerp(color, 0.12)           # (the suit's own colour does most of the telling apart now)
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in mi.get_surface_override_material_count():
			var mat := mi.get_active_material(i)
			if mat is StandardMaterial3D:
				var c: StandardMaterial3D = mat.duplicate()
				c.albedo_color = c.albedo_color * tint
				mi.set_surface_override_material(i, c)

func _play(pr: Person, role: String, fade := SurvivorAnim.FADE) -> void:
	if pr.anim == null:
		return
	var clip: String = pr.clips.get(role, "")
	if clip == "":
		clip = pr.clips.get(SurvivorAnim.FALLBACK.get(role, "idle"), "")
	if clip != "":
		pr.anim.play(clip, fade)

## Their tube strikes, then they walk up the hall out of the dark and on into its light, and turn to the camera
func _arrive(pr: Person) -> void:
	_switch(tubes[pr.place], true)
	var path := _path(pr.place)
	pr.root.position = path[0]
	pr.tag.visible = false
	_play(pr, "walk", 0.0)
	if pr.anim:
		pr.anim.speed_scale = SurvivorAnim.speed_scale("walk", WALK_SPEED)
	pr.walk_tw = create_tween()
	pr.walk_tw.tween_interval(STRIKE_TIME * 0.6)
	_walk(pr.walk_tw, pr.root, path)
	pr.walk_tw.tween_callback(func() -> void:
		_play(pr, pr.idle)
		if pr.anim:
			pr.anim.speed_scale = 1.0
		pr.tag.visible = true)
	pr.walk_tw.tween_property(pr.root, "rotation:y", _facing(pr.place), 0.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

## They turn round and walk back down the hall into the dark; their tube goes out once they are out of its pool
func _leave(pr: Person) -> void:
	pr.leaving = true
	if pr.walk_tw and pr.walk_tw.is_valid():
		pr.walk_tw.kill()
	pr.tag.visible = false
	var path := _path(pr.place)
	path.reverse()
	path[0] = pr.root.position             # (from wherever they had got to)
	_play(pr, "walk")
	if pr.anim:
		pr.anim.speed_scale = SurvivorAnim.speed_scale("walk", WALK_SPEED)
	var tw := create_tween()
	_walk(tw, pr.root, path)
	tw.parallel().tween_callback(func() -> void: _switch(tubes[pr.place], false)).set_delay(1.4)
	tw.tween_callback(func() -> void:
		if people.get(pr.id) == pr:
			people.erase(pr.id)
		pr.root.queue_free())

## The way in to place `i`: from the dark down the hall, up its middle, then across to the place (the room's
## places are round the corner of its wall)
func _path(i: int) -> Array[Vector3]:
	var to: Vector3 = PLACES[i]
	var lane := clampf(to.x, -1.4, 1.5)
	return [Vector3(lane * 0.5, 0.0, WALK_FROM), Vector3(lane, 0.0, minf(to.z - 1.2, -3.0)), to]

## Walk `node` along `path` at WALK_SPEED, turning into each leg as it goes (the suit faces its own +Z)
func _walk(tw: Tween, node: Node3D, path: Array[Vector3]) -> void:
	var yaw := node.rotation.y
	for k in range(1, path.size()):
		var a: Vector3 = path[k - 1]
		var b: Vector3 = path[k]
		if a.distance_to(b) < 0.05:
			continue
		var want := atan2(b.x - a.x, b.z - a.z)
		want = yaw + wrapf(want - yaw, -PI, PI)     # the short way round
		yaw = want
		var secs := a.distance_to(b) / WALK_SPEED
		tw.tween_property(node, "rotation:y", want, minf(0.45, secs)).set_trans(Tween.TRANS_SINE)
		tw.parallel().tween_property(node, "position", b, secs)

# ---- camera ---------------------------------------------------------------------------------
func _place_cam(pos: Vector3, look: Vector3) -> void:
	_cam_pos = pos
	_cam_look = look

## The title screen's push-in carries on into the hall: from far back, square down it, forward and round onto
## the group, slowing to rest
func from_menu(secs := 2.8) -> void:
	_kill_cam()
	_drift = 0.0
	_place_cam(CAM_FROM_POS, CAM_FROM_LOOK)
	_cam_tw = create_tween().set_parallel(true)
	_cam_tw.tween_property(self, "_cam_pos", CAM_REST_POS, secs).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_cam_tw.tween_property(self, "_cam_look", CAM_REST_LOOK, secs).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_cam_tw.tween_property(self, "_drift", 1.0, secs * 0.8).set_delay(secs * 0.5)

## BEGIN: on past the group, faster and faster, into the dark down the hall
func push_in(secs := 1.8) -> void:
	_kill_cam()
	_cam_tw = create_tween().set_parallel(true)
	_cam_tw.tween_property(self, "_drift", 0.0, 0.4)
	_cam_tw.tween_property(self, "_cam_pos", Vector3(-1.3, 1.7, -12.0), secs).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_cam_tw.tween_property(self, "_cam_look", Vector3(-0.8, 1.6, -30.0), secs * 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

## BACK: backs away up the hall
func pull_back(secs := 1.0) -> void:
	_kill_cam()
	_cam_tw = create_tween().set_parallel(true)
	_cam_tw.tween_property(self, "_drift", 0.0, 0.3)
	_cam_tw.tween_property(self, "_cam_pos", CAM_FROM_POS, secs).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_cam_tw.tween_property(self, "_cam_look", CAM_FROM_LOOK, secs).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

## Easter egg: the camera slips and hits the carpet, sits there on its side looking along the floor at the
## survivors' boots, then somebody picks it up (it swings up, rights itself and goes back to being held still)
func drop_camera() -> void:
	if _egg or _drift < 0.99:
		return
	_kill_cam()
	_egg = true
	var floor_pos := Vector3(-1.05, 0.11, 4.6)
	var floor_look := Vector3(1.4, 0.15, -3.5)
	var tw := create_tween().set_parallel(true)
	_cam_tw = tw
	tw.tween_property(self, "_drift", 0.0, 0.1)
	# the slip: a flinch up and away, then down fast
	tw.chain().tween_property(self, "_cam_pos", CAM_REST_POS + Vector3(0.05, 0.12, 0.1), 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "_roll", -0.25, 0.18)
	tw.chain().tween_property(self, "_cam_pos", floor_pos, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "_cam_look", floor_look, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "_roll", 1.25, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(_thud.bind(1.0, 0.0)).set_delay(0.5)
	# the bounce
	tw.chain().tween_property(self, "_cam_pos", floor_pos + Vector3(0.0, 0.1, -0.05), 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "_roll", 1.05, 0.12)
	tw.chain().tween_property(self, "_cam_pos", floor_pos, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "_roll", 1.3, 0.14)
	tw.tween_callback(_thud.bind(0.45, 0.0)).set_delay(0.14)
	# it lies there a while
	tw.chain().tween_interval(3.2)
	# the grab: a jolt, then up in a clumsy arc
	tw.chain().tween_callback(_thud.bind(0.6, -5.0))
	tw.tween_property(self, "_cam_pos", floor_pos + Vector3(0.1, 0.35, 0.35), 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(self, "_roll", 0.6, 0.5)
	tw.chain().tween_property(self, "_cam_pos", CAM_REST_POS + Vector3(-0.1, -0.35, 0.2), 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(self, "_cam_look", CAM_REST_LOOK + Vector3(-1.0, -1.3, 1.5), 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(self, "_roll", -0.18, 0.7)
	tw.chain().tween_property(self, "_cam_pos", CAM_REST_POS, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "_cam_look", CAM_REST_LOOK, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "_roll", 0.0, 0.9)
	tw.chain().tween_property(self, "_drift", 1.0, 0.6)
	tw.tween_callback(func() -> void: _egg = false)

func _thud(power: float, db: float) -> void:
	_shake = maxf(_shake, power)
	if _sound:
		thud_sfx.volume_db = -6.0 + db + (power - 1.0) * 8.0
		thud_sfx.pitch_scale = randf_range(0.85, 1.0) if power > 0.8 else randf_range(1.0, 1.2)
		thud_sfx.play()

## The hum and the tubes' clicks on or off (off fades the hum out over about a second and a half)
func set_sound(on: bool) -> void:
	_sound = on

func _kill_cam() -> void:
	if _cam_tw and _cam_tw.is_valid():
		_cam_tw.kill()
	_egg = false
	_roll = 0.0

func _process(dt: float) -> void:
	_t += dt
	_update_tubes(dt)
	# a camcorder held as still as hands can: a slow wander and a slight sway, nothing that reads as motion
	var wander := Vector3(sin(_t * 0.31) * 0.05 + sin(_t * 0.83) * 0.012, sin(_t * 0.47) * 0.03 + sin(_t * 1.3) * 0.006, sin(_t * 0.23) * 0.04) * _drift
	var look_wander := Vector3(sin(_t * 0.27 + 1.0) * 0.12, sin(_t * 0.39 + 2.0) * 0.06, 0.0) * _drift
	cam.position = _cam_pos + wander
	_shake = maxf(0.0, _shake - dt * 1.6)
	var knock := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * 0.06 * _shake * _shake
	cam.look_at(_cam_look + look_wander + knock, Vector3.UP)
	cam.rotate_object_local(Vector3.FORWARD, sin(_t * 0.21) * 0.006 * _drift + _roll)
