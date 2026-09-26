extends "res://scripts/world/level/level_data.gd"
## THE LEVEL, layer 2: what it is made of. Wallpapered walls (one MultiMesh per wall height), carpet and
## glossy tile floors, the ceiling with its drops where two heights meet, pit shafts falling away into
## the dark, and grime on the carpet. All built once from the grid when the level loads.

var wall_mat: StandardMaterial3D
var tall_wall_mat: StandardMaterial3D

func build_geometry() -> void:
	wall_mat = _wall_material("wall", WALL_H, true)
	tall_wall_mat = _wall_material("wall_tall", TALL_H, true)
	_build_surfaces()
	_build_walls()
	_build_ceiling_steps()
	_build_pit_shafts()
	_build_dirt()

# ---------------------------------------------------------------- materials
func _mat(tex: String, per_metre: Vector3, tint := Color.WHITE) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://textures/%s_color.webp" % tex)
	m.albedo_color = tint
	m.normal_enabled = true
	m.normal_texture = load("res://textures/%s_normal.webp" % tex)
	m.roughness = 0.88
	m.roughness_texture = load("res://textures/%s_rough.webp" % tex)
	m.ao_enabled = true
	m.ao_texture = load("res://textures/%s_ao.webp" % tex)
	m.ao_light_affect = 0.85
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = per_metre
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.metallic_specular = 0.35
	return m

# Wallpaper: generated at wall height (baseboard, grime, ceiling contact shadow baked in).
# `world`: triplanar world-space UVs for the wall boxes; otherwise explicit UVs (ceiling drops).
func _wall_material(prefix: String, height: float, world: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://textures/%s_color.png" % prefix)
	m.albedo_color = Color(1.0, 0.98, 0.88)
	m.normal_enabled = true
	m.normal_texture = load("res://textures/%s_normal.png" % prefix)
	m.normal_scale = 0.95
	m.roughness_texture = load("res://textures/%s_rough.png" % prefix)
	m.roughness = 0.95
	m.ao_enabled = true
	m.ao_texture = load("res://textures/%s_ao.png" % prefix)
	m.ao_light_affect = 0.85
	m.metallic_specular = 0.28
	if world:
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3(1.0 / 2.25, -1.0 / height, 1.0 / 2.25)
		m.uv1_offset = Vector3(0, 1, 0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.texture_repeat = true
	return m

func _cell_surface(cells: Array, height_fn: Callable, mat: Material, flip: bool, priority := 0) -> MeshInstance3D:
	# One quad per cell in a single mesh (the bulk of the level is just floor/ceiling)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := CELL / 2.0
	var n := Vector3.DOWN if flip else Vector3.UP
	for c in cells:
		var cx: float = c.x * CELL
		var cz: float = c.y * CELL
		var yy: float = height_fn.call(c)
		var a := Vector3(cx - h, yy, cz - h)
		var b := Vector3(cx + h, yy, cz - h)
		var d := Vector3(cx + h, yy, cz + h)
		var e := Vector3(cx - h, yy, cz + h)
		var quad := [a, d, b, a, e, d] if flip else [a, b, d, a, d, e]
		for v in quad:
			st.set_normal(n)
			st.add_vertex(v)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.material_override.render_priority = priority
	add_child(mi)
	return mi

func _build_surfaces() -> void:
	var carpet_cells := []
	var tile_cells := []
	var ceil_cells := []
	var floor_cells := []
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			ceil_cells.append(c)
			if pits.has(c): continue
			floor_cells.append(c)
			if tiles.has(c): tile_cells.append(c)
			else: carpet_cells.append(c)
	var carpet := _mat("l0_carpet", Vector3(0.5, 0.5, 0.5), Color(1.0, 0.94, 0.75))
	var ceil_m := _mat("l0_ceiling", Vector3(0.278, 0.278, 0.278), Color(0.89, 0.85, 0.74))
	_cell_surface(carpet_cells, func(_c): return 0.0, carpet, false)
	_cell_surface(ceil_cells, func(c): return ceiling_height(c), ceil_m, true)

	# Polished commercial tile rooms: high-res PBR vinyl composite tiles with wax sheen and normal-mapped bevels
	if not tile_cells.is_empty():
		var tm := StandardMaterial3D.new()
		tm.albedo_texture = load("res://textures/tiles_color.png")
		tm.normal_enabled = true
		tm.normal_texture = load("res://textures/tiles_normal.png")
		tm.normal_scale = 1.0
		tm.roughness = 1.0
		tm.roughness_texture = load("res://textures/tiles_rough.png")
		tm.ao_enabled = true
		tm.ao_texture = load("res://textures/tiles_ao.png")
		tm.ao_light_affect = 0.85
		tm.metallic = 0.02
		tm.metallic_specular = 0.55
		tm.uv1_triplanar = true
		tm.uv1_world_triplanar = true
		tm.uv1_scale = Vector3(1.0 / 2.25, 1.0 / 2.25, 1.0 / 2.25)
		tm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		_cell_surface(tile_cells, func(_c): return 0.0, tm, false, 0)

	# Floor collision: one thin box per cell (pits stay open)
	var body := StaticBody3D.new()
	add_child(body)
	for c in floor_cells:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(CELL, 0.4, CELL)
		cs.shape = bs
		cs.position = Vector3(c.x * CELL, -0.2, c.y * CELL)
		body.add_child(cs)

const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

func _build_walls() -> void:
	var groups := {WALL_H: [], TALL_H: []}
	for c: Vector2i in walls.keys():
		var exposed := false
		var near_tall := false
		for n: Vector2i in DIRS:
			if not walls.has(c + n): exposed = true
			if tall.has(c + n): near_tall = true
		if exposed:
			groups[TALL_H if near_tall else WALL_H].append(c)
	var mats := {WALL_H: wall_mat, TALL_H: tall_wall_mat}
	var body := StaticBody3D.new()
	add_child(body)
	for height in groups.keys():
		var list: Array = groups[height]
		if list.is_empty(): continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var box := BoxMesh.new()
		box.size = Vector3(CELL, height, CELL)
		mm.mesh = box
		mm.instance_count = list.size()
		for i in list.size():
			var c: Vector2i = list[i]
			mm.set_instance_transform(i, Transform3D(Basis(), Vector3(c.x * CELL, height / 2.0, c.y * CELL)))
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = Vector3(CELL, height, CELL)
			cs.shape = bs
			cs.position = Vector3(c.x * CELL, height / 2.0, c.y * CELL)
			body.add_child(cs)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mats[height]
		add_child(mmi)

# Where two open cells have different ceiling heights, a wallpapered drop closes the gap
# (like a drywall bulkhead) with a trim strip along its bottom edge.
func _build_ceiling_steps() -> void:
	var batches := [
		{"height": WALL_H, "st": SurfaceTool.new(), "n": 0},
		{"height": TALL_H, "st": SurfaceTool.new(), "n": 0}
	]
	for b in batches: (b.st as SurfaceTool).begin(Mesh.PRIMITIVE_TRIANGLES)
	var trims: Array = []
	var half := CELL / 2.0
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			if walls.has(c): continue
			for dv: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var nb: Vector2i = c + dv
				if walls.has(nb): continue
				var a := ceiling_height(c)
				var b2 := ceiling_height(nb)
				if a == b2: continue
				var lo := minf(a, b2)
				var hi := maxf(a, b2)
				var batch: Dictionary = batches[1] if hi > WALL_H else batches[0]
				var st: SurfaceTool = batch.st
				var bx := x * CELL + dv.x * half
				var bz := z * CELL + dv.y * half
				var ax := dv.y * half
				var az := dv.x * half
				var hgt: float = batch.height
				var u0 := ((z if dv.x != 0 else x) - 0.5) * 2.0
				var v_lo := 1.0 - lo / hgt
				var v_hi := 1.0 - hi / hgt
				var pts := [
					[Vector3(bx - ax, lo, bz - az), Vector2(u0, v_lo)],
					[Vector3(bx + ax, lo, bz + az), Vector2(u0 + 2.0, v_lo)],
					[Vector3(bx + ax, hi, bz + az), Vector2(u0 + 2.0, v_hi)],
					[Vector3(bx - ax, hi, bz - az), Vector2(u0, v_hi)]]
				var nrm := Vector3(dv.x, 0, dv.y)
				for i in [0, 1, 2, 0, 2, 3]:
					st.set_normal(nrm)
					st.set_uv(pts[i][1])
					st.add_vertex(pts[i][0])
				batch.n += 1
				var side := 1.0 if b2 > a else -1.0
				trims.append({"x": bx + dv.x * side * 0.03, "z": bz + dv.y * side * 0.03, "y": lo - 0.05, "along_x": dv.x == 0})
	for i in batches.size():
		var b: Dictionary = batches[i]
		if b.n == 0: continue
		var st: SurfaceTool = b.st
		st.generate_tangents()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		var m := _wall_material("wall" if i == 0 else "wall_tall", b.height, false)
		m.cull_mode = BaseMaterial3D.CULL_DISABLED    # seen from whichever cell is taller
		mi.material_override = m
		add_child(mi)
	if trims.is_empty(): return
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color("cfc6a8")
	tm.roughness = 0.75
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()
	mm.instance_count = trims.size()
	for i in trims.size():
		var t: Dictionary = trims[i]
		var sc := Vector3(CELL if t.along_x else 0.1, 0.1, 0.1 if t.along_x else CELL)
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(sc), Vector3(t.x, t.y, t.z)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = tm
	add_child(mmi)

# Pit shafts: the cut edge of the floor slab, then raw concrete walls falling away into
# blackness (vertex colours darken with depth), and a black bottom.
func _build_pit_shafts() -> void:
	if pits.is_empty(): return
	var H := CELL / 2.0
	var levels := [0.0, -0.32, -1.1, -2.4, -4.4, -7.0, -10.4, -PIT_DEPTH]
	var shade: Array[float] = []
	for i in levels.size():
		shade.append(1.25 if i == 0 else (1.1 if i == 1 else maxf(0.0, exp(levels[i] * 0.4) * 0.9)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wall := func(ax: float, az: float, bx: float, bz: float) -> void:
		var ln := Vector2(bx - ax, bz - az).length()
		var nrm := Vector3(-(bz - az), 0, bx - ax).normalized()
		for i in levels.size() - 1:
			var y0: float = levels[i]
			var y1: float = levels[i + 1]
			var c0 := Color(shade[i], shade[i], shade[i] * 0.95)
			var c1 := Color(shade[i + 1], shade[i + 1], shade[i + 1] * 0.95)
			var q := [
				[Vector3(ax, y0, az), c0, Vector2(0, -y0 * 0.5)],
				[Vector3(bx, y0, bz), c0, Vector2(ln * 0.5, -y0 * 0.5)],
				[Vector3(bx, y1, bz), c1, Vector2(ln * 0.5, -y1 * 0.5)],
				[Vector3(ax, y1, az), c1, Vector2(0, -y1 * 0.5)]]
			for k in [0, 1, 2, 0, 2, 3]:
				st.set_normal(nrm)
				st.set_color(q[k][1])
				st.set_uv(q[k][2])
				st.add_vertex(q[k][0])
	var cells: Array = []
	for c: Vector2i in pits.keys():
		cells.append(c)
		var x := c.x * CELL
		var z := c.y * CELL
		if not pits.has(c + Vector2i(-1, 0)): wall.call(x - H, z - H, x - H, z + H)
		if not pits.has(c + Vector2i(1, 0)): wall.call(x + H, z - H, x + H, z + H)
		if not pits.has(c + Vector2i(0, -1)): wall.call(x - H, z - H, x + H, z - H)
		if not pits.has(c + Vector2i(0, 1)): wall.call(x - H, z + H, x + H, z + H)
	st.generate_tangents()
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://textures/concrete_color.jpg")
	m.normal_enabled = true
	m.normal_texture = load("res://textures/concrete_normal.jpg")
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = m
	add_child(mi)
	var black := StandardMaterial3D.new()
	black.albedo_color = Color.BLACK
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cell_surface(cells, func(_c): return -PIT_DEPTH, black, false)

# Grime clusters: the painted 'grime' zone plus ~6% scattered stains, kept off the spawn room
func _build_dirt() -> void:
	var dirty: Array[Vector2i] = []
	var seen := {}
	var add := func(x: int, z: int) -> void:
		var c := Vector2i(x, z)
		if seen.has(c) or walls.has(c) or pits.has(c) or bright.has(c): return
		if Vector2(x * CELL - spawn_pos.x, z * CELL - spawn_pos.z).length() < 3.0 * CELL: return
		seen[c] = true
		dirty.append(c)
	var zones: Dictionary = level_data.get("zones", {})
	for c in zones.get("grime", []): add.call(c[0], c[1])
	for x in range(2, size - 2):
		for z in range(2, size - 2):
			if not walls.has(Vector2i(x, z)) and rng.randf() < 0.06: add.call(x, z)
	if dirty.is_empty(): return
	var wet_cells: Array[Vector2i] = []
	for c in dirty:
		if rng.randf() < 0.3: wet_cells.append(c)
	_grime_layer(dirty, false, CELL * 1.5, 0.008)
	_grime_layer(dirty, false, CELL * 1.1, 0.009)
	_grime_layer(wet_cells, true, CELL * 0.9, 0.010)

func _grime_layer(cells: Array, wet: bool, sz: float, y: float) -> void:
	if cells.is_empty(): return
	# One mesh per texture variant so every stain isn't identical
	var variants: Array = []
	for i in 4:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		variants.append(st)
	var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for c in cells:
		var x0: float = c.x * CELL + (rng.randf() - 0.5) * CELL * 0.5
		var z0: float = c.y * CELL + (rng.randf() - 0.5) * CELL * 0.5
		var r := (sz * (0.7 + rng.randf() * 0.6)) / 2.0
		var a := rng.randf() * TAU
		var ca := cos(a)
		var sa := sin(a)
		var st: SurfaceTool = variants[rng.randi() % 4]
		for k in [0, 3, 2, 0, 2, 1]:
			var s: Vector2 = corners[k]
			st.set_normal(Vector3.UP)
			st.set_uv(uvs[k])
			st.add_vertex(Vector3(x0 + (s.x * ca - s.y * sa) * r, y, z0 + (s.x * sa + s.y * ca) * r))
	for i in 4:
		var m := StandardMaterial3D.new()
		m.albedo_texture = load("res://textures/grime_%s_%d.png" % ["wet" if wet else "dry", i])
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		m.render_priority = 1
		if wet:
			m.albedo_color = Color("3a3320")
			m.roughness = 0.08
			m.metallic = 0.2
		else:
			m.roughness = 1.0
		var mi := MeshInstance3D.new()
		mi.mesh = (variants[i] as SurfaceTool).commit()
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
