extends "res://scripts/World/level/level_data.gd"
## Level geometry, first half: materials, chunked floor / ceiling surfaces, merged collision, walls and objects.


const Door := preload("res://scripts/World/props/door.gd")
const HideSpot := preload("res://scripts/World/props/hide_spot.gd")
const VerticalPieces := preload("res://scripts/World/props/vertical_pieces.gd")
const WindowPiece := preload("res://scripts/World/props/window.gd")
const WaterBody := preload("res://scripts/World/props/water_body.gd")
const WaterView := preload("res://scripts/World/props/water_view.gd")
const IndustrialProp := preload("res://scripts/World/props/industrial_prop.gd")
const EntityRoster := preload("res://scripts/Entities/entity_roster.gd")
const SurveyNote := preload("res://scripts/World/props/survey_clipboard.gd")
const PipeNetwork := preload("res://scripts/World/props/pipe_network.gd")
const Stairs := preload("res://scripts/World/props/stairs.gd")
const EventTrigger := preload("res://scripts/World/props/event_trigger.gd")
const MMBuffer := preload("res://scripts/World/mm_buffer.gd")
const PitFall := preload("res://scripts/World/level/pit_fall.gd")
const NoclipSlip := preload("res://scripts/World/level/noclip_slip.gd")
const NoclipDeath := preload("res://scripts/World/level/noclip_death.gd")
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
	door_frame_mat.albedo_texture = _SkirtMaterial.tex(_SkirtMaterial.DIRT[1])     # grime photo, multiplied over the cream, in world space
	door_frame_mat.uv1_triplanar = true
	door_frame_mat.uv1_world_triplanar = true
	door_frame_mat.uv1_scale = Vector3.ONE * 0.5

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
## office drop ceiling with its light panels, Ceiling_Office_Lit; the rest: the Level 0 look, "")
const DEFAULT_MATERIALS := {"ceiling": "Ceiling_Office_Lit"}
func _mat_id(slot: String) -> String:
	var id := str(level_data.get("materials", {}).get(slot, ""))
	return id if id != "" else str(DEFAULT_MATERIALS.get(slot, ""))

## The level's ceiling lights ("lights" in the .lvl, picked in the level editor): "panels" (the ceiling's own light
## panels; a ceiling with none of its own gets squares of its tiles lit, tile_panel_ceiling.gdshader), "troffers"
## (hanging 1 x 4 fluorescent fixtures, ballasts humming), "fluorescent" (the same hanging fixtures, the new tube model:
## level_fixtures.gd _build_fluorescent_fixtures()) or "none" (only what the windows and the torch give).
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
	lit.set_meta("panel_tiles", 1)
	lit.set_meta("round_spots", true)       # small round downlights, whatever the tile (its glaze may be dark: no block to light)
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
		# laid as the blocks' world projection lays it (triplanar flips v): the wallpaper's dark band along the
		# top under the ceiling, so a drawn or placed wall wears the same strip as the maze's walls
		m = _wall_material("wall" if key <= WALL_H else "wall_tall", key, false)
		m.uv1_scale = Vector3(1.0 / 2.25, 1.0 / key, 1.0)
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
const SURF_CHUNK := 16
const SURF_RANGE_SLACK := 6.0        # m: a ceiling's height varies from cell to cell
const FOG_END := 170.0               # level_lighting.gd HORIZON_END (this script sits below it, so it can't read it)
const FOG_END_CLASSIC := 260.0       # the found-footage (classic) level: a long, clear view, so the horizon and the far plane go out
const WRAP_FOG_END_MAX := 320.0     # the most an endless level's fog reaches (level_builder.gd _apply_wrap_view)

## How far the horizon fog reaches: past this nothing is seen
func _fog_end() -> float:
	if edge_wrap and not shell: return clampf(wrap_size() * 0.95, FOG_END, WRAP_FOG_END_MAX)
	if atmosphere() == "classic": return FOG_END_CLASSIC
	return FOG_END

## The visibility range of a floor, ceiling or panel chunk: the chunk's centre has to be this far off before its
## nearest cell can be past the fog
func _chunk_reach() -> float:
	return _fog_end() + SURF_CHUNK * CELL * sqrt(2.0) / 2.0 + SURF_RANGE_SLACK

## The chunk (SURF_CHUNK x SURF_CHUNK cells) a point is drawn in
func _chunk_at(p: Vector3) -> Vector2i:
	var c := cell_of(p)
	return Vector2i(c.x / SURF_CHUNK, c.y / SURF_CHUNK)

## Split `items` into chunks by `pos_of`, and build one MultiMesh per chunk, each with its own visibility range.
## One MultiMesh across the whole level has the level for its bounds, so it is drawn whole (every instance through
## the vertex shader) whenever any part of it is in view; per chunk, frustum and occlusion culling drop the rest.
## `build(list)` gets one chunk's items and returns its MultiMeshInstance3D, configured and filled with instance j
## as list[j]. With `key`, each item is given its chunk's MultiMesh and its instance there (item[key + "_mm"],
## item[key + "_i"]), so a colour can be written to it later. `extra` widens the range for pools that draw past
## their cell. Returns the first MultiMesh (null if there were no items): the level's "is there any" flag.
func _chunked(items: Array, pos_of: Callable, key: String, build: Callable, extra := 0.0) -> MultiMesh:
	if items.is_empty(): return null
	var chunks := {}
	for it in items: chunks.get_or_add(_chunk_at(pos_of.call(it)), []).append(it)
	var reach := _chunk_reach() + extra
	var first: MultiMesh = null
	for k in chunks:
		var list: Array = chunks[k]
		var mmi: MultiMeshInstance3D = build.call(list)
		mmi.visibility_range_end = reach
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		add_child(mmi)
		if first == null: first = mmi.multimesh
		if key == "": continue
		for j in list.size():
			var it: Dictionary = list[j]
			it[key + "_mm"] = mmi.multimesh
			it[key + "_i"] = j
	return first

## The SurfaceTool for the chunk `p` is in, from `sts` (chunk -> SurfaceTool), begun the first time it is asked for:
## a level-wide mesh built a piece at a time comes out as one mesh per chunk (_commit_chunks)
func _chunk_st(sts: Dictionary, p: Vector3) -> SurfaceTool:
	var k := _chunk_at(p)
	if not sts.has(k):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		sts[k] = st
	return sts[k]

## One MeshInstance3D per chunk from _chunk_st's SurfaceTools, each with the visibility range of a floor chunk.
## `setup(mi)` gives each its material and settings.
func _commit_chunks(sts: Dictionary, setup: Callable) -> void:
	var reach := _chunk_reach()
	for k in sts:
		var mesh := (sts[k] as SurfaceTool).commit()
		if mesh == null or mesh.get_surface_count() == 0: continue     # (asked for, then given nothing)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.visibility_range_end = reach
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		setup.call(mi)
		add_child(mi)

## _cell_surface, cut into chunks that each carry a visibility range
func _ranged_surface(cells: Array, height_fn: Callable, mat: Material, flip: bool, priority := 0, layers := 1) -> void:
	var chunks := {}
	for c: Vector2i in cells: chunks.get_or_add(Vector2i(c.x / SURF_CHUNK, c.y / SURF_CHUNK), []).append(c)
	var reach := _chunk_reach()
	for ch in chunks:
		await _slice()
		var mi := _cell_surface(chunks[ch], height_fn, mat, flip, priority, layers) as MeshInstance3D
		mi.visibility_range_end = reach
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

## The floors and the ceilings, one mesh per material. `floors` / `ceilings`: build only one of the two (a
## floor rebuilt in place does them a frame apart, level_builder.gd).
func _build_surfaces(floors := true, ceilings := true) -> void:
	var carpet_cells := []
	var tile_cells := []
	var classic_floor := []
	var hotel_floor := []                    # hotel corridors: the red hotel carpet (the zone's HOTEL_H ceiling comes from ceiling_height)
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
			elif classic.has(c) and not _has_pbr("ceiling"): classic_ceil.append(c)     # (a level's own ceiling wins)
			else: ceil_cells.append(c)
			if pits.has(c): continue
			if cut.has(c):
				var key := ("paint:" + str(pf[c])) if pf.has(c) else ("classic" if classic.has(c) and not _has_pbr("floor") else ("hotel" if hotel.has(c) else ("tiles" if tiles.has(c) else "carpet")))
				cut_keys.get_or_add(key, []).append(c)
				cut_all.append(c)
				continue
			floor_cells.append(c)
			# the Classic look's beige carpet only where the level hasn't picked a floor of its own (a Classic
			# atmosphere paints Classic on every open cell: the floor picked in the editor would never show)
			if pf.has(c): paint_floor.get_or_add(pf[c], []).append(c)
			elif classic.has(c) and not _has_pbr("floor"): classic_floor.append(c)
			elif hotel.has(c): hotel_floor.append(c)
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
		await _ranged_surface(ceil_cells, func(c): return ceiling_height(c), ceil_m, true, 0, CEIL_LAYER)
		for id in paint_ceil:
			await _ranged_surface(paint_ceil[id], func(c): return ceiling_height(c), _fillable_ceiling(_painted_mat(id).duplicate()), true, 0, CEIL_LAYER)
		# Classic zone: bright drop-ceiling tiles (the reference backrooms look)
		if not classic_ceil.is_empty():
			await _ranged_surface(classic_ceil, func(c): return ceiling_height(c), _acoustic_ceiling(Color(0.95, 0.9, 0.72)), true, 0, CEIL_LAYER)
		_build_collar_ceilings(ceil_m)
		if not shell: await _build_ceiling_collision(solid_cells + cut_all)
	if not floors: return
	# The floor is a one-sided surface: seen from below, through a hole in the ceiling under it, it isn't there,
	# and the walls and pillars standing on it hang in mid-air. The slab gets an underside of plaster.
	if not (through.is_empty() and open_above.is_empty() and holes_below.is_empty()):
		await _ranged_surface(floor_cells.filter(func(c: Vector2i) -> bool: return not shaft_pass.has(c)), func(_c): return -0.4, _plaster_mat(), true)
	# the carpet's floor plan, a slice at a time, before the first carpet asks for it (and would build it all at once)
	if _floor_map_tex == null and not (_has_pbr("floor") and classic_floor.is_empty() and hotel_floor.is_empty()): await _make_floor_map()
	var carpet: Material = _pbr_or("floor") if _has_pbr("floor") else _carpet_material(Color(1.0, 0.94, 0.75))
	await _ranged_surface(carpet_cells, func(_c): return 0.0, carpet, false)
	for id in paint_floor:
		await _ranged_surface(paint_floor[id], func(_c): return 0.0, _painted_mat(id), false)
	# Classic zone: a clean beige office carpet (the walls carry the yellow)
	if not classic_floor.is_empty():
		await _ranged_surface(classic_floor, func(_c): return 0.0, _carpet_material(Color(1.02, 0.93, 0.7)), false)
	# Hotel corridors: the deep red carpet of a hotel hall
	if not hotel_floor.is_empty():
		await _ranged_surface(hotel_floor, func(_c): return 0.0, _carpet_material(HOTEL_CARPET), false)

	# Polished commercial tile rooms: high-res PBR vinyl composite tiles with wax sheen and normal-mapped bevels
	if not tile_cells.is_empty():
		var tm: StandardMaterial3D = _pbr_or("tiles")
		if tm == null:
			tm = _default_tile_material()
		await _ranged_surface(tile_cells, func(_c): return 0.0, tm, false, 0)

	if not cut_keys.is_empty():
		var groups := {}
		for k: String in cut_keys:
			var m: Material = carpet
			if k.begins_with("paint:"): m = _painted_mat(k.substr(6))
			elif k == "classic": m = _carpet_material(Color(1.02, 0.93, 0.7))
			elif k == "hotel": m = _carpet_material(HOTEL_CARPET)
			elif k == "tiles": m = _pbr_or("tiles") if _has_pbr("tiles") else _default_tile_material()
			groups.get_or_add(m, []).append_array(cut_keys[k])
		_build_cut_floors(groups, polys)

	# round a spiral stair coming up from the floor below: these cells' floor, cut round to its hole
	var collar_tris := PackedVector3Array()
	for col: Dictionary in _stair_collars(false):
		var cut_polys := _collar_polys(col)
		for c: Vector2i in cut_polys:
			var m: Material = carpet
			if pf.has(c): m = _painted_mat(pf[c])
			elif tiles.has(c): m = _pbr_or("tiles") if _has_pbr("tiles") else _default_tile_material()
			collar_tris.append_array(_flat_polys(cut_polys[c], 0.0, m, false))
		collar_tris.append_array(_collar_side(col, func(c: Vector2i) -> float: return float(hole_floor.get(c, WALL_H)) - STOREY_H, 0.0, null))

	if shell:
		# only the holes' sides: a floor passed on a fall down a chain of holes stands as this copy (level_builder.gd
		# _stub), and without them you could steer out of the shaft under its floor line and fall clear of every floor
		_build_hole_collision()
		return
	await _slice()
	await _build_floor_collision(solid_cells)
	_build_hole_collision()
	_collar_solid(collar_tris)

const CarpetPOMShader := preload("res://shaders/carpet_pom.gdshader")

const HOTEL_CARPET := Color(0.7, 0.3, 0.26)     # the hotel corridor's carpet tint: a worn deep red

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
	if _floor_map_tex == null: _make_floor_map()
	sm.set_shader_parameter("floor_map", _floor_map_tex)
	sm.set_shader_parameter("map_cells", float(size))
	sm.set_shader_parameter("map_cell", CELL)
	Gfx.register_carpet(sm)
	return sm

## The floor plan the carpet wears by (carpet_pom.gdshader), one texel a cell. r: a solid wall block (the carpet
## greys along its foot), g: foot traffic. People keep to the middle of corridors, all go through a doorway, and
## spread out across a big room, so the fewer open cells round a cell (5 x 5) the more it is walked; then
## smoothed over its neighbours so a lane runs on round a corner. Counted with summed-area tables: a big level
## is tens of thousands of cells.
var _floor_map_tex: ImageTexture
func _make_floor_map() -> void:
	var n := size
	var w := n + 1
	# per cell: 1 solid (a wall block or a stairwell's box), 2 floor that is walked on, 0 neither (a pit)
	var kind := PackedByteArray()
	kind.resize(n * n)
	for z in n:
		for x in n:
			var c := Vector2i(x, z)
			kind[z * n + x] = 1 if (_block_at(c) or stair_cells.has(c)) else (0 if pits.has(c) else 2)
	var satf := PackedFloat32Array()
	satf.resize(w * w)
	for z in n:
		for x in n:
			var v := 1.0 if kind[z * n + x] == 2 else 0.0
			satf[(z + 1) * w + x + 1] = v + satf[z * w + x + 1] + satf[(z + 1) * w + x] - satf[z * w + x]
	await _slice()
	var traffic := PackedFloat32Array()
	traffic.resize(w * w)               # summed-area table of the raw traffic, for the smoothing
	for z in n:
		for x in n:
			var t := 0.0
			if kind[z * n + x] == 2:
				var x0 := clampi(x - 2, 0, n)
				var z0 := clampi(z - 2, 0, n)
				var x1 := clampi(x + 3, 0, n)
				var z1 := clampi(z + 3, 0, n)
				var open_round: float = satf[z1 * w + x1] - satf[z0 * w + x1] - satf[z1 * w + x0] + satf[z0 * w + x0] - 1.0
				t = clampf((16.0 - open_round) / 12.0, 0.15, 1.0)
				if carved.has(Vector2i(x, z)): t = 1.0         # a doorway: everyone passes through it
			traffic[(z + 1) * w + x + 1] = t + traffic[z * w + x + 1] + traffic[(z + 1) * w + x] - traffic[z * w + x]
		if z % 16 == 15: await _slice()
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for z in n:
		for x in n:
			var k := kind[z * n + x]
			var b := 0.0
			var g := 0.0
			if k == 2:
				var x0 := clampi(x - 1, 0, n)
				var z0 := clampi(z - 1, 0, n)
				var x1 := clampi(x + 2, 0, n)
				var z1 := clampi(z + 2, 0, n)
				var cnt: float = satf[z1 * w + x1] - satf[z0 * w + x1] - satf[z1 * w + x0] + satf[z0 * w + x0]
				g = (traffic[z1 * w + x1] - traffic[z0 * w + x1] - traffic[z1 * w + x0] + traffic[z0 * w + x0]) / maxf(cnt, 1.0)
				for nz in range(z0, z1):                   # a solid block in the 3 x 3 round it: the carpet greys at its foot
					for nx in range(x0, x1):
						if kind[nz * n + nx] == 1: b = 1.0
			img.set_pixel(x, z, Color(1.0 if k == 1 else 0.0, g, b, 1.0))
		if z % 16 == 15: await _slice()
	_floor_map_tex = ImageTexture.create_from_image(img)

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
	# row by row: sorted as packed numbers (row << 20 | column), a native sort; a sort_custom with a GDScript
	# comparison was tens of milliseconds on a big floor
	var order := PackedInt64Array()
	order.resize(free.size())
	var k := 0
	for c: Vector2i in free:
		order[k] = (c.y << 20) | c.x
		k += 1
	order.sort()
	var out: Array[Rect2i] = []
	var n_done := 0
	for key in order:
		n_done += 1
		if n_done % 128 == 0: await _slice()
		var c := Vector2i(key & 0xFFFFF, key >> 20)
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
	var n_done := 0
	for r in rects:
		n_done += 1
		if n_done % 64 == 0: await _slice()
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
	await _add_merged_boxes(body, await _merge_rects(_cell_set(floor_cells)), 0.4, -0.2)

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
		await _add_merged_boxes(body, await _merge_rects(by_height[ch]), 0.4, ch + 0.2)

## The sides of the holes through the slabs: under this floor's own through-pits down to the ceiling of the
## floor below, and over this floor's ceiling up to the hole in the floor above. Someone falling through is
## handed from one floor to the next half way down the slab (level_builder.gd), so each floor walls its own
## half and the other's: without them you could steer sideways into the slab and come down on a ceiling.
func _build_hole_collision() -> void:
	var tris := PackedVector3Array()
	var half := CELL / 2.0
	for part: Array in [[through, true], [open_above, false]]:
		var holes: Dictionary = part[0]
		for c: Vector2i in holes:
			if climb_up.has(c) or climb_down.has(c): continue      # stairs run up through it: their rails do this
			# from the ceiling of the room under the hole up to the floor over it
			var lo := Vector3(0.0, float(hole_floor.get(c, WALL_H)) - STOREY_H if part[1] else ceiling_height(c), 0.0)
			var hi := Vector3(0.0, 0.0 if part[1] else STOREY_H, 0.0)
			for n: Vector2i in DIRS:
				if holes.has(c + n): continue
				var mid := Vector3(c.x * CELL + n.x * half, 0.0, c.y * CELL + n.y * half)
				var along := Vector3(n.y, 0.0, n.x) * half
				tris.append_array([mid - along + lo, mid + along + lo, mid + along + hi, mid - along + lo, mid + along + hi, mid - along + hi])
	if tris.is_empty(): return
	var body := StaticBody3D.new()
	body.disable_mode = CollisionObject3D.DISABLE_MODE_KEEP_ACTIVE     # (a look-only floor doesn't process: still solid)
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
		await _slice()
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

## Hotel corridors (the HOTEL zone) are narrower than their cells: each face in hotel_faces (level_data.gd: an edge
## of a hotel cell, or the part of one that no object blocks) gets a slab HOTEL_INSET thick and HOTEL_H high, with its
## collision. The same spans are in wall_segments, so monsters are pushed out of the slab, not through it.
func _build_hotel_insets() -> void:
	if hotel_faces.is_empty(): return
	var body := StaticBody3D.new()
	add_child(body)
	for f: Array in hotel_faces:
		var c: Vector2i = f[0]
		var n: Vector2i = f[1]
		if stair_cells.has(c) or _block_at(c): continue
		var h := ceiling_height(c)
		var len: float = (float(f[3]) - float(f[2])) * CELL
		var sz := Vector3(HOTEL_INSET, h, len) if n.x != 0 else Vector3(len, h, HOTEL_INSET)
		var along := (float(f[2]) + float(f[3])) * 0.5 * CELL
		var ctr := Vector3(c.x * CELL + n.x * (CELL - HOTEL_INSET) * 0.5 + n.y * along,
			h * 0.5, c.y * CELL + n.y * (CELL - HOTEL_INSET) * 0.5 + n.x * along)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = sz
		mi.mesh = bm
		mi.material_override = wall_mat
		mi.position = ctr
		add_child(mi)
		if not shell:
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = sz
			cs.shape = bs
			cs.position = ctr
			body.add_child(cs)

func _build_walls() -> void:
	_build_hotel_insets()
	var groups := {WALL_H: [], UNDER_SLAB_H: [], TALL_H: [], GRAND_H: []}
	var n_done := 0
	for c: Vector2i in walls.keys():
		n_done += 1
		if n_done % 512 == 0: await _slice()
		if not _block_at(c): continue     # a door / thin wall object or a stairwell stands here instead of a solid block
		var exposed := false
		var reach := WALL_H               # as high as the tallest room it faces
		for n: Vector2i in DIRS:
			# a door / thin wall only fills a sliver of its cell, so the block beside it still shows
			if not _block_at(c + n): exposed = true
			if grand.has(c + n): reach = GRAND_H
			elif tall.has(c + n): reach = maxf(reach, TALL_H)
			elif under_slab.has(c + n): reach = maxf(reach, UNDER_SLAB_H)
		if exposed:
			groups[reach].append(c)
	if not shell: await _build_wall_collision(groups)
	# endless halls: the border's blocks only stop you (the copy of the level beyond the seam draws them)
	if edge_wrap:
		for height in groups.keys():
			groups[height] = (groups[height] as Array).filter(func(c: Vector2i) -> bool: return not wrap_ring.has(c))
	await _build_occluder(groups)
	# cells painted with a material get their own group per (height, material)
	var pw := painted("wall")
	if not pw.is_empty():
		for height in groups.keys():
			var keep := []
			for c in groups[height]:
				if pw.has(c): groups.get_or_add("%s|%s" % [height, pw[c]], []).append(c)
				else: keep.append(c)
			groups[height] = keep
	var mats := {WALL_H: wall_mat, UNDER_SLAB_H: tall_wall_mat, TALL_H: tall_wall_mat, GRAND_H: grand_wall_mat}
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
			await _slice()
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
	if _block_at(c) or stair_cells.has(c): return true      # (a stairwell's box is square and flush: no notch beside it)
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
	var n_done := 0
	for c: Vector2i in walls.keys():
		n_done += 1
		if n_done % 512 == 0: await _slice()
		if _block_at(c): buried[c] = true
	for height in groups.keys():
		for c in groups[height]: buried.erase(c)
	var body := StaticBody3D.new()
	add_child(body)
	for height: float in groups.keys():
		if groups[height].is_empty(): continue
		await _add_merged_boxes(body, await _merge_rects(_cell_set(groups[height]), buried), height, height / 2.0)

# The editor's free-placed objects (level_data.gd `objects`). Each one is built in its own local frame,
# facing +X (the way you walk through it) and spanning `scale` cells along Z, then placed with
# object_transform(). Wall height follows the cell it stands in (tall next to an atrium). Types without a
# builder of their own are built by their object_types.json "shape" (or "model", for clutter).
# ---------------------------------------------------------------- round holes for spiral stairs
## A spiral stair that climbs on through the slab (level_data.gd climb_cells) opens whole cells of it, but it
## comes up in a round hole (props/vertical_pieces.gd hole_radius): the rest of those cells is closed again. On
## the floor it stands on, its ceiling round the hole and the hole's round side up to the floor above; on that
## floor, its floor round the hole, and the hole's lower half for its solids.
const COLLAR_SUB := 12          # a cell is cut in this many strips each way; the ones the rim crosses are cut to it

## Spiral stairs climbing through this floor's ceiling (`up`) or coming up through its floor:
## [{at: the hole's middle (m), r: its radius, cells: {the cells it opens: true}}]
func _stair_collars(up: bool) -> Array:
	var out: Array = []
	var opened: Dictionary = climb_up if up else climb_down
	if opened.is_empty(): return out
	var objs = floor_data(level_raw, floor_src(level_raw, floor_no if up else floor_no - 1)).get("objects")
	if not (objs is Array): return out
	for raw in objs:
		if not (raw is Dictionary) or str(object_info(str(raw.get("type", ""))).get("shape", "")) != "spiral": continue
		var o := load_object(raw)
		if float(o.elev) + float(o.rise) < CLIMB_TOP: continue
		var cells := {}
		for c: Vector2i in footprint_cells(o, "spiral"):
			if opened.has(c): cells[c] = true
		if not cells.is_empty():
			out.append({"at": Vector2(o.pos_x, o.pos_y) * CELL, "r": VerticalPieces.hole_radius(o), "cells": cells})
	return out

## The hole's rim: a polygon of HOLE_SIDES corners (x, z in metres)
static func _collar_rim(col: Dictionary) -> PackedVector2Array:
	var rim := PackedVector2Array()
	for i in VerticalPieces.HOLE_SIDES:
		rim.append((col.at as Vector2) + Vector2.from_angle(TAU * i / VerticalPieces.HOLE_SIDES) * float(col.r))
	return rim

## What is left of each opened cell with the hole cut out of it: cell -> Array of polygons (x, z in metres)
func _collar_polys(col: Dictionary) -> Dictionary:
	var at: Vector2 = col.at
	var r: float = col.r
	var rim := _collar_rim(col)
	var inner := r * cos(PI / VerticalPieces.HOLE_SIDES)       # the rim's straight pieces come this close in
	var s := CELL / COLLAR_SUB
	var out := {}
	for c: Vector2i in col.cells:
		var polys: Array = []
		var o := Vector2(c.x, c.y) * CELL - Vector2(CELL, CELL) * 0.5
		for i in COLLAR_SUB:
			for j in COLLAR_SUB:
				var a := o + Vector2(i, j) * s
				var sq := PackedVector2Array([a, a + Vector2(s, 0), a + Vector2(s, s), a + Vector2(0, s)])
				var far := 0.0
				for p: Vector2 in sq: far = maxf(far, p.distance_to(at))
				if Vector2(clampf(at.x, a.x, a.x + s), clampf(at.y, a.y, a.y + s)).distance_to(at) >= r: polys.append(sq)
				elif far > inner: polys.append_array(Geometry2D.clip_polygons(sq, rim))
		out[c] = polys
	return out

## Lay `polys` (x, z in metres) flat at height `y`, facing down or up; returns their triangles, for a solid
func _flat_polys(polys: Array, y: float, mat: Material, down: bool, layers := 1) -> PackedVector3Array:
	var tris := PackedVector3Array()
	var n := Vector3.DOWN if down else Vector3.UP
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for poly: PackedVector2Array in polys:
		var idx := Geometry2D.triangulate_polygon(poly)
		for t in range(0, idx.size(), 3):
			var a := Vector3(poly[idx[t]].x, y, poly[idx[t]].y)
			var b := Vector3(poly[idx[t + 1]].x, y, poly[idx[t + 1]].y)
			var c := Vector3(poly[idx[t + 2]].x, y, poly[idx[t + 2]].y)
			var order := [a, b, c] if (b - a).cross(c - a).dot(n) <= 0.0 else [a, c, b]     # (Godot's front faces are clockwise)
			for v: Vector3 in order:
				st.set_normal(n)
				st.set_uv(Vector2(v.x, v.z))
				st.add_vertex(v)
			tris.append_array([a, b, c])
	if tris.is_empty(): return tris
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.layers = layers
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return tris

## The hole's round side, from `bottom` (cell -> height) up to `top`, facing in; drawn in `mat` unless that is
## null. Returns its triangles, for a solid.
func _collar_side(col: Dictionary, bottom: Callable, top: float, mat: Material) -> PackedVector3Array:
	var rim := _collar_rim(col)
	var at: Vector2 = col.at
	var tris := PackedVector3Array()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var u := 0.0
	for i in rim.size():
		var a2 := rim[i]
		var b2 := rim[(i + 1) % rim.size()]
		var mid := (a2 + b2) * 0.5
		var y0: float = bottom.call(cell_of(Vector3(mid.x, 0.0, mid.y)))
		var nrm := Vector3(at.x - mid.x, 0.0, at.y - mid.y).normalized()
		var ln := a2.distance_to(b2)
		var q := [[Vector3(a2.x, y0, a2.y), Vector2(u, y0)], [Vector3(b2.x, y0, b2.y), Vector2(u + ln, y0)],
			[Vector3(b2.x, top, b2.y), Vector2(u + ln, top)], [Vector3(a2.x, top, a2.y), Vector2(u, top)]]
		u += ln
		var flip: bool = ((q[1][0] as Vector3) - (q[0][0] as Vector3)).cross((q[2][0] as Vector3) - (q[0][0] as Vector3)).dot(nrm) > 0.0
		for k in ([0, 2, 1, 0, 3, 2] if flip else [0, 1, 2, 0, 2, 3]):
			st.set_normal(nrm)
			st.set_uv(q[k][1])
			st.add_vertex(q[k][0])
			tris.append(q[k][0])
	if mat != null:
		st.generate_tangents()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	return tris

## The ceiling round each hole a spiral climbs through to the floor above, and the hole's side up to that floor
func _build_collar_ceilings(ceil_m: Material) -> void:
	var cols := _stair_collars(true)
	if cols.is_empty(): return
	var pc := painted("ceiling")
	var painted_m := {}
	var tris := PackedVector3Array()
	for col: Dictionary in cols:
		var cut := _collar_polys(col)
		for c: Vector2i in cut:
			var m: Material = ceil_m
			if pc.has(c):
				if not painted_m.has(pc[c]): painted_m[pc[c]] = _fillable_ceiling(_painted_mat(pc[c]).duplicate())
				m = painted_m[pc[c]]
			tris.append_array(_flat_polys(cut[c], ceiling_height(c), m, true, CEIL_LAYER))
		tris.append_array(_collar_side(col, func(c: Vector2i) -> float: return ceiling_height(c), STOREY_H, _wall_uv_mat(WALL_H)))
	if not shell: _collar_solid(tris)

func _collar_solid(tris: PackedVector3Array) -> void:
	if tris.is_empty(): return
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = true
	cs.shape = shape
	body.add_child(cs)
	add_child(body)

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
## Two triangles a-b-c, a-c-d, wound so they face `facing` (Godot's front faces are clockwise)
func _quad(st: SurfaceTool, v: Array, nrm: Array, facing: Vector3) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	if (v[1] - v[0]).cross(v[2] - v[0]).dot(facing) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for k in order:
		st.set_normal(nrm[k])
		st.add_vertex(v[k])

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

## The dark vinyl cove base / skirting material: a matte near-black strip with fine grain noise and cellular rubber bump
const _SkirtMaterial := preload("res://scripts/World/level/skirt_material.gd")
func _skirt_material() -> Material:
	return _SkirtMaterial.get_material()


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
