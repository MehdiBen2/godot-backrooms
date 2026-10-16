extends SceneTree
## Watches THE MANNEQUIN kill another survivor, as their friends see it in co-op: a remote survivor
## (remote_player.gd, fed snapshots like the network does) is caught and its suit plays death_neck_snap. The
## real one holds still where it caught them; at the crack you, looking on, blink, and it is behind them with
## its hands on their head when your eyes open (mannequin.gd net_watch_kill). Then they die (the dead flag
## comes at mannequin_snap.gd TOTAL) and get back up (respawn). Snapshots the beats (needs a window).
## Env: LEVEL (index, needs a Mannequin zone), SHOT (prefix, default res://mq_watch), SIDE (camera yaw offset, rad).
## godot --path . --resolution 960x540 --script res://tools/shot_mq_watch.gd

const ID := 99
const SHOTS := [0.1, 1.2, 2.2, 2.3, 2.45, 2.75, 3.2, 3.9, 4.25, 4.8, 6.5, 9.0]
const DEAD_AT := 4.6        # mannequin_snap.gd TOTAL: Game.kill_player on their machine
const UP_AT := 8.0          # respawned

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
	main.set_paused(false)                      # (the start screen)
	main.get_node("UI").visible = false
	player.set_physics_process(false)
	game.god_mode = true                        # once it is done with them it hunts again: not the camera
	mq.process_mode = Node.PROCESS_MODE_INHERIT
	if not mq.ready_ok or mq.real_node == null:
		print("FAILED: no mannequin on this level")
		quit(1)
		return
	mq.awake = true

	# a survivor a little way off the real one, facing away from it: it comes up behind them
	var net: Node = root.get_node("Net")
	var r: Node3D = load("res://scripts/Net/remote_player.gd").new()
	r.peer_id = ID
	net.add_child(r)
	r.set_label("FRIEND")
	net.remotes[ID] = r
	var at: Vector3 = mq.nav.resolve(mq.real_node.position + Vector3(1.6, 0.0, 0.0), mq.RADIUS)
	at.y = 0.0
	var yaw := atan2(-(at.x - mq.real_node.position.x), -(at.z - mq.real_node.position.z)) + PI   # back to it
	var clock := 0.0
	var push := func(dead: bool) -> void:
		r.push_state(clock, at, yaw, 0.0, 0.0, 2 | 8 | (4 if dead else 0), game.level_index, game.level_floor)
	for i in 30:
		clock += 0.05
		push.call(false)
		await create_timer(0.05).timeout
		if not game.playing:
			main.set_paused(false)
			main.get_node("UI").visible = false
	print("clips: ", r.clips)

	# the friend's camera: off to the side, a few metres away
	var side := float(env_or.call("SIDE", "1.2"))
	var view := Basis(Vector3.UP, yaw + side) * Vector3(0, 0, -3.6)
	player.global_position = at + view
	player.rotation.y = atan2(-(at.x - player.global_position.x), -(at.z - player.global_position.z))
	cam.position = Vector3(0, 1.4, 0)
	cam.rotation = Vector3(-0.12, 0.0, 0.0)

	r.play_kill()
	mq.net_watch_kill(ID)
	var t := 0.0
	var shots := SHOTS.duplicate()
	var prefix: String = env_or.call("SHOT", "res://mq_watch")
	var send := 0.0
	Engine.max_physics_steps_per_frame = 64     # a slow window must not run the monsters in slow motion
	while not shots.is_empty():
		var dt: float = mq.get_process_delta_time() if t > 0.0 else 0.0
		t += dt                                  # game time, as remote_player.gd and the mannequin see it
		send -= dt
		if send <= 0.0:
			send = 0.05
			clock += 0.05
			push.call(t >= DEAD_AT and t < UP_AT)
		await process_frame
		if not game.playing:
			main.set_paused(false)                  # a window started from a terminal loses focus: main.gd pauses
			main.get_node("UI").visible = false
		if t >= shots[0]:
			shots.pop_front()
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("%s_%04.2f.png" % [prefix, t])
			print("t=%.2f lids=%.2f killing=%s fate=%.2f dead=%s | mq at %s headTilt=%.2f cut=%s watching=%s | fps=%d" % [t,
				game.fx_blink, r.loco.killing, r.loco.tree.get("parameters/fate/blend_amount"), r.dead, mq.real_node.position,
				mq.real_pose.get("headTilt", 0.0), mq._watch.get("cut", "-"), not mq._watch.is_empty(), Engine.get_frames_per_second()])
	quit()
