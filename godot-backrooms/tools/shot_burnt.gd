extends SceneTree
## THE BURNT's clips in a level (burnt.gd, theburnt_animated.glb): saves screenshots of it hiding at a wall corner
## and peeking out (from where you stand), its walk and its run (from the side), and the kill (through your own
## eyes), and prints what it was doing at each. Needs a window; the UI is hidden.
## Env: LEVEL (index, default 0), SHOT (output prefix, default res://burnt).
## godot --path . --resolution 1280x800 --script res://tools/shot_burnt.gd

var main: Node
var player: CharacterBody3D
var burnt: Node3D
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
	burnt = main.get_node("Burnt")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	main.get_node("UI").visible = false
	prefix = env_or.call("SHOT", "res://burnt")
	shot_cam = Camera3D.new()
	shot_cam.fov = 60.0
	main.add_child(shot_cam)
	player.spawn_grace = 0.0
	if burnt.body == null and not burnt._build():
		print("burnt: could not build: ", burnt.last_error)
		quit(1)
		return
	burnt._mark_pending = false            # (the level's own Burnt mark would stand it back there)
	burnt.present = true
	burnt.visible = true
	burnt.state = "stalk"
	print("level %d size %d, you at %s" % [game.level_index, level.size, player.global_position])
	print("burnt clips: ", burnt._ap.get_animation_list() if burnt._ap != null else "NONE")
	if env_or.call("ONLY", "") == "hug":
		await _hug()
		quit()
		return
	await _peek()
	await _gaits()
	await _kill()
	quit()

func _save(name: String) -> void:
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png("%s_%s.png" % [prefix, name])
	print("  saved %s_%s.png  (state %s, peek %s, clip %s @ %.2f, seen %s)" % [prefix, name, burnt.state, burnt._peek_phase,
			burnt._clip, burnt._ap.current_animation_position, burnt._is_seen])

## Your view turned onto `at` (or away from it)
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

# ------------------------------------------------------------------ the corner
func _peek() -> void:
	var n: int = level.size
	var found := false
	var you := Vector3.ZERO
	var y: float = player.global_position.y
	for tries in 4000:
		var b := Vector3(randi_range(1, n - 2) * 4.5, y, randi_range(1, n - 2) * 4.5)
		var p := b + Vector3(randf_range(-20, 20), 0, randf_range(-20, 20))
		if not burnt.nav.open_at(b.x, b.z) or not burnt.nav.open_at(p.x, p.z): continue
		var dd := Vector2(p.x - b.x, p.z - b.z).length()
		if dd < 9.0 or dd > 22.0: continue
		burnt.global_position = b
		if burnt.nav.clear_line(b.x, b.z, p.x, p.z): continue
		if burnt._find_peek(p):
			you = p
			found = true
			break
	if not found:
		print("peek: no corner found in this level")
		return
	player.frozen = true
	player.global_position = you
	print("peek: it at %s, you at %s, spot %s side %d" % [burnt.global_position, you, burnt._peek_at, burnt._peek_side])
	# you look away (it only moves unwatched); the shots are from your eyes, onto the corner
	_face(burnt._peek_head, true)
	burnt.state = "stalk"
	burnt._begin_peek()
	var t0 := Time.get_ticks_msec()
	while burnt._peek_phase in ["go", "set"] and Time.get_ticks_msec() - t0 < 12000:
		await process_frame
	print("peek: reached the spot (%s) after %.1f s" % [burnt._peek_phase, (Time.get_ticks_msec() - t0) / 1000.0])
	shot_cam.global_position = player.cam.global_position
	shot_cam.look_at(burnt._peek_head + Vector3.UP * 3.0, Vector3.UP)
	shot_cam.fov = 45.0
	shot_cam.make_current()
	await _wait(0.5)
	await _save("peek_reach")
	await _wait(1.3)
	await _save("peek_out")
	await _wait(1.0)
	await _save("peek_hold")
	# the corner from close, off to the side, to see the hand on the edge
	var side_view: Vector3 = burnt._peek_head + (you - burnt._peek_head).normalized() * 6.0 + Vector3.UP * 3.0
	shot_cam.global_position = side_view
	shot_cam.look_at(burnt._peek_head + Vector3.UP * 2.6, Vector3.UP)
	await _save("peek_close")
	# now you look at it: it must hold dead still
	_face(burnt._face())
	await _wait(0.6)
	var a: float = burnt._ap.current_animation_position
	await _wait(0.6)
	print("peek: watched, seen=%s, clip moved %.3f s in 0.6 s (want 0)" % [burnt._is_seen, burnt._ap.current_animation_position - a])
	# look away: it lets go and pulls back
	_face(burnt._peek_head, true)
	burnt._peek_t = 99.0
	await _wait(0.7)
	await _save("peek_back")
	await _wait(1.2)
	print("peek: after letting go: state %s phase '%s'" % [burnt.state, burnt._peek_phase])
	player.frozen = false

# ------------------------------------------------------------------ walk and run, from the side
func _gaits() -> void:
	# a long straight run of open cells: it walks along it toward you
	var n: int = level.size
	var y: float = player.global_position.y
	for tries in 4000:
		var a := Vector3(randi_range(1, n - 2) * 4.5, y, randi_range(1, n - 2) * 4.5)
		var dir := [Vector3(1, 0, 0), Vector3(0, 0, 1)][randi() % 2] as Vector3
		var b := a + dir * 22.5
		if not (burnt.nav.open_at(a.x, a.z) and burnt.nav.open_at(b.x, b.z) and burnt.nav.clear_line(a.x, a.z, b.x, b.z)): continue
		var side := dir.cross(Vector3.UP)
		var cam_at := a + dir * 9.0 + side * 2.0
		if not burnt.nav.open_at(cam_at.x, cam_at.z): cam_at = a + dir * 9.0 - side * 2.0
		if not burnt.nav.open_at(cam_at.x, cam_at.z): continue
		player.frozen = true
		player.global_position = b
		_face(a, true)
		burnt._end_peek()
		burnt._peek_cd = 999.0
		burnt.global_position = a
		burnt.yaw = atan2(dir.x, dir.z)
		burnt.state = "stalk"
		shot_cam.global_position = cam_at + Vector3.UP * 1.7
		shot_cam.fov = 70.0
		shot_cam.make_current()
		await _wait(1.5)
		shot_cam.look_at(burnt.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("walk_a")
		await _wait(0.6)
		shot_cam.look_at(burnt.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("walk_b")
		print("walk: _walk %.2f, clip speed %.2f" % [burnt._walk, burnt._ap.speed_scale])
		# caught: you turn on it, it stops dead mid-stride
		_face(burnt.global_position + Vector3.UP * 2.5)
		await _wait(0.4)
		shot_cam.look_at(burnt.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("walk_caught")
		await _wait(1.6)
		await _save("walk_settled")
		# the run (you unfrozen: frozen, you can't be taken, and it gives up)
		player.frozen = false
		burnt.global_position = a
		burnt._charge_cd = 0.0
		burnt._begin_charge()
		await _wait(0.5)
		shot_cam.look_at(burnt.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("run_crouch")
		await _wait(0.75)
		shot_cam.look_at(burnt.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("run_a")
		await _wait(0.2)
		shot_cam.look_at(burnt.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("run_b")
		await _wait(1.5)
		shot_cam.look_at(burnt.global_position + Vector3.UP * 2.2, Vector3.UP)
		await _save("run_end")
		burnt._end_charge()
		player.frozen = false
		return
	print("gaits: no straight corridor found")

# ------------------------------------------------------------------ the kill, through your eyes
func _kill() -> void:
	player.frozen = false
	player.spawn_grace = 0.0
	burnt._peek_cd = 999.0
	var p: Vector3 = player.global_position
	var fwd := -player.global_transform.basis.z
	fwd = Vector3(fwd.x, 0, fwd.z).normalized()
	burnt.global_position = Vector3(p.x, burnt.global_position.y, p.z) + fwd * 2.0
	burnt.yaw = atan2(-fwd.x, -fwd.z)
	burnt.rotation.y = burnt.yaw
	burnt.state = "stalk"
	player.cam.make_current()
	_face(burnt.global_position + Vector3.UP * 2.5)
	var marks := [["kill_grab", 0.85], ["kill_lift", 3.0], ["kill_lift_end", 6.6], ["kill_stare", 8.6], ["kill_stare_end", 10.3], ["kill_corrupt", 12.0]]
	var t0 := Time.get_ticks_msec()
	for m in marks:
		while (Time.get_ticks_msec() - t0) / 1000.0 < float(m[1]):
			await process_frame
		var eyes: Vector3 = player.cam.global_position
		var face: Vector3 = burnt._face()
		print("  %s: cam to its face %.2f m, fov %.0f" % [m[0], eyes.distance_to(face), player.cam.fov])
		await _save(m[0])
	var t1 := Time.get_ticks_msec()
	while not player.dead and Time.get_ticks_msec() - t1 < 15000:
		if burnt.state == "corrupt" and burnt.t > 1.2 and not has_meta("shot"):
			set_meta("shot", true)
			await _save("kill_corrupt_late")
		await process_frame
	print("kill: player dead = %s (state %s)" % [player.dead, burnt.state])

# ------------------------------------------------------------------ taken from behind (ONLY=hug)
func _hug() -> void:
	player.frozen = false
	player.spawn_grace = 0.0
	burnt._peek_cd = 999.0
	var fwd := -player.global_transform.basis.z
	fwd = Vector3(fwd.x, 0, fwd.z).normalized()
	var p: Vector3 = player.global_position
	burnt.global_position = Vector3(p.x, burnt.global_position.y, p.z) - fwd * 2.0
	burnt.yaw = atan2(fwd.x, fwd.z)
	burnt.rotation.y = burnt.yaw
	burnt.state = "stalk"
	player.cam.rotation.x = 0.0
	player.cam.make_current()
	var t0 := Time.get_ticks_msec()
	var shots := 0
	while Time.get_ticks_msec() - t0 < 6000 and burnt.state != "grab":
		if burnt.state == "hug":
			var cam: Vector3 = player.cam.global_position
			var hb: Vector3 = burnt.skel.global_transform * burnt.skel.get_bone_global_pose(burnt._bone["Head"]).origin
			var eye: Vector3 = burnt._face()
			print("  hug t %.2f: cam->eyes %.2f m  cam->head bone %.2f m  eyes rel cam (fwd %.2f, up %.2f)" % [burnt.t,
					cam.distance_to(eye), cam.distance_to(hb), (eye - cam).dot(burnt._hug_dir), eye.y - cam.y])
			if shots < 3 and burnt.t > shots * 0.9 + 0.3:
				await _save("hug_%d" % shots)
				shots += 1
		await process_frame
	await _wait(0.5)
	await _save("hug_after")
