@tool
class_name UBOpInsetFaces
extends RefCounted
## Inset each selected face individually: extrude it in place, then pull the
## new cap's vertices inward. Face indices survive, so the selection stays
## valid. `amount` is the rim width in both modes, the perpendicular distance
## the edges slide inward. Default mode moves each vertex toward the face
## center, scaled so its two edges slide `amount` on average, so rim width
## still varies with edge length on irregular faces. `equal` mode offsets
## every rim edge by the same distance with miter corners. On a square or any
## regular polygon the two modes are identical.


##
## Concave faces are planned before anything changes: the vertex average can
## sit on (or past) a reflex corner, so a concave face measures toward a point
## inside its kernel instead, and the planned rim is checked as a whole. When
## the requested mode's layout is invalid the other mode is tried, and when
## neither is valid (no kernel and the miter offset folds, e.g. a large amount
## on a door front) the face is left unchanged rather than given inverted or
## zero-area rim walls. Convex faces take exactly the paths they always did.
static func apply(data, face_set: Dictionary, amount: float, equal := false) -> void:
	for fi in UBOpUtils.valid_faces(data, face_set):

		var face: UBFace = data.faces[fi]
		var offsets := PackedVector3Array()
		var lp := UBOpUtils.loop_plane(data, face.vertices)
		if lp != null and lp.is_concave():
			offsets = _concave_offsets(data, face, lp, amount, equal)
			if offsets.is_empty():
				continue
		else:
			var center: Vector3 = data.face_center(face)
			if equal:
				offsets = _equal_offsets(data, face, center, amount)
			else:
				offsets = _center_offsets(data, face, center, amount)
		UBOpExtrudeFaces.apply(data, {fi: true}, 0.0)
		var verts: PackedInt32Array = data.faces[fi].vertices
		for i in verts.size():
			data.positions[verts[i]] += offsets[i]


static func _concave_offsets(data, face: UBFace, lp: UBOpUtils.LoopPlane, amount: float, equal: bool) -> PackedVector3Array:
	var kp: Variant = UBOpUtils.kernel_point(lp)
	var center_plan := PackedVector3Array()
	if kp != null:
		center_plan = _center_offsets(data, face, lp.to_3d(kp), amount)
	var miter_plan := _miter_offsets(lp, amount)
	var plans := [miter_plan, center_plan] if equal else [center_plan, miter_plan]
	for plan: PackedVector3Array in plans:
		if not plan.is_empty() and _plan_ok(lp, plan):
			return plan
	return PackedVector3Array()


static func _plan_ok(lp: UBOpUtils.LoopPlane, offsets: PackedVector3Array) -> bool:
	var n := lp.pts.size()
	var inner := PackedVector2Array()
	for i in n:
		inner.append(lp.pts[i] + Vector2(offsets[i].dot(lp.u), offsets[i].dot(lp.v)))
	var loops := [inner]
	for i in n:
		var j := (i + 1) % n
		loops.append(PackedVector2Array([lp.pts[i], lp.pts[j], inner[j], inner[i]]))
	return UBOpUtils.layout_ok(loops, lp.orient, lp.scale)


static func _miter_offsets(lp: UBOpUtils.LoopPlane, amount: float) -> PackedVector3Array:
	var pts := lp.pts
	var n := pts.size()
	var normals := PackedVector2Array()
	for i in n:
		var d := pts[(i + 1) % n] - pts[i]
		normals.append(Vector2(-d.y, d.x).normalized() * lp.orient)
	var out := PackedVector3Array()
	for i in n:
		var n1 := normals[(i - 1 + n) % n]
		var n2 := normals[i]
		var denom := 1.0 + n1.dot(n2)
		var v: Vector2 = (n1 + n2) * (amount / denom) if denom > 1e-6 else n1 * amount
		out.append(lp.u * v.x + lp.v * v.y)
	return out


static func _center_offsets(data, face: UBFace, center: Vector3, amount: float) -> PackedVector3Array:
	var verts: PackedInt32Array = face.vertices
	var n := verts.size()
	var normal: Vector3 = data.face_normal(face)

	var offsets := PackedVector3Array()
	offsets.resize(n)
	for i in n:
		var p: Vector3 = data.positions[verts[i]]
		var to_center := center - p
		var dist := to_center.length()
		if dist <= 1e-6:
			continue
		var dir := to_center / dist
		var prev: Vector3 = data.positions[verts[(i - 1 + n) % n]]
		var next: Vector3 = data.positions[verts[(i + 1) % n]]
		var proj := 0.0
		var count := 0
		for nrm: Vector3 in [
			_inward_edge_normal(normal, prev, p, center),
			_inward_edge_normal(normal, p, next, center),
		]:
			if nrm != Vector3.ZERO:
				proj += dir.dot(nrm)
				count += 1
		var travel := amount
		if count > 0 and proj / count > 1e-3:
			travel = amount * count / proj

		offsets[i] = dir * minf(travel, dist * 0.9)
	return offsets


static func _equal_offsets(data, face: UBFace, center: Vector3, amount: float) -> PackedVector3Array:
	var verts: PackedInt32Array = face.vertices
	var n := verts.size()
	var normal: Vector3 = data.face_normal(face)

	var offsets := PackedVector3Array()
	offsets.resize(n)
	for i in n:
		var p: Vector3 = data.positions[verts[i]]
		var prev: Vector3 = data.positions[verts[(i - 1 + n) % n]]
		var next: Vector3 = data.positions[verts[(i + 1) % n]]
		var n1 := _inward_edge_normal(normal, prev, p, center)
		var n2 := _inward_edge_normal(normal, p, next, center)
		var denom := 1.0 + n1.dot(n2)
		var v: Vector3 = (n1 + n2) * (amount / denom) if denom > 1e-6 else n1 * amount
		var to_center := center - p
		var s := 1.0
		for nrm: Vector3 in [n1, n2]:
			var travel := v.dot(nrm)
			if travel > 1e-9:
				s = minf(s, 0.9 * maxf(to_center.dot(nrm), 0.0) / travel)
		offsets[i] = v * s
	return offsets


static func _inward_edge_normal(face_normal: Vector3, a: Vector3, b: Vector3,
		center: Vector3) -> Vector3:
	var perp := face_normal.cross(b - a).normalized()
	if perp.dot(center - (a + b) * 0.5) < 0.0:
		perp = -perp
	return perp
