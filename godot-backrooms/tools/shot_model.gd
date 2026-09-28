extends SceneTree
## Renders a model on its own, front and side, to look at its pose (needs a window, not --headless).
## Env: MODEL (res:// path), SHOT (output prefix). Also prints its skeleton's bones.
## xvfb-run -s "-screen 0 900x900x24" godot --path . --resolution 900x900 --script res://tools/shot_model.gd

func _initialize() -> void:
	var path := OS.get_environment("MODEL") if OS.get_environment("MODEL") != "" else "res://models/entities/mannequin_variant.glb"
	var prefix := OS.get_environment("SHOT") if OS.get_environment("SHOT") != "" else "res://model"
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
	var model: Node3D = (load(path) as PackedScene).instantiate()
	world.add_child(model)
	for sk in model.find_children("*", "Skeleton3D", true, false):
		var s := sk as Skeleton3D
		for i in s.get_bone_count():
			print("bone %d %s parent=%d rest_origin=%s global_origin=%s" % [i, s.get_bone_name(i), s.get_bone_parent(i),
				s.get_bone_rest(i).origin, s.get_bone_global_rest(i).origin])
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.fov = 40.0
	var views := {"front": Vector3(0, 0.95, 3.6), "side": Vector3(3.6, 0.95, 0), "back": Vector3(0, 0.95, -3.6)}
	for k in views:
		cam.position = views[k]
		cam.look_at(Vector3(0, 0.9, 0), Vector3.UP)
		await process_frame
		await process_frame
		await create_timer(0.3).timeout
		root.get_texture().get_image().save_png("%s_%s.png" % [prefix, k])
	quit()
