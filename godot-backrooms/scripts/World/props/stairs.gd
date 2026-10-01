extends Node3D
## A stairwell between the floors of a level (level editor objects "stairs_up" / "stairs_down", built by
## level_geometry.gd _build_stairs): a boxed-in switchback stair, three cells long and two wide, with a
## doorway in its front. Inside, a landing at floor level; the right-hand lane climbs half a storey to a landing at the
## far end and the left-hand lane goes on up from there to the next floor's landing, straight above this one.
## Going down is the same stair the other way: the left-hand lane drops to a far landing, the right-hand one
## goes on down from it. A lane with no floor to lead to is walled off.
##
## The game holds one floor at a time, so the floor is swapped while you are on the far landing
## (level_builder.gd rebuild_floor_seamless): this well moves a storey up or down with you in it, the rest of
## the floor is replaced a piece a frame, and the new floor's end of the well takes this one's place. For that
## to be invisible, the part of the well you can see from there is built the same by the floor you leave and
## the floor you arrive on, each handing the other's end of the well to build():
##  - a storey is four repeats of the wallpaper, and every other material in the well is scaled to repeat a
##    whole number of times in it, so nothing slides when the well moves a storey up or down round you;
##  - each stretch belongs to one floor's stairs object (its look, handrail, light, sign): a floor's own
##    landing to that floor, the two flights and far landing above it to it as well;
##  - the doorway is only in front of the up lane and the wall between the lanes is thick, so from the
##    down-lane half of a far landing, where the swap happens, no floor's doorway can be seen at all;
##  - the well's lamps flicker by the clock, not by when they were built.

const CELL := 4.5
const STOREY := 9.0                    # floor to floor: four 2.25 m repeats of the wallpaper
const HALF := STOREY * 0.5             # what one flight climbs
const CELLS := 3                       # cells along the arrow (level_data.gd STAIR_CELLS) ...
const WIDE := 2                        # ... and across (STAIR_WIDE): the stairs object's own row and the one to its left
const WALL := 0.2                      # the well's own walls
const SPINE := 1.0                     # the wall between the two lanes
const LANDING := 3.0                   # how deep each landing is, along the arrow
const HEADROOM := 4.5                  # ceiling over every landing and, measured straight up, every step
const RISERS := 24
const DOOR_W := 2.2
const DOOR_H := 2.8
const SIDE := 1.0                      # the up lane is on +z: your right as you walk in

# local frame: x along the arrow from the middle of the first cell, z across from the middle of the well, y up
# from this floor
const X0 := -CELL * 0.5                # the front face (the doorway) ...
const X1 := CELL * (CELLS - 0.5)       # ... and the back
const IN0 := X0 + WALL
const IN1 := X1 - WALL
const XA := IN0 + LANDING              # where the flights leave the front landing
const XB := IN1 - LANDING              # and reach the far one
const OUT := CELL * WIDE * 0.5         # half the width outside ...
const HW := OUT - WALL                 # ... and inside
const LANE := HW - SPINE * 0.5
const LANE_MID := SPINE * 0.5 + LANE * 0.5
const TREAD := (XB - XA) / RISERS
const RISE := HALF / RISERS
const DOOR_Z0 := LANE_MID - DOOR_W * 0.5     # the doorway, in the middle of the up lane
const DOOR_Z1 := LANE_MID + DOOR_W * 0.5
# Where, across a far landing, the next floor takes over on the way up and hands back on the way down: both
# well into the down-lane half, clear of a sideways lean, so the up lane and the doorway at its foot are
# hidden behind the wall between the lanes on either side of the swap
const SWAP_UP := -2.2
const SWAP_DOWN := -1.2

const LAMP_COLOR := Color(1.0, 0.93, 0.78)
const LAMP_ENERGY := 1.7
const LAMP_RANGE := 9.0
const LAMP_LENGTH := 1.25
const LAMP_SHADOWS := 4                # how many of the nearest lamps cast a shadow
const LAMP_GLOW := 3.0                 # the tube's own brightness (HDR, so it blooms like the level's troffers)
const CEIL_LAYER := 1 << 18            # level_geometry.gd: the level's ceiling, lit by its own glow lights only
const SHELL_LAYERS := (1 << 10) | (1 << 11)   # level_geometry.gd: the floors above and below, lit by their own lights

var up := false                        # a floor above with its end of this well: the up lane is open
var down := false
var floor_no := 0

var _level: Node
var _from := Vector2.ZERO              # this well's own cell
var _body: StaticBody3D
var _st := {}                          # Material -> SurfaceTool, while building
var _looks := {}                       # look name -> its materials
var _mats := {}
var _lamps: Array = []                 # [light, tube material, flickers, which lamp of the well]
var _taken := false

## `ends`: floors up from this one (-1, 0, 1) -> that floor's stairs object where it has one on these cells.
## `room_h`: the ceiling round the well, which its box reaches. `mats`: the level's materials (wall, room_wall,
## floor, plaster, trim, wood, metal).
func build(level: Node, ends: Dictionary, f: int, room_h: float, mats: Dictionary) -> void:
	_level = level
	_mats = mats
	floor_no = f
	up = ends.has(1)
	down = ends.has(-1)
	var me: Dictionary = ends[0]
	_from = Vector2(me.pos_x, me.pos_y)
	_body = StaticBody3D.new()
	add_child(_body)
	var lo := -STOREY if down else 0.0
	var hi := maxf(room_h, (STOREY if up else 0.0) + HEADROOM)
	_shell(room_h, lo, hi)
	_front_landing(0, me, up, down, true)
	if up:
		_storey(0, me)
		_front_landing(1, ends[1], false, true, false)
	if down:
		_storey(-1, ends[-1])
		_front_landing(-1, ends[-1], true, false, false)
	_commit()

## Only the box the room sees, for a floor that is looked at and not walked on (level_shell.gd): its stair is
## the one the floor you are on builds, right through this floor. `mats`: room_wall, trim, metal.
func build_outside(room_h: float, mats: Dictionary) -> void:
	_mats = mats
	_body = StaticBody3D.new()
	add_child(_body)
	_shell(room_h, 0.0, room_h)
	_body.free()
	_commit()
	set_process(false)

func _commit() -> void:
	for mat: Material in _st:
		var mi := MeshInstance3D.new()
		mi.mesh = (_st[mat] as SurfaceTool).commit()
		mi.material_override = mat
		# seen from inside only, so its faces are one-sided: a tube out in the room would shine in through their backs
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		add_child(mi)
	_st.clear()

# ---------------------------------------------------------------- the pieces
## The box round the well, as the room sees it: wallpapered like the room up to its ceiling, a cased doorway
## in the front. And the well's solid walls, as tall as the stair inside runs.
func _shell(room_h: float, lo: float, hi: float) -> void:
	var skin := 0.1
	var m: Material = _mats.room_wall
	for s: float in [-1.0, 1.0]:
		var z := s * (OUT - skin * 0.5)
		_box(m, Vector3((X0 + X1) * 0.5, room_h * 0.5, z), Vector3(X1 - X0, room_h, skin))
		_solid(Vector3((X0 + X1) * 0.5, (lo + hi) * 0.5, s * (HW + WALL * 0.5)), Vector3(X1 - X0, hi - lo, WALL))
	_box(m, Vector3(X1 - skin * 0.5, room_h * 0.5, 0), Vector3(skin, room_h, OUT * 2.0))
	_solid(Vector3(X1 - WALL * 0.5, (lo + hi) * 0.5, 0), Vector3(WALL, hi - lo, OUT * 2.0))
	_solid(Vector3((XA + XB) * 0.5, (lo + hi) * 0.5, 0), Vector3(XB - XA, hi - lo, SPINE))
	# the front, round the doorway
	var dh := minf(DOOR_H, room_h - 0.15)
	var z0 := SIDE * DOOR_Z0
	var z1 := SIDE * DOOR_Z1
	var xs := X0 + skin * 0.5
	for part: Array in [[-OUT, minf(z0, z1), 0.0, room_h], [maxf(z0, z1), OUT, 0.0, room_h], [minf(z0, z1), maxf(z0, z1), dh, room_h]]:
		_box(m, Vector3(xs, (part[2] + part[3]) * 0.5, (part[0] + part[1]) * 0.5), Vector3(skin, part[3] - part[2], part[1] - part[0]))
	for part: Array in [[-OUT, minf(z0, z1), lo, hi], [maxf(z0, z1), OUT, lo, hi], [minf(z0, z1), maxf(z0, z1), dh, hi], [minf(z0, z1), maxf(z0, z1), lo, 0.0]]:
		if part[3] - part[2] > 0.01:
			_solid(Vector3(X0 + WALL * 0.5, (part[2] + part[3]) * 0.5, (part[0] + part[1]) * 0.5), Vector3(WALL, part[3] - part[2], part[1] - part[0]))
	# the doorway's frame: lining boards through the wall, casing on both faces, a strip across the floor
	var trim: Material = _mats.trim
	var zc := (z0 + z1) * 0.5
	var through := WALL + 0.02
	for z: float in [z0, z1]:
		_box(trim, Vector3(X0 + WALL * 0.5, dh * 0.5, z), Vector3(through, dh, 0.04))
	_box(trim, Vector3(X0 + WALL * 0.5, dh, zc), Vector3(through, 0.04, DOOR_W + 0.04))
	for x: float in [X0 - 0.012, IN0 + 0.012]:
		for z: float in [z0, z1]:
			_box(trim, Vector3(x, (dh + 0.09) * 0.5, z + signf(z - zc) * 0.045), Vector3(0.025, dh + 0.09, 0.09))
		_box(trim, Vector3(x, dh + 0.045, zc), Vector3(0.025, 0.09, DOOR_W + 0.18))
	_box(_mats.metal, Vector3(X0 + WALL * 0.5, 0.0, zc), Vector3(WALL + 0.06, 0.024, DOOR_W))

## The landing of floor `k` (floors up from this one): its floor, ceiling, walls, lamp and sign. A lane it
## has no flight in is walled off. `door`: this floor's own landing, with the doorway in its front wall.
func _front_landing(k: int, o: Dictionary, lane_up: bool, lane_down: bool, door: bool) -> void:
	var y := k * STOREY
	var look := _look(o)
	var top := y + HEADROOM
	# half a tread under the flights, to where their walking slope comes level with it (any further and its edge is a kerb across the slope)
	_solid(Vector3((X0 + XA + TREAD * 0.5) * 0.5, y - 0.15, 0), Vector3(XA + TREAD * 0.5 - X0, 0.3, HW * 2.0))
	_solid(Vector3((IN0 + XA) * 0.5, top + 0.1, 0), Vector3(LANDING, 0.2, HW * 2.0))
	_quad(look.floor, Vector3(IN0, y, -HW), Vector3(XA, y, -HW), Vector3(XA, y, HW), Vector3(IN0, y, HW), Vector3.UP)
	_quad(look.ceil, Vector3(IN0, top, -HW), Vector3(XA, top, -HW), Vector3(XA, top, HW), Vector3(IN0, top, HW), Vector3.DOWN)
	for s: float in [-1.0, 1.0]:
		_wall(look, Vector3(IN0, y, s * HW), Vector3(XA, y, s * HW), Vector3(0, 0, -s))
	_wall(look, Vector3(XA, y, -SPINE * 0.5), Vector3(XA, y, SPINE * 0.5), Vector3.LEFT)       # the end of the wall between the lanes
	for lane: Array in [[SIDE, lane_up], [-SIDE, lane_down]]:
		if lane[1]: continue
		var s: float = lane[0]
		_wall(look, Vector3(XA, y, s * SPINE * 0.5), Vector3(XA, y, s * HW), Vector3.LEFT)
		_solid(Vector3(XA + 0.1, y + HEADROOM * 0.5, s * LANE_MID), Vector3(0.2, HEADROOM, LANE))
	# the front wall, from inside
	if door:
		var dh := minf(DOOR_H, top - y - 0.1)
		var a := minf(SIDE * DOOR_Z0, SIDE * DOOR_Z1)
		var b := maxf(SIDE * DOOR_Z0, SIDE * DOOR_Z1)
		_wall(look, Vector3(IN0, y, -HW), Vector3(IN0, y, a), Vector3.RIGHT)
		_wall(look, Vector3(IN0, y, b), Vector3(IN0, y, HW), Vector3.RIGHT)
		_quad(look.wall, Vector3(IN0, y + dh, a), Vector3(IN0, y + dh, b), Vector3(IN0, top, b), Vector3(IN0, top, a), Vector3.RIGHT)
	else:
		_wall(look, Vector3(IN0, y, -HW), Vector3(IN0, y, HW), Vector3.RIGHT)
	for s: float in [-1.0, 1.0]:
		_lamp(o, Vector3((IN0 + XA) * 0.5, top, s * LANE_MID), (floor_no + k) * 4 + (0 if s < 0.0 else 1))
	if bool(o.get("sign", true)):
		_sign(floor_no + k, Vector3(IN0, y + 2.1, -SIDE * LANE_MID), look)

## The stair from floor `k`'s landing to the next one up: the up lane's flight, the far landing, and the
## down lane's flight back over the front. `o`: floor k's stairs object.
func _storey(k: int, o: Dictionary) -> void:
	var y := k * STOREY
	var look := _look(o)
	var mid := y + HALF
	var top := mid + HEADROOM
	_flight(look, o, SIDE, XA, XB, y)
	_flight(look, o, -SIDE, XB, XA, mid)
	_solid(Vector3((XB - TREAD * 0.5 + X1) * 0.5, mid - 0.15, 0), Vector3(X1 - XB + TREAD * 0.5, 0.3, HW * 2.0))
	_solid(Vector3((XB + IN1) * 0.5, top + 0.1, 0), Vector3(LANDING, 0.2, HW * 2.0))
	_quad(look.floor, Vector3(XB, mid, -HW), Vector3(IN1, mid, -HW), Vector3(IN1, mid, HW), Vector3(XB, mid, HW), Vector3.UP)
	_quad(look.ceil, Vector3(XB, top, -HW), Vector3(IN1, top, -HW), Vector3(IN1, top, HW), Vector3(XB, top, HW), Vector3.DOWN)
	for s: float in [-1.0, 1.0]:
		_wall(look, Vector3(XB, mid, s * HW), Vector3(IN1, mid, s * HW), Vector3(0, 0, -s))
	_wall(look, Vector3(IN1, mid, -HW), Vector3(IN1, mid, HW), Vector3.LEFT)
	_wall(look, Vector3(XB, mid, -SPINE * 0.5), Vector3(XB, mid, SPINE * 0.5), Vector3.RIGHT)
	for s: float in [-1.0, 1.0]:
		_lamp(o, Vector3((XB + IN1) * 0.5, top, s * LANE_MID), (floor_no + k) * 4 + (2 if s < 0.0 else 3))

## One flight in lane `s` (+1 / -1 across), climbing half a storey from (xs, y) to xe: steps, the sloping
## ceiling over them, the lane's two walls with a skirting board and a handrail up each, and the slope you
## actually walk on.
func _flight(look: Dictionary, o: Dictionary, s: float, xs: float, xe: float, y: float) -> void:
	var d := signf(xe - xs)
	var z_in := s * SPINE * 0.5
	var z_out := s * HW
	for i in RISERS:
		var x := xs + d * i * TREAD
		var t := y + (i + 1) * RISE
		_quad(look.floor, Vector3(x, t - RISE, z_in), Vector3(x, t - RISE, z_out), Vector3(x, t, z_out), Vector3(x, t, z_in), Vector3(-d, 0, 0))
		_quad(look.floor, Vector3(x, t, z_in), Vector3(x, t, z_out), Vector3(x + d * TREAD, t, z_out), Vector3(x + d * TREAD, t, z_in), Vector3.UP)
		# a nosing strip along the edge of each step: from above, all in one carpet, they are what tells the steps apart
		_box(look.nosing, Vector3(x + d * 0.012, t - 0.008, (z_in + z_out) * 0.5), Vector3(0.05, 0.03, LANE - 0.06))
	var run := Vector3(xe - xs, HALF, 0)
	var slope := run.normalized()
	var out := Vector3(-slope.y * d, slope.x * d, 0)            # square off the slope, upwards
	var head := Vector3(0, HEADROOM, 0)
	var a := Vector3(xs, y, 0)
	var b := Vector3(xe, y + HALF, 0)
	_quad(look.ceil, a + head + Vector3(0, 0, z_in), a + head + Vector3(0, 0, z_out), b + head + Vector3(0, 0, z_out), b + head + Vector3(0, 0, z_in), -out)
	var board := Vector3(0, RISE + 0.1, 0)                     # the skirting's top edge, clear of the step noses
	for wall: Array in [[z_out, -s], [z_in, s]]:
		var z: float = wall[0]
		var n := Vector3(0, 0, wall[1])
		_quad(look.wall, a + Vector3(0, 0, z), b + Vector3(0, 0, z), b + head + Vector3(0, 0, z), a + head + Vector3(0, 0, z), n)
		var zf := Vector3(0, 0, z) + n * 0.02
		_quad(look.trim, a + zf, b + zf, b + zf + board, a + zf + board, n)
		_quad(look.trim, a + board + Vector3(0, 0, z), b + board + Vector3(0, 0, z), b + board + zf, a + board + zf, out)
	if bool(o.get("rail", true)):
		var lift := Vector3(0, RISE + 0.92, 0)
		for wall: Array in [[z_out, -s], [z_in, s]]:
			var zw: float = wall[0]
			var zr: float = zw + wall[1] * 0.085
			_box(look.rail, (a + b) * 0.5 + lift + Vector3(0, 0, zr), Vector3(run.length() - 0.4, 0.05, 0.065), Basis(slope, out, slope.cross(out)))
			for i in 6:
				var at := a.lerp(b, (i + 0.5) / 6.0) + lift
				_box(look.bracket, at + Vector3(0, -0.05, zw + wall[1] * 0.045), Vector3(0.02, 0.02, 0.09))
				_box(look.bracket, at + Vector3(0, -0.035, zr), Vector3(0.02, 0.03, 0.02))
	# the walking surface: a slope from half a tread before the first riser, so both ends meet their landing flush
	var shift := Vector3(-d * TREAD * 0.5, 0, 0)
	var tilt := Basis(slope, out, slope.cross(out))
	var zc := Vector3(0, 0, s * LANE_MID)
	_solid((a + b) * 0.5 + shift + zc - out * 0.15, Vector3(run.length(), 0.3, LANE), tilt)
	_solid((a + b) * 0.5 + head + zc + out * 0.1, Vector3(run.length(), 0.2, LANE), tilt)

## A landing wall from `a` to `b` along the floor, HEADROOM tall, facing `n`, with its skirting board
func _wall(look: Dictionary, a: Vector3, b: Vector3, n: Vector3) -> void:
	var h := Vector3(0, HEADROOM, 0)
	_quad(look.wall, a, b, b + h, a + h, n)
	var mid := (a + b) * 0.5 + n * 0.01 + Vector3(0, 0.05, 0)
	var along := (b - a).abs()
	_box(look.trim, mid, Vector3(maxf(along.x, 0.02), 0.1, maxf(along.z, 0.02)))

## A tube lamp under a landing's ceiling at `at`, one over each lane, lit the way stairs object `o` says
## ("light": on, flicker, off). `id`: which lamp of the whole well it is, the same number on every floor.
func _lamp(o: Dictionary, at: Vector3, id: int) -> void:
	var mode := str(o.get("light", "on"))
	_box(_mats.trim, at - Vector3(0, 0.03, 0), Vector3(0.16, 0.06, LAMP_LENGTH + 0.1))
	var tube := StandardMaterial3D.new()
	tube.albedo_color = Color(0.13, 0.12, 0.1)
	tube.roughness = 0.4
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.035, LAMP_LENGTH)
	mi.mesh = bm
	mi.position = at - Vector3(0, 0.075, 0)
	mi.material_override = tube
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	if mode == "off": return
	tube.emission_enabled = true
	tube.emission = LAMP_COLOR
	tube.emission_energy_multiplier = LAMP_GLOW
	var l := OmniLight3D.new()
	l.light_color = LAMP_COLOR
	l.light_energy = LAMP_ENERGY
	l.omni_range = LAMP_RANGE
	l.omni_attenuation = 1.2
	l.omni_shadow_mode = OmniLight3D.SHADOW_CUBE
	l.shadow_enabled = false                     # the nearest few get one: _rank_lamps
	l.shadow_bias = 0.04
	l.shadow_normal_bias = 1.2
	l.shadow_blur = 1.6
	l.light_cull_mask &= ~(CEIL_LAYER | SHELL_LAYERS)   # the room's ceiling is lit by its own glow lights (and is beyond a wall)
	l.light_bake_mode = Light3D.BAKE_DISABLED    # not into the level's baked bounce light: that ends at the floor
	l.set_meta("gfx_managed", true)              # Gfx.apply_scene leaves it alone
	l.position = at - Vector3(0, 0.45, 0)
	add_child(l)
	_lamps.append([l, tube, mode == "flicker", id + roundi(_from.x) * 7 + roundi(_from.y) * 13])

## The floor's number on the wall you face as you come up to its landing
func _sign(n: int, at: Vector3, look: Dictionary) -> void:
	_box(look.plate, at + Vector3(0.012, 0, 0), Vector3(0.024, 0.75, 1.15))
	var lbl := Label3D.new()
	lbl.text = "G" if n == 0 else ("B%d" % -n if n < 0 else str(n))
	lbl.font = load("res://fonts/vcr.ttf")
	lbl.font_size = 128
	lbl.outline_size = 0
	lbl.pixel_size = 0.0046
	lbl.modulate = Color(0.93, 0.9, 0.8)
	lbl.shaded = true
	lbl.double_sided = false
	lbl.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	lbl.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	lbl.position = at + Vector3(0.027, 0, 0)
	lbl.rotation.y = PI * 0.5
	add_child(lbl)

# ---------------------------------------------------------------- looks
## The materials of a stretch of the well, by its stairs object's "style": "carpet" is the level's own
## wallpaper and carpet, "concrete" a bare service stair
func _look(o: Dictionary) -> Dictionary:
	var style := str(o.get("style", "carpet"))
	if _looks.has(style): return _looks[style]
	var look := {}
	if style == "concrete":
		look.wall = _concrete(Color(0.78, 0.77, 0.72), 0.42)
		look.floor = _concrete(Color(0.5, 0.5, 0.48), 0.6)
		look.ceil = look.wall
		look.trim = _paint(Color(0.2, 0.21, 0.2))
		look.rail = _paint(Color(0.62, 0.52, 0.12), 0.45)
		look.bracket = look.rail
		look.plate = _paint(Color(0.16, 0.3, 0.2))
		look.nosing = _paint(Color(0.66, 0.55, 0.12), 0.5)
	else:
		look.wall = _per_storey(_mats.wall)
		look.floor = _per_storey(_mats.floor)
		look.ceil = _per_storey(_mats.plaster)
		look.trim = _mats.trim
		look.rail = _mats.wood
		look.bracket = _mats.metal
		look.plate = _paint(Color(0.2, 0.17, 0.1))
		look.nosing = _paint(Color(0.2, 0.17, 0.12), 0.7)
	_looks[style] = look
	return look

## A world-space (triplanar) material slides over the well when the well moves a storey up or down. Scaled
## to the nearest whole number of repeats a storey, it lands exactly on itself.
func _per_storey(m: Material) -> Material:
	var bm := m as BaseMaterial3D
	if bm == null or not bm.uv1_triplanar or is_zero_approx(bm.uv1_scale.y): return m
	var per := absf(bm.uv1_scale.y) * STOREY
	var fit := maxf(1.0, roundf(per)) / per
	if is_equal_approx(fit, 1.0): return m
	var out := bm.duplicate() as BaseMaterial3D
	out.uv1_scale = bm.uv1_scale * fit
	return out

func _concrete(tint: Color, per_metre: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://textures/concrete_color.jpg")
	m.albedo_color = tint
	m.normal_enabled = true
	m.normal_texture = load("res://textures/concrete_normal.jpg")
	m.normal_scale = 0.6
	m.roughness = 0.92
	m.metallic_specular = 0.3
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * per_metre
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return _per_storey(m) as StandardMaterial3D

func _paint(col: Color, rough := 0.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic_specular = 0.4
	return m

# ---------------------------------------------------------------- mesh and collision
func _tool(mat: Material) -> SurfaceTool:
	if not _st.has(mat):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[mat] = st
	return _st[mat]

## A quad a-b-c-d facing `n` (Godot's front faces are clockwise)
func _quad(mat: Material, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	var st := _tool(mat)
	var order := [a, b, c, a, c, d]
	if (b - a).cross(c - a).dot(n) > 0.0:
		order = [a, c, b, a, d, c]
	for v: Vector3 in order:
		st.set_normal(n)
		st.add_vertex(v)

## A box `size` big about `at`, turned by `turn`
func _box(mat: Material, at: Vector3, size: Vector3, turn := Basis.IDENTITY) -> void:
	var h := size * 0.5
	for axis in 3:
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		for sgn: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = sgn
			var corners: Array[Vector3] = []
			for k: Array in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
				var p := Vector3.ZERO
				p[axis] = sgn * h[axis]
				p[u] = k[0] * h[u]
				p[v] = k[1] * h[v]
				corners.append(at + turn * p)
			_quad(mat, corners[0], corners[1], corners[2], corners[3], turn * n)

func _solid(at: Vector3, size: Vector3, turn := Basis.IDENTITY) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = Transform3D(turn, at)
	_body.add_child(cs)

# ---------------------------------------------------------------- running
## Is this world point inside the well?
func holds(p: Vector3) -> bool:
	var l := to_local(p)
	return l.x > X0 and l.x < X1 and absf(l.z) < OUT

## How well lit the well is at `p` by its own lamps, 0..1 (the level's tubes don't reach in here)
func light_at(p: Vector3) -> float:
	var best := 0.0
	for lamp: Array in _lamps:
		var l: OmniLight3D = lamp[0]
		var d := l.global_position.distance_to(p)
		best = maxf(best, l.light_energy / LAMP_ENERGY * clampf(1.0 - d / (LAMP_RANGE * 1.6), 0.0, 1.0))
	return best

var _rank_wait := 0.0

func _process(delta: float) -> void:
	var t := Time.get_ticks_msec() * 0.001
	for lamp: Array in _lamps:
		if not lamp[2]: continue
		var level := _flicker(t, lamp[3])
		(lamp[0] as OmniLight3D).light_energy = LAMP_ENERGY * level
		(lamp[1] as StandardMaterial3D).emission_energy_multiplier = LAMP_GLOW * level
	var player: Node3D = _level.player
	if player == null:
		return
	_rank_wait -= delta
	if _rank_wait <= 0.0:
		_rank_wait = 0.25
		_rank_lamps(player.global_position)
	if _taken or Game.dead or not (up or down):
		return
	var p := to_local(player.global_position)
	if p.x < IN0 or p.x > IN1 or absf(p.z) > HW:
		return
	# On a far landing, well into its down-lane half, or already past it: the floor this stretch leads to takes over
	var z := p.z * SIDE
	var far := p.x > XB - TREAD
	var step := 0
	if up and (p.y > HALF + 0.45 or (far and absf(p.y - HALF) < 0.45 and z < SWAP_UP)):
		step = 1
	elif down and (p.y < -HALF - 0.45 or (far and absf(p.y + HALF) < 0.45 and z > SWAP_DOWN)):
		step = -1
	if step != 0:
		_taken = true            # deferred: the swap frees this node, which must not happen under its own _process
		Game.change_floor.call_deferred(Game.level_floor + step, _from, "stairs", -step * STOREY)

## A lamp without a shadow shines through the well's walls, into the other lane and out into the room. The
## nearest few to the player cast one (where the graphics preset has shadows at all); lamps too far away to
## matter are switched off.
func _rank_lamps(p: Vector3) -> void:
	var order: Array = []
	for lamp: Array in _lamps:
		var l: OmniLight3D = lamp[0]
		var d := l.global_position.distance_to(p)
		l.visible = d < 45.0
		order.append([d, l])
	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var cap := LAMP_SHADOWS if int(Gfx.s.get("shadows", 1)) > 0 else 0
	for i in order.size():
		var l: OmniLight3D = order[i][1]
		var want: bool = i < cap and order[i][0] < 30.0
		if l.shadow_enabled != want: l.shadow_enabled = want

## A failing tube by the clock: steady for a few seconds, then a stutter of dropouts. `id` tells the lamps apart.
static func _flicker(t: float, id: int) -> float:
	var spell := floorf(t / 2.7) + id * 17.0
	if _hash(spell) > 0.4:
		return 1.0
	return 0.12 if _hash(floorf(t * 13.0) + id * 31.0) < 0.55 else 1.0

static func _hash(v: float) -> float:
	return fposmod(sin(v * 12.9898) * 43758.5453, 1.0)
