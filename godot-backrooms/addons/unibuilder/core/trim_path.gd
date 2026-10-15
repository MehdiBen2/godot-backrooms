@tool
class_name UBTrimPath
extends RefCounted
## Trim along a selection of wall faces from any number of Unibuilder objects.
## Turns faces into base-line segments in world space, clips them against the
## scene's solids so an overlapping wall carries trim only on its visible run,
## merges coplanar overlaps, and chains what is left into mitre-able paths for
## UBPrimitives.make_trim_path. Pure and headless: the editor hands in the
## faces and the solids to clip against.
##
## A segment is {"a": Vector3, "b": Vector3, "n": Vector3}: its base line's
## ends and the horizontal room-facing normal. Segments that come from a face
## also carry "data" (the mesh) and "proud" (how far that face stands in front
## of the base line, see wall_segments) until they are clipped, and the
## pipeline tags each with its source face ("src", then "srcs" once merged)
## so keep_rooms can tell spill from a room's own runs. A path is
## {"points": PackedVector3Array, "normals": PackedVector3Array,
## "closed": bool} with one normal per segment (points.size() - 1 of them
## open, points.size() closed).

## Ends closer than this are one corner.
const END_TOL := 1e-3
## Coplanar walls within this of one base line merge into one run.
const LINE_TOL := 1e-3
## A visible run shorter than this is noise, not a wall.
const MIN_LEN := 1e-3
## 1 + n0.n1 below this is a fold-back (walls turning back on themselves):
## there is no finite mitre, so the chain splits there instead.
const FOLD_TOL := 0.05
## Walls are faces whose normal is at least this horizontal.
const WALL_MIN_HORIZONTAL := 0.7
## How far in front of a wall the floor/ceiling probe stands.
const PROBE_OFFSET := 1e-3
## Where along a run the floor/ceiling probes stand (settle_on_surfaces).
const SETTLE_PROBES := [0.1, 0.3, 0.5, 0.7, 0.9]


## The base (or, with `top`, the top) edges of one wall face as segments:
## the face's edges lying at its lowest (highest) level along `up`. A face
## whose normal is mostly vertical is a floor or ceiling, not a wall, and
## yields nothing. An n-gon wall with an opening yields one segment per
## floor-level edge, so the trim stops at the jambs by itself.
static func wall_segments(data: UBMeshData, xf: Transform3D, fi: int, up: Vector3, top := false) -> Array:
	var out: Array = []
	if data == null or fi < 0 or fi >= data.faces.size():
		return out
	var face: UBFace = data.faces[fi]
	var normal := (xf.basis * data.face_normal(face)).normalized()
	var n := normal - up * normal.dot(up)
	if n.length() < WALL_MIN_HORIZONTAL:
		return out
	n = n.normalized()
	var world := PackedVector3Array()
	for vi in face.vertices:
		world.append(xf * data.positions[vi])
	var level := -INF if top else INF
	for p in world:
		var h := p.dot(up)
		level = maxf(level, h) if top else minf(level, h)
	var count := world.size()
	for i in count:
		var a := world[i]
		var b := world[(i + 1) % count]
		if absf(a.dot(up) - level) > END_TOL or absf(b.dot(up) - level) > END_TOL:
			continue
		if a.distance_to(b) < MIN_LEN:
			continue

		var en := up.cross((b - a).normalized())
		if en.length() < 0.5:
			continue
		en = en.normalized()
		if en.dot(n) < 0.0:
			en = -en

		var proud := 0.0
		for p in world:
			proud = maxf(proud, (p - a).dot(en))
		out.append({"a": a, "b": b, "n": en, "data": data, "proud": proud})
	return out


## Drop the parts of each segment that run inside another solid ({"data",
## "xf"} pairs). Where wall A runs on past wall B into B's volume, only A's
## visible run keeps trim, and its end lands on B's face so chain() can meet
## the two at one corner. The line is tested `lift` above the base along `up`,
## so a slab the wall stands on never counts, and PROBE_OFFSET in front of the
## wall, so the test never sits on the wall's own face plane. Against the
## segment's own mesh the probe also clears its "proud" distance, since a bent
## face can stand further forward than its base edge. Only watertight meshes
## clip: inside and outside are read off which way the crossed face points,
## which means nothing on an open mesh. Crossings come from the ray cache
## picking uses; a segment that starts inside a solid is clipped from its
## start.
static func clip_segments(segments: Array, solids: Array, up: Vector3, lift: float) -> Array:
	var out: Array = []
	for seg in segments:
		var a: Vector3 = seg.a
		var b: Vector3 = seg.b
		var length := a.distance_to(b)
		if length < MIN_LEN:
			continue
		var dir := (b - a) / length
		var buried: Array = []
		for solid in solids:
			var data: UBMeshData = solid.data
			if data == null or not data.is_watertight():
				continue
			var xf: Transform3D = solid.xf
			var inv := xf.affine_inverse()
			var side: Vector3 = seg.n
			var out_by := PROBE_OFFSET
			if seg.get("data") == data:
				out_by += float(seg.get("proud", 0.0))
			var origin: Vector3 = inv * (a + up * lift + side * out_by)
			var ldir: Vector3 = inv.basis * dir
			var scale := ldir.length()
			if scale < 1e-9:
				continue
			ldir /= scale
			var accel := UBRayAccel.build_cached(data)
			var t := 0.0
			var inside := false
			var enter_t := 0.0
			for _guard in 256:
				var hit: Array = accel.nearest(origin + ldir * (t * scale), ldir)
				if hit[0] < 0:
					break
				var wt: float = t + hit[1] / scale
				if hit[1] > 1e-7:
					var fn: Vector3 = (xf.basis * data.face_normal(data.faces[hit[0]])).normalized()
					if fn.dot(dir) < 0.0:
						if wt > length:
							break
						inside = true
						enter_t = wt
					else:

						buried.append([enter_t if inside else 0.0, minf(wt, length)])
						inside = false
						if wt > length:
							break
				t = wt + 1e-4
				if t > length:
					break
			if inside:
				buried.append([enter_t, length])
		buried.sort_custom(func(x, y) -> bool: return x[0] < y[0])
		var t0 := 0.0
		for iv in buried:
			var s: float = maxf(iv[0], t0)
			if s - t0 > MIN_LEN:
				out.append({"a": a + dir * t0, "b": a + dir * s, "n": seg.n, "src": seg.get("src", -1)})
			t0 = maxf(t0, iv[1])
		if length - t0 > MIN_LEN:
			out.append({"a": a + dir * t0, "b": a + dir * length, "n": seg.n, "src": seg.get("src", -1)})
	return out


## Move each segment's level to where the wall meets the room: a wall cube
## often reaches below the floor slab (or above the ceiling), and the trim
## belongs on the slab's surface, not the cube's hidden bottom edge. Probes
## just in front of the wall walk from the edge into the room's height. While
## one keeps leaving solids it started inside (the floor slab, a step on it)
## its level follows; it stops at the first solid it would enter (a shelf
## above) or at the far edge. A wall meeting the floor exactly, or floating
## above it, keeps its own edge. Each probe starts a hair inside the wall
## height, so a slab whose bottom is level with the wall bottom already counts
## as inside. Several probes along the run vote (the median wins): a long face
## shared by two rooms has a partition standing somewhere along it, and a
## single probe that happened to start inside the partition used to lift the
## whole run to the partition's top.
static func settle_on_surfaces(segments: Array, solids: Array, up: Vector3, top: bool,
		limit: float) -> Array:
	var out: Array = []
	var dir := -up if top else up
	for seg in segments:
		var a: Vector3 = seg.a
		var b: Vector3 = seg.b
		var level: float = a.dot(up)
		var votes: Array = []
		for frac in SETTLE_PROBES:
			var at: Vector3 = a.lerp(b, frac) + seg.n * PROBE_OFFSET + dir * PROBE_OFFSET
			votes.append(_settle_probe(seg, at, solids, up, dir, top, level, limit))
		votes.sort()
		var best: float = votes[votes.size() / 2]
		if absf(best - level) > 1e-6:
			var shift := up * (best - level)
			var moved: Dictionary = seg.duplicate()
			moved.a = a + shift
			moved.b = b + shift
			out.append(moved)
		else:
			out.append(seg)
	return out


static func _settle_probe(seg: Dictionary, at: Vector3, solids: Array, up: Vector3, dir: Vector3,
		top: bool, level: float, limit: float) -> float:
	var best := level
	for solid in solids:
		var data: UBMeshData = solid.data
		if data == null or data.faces.is_empty():
			continue
		var xf: Transform3D = solid.xf
		var inv := xf.affine_inverse()

		var start := at
		if seg.get("data") == data:
			start += seg.n * float(seg.get("proud", 0.0))
		var origin := inv * start
		var ldir: Vector3 = inv.basis * dir
		var scale := ldir.length()
		if scale < 1e-9:
			continue
		ldir /= scale
		var accel := UBRayAccel.build_cached(data)
		var t := 0.0
		for _guard in 64:
			var hit: Array = accel.nearest(origin + ldir * (t * scale), ldir)
			if hit[0] < 0:
				break
			var wt: float = t + hit[1] / scale
			if hit[1] > 1e-7:
				var fn: Vector3 = (xf.basis * data.face_normal(data.faces[hit[0]])).normalized()
				if fn.dot(dir) < 0.0:
					break
				var h: float = (at + dir * wt).dot(up)
				if top:
					if h < best and h > limit:
						best = h
				elif h > best and h < limit:
					best = h
			t = wt + 1e-4
	return best


## Coplanar walls sharing one base line (a long wall built from overlapping
## cubes, or two a hair proud of each other) merge into one run per
## overlapping group, so trim never doubles up.
static func merge_collinear(segments: Array) -> Array:
	var groups: Array = []
	for seg in segments:
		var length: float = seg.a.distance_to(seg.b)
		if length < MIN_LEN:
			continue
		var d: Vector3 = (seg.b - seg.a) / length
		var placed := false
		for g in groups:
			if g.n.dot(seg.n) < 0.999 or absf(d.dot(g.dir)) < 0.999:
				continue
			var off: Vector3 = seg.a - g.origin
			if (off - g.dir * off.dot(g.dir)).length() > LINE_TOL:
				continue
			var ta: float = off.dot(g.dir)
			var tb: float = (seg.b - g.origin).dot(g.dir)
			g.intervals.append([minf(ta, tb), maxf(ta, tb), _srcs_of(seg)])
			placed = true
			break
		if not placed:
			groups.append({"n": seg.n, "origin": seg.a, "dir": d, "intervals": [[0.0, length, _srcs_of(seg)]]})
	var out: Array = []
	for g in groups:
		var ivs: Array = g.intervals
		ivs.sort_custom(func(x, y) -> bool: return x[0] < y[0])
		var cur: Array = ivs[0]
		for i in range(1, ivs.size()):
			if ivs[i][0] <= cur[1] + END_TOL:
				cur = [cur[0], maxf(cur[1], ivs[i][1]), _union(cur[2], ivs[i][2])]
			else:
				out.append({"a": g.origin + g.dir * cur[0], "b": g.origin + g.dir * cur[1], "n": g.n, "srcs": cur[2]})
				cur = ivs[i]
		out.append({"a": g.origin + g.dir * cur[0], "b": g.origin + g.dir * cur[1], "n": g.n, "srcs": cur[2]})
	return out


## Chain segments end to end into paths. Ends within END_TOL meet; the
## corner is the exact intersection of the two base lines, so two clipped
## walls that each end on the other's face meet at one point; a chain that
## comes back to its start closes; a fold-back splits the chain rather than
## asking for an infinite mitre. Segment direction is free: a segment is
## reversed to fit, and the normals do not depend on it.
static func chain(segments: Array, up: Vector3) -> Array:
	var segs: Array = []
	for seg in segments:
		if seg.a.distance_to(seg.b) >= MIN_LEN:
			segs.append(seg)
	var used := PackedByteArray()
	used.resize(segs.size())
	var paths: Array = []
	for start in segs.size():
		if used[start]:
			continue
		used[start] = 1
		var pts: Array = [segs[start].a, segs[start].b]
		var ns: Array = [segs[start].n]
		var closed := _extend(pts, ns, segs, used, up, true)
		if not closed:
			_extend(pts, ns, segs, used, up, false)
		var points := PackedVector3Array()
		for p in pts:
			points.append(p)
		var normals := PackedVector3Array()
		for n in ns:
			normals.append(n)
		paths.append({"points": points, "normals": normals, "closed": closed})
	return paths


static func _extend(pts: Array, ns: Array, segs: Array, used: PackedByteArray, up: Vector3,
		forward: bool) -> bool:
	while true:
		var end: Vector3 = pts.back() if forward else pts[0]
		var found := -1
		var far := Vector3.ZERO
		for j in segs.size():
			if used[j]:
				continue
			if segs[j].a.distance_to(end) <= END_TOL:
				found = j
				far = segs[j].b
				break
			if segs[j].b.distance_to(end) <= END_TOL:
				found = j
				far = segs[j].a
				break
		if found < 0:
			return false
		var n_new: Vector3 = segs[found].n
		var n_end: Vector3 = ns.back() if forward else ns[0]
		if 1.0 + n_end.dot(n_new) < FOLD_TOL:
			return false
		used[found] = 1

		var prev: Vector3 = pts[pts.size() - 2] if forward else pts[1]
		var corner := _corner(prev, end, n_end, far, n_new, up)
		if forward:
			pts[pts.size() - 1] = corner
			pts.append(far)
			ns.append(n_new)
		else:
			pts[0] = corner
			pts.push_front(far)
			ns.push_front(n_new)

		var other: Vector3 = pts[0] if forward else pts.back()
		if pts.size() >= 4 and far.distance_to(other) <= END_TOL:
			var n_first: Vector3 = ns[0] if forward else ns.back()
			if 1.0 + n_new.dot(n_first) < FOLD_TOL:
				return false

			var seam := _corner(pts[pts.size() - 2] if forward else pts[1],
				far, n_new, pts[1] if forward else pts[pts.size() - 2], n_first, up)
			if forward:
				pts.remove_at(pts.size() - 1)
				pts[0] = seam
			else:
				pts.remove_at(0)
				pts[pts.size() - 1] = seam
			return true
	return false


static func _corner(p1: Vector3, end: Vector3, n1: Vector3, p2: Vector3, n2: Vector3,
		up: Vector3) -> Vector3:
	var d1 := end - p1
	d1 -= up * d1.dot(up)
	if d1.length() < 1e-9:
		return end
	d1 = d1.normalized()
	var denom := n2.dot(d1)
	if absf(denom) < 1e-6:
		return end
	var s := n2.dot(p2 - end) / denom
	return end + d1 * s


## Keep the rooms the selected walls enclose, and drop the runs their faces
## spill into neighbouring rooms. A long wall face shared by several rooms
## clips into one run per room (the partitions are solids), and only one of
## them belongs to the room the user picked. Segments are linked where their
## ends meet and, across a doorway, where a free end's gap to its partner
## runs through open space: along its own line to the next run of the same
## wall (a door mid-wall), to where two walls' lines cross (a door at a
## corner), or onto the middle of another wall (a partition stopping short of
## it, which splits that wall where the partition's line meets it). A group
## whose every end is linked is a room. When there is one, runs whose source
## face ("srcs", from merge_collinear) also lines a room but which are not
## part of one are spill and go; runs from faces that line no room stay, so
## a lone wall picked beside a room keeps its trim. With no room found the
## segments come back untouched. Only `blockers` close a gap (the editor
## passes the selected walls' own meshes), so a door leaf or a crate
## standing in a doorway does not.
static func keep_rooms(segments: Array, blockers: Array, up: Vector3, lift: float) -> Array:
	var segs: Array = []
	var linked: Array = []
	for s in segments:
		segs.append({"a": s.a, "b": s.b, "n": s.n, "srcs": s.get("srcs", [])})
		linked.append([false, false])
	if segs.size() < 2:
		return segments
	var links: Array = []
	for i in segs.size():
		for j in range(i + 1, segs.size()):
			for ei in 2:
				for ej in 2:
					if _end(segs[i], ei).distance_to(_end(segs[j], ej)) <= END_TOL:
						linked[i][ei] = true
						linked[j][ej] = true
						links.append([i, ei, j, ej])

	var refused := {}
	for _guard in 256:
		var cands := _bridges(segs, linked, up)
		cands.sort_custom(func(x, y) -> bool: return x.cost < y.cost)
		var took := false
		for c in cands:
			var key := str(c.legs)
			if refused.has(key):
				continue
			if not _legs_open(c.legs, blockers, up, lift):
				refused[key] = true
				continue
			var j: int = c.j
			var ej: int = c.ej
			if c.has("split"):

				var t: Dictionary = segs[j]
				var m := segs.size()
				segs.append({"a": c.split, "b": t.b, "n": t.n, "srcs": t.srcs})
				linked.append([false, linked[j][1]])
				for l in links:
					if l[0] == j and l[1] == 1:
						l[0] = m
					if l[2] == j and l[3] == 1:
						l[2] = m
				t.b = c.split
				linked[j][1] = false

				if (t.a - c.split).dot(segs[c.i].n) > 0.0:
					ej = 1
				else:
					j = m
					ej = 0
			linked[c.i][c.ei] = true
			linked[j][ej] = true
			links.append([c.i, c.ei, j, ej])
			took = true
			break
		if not took:
			break

	var parent: Array = range(segs.size())
	for l in links:
		var ra := _root(parent, l[0])
		var rb := _root(parent, l[2])
		if ra != rb:
			parent[ra] = rb
	var open_group := {}
	for i in segs.size():
		if not (linked[i][0] and linked[i][1]):
			open_group[_root(parent, i)] = true
	var room_srcs := {}
	for i in segs.size():
		if not open_group.has(_root(parent, i)):
			for s in segs[i].srcs:
				room_srcs[s] = true
	if room_srcs.is_empty():
		return segments
	var out: Array = []
	for i in segs.size():
		var spill := false
		if open_group.has(_root(parent, i)):
			for s in segs[i].srcs:
				if room_srcs.has(s):
					spill = true
					break
		if not spill:
			out.append(segs[i])
	return out


static func _end(seg: Dictionary, e: int) -> Vector3:
	return seg.b if e == 1 else seg.a


static func _root(parent: Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _srcs_of(seg: Dictionary) -> Array:
	if seg.has("srcs"):
		return seg.srcs.duplicate()
	var s: int = seg.get("src", -1)
	return [s] if s >= 0 else []


static func _union(x: Array, y: Array) -> Array:
	var out := x.duplicate()
	for s in y:
		if not out.has(s):
			out.append(s)
	return out


static func _bridges(segs: Array, linked: Array, up: Vector3) -> Array:
	var out: Array = []
	for i in segs.size():
		var s: Dictionary = segs[i]
		for ei in 2:
			if linked[i][ei]:
				continue
			var e := _end(s, ei)
			var d := e - _end(s, 1 - ei)
			d -= up * d.dot(up)
			if d.length() < MIN_LEN:
				continue
			d = d.normalized()
			for j in segs.size():
				if j == i:
					continue
				var t: Dictionary = segs[j]
				if absf(t.a.dot(up) - e.dot(up)) > END_TOL:
					continue
				var length: float = t.a.distance_to(t.b)
				var td: Vector3 = (t.b - t.a) / length
				if d.cross(td).length() < 1e-3:

					if s.n.dot(t.n) < 0.999:
						continue
					var off: Vector3 = t.a - e
					if (off - d * off.dot(d)).length() > LINE_TOL:
						continue
					for ej in 2:
						var f := _end(t, ej)
						var gap := (f - e).dot(d)
						if linked[j][ej] or gap <= END_TOL or (_end(t, 1 - ej) - f).dot(d) <= 0.0:
							continue
						out.append({"i": i, "ei": ei, "j": j, "ej": ej, "cost": gap,
							"legs": [[e, f, s.n]]})
					continue
				if 1.0 + s.n.dot(t.n) < FOLD_TOL:
					continue
				var c := _corner(_end(s, 1 - ei), e, s.n, t.a, t.n, up)
				var ahead := (c - e).dot(d)
				if ahead < -END_TOL or (e - c).dot(t.n) <= 0.0:
					continue
				var along: float = (c - t.a).dot(td)
				if along > END_TOL and along < length - END_TOL:
					out.append({"i": i, "ei": ei, "j": j, "ej": 1, "cost": maxf(ahead, 0.0),
						"legs": [[e, c, s.n]], "split": c})
					continue

				var ej := 0 if along <= END_TOL else 1
				if linked[j][ej]:
					continue
				var f := _end(t, ej)
				if (f - c).dot(s.n) < -END_TOL:
					continue
				out.append({"i": i, "ei": ei, "j": j, "ej": ej,
					"cost": maxf(ahead, 0.0) + f.distance_to(c), "legs": [[e, c, s.n], [f, c, t.n]]})
	return out


static func _legs_open(legs: Array, blockers: Array, up: Vector3, lift: float) -> bool:
	for leg in legs:
		var length: float = leg[0].distance_to(leg[1])
		if length < MIN_LEN:
			continue
		var kept := clip_segments([{"a": leg[0], "b": leg[1], "n": leg[2]}], blockers, up, lift)
		if kept.size() != 1 or kept[0].a.distance_to(kept[0].b) < length - END_TOL:
			return false
	return true


## The whole pipeline for the editor: wall faces ({"data", "xf", "face"})
## to paths at their bases (or tops), clipped against `solids`, merged, and
## narrowed to the rooms they enclose (keep_rooms).
static func paths_from_walls(walls: Array, solids: Array, up: Vector3, lift: float,
		top := false) -> Array:
	var segments: Array = []
	var meshes := {}
	for wi in walls.size():
		var w: Dictionary = walls[wi]
		var segs := wall_segments(w.data, w.xf, w.face, up, top)
		if segs.is_empty():
			continue
		meshes[w.data] = true
		for s in segs:
			s["src"] = wi

		var other := wall_segments(w.data, w.xf, w.face, up, not top)
		var limit: float = other[0].a.dot(up) if not other.is_empty() else (-INF if top else INF)
		segments.append_array(settle_on_surfaces(segs, solids, up, top, limit))
	var signed_lift := lift if not top else -lift
	segments = clip_segments(segments, solids, up, signed_lift)
	segments = merge_collinear(segments)

	var blockers: Array = []
	for solid in solids:
		if meshes.has(solid.data):
			blockers.append(solid)
	segments = keep_rooms(segments, blockers, up, signed_lift)
	return chain(segments, up)
