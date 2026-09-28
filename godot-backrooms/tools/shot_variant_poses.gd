extends SceneTree
## Renders the rigged mannequin variant in a row of poses, front and side (needs a window).
## xvfb-run -s "-screen 0 1400x700x24" godot --path . --resolution 1400x700 --script res://tools/shot_variant_poses.gd

const MannequinModel := preload("res://scripts/Entities/mannequin/mannequin_model.gd")

func _initialize() -> void:
	var prefix := OS.get_environment("SHOT") if OS.get_environment("SHOT") != "" else "res://variant_poses"
	var world := Node3D.new()
	root.add_child(world)
	await process_frame
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.35, 0.35, 0.38)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.6, 0.5, 0.0)
	world.add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 6)
	floor_mi.mesh = pm
	world.add_child(floor_mi)
	var model := MannequinModel.new()
	print("variant loaded: ", model.load_variant(world), " rigged: ", model.variant_rigged)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var poses: Array = []
	var p0 := MannequinModel.rest_pose()                      # planted, nothing else
	poses.append(p0)
	var p1 := MannequinModel.rest_pose()
	p1.armL = 1.45; p1.armR = 1.45                            # both arms reaching
	poses.append(p1)
	var p2 := MannequinModel.rest_pose()
	p2.headYaw = 1.0; p2.headTilt = 0.3                       # head snapped round
	poses.append(p2)
	var p3 := MannequinModel.rest_pose()
	p3.armL = 1.4; p3.headYaw = -0.5                          # one arm reaching
	poses.append(p3)
	poses.append(MannequinModel.random_pose(rng))
	for i in poses.size():
		var n := model.make_variant(poses[i])
		n.transform = Transform3D(Basis.IDENTITY, Vector3((i - 2) * 1.2, 0, 0)) * model.variant_root_xf
		world.add_child(n)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.fov = 45.0
	# each pose on its own, from three-quarters front, then a grid of them
	for i in poses.size():
		var at := Vector3((i - 2) * 1.2, 0.95, 0)
		cam.position = at + Vector3(1.6, 0.25, 2.6)
		cam.look_at(at, Vector3.UP)
		await create_timer(0.3).timeout
		root.get_texture().get_image().save_png("%s_%d.png" % [prefix, i])
	quit()
