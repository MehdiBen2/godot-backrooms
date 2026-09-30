extends Node3D
## Rolling golden-hour hills: procedural terrain + road, cloud sky, hilltop houses, distant castle.

const MMBuffer := preload("res://scripts/World/mm_buffer.gd")
const SIZE := 640.0
const RES := 320
const CHUNK := 80.0                         # terrain chunk edge: one mesh per chunk, so the ones outside the view are culled
const LOD_STEP := 4                         # far chunks keep every 4th grid line: 16x fewer triangles
const LOD_NEAR := 180.0                     # metres from a chunk's centre where it swaps to the coarse mesh
const OCC_STEP := 8                         # occluder grid spacing, in terrain cells
const HOUSE_CELL := 160.0                   # houses are batched per patch this size, so a patch off-screen is culled
const HOUSE_COUNT := 30
const GRASS_DENSITY := 1.2                  # blade roots per square metre, before the grass/road/house filter
const GRASS_RANGE := 70.0                   # blades fade out beyond this distance: cheap since the ground texture reads fine bare
const GRASS_HEIGHT := 0.55
const GRASS_WIDTH := 0.08
const DAY_SECONDS := 720.0                    # one full 24 h day/night cycle in real seconds
const START_HOUR := 11.0
const TIME_STEP := 0.1                        # the sky / light are refreshed this often (seconds), not every frame

var noise := FastNoiseLite.new()
var detail := FastNoiseLite.new()
var sites: Array[Vector3] = []               # x, terrain height, z of each house pad
var yaws: Array[float] = []
var spawn_xz := Vector2.ZERO
var terrain_mat: ShaderMaterial
var grass_mat: ShaderMaterial
var _batches := {}                            # "material/cell" -> {st: SurfaceTool, n: int, shadow: bool, mat}, while houses are built
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
	_build_houses()
	_build_castle()
	_build_grass()
	_commit_batches()
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
	# Gfx.apply_scene() would otherwise switch on the preset's SSAO / SSIL / SSR / volumetric fog here
	# (on any settings change made while in the hills): all tuned for small rooms, not a 1 km view
	env.set_meta("gfx_keep", true)
	if standalone:
		var we := WorldEnvironment.new()
		we.environment = env
		add_child(we)

	sun = DirectionalLight3D.new()
	# 0 keeps the sun on plain filtered shadows: any angular distance switches on PCSS, a blocker
	# search per pixel per split over the whole screen, the priciest pass here at High / Ultra
	sun.light_angular_distance = 0.0
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
	_build_terrain_material()
	# Chunked, so Godot skips a chunk that is off-screen (frustum culling) or behind a hill (the
	# occluder below), and each chunk swaps to a coarse copy with distance (visibility-range LOD).
	var chunks := int(SIZE / CHUNK)
	var per := RES / chunks                       # grid cells per chunk edge
	var body := StaticBody3D.new()
	add_child(body)
	for cj in chunks:
		for ci in chunks:
			_terrain_chunk(verts, norms, cols, n, ci * per, cj * per, per, body)
	_build_terrain_occluder(hs, n, cell, half)

func _build_terrain_material() -> void:
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/hills/terrain.gdshader")
	var tex := "res://textures/hills/%s/%s_%s.jpg"
	var sets := {"turf": "Grass001_1K-JPG", "path_a": "Ground085_1K-JPG", "path_b": "Ground109_1K-JPG"}
	for slot in sets:
		var folder: String = sets[slot]
		terrain_mat.set_shader_parameter(slot + "_color", load(tex % [folder, folder, "Color"]))
		terrain_mat.set_shader_parameter(slot + "_rough", load(tex % [folder, folder, "Roughness"]))
		terrain_mat.set_shader_parameter(slot + "_ao", load(tex % [folder, folder, "AmbientOcclusion"]))

## One terrain chunk: a full-detail mesh (also its collision, so walking is unchanged) and a coarse
## one for past LOD_NEAR. The detail mesh names the coarse one as its visibility parent (Godot's HLOD
## setup), so exactly one of the two is drawn and the swap hinges on a single distance: no gaps, no
## overlap. Each sits at its chunk's centre, so that distance is measured from the right place.
func _terrain_chunk(v: PackedVector3Array, nr: PackedVector3Array, co: PackedColorArray, n: int,
		i0: int, j0: int, per: int, body: StaticBody3D) -> void:
	var mid := v[(j0 + per / 2) * n + i0 + per / 2]
	var origin := Vector3(mid.x, 0.0, mid.z)
	var coarse := _chunk_instance(_grid_mesh(v, nr, co, n, i0, j0, per, LOD_STEP, origin, 4.0), origin)
	coarse.visibility_range_begin = LOD_NEAR
	coarse.visibility_range_begin_margin = 8.0     # hysteresis: no flicker when standing on the line
	var detail_mesh := _grid_mesh(v, nr, co, n, i0, j0, per, 1, origin, 0.0)
	var detail_inst := _chunk_instance(detail_mesh, origin)
	detail_inst.visibility_parent = detail_inst.get_path_to(coarse)
	var cs := CollisionShape3D.new()
	cs.shape = detail_mesh.create_trimesh_shape()
	cs.position = origin
	body.add_child(cs)

func _chunk_instance(mesh: ArrayMesh, origin: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = origin
	add_child(mi)
	return mi

## A per x per cell patch of the grid, sampled every `step` cells, local to `origin`. `skirt` > 0 hangs
## a wall that deep from the border: a coarse patch's edge only matches every `step`-th vertex of a
## detailed neighbour, and the skirt covers the thin cracks that leaves.
func _grid_mesh(v: PackedVector3Array, nr: PackedVector3Array, co: PackedColorArray, n: int,
		i0: int, j0: int, per: int, step: int, origin: Vector3, skirt: float) -> ArrayMesh:
	var cells := per / step
	var side := cells + 1
	var lv := PackedVector3Array()
	var ln := PackedVector3Array()
	var lc := PackedColorArray()
	lv.resize(side * side)
	ln.resize(side * side)
	lc.resize(side * side)
	for j in side:
		for i in side:
			var k := (j0 + j * step) * n + i0 + i * step
			lv[j * side + i] = v[k] - origin
			ln[j * side + i] = nr[k]
			lc[j * side + i] = co[k]
	var li := PackedInt32Array()
	li.resize(cells * cells * 6)
	var k := 0
	for j in cells:
		for i in cells:
			var a := j * side + i
			li[k] = a
			li[k + 1] = a + 1
			li[k + 2] = a + side
			li[k + 3] = a + 1
			li[k + 4] = a + side + 1
			li[k + 5] = a + side
			k += 6
	if skirt > 0.0:
		# the border, walked all the way round and closed: top row, right column, bottom row, left column
		var ring: Array[int] = []
		for i in side:
			ring.append(i)
		for j in range(1, side):
			ring.append(j * side + cells)
		for i in range(cells - 1, -1, -1):
			ring.append(cells * side + i)
		for j in range(cells - 1, -1, -1):
			ring.append(j * side)
		var base := lv.size()
		for r in ring:
			lv.append(lv[r] + Vector3.DOWN * skirt)
			ln.append(ln[r])
			lc.append(lc[r])
		for s in ring.size() - 1:
			var t0 := ring[s]
			var t1 := ring[s + 1]
			var b0 := base + s
			var b1 := b0 + 1
			# both windings: the skirt can be seen from either side
			li.append_array(PackedInt32Array([t0, t1, b0, t1, b1, b0, t0, b0, t1, t1, b0, b1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lv
	arrays[Mesh.ARRAY_NORMAL] = ln
	arrays[Mesh.ARRAY_COLOR] = lc
	arrays[Mesh.ARRAY_INDEX] = li
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, terrain_mat)
	return mesh

## Hills hide what is behind them: an occluder (a coarse copy of the ground) lets Godot skip every
## chunk and house it covers. Each vertex takes the lowest ground within one occluder cell around it
## and sits a bit under that, so the occluder never rises above the real surface and hides something
## that is actually in view.
func _build_terrain_occluder(hs: PackedFloat32Array, n: int, cell: float, half: float) -> void:
	var cells := RES / OCC_STEP
	var side := cells + 1
	# min filter done as a row pass then a column pass
	var rowmin := PackedFloat32Array()
	rowmin.resize(n * side)
	for j in n:
		for c in side:
			var low := INF
			for i in range(maxi((c - 1) * OCC_STEP, 0), mini((c + 1) * OCC_STEP, n - 1) + 1):
				low = minf(low, hs[j * n + i])
			rowmin[j * side + c] = low
	var verts := PackedVector3Array()
	verts.resize(side * side)
	for r in side:
		for c in side:
			var low := INF
			for j in range(maxi((r - 1) * OCC_STEP, 0), mini((r + 1) * OCC_STEP, n - 1) + 1):
				low = minf(low, rowmin[j * side + c])
			verts[r * side + c] = Vector3(c * OCC_STEP * cell - half, low - 0.5, r * OCC_STEP * cell - half)
	var idx := PackedInt32Array()
	for r in cells:
		for c in cells:
			var a := r * side + c
			idx.append_array(PackedInt32Array([a, a + 1, a + side, a + 1, a + side + 1, a + side]))
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	var oi := OccluderInstance3D.new()
	oi.occluder = occ
	add_child(oi)

# ---- grass blades -------------------------------------------------------------

## A tapered blade strip, base at y=0, tip at y=`height_m`: UV.y is the height factor the wind
## shader sways and stretches by.
func _blade_mesh(width: float, height_m: float, segs: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for s in segs + 1:
		var t := float(s) / segs
		var w := width * 0.5 * (1.0 - t)
		verts.append(Vector3(-w, height_m * t, 0.0))
		verts.append(Vector3(w, height_m * t, 0.0))
		norms.append(Vector3.BACK)
		norms.append(Vector3.BACK)
		uvs.append(Vector2(0.0, t))
		uvs.append(Vector2(1.0, t))
	for s in segs:
		var a := s * 2
		idx.append_array(PackedInt32Array([a, a + 1, a + 2, a + 1, a + 3, a + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _grass_noise_tex(seed_val: int, freq: float) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.seed = seed_val
	n.frequency = freq
	var t := NoiseTexture2D.new()
	t.width = 256
	t.height = 256
	t.seamless = true
	t.noise = n
	return t

func _build_grass_material() -> void:
	grass_mat = ShaderMaterial.new()
	grass_mat.shader = load("res://shaders/hills/grass.gdshader")
	grass_mat.set_shader_parameter("bottom_color", Color(0.1, 0.2, 0.05))
	grass_mat.set_shader_parameter("top_color", Color(0.42, 0.5, 0.16))
	grass_mat.set_shader_parameter("color_variation_1", Color(0.16, 0.28, 0.07))
	grass_mat.set_shader_parameter("color_variation_2", Color(0.5, 0.45, 0.2))
	grass_mat.set_shader_parameter("noise_variation_1", _grass_noise_tex(101, 0.02))
	grass_mat.set_shader_parameter("noise_variation_2", _grass_noise_tex(202, 0.035))
	grass_mat.set_shader_parameter("wind_noise", _grass_noise_tex(303, 0.015))
	grass_mat.set_shader_parameter("Noise1Scale", 12.0)
	grass_mat.set_shader_parameter("Noise2Scale", 18.0)
	grass_mat.set_shader_parameter("windNoiseScale", 25.0)

## Grass blades, chunked like the terrain so a chunk off-screen or beyond GRASS_RANGE is culled.
## Only sampled where surface_at() says "grass" and clear of the house pads.
func _build_grass() -> void:
	_build_grass_material()
	var blade := _blade_mesh(GRASS_WIDTH, GRASS_HEIGHT, 3)
	var chunks := int(SIZE / CHUNK)
	var half := SIZE * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260927
	for cj in chunks:
		for ci in chunks:
			var cx := ci * CHUNK - half + CHUNK * 0.5
			var cz := cj * CHUNK - half + CHUNK * 0.5
			_grass_chunk(blade, cx, cz, rng)

func _grass_chunk(blade: ArrayMesh, cx: float, cz: float, rng: RandomNumberGenerator) -> void:
	var count := int(CHUNK * CHUNK * GRASS_DENSITY)
	var xforms: Array[Transform3D] = []
	for i in count:
		var x := cx + rng.randf_range(-CHUNK * 0.5, CHUNK * 0.5)
		var z := cz + rng.randf_range(-CHUNK * 0.5, CHUNK * 0.5)
		if road_mask(x, z) > 0.4:
			continue
		var near_house := false
		for s in sites:
			if Vector2(x - s.x, z - s.z).length() < 9.0:
				near_house = true
				break
		if near_house:
			continue
		var y := height(x, z)
		var rot := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.75, 1.3))
		xforms.append(Transform3D(rot, Vector3(x, y, z)))
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = blade
	mm.instance_count = xforms.size()
	var buf := MMBuffer.alloc(mm)
	for i in xforms.size():
		MMBuffer.put(buf, i * 12, xforms[i])
	mm.buffer = buf
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = grass_mat
	mi.visibility_range_end = GRASS_RANGE
	mi.visibility_range_end_margin = 10.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

# ---- houses & castle ---------------------------------------------------------

func _mat(c: Color, rough := 0.85) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func _box(sz: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = sz
	return b

## House parts are folded into one batch per material and per HOUSE_CELL patch of ground instead of
## becoming a node each: 30 houses x ~17 parts was ~500 draw calls for a few thousand triangles. One
## batch per material alone would span the whole map and never be culled; per patch, the houses
## behind you or behind a hill are skipped. Trim and glass also stay out of the shadow pass.
func _stash(mesh: Mesh, mat: Material, xform: Transform3D, shadow := true) -> void:
	var key := "%d/%d/%d" % [mat.get_instance_id(), floori(xform.origin.x / HOUSE_CELL), floori(xform.origin.z / HOUSE_CELL)]
	if not _batches.has(key):
		var fresh := SurfaceTool.new()
		fresh.begin(Mesh.PRIMITIVE_TRIANGLES)
		_batches[key] = {"st": fresh, "n": 0, "shadow": shadow, "mat": mat}
	var b: Dictionary = _batches[key]
	var st: SurfaceTool = b.st
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nr: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var base: int = b.n
		for i in v.size():
			st.set_normal((xform.basis * nr[i]).normalized())
			st.add_vertex(xform * v[i])
		b.n = base + v.size()
		if idx.is_empty():
			for i in v.size():
				st.add_index(base + i)
		else:
			for i in idx.size():
				st.add_index(base + idx[i])

## Every batch collected since the last commit, as one node per material per patch.
func _commit_batches() -> void:
	for key in _batches:
		var b: Dictionary = _batches[key]
		if int(b.n) == 0:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = (b.st as SurfaceTool).commit()
		mi.material_override = b.mat
		if not b.shadow:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	_batches = {}

func _house(pos: Vector3, yaw: float, mats: Dictionary) -> void:
	var xform := Transform3D(Basis(Vector3.UP, yaw), pos)
	var w := randf_range(5.6, 7.0)
	var d := randf_range(6.5, 8.0)
	var hgt := randf_range(4.6, 5.6)
	_stash(_box(Vector3(w + 0.8, 6.0, d + 0.8)), mats.plinth, xform * Transform3D(Basis(), Vector3(0, -2.6, 0)))   # stone plinth sunk into the pad
	_stash(_box(Vector3(w, hgt, d)), mats.wall, xform * Transform3D(Basis(), Vector3(0, 0.4 + hgt * 0.5, 0)))
	var prism := PrismMesh.new()
	prism.size = Vector3(w + 1.2, w * 0.5, d + 1.2)
	_stash(prism, mats.roof, xform * Transform3D(Basis(), Vector3(0, 0.4 + hgt + w * 0.25, 0)))
	# door and windows on the front (+Z) and both sides
	_stash(_box(Vector3(1.1, 2.2, 0.16)), mats.door, xform * Transform3D(Basis(), Vector3(0, 1.5, d * 0.5 + 0.02)))
	for row in 2:
		var y := 1.9 + row * 2.2
		for sx in [-1.0, 1.0]:
			_stash(_box(Vector3(1.0, 1.35, 0.14)), mats.trim, xform * Transform3D(Basis(), Vector3(sx * w * 0.3, y, d * 0.5 + 0.02)), false)
			_stash(_box(Vector3(0.8, 1.15, 0.16)), mats.glass, xform * Transform3D(Basis(), Vector3(sx * w * 0.3, y, d * 0.5 + 0.04)), false)
			_stash(_box(Vector3(0.14, 1.35, 1.0)), mats.trim, xform * Transform3D(Basis(), Vector3(sx * (w * 0.5 + 0.02), y, 0)), false)
			_stash(_box(Vector3(0.16, 1.15, 0.8)), mats.glass, xform * Transform3D(Basis(), Vector3(sx * (w * 0.5 + 0.04), y, 0)), false)
	var root := Node3D.new()
	root.position = pos
	root.rotation.y = yaw
	add_child(root)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(w, hgt + w * 0.5, d)
	cs.shape = bs
	cs.position = Vector3(0, 0.4 + (hgt + w * 0.5) * 0.5, 0)
	body.add_child(cs)
	root.add_child(body)

## One material per look, shared by every house: the batch merge only works if the houses actually
## use the same Material objects.
func _build_houses() -> void:
	var palette := [Color(0.62, 0.4, 0.18), Color(0.7, 0.5, 0.24), Color(0.55, 0.36, 0.2), Color(0.66, 0.55, 0.32)]
	if glass_mat == null:
		glass_mat = _mat(Color(0.12, 0.17, 0.22), 0.15)
		glass_mat.emission = Color(1.0, 0.75, 0.4)
	var common := {"trim": _mat(Color(0.82, 0.78, 0.66)), "roof": _mat(Color(0.2, 0.15, 0.11), 0.7),
		"plinth": _mat(Color(0.34, 0.31, 0.27)), "door": _mat(Color(0.75, 0.72, 0.62)), "glass": glass_mat}
	for i in sites.size():
		var mats := common.duplicate()
		mats.wall = _mat(palette[i % palette.size()])
		_house(sites[i], yaws[i], mats)

func _build_castle() -> void:
	var pos := Vector3(-30.0, 0.0, -300.0)
	pos.y = height(pos.x, pos.z) - 2.0
	var xform := Transform3D(Basis.from_scale(Vector3.ONE * 3.0), pos)
	var stone := _mat(Color(0.86, 0.8, 0.68))
	var roof := _mat(Color(0.5, 0.4, 0.34))
	_stash(_box(Vector3(22, 12, 10)), stone, xform * Transform3D(Basis(), Vector3(0, 6, 0)))
	_stash(_box(Vector3(9, 22, 9)), stone, xform * Transform3D(Basis(), Vector3(0, 11, 0)))
	for sx in [-1.0, 1.0]:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 3.0
		cyl.bottom_radius = 3.0
		cyl.height = 18.0
		_stash(cyl, stone, xform * Transform3D(Basis(), Vector3(sx * 12.0, 9, 0)))
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 3.8
		cone.height = 8.0
		_stash(cone, roof, xform * Transform3D(Basis(), Vector3(sx * 12.0, 22, 0)))
	var spire := CylinderMesh.new()
	spire.top_radius = 0.0
	spire.bottom_radius = 5.5
	spire.height = 12.0
	_stash(spire, roof, xform * Transform3D(Basis(), Vector3(0, 28, 0)))

func spawn_position() -> Vector3:
	return Vector3(spawn_xz.x, height(spawn_xz.x, spawn_xz.y) + 1.0, spawn_xz.y)

# ---- player & hint -----------------------------------------------------------

func _build_player() -> void:
	var p := CharacterBody3D.new()
	p.set_script(load("res://scripts/World/hills/hills_player.gd"))
	p.position = Vector3(spawn_xz.x, height(spawn_xz.x, spawn_xz.y) + 1.0, spawn_xz.y)
	add_child(p)

func _build_hint() -> void:
	var layer := CanvasLayer.new()
	var l := Label.new()
	l.text = "WASD move  |  Shift sprint  |  Space jump  |  Esc release mouse"
	l.position = Vector2(16, 12)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	layer.add_child(l)
	add_child(layer)
