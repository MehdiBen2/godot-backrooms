extends SceneTree
## Photographs every wall-graph test scene (tools/wall_cases.gd) in the game's wallpaper, from above at an angle,
## to look at the joints (needs a window, not --headless):
##   godot --path godot-backrooms --resolution 1100x800 --script res://tools/shot_walls.gd
## Env: SHOT (output prefix, default user://walls), CASE (only scenes whose name contains it).

const Cases := preload("res://tools/wall_cases.gd")
const Joints := preload("res://scripts/World/level/walls/wall_joints.gd")
const WallMesh := preload("res://scripts/World/level/walls/wall_mesh.gd")
const CELL := 4.5
const FULL := 5.4

func _initialize() -> void:
	var prefix := OS.get_environment("SHOT") if OS.get_environment("SHOT") != "" else "user://walls"
	var only := OS.get_environment("CASE")
	await process_frame
	var paper := StandardMaterial3D.new()
	paper.albedo_texture = load("res://textures/wall_color.png")
	paper.albedo_color = Color(1.0, 0.98, 0.88)
	paper.normal_enabled = true
	paper.normal_texture = load("res://textures/wall_normal.png")
	paper.roughness = 0.95
	paper.uv1_scale = Vector3(1.0 / 2.25, -1.0 / FULL, 1.0)
	paper.uv1_offset = Vector3(0.0, 1.0, 0.0)
	paper.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var top := StandardMaterial3D.new()
	top.albedo_color = Color(0.55, 0.5, 0.42)
	for c: Dictionary in Cases.cases():
		if only != "" and not (str(c.name).to_lower().contains(only.to_lower())): continue
		var world := Node3D.new()
		root.add_child(world)
		var we := WorldEnvironment.new()
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.13, 0.12, 0.1)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.55, 0.53, 0.5)
		env.ssao_enabled = true
		we.environment = env
		world.add_child(we)
		var sun := DirectionalLight3D.new()
		sun.rotation = Vector3(-0.95, 0.6, 0.0)
		sun.shadow_enabled = true
		sun.light_energy = 1.1
		world.add_child(sun)
		var g = c.g
		var spans := {}
		var keys := {}
		var box := AABB()
		var first := true
		for e in g.edges:
			var ed: Dictionary = g.edges[e]
			spans[e] = Vector2(ed.base, ed.h if ed.h > 0.0 else FULL)
			keys[e] = {"l": "paper", "r": "paper", "cap": "top"}
		var sol := Joints.solve(g, CELL)
		var res := WallMesh.build(sol, spans, keys, 2.25)
		for key in res.meshes:
			var mi := MeshInstance3D.new()
			mi.mesh = res.meshes[key]
			mi.material_override = paper if key == "paper" else top
			world.add_child(mi)
			box = mi.get_aabb() if first else box.merge(mi.get_aabb())
			first = false
		var floor_mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(box.size.x + 12.0, box.size.z + 12.0)
		floor_mi.mesh = pm
		floor_mi.position = Vector3(box.get_center().x, 0.0, box.get_center().z)
		var fm := StandardMaterial3D.new()
		fm.albedo_color = Color(0.42, 0.38, 0.3)
		floor_mi.material_override = fm
		world.add_child(floor_mi)
		var cam := Camera3D.new()
		world.add_child(cam)
		cam.fov = 45.0
		var mid := box.get_center()
		var reach := maxf(box.size.x, box.size.z)
		for view: Array in [["angle", Vector3(-0.55, 0.85, 1.0)], ["top", Vector3(0.0, 1.0, 0.02)], ["low", Vector3(0.75, 0.35, 0.9)]]:
			var dir: Vector3 = (view[1] as Vector3).normalized()
			cam.position = mid + dir * reach * (0.95 if view[0] == "top" else 1.05)
			cam.look_at(mid + Vector3(0, 1.0, 0), Vector3.UP)
			await process_frame
			await process_frame
			await create_timer(0.25).timeout
			var name := str(c.name).replace(" ", "_").replace("-", "")
			root.get_texture().get_image().save_png("%s_%s_%s.png" % [prefix, name, view[0]])
		world.queue_free()
		await process_frame
	quit()
