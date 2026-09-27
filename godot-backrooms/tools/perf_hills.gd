extends SceneTree
## Measures the hills scene: draw calls, primitives and nodes per frame. Needs a real window, not --headless.

func _stats(tag: String) -> void:
	print(JSON.stringify({
		"tag": tag,
		"fps": snappedf(Performance.get_monitor(Performance.TIME_FPS), 1),
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"prims": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"video_mem_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 1),
	}))

func _init() -> void:
	var s: Node = load("res://scenes/hills.tscn").instantiate()
	root.add_child(s)
	await create_timer(3.0).timeout
	var p: Node3D = s.get_children().filter(func(c): return c is CharacterBody3D)[0]
	p.pitch = 0.0
	p.cam.rotation.x = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	print("NODES total=%d visible_mesh=%d multimesh=%d" % [
		s.get_child_count(true),
		s.find_children("*", "MeshInstance3D", true, false).size(),
		s.find_children("*", "MultiMeshInstance3D", true, false).size()])
	for f in 3:
		await create_timer(1.0).timeout
	_stats("spawn")
	p.global_position = s.sites[0] + Vector3(14, 3, 14)
	p.rotation.y = 0.6
	await create_timer(2.0).timeout
	_stats("house")
	p.rotation.y = PI
	await create_timer(1.0).timeout
	_stats("house_back")
	quit()
