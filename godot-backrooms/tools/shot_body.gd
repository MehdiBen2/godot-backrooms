extends SceneTree
## Your own body seen looking down (player_shadow.gd's legs), standing, walking and sprinting, saved to
## res://body_<state>_<n>.png. Needs a window (not --headless).
##   powershell -File tools/run_bg.ps1 -Offscreen -GodotArgs "--resolution 1280x720 --script res://tools/shot_body.gd"

const PlayerShadow := preload("res://scripts/Player/player_shadow.gd")
const PITCH := -66.0              # player_state.gd's furthest look down

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var world := Node3D.new()
	get_root().add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.25, 0.23, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.68, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-1.0, 0.4, 0.0)
	world.add_child(sun)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor.mesh = pm
	world.add_child(floor)
	# stands in for the player: player_shadow.gd reads its `cam` (and `torch`, none here)
	var s := GDScript.new()
	s.source_code = "extends Node3D\nvar cam: Camera3D\nvar torch\n"
	s.reload()
	var player := Node3D.new()
	player.set_script(s)
	world.add_child(player)
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.near = 0.05
	cam.position.y = 1.7
	cam.rotation.x = deg_to_rad(PITCH)
	player.add_child(cam)
	player.set("cam", cam)
	cam.make_current()
	var body := PlayerShadow.new()
	player.add_child(body)
	if not body.build():
		push_error("body build failed")
		quit(1)
		return
	for state in [["stand", 0.0, false], ["walk", 2.5, false], ["sprint", 6.0, true]]:
		var speed: float = state[1]
		var t0 := Time.get_ticks_msec()
		var n := 0
		while n < 4:
			var moving := speed > 0.0
			body.update(moving, state[2], false, false, speed, Vector3(0, 0, -speed), deg_to_rad(PITCH))
			await process_frame
			var t := (Time.get_ticks_msec() - t0) / 1000.0
			if t > 1.5 + n * 0.17:
				RenderingServer.force_draw(false)
				get_root().get_texture().get_image().save_png("res://body_%s_%d.png" % [state[0], n])
				n += 1
				var sk: Skeleton3D = body._legs_sk
				var w := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Waist")).origin
				var c := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Spine02")).origin
				print(state[0], " push ", snappedf(body._legs_push, 0.01), " waist ", w.snapped(Vector3.ONE * 0.01), " chest ", c.snapped(Vector3.ONE * 0.01))
	quit()
