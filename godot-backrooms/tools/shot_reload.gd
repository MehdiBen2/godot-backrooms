extends Node
## Renders the battery swap (TorchReload) from the player's camera at a few times into the clip.
## Env: SHOT (output prefix), TIMES (comma list of seconds). Needs a window (not --headless).
## godot --path . --audio-driver Dummy --resolution 960x540 res://tools/shot_reload.tscn

const TorchModel := preload("res://scripts/Player/torch_model.gd")

func _ready() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	DisplayServer.window_move_to_foreground()
	var root := get_tree().root
	var process_frame := get_tree().process_frame
	var prefix := OS.get_environment("SHOT") if OS.get_environment("SHOT") != "" else "res://reload"
	var times: PackedFloat64Array = []
	for s in (OS.get_environment("TIMES") if OS.get_environment("TIMES") != "" else "1.35,2.0,2.35,2.9,3.3,3.5,3.95,4.55,5.35,6.2").split(","):
		times.append(float(s))
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 800)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var world := Node3D.new()
	vp.add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.25, 0.23, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.78, 0.7)
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var cam := Camera3D.new()
	cam.fov = 75.0
	world.add_child(cam)
	cam.make_current()
	var torch := TorchModel.new()
	cam.add_child(torch)
	if not torch.build():
		push_error("torch build failed")
		get_tree().quit(1)
		return
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.8, 0.4, 0.0)
	sun.light_energy = 1.6
	world.add_child(sun)
	for i in 150:                     # let the pickup play out
		torch.update(0.016, true, false, false, 0.0)
		await process_frame
	torch.swap()
	for i in 400:
		torch.update(0.016, true, false, false, 0.0)
		await process_frame
		if torch._swap == 2:
			break
	# real time: take each shot as the clip's position passes its time
	for t in times:
		while torch._swap == 2 and torch._anim.current_animation_position < t:
			torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, false)
			torch.update(0.016, true, false, false, 0.0)
			await process_frame
		await process_frame
		RenderingServer.force_draw(false)
		vp.get_texture().get_image().save_png("%s_%0.1f.png" % [prefix, t])
	get_tree().quit()
