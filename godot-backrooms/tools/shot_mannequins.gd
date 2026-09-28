extends SceneTree
## Screenshots the mannequin crowd's decoys up close, variant sculpts first (needs a window).
## Env: LEVEL (index), SHOT (prefix), N (how many decoys), ALL=1 (not just variants), TORCH=1, DIST (m).
## xvfb-run -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 --script res://tools/shot_mannequins.gd

func _initialize() -> void:
	var env_or := func(k: String, d: String) -> String: return OS.get_environment(k) if OS.get_environment(k) != "" else d
	var game: Node = root.get_node("Game")
	game.level_index = int(env_or.call("LEVEL", "0"))
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await create_timer(2.0).timeout
	var mq: Node = main.get_node("Mannequin")
	var player: Node3D = main.get_node("Player")
	var cam: Camera3D = player.get_node("Camera3D")
	main.get_node("UI").visible = false
	player.set_physics_process(false)
	player.flash_on = env_or.call("TORCH", "") != ""
	cam.position = Vector3(0, 1.3, 0)
	cam.rotation = Vector3.ZERO
	var decoys: Array = mq.decoys
	var picks: Array = []
	for i in decoys.size():
		if decoys[i].get("variant", false) or env_or.call("ALL", "") != "":
			picks.append(i)
	print("decoys: %d, variants: %d, ready=%s" % [decoys.size(), decoys.filter(func(d): return d.get("variant", false)).size(), mq.ready_ok])
	var prefix: String = env_or.call("SHOT", "res://mq")
	var n := 0
	for i in picks:
		if n >= int(env_or.call("N", "3")): break
		var d: Dictionary = decoys[i]
		print("decoy %d mode=%s variant=%s yaw=%.2f" % [i, d.pose.get("mode", "stand"), d.get("variant", false), d.yaw])
		for side in [1.0, -1.0]:
			var fwd := Basis(Vector3.UP, d.yaw) * Vector3(0, 0, side)
			var at := Vector3(d.x, 0.0, d.z) + fwd * float(env_or.call("DIST", "3.0"))
			player.global_position = at
			player.rotation.y = atan2(fwd.x, fwd.z)
			await create_timer(0.6).timeout
			root.get_texture().get_image().save_png("%s_%d_%s.png" % [prefix, n, "a" if side > 0 else "b"])
		n += 1
	quit()
