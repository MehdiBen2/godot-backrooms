extends RefCounted
## Fits the hazmat rig (models/player/hazmat.glb) into a box: soles on the origin, centred on x/z, `height` tall.
## The file is baked into metres (tools/retarget_hazmat.py in the web repo), so the mesh bounds give the true
## sole and crown; the skeleton's rest-pose bones (which stop at the ankles and the crown) only centre it on
## x/z, and stand in for the mesh if its bounds look wrong. Call before setting root.transform.

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
	var c := (lo + hi) * 0.5

	# the mesh's own sole and crown (in the same space as the bones)
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var t := Transform3D.IDENTITY
		var n: Node = mi
		while n != null and n != stop:
			if n is Node3D:
				t = (n as Node3D).transform * t
			n = n.get_parent()
		var b := t * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	var floor_y := box.position.y
	var h := box.size.y
	if first or h < (hi.y - lo.y) or h > (hi.y - lo.y) * 1.6:      # not plausible: fall back to the bones
		floor_y = lo.y - (hi.y - lo.y) * 0.04
		h = (hi.y - lo.y) * 1.08
	if h <= 0.0001:
		return Transform3D.IDENTITY
	var sc := height / h
	return Transform3D(Basis.from_scale(Vector3(sc, sc, sc)), Vector3(-c.x, -floor_y, -c.z) * sc)
