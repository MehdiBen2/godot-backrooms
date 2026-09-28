extends SceneTree
## Renders a level from the spawn, looking down its longest open line, and saves screenshots (needs a
## window, not --headless). Env: LEVEL (index, default 0), PRESET (low..ultra, default high),
## SHOT (output prefix, default res://shot), PITCH (deg, default 8: a little up, to see the ceiling).
## xvfb-run -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 --script res://tools/shot_level.gd

func _initialize() -> void:
	var env_or := func(k: String, d: String) -> String: return OS.get_environment(k) if OS.get_environment(k) != "" else d
	var game: Node = root.get_node("Game")
	game.level_index = int(env_or.call("LEVEL", "0"))
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	root.get_node("Gfx").set_preset(env_or.call("PRESET", "high"))
	await create_timer(2.0).timeout
	game.playing = true
	var level: Node = main.get_node("Level")
	var player: Node3D = main.get_node("Player")
	var cam: Camera3D = player.get_node("Camera3D")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# face the longest open run from where we stand (SPOT=far: first move to the cell with the longest run)
	var c: Vector2i = level.cell_of(player.global_position)
	if env_or.call("SPOT", "") == "far":
		var top := -1
		for x in range(1, level.size - 1):
			for z in range(1, level.size - 1):
				var here := Vector2i(x, z)
				if level.walls.has(here): continue
				for d in [Vector2i(1, 0), Vector2i(0, 1)]:
					var n := 0
					while not level.walls.has(here + d * (n + 1)) and n < 60: n += 1
					if n > top:
						top = n
						c = here
		player.global_position = Vector3(c.x * level.CELL, 0.1, c.y * level.CELL)
		await create_timer(0.5).timeout
	# SPOT=zone:<name> (bright, dark, dim, classic...): stand in the middle of that zone
	var spot: String = env_or.call("SPOT", "")
	if spot.begins_with("zone:"):
		var cells: Dictionary = level.get(spot.substr(5))
		var sum := Vector2.ZERO
		for k in cells: sum += Vector2(k)
		var mid := sum / maxf(cells.size(), 1)
		var pick: Vector2i = cells.keys()[0]
		for k in cells:
			if Vector2(k).distance_to(mid) < Vector2(pick).distance_to(mid): pick = k
		c = pick
		player.global_position = Vector3(c.x * level.CELL, 0.1, c.y * level.CELL)
		await create_timer(0.5).timeout
	var best := Vector2i(0, 1)
	var best_n := -1
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n := 0
		while not level.walls.has(c + d * (n + 1)) and n < 60:
			n += 1
		if n > best_n:
			best_n = n
			best = d
	player.rotation.y = atan2(-float(best.x), -float(best.y))
	cam.rotation.x = deg_to_rad(float(env_or.call("PITCH", "8")))
	# OFF=vfog,ssr,ssao,ssil,glow,fog,post,gi,hud: switch effects off to find which one draws something
	var off: PackedStringArray = str(env_or.call("OFF", "")).split(",", false)
	var e: Environment = (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	for k in off:
		match k:
			"vfog": e.volumetric_fog_enabled = false
			"ssr": e.ssr_enabled = false
			"ssao": e.ssao_enabled = false
			"ssil": e.ssil_enabled = false
			"glow": e.glow_enabled = false
			"fog": e.fog_enabled = false
			"gi":
				e.sdfgi_enabled = false
				if level.voxel_gi: level.voxel_gi.visible = false
			"post", "hud": main.get_node("UI").visible = false
			"torch":
				player.flash_on = false
				player.flash.visible = false
			"shadows":
				for l in level.pool: l.shadow_enabled = false
				level._shadow_cap = 0
	var prefix: String = env_or.call("SHOT", "res://shot")
	for i in int(env_or.call("SHOTS", "3")):
		await create_timer(2.5).timeout
		root.get_texture().get_image().save_png("%s_%d.png" % [prefix, i])
		player.rotation.y += deg_to_rad(35.0)
	quit()
