extends RefCounted
## Fits the hazmat rig (models/player/hazmat.glb) into a box: feet on the origin, centred on x/z, `height` tall.
## The mesh AABB can't be trusted for this file (Z-up, 69x scaled armature: it lands metres off the body), so
## the fit is measured from the skeleton's rest-pose bones instead. Call before setting root.transform.

static func fit(root: Node3D, stop: Node, height: float) -> Transform3D:
	var sks := root.find_children("*", "Skeleton3D", true, false)
	if sks.is_empty():
		return Transform3D.IDENTITY
	var sk: Skeleton3D = sks[0]
	var xf := Transform3D.IDENTITY
	var p: Node = sk
	while p != null and p != stop:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in sk.get_bone_count():
		var o := xf * sk.get_bone_global_rest(i).origin
		lo = lo.min(o)
		hi = hi.max(o)
	var h := hi.y - lo.y
	if h <= 0.0001:
		return Transform3D.IDENTITY
	var sc := height / (h * 1.08)            # bones stop at the crown of the head and the ankles
	var c := (lo + hi) * 0.5
	return Transform3D(Basis.from_scale(Vector3(sc, sc, sc)), Vector3(-c.x, -lo.y + h * 0.04, -c.z) * sc)
