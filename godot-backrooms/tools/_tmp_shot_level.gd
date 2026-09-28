extends SceneTree
## Temporary: boots a level (LEVEL env, default 2), stands the player at CELL env "x,z" facing YAW env
## degrees and saves a screenshot to SHOT. Needs a real window (not --headless).
func _init() -> void:
	await process_frame
	var g: Node = root.get_node("Game")
	g.level_index = int(OS.get_environment("LEVEL")) if OS.get_environment("LEVEL") != "" else 2
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.0).timeout
	g.playing = true
	for n in main.find_children("*", "", true, false):
		if n.has_method("set_paused"): n.set_paused(false)
	var p: Node3D = main.get_node("Player")
	var cell := OS.get_environment("CELL").split(",") if OS.get_environment("CELL") != "" else PackedStringArray()
	if cell.size() == 2:
		p.global_position = Vector3(float(cell[0]) * 4.5, 0.1, float(cell[1]) * 4.5)
	p.rotation.y = deg_to_rad(float(OS.get_environment("YAW")))
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await create_timer(3.0).timeout
	g.playing = true
	for n in main.find_children("*", "", true, false):
		if n.has_method("set_paused"): n.set_paused(false)
	await create_timer(1.5).timeout
	var lv: Node = main.get_node("Level")
	print("near lit: ", lv.pool.filter(func(l): return l.visible).size(), "  far lit: ", lv.far_pool.filter(func(l): return l.visible).size(),
		"  far cap: ", lv._far_cap, "  eye: ", snappedf(lv.eye, 0.01), "  sdfgi: ", lv.env.sdfgi_enabled, "  exposure: ", snappedf(lv.env.tonemap_exposure, 0.01))
	root.get_viewport().get_texture().get_image().save_png(OS.get_environment("SHOT"))
	quit()
