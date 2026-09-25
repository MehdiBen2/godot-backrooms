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
		print("f", frames, " mimic spawned=", main.get_node("Mimic").spawned, " mode=", main.get_node("Mimic").mode, " peek=", main.get_node("Mimic").pk_phase, " ent=", ent.state)
	if frames == 1900:
		quit()
	return false
