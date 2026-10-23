extends SceneTree
## Temporary: front shot of work light (b) near spawn to check its lens bloom.
func _initialize() -> void:
	var game: Node = root.get_node("Game")
	game.level_index = 0
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	root.get_node("Gfx").set_preset("high")
	await create_timer(2.0).timeout
	game.playing = true
	var player: Node3D = main.get_node("Player")
	player.flash_on = false
	player.flash.visible = false
	var best: Node3D = null
	for s in root.find_children("*", "SpotLight3D", true, false):
		var p := s.get_parent() as Node3D
		if p.global_position.distance_to(Vector3(11.25, 0, 128.25)) < 0.5: best = p
	for d in [3.5, 9.0]:
		player.global_position = best.global_position + best.global_basis.x.normalized() * d + best.global_basis.z.normalized() * 0.8
		var to := best.global_position - player.global_position
		player.rotation.y = atan2(-to.x, -to.z)
		await create_timer(1.5).timeout
		root.get_texture().get_image().save_png("user://probe_bloom_%d.png" % d)
	quit()
