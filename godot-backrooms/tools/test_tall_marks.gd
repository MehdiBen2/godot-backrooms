extends SceneTree
## Entity marks of Kind burnt / tallone in a loaded level: both must stand on their marks (EntityLOD hands them over).
## godot --path . --audio-driver Dummy --script res://tools/test_tall_marks.gd
func _initialize() -> void:
	var game: Node = root.get_node("Game")
	game.level_index = 0
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(2.0).timeout
	game.playing = true
	var level: Node = main.get_node("Level")
	var player: Node3D = main.get_node("Player")
	var objs: Array = level.level_data.get("objects", [])
	var nav = main.get_node("Burnt").nav
	var spots := []
	var cx := 0
	var cz := 0
	for x in range(10, 90):                                  # an open stretch of floor to stand on: the marks go round it
		for z in range(10, 90):
			if spots.size() >= 2: break
			var ok := true
			for dx in range(-3, 4):
				for dz in range(-3, 4):
					if not nav.open_at((x + dx) * 4.5, (z + dz) * 4.5): ok = false
			if ok:
				cx = x
				cz = z
				spots = [Vector2i(x + 3, z), Vector2i(x, z + 3)]
	player.global_position = Vector3(cx * 4.5, 0.1, cz * 4.5)
	print("player ", player.global_position, " cell ", cx, ",", cz, " open here ", nav.open_at(player.global_position.x, player.global_position.z), " n ", nav.n)
	print("marks at ", spots)
	for i in 2:
		objs.insert(0, {"type": "entity", "kind": ["burnt", "tallone"][i], "behavior": "roam", "pos_x": spots[i].x, "pos_y": spots[i].y, "rotation": 0.0, "scale": 1.0})
	for n in ["Burnt", "TallOne"]:
		main.get_node(n)._ready()
	await create_timer(3.0).timeout
	print("player now ", player.global_position, " Game.playing ", game.playing, " dead ", game.dead, " lvl objs ", objs.size())
	for n in ["Burnt", "TallOne"]:
		var e: Node3D = main.get_node(n)
		print(n, " pending ", e._mark_pending, " lod_go ", e._lod_go, " is_spawned ", root.get_node("EntityLOD").is_spawned(e), " tier ", root.get_node("EntityLOD").tier_name(e), " err ", e.last_error, " body ", e.body)
		print("%s: present %s state %s at %s" % [n, e.present, e.state, e.global_position])
	quit()
