extends SceneTree
## Renders scenes/hills.tscn for a few frames and saves a screenshot (needs a real window, not --headless).
func _init() -> void:
	var s: Node = load("res://scenes/hills.tscn").instantiate()
	root.add_child(s)
	await create_timer(3.0).timeout
	var p: Node3D = s.get_children().filter(func(c): return c is CharacterBody3D)[0]
	p.rotation.y = 0.0
	await create_timer(1.0).timeout
	if OS.get_environment("HIGH") != "":
		p.global_position = s.sites[0] + Vector3(14, 3, 14)
		p.rotation.y = 0.6
		await create_timer(2.0).timeout
	root.get_viewport().get_texture().get_image().save_png(OS.get_environment("SHOT") if OS.get_environment("SHOT") != "" else "res://hills_shot.png")
	quit()
