extends SceneTree
## The wall hand letting go (wall_hand.gd): peeks round a wall edge with the hand on it, then walks back off
## the wall (and, from the start again, strafes away from it; and from out of reach, walks up to it), printing
## the hand's state each few ticks and saving frames as it goes, so you can see it push off and drop instead
## of hanging in the air. Needs a window.
## Env: LEVEL (index, default 0), SHOT (output prefix, default res://release).
## godot --path . --resolution 1280x800 --script res://tools/shot_wall_release.gd

const ShotPeek := preload("res://tools/shot_peek.gd")

func _initialize() -> void:
	var env_or := func(k: String, d: String) -> String: return OS.get_environment(k) if OS.get_environment(k) != "" else d
	var game: Node = root.get_node("Game")
	game.level_index = int(env_or.call("LEVEL", "0"))
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(2.0).timeout
	game.playing = true
	var level: Node = main.get_node("Level")
	var player: CharacterBody3D = main.get_node("Player")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	main.get_node("UI").visible = false
	var prefix: String = env_or.call("SHOT", "res://release")
	var peek := ShotPeek.new()
	# name, way to walk (camera space: x right, z back), m/s, how far off the wall it starts
	for run in [["back", Vector3(0, 0, 1), 1.2, 0.5], ["strafe", Vector3(1, 0, 0), 1.2, 0.5], ["approach", Vector3(0, 0, -1), 0.3, 0.95]]:
		var spot: Array = peek._find_edge(level, player, -1, run[3])
		if spot.is_empty():
			print("release: no wall edge")
			break
		player.flash_on = false
		player.global_position = spot[1]
		player.velocity = Vector3.ZERO
		player.rotation.y = spot[2]
		player.cam.rotation.x = 0.0
		await _drive(player, 1.4, Vector3.ZERO, "%s_%s" % [prefix, run[0]], 0)
		_save("%s_%s_on.png" % [prefix, run[0]])
		await _drive(player, 1.6, (run[1] as Vector3) * float(run[2]), "%s_%s" % [prefix, run[0]], 4)
		player.global_position = spot[0]
		await _drive(player, 1.0, Vector3.ZERO, "", 0)
	quit()

func _save(path: String) -> void:
	var img := root.get_texture().get_image()
	if img != null and not img.is_empty():
		img.save_png(path)

## Peek and hands run by hand (see shot_peek.gd), the body carried along `move` (camera space, m/s); every
## few ticks a line of the right hand's state, and `frames` frames saved evenly over the run
func _drive(player: CharacterBody3D, secs: float, move: Vector3, shot: String, frames: int) -> void:
	var dt := 1.0 / Engine.physics_ticks_per_second
	var n := int(secs / dt)
	var hands: Node = player.torch._hands
	for i in n:
		await physics_frame
		paused = false
		player.global_position += player.global_transform.basis * move * dt
		player.peek.update(dt, player, player.eye, true)
		player.torch.set_peek(player.peek.side, player.peek.leaning, player.peek.edge, player.peek.normal,
				player.peek.out, player.peek.dist, true, false)
		player.torch.update(dt, player.flash_on, false, false, player.bob)
		player._update_flashlight(dt)
		player._update_head(dt, Vector2.ZERO, false, false, false)
		var h = hands._hands[1]
		if shot != "" and i % 6 == 0:
			print("%s t %.2f  peek %d lean %s dist %.2f  mode %d off %s over %.3f strain %.2f u %.2f grab %.2f" % [shot.get_file(), i * dt,
					player.peek.side, player.peek.leaning, player.peek.dist, h.mode, h.off, h.over, h.strain, h.u, h.grab])
		if frames > 0 and i % (n / frames) == 0:
			_save("%s_%02d.png" % [shot, i / (n / frames)])
