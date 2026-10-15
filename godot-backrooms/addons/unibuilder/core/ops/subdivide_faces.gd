@tool
class_name UBOpSubdivideFaces
extends RefCounted
## Subdivide each selected n-gon into quads. Every edge is split into
## `segments` equal parts and each corner gets an (h x h) grid patch, with
## h = segments/2, spanned between its two half-edges and the spokes from the
## edge midpoints to a center vertex (Coons interior). `segments` is rounded
## down to even, since the patch layout needs edge midpoints; segments=2 is
## the classic n-quad fan around the center. Edge points are shared between
## neighboring subdivided faces, and unselected neighbors get them inserted as
## collinear vertices, so no T-junctions appear.
##
## Per-corner colors and manual UVs are interpolated from the parent's corners
## along the same grid the positions use, so painted faces keep their
## gradients and fitted textures keep their tiling. Colors are per face, so a
## hard seam between two subdivided faces stays a seam. Faces without
## per-corner data keep the uniform `color` fallback via duplicate_face. Auto
## faces inherit their UV settings and frozen axis and re-project onto the
## same map.


static func apply(data, face_set: Dictionary, segments := 2) -> void:
	segments = maxi(2, segments - (segments % 2))
	var h := segments / 2
	face_set = UBOpUtils.valid_faces(data, face_set)

	var centers := {}
	for fi in face_set.keys():
		var lp := UBOpUtils.loop_plane(data, data.faces[fi].vertices)
		if lp == null or not lp.is_concave():
			continue
		var kp: Variant = UBOpUtils.kernel_point(lp)
		if kp == null or not UBOpUtils.layout_ok(_cells_2d(lp.pts, kp, segments), lp.orient, lp.scale):
			face_set.erase(fi)
			continue
		centers[fi] = lp.to_3d(kp)
	if face_set.is_empty():
		return

	var edge_pts := {}
	for fi in face_set:
		for e in UBSelectQueries.face_edges(data.faces[fi]):
			if not edge_pts.has(e):
				var list := PackedInt32Array()
				for s in range(1, segments):
					list.append(data.add_vertex(
						data.positions[e.x].lerp(data.positions[e.y], float(s) / float(segments))))
				edge_pts[e] = list

	UBOpUtils.insert_edge_points(data, edge_pts, face_set)

	var new_faces: Array[UBFace] = []
	for fi in face_set:
		var face: UBFace = data.faces[fi]
		var verts: PackedInt32Array = face.vertices
		var n := verts.size()
		var center_pos: Vector3 = centers.get(fi, data.face_center(face))
		var center: int = data.add_vertex(center_pos)

		var cw := PackedFloat32Array()
		if centers.has(fi):
			var corner_pts := PackedVector3Array()
			for vi in verts:
				corner_pts.append(data.positions[vi])
			cw = UBOpUtils.loop_weights(corner_pts, center_pos)

		var vcol := {}
		var has_colors: bool = face.color_corners.size() == n
		if has_colors:
			var csum := Color(0, 0, 0, 0)
			for i in n:
				vcol[verts[i]] = face.color_corners[i]
				csum += face.color_corners[i]
			vcol[center] = csum / n
			if not cw.is_empty():
				csum = Color(0, 0, 0, 0)
				for i in n:
					csum += face.color_corners[i] * cw[i]
				vcol[center] = csum
		var vuv := {}
		var has_uvs: bool = face.uv_manual and face.uv_coords.size() == n
		if has_uvs:
			var usum := Vector2.ZERO
			for i in n:
				vuv[verts[i]] = face.uv_coords[i]
				usum += face.uv_coords[i]
			vuv[center] = usum / n
			if not cw.is_empty():
				usum = Vector2.ZERO
				for i in n:
					usum += face.uv_coords[i] * cw[i]
				vuv[center] = usum

		var pts: Array[PackedInt32Array] = []
		for i in n:
			var a := verts[i]
			var key := UBSelectQueries.edge_key(a, verts[(i + 1) % n])
			var list: PackedInt32Array = edge_pts[key]
			if a != key.x:
				list = list.duplicate()
				list.reverse()
			pts.append(list)
		if has_colors:

			for i in n:
				var ca: Color = face.color_corners[i]
				var cb: Color = face.color_corners[(i + 1) % n]
				for s in range(1, segments):
					vcol[pts[i][s - 1]] = ca.lerp(cb, float(s) / float(segments))
		if has_uvs:
			for i in n:
				var ua: Vector2 = face.uv_coords[i]
				var ub: Vector2 = face.uv_coords[(i + 1) % n]
				for s in range(1, segments):
					vuv[pts[i][s - 1]] = ua.lerp(ub, float(s) / float(segments))

		var spokes: Array[PackedInt32Array] = []
		for i in n:
			var mid: int = pts[i][h - 1]
			var s := PackedInt32Array([mid])
			for k in range(1, h):
				s.append(data.add_vertex(
					data.positions[mid].lerp(center_pos, float(k) / float(h))))
			s.append(center)
			spokes.append(s)
		if has_colors:
			for i in n:
				var mid_col: Color = vcol[pts[i][h - 1]]
				for k in range(1, h):
					vcol[spokes[i][k]] = mid_col.lerp(vcol[center], float(k) / float(h))
		if has_uvs:
			for i in n:
				var mid_uv: Vector2 = vuv[pts[i][h - 1]]
				for k in range(1, h):
					vuv[spokes[i][k]] = mid_uv.lerp(vuv[center], float(k) / float(h))

		for i in n:
			var prev := (i - 1 + n) % n
			var g: Array[PackedInt32Array] = []
			for a in h + 1:
				var row := PackedInt32Array()
				row.resize(h + 1)
				g.append(row)
			for a in h + 1:
				g[a][0] = verts[i] if a == 0 else pts[i][a - 1]
				g[a][h] = spokes[prev][a]
			for b in range(1, h + 1):
				g[0][b] = pts[prev][segments - 1 - b]
				g[h][b] = spokes[i][b]
			var p00: Vector3 = data.positions[g[0][0]]
			var p10: Vector3 = data.positions[g[h][0]]
			var p01: Vector3 = data.positions[g[0][h]]
			for a in range(1, h):
				for b in range(1, h):
					var s := float(a) / float(h)
					var t := float(b) / float(h)
					var p: Vector3 = (
						data.positions[g[a][0]] * (1.0 - t) + data.positions[g[a][h]] * t
						+ data.positions[g[0][b]] * (1.0 - s) + data.positions[g[h][b]] * s
						- (p00 * (1.0 - s) * (1.0 - t) + p10 * s * (1.0 - t)
							+ p01 * (1.0 - s) * t + center_pos * s * t))
					g[a][b] = data.add_vertex(p)
					if has_colors:

						vcol[g[a][b]] = (
							vcol[g[a][0]] * (1.0 - t) + vcol[g[a][h]] * t
							+ vcol[g[0][b]] * (1.0 - s) + vcol[g[h][b]] * s
							- (vcol[g[0][0]] * (1.0 - s) * (1.0 - t)
								+ vcol[g[h][0]] * s * (1.0 - t)
								+ vcol[g[0][h]] * (1.0 - s) * t
								+ vcol[center] * s * t))
					if has_uvs:
						vuv[g[a][b]] = (
							vuv[g[a][0]] * (1.0 - t) + vuv[g[a][h]] * t
							+ vuv[g[0][b]] * (1.0 - s) + vuv[g[h][b]] * s
							- (vuv[g[0][0]] * (1.0 - s) * (1.0 - t)
								+ vuv[g[h][0]] * s * (1.0 - t)
								+ vuv[g[0][h]] * (1.0 - s) * t
								+ vuv[center] * s * t))
			for a in h:
				for b in h:
					var cell: UBFace = face.duplicate_face()
					var loop := PackedInt32Array(
						[g[a][b], g[a + 1][b], g[a + 1][b + 1], g[a][b + 1]])
					UBOpUtils.set_face_loop(cell, loop)
					if has_colors:

						var cols := PackedColorArray()
						for vi in loop:
							cols.append(vcol[vi])
						cell.color_corners = cols
					if has_uvs:
						var coords := PackedVector2Array()
						for vi in loop:
							coords.append(vuv[vi])
						cell.uv_coords = coords
						cell.uv_manual = true
					new_faces.append(cell)

	var kept: Array[UBFace] = []
	for fi in data.faces.size():
		if not face_set.has(fi):
			kept.append(data.faces[fi])
	kept.append_array(new_faces)
	data.faces = kept


static func _cells_2d(pts: PackedVector2Array, c: Vector2, segments: int) -> Array:
	var n := pts.size()
	var h := segments / 2
	var cells := []
	for i in n:
		var prev := (i - 1 + n) % n
		var corner := pts[i]
		var nxt := pts[(i + 1) % n]
		var before := pts[prev]
		var g := []
		for a in h + 1:
			var row := PackedVector2Array()
			row.resize(h + 1)
			g.append(row)
		var mid_i := corner.lerp(nxt, 0.5)
		var mid_prev := before.lerp(corner, 0.5)
		for a in h + 1:

			g[a][0] = corner.lerp(nxt, float(a) / float(segments))
			g[a][h] = mid_prev.lerp(c, float(a) / float(h))
		for b in range(1, h + 1):

			g[0][b] = corner.lerp(before, float(b) / float(segments))
			g[h][b] = mid_i.lerp(c, float(b) / float(h))
		var p00: Vector2 = g[0][0]
		var p10: Vector2 = g[h][0]
		var p01: Vector2 = g[0][h]
		for a in range(1, h):
			for b in range(1, h):
				var s := float(a) / float(h)
				var t := float(b) / float(h)
				g[a][b] = (
					g[a][0] * (1.0 - t) + g[a][h] * t
					+ g[0][b] * (1.0 - s) + g[h][b] * s
					- (p00 * (1.0 - s) * (1.0 - t) + p10 * s * (1.0 - t)
						+ p01 * (1.0 - s) * t + c * s * t))
		for a in h:
			for b in h:
				cells.append(PackedVector2Array([g[a][b], g[a + 1][b], g[a + 1][b + 1], g[a][b + 1]]))
	return cells
