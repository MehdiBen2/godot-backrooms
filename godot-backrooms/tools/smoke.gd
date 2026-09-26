extends SceneTree
# Headless smoke test: godot --headless --fixed-fps 60 --script res://tools/smoke.gd
var frames := 0
var main: Node
func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
func _process(_dt: float) -> bool:
	frames += 1
	var ent = main.get_node("Entity")
	var ply = main.get_node("Player")
	var man = main.get_node("Mannequin")
	if frames == 5:
		root.get_node("Game").playing = true
		print("player at ", ply.global_position, " entity at ", ent.global_position, " mannequins: ", man.decoys.size(), " ready=", man.ready_ok)
	if frames == 20:
		print("event powerCut -> ", main.get_node("Events").run_event("powerCut"))
	if frames == 200:
		print("preacher -> ", main.get_node("Events").run_event("preacherWhisper"))
	if frames == 260:
		var f = -ply.global_transform.basis.z
		var p = ply.global_position + f * 12.0
		ent.summon(p.x, p.z, ply.global_position.x, ply.global_position.z)
		print("summoned at ", p)
	if frames > 20 and frames < 260 and frames % 40 == 0:
		var mm = main.get_node("Mimic")
		print("f", frames, " mimic session=", mm.session, " spawned=", mm.spawned, " mode=", mm.mode, " grid_down=", ply.grid_down)
	if frames > 260 and frames % 60 == 0 and frames < 900:
		print("f", frames, " entity state=", ent.state, " dist=", snappedf(ent.global_position.distance_to(ply.global_position), 0.1), " terror=", snappedf(root.get_node("Game").terror, 0.01), " dead=", root.get_node("Game").dead)
	if frames == 900:
		var g = root.get_node("Game")
		g.dead = false
		ply.dead = false
		ply.frozen = false
		ent.global_position = Vector3(153, 0, 81)
		ent.set_state("roam")
		man.warp_to_room()
		ply.rotation.y += PI     # look away so it can hunt
		print("warped to mannequins: ", ply.global_position, " real at ", man.real_node.position)
	if frames > 900 and frames < 1300 and frames % 40 == 0:
		print("f", frames, " mq awake=", man.awake, " moving=", man.moving, " real=", man.real_node.position, " snap=", man.snap_active, " dead=", root.get_node("Game").dead)
	if frames == 1300:
		var g2 = root.get_node("Game")
		g2.dead = false
		ply.dead = false
		ply.frozen = false
		man.killed = true
		man.start_snap()
		print("snap started")
		ent.global_position = ply.global_position + Vector3(0, 0, 30)
		print("stalk started: ", ent.begin_stalk(true))
	if frames > 1300 and frames % 60 == 0 and frames < 1900:
		print("f", frames, " snap_t=", snappedf(man.snap_t, 0.1), " dead=", root.get_node("Game").dead, " fov=", ply.cam.fov)
		print("f", frames, " mimic spawned=", main.get_node("Mimic").spawned, " mode=", main.get_node("Mimic").mode, " ent=", ent.state)
	# ---- the newer paths: lying in wait, the tubes, the watcher, the eyes, tile steps, presets
	if frames == 1900:
		var g3 = root.get_node("Game")
		g3.dead = false
		ply.dead = false
		ply.frozen = false
		ply.global_position = main.get_node("Level").spawn_pos
		ent.gather_target()
		ent.global_position = ply.global_position + Vector3(0, 0, 25)
		ent.last_known = ply.global_position
		ent.last_vel = Vector3.ZERO
		print("lurk begun: ", ent.begin_lurk(ply.global_position + Vector3(0, 0, 9)), " state=", ent.state)
		var lvl = main.get_node("Level")
		lvl.disturb(ply.global_position, 30.0, 1.0)
		var bursting := 0
		for f in lvl.lit:
			if f.burst > 0:
				bursting += 1
		print("disturbed tubes: ", bursting, " of ", lvl.lit.size())
		print("watcher: ", main.get_node("Watcher").debug_spawn("stand"))
		print("wallKnock -> ", main.get_node("Events").run_event("wallKnock"), "  breathBehind -> ", main.get_node("Events").run_event("breathBehind"))
		ply.sanity_lock = 5.0
		main.get_node("Eyes").debug_set(1)
	if frames > 1900 and frames % 60 == 0 and frames < 2400:
		print("f", frames, " ent=", ent.state, " waiting=", ent.lurk_waiting,
			" watcher=", main.get_node("Watcher").present, " eyes=", main.get_node("Eyes").alive_count(),
			" lights=", main.get_node("Level").pool.filter(func(l): return l.visible).size())
	if frames == 2100:
		var lvl2 = main.get_node("Level")
		if not lvl2.tiles.is_empty():
			var c: Vector2i = lvl2.tiles.keys()[0]
			ply.global_position = Vector3(c.x * lvl2.CELL, 0.1, c.y * lvl2.CELL)
			ply.footsteps.step(false, false, 1.0)
			print("tile step: on_tile=", ply.footsteps.on_tile, " noise=", ply.step_noise(), " surface=", lvl2.surface_at(ply.global_position))
		# every preset applies cleanly (then the player's own settings are put back exactly as they were)
		var gfx = root.get_node("Gfx")
		var saved_s: Dictionary = gfx.s.duplicate()
		var saved_p: String = gfx.preset
		for p in ["low", "medium", "high", "ultra"]:
			gfx.set_preset(p)
			print("preset ", p, ": physics ", Engine.physics_ticks_per_second, " Hz, particles x", gfx.particle_scale())
		gfx.s = saved_s
		gfx.preset = saved_p
		gfx._commit()
	if frames == 2400:
		ply.sanity_lock = -1.0
		quit()
	return false
