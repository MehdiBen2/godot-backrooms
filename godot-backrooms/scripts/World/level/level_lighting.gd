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
const LIT_DIFFUSER := Color(2.1, 1.95, 1.65)
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
var _rank_timer := 0.0
var _candidates: Array = []
var _lit_cap := POOL_SIZE
var _shadow_cap := 4

# ---- atmosphere
var env: Environment
var bounce := 1.0
var grid_glow := 0.0
var zone_amb := 1.0
var zone_fog := 1.0
var fill_lights: Array[OmniLight3D] = []   # the two steady fill lights of bright levels (off in a power cut)
var reflect_mmi: MultiMeshInstance3D   # the fake floor reflections of bright-zone tubes (they live below the floor)
var bright_mix := 0.0              # same idea for Bright zones (a softer version of the classic look)
var open_mix := 0.0                # how far the air is cleared and the far distance filled with light
var classic_mix := 0.0             # 0..1: how much of the classic look the player is standing in
var base_ambient := -1.0
var base_white := -1.0

func build_lighting() -> void:
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

## Real-time bounce light (SDFGI). VoxelGI and baked lightmaps can only be baked in the editor and these levels are built
## at load (and their tubes flicker and cut out, which a bake can't follow), so SDFGI is the GI that fits. It is heavy, so
## it is on by default only for levels with a Classic zone, and only when the preset turns Global illumination on (the
## menu's "Global illumination" row, i.e. Ultra); a level can force it with "sdfgi": true / false in its .lvl (the editor
## has a checkbox).
func _apply_gi() -> void:
	if env == null: return
	var want: bool = level_data.get("sdfgi", not classic.is_empty())
	env.sdfgi_enabled = want and bool(Gfx.s.get("ssil", false)) and not Gfx.compat
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
			if walls.has(c): continue
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
			if not (ns or ew or grid_node or is_bright or (is_classic and x % 2 == 0 and z % 2 == 0)): continue
			var chance := 1.0 if dark.has(c) else (0.75 if dim.has(c) else BURNT_CHANCE)
			var burnt := not (is_bright or is_classic) and rng.randf() < chance
			var flick := (not burnt) and not (is_bright or is_classic) and (flicker.has(c) or rng.randf() < FLICKER_CHANCE)
			fx.append({"pos": pos, "light_pos": pos - Vector3(0, 0.45, 0), "rot": PI / 2.0 if ns else 0.0,
				"burnt": burnt, "bright": is_bright, "classic": is_classic, "flickers": flick, "level": 1.0,
				"timer": rng.randf() * 4.0, "burst": 0, "black": 0.0, "slot": -1, "dsq": 0.0,
				"index": -1, "wanted": false})
	for f in fx:
		if not f.burnt:
			f.index = lit.size()
			lit.append(f)

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
	reflect_mmi = mmi
	for o in [-2.2, 2.2]:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.94, 0.80)
		l.omni_range = 24.0
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
		l.omni_range = LIGHT_RANGE
		l.omni_attenuation = 1.4
		l.light_energy = 0.0
		l.shadow_enabled = false
		l.shadow_bias = 0.04
		l.shadow_normal_bias = 1.2
		l.shadow_blur = 1.6
		l.visible = false
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
			f.slot = free
			slot_assigned.emit(free)
		_rank_slots()
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
			continue
		slot_weight[i] += (slot_target[i] - slot_weight[i]) * k
		var d := sqrt(f.dsq)
		var t := clampf((d - FADE_START) / fade_range, 0.0, 1.0)
		var dist_fade := 1.0 - t * t * (3.0 - 2.0 * t)
		var energy: float = LIGHT_ENERGY * (CLASSIC_BOOST if f.classic else 1.0) * f.level * slot_weight[i] * dist_fade * slot_on[i]
		l.visible = energy > 0.002
		lb.visible = l.visible and f.dsq < TWIN_RANGE * TWIN_RANGE       # far away the tube reads as a point: skip the twin
		# one light at each end of the tube, so the ceiling is lit along its whole length, not from a point
		var axis := Vector3(cos(f.rot), 0.0, -sin(f.rot)) * TUBE_HALF
		l.global_position = f.light_pos + axis
		lb.global_position = f.light_pos - axis
		l.light_energy = energy * 0.5
		lb.light_energy = energy * 0.5

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
	for l in pool + pool_b:                                              # stark white tubes in the classic zone, so the light reads against the yellow walls
		l.light_color = LIGHT_COLOR.lerp(Color(1.0, 0.99, 0.96), classic_mix)
	if base_white < 0.0: base_white = env.tonemap_white
	env.tonemap_white = lerpf(base_white, 4.0, classic_mix)              # gentler highlight roll-off: no clipped white
	if base_ambient < 0.0: base_ambient = env.ambient_light_energy
	env.ambient_light_energy = lerpf(base_ambient, 0.55, open_mix)     # flat, washed-out fill light
	if dark.has(c):
		za = 0.12; zf = 1.35
	elif dim.has(c):
		za = 0.55; zf = 1.15
	var k := minf(1.0, delta * ADAPT)
	bounce += (tube_light_at(player.global_position) - bounce) * k
	zone_amb += (za - zone_amb) * k
	zf = lerpf(zf, 0.15, open_mix)                                    # clear air: you see the whole hall
	zone_fog += (zf - zone_fog) * k
	var b := AMBIENT_MIN + (1.0 - AMBIENT_MIN) * bounce
	# power cut: a faint glow so shapes barely read (ATMOSPHERE.gridDownAmbient / gridDownFog)
	var darkness := 1.0 - minf(1.0, maxf(b * zone_amb, 0.25 * grid_glow))
	env.fog_light_color = FOG_COLOR.lerp(FOG_COLOR_DARK, darkness)
	# in big lit halls the distance fades to a warm haze instead of black, so you can read the far walls and ceiling
	env.fog_light_color = env.fog_light_color.lerp(Color(0.34, 0.29, 0.16), open_mix * (1.0 - darkness))
	env.background_color = env.fog_light_color
	var lit_scale := FOG_LIT_SCALE + (1.0 + FOG_DARK_BOOST - FOG_LIT_SCALE) * darkness
	# web uses exp2 fog at 0.075; Godot's exponential fog needs a lower density for the same feel
	env.fog_density = FOG_DENSITY * 0.8 * lit_scale * zone_fog * (1.0 + (0.55 - 1.0) * grid_glow)
	if env.volumetric_fog_enabled:
		env.volumetric_fog_density = 0.016 * lit_scale * zone_fog * (1.0 + (0.55 - 1.0) * grid_glow)
		env.volumetric_fog_albedo = Color(0.88, 0.82, 0.58, 1.0).lerp(Color(0.08, 0.06, 0.03, 1.0), darkness)

func update_lighting(delta: float) -> void:
	if player == null or pool.is_empty(): return
	_update_fixtures(delta)
	_update_pool(delta)
	_update_atmosphere(delta)
