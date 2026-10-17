extends SceneTree
## THE TALL ONE in a level (tall_one.gd, tall_one.glb): runs the whole chain (it sees you, spots, flees, stands out of
## sight, screams, you have 7 s, it hunts and kills you), printing each state change with the time, and saves
## screenshots of its walk and run (from the side) and of the kill through your own eyes. Needs a window; the UI is hidden.
## Env: LEVEL (index, default 0), SHOT (output prefix, default res://tallone), ONLY (gaits | kill | chain).
## godot --path . --resolution 1280x720 --audio-driver Dummy --script res://tools/shot_tallone.gd

var main: Node
var player: CharacterBody3D
var tall: Node3D
var level: Node
var shot_cam: Camera3D
var prefix := ""

func _initialize() -> void:
	var env_or := func(k: String, d: String) -> String: return OS.get_environment(k) if OS.get_environment(k) != "" else d
	var game: Node = root.get_node("Game")
	game.level_index = int(env_or.call("LEVEL", "0"))
	game.respawned = true
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(2.0).timeout
	game.playing = true
	level = main.get_node("Level")
	player = main.get_node("Player")
	tall = main.get_node("TallOne")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.get_node("UI").visible = false
	prefix = env_or.call("SHOT", "res://tallone")
	shot_cam = Camera3D.new()
	shot_cam.fov = 60.0
	main.add_child(shot_cam)
	player.spawn_grace = 0.0
	if tall.body == null and not tall._build():
		print("tallone: could not build: ", tall.last_error)
		quit(1)
		return
	tall._mark_pending = false
	print("level %d size %d, you at %s" % [game.level_index, level.size, player.global_position])
	print("tallone clips: ", tall._ap.get_animation_list() if tall._ap != null else "NONE", " eye node: ", tall._eye)
	var only: String = env_or.call("ONLY", "all")
	if only in ["all", "gaits"]:
		await _gaits()
	if only in ["all", "kill"]:
		await _kill()
	if only in ["all", "chain"]:
		await _chain()
	quit()

func _save(name: String) -> void:
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png("%s_%s.png" % [prefix, name])
	print("  saved %s_%s.png  (state %s, clip %s @ %.2f)" % [prefix, name, tall.state, tall._clip, tall._ap.current_animation_position])

func _face(at: Vector3, away := false) -> void:
	var d: Vector3 = at - player.cam.global_position
	if away: d = -d
	player.rotation.y = atan2(-d.x, -d.z)
	player.cam.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())

func _wait(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		player.velocity = Vector3.ZERO
		await process_frame

## A straight corridor: it comes down it toward a camera at the side
func _gaits() -> void:
	var n: int = level.size
	var y: float = player.global_position.y
	for tries in 4000:
		var a := Vector3(randi_range(1, n - 2) * 4.5, y, randi_range(1, n - 2) * 4.5)
		var dir := [Vector3(1, 0, 0), Vector3(0, 0, 1)][randi() % 2] as Vector3
		var b := a + dir * 31.5
		if not (tall.nav.open_at(a.x, a.z) and tall.nav.open_at(b.x, b.z) and tall.nav.clear_line(a.x, a.z, b.x, b.z)): continue
		var side := dir.cross(Vector3.UP)
		var cam_at := a + dir * 12.0 + side * 3.0
		if not tall.nav.open_at(cam_at.x, cam_at.z): cam_at = a + dir * 12.0 - side * 3.0
		if not tall.nav.open_at(cam_at.x, cam_at.z): continue
		player.frozen = true
		player.global_position = b + dir * 4.5
		_face(a, true)
		tall.present = true
		tall.visible = true
		tall.global_position = a
		tall._begin_roam()
		tall._pause = 0.0
		tall.yaw = atan2(dir.x, dir.z)
		tall._wp = b
		tall._wp_t = 0.0
		shot_cam.global_position = cam_at + Vector3.UP * 2.0
		shot_cam.fov = 75.0
		shot_cam.make_current()
		await _wait(2.0)
		shot_cam.look_at(tall.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("walk_a")
		await _wait(0.5)
		shot_cam.look_at(tall.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("walk_b")
		print("walk: _walk %.2f, clip speed %.2f" % [tall._walk, tall._ap.speed_scale])
		tall.state = "flee"
		tall._flee_to = b
		tall.t = 0.0
		tall._sp = 1.0
		tall.global_position = a
		await _wait(0.4)
		shot_cam.look_at(tall.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("run_a")
		await _wait(0.2)
		shot_cam.look_at(tall.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("run_b")
		print("run: speed %.1f m/s clip speed %.2f" % [tall.flee_speed * tall._sp, tall._ap.speed_scale])
		tall._despawn_quietly()
		player.frozen = false
		return
	print("gaits: no straight corridor found")

## The kill through your own eyes: it leaps from where it is and sits on you
func _kill() -> void:
	player.frozen = false
	player.spawn_grace = 0.0
	var p: Vector3 = player.global_position
	var fwd := -player.global_transform.basis.z
	fwd = Vector3(fwd.x, 0, fwd.z).normalized()
	player.cam.make_current()
	player.cam.rotation.x = 0.0
	tall.present = true
	tall.visible = true
	tall.global_position = Vector3(p.x, p.y, p.z) + fwd * 9.0
	tall.yaw = atan2(-fwd.x, -fwd.z)
	tall.rotation.y = tall.yaw
	tall.state = "hunt"
	tall._hunt_t = 0.0
	tall._sp = 1.0
	tall._clip = ""
	var marks := [0.15, 0.45, 0.8, 1.2, 1.8, 3.0, 4.5, 6.0, 7.5, 8.6]
	var started := false
	var t0 := Time.get_ticks_msec()
	var i := 0
	while i < marks.size() and not player.dead and Time.get_ticks_msec() - t0 < 30000:
		if tall.state == "kill":
			if not started:
				started = true
				print("kill began after %.2f s, you were frozen: %s" % [(Time.get_ticks_msec() - t0) / 1000.0, player.frozen])
			if tall.t >= float(marks[i]):
				var eye: Vector3 = player.cam.global_position
				print("  t %.2f: cam %s fov %.0f, blood %.2f" % [tall.t, eye, player.cam.fov, root.get_node("Game").fx_blood])
				await _save("kill_%02d" % int(float(marks[i]) * 10.0))
				i += 1
		await process_frame
	var t1 := Time.get_ticks_msec()
	while not player.dead and Time.get_ticks_msec() - t1 < 12000:
		await process_frame
	print("kill: player dead = %s, reason %s (state %s)" % [player.dead, root.get_node("Game").death_reason, tall.state])

## The whole sequence from the first sighting, with the time of every state
func _chain() -> void:
	player.dead = false
	root.get_node("Game").dead = false
	player.frozen = false
	root.get_node("Game").fx_reset()
	var au: Node = main.get_node_or_null("Audio")
	if au != null: au.set_muffled(false)
	# (the level can start you in a safe room, which the monsters' nav treats as a wall: stand on open floor)
	for x in range(10, 90):
		var moved := false
		for z in range(10, 90):
			var ok := true
			for dx in range(-3, 4):
				for dz in range(-3, 4):
					if not tall.nav.open_at((x + dx) * 4.5, (z + dz) * 4.5): ok = false
			if ok:
				player.global_position = Vector3(x * 4.5, 0.1, z * 4.5)
				moved = true
				break
		if moved: break
	if not tall.debug_spawn():
		print("chain: could not spawn: ", tall.last_error)
		return
	var t0 := Time.get_ticks_msec()
	var last := ""
	var screamed_at := -1.0
	var hunted_at := -1.0
	while not player.dead and Time.get_ticks_msec() - t0 < 90000:
		if tall.state != last:
			last = tall.state
			var now := (Time.get_ticks_msec() - t0) / 1000.0
			print("  %.1f s: %s  (it is %.1f m away)" % [now, last, tall._dist_to_player()])
			if last == "scream": screamed_at = now
			if last == "hunt": hunted_at = now
		player.velocity = Vector3.ZERO
		await process_frame
	print("chain: dead = %s; scream -> hunt took %.1f s" % [player.dead, hunted_at - screamed_at])
