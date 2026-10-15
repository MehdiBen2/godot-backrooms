@tool
class_name UBOpUtils
extends RefCounted
## Shared helpers for mesh ops. Ops are pure functions on UBMeshData with no
## editor or UI knowledge and no signals; the caller owns undo and change
## notification.


## Give a face a loop that is not a re-indexing of its old corners (splits,
## merges, chamfer strips) and drop the per-corner data that described the old
## loop: manual UVs fall back to auto and paint to the flat face color. Equal
## counts alone would let stale corner data land on the wrong corners. Ops
## that only re-index the same corners (compaction remaps, reverse_face_loop,
## triangulation) must not use this.
static func set_face_loop(face: UBFace, verts: PackedInt32Array) -> void:
	face.vertices = verts
	face.uv_manual = false
	face.uv_coords = PackedVector2Array()
	face.color_corners = PackedColorArray()


## Position-based color sampler over one painted face, captured before an op
## rewrites its loop. Ops that carve a face into new loops (connect, insert
## loop, cut) use it to give every new face the colors the paint had at those
## positions: an original corner keeps its exact color, a point on an edge
## gets the edge lerp, an interior point the barycentric blend of its
## triangle. capture_colors returns null for an unpainted face.
class ColorField:
	var pts: PackedVector3Array
	var cols: PackedColorArray
	var tris: PackedInt32Array
	var by_id := {}

	## Color at an arbitrary position: the triangle whose clamped barycentric
	## coordinates fit best. Points slightly outside or off-plane clamp to the
	## nearest boundary value instead of extrapolating.
	func color_at(p: Vector3) -> Color:
		var best := -1.0e30
		var best_col := Color.WHITE
		for t in range(0, tris.size(), 3):
			var a := pts[tris[t]]
			var ab := pts[tris[t + 1]] - a
			var ac := pts[tris[t + 2]] - a
			var ap := p - a
			var d00 := ab.dot(ab)
			var d01 := ab.dot(ac)
			var d11 := ac.dot(ac)
			var d20 := ap.dot(ab)
			var d21 := ap.dot(ac)
			var denom := d00 * d11 - d01 * d01
			if absf(denom) < 1e-12:
				continue
			var v := (d11 * d20 - d01 * d21) / denom
			var w := (d00 * d21 - d01 * d20) / denom
			var u := 1.0 - v - w
			var fit := minf(u, minf(v, w))
			if fit > best:
				best = fit
				u = maxf(u, 0.0)
				v = maxf(v, 0.0)
				w = maxf(w, 0.0)
				var s := u + v + w
				if s < 1e-12:
					continue
				best_col = (
					cols[tris[t]] * u + cols[tris[t + 1]] * v
					+ cols[tris[t + 2]] * w) / s
		return best_col

	## Per-corner colors for a new loop: exact at captured corners, sampled
	## elsewhere (new vertices must already have positions in `data`).
	func colors_for_loop(data, loop: PackedInt32Array) -> PackedColorArray:
		var out := PackedColorArray()
		for vi in loop:
			out.append(by_id[vi] if by_id.has(vi) else color_at(data.positions[vi]))
		return out


## ColorField factory: null when the face carries no per-corner paint, or is
## too degenerate to triangulate.
static func capture_colors(data, face: UBFace) -> ColorField:
	var n := face.vertices.size()
	if face.color_corners.size() != n:
		return null
	var field := ColorField.new()
	field.cols = face.color_corners.duplicate()
	for i in n:
		var p: Vector3 = data.positions[face.vertices[i]]
		field.pts.append(p)
		if not field.by_id.has(face.vertices[i]):
			field.by_id[face.vertices[i]] = face.color_corners[i]
	field.tris = UBTriangulate.triangulate(field.pts)
	if field.tris.is_empty():
		return null
	return field


## Selection sanitisers. The editor owns the selection handed to an op, and it
## can name elements the mesh no longer has: an index that is in range can
## still name a different element, and an edge key can have two real endpoints
## that share no edge. Every op filters its selection through these first.
static func valid_faces(data, face_set: Dictionary) -> Dictionary:
	var out := {}
	for fi in face_set:
		if fi is int and fi >= 0 and fi < data.faces.size():
			out[fi] = true
	return out


static func valid_vertices(data, vert_set: Dictionary) -> Dictionary:
	var out := {}
	for vi in vert_set:
		if vi is int and vi >= 0 and vi < data.positions.size():
			out[vi] = true
	return out


## Edge keys that are real edges of the mesh, per the topology cache. In-range
## endpoints are not enough: two opposite corners of a cube form an in-range
## key that no face connects.
static func valid_edges(topo, edge_set: Dictionary) -> Dictionary:
	var out := {}
	for e in edge_set:
		if e is Vector2i and topo.edge_faces.has(e):
			out[e] = true
	return out


static func is_real_edge(topo, e: Vector2i) -> bool:
	return topo.edge_faces.has(e)


## Drops vertices referenced by no face and remaps every face index. Call after
## any op that can orphan vertices; orphans violate validate().
static func remove_unused_vertices(data) -> void:
	var used := {}
	for f in data.faces:
		for vi in f.vertices:
			used[vi] = true
	if used.size() == data.positions.size():
		return
	var remap := PackedInt32Array()
	remap.resize(data.positions.size())
	var new_positions := PackedVector3Array()
	for vi in data.positions.size():
		if used.has(vi):
			remap[vi] = new_positions.size()
			new_positions.append(data.positions[vi])
		else:
			remap[vi] = -1
	data.positions = new_positions
	for f in data.faces:
		var verts: PackedInt32Array = f.vertices
		for i in verts.size():
			verts[i] = remap[verts[i]]
		f.vertices = verts


## Reverse a face's vertex loop (flipping its winding, and so its normal),
## keeping manual UVs and paint colors attached to their vertices. Every op
## that flips a winding must go through this; reversing `vertices` alone
## scrambles per-corner data, since equal counts never trigger the compiler's
## mismatch fallback.
static func reverse_face_loop(face: UBFace) -> void:
	var verts: PackedInt32Array = face.vertices
	verts.reverse()
	face.vertices = verts
	if face.uv_manual and face.uv_coords.size() == verts.size():
		var coords: PackedVector2Array = face.uv_coords
		coords.reverse()
		face.uv_coords = coords
	if face.color_corners.size() == verts.size():
		var colors: PackedColorArray = face.color_corners
		colors.reverse()
		face.color_corners = colors


static func translate_vertices(data, vertex_set: Dictionary, offset: Vector3) -> void:
	for vi in vertex_set:
		data.positions[vi] += offset


## Rewrite every face through an index remap (remap[i] == i for untouched
## vertices). Faces that degenerate (under 3 distinct vertices) are dropped;
## unused vertices are compacted afterwards. Per-corner arrays follow their
## kept corners. Shared tail of collapse and weld.
##
## A loop that comes back through a vertex it already visited (two non-adjacent
## corners of one n-gon merged) is PINCHED, not degenerate: it is split at the
## repeated vertex into sub-loops, and every sub-loop with 3+ corners and a
## non-zero area survives as its own face (the first keeps the source face, the
## rest are appended at the end of the face list). Dropping the whole loop, as
## this used to, opened the mesh.
static func remap_faces(data, remap: PackedInt32Array) -> void:
	var kept: Array[UBFace] = []
	var extra: Array[UBFace] = []
	for f in data.faces:
		var old_n: int = f.vertices.size()
		var pieces := remap_loop(data, f.vertices, remap)
		if pieces.is_empty():
			continue

		var faces: Array[UBFace] = [f]
		for k in range(1, pieces.size()):
			faces.append(f.duplicate_face())
		for k in pieces.size():
			var face: UBFace = faces[k]
			var out: PackedInt32Array = pieces[k][0]
			var src: PackedInt32Array = pieces[k][1]

			if out.size() != old_n or pieces.size() > 1:
				if face.uv_coords.size() == old_n:
					var uvs := PackedVector2Array()
					for i in src:
						uvs.append(face.uv_coords[i])
					face.uv_coords = uvs
				if face.color_corners.size() == old_n:
					var cols := PackedColorArray()
					for i in src:
						cols.append(face.color_corners[i])
					face.color_corners = cols
			face.vertices = out
			if k == 0:
				kept.append(face)
			else:
				extra.append(face)
	kept.append_array(extra)
	data.faces = kept
	remove_unused_vertices(data)


## One face loop through a remap, as remap_faces rewrites it: an Array of
## [loop: PackedInt32Array, src: PackedInt32Array] pieces (src = the source
## corner index of each entry), empty when the face degenerates. Pure.
static func remap_loop(data, verts: PackedInt32Array, remap: PackedInt32Array) -> Array:
	var out := PackedInt32Array()
	var src := PackedInt32Array()
	for i in verts.size():
		var nv := remap[verts[i]]
		if out.is_empty() or out[out.size() - 1] != nv:
			out.append(nv)
			src.append(i)
	while out.size() > 1 and out[0] == out[out.size() - 1]:
		out.remove_at(out.size() - 1)
		src.remove_at(src.size() - 1)
	if out.size() < 3:
		return []

	var pieces := []
	var stack_v := PackedInt32Array()
	var stack_s := PackedInt32Array()
	var pos := {}
	for k in out.size():
		var v := out[k]
		if pos.has(v):
			var p: int = pos[v]
			pieces.append([stack_v.slice(p), stack_s.slice(p)])
			for r in range(p + 1, stack_v.size()):
				pos.erase(stack_v[r])
			stack_v.resize(p + 1)
			stack_s.resize(p + 1)
		else:
			pos[v] = stack_v.size()
			stack_v.append(v)
			stack_s.append(src[k])
	if pieces.is_empty():
		return [[out, src]]
	pieces.append([stack_v, stack_s])
	var kept := []
	for piece: Array in pieces:
		var loop: PackedInt32Array = piece[0]
		if loop.size() >= 3 and _loop_has_area(data, loop):
			kept.append(piece)
	return kept


static func _loop_has_area(data, loop: PackedInt32Array) -> bool:
	var pts := PackedVector3Array()
	for vi in loop:
		pts.append(data.positions[vi])
	var scale := 0.0
	for i in pts.size():
		scale = maxf(scale, pts[i].distance_squared_to(pts[(i + 1) % pts.size()]))
	return UBTriangulate.newell_normal(pts).length() > 1e-9 * scale


## True when rewriting the faces through `remap` (as remap_faces would) leaves
## some edge shared by more than two faces that was not already over-shared:
## the link condition an edge collapse must respect, or it fuses two surfaces
## along an edge (a triangulated cone collapsed across one edge). Weld does
## NOT check it: stitching two touching solids is a legitimate weld, and
## mirror's closed-mesh contract relies on it. Pure: nothing is mutated.
static func remap_overshares(data, remap: PackedInt32Array) -> bool:
	var before := {}
	for f in data.faces:
		for e in UBSelectQueries.face_edges(f):
			before[e] = before.get(e, 0) + 1
	var after := {}
	for f in data.faces:
		for piece: Array in remap_loop(data, f.vertices, remap):
			var loop: PackedInt32Array = piece[0]
			for i in loop.size():
				var e := UBSelectQueries.edge_key(loop[i], loop[(i + 1) % loop.size()])
				after[e] = after.get(e, 0) + 1
	for e in after:
		if after[e] > 2 and before.get(e, 0) <= 2:
			return true
	return false


## Planar 2D view of a vertex loop, for ops that need polygon geometry
## (diagonals, kernels, layout checks). Coordinates are CENTRED on the loop's
## centroid before projecting, for the precision reason UBTriangulate centres
## (float32 cancellation on faces far from the origin). `orient` is the sign of
## the loop's signed area in these coordinates, so "inside" tests are
## winding-agnostic. Built by loop_plane; null when the loop has no area.
class LoopPlane:
	var origin: Vector3
	var u: Vector3
	var v: Vector3
	var pts := PackedVector2Array()
	var orient := 1.0
	## Largest corner distance from the centroid: the length scale for
	## tolerances.
	var scale := 0.0

	func to_3d(p: Vector2) -> Vector3:
		return origin + u * p.x + v * p.y

	func to_2d(p: Vector3) -> Vector2:
		var d := p - origin
		return Vector2(d.dot(u), d.dot(v))

	## True when some corner turns against the loop's winding (collinear
	## corners count as convex).
	func is_concave() -> bool:
		var n := pts.size()
		var eps := 1e-9 * scale * scale
		for i in n:
			var a := pts[(i - 1 + n) % n]
			var b := pts[i]
			var c := pts[(i + 1) % n]
			if orient * (b - a).cross(c - b) < -eps:
				return true
		return false


static func loop_plane(data, loop: PackedInt32Array) -> LoopPlane:
	var n := loop.size()
	if n < 3:
		return null
	var pts3 := PackedVector3Array()
	var c := Vector3.ZERO
	for vi in loop:
		pts3.append(data.positions[vi])
		c += data.positions[vi]
	c /= float(n)
	var normal := UBTriangulate.newell_normal(pts3)
	if normal.length_squared() <= 0.0:
		return null
	normal = normal.normalized()
	var axis := Vector3.RIGHT if absf(normal.x) < 0.9 else Vector3.UP
	var lp := LoopPlane.new()
	lp.origin = c
	lp.u = (axis - normal * axis.dot(normal)).normalized()
	lp.v = normal.cross(lp.u)
	for p in pts3:
		lp.pts.append(lp.to_2d(p))
		lp.scale = maxf(lp.scale, (p - c).length())
	var area := signed_area_2d(lp.pts)
	if absf(area) <= 1e-12 * lp.scale * lp.scale:
		return null
	lp.orient = signf(area)
	return lp


static func signed_area_2d(pts: PackedVector2Array) -> float:
	var a := 0.0
	var n := pts.size()
	for i in n:
		a += pts[i].cross(pts[(i + 1) % n])
	return a * 0.5


## Proper crossing only: shared endpoints and touching tips do not count.
## `eps` is in cross-product units (length squared).
static func segments_cross(a: Vector2, b: Vector2, c: Vector2, d: Vector2, eps := 1e-9) -> bool:
	var d1 := (b - a).cross(c - a)
	var d2 := (b - a).cross(d - a)
	var d3 := (d - c).cross(a - c)
	var d4 := (d - c).cross(b - c)
	return ((d1 > eps and d2 < -eps) or (d1 < -eps and d2 > eps)) \
		and ((d3 > eps and d4 < -eps) or (d3 < -eps and d4 > eps))


## True when corners i and j of the loop can be joined by a chord that runs
## through the polygon's interior: it crosses no loop edge, passes through no
## other corner (a collinear run, or a reflex corner on the line), and its
## midpoint is inside. A chord between two corners of a CONCAVE face can leave
## the polygon, and splitting along it yields inverted, overlapping faces.
static func chord_inside(lp: LoopPlane, i: int, j: int) -> bool:
	var pts := lp.pts
	var n := pts.size()
	var a := pts[i]
	var b := pts[j]
	var len_eps := 1e-6 * lp.scale
	if a.distance_to(b) <= len_eps:
		return false
	var cross_eps := 1e-9 * lp.scale * lp.scale
	for k in n:
		var k1 := (k + 1) % n
		if k == i or k == j or k1 == i or k1 == j:
			continue
		if segments_cross(a, b, pts[k], pts[k1], cross_eps):
			return false
	for k in n:
		if k == i or k == j:
			continue
		var q := Geometry2D.get_closest_point_to_segment(pts[k], a, b)
		if q.distance_to(pts[k]) <= len_eps:
			return false
	return Geometry2D.is_point_in_polygon((a + b) * 0.5, pts)


## A point strictly inside the polygon's KERNEL (the region that sees every
## corner and edge), or null when the kernel is empty or a sliver. A fan from
## a kernel point to the boundary never folds, which is what subdivide's spokes
## and inset's center-relative travel need; the vertex average a convex face
## uses can sit ON a reflex corner of a concave one.
static func kernel_point(lp: LoopPlane) -> Variant:
	var r := lp.scale * 2.0 + 1.0
	var poly := PackedVector2Array([Vector2(-r, -r), Vector2(r, -r), Vector2(r, r), Vector2(-r, r)])
	var pts := lp.pts
	var n := pts.size()
	for i in n:
		var a := pts[i]
		var dir := pts[(i + 1) % n] - a
		if dir.length_squared() <= 0.0:
			continue
		var clipped := PackedVector2Array()
		var m := poly.size()
		for k in m:
			var p := poly[k]
			var q := poly[(k + 1) % m]
			var sp := lp.orient * dir.cross(p - a)
			var sq := lp.orient * dir.cross(q - a)
			if sp >= 0.0:
				clipped.append(p)
			if (sp >= 0.0) != (sq >= 0.0):
				clipped.append(p + (q - p) * (sp / (sp - sq)))
		poly = clipped
		if poly.size() < 3:
			return null
	var area := signed_area_2d(poly)
	if absf(area) <= 1e-6 * lp.scale * lp.scale:
		return null

	var c := Vector2.ZERO
	var m := poly.size()
	for k in m:
		var p := poly[k]
		var q := poly[(k + 1) % m]
		c += (p + q) * p.cross(q)
	return c / (6.0 * area)


## True when the 2D loops form a valid planar layout of one face's
## replacement: every loop has the winding `orient` with a non-zero area, no
## loop repeats a corner position, and no edge of any loop properly crosses an
## edge of any loop. Ops that carve a concave face check their plan with it and
## leave the face alone when it fails.
static func layout_ok(loops: Array, orient: float, scale: float) -> bool:
	var area_eps := 1e-9 * scale * scale
	var len_eps := 1e-6 * scale
	var cross_eps := 1e-9 * scale * scale
	var edges := []
	for loop: PackedVector2Array in loops:
		var n := loop.size()
		if n < 3 or orient * signed_area_2d(loop) <= area_eps:
			return false
		for i in n:
			for j in range(i + 1, n):
				if loop[i].distance_to(loop[j]) <= len_eps:
					return false
			edges.append([loop[i], loop[(i + 1) % n]])
	for i in edges.size():
		var e: Array = edges[i]
		for j in range(i + 1, edges.size()):
			var f: Array = edges[j]
			if segments_cross(e[0], e[1], f[0], f[1], cross_eps):
				return false
	return true


## Per-corner interpolation weights of point p over a loop's corner points:
## the clamped barycentric coordinates of the best-fitting triangle of the
## loop's triangulation (ColorField.color_at's rule). Lets ops sample manual
## UVs and paint at an interior point of a concave face, where the plain
## corner average does not describe the point.
static func loop_weights(pts: PackedVector3Array, p: Vector3) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	w.resize(pts.size())
	var tris := UBTriangulate.triangulate(pts)
	var best := -1.0e30
	for t in range(0, tris.size(), 3):
		var a := pts[tris[t]]
		var ab := pts[tris[t + 1]] - a
		var ac := pts[tris[t + 2]] - a
		var ap := p - a
		var d00 := ab.dot(ab)
		var d01 := ab.dot(ac)
		var d11 := ac.dot(ac)
		var d20 := ap.dot(ab)
		var d21 := ap.dot(ac)
		var denom := d00 * d11 - d01 * d01
		if absf(denom) < 1e-12:
			continue
		var bv := (d11 * d20 - d01 * d21) / denom
		var bw := (d00 * d21 - d01 * d20) / denom
		var bu := 1.0 - bv - bw
		var fit := minf(bu, minf(bv, bw))
		if fit <= best:
			continue
		bu = maxf(bu, 0.0)
		bv = maxf(bv, 0.0)
		bw = maxf(bw, 0.0)
		var s := bu + bv + bw
		if s < 1e-12:
			continue
		best = fit
		w.fill(0.0)
		w[tris[t]] += bu / s
		w[tris[t + 1]] += bv / s
		w[tris[t + 2]] += bw / s
	if best <= -1.0e30:
		w.fill(1.0 / maxf(1.0, float(pts.size())))
	return w


## Split edges by inserting already-created vertices into every face loop that
## contains them, keeping neighbors T-junction-free. A value is either one
## vertex index (midpoint split) or an ordered list running key.x -> key.y;
## lists insert reversed in faces that traverse the edge y -> x. skip_faces are
## left untouched, for callers about to rebuild those faces themselves.
## Paint colors and manual UVs grow with the loop: each inserted point takes
## the lerp of the edge's two corners at its position along the edge.
static func insert_edge_points(data, edge_points: Dictionary, skip_faces := {}) -> void:
	for fi in data.faces.size():
		if skip_faces.has(fi):
			continue
		var face: UBFace = data.faces[fi]
		var verts: PackedInt32Array = face.vertices
		var n := verts.size()
		var has_uv: bool = face.uv_manual and face.uv_coords.size() == n
		var has_col: bool = face.color_corners.size() == n
		var out := PackedInt32Array()
		var out_uv := PackedVector2Array()
		var out_col := PackedColorArray()
		var changed := false
		for i in n:
			var a := verts[i]
			var b := verts[(i + 1) % n]
			out.append(a)
			if has_uv:
				out_uv.append(face.uv_coords[i])
			if has_col:
				out_col.append(face.color_corners[i])
			var key := UBSelectQueries.edge_key(a, b)
			if not edge_points.has(key):
				continue
			changed = true
			var pts: Variant = edge_points[key]
			var inserted := PackedInt32Array()
			if pts is int:
				inserted.append(pts)
			elif a == key.x:
				inserted.append_array(pts)
			else:
				var list: PackedInt32Array = pts
				for j in range(list.size() - 1, -1, -1):
					inserted.append(list[j])
			out.append_array(inserted)
			if not (has_uv or has_col):
				continue
			var pa: Vector3 = data.positions[a]
			var ab: Vector3 = data.positions[b] - pa
			var len2 := ab.length_squared()
			for vi in inserted:

				var t := 0.5
				if len2 > 1e-12:
					t = clampf((data.positions[vi] - pa).dot(ab) / len2, 0.0, 1.0)
				if has_uv:
					out_uv.append(face.uv_coords[i].lerp(face.uv_coords[(i + 1) % n], t))
				if has_col:
					out_col.append(face.color_corners[i].lerp(face.color_corners[(i + 1) % n], t))
		if changed:
			face.vertices = out
			if has_uv:
				face.uv_coords = out_uv
			if has_col:
				face.color_corners = out_col
