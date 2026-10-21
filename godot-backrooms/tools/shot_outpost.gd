extends SceneTree
## The T.S.R.A. outpost kit (object_types.json "outpost_*") lined up on a floor, the view saved to res://shot_outpost.png.
## ONLY narrows it (ONLY=desk: the outpost_desk* types). Needs a window. godot --path . --resolution 1280x720 --audio-driver Dummy --script res://tools/shot_outpost.gd

func _initialize() -> void:
	var types: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://levels/object_types.json"))
	var root := Node3D.new()
	get_root().add_child(root)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.1, 0.1, 0.1)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.75)
	env.environment.ambient_light_energy = 0.6
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	root.add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(40, 12)
	floor_mi.mesh = pm
	root.add_child(floor_mi)
	var x := -8.0
	var Prop: GDScript = load("res://scripts/World/props/industrial_prop.gd")
	for k: String in types:
		if not k.begins_with("outpost_" + OS.get_environment("ONLY")): continue
		var p: Node3D = Prop.new()
		root.add_child(p)
		p.build_info(types[k], false)
		p.position = Vector3(x, float(types[k].get("params", {}).get("elev", 0.0)), 0)
		p.rotation_degrees.y = -90        # the editor arrow at rotation 0 is +X; turned to face the camera
		print(k, " bounds ", p.bounds)
		x += maxf(p.bounds.size.x, p.bounds.size.z) + 0.6
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.look_at_from_position(Vector3(float(OS.get_environment("CX")), float(OS.get_environment("CY")), float(OS.get_environment("CZ"))), Vector3(float(OS.get_environment("CX")), 0.5, 0))
	cam.make_current()
	await process_frame
	await process_frame
	await process_frame
	get_root().get_texture().get_image().save_png("res://shot_outpost.png")
	quit()
