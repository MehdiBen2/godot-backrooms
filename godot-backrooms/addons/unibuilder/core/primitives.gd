@tool
class_name UBPrimitives
extends RefCounted
## Factory functions producing UBMeshData shapes; the interactive shape tools
## call these with live parameters.
##
## Curved primitives bake manual per-corner UVs onto their curved faces. Per-face
## planar auto-UV cannot join faces whose normals differ, so the bake unrolls
## the curved surface flat: the texture runs continuously around the curve with
## one seam per closed loop, at 1:1 texel density where an isometric unroll
## exists (cylinder and cone walls; torus and sphere as close as their curvature
## allows). Flat faces (caps, bases) stay on auto, since coplanar faces share a
## projection frame. The baked coords follow the manual-UV rules everywhere
## else: topology ops degrade them to auto, the UV editor edits them, and its
## Auto button re-bakes the per-face projection. All charts keep the auto
## projection's handedness, so nothing renders mirrored.


static func make_cube(size := Vector3.ONE) -> UBMeshData:
	var data := UBMeshData.new()
	var h := size * 0.5
	for p in [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z),
		Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]:
		data.add_vertex(p)

	data.add_face(PackedInt32Array([0, 3, 2, 1]))
	data.add_face(PackedInt32Array([4, 5, 6, 7]))
	data.add_face(PackedInt32Array([0, 1, 5, 4]))
	data.add_face(PackedInt32Array([2, 3, 7, 6]))
	data.add_face(PackedInt32Array([1, 2, 6, 5]))
	data.add_face(PackedInt32Array([0, 4, 7, 3]))
	return data


## Subdivided plane on XZ, facing +Y, centered at the origin. Vertices are laid
## out row-major (index = j * (divisions.x + 1) + i), faces likewise.
static func make_plane(size := Vector2.ONE, divisions := Vector2i(1, 1)) -> UBMeshData:
	var data := UBMeshData.new()
	var dx := maxi(1, divisions.x)
	var dz := maxi(1, divisions.y)
	for j in dz + 1:
		for i in dx + 1:
			data.add_vertex(Vector3(
				(float(i) / dx - 0.5) * size.x, 0.0, (float(j) / dz - 0.5) * size.y))
	for j in dz:
		for i in dx:
			var v00 := j * (dx + 1) + i
			var v10 := v00 + 1
			var v01 := v00 + (dx + 1)
			var v11 := v01 + 1

			data.add_face(PackedInt32Array([v00, v10, v11, v01]))
	return data


## Smooth shades the walls only (one group across the ring) and leaves the caps
## hard, so the silhouette rounds without the rim softening into it, the same
## rule as the pipe and torus.
static func make_cylinder(radius := 0.5, height := 1.0, sides := 16, smooth := false) -> UBMeshData:
	sides = maxi(3, sides)
	var data := UBMeshData.new()
	var hh := height * 0.5
	for i in sides:
		var t := TAU * i / sides
		data.add_vertex(Vector3(cos(t) * radius, -hh, sin(t) * radius))
	for i in sides:
		var t := TAU * i / sides
		data.add_vertex(Vector3(cos(t) * radius, hh, sin(t) * radius))
	var top := PackedInt32Array()
	for i in sides:
		top.append(sides + i)
	data.add_face(top)
	var bottom := PackedInt32Array()
	for i in range(sides - 1, -1, -1):
		bottom.append(i)
	data.add_face(bottom)
	var chord := 2.0 * radius * sin(PI / sides)
	for i in sides:
		var j := (i + 1) % sides
		var wall := data.add_face(PackedInt32Array([i, j, sides + j, sides + i]))
		if smooth:
			wall.smoothing_group = 1

		_ring_wall_uvs(data, wall, {
			i: -chord * i, j: -chord * (i + 1),
			sides + j: -chord * (i + 1), sides + i: -chord * i,
		})
	return data


## Smooth shades the side fan only; the base stays hard. The apex is one shared
## vertex, so smoothing averages every side normal there into a straight-up
## normal, the usual rounded tip of a smooth cone.
static func make_cone(radius := 0.5, height := 1.0, sides := 16, smooth := false) -> UBMeshData:
	sides = maxi(3, sides)
	var data := UBMeshData.new()
	var hh := height * 0.5
	for i in sides:
		var t := TAU * i / sides
		data.add_vertex(Vector3(cos(t) * radius, -hh, sin(t) * radius))
	var apex := data.add_vertex(Vector3(0, hh, 0))
	var bottom := PackedInt32Array()
	for i in range(sides - 1, -1, -1):
		bottom.append(i)
	data.add_face(bottom)

	var chord := 2.0 * radius * sin(PI / sides)
	var slant := sqrt(radius * radius + height * height)
	var wedge := 2.0 * asin(minf(1.0, chord / maxf(2.0 * slant, 1e-12)))
	for i in sides:
		var side := data.add_face(PackedInt32Array([i, (i + 1) % sides, apex]))
		if smooth:
			side.smoothing_group = 1
		side.uv_manual = true
		side.uv_coords = PackedVector2Array([
			Vector2(cos(i * wedge), sin(i * wedge)) * slant,
			Vector2(cos((i + 1) * wedge), sin((i + 1) * wedge)) * slant,
			Vector2.ZERO,
		])
	return data


## Triangular prism (tent shape): rectangular base, ridge along Z at the top.
static func make_prism(size := Vector3.ONE) -> UBMeshData:
	var data := UBMeshData.new()
	var h := size * 0.5
	for p in [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z),
		Vector3(0, h.y, -h.z), Vector3(0, h.y, h.z),
	]:
		data.add_vertex(p)
	data.add_face(PackedInt32Array([0, 3, 2, 1]))
	data.add_face(PackedInt32Array([0, 1, 4]))
	data.add_face(PackedInt32Array([2, 3, 5]))
	data.add_face(PackedInt32Array([1, 2, 5, 4]))
	data.add_face(PackedInt32Array([0, 4, 5, 3]))
	return data


## Solid built by extruding a closed 2D profile along X, centered on X.
## Profile points are (z, y); either winding is accepted. The n-gon caps may be
## concave; the compiler's ear clipping handles them.
static func make_extruded_profile(profile: PackedVector2Array, width: float) -> UBMeshData:
	var data := UBMeshData.new()
	var pts := profile
	if _signed_area(pts) < 0.0:
		pts = pts.duplicate()
		pts.reverse()
	var n := pts.size()
	var hw := width * 0.5
	for p in pts:
		data.add_vertex(Vector3(hw, p.y, p.x))
	for p in pts:
		data.add_vertex(Vector3(-hw, p.y, p.x))
	var right := PackedInt32Array()
	for i in n:
		right.append(i)
	data.add_face(right)
	var left := PackedInt32Array()
	for i in range(n - 1, -1, -1):
		left.append(n + i)
	data.add_face(left)
	for i in n:
		var j := (i + 1) % n
		data.add_face(PackedInt32Array([n + i, n + j, j, i]))
	return data


## Stair layouts (make_stairs `layout.turn`): which way the staircase turns at
## its landing, seen walking up the first flight. LEFT/RIGHT are a quarter turn
## (an L), U_LEFT/U_RIGHT a half turn (two flights side by side with a well
## between them).
enum StairTurn { NONE, LEFT, RIGHT, U_LEFT, U_RIGHT }

## The shape_spec `kind` the shape tool records for stairs
## (UBShapeTool.Kind.STAIRS). Core cannot see the editor's enum, and the
## collision node needs it to lay a staircase's ramp out per flight
## (stairs_ramp_pieces). The value is persisted in every saved spec, so it must
## not change.
const STAIRS_SPEC_KIND := 5


## Solid stairs rising toward +Z, built from a staircase profile.
##
## `overhang` projects each tread past its riser by that much, with a lip `lip`
## thick under it. The footprint is kept: risers shift back so the lowest nose
## still sits on the drawn edge, and treads get deeper rather than the stairs
## longer. `bevel` cuts every convex nosing corner (the tread's front edge, and
## the lip's bottom edge when there is one) by that much along both adjacent
## edges: a flat chamfer at `bevel_segs` 1, a quarter round above it. With an
## overhang, a bevel of half the lip makes the two rounds meet in a bullnose.
## Sizes are clamped to half the shortest adjacent edge so no corner crosses
## its neighbour. Overhang 0 and bevel 0 give the plain profile. `smooth` puts
## the rounded faces (segs > 1) in one smoothing group; treads, risers and the
## flat chamfer stay hard.
##
## `layout` (all optional; defaults reproduce the plain flight):
## - `turn` (StairTurn): a landing splits the flight in two. LEFT/RIGHT put
##   the second flight across the remaining width of the footprint, at right
##   angles; U_LEFT/U_RIGHT run it back alongside the first. Needs 2+ steps.
## - `split`: risers in the first flight (0 = half, rounded down).
## - `flight_w`: width of the first flight (both flights for a U-turn).
## - `landing`: depth of the landing along the first flight's direction.
##   For an L the landing is flight_w x landing and the second flight is
##   `landing` wide; for a U it spans the whole width.
## - `open`: open risers. Each tread is a separate slab `lip` thick with
##   nothing under it, and the landing becomes a slab too.
## - `stringer`: with open risers, the width of a sloped beam under each
##   side of every flight (0 = none). Its depth is one riser plus the slab.
## Turned closed layouts are one watertight solid. Open layouts are separate
## closed solids that touch along edges only. U-turn flights meet when
## `flight_w` reaches half the width, and the result is still one solid.
static func make_stairs(size := Vector3.ONE, steps := 4, overhang := 0.0, lip := 0.1,
		bevel := 0.0, bevel_segs := 1, smooth := true, layout := {}) -> UBMeshData:
	steps = maxi(1, steps)
	bevel_segs = clampi(bevel_segs, 1, 8)
	var turn := clampi(int(layout.get("turn", StairTurn.NONE)), 0, StairTurn.size() - 1)
	var open := bool(layout.get("open", false))
	if steps < 2:
		turn = StairTurn.NONE
	if turn == StairTurn.NONE and not open:
		return _make_straight_stairs(size, steps, overhang, lip, bevel, bevel_segs, smooth)
	return _make_stairs_layout(size, steps, overhang, lip, bevel, bevel_segs, smooth,
		turn, int(layout.get("split", 0)), float(layout.get("flight_w", 0.0)),
		float(layout.get("landing", 0.0)), open, float(layout.get("stringer", 0.0)))


static func _make_straight_stairs(size: Vector3, steps: int, overhang: float, lip: float,
		bevel: float, bevel_segs: int, smooth: bool) -> UBMeshData:
	var y0 := -size.y * 0.5
	var z0 := -size.z * 0.5
	var dy := size.y / steps
	overhang = clampf(overhang, 0.0, 0.45 * size.z / steps)
	var dz := (size.z - overhang) / steps
	var nos := _nosing(dz, dy, overhang, lip, bevel, false)
	var prof := _stairs_profile(z0 + overhang, z0 + size.z, y0, y0, y0 + size.y, steps,
		overhang, nos.lip, nos.bevel, bevel_segs)
	var data := make_extruded_profile(PackedVector2Array(prof.pts), size.x)
	if smooth:
		_smooth_profile_arcs(data, _arc_key_sets(prof))
	return data


static func _nosing(dz: float, dy: float, overhang: float, lip: float, bevel: float,
		slab: bool) -> Dictionary:
	var has_lip := slab or overhang > 1e-9
	lip = clampf(lip, 0.005, 0.9 * dy) if has_lip else 0.0
	var limit := 0.5 * minf(dz + overhang, lip if has_lip else dy)
	if has_lip and not slab:
		limit = minf(limit, 0.5 * overhang)
	var b := clampf(bevel, 0.0, limit)
	if b < 1e-6:
		b = 0.0
	return {"lip": lip, "bevel": b}


static func _prof_append(pts: Array, arcs: Array, p: Vector2, arc: int) -> void:
	var tol := 1e-5 * maxf(1.0, p.length())
	if pts.is_empty() or (pts[pts.size() - 1] as Vector2).distance_to(p) > tol:
		pts.append(p)
		arcs.append(PackedInt32Array([arc]) if arc >= 0 else PackedInt32Array())
	elif arc >= 0:
		var last: PackedInt32Array = arcs[arcs.size() - 1]
		if not last.has(arc):
			last.append(arc)
			arcs[arcs.size() - 1] = last


static func _prof_corner(pts: Array, arcs: Array, counter: Array, p: Vector2, d_in: Vector2,
		d_out: Vector2, b: float, bevel_segs: int) -> void:
	if b <= 0.0:
		_prof_append(pts, arcs, p, -1)
		return
	var s := p - d_in * b
	var e := p + d_out * b
	if bevel_segs == 1:
		_prof_append(pts, arcs, s, -1)
		_prof_append(pts, arcs, e, -1)
		return
	var c := s + d_out * b
	var id: int = counter[0]
	counter[0] += 1
	for k in bevel_segs + 1:
		var t := (PI * 0.5) * float(k) / bevel_segs
		_prof_append(pts, arcs, c - d_out * b * cos(t) + d_in * b * sin(t), id)


static func _stairs_profile(front: float, back: float, floor_y: float, base: float, top: float,
		steps: int, overhang: float, lip: float, b: float, bevel_segs: int, nose0 := NAN) -> Dictionary:
	var s := 1.0 if back >= front else -1.0
	var dz := (back - front) / steps
	var dy := (top - base) / steps
	var has_lip := lip > 0.0
	var pts: Array = []
	var arcs: Array = []
	var counter := [0]
	_prof_append(pts, arcs, Vector2(front, floor_y), -1)
	_prof_append(pts, arcs, Vector2(back, floor_y), -1)
	_prof_append(pts, arcs, Vector2(back, top), -1)
	for i in range(steps - 1, -1, -1):
		var zr := front + i * dz
		var yt := base + (i + 1) * dy
		var zn := zr - overhang * s
		if i == 0 and not is_nan(nose0):
			zn = nose0

		_prof_corner(pts, arcs, counter, Vector2(zn, yt), Vector2(-s, 0.0), Vector2(0.0, -1.0), b, bevel_segs)
		if has_lip:

			_prof_corner(pts, arcs, counter, Vector2(zn, yt - lip), Vector2(0.0, -1.0), Vector2(s, 0.0), b, bevel_segs)
			_prof_append(pts, arcs, Vector2(zr, yt - lip), -1)
		if i > 0:
			_prof_append(pts, arcs, Vector2(zr, base + i * dy), -1)
	if base > floor_y:
		_prof_append(pts, arcs, Vector2(front, base), -1)
	return {"pts": pts, "arcs": arcs}


static func _slab_profile(zn: float, zb: float, yb: float, yt: float, s: float, b: float,
		bevel_segs: int) -> Dictionary:
	var pts: Array = []
	var arcs: Array = []
	var counter := [0]
	_prof_append(pts, arcs, Vector2(zb, yb), -1)
	_prof_append(pts, arcs, Vector2(zb, yt), -1)
	_prof_corner(pts, arcs, counter, Vector2(zn, yt), Vector2(-s, 0.0), Vector2(0.0, -1.0), b, bevel_segs)
	_prof_corner(pts, arcs, counter, Vector2(zn, yb), Vector2(0.0, -1.0), Vector2(s, 0.0), b, bevel_segs)
	return {"pts": pts, "arcs": arcs}


static func _arc_key_sets(prof: Dictionary) -> Array[Dictionary]:
	var sets: Array[Dictionary] = []
	for i in prof.pts.size():
		for id in (prof.arcs[i] as PackedInt32Array):
			while sets.size() <= id:
				sets.append({})
			sets[id][_profile_key(prof.pts[i])] = true
	return sets


static func _profile_key(p: Vector2) -> String:
	return "%.5f,%.5f" % [p.x, p.y]


static func _smooth_profile_arcs(data: UBMeshData, arcs: Array[Dictionary]) -> void:
	for fi in range(2, data.faces.size()):
		var loop := data.faces[fi].vertices
		if loop.size() != 4:
			continue
		var a := data.positions[loop[3]]
		var c := data.positions[loop[2]]
		var ka := _profile_key(Vector2(a.z, a.y))
		var kc := _profile_key(Vector2(c.z, c.y))
		for keys in arcs:
			if keys.has(ka) and keys.has(kc):
				data.faces[fi].smoothing_group = 1
				break


const _FRAME_FWD := [Vector3.RIGHT, Vector3(0, 0, 1)]
const _FRAME_TURN := [Vector3(0, 0, -1), Vector3.RIGHT]
const _FRAME_BACK := [Vector3.LEFT, Vector3(0, 0, -1)]


static func _make_stairs_layout(size: Vector3, steps: int, overhang: float, lip: float,
		bevel: float, bevel_segs: int, smooth: bool, turn: int, split: int, flight_w: float,
		landing: float, open: bool, stringer: float) -> UBMeshData:
	var data := UBMeshData.new()
	var cache := {}
	var lay := _stairs_layout(size, steps, turn, split, flight_w, landing)
	var x_l: float = lay.x_l
	var x_r: float = lay.x_r
	var z0: float = lay.z0
	var z_end: float = lay.z_end
	var y0: float = lay.y0
	var y_top: float = lay.y_top
	var dy := size.y / steps
	var turned: bool = lay.turned
	var u_turn: bool = lay.u_turn

	var mirror: bool = lay.mirror
	var n1: int = lay.n1
	var n2: int = lay.n2
	var fw: float = lay.fw
	var ld: float = lay.ld
	var h1: float = lay.h1
	var z_land: float = lay.z_land
	var xs1: float = lay.xs1
	var xs2: float = lay.xs2
	var touch: bool = lay.touch

	var back1: float = lay.back1
	var span1 := back1 - z0
	var span2 := (x_r - xs1) if (turned and not u_turn) else span1
	var ov := clampf(overhang, 0.0, 0.45 * minf(span1 / n1, span2 / n2 if n2 > 0 else INF))
	var dz_min := minf((span1 - ov) / n1, span2 / n2 if n2 > 0 else INF)
	var nos := _nosing(dz_min, dy, ov, lip, bevel, open)
	var lp: float = nos.lip
	var b: float = nos.bevel
	var sw := 0.0
	if open and stringer > 0.0:
		var narrowest := minf(fw, ld if turned and not u_turn else fw)
		sw = clampf(stringer, 0.0, 0.45 * narrowest)
	var x_hi1 := xs1 if turned else x_r
	if open:

		_emit_flight_open(data, cache, _FRAME_FWD, x_l, x_hi1, z0 + ov, back1, y0, h1, n1,
			ov, lp, b, bevel_segs, smooth, z_end if turned else back1,
			x_l, x_r if u_turn else x_hi1)
		if sw > 0.0:
			_emit_beams(data, cache, _FRAME_FWD, x_l, x_hi1, z0 + ov, back1, y0, h1, n1, lp, sw, y0)
		if turned and not u_turn:
			_emit_flight_open(data, cache, _FRAME_TURN, -z_end, -z_land, xs1, x_r, h1, y_top, n2,
				ov, lp, b, bevel_segs, smooth, x_r, -z_end, -z_land)
			if sw > 0.0:
				_emit_beams(data, cache, _FRAME_TURN, -z_end, -z_land, xs1, x_r, h1, y_top, n2, lp, sw, h1 - lp)
		elif u_turn:
			_emit_flight_open(data, cache, _FRAME_BACK, -x_r, -xs2, -z_land, -z0, h1, y_top, n2,
				ov, lp, b, bevel_segs, smooth, -z0, -x_r, -xs2)
			if sw > 0.0:
				_emit_beams(data, cache, _FRAME_BACK, -x_r, -xs2, -z_land, -z0, h1, y_top, n2, lp, sw, h1 - lp)
	else:

		var prof1 := _stairs_profile(z0 + ov, back1, y0, y0, h1, n1, ov, lp, b, bevel_segs,
			z0 if touch else NAN)
		var prof2 := {}
		var world2 := {}
		if touch:

			prof2 = _stairs_profile(-z_land, -z0, y0, h1, y_top, n2, ov, lp, b, bevel_segs)
			world2 = _flip_profile_z(prof2)
			_split_shared_edges(world2, prof1.pts)
			_split_shared_edges(prof1, world2.pts)
			prof2 = _flip_profile_z(world2)

		_emit_profile_solid(data, cache, _FRAME_FWD, x_l, x_hi1, prof1,
			[[Vector2(back1, y0), Vector2(back1, h1)]], smooth, not touch)
		if turned and not u_turn:

			_emit_landing_closed(data, cache, x_l, xs1, z_land, z_end, y0, h1, [], [], true, false)
			prof2 = _stairs_profile(xs1, x_r, y0, h1, y_top, n2, ov, lp, b, bevel_segs)
			_emit_profile_solid(data, cache, _FRAME_TURN, -z_end, -z_land, prof2,
				[[Vector2(xs1, h1), Vector2(xs1, y0)]], smooth)
		elif u_turn:

			_emit_landing_closed(data, cache, x_l, x_r, z_land, z_end, y0, h1,
				[[xs1, xs2]], [xs1, xs2], true, true)
			if not touch:
				prof2 = _stairs_profile(-z_land, -z0, y0, h1, y_top, n2, ov, lp, b, bevel_segs)
			_emit_profile_solid(data, cache, _FRAME_BACK, -x_r, -xs2, prof2,
				[[Vector2(-z_land, h1), Vector2(-z_land, y0)]], smooth, not touch)
			if touch:

				for loop: PackedVector2Array in _profile_minus(world2.pts, prof1.pts):
					var ids := PackedInt32Array()
					for p in loop:
						ids.append(_vid(data, cache, Vector3(xs1, p.y, p.x)))
					_add_face_oriented(data, ids, Vector3.LEFT)
	if mirror:
		_mirror_x(data)
	return data


static func _stairs_layout(size: Vector3, steps: int, turn: int, split: int, flight_w: float,
		landing: float) -> Dictionary:
	steps = maxi(1, steps)
	turn = clampi(turn, 0, StairTurn.size() - 1)
	if steps < 2:
		turn = StairTurn.NONE
	var x_l := -size.x * 0.5
	var x_r := size.x * 0.5
	var z0 := -size.z * 0.5
	var z_end := size.z * 0.5
	var y0 := -size.y * 0.5
	var y_top := size.y * 0.5
	var dy := size.y / steps
	var turned := turn != StairTurn.NONE
	var u_turn := turn == StairTurn.U_LEFT or turn == StairTurn.U_RIGHT
	var n1 := steps
	var n2 := 0
	var fw := size.x
	var ld := 0.0
	if turned:
		n1 = clampi(split if split > 0 else steps / 2, 1, steps - 1)
		n2 = steps - n1
		fw = clampf(flight_w, size.x * 0.05, size.x * (0.5 if u_turn else 0.95))
		if u_turn and fw >= size.x * (0.5 - 1e-5):

			fw = size.x * 0.5
		ld = clampf(landing, size.z * 0.05, size.z * 0.95)
	var h1 := y0 + n1 * dy if turned else y_top
	var z_land := z_end - ld
	var xs1 := x_l + fw

	var xs2 := x_r - fw
	var touch := u_turn and xs2 <= xs1
	if touch:
		xs2 = xs1
	return {
		"turned": turned, "u_turn": u_turn, "touch": touch,
		"mirror": turn == StairTurn.RIGHT or turn == StairTurn.U_RIGHT,
		"n1": n1, "n2": n2, "fw": fw, "ld": ld, "h1": h1, "z_land": z_land,
		"xs1": xs1, "xs2": xs2,
		"back1": z_land if turned else z_end, "x_hi1": xs1 if turned else x_r,
		"x_l": x_l, "x_r": x_r, "z0": z0, "z_end": z_end, "y0": y0, "y_top": y_top,
	}


## Convex ramp-collision pieces for a stairs shape_spec (dims + params as the
## shape tool records them). A straight flight gives one wedge over the box,
## the same 6-point wedge UBMeshInstance3D builds from the bounds. A turned
## layout gives a wedge per flight (the second on a plinth down to the floor)
## and a box for the landing. Right turns are the mirrored left pieces. Open
## risers use the same pieces.
static func stairs_ramp_pieces(dims: Dictionary, params: Dictionary) -> Array[PackedVector3Array]:
	var size := Vector3(float(dims.get("su", 1.0)), float(dims.get("ah", 1.0)), float(dims.get("sv", 1.0)))
	var lay := _stairs_layout(size, clampi(int(params.get("steps", 4)), 1, 64),
		int(params.get("turn", 0)), int(params.get("split", 0)),
		float(params.get("flight_w", 0.0)), float(params.get("landing", 0.0)))
	var pieces: Array[PackedVector3Array] = []
	var x_l: float = lay.x_l
	var x_r: float = lay.x_r
	var y0: float = lay.y0
	var h1: float = lay.h1
	var z_land: float = lay.z_land

	pieces.append(PackedVector3Array([
		Vector3(x_l, y0, lay.z0), Vector3(lay.x_hi1, y0, lay.z0),
		Vector3(x_l, y0, lay.back1), Vector3(lay.x_hi1, y0, lay.back1),
		Vector3(x_l, h1, lay.back1), Vector3(lay.x_hi1, h1, lay.back1),
	]))
	if lay.turned:
		var land_r: float = x_r if lay.u_turn else lay.xs1
		pieces.append(_box_points(x_l, land_r, y0, h1, z_land, lay.z_end))
		if lay.u_turn:
			var xs2: float = lay.xs2
			pieces.append(PackedVector3Array([
				Vector3(xs2, y0, lay.z0), Vector3(x_r, y0, lay.z0),
				Vector3(xs2, y0, z_land), Vector3(x_r, y0, z_land),
				Vector3(xs2, h1, z_land), Vector3(x_r, h1, z_land),
				Vector3(xs2, lay.y_top, lay.z0), Vector3(x_r, lay.y_top, lay.z0),
			]))
		else:
			var xs1: float = lay.xs1
			pieces.append(PackedVector3Array([
				Vector3(xs1, y0, z_land), Vector3(x_r, y0, z_land),
				Vector3(xs1, y0, lay.z_end), Vector3(x_r, y0, lay.z_end),
				Vector3(xs1, h1, z_land), Vector3(xs1, h1, lay.z_end),
				Vector3(x_r, lay.y_top, z_land), Vector3(x_r, lay.y_top, lay.z_end),
			]))
	if lay.mirror:
		for i in pieces.size():
			var pts := pieces[i]
			for k in pts.size():
				pts[k].x = -pts[k].x
			pieces[i] = pts
	return pieces


static func _box_points(xa: float, xb: float, ya: float, yb: float, za: float, zb: float) -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(xa, ya, za), Vector3(xb, ya, za), Vector3(xa, ya, zb), Vector3(xb, ya, zb),
		Vector3(xa, yb, za), Vector3(xb, yb, za), Vector3(xa, yb, zb), Vector3(xb, yb, zb),
	])


static func _vid(data: UBMeshData, cache: Dictionary, p: Vector3) -> int:
	var key := Vector3(p.x + 0.0, p.y + 0.0, p.z + 0.0)
	if not cache.has(key):
		cache[key] = data.add_vertex(key)
	return cache[key]


static func _map(frame: Array, lx: float, y: float, lz: float) -> Vector3:
	var ax: Vector3 = frame[0]
	var az: Vector3 = frame[1]
	return Vector3(lx * ax.x + lz * az.x, y, lx * ax.z + lz * az.z)


static func _emit_profile_solid(data: UBMeshData, cache: Dictionary, frame: Array, x_lo: float,
		x_hi: float, prof: Dictionary, skip: Array, smooth: bool, cap_hi := true) -> void:
	var pts: Array = prof.pts.duplicate()
	var arcs: Array = prof.arcs.duplicate()
	if _signed_area(PackedVector2Array(pts)) < 0.0:
		pts.reverse()
		arcs.reverse()
	var n := pts.size()
	var right := PackedInt32Array()
	var left := PackedInt32Array()
	for p: Vector2 in pts:
		right.append(_vid(data, cache, _map(frame, x_hi, p.y, p.x)))
		left.append(_vid(data, cache, _map(frame, x_lo, p.y, p.x)))
	if cap_hi:
		data.add_face(right)
	var lcap := PackedInt32Array()
	for i in range(n - 1, -1, -1):
		lcap.append(left[i])
	data.add_face(lcap)
	for i in n:
		var j := (i + 1) % n
		if _edge_listed(skip, pts[i], pts[j]):
			continue
		var face := data.add_face(PackedInt32Array([left[i], left[j], right[j], right[i]]))
		if smooth and _share_arc(arcs[i], arcs[j]):
			face.smoothing_group = 1


static func _edge_listed(skip: Array, a: Vector2, b: Vector2) -> bool:
	for pair in skip:
		if (pair[0] == a and pair[1] == b) or (pair[0] == b and pair[1] == a):
			return true
	return false


static func _share_arc(a: PackedInt32Array, b: PackedInt32Array) -> bool:
	for id in a:
		if b.has(id):
			return true
	return false


static func _flip_profile_z(prof: Dictionary) -> Dictionary:
	var pts: Array = []
	for p: Vector2 in prof.pts:
		pts.append(Vector2(-p.x, p.y))
	return {"pts": pts, "arcs": prof.arcs.duplicate()}


static func _split_shared_edges(prof: Dictionary, other: Array) -> void:
	var pts: Array = prof.pts
	var arcs: Array = prof.arcs
	var out_pts: Array = []
	var out_arcs: Array = []
	var n := pts.size()
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		out_pts.append(a)
		out_arcs.append(arcs[i])
		var axis := -1
		if a.x == b.x and a.y != b.y:
			axis = 1
		elif a.y == b.y and a.x != b.x:
			axis = 0
		if axis < 0:
			continue
		var between: Array = []
		for r: Vector2 in other:
			if r[1 - axis] != a[1 - axis] or between.has(r):
				continue
			var t: float = (r[axis] - a[axis]) / (b[axis] - a[axis])
			if t > 0.0 and t < 1.0:
				between.append(r)
		between.sort_custom(func(p: Vector2, q: Vector2) -> bool:
			return absf(p[axis] - a[axis]) < absf(q[axis] - a[axis]))
		for r in between:
			out_pts.append(r)
			out_arcs.append(PackedInt32Array())
	prof.pts = out_pts
	prof.arcs = out_arcs


static func _ccw_loop(pts: Array) -> Array:
	var out: Array = pts.duplicate()
	if _signed_area(PackedVector2Array(out)) < 0.0:
		out.reverse()
	return out


static func _has_directed_edge(poly: Array, p: Vector2, q: Vector2) -> bool:
	var n := poly.size()
	for i in n:
		if poly[i] == p and poly[(i + 1) % n] == q:
			return true
	return false


static func _profile_minus(outer: Array, inner: Array) -> Array:
	var a := _ccw_loop(outer)
	var b := _ccw_loop(inner)
	var edges: Array = []
	for i in a.size():
		var p: Vector2 = a[i]
		var q: Vector2 = a[(i + 1) % a.size()]
		if not _has_directed_edge(b, p, q):
			edges.append([p, q, 0])
	for i in b.size():
		var p: Vector2 = b[i]
		var q: Vector2 = b[(i + 1) % b.size()]
		if not _has_directed_edge(a, p, q):
			edges.append([q, p, 1])
	var loops: Array = []
	var used := PackedByteArray()
	used.resize(edges.size())
	for start in edges.size():
		if used[start]:
			continue
		var loop := PackedVector2Array()
		var cur := start
		while true:
			used[cur] = 1
			loop.append(edges[cur][0])
			var nxt := _next_boundary_edge(edges, cur)
			if nxt == start or nxt < 0 or used[nxt]:
				break
			cur = nxt
		if loop.size() >= 3:
			loops.append(loop)
	return loops


static func _next_boundary_edge(edges: Array, cur: int) -> int:
	var at: Vector2 = edges[cur][1]
	var src: int = edges[cur][2]
	var same := -1
	for i in edges.size():
		if edges[i][0] != at:
			continue
		if edges[i][2] != src:
			return i
		same = i
	return same


static func _emit_landing_closed(data: UBMeshData, cache: Dictionary, xa: float, xb: float,
		za: float, zb: float, y0: float, y1: float, front_open: Array, front_xs: Array,
		left_open: bool, right_open: bool) -> void:
	var xs: Array = [xa]
	for x in front_xs:
		if x > xa and x < xb and not xs.has(x):
			xs.append(x)
	xs.append(xb)
	var top := PackedInt32Array()
	var bottom := PackedInt32Array()
	for x in xs:
		top.append(_vid(data, cache, Vector3(x, y1, za)))
		bottom.append(_vid(data, cache, Vector3(x, y0, za)))
	top.append(_vid(data, cache, Vector3(xb, y1, zb)))
	top.append(_vid(data, cache, Vector3(xa, y1, zb)))
	bottom.append(_vid(data, cache, Vector3(xb, y0, zb)))
	bottom.append(_vid(data, cache, Vector3(xa, y0, zb)))
	_add_face_oriented(data, top, Vector3.UP)
	_add_face_oriented(data, bottom, Vector3.DOWN)
	_add_face_oriented(data, PackedInt32Array([
		_vid(data, cache, Vector3(xa, y0, zb)), _vid(data, cache, Vector3(xb, y0, zb)),
		_vid(data, cache, Vector3(xb, y1, zb)), _vid(data, cache, Vector3(xa, y1, zb)),
	]), Vector3(0, 0, 1))
	if left_open:
		_add_face_oriented(data, PackedInt32Array([
			_vid(data, cache, Vector3(xa, y0, za)), _vid(data, cache, Vector3(xa, y0, zb)),
			_vid(data, cache, Vector3(xa, y1, zb)), _vid(data, cache, Vector3(xa, y1, za)),
		]), Vector3.LEFT)
	if right_open:
		_add_face_oriented(data, PackedInt32Array([
			_vid(data, cache, Vector3(xb, y0, za)), _vid(data, cache, Vector3(xb, y0, zb)),
			_vid(data, cache, Vector3(xb, y1, zb)), _vid(data, cache, Vector3(xb, y1, za)),
		]), Vector3.RIGHT)
	for strip in front_open:
		var x1: float = strip[0]
		var x2: float = strip[1]
		if x2 <= x1:
			continue
		_add_face_oriented(data, PackedInt32Array([
			_vid(data, cache, Vector3(x1, y0, za)), _vid(data, cache, Vector3(x2, y0, za)),
			_vid(data, cache, Vector3(x2, y1, za)), _vid(data, cache, Vector3(x1, y1, za)),
		]), Vector3(0, 0, -1))


static func _emit_flight_open(data: UBMeshData, cache: Dictionary, frame: Array, x_lo: float,
		x_hi: float, front: float, back: float, base: float, top: float, n: int, overhang: float,
		lip: float, b: float, bevel_segs: int, smooth: bool, last_back: float, last_x_lo: float,
		last_x_hi: float) -> void:
	var s := 1.0 if back >= front else -1.0
	var dz := (back - front) / n
	var dy := (top - base) / n
	for i in n:
		var zr := front + i * dz
		var yt := base + (i + 1) * dy
		var last := i == n - 1
		var zb := last_back if last else zr + dz
		var prof := _slab_profile(zr - overhang * s, zb, yt - lip, yt, s, b, bevel_segs)
		_emit_profile_solid(data, cache, frame, last_x_lo if last else x_lo,
			last_x_hi if last else x_hi, prof, [], smooth)


static func _emit_beams(data: UBMeshData, cache: Dictionary, frame: Array, x_lo: float,
		x_hi: float, front: float, back: float, base: float, top: float, n: int, lip: float,
		sw: float, floor_y: float) -> void:
	var dz := (back - front) / n
	var dy := (top - base) / n
	var depth := dy + lip

	var k_a := (floor_y - base + lip) / dy
	var k_b := k_a + depth / dy
	if k_a >= n - 1e-6:
		return
	var pts: Array = [Vector2(front + dz * k_a, floor_y)]
	if k_b < n:
		pts.append(Vector2(front + dz * k_b, floor_y))
		pts.append(Vector2(back, base + n * dy - lip - depth))
	else:
		pts.append(Vector2(back, floor_y))
	pts.append(Vector2(back, base + n * dy - lip))
	var arcs: Array = []
	for _p in pts:
		arcs.append(PackedInt32Array())
	var prof := {"pts": pts, "arcs": arcs}
	_emit_profile_solid(data, cache, frame, x_lo, x_lo + sw, prof, [], false)
	_emit_profile_solid(data, cache, frame, x_hi - sw, x_hi, prof, [], false)


static func _mirror_x(data: UBMeshData) -> void:
	var pos := data.positions
	for i in pos.size():
		pos[i].x = -pos[i].x
	data.positions = pos
	for f in data.faces:
		var v := f.vertices
		v.reverse()
		f.vertices = v


## Arch: a wall spanning Z with a semicircular opening, extruded along X.
## `smooth` puts the opening's curved underside in one smoothing group so it
## shades round; the springing edges and everything else stay hard.
static func make_arch(span := 2.0, height := 1.5, thickness := 0.5, radius := 0.8, sides := 8, smooth := false) -> UBMeshData:
	sides = maxi(2, sides)
	var w2 := span * 0.5
	var y0 := -height * 0.5

	var r_hi := minf(w2 * 0.95, height * 0.95)
	var r := clampf(radius, minf(0.01, r_hi), r_hi)
	var profile := PackedVector2Array()
	profile.append(Vector2(-w2, y0))
	profile.append(Vector2(-w2, y0 + height))
	profile.append(Vector2(w2, y0 + height))
	profile.append(Vector2(w2, y0))
	profile.append(Vector2(r, y0))
	for i in range(1, sides):
		var t := PI * i / sides
		profile.append(Vector2(r * cos(t), y0 + r * sin(t)))
	profile.append(Vector2(-r, y0))
	var data := make_extruded_profile(profile, thickness)
	if smooth:
		_smooth_arc_walls(data, func(p: Vector3) -> bool:
			return absf(Vector2(p.z, p.y - y0).length() - r) <= r * 1e-3)
	return data


static func _smooth_arc_walls(data: UBMeshData, on_arc: Callable) -> void:
	for fi in range(2, data.faces.size()):
		var all_on := true
		for vi in data.faces[fi].vertices:
			if not on_arc.call(data.positions[vi]):
				all_on = false
				break
		if all_on:
			data.faces[fi].smoothing_group = 1


## Door frame: a wall spanning Z with a doorway reaching the floor, extruded
## along X, with two side posts and a pediment band on top. Watertight.
## `pediment_height` is the solid band above the opening, `side_width` the post
## on each side. `arched` swaps the flat lintel for an arc to the same apex
## height: semicircular when the opening is tall enough (radius = opening
## half-width), elliptically squashed otherwise so it always fits.
static func make_door(span := 2.0, height := 2.0, thickness := 0.5, pediment_height := 0.5, side_width := 0.75, arched := false, sides := 8, smooth := false) -> UBMeshData:
	var w2 := span * 0.5
	var y0 := -height * 0.5
	var ped := clampf(pediment_height, 0.01, height * 0.95)
	var side := clampf(side_width, 0.01, w2 * 0.95)
	var ow := w2 - side
	var oh := height - ped
	var profile := PackedVector2Array()
	profile.append(Vector2(-w2, y0))
	profile.append(Vector2(-w2, y0 + height))
	profile.append(Vector2(w2, y0 + height))
	profile.append(Vector2(w2, y0))
	profile.append(Vector2(ow, y0))
	if arched:
		sides = maxi(2, sides)
		var b := minf(ow, oh)
		var spring := y0 + oh - b
		if oh > b + 1e-6:
			profile.append(Vector2(ow, spring))
		for i in range(1, sides):
			var t := PI * i / sides
			profile.append(Vector2(ow * cos(t), spring + b * sin(t)))
		if oh > b + 1e-6:
			profile.append(Vector2(-ow, spring))
	else:
		profile.append(Vector2(ow, y0 + oh))
		profile.append(Vector2(-ow, y0 + oh))
	profile.append(Vector2(-ow, y0))
	var data := make_extruded_profile(profile, thickness)
	if arched and smooth:

		var b := minf(ow, oh)
		var spring := y0 + oh - b
		_smooth_arc_walls(data, func(p: Vector3) -> bool:
			return absf(Vector2(p.z / ow, (p.y - spring) / b).length() - 1.0) <= 1e-3)
	return data


static func _add_face_oriented(data: UBMeshData, ids: PackedInt32Array, outward: Vector3) -> UBFace:
	var face := data.add_face(ids)
	if data.face_normal(face).dot(outward) < 0.0:
		var v := face.vertices
		v.reverse()
		face.vertices = v
	return face


## Cube-sphere: a cube with each face split into subdivisions² quads, vertices
## normalized onto the sphere. Quads everywhere, no pole fans. `smooth` (the
## default) puts every face in smoothing group 1; unchecked leaves the quads
## flat for low-poly work.
static func make_sphere(radius := 0.5, subdivisions := 4, smooth := true) -> UBMeshData:
	subdivisions = clampi(subdivisions, 1, 16)
	var data := UBMeshData.new()
	var cache := {}
	var frames := [
		[Vector3.UP, Vector3.RIGHT, Vector3(0, 0, 1)],
		[Vector3.DOWN, Vector3.RIGHT, Vector3(0, 0, 1)],
		[Vector3.RIGHT, Vector3.UP, Vector3(0, 0, 1)],
		[Vector3.LEFT, Vector3.UP, Vector3(0, 0, 1)],
		[Vector3(0, 0, 1), Vector3.RIGHT, Vector3.UP],
		[Vector3(0, 0, -1), Vector3.RIGHT, Vector3.UP],
	]
	for frame in frames:
		var n: Vector3 = frame[0]
		var u: Vector3 = frame[1]
		var v: Vector3 = frame[2]
		for gy in subdivisions:
			for gx in subdivisions:
				var ids := PackedInt32Array()
				for corner in [Vector2i(gx, gy), Vector2i(gx + 1, gy), Vector2i(gx + 1, gy + 1), Vector2i(gx, gy + 1)]:
					var p: Vector3 = (
						n + u * (2.0 * corner.x / subdivisions - 1.0)
						+ v * (2.0 * corner.y / subdivisions - 1.0)
					)
					var key := (p * 4096.0).round()
					if not cache.has(key):
						cache[key] = data.add_vertex(p.normalized() * radius)
					ids.append(cache[key])
				var face := _add_face_oriented(data, ids, _quad_centroid(data, ids))
				if smooth:
					face.smoothing_group = 1
	_bake_sphere_uvs(data, radius)
	return data


static func _bake_sphere_uvs(data: UBMeshData, radius: float) -> void:
	if radius <= 0.0:
		return
	for face in data.faces:
		var lons := PackedFloat64Array()
		var lo := INF
		var hi := -INF
		for vi in face.vertices:
			var p := data.positions[vi]
			if Vector2(p.x, p.z).length() <= radius * 1e-5:
				lons.append(INF)
				continue
			var lon := atan2(p.z, p.x)
			lons.append(lon)
			lo = minf(lo, lon)
			hi = maxf(hi, lon)
		if hi - lo > PI:
			for k in lons.size():
				if lons[k] < 0.0:
					lons[k] += TAU
		var lon_sum := 0.0
		var lon_count := 0
		for k in lons.size():
			if lons[k] != INF:
				lon_sum += lons[k]
				lon_count += 1
		var coords := PackedVector2Array()
		for k in face.vertices.size():
			var lon := lons[k] if lons[k] != INF else lon_sum / maxi(1, lon_count)
			var lat := asin(clampf(data.positions[face.vertices[k]].y / radius, -1.0, 1.0))
			coords.append(Vector2(-lon * radius, -lat * radius))
		face.uv_manual = true
		face.uv_coords = coords


static func _ring_wall_uvs(data: UBMeshData, face: UBFace, u_by_vertex: Dictionary) -> void:
	var coords := PackedVector2Array()
	for vi in face.vertices:
		coords.append(Vector2(u_by_vertex[vi], -data.positions[vi].y))
	face.uv_manual = true
	face.uv_coords = coords


static func _quad_centroid(data: UBMeshData, ids: PackedInt32Array) -> Vector3:
	var sum := Vector3.ZERO
	for vi in ids:
		sum += data.positions[vi]
	return sum / ids.size()


## Torus: ring radius to the tube center, tube radius around it. Quads
## everywhere, smoothing group 1.
static func make_torus(ring_radius := 1.0, tube_radius := 0.25, ring_segments := 24, tube_segments := 12) -> UBMeshData:
	ring_segments = maxi(3, ring_segments)
	tube_segments = maxi(3, tube_segments)
	tube_radius = clampf(tube_radius, 0.001, ring_radius * 0.95)
	var data := UBMeshData.new()
	for i in ring_segments:
		var a := TAU * i / ring_segments
		var center := Vector3(cos(a) * ring_radius, 0.0, sin(a) * ring_radius)
		var radial := Vector3(cos(a), 0.0, sin(a))
		for j in tube_segments:
			var b := TAU * j / tube_segments
			data.add_vertex(center + radial * cos(b) * tube_radius + Vector3.UP * sin(b) * tube_radius)
	var chord_ring := 2.0 * ring_radius * sin(PI / ring_segments)
	var chord_tube := 2.0 * tube_radius * sin(PI / tube_segments)
	for i in ring_segments:
		var i2 := (i + 1) % ring_segments
		for j in tube_segments:
			var j2 := (j + 1) % tube_segments
			var ids := PackedInt32Array([
				i * tube_segments + j, i2 * tube_segments + j,
				i2 * tube_segments + j2, i * tube_segments + j2,
			])

			var centroid := _quad_centroid(data, ids)
			var a0 := TAU * i / ring_segments
			var a1 := TAU * (i + 1) / ring_segments
			var chord_mid := (Vector3(cos(a0), 0.0, sin(a0)) + Vector3(cos(a1), 0.0, sin(a1))) * (ring_radius * 0.5)
			var face := _add_face_oriented(data, ids, centroid - chord_mid)
			face.smoothing_group = 1

			var cols := {
				i * tube_segments + j: Vector2i(i, j),
				i2 * tube_segments + j: Vector2i(i + 1, j),
				i2 * tube_segments + j2: Vector2i(i + 1, j + 1),
				i * tube_segments + j2: Vector2i(i, j + 1),
			}
			var coords := PackedVector2Array()
			for vi in face.vertices:
				var col: Vector2i = cols[vi]
				coords.append(Vector2(-chord_ring * col.x, -chord_tube * col.y))
			face.uv_manual = true
			face.uv_coords = coords
	return data


## Pipe: outer wall, inner wall, and two ring caps; watertight, Euler
## characteristic 0. Walls share smoothing group 1, caps stay hard.
static func make_pipe(outer_radius := 0.5, inner_radius := 0.3, height := 1.0, sides := 16) -> UBMeshData:
	sides = maxi(3, sides)
	inner_radius = clampf(inner_radius, 0.001, outer_radius * 0.98)
	var data := UBMeshData.new()
	var hh := height * 0.5
	for ring in [[outer_radius, -hh], [outer_radius, hh], [inner_radius, -hh], [inner_radius, hh]]:
		for i in sides:
			var t := TAU * i / sides
			data.add_vertex(Vector3(cos(t) * ring[0], ring[1], sin(t) * ring[0]))
	var ob := 0
	var ot := sides
	var ib := sides * 2
	var it := sides * 3
	var chord_out := 2.0 * outer_radius * sin(PI / sides)
	var chord_in := 2.0 * inner_radius * sin(PI / sides)
	for i in sides:
		var j := (i + 1) % sides
		var mid := TAU * (i + 0.5) / sides
		var radial := Vector3(cos(mid), 0.0, sin(mid))
		var outer := _add_face_oriented(data, PackedInt32Array([ob + i, ob + j, ot + j, ot + i]), radial)
		var inner := _add_face_oriented(data, PackedInt32Array([ib + i, ib + j, it + j, it + i]), -radial)
		outer.smoothing_group = 1
		inner.smoothing_group = 1
		_add_face_oriented(data, PackedInt32Array([ot + i, ot + j, it + j, it + i]), Vector3.UP)
		_add_face_oriented(data, PackedInt32Array([ob + i, ob + j, ib + j, ib + i]), Vector3.DOWN)

		_ring_wall_uvs(data, outer, {
			ob + i: -chord_out * i, ob + j: -chord_out * (i + 1),
			ot + j: -chord_out * (i + 1), ot + i: -chord_out * i,
		})
		_ring_wall_uvs(data, inner, {
			ib + i: chord_in * i, ib + j: chord_in * (i + 1),
			it + j: chord_in * (i + 1), it + i: chord_in * i,
		})
	return data


## Scales and slides a mesh's XZ footprint so it is centered on the local origin
## and its larger horizontal dimension spans `extent`. Radial primitives get
## this for free by building around their own center; a shape built around a
## pivot outside itself (the curved staircase's arc center) does not. Y is
## untouched. Fitting after the build is exact, since it accounts for the
## chords cutting inside the ideal arc.
static func fit_xz(data: UBMeshData, extent: float) -> UBMeshData:
	if data == null or data.positions.is_empty():
		return data
	var lo := Vector2(INF, INF)
	var hi := -lo
	for p in data.positions:
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
	var size := hi - lo
	var span := maxf(size.x, size.y)
	if span <= 1e-6:
		return data
	var k := maxf(extent, 1e-6) / span
	var center := (lo + hi) * 0.5
	for i in data.positions.size():
		var p: Vector3 = data.positions[i]
		data.positions[i] = Vector3((p.x - center.x) * k, p.y, (p.z - center.y) * k)
	return data


## Curved stairs: the polar variant of make_stairs. Solid wedge steps ascend
## around an arc (rising with increasing angle), watertight. The arc is clamped
## below a full turn so the end caps never coincide.
static func make_curved_stairs(inner_radius := 0.5, outer_radius := 1.5, height := 1.0, steps := 8, arc_deg := 90.0) -> UBMeshData:
	arc_deg = clampf(arc_deg, 5.0, 355.0)

	steps = maxi(maxi(1, steps), ceili(arc_deg / 179.0))
	inner_radius = clampf(inner_radius, 0.001, outer_radius * 0.95)
	var arc := deg_to_rad(arc_deg)
	var data := UBMeshData.new()
	var y0 := -height * 0.5
	var dh := height / steps
	var cache := {}

	var radii := [inner_radius, outer_radius]
	var vert := func(ring: int, k: int, level: int) -> int:
		var key := Vector3i(ring, k, level)
		if not cache.has(key):
			var a: float = arc * k / steps
			var r: float = radii[ring]
			var y: float = y0 + level * dh
			cache[key] = data.add_vertex(Vector3(cos(a) * r, y, sin(a) * r))
		return cache[key]
	for i in steps:
		var mid: float = arc * (i + 0.5) / steps
		var radial := Vector3(cos(mid), 0.0, sin(mid))
		var in0: int = vert.call(0, i, 0)
		var out0: int = vert.call(1, i, 0)
		var in1: int = vert.call(0, i + 1, 0)
		var out1: int = vert.call(1, i + 1, 0)
		var tin0: int = vert.call(0, i, i + 1)
		var tout0: int = vert.call(1, i, i + 1)
		var tin1: int = vert.call(0, i + 1, i + 1)
		var tout1: int = vert.call(1, i + 1, i + 1)
		_add_face_oriented(data, PackedInt32Array([in0, out0, out1, in1]), Vector3.DOWN)
		_add_face_oriented(data, PackedInt32Array([tin0, tout0, tout1, tin1]), Vector3.UP)

		var wall_out := PackedInt32Array([out0, out1, tout1, tout0])
		var wall_in := PackedInt32Array([in0, in1, tin1, tin0])
		if i > 0:
			wall_out.append(vert.call(1, i, i))
			wall_in.append(vert.call(0, i, i))
		_add_face_oriented(data, wall_out, radial)
		_add_face_oriented(data, wall_in, -radial)
		var a0: float = arc * i / steps
		var tangent := Vector3(-sin(a0), 0.0, cos(a0))
		if i == 0:

			_add_face_oriented(data, PackedInt32Array([in0, out0, tout0, tin0]), -tangent)
		else:

			var pin: int = vert.call(0, i, i)
			var pout: int = vert.call(1, i, i)
			_add_face_oriented(data, PackedInt32Array([pin, pout, tout0, tin0]), -tangent)

	var ae: float = arc
	var end_tangent := Vector3(-sin(ae), 0.0, cos(ae))
	_add_face_oriented(data, PackedInt32Array([
		vert.call(0, steps, 0), vert.call(1, steps, 0),
		vert.call(1, steps, steps), vert.call(0, steps, steps),
	]), end_tangent)
	return data


## Prism over an arbitrary polygon: base at y=0, cap at y=height. Points are
## (x, z); either winding is accepted, concave outlines are fine (Poly Shape).
static func make_polygon_prism(points: PackedVector2Array, height := 1.0) -> UBMeshData:
	var data := UBMeshData.new()

	var pts := dedupe_loop(points, true)
	if pts.size() < 3:
		return data
	if _signed_area(pts) < 0.0:
		pts = pts.duplicate()
		pts.reverse()
	var n := pts.size()
	for p in pts:
		data.add_vertex(Vector3(p.x, 0, p.y))
	for p in pts:
		data.add_vertex(Vector3(p.x, height, p.y))
	var top := PackedInt32Array()
	for i in n:
		top.append(n + i)
	data.add_face(top)
	var bottom := PackedInt32Array()
	for i in range(n - 1, -1, -1):
		bottom.append(i)
	data.add_face(bottom)
	for i in n:
		var j := (i + 1) % n
		data.add_face(PackedInt32Array([i, j, n + j, n + i]))
	return data


## Drop consecutive points within `tol` of the one before (a double click),
## and with `closed` a last point repeating the first.
static func dedupe_loop(points: PackedVector2Array, closed: bool, tol := 1e-4) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > tol:
			out.append(p)
	if closed and out.size() > 1 and out[0].distance_to(out[out.size() - 1]) <= tol:
		out.remove_at(out.size() - 1)
	return out


static func _signed_area(pts: PackedVector2Array) -> float:
	if pts.is_empty():
		return 0.0

	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= pts.size()
	var area := 0.0
	for i in pts.size():
		var a := pts[i] - c
		var b := pts[(i + 1) % pts.size()] - c
		area += a.x * b.y - b.x * a.y
	return area * 0.5


## Cross-sections for make_trim, named for the mouldings they make as a
## skirting (Upside Down turns each into its cornice twin).
enum TrimProfile { FLAT, CHAMFER, ROUND, COVE, OGEE, STEPPED }


## The (out, up) cross-section of a trim strip filling depth x height: its flat
## back along out = 0 (the wall), its bottom along up = 0 (the floor). FLAT is a
## plain board; CHAMFER cuts the top outer corner at 45 degrees; ROUND puts a
## quarter round there; COVE hollows the whole face into a concave quarter arc
## from the wall top to the toe; OGEE runs an S over the top part (convex out
## from the wall, concave down onto the face); STEPPED is two boards, the upper
## one half as deep. Curves take `segs` segments and are tagged as arcs so
## make_trim can smooth them. Returns {"pts", "arcs"} in the _stairs_profile
## convention.
static func trim_profile(profile: int, depth: float, height: float, segs: int) -> Dictionary:
	var d := maxf(depth, 1e-4)
	var h := maxf(height, 1e-4)
	segs = clampi(segs, 1, 32)
	var pts: Array = []
	var arcs: Array = []
	_prof_append(pts, arcs, Vector2(0.0, 0.0), -1)
	_prof_append(pts, arcs, Vector2(0.0, h), -1)
	match profile:
		TrimProfile.CHAMFER:
			var c := minf(d, h * 0.5)
			_prof_append(pts, arcs, Vector2(d - c, h), -1)
			_prof_append(pts, arcs, Vector2(d, h - c), -1)
		TrimProfile.ROUND:
			var r := minf(d, h * 0.5)
			for k in segs + 1:
				var t := (PI * 0.5) * float(k) / segs
				_prof_append(pts, arcs, Vector2(d - r + r * sin(t), h - r + r * cos(t)), 0)
		TrimProfile.COVE:
			for k in segs + 1:
				var t := (PI * 0.5) * float(k) / segs
				_prof_append(pts, arcs, Vector2(d - d * cos(t), h - h * sin(t)), 0)
		TrimProfile.OGEE:

			var k := minf(h * 0.5, d * 1.5)
			var mx := d * 0.5
			var my := h - k * 0.5
			for i in segs + 1:
				var t := (PI * 0.5) * float(i) / segs
				_prof_append(pts, arcs, Vector2(mx * sin(t), my + k * 0.5 * cos(t)), 0)
			for i in segs + 1:
				var t := (PI * 0.5) * float(i) / segs
				_prof_append(pts, arcs, Vector2(d - mx * cos(t), my - k * 0.5 * sin(t)), 1)
		TrimProfile.STEPPED:
			_prof_append(pts, arcs, Vector2(d * 0.5, h), -1)
			_prof_append(pts, arcs, Vector2(d * 0.5, h * 0.6), -1)
			_prof_append(pts, arcs, Vector2(d, h * 0.6), -1)
		_:
			_prof_append(pts, arcs, Vector2(d, h), -1)
	_prof_append(pts, arcs, Vector2(d, 0.0), -1)
	return {"pts": pts, "arcs": arcs}


## A moulding strip (skirting, dado, cornice): `profile` (TrimProfile) depth x
## height, run `length` along local Z and centred on it, standing on the
## drawing plane y = 0. `across` (along local X) is the drawn extent the shape
## tool uses as the height gauge; the depth is typed or remembered.
## `upright` (drawn on a wall): up runs along X from the -across/2 edge (from
## +across/2, downward, with `flip`) and the depth along +Y off the wall, whose
## face is the plane. Otherwise (drawn on a floor): up is +Y from the floor and
## the depth runs along X from the -across/2 edge (from +across/2 with `flip`),
## the wall being that edge. `invert` turns the profile upside down within its
## height. The strip is anchored at the plane and one edge rather than centred,
## so Depth and Height can be retyped without it leaving its wall. `smooth`
## groups the curved faces.
static func make_trim(length: float, across: float, depth: float, height: float, profile: int,
		segs: int, upright: bool, flip: bool, invert: bool, smooth: bool) -> UBMeshData:
	var prof := trim_profile(profile, depth, height, segs)
	var x0 := -across * 0.5
	var x1 := across * 0.5
	var mapped: Array = []
	for p: Vector2 in prof.pts:
		var a: float = p.x
		var b: float = p.y
		if invert:
			b = maxf(height, 1e-4) - b
		if upright:
			mapped.append(Vector2(x1 - b if flip else x0 + b, a))
		else:
			mapped.append(Vector2(x1 - a if flip else x0 + a, b))
	var data := UBMeshData.new()
	var cache := {}

	_emit_profile_solid(data, cache, _FRAME_TURN, -length * 0.5, length * 0.5,
		{"pts": mapped, "arcs": prof.arcs}, [], smooth)
	return data


## A trim profile swept along a wall-base path with mitred corners (UBTrimPath
## builds the path). `points` are the corners in order, `normals` one
## horizontal room-facing normal per segment (points.size() - 1 open,
## points.size() closed), `up` the wall direction. At each corner the profile
## ring sits on the intersection of the two neighbouring walls' offset lines
## (a point `a` out from the wall lands at corner + a * (n0 + n1) / (1 + n0.n1)),
## so any angle, inside or outside, joins with no gap. Open paths get square end
## caps; a closed path wraps. `hang` puts the profile's up downward, for a
## strip along a wall's top edge (a cornice); `invert` mirrors within the
## height; `offset` slides the strip along `up`; `out_offset` slides the
## profile along the normals (a wall centred on its line is a FLAT profile at
## out_offset = -thickness / 2). With `bake_uvs` the UVs are manual and
## continuous, U the distance along the path and V the distance around the
## profile, so a texture runs round the corners unbroken. Without it the faces
## stay on auto projection, which a wall wants so its sides measure V as height
## above the base like a cube's.
static func make_trim_path(points: PackedVector3Array, normals: PackedVector3Array, closed: bool,
		up: Vector3, depth: float, height: float, profile: int, segs: int, hang: bool,
		invert: bool, offset: float, smooth: bool, out_offset := 0.0, bake_uvs := true) -> UBMeshData:
	var data := UBMeshData.new()
	var n := points.size()
	var seg_count := n if closed else n - 1
	if n < 2 or normals.size() < seg_count:
		return data
	var prof := trim_profile(profile, depth, height, segs)
	var pts: Array = prof.pts.duplicate()
	var arcs: Array = prof.arcs.duplicate()
	if _signed_area(PackedVector2Array(pts)) < 0.0:
		pts.reverse()
		arcs.reverse()
	var h := maxf(height, 1e-4)
	var count := pts.size()

	var vs := PackedFloat32Array()
	var v_acc := 0.0
	for k in count:
		vs.append(v_acc)
		v_acc += (pts[(k + 1) % count] as Vector2).distance_to(pts[k])

	var rings: Array = []
	var uv_of := {}
	var u_acc := 0.0
	for i in n:
		var m: Vector3
		if closed or (i > 0 and i < n - 1):
			var n0: Vector3 = normals[(i - 1 + seg_count) % seg_count]
			var n1: Vector3 = normals[i % seg_count]
			var d := 1.0 + n0.dot(n1)
			m = (n0 + n1) / d if d > 1e-4 else n1
		elif i == 0:
			m = normals[0]
		else:
			m = normals[seg_count - 1]
		if i > 0:
			u_acc += points[i].distance_to(points[i - 1])
		var ring := PackedInt32Array()
		for k in count:
			var p: Vector2 = pts[k]
			var b: float = (h - p.y) if invert else p.y
			if hang:
				b = -b
			var vid := data.add_vertex(points[i] + m * (p.x + out_offset) + up * (b + offset))
			ring.append(vid)
			uv_of[vid] = Vector2(u_acc, vs[k])
		rings.append(ring)

	var b_sign := (-1.0 if invert else 1.0) * (-1.0 if hang else 1.0)
	for i in seg_count:
		var r0: PackedInt32Array = rings[i]
		var r1: PackedInt32Array = rings[(i + 1) % n]
		var side: Vector3 = normals[i]
		var wrap_u := 0.0
		if closed and i == seg_count - 1:

			wrap_u = u_acc + points[0].distance_to(points[n - 1])
		for k in count:
			var k2 := (k + 1) % count
			var e: Vector2 = pts[k2] - pts[k]
			var outward := side * e.y + up * (-e.x * b_sign)
			var face := _add_face_oriented(data, PackedInt32Array([r0[k], r0[k2], r1[k2], r1[k]]), outward)
			if smooth and _share_arc(arcs[k], arcs[k2]):
				face.smoothing_group = 1
			if not bake_uvs:
				continue
			var coords := PackedVector2Array()
			for vid in face.vertices:
				var uv: Vector2 = uv_of[vid]
				if wrap_u > 0.0 and (vid == r1[k] or vid == r1[k2]):
					uv.x = wrap_u

				if k2 == 0 and (vid == r0[k2] or vid == r1[k2]):
					uv.y = v_acc
				coords.append(uv)
			face.uv_manual = true
			face.uv_coords = coords
	if not closed:
		var d0 := (points[1] - points[0]).normalized()
		var d1 := (points[n - 1] - points[n - 2]).normalized()
		_add_face_oriented(data, rings[0], -d0)
		_add_face_oriented(data, rings[n - 1], d1)

	if bake_uvs and data.faces.size() > 0 and _uv_area(data.faces[0]) < 0.0:
		for f in data.faces:
			if not f.uv_manual:
				continue
			var c := f.uv_coords
			for k in c.size():
				c[k].y = v_acc - c[k].y
			f.uv_coords = c
	return data


static func _uv_area(face: UBFace) -> float:
	var c := face.uv_coords
	var area := 0.0
	for i in c.size():
		area += c[i].cross(c[(i + 1) % c.size()])
	return area * 0.5
