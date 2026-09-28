extends "res://scripts/World/level/level_data.gd"
## THE LEVEL, layer 2: what it is made of. Wallpapered walls (one MultiMesh per wall height), carpet and
## glossy tile floors, the ceiling with its drops where two heights meet, pit shafts falling away into
## the dark, and grime on the carpet. All built once from the grid when the level loads.
##
## Three free-placed objects live alongside the plain block (level_data.gd `objects`): thin walls (a slim
## partition), arches (a round-topped walkable opening through a full wall) and doors (a framed, hinged
## door set into a thin wall, see props/door.gd). Each has its own position, rotation and width.

const Door := preload("res://scripts/World/props/door.gd")
const THIN_DEPTH := 0.3        # a thin wall's thickness along its closed axis (vs. a full CELL block)
const ARCH_OPEN := 3.0         # a 1-cell archway's opening width; the rest of its span is a plain pillar each side
const ARCH_SPRING := 2.4       # height where the straight sides turn into the semicircular crown
const ARCH_SEGS := 16

var wall_mat: StandardMaterial3D
var tall_wall_mat: StandardMaterial3D
var door_leaf_mat: StandardMaterial3D
var door_hw_mat: StandardMaterial3D
var door_frame_mat: StandardMaterial3D
## The level's ceiling material when it has light panels baked into it (an emission texture, e.g. BRC_A).
## Then level_lighting.gd builds the ceiling itself, one textured quad per cell with a light behind its
## panels, instead of the plain ceiling here plus hanging troffers.
var panel_ceiling: StandardMaterial3D

func build_geometry() -> void:
	panel_ceiling = _panel_ceiling_material()
	wall_mat = _pbr_or("wall", true) if _has_pbr("wall") else _wall_material("wall", WALL_H, true)
	tall_wall_mat = _pbr_or("wall", true) if _has_pbr("wall") else _wall_material("wall_tall", TALL_H, true)
	door_leaf_mat = (load("res://textures/pbr/Wood029/Wood029.tres") as StandardMaterial3D).duplicate()
	door_leaf_mat.roughness = 0.75
	door_hw_mat = (load("res://textures/pbr/Metal038/Metal038.tres") as StandardMaterial3D).duplicate()
	door_hw_mat.roughness = 0.35
	door_frame_mat = StandardMaterial3D.new()          # painted gray metal frame and casing
	door_frame_mat.albedo_color = Color(0.55, 0.55, 0.53)
	door_frame_mat.roughness = 0.5
	door_frame_mat.metallic_specular = 0.45
	_build_surfaces()
	_build_walls()
	_build_objects()
	_build_ceiling_steps()
	_build_pit_shafts()
	_build_dirt()

# ---------------------------------------------------------------- materials
## The .lvl's optional "materials" ({wall, floor, ceiling, tiles} -> a folder in textures/pbr/, picked in the
## level editor). Null when the slot is unset, so the caller falls back to the Level 0 look.
func _has_pbr(slot: String) -> bool:
	var id := str(level_data.get("materials", {}).get(slot, ""))
	return not id.is_empty() and ResourceLoader.exists("res://textures/pbr/%s/%s.tres" % [id, id])

func _pbr_or(slot: String, _world := false) -> StandardMaterial3D:
	if not _has_pbr(slot):
		return null
	var id := str(level_data.get("materials", {}).get(slot, ""))
	var m: StandardMaterial3D = (load("res://textures/pbr/%s/%s.tres" % [id, id]) as StandardMaterial3D).duplicate()
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(0.45, 0.45, 0.45)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m

func _panel_ceiling_material() -> StandardMaterial3D:
	if not _has_pbr("ceiling"):
		return null
	var id := str(level_data.get("materials", {}).get("ceiling", ""))
	var m := load("res://textures/pbr/%s/%s.tres" % [id, id]) as StandardMaterial3D
	return m if m != null and m.emission_enabled and m.emission_texture != null else null

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
			st.set_tangent(Plane(1, 0, 0, 1))
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
	var classic_floor := []
	var classic_ceil := []
	var ceil_cells := []
	var floor_cells := []
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			if panel_ceiling != null: pass          # built by level_lighting.gd with its lights
			elif classic.has(c): classic_ceil.append(c)
			else: ceil_cells.append(c)
			if pits.has(c): continue
			floor_cells.append(c)
			if classic.has(c): classic_floor.append(c)
			elif tiles.has(c): tile_cells.append(c)
			else: carpet_cells.append(c)
	var carpet: StandardMaterial3D = _pbr_or("floor") if _has_pbr("floor") else _mat("l0_carpet", Vector3(0.5, 0.5, 0.5), Color(1.0, 0.94, 0.75))
	var ceil_m: StandardMaterial3D = _pbr_or("ceiling") if _has_pbr("ceiling") else _mat("l0_ceiling", Vector3(0.278, 0.278, 0.278), Color(0.89, 0.85, 0.74))
	_cell_surface(carpet_cells, func(_c): return 0.0, carpet, false)
	_cell_surface(ceil_cells, func(c): return ceiling_height(c), ceil_m, true)
	# Classic zone: glowing mono-yellow carpet and bright drop-ceiling tiles (the reference backrooms look)
	if not classic_floor.is_empty():
		_cell_surface(classic_floor, func(_c): return 0.0, _classic_mat("l0_carpet", 0.5, Color(1.2, 1.05, 0.62), 0.0), false)
	if not classic_ceil.is_empty():
		_cell_surface(classic_ceil, func(c): return ceiling_height(c), _classic_mat("l0_ceiling", 0.278, Color(0.95, 0.9, 0.72), 0.0), true)

	# Polished commercial tile rooms: high-res PBR vinyl composite tiles with wax sheen and normal-mapped bevels
	if not tile_cells.is_empty():
		var tm: StandardMaterial3D = _pbr_or("tiles")
		if tm == null:
			tm = _default_tile_material()
		_cell_surface(tile_cells, func(_c): return 0.0, tm, false, 0)

	_build_floor_collision(floor_cells)

func _classic_mat(tex: String, scale: float, tint: Color, glow := 0.1) -> StandardMaterial3D:
	var m := _mat(tex, Vector3(scale, scale, scale), tint)
	if glow > 0.0:                      # a faint self-glow only; real brightness comes from the lights
		m.emission_enabled = true
		m.emission_texture = m.albedo_texture
		m.emission = tint
		m.emission_energy_multiplier = glow
	return m

func _default_tile_material() -> StandardMaterial3D:
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
	return tm

func _build_floor_collision(floor_cells: Array) -> void:
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

## Occlusion culling: every wall block is an occluder, so the renderer skips whatever is hidden behind walls
## (the rest of a maze is never on screen). One merged mesh: 8 vertices and 12 triangles per block.
func _build_occluder(groups: Dictionary) -> void:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var h := CELL / 2.0
	var tris := [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
	for height in groups.keys():
		for c: Vector2i in groups[height]:
			var b := verts.size()
			var x := c.x * CELL
			var z := c.y * CELL
			for y in [0.0, height]:
				verts.append(Vector3(x - h, y, z - h))
				verts.append(Vector3(x + h, y, z - h))
				verts.append(Vector3(x + h, y, z + h))
				verts.append(Vector3(x - h, y, z + h))
			# corners 0-3 bottom, 4-7 top (the tri table above indexes them that way)
			for t in tris: idx.append(b + t)
	if verts.is_empty(): return
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	var oi := OccluderInstance3D.new()
	oi.occluder = occ
	add_child(oi)

const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

func _build_walls() -> void:
	var groups := {WALL_H: [], TALL_H: []}
	for c: Vector2i in walls.keys():
		if carved.has(c): continue     # a door / thin wall object stands here instead of a solid block
		var exposed := false
		var near_tall := false
		for n: Vector2i in DIRS:
			# a door / thin wall only fills a sliver of its cell, so the block beside it still shows
			if not walls.has(c + n) or carved.has(c + n): exposed = true
			if tall.has(c + n): near_tall = true
		if exposed:
			groups[TALL_H if near_tall else WALL_H].append(c)
	_build_occluder(groups)
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

# The editor's free-placed objects (level_data.gd `objects`). Each one is built in its own local frame,
# facing +X (the way you walk through it) and spanning `scale` cells along Z, then placed with
# object_transform(). Wall height follows the cell it stands in (tall next to an atrium).
func _build_objects() -> void:
	var thin: Array = []
	var arch: Array = []
	for o: Dictionary in objects:
		match o.type:
			"door": _build_door(o)
			"thin_wall": thin.append(o)
			"arch": arch.append(o)
	_build_thin_walls(thin)
	_build_arches(arch)

func _object_wall_h(o: Dictionary) -> float:
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	for n: Vector2i in DIRS + [Vector2i.ZERO]:
		if tall.has(c + n): return TALL_H
	return WALL_H

## One box collider under `body`, placed by `xf` (object space) at local `pos`
func _add_box_collider(body: StaticBody3D, xf: Transform3D, size: Vector3, pos: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = xf * Transform3D(Basis(), pos)
	body.add_child(cs)

# A slim partition instead of a full CELL-deep block: same material as a normal wall so it reads as part
# of the same maze, just thin. Its own StaticBody3D (one box each; there are usually few of these).
func _build_thin_walls(list: Array) -> void:
	if list.is_empty(): return
	var body := StaticBody3D.new()
	add_child(body)
	for o: Dictionary in list:
		var h := _object_wall_h(o)
		var size := Vector3(THIN_DEPTH, h, CELL * o.scale)
		var xf := object_transform(o)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mi.mesh = box
		mi.transform = xf * Transform3D(Basis(), Vector3(0, h * 0.5, 0))
		mi.material_override = tall_wall_mat if h > WALL_H else wall_mat
		add_child(mi)
		_add_box_collider(body, xf, size, Vector3(0, h * 0.5, 0))

# A round-topped opening through a full CELL-deep wall: straight jambs up to ARCH_SPRING, then a
# semicircular crown (flattened if a wide arch would hit the ceiling), solid wall to either side of the
# opening and above it. The opening is the span minus a fixed pillar each side, so a 1-cell arch opens
# ARCH_OPEN wide and a wider one opens up to match.
func _build_arches(list: Array) -> void:
	if list.is_empty(): return
	var crown: Array = []                  # world-space triangles, clockwise-front (Godot's convention)
	var under := {}                        # wall height -> [world pos, uv] for the crown's underside
	var body := StaticBody3D.new()
	add_child(body)
	var d := CELL * 0.5
	var pillar := (CELL - ARCH_OPEN) * 0.5
	for o: Dictionary in list:
		var xf := object_transform(o)
		var h := _object_wall_h(o)
		var w: float = CELL * o.scale - pillar * 2.0
		var r := w * 0.5
		var rise := minf(r, h - ARCH_SPRING - 0.3)
		for side: float in [-1.0, 1.0]:
			var size := Vector3(CELL, h, pillar)
			var pos := Vector3(0, h * 0.5, side * (r + pillar * 0.5))
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = size
			mi.mesh = box
			mi.transform = xf * Transform3D(Basis(), pos)
			mi.material_override = tall_wall_mat if h > WALL_H else wall_mat
			add_child(mi)
			_add_box_collider(body, xf, size, pos)
		# The underside can't use the walls' world-triplanar wallpaper (it's stretched to the wall height, so
		# on a surface that hardly changes in y it smears into streaks). It gets real UVs instead: the
		# wallpaper carried on up from each jamb, unrolled height = spring + arc length from the nearer
		# spring, so the two halves meet at the crown.
		var arc: Array[Vector2] = []           # (z, y) along the arc, left spring to right spring
		for i in ARCH_SEGS + 1:
			var t := PI * (1.0 - float(i) / ARCH_SEGS)
			arc.append(Vector2(r * cos(t), ARCH_SPRING + rise * sin(t)))
		var run: Array[float] = [0.0]
		for i in ARCH_SEGS: run.append(run[i] + arc[i].distance_to(arc[i + 1]))
		var total: float = run[ARCH_SEGS]
		if not under.has(h): under[h] = []
		# the crown: wall from the arc up to the top, one slice per segment (z across the opening, x through it)
		for i in ARCH_SEGS:
			var a0 := arc[i]
			var a1 := arc[i + 1]
			var f0 := Vector3(-d, a0.y, a0.x); var f1 := Vector3(-d, a1.y, a1.x)
			var b0 := Vector3(d, a0.y, a0.x); var b1 := Vector3(d, a1.y, a1.x)
			var ft0 := Vector3(-d, h, a0.x); var ft1 := Vector3(-d, h, a1.x)
			var bt0 := Vector3(d, h, a0.x); var bt1 := Vector3(d, h, a1.x)
			for v in [f0, ft0, ft1, f0, ft1, f1,        # front face (-X)
					b0, bt1, bt0, b0, b1, bt1]:             # back face (+X)
				crown.append(xf * v)
			var u0 := ARCH_SPRING + minf(run[i], total - run[i])
			var u1 := ARCH_SPRING + minf(run[i + 1], total - run[i + 1])
			for pv in [[f0, Vector2(-d, u0)], [f1, Vector2(-d, u1)], [b0, Vector2(d, u0)],     # (metres through, metres up)
					[f1, Vector2(-d, u1)], [b1, Vector2(d, u1)], [b0, Vector2(d, u0)]]:
				under[h].append([xf * (pv[0] as Vector3), pv[1]])
	if crown.is_empty(): return
	var pbr := _has_pbr("wall")
	var under_faces: Array = []            # the underside's triangles again, for the collision shape
	for hh: float in under:
		var ust := SurfaceTool.new()
		ust.begin(Mesh.PRIMITIVE_TRIANGLES)
		for e in under[hh]:
			var uvm: Vector2 = e[1]
			# as the walls map it: 2.25 m per repeat across, the full wall height per repeat up
			ust.set_uv(uvm * 0.45 if pbr else Vector2(uvm.x / 2.25, 1.0 - uvm.y / hh))
			ust.add_vertex(e[0])
			under_faces.append(e[0])
		ust.generate_normals()
		ust.generate_tangents()
		var um: StandardMaterial3D
		if pbr:
			um = _pbr_or("wall")
			um.uv1_triplanar = false
			um.uv1_scale = Vector3.ONE
		else:
			um = _wall_material("wall_tall" if hh > WALL_H else "wall", hh, false)
		var umi := MeshInstance3D.new()
		umi.mesh = ust.commit()
		umi.material_override = um
		add_child(umi)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in crown: st.add_vertex(v)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = wall_mat
	add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array(crown + under_faces))
	shape.backface_collision = true
	cs.shape = shape
	body.add_child(cs)

# A door is always set in a thin wall: props/door.gd builds the partition across the object's span with
# the doorway, frame, casing, leaf and knobs in it.
func _build_door(o: Dictionary) -> void:
	var h := _object_wall_h(o)
	var d := Door.new()
	d.transform = object_transform(o)
	add_child(d)
	d.build(CELL * o.scale, THIN_DEPTH, h, tall_wall_mat if h > WALL_H else wall_mat, door_frame_mat, door_leaf_mat, door_hw_mat)

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
		var m: StandardMaterial3D
		if _has_pbr("wall"):
			m = _pbr_or("wall")
			m.uv1_triplanar = false        # explicit UVs on the drops
			m.uv1_scale = Vector3.ONE
		else:
			m = _wall_material("wall" if i == 0 else "wall_tall", b.height, false)
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
