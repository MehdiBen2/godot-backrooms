extends SceneTree
## Stands the player on one cell of a level and photographs a few ways round (needs a window, not --headless).
## Env: LEVEL (index, default 0), AT ("x,z" cell), LOOK (degrees on the map, comma separated: 0 = +x east, 90 =
## +z south; default 0,90,180,270), PITCH (deg, default -5), SHOT (output prefix, default res://spot).
##   godot --path godot-backrooms --resolution 1280x720 --script res://tools/shot_spot.gd

func _initialize() -> void:
	var env_or := func(k: String, d: String) -> String: return OS.get_environment(k) if OS.get_environment(k) != "" else d
	var game: Node = root.get_node("Game")
	game.level_index = int(env_or.call("LEVEL", "0"))
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	root.get_node("Gfx").set_preset("high")
	await create_timer(2.0).timeout
	game.playing = true
	var level: Node = main.get_node("Level")
	var player: Node3D = main.get_node("Player")
	var cam: Camera3D = player.get_node("Camera3D")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.get_node("UI").visible = false
	var at: PackedStringArray = str(env_or.call("AT", "2,2")).split(",")
	player.global_position = Vector3(float(at[0]) * level.CELL, 0.1, float(at[1]) * level.CELL)
	cam.rotation.x = deg_to_rad(float(env_or.call("PITCH", "-5")))
	var prefix: String = env_or.call("SHOT", "res://spot")
	# OFF=fake,real: hide the fake light (the floor pools, the lit wall faces, the cones) / the real lights, to see
	# which one draws something
	var off: PackedStringArray = str(env_or.call("OFF", "")).split(",", false)
	if off.has("fake"):
		for mmi in level.find_children("*", "MultiMeshInstance3D", true, false):
			var m = (mmi as MultiMeshInstance3D).material_override
			if m is ShaderMaterial and (m as ShaderMaterial).shader != null and (m as ShaderMaterial).shader.code.contains("blend_add"): mmi.visible = false
	if off.has("real"):
		for k in ["pool", "pool_b", "far_pool", "ceil_glow"]:
			for l in level.get(k): (l as Light3D).visible = false
	for deg in str(env_or.call("LOOK", "0,90,180,270")).split(","):
		var d := Vector2.from_angle(deg_to_rad(float(deg)))
		player.rotation.y = atan2(-d.x, -d.y)
		paused = false
		await create_timer(1.5).timeout
		root.get_texture().get_image().save_png("%s_%s.png" % [prefix, deg])
	print("walls in graph: ", level.wall_graph.edges.size(), " objects: ", level.objects.size())
	quit()
