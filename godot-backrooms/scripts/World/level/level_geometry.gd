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
const VerticalPieces := preload("res://scripts/World/props/vertical_pieces.gd")
const WindowPiece := preload("res://scripts/World/props/window.gd")
const WaterBody := preload("res://scripts/World/props/water_body.gd")
const WaterView := preload("res://scripts/World/props/water_view.gd")
const IndustrialProp := preload("res://scripts/World/props/industrial_prop.gd")
const Stairs := preload("res://scripts/World/props/stairs.gd")
const EventTrigger := preload("res://scripts/World/props/event_trigger.gd")
const MMBuffer := preload("res://scripts/World/mm_buffer.gd")
const PitFall := preload("res://scripts/World/level/pit_fall.gd")
const NoclipSlip := preload("res://scripts/World/level/noclip_slip.gd")
const EndlessShaft := preload("res://scripts/World/level/endless_shaft.gd")
const ARCH_SPRING := 2.4       # height where the straight sides turn into the semicircular crown
const ARCH_SEGS := 16
const SQUEEZE_OPEN_H := 2.3   # height of the slit through a squeeze gap's wall, floor to lintel
const SQUEEZE_FUNNEL := 0.5   # m: how far out from the slit (each side along the wall, and along the way through) counts as "at" it
const COLLIDER_CHUNK := 8      # merged collision boxes never cross an 8x8-cell chunk (same chunks as the wall MultiMeshes)

var wall_mat: StandardMaterial3D
var tall_wall_mat: StandardMaterial3D
var grand_wall_mat: StandardMaterial3D
var door_leaf_mat: StandardMaterial3D
var door_hw_mat: StandardMaterial3D
var door_frame_mat: StandardMaterial3D
## The level's ceiling material when it has light panels baked into it (an emission texture, e.g. Ceiling_Light_Panels).
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
	call("_build_trim")                  # (level_trim.gd, the layer over this one: skirting, fittings, wear)
	_build_ceiling_steps()
	_build_pit_shafts()
	_build_dirt()

## The level's shared materials, before anything is built with them
func _make_materials() -> void:
	_floor_map_tex = null                # (this floor's plan: built with its first carpet)
	_pit_materials()
	_shaft_mat = null
	panel_ceiling = _panel_ceiling_material()
	_uv_wall.clear()
	_tile_uv = null
	wall_mat = _pbr_or("wall", true) if _has_pbr("wall") else _wall_material("wall", WALL_H, true)
	tall_wall_mat = _pbr_or("wall", true) if _has_pbr("wall") else _wall_material("wall_tall", TALL_H, true)
	# (the tall wallpaper, its baked skirting and ceiling shadow stretched on up to a grand hall's ceiling)
	grand_wall_mat = _pbr_or("wall", true) if _has_pbr("wall") else _wall_material("wall_tall", GRAND_H, true)
	if ResourceLoader.exists("res://textures/props/door/door_leaf.tres"):
		door_leaf_mat = (load("res://textures/props/door/door_leaf.tres") as StandardMaterial3D).duplicate()
	else:
		door_leaf_mat = (load("res://textures/pbr/Wood_Dark_Knot/Wood_Dark_Knot.tres") as StandardMaterial3D).duplicate()
		door_leaf_mat.roughness = 0.75
	door_hw_mat = (load("res://textures/pbr/Metal_Grey_Plate/Metal_Grey_Plate.tres") as StandardMaterial3D).duplicate()
	door_hw_mat.roughness = 0.35
	door_frame_mat = StandardMaterial3D.new()          # old painted frame and casing: a dingy warm cream, flat, no sheen
	door_frame_mat.albedo_color = Color(0.40, 0.37, 0.29)
	door_frame_mat.roughness = 0.85
	door_frame_mat.metallic_specular = 0.08

# ---------------------------------------------------------------- materials
## The .lvl's optional "materials" ({wall, floor, ceiling, tiles} -> a folder in textures/pbr/, picked in the
## level editor). Null when the slot is unset, so the caller falls back to the Level 0 look.
func _has_pbr(slot: String) -> bool:
	var id := _mat_id(slot)
	return not id.is_empty() and ResourceLoader.exists("res://textures/pbr/%s/%s.tres" % [id, id])

func _pbr_or(slot: String, _world := false) -> StandardMaterial3D:
	if not _has_pbr(slot):
		return null
	return _pbr_by_id(_mat_id(slot))

## The textures/pbr folder a surface is made of: the level's pick, else the game's default (the ceiling: the
## pool rooms' white tiles, Tile_White_Grid; the rest: the Level 0 look, "")
const DEFAULT_MATERIALS := {"ceiling": "Tile_White_Grid"}
func _mat_id(slot: String) -> String:
	var id := str(level_data.get("materials", {}).get(slot, ""))
	return id if id != "" else str(DEFAULT_MATERIALS.get(slot, ""))

## The level's ceiling lights ("lights" in the .lvl, picked in the level editor): "panels" (the ceiling's own light
## panels; a ceiling with none of its own gets squares of its tiles lit, tile_panel_ceiling.gdshader), "troffers"
## (hanging 1 x 4 fluorescent fixtures, ballasts humming) or "none" (only what the windows and the torch give).
## Troffers are only ever hung when asked for.
func lights_mode() -> String:
	return str(level_data.get("lights", "panels"))

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
	if bool(m.get_meta("tile_panels", false)):
		# a tiled ceiling with light panels (Tile_White_Grid_Lit) used anywhere but as the level's ceiling: plain tiles
		m.emission_enabled = false
	if id.to_lower().contains("tile"):
		# Glazed tile: the photo's roughness map is all but a mirror on the glaze, which under screen-space
		# reflections, bloom and the camera's lens dirt turned every lamp into a blinding pool on the floor and a
		# hot spot on every wall. A satin glaze instead: the lamps still gleam in it, softly.
		m.roughness_texture = null
		m.roughness = 0.46
		m.metallic_specular = 0.3
	if bool(m.get_meta("drop_ceiling", false)):
		# a drop ceiling (Ceiling_Drop*) painted on cells: plain tiles only (its emission map is the light panels'),
		# the texture's two tiles a 1.5 m repeat, and its grid on the level's tile grid (edges half a tile off the
		# cell centres, as drop_ceiling.gdshader lays them)
		m.emission_enabled = false
		m.emission_texture = null
		m.uv1_scale = Vector3.ONE / 1.5
		# (2 x 4 tiles: one long tile across the texture, its ends on the cell edges)
		m.uv1_offset = Vector3(0.5 if bool(m.get_meta("long_tiles", false)) else 0.25, 0.25, 0.25)
	return m

func _panel_ceiling_material() -> StandardMaterial3D:
	if not _has_pbr("ceiling") or lights_mode() != "panels":
		return null
	var id := _mat_id("ceiling")
	var m := load("res://textures/pbr/%s/%s.tres" % [id, id]) as StandardMaterial3D
	if m == null: return null
	# (a tiled ceiling with "tile_panels" draws its panels itself: tile_panel_ceiling.gdshader)
	if m.emission_enabled and (m.emission_texture != null or bool(m.get_meta("tile_panels", false))): return m
	# a ceiling with no light panels of its own: squares of its own tiles lit from behind
	var lit := m.duplicate() as StandardMaterial3D
	lit.emission_enabled = true
	lit.set_meta("tile_panels", true)
	lit.set_meta("panel_tiles", 4)
	return lit

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

## The wall material for a mesh that carries its own UVs, in metres: u along the wall's face, v up it. A world
## (triplanar) projection is only true on faces square to the axes; round a curve it blends two projections and
## the tiles go double and smeared at every 45 degrees. A curved or spline wall and a round column are unrolled
## instead (_sweep_wall, _uv_cylinder), so their tiles run round them unbroken, square and the same size as on
## the walls. `h`: the wall's height, for the wallpaper (stretched to its room's height, as on the blocks).
var _uv_wall := {}
func _wall_uv_mat(h: float) -> StandardMaterial3D:
	var key := GRAND_H if h > TALL_H + 0.01 else (TALL_H if h > WALL_H + 0.01 else WALL_H)
	if _uv_wall.has(key): return _uv_wall[key]
	var m: StandardMaterial3D
	if _has_pbr("wall"):
		m = _pbr_or("wall")
		m.uv1_triplanar = false
		m.uv1_world_triplanar = false
		m.uv1_scale = Vector3(PBR_PER_M, -PBR_PER_M, 1.0)
	else:
		m = _wall_material("wall" if key <= WALL_H else "wall_tall", key, false)
		m.uv1_scale = Vector3(1.0 / 2.25, -1.0 / key, 1.0)
		m.uv1_offset = Vector3(0.0, 1.0, 0.0)
	_uv_wall[key] = m
	return m

const PBR_PER_M := 0.45          # textures/pbr repeats a metre (_pbr_by_id's world scale)

## The tiles zones' tile, for a mesh with its own UVs in metres (a pool's basin in a level not walled in tiles)
var _tile_uv: StandardMaterial3D
func _tile_uv_mat() -> StandardMaterial3D:
	if _tile_uv == null:
		_tile_uv = (_pbr_or("tiles") if _has_pbr("tiles") else _default_tile_material())
		_tile_uv.uv1_triplanar = false
		_tile_uv.uv1_world_triplanar = false
		_tile_uv.uv1_scale = Vector3(PBR_PER_M, -PBR_PER_M, 1.0)
	return _tile_uv

## The world-projected wall material for a wall `h` metres tall (the wallpaper is drawn to its room's height)
func _wall_mat_for(h: float) -> StandardMaterial3D:
	if h > TALL_H + 0.01: return grand_wall_mat
	return tall_wall_mat if h > WALL_H else wall_mat

## How far along a wall one repeat of its material runs, metres (a closed loop is fitted to a whole number of them)
func _wall_repeat() -> float:
	return 1.0 / PBR_PER_M if _has_pbr("wall") else 2.25

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

func _cell_surface(cells: Array, height_fn: Callable, mat: Material, flip: bool, priority := 0, layers := 1) -> Node3D:
	if cells.is_empty():
		return null
	var h := CELL / 2.0
	var n := Vector3.DOWN if flip else Vector3.UP
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
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
	if priority != 0:
		mi.material_override = mat.duplicate()
		mi.material_override.render_priority = priority
	mi.layers = layers
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

# Floors and ceilings are cut into SURF_CHUNK x SURF_CHUNK cell chunks, as the walls are. Each chunk stops being
# drawn once it is wholly past the horizon fog, so the far floor and ceiling cost nothing. No fade: the drop
# happens where the fog is opaque, so there is nothing to dither.
const SURF_CHUNK := 8
const SURF_RANGE_SLACK := 6.0        # m: a ceiling's height varies from cell to cell
const FOG_END := 170.0               # level_lighting.gd HORIZON_END (this script sits below it, so it can't read it)
const WRAP_FOG_END_MAX := 320.0      # the most an endless level's fog reaches (level_builder.gd _apply_wrap_view)

## How far the horizon fog reaches: past this nothing is seen
func _fog_end() -> float:
	if edge_wrap and not shell: return clampf(wrap_size() * 0.95, FOG_END, WRAP_FOG_END_MAX)
	return FOG_END

## _cell_surface, cut into chunks that each carry a visibility range
func _ranged_surface(cells: Array, height_fn: Callable, mat: Material, flip: bool, priority := 0, layers := 1) -> void:
	var chunks := {}
	for c: Vector2i in cells: chunks.get_or_add(Vector2i(c.x / SURF_CHUNK, c.y / SURF_CHUNK), []).append(c)
	# the chunk's centre has to be this far off before its nearest cell can be past the fog
	var reach := _fog_end() + SURF_CHUNK * CELL * sqrt(2.0) / 2.0 + SURF_RANGE_SLACK
	for ch in chunks:
		var mi := _cell_surface(chunks[ch], height_fn, mat, flip, priority, layers) as MeshInstance3D
		mi.visibility_range_end = reach
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

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
	# a pool's outline is cut out of the floor of the cells it reaches into (_cut_cell_tris)
	var polys := _pool_polys()
	var cut := _pool_cut_cells(polys) if not polys.is_empty() else {}
	var cut_keys := {}                       # what a cut cell's floor is made of -> those cells
	var cut_all: Array = []
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			if stair_cells.has(c): continue         # a stairwell: props/stairs.gd builds its own floors and ceilings
			if not crop.is_empty() and not crop.has(c): continue
			if open_above.has(c) or shaft_pass.has(c): pass     # a hole in the floor above, or a shaft from below passing up through this wall: no ceiling
			elif panel_ceiling != null: pass        # built by level_fixtures.gd with its lights
			elif pc.has(c): paint_ceil.get_or_add(pc[c], []).append(c)
			elif classic.has(c): classic_ceil.append(c)
			else: ceil_cells.append(c)
			if pits.has(c): continue
			if cut.has(c):
				var key := ("paint:" + str(pf[c])) if pf.has(c) else ("classic" if classic.has(c) else ("tiles" if tiles.has(c) else "carpet"))
				cut_keys.get_or_add(key, []).append(c)
				cut_all.append(c)
				continue
			floor_cells.append(c)
			if pf.has(c): paint_floor.get_or_add(pf[c], []).append(c)
			elif classic.has(c): classic_floor.append(c)
			elif tiles.has(c): tile_cells.append(c)
			else: carpet_cells.append(c)
	# endless halls: the open border cells are walked on too (the copy beyond the seam draws their floor), so
	# whatever ends up on one (a monster spawned there, a dropped battery) stands on something
	var solid_cells := floor_cells
	if edge_wrap:
		solid_cells = floor_cells.duplicate()
		for c: Vector2i in wrap_ring:
			if not walls.has(c): solid_cells.append(c)
	if ceilings:
		var ceil_m: Material = _fillable_ceiling(_pbr_or("ceiling")) if _has_pbr("ceiling") else _acoustic_ceiling(Color(0.89, 0.85, 0.74))
		_ranged_surface(ceil_cells, func(c): return ceiling_height(c), ceil_m, true, 0, CEIL_LAYER)
		for id in paint_ceil:
			_ranged_surface(paint_ceil[id], func(c): return ceiling_height(c), _fillable_ceiling(_painted_mat(id).duplicate()), true, 0, CEIL_LAYER)
		# Classic zone: bright drop-ceiling tiles (the reference backrooms look)
		if not classic_ceil.is_empty():
			_ranged_surface(classic_ceil, func(c): return ceiling_height(c), _acoustic_ceiling(Color(0.95, 0.9, 0.72)), true, 0, CEIL_LAYER)
		if not shell: _build_ceiling_collision(solid_cells + cut_all)
	if not floors: return
	# The floor is a one-sided surface: seen from below, through a hole in the ceiling under it, it isn't there,
	# and the walls and pillars standing on it hang in mid-air. The slab gets an underside of plaster.
	if not (through.is_empty() and open_above.is_empty() and holes_below.is_empty()):
		_ranged_surface(floor_cells.filter(func(c: Vector2i) -> bool: return not shaft_pass.has(c)), func(_c): return -0.4, _plaster_mat(), true)
	var carpet: Material = _pbr_or("floor") if _has_pbr("floor") else _carpet_material(Color(1.0, 0.94, 0.75))
	_ranged_surface(carpet_cells, func(_c): return 0.0, carpet, false)
	for id in paint_floor:
		_ranged_surface(paint_floor[id], func(_c): return 0.0, _painted_mat(id), false)
	# Classic zone: a clean beige office carpet (the walls carry the yellow)
	if not classic_floor.is_empty():
		_ranged_surface(classic_floor, func(_c): return 0.0, _carpet_material(Color(1.02, 0.93, 0.7)), false)

	# Polished commercial tile rooms: high-res PBR vinyl composite tiles with wax sheen and normal-mapped bevels
	if not tile_cells.is_empty():
		var tm: StandardMaterial3D = _pbr_or("tiles")
		if tm == null:
			tm = _default_tile_material()
		_ranged_surface(tile_cells, func(_c): return 0.0, tm, false, 0)

	if not cut_keys.is_empty():
		var groups := {}
		for k: String in cut_keys:
			var m: Material = carpet
			if k.begins_with("paint:"): m = _painted_mat(k.substr(6))
			elif k == "classic": m = _carpet_material(Color(1.02, 0.93, 0.7))
			elif k == "tiles": m = _pbr_or("tiles") if _has_pbr("tiles") else _default_tile_material()
			groups.get_or_add(m, []).append_array(cut_keys[k])
		_build_cut_floors(groups, polys)

	if shell: return
	_build_floor_collision(solid_cells)
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
	sm.set_shader_parameter("normal_scale", 1.5)
	sm.set_shader_parameter("roughness_mult", 0.94)
	sm.set_shader_parameter("metallic_specular", 0.20)
	sm.set_shader_parameter("ao_light_affect", 0.75)
	sm.set_shader_parameter("height_scale", 0.025)
	# parallax march length by preset (Gfx `post`: 0 low, 1 medium, 2 high/ultra); 0 layers = no POM at all
	var q := clampi(int(Gfx.s.get("post", 2)), 0, 2)
	sm.set_shader_parameter("min_layers", [0, 4, 6][q])
	sm.set_shader_parameter("max_layers", [0, 8, 14][q])
	sm.set_shader_parameter("near_distance", 8.0)
	sm.set_shader_parameter("near_fade_range", 3.0)
	sm.set_shader_parameter("crevice_ao_strength", 0.3)
	sm.set_shader_parameter("mid_distance", 25.0)
	sm.set_shader_parameter("mid_fade_range", 8.0)
	if _floor_map_tex == null: _floor_map_tex = _floor_map()
	sm.set_shader_parameter("floor_map", _floor_map_tex)
	sm.set_shader_parameter("map_cells", float(size))
	sm.set_shader_parameter("map_cell", CELL)
	return sm

## The floor plan the carpet wears by (carpet_pom.gdshader), one texel a cell. r: a solid wall block (the carpet
## greys along its foot), g: foot traffic. People keep to the middle of corridors, all go through a doorway, and
## spread out across a big room, so the fewer open cells round a cell (5 x 5) the more it is walked; then
## smoothed over its neighbours so a lane runs on round a corner. Counted with summed-area tables: a big level
## is tens of thousands of cells.
var _floor_map_tex: ImageTexture
func _floor_map() -> ImageTexture:
	var n := size
	var w := n + 1
	var on_floor := func(c: Vector2i) -> bool: return not _block_at(c) and not stair_cells.has(c) and not pits.has(c)
	var sat := PackedInt32Array()
	sat.resize(w * w)
	for z in n:
		for x in n:
			var v := 1 if on_floor.call(Vector2i(x, z)) else 0
			sat[(z + 1) * w + x + 1] = v + sat[z * w + x + 1] + sat[(z + 1) * w + x] - sat[z * w + x]
	var box_sum := func(t: PackedFloat32Array, x0: int, z0: int, x1: int, z1: int) -> float:
		x0 = clampi(x0, 0, n); z0 = clampi(z0, 0, n); x1 = clampi(x1, 0, n); z1 = clampi(z1, 0, n)
		return t[z1 * w + x1] - t[z0 * w + x1] - t[z1 * w + x0] + t[z0 * w + x0]
	var satf := PackedFloat32Array()
	satf.resize(w * w)
	for i in w * w: satf[i] = sat[i]
	var traffic := PackedFloat32Array()
	traffic.resize(w * w)               # summed-area table of the raw traffic, for the smoothing
	for z in n:
		for x in n:
			var t := 0.0
			if on_floor.call(Vector2i(x, z)):
				var open_round: float = box_sum.call(satf, x - 2, z - 2, x + 3, z + 3) - 1.0
				t = clampf((16.0 - open_round) / 12.0, 0.15, 1.0)
				if carved.has(Vector2i(x, z)): t = 1.0         # a doorway: everyone passes through it
			traffic[(z + 1) * w + x + 1] = t + traffic[z * w + x + 1] + traffic[(z + 1) * w + x] - traffic[z * w + x]
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for z in n:
		for x in n:
			var c := Vector2i(x, z)
			var solid := _block_at(c) or stair_cells.has(c)
			var b := 0.0
			var g := 0.0
			if on_floor.call(c):
				var cnt: float = box_sum.call(satf, x - 1, z - 1, x + 2, z + 2)
				g = box_sum.call(traffic, x - 1, z - 1, x + 2, z + 2) / maxf(cnt, 1.0)
				for dx in range(-1, 2):
					for dz in range(-1, 2):
						if dx == 0 and dz == 0: continue
						var nx: int = x + dx
						var nz: int = z + dz
						if nx >= 0 and nx < n and nz >= 0 and nz < n:
							if _block_at(Vector2i(nx, nz)) or stair_cells.has(Vector2i(nx, nz)):
								b = 1.0
								break
					if b > 0.0: break
			img.set_pixel(x, z, Color(1.0 if solid else 0.0, g, b, 1.0))
	return ImageTexture.create_from_image(img)

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
			if climb_up.has(c) or climb_down.has(c): continue      # stairs run up through it: their rails do this
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
	var groups := {WALL_H: [], TALL_H: [], GRAND_H: []}
	for c: Vector2i in walls.keys():
		if not _block_at(c): continue     # a door / thin wall object or a stairwell stands here instead of a solid block
		var exposed := false
		var reach := WALL_H               # as high as the tallest room it faces
		for n: Vector2i in DIRS:
			# a door / thin wall only fills a sliver of its cell, so the block beside it still shows
			if not _block_at(c + n): exposed = true
			if grand.has(c + n): reach = GRAND_H
			elif tall.has(c + n): reach = maxf(reach, TALL_H)
		if exposed:
			groups[reach].append(c)
	if not shell: _build_wall_collision(groups)
	# endless halls: the border's blocks only stop you (the copy of the level beyond the seam draws them)
	if edge_wrap:
		for height in groups.keys():
			groups[height] = (groups[height] as Array).filter(func(c: Vector2i) -> bool: return not wrap_ring.has(c))
	_build_occluder(groups)
	# cells painted with a material get their own group per (height, material)
	var pw := painted("wall")
	if not pw.is_empty():
		for height in groups.keys():
			var keep := []
			for c in groups[height]:
				if pw.has(c): groups.get_or_add("%s|%s" % [height, pw[c]], []).append(c)
				else: keep.append(c)
			groups[height] = keep
	var mats := {WALL_H: wall_mat, TALL_H: tall_wall_mat, GRAND_H: grand_wall_mat}
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
			# a block standing out into the room gets its outside corners rounded (_wall_block), so they are
			# grouped by which of its edges those are
			var by_shape := {}
			for c: Vector2i in chunks[ch]:
				by_shape.get_or_add(_outer_corners(c), []).append(c)
			for shape: int in by_shape:
				var ch_list: Array = by_shape[shape]
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = _wall_block(height, shape)
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

## Real outside corners are never knife sharp: the drywall's corner bead rounds them, and the rounded edge
## catches the light in a soft line down the corner. The four vertical edges of wall block `c` that are outside
## corners (both sides and the cell across the corner open), as bits in _wall_block's order: +x+z, -x+z,
## -x-z, +x-z. An edge another block meets stays square, or a straight wall would show a notch at every joint.
const CORNER_ROUND := 0.025         # metres
const CORNER_SIGNS := [Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1), Vector2i(1, -1)]
func _outer_corners(c: Vector2i) -> int:
	var m := 0
	for k in 4:
		var s: Vector2i = CORNER_SIGNS[k]
		if not (_solid_at(c + Vector2i(s.x, 0)) or _solid_at(c + Vector2i(0, s.y)) or _solid_at(c + s)): m |= 1 << k
	return m

## A wall block, or a squeeze gap's jambs (they fill their cell edge to edge, so a block beside one keeps its
## corner square and the wall runs on flush)
func _solid_at(c: Vector2i) -> bool:
	if _block_at(c): return true
	if not carved.has(c): return false
	if _squeeze_cells.is_empty():
		for o: Dictionary in objects:
			if o.type == "squeeze_gap": _squeeze_cells[Vector2i(roundi(o.pos_x), roundi(o.pos_y))] = true
		if _squeeze_cells.is_empty(): _squeeze_cells[Vector2i(-9999, -9999)] = true
	return _squeeze_cells.has(c)
var _squeeze_cells := {}

## A wall block CELL square and `height` tall (centred, like the BoxMesh it replaces) with the vertical edges in
## `round_mask` rounded. No bottom (it stands on the floor) and no UVs (the wall materials are world triplanar).
var _blocks := {}
func _wall_block(height: float, round_mask: int) -> Mesh:
	var key := "%s|%d" % [height, round_mask]
	if _blocks.has(key): return _blocks[key]
	var mesh: Mesh
	if round_mask == 0:
		var box := BoxMesh.new()
		box.size = Vector3(CELL, height, CELL)
		mesh = box
	else:
		# the plan's outline, corner by corner round the block: [point, normal before it, normal after it]
		var hc := CELL * 0.5
		var r := CORNER_ROUND
		var ring: Array = []
		for k in 4:
			var s: Vector2i = CORNER_SIGNS[k]
			var mid := PI * 0.25 + PI * 0.5 * k
			if round_mask & (1 << k):
				var ctr := Vector2(s.x * (hc - r), s.y * (hc - r))
				for j in 5:
					var a := mid - PI * 0.25 + PI * 0.5 * j / 4.0
					var nrm := Vector2(cos(a), sin(a))
					ring.append([ctr + nrm * r, nrm, nrm])
			else:
				var a0 := mid - PI * 0.25
				var a1 := mid + PI * 0.25
				ring.append([Vector2(s.x * hc, s.y * hc), Vector2(cos(a0), sin(a0)).round(), Vector2(cos(a1), sin(a1)).round()])
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var lo := -height * 0.5
		var hi := height * 0.5
		var top := Vector3(0.0, hi, 0.0)
		for i in ring.size():
			var a: Array = ring[i]
			var b: Array = ring[(i + 1) % ring.size()]
			var pa := Vector3(a[0].x, 0.0, a[0].y)
			var pb := Vector3(b[0].x, 0.0, b[0].y)
			var na := Vector3(a[2].x, 0.0, a[2].y)
			var nb := Vector3(b[1].x, 0.0, b[1].y)
			if pa.distance_to(pb) > 0.0001:
				_quad(st, [pa + Vector3(0, lo, 0), pb + Vector3(0, lo, 0), pb + Vector3(0, hi, 0), pa + Vector3(0, hi, 0)],
					[na, nb, nb, na], (na + nb).normalized())
				_quad(st, [top, pa + Vector3(0, hi, 0), pb + Vector3(0, hi, 0), top], [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP], Vector3.UP)
		mesh = st.commit()
	_blocks[key] = mesh
	return mesh

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
	var vertical: Array = []
	var water: Array = []
	var pools: Array = []
	for o: Dictionary in objects:
		match o.type:
			"door": _build_door(o)
			"arch": arch.append(o)
			"squeeze_gap": _build_squeeze(o)
			"stairs_up", "stairs_down": _build_stairs(o)
			_:
				var info := object_info(o.type)
				if info.has("model"):
					props.append(o)
					continue
				match str(info.get("shape", "")):
					"slab", "corner", "arc", "spline": shaped.append(o)
					"pillar", "column": _build_column(o)
					"platform", "flight", "spiral": vertical.append(o)
					"window": _build_window(o)
					"lamp": _build_lamp(o)
					"water": water.append(o)
					"pool": pools.append(o)
					"zone":
						if not shell: _build_trigger(o)
	_build_shaped_walls(shaped)
	_build_arches(arch)
	_build_props(props)
	_build_vertical(vertical)
	if not shell: _build_climbers()
	_build_water(water)
	_build_pools(pools)
	if not shell and not waters.is_empty():
		var view := WaterView.new()
		view.name = "WaterView"
		add_child(view)
		view.setup(self)

# ---------------------------------------------------------------- raised floors, stairs, windows, water
## The surfaces the raised floors and straight / spiral stairs are made of (object_types.json "surface"), and
## their rails: built once a floor, shared by every piece
func _piece_mats() -> Dictionary:
	var tile: StandardMaterial3D = _pbr_or("wall") if _has_pbr("wall") else (_pbr_or("tiles") if _has_pbr("tiles") else _default_tile_material())
	var floor_m: Material = _pbr_or("floor") if _has_pbr("floor") else _mat("l0_carpet", Vector3(0.5, 0.5, 0.5), Color(1.0, 0.94, 0.75))
	var chrome := StandardMaterial3D.new()          # the pool rooms' rails: polished stainless tube
	chrome.albedo_color = Color(0.86, 0.87, 0.88)
	chrome.metallic = 1.0
	chrome.roughness = 0.14
	return {"tile": tile, "floor": floor_m, "concrete": _plaster_mat(), "under": _plaster_mat(), "chrome": chrome,
		"tile_uv": _wall_uv_mat(WALL_H) if _has_pbr("wall") else _tile_uv_mat(),
		"column": _wall_uv_mat(WALL_H) if _has_pbr("wall") else null, "repeat": _wall_repeat()}

## Raised floors (a slab `elev` m up), straight flights and spiral stairs: all within this floor, walked up with no
## floor swap. A raised floor leaves its rail open wherever a flight's or a spiral's top arrives at its height.
func _build_vertical(list: Array) -> void:
	if list.is_empty(): return
	var mats := _piece_mats()
	var tops: Array = []                        # [world point at the top of a stair, half its width, its height]
	for o: Dictionary in list:
		var shape := str(object_info(o.type).get("shape", ""))
		if shape in ["flight", "spiral"]:
			tops.append(VerticalPieces.top_exit(o, shape, object_transform(o)))
			_set_landing(o, shape)
	var solid := func(p: Vector3) -> bool: return _block_at(cell_of(p))
	for o: Dictionary in list:
		var vp := VerticalPieces.new()
		vp.transform = object_transform(o)
		add_child(vp)
		vp.build(o, str(object_info(o.type).get("shape", "")), mats, tops, solid, ceiling_height(Vector2i(roundi(o.pos_x), roundi(o.pos_y))), shell)
		if not shell:
			for l in vp.find_children("*", "Light3D", true, false): (l as Light3D).light_cull_mask &= ~SHELL_LAYERS

## The floor below's stairs that climb up through this floor (level_data.gd climb_cells): built here too, a storey
## down, as solids only (the look-only copy of that floor draws them), so whoever comes up them keeps their footing
## when this floor takes over, and can walk back down them
func _build_climbers() -> void:
	if climb_down.is_empty(): return
	var objs = floor_data(level_raw, floor_src(level_raw, floor_no - 1)).get("objects")
	if not (objs is Array): return
	var mats := _piece_mats()
	for raw in objs:
		if not (raw is Dictionary): continue
		var shape := str(object_info(str(raw.get("type", ""))).get("shape", ""))
		if shape != "flight" and shape != "spiral": continue
		var o := load_object(raw)
		if float(o.elev) + float(o.rise) < CLIMB_TOP: continue
		_set_landing(o, shape)
		var vp := VerticalPieces.new()
		vp.transform = object_transform(o).translated(Vector3(0, -STOREY_H, 0))
		vp.solids_only = true
		add_child(vp)
		vp.build(o, shape, mats, [], func(_p): return false, STOREY_H * 2.0, false)

## A stair that climbs on up to the floor above comes out in a hole in it that is whole cells: from its top to
## the edge of that hole there is nothing to step onto. It gets a landing that far ("_landing", metres; 0 for one
## that stops on this floor), level with the floor above.
func _set_landing(o: Dictionary, shape: String) -> void:
	o["_landing"] = 0.0
	if float(o.get("elev", 0.0)) + float(o.get("rise", 0.0)) < CLIMB_TOP: return
	var ex: Array = VerticalPieces.top_exit(o, shape, object_transform(o))
	var p: Vector3 = ex[0]
	var d: Vector3 = ex[3]
	var c := cell_of(p - d * 0.05)
	var t := CELL
	for axis: int in [0, 2]:
		var dv := d[axis]
		if absf(dv) < 0.0001: continue
		var mid := float(c.x if axis == 0 else c.y) * CELL
		var bound := mid + signf(dv) * CELL * 0.5
		t = minf(t, (bound - p[axis]) / dv)
	o["_landing"] = clampf(t, 0.0, CELL) + 0.05

## A window on a wall: a sky through its glass and sunlight thrown in through it (props/window.gd)
func _build_window(o: Dictionary) -> void:
	var w := WindowPiece.new()
	w.transform = object_transform(o)
	add_child(w)
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	var into := c
	var ahead := cell_of(w.transform * Vector3(CELL * 0.5, 0.0, 0.0))   # the cell it looks into, if it sits on an edge
	if not walls.has(ahead): into = ahead
	w.build(o, ceiling_height(into), shell, func(p: Vector3) -> bool: return _block_at(cell_of(p)))
	for l in w.find_children("*", "Light3D", true, false):
		(l as Light3D).light_cull_mask &= ~SHELL_LAYERS

## A lamp that is not a ceiling tube (props/lamp_fixture.gd): a standing lamp, a sconce, a chandelier, a candle...
func _build_lamp(o: Dictionary) -> void:
	var lamp := LampFixture.new()
	lamp.transform = object_transform(o)
	add_child(lamp)
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	var into := c
	if walls.has(c):                                   # a sconce on a wall face: the room it lights is the cell it faces
		var ahead := cell_of(lamp.transform * Vector3(CELL * 0.5, 0.0, 0.0))
		if not walls.has(ahead): into = ahead
	lamp.build(o, ceiling_height(into), shell)

## Standing water (props/water_body.gd), and on the floor you walk on the eye that notices when it is under it
func _build_water(list: Array) -> void:
	if list.is_empty(): return
	for o: Dictionary in list:
		var wb := WaterBody.new()
		wb.transform = object_transform(o)
		add_child(wb)
		wb.build(self, o, shell)

## Pools sunk into the floor (props/pool.gd); _build_surfaces has already cut their outlines out of the floor
func _build_pools(list: Array) -> void:
	if list.is_empty(): return
	var mats := _piece_mats()
	for o: Dictionary in list:
		if not o.has("_poly"): continue
		var pp := PoolPiece.new()
		pp.transform = object_transform(o)
		add_child(pp)
		var wm := ShaderMaterial.new()
		wm.shader = load("res://shaders/water.gdshader")
		var tint: Array = WaterBody.TINTS.get(str(o.get("tint", "clear")), WaterBody.TINTS.clear)
		wm.set_shader_parameter("absorb", tint[0])
		wm.set_shader_parameter("scatter_color", tint[1])
		wm.set_shader_parameter("surface_y", float(o.level))
		pp.build(o, mats, wm, shell)

## Every pool's outline in the level's plan (metres, x / z), for cutting them out of the floor
func _pool_polys() -> Array:
	var out: Array = []
	for o: Dictionary in waters:
		if not o.has("_poly"): continue
		var xf := object_transform(o)
		var world := PackedVector2Array()
		for v: Vector2 in o._poly:
			var w := xf * Vector3(v.x, 0.0, v.y)
			world.append(Vector2(w.x, w.z))
		var box := Rect2(world[0], Vector2.ZERO)
		for v in world: box = box.expand(v)
		out.append([world, box])
	return out

## The cells a pool's outline cuts into (their floor is _cut_cell_tris), from _pool_polys()
func _pool_cut_cells(polys: Array) -> Dictionary:
	var out := {}
	for pb: Array in polys:
		var box: Rect2 = pb[1]
		for x in range(floori(box.position.x / CELL + 0.5) - 1, ceili(box.end.x / CELL + 0.5) + 1):
			for z in range(floori(box.position.y / CELL + 0.5) - 1, ceili(box.end.y / CELL + 0.5) + 1):
				var cell_box := Rect2(x * CELL - CELL * 0.5, z * CELL - CELL * 0.5, CELL, CELL)
				if cell_box.intersects(box): out[Vector2i(x, z)] = true
	return out

## The floor of cell `c` that is left round the pools: in pieces half a metre square, each kept, dropped or cut
## to the outlines; flat triangles on the plan (x, z)
const CUT_PIECES := 9
func _cut_cell_tris(c: Vector2i, polys: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var s := CELL / CUT_PIECES
	var x0 := c.x * CELL - CELL * 0.5
	var z0 := c.y * CELL - CELL * 0.5
	for i in CUT_PIECES:
		for k in CUT_PIECES:
			var sq := PackedVector2Array([Vector2(x0 + i * s, z0 + k * s), Vector2(x0 + (i + 1) * s, z0 + k * s),
				Vector2(x0 + (i + 1) * s, z0 + (k + 1) * s), Vector2(x0 + i * s, z0 + (k + 1) * s)])
			var sq_box := Rect2(sq[0], Vector2(s, s))
			var pieces: Array = [sq]
			for pb: Array in polys:
				if not (pb[1] as Rect2).intersects(sq_box): continue
				var poly: PackedVector2Array = pb[0]
				var inside := 0
				for q in sq: if Geometry2D.is_point_in_polygon(q, poly): inside += 1
				if inside == 4:
					var any_in := false
					for v in poly: if sq_box.has_point(v): any_in = true
					if not any_in:
						pieces = []
						break
				var next: Array = []
				for pc: PackedVector2Array in pieces:
					var cw := Geometry2D.is_polygon_clockwise(pc)
					for r: PackedVector2Array in Geometry2D.clip_polygons(pc, poly):
						if Geometry2D.is_polygon_clockwise(r) == cw: next.append(r)     # (the others are holes)
				pieces = next
			for pc: PackedVector2Array in pieces:
				var idx := Geometry2D.triangulate_polygon(pc)
				for j in idx: out.append(pc[j])
	return out

## The floors of the cells a pool cuts into: `groups` material -> [cells], built from _cut_cell_tris, with a
## solid of their own (they are left out of the merged floor boxes)
func _build_cut_floors(groups: Dictionary, polys: Array) -> void:
	var faces := PackedVector3Array()
	for m: Material in groups:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for c: Vector2i in groups[m]:
			var tris := _cut_cell_tris(c, polys)
			for t in range(0, tris.size(), 3):
				var a := Vector3(tris[t].x, 0.0, tris[t].y)
				var b := Vector3(tris[t + 1].x, 0.0, tris[t + 1].y)
				var d := Vector3(tris[t + 2].x, 0.0, tris[t + 2].y)
				var order := [a, b, d] if (b - a).cross(d - a).y < 0.0 else [a, d, b]
				for v: Vector3 in order:
					st.set_normal(Vector3.UP)
					st.set_uv(Vector2(v.x, v.z))
					st.add_vertex(v)
					faces.append(v)
		st.generate_tangents()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	if shell or faces.is_empty(): return
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	cs.shape = shape
	body.add_child(cs)
	add_child(body)

## The wall faces that stand round and in a water body, for the ripples of light it throws on them: the grid's
## wall blocks, and the walls, pillars and columns placed as objects. [a, b, outward normal] per face (world, on
## the floor; a and b along the face). `inside`: whether a world point (on the floor) is over the water.
func wall_faces_near(inside: Callable, box: Rect2) -> Array:
	var out: Array = []
	var h := CELL * 0.5
	for x in range(floori(box.position.x / CELL) - 1, ceili(box.end.x / CELL) + 2):
		for z in range(floori(box.position.y / CELL) - 1, ceili(box.end.y / CELL) + 2):
			var c := Vector2i(x, z)
			if _block_at(c) or walls.has(c): continue
			for n: Vector2i in DIRS:
				if not _block_at(c + n): continue
				var mid := Vector3(c.x * CELL + n.x * h, 0.0, c.y * CELL + n.y * h)
				var along := Vector3(n.y, 0.0, n.x) * h
				out.append([mid - along, mid + along, Vector3(-n.x, 0.0, -n.y)])
	for o: Dictionary in objects:
		var shape := str(object_info(o.type).get("shape", ""))
		var xf := object_transform(o)
		if shape in ["slab", "corner", "arc", "spline"]:
			if not inside.call(xf.origin) and not box.grow(CELL * float(o.scale)).has_point(Vector2(xf.origin.x, xf.origin.z)): continue
			var path := shape_path(o)
			var t := object_thick(o) * 0.5
			for i in path.size() - 1:
				var a := xf * (Vector3(path[i].x, 0.0, path[i].y) * CELL)
				var b := xf * (Vector3(path[i + 1].x, 0.0, path[i + 1].y) * CELL)
				if a.distance_to(b) < 0.001: continue
				var side := (b - a).normalized().cross(Vector3.UP)
				for s: float in [1.0, -1.0]:
					out.append([a + side * t * s, b + side * t * s, side * s])
		elif shape in ["pillar", "column"]:
			if not inside.call(xf.origin): continue
			var r := object_thick(o) * 0.5
			var k := 24 if shape == "column" else 4
			for i in k:
				var a0 := TAU * (i + (0.5 if shape == "pillar" else 0.0)) / k
				var a1 := TAU * (i + 1 + (0.5 if shape == "pillar" else 0.0)) / k
				var rr := r * (sqrt(2.0) if shape == "pillar" else 1.0)
				var a := xf * Vector3(cos(a0) * rr, 0.0, sin(a0) * rr)
				var b := xf * Vector3(cos(a1) * rr, 0.0, sin(a1) * rr)
				var mid := (a + b) * 0.5
				out.append([a, b, (mid - xf.origin).normalized()])
	return out

# Decorative clutter (levels/object_types.json entries with a "model" key): one imported mesh each, no
# effect on the grid, nav or walls. See props/industrial_prop.gd for how the material is put together.
func _build_props(list: Array) -> void:
	for o: Dictionary in list:
		var info := object_info(o.type)
		var p := IndustrialProp.new()
		p.transform = object_transform(o) * Transform3D(Basis.from_scale(Vector3.ONE * o.scale), Vector3.ZERO)
		p.position.y += float(o.get("elev", 0.0))       # lifted off the floor: a sign on a wall, a box on a shelf
		add_child(p)
		p.build(str(info.model), info.get("textures", {}), {} if shell else info.get("light", {}), float(info.get("model_yaw", 0.0)), float(info.get("glow", 0.0)), float(info.get("model_scale", 1.0)))
		for l in p.find_children("*", "Light3D", true, false):
			(l as Light3D).light_cull_mask &= ~SHELL_LAYERS      # a work lamp lights its own floor, not the ones under it

func _object_wall_h(o: Dictionary) -> float:
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	var all_low := true
	var top := 0.0
	for n: Vector2i in DIRS + [Vector2i.ZERO]:
		var cell: Vector2i = c + n
		if grand.has(cell): top = GRAND_H
		elif tall.has(cell): top = maxf(top, TALL_H)
		if not low.has(cell): all_low = false
	if top > 0.0: return top
	return LOW_H if all_low else WALL_H

## The squeeze gap `pos` (world) is at, if any: {"o": the object, "local": pos in its frame (metres, +x the
## way through, z across), "gap": the slit's width, "inside": between the wall's faces}. The slit's funnel
## (SQUEEZE_FUNNEL either side) counts as at it, so the player can be made slim before touching the jambs.
func squeeze_at(pos: Vector3) -> Dictionary:
	for o: Dictionary in objects:
		if o.type != "squeeze_gap":
			continue
		var gap := clampf(float(o.get("gap", 0.55)), 0.35, 0.9)
		var local := object_transform(o).affine_inverse() * pos
		var d := CELL * 0.5
		if absf(local.x) <= d + SQUEEZE_FUNNEL and absf(local.z) <= gap * 0.5 + SQUEEZE_FUNNEL:
			return {"o": o, "local": local, "gap": gap, "inside": absf(local.x) <= d}
	return {}

## The clear height directly over `pos` (world) if it's under an arch's crown, else INF. The crown's
## curve dips well below the room's own ceiling_height() near the springline, so anything tall passing
## under it (bacteria_rig.gd) needs this, not just the flat per-cell height.
func arch_clearance(pos: Vector3) -> float:
	var best := INF
	for o: Dictionary in objects:
		if o.type != "arch":
			continue
		var xf := object_transform(o)
		var local := xf.affine_inverse() * pos
		var fr := _arch_frame(o)
		if absf(local.x) > float(fr.d):
			continue
		var r: float = fr.r
		if r <= 0.0 or absf(local.z) > r:
			continue
		var rise: float = fr.rise
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
		mi.material_override = _wall_uv_mat(full if h >= full - 0.01 else WALL_H)
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
## where the path turns gently (a curve) and keep a hard edge at a sharp turn (a corner). Each face is unrolled
## for its UVs (metres: u the distance along that face, v up; _wall_uv_mat), so the tiles follow the bend at
## their true size: the inside of a curve is shorter than the outside, and each gets its own count of them. A
## closed loop is fitted to a whole number of the material's repeats, so it has no seam where it meets itself.
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
	# how far along each face every point is, and for a loop the stretch that makes it a whole number of repeats
	var run := {1.0: [0.0], -1.0: [0.0]}
	var fit := {1.0: 1.0, -1.0: 1.0}
	var rep := _wall_repeat()
	for sgn: float in [1.0, -1.0]:
		for i in segs:
			var j := (i + 1) % n
			run[sgn].append(run[sgn][i] + (p[j] + off[j] * sgn).distance_to(p[i] + off[i] * sgn))
		var total: float = run[sgn][segs]
		if closed and total > 0.01: fit[sgn] = maxf(1.0, roundf(total / rep)) * rep / total
	for i in segs:
		var j := (i + 1) % n
		for sgn: float in [1.0, -1.0]:
			var face := side[i] * sgn
			var ni: Vector2 = off[i].normalized() * sgn if smooth[i] else face
			var nj: Vector2 = off[j].normalized() * sgn if smooth[j] else face
			var a: Vector3 = at.call(p[i] + off[i] * sgn, 0.0)
			var b: Vector3 = at.call(p[j] + off[j] * sgn, 0.0)
			# (the far face runs the other way round, so its tiles read the right way out from it too)
			var ua: float = run[sgn][i] * fit[sgn] * sgn
			var ub: float = run[sgn][i + 1] * fit[sgn] * sgn
			_quad_uv(st, [a, b, b + Vector3(0, h, 0), a + Vector3(0, h, 0)],
				[at.call(ni, 0.0), at.call(nj, 0.0), at.call(nj, 0.0), at.call(ni, 0.0)],
				[Vector2(ua, 0.0), Vector2(ub, 0.0), Vector2(ub, h), Vector2(ua, h)], at.call(face, 0.0))
		var top := [at.call(p[i] + off[i], h), at.call(p[j] + off[j], h), at.call(p[j] - off[j], h), at.call(p[i] - off[i], h)]
		var tuv: Array = top.map(func(v: Vector3) -> Vector2: return Vector2(v.x, v.z))
		_quad_uv(st, top, [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP], tuv, Vector3.UP)
	if not closed:
		for end: int in [0, n - 1]:
			var out: Vector2 = (p[0] - p[1]).normalized() if end == 0 else (p[n - 1] - p[n - 2]).normalized()
			var o3: Vector3 = at.call(out, 0.0)
			var l: Vector3 = at.call(p[end] + off[end], 0.0)
			var r: Vector3 = at.call(p[end] - off[end], 0.0)
			var w := l.distance_to(r)
			_quad_uv(st, [l, r, r + Vector3(0, h, 0), l + Vector3(0, h, 0)], [o3, o3, o3, o3],
				[Vector2(0, 0), Vector2(w, 0), Vector2(w, h), Vector2(0, h)], o3)
	st.generate_tangents()
	return st.commit()

## _quad with UVs (for the normal map's tangents and the unrolled wall materials)
func _quad_uv(st: SurfaceTool, v: Array, nrm: Array, uv: Array, facing: Vector3) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	if (v[1] - v[0]).cross(v[2] - v[0]).dot(facing) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for k in order:
		st.set_normal(nrm[k])
		st.set_uv(uv[k])
		st.add_vertex(v[k])

## An upright cylinder `r` round and `h` tall on the floor with its top capped, unrolled for its UVs like a swept
## wall (metres round and up), and fitted to a whole number of the material's repeats round it (no seam)
func _uv_cylinder(r: float, h: float, segs := 32) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rep := _wall_repeat()
	var circ := TAU * r
	var k := maxf(1.0, roundf(circ / rep)) * rep / circ
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var n0 := Vector3(cos(a0), 0.0, sin(a0))
		var n1 := Vector3(cos(a1), 0.0, sin(a1))
		var u0 := circ * i / segs * k
		var u1 := circ * (i + 1) / segs * k
		_quad_uv(st, [n0 * r, n1 * r, n1 * r + Vector3(0, h, 0), n0 * r + Vector3(0, h, 0)], [n0, n1, n1, n0],
			[Vector2(u0, 0), Vector2(u1, 0), Vector2(u1, h), Vector2(u0, h)], (n0 + n1) * 0.5)
		var top := Vector3(0, h, 0)
		_quad_uv(st, [top, n0 * r + top, n1 * r + top, top], [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP],
			[Vector2.ZERO, Vector2(n0.x, n0.z) * r, Vector2(n1.x, n1.z) * r, Vector2.ZERO], Vector3.UP)
	st.generate_tangents()
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
	if round_one and _has_pbr("wall"):
		# a level walled in tiles (the pool rooms): the column is tiled too, unrolled round it so they don't smear
		mi.mesh = _uv_cylinder(w * 0.5, h, 32)
		mi.material_override = _wall_uv_mat(WALL_H)
		var shape := CylinderShape3D.new()
		shape.radius = w * 0.5
		shape.height = h
		cs.shape = shape
	elif round_one:
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
		mi.material_override = _wall_mat_for(h)
		var shape := BoxShape3D.new()
		shape.size = Vector3(w, h, w)
		cs.shape = shape
	var centre := object_transform(o) * Transform3D(Basis(), Vector3(0, h * 0.5, 0))
	# (the unrolled cylinder stands on its foot; the stock meshes are centred)
	mi.transform = object_transform(o) if mi.mesh is ArrayMesh else centre
	add_child(mi)
	var body := StaticBody3D.new()
	body.transform = centre
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

# A round-topped opening: straight jambs up to ARCH_SPRING, then a semicircular crown (flattened if a wide arch
# would hit the ceiling), solid wall to either side of the opening and above it. The opening is the span minus a
# pillar each side, so a 1-cell arch opens 4.5 m less a pillar each side and a wider one opens up to match.
# Square on a wall cell it punches through the full CELL-deep wall. Anywhere else it is a wall of its own,
# FREE_ARCH_D thick, and each pillar reaches on out (up to ARCH_REACH) to the nearest wall beside it, so it joins
# the room's walls instead of standing about with gaps round it. The underside is unrolled for its UVs like a
# curved wall (_wall_uv_mat): the tiles or wallpaper carried on up from each jamb, meeting at the crown.
const FREE_ARCH_D := 0.6
const ARCH_REACH := 1.5             # cells a free-standing arch's pillar looks along for a wall to meet

## How arch `o` stands: {d: half its depth through, r: half the opening, ext: [how far out each pillar reaches,
## -z side then +z], h: its height, rise: the crown's}
func _arch_frame(o: Dictionary) -> Dictionary:
	var pillar := float(object_info("arch").get("pillar", 0.75))
	var h := _object_wall_h(o)
	var r: float = (CELL * o.scale - pillar * 2.0) * 0.5
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	var in_wall := arch_cells.has(c) and absf(o.pos_x - c.x) <= 0.26 and absf(o.pos_y - c.y) <= 0.26
	var ext := [r + pillar, r + pillar]
	if not in_wall:
		var xf := object_transform(o)
		for k in 2:
			var side := -1.0 if k == 0 else 1.0
			var z := r + pillar
			while z < r + pillar + ARCH_REACH * CELL:
				var at := xf * Vector3(0.0, 0.0, side * (z + 0.05))
				if _block_at(cell_of(at)):
					ext[k] = z + 0.1          # into the block's face a hair: no seam where they meet
					break
				z += 0.1
	return {"d": CELL * 0.5 if in_wall else FREE_ARCH_D * 0.5, "r": r, "ext": ext, "h": h, "rise": minf(r, h - ARCH_SPRING - 0.3)}

func _build_arches(list: Array) -> void:
	if list.is_empty(): return
	var body := StaticBody3D.new()
	add_child(body)
	var crown := SurfaceTool.new()          # the wall over the opening, front and back (world triplanar, like the walls)
	crown.begin(Mesh.PRIMITIVE_TRIANGLES)
	var under := {}                         # wall height -> SurfaceTool of the underside (unrolled UVs)
	var faces := PackedVector3Array()       # every crown triangle again, for the collision shape
	for o: Dictionary in list:
		var xf := object_transform(o)
		var fr := _arch_frame(o)
		var d: float = fr.d
		var r: float = fr.r
		var h: float = fr.h
		var rise: float = fr.rise
		for k in 2:
			var side := -1.0 if k == 0 else 1.0
			var outer: float = fr.ext[k]
			var size := Vector3(d * 2.0, h, maxf(outer - r, 0.05))
			var pos := Vector3(0, h * 0.5, side * (r + outer) * 0.5)
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = size
			mi.mesh = box
			mi.transform = xf * Transform3D(Basis(), pos)
			mi.material_override = _wall_mat_for(h)
			add_child(mi)
			_add_box_collider(body, xf, size, pos)
			var oi := OccluderInstance3D.new()
			var bo := BoxOccluder3D.new()
			bo.size = size
			oi.occluder = bo
			oi.transform = xf * Transform3D(Basis(), pos)
			add_child(oi)
		var arc: Array[Vector2] = []            # (z, y) along the arc, one spring to the other
		for i in ARCH_SEGS + 1:
			var t := PI * (1.0 - float(i) / ARCH_SEGS)
			arc.append(Vector2(r * cos(t), ARCH_SPRING + rise * sin(t)))
		var run: Array[float] = [0.0]
		for i in ARCH_SEGS: run.append(run[i] + arc[i].distance_to(arc[i + 1]))
		var total: float = run[ARCH_SEGS]
		if not under.has(h):
			under[h] = SurfaceTool.new()
			(under[h] as SurfaceTool).begin(Mesh.PRIMITIVE_TRIANGLES)
		var ust: SurfaceTool = under[h]
		for i in ARCH_SEGS:
			var a0 := arc[i]
			var a1 := arc[i + 1]
			for x: float in [-d, d]:
				var n := Vector3(signf(x), 0, 0)
				var q := [Vector3(x, a0.y, a0.x), Vector3(x, a1.y, a1.x), Vector3(x, h, a1.x), Vector3(x, h, a0.x)]
				_quad(crown, [xf * q[0], xf * q[1], xf * q[2], xf * q[3]], [xf.basis * n, xf.basis * n, xf.basis * n, xf.basis * n], xf.basis * n)
				for v in [q[0], q[1], q[2], q[0], q[2], q[3]]: faces.append(xf * (v as Vector3))
			# the underside: facing down and in, towards the middle of the opening
			var mid := (a0 + a1) * 0.5
			var inward := Vector3(0.0, ARCH_SPRING - mid.y, -mid.x).normalized()
			if inward.y > 0.0: inward = -inward
			var u0 := ARCH_SPRING + minf(run[i], total - run[i])
			var u1 := ARCH_SPRING + minf(run[i + 1], total - run[i + 1])
			var uq := [[Vector3(-d, a0.y, a0.x), Vector2(-d, u0)], [Vector3(d, a0.y, a0.x), Vector2(d, u0)],
				[Vector3(d, a1.y, a1.x), Vector2(d, u1)], [Vector3(-d, a1.y, a1.x), Vector2(-d, u1)]]
			var nw := (xf.basis * inward).normalized()
			_quad_uv(ust, [xf * uq[0][0], xf * uq[1][0], xf * uq[2][0], xf * uq[3][0]], [nw, nw, nw, nw],
				[uq[0][1], uq[1][1], uq[2][1], uq[3][1]], nw)
			for v in [uq[0][0], uq[1][0], uq[2][0], uq[0][0], uq[2][0], uq[3][0]]: faces.append(xf * (v as Vector3))
	for hh: float in under:
		var ust: SurfaceTool = under[hh]
		ust.generate_tangents()
		var umi := MeshInstance3D.new()
		umi.mesh = ust.commit()
		umi.material_override = _wall_uv_mat(hh)
		add_child(umi)
	var mi := MeshInstance3D.new()
	mi.mesh = crown.commit()
	mi.material_override = wall_mat
	add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	cs.shape = shape
	body.add_child(cs)

# A squeeze gap: a full CELL-deep wall with a narrow slit through it (`gap` wide, open right up to the ceiling): a
# jamb of wall either side, flush with the neighbouring wall blocks. The cell is "carved" (an object's on_cell "wall"):
# no solid block of its own, so the slit is the only way through, and the monster's nav treats it as wall.
func _build_squeeze(o: Dictionary) -> void:
	var xf := object_transform(o)
	var h := _object_wall_h(o)
	var gap := clampf(float(o.get("gap", 0.55)), 0.35, 0.9)
	var jamb := (CELL - gap) * 0.5
	var body := StaticBody3D.new()
	add_child(body)
	var parts: Array = []                          # [size, local pos]
	for side: float in [-1.0, 1.0]:
		parts.append([Vector3(CELL, h, jamb), Vector3(0, h * 0.5, side * (gap * 0.5 + jamb * 0.5))])
	for part: Array in parts:
		var size: Vector3 = part[0]
		var pos: Vector3 = part[1]
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mi.mesh = box
		mi.transform = xf * Transform3D(Basis(), pos)
		mi.material_override = _wall_mat_for(h)
		add_child(mi)
		_add_box_collider(body, xf, size, pos)
		var oi := OccluderInstance3D.new()
		var bo := BoxOccluder3D.new()
		bo.size = size
		oi.occluder = bo
		oi.transform = xf * Transform3D(Basis(), pos)
		add_child(oi)

# A door is always set in a thin wall: props/door.gd builds the partition across the object's span with
# the doorway, frame, casing, leaf and knobs in it.
func _build_door(o: Dictionary) -> void:
	var h := _object_wall_h(o)
	var d := Door.new()
	d.transform = object_transform(o)
	add_child(d)
	d.build(CELL * o.scale, float(object_info("door").get("thickness", 0.3)), h, _wall_mat_for(h), door_frame_mat, door_leaf_mat, door_hw_mat)

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
		"wall": paper, "room_wall": _wall_mat_for(room_h),
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
	s.build_outside(room_h, {"room_wall": _wall_mat_for(room_h), "trim": door_frame_mat, "metal": door_hw_mat})
	return s

# Where two open cells have different ceiling heights, a wallpapered drop closes the gap
# (like a drywall bulkhead) with a trim strip along its bottom edge.
const STEP_TRIM_H := 0.1           # metres: the trim along a ceiling step's bottom edge
const STEP_TRIM_RUN := CELL          # a strip's length: exactly a cell (longer, its ends stuck out past a corner as little ears; at 4 mm thick the notch at a corner is not visible)
const STEP_TRIM_D := 0.004          # ...and how far it stands out from the step's face
const STEP_TRIM_TOP := 0.06         # the strip along the face's top edge, under the tall ceiling
func _build_ceiling_steps() -> void:
	var batches := [
		{"height": WALL_H, "st": SurfaceTool.new(), "n": 0},
		{"height": TALL_H, "st": SurfaceTool.new(), "n": 0},
		{"height": GRAND_H, "st": SurfaceTool.new(), "n": 0}
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
				var batch: Dictionary = batches[2] if hi > TALL_H else (batches[1] if hi > WALL_H else batches[0])
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
				# one face for each side, wound and shaded to face its own way (a single face with culling off gets
				# its normal flipped from the far side, and was lit as if it faced away: black)
				var plane_n := ((pts[1][0] - pts[0][0]) as Vector3).cross((pts[2][0] - pts[0][0]) as Vector3)
				for facing: float in [1.0, -1.0]:
					var order := [0, 2, 1, 0, 3, 2] if plane_n.dot(nrm * facing) > 0.0 else [0, 1, 2, 0, 2, 3]
					for i in order:
						st.set_normal(nrm * facing)
						st.set_uv(pts[i][1])
						st.add_vertex(pts[i][0])
				for i in [0, 1, 2, 0, 2, 3]: collider_tris.append(pts[i][0])
				batch.n += 1
				var side := 1.0 if b2 > a else -1.0
				# (flush on the bulkhead's face, a hand's width up from its bottom edge, like the skirting on the walls)
				# and a strip along the top where the face meets the tall ceiling, as the walls have at theirs
				for strip: Array in [[lo + STEP_TRIM_H * 0.5, STEP_TRIM_H], [hi - STEP_TRIM_TOP * 0.5, STEP_TRIM_TOP]]:
					trims.append({"x": bx + dv.x * side * STEP_TRIM_D * 0.5, "z": bz + dv.y * side * STEP_TRIM_D * 0.5, "y": strip[0], "h": strip[1], "along_x": dv.x == 0})
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
		mi.material_override = m          # (both sides are in the mesh, each facing its own way: lit like any wall)
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
	# the same dark vinyl as the skirting (level_trim.gd), so it is lit like it: a cream one read as a glowing white bar
	var tm: Material
	if has_method("_skirt_material"):
		tm = call("_skirt_material")
	else:
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(0.17, 0.145, 0.12)
		sm.roughness = 1.0
		sm.metallic_specular = 0.0
		tm = sm
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()
	mm.instance_count = trims.size()
	var buf := MMBuffer.alloc(mm)
	var st := MMBuffer.stride(mm)
	for i in trims.size():
		var t: Dictionary = trims[i]
		var sc := Vector3(STEP_TRIM_RUN if t.along_x else STEP_TRIM_D, t.h, STEP_TRIM_D if t.along_x else STEP_TRIM_RUN)
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
	# the Endless zone: no ceiling, and walls and tubes going up out of sight (a look-only floor has no use for it)
	# (and an Open ceiling with nothing above it to look up into: it used to be a short, hazy, torch-lit shaft)
	var up_cells := endless_ceiling.duplicate()
	up_cells.merge(shaft_up)
	if not shell and not up_cells.is_empty():
		var es := EndlessShaft.new()
		es.name = "EndlessShaft"
		add_child(es)
		es.setup(self, up_cells)
	# An open ceiling with no room over it to look up into (the top floor, or solid wall above): a shaft
	# rising into the dark, the pit's own turned over. It goes up through the floors above for as long as they
	# are solid wall there (shaft_floors of them, level_data.gd shaft_rise) and stops under the slab of the first
	# that is not; past the last floor it runs on a long way. Its walls are black well before its end.
	if shell and not shaft_up.is_empty():
		var top := WALL_H
		var end := STOREY_H * (shaft_floors + 1)
		if not in_stack(level_raw, floor_no + shaft_floors + 1): end = STOREY_H * shaft_floors + WALL_H + 36.0
		var rise: Array = [top]
		for step: float in [0.32, 1.1, 2.4, 4.4, 7.0, 10.4, 14.0, 20.0]:
			if top + step < end - 0.5: rise.append(top + step)
		rise.append(end)
		_pit_shaft(shaft_up, rise, true, true, _shaft_paper())
		_shaft_haze(shaft_up, top, end)
	# Noclip Floor: plain floor you fall straight through (noclip_slip.gd); only on the floor you walk on
	if not shell and not noclip_floor.is_empty():
		var ns := NoclipSlip.new()
		ns.name = "NoclipSlip"
		add_child(ns)
		ns.setup(self)
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

## `up`: a shaft rising from an open ceiling. Its walls stand a hair inside the cell (it passes through the
## wall of the floors above, whose own faces lie on the cell's edge) and are quite black at its end, so the
## end can't be made out, however short the shaft has to be.
## `mat`: what the walls are made of (the shafts' concrete when null); it must take its brightness from the vertex colours.
func _pit_shaft(cells_in: Dictionary, levels: Array, bottom := true, up := false, mat: Material = null) -> void:
	if cells_in.is_empty(): return
	var H := CELL / 2.0
	var I := H - (0.02 if up else 0.0)                              # how far out from the cell's middle its walls stand
	var shade: Array[float] = []
	for i in levels.size():
		var far := absf(float(levels[i]) - float(levels[0]))        # how far along the shaft, down or up
		shade.append(1.25 if i == 0 else (1.1 if i == 1 else maxf(0.0, exp(-far * 0.4) * 0.9)))
	if up:
		# the room's own walls carried on up: no bright cut edge where they start, and dark by the end
		shade[0] = 1.0
		shade[1] = 0.96
		for i in range(2, shade.size()):
			var far := absf(float(levels[i]) - float(levels[0]))
			shade[i] = maxf(0.0, exp(-far * 0.22))
		shade[shade.size() - 1] = 0.0
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
		if not cells_in.has(c + Vector2i(-1, 0)): wall.call(x - I, z - H, x - I, z + H)
		if not cells_in.has(c + Vector2i(1, 0)): wall.call(x + I, z - H, x + I, z + H)
		if not cells_in.has(c + Vector2i(0, -1)): wall.call(x - H, z - I, x + H, z - I)
		if not cells_in.has(c + Vector2i(0, 1)): wall.call(x - H, z + I, x + H, z + I)
	st.generate_tangents()
	var mats := _pit_materials()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat if mat != null else mats[0]
	add_child(mi)
	if bottom:
		_cell_surface(cells, func(_c): return levels[-1], mats[1], float(levels[-1]) > float(levels[0]))     # a shaft going up is closed by a face looking down

## What a shaft rising from an open ceiling is walled with: the level's own wallpaper (plain, without the room
## walls' skirting and ceiling shadow), darkened by the mesh's vertex colours as it climbs
var _shaft_mat: StandardMaterial3D
func _shaft_paper() -> StandardMaterial3D:
	if _shaft_mat == null:
		var m: StandardMaterial3D = _pbr_or("wall")
		if m == null:
			m = _mat("l0_wallpaper", Vector3.ONE / 2.25, Color(1.0, 0.98, 0.88))
			m.roughness = 0.95
			m.normal_scale = 0.95
			m.metallic_specular = 0.28
		m.vertex_color_use_as_albedo = true
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_shaft_mat = m
	return _shaft_mat

## Haze hanging in a shaft that rises from an open ceiling: a stack of thin see-through sheets across it,
## thicker the higher they hang, so the walls sink into it and the top is never seen. They are lit like
## anything else, so the haze is as bright as the room under it and catches the torch.
func _shaft_haze(cells: Dictionary, from: float, to: float) -> void:
	if cells.is_empty(): return
	var reach := minf(to - from, 18.0)
	var sheets := clampi(int(reach / 0.7), 4, 14)
	var half := CELL / 2.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(sheets - 1, -1, -1):                 # from the top down: the far ones first
		var y := from + 0.6 + (reach - 0.9) * float(i) / float(sheets - 1)
		var col := Color(1, 1, 1, lerpf(0.07, 0.3, float(i) / float(sheets - 1)))
		for c: Vector2i in cells:
			var x := c.x * CELL
			var z := c.y * CELL
			var a := Vector3(x - half, y, z - half)
			var b := Vector3(x + half, y, z - half)
			var d := Vector3(x + half, y, z + half)
			var e := Vector3(x - half, y, z + half)
			for v: Vector3 in [a, d, b, a, e, d]:
				st.set_normal(Vector3.DOWN)
				st.set_color(col)
				st.add_vertex(v)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _pit_materials()[2]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

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
		var haze := StandardMaterial3D.new()            # _shaft_haze: its sheets' vertex colours carry how thick each is
		haze.albedo_color = Color(0.82, 0.78, 0.64)
		haze.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		haze.vertex_color_use_as_albedo = true
		haze.roughness = 1.0
		haze.metallic_specular = 0.0
		haze.cull_mode = BaseMaterial3D.CULL_DISABLED
		_pit_mats = [m, black, haze]
	return _pit_mats

static var _grime_mats := {}

# Grime clusters: the painted 'grime' zone plus ~6% scattered stains, kept off the spawn room
func _build_dirt() -> void:
	var dirty: Array[Vector2i] = []
	var seen := {}
	var add := func(x: int, z: int) -> void:
		var c := Vector2i(x, z)
		if seen.has(c) or walls.has(c) or pits.has(c) or bright.has(c) or loop.has(c) or pool_cells.has(c): return
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
		var key := "%s_%d" % ["wet" if wet else "dry", i]
		if not _grime_mats.has(key):
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
			_grime_mats[key] = m
		var mi := MeshInstance3D.new()
		mi.mesh = (variants[i] as SurfaceTool).commit()
		mi.material_override = _grime_mats[key]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
