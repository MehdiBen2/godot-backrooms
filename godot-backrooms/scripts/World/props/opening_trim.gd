extends RefCounted
## The joinery round an opening in a wall of the graph (wall_openings.gd): the lining boards on its reveals (the
## jambs, the head, a window's sill) and the casing (architrave) round it on the faces of the wall, a window's
## stool (the board it stands on, proud of the wall) and apron under that. Built from the hole as wall_mesh.gd cut
## it, so it follows a curved wall and a round head exactly. World coordinates (the level's frame), one mesh: the
## painted trim material (level_geometry.gd door_frame_mat).

const Geom := preload("res://scripts/World/level/walls/wall_geom.gd")
const Openings := preload("res://scripts/World/level/walls/wall_openings.gd")

## `h`: the hole as cut (wall_mesh.gd build().holes: ts, l, r, ...), `cv`: its wall's centre line (metres).
## `opts`: lining (board thickness, 0: none), casing_w / casing_d (the casing's width and how far it stands out,
## 0: none), faces (["l", "r"]: which faces get casing), stool (a window's: how far it stands out, 0: none).
static func build(h: Dictionary, cv: Dictionary, opts: Dictionary) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)                  # (flat: boards have crisp edges)
	var ts: Array = h.ts
	var n := ts.size()
	var l: PackedVector2Array = h.l
	var r: PackedVector2Array = h.r
	var tops: Array[float] = []
	var bots: Array[float] = []
	for t: float in ts:
		tops.append(Openings.top_at(h, t))
		bots.append(Openings.bottom_at(h, t))
	var mid_t := (float(h.t0) + float(h.t1)) * 0.5
	var spring := Openings.spring_of(h)
	var round: bool = h["round"]
	var disc: bool = h.get("disc", false)
	var lin := float(opts.get("lining", 0.0))
	var cw := float(opts.get("casing_w", 0.0))
	var cd := float(opts.get("casing_d", 0.0))
	var p3 := func(p: Vector2, y: float) -> Vector3: return Vector3(p.x, y, p.y)
	var tan3 := func(t: float) -> Vector3:
		var d := Geom.tangent(cv, t)
		return Vector3(d.x, 0.0, d.y)
	# in towards the middle of the opening from a point on its edge (the head: down, the sill: up, a jamb: across)
	var inward := func(i: int, top: bool) -> Vector3:
		if not round or (not top and not disc): return Vector3.DOWN if top else Vector3.UP
		var c := Geom.point(cv, mid_t)
		var d: Vector3 = tan3.call(ts[i])
		var p: Vector2 = l[i]
		var v := d * d.dot(Vector3(c.x - p.x, 0.0, c.y - p.y)) + Vector3(0.0, spring - (tops[i] if top else bots[i]), 0.0)
		return v.normalized() if v.length() > 1e-6 else (Vector3.DOWN if top else Vector3.UP)
	# ---- the lining: boards over the jambs, under the head, on the sill
	if lin > 0.0:
		for k: int in [0, n - 1]:
			if tops[k] - bots[k] < 0.02: continue
			var into: Vector3 = tan3.call(ts[k]) * (1.0 if k == 0 else -1.0)
			var a: Vector3 = p3.call(l[k], 0.0)
			var b: Vector3 = p3.call(r[k], 0.0)
			_hexa(st, [a + Vector3(0, bots[k], 0), b + Vector3(0, bots[k], 0), b + into * lin + Vector3(0, bots[k], 0), a + into * lin + Vector3(0, bots[k], 0)],
				[a + Vector3(0, tops[k], 0), b + Vector3(0, tops[k], 0), b + into * lin + Vector3(0, tops[k], 0), a + into * lin + Vector3(0, tops[k], 0)])
		for i in n - 1:
			for top: bool in [true, false]:
				if not top and float(h.y0) < 0.01: continue          # (a door's: the floor)
				var ya: float = tops[i] if top else bots[i]
				var yb: float = tops[i + 1] if top else bots[i + 1]
				var ia: Vector3 = inward.call(i, top) * lin
				var ib: Vector3 = inward.call(i + 1, top) * lin
				var la: Vector3 = p3.call(l[i], ya)
				var lb: Vector3 = p3.call(l[i + 1], yb)
				var rb: Vector3 = p3.call(r[i + 1], yb)
				var ra: Vector3 = p3.call(r[i], ya)
				_hexa(st, [la, lb, rb, ra], [la + ia, lb + ib, rb + ib, ra + ia])
	# ---- the casing round it on each face
	for side: String in opts.get("faces", []):
		if cw <= 0.0: break
		var face: PackedVector2Array = l if side == "l" else r
		var sgn := 1.0 if side == "l" else -1.0
		var out_of := func(i: int) -> Vector3:            # the face's outward normal at sample i
			var nn := Geom.normal(cv, ts[i]) * sgn
			return Vector3(nn.x, 0.0, nn.y)
		var under := cw if float(opts.get("stool", 0.0)) > 0.0 else 0.0     # a window's casing runs on down to the apron
		if not disc:
			for k: int in [0, n - 1]:
				var away: Vector3 = tan3.call(ts[k]) * (-1.0 if k == 0 else 1.0)
				var o: Vector3 = out_of.call(k) * cd
				var a: Vector3 = p3.call(face[k], 0.0)
				var y0 := maxf(bots[k] - under, 0.0)
				var y1: float = tops[k] + (0.0 if round else cw)
				_hexa(st, [a + Vector3(0, y0, 0), a + away * cw + Vector3(0, y0, 0), a + away * cw + o + Vector3(0, y0, 0), a + o + Vector3(0, y0, 0)],
					[a + Vector3(0, y1, 0), a + away * cw + Vector3(0, y1, 0), a + away * cw + o + Vector3(0, y1, 0), a + o + Vector3(0, y1, 0)])
		# across the head (round: a band round it), and a porthole's bottom
		for top: bool in ([true, false] if disc else [true]):
			for i in n - 1:
				var ya: float = tops[i] if top else bots[i]
				var yb: float = tops[i + 1] if top else bots[i + 1]
				var a: Vector3 = p3.call(face[i], ya)
				var b: Vector3 = p3.call(face[i + 1], yb)
				var ua: Vector3 = -inward.call(i, top) * cw
				var ub: Vector3 = -inward.call(i + 1, top) * cw
				var oa: Vector3 = out_of.call(i) * cd
				var ob: Vector3 = out_of.call(i + 1) * cd
				_hexa(st, [a, b, b + ob, a + oa], [a + ua, b + ub, b + ub + ob, a + ua + oa])
		# a window's stool (proud of the face, past the casing at both ends) and the apron under it
		var stool := float(opts.get("stool", 0.0))
		if stool > 0.0 and not disc:
			var y := float(h.y0)
			var a0: Vector3 = p3.call(face[0], 0.0) - tan3.call(ts[0]) * (cw + 0.03)
			var a1: Vector3 = p3.call(face[n - 1], 0.0) + tan3.call(ts[n - 1]) * (cw + 0.03)
			var pts: Array = [a0]
			for i in n: pts.append(p3.call(face[i], 0.0))
			pts.append(a1)
			for i in pts.size() - 1:
				var j := clampi(i - 1, 0, n - 1)
				var jj := clampi(i, 0, n - 1)
				var oa: Vector3 = out_of.call(j) * stool
				var ob: Vector3 = out_of.call(jj) * stool
				# (back into the reveal as far as the lining: the board the window stands on)
				var ba: Vector3 = -out_of.call(j) * lin * 2.0
				var bb: Vector3 = -out_of.call(jj) * lin * 2.0
				var pa: Vector3 = pts[i]
				var pb: Vector3 = pts[i + 1]
				var lo := Vector3(0, y - 0.035, 0)
				var hi := Vector3(0, y + lin * 0.5, 0)
				_hexa(st, [pa + ba + lo, pb + bb + lo, pb + ob + lo, pa + oa + lo], [pa + ba + hi, pb + bb + hi, pb + ob + hi, pa + oa + hi])
	st.generate_normals()
	return st.commit()

## A six-sided block from its four bottom corners and the four top corners over them, every face out
static func _hexa(st: SurfaceTool, bot: Array, top: Array) -> void:
	var c := Vector3.ZERO
	for p: Vector3 in bot + top: c += p
	c /= 8.0
	var faces := [[bot[0], bot[1], bot[2], bot[3]], [top[0], top[1], top[2], top[3]]]
	for i in 4:
		var j := (i + 1) % 4
		faces.append([bot[i], bot[j], top[j], top[i]])
	for f: Array in faces:
		var a: Vector3 = f[0]
		var b: Vector3 = f[1]
		var cc: Vector3 = f[2]
		var d: Vector3 = f[3]
		var nrm := (cc - a).cross(d - b)
		if nrm.length() < 1e-10: continue
		var m := (a + b + cc + d) * 0.25
		# Godot's front faces are clockwise seen from outside
		var order := [a, b, cc, a, cc, d]
		if nrm.dot(m - c) > 0.0: order = [a, cc, b, a, d, cc]
		for v: Vector3 in order:
			st.set_uv(Vector2(v.x + v.z, v.y))
			st.add_vertex(v)
