extends "res://scripts/World/level/level_geometry.gd"
## THE LEVEL, layer 3a: the light fixtures themselves (the web game's level.js _placeLights).
##
## Troffer fixtures and ceiling panels are placed some burnt out, some flickering, and drawn as MultiMeshes
## (housings, tubes, diffuser lenses, floor reflections). Failing tubes: long stable stretches, then a burst
## of dropouts and re-strikes. Anything big running underneath them (disturb) sets them off too. Power cuts,
## tints and single cut fixtures live here. level_light_pool.gd (3b) decides which of them cast real light,
## level_lighting.gd (3c) turns that into fog, ambient and glare.

signal fixture_event(fixture: Dictionary, restrike: bool)   # audio listens: arc pop / re-strike tick
const LIGHT_ENERGY := 2.2           # tuned for Godot 4 PBR lighting
const BURNT_CHANCE := 0.16
const FLICKER_CHANCE := 0.24
const LIMINAL_BURNT_CHANCE := 0.03     # liminal: nearly every tube works, steady, humming - nothing is wrong, and that's what's wrong
const LIMINAL_FLICKER_CHANCE := 0.04
const LIT_DIFFUSER := Color(3.2, 3.0, 2.55)   # HDR: well past the bloom threshold, so a lit tube glows and hits the lens
const TOP_Y := 0.1432132             # troffer housing top, baked model coordinates
const PANEL_DROP := 0.35            # metres under the ceiling for the light (so the ceiling itself is lit too)
const PANEL_GLOW := Color(3.6, 3.25, 2.75)  # HDR emission multiplier over the (pale blue) emission map: a warm white that blooms
const PANEL_BURNT_CHANCE := 0.08
const PANEL_FLICKER_CHANCE := 0.06
const PANEL_OFFSETS := [Vector2(0, 0), Vector2(-1.5, -1.5), Vector2(1.5, -1.5), Vector2(-1.5, 1.5), Vector2(1.5, 1.5)]

var panels_mm: MultiMesh   # panel ceilings: one instance per fixture, its colour = that cell's panel glow
var fx: Array = []        # every fixture
var lit: Array = []       # the non-burnt ones (the light pool ranks these)
var tubes_mm: MultiMesh
var lens_mm: MultiMesh
var glow_mm: MultiMesh     # the pool of light on the floor under each lit tube, for the tubes past the real lights' reach
var tint := Color.WHITE   # events recolour every lit tube (null in the web game = white)

var fill_lights: Array[OmniLight3D] = []   # the two steady fill lights of bright levels (off in a power cut)
var reflect_mmi: MultiMeshInstance3D   # the fake floor reflections of bright-zone tubes (they live below the floor)

# ----------------------------------------------------------------- fixture index
# A big level has a thousand tubes or more, and most of what asks about them only wants the few near a point
# (the light pool ten times a second, a monster stuttering the tubes it runs under) or the few doing something
# (the flicker model, every frame). Both used to walk the whole list. The index: the tubes by grid square, and
# the set that is awake (flickering, in a burst, cut). Rebuilt whenever `lit` is (_index_fixtures).
const FX_SQUARE := 4                # cells along a side of an index square
var _fx_grid := {}                  # Vector2i square -> Array of the lit fixtures in it
var _awake := {}                    # lit index -> fixture: the ones _update_fixtures has to look at

func _index_fixtures() -> void:
	_fx_grid.clear()
	_awake.clear()
	for f: Dictionary in lit:
		var k := _fx_square(f.pos)
		if not _fx_grid.has(k): _fx_grid[k] = []
		(_fx_grid[k] as Array).append(f)
		if f.flickers or f.black > 0.0 or f.burst > 0: _wake(f)

func _fx_square(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / (CELL * FX_SQUARE)), floori(p.z / (CELL * FX_SQUARE)))

## Every index square a circle round `p` (on the floor plan) touches, as [first, last] corners
func _fx_span(p: Vector3, radius: float) -> Array[Vector2i]:
	return [_fx_square(p - Vector3(radius, 0.0, radius)), _fx_square(p + Vector3(radius, 0.0, radius))]

## The lit fixtures within `radius` of `p` on the floor plan (height ignored, like every light test here)
func fixtures_near(p: Vector3, radius: float) -> Array:
	var out: Array = []
	var r2 := radius * radius
	var span := _fx_span(p, radius)
	for x in range(span[0].x, span[1].x + 1):
		for z in range(span[0].y, span[1].y + 1):
			var sq = _fx_grid.get(Vector2i(x, z))
			if sq == null: continue
			for f: Dictionary in sq:
				var dx: float = f.pos.x - p.x
				var dz: float = f.pos.z - p.z
				if dx * dx + dz * dz <= r2: out.append(f)
	return out

## A tube that has something to do from now on (a burst, a cut): the flicker model looks at it until it settles
func _wake(f: Dictionary) -> void:
	if int(f.index) >= 0: _awake[int(f.index)] = f
# ----------------------------------------------------------------- fixtures
## A floor that can be seen from the next one, through a hole in a slab, is built twice: to walk on, and to be
## looked at from above or below (level_shell.gd). Both must burn out and flicker the same tubes, so on those
## floors the dice for them start from the floor's number here, whatever was rolled before (stains, which
## depend on where you came in). A floor with no hole keeps the one sequence it always had. (An endless
## level's repeats of a floor take that floor's number: they are the same floor, down to the dead tubes.)
func _seed_fixtures() -> void:
	if not (through.is_empty() and open_above.is_empty()):
		rng.seed = 2971 + floor_src(level_raw, floor_no) * 7919

# Same placement rules as the web game's _placeLights: corridor cells and a 3-cell grid, min
# spacing 1.9 cells, some tubes burnt out, some flickering.
func _place_fixtures() -> void:
	_seed_fixtures()
	var min_sp := CELL * 1.9
	# fixtures sit on cell centres and min_sp is under 2 cells, so only the 3x3 cells round one can be too
	# close: a lookup by cell instead of a scan of every fixture so far (which went quadratic on big levels)
	var at_cell := {}
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			# no fixture over any wall, placed thin walls and doors included: the wall reaches the ceiling,
			# so a troffer there sits on top of it and its light bleeds through both faces
			if walls.has(c) or arch_cells.has(c) or pillar_cells.has(c) or open_above.has(c): continue
			var y := LOW_H - 0.03 if ceiling_height(c) == LOW_H else WALL_H - 0.03
			var pos := Vector3(x * CELL, y, z * CELL)
			var too_close := false
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					var near = at_cell.get(Vector2i(x + dx, z + dz))
					if near != null and (near as Vector3).distance_to(pos) < min_sp:
						too_close = true
			if too_close: continue
			var is_classic := classic.has(c)
			var is_bright := bright.has(c)
			var ns := walls.has(Vector2i(x - 1, z)) and walls.has(Vector2i(x + 1, z))
			var ew := walls.has(Vector2i(x, z - 1)) and walls.has(Vector2i(x, z + 1))
			var grid_node := x % 3 == 0 and z % 3 == 0
			# big lit halls (Bright / Classic) get the plain 3-cell grid only: a sparse, regular ceiling like the
			# reference photos. The far-light pool and the baked bounce light keep the gaps between tubes lit.
			if is_bright or is_classic:
				if not grid_node: continue
			# liminal: a denser, perfectly regular grid, so light is flat and even everywhere you stand
			elif liminal.has(c):
				if not (ns or ew or (x % 2 == 0 and z % 2 == 0)): continue
			elif not (ns or ew or grid_node): continue
			var is_liminal := liminal.has(c)
			var chance := 1.0 if dark.has(c) else (0.75 if dim.has(c) else (LIMINAL_BURNT_CHANCE if is_liminal else BURNT_CHANCE))
			var burnt := not (is_bright or is_classic) and rng.randf() < chance
			var flick := (not burnt) and not (is_bright or is_classic) and (flicker.has(c) or rng.randf() < (LIMINAL_FLICKER_CHANCE if is_liminal else FLICKER_CHANCE))
			if loop.has(c):                 # a corridor that repeats: every tube alike, or the repeat would show
				burnt = false
				flick = false
			fx.append({"pos": pos, "light_pos": pos - Vector3(0, 0.45, 0), "rot": PI / 2.0 if ns else 0.0,
				"burnt": burnt, "bright": is_bright, "classic": is_classic, "flickers": flick, "level": 1.0,
				"timer": rng.randf() * 4.0, "burst": 0, "black": 0.0, "slot": -1, "dsq": 0.0,
				"index": -1, "wanted": false, "ceil_h": ceiling_height(c)})
			at_cell[c] = pos
	for f in fx:
		if not f.burnt:
			f.index = lit.size()
			lit.append(f)
	_index_fixtures()

# Panel ceilings: a fixture per open cell (its five panels), a real light only on the checkerboard cells
func _place_panel_fixtures() -> void:
	_seed_fixtures()
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			# thin walls and doors leave most of their cell open, so they still need their ceiling panel
			if (walls.has(c) and not carved.has(c)) or arch_cells.has(c) or open_above.has(c): continue
			var pos := Vector3(x * CELL, ceiling_height(c), z * CELL)
			var is_classic := classic.has(c)
			var is_bright := bright.has(c)
			# only every other cell each way glows (a sparse, regular grid like the reference photos); the rest
			# of the texture's panels read as switched-off diffusers
			# a placed wall / door keeps its ceiling quad (no hole) but never glows or casts: its light would
			# sit right on top of the wall and bleed through both faces
			var on_grid := x % 2 == 0 and z % 2 == 0 and not carved.has(c)
			var chance := 1.0 if dark.has(c) else (0.6 if dim.has(c) else PANEL_BURNT_CHANCE)
			var burnt := not on_grid or (not (is_bright or is_classic) and rng.randf() < chance)
			var flick := (not burnt) and not (is_bright or is_classic) and (flicker.has(c) or rng.randf() < PANEL_FLICKER_CHANCE)
			if loop.has(c):
				burnt = not on_grid
				flick = false
			fx.append({"pos": pos, "light_pos": pos - Vector3(0, PANEL_DROP, 0), "rot": 0.0, "casts": on_grid,
				"burnt": burnt, "bright": is_bright, "classic": is_classic, "flickers": flick, "level": 1.0,
				"timer": rng.randf() * 4.0, "burst": 0, "black": 0.0, "slot": -1, "dsq": 0.0,
				"index": -1, "cell": fx.size(), "wanted": false})
	for f in fx:
		if not f.burnt:
			f.index = lit.size()
			lit.append(f)
	_index_fixtures()

# One quad per cell, the texture repeating exactly once per cell so its panels sit where the lights are
func _build_panel_ceiling() -> void:
	if fx.is_empty(): return
	var sh: Shader = load("res://shaders/panel_ceiling.gdshader")
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("albedo_tex", panel_ceiling.albedo_texture)
	mat.set_shader_parameter("normal_tex", panel_ceiling.normal_texture)
	mat.set_shader_parameter("orm_tex", panel_ceiling.roughness_texture)
	mat.set_shader_parameter("emission_tex", panel_ceiling.emission_texture)
	var quad := PlaneMesh.new()
	quad.size = Vector2(CELL, CELL)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = fx.size()
	var down := Basis(Vector3.RIGHT, PI)              # PlaneMesh faces up; flip it to face the floor
	var buf := MMBuffer.alloc(mm)
	var st := MMBuffer.stride(mm)
	for f in fx:
		MMBuffer.put(buf, f.cell * st, Transform3D(down, f.pos))
		MMBuffer.put_color(buf, f.cell * st, Color.BLACK if f.burnt else PANEL_GLOW)
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.layers = CEIL_LAYER
	add_child(mmi)
	panels_mm = mm
	ceil_mats.append(mat)          # its ceiling_fill is driven by level_lighting.gd

## A shader written out in code, compiled once: a floor rebuilt in place (level_builder.gd) reuses it
static var _coded := {}
static func _coded_shader(code: String) -> Shader:
	if not _coded.has(code):
		var sh := Shader.new()
		sh.code = code
		_coded[code] = sh
	return _coded[code]

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
	var tubes_shader := _coded_shader("shader_type spatial;\nrender_mode unshaded, shadows_disabled;\nvoid fragment() { ALBEDO = COLOR.rgb; }")
	var lit_tubes := ShaderMaterial.new()
	lit_tubes.shader = tubes_shader
	var lens_shader := _coded_shader("shader_type spatial;\nrender_mode unshaded, blend_add, depth_draw_never, shadows_disabled;\nvoid fragment() { ALBEDO = COLOR.rgb; ALPHA = 0.35; }")
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
		var buf := MMBuffer.alloc(mm)
		var st := MMBuffer.stride(mm)
		for i in items.size():
			var f: Dictionary = items[i]
			var t := Transform3D(Basis(Vector3.UP, f.rot), f.pos + yoff) * base_off * mw
			MMBuffer.put(buf, i * st, t)
			if colored: MMBuffer.put_color(buf, i * st, LIT_DIFFUSER if part == "Object_5" else LIT_DIFFUSER * 0.45)
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.layers = CEIL_LAYER          # flush with the ceiling: lit by its glow, not blown out by the tube under it
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
	var hanging: Array = fx.filter(func(f): return tall.has(cell_of(f.pos)))
	if not hanging.is_empty():
		var rise := TALL_H - WALL_H
		var cm := MultiMesh.new()
		cm.transform_format = MultiMesh.TRANSFORM_3D
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.02; cyl.bottom_radius = 0.02; cyl.height = 1.0; cyl.radial_segments = 5
		cm.mesh = cyl
		cm.instance_count = hanging.size()
		var cbuf := MMBuffer.alloc(cm)
		var cst := MMBuffer.stride(cm)
		for i in hanging.size():
			var f: Dictionary = hanging[i]
			MMBuffer.put(cbuf, i * cst, Transform3D(Basis.from_scale(Vector3(1, rise, 1)), Vector3(f.pos.x, WALL_H + rise / 2.0, f.pos.z)))
		cm.buffer = cbuf
		var chain_mat := StandardMaterial3D.new()
		chain_mat.albedo_color = Color("14120c")
		chain_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var cmi := MultiMeshInstance3D.new()
		cmi.multimesh = cm
		cmi.material_override = chain_mat
		add_child(cmi)

func _set_lit_color(f: Dictionary, lvl: float) -> void:
	if tubes_mm: tubes_mm.set_instance_color(f.index, LIT_DIFFUSER * tint * lvl)
	if lens_mm: lens_mm.set_instance_color(f.index, LIT_DIFFUSER * tint * (lvl * 0.45))
	f.glow_lvl = lvl
	_write_glow(f)
	if panels_mm: panels_mm.set_instance_color(f.cell, PANEL_GLOW * tint * lvl)

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
	_wake(f)

# Every tube dies at once; they return at staggered times after `duration`
func cut_power(duration: float) -> void:
	for f in lit:
		f.black = duration + rng.randf() * 1.6
		f.level = 0.03
		_set_lit_color(f, 0.03)
		_wake(f)

func restore_power() -> void:
	for f in lit:
		if f.black > 0.0 or f.burst > 0 or f.level < 0.5:
			f.black = 0.0
			f.burst = 0
			f.level = 1.0
			f.timer = 1.0 + rng.randf() * 3.0
			_set_lit_color(f, 1.0)
			fixture_event.emit(f, true)

func restore_all() -> void:
	restore_power()
	set_tint(Color.WHITE)

## Something big passing under the tubes: every working tube within `radius` of `pos` may stutter (a
## short burst of dropouts and re-strikes, with their pops). `strength` 0..1 = how likely each one is.
func disturb(pos: Vector3, radius: float, strength: float) -> void:
	for f in fixtures_near(pos, radius):
		if f.black > 0.0 or f.burst > 0 or rng.randf() > strength:
			continue
		f.burst = 2 * (2 + rng.randi() % 3)
		f.timer = 0.02 + rng.randf() * 0.08
		_wake(f)

## Flicker tubes near `pos` actively for `duration` seconds
func flicker_fixtures(pos: Vector3, radius: float, duration: float) -> void:
	var affected: Array = []
	for f in fixtures_near(pos, radius):
		if f.black <= 0.0: affected.append(f)

	# If the trigger was placed in a gap between fixtures, grab nearest lit tubes
	if affected.is_empty() and not lit.is_empty():
		var sorted_lit := lit.duplicate()
		sorted_lit.sort_custom(func(a, b):
			var da := Vector2(a.pos.x - pos.x, a.pos.z - pos.z).length_squared()
			var db := Vector2(b.pos.x - pos.x, b.pos.z - pos.z).length_squared()
			return da < db
		)
		for i in mini(3, sorted_lit.size()):
			if sorted_lit[i].black <= 0.0:
				affected.append(sorted_lit[i])

	var end_time := Game.time + duration
	for f in affected:
		f["flicker_until"] = end_time
		f.burst = 2 * (3 + rng.randi() % 4)      # 6 to 14 rapid bursts
		f.timer = 0.01 + rng.randf() * 0.04
		_wake(f)

# The light under a tube that has no real light on it. Only the nearest tubes get real lights
# (level_light_pool.gd), so from a distance the floor under a lit tube stayed as dark as under a dead one until
# you walked up to it. Each lit tube gets, instead:
#   - a pool of light on the floor: the floor's own texture lit the way a lamp at ceiling height lights a
#     floor (bright under it, falling away with the angle), over its own cell and the open cells round it.
#     It stops at walls and at pits (no floor there to light), so nothing is painted on the void or in the
#     next corridor over;
#   - the same light on the walls round it: a lit floor between pitch black walls reads as a glowing slab;
#   - a faint cone of lit air hanging under the tube.
# Floor and walls are lit by the real lights' own formula (energy, range and falloff of the pool's OmniLight3D,
# times the angle the light arrives at), so the fake is as bright as the real light it stands in for.
# All of it flickers with the tube and fades out as a real light fades in on it (_glow_real, from the light pool),
# so walking up to a tube swaps the fake for the real thing.
const GLOW_CELLS := 3               # the pool's quad, in cells: the tube's own and one each way
# the real lights these stand in for (level_light_pool.gd, declared below this script: keep in step with
# LIGHT_RANGE / PANEL_RANGE, PANEL_ENERGY, the pool's omni_attenuation and CLASSIC_BOOST)
const GLOW_RANGE := 20.0
const GLOW_RANGE_PANEL := 16.0
const GLOW_ENERGY_PANEL := 1.9
const GLOW_DECAY := 1.4
const GLOW_CLASSIC := 1.6
const CONE_TOP := 0.3               # metres: the cone's radius at the tube...
const CONE_BOTTOM := 1.9            # ...and at the floor
const GLOW_COLOR := Color(1.0, 0.93, 0.78)   # the tubes' light (level_light_pool.gd LIGHT_COLOR, which is declared below this script)
var cone_mm: MultiMesh
var wall_glow_mm: MultiMesh       # the lit wall faces round each tube
var _wall_glow_h := PackedFloat32Array()   # each face's wall height (it rides in the instance colour's alpha)

func _build_floor_glow() -> void:
	if lit.is_empty(): return
	var sh := _coded_shader("""shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform sampler2D floor_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 floor_tint : source_color = vec3(1.0, 0.94, 0.75);
uniform vec2 floor_scale = vec2(0.5);
uniform sampler2D tile_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tile_scale = 0.4444;
uniform vec3 light_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float strength = 1.0;
uniform float cell = 4.5;
uniform float energy = 2.2;
uniform float range = 20.0;
uniform float decay = 1.4;
varying vec2 lp;          // metres from the spot under the tube
varying vec3 wp;
varying vec4 info;        // x: which cells round it are open (bits), y: the tube's direction, z: 1 on tiles, w: the lamp's height
void vertex() {
	lp = VERTEX.xz;
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	info = INSTANCE_CUSTOM;
}
void fragment() {
	if (info.x < -0.5) discard;                 // the tube hangs over a pit
	float half_c = cell * 0.5;
	int ix = lp.x > half_c ? 1 : (lp.x < -half_c ? -1 : 0);
	int iz = lp.y > half_c ? 1 : (lp.y < -half_c ? -1 : 0);
	if (ix != 0 || iz != 0) {
		int bit;
		if (iz == 0) bit = ix > 0 ? 0 : 1;
		else if (ix == 0) bit = iz > 0 ? 2 : 3;
		else bit = (iz > 0 ? 4 : 6) + (ix > 0 ? 0 : 1);
		int m = int(info.x + 0.5);
		if (((m >> bit) & 1) == 0) discard;     // a wall, a pit, or round a corner
	}
	// a tube is a line, not a point: its pool is a little longer along it
	vec2 ax = vec2(cos(info.y), -sin(info.y));
	float along = dot(lp, ax);
	vec2 q = lp - ax * along * 0.18;
	// what an OmniLight3D of this energy, range and decay puts on a floor from this height
	float d = sqrt(dot(q, q) + info.w * info.w);
	float nd = d / range;
	nd *= nd;
	nd = max(1.0 - nd * nd, 0.0);
	float e = energy * nd * nd * pow(d, -decay) * (info.w / d);
	e *= 1.0 - smoothstep(cell * 0.75, cell * 1.45, length(lp));
	vec3 base = info.z > 0.5 ? texture(tile_tex, wp.xz * tile_scale).rgb : texture(floor_tex, wp.xz * floor_scale).rgb * floor_tint;
	ALBEDO = base * light_color * COLOR.rgb * e * strength;
}""")
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var fm: StandardMaterial3D = _pbr_or("floor") if _has_pbr("floor") else null
	if fm != null and fm.albedo_texture != null:
		mat.set_shader_parameter("floor_tex", fm.albedo_texture)
		mat.set_shader_parameter("floor_tint", fm.albedo_color)
		mat.set_shader_parameter("floor_scale", Vector2(absf(fm.uv1_scale.x), absf(fm.uv1_scale.z)))
	else:
		mat.set_shader_parameter("floor_tex", load("res://textures/l0_carpet_color.webp"))
	mat.set_shader_parameter("tile_tex", load("res://textures/tiles_color.png"))
	var energy: float = GLOW_ENERGY_PANEL if panels_mm else LIGHT_ENERGY
	var reach: float = GLOW_RANGE_PANEL if panels_mm else GLOW_RANGE
	mat.set_shader_parameter("light_color", GLOW_COLOR)
	mat.set_shader_parameter("cell", CELL)
	mat.set_shader_parameter("energy", energy)
	mat.set_shader_parameter("range", reach)
	mat.set_shader_parameter("decay", GLOW_DECAY)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	var quad := PlaneMesh.new()
	quad.size = Vector2.ONE * CELL * GLOW_CELLS
	mm.mesh = quad
	mm.instance_count = lit.size()
	var buf := MMBuffer.alloc(mm)
	var st := MMBuffer.stride(mm)
	for i in lit.size():
		var f: Dictionary = lit[i]
		f.glow_lvl = 1.0
		f.glow_share = 1.0
		var c := cell_of(f.pos)
		MMBuffer.put_at(buf, i * st, Vector3(f.pos.x, 0.02, f.pos.z))
		MMBuffer.put_color(buf, i * st, Color.WHITE)
		buf[i * st + 16] = _glow_mask(c)
		buf[i * st + 17] = f.rot
		buf[i * st + 18] = 1.0 if tiles.has(c) else 0.0
		buf[i * st + 19] = f.light_pos.y
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mmi.extra_cull_margin = CELL * GLOW_CELLS
	add_child(mmi)
	glow_mm = mm

	# the cone of lit air: soft at its silhouette, strongest up at the tube, gone by the floor
	var csh := _coded_shader("""shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform vec3 light_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float strength = 0.05;
varying float up;
void vertex() { up = VERTEX.y + 0.5; }
void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float edge = facing * facing;
	float near = smoothstep(1.5, 6.0, length(VERTEX));      // not a sheet across the lens when you stand in one
	// (up can dip a hair under 0 at the bottom ring: pow() of that is not a number, and bloom smears one such pixel into a white blob)
	ALBEDO = max(light_color * COLOR.rgb * edge * pow(clamp(up, 0.0, 1.0), 1.7) * near * strength, vec3(0.0));
}""")
	var cmat := ShaderMaterial.new()
	cmat.shader = csh
	cmat.set_shader_parameter("light_color", GLOW_COLOR)
	var cone := CylinderMesh.new()
	cone.top_radius = CONE_TOP
	cone.bottom_radius = CONE_BOTTOM
	cone.height = 1.0
	cone.radial_segments = 20
	cone.rings = 1
	cone.cap_top = false
	cone.cap_bottom = false
	var cm := MultiMesh.new()
	cm.transform_format = MultiMesh.TRANSFORM_3D
	cm.use_colors = true
	cm.mesh = cone
	cm.instance_count = lit.size()
	var cbuf := MMBuffer.alloc(cm)
	var cst := MMBuffer.stride(cm)
	for i in lit.size():
		var f: Dictionary = lit[i]
		var h: float = f.light_pos.y
		MMBuffer.put(cbuf, i * cst, Transform3D(Basis.from_scale(Vector3(1.0, h, 1.0)), Vector3(f.pos.x, h * 0.5, f.pos.z)))
		MMBuffer.put_color(cbuf, i * cst, Color.WHITE)
	cm.buffer = cbuf
	var cmi := MultiMeshInstance3D.new()
	cmi.multimesh = cm
	cmi.material_override = cmat
	cmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(cmi)
	cone_mm = cm

	# the walls round each tube: one quad a wall face, over the tube's own cell and the open cells beside it
	var wsh := _coded_shader("""shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform sampler2D wall_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tall_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 wall_tint : source_color = vec3(1.0, 0.98, 0.88);
uniform vec2 wall_scale = vec2(0.4444, 1.0);   // repeats a metre along the wall; up it (when not one texture a wall height)
uniform float wall_flip = 1.0;                 // 1: one texture a wall height, its top at the top
uniform float cell = 4.5;
uniform float tall_from = 8.0;                 // walls this high wear tall_tex
uniform vec3 light_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float strength = 1.0;
uniform float energy = 2.2;
uniform float range = 20.0;
uniform float decay = 1.4;
varying vec3 wp;
varying vec3 wn;
varying vec3 lamp;
void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	lamp = INSTANCE_CUSTOM.xyz;
}
void fragment() {
	vec3 l = lamp - wp;
	float d = max(length(l), 0.05);
	float nd = d / range;
	nd *= nd;
	nd = max(1.0 - nd * nd, 0.0);
	float e = energy * nd * nd * pow(d, -decay) * max(dot(wn, l / d), 0.0);
	// it dies away along the wall as the pool does across the floor: no lit rectangle with a hard end
	e *= 1.0 - smoothstep(cell * 0.75, cell * 1.45, length(l.xz));
	float h = COLOR.a * 16.0;
	float along = abs(wn.x) > 0.5 ? wp.z : wp.x;
	vec2 uv = vec2(along * wall_scale.x, wall_flip > 0.5 ? 1.0 - wp.y / h : wp.y * wall_scale.y);
	vec3 base = (h > tall_from ? texture(tall_tex, uv).rgb : texture(wall_tex, uv).rgb) * wall_tint;
	ALBEDO = base * light_color * COLOR.rgb * e * strength;
}""")
	var wmat := ShaderMaterial.new()
	wmat.shader = wsh
	if wall_mat != null and wall_mat.albedo_texture != null:
		var sc := wall_mat.uv1_scale
		wmat.set_shader_parameter("wall_tex", wall_mat.albedo_texture)
		wmat.set_shader_parameter("tall_tex", tall_wall_mat.albedo_texture if tall_wall_mat != null and tall_wall_mat.albedo_texture != null else wall_mat.albedo_texture)
		wmat.set_shader_parameter("wall_tint", wall_mat.albedo_color)
		wmat.set_shader_parameter("wall_scale", Vector2(absf(sc.x), absf(sc.y)))
		wmat.set_shader_parameter("wall_flip", 1.0 if sc.y < 0.0 else 0.0)
	wmat.set_shader_parameter("tall_from", (WALL_H + TALL_H) * 0.5)
	wmat.set_shader_parameter("cell", CELL)
	wmat.set_shader_parameter("light_color", GLOW_COLOR)
	wmat.set_shader_parameter("energy", energy)
	wmat.set_shader_parameter("range", reach)
	wmat.set_shader_parameter("decay", GLOW_DECAY)
	var faces: Array = []            # [transform, the tube's light, the wall's height]
	for f: Dictionary in lit:
		f.glow_faces = PackedInt32Array()
		var c := cell_of(f.pos)
		if stair_cells.has(c): continue
		# (a cell with no floor still has walls round it: a wall lit up to the edge of a pit and black beside
		# it is a rectangle of light with hard ends)
		var from: Array[Vector2i] = [c]
		for n: Vector2i in DIRS:
			var o2 := c + n
			if not (walls.has(o2) or stair_cells.has(o2) or edge_blocked(c, o2)): from.append(o2)
		for o: Vector2i in from:
			for n: Vector2i in DIRS:
				if not (walls.has(o + n) and _block_at(o + n)): continue
				var hgt: float = TALL_H if tall.has(o) else WALL_H
				var nrm := Vector3(-n.x, 0.0, -n.y)                      # the face looks back into the open cell
				var at := Vector3(o.x * CELL, hgt * 0.5, o.y * CELL) - nrm * (CELL * 0.5 - 0.012)
				var xf := Transform3D(Basis(Vector3.UP.cross(nrm) * CELL, Vector3.UP * hgt, nrm), at)
				f.glow_faces.append(faces.size())
				faces.append([xf, f.light_pos, hgt])
	_wall_glow_h.resize(faces.size())
	if not faces.is_empty():
		var wm := MultiMesh.new()
		wm.transform_format = MultiMesh.TRANSFORM_3D
		wm.use_colors = true
		wm.use_custom_data = true
		wm.mesh = QuadMesh.new()
		wm.instance_count = faces.size()
		var wbuf := MMBuffer.alloc(wm)
		var wst := MMBuffer.stride(wm)
		for i in faces.size():
			var lamp: Vector3 = faces[i][1]
			_wall_glow_h[i] = float(faces[i][2]) / 16.0
			MMBuffer.put(wbuf, i * wst, faces[i][0])
			MMBuffer.put_color(wbuf, i * wst, Color(1, 1, 1, _wall_glow_h[i]))
			wbuf[i * wst + 16] = lamp.x
			wbuf[i * wst + 17] = lamp.y
			wbuf[i * wst + 18] = lamp.z
		wm.buffer = wbuf
		var wmi := MultiMeshInstance3D.new()
		wmi.multimesh = wm
		wmi.material_override = wmat
		wmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		wmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(wmi)
		wall_glow_mm = wm
	for f: Dictionary in lit: _write_glow(f)      # (a classic tube's boost is in its colour)

## Which of the eight cells round `c` a pool of light under a tube in `c` spreads onto, as bits (the shader's
## order: +x, -x, +z, -z, then the corners +x+z, -x+z, +x-z, -x-z); -1 when `c` itself has no floor
func _glow_mask(c: Vector2i) -> float:
	if not _glow_floor(c): return -1.0
	var m := 0
	var orth := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var open := [false, false, false, false]
	for k in 4:
		open[k] = _glow_floor(c + orth[k]) and not edge_blocked(c, c + orth[k])
		if open[k]: m |= 1 << k
	# a corner cell is lit past either of the cells beside it
	var diag := [[0, 2], [1, 2], [0, 3], [1, 3]]
	for k in 4:
		var d: Vector2i = orth[diag[k][0]] + orth[diag[k][1]]
		if _glow_floor(c + d) and (open[diag[k][0]] or open[diag[k][1]]): m |= 1 << (4 + k)
	return float(m)

## Floor a tube's light can land on: not wall (a thin wall or door in the cell counts as wall), pit or stairwell
func _glow_floor(c: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= size or c.y >= size: return false
	return not (walls.has(c) or pits.has(c) or through.has(c) or stair_cells.has(c))

## The fake light of tube `f` as it is now: its level, the events' tint, and the share no real light covers
func _write_glow(f: Dictionary) -> void:
	if glow_mm == null or int(f.index) < 0: return
	var k: float = float(f.get("glow_lvl", 1.0)) * float(f.get("glow_share", 1.0))
	var c := Color(tint.r * k, tint.g * k, tint.b * k)
	if cone_mm: cone_mm.set_instance_color(f.index, c)
	if f.classic: c = Color(c.r * GLOW_CLASSIC, c.g * GLOW_CLASSIC, c.b * GLOW_CLASSIC)
	glow_mm.set_instance_color(f.index, c)
	if wall_glow_mm:
		for i: int in f.get("glow_faces", PackedInt32Array()):
			wall_glow_mm.set_instance_color(i, Color(c.r, c.g, c.b, _wall_glow_h[i]))

## The light pool, every frame for the tubes it holds: a real light is on tube `f` at this strength (0..1) from
## this source ("rw_slot": a near light, "rw_far": a far one). The fake fades by as much.
func _glow_real(f: Dictionary, key: String, w: float) -> void:
	if glow_mm == null: return
	f[key] = w
	var share := 1.0 - clampf(maxf(float(f.get("rw_slot", 0.0)), float(f.get("rw_far", 0.0))), 0.0, 1.0)
	var was: float = f.get("glow_share", 1.0)
	if share == was or (absf(share - was) < 0.02 and share > 0.0 and share < 1.0): return
	f.glow_share = share
	_write_glow(f)

# Fake planar reflection for the polished room: mirrored fixture panels under the
# semi-transparent floor, plus two steady lights so the room stays bright.
func _build_floor_reflections() -> void:
	var items: Array = fx.filter(func(f): return f.bright)
	if items.is_empty(): return
	var shader := _coded_shader("shader_type spatial;\nrender_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;\nvoid fragment() { ALBEDO = vec3(2.2, 2.15, 1.9) * 0.55; ALPHA = 1.0; }")
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = -1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var box := BoxMesh.new()
	box.size = Vector3(0.7, 0.02, 0.7) if panels_mm else Vector3(1.95, 0.02, 0.82)
	mm.mesh = box
	var offs: Array = PANEL_OFFSETS if panels_mm else [Vector2.ZERO]   # a panel cell mirrors all five of its panels
	mm.instance_count = items.size() * offs.size()
	var cx := 0.0
	var cz := 0.0
	var buf := MMBuffer.alloc(mm)
	var st := MMBuffer.stride(mm)
	for i in items.size():
		var f: Dictionary = items[i]
		for k in offs.size():
			var o: Vector2 = offs[k]
			MMBuffer.put(buf, (i * offs.size() + k) * st, Transform3D(Basis(Vector3.UP, f.rot), Vector3(f.pos.x + o.x, -f.pos.y, f.pos.z + o.y)))
		cx += f.pos.x
		cz += f.pos.z
	mm.buffer = buf
	cx /= items.size()
	cz /= items.size()
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	reflect_mmi = mmi
	for o in [-2.2, 2.2]:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.94, 0.80)
		l.omni_range = 24.0
		l.light_cull_mask &= ~(CEIL_LAYER | SHELL_LAYERS)
		l.omni_attenuation = 1.3
		l.light_energy = LIGHT_ENERGY * 1.5
		l.shadow_enabled = false              # two shadowed 24 m omnis over the whole level were a big fps cost
		l.shadow_bias = 0.03
		l.position = Vector3(cx, WALL_H - 0.6, cz + o * CELL)
		add_child(l)
		fill_lights.append(l)

# Failing-tube model: long stable stretches, then a burst of rapid dropouts and re-strikes.
# Steady tubes only stutter when something disturbs them (a burst already set). Only the awake tubes are
# looked at (_wake); a steady one goes back to sleep once it has nothing left to do.
func _update_fixtures(delta: float) -> void:
	var settled: Array[int] = []
	# (a copy of the keys: whatever listens to fixture_event may set more tubes off while this runs)
	for i: int in _awake.keys():
		var f = _awake.get(i)
		if f == null: continue
		if f.black > 0.0:
			f.black -= delta
			if f.black <= 0.0:
				f.level = 1.0
				f.burst = 0
				f.timer = 1.0 + rng.randf() * 3.0
				_set_lit_color(f, 1.0)
				fixture_event.emit(f, true)
			continue
		var is_event_flickering: bool = float(f.get("flicker_until", 0.0)) > Game.time
		if not f.flickers and not is_event_flickering and f.burst == 0:
			settled.append(i)
			continue
		f.timer -= delta
		if f.timer > 0.0: continue
		if f.burst == 0:
			if is_event_flickering:
				f.burst = 2 * (2 + rng.randi() % 4)
			else:
				f.burst = 2 * (1 + rng.randi() % 4)      # even: always ends lit
		f.burst -= 1
		var going_off: bool = f.level > 0.3
		f.level = 0.04 if going_off else 0.7 + rng.randf() * 0.45
		f.timer = (0.03 + rng.randf() * 0.09) if going_off else (0.04 + rng.randf() * 0.14)
		if f.burst == 0:
			f.level = 1.0
			f.timer = (0.08 + rng.randf() * 0.25) if is_event_flickering else (1.5 + rng.randf() * 6.0)
		_set_lit_color(f, 0.06 if going_off else f.level)
		fixture_event.emit(f, not going_off)
	for i in settled:
		var f = _awake.get(i)
		# (unless something set it off again since)
		if f != null and f.black <= 0.0 and f.burst == 0: _awake.erase(i)
