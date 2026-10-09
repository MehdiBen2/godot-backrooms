extends RefCounted
## THE LEVEL, bounce light: a GI made for a world built on a grid (level_lighting.gd owns one per floor).
##
## A real (baked) GI is what makes a lit office look real: the ceiling and walls lit back by the floor and walls
## round them, brightest near the lamps, falling off between them and down a long hall, carried round corners,
## stopped by walls, and tinted by what it bounced off (yellow wallpaper and carpet give a warm, yellow ceiling).
## VoxelGI and SDFGI are too coarse or too heavy for levels this big (level_lighting.gd _apply_gi), and the even
## ambient fill that stood in for them lights every corner the same. This one is worked out on the level's own
## grid, a value a cell:
##   - every working lamp puts its light into its cell (the ceiling fixtures by their output as it is now, so
##     flicker, burnt-out tubes, power cuts and the events all show; the placed lamps of lamp_fixture.gd too);
##   - the light spreads from cell to cell, losing a share each step (DECAY), and a wall sends it back the way it
##     came (a corridor carries it further than an open hall, as it does in a real building);
##   - two values a cell: at the floor (r) and at the ceiling (g, which takes less straight from the lamps and
##     spreads further: the soft, even bounce a ceiling gets from the room under it).
## Solved fully once when the floor is built, then kept up to date a little every frame: the cells round the
## player every frame, the rest of the map a few rows at a time. The result is a small float texture, a texel a
## cell, that the floors, walls and ceilings read with filtering (shaders/grid_gi.gdshader, as a second pass
## over their own materials), so it lands on them as smooth gradients, not cell-sized steps.

const PassShader := preload("res://shaders/grid_gi.gdshader")

const DECAY_LO := 0.8              # share of its neighbours' light a floor-level cell keeps (higher: reaches further)
const DECAY_HI := 0.88             # the ceiling's bounce spreads further and evener
const HI_SOURCE := 0.55            # share of a lamp's light the ceiling channel takes straight in
const BUILD_SWEEPS := 24           # Gauss-Seidel sweeps over the whole map when the floor is built
const WINDOW := 13                 # cells round the player re-solved every frame
const BAND := 4                    # rows of the rest of the map re-solved each frame, sweeping across it
const UPLOAD_EVERY := 3            # frames between texture uploads
const LAMP_SHARE := 0.35           # a placed lamp's light, against a ceiling fixture's
const STRIP_SHARE := 0.08          # an emergency strip's (red, and dim): next to nothing

var lvl                            # the level (level_lighting.gd and the layers under it)
var n := 0
var open := PackedByteArray()      # 1: light goes through this cell
var src := PackedFloat32Array()
var lo := PackedFloat32Array()
var hi := PackedFloat32Array()
var pix := PackedFloat32Array()    # the texture's data: lo, hi per texel
var cell_fx := {}                  # cell index -> the lit ceiling fixtures in it
var cell_lamps := {}               # cell index -> the placed lamps in it
var img: Image
var tex: ImageTexture
var passes: Array[ShaderMaterial] = []
var _scale := 1.0
var _boost := 1.0
var _cell := 4.5
var _wall_h := 5.4
var _band := 1
var _frame := 0
var _last := {}                    # the uniforms as last written (written only when they change)

## `energy_scale`: a fixture's real light against a troffer's (a panel's is brighter); `boost`: a Classic zone
## fixture's extra; `cell`, `wall_h`: level_data.gd CELL, WALL_H
func build(level, energy_scale: float, boost: float, cell: float, wall_h: float) -> void:
	lvl = level
	_scale = energy_scale
	_boost = boost
	_cell = cell
	_wall_h = wall_h
	n = int(level.size)
	var cells := n * n
	open.resize(cells)
	src.resize(cells)
	lo.resize(cells)
	hi.resize(cells)
	pix.resize(cells * 2)
	for z in n:
		for x in n:
			var c := Vector2i(x, z)
			var shut: bool = (level.walls.has(c) and not level.carved.has(c)) or level.pits.has(c) or level.stair_cells.has(c)
			open[z * n + x] = 0 if (shut or x == 0 or z == 0 or x == n - 1 or z == n - 1) else 1
	for f: Dictionary in level.lit:
		var c: Vector2i = level.cell_of(f.pos)
		if c.x > 0 and c.y > 0 and c.x < n - 1 and c.y < n - 1:
			cell_fx.get_or_add(c.y * n + c.x, []).append(f)
	for l in LampFixture.all:
		if is_instance_valid(l) and level.is_ancestor_of(l):
			var c: Vector2i = level.cell_of(l.global_position)
			if c.x > 0 and c.y > 0 and c.x < n - 1 and c.y < n - 1:
				cell_lamps.get_or_add(c.y * n + c.x, []).append(l)
	_sources(1, 1, n - 2, n - 2)
	for s in BUILD_SWEEPS:
		_relax(1, 1, n - 2, n - 2, s % 2 == 1)
	img = Image.create_from_data(n, n, false, Image.FORMAT_RGF, pix.to_byte_array())
	tex = ImageTexture.create_from_image(img)

# ---------------------------------------------------------------- the solve
## The light the lamps in each cell of a rectangle put in now
func _sources(x0: int, z0: int, x1: int, z1: int) -> void:
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var i := z * n + x
			var s := 0.0
			var fs = cell_fx.get(i)
			if fs != null:
				for f: Dictionary in fs:
					s += lvl.lamp_out(f) * (_boost if f.classic else 1.0)
				s *= _scale
			var ls = cell_lamps.get(i)
			if ls != null:
				for l in ls:
					if is_instance_valid(l): s += l.output() * (STRIP_SHARE if l.kind == "emergency_strip" else LAMP_SHARE)
			src[i] = s

## One Gauss-Seidel sweep over a rectangle (in place, so it converges about twice as fast as Jacobi), walking it
## forwards or backwards (alternate sweeps: the light spreads evenly both ways). A wall neighbour hands the cell's
## own light back to it (reflected). Each open cell's value is also written into the wall cells beside it, so the
## filtered read along a wall's foot or face doesn't pull towards black (that is SSAO's job, and the base pass's).
func _relax(x0: int, z0: int, x1: int, z1: int, back := false) -> void:
	var zs := range(z1, z0 - 1, -1) if back else range(z0, z1 + 1)
	var xs := range(x1, x0 - 1, -1) if back else range(x0, x1 + 1)
	var q_lo := DECAY_LO * 0.25
	var q_hi := DECAY_HI * 0.25
	for z: int in zs:
		var row := z * n
		for x: int in xs:
			var i := row + x
			if open[i] == 0: continue
			var l0 := lo[i]
			var h0 := hi[i]
			var w := i - 1
			var e := i + 1
			var nn := i - n
			var ss := i + n
			var ow := open[w] == 1
			var oe := open[e] == 1
			var on := open[nn] == 1
			var os := open[ss] == 1
			var sl := (lo[w] if ow else l0) + (lo[e] if oe else l0) + (lo[nn] if on else l0) + (lo[ss] if os else l0)
			var sh := (hi[w] if ow else h0) + (hi[e] if oe else h0) + (hi[nn] if on else h0) + (hi[ss] if os else h0)
			var s := src[i]
			var vl := s + q_lo * sl
			var vh := s * HI_SOURCE + q_hi * sh
			lo[i] = vl
			hi[i] = vh
			pix[i * 2] = vl
			pix[i * 2 + 1] = vh
			if not ow:
				pix[w * 2] = vl; pix[w * 2 + 1] = vh
			if not oe:
				pix[e * 2] = vl; pix[e * 2 + 1] = vh
			if not on:
				pix[nn * 2] = vl; pix[nn * 2 + 1] = vh
			if not os:
				pix[ss * 2] = vl; pix[ss * 2 + 1] = vh

# ---------------------------------------------------------------- every frame
## `strength`: how much bounce the look wants; `color`: its tint times the lamps' white (and the events' tint);
## `fog`: the distance fog's density
func update(player_pos: Vector3, strength: float, color: Color, fog: float) -> void:
	if passes.is_empty() or tex == null: return
	var c: Vector2i = lvl.cell_of(player_pos)
	var x0 := clampi(c.x - WINDOW, 1, n - 2)
	var x1 := clampi(c.x + WINDOW, 1, n - 2)
	var z0 := clampi(c.y - WINDOW, 1, n - 2)
	var z1 := clampi(c.y + WINDOW, 1, n - 2)
	var back := _frame % 2 == 1
	_sources(x0, z0, x1, z1)
	_relax(x0, z0, x1, z1, back)
	# the rest of the map, a band of rows at a time (a power cut far off still dims its bounce in a few seconds)
	var b0 := _band
	var b1 := mini(_band + BAND - 1, n - 2)
	_sources(1, b0, n - 2, b1)
	_relax(1, b0, n - 2, b1, back)
	_band = b1 + 1 if b1 + 1 < n - 1 else 1
	_frame += 1
	if _frame % UPLOAD_EVERY == 0:
		img.set_data(n, n, false, Image.FORMAT_RGF, pix.to_byte_array())
		tex.update(img)
	_set_all("strength", strength, 0.002)
	_set_all("gi_color", color, 0.004)
	_set_all("fog_density", fog, 0.0005)

func _set_all(param: String, v, eps: float) -> void:
	var was = _last.get(param)
	if was != null:
		if v is Color and (v as Color).is_equal_approx(was): return
		if v is Vector3 and (v as Vector3).is_equal_approx(was): return
		if v is float and absf(v - was) < eps: return
	_last[param] = v
	for m in passes: m.set_shader_parameter(param, v)

# ---------------------------------------------------------------- the passes
## Put the bounce pass on every floor and wall the level built: the meshes it adds straight under itself whose
## material is an opaque, lit one. `skip`: materials to leave alone (the pit shafts' concrete and black).
## `ceil_layer`: the ceilings' render layer. Ceilings are left alone: their light panels are drawn in the ceiling's
## own material, and multiplying the ceiling dimmed the panels themselves (dull, no bloom).
func attach(root: Node, skip: Array, ceil_layer: int) -> void:
	var made := {}                         # base material -> its pass
	for ch in root.get_children():
		if not (ch is GeometryInstance3D): continue
		if (ch as VisualInstance3D).layers & ceil_layer: continue
		var m: Material = (ch as GeometryInstance3D).material_override
		if m == null or skip.has(m) or not _eligible(m): continue
		if made.has(m): continue
		var p := _pass_for(m)
		made[m] = p
		m.next_pass = p

func _eligible(m: Material) -> bool:
	if m.next_pass != null and not m.next_pass.has_meta("grid_gi"): return false
	if m is StandardMaterial3D:
		var s := m as StandardMaterial3D
		return s.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and s.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL \
			and s.blend_mode == BaseMaterial3D.BLEND_MODE_MIX and (not s.emission_enabled or s.emission_energy_multiplier < 1.0)
	if m is ShaderMaterial:
		var sh := (m as ShaderMaterial).shader
		if sh == null: return false
		var code := sh.code
		return not ("unshaded" in code or "blend_" in code or "ALPHA" in code or "shader_type spatial" not in code)
	return false

func _pass_for(m: Material) -> ShaderMaterial:
	var p := ShaderMaterial.new()
	p.shader = PassShader
	p.set_meta("grid_gi", true)
	p.set_shader_parameter("gi_map", tex)
	p.set_shader_parameter("map_cells", float(n))
	p.set_shader_parameter("map_cell", _cell)
	p.set_shader_parameter("hi_height", _wall_h)
	p.set_shader_parameter("strength", 0.0)
	passes.append(p)
	return p
