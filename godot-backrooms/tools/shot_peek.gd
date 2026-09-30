extends SceneTree
## Stands the player at a wall edge in a level and saves screenshots of the corner peek (peek.gd) and the
## hands (wall_hand.gd): torch up peeking left (right hand on the wall, torch passed to the left) and
## right, torch away, crouched, and too far off to take hold (the open hand). Needs a window; the UI is
## hidden (HUD=1 keeps it).
## Env: LEVEL (index, default 0), SHOT (output prefix, default res://peek).
## godot --path . --resolution 1280x800 --script res://tools/shot_peek.gd

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
	# the mouse stays free so the player's own tick stays off (_drive runs it), and the window on top so
	# it keeps drawing
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	if env_or.call("HUD", "") == "":
		main.get_node("UI").visible = false
	var prefix: String = env_or.call("SHOT", "res://peek")
	var shots := [
		# name, side (-1 left / 1 right), how far off the wall (m), torch, crouch
		["torch_left", -1, 0.55, true, false],
		["torch_right", 1, 0.55, true, false],
		["away_left", -1, 0.55, false, false],
		["away_right_crouch", 1, 0.55, false, true],
		["torch_left_far", -1, 0.95, true, false],
	]
	for s in shots:
		var spot: Array = _find_edge(level, player, s[1], s[2])
		if spot.is_empty():
			print("peek: no wall edge on side %d" % s[1])
			continue
		var mid: Vector3 = spot[0]
		player.flash_on = s[3]
		player.global_position = spot[1]
		player.velocity = Vector3.ZERO
		player.rotation.y = spot[2]
		player.cam.rotation.x = 0.0
		await _drive(player, 0.45, s[4])
		_save("%s_%s_in.png" % [prefix, s[0]])
		print("peek %s (in): side %d amount %.2f" % [s[0], player.peek.side, player.peek.amount])
		await _drive(player, 1.4, s[4])
		_save("%s_%s.png" % [prefix, s[0]])
		var hands: Node = player.torch._hands
		print("peek %s: side %d amount %.2f offset %.2f dist %.2f  modes L %d R %d  torch in %d" % [s[0], player.peek.side,
				player.peek.amount, player.peek.offset, player.peek.dist, hands.mode_of(0), hands.mode_of(1), player.torch._torch_in])
		# step back off the wall so the next shot starts from no peek
		player.global_position = mid
		await _drive(player, 1.0, false)
	quit()

## A spot `back` m off a wall whose edge is 0.25 m out on `side`, checked with the peek's own rays:
## [the free cell's middle, where to stand, the yaw to face the wall], or [] if none.
func _find_edge(level: Node, player: CharacterBody3D, side: int, back: float) -> Array:
	var walls: Dictionary = level.walls
	var cell: float = level.CELL
	for x in range(1, level.size - 1):
		for z in range(1, level.size - 1):
			var c := Vector2i(x, z)
			if walls.has(c):
				continue
			for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
				var r := Vector2i(-d.y, d.x) * side
				if not walls.has(c + d) or walls.has(c + d + r) or walls.has(c + r) or walls.has(c - d):
					continue
				var f := Vector3(d.x, 0.0, d.y)
				var rw := Vector3(-f.z, 0.0, f.x) * side
				var mid := Vector3(c.x * cell, 0.1, c.y * cell)
				var at := mid + f * (cell * 0.5 - back) + rw * (cell * 0.5 - 0.25)
				var yaw := atan2(-f.x, -f.z)
				player.global_position = at
				player.rotation.y = yaw
				if player.peek._detect(player, player.STAND_H) == side:
					return [mid, at, yaw]
	return []

func _save(path: String) -> void:
	var img := root.get_texture().get_image()
	if img != null and not img.is_empty():
		img.save_png(path)

## The player's tick skips everything while the mouse isn't captured, which a script launch can't count
## on, so the parts that matter here are run by hand: the peek, the hands, the torch, the head.
func _drive(player: CharacterBody3D, secs: float, crouch: bool) -> void:
	var dt := 1.0 / Engine.physics_ticks_per_second
	for i in int(secs / dt):
		await physics_frame
		paused = false
		player.is_crouching = crouch
		player.eye = lerpf(player.eye, player.CROUCH_H if crouch else player.STAND_H, minf(1.0, dt * 10.0))
		player.peek.update(dt, player, player.eye, true)
		player.torch.set_peek(player.peek.side, player.peek.leaning, player.peek.edge, player.peek.normal,
				player.peek.out, player.peek.dist, true, crouch)
		player.torch.update(dt, player.flash_on, false, false, player.bob)
		player._update_flashlight(dt)
		player._update_head(dt, Vector2.ZERO, false, crouch, false)
