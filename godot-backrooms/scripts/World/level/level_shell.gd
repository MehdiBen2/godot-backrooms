extends "res://scripts/World/level/level_fixtures.gd"
## A floor of the level that you are not on, built to be looked at. The floors of a level stand a storey
## apart (level_data.gd STOREY_H), and a pit over an open cell of the floor below is a hole through the slab
## between them, so from the edge of a shaft you see the floors under you and over you, each with its rooms
## lit. level_builder.gd keeps a few of them either side of the floor you are on, wherever a chain of such
## holes leads, and moves them as you change floor.
##
## It is the floor's own geometry and tubes, from the same code and the same dice as the floor you walk on, so
## that one can take the other's place unnoticed. Left out: everything you could bump into, set off or pick
## up, and the floor more than RADIUS cells from its holes (nothing further off can be seen through them).
## It has no light pool; a few plain lights stand in for it (add_lights).

const RADIUS := 10                 # cells round the holes that are built
const MAX_LIGHTS := 24
const MAX_GLOWS := 12
const LIGHT_REACH := 18.0
const LIGHT_COLOR := Color(1.0, 0.93, 0.78)     # level_light_pool.gd LIGHT_COLOR
const LIMINAL_COLOR := Color(0.95, 0.98, 0.9)   # level_lighting.gd ATMOSPHERES.liminal.light
const PANEL_LIGHT := 1.9                        # level_light_pool.gd PANEL_ENERGY
const CLASSIC_BOOST := 1.6

## Neighbouring floors take the two shell render layers turn about (level_geometry.gd SHELL_LAYERS), so a
## floor's lights never reach the one above or below it
static func layer_of(f: int) -> int:
	return 1 << (10 + posmod(f, 2))

## Floor `f` of level `meta` (`raw`: its .lvl, already read), as steps small enough to take one a frame. The
## node goes into the tree when the last one is done, so the floor appears whole.
func build_stages(meta: Dictionary, raw: Dictionary, f: int) -> Array[Callable]:
	var holes: Array = []
	return [
		func() -> void:
			shell = true
			process_mode = Node.PROCESS_MODE_DISABLED
			level_meta = meta
			rng.seed = 1971 + f * 7919
			load_floor(f, raw)
			holes.append_array(through.keys() + open_above.keys())
			_make_materials()
			# the tubes are dealt out over the whole floor, as on the floor you walk on, and only then is it cut down
			if panel_ceiling != null: _place_panel_fixtures()
			else: _place_fixtures()
			_crop_to(holes),
		func() -> void: _build_surfaces(),
		_build_walls,
		func() -> void:
			_build_objects()
			_build_ceiling_steps()
			_build_pit_shafts(),
		func() -> void:
			if panel_ceiling != null: _build_panel_ceiling()
			else: _build_fixture_meshes()
			dress(self, layer_of(f))
			note_world_mats(self)
			add_lights(self, lit, holes, layer_of(f), PANEL_LIGHT if panel_ceiling != null else LIGHT_ENERGY, liminal),
	]

## Keep only the cells within RADIUS of a hole (the box round all of them): the rest of the floor becomes
## solid, unbuilt wall, and what stood on it goes
func _crop_to(holes: Array) -> void:
	if holes.is_empty(): return
	var box := Rect2i(holes[0], Vector2i.ONE)
	for h: Vector2i in holes: box = box.expand(h)
	box = box.grow(RADIUS)
	box.end += Vector2i.ONE                      # expand() takes the far corner in, has_point() leaves it out
	if box.position.x <= 1 and box.position.y <= 1 and box.end.x >= size - 1 and box.end.y >= size - 1: return
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			if box.has_point(c):
				crop[c] = true
				continue
			walls[c] = true
			for cells: Dictionary in [pits, carved, stair_cells, arch_cells, pillar_cells, tall, low]:
				cells.erase(c)
	var kept: Array = []
	for o: Dictionary in objects:
		var inside := true
		for c: Vector2i in (stair_footprint(o) if is_stairs(o.type) else [Vector2i(roundi(o.pos_x), roundi(o.pos_y))]):
			if not crop.has(c): inside = false
		if inside:
			kept.append(o)
		elif is_stairs(o.type):
			for c in stair_footprint(o): stair_cells.erase(c)      # plain wall again
	objects = kept
	fx = fx.filter(func(f: Dictionary) -> bool: return crop.has(cell_of(f.pos)))
	lit.clear()
	for i in fx.size():
		var f: Dictionary = fx[i]
		if f.has("cell"): f.cell = i             # a panel ceiling draws one quad per fixture, by this number
		if not f.burnt:
			f.index = lit.size()
			lit.append(f)

## Put everything under `n` on render layer `layer`, lit by its own lights and no others, and make its own
## lights light nothing else: no shadows (nothing here is near enough to need them), no glow in the fog (it
## would show through the floor above)
static func dress(n: Node, layer: int) -> void:
	if n is Light3D:
		var l := n as Light3D
		l.light_cull_mask = layer
		l.shadow_enabled = false
		l.light_volumetric_fog_energy = 0.0
	elif n is GeometryInstance3D and (n as GeometryInstance3D).layers != CEIL_LAYER:
		(n as GeometryInstance3D).layers = layer      # (the ceiling keeps its own layer and its own soft lights, as on any floor)
	for c in n.get_children():
		dress(c, layer)

## The wallpaper and the other world-space (triplanar) materials take their pattern from where a surface is
## in the world: a floor standing a storey higher would wear its skirting board and the shadow under its
## ceiling part way up the wall. note_world_mats() finds a floor's, set_height() puts the floor at a height
## and slides each pattern back by as much, so it sits on the walls as it does on the floor you walk on.
static func note_world_mats(of: Node) -> void:
	var found := {}
	_world_mats(of, found)
	of.set_meta("world_mats", found)

static func _world_mats(n: Node, found: Dictionary) -> void:
	if n is GeometryInstance3D:
		var m := (n as GeometryInstance3D).material_override as BaseMaterial3D
		if m != null and m.uv1_triplanar and m.uv1_world_triplanar and not found.has(m): found[m] = m.uv1_offset
	for c in n.get_children():
		_world_mats(c, found)

static func set_height(of: Node3D, y: float) -> void:
	of.position.y = y
	var mats: Dictionary = of.get_meta("world_mats", {})
	for m: BaseMaterial3D in mats:
		var base: Vector3 = mats[m]
		m.uv1_offset = Vector3(base.x, base.y - y * m.uv1_scale.y, base.z)

## The stand-in for the light pool: a plain light on each of the working tubes nearest the holes, where the
## floor is looked at from, and on the nearest of those the soft light that only the ceiling gets (as
## level_light_pool.gd does it; that one reaches 3.5 m, so no other floor's ceiling). `fixtures`:
## level_fixtures.gd `lit`. `cool`: the cells of the liminal look, whose tubes are a cooler white.
static func add_lights(to: Node3D, fixtures: Array, holes: Array, layer: int, energy: float, cool := {}) -> void:
	if holes.is_empty() or fixtures.is_empty(): return
	var box := Rect2(Vector2(holes[0]), Vector2.ZERO)
	for h: Vector2i in holes: box = box.expand(Vector2(h))
	var ranked: Array = []
	for f: Dictionary in fixtures:
		if not f.get("casts", true): continue
		var at := Vector2(f.pos.x, f.pos.z) / CELL
		var off := Vector2(maxf(maxf(box.position.x - at.x, at.x - box.end.x), 0.0), maxf(maxf(box.position.y - at.y, at.y - box.end.y), 0.0))
		ranked.append([off.length(), f])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var mains: Array = []
	var glows: Array = []
	to.set_meta("mains", mains)
	to.set_meta("glows", glows)
	for i in mini(MAX_LIGHTS, ranked.size()):
		var f: Dictionary = ranked[i][1]
		var color := Color(1.0, 0.99, 0.96) if f.classic else (LIMINAL_COLOR if cool.has(cell_of(f.pos)) else LIGHT_COLOR)
		var l := _light(color, energy * (CLASSIC_BOOST if f.classic else 1.0), LIGHT_REACH, layer)
		l.omni_attenuation = 1.4
		l.position = f.light_pos
		to.add_child(l)
		mains.append(l)
		if i >= MAX_GLOWS: continue
		var top: float = f.get("ceil_h", f.pos.y)
		var g := _light(color, l.light_energy * 0.5, 3.5, CEIL_LAYER)
		g.omni_attenuation = 1.6
		g.light_specular = 0.35
		g.position = Vector3(f.pos.x, top - 1.6, f.pos.z)
		to.add_child(g)
		glows.append(g)

## How many of a look-only floor's lights are lit depends on how many storeys off it is: the full set next to
## the floor you are on, a handful where it is a shape in the haze. They are in order, nearest the holes first.
static func show_lights(of: Node, storeys: int) -> void:
	var n_main := MAX_LIGHTS if storeys <= 2 else (12 if storeys <= 4 else 6)
	var n_glow := MAX_GLOWS if storeys <= 1 else 0
	var mains: Array = of.get_meta("mains", [])
	var glows: Array = of.get_meta("glows", [])
	for i in mains.size(): (mains[i] as Light3D).visible = i < n_main
	for i in glows.size(): (glows[i] as Light3D).visible = i < n_glow

static func _light(color: Color, energy: float, reach: float, mask: int) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = reach
	l.shadow_enabled = false
	l.light_cull_mask = mask
	l.light_volumetric_fog_energy = 0.0
	l.light_bake_mode = Light3D.BAKE_DISABLED
	l.distance_fade_enabled = true
	l.distance_fade_begin = 70.0
	l.distance_fade_length = 20.0
	l.set_meta("gfx_managed", true)          # Gfx.apply_scene leaves it alone
	return l
