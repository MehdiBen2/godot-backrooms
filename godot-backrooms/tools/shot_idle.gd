extends Node
## Renders the left hand's idle gestures (torch_model.gd IDLE_CLIPS) from the player's camera, a few
## shots into each, and with the torch on the rest it's held in (before, and after each gesture).
## Env: SHOT (output prefix), TIMES (comma list of seconds), TORCH (1: torch on), SPRINT (1: then sprint,
## a shot every eighth of a stride of the pump, and one after stopping), GROPE (1: then walk in the dark,
## torch down: the hand feeling ahead, shots as it comes up and through a sweep, and after stopping), BRACE
## (1: then caught: the last reach, shots through it and once the hands are gone), CATCH (bacteria |
## mannequin: that entity's catch instead, both arms, shots through it; the mannequin flings the torch).
## Needs a window (not --headless).
## godot --path . --audio-driver Dummy --resolution 960x540 res://tools/shot_idle.tscn

const TorchModel := preload("res://scripts/Player/torch_model.gd")

var _bob := 0.0                   # the head bob's phase while sprinting (a lambda can't change a local)

func _ready() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	DisplayServer.window_move_to_foreground()
	var process_frame := get_tree().process_frame
	var prefix := OS.get_environment("SHOT") if OS.get_environment("SHOT") != "" else "res://idle"
	var on := OS.get_environment("TORCH") == "1"
	var times: PackedFloat64Array = []
	for s in (OS.get_environment("TIMES") if OS.get_environment("TIMES") != "" else "0.5,1.2,2.3,2.8,3.4").split(","):
		times.append(float(s))
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
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
	var step := func() -> void:
		torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, false)
		torch.update(0.016, on, false, false, 0.0)
	var shoot := func(tag: String) -> void:
		await process_frame
		RenderingServer.force_draw(false)
		vp.get_texture().get_image().save_png("%s_%s.png" % [prefix, tag])
	for i in 150:                     # let the pickup (or nothing) play out
		step.call()
		await process_frame
	await shoot.call("rest")
	for clip in TorchModel.IDLE_CLIPS:
		var why: String = torch.debug_play(clip)
		if why != "":
			push_error("%s: %s" % [clip, why])
			continue
		for t in times:
			while torch._gesture == clip and torch._idle.current_animation_position < t:
				step.call()
				await process_frame
			await shoot.call("%s_%0.1f" % [clip, t])
		while torch._gesture != "":   # play it out: back to the rest, or the hand drops away
			step.call()
			await process_frame
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 1000:   # a second of real time: the cross-fade back to the rest is done
			step.call()
			await process_frame
		await shoot.call(clip + "_after")
		print(clip, " done; left hand hidden: ", torch._hands.hidden(0), "  resting: ", torch._idle_on, "  arms visible: ", torch.visible)
	if OS.get_environment("SPRINT") == "1":
		var run := func(sprint: bool) -> void:
			_bob += 0.016 * 7.5 if sprint else 0.0    # about player.gd's bob_rate at a sprint
			torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, false)
			torch.update(0.016, on, sprint, sprint, _bob)
		for i in 120:
			run.call(true)
			await process_frame
		var next := ceilf(_bob / TAU) * TAU
		for k in 8:
			while _bob < next + k * TAU / 8.0:
				run.call(true)
				await process_frame
			await shoot.call("sprint_%d" % k)
		print("sprint: base ", torch._base, "  left hand hidden: ", torch._hands.hidden(0))
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 1000:
			run.call(false)
			await process_frame
		await shoot.call("sprint_after")
		print("after the sprint: base ", torch._base, "  left hand hidden: ", torch._hands.hidden(0))
	if OS.get_environment("GROPE") == "1":
		torch.ambient = 0.1
		var walk := func(moving: bool) -> void:
			_bob += 0.016 * 5.3 if moving else 0.0
			torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, false)
			torch.update(0.016, false, false, moving, _bob)
		var t0 := Time.get_ticks_msec()
		for at in [0.3, 0.7, 1.5, 2.2, 3.0, 3.8]:
			while Time.get_ticks_msec() - t0 < at * 1000.0:
				walk.call(true)
				await process_frame
			await shoot.call("grope_%0.1f" % at)
		print("grope: base ", torch._base, "  left hand hidden: ", torch._hands.hidden(0))
		t0 = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 3500:
			walk.call(false)
			await process_frame
		await shoot.call("grope_after")
		print("stopped in the dark: base ", torch._base, "  left hand hidden: ", torch._hands.hidden(0))
	if OS.get_environment("BRACE") == "1":
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 1500:     # back to standing about first
			step.call()
			await process_frame
		torch.caught = true
		t0 = Time.get_ticks_msec()
		for at in [0.04, 0.1, 0.17, 0.24, 0.4]:
			while Time.get_ticks_msec() - t0 < at * 1000.0:
				torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, false)
				torch.update(get_process_delta_time(), false, false, false, 0.0)
				await process_frame
			await shoot.call("brace_%0.2f" % at)
		print("caught: visible ", torch.visible)
	var kind := OS.get_environment("CATCH")
	if kind != "":
		var floor_body := StaticBody3D.new()       # somewhere for a flung torch to land
		var floor_shape := CollisionShape3D.new()
		floor_shape.shape = WorldBoundaryShape3D.new()
		floor_body.add_child(floor_shape)
		floor_body.position.y = -1.6
		world.add_child(floor_body)
		var body := Node3D.new()                   # stands in for the player (the throw's world is its parent)
		world.add_child(body)
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 1500:   # back to standing about first
			step.call()
			await process_frame
		var show_for := 2.85 if kind == "bacteria" else 2.3
		torch.catch_scene(kind, body, show_for)
		torch.caught = true
		t0 = Time.get_ticks_msec()
		var times := [0.06, 0.16, 0.3, 0.6, 1.2, 2.0, show_for + 0.2] if kind == "bacteria" else [0.06, 0.12, 0.2, 0.4, 1.0, 2.1, show_for + 0.2]
		for at in times:
			while Time.get_ticks_msec() - t0 < at * 1000.0:
				torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, false)
				torch.update(get_process_delta_time(), false, false, false, 0.0)
				await process_frame
			await shoot.call("%s_%0.2f" % [kind, at])
		var flung := world.find_child("FlungTorch", true, false)
		print("%s: hands visible at the end %s, flung torch %s" % [kind, torch.visible, (flung as Node3D).global_position if flung else "none"])
	get_tree().quit()
