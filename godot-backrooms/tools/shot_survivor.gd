extends SceneTree
## Walks the survivor suit (models/player/survivor.glb) through every state the way the game drives it
## (player_shadow.gd -> survivor_anim.gd): idle, walk, run, sprint, crouch idle, crouch walk, death, easing
## the speed in and out like player.gd. The body really travels across a grid at that speed, so it prints how
## fast each state's planted feet slide over the floor (0 = no skating), and snapshots every transition.
## Env: SHOT (output prefix, default res://survivor).
## xvfb-run -s "-screen 0 480x480x24" godot --path . --resolution 480x480 --rendering-driver opengl3 --script res://tools/shot_survivor.gd

const Shadow := preload("res://scripts/Player/player_shadow.gd")
const DT := 1.0 / 60.0
const ACCEL := 16.0          # player.gd ACCEL_GROUND / DECEL_GROUND, x the target speed per second
const DECEL := 22.0

# label, seconds, target speed (m/s), sprinting, crouching, dead
const PLAN := [
	["idle", 2.0, 0.0, false, false, false],
	["walk", 2.0, 1.0, false, false, false],
	["run", 2.5, 2.6, false, false, false],
	["sprint", 2.0, 4.55, true, false, false],
	["run", 1.5, 2.6, false, false, false],
	["idle", 1.5, 0.0, false, false, false],
	["crouch_idle", 2.0, 0.0, false, true, false],
	["crouch_walk", 3.0, 1.35, false, true, false],
	["crouch_idle", 1.5, 0.0, false, true, false],
	["run", 1.5, 2.6, false, false, false],
	["crouch_walk", 2.0, 1.35, false, true, false],
	["idle", 1.5, 0.0, false, false, false],
	["dead", 3.0, 0.0, false, false, true],
]
const SNAP_AT := [0.0, 0.08, 0.16, 0.24, 0.6]    # seconds into each segment

func _initialize() -> void:
	var prefix := OS.get_environment("SHOT") if OS.get_environment("SHOT") != "" else "res://survivor"
	var world := Node3D.new()
	root.add_child(world)
	await process_frame
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.33, 0.33, 0.36)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.7)
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.8, 0.6, 0.0)
	world.add_child(sun)
	var line := StandardMaterial3D.new()
	line.albedo_color = Color(0.12, 0.12, 0.12)
	for i in range(-4, 60):              # a line across the floor every half metre along the way
		var m := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = Vector3(1.6, 0.004, 0.02)
		m.mesh = b
		m.material_override = line
		m.position = Vector3(0, 0.002, -i * 0.5)
		world.add_child(m)

	var body := Shadow.new()
	world.add_child(body)
	if not body.build():
		print("FAILED: survivor model did not load")
		quit(1)
		return
	for m in body.find_children("*", "MeshInstance3D", true, false):
		(m as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		(m as MeshInstance3D).layers = 1
	var anim: AnimationPlayer = body.anim
	anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	print("clips: ", body.clips)
	var sk: Skeleton3D = body.find_children("*", "Skeleton3D", true, false)[0]
	var toes := [sk.find_bone("L_ToeBase"), sk.find_bone("R_ToeBase")]

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.8
	world.add_child(cam)

	var speed := 0.0
	var shot := 0
	for seg in PLAN:
		var label: String = seg[0]
		var n := int(round(float(seg[1]) / DT))
		var prev := []
		var slides := []
		var lowest := [INF, INF]
		var dip := INF               # lowest toe during the cross-fade in (the floor is at 0)
		var snaps := SNAP_AT.duplicate()
		for i in n:
			var t := i * DT
			var target: float = seg[2]
			speed = move_toward(speed, target, (ACCEL if target > speed else DECEL) * maxf(target, 2.6) * DT)
			body.position.z -= speed * DT
			body.update(target > 0.0, seg[3], seg[4], seg[5], speed)
			anim.advance(DT)
			cam.position = body.position + Vector3(4.0, 1.0, 0.0)
			cam.look_at(body.position + Vector3(0, 0.8, 0))
			# planted feet: the lowest a toe gets once the cross-fade is over, give or take 2 cm
			var now := []
			for k in 2:
				var p := sk.global_transform * sk.get_bone_global_pose(toes[k]).origin
				now.append(p)
				if t < 0.4:
					dip = minf(dip, p.y)
					continue
				lowest[k] = minf(lowest[k], p.y)
				if t > 0.5 and not prev.is_empty() and p.y < lowest[k] + 0.02 and prev[k].y < lowest[k] + 0.02:
					slides.append(Vector2(p.x - prev[k].x, p.z - prev[k].z).length() / DT)
			prev = now
			if not snaps.is_empty() and t >= snaps[0]:
				snaps.pop_front()
				await process_frame
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png("%s_%03d_%s_%.2f.png" % [prefix, shot, label, t])
				shot += 1
		slides.sort()
		var med: float = slides[slides.size() / 2] if not slides.is_empty() else 0.0
		var p90: float = slides[int(slides.size() * 0.9)] if not slides.is_empty() else 0.0
		print("%-12s role=%-12s clip=%-16s speed %.2f m/s  scale %.2f  planted-foot slide median %.2f m/s, p90 %.2f m/s  toe low in blend %+.3f m" % [
			label, body._role, body.clips.get(body._role, ""), speed, anim.speed_scale, med, p90, dip])
	quit()
