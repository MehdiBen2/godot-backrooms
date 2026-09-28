extends SceneTree
## Stares at the mannequin room and reports what the stare does: blinks, sanity lost, and how far the real
## one moved (needs a window for the captured mouse). Env: LEVEL, SECONDS.
## xvfb-run -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 --script res://tools/probe_stare.gd

func _initialize() -> void:
	var game: Node = root.get_node("Game")
	game.level_index = int(OS.get_environment("LEVEL") if OS.get_environment("LEVEL") != "" else "0")
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.5).timeout
	game.playing = true
	var mq: Node = main.get_node("Mannequin")
	var player: Node = main.get_node("Player")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	mq.warp_to_room()
	player.spawn_grace = 999.0                    # no kill while we measure
	var c: Vector3 = mq.room_centre()
	var secs := float(OS.get_environment("SECONDS") if OS.get_environment("SECONDS") != "" else "25")
	var s0: float = player.sanity
	var blinks := 0
	var was := false
	var moved := 0.0
	var last: Vector3 = mq.real_node.position
	var t := 0.0
	var shut_frames := 0
	while t < secs:
		await physics_frame
		t += 1.0 / Engine.physics_ticks_per_second
		# keep looking at the middle of the room
		var to: Vector3 = c - player.global_position
		player.rotation.y = atan2(-to.x, -to.z)
		player.cam.rotation.x = 0.0
		var b: bool = player.blink.blinking()
		if b and not was:
			blinks += 1
		was = b
		if mq.eyes_shut():
			shut_frames += 1
		var p: Vector3 = mq.real_node.position
		moved += p.distance_to(last)
		last = p
	print("stared %.0f s: %d blinks, eyes shut %d frames, sanity %.1f -> %.1f (-%.2f), real one moved %.2f m, stare=%.1f" % [
		secs, blinks, shut_frames, s0, player.sanity, s0 - player.sanity, moved, mq.stare])
	quit()
