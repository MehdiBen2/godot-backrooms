extends Node3D
## Pits with no bottom (level_data.gd `abyss`: pits painted with the Abyss zone, and any pit with no floor under
## it to drop into). Built by level_geometry.gd for the floor you are on.
##
## From the rim you look down a shaft that goes on for ever: storey after storey of the level's own wall,
## the bare slab between floors, a buzzing tube under every slab, all of it fading into a sickly haze. Step in
## and you fall, faster and faster, the haze thickening as you go, until after a while (`abyss_secs` in the
## .lvl, 0: never) everything goes black and you come to beside the spawn point.
##
## How it stays cheap however fast you fall and wherever you look:
##   - nothing is built as you fall. The shaft is one storey of mesh (a handful of quads per wall), drawn by a
##     fixed pool of POOL nodes, each one storey, that are moved, never made or freed. Storey k is always
##     node posmod(k, POOL); only those within reach of the camera are shown.
##   - the player does not fall for ever either: past WRAP_BOTTOM they are moved WRAP_H up, with their speed,
##     their view and everything that follows them left as it was. WRAP_H is a whole number of storeys and
##     of tube patterns (pit_shaft.gdshader `rows`), so the shaft round them is exactly the same, and POOL
##     divides it, so every node moves with them and TAA sees no motion at all.
##   - no real lights. The tubes glow and their light on the walls is worked out in pit_shaft.gdshader from
##     where a pixel is in its storey: the cost of a lightmap, without the texture. The torch keeps its light
##     and loses its shadow (there is nothing in a shaft to cast one).
##   - the fog thickens with depth and the camera's far plane follows it (FAR_K): nothing the fog has
##     swallowed is drawn. Once the far plane no longer reaches the floor you fell from, the whole level is
##     hidden and its lighting stops running (Game.freefall), and while you fall the screen effects that cost
##     most and add nothing here (volumetric fog, SSAO, SSIL, SSR) are off.

const ShaftShader := preload("res://shaders/pit_shaft.gdshader")
const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

const ROW_PERIOD := 12             # storeys before the pattern of dead and failing tubes comes round again
const WRAP_SEGS := 24              # the loop, in storeys: a multiple of ROW_PERIOD
const POOL := WRAP_SEGS            # storeys drawn at most (it divides WRAP_SEGS: see above)
const WRAP_TOP_SEGS := 12          # the loop's top, in storeys under the floor: well past the far plane (FAR_MAX)
const ENTER_Y := -0.8              # feet this far under the floor over the pit: you are falling
const TUBE_Y := 5.05               # pit_shaft.gdshader tube_y
const TUBE_HALF := 0.6
const TUBE_OUT := 0.11             # how far the tubes stand off the wall
const TUBE_THICK := 0.045

const FOG_FROM := 4.0              # m fallen before the haze starts to close in
const FOG_RAMP := 70.0             # m over which it does
const FOG_DEEP := 0.085            # its density then: 95 % of the light gone in 35 m
const FAR_K := 5.52                # ln(250): at this many fog lengths a wall is under 1/250 of its own light
const FAR_MIN := 24.0
const FAR_MAX := 90.0              # the most the camera reaches while falling (and the pool's reach)
const PREVIEW_REACH := 75.0        # how far down the shaft is drawn from the rim (the level's own fog ends near 70 m)
const SPEED_MAX := 55.0            # m/s: terminal speed in the abyss (player.gd FALL_SPEED_MAX elsewhere)
const FALL_SECS := 60.0            # the default `abyss_secs`
const FADE_OUT := 1.8
const FADE_IN := 1.4
const HIDE_MARGIN := 6.0

## The haze, by the level's look: a sickly yellow over the dim halls, washed-out grey-green in the liminal look,
## a dirtier yellow in the bright classic one
const SICK := {"dim": Color(0.16, 0.145, 0.085), "liminal": Color(0.23, 0.235, 0.19), "classic": Color(0.3, 0.27, 0.15)}

var level: Node3D
var seg_h := 9.0
var cell := 4.5
var wrap_h := 0.0
var wrap_top := 0.0
var wrap_bottom := 0.0
var shafts: Array = []             # each {cells, root: Node3D, pool: Array, body: StaticBody3D, box: Rect2}
var _shaft_of := {}                # Vector2i -> its shaft's place in `shafts`
var _mat: ShaderMaterial
var _rows := PackedFloat32Array()  # pit_shaft.gdshader `rows`: 0 dead, 1 steady, 2 failing
var _secs := FALL_SECS

var active := -1                   # the shaft being fallen down
var depth := 0.0                   # m fallen since the rim, loops and all
var _wraps := 0
var _t := 0.0
var _reach := PREVIEW_REACH
var _fade := 0.0                   # 0..1 the black at the end of the fall
var _waking := 0.0                 # 1..0 the black lifting after it
var _ending := false
var _level_hidden := false
var _hidden: Array = []
var _saved := {}
var _fog_from := 0.0
var _fog_col_from := Color.BLACK
var _sick := Color.BLACK
var _wind: AudioStreamPlayer
var _hum: AudioStreamPlayer
var _gust := FastNoiseLite.new()

static var _wind_stream: AudioStreamWAV

func setup(lvl: Node3D) -> void:
	level = lvl
	seg_h = lvl.STOREY_H
	cell = lvl.CELL
	wrap_h = WRAP_SEGS * seg_h
	wrap_top = -WRAP_TOP_SEGS * seg_h
	wrap_bottom = wrap_top - wrap_h
	_secs = float(lvl.level_data.get("abyss_secs", FALL_SECS))
	var r := RandomNumberGenerator.new()
	r.seed = hash(str(lvl.level_meta.get("id", "")) + ":" + str(lvl.floor_no))
	_rows.resize(16)
	for k in 16:
		var v := r.randf()
		_rows[k] = 0.0 if v < 0.15 else (2.0 if v < 0.3 else 1.0)
	_rows[0] = 1.0                      # (the first row under the rim is lit: it is what you see of it from above)
	_mat = _material()
	var seen := {}
	for start: Vector2i in lvl.abyss:
		if seen.has(start): continue
		var cells := {start: true}
		var todo: Array[Vector2i] = [start]
		seen[start] = true
		while not todo.is_empty():
			var c: Vector2i = todo.pop_back()
			for d: Vector2i in DIRS:
				if lvl.abyss.has(c + d) and not seen.has(c + d):
					seen[c + d] = true
					cells[c + d] = true
					todo.append(c + d)
		for c: Vector2i in cells: _shaft_of[c] = shafts.size()
		shafts.append(_build_shaft(cells))
	if _wind_stream == null: _wind_stream = _make_wind()
	_gust.frequency = 0.35

func _exit_tree() -> void:
	if active >= 0: _end(false)
	if Gfx.post_mat: Gfx.post_mat.set_shader_parameter("fall_fade", 0.0)

# ---------------------------------------------------------------- building
func _build_shaft(cells: Dictionary) -> Dictionary:
	var runs := _runs(cells)
	var mesh := _segment_mesh(runs)
	var root := Node3D.new()
	add_child(root)
	var pool: Array = []
	for i in POOL:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mi.visible = false
		root.add_child(mi)
		pool.append(mi)
	# the sides, for the whole drop and the loop: you can drift about inside the shaft, never out of it
	var body := StaticBody3D.new()
	var lo := wrap_bottom - 4.0 * seg_h
	for r: Dictionary in runs:
		var a: Vector3 = r.from
		var b: Vector3 = r.to
		var n: Vector3 = r.n
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var along := (b - a).normalized()
		box.size = Vector3(a.distance_to(b) + 1.0, -lo, 0.5) if absf(along.x) > 0.5 else Vector3(0.5, -lo, a.distance_to(b) + 1.0)
		cs.shape = box
		cs.position = (a + b) * 0.5 - n * 0.25 + Vector3(0.0, lo * 0.5, 0.0)
		body.add_child(cs)
	add_child(body)
	var box2 := Rect2()
	var first := true
	for c: Vector2i in cells:
		var rc := Rect2(Vector2(c) * cell - Vector2.ONE * cell * 0.5, Vector2.ONE * cell)
		box2 = rc if first else box2.merge(rc)
		first = false
	return {"cells": cells, "root": root, "pool": pool, "body": body, "box": box2, "lo": 1, "hi": 0}

## The walls round a set of cells, as straight runs: {from, to (at y 0), n (facing into the shaft), cells}
func _runs(cells: Dictionary) -> Array:
	var lines := {}
	for c: Vector2i in cells:
		for d: Vector2i in DIRS:
			if cells.has(c + d): continue
			var key := Vector3i(0, d.x, c.x) if d.x != 0 else Vector3i(1, d.y, c.y)
			if not lines.has(key): lines[key] = []
			lines[key].append(c.y if d.x != 0 else c.x)
	var out: Array = []
	for key: Vector3i in lines:
		var list: Array = lines[key]
		list.sort()
		var start: int = list[0]
		var prev: int = start
		for i in range(1, list.size() + 1):
			if i < list.size() and list[i] == prev + 1:
				prev = list[i]
				continue
			var plane := (key.z + key.y * 0.5) * cell
			var a0 := (start - 0.5) * cell
			var b0 := (prev + 0.5) * cell
			if key.x == 0:
				out.append({"from": Vector3(plane, 0, a0), "to": Vector3(plane, 0, b0), "n": Vector3(-key.y, 0, 0), "cells": prev - start + 1})
			else:
				out.append({"from": Vector3(a0, 0, plane), "to": Vector3(b0, 0, plane), "n": Vector3(0, 0, -key.y), "cells": prev - start + 1})
			if i < list.size():
				start = list[i]
				prev = start
	return out

## One storey of shaft, y 0 to seg_h: a quad a run of wall (the shader paints wall and slab on it), and a
## tube on every cell's width of it. UV: metres along the run, and its length (for the corner shading).
func _segment_mesh(runs: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var up := Vector3(0.0, seg_h, 0.0)
	for r: Dictionary in runs:
		var a: Vector3 = r.from
		var b: Vector3 = r.to
		var n: Vector3 = r.n
		var ln := a.distance_to(b)
		_quad(st, [a, b, b + up, a + up], n, Color.WHITE, [Vector2(0, ln), Vector2(ln, ln), Vector2(ln, ln), Vector2(0, ln)])
		var dir := (b - a) / ln
		for i in int(r.cells):
			var mid := a + dir * (cell * (i + 0.5)) + Vector3(0.0, TUBE_Y, 0.0)
			var s := dir * TUBE_HALF
			var lo := Vector3(0.0, -TUBE_THICK, 0.0)
			var hi := Vector3(0.0, TUBE_THICK, 0.0)
			var back := n * 0.02
			var front := n * TUBE_OUT
			var glass := Color(1, 1, 1, 0)
			var housing := Color(0, 0, 0, 0)
			var none := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
			_quad(st, [mid - s + front + lo, mid + s + front + lo, mid + s + front + hi, mid - s + front + hi], n, glass, none)
			_quad(st, [mid - s + back + lo, mid + s + back + lo, mid + s + front + lo, mid - s + front + lo], Vector3.DOWN, glass, none)
			_quad(st, [mid - s + back + hi, mid + s + back + hi, mid + s + front + hi, mid - s + front + hi], Vector3.UP, housing, none)
			_quad(st, [mid - s + back + lo, mid - s + front + lo, mid - s + front + hi, mid - s + back + hi], -dir, housing, none)
			_quad(st, [mid + s + back + lo, mid + s + front + lo, mid + s + front + hi, mid + s + back + hi], dir, housing, none)
	return st.commit()

## A quad facing `n`, wound clockwise seen from that side (Godot's front face)
func _quad(st: SurfaceTool, v: Array, n: Vector3, col: Color, uv: Array) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	var v0: Vector3 = v[0]
	var v1: Vector3 = v[1]
	var v2: Vector3 = v[2]
	if (v1 - v0).cross(v2 - v0).dot(n) > 0.0: order = [0, 2, 1, 0, 3, 2]
	for k: int in order:
		st.set_normal(n)
		st.set_color(col)
		st.set_uv(uv[k])
		st.add_vertex(v[k])

## The level's wall, as the walls round the pit wear it (a wall painted with another material there wins)
func _wall_source() -> StandardMaterial3D:
	var count := {}
	var paint: Dictionary = level.painted("wall")
	for c: Vector2i in level.abyss:
		for d: Vector2i in DIRS:
			if paint.has(c + d): count[paint[c + d]] = int(count.get(paint[c + d], 0)) + 1
	var best := ""
	for id: String in count:
		if best == "" or count[id] > count[best]: best = id
	if best != "": return level._painted_mat(best)
	return level.wall_mat

func _material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ShaftShader
	var src := _wall_source()
	if src != null and src.albedo_texture != null:
		var sc := src.uv1_scale
		var flip := sc.y < 0.0            # the generated wallpaper: one texture a wall height, top at the top
		m.set_shader_parameter("wall_tex", src.albedo_texture)
		m.set_shader_parameter("wall_tint", src.albedo_color)
		m.set_shader_parameter("wall_scale", Vector2(absf(sc.x), 1.0 if flip else maxf(1.0, roundf(level.WALL_H * absf(sc.y)))))
		m.set_shader_parameter("wall_flip", 1.0 if flip else 0.0)
	m.set_shader_parameter("slab_tex", load("res://textures/concrete_color.jpg"))
	m.set_shader_parameter("seg_h", seg_h)
	m.set_shader_parameter("band_h", level.WALL_H)
	m.set_shader_parameter("tube_y", TUBE_Y)
	m.set_shader_parameter("tube_half", TUBE_HALF)
	m.set_shader_parameter("cell", cell)
	m.set_shader_parameter("shaft_w", cell)         # (a pit is a cell wide or more: the far wall is at least that far)
	var look: String = level.atmosphere()
	var tube: Color = level.LIGHT_COLOR
	if look == "liminal": tube = level.ATMOSPHERES.liminal.light
	elif look == "classic": tube = Color(1.0, 0.99, 0.96)
	m.set_shader_parameter("tube_color", tube)
	m.set_shader_parameter("rows", _rows)
	m.set_shader_parameter("period", ROW_PERIOD)
	_sick = SICK.get(look, SICK.dim)
	return m

## A dull, endless roar of air, made once: low-passed noise, its end faded into its start so it loops
static func _make_wind() -> AudioStreamWAV:
	var rate := 22050
	var n := rate * 2
	var fade := rate / 2
	var r := RandomNumberGenerator.new()
	r.seed = 1971
	var s := PackedFloat32Array()
	s.resize(n + fade)
	var a := 0.0
	var b := 0.0
	var peak := 0.0
	for i in n + fade:
		a += (r.randf() * 2.0 - 1.0 - a) * 0.09
		b += (a - b) * 0.2
		s[i] = b
	for i in fade:
		var t := float(i) / fade
		s[i] = s[i] * t + s[n + i] * (1.0 - t)
	for i in n: peak = maxf(peak, absf(s[i]))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n: data.encode_s16(i * 2, int(clampf(s[i] / maxf(peak, 0.0001), -1.0, 1.0) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w

# ---------------------------------------------------------------- running
## Storey k of shaft `s` on node posmod(k, POOL), for every storey within `reach` of `y` and under the rim
func _snap(s: Dictionary, y: float, reach: float) -> void:
	var lo := floori((y - reach) / seg_h)
	var hi := mini(floori((y + reach) / seg_h), -1)
	lo = maxi(lo, hi - POOL + 1)
	if lo == s.lo and hi == s.hi: return
	s.lo = lo
	s.hi = hi
	var pool: Array = s.pool
	for mi: MeshInstance3D in pool: mi.visible = false
	for k in range(lo, hi + 1):
		var mi: MeshInstance3D = pool[posmod(k, POOL)]
		mi.position = Vector3(0.0, k * seg_h, 0.0)
		mi.visible = true

func _process(dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or level == null: return
	_t += dt
	if _waking > 0.0:
		_waking = maxf(0.0, _waking - dt / FADE_IN)
		if Gfx.post_mat: Gfx.post_mat.set_shader_parameter("fall_fade", _waking)
	var at := cam.global_position
	if active < 0:
		# from up on the floor: each shaft as far down as can be seen, and only when you are near enough to see it
		for s: Dictionary in shafts:
			var box: Rect2 = s.box
			var near := box.grow(PREVIEW_REACH).has_point(Vector2(at.x, at.z))
			(s.root as Node3D).visible = near
			if near: _snap(s, at.y, PREVIEW_REACH)
		return
	var p: CharacterBody3D = level.player
	var env: Environment = level.env
	# the haze closes in with depth, and the far plane with it
	var k := smoothstep(FOG_FROM, FOG_FROM + FOG_RAMP, depth)
	var dens := lerpf(_fog_from, FOG_DEEP, k)
	var col := _fog_col_from.lerp(_sick, k)
	if env != null:
		env.fog_density = dens
		env.fog_light_color = col
		env.background_color = col
		_enforce(env)
	if level._horizon_mat != null: level._horizon_mat.set_shader_parameter("fog_color", col)
	_reach = clampf(FAR_K / maxf(dens, 0.001), FAR_MIN, FAR_MAX)
	cam.far = minf(_reach, float(_saved.far))
	_snap(shafts[active], at.y, _reach)
	_hide_level(at.y + _reach < -HIDE_MARGIN)
	# the air tearing past, in gusts; a tube's buzz swelling and dropping away as you pass it
	var fall := smoothstep(4.0, SPEED_MAX, -p.velocity.y)
	if _wind:
		_wind.volume_db = linear_to_db(maxf(fall * (0.75 + 0.25 * _gust.get_noise_1d(_t * 10.0)) * (1.0 - _fade), 0.0001))
		_wind.pitch_scale = 0.7 + 0.6 * fall
	if _hum:
		var row := roundi((at.y - TUBE_Y) / seg_h)          # the nearest row of tubes
		var h := at.y - (row * seg_h + TUBE_Y)
		var d := absf(h)
		var kind := _rows[posmod(row, ROW_PERIOD)]
		var lv := 0.0 if kind < 0.5 else (1.0 if kind < 1.5 else (1.0 if randf() > 0.3 else 0.1))
		_hum.volume_db = linear_to_db(maxf(lv * exp(-d * d / 4.5) * 0.9 * (1.0 - _fade), 0.0001))
		_hum.pitch_scale = clampf(1.0 + signf(h) * fall * 0.06, 0.8, 1.2)     # coming up to it, then leaving it behind

func _physics_process(dt: float) -> void:
	if level == null: return
	var p := level.player as CharacterBody3D
	if p == null or not is_instance_valid(p): return
	if active < 0:
		if _waking > 0.0 or p.global_position.y > ENTER_Y: return
		if Game.noclip or Game.draw_mode or Game.dead or Death.respawn_busy: return
		var i: int = _shaft_of.get(level.cell_of(p.global_position), -1)
		if i >= 0: _begin(i)
		return
	if Game.noclip or Game.draw_mode or Game.dead:
		_end(false)
		return
	depth = -p.global_position.y + _wraps * wrap_h
	if p.global_position.y < wrap_bottom:
		_shift(p, wrap_h)
		_wraps += 1
	if _secs > 0.0 and not _ending and depth > 2.0 * seg_h:
		var fall_t: float = _saved.get("t", 0.0) + dt
		_saved.t = fall_t
		if fall_t > _secs: _ending = true
	if _ending:
		_fade = minf(1.0, _fade + dt / FADE_OUT)
		if Gfx.post_mat: Gfx.post_mat.set_shader_parameter("fall_fade", _fade)
		if _fade >= 1.0: _end(true)

## The loop: everything that follows the player goes up with them, and the storeys round them too, so the
## next frame is the same picture a storey-pattern higher
func _shift(p: CharacterBody3D, dy: float) -> void:
	p.global_position.y += dy
	p.beam_pos.y += dy                      # the torch's eased position, or the beam would swing up 200 m after you
	p.flash_target.y += dy
	p.flash.global_position = p.beam_pos
	_snap(shafts[active], p.cam.global_position.y, _reach)

func _begin(i: int) -> void:
	active = i
	depth = 0.0
	_wraps = 0
	_fade = 0.0
	_ending = false
	Game.freefall = true
	var p: CharacterBody3D = level.player
	var env: Environment = level.env
	_saved = {"far": p.cam.far, "speed": p.fall_speed_max, "shadow": p.flash.shadow_enabled, "t": 0.0}
	if env != null:
		_saved.env = _env_state(env)
		_fog_from = env.fog_density
		_fog_col_from = env.fog_light_color
	p.fall_speed_max = SPEED_MAX
	p.flash.shadow_enabled = false
	for j in shafts.size(): (shafts[j].root as Node3D).visible = j == i
	if not Gfx.changed.is_connected(_on_gfx): Gfx.changed.connect(_on_gfx)
	var bus := "Ambience" if AudioServer.get_bus_index("Ambience") >= 0 else "Master"
	_wind = AudioStreamPlayer.new()
	_wind.stream = _wind_stream
	_wind.bus = bus
	_wind.volume_db = -80.0
	add_child(_wind)
	_wind.play()
	_hum = AudioStreamPlayer.new()
	_hum.stream = load("res://audio/hum_diffuse.wav")
	_hum.bus = bus
	_hum.volume_db = -80.0
	add_child(_hum)
	_hum.play()

## `wake`: the fall is over, the player comes to at the spawn point (behind the black, which then lifts)
func _end(wake: bool) -> void:
	var p: CharacterBody3D = level.player
	var env: Environment = level.env
	if env != null and _saved.has("env"):
		var e: Dictionary = _saved.env
		env.volumetric_fog_enabled = e.vfog
		env.ssao_enabled = e.ssao
		env.ssil_enabled = e.ssil
		env.ssr_enabled = e.ssr
		env.fog_density = e.fog
		env.fog_light_color = e.fog_color
		env.background_color = e.bg
	if p != null and is_instance_valid(p):
		p.cam.far = _saved.get("far", p.cam.far)
		p.fall_speed_max = _saved.get("speed", p.FALL_SPEED_MAX)
		p.flash.shadow_enabled = _saved.get("shadow", true)
		if wake:
			p._back_to_spawn()
			p.beam_pos = p.cam.global_position
			p.flash_target = p.beam_pos - p.cam.global_transform.basis.z * 16.0
	_hide_level(false)
	if Gfx.changed.is_connected(_on_gfx): Gfx.changed.disconnect(_on_gfx)
	for a: AudioStreamPlayer in [_wind, _hum]:
		if a != null and is_instance_valid(a): a.queue_free()
	_wind = null
	_hum = null
	active = -1
	_ending = false
	_fade = 0.0
	Game.freefall = false
	for s: Dictionary in shafts: s.lo = 1          # re-placed for the view from the floor
	if wake:
		_waking = 1.0
	elif Gfx.post_mat:
		Gfx.post_mat.set_shader_parameter("fall_fade", 0.0)

func _env_state(env: Environment) -> Dictionary:
	return {"vfog": env.volumetric_fog_enabled, "ssao": env.ssao_enabled, "ssil": env.ssil_enabled, "ssr": env.ssr_enabled,
		"fog": env.fog_density, "fog_color": env.fog_light_color, "bg": env.background_color}

## Nothing in a lit concrete shaft needs these, and each costs a pass over the whole screen (the volumetric fog
## a 3D grid besides, which smears at this speed). Set only when they are on, so a frame costs no calls.
func _enforce(env: Environment) -> void:
	if env.volumetric_fog_enabled: env.volumetric_fog_enabled = false
	if env.ssao_enabled: env.ssao_enabled = false
	if env.ssil_enabled: env.ssil_enabled = false
	if env.ssr_enabled: env.ssr_enabled = false

## The graphics settings changed mid-fall: what they put back on is what the end of the fall restores
func _on_gfx() -> void:
	var env: Environment = level.env
	if env == null or not _saved.has("env"): return
	var now := _env_state(env)
	for key in ["vfog", "ssao", "ssil", "ssr"]: _saved.env[key] = now[key]
	_enforce(env)

## Everything of the level but the pit: its floor, its tubes and lights, the floors seen through other holes
func _hide_level(hide: bool) -> void:
	if hide == _level_hidden: return
	_level_hidden = hide
	if hide:
		_hidden.clear()
		for c in level.get_children():
			if c == self or not (c is Node3D) or not (c as Node3D).visible: continue
			(c as Node3D).visible = false
			_hidden.append(c)
	else:
		for c in _hidden:
			if is_instance_valid(c): (c as Node3D).visible = true
		_hidden.clear()
