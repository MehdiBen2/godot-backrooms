extends Node3D
## Builds a backrooms level from levels/levels.json (the same data the web game uses) and
## ports the web game's level.js: wallpapered walls, carpet / glossy tile floors, ceiling
## drops, pit shafts, floor grime, and the troffer light fixtures with their flicker model,
## the 8-light pool that follows the player, and the tube-light-driven fog.
## Grid rows are z, characters are x. '#' wall, '.' floor, 'O' pit.

signal fixture_event(fixture: Dictionary, restrike: bool)   # audio listens: arc pop / re-strike tick
signal slot_assigned(slot: int)                              # a light came into range (hum "notice")

const CELL := 4.5
const WALL_H := 5.4
const TALL_H := 10.8
const LOW_H := 2.3
const PIT_DEPTH := 14.0

# LIGHTING / ATMOSPHERE (config.js)
const LIGHT_RANGE := 20.0
const LIGHT_ENERGY := 2.4           # tuned for Godot 4 PBR lighting
const LIGHT_COLOR := Color(1.0, 0.953, 0.859)
const BURNT_CHANCE := 0.16
const FLICKER_CHANCE := 0.24
const POOL_SIZE := 8
const SELECT_RADIUS := 22.0
const FADE_START := 14.0
const LIT_DIFFUSER := Color(2.2, 2.1, 1.85)
const TOP_Y := 0.1432132             # troffer housing top, baked model coordinates
const FOG_DENSITY := 0.075
const FOG_LIT_SCALE := 0.5
const FOG_DARK_BOOST := 0.5
const AMBIENT_MIN := 0.3
const BOUNCE_RADIUS := 7.0
const BOUNCE_FULL := 1.3
const ADAPT := 1.6
const FOG_COLOR := Color("0f0b05")
const FOG_COLOR_DARK := Color("020201")

@export var level_index := 0

var size := 0
var walls := {}       # Vector2i -> true
var pits := {}
var tall := {}
var low := {}
var tiles := {}
var bright := {}
var dark := {}
var dim := {}
var flicker := {}
var spawn_pos := Vector3.ZERO
var level_data := {}
var level_meta := {}
var level_name := "LEVEL 0"
var player: Node3D
var rng := RandomNumberGenerator.new()

var wall_mat: StandardMaterial3D
var tall_wall_mat: StandardMaterial3D

func _ready() -> void:
	rng.seed = 1971
	var levels := read_index()
	Game.level_count = levels.size()
	level_index = clampi(Game.level_index, 0, levels.size() - 1)
	level_meta = levels[level_index]
	var d := read_level(level_meta)
	level_data = d
	_load(d)
	wall_mat = _wall_material("wall", WALL_H, true)
	tall_wall_mat = _wall_material("wall_tall", TALL_H, true)
	_build_surfaces()
	_build_walls()
	_build_ceiling_steps()
	_build_pit_shafts()
	_build_dirt()
	_place_fixtures()
	_build_fixture_meshes()
	_build_light_pool()
	_build_floor_reflections()
	_build_exit()

# ---------------------------------------------------------------- level files
# The same files the web game and tools/level_editor.py use: levels/levels.json is the playlist
# ([{id, name, file}]) and each file is a .lvl (JSON: size, spawn, exit, entity, tv, grid, zones).
# The Python editor mirrors saves straight into this folder.
static func read_index() -> Array:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://levels/levels.json"))
	var out: Array = parsed if parsed is Array else []
	if out.is_empty():
		push_error("levels/levels.json is missing or empty")
		out = [{"id": "level0", "name": "Level 0", "file": "level0.lvl"}]
	return out

static func read_level(meta: Dictionary) -> Dictionary:
	if meta.has("data"):                              # old baked format
		return meta["data"]
	var path := "res://levels/" + str(meta.get("file", ""))
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not parsed.has("grid"):
		push_error("cannot read level file " + path)
		return {"size": 8, "spawn": [2, 2], "grid": ["########", "#......#", "#......#", "#......#", "#......#", "#......#", "#......#", "########"]}
	return parsed

func _load(d: Dictionary) -> void:
	size = int(d["size"])
	var grid: Array = d["grid"]
	for z in size:
		var row: String = grid[z] if z < grid.size() else ""
		for x in size:
			var ch := row[x] if x < row.length() else "#"
			var edge := x == 0 or z == 0 or x == size - 1 or z == size - 1
			if edge or ch == "#":
				walls[Vector2i(x, z)] = true
			elif ch == "O":
				pits[Vector2i(x, z)] = true
	var zones: Dictionary = d.get("zones", {})
	for name in ["tall", "low", "tiles", "bright", "dark", "dim", "flicker"]:
		var target: Dictionary = get(name)
		for c in zones.get(name, []):
			var v := Vector2i(c[0], c[1])
			if not walls.has(v): target[v] = true
	var s: Array = d.get("spawn", [4, 4])
	spawn_pos = Vector3(s[0] * CELL, 0.1, s[1] * CELL)
	level_name = str(level_meta.get("name", "LEVEL 0"))

func ceiling_height(c: Vector2i) -> float:
	if tall.has(c): return TALL_H
	if low.has(c): return LOW_H
	return WALL_H

# ---------------------------------------------------------------- materials
func _mat(tex: String, per_metre: Vector3, tint := Color.WHITE) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://textures/%s_color.webp" % tex)
	m.albedo_color = tint
	m.normal_enabled = true
	m.normal_texture = load("res://textures/%s_normal.webp" % tex)
	m.roughness = 1.0
	m.roughness_texture = load("res://textures/%s_rough.webp" % tex)
	m.ao_enabled = true
	m.ao_texture = load("res://textures/%s_ao.webp" % tex)
	m.ao_light_affect = 0.9
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = per_metre
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.metallic_specular = 0.15
	return m

# Wallpaper: generated at wall height (baseboard, grime, ceiling contact shadow baked in).
# `world`: triplanar world-space UVs for the wall boxes; otherwise explicit UVs (ceiling drops).
func _wall_material(prefix: String, height: float, world: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://textures/%s_color.png" % prefix)
	m.albedo_color = Color(1.0, 0.97, 0.86)
	m.normal_enabled = true
	m.normal_texture = load("res://textures/%s_normal.png" % prefix)
	m.normal_scale = 0.9
	m.roughness_texture = load("res://textures/%s_rough.png" % prefix)
	m.roughness = 1.0
	m.ao_enabled = true
	m.ao_texture = load("res://textures/%s_ao.png" % prefix)
	m.ao_light_affect = 0.9
	m.metallic_specular = 0.2
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

	# Polished tile rooms: glossy, 74% opaque, with mirrored fixtures showing through
	if not tile_cells.is_empty():
		var tm := StandardMaterial3D.new()
		tm.albedo_texture = load("res://textures/floor_tile.png")
		tm.albedo_color = Color(1, 1, 1, 0.74)
		tm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		tm.roughness = 0.1
		tm.metallic = 0.15
		tm.uv1_triplanar = true
		tm.uv1_world_triplanar = true
		tm.uv1_scale = Vector3(0.5, 0.5, 0.5)
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

# ----------------------------------------------------------------- fixtures
# Same placement rules as the web game's _placeLights: corridor cells and a 3-cell grid, min
# spacing 1.9 cells, some tubes burnt out, some flickering.
var fx: Array = []        # every fixture
var lit: Array = []       # the non-burnt ones (the light pool ranks these)

func _place_fixtures() -> void:
	var min_sp := CELL * 1.9
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			if walls.has(c): continue
			var y := LOW_H - 0.03 if ceiling_height(c) == LOW_H else WALL_H - 0.03
			var pos := Vector3(x * CELL, y, z * CELL)
			var too_close := false
			for f in fx:
				if (f.pos as Vector3).distance_to(pos) < min_sp:
					too_close = true
					break
			if too_close: continue
			var is_bright := bright.has(c)
			var ns := walls.has(Vector2i(x - 1, z)) and walls.has(Vector2i(x + 1, z))
			var ew := walls.has(Vector2i(x, z - 1)) and walls.has(Vector2i(x, z + 1))
			var grid_node := x % 3 == 0 and z % 3 == 0
			if not (ns or ew or grid_node or is_bright): continue
			var chance := 1.0 if dark.has(c) else (0.75 if dim.has(c) else BURNT_CHANCE)
			var burnt := (not is_bright) and rng.randf() < chance
			var flick := (not burnt) and (not is_bright) and (flicker.has(c) or rng.randf() < FLICKER_CHANCE)
			fx.append({"pos": pos, "light_pos": pos - Vector3(0, 0.45, 0), "rot": PI / 2.0 if ns else 0.0,
				"burnt": burnt, "bright": is_bright, "flickers": flick, "level": 1.0,
				"timer": rng.randf() * 4.0, "burst": 0, "black": 0.0, "slot": -1, "dsq": 0.0,
				"index": -1, "wanted": false})
	for f in fx:
		if not f.burnt:
			f.index = lit.size()
			lit.append(f)

var tubes_mm: MultiMesh
var lens_mm: MultiMesh

func _mesh_world(root: Node, node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null:
		if n is Node3D: t = (n as Node3D).transform * t
		if n == root: break
		n = n.get_parent()
	return t

func _build_fixture_meshes() -> void:
	var scene: PackedScene = load("res://models/lights/office_lighting_troffer_light_1x4.glb")
	var root: Node3D = scene.instantiate()
	var parts := {}
	for n in root.find_children("Object_*", "MeshInstance3D", true, false):
		parts[String(n.name)] = n
	if not (parts.has("Object_2") and parts.has("Object_3") and parts.has("Object_4") and parts.has("Object_5")):
		push_warning("Troffer model is missing Object_2..5 parts; found: %s" % str(parts.keys()))
		root.queue_free()
		return
	var base_off := Transform3D(Basis(), Vector3(0, -TOP_Y, 0))

	var housing_mat := StandardMaterial3D.new()
	housing_mat.albedo_color = Color("cfcabf"); housing_mat.roughness = 0.65; housing_mat.metallic = 0.2
	var tray_mat := StandardMaterial3D.new()
	tray_mat.albedo_color = Color("eeece4"); tray_mat.roughness = 0.45; tray_mat.metallic = 0.25
	var burnt_tubes := StandardMaterial3D.new()
	burnt_tubes.albedo_color = Color("221f1a"); burnt_tubes.roughness = 0.9; burnt_tubes.metallic = 0.1
	var burnt_lens := StandardMaterial3D.new()
	burnt_lens.albedo_color = Color(0.2, 0.188, 0.157, 0.65)
	burnt_lens.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	burnt_lens.roughness = 0.85
	var tubes_shader := Shader.new()
	tubes_shader.code = "shader_type spatial;\nrender_mode unshaded, shadows_disabled;\nvoid fragment() { ALBEDO = COLOR.rgb; }"
	var lit_tubes := ShaderMaterial.new()
	lit_tubes.shader = tubes_shader
	var lens_shader := Shader.new()
	lens_shader.code = "shader_type spatial;\nrender_mode unshaded, blend_add, depth_draw_never, shadows_disabled;\nvoid fragment() { ALBEDO = COLOR.rgb; ALPHA = 0.35; }"
	var lit_lens := ShaderMaterial.new()
	lit_lens.shader = lens_shader

	var burnt: Array = fx.filter(func(f): return f.burnt)
	var yoff := Vector3(0, 0.03, 0)
	var place := func(part: String, items: Array, mat: Material, colored: bool) -> MultiMesh:
		if items.is_empty(): return null
		var node: MeshInstance3D = parts[part]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = colored
		mm.mesh = node.mesh
		mm.instance_count = items.size()
		var mw := _mesh_world(root, node)
		for i in items.size():
			var f: Dictionary = items[i]
			var t := Transform3D(Basis(Vector3.UP, f.rot), f.pos + yoff) * base_off * mw
			mm.set_instance_transform(i, t)
			if colored: mm.set_instance_color(i, LIT_DIFFUSER if part == "Object_5" else LIT_DIFFUSER * 0.45)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		return mm
	place.call("Object_3", fx, housing_mat, false)
	place.call("Object_4", fx, tray_mat, false)
	place.call("Object_5", burnt, burnt_tubes, false)
	tubes_mm = place.call("Object_5", lit, lit_tubes, true)
	place.call("Object_2", burnt, burnt_lens, false)
	lens_mm = place.call("Object_2", lit, lit_lens, true)
	root.queue_free()

	# Chains for fixtures hanging under the atrium ceiling
	var hanging: Array = fx.filter(func(f): return tall.has(Vector2i(roundi(f.pos.x / CELL), roundi(f.pos.z / CELL))))
	if not hanging.is_empty():
		var rise := TALL_H - WALL_H
		var cm := MultiMesh.new()
		cm.transform_format = MultiMesh.TRANSFORM_3D
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.02; cyl.bottom_radius = 0.02; cyl.height = 1.0; cyl.radial_segments = 5
		cm.mesh = cyl
		cm.instance_count = hanging.size()
		for i in hanging.size():
			var f: Dictionary = hanging[i]
			cm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(1, rise, 1)), Vector3(f.pos.x, WALL_H + rise / 2.0, f.pos.z)))
		var chain_mat := StandardMaterial3D.new()
		chain_mat.albedo_color = Color("14120c")
		chain_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var cmi := MultiMeshInstance3D.new()
		cmi.multimesh = cm
		cmi.material_override = chain_mat
		add_child(cmi)

var tint := Color.WHITE      # events recolour every lit tube (null in the web game = white)

func _set_lit_color(f: Dictionary, level: float) -> void:
	if tubes_mm: tubes_mm.set_instance_color(f.index, LIT_DIFFUSER * tint * level)
	if lens_mm: lens_mm.set_instance_color(f.index, LIT_DIFFUSER * tint * (level * 0.45))

# Recolour every lit tube; Color.WHITE puts the normal warm white back (random events)
func set_tint(c: Color) -> void:
	tint = c
	for f in lit:
		if f.black > 0.0: continue
		_set_lit_color(f, f.level)

# One tube dies for `duration` seconds, then re-strikes
func cut_fixture(f: Dictionary, duration: float) -> void:
	f.black = duration
	f.level = 0.03
	_set_lit_color(f, 0.03)

# Every tube dies at once; they return at staggered times after `duration`
func cut_power(duration: float) -> void:
	for f in lit:
		f.black = duration + rng.randf() * 1.6
		f.level = 0.03
		_set_lit_color(f, 0.03)

func restore_power() -> void:
	for f in lit:
		if f.black > 0.0: f.black = 0.001

# Fake planar reflection for the polished room: mirrored fixture panels under the
# semi-transparent floor, plus two steady lights so the room stays bright.
func _build_floor_reflections() -> void:
	var items: Array = fx.filter(func(f): return f.bright)
	if items.is_empty(): return
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nrender_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;\nvoid fragment() { ALBEDO = vec3(2.2, 2.15, 1.9) * 0.55; ALPHA = 1.0; }"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = -1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var box := BoxMesh.new()
	box.size = Vector3(1.95, 0.02, 0.82)
	mm.mesh = box
	mm.instance_count = items.size()
	var cx := 0.0
	var cz := 0.0
	for i in items.size():
		var f: Dictionary = items[i]
		mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, f.rot), Vector3(f.pos.x, -f.pos.y, f.pos.z)))
		cx += f.pos.x
		cz += f.pos.z
	cx /= items.size()
	cz /= items.size()
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	for o in [-2.2, 2.2]:
		var l := OmniLight3D.new()
		l.light_color = Color("fff1cf")
		l.omni_range = 24.0
		l.omni_attenuation = 1.4
		l.light_energy = LIGHT_ENERGY * 2.6 / 1.5 * 0.6
		l.position = Vector3(cx, WALL_H - 0.6, cz + o * CELL)
		add_child(l)

# ---------------------------------------------------------------- light pool
# A fixed number of lights re-targeted to the nearest lit fixtures; slots cross-fade so
# nothing pops. Each slot also drives one spatial hum voice (audio.gd reads slot_*).
var pool: Array[OmniLight3D] = []
var slot_fixture: Array = []       # fixture Dictionary or null
var slot_weight: Array[float] = []
var slot_target: Array[float] = []
var _rank_timer := 0.0
var _candidates: Array = []

func _build_light_pool() -> void:
	for i in POOL_SIZE:
		var l := OmniLight3D.new()
		l.light_color = LIGHT_COLOR
		l.omni_range = LIGHT_RANGE
		l.omni_attenuation = 1.4
		l.light_energy = 0.0
		l.shadow_enabled = true
		l.shadow_bias = 0.04
		l.shadow_normal_bias = 1.2
		l.shadow_blur = 1.6
		add_child(l)
		pool.append(l)
		slot_fixture.append(null)
		slot_weight.append(0.0)
		slot_target.append(0.0)

func slot_level(i: int) -> float:
	var f = slot_fixture[i]
	return 0.0 if f == null else f.level * slot_weight[i]

func slot_position(i: int) -> Vector3:
	var f = slot_fixture[i]
	return Vector3.ZERO if f == null else f.light_pos

func _rank(p: Vector3) -> void:
	var max_sq := SELECT_RADIUS * SELECT_RADIUS
	_candidates.clear()
	for f in lit:
		var dx: float = f.pos.x - p.x
		var dz: float = f.pos.z - p.z
		f.dsq = dx * dx + dz * dz
		f.wanted = false
		if f.dsq < max_sq: _candidates.append(f)
	_candidates.sort_custom(func(a, b): return a.dsq < b.dsq)
	var n := mini(_candidates.size(), POOL_SIZE)
	for i in n: _candidates[i].wanted = true
	_candidates.resize(n)

func _update_pool(delta: float) -> void:
	var p := player.global_position
	_rank_timer -= delta
	if _rank_timer <= 0.0:
		_rank_timer = 0.1
		_rank(p)
		for i in POOL_SIZE:
			var f = slot_fixture[i]
			if f == null: continue
			slot_target[i] = 1.0 if f.wanted else 0.0
			if slot_target[i] == 0.0 and slot_weight[i] < 0.02:
				f.slot = -1
				slot_fixture[i] = null
		for f in _candidates:
			if f.slot != -1: continue
			var free := slot_fixture.find(null)
			if free == -1: break
			slot_fixture[free] = f
			slot_target[free] = 1.0
			slot_weight[free] = 0.0
			f.slot = free
			slot_assigned.emit(free)
	var k := minf(1.0, delta * 5.0)
	var fade_range := SELECT_RADIUS - FADE_START
	for i in POOL_SIZE:
		var l := pool[i]
		var f = slot_fixture[i]
		if f == null:
			l.light_energy = 0.0
			continue
		slot_weight[i] += (slot_target[i] - slot_weight[i]) * k
		var d := sqrt(f.dsq)
		var t := clampf((d - FADE_START) / fade_range, 0.0, 1.0)
		var dist_fade := 1.0 - t * t * (3.0 - 2.0 * t)
		l.global_position = f.light_pos
		l.light_energy = LIGHT_ENERGY * f.level * slot_weight[i] * dist_fade

# Failing-tube model: long stable stretches, then a burst of rapid dropouts and re-strikes
func _update_fixtures(delta: float) -> void:
	for f in lit:
		if f.black > 0.0:
			f.black -= delta
			if f.black <= 0.0:
				f.level = 1.0
				f.burst = 0
				f.timer = 1.0 + rng.randf() * 3.0
				_set_lit_color(f, 1.0)
				fixture_event.emit(f, true)
			continue
		if not f.flickers: continue
		f.timer -= delta
		if f.timer > 0.0: continue
		if f.burst == 0:
			f.burst = 2 * (1 + rng.randi() % 4)      # even: always ends lit
		f.burst -= 1
		var going_off: bool = f.level > 0.3
		f.level = 0.04 if going_off else 0.7 + rng.randf() * 0.45
		f.timer = (0.03 + rng.randf() * 0.09) if going_off else (0.04 + rng.randf() * 0.14)
		if f.burst == 0:
			f.level = 1.0
			f.timer = 1.5 + rng.randf() * 6.0
		_set_lit_color(f, 0.06 if going_off else f.level)
		fixture_event.emit(f, not going_off)

# ------------------------------------------------------- atmosphere (lighting.js)
var bounce := 1.0
var grid_glow := 0.0
var zone_amb := 1.0
var zone_fog := 1.0

# How much working tube light reaches a point (0..1): the web game's bounce estimate
func tube_light_at(p: Vector3) -> float:
	var sum := 0.0
	for i in POOL_SIZE:
		var f = slot_fixture[i]
		if f == null: continue
		var dsq := (f.pos as Vector3).distance_squared_to(p)
		sum += f.level * slot_weight[i] / (1.0 + dsq / (BOUNCE_RADIUS * BOUNCE_RADIUS))
	return minf(1.0, sum / BOUNCE_FULL)

func _update_atmosphere(delta: float) -> void:
	var we := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null: return
	var env := we.environment
	var c := Vector2i(roundi(player.global_position.x / CELL), roundi(player.global_position.z / CELL))
	var za := 1.0
	var zf := 1.0
	var grid_down: bool = player.get("grid_down") == true
	grid_glow += ((1.0 if grid_down else 0.0) - grid_glow) * minf(1.0, delta * 0.5)
	if dark.has(c):
		za = 0.12; zf = 1.35
	elif dim.has(c):
		za = 0.55; zf = 1.15
	var k := minf(1.0, delta * ADAPT)
	bounce += (tube_light_at(player.global_position) - bounce) * k
	zone_amb += (za - zone_amb) * k
	zone_fog += (zf - zone_fog) * k
	var b := AMBIENT_MIN + (1.0 - AMBIENT_MIN) * bounce
	# power cut: a faint glow so shapes barely read (ATMOSPHERE.gridDownAmbient / gridDownFog)
	var darkness := 1.0 - minf(1.0, maxf(b * zone_amb, 0.6 * grid_glow))
	env.fog_light_color = FOG_COLOR.lerp(FOG_COLOR_DARK, darkness)
	env.background_color = env.fog_light_color
	var lit_scale := FOG_LIT_SCALE + (1.0 + FOG_DARK_BOOST - FOG_LIT_SCALE) * darkness
	# web uses exp2 fog at 0.075; Godot's exponential fog needs a lower density for the same feel
	env.fog_density = FOG_DENSITY * 0.8 * lit_scale * zone_fog * (1.0 + (0.55 - 1.0) * grid_glow)

func _process(delta: float) -> void:
	if player == null or pool.is_empty(): return
	_update_fixtures(delta)
	_update_pool(delta)
	_update_atmosphere(delta)

# ---------------------------------------------------------------- exit
var exit_door: Node3D

func _build_exit() -> void:
	var e = level_data.get("exit")
	if not (e is Array) or e.size() < 2:
		return
	exit_door = preload("res://scripts/world/level_exit.gd").new()
	exit_door.position = Vector3(e[0] * CELL, 0.0, e[1] * CELL)
	add_child(exit_door)

func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	match e.physical_keycode:            # dev: PageUp / PageDown switch level, Home reloads it from disk
		KEY_PAGEDOWN: Game.change_level(Game.level_index + 1)
		KEY_PAGEUP: Game.change_level(Game.level_index - 1)
		KEY_HOME: Game.change_level(Game.level_index)
