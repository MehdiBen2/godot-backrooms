extends "res://scripts/World/level/level_geometry.gd"
## THE LEVEL, layer 3: its light (the web game's level.js lights + lighting.js).
##
## Troffer fixtures are placed like the web game's _placeLights, some burnt out, some flickering. Only a
## small pool of real lights exists: POOL_SIZE slots re-targeted to the nearest working tubes and cross-
## faded so nothing pops (each slot also drives one spatial hum voice in audio.gd). How many of those are
## actually lit, and how many of the nearest cast shadows, comes from the graphics preset (Gfx `lights` /
## `light_shadows`), which is what keeps this playable on a weak PC. The tube-light estimate that drives
## sanity, fog and the entity's sight (tube_light_at) is the same on every preset.
##
## Failing tubes: long stable stretches, then a burst of dropouts and re-strikes. Anything big running
## underneath them (disturb) sets them off too. Fog and ambient follow how much tube light reaches you.

signal fixture_event(fixture: Dictionary, restrike: bool)   # audio listens: arc pop / re-strike tick
signal slot_assigned(slot: int)                              # a light came into range (hum "notice")

const LIGHT_RANGE := 20.0
const LIGHT_ENERGY := 2.2           # tuned for Godot 4 PBR lighting
const LIGHT_COLOR := Color(1.0, 0.93, 0.78)
const CLASSIC_BOOST := 1.6          # classic-zone tubes are this much brighter
const BURNT_CHANCE := 0.16
const FLICKER_CHANCE := 0.24
const POOL_SIZE := 12
const SELECT_RADIUS := 26.0
const FADE_START := 18.0
# Far lights: past the main pool every tube you can see still lights the walls round it. Cheap, shadowless,
# short-ranged point lights (Forward+ clusters them) on the next nearest tubes out to FAR_RADIUS; how many
# comes from the graphics preset (Gfx `far_lights`). Same range and falloff as the near lights, so a wall
# 30 m away is lit exactly like the same wall up close (anything else reads as a flat, fake distance).
const FAR_MAX := 32
const FAR_RADIUS := 46.0
const FAR_FADE := 36.0
# Eye adaptation: exposure follows how much tube light is where you stand and where you look, so a
# shadowed corner opens up and a blazing hall calms down. Dark zones and power cuts are left dark.
const EYE_GAIN_DARK := 1.35
const EYE_GAIN_BRIGHT := 0.85
const EYE_SPEED := 0.9
const EYE_PROBE := 8.0
# Glare: looking into a lit tube / panel stops the exposure down, so the rest of the room drops toward shadow
# like a real eye or camera. Clamps down fast, opens back up slowly.
const GLARE_CONE := 0.87            # cos of the half-angle round the view centre where a light counts (~30 deg)
const GLARE_FULL := 0.99            # cos where it counts fully (~8 deg: staring straight at it)
const GLARE_DIST := 7.0             # metres: nearer lights glare more
const GLARE_DIM := 0.55             # exposure multiplier at full glare (the light itself stays clipped white: it's HDR)
const GLARE_IN := 3.5               # 1/s: stopping down (fast)
const GLARE_OUT := 0.7              # 1/s: opening back up (slow)
# Ceiling glow: the tube lights skip the ceiling (CEIL_LAYER, level_geometry.gd), so each lit slot also drives a
# soft light further down that only reaches the ceiling: the broad halo round a real troffer, never a hotspot.
# It only ever lights the CEIL_LAYER mesh (never walls), so walls can never occlude it: it has no way to
# know a corner is in the way. Its range is kept well under CELL (level_data.gd) so the halo stays inside
# the fixture's own cell instead of bleeding over a nearby wall onto a corridor the fixture isn't even in.
const CEIL_GLOW := 0.5              # of the slot's energy, tube fixtures (the ceiling round a troffer is well lit)
const CEIL_GLOW_PANEL := 0.2        # panel ceilings: the panels themselves already light up the tiles round them
const CEIL_GLOW_DROP := 1.6         # metres under the fixture: further down = wider, softer halo
const CEIL_GLOW_RANGE := 3.5
const LIT_DIFFUSER := Color(3.2, 3.0, 2.55)   # HDR: well past the bloom threshold, so a lit tube glows and hits the lens
const TOP_Y := 0.1432132             # troffer housing top, baked model coordinates
const FOG_DENSITY := 0.075
const FOG_LIT_SCALE := 0.5
const FOG_DARK_BOOST := 0.5
const AMBIENT_MIN := 0.3
const BOUNCE_RADIUS := 7.0
const BOUNCE_FULL := 1.3
const ADAPT := 1.6
const FOG_COLOR := Color("141108")
const FOG_COLOR_DARK := Color("020201")

# ---- panel ceilings (a ceiling material with baked light panels, see level_geometry.gd panel_ceiling)
# Every open cell is a fixture that owns its five panels (the texture repeats once per cell: one panel
# in the middle, four on the diagonals). Only every other cell each way glows and hides a real light behind
# its panels (a sparse, regular grid); the other cells' panel squares are drawn as plain ceiling tiles.
const PANEL_ENERGY := 1.9
const PANEL_RANGE := 16.0
const PANEL_DROP := 0.35            # metres under the ceiling for the light (so the ceiling itself is lit too)
const PANEL_GLOW := Color(3.6, 3.25, 2.75)  # HDR emission multiplier over the (pale blue) emission map: a warm white that blooms
const PANEL_BURNT_CHANCE := 0.08
const PANEL_FLICKER_CHANCE := 0.06
const PANEL_OFFSETS := [Vector2(0, 0), Vector2(-1.5, -1.5), Vector2(1.5, -1.5), Vector2(-1.5, 1.5), Vector2(1.5, 1.5)]

## Level-wide looks. "dim" is what main.tscn's WorldEnvironment is tuned for; the others are where the
## environment blends to while you stand in them (classic_mix: the Classic zone, or "atmosphere":
## "classic" for the whole level). Tune the classic backrooms look here.
const ATMOSPHERES := {
	"classic": {
		"ambient_energy": 0.8, "ambient_color": Color(0.36, 0.31, 0.17),   # flat, even yellow fill: far walls never go dark
		"exposure": 1.05, "tonemap_white": 4.0,       # gentle highlight roll-off: panels clip white, walls don't
		"glow_threshold": 1.1,                        # the panels bloom, the brightly lit walls don't
		"glow_intensity": 1.0, "glow_bloom": 0.02, "glow_wide": 0.5,    # wide soft halo round the lights (glow level 5)
		"ssao_intensity": 2.5,                        # fluorescent light is shadowless: keep only contact AO
		"haze": Color(0.66, 0.58, 0.36),              # the far distance fades to lit-wallpaper yellow, never to murk
	},
}

var panels_mm: MultiMesh   # panel ceilings: one instance per fixture, its colour = that cell's panel glow
var _env_base := {}        # the WorldEnvironment's own (dim) values, read once

var fx: Array = []        # every fixture
var lit: Array = []       # the non-burnt ones (the light pool ranks these)
var tubes_mm: MultiMesh
var lens_mm: MultiMesh
var tint := Color.WHITE   # events recolour every lit tube (null in the web game = white)

# ---- light pool
var pool: Array[OmniLight3D] = []
var pool_b: Array[OmniLight3D] = []     # a twin for each slot: the two ends of the long tube (Godot has no area lights)
const TWIN_RANGE := 15.0              # metres: beyond this only one light per tube
const TUBE_HALF := 0.65                # metres from the fixture centre to each end light
var slot_fixture: Array = []       # fixture Dictionary or null
var slot_weight: Array[float] = []
var slot_target: Array[float] = []
var slot_on: Array[float] = []     # 0..1: lit under the quality cap (eased, so a light never pops)
var slot_want: Array[bool] = []
# Only the nearest few lights cast shadows (Gfx `light_shadows`), and the tube twins and far lights never
# do, so an unshadowed light shines straight through walls: a tube in the next corridor would light your
# floor with no source in sight. Each fixture gets a grid line-of-sight test to the player (f.seen) and an
# unshadowed light fades out while its tube is behind a wall. Eased, so nothing pops.
var slot_vis: Array[float] = []    # 0..1: main light allowed (shadowed, or its tube in sight)
var slot_twin: Array[float] = []   # 0..1: twin allowed (never shadowed, so only while in sight)
var far_vis: Array[float] = []
var _door_cells := {}              # doorways let light through; every other wall cell blocks it
var _rank_timer := 0.0
var _candidates: Array = []
var _lit_cap := POOL_SIZE
var _shadow_cap := 4

# ---- atmosphere
var env: Environment
var bounce := 1.0
var eye := 1.0                     # eye-adaptation exposure gain
var glare := 0.0                   # 0..1 smoothed: how much light you are looking straight into
var cam_mix := 0.0                 # how far the camera settings lean to the classic look (Classic zone, or softer in Bright)
var far_pool: Array[OmniLight3D] = []
var ceil_glow: Array[OmniLight3D] = []   # one per pool slot: lights only the ceiling layer
var far_fixture: Array = []        # fixture Dictionary or null
var far_weight: Array[float] = []
var _far_candidates: Array = []
var _far_cap := 16
var grid_glow := 0.0
var zone_amb := 1.0
var zone_fog := 1.0
var fill_lights: Array[OmniLight3D] = []   # the two steady fill lights of bright levels (off in a power cut)
var reflect_mmi: MultiMeshInstance3D   # the fake floor reflections of bright-zone tubes (they live below the floor)
var bright_mix := 0.0              # same idea for Bright zones (a softer version of the classic look)
var open_mix := 0.0                # how far the air is cleared and the far distance filled with light
var classic_mix := 0.0             # 0..1: how much of the classic look the player is standing in

func build_lighting() -> void:
	for o: Dictionary in objects:
		if o.type == "door":
			_door_cells[Vector2i(roundi(o.pos_x), roundi(o.pos_y))] = true
	if panel_ceiling != null:
		_place_panel_fixtures()
		_build_panel_ceiling()
	else:
		_place_fixtures()
		_build_fixture_meshes()
	_build_light_pool()
	_build_floor_reflections()
	var we := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	env = we.environment if we else null
	_read_quality()
	Gfx.changed.connect(_read_quality)
	_apply_gi()
	Gfx.changed.connect(_apply_gi)

## Bounce light. Best: the level's baked VoxelGI (tools/bake_level.gd, run by the level editor on every save).
## Only the geometry is baked, the light bouncing round it is live, so flickering tubes and power cuts bounce
## too. It is used while the .lvl is unchanged since the bake and the preset allows it (Gfx `baked_gi`: High and
## Ultra; Ultra adds a second bounce). Without a bake: SDFGI, heavy, so only on Ultra ("ssil") and only for
## levels with a Classic zone unless the .lvl forces it with "sdfgi": true / false (the editor's REAL-TIME GI).
const BAKE_VERSION := "3"          # bump when the geometry code changes in a way old bakes no longer match
var voxel_gi: VoxelGI

func gi_path() -> String:
	return "res://levels/baked/%s_gi.res" % str(level_meta.get("id", "level"))

## Changes whenever the level file (or BAKE_VERSION) does: a stale bake is never used
func bake_hash() -> String:
	return (FileAccess.get_file_as_string("res://levels/" + str(level_meta.get("file", ""))) + BAKE_VERSION).md5_text()

## The box the VoxelGI covers: the whole grid, floor to the highest ceiling, a little margin all round
func gi_bounds() -> Dictionary:
	var top := TALL_H if not tall.is_empty() else WALL_H
	var lo := Vector3(-CELL * 0.5, -0.5, -CELL * 0.5)
	var hi := Vector3((size - 0.5) * CELL, top + 0.5, (size - 0.5) * CELL)
	return {"center": (lo + hi) * 0.5, "size": hi - lo}

func _load_baked_gi() -> VoxelGIData:
	if not ResourceLoader.exists(gi_path()): return null
	var data := load(gi_path()) as VoxelGIData
	return data if data != null and str(data.get_meta("lvl_hash", "")) == bake_hash() else null

func _apply_gi() -> void:
	if env == null: return
	var data: VoxelGIData = _load_baked_gi() if (bool(Gfx.s.get("baked_gi", false)) and not Gfx.compat) else null
	if data != null:
		if voxel_gi == null:
			voxel_gi = VoxelGI.new()
			voxel_gi.position = data.get_meta("center")
			voxel_gi.size = data.get_meta("size")
			voxel_gi.subdiv = data.get_meta("subdiv")
			add_child(voxel_gi)
		data.interior = true                 # no sky: only the tubes light the place
		data.energy = 1.15
		data.propagation = 0.75              # how far bounced light travels from voxel to voxel
		data.dynamic_range = 4.0
		data.bias = 1.0
		data.normal_bias = 0.2
		data.use_two_bounces = false         # each bounce off yellow walls multiplies the colour: two turned dark corners red-brown
		voxel_gi.data = data
		voxel_gi.visible = true
	elif voxel_gi != null:
		voxel_gi.visible = false
	var want: bool = level_data.get("sdfgi", not classic.is_empty())
	env.sdfgi_enabled = data == null and want and bool(Gfx.s.get("ssil", false)) and not Gfx.compat
	if env.sdfgi_enabled:
		env.sdfgi_cascades = 3
		env.sdfgi_min_cell_size = 0.5
		# Off: SDFGI's probe occlusion approximates AO from the voxel cascades, which lag behind
		# fast-moving dynamic objects (the player) and show up as a dark halo/blob dragging along
		# beneath them. The bounce light itself still works fine without it.
		env.sdfgi_use_occlusion = false
		env.sdfgi_bounce_feedback = 0.6
		env.sdfgi_energy = 1.0

func _read_quality() -> void:
	_lit_cap = clampi(int(Gfx.s.get("lights", POOL_SIZE)), 1, POOL_SIZE)
	_far_cap = clampi(int(Gfx.s.get("far_lights", 16)), 0, FAR_MAX)
	_shadow_cap = int(Gfx.s.get("light_shadows", 4)) if int(Gfx.s.get("shadows", 1)) > 0 else 0
	_rank_timer = 0.0

# ----------------------------------------------------------------- fixtures
# Same placement rules as the web game's _placeLights: corridor cells and a 3-cell grid, min
# spacing 1.9 cells, some tubes burnt out, some flickering.
func _place_fixtures() -> void:
	var min_sp := CELL * 1.9
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			if walls.has(c) or arch_cells.has(c): continue
			var y := LOW_H - 0.03 if ceiling_height(c) == LOW_H else WALL_H - 0.03
			var pos := Vector3(x * CELL, y, z * CELL)
			var too_close := false
			for f in fx:
				if (f.pos as Vector3).distance_to(pos) < min_sp:
					too_close = true
					break
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
			elif not (ns or ew or grid_node): continue
			var chance := 1.0 if dark.has(c) else (0.75 if dim.has(c) else BURNT_CHANCE)
			var burnt := not (is_bright or is_classic) and rng.randf() < chance
			var flick := (not burnt) and not (is_bright or is_classic) and (flicker.has(c) or rng.randf() < FLICKER_CHANCE)
			fx.append({"pos": pos, "light_pos": pos - Vector3(0, 0.45, 0), "rot": PI / 2.0 if ns else 0.0,
				"burnt": burnt, "bright": is_bright, "classic": is_classic, "flickers": flick, "level": 1.0,
				"timer": rng.randf() * 4.0, "burst": 0, "black": 0.0, "slot": -1, "dsq": 0.0,
				"index": -1, "wanted": false, "ceil_h": ceiling_height(c)})
	for f in fx:
		if not f.burnt:
			f.index = lit.size()
			lit.append(f)

# Panel ceilings: a fixture per open cell (its five panels), a real light only on the checkerboard cells
func _place_panel_fixtures() -> void:
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			# thin walls and doors leave most of their cell open, so they still need their ceiling panel
			if (walls.has(c) and not carved.has(c)) or arch_cells.has(c): continue
			var pos := Vector3(x * CELL, ceiling_height(c), z * CELL)
			var is_classic := classic.has(c)
			var is_bright := bright.has(c)
			# only every other cell each way glows (a sparse, regular grid like the reference photos); the rest
			# of the texture's panels read as switched-off diffusers
			var on_grid := x % 2 == 0 and z % 2 == 0
			var chance := 1.0 if dark.has(c) else (0.6 if dim.has(c) else PANEL_BURNT_CHANCE)
			# a door / thin wall stands right under the cell centre, where the light would go: it would sit
			# inside the partition, so these cells keep their panel but never glow or cast
			var burnt := not on_grid or carved.has(c) or (not (is_bright or is_classic) and rng.randf() < chance)
			var flick := (not burnt) and not (is_bright or is_classic) and (flicker.has(c) or rng.randf() < PANEL_FLICKER_CHANCE)
			fx.append({"pos": pos, "light_pos": pos - Vector3(0, PANEL_DROP, 0), "rot": 0.0, "casts": on_grid,
				"burnt": burnt, "bright": is_bright, "classic": is_classic, "flickers": flick, "level": 1.0,
				"timer": rng.randf() * 4.0, "burst": 0, "black": 0.0, "slot": -1, "dsq": 0.0,
				"index": -1, "cell": fx.size(), "wanted": false})
	for f in fx:
		if not f.burnt:
			f.index = lit.size()
			lit.append(f)

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
	for f in fx:
		mm.set_instance_transform(f.cell, Transform3D(down, f.pos))
		mm.set_instance_color(f.cell, Color.BLACK if f.burnt else PANEL_GLOW)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.layers = CEIL_LAYER
	add_child(mmi)
	panels_mm = mm

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

func _set_lit_color(f: Dictionary, lvl: float) -> void:
	if tubes_mm: tubes_mm.set_instance_color(f.index, LIT_DIFFUSER * tint * lvl)
	if lens_mm: lens_mm.set_instance_color(f.index, LIT_DIFFUSER * tint * (lvl * 0.45))
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

# Every tube dies at once; they return at staggered times after `duration`
func cut_power(duration: float) -> void:
	for f in lit:
		f.black = duration + rng.randf() * 1.6
		f.level = 0.03
		_set_lit_color(f, 0.03)

func restore_power() -> void:
	for f in lit:
		if f.black > 0.0: f.black = 0.001

## Something big passing under the tubes: every working tube within `radius` of `pos` may stutter (a
## short burst of dropouts and re-strikes, with their pops). `strength` 0..1 = how likely each one is.
func disturb(pos: Vector3, radius: float, strength: float) -> void:
	var r2 := radius * radius
	for f in lit:
		if f.black > 0.0 or f.burst > 0:
			continue
		if (f.pos as Vector3).distance_squared_to(pos) > r2 or rng.randf() > strength:
			continue
		f.burst = 2 * (1 + rng.randi() % 2)      # even: always ends lit
		f.timer = rng.randf() * 0.15

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
	box.size = Vector3(0.7, 0.02, 0.7) if panels_mm else Vector3(1.95, 0.02, 0.82)
	mm.mesh = box
	var offs: Array = PANEL_OFFSETS if panels_mm else [Vector2.ZERO]   # a panel cell mirrors all five of its panels
	mm.instance_count = items.size() * offs.size()
	var cx := 0.0
	var cz := 0.0
	for i in items.size():
		var f: Dictionary = items[i]
		for k in offs.size():
			var o: Vector2 = offs[k]
			mm.set_instance_transform(i * offs.size() + k, Transform3D(Basis(Vector3.UP, f.rot), Vector3(f.pos.x + o.x, -f.pos.y, f.pos.z + o.y)))
		cx += f.pos.x
		cz += f.pos.z
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
		l.light_cull_mask &= ~CEIL_LAYER
		l.omni_attenuation = 1.3
		l.light_energy = LIGHT_ENERGY * 1.5
		l.shadow_enabled = false              # two shadowed 24 m omnis over the whole level were a big fps cost
		l.shadow_bias = 0.03
		l.position = Vector3(cx, WALL_H - 0.6, cz + o * CELL)
		add_child(l)
		fill_lights.append(l)

# ---------------------------------------------------------------- light pool
func _build_light_pool() -> void:
	for i in POOL_SIZE:
		var l := OmniLight3D.new()
		l.light_color = LIGHT_COLOR
		l.light_size = 0.0                   # > 0 turns on PCSS soft shadows, which are expensive; shadow_blur is enough
		l.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID   # much cheaper than cube shadows, fine for ceiling lights
		l.omni_range = PANEL_RANGE if panels_mm else LIGHT_RANGE
		l.omni_attenuation = 1.4
		l.light_energy = 0.0
		l.shadow_enabled = false
		l.shadow_bias = 0.04
		l.shadow_normal_bias = 1.2
		l.shadow_blur = 1.6
		l.visible = false
		l.light_cull_mask &= ~CEIL_LAYER     # the ceiling gets its glow from ceil_glow instead (no hotspot)
		l.set_meta("gfx_managed", true)      # Gfx.apply_scene leaves these to us
		add_child(l)
		pool.append(l)
		var lb := l.duplicate() as OmniLight3D           # the tube's other end; unshadowed (only the first casts)
		lb.set_meta("gfx_managed", true)
		add_child(lb)
		pool_b.append(lb)
		slot_fixture.append(null)
		slot_weight.append(0.0)
		slot_target.append(0.0)
		slot_on.append(0.0)
		slot_want.append(false)
		slot_vis.append(0.0)
		slot_twin.append(0.0)
		var g := OmniLight3D.new()
		g.light_color = LIGHT_COLOR
		g.omni_range = CEIL_GLOW_RANGE
		g.omni_attenuation = 1.6
		g.light_cull_mask = CEIL_LAYER
		g.light_specular = 0.0
		g.shadow_enabled = false
		g.visible = false
		g.set_meta("gfx_managed", true)
		add_child(g)
		ceil_glow.append(g)
	for i in FAR_MAX:
		var fl := OmniLight3D.new()
		fl.light_color = LIGHT_COLOR
		fl.omni_range = PANEL_RANGE if panels_mm else LIGHT_RANGE
		fl.omni_attenuation = 1.4
		fl.shadow_enabled = false
		fl.light_cull_mask &= ~CEIL_LAYER
		fl.light_energy = 0.0
		fl.visible = false
		fl.set_meta("gfx_managed", true)
		add_child(fl)
		far_pool.append(fl)
		far_fixture.append(null)
		far_weight.append(0.0)
		far_vis.append(0.0)

func slot_level(i: int) -> float:
	var f = slot_fixture[i]
	return 0.0 if f == null else f.level * slot_weight[i]

func slot_position(i: int) -> Vector3:
	var f = slot_fixture[i]
	return Vector3.ZERO if f == null else f.light_pos

## Grid line of sight from a light to a point: any wall cell in between blocks it (a doorway doesn't), and
## so does an off-centre thin wall or door. The two end cells are skipped, the light's own and the target's.
func _light_sees(a: Vector3, b: Vector3) -> bool:
	var ca := cell_of(a)
	var cb := cell_of(b)
	var dx := b.x - a.x
	var dz := b.z - a.z
	var steps := ceili(sqrt(dx * dx + dz * dz) / 0.5)
	for i in range(1, steps):
		var t := float(i) / steps
		var c := Vector2i(roundi((a.x + dx * t) / CELL), roundi((a.z + dz * t) / CELL))
		if c == ca or c == cb: continue
		if walls.has(c) and not _door_cells.has(c): return false
	return not crosses_wall_segment(Vector2(a.x, a.z) / CELL, Vector2(b.x, b.z) / CELL)

func _rank(p: Vector3) -> void:
	var max_sq := SELECT_RADIUS * SELECT_RADIUS
	var far_sq := FAR_RADIUS * FAR_RADIUS
	_candidates.clear()
	for f in lit:
		var dx: float = f.pos.x - p.x
		var dz: float = f.pos.z - p.z
		f.dsq = dx * dx + dz * dz
		f.wanted = false
		f.far_wanted = false
		if f.dsq < far_sq and f.get("casts", true):
			f.seen = _light_sees(f.light_pos, p)
			_candidates.append(f)
	_candidates.sort_custom(func(a, b): return a.dsq < b.dsq)
	# the far lights take over where the preset's lit cap stops (so a low preset still lights distant walls)
	_far_candidates = _candidates.slice(mini(_lit_cap, _candidates.size()), mini(_lit_cap + _far_cap, _candidates.size()))
	for f in _far_candidates: f.far_wanted = true
	var n := 0
	while n < mini(_candidates.size(), POOL_SIZE) and _candidates[n].dsq < max_sq:
		_candidates[n].wanted = true
		n += 1
	_candidates.resize(n)

# Which slots are lit (the nearest `_lit_cap`) and which of those cast shadows (the nearest `_shadow_cap`)
func _rank_slots() -> void:
	var order: Array[int] = []
	for i in POOL_SIZE:
		slot_want[i] = false
		if slot_fixture[i] != null:
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return slot_fixture[a].dsq < slot_fixture[b].dsq)
	for r in order.size():
		var i := order[r]
		slot_want[i] = r < _lit_cap
		var shadow := r < _shadow_cap
		if pool[i].shadow_enabled != shadow:
			pool[i].shadow_enabled = shadow

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
			slot_vis[free] = 1.0 if f.get("seen", true) else 0.0
			slot_twin[free] = slot_vis[free]
			f.slot = free
			slot_assigned.emit(free)
		_rank_slots()
		_assign_far()
	var k := minf(1.0, delta * 5.0)
	var k_on := minf(1.0, delta * 4.0)
	var fade_range := SELECT_RADIUS - FADE_START
	for i in POOL_SIZE:
		var l := pool[i]
		var f = slot_fixture[i]
		slot_on[i] += ((1.0 if (f != null and slot_want[i]) else 0.0) - slot_on[i]) * k_on
		var lb := pool_b[i]
		if f == null:
			l.light_energy = 0.0
			l.visible = false
			lb.visible = false
			ceil_glow[i].visible = false
			continue
		slot_weight[i] += (slot_target[i] - slot_weight[i]) * k
		var d := sqrt(f.dsq)
		var t := clampf((d - FADE_START) / fade_range, 0.0, 1.0)
		var dist_fade := 1.0 - t * t * (3.0 - 2.0 * t)
		# a dead tube, or one caught in the dark half of a flicker, keeps a faint ember but lights nothing
		var cast: float = 0.0 if (f.black > 0.0 or f.level < 0.1) else f.level
		var seen: bool = f.get("seen", true)
		slot_vis[i] += ((1.0 if (seen or l.shadow_enabled) else 0.0) - slot_vis[i]) * k
		slot_twin[i] += ((1.0 if seen else 0.0) - slot_twin[i]) * k
		var energy: float = (PANEL_ENERGY if panels_mm else LIGHT_ENERGY) * (CLASSIC_BOOST if f.classic else 1.0) * cast * slot_weight[i] * dist_fade * slot_on[i] * slot_vis[i]
		l.visible = energy > 0.002
		var g := ceil_glow[i]
		# the halo only reads as "coming from this fixture" while its real ceiling is close enough
		# to reach (a hanging fixture under a tall atrium ceiling is metres short of that: skip it
		# rather than paint a faint, disconnected glow patch on a ceiling far above the housing)
		var ceil_h: float = f.get("ceil_h", f.light_pos.y)
		var ceil_gap: float = ceil_h - f.light_pos.y
		var ceil_reach := clampf(1.0 - (ceil_gap - CEIL_GLOW_DROP) / (CEIL_GLOW_RANGE - CEIL_GLOW_DROP), 0.0, 1.0)
		g.visible = l.visible and ceil_reach > 0.0
		g.global_position = Vector3(f.light_pos.x, ceil_h - CEIL_GLOW_DROP, f.light_pos.z)
		g.light_energy = energy * (CEIL_GLOW_PANEL if panels_mm else CEIL_GLOW) * ceil_reach
		if panels_mm:                        # square panels: one point light, no tube ends
			lb.visible = false
			l.global_position = f.light_pos
			l.light_energy = energy
			continue
		# one light at each end of the tube, so the ceiling is lit along its whole length, not from a point.
		# The twin never casts shadows, so behind a wall it hands its share back to the main light, which
		# slides to the tube's centre.
		var twin := slot_twin[i] if f.dsq < TWIN_RANGE * TWIN_RANGE else 0.0   # far away the tube reads as a point
		lb.visible = l.visible and twin > 0.01
		var axis := Vector3(cos(f.rot), 0.0, -sin(f.rot)) * TUBE_HALF * twin
		l.global_position = f.light_pos + axis
		lb.global_position = f.light_pos - axis
		l.light_energy = energy * (1.0 - 0.5 * twin)
		lb.light_energy = energy * 0.5 * twin
	_update_far(k)

# Far lights keep their tube while it stays wanted (no jumping about), fade out when it isn't, and a
# freed light fades in on the next tube out, so moving through the level never pops.
func _assign_far() -> void:
	for i in FAR_MAX:
		var f = far_fixture[i]
		if f != null and not f.far_wanted and far_weight[i] < 0.02:
			f.far = -1
			far_fixture[i] = null
	for f in _far_candidates:
		if f.get("far", -1) != -1: continue
		var free := far_fixture.find(null)
		if free == -1: break
		far_fixture[free] = f
		far_weight[free] = 0.0
		far_vis[free] = 1.0 if f.get("seen", true) else 0.0
		f.far = free

func _update_far(k: float) -> void:
	var fade_range := FAR_RADIUS - FAR_FADE
	var base := PANEL_ENERGY if panels_mm else LIGHT_ENERGY
	for i in FAR_MAX:
		var fl := far_pool[i]
		var f = far_fixture[i]
		if f == null:
			fl.visible = false
			continue
		far_weight[i] += ((1.0 if f.far_wanted else 0.0) - far_weight[i]) * k
		far_vis[i] += ((1.0 if f.get("seen", true) else 0.0) - far_vis[i]) * k   # shadowless: off while behind a wall
		var t := clampf((sqrt(f.dsq) - FAR_FADE) / fade_range, 0.0, 1.0)
		var cast: float = 0.0 if (f.black > 0.0 or f.level < 0.1) else f.level
		var energy: float = base * (CLASSIC_BOOST if f.classic else 1.0) * cast * far_weight[i] * far_vis[i] * (1.0 - t * t * (3.0 - 2.0 * t))
		fl.visible = energy > 0.002
		fl.global_position = f.light_pos
		fl.light_energy = energy

# Failing-tube model: long stable stretches, then a burst of rapid dropouts and re-strikes.
# Steady tubes only stutter when something disturbs them (a burst already set).
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
		if not f.flickers and f.burst == 0: continue
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
	if env == null: return
	var c := cell_of(player.global_position)
	var za := 1.0
	var zf := 1.0
	var grid_down: bool = player.get("grid_down") == true
	grid_glow += ((1.0 if grid_down else 0.0) - grid_glow) * minf(1.0, delta * 0.5)
	classic_mix += ((1.0 if classic.has(c) else 0.0) - classic_mix) * minf(1.0, delta * 1.5)
	bright_mix += ((1.0 if bright.has(c) else 0.0) - bright_mix) * minf(1.0, delta * 1.5)
	# how much of the building's power is on (a power cut kills the tubes): drives the fill lights and the cleared air
	var power := 1.0
	if not lit.is_empty():
		var total := 0.0
		var n := 0
		for i in range(0, lit.size(), maxi(1, lit.size() / 24)):
			total += minf(1.0, lit[i].level) * (0.0 if lit[i].black > 0.0 else 1.0)
			n += 1
		power = total / maxf(n, 1)
	power = smoothstep(0.1, 0.7, power)
	for fl in fill_lights:
		fl.light_energy = LIGHT_ENERGY * 1.5 * (1.0 - grid_glow) * power
	open_mix = maxf(classic_mix, bright_mix * 0.85) * (1.0 - grid_glow) * power   # a power cut is dark, whatever the zone
	Game.fx_classic = classic_mix
	if reflect_mmi != null:                                              # noclip under the map would show them as huge white panels
		reflect_mmi.visible = player.global_position.y > 0.0
	for l in pool + pool_b + far_pool + ceil_glow:                                   # stark white tubes in the classic zone, so the light reads against the yellow walls
		l.light_color = LIGHT_COLOR.lerp(Color(1.0, 0.99, 0.96), classic_mix)
	cam_mix = maxf(classic_mix, bright_mix * 0.7)
	if dark.has(c):
		za = 0.12; zf = 1.35
	elif dim.has(c):
		za = 0.55; zf = 1.15
	var k := minf(1.0, delta * ADAPT)
	bounce += (tube_light_at(player.global_position) - bounce) * k
	zone_amb += (za - zone_amb) * k
	# eye adaptation: light where you stand and where you look (a lit hall ahead calms the exposure down,
	# a wall in shade in front of you opens it up); only where the zone is meant to be readable
	var cam := get_viewport().get_camera_3d()
	var ahead := player.global_position
	if cam: ahead = cam.global_position - cam.global_transform.basis.z * EYE_PROBE
	var seen := 0.5 * (tube_light_at(player.global_position) + tube_light_at(ahead))
	var gain := lerpf(1.0, lerpf(EYE_GAIN_DARK, EYE_GAIN_BRIGHT, seen), clampf(zone_amb, 0.0, 1.0) * (1.0 - grid_glow))
	eye += (gain - eye) * minf(1.0, delta * EYE_SPEED)
	if cam:
		var target := _glare_now(cam)
		glare += (target - glare) * minf(1.0, delta * (GLARE_IN if target > glare else GLARE_OUT))
	if Gfx.post_mat:
		Gfx.post_mat.set_shader_parameter("glare", glare)   # lens dirt / halation / streaks swell (post.gdshader)
	_blend_env(ATMOSPHERES.classic)
	zf = lerpf(zf, 0.2, open_mix)                                     # clear air: the far halls keep their light, only a touch of haze
	zone_fog += (zf - zone_fog) * k
	var b := AMBIENT_MIN + (1.0 - AMBIENT_MIN) * bounce
	# power cut: a faint glow so shapes barely read (ATMOSPHERE.gridDownAmbient / gridDownFog)
	var darkness := 1.0 - minf(1.0, maxf(b * zone_amb, 0.25 * grid_glow))
	env.fog_light_color = FOG_COLOR.lerp(FOG_COLOR_DARK, darkness)
	# in big lit halls the distance fades to a warm haze instead of black, so you can read the far walls and ceiling
	env.fog_light_color = env.fog_light_color.lerp(ATMOSPHERES.classic.haze, open_mix * (1.0 - darkness))
	env.background_color = env.fog_light_color
	var lit_scale := FOG_LIT_SCALE + (1.0 + FOG_DARK_BOOST - FOG_LIT_SCALE) * darkness
	# web uses exp2 fog at 0.075; Godot's exponential fog needs a lower density for the same feel
	env.fog_density = FOG_DENSITY * 0.8 * lit_scale * zone_fog * (1.0 + (0.55 - 1.0) * grid_glow)
	if env.volumetric_fog_enabled:
		env.volumetric_fog_density = 0.016 * lit_scale * zone_fog * (1.0 + (0.55 - 1.0) * grid_glow)
		env.volumetric_fog_albedo = Color(0.88, 0.82, 0.58, 1.0).lerp(Color(0.08, 0.06, 0.03, 1.0), darkness)

## Blend the WorldEnvironment from its own (dim) values toward an ATMOSPHERES look: the camera settings
## follow classic_mix (where you stand), the light itself open_mix (which a power cut takes away).
## How much lit fixture sits near the centre of the view right now (0..1), lights behind walls left out
func _glare_now(cam: Camera3D) -> float:
	var fwd := -cam.global_transform.basis.z
	var cp := cam.global_position
	var sum := 0.0
	for i in POOL_SIZE:
		var f = slot_fixture[i]
		if f == null or f.black > 0.0: continue
		var to: Vector3 = (f.pos as Vector3) - cp
		var d := to.length()
		if d < 0.2: continue
		var facing := fwd.dot(to / d)
		if facing < GLARE_CONE: continue
		var w := smoothstep(GLARE_CONE, GLARE_FULL, facing) * slot_level(i) / (1.0 + d * d / (GLARE_DIST * GLARE_DIST))
		if w > 0.01 and _line_clear(cp, f.pos): sum += w
	return clampf(sum, 0.0, 1.0)

## True when no wall cell lies between two points (half-cell steps across the grid)
func _line_clear(a: Vector3, b: Vector3) -> bool:
	var steps := maxi(1, ceili(Vector2(b.x - a.x, b.z - a.z).length() / (CELL * 0.5)))
	for k in range(1, steps):
		var p := a.lerp(b, float(k) / steps)
		if walls.has(cell_of(p)): return false
	return true

func _blend_env(a: Dictionary) -> void:
	if _env_base.is_empty():
		# kept on the resource: main.tscn's Environment can outlive a level reload with the last blend in it
		if not env.has_meta("atmo_base"):
			env.set_meta("atmo_base", {"ambient_energy": env.ambient_light_energy, "ambient_color": env.ambient_light_color,
				"exposure": env.tonemap_exposure, "tonemap_white": env.tonemap_white,
				"glow_threshold": env.glow_hdr_threshold, "glow_intensity": env.glow_intensity,
				"glow_bloom": env.glow_bloom, "glow_wide": env.get_glow_level(5), "ssao_intensity": env.ssao_intensity})
		_env_base = env.get_meta("atmo_base")
	var b := _env_base
	env.ambient_light_energy = lerpf(b.ambient_energy, a.ambient_energy, open_mix)
	env.ambient_light_color = (b.ambient_color as Color).lerp(a.ambient_color, open_mix)
	env.tonemap_exposure = lerpf(b.exposure, a.exposure, cam_mix) * eye * lerpf(1.0, GLARE_DIM, glare)
	env.tonemap_white = lerpf(b.tonemap_white, a.tonemap_white, cam_mix)
	env.glow_hdr_threshold = lerpf(b.glow_threshold, a.glow_threshold, cam_mix)
	env.glow_intensity = lerpf(b.glow_intensity, a.glow_intensity, cam_mix) * (1.0 + 0.35 * glare)   # the light you stare into blooms a bit more
	env.glow_bloom = lerpf(b.glow_bloom, a.glow_bloom, cam_mix)
	env.set_glow_level(5, lerpf(b.glow_wide, a.glow_wide, cam_mix))
	env.ssao_intensity = lerpf(b.ssao_intensity, a.ssao_intensity, cam_mix)

func update_lighting(delta: float) -> void:
	if player == null or pool.is_empty(): return
	_update_fixtures(delta)
	_update_pool(delta)
	_update_atmosphere(delta)
