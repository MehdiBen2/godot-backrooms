extends "res://scripts/World/level/level_data.gd"
## THE LEVEL, layer 2: what it is made of. Wallpapered walls (one MultiMesh per wall height), carpet and
## glossy tile floors, the ceiling with its drops where two heights meet, pit shafts falling away into
## the dark, and grime on the carpet. All built once from the grid when the level loads.
##
## Free-placed objects live alongside the plain block (level_data.gd `objects`): walls of any plan shape
## (a straight thin wall, a waist-high half wall, an L corner, a curve up to a full round room), pillars and
## columns, arches (a round-topped walkable opening through a full wall), doors (a framed, hinged door set
## into a thin wall, see props/door.gd) and invisible event triggers (props/event_trigger.gd). Each has its
## own position, rotation and width, and the walls their own thickness and height.

const Door := preload("res://scripts/World/props/door.gd")
const IndustrialProp := preload("res://scripts/World/props/industrial_prop.gd")
const Stairs := preload("res://scripts/World/props/stairs.gd")
const EventTrigger := preload("res://scripts/World/props/event_trigger.gd")
const MMBuffer := preload("res://scripts/World/mm_buffer.gd")
const PitFall := preload("res://scripts/World/level/pit_fall.gd")
const ARCH_SPRING := 2.4       # height where the straight sides turn into the semicircular crown
const ARCH_SEGS := 16
const COLLIDER_CHUNK := 8      # merged collision boxes never cross an 8x8-cell chunk (same chunks as the wall MultiMeshes)

var wall_mat: StandardMaterial3D
var tall_wall_mat: StandardMaterial3D
var door_leaf_mat: StandardMaterial3D
var door_hw_mat: StandardMaterial3D
var door_frame_mat: StandardMaterial3D
## The level's ceiling material when it has light panels baked into it (an emission texture, e.g. BRC_A).
## Then level_fixtures.gd builds the ceiling itself, one textured quad per cell with a light behind its
## panels, instead of the plain ceiling here plus hanging troffers.
var panel_ceiling: StandardMaterial3D
var stairwells: Array = []     # this floor's stairwells (props/stairs.gd), for the light they give where they stand
var pit_fall: Node3D           # this floor's bottomless pits and the fall down them (pit_fall.gd), if it has any

func build_geometry() -> void:
	_make_materials()
	_build_surfaces()
	_build_walls()
	_build_objects()
	_build_ceiling_steps()
	_build_pit_shafts()
	_build_dirt()

## The level's shared materials, before anything is built with them
func _make_materials() -> void:
	_pit_materials()
	panel_ceiling = _panel_ceiling_material()
	wall_mat = _pbr_or("wall", true) if _has_pbr("wall") else _wall_material("wall", WALL_H, true)
	tall_wall_mat = _pbr_or("wall", true) if _has_pbr("wall") else _wall_material("wall_tall", TALL_H, true)
	if ResourceLoader.exists("res://textures/props/door/door_leaf.tres"):
		door_leaf_mat = (load("res://textures/props/door/door_leaf.tres") as StandardMaterial3D).duplicate()
	else:
		door_leaf_mat = (load("res://textures/pbr/Wood029/Wood029.tres") as StandardMaterial3D).duplicate()
		door_leaf_mat.roughness = 0.75
	door_hw_mat = (load("res://textures/pbr/Metal038/Metal038.tres") as StandardMaterial3D).duplicate()
	door_hw_mat.roughness = 0.35
	door_frame_mat = StandardMaterial3D.new()          # painted gray metal frame and casing
	door_frame_mat.albedo_color = Color(0.55, 0.55, 0.53)
	door_frame_mat.roughness = 0.5
	door_frame_mat.metallic_specular = 0.45

# ---------------------------------------------------------------- materials
## The .lvl's optional "materials" ({wall, floor, ceiling, tiles} -> a folder in textures/pbr/, picked in the
## level editor). Null when the slot is unset, so the caller falls back to the Level 0 look.
func _has_pbr(slot: String) -> bool:
	var id := str(level_data.get("materials", {}).get(slot, ""))
	return not id.is_empty() and ResourceLoader.exists("res://textures/pbr/%s/%s.tres" % [id, id])

func _pbr_or(slot: String, _world := false) -> StandardMaterial3D:
	if not _has_pbr(slot):
		return null
	return _pbr_by_id(str(level_data.get("materials", {}).get(slot, "")))

## The .lvl's "paint" ({wall|floor|ceiling} -> {pbr name -> [[x, z], ...]}, the editor's material brush):
## cells that override the level's material for that surface. slot -> {Vector2i: pbr name}
var _painted := {}
func painted(slot: String) -> Dictionary:
	if _painted.is_empty():
		for sl in ["wall", "floor", "ceiling"]:
			var cells := {}
			for id in level_data.get("paint", {}).get(sl, {}):
				if not ResourceLoader.exists("res://textures/pbr/%s/%s.tres" % [id, id]): continue
				for c in level_data["paint"][sl][id]:
					cells[Vector2i(c[0], c[1])] = str(id)
			_painted[sl] = cells
	return _painted[slot]

var _paint_mats := {}
func _painted_mat(id: String) -> StandardMaterial3D:
	if not _paint_mats.has(id): _paint_mats[id] = _pbr_by_id(id)
	return _paint_mats[id]

func _pbr_by_id(id: String) -> StandardMaterial3D:
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
	m.ao_light_affect = AO_DIRECT
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
	m.ao_light_affect = AO_DIRECT
	m.metallic_specular = 0.28
	if world:
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3(1.0 / 2.25, -1.0 / height, 1.0 / 2.25)
		m.uv1_offset = Vector3(0, 1, 0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.texture_repeat = true
	return m

## How much the baked AO maps darken *direct* light. AO is occlusion of light arriving from all round, so it
## belongs on the ambient / bounce light; at 0.85 the wallpaper's baked ceiling band and baseboard stayed dark
## right under a lamp and in the torch beam, a painted-on shadow that never moved. The real contact
## darkening now comes from the shadows, the bounce light and SSAO.
const AO_DIRECT := 0.2

## Ceiling materials whose bounce-light fill level_lighting.gd drives (found-footage look)
var ceil_mats: Array[Material] = []

## A ceiling material that can glow with its own colour (the fill stands in for bounce light off the lit
## carpet and walls, which the tube lights never put on the ceiling layer). Starts dark.
func _fillable_ceiling(m: StandardMaterial3D) -> StandardMaterial3D:
	if not m.emission_enabled:
		m.emission_enabled = true
		m.emission_texture = m.albedo_texture
		m.emission = m.albedo_color
		m.emission_energy_multiplier = 0.0
		ceil_mats.append(m)
	return m

## The ceiling's own render layer: the tube lights skip it (a point light 0.45 m under it blows a white hotspot);
## it is lit by bounce light, the tubes' glow and level_lighting.gd's soft ceiling-glow lights instead.
const CEIL_LAYER := 1 << 18
## The look-only floors above and below (level_shell.gd) are drawn on these two render layers, turn about, and
## lit only by lights of their own: no light here has a shadow that a floor slab would stop, so a lamp that lit
## every layer would shine straight through into the storeys under and over it.
const SHELL_LAYERS := (1 << 10) | (1 << 11)

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
			st.set_uv(Vector2(v.x, v.z))
			st.add_vertex(v)
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.material_override.render_priority = priority
	# Floors, ceilings and pit bottoms never shade anything you can see: every tube hangs under its ceiling
	# and above the floor (the steps between ceiling heights are their own casters). Left on, the whole
	# level's floor and ceiling were drawn into all six faces of every shadowed light's cube, every frame.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

## The floors and the ceilings, one mesh per material. `floors` / `ceilings`: build only one of the two (a
## floor rebuilt in place does them a frame apart, level_builder.gd).
func _build_surfaces(floors := true, ceilings := true) -> void:
	var carpet_cells := []
	var tile_cells := []
	var classic_floor := []
	var classic_ceil := []
	var ceil_cells := []
	var floor_cells := []
	var paint_floor := {}                    # pbr name -> cells the editor's material brush covered
	var paint_ceil := {}
	var pf := painted("floor")
	var pc := painted("ceiling")
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			if stair_cells.has(c): continue         # a stairwell: props/stairs.gd builds its own floors and ceilings
			if not crop.is_empty() and not crop.has(c): continue
			if open_above.has(c): pass              # a hole in the floor above: no ceiling under it
			elif panel_ceiling != null: pass        # built by level_fixtures.gd with its lights
			elif pc.has(c): paint_ceil.get_or_add(pc[c], []).append(c)
			elif classic.has(c): classic_ceil.append(c)
			else: ceil_cells.append(c)
			if pits.has(c): continue
			floor_cells.append(c)
			if pf.has(c): paint_floor.get_or_add(pf[c], []).append(c)
			elif classic.has(c): classic_floor.append(c)
			elif tiles.has(c): tile_cells.append(c)
			else: carpet_cells.append(c)
	if ceilings:
		var ceil_m: Material = _fillable_ceiling(_pbr_or("ceiling")) if _has_pbr("ceiling") else _acoustic_ceiling(Color(0.89, 0.85, 0.74))
		_cell_surface(ceil_cells, func(c): return ceiling_height(c), ceil_m, true).layers = CEIL_LAYER
		for id in paint_ceil:
			_cell_surface(paint_ceil[id], func(c): return ceiling_height(c), _fillable_ceiling(_painted_mat(id).duplicate()), true).layers = CEIL_LAYER
		# Classic zone: bright drop-ceiling tiles (the reference backrooms look)
		if not classic_ceil.is_empty():
			_cell_surface(classic_ceil, func(c): return ceiling_height(c), _acoustic_ceiling(Color(0.95, 0.9, 0.72)), true).layers = CEIL_LAYER
		if not shell: _build_ceiling_collision(floor_cells)
	if not floors: return
	# The floor is a one-sided surface: seen from below, through a hole in the ceiling under it, it isn't there,
	# and the walls and pillars standing on it hang in mid-air. The slab gets an underside of plaster.
	if not (through.is_empty() and open_above.is_empty() and holes_below.is_empty()):
		_cell_surface(floor_cells, func(_c): return -0.4, _plaster_mat(), true)
	var carpet: Material = _pbr_or("floor") if _has_pbr("floor") else _carpet_material(Color(1.0, 0.94, 0.75))
	_cell_surface(carpet_cells, func(_c): return 0.0, carpet, false)
	for id in paint_floor:
		_cell_surface(paint_floor[id], func(_c): return 0.0, _painted_mat(id), false)
	# Classic zone: glowing mono-yellow carpet
	if not classic_floor.is_empty():
		_cell_surface(classic_floor, func(_c): return 0.0, _carpet_material(Color(1.2, 1.05, 0.62)), false)

	# Polished commercial tile rooms: high-res PBR vinyl composite tiles with wax sheen and normal-mapped bevels
	if not tile_cells.is_empty():
		var tm: StandardMaterial3D = _pbr_or("tiles")
		if tm == null:
			tm = _default_tile_material()
		_cell_surface(tile_cells, func(_c): return 0.0, tm, false, 0)

	if shell: return
	_build_floor_collision(floor_cells)
	_build_hole_collision()

const CarpetPOMShader := preload("res://shaders/carpet_pom.gdshader")

func _carpet_material(tint := Color(1.0, 0.94, 0.75)) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = CarpetPOMShader
	sm.set_shader_parameter("albedo_tex", load("res://textures/l0_carpet_color.webp"))
	sm.set_shader_parameter("normal_tex", load("res://textures/l0_carpet_normal.webp"))
	sm.set_shader_parameter("roughness_tex", load("res://textures/l0_carpet_rough.webp"))
	sm.set_shader_parameter("ao_tex", load("res://textures/l0_carpet_ao.webp"))
	sm.set_shader_parameter("height_tex", load("res://textures/l0_carpet_height.png"))
	sm.set_shader_parameter("albedo_tint", tint)
	sm.set_shader_parameter("uv_scale", Vector2(0.5, 0.5))
	sm.set_shader_parameter("normal_scale", 2.4)
	sm.set_shader_parameter("roughness_mult", 0.88)
	sm.set_shader_parameter("metallic_specular", 0.35)
	sm.set_shader_parameter("ao_light_affect", 0.75)
	sm.set_shader_parameter("height_scale", 0.04)
	# parallax march length by preset (Gfx `post`: 0 low, 1 medium, 2 high/ultra); 0 layers = no POM at all
	var q := clampi(int(Gfx.s.get("post", 2)), 0, 2)
	sm.set_shader_parameter("min_layers", [0, 4, 6][q])
	sm.set_shader_parameter("max_layers", [0, 8, 14][q])
	sm.set_shader_parameter("near_distance", 10.0)
	sm.set_shader_parameter("near_fade_range", 2.5)
	sm.set_shader_parameter("crevice_ao_strength", 0.6)
	sm.set_shader_parameter("mid_distance", 30.0)
	sm.set_shader_parameter("mid_fade_range", 5.0)
	return sm

const AcousticCeilingShader := preload("res://shaders/acoustic_ceiling.gdshader")

## The Level 0 drop ceiling (acoustic_ceiling.gdshader): the l0_ceiling tiles with a fine fibre grain that
## catches the light. Registered in ceil_mats for level_lighting.gd's bounce-light fill.
func _acoustic_ceiling(tint: Color) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = AcousticCeilingShader
	sm.set_shader_parameter("albedo_tex", load("res://textures/l0_ceiling_color.webp"))
	sm.set_shader_parameter("normal_tex", load("res://textures/l0_ceiling_normal.webp"))
	sm.set_shader_parameter("rough_tex", load("res://textures/l0_ceiling_rough.webp"))
	sm.set_shader_parameter("ao_tex", load("res://textures/l0_ceiling_ao.webp"))
	sm.set_shader_parameter("albedo_tint", tint)
	sm.set_shader_parameter("ao_light_affect", AO_DIRECT)
	ceil_mats.append(sm)
	return sm

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
	tm.ao_light_affect = AO_DIRECT
	tm.metallic = 0.02
	tm.metallic_specular = 0.55
	tm.uv1_triplanar = true
	tm.uv1_world_triplanar = true
	tm.uv1_scale = Vector3(1.0 / 2.25, 1.0 / 2.25, 1.0 / 2.25)
	tm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return tm

# ---------------------------------------------------------------- merged collision
## Greedy-merge grid cells into as few rectangles as possible: from each unclaimed cell in `must` (row by
## row), grow right, then down while every cell of the next row is in `must` or `may`. `may` cells are
## filler (solid anyway, e.g. buried wall cells) that let rectangles join but never start one. A rectangle
## never crosses a COLLIDER_CHUNK boundary, so each box stays local for the physics broadphase.
func _merge_rects(must: Dictionary, may := {}) -> Array[Rect2i]:
	var free := must.duplicate()
	var fill := may.duplicate()
	var keys := free.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	var out: Array[Rect2i] = []
	for c: Vector2i in keys:
		if not free.has(c): continue
		var x_end := (floori(float(c.x) / COLLIDER_CHUNK) + 1) * COLLIDER_CHUNK
		var y_end := (floori(float(c.y) / COLLIDER_CHUNK) + 1) * COLLIDER_CHUNK
		var w := 1
		while c.x + w < x_end:
			var n := Vector2i(c.x + w, c.y)
			if not (free.has(n) or fill.has(n)): break
			w += 1
		var h := 1
		while c.y + h < y_end:
			var row_ok := true
			for dx in w:
				var n := Vector2i(c.x + dx, c.y + h)
				if not (free.has(n) or fill.has(n)):
					row_ok = false
					break
			if not row_ok: break
			h += 1
		for dy in h:
			for dx in w:
				free.erase(Vector2i(c.x + dx, c.y + dy))
				fill.erase(Vector2i(c.x + dx, c.y + dy))
		out.append(Rect2i(c, Vector2i(w, h)))
	return out

## One box per merged rectangle of cells, `thick` tall and centred at height `y`
func _add_merged_boxes(body: StaticBody3D, rects: Array[Rect2i], thick: float, y: float) -> void:
	for r in rects:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(r.size.x * CELL, thick, r.size.y * CELL)
		cs.shape = bs
		cs.position = Vector3((r.position.x + (r.size.x - 1) / 2.0) * CELL, y, (r.position.y + (r.size.y - 1) / 2.0) * CELL)
		body.add_child(cs)

func _cell_set(cells: Array) -> Dictionary:
	var d := {}
	for c in cells: d[c] = true
	return d

func _build_floor_collision(floor_cells: Array) -> void:
	# Floor collision: thin slabs merged over runs of floor cells (pits stay open)
	var body := StaticBody3D.new()
	add_child(body)
	_add_merged_boxes(body, _merge_rects(_cell_set(floor_cells)), 0.4, -0.2)

## Ceiling collision: one thin box per cell at that cell's own ceiling_height(). Neither ceiling style
## (the plain quad above, or level_fixtures.gd's panel ceiling) has ever carried a collider, so nothing
## has ever stopped a jump, a shove or a tall entity from poking straight through into the unlit plenum
## above it - only ever noticed at a low ceiling because that's the one height anything can actually reach.
func _build_ceiling_collision(floor_cells: Array) -> void:
	var body := StaticBody3D.new()
	add_child(body)
	var by_height := {}                  # merged per ceiling height, so a slab never spans a step
	for c in floor_cells:
		if open_above.has(c): continue   # a hole in the floor above: you come down through here
		by_height.get_or_add(ceiling_height(c), {})[c] = true
	for ch: float in by_height:
		_add_merged_boxes(body, _merge_rects(by_height[ch]), 0.4, ch + 0.2)

## The sides of the holes through the slabs: under this floor's own through-pits down to the ceiling of the
## floor below, and over this floor's ceiling up to the hole in the floor above. Someone falling through is
## handed from one floor to the next half way down the slab (level_builder.gd), so each floor walls its own
## half and the other's: without them you could steer sideways into the slab and come down on a ceiling.
func _build_hole_collision() -> void:
	var tris := PackedVector3Array()
	var half := CELL / 2.0
	for part: Array in [[through, WALL_H - STOREY_H, 0.0], [open_above, WALL_H, STOREY_H]]:
		var holes: Dictionary = part[0]
		for c: Vector2i in holes:
			for n: Vector2i in DIRS:
				if holes.has(c + n): continue
				var mid := Vector3(c.x * CELL + n.x * half, 0.0, c.y * CELL + n.y * half)
				var along := Vector3(n.y, 0.0, n.x) * half
				var lo := Vector3(0.0, part[1], 0.0)
				var hi := Vector3(0.0, part[2], 0.0)
				tris.append_array([mid - along + lo, mid + along + lo, mid + along + hi, mid - along + lo, mid + along + hi, mid - along + hi])
	if tris.is_empty(): return
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = true
	cs.shape = shape
	body.add_child(cs)
	add_child(body)

## Occlusion culling with baked portals:
## Partitions solid wall blocks into spatial 8x8 cell grid chunks with boundary occlusion quads,
## leaving doorway openings as natural portals. Omission of interior faces and localized AABBs
## allow fast frustum culling and prevent GPU rasterization of closed corridors.
func _build_occluder(groups: Dictionary) -> void:
	var h := CELL / 2.0
	# Collect cells per height into 8x8 spatial chunks: ch -> Array of [Vector2i, height]
	var chunks := {}
	for height in groups.keys():
		var h_val: float = float(height)
		for c: Vector2i in groups[height]:
			var ch := Vector2i(c.x / 8, c.y / 8)
			chunks.get_or_add(ch, []).append([c, h_val])

	for ch in chunks:
		var cell_list: Array = chunks[ch]
		var verts := PackedVector3Array()
		var idx := PackedInt32Array()

		for item in cell_list:
			var c: Vector2i = item[0]
			var wall_height: float = item[1]
			var x := c.x * CELL
			var z := c.y * CELL

			var p0 := Vector3(x - h, 0.0, z - h)
			var p1 := Vector3(x + h, 0.0, z - h)
			var p2 := Vector3(x + h, 0.0, z + h)
			var p3 := Vector3(x - h, 0.0, z + h)

			var t0 := Vector3(x - h, wall_height, z - h)
			var t1 := Vector3(x + h, wall_height, z - h)
			var t2 := Vector3(x + h, wall_height, z + h)
			var t3 := Vector3(x - h, wall_height, z + h)

			# North face (facing z - 1)
			if not _block_at(c + Vector2i(0, -1)):
				var b := verts.size()
				verts.append_array([p0, t0, t1, p1])
				idx.append_array([b, b + 1, b + 3, b + 3, b + 1, b + 2])

			# South face (facing z + 1)
			if not _block_at(c + Vector2i(0, 1)):
				var b := verts.size()
				verts.append_array([p3, p2, t2, t3])
				idx.append_array([b, b + 1, b + 3, b + 1, b + 2, b + 3])

			# East face (facing x + 1)
			if not _block_at(c + Vector2i(1, 0)):
				var b := verts.size()
				verts.append_array([p1, t1, t2, p2])
				idx.append_array([b, b + 1, b + 3, b + 3, b + 1, b + 2])

			# West face (facing x - 1)
			if not _block_at(c + Vector2i(-1, 0)):
				var b := verts.size()
				verts.append_array([p0, p3, t3, t0])
				idx.append_array([b, b + 1, b + 3, b + 1, b + 2, b + 3])

			# Top face (blocks over-the-wall line of sight in atriums/stairs)
			var b_top := verts.size()
			verts.append_array([t0, t1, t2, t3])
			idx.append_array([b_top, b_top + 3, b_top + 1, b_top + 1, b_top + 3, b_top + 2])

		if verts.is_empty():
			continue

		var occ := ArrayOccluder3D.new()
		occ.set_arrays(verts, idx)
		var oi := OccluderInstance3D.new()
		oi.occluder = occ
		add_child(oi)

const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## Does a solid wall block stand in this cell? Not where an object stands in for it (a door, a thin wall)
## and not in a stairwell, which is a wall to the grid but builds its own.
func _block_at(c: Vector2i) -> bool:
	return walls.has(c) and not carved.has(c) and not stair_cells.has(c)

func _build_walls() -> void:
	var groups := {WALL_H: [], TALL_H: []}
	for c: Vector2i in walls.keys():
		if not _block_at(c): continue     # a door / thin wall object or a stairwell stands here instead of a solid block
		var exposed := false
		var near_tall := false
		for n: Vector2i in DIRS:
			# a door / thin wall only fills a sliver of its cell, so the block beside it still shows
			if not _block_at(c + n): exposed = true
			if tall.has(c + n): near_tall = true
		if exposed:
			groups[TALL_H if near_tall else WALL_H].append(c)
	_build_occluder(groups)
	if not shell: _build_wall_collision(groups)
	# cells painted with a material get their own group per (height, material)
	var pw := painted("wall")
	if not pw.is_empty():
		for height in groups.keys():
			var keep := []
			for c in groups[height]:
				if pw.has(c): groups.get_or_add("%s|%s" % [height, pw[c]], []).append(c)
				else: keep.append(c)
			groups[height] = keep
	var mats := {WALL_H: wall_mat, TALL_H: tall_wall_mat}
	for key in groups.keys():
		var list: Array = groups[key]
		if list.is_empty(): continue
		var height: float = float(str(key).get_slice("|", 0))
		var mat: Material = _painted_mat(str(key).get_slice("|", 1)) if key is String else mats[key]
		var chunks := {}
		for c: Vector2i in list:
			var ch := Vector2i(c.x / 8, c.y / 8)
			chunks.get_or_add(ch, []).append(c)
		for ch in chunks:
			var ch_list: Array = chunks[ch]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			var box := BoxMesh.new()
			box.size = Vector3(CELL, height, CELL)
			mm.mesh = box
			mm.instance_count = ch_list.size()
			var buf := MMBuffer.alloc(mm)
			var st := MMBuffer.stride(mm)
			for i in ch_list.size():
				var c: Vector2i = ch_list[i]
				MMBuffer.put_at(buf, i * st, Vector3(c.x * CELL, height / 2.0, c.y * CELL))
			mm.buffer = buf
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = mat
			# No visibility_range: it measures to the chunk's AABB centre, so walls in plain view down a
			# long corridor dithered out. Unseen chunks are already dropped by frustum + occlusion culling.
			add_child(mmi)

## Wall collision: the exposed blocks of each height merged into large boxes per chunk (see _merge_rects)
## instead of one box per block. Buried blocks (walled in on every side, never drawn) are filler: they
## let a thick wall become one box instead of a ring of them.
func _build_wall_collision(groups: Dictionary) -> void:
	var buried := {}
	for c: Vector2i in walls.keys():
		if _block_at(c): buried[c] = true
	for height in groups.keys():
		for c in groups[height]: buried.erase(c)
	var body := StaticBody3D.new()
	add_child(body)
	for height: float in groups.keys():
		if groups[height].is_empty(): continue
		_add_merged_boxes(body, _merge_rects(_cell_set(groups[height]), buried), height, height / 2.0)

# The editor's free-placed objects (level_data.gd `objects`). Each one is built in its own local frame,
# facing +X (the way you walk through it) and spanning `scale` cells along Z, then placed with
# object_transform(). Wall height follows the cell it stands in (tall next to an atrium). Types without a
# builder of their own are built by their object_types.json "shape" (or "model", for clutter).
func _build_objects() -> void:
	var shaped: Array = []
	var arch: Array = []
	var props: Array = []
	for o: Dictionary in objects:
		match o.type:
			"door": _build_door(o)
			"arch": arch.append(o)
			"stairs_up", "stairs_down": _build_stairs(o)
			_:
				var info := object_info(o.type)
				if info.has("model"):
					props.append(o)
					continue
				match str(info.get("shape", "")):
					"slab", "corner", "arc": shaped.append(o)
					"pillar", "column": _build_column(o)
					"zone":
						if not shell: _build_trigger(o)
	_build_shaped_walls(shaped)
	_build_arches(arch)
	_build_props(props)

# Decorative clutter (levels/object_types.json entries with a "model" key): one imported mesh each, no
# effect on the grid, nav or walls. See props/industrial_prop.gd for how the material is put together.
func _build_props(list: Array) -> void:
	for o: Dictionary in list:
		var info := object_info(o.type)
		var p := IndustrialProp.new()
		p.transform = object_transform(o) * Transform3D(Basis.from_scale(Vector3.ONE * o.scale), Vector3.ZERO)
		add_child(p)
		p.build(str(info.model), info.get("textures", {}), {} if shell else info.get("light", {}), float(info.get("model_yaw", 0.0)))
		for l in p.find_children("*", "Light3D", true, false):
			(l as Light3D).light_cull_mask &= ~SHELL_LAYERS      # a work lamp lights its own floor, not the ones under it

func _object_wall_h(o: Dictionary) -> float:
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	var all_low := true
	for n: Vector2i in DIRS + [Vector2i.ZERO]:
		var cell: Vector2i = c + n
		if tall.has(cell): return TALL_H
		if not low.has(cell): all_low = false
	return LOW_H if all_low else WALL_H

## The clear height directly over `pos` (world) if it's under an arch's crown, else INF. The crown's
## curve dips well below the room's own ceiling_height() near the springline, so anything tall passing
## under it (bacteria_rig.gd) needs this, not just the flat per-cell height.
func arch_clearance(pos: Vector3) -> float:
	var best := INF
	var pillar := float(object_info("arch").get("pillar", 0.75))
	for o: Dictionary in objects:
		if o.type != "arch":
			continue
		var xf := object_transform(o)
		var local := xf.affine_inverse() * pos
		var d := CELL * 0.5
		if absf(local.x) > d:
			continue
		var w: float = CELL * o.scale - pillar * 2.0
		var r := w * 0.5
		if r <= 0.0 or absf(local.z) > r:
			continue
		var h := _object_wall_h(o)
		var rise := minf(r, h - ARCH_SPRING - 0.3)
		var t := local.z / r
		var clear := ARCH_SPRING + rise * sqrt(maxf(0.0, 1.0 - t * t))
		best = minf(best, clear)
	return best

## One box collider under `body`, placed by `xf` (object space) at local `pos`
func _add_box_collider(body: StaticBody3D, xf: Transform3D, size: Vector3, pos: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = xf * Transform3D(Basis(), pos)
	body.add_child(cs)

# Walls of any plan shape (object_types.json "shape": "slab" straight, "corner" an L, "arc" a curve): the
# centre line from shape_path() swept `thick` wide and `height` tall (0 = up to the ceiling), in the same
# wallpaper as the maze so it reads as part of it. One mesh each (mitred joints, so a curve is smooth and a
# corner closed), a box collider per straight run under one StaticBody3D, and occluders when full height.
func _build_shaped_walls(list: Array) -> void:
	if list.is_empty(): return
	var body := StaticBody3D.new()           # filled before it joins the tree: each shape added to a live body rebuilds it
	for o: Dictionary in list:
		var full := _object_wall_h(o)
		var h := minf(o.height, full) if float(o.get("height", 0.0)) > 0.0 else full
		var t := object_thick(o)
		var xf := object_transform(o)
		var path := shape_path(o)
		if path.size() < 2: continue
		var mi := MeshInstance3D.new()
		mi.mesh = _sweep_wall(path, t, h)
		mi.transform = xf
		mi.material_override = tall_wall_mat if h > WALL_H else wall_mat
		add_child(mi)
		var n := path.size()
		var closed := n > 2 and path[0].distance_to(path[n - 1]) < 0.001
		for i in n - 1:
			var a := Vector3(path[i].x, 0.0, path[i].y) * CELL
			var b := Vector3(path[i + 1].x, 0.0, path[i + 1].y) * CELL
			var run := b - a
			if run.length() < 0.001: continue
			# joints overlap by half the thickness so the boxes leave no gap on the outside of a bend
			var grow_a := t * 0.5 if (i > 0 or closed) else 0.0
			var grow_b := t * 0.5 if (i < n - 2 or closed) else 0.0
			var dir := run.normalized()
			var mid := (a + b) * 0.5 + dir * (grow_b - grow_a) * 0.5
			var seg := xf * Transform3D(Basis(Vector3.UP, atan2(-dir.z, dir.x)), mid)
			var size := Vector3(run.length() + grow_a + grow_b, h, t)
			_add_box_collider(body, seg, size, Vector3(0, h * 0.5, 0))
			if h >= full - 0.01:
				var oi := OccluderInstance3D.new()
				var bo := BoxOccluder3D.new()
				bo.size = Vector3(run.length(), h, t)
				oi.occluder = bo
				oi.transform = seg * Transform3D(Basis(), Vector3(0, h * 0.5, 0))
				add_child(oi)
	add_child(body)

## A wall `t` thick and `h` tall along `path` (object space, cells): both faces offset from the centre line
## with mitred joints, a top, and end caps unless the path closes on itself. The faces shade smoothly
## where the path turns gently (a curve) and keep a hard edge at a sharp turn (a corner). No UVs: the wall
## materials are world triplanar.
func _sweep_wall(path: PackedVector2Array, t: float, h: float) -> ArrayMesh:
	var p: Array[Vector2] = []
	for v in path: p.append(v * CELL)
	var closed := p.size() > 2 and p[0].distance_to(p[-1]) < 0.01
	if closed: p.remove_at(p.size() - 1)
	var n := p.size()
	var segs := n if closed else n - 1
	var side: Array[Vector2] = []              # each run's left-hand normal (2D x / z)
	for i in segs:
		var d := (p[(i + 1) % n] - p[i]).normalized()
		side.append(Vector2(-d.y, d.x))
	var off: Array[Vector2] = []               # the mitre at each point: where the left face sits
	var smooth: Array[bool] = []
	for i in n:
		var before: Vector2 = side[(i - 1 + segs) % segs] if (closed or i > 0) else side[0]
		var after: Vector2 = side[i % segs] if (closed or i < n - 1) else side[segs - 1]
		var m := (before + after).normalized()
		off.append(m * (t * 0.5 / maxf(m.dot(after), 0.3)))
		smooth.append(before.dot(after) > 0.85)          # under ~30 degrees: part of a curve
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var at := func(q: Vector2, y: float) -> Vector3: return Vector3(q.x, y, q.y)
	for i in segs:
		var j := (i + 1) % n
		for sgn: float in [1.0, -1.0]:
			var face := side[i] * sgn
			var ni: Vector2 = off[i].normalized() * sgn if smooth[i] else face
			var nj: Vector2 = off[j].normalized() * sgn if smooth[j] else face
			var a: Vector3 = at.call(p[i] + off[i] * sgn, 0.0)
			var b: Vector3 = at.call(p[j] + off[j] * sgn, 0.0)
			_quad(st, [a, b, b + Vector3(0, h, 0), a + Vector3(0, h, 0)],
				[at.call(ni, 0.0), at.call(nj, 0.0), at.call(nj, 0.0), at.call(ni, 0.0)], at.call(face, 0.0))
		var top := [at.call(p[i] + off[i], h), at.call(p[j] + off[j], h), at.call(p[j] - off[j], h), at.call(p[i] - off[i], h)]
		_quad(st, top, [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP], Vector3.UP)
	if not closed:
		for end: int in [0, n - 1]:
			var out: Vector2 = (p[0] - p[1]).normalized() if end == 0 else (p[n - 1] - p[n - 2]).normalized()
			var o3: Vector3 = at.call(out, 0.0)
			var l: Vector3 = at.call(p[end] + off[end], 0.0)
			var r: Vector3 = at.call(p[end] - off[end], 0.0)
			_quad(st, [l, r, r + Vector3(0, h, 0), l + Vector3(0, h, 0)], [o3, o3, o3, o3], o3)
	return st.commit()

## Two triangles a-b-c, a-c-d, wound so they face `facing` (Godot's front faces are clockwise)
func _quad(st: SurfaceTool, v: Array, nrm: Array, facing: Vector3) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	if (v[1] - v[0]).cross(v[2] - v[0]).dot(facing) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for k in order:
		st.set_normal(nrm[k])
		st.add_vertex(v[k])

# A free-standing pillar (square, wallpapered like the walls) or column (round, painted plaster),
# `thick` metres across and `height` tall (0 = up to the ceiling). Nav treats it as a circle to be pushed
# out of (level_data.gd), the player as a solid.
func _build_column(o: Dictionary) -> void:
	var full := _object_wall_h(o)
	var h := minf(o.height, full) if float(o.get("height", 0.0)) > 0.0 else full
	var w := object_thick(o)
	var round_one := str(object_info(o.type).get("shape", "")) == "column"
	var mi := MeshInstance3D.new()
	var cs := CollisionShape3D.new()
	if round_one:
		var cyl := CylinderMesh.new()
		cyl.top_radius = w * 0.5
		cyl.bottom_radius = w * 0.5
		cyl.height = h
		cyl.radial_segments = 24
		cyl.rings = 1
		mi.mesh = cyl
		mi.material_override = _plaster_mat()
		var shape := CylinderShape3D.new()
		shape.radius = w * 0.5
		shape.height = h
		cs.shape = shape
	else:
		var box := BoxMesh.new()
		box.size = Vector3(w, h, w)
		mi.mesh = box
		mi.material_override = tall_wall_mat if h > WALL_H else wall_mat
		var shape := BoxShape3D.new()
		shape.size = Vector3(w, h, w)
		cs.shape = shape
	mi.transform = object_transform(o) * Transform3D(Basis(), Vector3(0, h * 0.5, 0))
	add_child(mi)
	var body := StaticBody3D.new()
	body.transform = mi.transform
	body.add_child(cs)
	add_child(body)

## Painted plaster for round columns: the pit shafts' concrete, fine-grained and tinted a pale warm cream
## (wallpaper, being projected flat, smears round a cylinder)
var _plaster: StandardMaterial3D
func _plaster_mat() -> StandardMaterial3D:
	if _plaster == null:
		_plaster = StandardMaterial3D.new()
		_plaster.albedo_texture = load("res://textures/concrete_color.jpg")
		_plaster.albedo_color = Color(1.0, 0.95, 0.8)
		_plaster.normal_enabled = true
		_plaster.normal_texture = load("res://textures/concrete_normal.jpg")
		_plaster.normal_scale = 0.35
		_plaster.roughness = 0.9
		_plaster.metallic_specular = 0.3
		_plaster.uv1_triplanar = true
		_plaster.uv1_world_triplanar = true
		_plaster.uv1_scale = Vector3(0.6, 0.6, 0.6)
		_plaster.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return _plaster

# An invisible event trigger (props/event_trigger.gd): the box `depth` cells along its arrow by `scale`
# across, watching for the player
func _build_trigger(o: Dictionary) -> void:
	var t := EventTrigger.new()
	t.transform = object_transform(o)
	t.setup(self, o, CELL)
	add_child(t)

# A round-topped opening through a full CELL-deep wall: straight jambs up to ARCH_SPRING, then a
# semicircular crown (flattened if a wide arch would hit the ceiling), solid wall to either side of the
# opening and above it. The opening is the span minus a fixed pillar each side, so a 1-cell arch opens
# 4.5 m less a pillar each side (object_types.json) and a wider one opens up to match.
func _build_arches(list: Array) -> void:
	if list.is_empty(): return
	var crown: Array = []                  # world-space triangles, clockwise-front (Godot's convention)
	var under := {}                        # wall height -> [world pos, uv] for the crown's underside
	var body := StaticBody3D.new()
	add_child(body)
	var d := CELL * 0.5
	var pillar := float(object_info("arch").get("pillar", 0.75))
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
			var oi := OccluderInstance3D.new()
			var bo := BoxOccluder3D.new()
			bo.size = size
			oi.occluder = bo
			oi.transform = xf * Transform3D(Basis(), pos)
			add_child(oi)
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
	d.build(CELL * o.scale, float(object_info("door").get("thickness", 0.3)), h, tall_wall_mat if h > WALL_H else wall_mat, door_frame_mat, door_leaf_mat, door_hw_mat)

# A stairwell (props/stairs.gd builds and runs it): a boxed-in switchback stair standing on its cells, with a
# flight up to the next floor wherever that floor has a stairwell on the same cells, and a flight down likewise.
# What it is given of the floors above and below is their end of the well, so the part the two floors share
# is built the same on both: the floor is swapped under you half way up, and nothing you can see changes.
func _build_stairs(o: Dictionary) -> void:
	if shell:
		add_child(stair_skin(o))
		return
	var f := floor_no
	var ends := {}                          # floors up from here (-1, 0, 1) -> that floor's end of the well
	ends[0] = o
	for d: int in [-1, 1]:
		var p := stair_partner(level_raw, f + d, o)
		if not p.is_empty(): ends[d] = p
	var room_h := _stair_room_h(o)
	var s := Stairs.new()
	s.transform = _stair_xf(o)
	add_child(s)
	# inside, the plain wallpaper, without the room walls' baked skirting and ceiling shadow (the well has its own
	# boards, and they would hang in mid-air beside a flight)
	var paper: StandardMaterial3D = _pbr_or("wall")
	if paper == null:
		paper = _mat("l0_wallpaper", Vector3.ONE / 2.25, Color(1.0, 0.98, 0.88))
		paper.roughness = 0.95
		paper.normal_scale = 0.95
		paper.metallic_specular = 0.28
	s.build(self, ends, f, room_h, {
		"wall": paper, "room_wall": tall_wall_mat if room_h > WALL_H else wall_mat,
		"floor": _pbr_or("floor") if _has_pbr("floor") else _mat("l0_carpet", Vector3(0.5, 0.5, 0.5), Color(1.0, 0.94, 0.75)),
		"plaster": _plaster_mat(), "trim": door_frame_mat, "wood": door_leaf_mat, "metal": door_hw_mat})
	stairwells.append(s)

## The ceiling a stairwell's box has to reach: the highest round it
func _stair_room_h(o: Dictionary) -> float:
	var room_h := 0.0
	for c in stair_footprint(o):
		for n: Vector2i in DIRS:
			if not walls.has(c + n): room_h = maxf(room_h, ceiling_height(c + n))
	return room_h if room_h > 0.0 else WALL_H

func _stair_xf(o: Dictionary) -> Transform3D:
	return object_transform(o) * Transform3D(Basis(), Vector3(0, 0, -CELL * 0.5 * (STAIR_WIDE - 1)))     # the middle of the well

## A stairwell as a look-only floor has it: the box the room sees and nothing inside. The stair itself is
## built by the floor you are on, right through the floors it joins, and two copies of it would overlap.
func stair_skin(o: Dictionary) -> Node3D:
	var room_h := _stair_room_h(o)
	var s := Stairs.new()
	s.transform = _stair_xf(o)
	s.build_outside(room_h, {"room_wall": tall_wall_mat if room_h > WALL_H else wall_mat, "trim": door_frame_mat, "metal": door_hw_mat})
	return s

# Where two open cells have different ceiling heights, a wallpapered drop closes the gap
# (like a drywall bulkhead) with a trim strip along its bottom edge.
func _build_ceiling_steps() -> void:
	var batches := [
		{"height": WALL_H, "st": SurfaceTool.new(), "n": 0},
		{"height": TALL_H, "st": SurfaceTool.new(), "n": 0}
	]
	for b in batches: (b.st as SurfaceTool).begin(Mesh.PRIMITIVE_TRIANGLES)
	var trims: Array = []
	var collider_tris := PackedVector3Array()
	var half := CELL / 2.0
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			# a solid wall cell has no ceiling to step from, but a carved one (a door / thin wall
			# standing in for the block) opens up to WALL_H / TALL_H same as any open cell, so a
			# neighbouring low room still needs its bulkhead closing the gap up to that opening
			if walls.has(c) and not carved.has(c): continue
			for dv: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var nb: Vector2i = c + dv
				if walls.has(nb) and not carved.has(nb): continue
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
					collider_tris.append(pts[i][0])
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
	if not collider_tris.is_empty():
		var body := StaticBody3D.new()
		add_child(body)
		var cs := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(collider_tris)
		shape.backface_collision = true
		cs.shape = shape
		body.add_child(cs)
	if trims.is_empty(): return
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color("cfc6a8")
	tm.roughness = 0.75
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()
	mm.instance_count = trims.size()
	var buf := MMBuffer.alloc(mm)
	var st := MMBuffer.stride(mm)
	for i in trims.size():
		var t: Dictionary = trims[i]
		var sc := Vector3(CELL if t.along_x else 0.1, 0.1, 0.1 if t.along_x else CELL)
		MMBuffer.put(buf, i * st, Transform3D(Basis.from_scale(sc), Vector3(t.x, t.y, t.z)))
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = tm
	add_child(mmi)

# Pit shafts: the cut edge of the floor slab, then raw concrete walls falling away into
# blackness (vertex colours darken with depth), and a black bottom. A pit that opens into the floor below
# (`through`) is only the hole through the slab between the two: its sides, down to that floor's ceiling.
func _build_pit_shafts() -> void:
	# An open ceiling with no room over it to look up into (the top floor, or solid wall above): a shaft
	# rising into the dark, the pit's own turned over. Under another floor it stops at that floor's slab.
	var top := WALL_H
	if in_stack(level_raw, floor_no + 1):
		_pit_shaft(shaft_up, [top, top + 0.32, top + 1.1, top + 2.4, STOREY_H])
	else:
		_pit_shaft(shaft_up, [top, top + 0.32, top + 1.1, top + 2.4, top + 4.4, top + 7.0, top + 10.4, top + PIT_DEPTH])
	if pits.is_empty(): return
	# the bottomless ones (level_data.gd `abyss`) are pit_fall.gd's to build, on the floor you walk on; a
	# look-only floor (level_shell.gd) shows them as ordinary deep pits, dark at the bottom
	var bottomless := not shell and not abyss.is_empty()
	if bottomless:
		var pf := PitFall.new()
		pf.name = "PitFall"
		add_child(pf)
		pf.setup(self)
		pit_fall = pf
	var deep := {}
	for c: Vector2i in pits:
		if not through.has(c) and not (bottomless and abyss.has(c)): deep[c] = true
	# a pit with a wall under it on the floor below runs on down inside that wall, and stops short of a room two floors down
	var depth := PIT_DEPTH
	if in_stack(level_raw, floor_no - 1) and in_stack(level_raw, floor_no - 2):
		var under: Array = floor_data(level_raw, floor_src(level_raw, floor_no - 2))["grid"]
		for c: Vector2i in deep:
			if c.y < under.size() and c.x < (under[c.y] as String).length() and under[c.y][c.x] != "#":
				depth = minf(depth, STOREY_H * 2.0 - WALL_H)
				break
	_pit_shaft(deep, [0.0, -0.32, -1.1, -2.4, -4.4, -7.0, -10.4, -depth])
	_pit_shaft(through, [0.0, -0.32, -1.1, -2.4, WALL_H - STOREY_H], false)

func _pit_shaft(cells_in: Dictionary, levels: Array, bottom := true) -> void:
	if cells_in.is_empty(): return
	var H := CELL / 2.0
	var shade: Array[float] = []
	for i in levels.size():
		var far := absf(float(levels[i]) - float(levels[0]))        # how far along the shaft, down or up
		shade.append(1.25 if i == 0 else (1.1 if i == 1 else maxf(0.0, exp(-far * 0.4) * 0.9)))
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
	for c: Vector2i in cells_in.keys():
		cells.append(c)
		var x := c.x * CELL
		var z := c.y * CELL
		if not cells_in.has(c + Vector2i(-1, 0)): wall.call(x - H, z - H, x - H, z + H)
		if not cells_in.has(c + Vector2i(1, 0)): wall.call(x + H, z - H, x + H, z + H)
		if not cells_in.has(c + Vector2i(0, -1)): wall.call(x - H, z - H, x + H, z - H)
		if not cells_in.has(c + Vector2i(0, 1)): wall.call(x - H, z + H, x + H, z + H)
	st.generate_tangents()
	var mats := _pit_materials()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mats[0]
	add_child(mi)
	if bottom:
		_cell_surface(cells, func(_c): return levels[-1], mats[1], float(levels[-1]) > float(levels[0]))     # a shaft going up is closed by a face looking down

## The shafts' concrete and the black of their bottoms: one of each for every floor of every level, made with
## the level's other materials. A kind of material is compiled when the first one of it is made (a fifth of a
## second for these), and the first pit to need one may be on a floor built while the game is being played.
static var _pit_mats: Array = []
static func _pit_materials() -> Array:
	if _pit_mats.is_empty():
		var m := StandardMaterial3D.new()
		m.albedo_texture = load("res://textures/concrete_color.jpg")
		m.normal_enabled = true
		m.normal_texture = load("res://textures/concrete_normal.jpg")
		m.vertex_color_use_as_albedo = true
		m.roughness = 1.0
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		var black := StandardMaterial3D.new()
		black.albedo_color = Color.BLACK
		black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_pit_mats = [m, black]
	return _pit_mats

# Grime clusters: the painted 'grime' zone plus ~6% scattered stains, kept off the spawn room
func _build_dirt() -> void:
	var dirty: Array[Vector2i] = []
	var seen := {}
	var add := func(x: int, z: int) -> void:
		var c := Vector2i(x, z)
		if seen.has(c) or walls.has(c) or pits.has(c) or bright.has(c) or loop.has(c): return
		for dx in range(-1, 2):               # a stain is wider than its cell: none hanging over a stairwell's down flight
			for dz in range(-1, 2):
				if stair_cells.has(c + Vector2i(dx, dz)): return
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
