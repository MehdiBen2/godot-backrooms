extends SceneTree
## Opens a door in a level with each way of opening it (player.gd DS_WAYS), then shuts it, printing the left
## hand's state (wall_hand.gd DOOR) every few ticks and saving frames, so the reach, the turn of the handle,
## the push and the letting go can be checked. Needs a window.
## Env: LEVEL (index, default 0), DOOR (which of the level's doors, default 0), WAYS (names, comma separated,
## default all), SHOT (output prefix, default res://door), FRAMES (per run, default 8).
## godot --path . --resolution 1280x800 --script res://tools/shot_door.gd

func _initialize() -> void:
	var env_or := func(k: String, d: String) -> String: return OS.get_environment(k) if OS.get_environment(k) != "" else d
	var game: Node = root.get_node("Game")
	game.level_index = int(env_or.call("LEVEL", "0"))
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(2.0).timeout
	game.playing = true
	var player: CharacterBody3D = main.get_node("Player")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	main.get_node("UI").visible = false
	var prefix: String = env_or.call("SHOT", "res://door")
	var frames := int(env_or.call("FRAMES", "8"))
	var doors: Array = []
	for d in get_nodes_in_group("doors"):
		if d.has_method("interact") and d.has_method("grip_at") and not doors.has(d):
			doors.append(d)
	if doors.is_empty():
		print("door: no doors in level %s" % game.level_index)
		quit()
		return
	var door: Node3D = doors[mini(int(env_or.call("DOOR", "0")), doors.size() - 1)]
	print("door: %d doors, using %s (%s, handle %s)" % [doors.size(), door.name, door.leaf, door.handle_kind()])
	var names: PackedStringArray = str(env_or.call("WAYS", "")).split(",", false)
	for way in player.DS_WAYS:
		if not names.is_empty() and not names.has(way.name):
			continue
		# 1.6 m out on the +x side, facing it, the door shut
		player.global_position = door.to_global(Vector3(1.6, 0.0, 0.2))
		player.global_position.y = door.global_position.y + 0.05
		player.velocity = Vector3.ZERO
		var to: Vector3 = door.global_position - player.global_position
		player.rotation.y = atan2(-to.x, -to.z)
		player.cam.rotation.x = 0.0
		await _ticks(player, 0.5)
		door.interact(player)
		player._ds_way = way                        # this way, not the dice's
		door.pace = float(way.pace)
		door.ajar = float(way.ajar) if door.latched() else 0.0
		await _run(player, 4.2, "%s_%s" % [prefix, way.name], frames)
		# back, and shut it
		player.global_position = door.to_global(Vector3(1.4, 0.0, 0.2))
		player.global_position.y = door.global_position.y + 0.05
		var back: Vector3 = door.global_position - player.global_position
		player.rotation.y = atan2(-back.x, -back.z)
		await _ticks(player, 0.4)
		door.interact(player)
		await _run(player, 4.4, "%s_%s_shut" % [prefix, way.name], 3)
	quit()

func _ticks(player: CharacterBody3D, secs: float) -> void:
	for i in int(secs * Engine.physics_ticks_per_second):
		await physics_frame
		paused = false

func _run(player: CharacterBody3D, secs: float, shot: String, frames: int) -> void:
	var n := int(secs * Engine.physics_ticks_per_second)
	var hands = player.torch._hands
	for i in n:
		await physics_frame
		paused = false
		var h = hands._hands[0]
		if i % 6 == 0:
			print("%s t %.2f  active %s  k %.2f  door %.2f  mode %d off %s over %.3f u %.2f grip %.2f palm %.2f turn %.2f press %.2f" % [shot.get_file(),
					player._ds_t, player._door_anim_active, player._ds_k, player._ds.open_amount if player._ds != null else -1.0,
					h.mode, h.off, h.over, h.u, h.grip, h.palm_k, h.turn, h.press])
			if player._ds != null:
				var g: Vector3 = player._ds.grip_at(player._ds_side)
				print("    at %s  grip %s  eye-grip %.2f  side %d  goal z %.2f" % [player._ds.to_local(player.global_position).snapped(Vector3.ONE * 0.01),
						player._ds.to_local(g).snapped(Vector3.ONE * 0.01), player.cam.global_position.distance_to(g), player._ds_side, player._ds_z])
				var lb: Node3D = player._ds.leaf_body
				var st: Transform3D = PhysicsServer3D.body_get_state(lb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
				print("    leaf node %s  physics %s  sync %s" % [player._ds.to_local(lb.global_transform * player._ds.leaf_collision.position).snapped(Vector3.ONE * 0.01),
						player._ds.to_local(st * player._ds.leaf_collision.position).snapped(Vector3.ONE * 0.01), lb.sync_to_physics])
				for c in player.get_slide_collision_count():
					var col := player.get_slide_collision(c)
					print("    hits %s at %s" % [col.get_collider().name if col.get_collider() else "?", player._ds.to_local(col.get_position()).snapped(Vector3.ONE * 0.01)])
		if frames > 0 and i % maxi(1, n / frames) == 0:
			var img := root.get_texture().get_image()
			if img != null and not img.is_empty():
				img.save_png("%s_%02d.png" % [shot, i / maxi(1, n / frames)])
