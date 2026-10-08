extends Node3D
## Raised floors and the stairs up to them that are not stairwells: the level editor's "platform", "stair_flight"
## and "stair_spiral" (object_types.json shapes "platform", "flight", "spiral"), built by level_geometry.gd
## _build_vertical. They stand on this floor and climb within it: no floor is swapped and nothing loads, you
## simply walk up onto a mezzanine, a balcony, a walkway over the water.
##   platform  a slab with its top `elev` m up, `depth` cells along the arrow by `scale` across, on posts if asked,
##             railed or parapeted round its open edges (open wherever a stair arrives, or a wall stands against it)
##   flight    solid steps climbing `rise` m along the arrow over `depth` cells, from `elev` m up
##   spiral    steps wound `sweep` degrees round a tiled column, `scale` cells across, climbing `rise` m
## Everything is in the piece's own frame (object_transform: +x the arrow, z across, y up from the floor), drawn
## as one mesh per material, and stood on by plain solids: a slab's box, a flight's wedge (its top is the slope
## through the step noses, so you walk up it and don't climb each riser, as props/stairs.gd does), a spiral's
## helical ramp through its noses. The solids say what they are made of (footsteps.gd reads "surface" off them).

const CELL := 4.5
const RISER := 0.18               # m: the step height a flight aims for (it is fitted to its rise)
const SPIRAL_RISER := 0.2
const STEP_SLAB := 0.24           # m: how deep a spiral step's block is under its tread
const RAIL_H := 0.95              # m: a handrail's height over the step noses or the floor
const RAIL_R := 0.022             # m: a chrome tube's radius
const POST_EVERY := 1.5           # m: the most between two posts of a rail
const PARAPET_H := 1.05
const PARAPET_T := 0.2
const POST_W := 0.32              # m: a raised floor's square legs
const MAX_WALK := 40.0            # degrees: steeper than this a flight / spiral can't be walked up (CharacterBody3D floor angle 45)
const SURFACE := {"tile": "tile", "floor": "carpet", "concrete": "concrete"}

var _st := {}                     # Material -> SurfaceTool, while building
var _body: StaticBody3D           # null for a look-only copy (level_shell.gd): nothing to stand on
var _surface := "tile"
var solids_only := false          # only the solids (the floor above's copy of stairs coming up through it)

## Build piece `o` of shape `shape`. `mats`: level_geometry.gd _piece_mats. `tops`: every stair's top_exit() on this
## floor (a raised floor leaves its rail open where one arrives at its height). `solid`: is a world point inside a
## wall block (no rail along a wall). `ceiling`: the room's ceiling height where it stands. `shell`: drawn only.
func build(o: Dictionary, shape: String, mats: Dictionary, tops: Array, solid: Callable, ceiling: float, shell: bool) -> void:
	name = "%s_%d" % [shape.capitalize(), get_index()]
	var surf := str(o.get("surface", "tile"))
	_surface = SURFACE.get(surf, "tile")
	if not shell: _body = StaticBody3D.new()
	var top: Material = mats.get(surf, mats.tile)
	match shape:
		"platform": _platform(o, top, mats, tops, solid)
		"flight": _flight(o, top, mats)
		"spiral": _spiral(o, top, mats, ceiling)
	_commit()

## Where stair `o` (shape "flight" or "spiral", placed by `xf` in the level) lets you off at its top: [the point
## in the level at the middle of its last step's far edge, half its width (m), the height it reaches (m), the way
## you walk off it (flat)]
static func top_exit(o: Dictionary, shape: String, xf: Transform3D) -> Array:
	var top := float(o.get("elev", 0.0)) + float(o.get("rise", 2.7))
	if shape == "spiral":
		var r_out := float(o.scale) * CELL * 0.5
		var r_in := float(o.get("core", 0.7)) * 0.5
		var end := deg_to_rad(float(o.get("sweep", 360.0)))
		var turn := _turn(o)
		var mid := (r_out + r_in) * 0.5
		var at := _polar(end, mid, turn)
		var ahead := _polar(end + 0.01, mid, turn) - at
		return [xf * Vector3(at.x, top, at.z), (r_out - r_in) * 0.5, top, (xf.basis * ahead).normalized()]
	var run := float(o.get("depth", 1.0)) * CELL
	return [xf * Vector3(run * 0.5, top, 0.0), float(o.scale) * CELL * 0.5, top, (xf.basis * Vector3.RIGHT).normalized()]


# ---------------------------------------------------------------- raised floor
func _platform(o: Dictionary, top_mat: Material, mats: Dictionary, tops: Array, solid: Callable) -> void:
	var hx := float(o.get("depth", 2.0)) * CELL * 0.5
	var hz := float(o.scale) * CELL * 0.5
	var y1 := float(o.get("elev", 2.7))
	var y0 := maxf(0.0, y1 - clampf(float(o.get("slab", 0.35)), 0.05, y1))
	var c := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]
	var up := Vector3(0, y1, 0)
	var dn := Vector3(0, y0, 0)
	_quad(top_mat, c[0] + up, c[1] + up, c[2] + up, c[3] + up, Vector3.UP)
	if y0 > 0.01: _quad(mats.under, c[0] + dn, c[1] + dn, c[2] + dn, c[3] + dn, Vector3.DOWN)
	for i in 4:
		var a: Vector3 = c[i]
		var b: Vector3 = c[(i + 1) % 4]
		_quad(mats.tile, a + dn, b + dn, b + up, a + up, _edge_out(a, b))
	_solid(Vector3(0, (y0 + y1) * 0.5, 0), Vector3(hx * 2.0, y1 - y0, hz * 2.0))
	# legs: at the corners, and every two cells or so along a long side
	if bool(o.get("posts", true)) and y0 > 0.4:
		var inset := POST_W * 0.5 + 0.15
		var nx := maxi(1, ceili(hx * 2.0 / (CELL * 2.0)))
		var nz := maxi(1, ceili(hz * 2.0 / (CELL * 2.0)))
		for ix in nx + 1:
			for iz in nz + 1:
				if ix != 0 and ix != nx and iz != 0 and iz != nz: continue      # round the rim only
				var p := Vector3(lerpf(-hx + inset, hx - inset, float(ix) / nx), y0 * 0.5, lerpf(-hz + inset, hz - inset, float(iz) / nz))
				if solid.call(transform * Vector3(p.x, 0.0, p.z)): continue
				_box(mats.tile, p, Vector3(POST_W, y0, POST_W))
				_solid(p, Vector3(POST_W, y0, POST_W))
	# what runs round the open edges
	var edge := str(o.get("edge", "chrome"))
	if edge == "none": return
	var gaps: Array = []                  # [local point on the rim, half width]: where a stair arrives
	for t: Array in tops:
		if absf(float(t[2]) - y1) > 0.2: continue
		var lp := transform.affine_inverse() * (t[0] as Vector3)
		if absf(lp.x) > hx + 0.8 or absf(lp.z) > hz + 0.8: continue
		gaps.append([Vector3(lp.x, 0.0, lp.z), float(t[1]) + 0.12])
	for i in 4:
		var a: Vector3 = c[i]
		var b: Vector3 = c[(i + 1) % 4]
		var out := _edge_out(a, b)
		var inset := out * (PARAPET_T * 0.5 if edge == "parapet" else 0.06)
		# the rim in short pieces; a piece is left off at a stair's head or where the edge runs along a wall
		var pieces := maxi(1, ceili(a.distance_to(b) / 0.25))
		var run_from := -1
		for k in pieces + 1:
			var on := false
			if k < pieces:
				var m := a.lerp(b, (k + 0.5) / pieces)
				on = not solid.call(transform * (m + out * 0.35))
				for g: Array in gaps:
					var gp: Vector3 = g[0]
					if m.distance_to(gp) < float(g[1]) or (m + out * 0.5).distance_to(gp) < float(g[1]): on = false
			if on and run_from < 0: run_from = k
			elif not on and run_from >= 0:
				var p0 := a.lerp(b, float(run_from) / pieces) - inset
				var p1 := a.lerp(b, float(k) / pieces) - inset
				if edge == "parapet": _parapet(mats.tile, p0 + up, p1 + up)
				else: _rail(mats.chrome, p0 + up, p1 + up, true)
				run_from = -1

## Which way the edge a -> b of a raised floor (corners on its rim, centred on the origin) faces out
static func _edge_out(a: Vector3, b: Vector3) -> Vector3:
	if absf(a.x - b.x) < 0.001: return Vector3(signf(a.x), 0.0, 0.0)
	return Vector3(0.0, 0.0, signf(a.z))

## The basis of a long solid running along `dir`, upright across it
static func _along(dir: Vector3) -> Basis:
	var up := Vector3.UP.slide(dir).normalized()
	return Basis(dir, up, dir.cross(up))

## A run of chrome rail from `a` to `b` (on the walking surface): posts at both ends and no further apart than
## POST_EVERY, a top rail RAIL_H up (and with `mid`, a second one halfway), and a solid so you can't walk off past it
func _rail(m: Material, a: Vector3, b: Vector3, mid: bool) -> void:
	var len := a.distance_to(b)
	if len < 0.05: return
	var posts := maxi(1, ceili(len / POST_EVERY))
	var lift := Vector3(0, RAIL_H, 0)
	for i in posts + 1:
		var p := a.lerp(b, float(i) / posts)
		_tube(m, p, p + lift, RAIL_R * 1.1)
	_tube(m, a + lift, b + lift, RAIL_R)
	if mid: _tube(m, a + lift * 0.5, b + lift * 0.5, RAIL_R * 0.8)
	_solid((a + b) * 0.5 + lift * 0.5, Vector3(len, RAIL_H, 0.08), _along((b - a) / len))

func _parapet(m: Material, a: Vector3, b: Vector3) -> void:
	var len := a.distance_to(b)
	if len < 0.05: return
	var turn := _along((b - a) / len)
	var at := (a + b) * 0.5 + Vector3(0, PARAPET_H * 0.5, 0)
	_box(m, at, Vector3(len + PARAPET_T, PARAPET_H, PARAPET_T), turn)
	_solid(at, Vector3(len + PARAPET_T, PARAPET_H, PARAPET_T), turn)

# ---------------------------------------------------------------- straight flight
func _flight(o: Dictionary, top_mat: Material, mats: Dictionary) -> void:
	var run := maxf(float(o.get("depth", 1.0)) * CELL, 0.3)
	var hw := float(o.scale) * CELL * 0.5
	var base := float(o.get("elev", 0.0))
	var rise := maxf(float(o.get("rise", 2.7)), 0.05)
	var n := maxi(1, roundi(rise / RISER))
	var tread := run / n
	var rh := rise / n
	var x0 := -run * 0.5
	var x1 := run * 0.5
	var side: Material = mats.tile
	for i in n:
		var xa := x0 + i * tread
		var xb := xa + tread
		var ya := base + i * rh
		var yb := ya + rh
		_quad(top_mat, Vector3(xa, yb, -hw), Vector3(xb, yb, -hw), Vector3(xb, yb, hw), Vector3(xa, yb, hw), Vector3.UP)
		_quad(side, Vector3(xa, ya, -hw), Vector3(xa, yb, -hw), Vector3(xa, yb, hw), Vector3(xa, ya, hw), Vector3.LEFT)
		for z: float in [-hw, hw]:
			_quad(side, Vector3(xa, base, z), Vector3(xb, base, z), Vector3(xb, yb, z), Vector3(xa, yb, z), Vector3(0, 0, signf(z)))
	_quad(side, Vector3(x1, base, -hw), Vector3(x1, base + rise, -hw), Vector3(x1, base + rise, hw), Vector3(x1, base, hw), Vector3.RIGHT)
	# up through the ceiling: a landing on to the edge of the hole it comes up in (level_geometry.gd _set_landing)
	var land := float(o.get("_landing", 0.0))
	if land > 0.01:
		var lt := base + rise
		var lx := x1 + land
		_quad(top_mat, Vector3(x1, lt, -hw), Vector3(lx, lt, -hw), Vector3(lx, lt, hw), Vector3(x1, lt, hw), Vector3.UP)
		_quad(mats.under, Vector3(x1, lt - 0.3, -hw), Vector3(lx, lt - 0.3, -hw), Vector3(lx, lt - 0.3, hw), Vector3(x1, lt - 0.3, hw), Vector3.DOWN)
		for z: float in [-hw, hw]:
			_quad(side, Vector3(x1, lt - 0.3, z), Vector3(lx, lt - 0.3, z), Vector3(lx, lt, z), Vector3(x1, lt, z), Vector3(0, 0, signf(z)))
		_solid(Vector3((x1 + lx) * 0.5, lt - 0.15, 0.0), Vector3(lx - x1 + 0.02, 0.3, hw * 2.0))
	if base > 0.01:
		_quad(mats.under, Vector3(x0, base, -hw), Vector3(x1, base, -hw), Vector3(x1, base, hw), Vector3(x0, base, hw), Vector3.DOWN)
	# the walking surface: a wedge whose slope runs through the step noses, from half a tread before the first
	# riser (so it meets the floor flush) to the last nose, then flat to the top step's far edge
	var top := base + rise
	var prof := [Vector2(x0 - tread * 0.5, base), Vector2(x1 - tread * 0.5, top), Vector2(x1, top), Vector2(x1, base)]
	var pts := PackedVector3Array()
	for q: Vector2 in prof:
		pts.append(Vector3(q.x, q.y, -hw))
		pts.append(Vector3(q.x, q.y, hw))
	_hull(pts)
	# chrome rails up either side, posts on the steps
	var which := str(o.get("railing", "both"))
	if which == "none": return
	var sides: Array[float] = []
	if which in ["both", "left"]: sides.append(-1.0)        # (left climbing: -z, the map's left of the arrow)
	if which in ["both", "right"]: sides.append(1.0)
	var lift := Vector3(0, RAIL_H, 0)
	for s: float in sides:
		var z := s * (hw - 0.1)
		var a := Vector3(x0 + tread * 0.5, base + rh, z)
		var b := Vector3(x1 - tread * 0.5, top, z)
		var posts := maxi(1, ceili(a.distance_to(b) / POST_EVERY))
		for i in posts + 1:
			var p := a.lerp(b, float(i) / posts)
			var step := clampi(floori((p.x - x0) / tread), 0, n - 1)
			var foot := Vector3(p.x, base + (step + 1) * rh, z)
			_tube(mats.chrome, foot, Vector3(p.x, p.y, z) + lift, RAIL_R * 1.1)
		_tube(mats.chrome, a + lift, b + lift, RAIL_R)
		_fence(a, b, RAIL_H)

# ---------------------------------------------------------------- spiral
## The local point at angle `a` (radians along the climb from the arrow) and radius `r`. "left" climbs
## anticlockwise seen from above: on the map (+x east, +z south) that is from +x round towards -z.
static func _polar(a: float, r: float, turn: float) -> Vector3:
	return Vector3(cos(a) * r, 0.0, -sin(a) * r * turn)

static func _turn(o: Dictionary) -> float:
	return -1.0 if str(o.get("turn", "left")) == "right" else 1.0

func _spiral(o: Dictionary, top_mat: Material, mats: Dictionary, ceiling: float) -> void:
	var r_out := maxf(float(o.scale) * CELL * 0.5, 0.6)
	var r_in := clampf(float(o.get("core", 0.7)) * 0.5, 0.1, r_out - 0.4)
	var base := float(o.get("elev", 0.0))
	var rise := maxf(float(o.get("rise", 5.4)), 0.2)
	var sweep := deg_to_rad(clampf(float(o.get("sweep", 360.0)), 30.0, 1440.0))
	var turn := _turn(o)
	var n := maxi(3, roundi(rise / SPIRAL_RISER))
	var da := sweep / n
	var rh := rise / n
	var arcs := maxi(2, ceili(da / deg_to_rad(6.0)))     # each tread's curve, in this many straight pieces
	for i in n:
		var a0 := i * da
		var a1 := a0 + da
		var y1 := base + (i + 1) * rh
		var y0 := maxf(base, y1 - STEP_SLAB)
		for k in arcs:
			var b0 := lerpf(a0, a1, float(k) / arcs)
			var b1 := lerpf(a0, a1, float(k + 1) / arcs)
			var i0 := _polar(b0, r_in, turn)
			var i1 := _polar(b1, r_in, turn)
			var o0 := _polar(b0, r_out, turn)
			var o1 := _polar(b1, r_out, turn)
			var yt := Vector3(0, y1, 0)
			var yb := Vector3(0, y0, 0)
			_quad(top_mat, i0 + yt, o0 + yt, o1 + yt, i1 + yt, Vector3.UP)
			if y0 > base + 0.001 or base > 0.01: _quad(mats.under, i0 + yb, o0 + yb, o1 + yb, i1 + yb, Vector3.DOWN)
			var mid := _polar((b0 + b1) * 0.5, 1.0, turn)
			_quad(mats.tile, o0 + yb, o1 + yb, o1 + yt, o0 + yt, mid)       # the step's outer end
		# its riser at the front, and the back of its block (seen from below)
		var f_in := _polar(a0, r_in, turn)
		var f_out := _polar(a0, r_out, turn)
		var front := -(_polar(a0 + 0.01, 1.0, turn) - _polar(a0, 1.0, turn)).normalized()
		_quad(mats.tile, f_in + Vector3(0, y0, 0), f_out + Vector3(0, y0, 0), f_out + Vector3(0, y1, 0), f_in + Vector3(0, y1, 0), front)
		var b_in := _polar(a1, r_in, turn)
		var b_out := _polar(a1, r_out, turn)
		_quad(mats.tile, b_in + Vector3(0, y0, 0), b_out + Vector3(0, y0, 0), b_out + Vector3(0, y1, 0), b_in + Vector3(0, y1, 0), -front.rotated(Vector3.UP, da * turn))
	# the column, floor to ceiling (or a storey past the top step, under an open ceiling)
	var col_h := maxf(base + rise + 2.4, ceiling if ceiling > base + rise else base + rise + 2.4)
	# up through the ceiling: a landing off the top step to the edge of the hole (level_geometry.gd _set_landing)
	var land := float(o.get("_landing", 0.0))
	if land > 0.01:
		var top := base + rise
		var ahead := (_polar(sweep + 0.01, 1.0, turn) - _polar(sweep, 1.0, turn)).normalized()
		var e_in := _polar(sweep, r_in, turn)
		var e_out := _polar(sweep, r_out, turn)
		var lift := Vector3(0, top, 0)
		var q := [e_in + lift, e_out + lift, e_out + ahead * land + lift, e_in + ahead * land + lift]
		_quad(top_mat, q[0], q[1], q[2], q[3], Vector3.UP)
		var dn := Vector3(0, -0.3, 0)
		_quad(mats.under, q[0] + dn, q[1] + dn, q[2] + dn, q[3] + dn, Vector3.DOWN)
		var across := (e_out - e_in).normalized()
		_solid((e_in + e_out) * 0.5 + ahead * land * 0.5 + Vector3(0, top - 0.15, 0), Vector3(r_out - r_in, 0.3, land + 0.02), Basis(across, Vector3.UP, across.cross(Vector3.UP)))
	var col: Material = mats.get("column")
	if solids_only: pass
	elif col != null: _cylinder_uv(col, r_in, col_h, float(mats.get("repeat", 2.2)))
	else: _cylinder(mats.tile, r_in, col_h)
	if _body != null:
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = r_in
		cyl.height = col_h
		cs.shape = cyl
		cs.position = Vector3(0, col_h * 0.5, 0)
		cs.set_meta("surface", _surface)
		_body.add_child(cs)
	# the walking surface: a helical ramp through the middle of every tread at its height (a slab a little thick,
	# so it can't be fallen through), from half a step before the first riser (flush with the floor) up to the
	# middle of the last tread, then flat over the rest of it: the straight flight's wedge, wound round
	var faces := PackedVector3Array()
	var samples := maxi(12, n * 3)
	var ramp := func(a: float) -> float: return clampf(base + rh * (a / da + 0.5), base, base + rise)
	var prev := -0.5 * da
	for s in range(1, samples + 1):
		var a := lerpf(-0.5 * da, sweep, float(s) / samples)
		var ya: float = ramp.call(prev)
		var yb: float = ramp.call(a)
		var pi0 := _polar(prev, r_in, turn) + Vector3(0, ya, 0)
		var po0 := _polar(prev, r_out, turn) + Vector3(0, ya, 0)
		var pi1 := _polar(a, r_in, turn) + Vector3(0, yb, 0)
		var po1 := _polar(a, r_out, turn) + Vector3(0, yb, 0)
		var dn := Vector3(0, -0.3, 0)
		faces.append_array([pi0, po0, po1, pi0, po1, pi1])
		faces.append_array([pi0 + dn, po1 + dn, po0 + dn, pi0 + dn, pi1 + dn, po1 + dn])
		faces.append_array([po0, po0 + dn, po1 + dn, po0, po1 + dn, po1])
		if bool(o.get("rail", true)):
			# a fence up the open side, so a misstep doesn't drop you off the edge
			var lift := Vector3(0, RAIL_H, 0)
			var ro0 := _polar(prev, r_out - 0.06, turn) + Vector3(0, ya, 0)
			var ro1 := _polar(a, r_out - 0.06, turn) + Vector3(0, yb, 0)
			faces.append_array([ro0, ro1, ro1 + lift, ro0, ro1 + lift, ro0 + lift])
		prev = a
	if _body != null:
		var cs := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		shape.backface_collision = true
		cs.shape = shape
		cs.set_meta("surface", _surface)
		_body.add_child(cs)
	# the handrail: a chrome helix round the open side, a post on every other step
	if not bool(o.get("rail", true)): return
	var rr := r_out - 0.08
	var lift := Vector3(0, RAIL_H, 0)
	for i in range(0, n, 2):
		var a := (i + 0.5) * da
		var foot := _polar(a, rr, turn) + Vector3(0, base + (i + 1) * rh, 0)
		var head := _polar(a, rr, turn) + Vector3(0, ramp.call(a), 0) + lift
		_tube(mats.chrome, foot, head, RAIL_R * 1.1)
	var steps := maxi(8, ceili(sweep / deg_to_rad(8.0)))
	var last := _polar(0.5 * da, rr, turn) + Vector3(0, ramp.call(0.5 * da), 0) + lift
	for s in range(1, steps + 1):
		var a := lerpf(0.5 * da, sweep - 0.5 * da, float(s) / steps)
		var p := _polar(a, rr, turn) + Vector3(0, ramp.call(a), 0) + lift
		_tube(mats.chrome, last, p, RAIL_R)
		last = p

# ---------------------------------------------------------------- mesh pieces
func _tool(m: Material) -> SurfaceTool:
	if not _st.has(m):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[m] = st
	return _st[m]

## A quad a-b-c-d facing `n` (either winding given; Godot's front faces are clockwise)
func _quad(m: Material, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	var st := _tool(m)
	var order := [a, b, c, a, c, d]
	if (b - a).cross(c - a).dot(n) > 0.0:
		order = [a, c, b, a, d, c]
	for v: Vector3 in order:
		st.set_normal(n)
		st.add_vertex(v)

func _box(m: Material, at: Vector3, size: Vector3, turn := Basis.IDENTITY) -> void:
	var h := size * 0.5
	for axis in 3:
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		for sgn: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = sgn
			var q: Array[Vector3] = []
			for k: Array in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
				var p := Vector3.ZERO
				p[axis] = sgn * h[axis]
				p[u] = k[0] * h[u]
				p[v] = k[1] * h[v]
				q.append(at + turn * p)
			_quad(m, q[0], q[1], q[2], q[3], turn * n)

## A round tube from `a` to `b` (an eight-sided prism; the chrome's reflections round it off)
func _tube(m: Material, a: Vector3, b: Vector3, r: float) -> void:
	var axis := b - a
	if axis.length() < 0.001: return
	var d := axis.normalized()
	var side := (Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT).cross(d).normalized()
	var other := d.cross(side)
	var st := _tool(m)
	for i in 8:
		var t0 := TAU * i / 8.0
		var t1 := TAU * (i + 1) / 8.0
		var n0 := side * cos(t0) + other * sin(t0)
		var n1 := side * cos(t1) + other * sin(t1)
		var q := [[a + n0 * r, n0], [a + n1 * r, n1], [b + n1 * r, n1], [a + n0 * r, n0], [b + n1 * r, n1], [b + n0 * r, n0]]
		var flip: bool = ((q[1][0] as Vector3) - (q[0][0] as Vector3)).cross((q[2][0] as Vector3) - (q[0][0] as Vector3)).dot(n0 + n1) > 0.0
		for k in ([0, 2, 1, 3, 5, 4] if flip else [0, 1, 2, 3, 4, 5]):
			st.set_normal(q[k][1])
			st.add_vertex(q[k][0])

func _cylinder(m: Material, r: float, h: float) -> void:
	for i in 24:
		var n0 := Vector3(cos(TAU * i / 24.0), 0.0, sin(TAU * i / 24.0))
		var n1 := Vector3(cos(TAU * (i + 1) / 24.0), 0.0, sin(TAU * (i + 1) / 24.0))
		_quad(m, n0 * r, n1 * r, n1 * r + Vector3(0, h, 0), n0 * r + Vector3(0, h, 0), (n0 + n1) * 0.5)

## The column with its own UVs (metres round and up), fitted to a whole number of `rep` round it, for the
## unrolled wall material (level_geometry.gd _wall_uv_mat): its tiles go round it unbroken
func _cylinder_uv(m: Material, r: float, h: float, rep: float) -> void:
	var circ := TAU * r
	var k := maxf(1.0, roundf(circ / rep)) * rep / circ
	var mesh_st := SurfaceTool.new()
	mesh_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 32:
		var n0 := Vector3(cos(TAU * i / 32.0), 0.0, sin(TAU * i / 32.0))
		var n1 := Vector3(cos(TAU * (i + 1) / 32.0), 0.0, sin(TAU * (i + 1) / 32.0))
		var u0 := circ * i / 32.0 * k
		var u1 := circ * (i + 1) / 32.0 * k
		var v := [[n0 * r, Vector2(u0, 0), n0], [n1 * r, Vector2(u1, 0), n1], [n1 * r + Vector3(0, h, 0), Vector2(u1, h), n1],
			[n0 * r, Vector2(u0, 0), n0], [n1 * r + Vector3(0, h, 0), Vector2(u1, h), n1], [n0 * r + Vector3(0, h, 0), Vector2(u0, h), n0]]
		var flip: bool = ((v[1][0] as Vector3) - (v[0][0] as Vector3)).cross((v[2][0] as Vector3) - (v[0][0] as Vector3)).dot(n0 + n1) > 0.0
		for j in ([0, 2, 1, 3, 5, 4] if flip else [0, 1, 2, 3, 4, 5]):
			mesh_st.set_normal(v[j][2])
			mesh_st.set_uv(v[j][1])
			mesh_st.add_vertex(v[j][0])
	mesh_st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh_st.commit()
	mi.material_override = m
	add_child(mi)

# ---------------------------------------------------------------- solids
func _solid(at: Vector3, size: Vector3, turn := Basis.IDENTITY) -> void:
	if _body == null: return
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size.abs()
	cs.shape = bs
	cs.transform = Transform3D(turn.orthonormalized(), at)
	cs.set_meta("surface", _surface)
	_body.add_child(cs)

## An upright fence of no thickness to speak of along a sloping rail, from the line a -> b up `h`: its ends and
## sides plumb (a box tilted to the slope jutted back over the treads at its top and caught you there)
func _fence(a: Vector3, b: Vector3, h: float) -> void:
	var side := (b - a).cross(Vector3.UP).normalized() * 0.04
	var up := Vector3(0, h, 0)
	_hull(PackedVector3Array([a - side, a + side, b - side, b + side, a - side + up, a + side + up, b - side + up, b + side + up]))

func _hull(pts: PackedVector3Array) -> void:
	if _body == null: return
	var cs := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	cs.shape = shape
	cs.set_meta("surface", _surface)
	_body.add_child(cs)

## One MeshInstance3D per material, and the solids (added to the body before it joins the tree: each shape added
## to a live body rebuilds it)
func _commit() -> void:
	if solids_only: _st.clear()
	for m: Material in _st:
		var st: SurfaceTool = _st[m]
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = m
		add_child(mi)
	_st.clear()
	if _body != null: add_child(_body)
