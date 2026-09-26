extends Node3D
## Rolling golden-hour hills: procedural terrain + road, cloud sky, wind grass, hilltop houses, distant castle.

const SIZE := 640.0
const RES := 320
const HOUSE_COUNT := 30
const GRASS_COUNT := 140000
const GRASS_RADIUS := 85.0
const SUN_DIR := Vector3(0.38, 0.27, -0.88)   # toward the sun; it sits low behind the far hills

var noise := FastNoiseLite.new()
var detail := FastNoiseLite.new()
var sites: Array[Vector3] = []               # x, terrain height, z of each house pad
var yaws: Array[float] = []
var spawn_xz := Vector2.ZERO

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
	spawn_xz = Vector2(road_x(40.0), 40.0)
	_pick_house_sites()
	_build_environment()
	_build_terrain()
	_build_grass()
	_build_houses()
	_build_castle()
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

# ---- environment: sky, sun, fog ----------------------------------------------

func _build_environment() -> void:
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/hills/sky.gdshader")
	sky_mat.set_shader_parameter("sun_dir", SUN_DIR.normalized())
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.9, 0.74, 0.5)
	env.fog_light_energy = 1.0
	env.fog_density = 0.0028
	env.fog_sun_scatter = 0.7
	env.fog_aerial_perspective = 0.45
	env.fog_sky_affect = 0.15
	env.ssao_enabled = true
	env.ssao_radius = 1.5
	env.ssao_intensity = 2.0
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.1
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.8, 0.52)
	sun.light_energy = 2.4
	sun.light_angular_distance = 0.6
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 320.0
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -SUN_DIR.normalized(), Vector3.UP)

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
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	add_child(body)

# ---- grass -------------------------------------------------------------------

func _tuft_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for b in 9:
		var ang := randf() * TAU
		var off := Vector3(randf_range(-0.16, 0.16), 0.0, randf_range(-0.16, 0.16))
		var side := Vector3(cos(ang), 0.0, sin(ang))
		var lean := Vector3(-side.z, 0.0, side.x) * randf_range(-0.1, 0.1)
		var h := randf_range(0.2, 0.42)
		var w := randf_range(0.016, 0.026)
		var base := verts.size()
		for t in [0.0, 0.55]:
			var wt: float = w * (1.0 - t * 0.7)
			var c: Vector3 = off + lean * t * t + Vector3.UP * h * t
			verts.append(c - side * wt)
			verts.append(c + side * wt)
			uvs.append(Vector2(0, t))
			uvs.append(Vector2(1, t))
		verts.append(off + lean + Vector3.UP * h)
		uvs.append(Vector2(0.5, 1.0))
		idx.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2, base + 2, base + 3, base + 4])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _build_grass() -> void:
	var mesh := _tuft_mesh()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/hills/grass.gdshader")
	mesh.surface_set_material(0, mat)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	var placed: Array[Transform3D] = []
	var colors: Array[Color] = []
	var tries := 0
	while placed.size() < GRASS_COUNT and tries < GRASS_COUNT * 2:
		tries += 1
		var r := GRASS_RADIUS * sqrt(randf())
		var a := randf() * TAU
		var x := spawn_xz.x + cos(a) * r
		var z := spawn_xz.y + sin(a) * r
		if road_mask(x, z) > 0.2:
			continue
		var skip := false
		for s in sites:
			if absf(s.x - x) < 6.0 and absf(s.z - z) < 6.0:
				skip = true
				break
		if skip:
			continue
		var sc := randf_range(0.8, 1.35)
		var basis := Basis(Vector3.UP, randf() * TAU).scaled(Vector3(sc, sc * randf_range(0.8, 1.3), sc))
		placed.append(Transform3D(basis, Vector3(x, height(x, z) - 0.03, z)))
		var v := randf_range(0.75, 1.15)
		colors.append(Color(v, v * randf_range(0.92, 1.05), v * randf_range(0.8, 1.0)))
	mm.instance_count = placed.size()
	for i in placed.size():
		mm.set_instance_transform(i, placed[i])
		mm.set_instance_color(i, colors[i])
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.visibility_range_end = GRASS_RADIUS + 12.0
	inst.visibility_range_end_margin = 10.0
	inst.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(inst)

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
	var glass := _mat(Color(0.12, 0.17, 0.22), 0.15)
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

# ---- player & hint -----------------------------------------------------------

func _build_player() -> void:
	var p := CharacterBody3D.new()
	p.set_script(load("res://scripts/world/hills/hills_player.gd"))
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
