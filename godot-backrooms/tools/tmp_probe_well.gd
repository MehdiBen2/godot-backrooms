extends SceneTree
# temporary: what draws inside a stairwell where there should be air

func _initialize() -> void:
	var game := root.get_node("Game")
	game.level_index = 0
	game.level_floor = 0
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await create_timer(2.0).timeout
	var level: Node = main.get_node("Level")
	var w: Node3D = level.stairwells[0]
	for local: Vector3 in [Vector3(6.0, 0.0, -2.4), Vector3(-1.0, 0.0, 2.4)]:
		var p := w.to_global(local)
		var probe := AABB(p - Vector3(0.05, 0.05, 0.05), Vector3(0.1, 0.1, 0.1))
		print("--- at local %s world %s" % [local, p])
		for n: Node in root.find_children("*", "VisualInstance3D", true, false):
			var vi := n as VisualInstance3D
			if not vi.is_visible_in_tree(): continue
			var box: AABB = vi.global_transform * vi.get_aabb()
			if box.intersects(probe) and vi is MeshInstance3D and box.size.y < 0.2 and not w.is_ancestor_of(vi):
				var faces := (vi as MeshInstance3D).mesh.get_faces()
				var hit := false
				for i in range(0, faces.size(), 3):
					var a := vi.global_transform * faces[i]
					var b := vi.global_transform * faces[i + 1]
					var c := vi.global_transform * faces[i + 2]
					if Geometry2D.point_is_inside_triangle(Vector2(p.x, p.z), Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)):
						hit = true
						break
				print("  tri hit: %s  parent=%s script=%s" % [hit, vi.get_parent().name, vi.get_script()])
				var mat := ""
				if vi is GeometryInstance3D and (vi as GeometryInstance3D).material_override != null:
					mat = str((vi as GeometryInstance3D).material_override)
				print("  %s [%s] layers=%d inside_well=%s box=%s %s" % [vi.get_path(), vi.get_class(), vi.layers, w.is_ancestor_of(vi), box, mat])
	quit()
