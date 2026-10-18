extends SceneTree
## The metal cabinet hiding spot (props/hide_spot.gd) in a level: stands one in front of you, saves the view from outside,
## climbs in (E), saves the view from inside through the door's crack, checks `player.hidden` is what THE TALL ONE reads,
## then climbs out. Needs a window. Env: LEVEL (index, default 0), SHOT (output prefix, default res://hide).
## godot --path . --resolution 1280x720 --audio-driver Dummy --script res://tools/shot_hide.gd

var IndustrialProp: GDScript
var HideSpot: GDScript

func _initialize() -> void:
	IndustrialProp = load("res://scripts/World/props/industrial_prop.gd")
	HideSpot = load("res://scripts/World/props/hide_spot.gd")
	var env_or := func(k: String, d: String) -> String: return OS.get_environment(k) if OS.get_environment(k) != "" else d
	var game: Node = root.get_node("Game")
	game.level_index = int(env_or.call("LEVEL", "0"))
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(2.0).timeout
	game.playing = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.get_node("UI").visible = false
	var player: CharacterBody3D = main.get_node("Player")
	var tall: Node3D = main.get_node("TallOne")
	var prefix: String = env_or.call("SHOT", "res://hide")
	player.spawn_grace = 0.0
	var types: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://levels/object_types.json"))
	var info: Dictionary = types[OS.get_environment("PROP") if OS.get_environment("PROP") != "" else "prop_hide_cabinet"]
	var fwd := -player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var p: Node3D = IndustrialProp.new()
	main.add_child(p)
	p.global_position = player.global_position + fwd * 2.3
	p.rotation.y = atan2(fwd.z, -fwd.x)
	p.build_info(info)
	var spot: Node3D = HideSpot.new()
	p.add_child(spot)
	spot.setup(p, info)
	print("bounds ", p.bounds, " door ", spot._door, " meshes under door ", spot._door.get_child_count() if spot._door else -1)
	player.cam.rotation.x = -0.1
	var light := OmniLight3D.new()
	light.omni_range = 8.0
	main.add_child(light)
	light.global_position = p.global_position + Vector3(0, 2.2, 0) + fwd * -1.0
	await _frames(20)
	root.get_texture().get_image().save_png(prefix + "_outside.png")
	print("can_interact ", spot.can_interact(player.cam.global_position), " hidden before ", player.hidden)
	spot.interact(player)
	await _frames(25)
	root.get_texture().get_image().save_png(prefix + "_gliding.png")
	await create_timer(1.3).timeout
	print("state ", spot._state, " hidden ", player.hidden, " frozen ", player.frozen, " tall reads hidden: ", tall._player_hidden(), " sees: ", tall._sees({"pos": player.global_position, "local": true, "id": 0}))
	await _frames(5)
	root.get_texture().get_image().save_png(prefix + "_inside.png")
	spot._look = Vector2(0.4, 0.1)
	await _frames(5)
	root.get_texture().get_image().save_png(prefix + "_inside_look.png")
	spot._t = 1.0
	var e := InputEventKey.new()
	e.physical_keycode = KEY_E
	e.pressed = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	spot._unhandled_input(e)
	print("after E: ", spot._state)
	await create_timer(0.5).timeout
	root.get_texture().get_image().save_png(prefix + "_leaving.png")
	await create_timer(1.2).timeout
	print("state ", spot._state, " hidden ", player.hidden, " frozen ", player.frozen, " cam ", player.cam.global_position)
	quit()

func _frames(n: int) -> void:
	for i in n: await process_frame
