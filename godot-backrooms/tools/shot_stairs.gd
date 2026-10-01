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
		["room", Vector3(-13.0, 0.1, 6.5), Vector3(1, 0, -0.42), 6.0],
		["door", Vector3(-5.5, 0.1, 2.4), Vector3(1, 0, 0), 4.0],
		["landing", Vector3(-1.6, 0.05, 2.4), Vector3(1, 0, -0.1), 10.0],
		["landing_down", Vector3(-1.2, 0.05, -2.4), Vector3(1, 0, 0), -18.0],
		["landing_back", Vector3(0.6, 0.05, -1.2), Vector3(-1, 0, -0.35), 6.0],
		["up_flight", Vector3(3.5, 1.7, 2.4), Vector3(1, 0, 0), 14.0],
		["far_landing", Vector3(8.6, w.HALF + 0.05, 2.6), Vector3(0.3, 0, -1), 4.0],
		["far_up", Vector3(10.2, w.HALF + 0.05, -2.0), Vector3(-1, 0, -0.06), 16.0],
		["far_down", Vector3(10.2, w.HALF + 0.05, 2.4), Vector3(-1, 0, 0), -22.0],
	]
	# VIEW="x,y,z,dx,dz,pitch;...": these views instead (the well's own frame)
	var custom := OS.get_environment("VIEW")
	if custom != "":
		views = []
		for part in custom.split(";", false):
			var f := part.split_floats(",")
			views.append(["view%d" % views.size(), Vector3(f[0], f[1], f[2]), Vector3(f[3], 0, f[4]), f[5]])
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
	var storey: float = w.STOREY
	var cell: Vector2i = level.cell_of(w.to_global(Vector3.ZERO))
	# the far landing, in the down-lane half, just short of the line where the floor above takes over
	var y: float = w.HALF + 0.05
	var z: float = w.SWAP_UP + 0.25
	var views := [["a", Vector3(9.6, y, z), Vector3(-1, 0, -0.08), 10.0], ["b", Vector3(10.0, y, z), Vector3(-0.3, 0, 1), 0.0],
		["c", Vector3(10.4, y, z), Vector3(-1, 0, 0.6), -8.0], ["d", Vector3(8.6, y, z), Vector3(0.2, 0, 1), 4.0]]
	for v: Array in views:
		_stand(w, v[1], v[2], v[3])
		var before := await _shot("swap_%s_0" % v[0])
		var again := await _shot("swap_%s_1" % v[0])
		# the swap the well makes when you cross that line, taken here without moving: the same view either side of it
		var home := w.global_position
		var t0 := Time.get_ticks_msec()
		game.change_floor(start + 1, Vector2(cell), "stairs", -storey)
		var worst := 0.0
		var frames := 0
		var mid: Image = null
		while level.rebuilding and frames < 600:
			var f0 := Time.get_ticks_usec()
			await process_frame
			worst = maxf(worst, (Time.get_ticks_usec() - f0) / 1000.0)
			frames += 1
			if frames == 3: mid = root.get_texture().get_image()
		w = level.stairwells[_same_well(home)]
		print("view %s: floor %d -> %d, built over %d frames in %d ms, longest frame %.0f ms, player at local %s" % [v[0], start, game.level_floor,
			frames, Time.get_ticks_msec() - t0, worst, w.to_local(player.global_position).snappedf(0.01)])
		var after := await _shot("swap_%s_2" % v[0])
		print("  picture change (of 255): same floor twice %.2f, while it is rebuilt %.2f, on the floor above %.2f" % [
			_diff(before, again), _diff(before, mid) if mid != null else -1.0, _diff(before, after)])
		# and down again
		game.change_floor(start, Vector2(cell), "stairs", storey)
		while level.rebuilding: await process_frame
		w = level.stairwells[_same_well(home)]
		var back := await _shot("swap_%s_3" % v[0])
		print("  back down: floor %d, player at local %s, picture change %.2f" % [game.level_floor, w.to_local(player.global_position).snappedf(0.01), _diff(before, back)])

## After a floor swap the well is a new node: the one standing at `at`, where the old one stood
func _same_well(at: Vector3) -> int:
	var best := 0
	for i in level.stairwells.size():
		if level.stairwells[i].global_position.distance_to(at) < level.stairwells[best].global_position.distance_to(at): best = i
	return best

## Walks a body the player's size (the player goes with it, so the well sees it) to each spot in turn, in the
## well's own frame, at `speed` m/s, and says where it got to: off the floor, stuck, or jolted up or down
func _walk_path(well: Node3D, probe: CharacterBody3D, path: Array, speed: float) -> Node3D:
	var home := Vector3(well.global_position.x, 0.0, well.global_position.z)
	for leg: Array in path:
		var target: Vector3 = leg[1]
		var ticks := 0
		var air := 0
		var jolt := 0.0
		var slowest := 0.0
		while ticks < 1200:
			var here := well.to_local(probe.global_position)
			var to := Vector3(target.x - here.x, 0.0, target.z - here.z)
			if to.length() < 0.15: break
			var dir := (well.global_transform.basis * to.normalized())
			probe.velocity = Vector3(dir.x * speed, probe.velocity.y, dir.z * speed)
			if not probe.is_on_floor(): probe.velocity.y -= 20.0 / Engine.physics_ticks_per_second
			var y0 := probe.global_position.y
			probe.move_and_slide()
			jolt = maxf(jolt, absf(probe.global_position.y - y0))
			if not probe.is_on_floor(): air += 1
			player.global_position = probe.global_position
			ticks += 1
			var f0 := Time.get_ticks_usec()
			await physics_frame
			slowest = maxf(slowest, (Time.get_ticks_usec() - f0) / 1000.0)
			if absf(player.global_position.y - probe.global_position.y) > 1.0:      # the floor was swapped: the well moved it
				probe.global_position = player.global_position
			if not level.stairwells.is_empty():
				var best := 0
				for i in level.stairwells.size():
					var q: Vector3 = level.stairwells[i].global_position
					if Vector2(q.x - home.x, q.z - home.z).length() < Vector2(level.stairwells[best].global_position.x - home.x, level.stairwells[best].global_position.z - home.z).length(): best = i
				well = level.stairwells[best]
		print("  %-26s floor %d  at %s  %s  off the floor %d ticks, biggest step %.3f m, slowest frame %.0f ms" % [leg[0], game.level_floor,
			well.to_local(probe.global_position).snappedf(0.01), "ok" if ticks < 1200 else "STUCK", air, jolt, slowest])
	return well

func _walk(which: int) -> void:
	var w: Node3D = level.stairwells[which]
	var probe := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.42
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	probe.add_child(cs)
	probe.collision_layer = 0
	probe.collision_mask = 1
	main.add_child(probe)
	probe.add_collision_exception_with(player)           # the player rides along inside it
	var lane: float = w.LANE_MID
	var top: float = w.XB + 1.5
	var up := [["to the door", Vector3(-3.0, 0, lane)], ["onto the landing", Vector3(-0.6, 0, lane)], ["up the first flight", Vector3(top, 0, lane)],
		["across the far landing", Vector3(top, 0, -lane)], ["up the second flight", Vector3(-0.6, 0, -lane)], ["across the landing", Vector3(-0.6, 0, lane)],
		["out of the door", Vector3(-4.5, 0, lane)]]
	var down := [["back in", Vector3(-0.6, 0, lane)], ["across the landing", Vector3(-0.6, 0, -lane)], ["down the first flight", Vector3(top, 0, -lane)],
		["across the far landing", Vector3(top, 0, lane)], ["down the second flight", Vector3(-0.6, 0, lane)], ["out of the door", Vector3(-4.5, 0, lane)]]
	for speed: float in [2.6, 4.55]:
		probe.global_position = w.to_global(Vector3(-5.0, 0.05, lane))
		probe.velocity = Vector3.ZERO
		print("up from floor %d at %.1f m/s" % [game.level_floor, speed])
		w = await _walk_path(w, probe, up, speed)
		print("down from floor %d" % game.level_floor)
		w = await _walk_path(w, probe, down, speed)
	probe.queue_free()
