extends Node3D
## A floor's pipework: the level editor's pipe runs ("pipe", drawn point by point) and risers ("pipe_riser", straight
## up), built together so they join up as a real system would (level_geometry.gd _build_pipes).
##  - A run is a tube swept along its points, its corners real bends (a bend radius of three pipe radii, less where
##    a leg is short). "count" pipes run side by side ("stack": "side") or one over another ("up"), "gap" apart.
##  - It hangs from the ceiling ("hang": "ceiling", "drop" metres under it, on rods and clamps), stands on the
##    floor (on saddle stands) or is held at "elev" metres up (on nothing: along a wall, say).
##  - Where a run's end meets another pipe it is joined, not left overlapping: end to end in line, a coupling; end to
##    end at an angle, an elbow; end into the side of a pipe, a tee with a sleeve round the pipe it joins; into a
##    riser, the same. An end that meets nothing is closed with a blind flange.
##  - Flanges every few metres along the straights, as long runs are made of lengths bolted together.
##  - Only what you can walk into is solid: pipes low enough to bump into, risers, floor stands.

const CELL := 4.5
const SIDES := 14                  # round a pipe
const FLANGE_EVERY := 3.0          # m along a straight between flange pairs
const SUPPORT_EVERY := 2.2         # m between hangers / stands
const JOIN_SLACK := 0.12           # m beyond touching that still counts as meeting
const HEAD_ROOM := 2.0             # pipes whose underside is below this are solid
const PBR := {"rust": "Metal_Rusted", "steel": "Metal_Grey_Plate", "dark": "Metal_Dark_Plate"}
const PAINT := {"green": Color(0.24, 0.36, 0.24), "red": Color(0.55, 0.12, 0.1), "yellow": Color(0.78, 0.6, 0.12),
	"blue": Color(0.16, 0.27, 0.45), "white": Color(0.82, 0.82, 0.78), "grey": Color(0.42, 0.43, 0.44)}

static var _mats := {}

var _st := {}                      # material key -> SurfaceTool
var _lines: Array = []             # each pipe of each run: {pts: PackedVector3Array (m), r, mat, hang, top (ceiling), cap: [start, end]}
var _risers: Array = []            # {at: Vector3 (bottom), y1, r, mat}
var _solid: Array = []             # [Transform3D, size] boxes to collide with
var _collide := true
var _ports: Array = []            # pipe props' openings: {pos, dir (out of it), r} (level_geometry.gd _pipe_ports)
var _runs := 0                     # runs added so far: the pipes of one run (a bundle) never join each other

## `pipes` / `risers`: their objects; `xf_of`: an object's transform (level_data.object_transform); `ceil_at`: the
## ceiling height (m) over a point. `collide`: false for a look-only copy of another floor.
func build(pipes: Array, risers: Array, xf_of: Callable, ceil_at: Callable, collide := true, ports: Array = []) -> void:
	_collide = collide
	_ports = ports
	for o: Dictionary in risers:
		var at: Vector3 = (xf_of.call(o) as Transform3D).origin
		var r := clampf(float(o.get("diameter", 0.3)), 0.04, 2.0) * 0.5
		var top := float(o.get("to", 0.0))
		var y1: float = float(ceil_at.call(at)) - 0.02 if top <= 0.0 else top
		_risers.append({"at": Vector3(at.x, maxf(float(o.get("from", 0.0)), 0.0), at.z), "y1": y1, "r": r, "mat": str(o.get("material", "rust"))})
	for o: Dictionary in pipes:
		_add_run(o, xf_of.call(o), ceil_at)
	_join()
	for l: Dictionary in _lines: _build_line(l)
	for rs: Dictionary in _risers: _build_riser(rs)
	_commit()

# ---------------------------------------------------------------- runs -> lines
func _add_run(o: Dictionary, xf: Transform3D, ceil_at: Callable) -> void:
	var raw = o.get("points", [])
	var plan := PackedVector3Array()
	if raw is Array:
		for q in raw:
			if q is Array and q.size() >= 2:
				var p: Vector3 = xf * (Vector3(float(q[0]), 0.0, float(q[1])) * CELL)
				if plan.is_empty() or plan[plan.size() - 1].distance_to(p) > 0.02: plan.append(p)
	if plan.size() < 2: return
	var r := clampf(float(o.get("diameter", 0.3)), 0.04, 2.0) * 0.5
	var count := clampi(int(o.get("count", 1)), 1, 8)
	var gap := maxf(float(o.get("gap", 0.08)), 0.0)
	var pitch := r * 2.0 + gap
	var hang := str(o.get("hang", "ceiling"))
	var ceiling := INF
	for p in plan: ceiling = minf(ceiling, float(ceil_at.call(p)))
	var y: float
	match hang:
		"floor": y = r + 0.12                                    # on stands a hand's height off the floor
		"elev": y = maxf(float(o.get("elev", 1.0)), 0.0) + r
		_: y = ceiling - maxf(float(o.get("drop", 0.45)), r + 0.05)
	var up := str(o.get("stack", "side")) == "up"
	for k in count:
		var s := (k - (count - 1) * 0.5) * pitch
		var pts := PackedVector3Array()
		if up:
			# one over another: a ceiling rack hangs down from the top pipe, a floor rack builds up from the bottom one
			var dy := -k * pitch if hang == "ceiling" else k * pitch
			for p in plan: pts.append(Vector3(p.x, y + dy, p.z))
		else:
			pts = _offset(plan, s, y)
		_lines.append({"pts": pts, "r": r, "mat": str(o.get("material", "rust")), "hang": hang, "top": ceiling,
			"flanges": bool(o.get("flanges", true)), "style": str(o.get("style", "tube")), "cap": [true, true], "run": _runs, "tees": [], "valves": clampi(int(o.get("valves", 0)), 0, 12) if k == 0 or not up else 0})
	_runs += 1

## A plan line moved `s` metres sideways (left of its way), at height y: corners mitred so the runs stay parallel
func _offset(plan: PackedVector3Array, s: float, y: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := plan.size()
	for i in n:
		var d0 := (plan[i] - plan[i - 1]).normalized() if i > 0 else Vector3.ZERO
		var d1 := (plan[i + 1] - plan[i]).normalized() if i < n - 1 else Vector3.ZERO
		var side := Vector3.ZERO
		if d0 != Vector3.ZERO: side += Vector3(-d0.z, 0, d0.x)
		if d1 != Vector3.ZERO: side += Vector3(-d1.z, 0, d1.x)
		side = side.normalized()
		var ref := Vector3(-d1.z, 0, d1.x) if d1 != Vector3.ZERO else Vector3(-d0.z, 0, d0.x)
		var k := 1.0 / maxf(side.dot(ref), 0.35)
		var p := plan[i] + side * s * k
		out.append(Vector3(p.x, y, p.z))
	return out

# ---------------------------------------------------------------- joining
## Every run end that meets something is made to meet it properly (and loses its blind flange)
func _join() -> void:
	for li in _lines.size():
		var l: Dictionary = _lines[li]
		for end in [0, 1]:
			if not (l.cap as Array)[end]: continue          # (already joined from the other pipe's side)
			var pts: PackedVector3Array = l.pts
			var i := 0 if end == 0 else pts.size() - 1
			var e := pts[i]
			var out := (e - pts[1 if end == 0 else pts.size() - 2]).normalized()
			if _join_port(l, end, i, e, out): continue
			if _join_riser(l, end, i, e): continue
			_join_line(li, end, i, e, out)

## A run end at the opening of a pipe prop (Pipe section, elbow, tee, Rusty pipes: object_types.json "ports").
## An opening facing the run's way: a coupling; facing up or down: the run comes in over (under) it on a short
## stub and an elbow, as the level editor lifts the run to (level_editor_canvas.gd _pipe_attach).
func _join_port(l: Dictionary, end: int, i: int, e: Vector3, out: Vector3) -> bool:
	var r := float(l.r)
	for pt: Dictionary in _ports:
		var pos: Vector3 = pt.pos
		var dir: Vector3 = pt.dir
		var pts: PackedVector3Array = l.pts
		if absf(dir.y) > 0.5:
			var flat := Vector2(e.x - pos.x, e.z - pos.z).length()
			var dy := (e.y - pos.y) * signf(dir.y)
			if flat > float(pt.r) + r + JOIN_SLACK or dy < -0.05 or dy > r * 4.0 + 0.3: continue
			var at := Vector3(pos.x, e.y, pos.z)
			pts[i] = at
			l.pts = pts
			(l.cap as Array)[end] = false
			if at.distance_to(pos) > 0.02: _cyl(pos, at, r, l.mat, false)
			_ball(at, r * 1.3, l.mat)
			return true
		if e.distance_to(pos) > float(pt.r) + r + JOIN_SLACK: continue
		pts[i] = pos
		l.pts = pts
		(l.cap as Array)[end] = false
		if out.dot(-dir) > 0.96: _coupling(pos, out, r, l.mat)
		else: _ball(pos, r * 1.3, l.mat)
		return true
	return false

func _join_riser(l: Dictionary, end: int, i: int, e: Vector3) -> bool:
	for rs: Dictionary in _risers:
		var a: Vector3 = rs.at
		var flat := Vector2(e.x - a.x, e.z - a.z).length()
		if flat > float(l.r) + float(rs.r) + JOIN_SLACK: continue
		if e.y < a.y - float(l.r) or e.y > float(rs.y1) + float(l.r): continue
		var pts: PackedVector3Array = l.pts
		pts[i] = Vector3(a.x, e.y, a.z)                   # into the riser's axis
		l.pts = pts
		(l.cap as Array)[end] = false
		var at_end := absf(e.y - float(rs.y1)) < float(l.r) * 2.0 or absf(e.y - a.y) < float(l.r) * 2.0
		if at_end:
			# the riser turns into the run: an elbow, the riser cut to meet it
			if absf(e.y - float(rs.y1)) < absf(e.y - a.y): rs.y1 = e.y
			else: rs.at = Vector3(a.x, e.y, a.z)
			_ball(pts[i], maxf(float(l.r), float(rs.r)) * 1.25, l.mat)
		else:
			_sleeve(Vector3(a.x, e.y, a.z), Vector3.UP, float(rs.r), rs.mat)
		return true
	return false

func _join_line(li: int, end: int, i: int, e: Vector3, out: Vector3) -> void:
	var l: Dictionary = _lines[li]
	var best := INF
	var hit := {}
	for mi in _lines.size():
		if mi == li: continue
		var m: Dictionary = _lines[mi]
		if int(m.run) == int(l.run): continue               # its own bundle: side by side, not joined
		var mp: PackedVector3Array = m.pts
		for k in mp.size() - 1:
			var q := Geometry3D.get_closest_point_to_segment(e, mp[k], mp[k + 1])
			var d := e.distance_to(q)
			if d < best:
				best = d
				hit = {"m": m, "q": q, "k": k}
	if hit.is_empty() or best > float(l.r) + float((hit.m as Dictionary).r) + JOIN_SLACK: return
	var m: Dictionary = hit.m
	var mp: PackedVector3Array = m.pts
	var q: Vector3 = hit.q
	var pts: PackedVector3Array = l.pts
	(l.cap as Array)[end] = false
	var r := maxf(float(l.r), float(m.r))
	# end to end?
	for mend in [0, 1]:
		var j := 0 if mend == 0 else mp.size() - 1
		if q.distance_to(mp[j]) < r * 2.0:
			var m_out := (mp[j] - mp[1 if mend == 0 else mp.size() - 2]).normalized()
			pts[i] = mp[j]
			l.pts = pts
			(m.cap as Array)[mend] = false
			if out.dot(-m_out) > 0.96:
				_coupling(mp[j], out, r, l.mat)                # straight on: two flanges bolted face to face
			else:
				_ball(mp[j], r * 1.3, l.mat)                    # at an angle: an elbow
			return
	# into its side: a tee
	pts[i] = q
	l.pts = pts
	var along := (mp[hit.k + 1] - mp[hit.k]).normalized()
	if str(m.get("style", "tube")) == "pack" and absf(out.dot(along)) < 0.05:
		# a pack-pipe run: the pack's own tee goes in it here (its straights are cut round it), else a sleeve
		var branch := -out - along * (-out).dot(along)
		(m.tees as Array).append({"k": hit.k, "q": q, "along": along, "branch": branch.normalized()})
	else:
		_sleeve(q, along, float(m.r), m.mat)

# ---------------------------------------------------------------- one pipe
func _build_line(l: Dictionary) -> void:
	var r: float = l.r
	var raw: PackedVector3Array = l.pts
	var path := _bent(raw, r * 3.0)
	var packed := str(l.get("style", "tube")) == "pack" and _pack_line(l)
	if not packed:
		_tube(path, r, l.mat)
		for t: Dictionary in l.tees: _sleeve(t.q, t.along, r, l.mat)
	var caps: Array = l.cap
	var n := raw.size()
	for end in [0, 1]:
		if not caps[end]: continue
		var e := raw[0] if end == 0 else raw[n - 1]
		var out := (raw[0] - raw[1]).normalized() if end == 0 else (raw[n - 1] - raw[n - 2]).normalized()
		_cyl(e - out * 0.03, e + out * 0.02, r * 1.35, l.mat, true)       # a blind flange
	# along each straight leg: flange pairs every few metres, and its hangers or stands
	for k in n - 1:
		var a := raw[k]
		var b := raw[k + 1]
		var run := b - a
		var seg_len := run.length()
		if seg_len < 0.05: continue
		var d := run / seg_len
		var clear := r * 3.5                                     # (keep clear of the bends)
		if bool(l.flanges) and not packed and seg_len > FLANGE_EVERY:
			var f := FLANGE_EVERY
			while f < seg_len - clear:
				_coupling(a + d * f, d, r, l.mat)
				f += FLANGE_EVERY
		var supports := maxi(1, int(seg_len / SUPPORT_EVERY))
		for s in supports:
			var at := a + d * (seg_len * (s + 0.5) / supports)
			match str(l.hang):
				"ceiling": _hanger(at, d, r, float(l.top))
				"floor": _stand(at, d, r)
		if at_head(a, b, r):
			_solid_box(a, b, r)
	_valves(l)

## "valves" hand-wheel gate valves spread along the run's straights (kept clear of its bends): a flanged body in
## the pipe, a stem and a red wheel on the side you reach it from (under a high pipe, over a low one)
func _valves(l: Dictionary) -> void:
	var count: int = l.valves
	if count <= 0: return
	var raw: PackedVector3Array = l.pts
	var r: float = l.r
	var clear := r * 4.5
	var total := 0.0
	var spans: Array = []                                   # [a, d, usable length]
	for k in raw.size() - 1:
		var seg := raw[k + 1] - raw[k]
		var use := seg.length() - clear * 2.0
		if use <= 0.0: continue
		spans.append([raw[k] + seg.normalized() * clear, seg.normalized(), use])
		total += use
	if total <= 0.0: return
	for v in count:
		var at := total * (v + 0.5) / count
		for sp: Array in spans:
			if at > float(sp[2]):
				at -= float(sp[2])
				continue
			var d: Vector3 = sp[1]
			var c: Vector3 = (sp[0] as Vector3) + d * at
			_cyl(c - d * r * 1.2, c + d * r * 1.2, r * 1.25, l.mat, true)          # the body
			_coupling(c - d * r * 1.2, d, r, l.mat)
			_coupling(c + d * r * 1.2, d, r, l.mat)
			var up := Vector3.DOWN if c.y > 1.7 else Vector3.UP
			if absf(d.dot(Vector3.UP)) > 0.9: up = d.cross(Vector3.RIGHT).normalized()
			var hub := c + up * r * 2.6
			_cyl(c + up * r * 1.1, hub, r * 0.16, l.mat, true)                     # the stem
			var a1 := d
			var a2 := up.cross(d).normalized()
			var wr := r * 1.4
			for k in 12:                                                             # the wheel's rim
				var t0 := TAU * k / 12.0
				var t1 := TAU * (k + 1) / 12.0
				_cyl(hub + (a1 * cos(t0) + a2 * sin(t0)) * wr, hub + (a1 * cos(t1) + a2 * sin(t1)) * wr, r * 0.1, "red", false)
			for k in 3:                                                              # and its spokes
				var t := TAU * k / 3.0
				_cyl(hub, hub + (a1 * cos(t) + a2 * sin(t)) * wr, r * 0.07, "red", false)
			break

# ---------------------------------------------------------------- the asset pack's pipe pieces
## "style": "pack" builds a run from the game's own flanged pipe models (industrial_asset_pack_free.glb): straight
## lengths, tiled and stretched a touch to fill each leg, and an elbow at every right-angle corner. Scaled to the
## run's diameter. Returns false (the run is drawn as plain tube instead) if a corner is not a right angle or a leg
## is too short to take its elbows.
const PACK_PATH := "res://models/props/asset_pack/industrial_asset_pack_free.glb"
const PACK_DIA := 1.54             # the pieces' own width (their units)
const PACK_LEN := 4.59             # a straight's own length
const PACK_LEG := 2.3              # an elbow's leg, corner to flange
static var _pack := {}             # "straight" / "elbow": {mesh, box}

static func _pack_piece(key: String) -> Dictionary:
	if _pack.is_empty():
		var scene := load(PACK_PATH) as PackedScene
		if scene != null:
			var inst := scene.instantiate()
			for n in inst.find_children("*", "MeshInstance3D", true, false):
				var mi := n as MeshInstance3D
				var nm := String(mi.name).replace(".", "_")
				var k := "straight" if nm.begins_with("Cylinder_001") else "elbow" if nm.begins_with("Cylinder_002") else "tee" if nm.begins_with("Cylinder_003") else ""
				if k != "" and mi.mesh != null and not _pack.has(k):
					_pack[k] = {"mesh": mi.mesh, "box": mi.mesh.get_aabb()}
			inst.free()
		_pack["loaded"] = true
	return _pack.get(key, {})

## The rotation taking the piece's frame (fa, fb) onto (ta, tb): both pairs perpendicular unit vectors
static func _align(fa: Vector3, fb: Vector3, ta: Vector3, tb: Vector3) -> Basis:
	return Basis(ta, tb, ta.cross(tb)) * Basis(fa, fb, fa.cross(fb)).transposed()

func _pack_line(l: Dictionary) -> bool:
	var straight := _pack_piece("straight")
	var elbow := _pack_piece("elbow")
	var tee := _pack_piece("tee")
	if straight.is_empty() or elbow.is_empty(): return false
	var raw: PackedVector3Array = l.pts
	var n := raw.size()
	var s := float(l.r) * 2.0 / PACK_DIA
	var leg := PACK_LEG * s
	# the elbow's two legs, found on its box: the axes it reaches out along from its corner at the origin
	var legs := _piece_legs(elbow.box)
	if legs.size() != 2: return false
	var dirs: Array[Vector3] = []
	for k in n - 1:
		dirs.append((raw[k + 1] - raw[k]).normalized())
	for k in n - 2:
		if absf(dirs[k].dot(dirs[k + 1])) > 0.01: return false
	# each leg: what is left of it between its elbows and round its tees (each needs a leg's length either side)
	var cuts: Array = []                                   # per leg: [[from, to], ...] (m along it) for straights
	for k in n - 1:
		var seg_len := raw[k].distance_to(raw[k + 1])
		var lo := leg if k > 0 else 0.0
		var hi := seg_len - (leg if k < n - 2 else 0.0)
		if hi - lo < -0.01: return false
		var at: Array[float] = []
		for t: Dictionary in l.tees:
			if int(t.k) == k: at.append(((t.q as Vector3) - raw[k]).dot(dirs[k]))
		at.sort()
		var spans: Array = []
		var from := lo
		for x in at:
			if tee.is_empty() or x - leg < from - 0.01 or x + leg > hi + 0.01: return false
			spans.append([from, x - leg])
			from = x + leg
		spans.append([from, hi])
		cuts.append(spans)
	# the elbows
	for k in range(1, n - 1):
		var rot := _align(legs[0], legs[1], -dirs[k - 1], dirs[k])
		_pack_add(elbow.mesh, Transform3D(rot * Basis.from_scale(Vector3.ONE * s), raw[k]))
	# the tees: through along the run, the branch out to the run that joins it
	if not (l.tees as Array).is_empty():
		var tl := _piece_legs(tee.box)
		var through := Vector3.ZERO
		var side := Vector3.ZERO
		for v in tl:
			if tl.has(-v): through = v.abs()
			else: side = v
		if through == Vector3.ZERO or side == Vector3.ZERO: return false
		for t: Dictionary in l.tees:
			var rot := _align(through, side, t.along, t.branch)
			_pack_add(tee.mesh, Transform3D(rot * Basis.from_scale(Vector3.ONE * s), t.q))
	# the straights
	for k in n - 1:
		for sp: Array in cuts[k]:
			_pack_straights(straight, raw[k] + dirs[k] * float(sp[0]), raw[k] + dirs[k] * float(sp[1]), dirs[k], s)
	return true

## The ends a fitting reaches out to from its middle (its origin), read off its box: the axes it reaches well past
## its own width along. Unit axes, signed.
static func _piece_legs(box: AABB) -> Array[Vector3]:
	var thr := minf(box.size.x, minf(box.size.y, box.size.z)) * 1.2
	var legs: Array[Vector3] = []
	for k in 3:
		var ax := Vector3.ZERO
		ax[k] = 1.0
		if box.end[k] > thr: legs.append(ax)
		if box.position[k] < -thr: legs.append(-ax)
	return legs

## Straight lengths from a to b (along d): as many as fit near their own length, stretched a touch to fill it
func _pack_straights(straight: Dictionary, a: Vector3, b: Vector3, d: Vector3, s: float) -> void:
	var span := a.distance_to(b)
	if span < 0.05: return
	var sb: AABB = straight.box
	var long := 0
	for k in 3:
		if sb.size[k] > sb.size[long]: long = k
	var axis := Vector3.ZERO
	axis[long] = 1.0
	var other := Vector3.ZERO
	other[(long + 1) % 3] = 1.0
	var pieces := maxi(1, roundi(span / (PACK_LEN * s)))
	var piece := span / pieces
	var perp := d.cross(Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT).normalized()
	var sv := Vector3.ONE * s
	sv[long] = piece / PACK_LEN
	var bs := _align(axis, other, d, perp) * Basis.from_scale(sv)
	for i in pieces:
		var mid := a + d * (piece * (i + 0.5))
		_pack_add(straight.mesh, Transform3D(bs, mid - bs * sb.get_center()))

func _pack_add(mesh: Mesh, xf: Transform3D) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = xf
	add_child(mi)

func at_head(a: Vector3, b: Vector3, r: float) -> bool:
	return minf(a.y, b.y) - r < HEAD_ROOM

func _build_riser(rs: Dictionary) -> void:
	var a: Vector3 = rs.at
	var r: float = rs.r
	var b := Vector3(a.x, rs.y1, a.z)
	if b.y - a.y < 0.05: return
	_cyl(a, b, r, rs.mat, false)
	if a.y < 0.05: _cyl(a, a + Vector3(0, 0.04, 0), r * 1.45, rs.mat, true)      # floor flange
	_cyl(b - Vector3(0, 0.04, 0), b, r * 1.45, rs.mat, true)                       # flange at the top
	var f := FLANGE_EVERY
	while f < b.y - a.y - 0.3:
		_coupling(a + Vector3(0, f, 0), Vector3.UP, r, rs.mat)
		f += FLANGE_EVERY
	_solid_box(a, b, r)

# ---------------------------------------------------------------- fittings and supports
## Two flanges face to face where lengths of pipe are bolted together, with their bolts
func _coupling(at: Vector3, d: Vector3, r: float, mat: String) -> void:
	_cyl(at - d * 0.035, at + d * 0.035, r * 1.32, mat, true)
	var side := d.cross(Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT).normalized()
	var up := d.cross(side).normalized()
	for k in 6:
		var a := TAU * k / 6.0
		var p := at + (side * cos(a) + up * sin(a)) * r * 1.18
		_cyl(p - d * 0.05, p + d * 0.05, maxf(r * 0.06, 0.008), "dark", true)

## A sleeve round a pipe where another joins its side (a tee), `d` the pipe's way
func _sleeve(at: Vector3, d: Vector3, r: float, mat: String) -> void:
	_cyl(at - d * r * 1.3, at + d * r * 1.3, r * 1.22, mat, true)

## Where hanging pipe meets ceiling: a rod up, a clamp round the pipe
func _hanger(at: Vector3, d: Vector3, r: float, ceiling: float) -> void:
	_cyl(at - d * 0.025, at + d * 0.025, r * 1.12, "dark", true)
	var top := at + Vector3(0, r, 0)
	if ceiling - top.y > 0.02:
		_cyl(top, Vector3(top.x, ceiling, top.z), maxf(r * 0.08, 0.01), "dark", true)

## A saddle stand under a floor pipe
func _stand(at: Vector3, d: Vector3, r: float) -> void:
	var h := at.y - r
	if h < 0.02: return
	var across := Vector3(-d.z, 0, d.x).normalized()
	var xf := Transform3D(Basis(across, Vector3.UP, across.cross(Vector3.UP)), Vector3(at.x, h * 0.5, at.z))
	_box(xf, Vector3(r * 2.4, h, 0.08), "dark")
	_cyl(at - d * 0.03, at + d * 0.03, r * 1.12, "dark", true)

# ---------------------------------------------------------------- geometry
## The line with its corners rounded: each turned through an arc of `bend` radius (less where a leg is short)
func _bent(pts: PackedVector3Array, bend: float) -> PackedVector3Array:
	var n := pts.size()
	if n < 3: return pts
	var out := PackedVector3Array([pts[0]])
	for i in range(1, n - 1):
		var p := pts[i]
		var a := (p - pts[i - 1]).normalized()
		var b := (pts[i + 1] - p).normalized()
		var turn := acos(clampf(a.dot(b), -1.0, 1.0))
		if turn < 0.02:
			out.append(p)
			continue
		var t := minf(bend * tan(turn * 0.5), 0.45 * minf(p.distance_to(pts[i - 1]), p.distance_to(pts[i + 1])))
		var rad := t / tan(turn * 0.5)
		var nrm := (b - a * a.dot(b)).normalized()
		var c := p - a * t + nrm * rad
		var steps := maxi(3, ceili(turn / deg_to_rad(12.0)))
		for s in steps + 1:
			var al := turn * s / steps
			out.append(c + (-nrm * cos(al) + a * sin(al)) * rad)
	out.append(pts[n - 1])
	return out

## A tube along `path`, `r` round, its ring turned along with it (no twist), open at both ends
func _tube(path: PackedVector3Array, r: float, mat: String) -> void:
	var n := path.size()
	if n < 2: return
	var st := _surface(mat)
	var t0 := (path[1] - path[0]).normalized()
	var nrm := t0.cross(Vector3.UP if absf(t0.y) < 0.9 else Vector3.RIGHT).normalized()
	var rings: Array = []
	var along := 0.0
	for i in n:
		var tan_i: Vector3
		if i == 0: tan_i = t0
		elif i == n - 1: tan_i = (path[i] - path[i - 1]).normalized()
		else: tan_i = ((path[i] - path[i - 1]).normalized() + (path[i + 1] - path[i]).normalized()).normalized()
		nrm = (nrm - tan_i * nrm.dot(tan_i)).normalized()
		var bi := tan_i.cross(nrm)
		if i > 0: along += path[i].distance_to(path[i - 1])
		var ring: Array = []
		for k in SIDES + 1:
			var a := TAU * k / SIDES
			var dir := nrm * cos(a) + bi * sin(a)
			ring.append([path[i] + dir * r, dir, Vector2(float(k) / SIDES, along / (TAU * r))])
		rings.append(ring)
	for i in n - 1:
		for k in SIDES:
			var a: Array = rings[i][k]
			var b: Array = rings[i][k + 1]
			var c: Array = rings[i + 1][k + 1]
			var d: Array = rings[i + 1][k]
			_tri(st, a, b, c)
			_tri(st, a, c, d)

## A closed cylinder from a to b
func _cyl(a: Vector3, b: Vector3, r: float, mat: String, caps: bool) -> void:
	_tube(PackedVector3Array([a, b]), r, mat)
	if not caps: return
	var st := _surface(mat)
	var d := (b - a).normalized()
	var side := d.cross(Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT).normalized()
	var up := d.cross(side).normalized()
	for end in [a, b]:
		var face := -d if end == a else d
		for k in SIDES:
			var a0 := TAU * k / SIDES
			var a1 := TAU * (k + 1) / SIDES
			var p0: Vector3 = end + (side * cos(a0) + up * sin(a0)) * r
			var p1: Vector3 = end + (side * cos(a1) + up * sin(a1)) * r
			if end == a: _tri(st, [end, face, Vector2(0.5, 0.5)], [p1, face, Vector2(0, 0)], [p0, face, Vector2(1, 0)])
			else: _tri(st, [end, face, Vector2(0.5, 0.5)], [p0, face, Vector2(0, 0)], [p1, face, Vector2(1, 0)])

## A cast fitting: an elbow's body where two pipes meet at an angle
func _ball(c: Vector3, r: float, mat: String) -> void:
	var st := _surface(mat)
	var rings := 8
	for i in rings:
		for k in SIDES:
			var v: Array = []
			for q in [[i, k], [i, k + 1], [i + 1, k + 1], [i + 1, k]]:
				var th := PI * float(q[0]) / rings
				var ph := TAU * float(q[1]) / SIDES
				var dir := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
				v.append([c + dir * r, dir, Vector2(float(q[1]) / SIDES, float(q[0]) / rings)])
			_tri(st, v[0], v[2], v[1])
			_tri(st, v[0], v[3], v[2])

func _box(xf: Transform3D, size: Vector3, mat: String) -> void:
	var st := _surface(mat)
	var h := size * 0.5
	for f in [[Vector3.RIGHT, Vector3.UP, Vector3.BACK], [Vector3.LEFT, Vector3.UP, Vector3.FORWARD], [Vector3.UP, Vector3.BACK, Vector3.RIGHT],
			[Vector3.DOWN, Vector3.FORWARD, Vector3.RIGHT], [Vector3.BACK, Vector3.UP, Vector3.LEFT], [Vector3.FORWARD, Vector3.UP, Vector3.RIGHT]]:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var w: Vector3 = f[2]
		var c := n * h
		var corners := [c - u * h - w * h, c - u * h + w * h, c + u * h + w * h, c + u * h - w * h]
		var wn := (xf.basis * n).normalized()
		var vs: Array = []
		for k in 4: vs.append([xf * (corners[k] as Vector3), wn, Vector2(k % 2, k / 2)])
		_tri(st, vs[0], vs[1], vs[2])
		_tri(st, vs[0], vs[2], vs[3])

## [position, normal, uv] x 3, wound so the face points the normals' way
func _tri(st: SurfaceTool, a: Array, b: Array, c: Array) -> void:
	var face := ((b[0] as Vector3) - (a[0] as Vector3)).cross((c[0] as Vector3) - (a[0] as Vector3))
	var order := [a, b, c] if face.dot(a[1] as Vector3) < 0.0 else [a, c, b]
	for v: Array in order:
		st.set_normal(v[1])
		st.set_uv(v[2])
		st.add_vertex(v[0])

func _solid_box(a: Vector3, b: Vector3, r: float) -> void:
	if not _collide: return
	var run := b - a
	var seg_len := run.length()
	if seg_len < 0.01: return
	var d := run / seg_len
	var side := d.cross(Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT).normalized()
	_solid.append([Transform3D(Basis(side, d.cross(side), d).orthonormalized(), (a + b) * 0.5), Vector3(r * 2.0, r * 2.0, seg_len)])

func _surface(mat: String) -> SurfaceTool:
	if not _st.has(mat):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[mat] = st
	return _st[mat]

func _commit() -> void:
	for key in _st:
		var mi := MeshInstance3D.new()
		mi.mesh = (_st[key] as SurfaceTool).commit()
		mi.material_override = material(key)
		add_child(mi)
	if _solid.is_empty(): return
	var body := StaticBody3D.new()
	for s: Array in _solid:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = s[1]
		cs.shape = bs
		cs.transform = s[0]
		body.add_child(cs)
	add_child(body)

## A pipe finish: the game's rusted / grey / dark metal (textures/pbr), or a coat of paint, or copper
static func material(key: String) -> Material:
	if _mats.has(key): return _mats[key]
	var m: StandardMaterial3D = null
	if PBR.has(key):
		var path := "res://textures/pbr/%s/%s.tres" % [PBR[key], PBR[key]]
		if ResourceLoader.exists(path):
			m = (load(path) as StandardMaterial3D).duplicate()
			m.uv1_triplanar = true
			m.uv1_world_triplanar = true
			m.uv1_scale = Vector3.ONE * 1.1
	if m == null:
		m = StandardMaterial3D.new()
		m.roughness = 0.55
		m.metallic = 0.35
		match key:
			"copper":
				m.albedo_color = Color(0.68, 0.4, 0.22)
				m.metallic = 0.9
				m.roughness = 0.38
			"rust": m.albedo_color = Color(0.42, 0.24, 0.14)
			"steel": m.albedo_color = Color(0.55, 0.56, 0.57)
			"dark": m.albedo_color = Color(0.16, 0.16, 0.17)
			_: m.albedo_color = PAINT.get(key, Color(0.5, 0.5, 0.5))
	_mats[key] = m
	return m
