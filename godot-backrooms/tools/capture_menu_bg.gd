extends SceneTree
## Renders the title screen backdrops: textures/menu/bg_0.png .. bg_N.png (main_menu.gd cycles them).
## Run: Godot --path . --resolution 1920x1080 --script tools/capture_menu_bg.gd
## Each frame frames a long corridor from behind a lit fixture with a varied camera (height, side offset,
## pitch, dutch roll, FOV, distance) so the set isn't twelve copies of the same eye-level shot. The
## first-person viewmodel is hidden.

const SHOTS := 12
# height, side offset (m), pitch (deg), roll (deg), fov, distance behind the fixture (cells)
const RIGS := [
	[0.45, 0.0, 7.0, 0.0, 78.0, 1.6],     # floor-level, looking up the hall
	[1.7, -1.4, 1.0, -2.5, 72.0, 2.2],    # off-centre eye level, slight dutch tilt
	[0.9, 1.2, 4.0, 3.0, 82.0, 1.2],      # low and wide, hugging a wall
	[1.5, 0.0, -2.0, 0.0, 60.0, 3.0],     # long lens, compressed perspective
	[0.6, -0.9, 9.0, 4.0, 85.0, 0.8],     # ceiling light looming
	[1.9, 1.0, -4.0, -3.0, 70.0, 2.0],    # high, looking down the carpet
]

func _initialize() -> void:
	root.get_node("Game").respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	DirAccess.make_dir_recursive_absolute("res://textures/menu")
	await create_timer(4.0).timeout
	main.get_node("UI").visible = false
	var level: Node = main.get_node("Level")
	var player: Node3D = main.get_node("Player")
	var cam: Camera3D = player.get_node("Camera3D")
	player.set_physics_process(false)
	player.set_process(false)
	for ch in cam.get_children():                       # torch / arms viewmodel, keep the lights
		if ch is Node3D and not (ch is Light3D):
			ch.visible = false
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
			if open >= 5 and not level.walls.has(c + back):
				picks.append({"pos": p, "dir": dir * s, "open": open})
	picks.sort_custom(func(a, b): return a.open > b.open)
	var used := []
	var n := 0
	for pk in picks:
		if n >= SHOTS: break
		var far := true
		for u in used:
			if (u as Vector3).distance_to(pk.pos) < cell * 4.0: far = false
		if not far: continue
		used.append(pk.pos)
		var rig: Array = RIGS[n % RIGS.size()]
		var d: Vector3 = pk.dir
		var side := Vector3(-d.z, 0, d.x)
		player.global_position = Vector3(pk.pos.x, 0.1, pk.pos.z) - d * cell * rig[5] + side * rig[1]
		player.rotation.y = atan2(-d.x, -d.z)
		cam.position = Vector3(0, rig[0], 0)
		cam.rotation = Vector3(deg_to_rad(rig[2]), 0, deg_to_rad(rig[3]))
		cam.fov = rig[4]
		await create_timer(2.0).timeout
		root.get_texture().get_image().save_png("res://textures/menu/bg_%d.png" % n)
		n += 1
	quit()
