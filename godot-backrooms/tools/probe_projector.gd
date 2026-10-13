extends SceneTree
## Which way a SpotLight3D's projector texture runs (needs a window, not --headless): a light aimed as a window's sun
## is (looking_at its patch, up = +y), its projector lit only in the image's top-left quadrant, photographed from
## above. Markers: red where the quadrant's middle lands if the image's top is the light's +y and its left the
## light's -x (u along +x), green if its top is -y, blue if top +y and left +x. Half angle = spot_angle assumed.
##   godot --path godot-backrooms --resolution 900x900 --script res://tools/probe_projector.gd

func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color.BLACK
	world.add_child(env)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(30, 30)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.8, 0.8, 0.8)
	floor_mi.material_override = fm
	world.add_child(floor_mi)
	var at := Vector3(0.0, 3.0, 0.0)
	var fwd := Vector3(0.76, -0.65, 0.0).normalized()
	var l := SpotLight3D.new()
	l.position = at
	l.basis = Basis.looking_at(fwd, Vector3.UP)
	l.spot_angle = 40.0
	l.spot_range = 30.0
	l.spot_attenuation = 0.0
	l.spot_angle_attenuation = 0.01
	l.light_energy = 4.0
	l.shadow_enabled = OS.get_environment("SHADOW") == "1"
	const N := 64
	var img := Image.create(N, N, false, Image.FORMAT_L8)
	for y in N:
		for x in N:
			img.set_pixel(x, y, Color.WHITE if (x < N / 2 and y < N / 2) else Color(0.08, 0.08, 0.08))
	l.light_projector = ImageTexture.create_from_image(img)
	world.add_child(l)
	var tn := tan(deg_to_rad(l.spot_angle))
	var hyp := {Color.RED: Vector3(-0.5 * tn, 0.5 * tn, -1.0), Color.GREEN: Vector3(-0.5 * tn, -0.5 * tn, -1.0), Color.BLUE: Vector3(0.5 * tn, 0.5 * tn, -1.0)}
	for c: Color in hyp:
		var ray: Vector3 = l.basis * hyp[c]
		if ray.y >= 0.0: continue
		var p: Vector3 = at + ray * (-at.y / ray.y)
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.25
		sm.height = 0.5
		s.mesh = sm
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		s.material_override = m
		s.position = p
		world.add_child(s)
		print(c, " at ", p)
	var cam := Camera3D.new()
	cam.position = Vector3(3.0, 16.0, 0.0)
	cam.basis = Basis.looking_at(Vector3.DOWN, Vector3.FORWARD)
	cam.fov = 60.0
	world.add_child(cam)
	cam.current = true
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	var shot := root.get_viewport().get_texture().get_image()
	shot.save_png(OS.get_environment("SHOT") if OS.get_environment("SHOT") != "" else "res://projector.png")
	quit()
