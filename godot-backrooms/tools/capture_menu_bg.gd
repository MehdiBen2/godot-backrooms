extends SceneTree
## Renders the title screen backdrops: textures/menu/bg_0.png .. bg_N.png (main_menu.gd cycles them).
## Run: Godot --path . --resolution 1920x1080 --script tools/capture_menu_bg.gd
## Frames long corridors from just behind a lit fixture, crops the flashlight out.

const SHOTS := 6

func _initialize() -> void:
	root.get_node("Game").respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	DirAccess.make_dir_recursive_absolute("res://textures/menu")
	await create_timer(4.0).timeout
	main.get_node("UI").visible = false
	var level: Node = main.get_node("Level")
	var player: Node3D = main.get_node("Player")
	player.set_physics_process(false)
	var cell: float = level.CELL
	var picks := []
	for f in level.lit:
		var p: Vector3 = f.pos
		var c := Vector2i(roundi(p.x / cell), roundi(p.z / cell))
		var dir := Vector3(0, 0, 1) if f.rot == 0.0 else Vector3(1, 0, 0)
		for s in [1.0, -1.0]:
			var step := Vector2i(roundi(dir.x * s), roundi(dir.z * s))
			var open := 0
			while not level.walls.has(c + step * (open + 1)) and open < 12:
				open += 1
			var back := Vector2i(-step.x, -step.y)
			if open >= 6 and not level.walls.has(c + back):
				picks.append({"pos": p, "dir": dir * s, "open": open})
	picks.sort_custom(func(a, b): return a.open > b.open)
	var used := []
	var n := 0
	for pk in picks:
		if n >= SHOTS: break
		var far := true
		for u in used:
			if (u as Vector3).distance_to(pk.pos) < cell * 6.0: far = false
		if not far: continue
		used.append(pk.pos)
		var d: Vector3 = pk.dir
		player.global_position = Vector3(pk.pos.x, 0.1, pk.pos.z) - d * cell * 0.9
		player.rotation.y = atan2(-d.x, -d.z)
		player.get_node("Camera3D").rotation.x = deg_to_rad(2)
		await create_timer(1.6).timeout
		var img := root.get_texture().get_image()
		# drop the torch (bottom 30%), keep 16:9 by trimming the sides equally
		var h := 760
		var w := int(h * 16.0 / 9.0)
		img = img.get_region(Rect2i((img.get_width() - w) / 2, 0, w, h))
		img.resize(1920, 1080, Image.INTERPOLATE_LANCZOS)
		img.save_png("res://textures/menu/bg_%d.png" % n)
		n += 1
	quit()
