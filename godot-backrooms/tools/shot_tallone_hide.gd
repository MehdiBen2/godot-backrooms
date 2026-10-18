extends SceneTree
## THE TALL ONE and a hiding place (tall_one.gd stalk / peer / circle, props/hide_spot.gd): a cabinet stands in front of
## you, it hunts you, and when it is close and has you in sight you climb in. Prints each state change with the time and
## where it is, and saves the view through the vent while it peers in, and a side view of it at the door.
## Needs a window. Env: LEVEL (index, default 0), PROP (default prop_hide_cabinet), SHOT (output prefix, default res://hidetall),
## OUT_AT_PEER=1 (you climb out while it is peering in: it should have you).
## godot --path . --resolution 1280x720 --audio-driver Dummy --script res://tools/shot_tallone_hide.gd

func _initialize() -> void:
	var env_or := func(k: String, d: String) -> String: return OS.get_environment(k) if OS.get_environment(k) != "" else d
	var IndustrialProp: GDScript = load("res://scripts/World/props/industrial_prop.gd")
	var HideSpot: GDScript = load("res://scripts/World/props/hide_spot.gd")
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
	var prefix: String = env_or.call("SHOT", "res://hidetall")
	player.spawn_grace = 0.0
	var types: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://levels/object_types.json"))
	var info: Dictionary = types[env_or.call("PROP", "prop_hide_cabinet")]
	# the cabinet: a step ahead of you, its door toward you, in the longest clear line we can find
	var fwd := -player.global_transform.basis.z
	fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
	var p: Node3D = IndustrialProp.new()
	main.add_child(p)
	p.global_position = player.global_position + fwd * 2.3
	p.rotation.y = atan2(fwd.z, -fwd.x)
	p.build_info(info)
	var spot: Node3D = HideSpot.new()
	p.add_child(spot)
	spot.setup(p, info)
	if tall.body == null and not tall._build():
		print("tallone: could not build: ", tall.last_error)
		quit(1)
		return
	tall._mark_pending = false
	tall.debug_hunt()
	print("hunt from %.1f m" % tall.global_position.distance_to(player.global_position))
	var t0 := Time.get_ticks_msec()
	var last := ""
	var hid := false
	var side_saved := false
	var vent_saved := false
	var shot_cam := Camera3D.new()
	shot_cam.fov = 60.0
	main.add_child(shot_cam)
	while Time.get_ticks_msec() - t0 < 45000:
		await process_frame
		var s := float(Time.get_ticks_msec() - t0) / 1000.0
		var d: float = tall.global_position.distance_to(player.global_position)
		if tall.state != last:
			last = tall.state
			print("%6.2f s  %-7s at %.1f m from you (hidden %s)" % [s, tall.state, d, player.hidden])
		if not hid:
			player.velocity = Vector3.ZERO
			var clear: bool = tall.nav.clear_line(tall.global_position.x, tall.global_position.z, player.global_position.x, player.global_position.z)
			if (d < 16.0 and clear) or d < 9.0:
				hid = true
				print("%6.2f s  you climb in (it is %.1f m off, %s)" % [s, d, "in sight" if clear else "out of sight"])
				spot.interact(player)
		if OS.get_environment("OUT_AT_PEER") != "" and tall.state == "peer" and tall.t > 2.5 and spot._state == "hidden":
			print("%6.2f s  you climb out while it peers in" % s)
			spot._t = 1.0
			var e := InputEventKey.new()
			e.physical_keycode = KEY_E
			e.pressed = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			spot._unhandled_input(e)
		if tall.state == "kill":
			print("%6.2f s  it has you" % s)
			break
		if tall.state == "peer" and tall.t > 2.6 and not vent_saved:
			vent_saved = true
			root.get_texture().get_image().save_png(prefix + "_vent.png")
			print("  saved %s_vent.png" % prefix)
			var side := Vector3(-fwd.z, 0.0, fwd.x)
			shot_cam.global_position = p.global_position + side * 5.5 + fwd * -1.2 + Vector3.UP * 1.6
			shot_cam.look_at(p.global_position + fwd * -1.2 + Vector3.UP * 1.3, Vector3.UP)
			shot_cam.make_current()
			await process_frame
			await process_frame
			root.get_texture().get_image().save_png(prefix + "_side.png")
			print("  saved %s_side.png" % prefix)
			player.cam.make_current()
			side_saved = true
		if side_saved and tall.state == "roam" and tall.t > 1.0:
			break
		if OS.get_environment("DEBUG_CIRCLE") != "" and tall.state == "peer" and tall.t > 4.9:
			var prop: Node3D = spot
			prop = p
			var b: AABB = p.bounds
			var c := p.global_position
			var f: Vector3 = tall._hide_out()
			var r := Vector3(-f.z, 0.0, f.x)
			var hd := b.size.x * 0.5
			for side: float in [1.0, -1.0]:
				for wide: float in [1.4, 1.0, 0.7]:
					var hw := b.size.z * 0.5 + wide
					var a: Vector3 = tall.nav.resolve(c + f * (hd + 1.0) + r * side * hw, 0.9)
					var bk: Vector3 = tall.nav.resolve(c - f * (hd + 1.0) + r * side * hw, 0.9)
					var q: Vector3 = tall.global_position
					print("side %d wide %.1f a %s bk %s  clear(me,a) %s clear(a,bk) %s  behind-dot %.2f  open a %s bk %s" % [side, wide, a, bk, tall.nav.clear_line(q.x, q.z, a.x, a.z), tall.nav.clear_line(a.x, a.z, bk.x, bk.z), (bk - c).dot(f), tall.nav.open_at(a.x, a.z), tall.nav.open_at(bk.x, bk.z)])
			print("cabinet at ", c, " out ", f, " me ", tall.global_position)
			break
	print("end: state %s, you hidden %s, dead %s" % [tall.state, player.hidden, player.dead])
	quit()
