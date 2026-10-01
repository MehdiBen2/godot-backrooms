extends SceneTree
## Checks the stacked floors in the real game (needs a window, not --headless) and saves screenshots: the
## look-only floors above and below the one you are on, seen through the holes in the slabs (a pit over an
## open cell of the floor below), and the fall through one. See level_builder.gd `shells`, level_shell.gd.
## Env: LEVEL (index, default 0), FLOOR (default 0), PRESET (default high), SHOT (output prefix, default
## res://shot_stack), OFF (as tools/shot_level.gd: fog,vfog,...), MODE:
##   look (default)  views from the edge of the first hole: across, down, up
##   swap            holds still in the slab under the hole, where the floor below takes over, and measures how
##                   much of the picture changes across the swap (against two shots of the same floor)
##   fall            walks a body the player's size off the edge and lets it drop, floor after floor
## VIEW="x,y,z,dx,dz,pitch;...": these views instead (x, z in cells, y in metres).
## godot --path . --resolution 1280x720 --script res://tools/shot_stack.gd

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
	level = main.get_node("Level")
	var worst := 0.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		var f0 := Time.get_ticks_usec()
		await process_frame
		frames += 1
		if frames > 3: worst = maxf(worst, (Time.get_ticks_usec() - f0) / 1000.0)     # the first frames are the game itself loading
	game.playing = true
	player = main.get_node("Player")
	cam = player.get_node("Camera3D")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE          # the player holds still wherever it is put
	main.get_node("UI").visible = false
	prefix = env_or.call("SHOT", "res://shot_stack")
	var e: Environment = (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	for k in str(env_or.call("OFF", "")).split(",", false):
		match k:
			"vfog": e.volumetric_fog_enabled = false
			"fog": e.fog_enabled = false
			"glow": e.glow_enabled = false
			"torch":
				player.flash_on = false
				player.flash.visible = false
	print("floor %d: %d holes down, %d up; longest frame while the other floors were built %.0f ms" % [game.level_floor, level.through.size(), level.open_above.size(), worst])
	_report()
	if level.through.is_empty() and level.open_above.is_empty():
		print("no hole on this floor")
		quit(1)
		return
	match env_or.call("MODE", "look"):
		"swap": await _swap()
		"fall": await _fall()
		_: await _look()
	quit()

func _report() -> void:
	var ks: Array = level.shells.keys()
	ks.sort()
	for k: int in ks:
		var s: Node3D = level.shells[k]
		var lights := s.find_children("*", "OmniLight3D", true, false).size()
		print("  floor %d at y %.1f: %s, %d nodes, %d lights" % [k, s.position.y, "the floor itself, left standing" if s.has_meta("demoted") else "a copy", s.get_child_count(), lights])

## The edge of the hole nearest the spawn: [the cell to stand on, the hole cell beside it]
func _edge() -> Array:
	var holes: Dictionary = level.through if not level.through.is_empty() else level.open_above
	var from: Vector2i = level.cell_of(level.spawn_pos)
	var best: Array = []
	for h: Vector2i in holes:
		for n: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var c: Vector2i = h + n
			if holes.has(c) or level.walls.has(c) or level.pits.has(c): continue
			if best.is_empty() or (c - from).length_squared() < (best[0] - from).length_squared(): best = [c, h]
	return best

func _stand(at: Vector3, to: Vector3, pitch: float) -> void:
	player.global_position = at
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(-to.x, -to.z)
	cam.rotation.x = deg_to_rad(pitch)

func _shot(name: String, wait := 1.2) -> Image:
	await create_timer(wait).timeout
	var img := root.get_texture().get_image()
	img.save_png("%s_%s.png" % [prefix, name])
	return img

func _look() -> void:
	var edge := _edge()
	if edge.is_empty():
		print("no floor beside a hole to stand on")
		return
	var c: Vector2i = edge[0]
	var d := Vector2(edge[1] - c)
	var cell: float = level.CELL
	var at := Vector3(c.x * cell, 0.1, c.y * cell)
	var out := Vector3(d.x, 0, d.y)
	var side := Vector3(-d.y, 0, d.x)
	var views := [
		["across", at, out, 0.0], ["down", at + out * 1.6, out, -42.0], ["down_steep", at + out * 2.0, out, -72.0],
		["up", at + out * 1.6, out, 38.0], ["along", at + out * 1.2, out + side * 1.4, -12.0], ["back", at + out * 0.5, -out, 0.0]]
	var custom := OS.get_environment("VIEW")
	if custom != "":
		views = []
		for part in custom.split(";", false):
			var f := part.split_floats(",")
			views.append(["view%d" % views.size(), Vector3(f[0] * cell, f[1], f[2] * cell), Vector3(f[3], 0, f[4]), f[5]])
	for v: Array in views:
		_stand(v[1], v[2], v[3])
		await _shot(v[0])
	print("%d views shot from cell %s" % [views.size(), c])

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

func _swap() -> void:
	if level.through.is_empty():
		print("no hole down from this floor")
		return
	var edge := _edge()
	var h: Vector2i = edge[1]
	var d := Vector2(h - edge[0])
	var cell: float = level.CELL
	var out := Vector3(d.x, 0, d.y)
	# in the slab, in the hole, a hand above where the floor below takes over
	var at := Vector3(h.x * cell, -level.FALL_SWAP + 0.1, h.y * cell) + out * cell * 0.5
	for v: Array in [["down", out, -60.0], ["level", out, 0.0], ["up", -out, 55.0]]:
		var start: int = game.level_floor
		_stand(at, v[1], v[2])
		var before := await _shot("swap_%s_0" % v[0])
		var again := await _shot("swap_%s_1" % v[0])
		var t0 := Time.get_ticks_msec()
		var u0 := Time.get_ticks_usec()
		game.change_floor(start - 1, Vector2(h), "fall", level.STOREY_H)
		var call_ms := (Time.get_ticks_usec() - u0) / 1000.0
		var worst := 0.0
		var frames := 0
		var mid: Image = null
		while level.rebuilding and frames < 600:
			var f0 := Time.get_ticks_usec()
			await process_frame
			worst = maxf(worst, (Time.get_ticks_usec() - f0) / 1000.0)
			frames += 1
			if frames == 3: mid = root.get_texture().get_image()
		await process_frame
		var first := root.get_texture().get_image()
		first.save_png("%s_swap_%s_2.png" % [prefix, v[0]])
		print("view %s: floor %d -> %d, the swap itself %.0f ms, built over %d frames in %d ms, longest frame %.0f ms, player at y %.2f" % [v[0], start,
			game.level_floor, call_ms, frames, Time.get_ticks_msec() - t0, worst, player.global_position.y])
		var after := await _shot("swap_%s_3" % v[0])
		print("  picture change (of 255): same floor twice %.2f, while it is built %.2f, the frame it shows %.2f, settled %.2f" % [
			_diff(before, again), _diff(before, mid) if mid != null else -1.0, _diff(before, first), _diff(before, after)])
		_report()
		# and back up, the way a respawn or the stairs would have it, for the next view
		game.level_floor = start
		level.load_level_seamless(game.level_index)
		game.level_floor = start
		if start != 0: level.rebuild_floor_seamless(start, {})
		await create_timer(1.5).timeout

func _fall() -> void:
	var edge := _edge()
	var c: Vector2i = edge[0]
	var d := Vector2(edge[1] - c)
	var cell: float = level.CELL
	var out := Vector3(d.x, 0, d.y)
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
	probe.global_position = Vector3(c.x * cell, 0.05, c.y * cell)
	_stand(probe.global_position, out, -35.0)
	await create_timer(0.5).timeout
	var start: int = game.level_floor
	var floor_was := start
	var ticks := 0
	var landed := 0
	var worst := 0.0
	var shots := 0
	while ticks < 3000:
		# walk out over the hole, then straight on down
		var over: bool = level.pits.has(level.cell_of(probe.global_position))
		var walk := out * (2.6 if (not over or probe.is_on_floor()) else 0.0)
		probe.velocity = Vector3(walk.x, probe.velocity.y, walk.z)
		if not probe.is_on_floor(): probe.velocity.y -= 20.0 / Engine.physics_ticks_per_second
		probe.move_and_slide()
		player.global_position = probe.global_position
		ticks += 1
		var f0 := Time.get_ticks_usec()
		await physics_frame
		var ms := (Time.get_ticks_usec() - f0) / 1000.0
		worst = maxf(worst, ms)
		if absf(player.global_position.y - probe.global_position.y) > 1.0:      # the floor below took over: it lifted the player
			probe.global_position = player.global_position
		if game.level_floor != floor_was:
			print("  tick %d: floor %d -> %d at y %.2f (now %.2f), falling at %.1f m/s, that frame %.0f ms" % [ticks, floor_was, game.level_floor,
				probe.global_position.y - level.STOREY_H, probe.global_position.y, -probe.velocity.y, ms])
			floor_was = game.level_floor
			if shots < 3:
				root.get_texture().get_image().save_png("%s_fall_%d.png" % [prefix, shots])
				shots += 1
		if probe.is_on_floor() and not level.rebuilding and ticks > 30:
			landed += 1
			if landed == 1:
				print("  tick %d: on the ground on floor %d, cell %s, y %.2f" % [ticks, game.level_floor, level.cell_of(probe.global_position), probe.global_position.y])
			if landed > 90 and (game.level_floor != start or ticks > 900):
				break
		else:
			landed = 0
		if probe.global_position.y < -40.0:
			print("  tick %d: fell out of the world on floor %d" % [ticks, game.level_floor])
			break
	print("fall over after %d ticks on floor %d at %s, longest frame %.0f ms" % [ticks, game.level_floor, probe.global_position.snappedf(0.01), worst])
	_report()
	await _shot("fall_end")
	probe.queue_free()
