extends SceneTree
## Checks a floor's stairwells in the real game (needs a window, not --headless) and saves screenshots.
## Env: LEVEL (index, default 0), FLOOR (default 0), WELL (which stairwell of the floor, default 0),
## PRESET (default high), SHOT (output prefix, default res://shot_stairs), MODE:
##   look (default)  views of the well from the room, its doorway, its landings and flights
##   swap            stands on the far landing, takes the floor swap up and back down, and measures how much of
##                   the picture changed across each (against two shots of the same floor as the noise floor)
##   walk            walks the player up to the next floor and back down with the real controls, printing the path
## godot --path . --resolution 1280x720 --script res://tools/shot_stairs.gd

var game: Node
var main: Node
var level: Node
var player: CharacterBody3D
var cam: Camera3D
var prefix := ""

func _initialize() -> void:
	var env_or := func(k: String, d: String) -> String: return OS.get_environment(k) if OS.get_environment(k) != "" else d
	game = root.get_node("Game")
	game.level_index = int(env_or.call("LEVEL", "0"))
	game.level_floor = int(env_or.call("FLOOR", "0"))
	game.respawned = true
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	root.get_node("Gfx").set_preset(env_or.call("PRESET", "high"))
	await create_timer(2.0).timeout
	game.playing = true
	level = main.get_node("Level")
	player = main.get_node("Player")
	cam = player.get_node("Camera3D")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE          # the player holds still wherever it is put
	main.get_node("UI").visible = false
	prefix = env_or.call("SHOT", "res://shot_stairs")
	print("floor %d: %d stairwells" % [game.level_floor, level.stairwells.size()])
	for s in level.stairwells:
		print("  at cell %s, up %s, down %s" % [level.cell_of(s.global_position), s.up, s.down])
	var which := int(env_or.call("WELL", "0"))
	if which >= level.stairwells.size():
		print("no such stairwell")
		quit(1)
		return
	match env_or.call("MODE", "look"):
		"swap": await _swap(which)
		"walk": await _walk(which)
		_: await _look(which)
	quit()

## Stand at `at` in the well's own frame (x along its arrow, z across, y up), looking along `to`
func _stand(well: Node3D, at: Vector3, to: Vector3, pitch := 0.0) -> void:
	player.global_position = well.to_global(at)
	player.velocity = Vector3.ZERO
	var d := well.global_transform.basis * to
	player.rotation.y = atan2(-d.x, -d.z)
	cam.rotation.x = deg_to_rad(pitch)

func _shot(name: String) -> Image:
	await create_timer(1.2).timeout
	var img := root.get_texture().get_image()
	img.save_png("%s_%s.png" % [prefix, name])
	return img

func _look(which: int) -> void:
	var w: Node3D = level.stairwells[which]
	var views := [
		["room", Vector3(-9.0, 0.1, 3.2), Vector3(1, 0, -0.42), 4.0],
		["door", Vector3(-4.2, 0.1, 1.15), Vector3(1, 0, 0), 2.0],
		["landing", Vector3(-1.5, 0.05, 1.15), Vector3(1, 0, 0), 8.0],
		["landing_down", Vector3(-1.2, 0.05, -1.15), Vector3(1, 0, 0), -22.0],
		["landing_back", Vector3(-0.5, 0.05, -0.2), Vector3(-1, 0, -0.5), 2.0],
		["up_flight", Vector3(1.6, 1.0, 1.15), Vector3(1, 0, 0), 12.0],
		["far_landing", Vector3(5.2, 2.75, 1.2), Vector3(0.25, 0, -1), 0.0],
		["far_up", Vector3(6.0, 2.75, -0.9), Vector3(-1, 0, -0.06), 14.0],
		["far_down", Vector3(6.0, 2.75, 1.15), Vector3(-1, 0, 0), -24.0],
	]
	for v: Array in views:
		_stand(w, v[1], v[2], v[3])
		await _shot(v[0])
	print("%d views shot" % views.size())

## Mean difference between two frames, 0..255
func _diff(a: Image, b: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			sum += absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)
			n += 3
	return sum / n * 255.0

func _swap(which: int) -> void:
	var w: Node3D = level.stairwells[which]
	var start: int = game.level_floor
	# the far landing, in the down-lane half but short of the line where the floor above takes over
	var views := [["a", Vector3(5.7, 2.75, -0.8), Vector3(-1, 0, -0.08), 10.0], ["b", Vector3(5.9, 2.75, -0.75), Vector3(-0.3, 0, 1), 0.0],
		["c", Vector3(6.1, 2.75, -0.8), Vector3(-1, 0, 0.6), -8.0]]
	for v: Array in views:
		_stand(w, v[1], v[2], v[3])
		var before := await _shot("swap_%s_0" % v[0])
		var again := await _shot("swap_%s_1" % v[0])
		# over the line and back: the floor above is loaded, and stays (the way back is further across)
		var t0 := Time.get_ticks_msec()
		_stand(w, v[1] + Vector3(0, 0, -0.5), v[2], v[3])
		await process_frame
		await process_frame
		await process_frame
		w = level.stairwells[_same_well(w)]
		print("view %s: floor %d -> %d in about %d ms, player now at local %s" % [v[0], start, game.level_floor, Time.get_ticks_msec() - t0, w.to_local(player.global_position)])
		_stand(w, v[1] - Vector3(0, w.STOREY, 0), v[2], v[3])
		var after := await _shot("swap_%s_2" % v[0])
		print("  noise floor %.2f, across the swap %.2f (of 255)" % [_diff(before, again), _diff(before, after)])
		# and down again
		_stand(w, Vector3(v[1].x, v[1].y - w.STOREY, -0.3), v[2], v[3])
		await process_frame
		await process_frame
		await process_frame
		w = level.stairwells[_same_well(w)]
		print("  back down: floor %d, player at local %s" % [game.level_floor, w.to_local(player.global_position)])

## After a floor swap the well is a new node: the one standing where `old` stood
func _same_well(old: Node3D) -> int:
	var at := old.global_position if is_instance_valid(old) else player.global_position
	var best := 0
	for i in level.stairwells.size():
		if level.stairwells[i].global_position.distance_to(at) < level.stairwells[best].global_position.distance_to(at): best = i
	return best

## Hold a movement key for `secs`, facing `to` (the well's frame), logging where the player gets to
func _go(well: Node3D, to: Vector3, secs: float, label: String) -> Node3D:
	var d := well.global_transform.basis * to
	player.rotation.y = atan2(-d.x, -d.z)
	Input.action_press("move_forward")
	var t := 0.0
	var worst := 0.0
	var last_y := player.global_position.y
	while t < secs:
		await physics_frame
		t += 1.0 / Engine.physics_ticks_per_second
		if level.stairwells.is_empty(): break
		well = level.stairwells[_same_well(well)]
		var y := player.global_position.y
		if absf(y - last_y) < 2.0: worst = maxf(worst, absf(y - last_y))      # a floor swap moves it a whole storey
		last_y = y
	Input.action_release("move_forward")
	print("  %-22s floor %d  local %s  on floor %s  biggest step %.3f m" % [label, game.level_floor, well.to_local(player.global_position).snappedf(0.01), player.is_on_floor(), worst])
	return well

func _walk(which: int) -> void:
	var w: Node3D = level.stairwells[which]
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_stand(w, Vector3(-4.5, 0.1, 1.15), Vector3(1, 0, 0))
	await create_timer(0.5).timeout
	print("walking up from floor %d" % game.level_floor)
	w = await _go(w, Vector3(1, 0, 0), 5.2, "in and up the flight")
	w = await _go(w, Vector3(0, 0, -1), 1.1, "across the far landing")
	w = await _go(w, Vector3(-1, 0, 0), 4.2, "up the second flight")
	w = await _go(w, Vector3(0, 0, 1), 1.0, "across the landing")
	w = await _go(w, Vector3(-1, 0, 0), 1.6, "out of the door")
	await _shot("walk_top")
	print("walking back down from floor %d" % game.level_floor)
	w = await _go(w, Vector3(1, 0, 0), 1.3, "in")
	w = await _go(w, Vector3(0, 0, -1), 1.0, "across the landing")
	w = await _go(w, Vector3(1, 0, 0), 3.6, "down the flight")
	w = await _go(w, Vector3(0, 0, 1), 1.1, "across the far landing")
	w = await _go(w, Vector3(-1, 0, 0), 5.0, "down and out")
	await _shot("walk_bottom")
