extends Node3D
## Rolling golden-hour hills: procedural terrain + road, cloud sky, wind grass, hilltop houses, distant castle.

const SIZE := 640.0
const RES := 320
const HOUSE_COUNT := 30
const TILE_SIZE := 5.0                        # GodotGrass tile LOD: one MultiMesh per tile, re-seated as the player moves
const GRASS_RADIUS := 90.0                    # blades fade out by 85 m (grass.gdshader); the terrain shader carries the rest
const GRASS_HIGH_PATH := "res://models/grass/grass_high.obj"
const GRASS_LOW_PATH := "res://models/grass/grass_low.obj"
# .obj meshes can't be preloaded off the main thread, so load them when the grass is built
static var grass_high: Mesh
static var grass_low: Mesh
const DAY_SECONDS := 720.0                    # one full 24 h day/night cycle in real seconds
const START_HOUR := 11.0
const TIME_STEP := 0.1                        # the sky / light are refreshed this often (seconds), not every frame

var noise := FastNoiseLite.new()
var detail := FastNoiseLite.new()
var sites: Array[Vector3] = []               # x, terrain height, z of each house pad
var yaws: Array[float] = []
var spawn_xz := Vector2.ZERO
var terrain_tex: ImageTexture
var grass_mat: ShaderMaterial
var grass_tiles: Array = []                  # [MultiMeshInstance3D, rest position]
var prev_tile := Vector2i(1 << 20, 0)
var player: Node3D
var env: Environment
var sky_mat: ShaderMaterial
var sun: DirectionalLight3D
var glass_mat: StandardMaterial3D           # every house window: lit up at night
var hour := START_HOUR
var time_scale := 1.0                       # debug: the clock runs this many times faster
const SPEEDS := [1.0, 30.0, 120.0]
var cloud_t := 0.0
var time_acc := 0.0
## true when run as its own scene (own player, HUD hint, environment); false when embedded in the game via hills_portal.gd
var standalone := true

func _ready() -> void:
	seed(20260926)
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.0055
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.45
	noise.seed = 7
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail.frequency = 0.03
	detail.seed = 11
	add_to_group("hills")
	spawn_xz = Vector2(road_x(40.0), 40.0)
	_pick_house_sites()
	_build_environment()
	_build_terrain()
	_build_grass()
	_build_houses()
	_build_castle()
	_apply_time()
	if standalone:
		_build_player()
		_build_hint()

# ---- height field ------------------------------------------------------------

func road_x(z: float) -> float:
	return 18.0 * sin(z * 0.011) + 9.0 * sin(z * 0.027 + 1.3)

func road_mask(x: float, z: float) -> float:
	return 1.0 - smoothstep(3.2, 5.2, absf(x - road_x(z)))

func raw_height(x: float, z: float) -> float:
	return noise.get_noise_2d(x, z) * 30.0 + 6.0 + detail.get_noise_2d(x, z) * 1.6

func height(x: float, z: float) -> float:
	var h := raw_height(x, z)
	# the road keeps its centreline height across its width, blended out smoothly (no trench)
	var hm := 1.0 - smoothstep(2.5, 11.0, absf(x - road_x(z)))
	h = lerpf(h, raw_height(road_x(z), z), hm)
	for s in sites:
		var t := 1.0 - smoothstep(8.0, 15.0, Vector2(x - s.x, z - s.z).length())
		if t > 0.0:
			h = lerpf(h, s.y, t)
	return h

func _pick_house_sites() -> void:
	var tries := 0
	while sites.size() < HOUSE_COUNT and tries < 6000:
		tries += 1
		var p := Vector2(randf_range(-270.0, 270.0), randf_range(-270.0, 270.0))
		if p.distance_to(spawn_xz) < 32.0 or absf(p.x - road_x(p.y)) < 16.0:
			continue
		var h := raw_height(p.x, p.y)
		var ring := 0.0
		for k in 8:
			var a := k * TAU / 8.0
			ring += raw_height(p.x + cos(a) * 18.0, p.y + sin(a) * 18.0)
		if h < ring / 8.0 + 1.2 or h < 8.0:
			continue
		var close := false
		for s in sites:
			if Vector2(s.x - p.x, s.z - p.y).length() < 36.0:
				close = true
				break
		if close:
			continue
		sites.append(Vector3(p.x, h, p.y))
		yaws.append(roundf(randf() * 24.0) * TAU / 24.0)

# ---- environment: sky, sun / moon, fog, day-night cycle ----------------------

func _build_environment() -> void:
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/hills/sky.gdshader")
	sky_mat.set_shader_parameter("cloud_cover", 0.55)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL     # the sky changes all day: refresh its lighting over several frames
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.fog_enabled = true
	env.fog_sun_scatter = 0.6
	env.fog_aerial_perspective = 0.45
	env.fog_sky_affect = 0.15
	env.ssao_enabled = false                    # it darkened the ground around the blades into blotchy bands, and costs a lot
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.1
	if standalone:
		var we := WorldEnvironment.new()
		we.environment = env
		add_child(we)

	sun = DirectionalLight3D.new()
	sun.light_angular_distance = 0.6
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 150.0    # tighter range = sharper shadow map, fewer terraced bands on the hills
	sun.directional_shadow_split_1 = 0.08
	sun.directional_shadow_split_2 = 0.22
	sun.directional_shadow_split_3 = 0.5
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.08
	sun.shadow_normal_bias = 2.5
	add_child(sun)

# palettes for the three looks of the sky: [zenith, mid, horizon, cloud lit, cloud shade]
const PAL_DAY := [Color(0.16, 0.36, 0.75), Color(0.45, 0.65, 0.9), Color(0.75, 0.85, 0.95), Color(1.0, 0.98, 0.95), Color(0.58, 0.63, 0.72)]
const PAL_GOLD := [Color(0.22, 0.3, 0.55), Color(0.7, 0.6, 0.62), Color(1.0, 0.62, 0.32), Color(1.0, 0.72, 0.5), Color(0.5, 0.4, 0.48)]
const PAL_NIGHT := [Color(0.005, 0.012, 0.04), Color(0.015, 0.03, 0.08), Color(0.05, 0.07, 0.13), Color(0.12, 0.15, 0.24), Color(0.02, 0.03, 0.06)]

## Sets the sun / moon, sky palette, fog, ambient and window lights for the current `hour`.
func _apply_time() -> void:
	var a := (hour - 6.0) / 12.0 * PI                    # 6:00 sunrise in +X, noon overhead, 18:00 sunset in -X
	var to_sun := Vector3(cos(a), sin(a), -0.35).normalized()
	var e := to_sun.y
	var dw := smoothstep(0.1, 0.4, e)
	var gw := clampf(1.0 - absf(e - 0.05) / 0.28, 0.0, 1.0)
	var nw := 1.0 - smoothstep(-0.25, 0.0, e)
	var tot := maxf(dw + gw + nw, 0.001)
	dw /= tot
	gw /= tot
	nw /= tot
	var pal: Array[Color] = []
	for i in 5:
		pal.append(PAL_DAY[i] * dw + PAL_GOLD[i] * gw + PAL_NIGHT[i] * nw)
	var dark := 1.0 - smoothstep(-0.18, 0.02, e)         # 0 day .. 1 night, drives stars / moon / lights
	var day_mix := smoothstep(-0.15, 0.3, e)
	var sun_col := Color(1.0, 0.5, 0.2).lerp(Color(1.0, 0.96, 0.88), smoothstep(0.0, 0.4, e))
	sky_mat.set_shader_parameter("sun_dir", to_sun)
	sky_mat.set_shader_parameter("moon_dir", -to_sun)
	sky_mat.set_shader_parameter("zenith_col", pal[0])
	sky_mat.set_shader_parameter("mid_col", pal[1])
	sky_mat.set_shader_parameter("horizon_col", pal[2])
	sky_mat.set_shader_parameter("cloud_lit", pal[3])
	sky_mat.set_shader_parameter("cloud_shade", pal[4])
	sky_mat.set_shader_parameter("sun_col", sun_col)
	sky_mat.set_shader_parameter("night", dark)
	sky_mat.set_shader_parameter("cloud_time", cloud_t)
	# one light does both jobs: the sun above the horizon, the moon below it (each fades to 0 at the horizon)
	if e >= 0.0:
		sun.light_color = sun_col
		sun.light_energy = 2.6 * smoothstep(0.0, 0.18, e)
		sun.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP)
	else:
		sun.light_color = Color(0.55, 0.65, 1.0)
		sun.light_energy = 0.9 * smoothstep(0.0, 0.18, -e)
		sun.look_at_from_position(Vector3.ZERO, to_sun, Vector3.UP)
	# the night sky is near black, so blend in a flat moonlit-blue ambient to keep the hills readable
	env.ambient_light_color = Color(0.2, 0.28, 0.5)
	env.ambient_light_sky_contribution = lerpf(0.3, 1.0, day_mix)
	env.ambient_light_energy = lerpf(1.3, 1.0, day_mix)
	env.fog_light_color = pal[2].lerp(Color(0.7, 0.75, 0.9), dw * 0.3)
	env.fog_light_energy = lerpf(0.3, 1.0, day_mix)
	env.fog_density = 0.0016 + 0.0012 * gw + 0.0014 * nw
	if glass_mat != null:
		glass_mat.emission_enabled = dark > 0.05
		glass_mat.emission_energy_multiplier = 3.0 * dark
	Game.day_light = 0.12 + 0.88 * smoothstep(-0.08, 0.3, e)

func _process(dt: float) -> void:
	hour = fposmod(hour + dt * time_scale * 24.0 / DAY_SECONDS, 24.0)
	cloud_t += dt * 0.008
	time_acc += dt
	if time_acc >= TIME_STEP and sky_mat != null:
		time_acc = 0.0
		_apply_time()

## Debug clock keys (dev keys / debug build, or the standalone scene):
##   N  jump to midnight, or back to noon    [ ]  step an hour back / forward
##   K  cycle the clock speed 1x -> 30x -> 120x, so a whole day passes in seconds
func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo and (Game.dev_keys or standalone)):
		return
	match e.physical_keycode:
		KEY_N:
			hour = 12.0 if (hour < 5.0 or hour > 19.0) else 0.0
			print("hills clock: %02d:00" % int(hour))
		KEY_BRACKETRIGHT:
			hour = fposmod(hour + 1.0, 24.0)
		KEY_BRACKETLEFT:
			hour = fposmod(hour - 1.0, 24.0)
		KEY_K:
			time_scale = SPEEDS[(SPEEDS.find(time_scale) + 1) % SPEEDS.size()]
			print("hills clock speed: x%d" % int(time_scale))
	_apply_time()

## What is underfoot at world (x, z): "dirt" on the road and steep slopes, "grass" everywhere else
func surface_at(x: float, z: float) -> String:
	if road_mask(x, z) > 0.4:
		return "dirt"
	var e := 1.5
	var slope := Vector2(height(x + e, z) - height(x - e, z), height(x, z + e) - height(x, z - e)).length() / (2.0 * e)
	return "dirt" if slope > 0.9 else "grass"

# ---- terrain -----------------------------------------------------------------

func _build_terrain() -> void:
	var n := RES + 1
	var cell := SIZE / RES
	var half := SIZE * 0.5
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	for j in n:
		for i in n:
			hs[j * n + i] = height(i * cell - half, j * cell - half)
	_bake_terrain_texture(hs, n, cell, half)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(n * n)
	norms.resize(n * n)
	cols.resize(n * n)
	for j in n:
		for i in n:
			var x := i * cell - half
			var z := j * cell - half
			var hl := hs[j * n + maxi(i - 1, 0)]
			var hr := hs[j * n + mini(i + 1, n - 1)]
			var hd := hs[maxi(j - 1, 0) * n + i]
			var hu := hs[mini(j + 1, n - 1) * n + i]
			verts[j * n + i] = Vector3(x, hs[j * n + i], z)
			norms[j * n + i] = Vector3(hl - hr, 2.0 * cell, hd - hu).normalized()
			cols[j * n + i] = Color(road_mask(x, z), 0, 0)
	var idx := PackedInt32Array()
	idx.resize(RES * RES * 6)
	var k := 0
	for j in RES:
		for i in RES:
			var a := j * n + i
			var b := a + 1
			var c := a + n
			var d := c + 1
			idx[k] = a
			idx[k + 1] = b
			idx[k + 2] = c
			idx[k + 3] = b
			idx[k + 4] = d
			idx[k + 5] = c
			k += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/hills/terrain.gdshader")
	var tex := "res://textures/hills/%s/%s_%s.jpg"
	var sets := {"turf": "Grass001_1K-JPG", "path_a": "Ground085_1K-JPG", "path_b": "Ground109_1K-JPG"}
	for slot in sets:
		var folder: String = sets[slot]
		mat.set_shader_parameter(slot + "_color", load(tex % [folder, folder, "Color"]))
		mat.set_shader_parameter(slot + "_rough", load(tex % [folder, folder, "Roughness"]))
		mat.set_shader_parameter(slot + "_ao", load(tex % [folder, folder, "AmbientOcclusion"]))
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	add_child(body)

# ---- grass (GodotGrass port) ---------------------------------------------------

## R = ground height, G = no-grass mask (road + house pads); sampled by grass.gdshader.
func _bake_terrain_texture(hs: PackedFloat32Array, n: int, cell: float, half: float) -> void:
	var img := Image.create(n, n, false, Image.FORMAT_RGF)
	for j in n:
		for i in n:
			var x := i * cell - half
			var z := j * cell - half
			var m := road_mask(x, z)
			for s in sites:
				var d := Vector2(x - s.x, z - s.z).length()
				m = maxf(m, 1.0 - smoothstep(6.5, 9.0, d))
			img.set_pixel(i, j, Color(hs[j * n + i], m, 0.0))
	terrain_tex = ImageTexture.create_from_image(img)

func _grass_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/hills/grass.gdshader")
	var clump := FastNoiseLite.new()
	clump.noise_type = FastNoiseLite.TYPE_CELLULAR
	var clump_tex := NoiseTexture2D.new()
	clump_tex.width = 256
	clump_tex.height = 256
	clump_tex.seamless = true
	clump_tex.noise = clump
	var wind := FastNoiseLite.new()
	wind.noise_type = FastNoiseLite.TYPE_PERLIN
	wind.frequency = 0.0275
	wind.fractal_gain = 0.1
	wind.domain_warp_enabled = true
	wind.domain_warp_amplitude = 20.0
	wind.domain_warp_frequency = 0.005
	var wind_tex := NoiseTexture2D.new()
	wind_tex.seamless = true
	wind_tex.noise = wind
	mat.set_shader_parameter("clump_noise", clump_tex)
	mat.set_shader_parameter("wind_noise", wind_tex)
	mat.set_shader_parameter("terrain_data", terrain_tex)
	mat.set_shader_parameter("terrain_size", SIZE)
	mat.set_shader_parameter("clumping_factor", 0.5)
	mat.set_shader_parameter("wind_speed", 1.0)
	return mat

func _grass_lod(density: float, mesh: Mesh) -> MultiMesh:
	var row := ceili(TILE_SIZE * lerpf(0.0, 10.0, density))
	var mm := MultiMesh.new()
	mm.mesh = mesh
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = row * row
	# blades are lifted onto the terrain in the shader, so the culling box must span the height range
	mm.custom_aabb = AABB(Vector3(-TILE_SIZE, -40.0, -TILE_SIZE), Vector3(TILE_SIZE * 2.0, 100.0, TILE_SIZE * 2.0))
	var jitter := TILE_SIZE / float(row) * 0.5 * 0.9
	for i in row:
		for j in row:
			var p := Vector3(i / float(row) - 0.5, 0.0, j / float(row) - 0.5) * TILE_SIZE
			p += Vector3(randf_range(-jitter, jitter), 0.0, randf_range(-jitter, jitter))
			mm.set_instance_transform(i + j * row, Transform3D(Basis(), p))
	return mm

func _build_grass() -> void:
	grass_mat = _grass_material()
	if grass_high == null:
		grass_high = load(GRASS_HIGH_PATH)
	if grass_low == null:
		grass_low = load(GRASS_LOW_PATH)
	var lods: Array[MultiMesh] = [
		_grass_lod(0.7, grass_high), _grass_lod(0.35, grass_high), _grass_lod(0.18, grass_low),
		_grass_lod(0.08, grass_low), _grass_lod(0.04, grass_low)]
	var r := int(GRASS_RADIUS)
	for i in range(-r, r, int(TILE_SIZE)):
		for j in range(-r, r, int(TILE_SIZE)):
			var pos := Vector3(i, 0.0, j)
			var dist := pos.length()
			if dist > GRASS_RADIUS:
				continue
			var inst := MultiMeshInstance3D.new()
			inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # grass shadow maps cost far too much
			inst.material_override = grass_mat
			inst.position = pos
			inst.extra_cull_margin = 1.0
			if dist < 10.0:
				inst.multimesh = lods[0]
			elif dist < 25.0:
				inst.multimesh = lods[1]
			elif dist < 45.0:
				inst.multimesh = lods[2]
			elif dist < 68.0:
				inst.multimesh = lods[3]
			else:
				inst.multimesh = lods[4]
			add_child(inst)
			grass_tiles.append([inst, pos])

func _physics_process(_dt: float) -> void:
	if player == null or grass_mat == null:
		return
	grass_mat.set_shader_parameter("player_position", player.global_position)
	# re-seat the LOD tiles whenever the player crosses into a new tile
	var t := Vector2i(floori((player.global_position.x + TILE_SIZE * 0.5) / TILE_SIZE),
			floori((player.global_position.z + TILE_SIZE * 0.5) / TILE_SIZE))
	if t != prev_tile:
		prev_tile = t
		var off := Vector3(t.x, 0.0, t.y) * TILE_SIZE
		for d in grass_tiles:
			d[0].global_position = d[1] + off

# ---- houses & castle ---------------------------------------------------------

func _mat(c: Color, rough := 0.85) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func _part(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi

func _box(sz: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = sz
	return b

func _house(pos: Vector3, yaw: float, wall_col: Color) -> void:
	var root := Node3D.new()
	root.position = pos
	root.rotation.y = yaw
	add_child(root)
	var wall := _mat(wall_col)
	var trim := _mat(Color(0.82, 0.78, 0.66))
	var roof := _mat(Color(0.2, 0.15, 0.11), 0.7)
	if glass_mat == null:
		glass_mat = _mat(Color(0.12, 0.17, 0.22), 0.15)
		glass_mat.emission = Color(1.0, 0.75, 0.4)
	var glass := glass_mat
	var w := randf_range(5.6, 7.0)
	var d := randf_range(6.5, 8.0)
	var hgt := randf_range(4.6, 5.6)
	_part(root, _box(Vector3(w + 0.8, 6.0, d + 0.8)), _mat(Color(0.34, 0.31, 0.27)), Vector3(0, -2.6, 0))   # stone plinth sunk into the pad
	_part(root, _box(Vector3(w, hgt, d)), wall, Vector3(0, 0.4 + hgt * 0.5, 0))
	var prism := PrismMesh.new()
	prism.size = Vector3(w + 1.2, w * 0.5, d + 1.2)
	_part(root, prism, roof, Vector3(0, 0.4 + hgt + w * 0.25, 0))
	# door and windows on the front (+Z) and both sides
	_part(root, _box(Vector3(1.1, 2.2, 0.16)), _mat(Color(0.75, 0.72, 0.62)), Vector3(0, 1.5, d * 0.5 + 0.02))
	for row in 2:
		var y := 1.9 + row * 2.2
		for sx in [-1.0, 1.0]:
			_part(root, _box(Vector3(1.0, 1.35, 0.14)), trim, Vector3(sx * w * 0.3, y, d * 0.5 + 0.02))
			_part(root, _box(Vector3(0.8, 1.15, 0.16)), glass, Vector3(sx * w * 0.3, y, d * 0.5 + 0.04))
			_part(root, _box(Vector3(0.14, 1.35, 1.0)), trim, Vector3(sx * (w * 0.5 + 0.02), y, 0))
			_part(root, _box(Vector3(0.16, 1.15, 0.8)), glass, Vector3(sx * (w * 0.5 + 0.04), y, 0))
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(w, hgt + w * 0.5, d)
	cs.shape = bs
	cs.position = Vector3(0, 0.4 + (hgt + w * 0.5) * 0.5, 0)
	body.add_child(cs)
	root.add_child(body)

func _build_houses() -> void:
	var palette := [Color(0.62, 0.4, 0.18), Color(0.7, 0.5, 0.24), Color(0.55, 0.36, 0.2), Color(0.66, 0.55, 0.32)]
	for i in sites.size():
		_house(sites[i], yaws[i], palette[i % palette.size()])

func _build_castle() -> void:
	var pos := Vector3(-30.0, 0.0, -300.0)
	pos.y = height(pos.x, pos.z) - 2.0
	var root := Node3D.new()
	root.position = pos
	root.scale = Vector3.ONE * 3.0
	add_child(root)
	var stone := _mat(Color(0.86, 0.8, 0.68))
	var roof := _mat(Color(0.5, 0.4, 0.34))
	_part(root, _box(Vector3(22, 12, 10)), stone, Vector3(0, 6, 0))
	_part(root, _box(Vector3(9, 22, 9)), stone, Vector3(0, 11, 0))
	for sx in [-1.0, 1.0]:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 3.0
		cyl.bottom_radius = 3.0
		cyl.height = 18.0
		_part(root, cyl, stone, Vector3(sx * 12.0, 9, 0))
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 3.8
		cone.height = 8.0
		_part(root, cone, roof, Vector3(sx * 12.0, 22, 0))
	var spire := CylinderMesh.new()
	spire.top_radius = 0.0
	spire.bottom_radius = 5.5
	spire.height = 12.0
	_part(root, spire, roof, Vector3(0, 28, 0))

func spawn_position() -> Vector3:
	return Vector3(spawn_xz.x, height(spawn_xz.x, spawn_xz.y) + 1.0, spawn_xz.y)

# ---- player & hint -----------------------------------------------------------

func _build_player() -> void:
	var p := CharacterBody3D.new()
	p.set_script(load("res://scripts/world/hills/hills_player.gd"))
	p.position = Vector3(spawn_xz.x, height(spawn_xz.x, spawn_xz.y) + 1.0, spawn_xz.y)
	add_child(p)
	player = p

func _build_hint() -> void:
	var layer := CanvasLayer.new()
	var l := Label.new()
	l.text = "WASD move  |  Shift sprint  |  Space jump  |  Esc release mouse"
	l.position = Vector2(16, 12)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	layer.add_child(l)
	add_child(layer)
