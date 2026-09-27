extends SceneTree
func _init() -> void:
	var t := Time.get_ticks_msec()
	var s: Node3D = load("res://scenes/hills.tscn").instantiate()
	s.standalone = false
	root.add_child(s)
	print("build ms: ", Time.get_ticks_msec() - t)
	var mis := s.find_children("*", "MeshInstance3D", true, false)
	var coarse := 0
	var detail := 0
	var bad := 0
	for mi: MeshInstance3D in mis:
		if mi.visibility_range_begin > 0.0:
			coarse += 1
		elif not mi.visibility_parent.is_empty():
			detail += 1
			var p := mi.get_node_or_null(mi.visibility_parent) as GeometryInstance3D
			if p == null or p.visibility_range_begin <= 0.0:
				bad += 1
	print("mesh instances: ", mis.size(), "  coarse: ", coarse, "  detail: ", detail, "  bad parents: ", bad)
	var occ := s.find_children("*", "OccluderInstance3D", true, false)
	print("occluders: ", occ.size(), "  tris: ", (occ[0].occluder as ArrayOccluder3D).indices.size() / 3)
	# occluder must never rise above the ground
	var o: ArrayOccluder3D = occ[0].occluder
	var above := 0
	for vtx in o.vertices:
		if vtx.y > s.height(vtx.x, vtx.z) - 0.4:
			above += 1
	print("occluder verts above ground: ", above)
	print("gfx_keep: ", s.env.has_meta("gfx_keep"), "  sun angular: ", s.sun.light_angular_distance)
	var sp: Vector3 = s.spawn_position()
	print("spawn: ", sp)
	quit()
