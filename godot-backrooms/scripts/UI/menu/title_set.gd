extends Node3D
## The title screen's backdrop (main_menu.gd): a few short sets of Level 0, each with its troffers failing overhead
## and a figure from the mannequin crowd standing in it, shown one after another on a world of their own (the
## title's SubViewport). The camera creeps along a set's track; then it pushes on, the lights stutter out, and the
## next set strikes on. A figure is never quite where it was: each time its set comes round again it has taken a
## step nearer, or moved on to its next spot, so the same room is a little different every visit.
##
## push_in() and pull_back() are the title's PLAY and BACK moves: the camera pushes on down its track for the
## lobby to come up through, and pulls back to the start of the track again.

const Lobby := preload("res://scripts/UI/menu/lobby_corridor.gd")       # the lobby's hall: its tubes, skirting, colours
const MannequinModel := preload("res://scripts/Entities/mannequin/mannequin_model.gd")
const CarpetShader := preload("res://shaders/carpet_pom.gdshader")
const CeilingShader := preload("res://shaders/acoustic_ceiling.gdshader")
const SkirtMaterial := preload("res://scripts/World/level/skirt_material.gd")

const CELL := 4.5                       # level_data.gd CELL / WALL_H: the level's own scale
const WALL_H := 5.4
const WALL_T := 0.3
const SPACING := 80.0                   # m between the sets' origins: only the set on screen is ever drawn
const HOLD := 9.0                       # s the camera creeps along a set's track
const LEAVE_DIST := 2.2                 # m the camera pushes on past the end of the track
const LEAVE_SECS := 2.6
const CUT_SECS := 1.1                   # s of dark between two sets
const AMBIENT := 0.22                   # the environment's ambient energy with the lights up
const CAM_FOV := 52.0

## The sets, in the order they come up. cells: the open cells (x, z) with walls round them. tubes: [x, z, state]
## (on / flicker / dying / dead). figs: one figure each, standing on its `spots` in turn (one step further on every
## time the set comes round again, then it stays on the last), turned to `face`. cam: the track, [from, to, look],
## in metres: the camera creeps from `from` to `to` while it aims at `look`.
const SETS := [
	{   # the hall: one figure down it, coming nearer
		"cells": [Vector2i(0, 3), Vector2i(0, 2), Vector2i(0, 1), Vector2i(0, 0), Vector2i(0, -1), Vector2i(0, -2),
			Vector2i(0, -3), Vector2i(0, -4), Vector2i(0, -5), Vector2i(0, -6), Vector2i(1, 0), Vector2i(1, -1)],
		"tubes": [[0, 2, "on"], [0, 0, "flicker"], [0, -3, "flicker"], [0, -5, "dead"], [1, -1, "flicker"]],
		"figs": [{"spots": [Vector2i(0, -3), Vector2i(0, -2), Vector2i(0, -1)], "face": Vector3(0, 0, 9)}],
		"cam": [Vector3(-0.6, 1.6, 9.0), Vector3(-0.6, 1.6, 3.0), Vector3(-1.2, 1.4, -13.5)],
	},
	{   # the room: a figure in the back corner that walks up to the camera, a light dying over the door
		"cells": [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0),
			Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)],
		"tubes": [[-1, 1, "dying"], [1, 1, "flicker"], [0, 0, "on"], [-1, -1, "dead"], [1, -1, "on"]],
		"figs": [],
		"cam": [Vector3(0.8, 1.6, 5.6), Vector3(-0.6, 1.6, 5.9), Vector3(0, 1.4, -4.5)],
	},
	{   # the bays: a long lit hall, the camera tracking along it toward a figure at the far end
		"cells": [Vector2i(-2, 0), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, 1),
			Vector2i(-1, -1)],
		"tubes": [[-2, 0, "flicker"], [0, 0, "on"], [2, 0, "dying"], [1, 1, "dead"], [-1, -1, "dead"]],
		"figs": [],
		"cam": [Vector3(-9.2, 1.6, -0.5), Vector3(-3.5, 1.6, -0.5), Vector3(9.0, 1.4, 0.0)],
	},
	{   # the crowd: three figures standing in an open room, the camera panning across them
		"cells": [Vector2i(-2, -1), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-2, 0), Vector2i(-1, 0),
			Vector2i(0, 0), Vector2i(1, 0), Vector2i(-2, 1), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)],
		"tubes": [[-2, 1, "on"], [0, 1, "flicker"], [1, -1, "dying"], [-1, -1, "dead"], [1, 1, "on"], [-2, -1, "flicker"]],
		"figs": [],
		"cam": [Vector3(-3.0, 1.6, 6.0), Vector3(1.0, 1.6, 6.0), Vector3(-0.5, 1.3, 0.0)],
	},
]

## One fixture: a lamp in the ceiling, its diffuser and the light it throws (lobby_corridor.gd Tube)
class Tube:
	var light: SpotLight3D
	var fill: OmniLight3D
	var glow_tubes: ShaderMaterial          # the lit tubes' and lens's colour (a dead one has neither)
	var glow_lens: ShaderMaterial
	var energy := 1.0                       # this tube's own output (age)
	var on := false                         # where it is headed
	var state := "on"                       # on / flicker / dying / dead
	var value := 0.0                        # 0..1 output now
	var burst := 0.0                        # s of stutter left
	var step := 0.0                         # s until the stutter picks its next value
	var step_v := 0.0
	var next := 6.0                         # s until the next spontaneous burst

## One set: its root (hidden unless it is on screen), its fixtures, its figures and its camera track in the world
class Shot:
	var root: Node3D
	var tubes: Array = []                   # Tube
	var figs: Array = []                    # {node, spots, at, face}
	var cam_from: Vector3
	var cam_to: Vector3
	var look: Vector3
	var visits := 0

var cam: Camera3D
var env: Environment
var shots: Array[Shot] = []
var model: MannequinModel
var auto := true                        # false while the lobby has the camera (PLAY): no cuts
var _rng := RandomNumberGenerator.new()
var _cur := 0
var _mode := "hold"                     # hold / leave / cut / back
var _mode_t := 0.0
var _mode_secs := HOLD
var _pos := Vector3.ZERO
var _from_pos := Vector3.ZERO
var _t := 0.0
var _carpet: ShaderMaterial
var _ceiling: ShaderMaterial
var _paper: StandardMaterial3D
var _troffer_scene: PackedScene
var _ambient_tw: Tween

func _ready() -> void:
	_rng.randomize()
	model = MannequinModel.new()
	var template := Node3D.new()           # load_template leaves its scene under the host: keep it out of sight
	add_child(template)
	model.load_template(template)
	template.visible = false
	var variants := Node3D.new()           # the same for the worn sculpts
	add_child(variants)
	variants.visible = false
	model.load_variant(variants)
	_build_env()
	_carpet = _carpet_material()
	_ceiling = _ceiling_material()
	_paper = _wallpaper_material()
	for i in SETS.size():
		shots.append(_build_shot(SETS[i], i))
	cam = Camera3D.new()
	cam.fov = CAM_FOV
	cam.near = 0.05
	cam.far = 120.0
	add_child(cam)
	cam.current = true
	_show(0)
	_enter("hold", HOLD)

func _process(dt: float) -> void:
	_t += dt
	_mode_t += dt
	var s := shots[_cur]
	_update_tubes(s, dt)
	match _mode:
		"hold":
			_pos = s.cam_from.lerp(s.cam_to, _smooth(clampf(_mode_t / _mode_secs, 0.0, 1.0)))
			if auto and _mode_t >= _mode_secs:
				_enter("leave", LEAVE_SECS)
		"leave":
			var fwd := (s.cam_to - s.cam_from).normalized()
			_pos = s.cam_to + fwd * LEAVE_DIST * _ease_in(clampf(_mode_t / _mode_secs, 0.0, 1.0))
			if auto and _mode_t >= _mode_secs:
				_lights_out(s)
				_enter("cut", CUT_SECS)
		"cut":
			if _mode_t >= _mode_secs:
				_show((_cur + 1) % shots.size())
				_enter("hold", HOLD)
		"back":
			_pos = _from_pos.lerp(s.cam_from, _smooth(clampf(_mode_t / _mode_secs, 0.0, 1.0)))
			if _mode_t >= _mode_secs:
				_enter("hold", HOLD)
	cam.position = _pos + Vector3(sin(_t * 0.31) * 0.03, sin(_t * 0.47) * 0.02, 0.0)     # the hand that holds it
	cam.look_at(s.look, Vector3.UP)

## PLAY: the camera pushes on down its track in `secs`, into the dark the lobby comes up through
func push_in(secs := 1.3) -> void:
	auto = false
	if _mode == "cut":                      # PLAY in the dark: the next set strikes on for the push
		_show((_cur + 1) % shots.size())
	_enter("leave", secs)

## BACK: the camera pulls back to the top of its track in `secs`, and the sets come round again
func pull_back(secs := 1.4) -> void:
	auto = true
	_from_pos = _pos
	_fade_ambient(AMBIENT)
	_enter("back", secs)

func _enter(mode: String, secs: float) -> void:
	_mode = mode
	_mode_t = 0.0
	_mode_secs = secs

## Bring set `i` up on screen: its tubes strike on, its figures take their next step, the camera is at the top of its track
func _show(i: int) -> void:
	for k in shots.size():
		shots[k].root.visible = k == i
	_cur = i
	var s := shots[i]
	s.visits += 1
	for f in s.figs:
		if s.visits > 1:
			f.at = mini(f.at + 1, f.spots.size() - 1)
		_place_fig(f)
	for tb: Tube in s.tubes:
		tb.on = false
		tb.value = 0.0
		tb.burst = 0.0
		if tb.state != "dead":
			_switch(tb, true)
		_show_tube(tb)
	_fade_ambient(AMBIENT)
	_pos = s.cam_from

## The set goes dark: its tubes stutter out and the room's own light goes with them
func _lights_out(s: Shot) -> void:
	for tb: Tube in s.tubes:
		if tb.state != "dead":
			_switch(tb, false)
	_fade_ambient(0.0)

func _fade_ambient(to: float) -> void:
	if _ambient_tw:
		_ambient_tw.kill()
	_ambient_tw = create_tween()
	_ambient_tw.tween_property(env, "ambient_light_energy", to, 0.5)

func _smooth(k: float) -> float:
	return k * k * (3.0 - 2.0 * k)

func _ease_in(k: float) -> float:
	return k * k

# ---- the sets -------------------------------------------------------------------------------
## main_menu.gd's WorldEnvironment look for the lobby, held a little darker, with the fog closer in
func _build_env() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.024, 0.012)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.26, 0.227, 0.133)
	env.ambient_light_energy = AMBIENT
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
	env.fog_density = 0.03
	env.fog_aerial_perspective = 0.15
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func _build_shot(d: Dictionary, i: int) -> Shot:
	var s := Shot.new()
	s.root = Node3D.new()
	s.root.position = Vector3(i * SPACING, 0.0, 0.0)
	s.root.visible = false
	add_child(s.root)
	var off := s.root.position
	s.cam_from = d.cam[0] + off
	s.cam_to = d.cam[1] + off
	s.look = d.cam[2] + off
	_build_hall(s.root, d.cells)
	for t in d.tubes:
		s.tubes.append(_tube(s.root, Vector3(t[0] * CELL, WALL_H, t[1] * CELL), t[2]))
	for f in d.figs:
		var holder := _figure(s.root)
		var fig := {"node": holder, "spots": f.spots, "at": 0, "face": f.face}
		_place_fig(fig)
		s.figs.append(fig)
	return s

## Walls round every open cell that has no open cell beyond it, the floor and the ceiling over them all
func _build_hall(root: Node3D, cells: Array) -> void:
	var open := {}
	for c in cells:
		open[c] = true
	var floor_st := SurfaceTool.new()
	var ceil_st := SurfaceTool.new()
	var skirt_st := SurfaceTool.new()
	floor_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	ceil_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	skirt_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for c: Vector2i in cells:
		var x0 := (c.x - 0.5) * CELL
		var z0 := (c.y - 0.5) * CELL
		_quad(floor_st, Vector3(x0, 0, z0), Vector3(x0 + CELL, 0, z0), Vector3(x0 + CELL, 0, z0 + CELL), Vector3(x0, 0, z0 + CELL), Vector3.UP)
		_quad(ceil_st, Vector3(x0, WALL_H, z0 + CELL), Vector3(x0 + CELL, WALL_H, z0 + CELL), Vector3(x0 + CELL, WALL_H, z0), Vector3(x0, WALL_H, z0), Vector3.DOWN)
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if open.has(c + d):
				continue
			var wall := MeshInstance3D.new()
			var box := BoxMesh.new()
			var along_x: bool = d.y != 0
			box.size = Vector3(CELL + WALL_T if along_x else WALL_T, WALL_H, WALL_T if along_x else CELL + WALL_T)
			wall.mesh = box
			wall.material_override = _paper
			wall.position = Vector3((c.x + d.x * 0.5) * CELL + d.x * WALL_T * 0.5, WALL_H * 0.5, (c.y + d.y * 0.5) * CELL + d.y * WALL_T * 0.5)
			root.add_child(wall)
			_skirt(skirt_st, Vector3((c.x + d.x * 0.5) * CELL, 0.0, (c.y + d.y * 0.5) * CELL), Vector3(d.x, 0, d.y), CELL)
	var skirting := MeshInstance3D.new()
	skirting.mesh = skirt_st.commit()
	skirting.material_override = SkirtMaterial.get_material()
	root.add_child(skirting)
	for pair in [[floor_st, _carpet], [ceil_st, _ceiling]]:
		var st: SurfaceTool = pair[0]
		st.generate_tangents()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = pair[1]
		root.add_child(mi)

## The vinyl cove base (lobby_corridor.gd _skirt) along the foot of a wall: `at` the middle of its face on the
## floor, `toward` the way the wall lies from the room, `length` along it
func _skirt(st: SurfaceTool, at: Vector3, toward: Vector3, length: float) -> void:
	var along := Vector3.UP.cross(toward).normalized()
	var skirt: Array = Lobby.SKIRT
	var n := skirt.size()
	var nrm: Array[Vector2] = []
	for k in n:                                  # the profile's normals, smoothed: out from the wall, up the cove
		var a: Vector2 = skirt[maxi(k - 1, 0)]
		var b: Vector2 = skirt[mini(k + 1, n - 1)]
		var tan := (b - a).normalized()
		nrm.append(Vector2(-tan.y, tan.x))
	for k in n - 1:
		var p0: Vector2 = skirt[k]
		var p1: Vector2 = skirt[k + 1]
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
func _carpet_material() -> ShaderMaterial:
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
func _ceiling_material() -> ShaderMaterial:
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
func _wallpaper_material() -> StandardMaterial3D:
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

## A 2 x 4 ft troffer set into the ceiling at `at` (lobby_corridor.gd _tube): the housing, the diffuser that glows,
## the cone of light down and a faint fill for the bounce off the carpet
func _tube(root: Node3D, at: Vector3, state: String) -> Tube:
	var tb := Tube.new()
	tb.state = state
	tb.energy = _rng.randf_range(0.85, 1.0) if state != "dying" else 0.4
	tb.next = _rng.randf_range(3.0, 12.0)
	_troffer(root, tb, at, state == "dead")
	tb.light = SpotLight3D.new()
	tb.light.position = at - Vector3(0, 0.12, 0)
	tb.light.rotation_degrees = Vector3(-90, 0, 0)
	tb.light.light_color = Lobby.TUBE_COLOR
	tb.light.spot_range = 11.0
	tb.light.spot_angle = 72.0
	tb.light.spot_angle_attenuation = 1.6
	tb.light.shadow_enabled = false
	root.add_child(tb.light)
	tb.fill = OmniLight3D.new()
	tb.fill.position = Vector3(at.x, 0.6, at.z + 0.8)
	tb.fill.light_color = Color(1.0, 0.86, 0.55)
	tb.fill.omni_range = 5.0
	tb.fill.shadow_enabled = false
	root.add_child(tb.fill)
	tb.on = state != "dead"
	_show_tube(tb)
	return tb

## The level's troffer (lobby_corridor.gd _troffer): the same model and materials, one instance
func _troffer(root: Node3D, tb: Tube, at: Vector3, burnt: bool) -> void:
	if _troffer_scene == null:
		_troffer_scene = load("res://models/lights/office_lighting_troffer_light_1x4.glb")
	var scene: Node3D = _troffer_scene.instantiate()
	var parts := {}
	for n in scene.find_children("Object_*", "MeshInstance3D", true, false):
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
	var base := Transform3D(Basis(), at + Vector3(0, 0.03 - Lobby.TROFFER_TOP_Y, 0))
	for part in mats:
		if not parts.has(part):
			continue
		var node: MeshInstance3D = parts[part]
		var mi := MeshInstance3D.new()
		mi.mesh = node.mesh
		mi.material_override = mats[part]
		mi.transform = base * _mesh_world(scene, node)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	scene.queue_free()

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
	tb.light.light_energy = Lobby.LIGHT_ENERGY * v
	tb.light.visible = v > 0.002
	tb.fill.light_energy = 0.35 * v
	tb.fill.visible = v > 0.002
	if tb.glow_tubes:
		var g := Vector3(Lobby.LIT_DIFFUSER.r, Lobby.LIT_DIFFUSER.g * 0.95, Lobby.LIT_DIFFUSER.b * 0.85) * v
		tb.glow_tubes.set_shader_parameter("glow", g)
		tb.glow_lens.set_shader_parameter("glow", g * 0.45)

## Set a tube going on or off: it stutters for a moment either way, like a starter that won't take at once
func _switch(tb: Tube, on: bool) -> void:
	if tb.on == on:
		return
	tb.on = on
	tb.burst = Lobby.STRIKE_TIME * (1.0 if on else 0.45) * _rng.randf_range(0.8, 1.2)
	tb.step = 0.0

## lobby_corridor.gd _update_tubes, for one set: a hall tube fails now and then, the dying ones stay unsteady
func _update_tubes(s: Shot, dt: float) -> void:
	for tb: Tube in s.tubes:
		if tb.state == "dead":
			continue
		if tb.on and tb.burst <= 0.0:
			tb.next -= dt
			if tb.next <= 0.0:
				tb.burst = _rng.randf_range(0.6, 2.4) if tb.state == "flicker" else _rng.randf_range(0.12, 0.5)
				tb.next = _rng.randf_range(0.6, 3.0) if tb.state == "flicker" else _rng.randf_range(7.0, 22.0)
		if tb.burst > 0.0:
			tb.burst -= dt
			tb.step -= dt
			if tb.step <= 0.0:
				tb.step = _rng.randf_range(0.03, 0.09)
				tb.step_v = [0.0, 0.0, 0.12, 0.4, 1.0, 1.0][_rng.randi() % 6]
			tb.value = tb.step_v
			if tb.burst <= 0.0:
				tb.value = 1.0 if tb.on else 0.0
		else:
			tb.value = 1.0 if tb.on else 0.0
		if tb.state == "dying" and tb.on:
			tb.value *= 0.55 + 0.45 * (0.5 + 0.5 * sin(_t * 7.3 + tb.energy * 40.0)) * (0.7 + 0.3 * sin(_t * 1.9))
		elif tb.on:
			tb.value *= 0.97 + 0.03 * sin(_t * 120.0 + tb.energy * 10.0)
		_show_tube(tb)

# ---- the figures ----------------------------------------------------------------------------
## A figure from the mannequin crowd (mannequin.gd: mostly the jointed sculpt, now and then a worn variant), built
## under `root` at its origin; _place_fig turns and moves it
func _figure(root: Node3D) -> Node3D:
	var holder := Node3D.new()
	root.add_child(holder)
	var pose := MannequinModel.rest_pose()
	pose["mode"] = "stand"
	pose["headYaw"] = _rng.randf_range(-0.25, 0.25)
	pose["headTilt"] = _rng.randf_range(-0.1, 0.1)
	if model.variant_count() > 0 and _rng.randf() < 0.3:
		var idx := _rng.randi() % model.variant_count()
		var vn := model.make_variant(pose, {}, idx)
		if vn != null:
			vn.transform = model.variant_root_xf_at(idx)
			holder.add_child(vn)
			return holder
	var xfs := model.part_transforms(pose)
	for j in model.parts.size():
		var mi := MeshInstance3D.new()
		mi.mesh = model.parts[j].mesh
		mi.transform = xfs[j]
		holder.add_child(mi)
	return holder

## Stand the figure on its current spot (cell coordinates), turned to its `face` point (set-local)
func _place_fig(f: Dictionary) -> void:
	var p: Vector2i = f.spots[f.at]
	f.node.transform = _place(Vector3(p.x * CELL, 0.0, p.y * CELL), f.face)

## Feet at `at`, facing `toward` (a point it looks at)
func _place(at: Vector3, toward: Vector3) -> Transform3D:
	var d := toward - at
	return Transform3D(Basis(Vector3.UP, atan2(d.x, d.z)), at)

