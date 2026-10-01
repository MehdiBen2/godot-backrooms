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
var tint := Color.WHITE   # events recolour every lit tube (null in the web game = white)

var fill_lights: Array[OmniLight3D] = []   # the two steady fill lights of bright levels (off in a power cut)
var reflect_mmi: MultiMeshInstance3D   # the fake floor reflections of bright-zone tubes (they live below the floor)
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
		var d2 := Vector2(f.pos.x - pos.x, f.pos.z - pos.z).length_squared()
		if d2 > r2 or rng.randf() > strength:
			continue
		f.burst = 2 * (2 + rng.randi() % 3)
		f.timer = 0.02 + rng.randf() * 0.08

## Flicker tubes near `pos` actively for `duration` seconds
func flicker_fixtures(pos: Vector3, radius: float, duration: float) -> void:
	var r2 := radius * radius
	var affected: Array = []
	for f in lit:
		if f.black > 0.0: continue
		var d2 := Vector2(f.pos.x - pos.x, f.pos.z - pos.z).length_squared()
		if d2 <= r2:
			affected.append(f)

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
		var is_event_flickering: bool = float(f.get("flicker_until", 0.0)) > Game.time
		if not f.flickers and not is_event_flickering and f.burst == 0: continue
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
