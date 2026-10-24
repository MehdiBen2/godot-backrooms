extends SceneTree
## Screenshots of a level from set places (needs a window, not --headless: run it with tools/run_bg.ps1 -Offscreen).
## Env: LEVEL (index in levels.json, default 0), PRESET (low..ultra, default high), SHOT (output prefix, default
## res://shot), FLOOR (floor to start on, default 0), TORCH (1: keep the torch on), HUD (1: keep the HUD),
## VIEWS: "x,z,look,pitch[,y]" separated by ";": stand on cell (x, z) (fractions allowed), look `look` degrees
## clockwise on the map (0 east, 90 south: the level editor's arrows), `pitch` degrees up, eyes raised `y` m
## (default 0: on the floor there). One PNG per view: <SHOT>_<i>.png.
##   $env:LEVEL=1; $env:VIEWS="10,12,90,5;20,8,0,-10"; powershell -File tools/run_bg.ps1 -Offscreen
##     -GodotArgs "--resolution 1280x720 --script res://tools/shot_views.gd"

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
	var want_floor := int(env_or.call("FLOOR", "0"))
	if want_floor != 0 and level.has_method("rebuild_floor_seamless"):
		level.rebuild_floor_seamless(want_floor, {}, true)
		await create_timer(4.0).timeout
	var player: CharacterBody3D = main.get_node("Player")
	var cam: Camera3D = player.get_node("Camera3D")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if env_or.call("TORCH", "0") != "1":
		player.flash_on = false
		player.flash.visible = false
	if env_or.call("HUD", "0") != "1":
		main.get_node("UI").visible = false
	var prefix: String = env_or.call("SHOT", "res://shot")
	var views := String(env_or.call("VIEWS", "")).split(";", false)
	if views.is_empty():
		views = ["%f,%f,0,0" % [player.global_position.x / 4.5, player.global_position.z / 4.5]]
	var i := 0
	for v in views:
		var p := v.split(",")
		var at := Vector3(float(p[0]) * 4.5, 0.1 + (float(p[4]) if p.size() > 4 else 0.0), float(p[1]) * 4.5)
		var look := deg_to_rad(float(p[2]) if p.size() > 2 else 0.0)
		player.global_position = at
		player.velocity = Vector3.ZERO
		player.rotation.y = atan2(-cos(look), -sin(look))
		cam.rotation.x = deg_to_rad(float(p[3]) if p.size() > 3 else 0.0)
		# held where it was put (no falling off a ledge or sinking into the water while the frame settles)
		for k in 40:
			player.global_position = at
			player.velocity = Vector3.ZERO
			await physics_frame
		await create_timer(1.2).timeout
		root.get_texture().get_image().save_png("%s_%d.png" % [prefix, i])
		print("shot %d: %s" % [i, v])
		i += 1
	quit()
