extends SceneTree
## Measures how much the camera actually moves (handheld shake, bob): stands still, then walks forward,
## and prints the peak-to-peak camera pitch / roll / height. Runs headless.
## godot --headless --path . --script res://tools/probe_camera.gd

func _initialize() -> void:
	var game: Node = root.get_node("Game")
	game.level_index = int(OS.get_environment("LEVEL") if OS.get_environment("LEVEL") != "" else "2")
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.5).timeout
	game.playing = true
	var player: Node = main.get_node("Player")
	var cam: Camera3D = player.get_node("Camera3D")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await physics_frame
	print("mouse captured = ", Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	print("head_bob setting = ", player.head_bob, "  handheld = ", player.get("handheld"))
	for phase in ["standing", "walking"]:
		if phase == "walking":
			Input.action_press("ui_up")
			var ev := InputEventKey.new()
			ev.physical_keycode = KEY_W
			ev.pressed = true
			Input.parse_input_event(ev)
		var mn := Vector3(INF, INF, INF)
		var mx := -mn
		for i in 480:
			await physics_frame
			var v := Vector3(cam.rotation.x, cam.rotation.z, cam.rotation.y)
			mn = mn.min(v)
			mx = mx.max(v)
		var d := mx - mn
		print("%s: pitch %.2f deg, roll %.2f deg, yaw %.2f deg (peak to peak over 8 s)" % [phase,
			rad_to_deg(d.x), rad_to_deg(d.y), rad_to_deg(d.z)])
	quit()
