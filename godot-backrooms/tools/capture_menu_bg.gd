extends SceneTree
## Renders stills of the level for the title screen backdrop (textures/menu_bg.png).
## Run: Godot --path . --resolution 1920x1080 --script tools/capture_menu_bg.gd
## Writes tools/shots/shot_<yaw>.png for each yaw; copy the best one to textures/menu_bg.png.

func _initialize() -> void:
	root.get_node("Game").respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	DirAccess.make_dir_recursive_absolute("res://tools/shots")
	await create_timer(4.0).timeout
	main.get_node("UI").visible = false
	var player: Node3D = main.get_node("Player")
	for yaw in [0, 90, 180, 270]:
		player.rotation.y = deg_to_rad(yaw)
		player.get_node("Camera3D").rotation.x = deg_to_rad(-1)
		await create_timer(1.5).timeout
		root.get_texture().get_image().save_png("res://tools/shots/shot_%d.png" % yaw)
	quit()
