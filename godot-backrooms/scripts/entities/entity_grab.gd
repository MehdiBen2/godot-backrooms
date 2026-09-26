extends RefCounted
## THE BACTERIA's grab (js/game/grab.js): it doesn't just kill you, it seizes you, hauls you up and
## eats you, and the camera is yours to watch it happen, helpless. Driven by entity.gd each physics
## frame while active(); owns the entity, the player's camera and the screen effects until it ends.
##
##   0.0 - 0.4s  snatch  it snaps onto you; violent downward jolt, camera whips to its FEET, FOV punch
##   0.4 - 2.6s  haul    it hoists you high into the air until you are eye-to-eye at the very top;
##                       the view slowly climbs up its body (legs -> chest -> neck -> head);
##                       arms wrap from the sides, claws clutching and digging into your neck/shoulders;
##                       dangling sway, Dutch tilt roll, terror tremors; heartbeat slows, flatline rises;
##                       flashlight actively tracks and illuminates the creature
##   2.6 - 2.9s  rear    it rears back with jaws wide open, preparing to strike
##   2.9 - 3.4s  bite    it lunges; jaws and claws tear into the victim, camera dragged into its mouth;
##                       3D high-velocity blood spray bursts, fine red mist, flesh chunks, violent trauma shake
##   3.4 - 5.0s  fade    life drains, edges close in to black
##   5.0s        death   death camera takes over smoothly from the final position

const CLIMB_START := 0.35
const CLIMB_END := 2.5
const BITE_AT := 2.9
const FLATLINE_AT := 1.7
const FADE_AT := 3.4
const TOTAL := 5.0
const HOLD := 1.15               # metres between it and you
const BASE_FOV := 75.0
const CELL := 4.5

var e: Node3D                    # the entity
var t := -1.0                    # seconds since it seized you, < 0 when it hasn't
var base := Vector3.ZERO         # where you stood (player feet)
var pos := Vector3.ZERO          # where it plants itself
var head_y := 3.9
var beat := 0.0
var flat := false
var bitten := false
var ripped := false
var second_rip := false
var third_rip := false
var dir := Vector3.FORWARD
var eye := 1.7

var trauma := 0.0
var impulse_pitch := 0.0
var impulse_yaw := 0.0
var impulse_roll := 0.0

var _start_rot := Quaternion.IDENTITY
var _start_pos := Vector3.ZERO
var _start_fov := BASE_FOV

func _init(entity: Node3D) -> void:
	e = entity

func active() -> bool:
	return t >= 0.0

func _smooth(x: float) -> float:
	var c := clampf(x, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)

func _ceiling_y(p: Vector3) -> float:
	if e != null and e.level != null and is_instance_valid(e.level) and e.level.has_method("ceiling_height"):
		return e.level.ceiling_height(Vector2i(roundi(p.x / CELL), roundi(p.z / CELL)))
	return 5.4

func _safe_look_basis(dir_to: Vector3, fallback_fwd: Vector3) -> Basis:
	if dir_to.length_squared() < 0.0001:
		return Basis.IDENTITY
	var fwd := dir_to.normalized()
	var up := Vector3.UP
	if absf(fwd.dot(up)) > 0.95:
		up = -fallback_fwd if absf(fallback_fwd.dot(fwd)) < 0.9 else Vector3.RIGHT
	return Basis.looking_at(fwd, up)

## Spawns genuine 3D blood splatter particle bursts exploding toward and past the player's view
func _spawn_blood_burst(origin: Vector3, to_cam: Vector3, intensity: float = 1.0) -> void:
	if e == null or not is_instance_valid(e) or not e.is_inside_tree():
		return
	var world := e.get_tree().current_scene
	if world == null:
		return
	var dir_norm := (to_cam.normalized() + Vector3(0.0, 0.18, 0.0)).normalized()

	# 1. High-velocity arterial blood spray (elongated droplets flying directly toward/past the camera)
	var p_spray := GPUParticles3D.new()
	p_spray.amount = int(120 * intensity)
	p_spray.lifetime = 0.85
	p_spray.one_shot = true
	p_spray.explosiveness = 0.96
	p_spray.local_coords = false
	p_spray.visibility_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))

	var mat_spray := ParticleProcessMaterial.new()
	mat_spray.direction = dir_norm
	mat_spray.spread = 58.0
	mat_spray.initial_velocity_min = 3.6 * intensity
	mat_spray.initial_velocity_max = 9.2 * intensity
	mat_spray.gravity = Vector3(0.0, -14.0, 0.0)
	mat_spray.damping_min = 0.5
	mat_spray.damping_max = 1.6
	mat_spray.scale_min = 0.8
	mat_spray.scale_max = 1.8
	mat_spray.particle_flag_align_y = true
	p_spray.process_material = mat_spray

	var cap_mesh := CapsuleMesh.new()
	cap_mesh.radius = 0.016
	cap_mesh.height = 0.14
	cap_mesh.radial_segments = 6
	cap_mesh.rings = 2
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.24, 0.006, 0.01, 0.96)
	cap_mat.roughness = 0.08
	cap_mat.specular = 0.95
	cap_mat.metallic = 0.05
	cap_mesh.material = cap_mat
	p_spray.draw_pass_1 = cap_mesh
	p_spray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(p_spray)
	p_spray.global_position = origin
	p_spray.emitting = true

	# 2. Fine blood mist / vapor cloud hanging in the flashlight beam
	var p_mist := GPUParticles3D.new()
	p_mist.amount = int(60 * intensity)
	p_mist.lifetime = 0.75
	p_mist.one_shot = true
	p_mist.explosiveness = 0.92
	p_mist.local_coords = false
	p_mist.visibility_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))

	var mat_mist := ParticleProcessMaterial.new()
	mat_mist.direction = dir_norm
	mat_mist.spread = 82.0
	mat_mist.initial_velocity_min = 1.8 * intensity
	mat_mist.initial_velocity_max = 5.4 * intensity
	mat_mist.gravity = Vector3(0.0, -4.5, 0.0)
	mat_mist.damping_min = 1.2
	mat_mist.damping_max = 2.8
	mat_mist.scale_min = 0.9
	mat_mist.scale_max = 2.2
	p_mist.process_material = mat_mist

	var sph_mesh := SphereMesh.new()
	sph_mesh.radius = 0.024
	sph_mesh.height = 0.048
	sph_mesh.radial_segments = 6
	sph_mesh.rings = 3
	var sph_mat := StandardMaterial3D.new()
	sph_mat.albedo_color = Color(0.38, 0.012, 0.018, 0.75)
	sph_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sph_mat.roughness = 0.15
	sph_mesh.material = sph_mat
	p_mist.draw_pass_1 = sph_mesh
	p_mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(p_mist)
	p_mist.global_position = origin
	p_mist.emitting = true

	# 3. Dense flesh/blood chunks exploding outward
	var p_chunks := GPUParticles3D.new()
	p_chunks.amount = int(25 * intensity)
	p_chunks.lifetime = 1.1
	p_chunks.one_shot = true
	p_chunks.explosiveness = 0.98
	p_chunks.local_coords = false
	p_chunks.visibility_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))

	var mat_chunks := ParticleProcessMaterial.new()
	mat_chunks.direction = (dir_norm + Vector3(randf_range(-0.4, 0.4), 0.3, randf_range(-0.4, 0.4))).normalized()
	mat_chunks.spread = 90.0
	mat_chunks.initial_velocity_min = 2.0 * intensity
	mat_chunks.initial_velocity_max = 7.5 * intensity
	mat_chunks.gravity = Vector3(0.0, -18.0, 0.0)
	mat_chunks.damping_min = 0.4
	mat_chunks.damping_max = 1.0
	mat_chunks.scale_min = 0.8
	mat_chunks.scale_max = 2.0
	p_chunks.process_material = mat_chunks

	var chunk_mesh := SphereMesh.new()
	chunk_mesh.radius = 0.032
	chunk_mesh.height = 0.064
	chunk_mesh.radial_segments = 5
	chunk_mesh.rings = 3
	var chunk_mat := StandardMaterial3D.new()
	chunk_mat.albedo_color = Color(0.14, 0.003, 0.006, 1.0)
	chunk_mat.roughness = 0.2
	chunk_mesh.material = chunk_mat
	p_chunks.draw_pass_1 = chunk_mesh
	p_chunks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(p_chunks)
	p_chunks.global_position = origin
	p_chunks.emitting = true

	# Auto-free after particles complete
	e.get_tree().create_timer(1.8).timeout.connect(func() -> void:
		if is_instance_valid(p_spray): p_spray.queue_free()
		if is_instance_valid(p_mist): p_mist.queue_free()
		if is_instance_valid(p_chunks): p_chunks.queue_free()
	)

# It has you: called from the entity's reach check instead of an instant death
func start() -> void:
	var player: CharacterBody3D = e.player
	var cam: Camera3D = player.cam
	t = 0.0
	flat = false
	bitten = false
	ripped = false
	second_rip = false
	third_rip = false
	trauma = 0.65
	impulse_pitch = 0.25
	impulse_yaw = 0.0
	impulse_roll = 0.0
	player.frozen = true
	player.velocity = Vector3.ZERO
	base = player.global_position
	eye = cam.position.y
	_start_rot = cam.global_transform.basis.get_rotation_quaternion()
	_start_pos = cam.global_position
	_start_fov = cam.fov

	# it stands right in front of you, facing you
	var d := Vector3(player.global_position.x - e.global_position.x, 0.0, player.global_position.z - e.global_position.z)
	dir = d.normalized() if d.length() > 0.001 else Vector3.FORWARD
	pos = Vector3(player.global_position.x - dir.x * HOLD, e.global_position.y, player.global_position.z - dir.z * HOLD)
	head_y = maxf(1.5, e.MODEL_HEIGHT * 0.85)
	e.yaw = atan2(dir.x, dir.z)
	e.rotation.y = e.yaw
	e.vel = Vector3.ZERO
	e.stun_timer = 0.0

	e.scares.gasp()
	e.scares.seize()
	e.scares.heartbeat(1.8)
	beat = 0.55
	Game.fx_reset()
	Game.fx_shock = 0.8
	Death.grab_begin()

func update(delta: float) -> void:
	t += delta
	var scares: Node = e.scares
	var cam: Camera3D = e.player.cam
	var p := base

	# the entity holds its pose: a strike animation, planted in front of you; it rears back to bite
	var rearing := t > BITE_AT - 0.35 and t < BITE_AT
	var lunging := t >= BITE_AT and t < BITE_AT + 0.4
	e.lunge_windup = 0.25 if rearing else 0.0
	e.lunge = 0.45 if lunging else 0.08
	e.global_position = e.global_position.lerp(pos, minf(1.0, delta * 14.0))
	e.yaw = atan2(dir.x, dir.z)
	e.rotation.y = e.yaw
	# Animate with dedicated grab pose: arms bracket the player and claws clutch/tear
	e.rig.animate(delta, 0.0, "grab")
	var ep: Vector3 = e.global_position

	# Target points on the bacteria: feet, head, and gaping jaws
	var feet_pos: Vector3 = e.rig.get_feet_global_pos() if e.rig and e.rig.has_method("get_feet_global_pos") else ep + Vector3(0.0, 0.2, 0.0) + dir * 0.25
	var head_pos: Vector3 = e.rig.get_head_global_pos() if e.rig and e.rig.has_method("get_head_global_pos") else ep + Vector3(0.0, head_y, 0.0) + dir * 0.35
	var mouth_pos: Vector3 = head_pos + dir * 0.18 + Vector3(0.0, -0.12, 0.0)

	# Ceiling check to make sure the lifted camera never clips low ceilings
	var ceil_h := _ceiling_y(cam.global_position)
	var max_y := ceil_h - 0.3

	# Initial snatch shock (sharp downward jerk / flinch as claws grab you)
	var snatch_dip := 0.22 * exp(-t * 7.0) * sin(t * 22.0)

	# The Haul Up: you are lifted high off the ground to the very top, eye-to-eye with its head!
	var rise := _smooth((t - 0.35) / 2.15)
	var target_eye_y := minf(head_pos.y - 0.05, max_y)
	var lift_y := lerpf(_start_pos.y, target_eye_y, rise) - snatch_dip

	# Helpless dangling / struggling suspension (natural pendular motion)
	var dangle_y := sin(t * 3.4) * 0.045 * rise
	var dangle_x := sin(t * 1.8) * 0.04 * rise
	var dangle_z := cos(t * 1.8) * 0.04 * rise

	# Horizontal pull toward its chest / mouth
	var bite := _smooth((t - BITE_AT) / 0.35)
	var pull := 0.25 * rise + 0.55 * bite

	# Screen Shake & Trauma Decay
	if t >= BITE_AT and t < FADE_AT:
		trauma = maxf(trauma, 0.85)
	elif t >= FADE_AT:
		trauma = move_toward(trauma, 0.0, delta * 0.65)
	else:
		trauma = move_toward(trauma, 0.08 + 0.14 * rise, delta * 0.4)

	impulse_pitch = move_toward(impulse_pitch, 0.0, delta * 3.8)
	impulse_yaw = move_toward(impulse_yaw, 0.0, delta * 3.8)
	impulse_roll = move_toward(impulse_roll, 0.0, delta * 3.8)

	var shake := trauma * trauma

	# Base hanging camera position
	var hang_pos := Vector3(
		p.x + (ep.x - p.x) * pull + dangle_x,
		lift_y + dangle_y,
		p.z + (ep.z - p.z) * pull + dangle_z
	)

	# On bite: violently pulled forward right into the gaping mouth
	var cam_pos := hang_pos.lerp(mouth_pos, bite * 0.75)
	cam_pos.y = minf(cam_pos.y, max_y)

	# Gaze climbs up its body from feet to head over 0.35s -> 2.5s
	var climb := _smooth((t - CLIMB_START) / (CLIMB_END - CLIMB_START))
	var look_target: Vector3 = feet_pos.lerp(head_pos, climb)

	# During the bite, look straight into the throat / maw
	if bite > 0.0:
		look_target = look_target.lerp(mouth_pos - dir * 0.4, bite)

	var to := look_target - cam_pos
	var target_basis := _safe_look_basis(to, dir)
	var target_quat := target_basis.get_rotation_quaternion()

	# Whip down to feet in the first 0.28s, then track the climbing target smoothly
	var whip := _smooth(t / 0.28)
	var cur_quat := _start_rot.slerp(target_quat, whip)
	var b := Basis(cur_quat)

	# Multi-axis rotational screen trauma shake: high-frequency shudder + directional impulses
	var s_pitch := (sin(t * 54.0) * 0.14 + sin(t * 112.0) * 0.07 + (randf() - 0.5) * 0.12) * shake + impulse_pitch
	var s_yaw := (cos(t * 46.0) * 0.12 + sin(t * 94.0) * 0.06 + (randf() - 0.5) * 0.10) * shake + impulse_yaw
	var s_roll := (sin(t * 38.0) * 0.16 + cos(t * 78.0) * 0.08 + (randf() - 0.5) * 0.14) * shake + impulse_roll

	# Dangling tilt
	var roll := (sin(t * 3.6) * 0.045 + sin(t * 7.2) * 0.018) * _smooth((t - 0.4) / 0.8) \
		+ 0.28 * _smooth((t - 0.8) / 2.0)

	b = b.rotated(b.x.normalized(), s_pitch)
	b = b.rotated(b.y.normalized(), s_yaw)
	b = b.rotated(b.z.normalized(), s_roll + roll)
	b = b.orthonormalized()

	# Positional camera shake displacement in camera space
	var shake_pos := (
		b.x * ((randf() - 0.5) * 0.35) +
		b.y * ((randf() - 0.5) * 0.30) +
		b.z * ((randf() - 0.5) * 0.24)
	) * shake

	cam.global_transform = Transform3D(b, cam_pos + shake_pos)

	# FOV: initial whip punch, slow dread dilation, heartbeat throb, bite surge, and trauma shake
	var fov_kick := 18.0 * exp(-t * 6.0)
	var fov_dread := 18.0 * _smooth((t - 0.5) / 2.2)
	var fov_pulse := sin(t * 7.5) * 2.2 * _smooth((t - 0.5) / 1.0)
	var fov_bite := 16.0 * bite
	var fov_shake := (randf() - 0.5) * 10.0 * shake
	cam.fov = _start_fov + fov_kick + fov_dread + fov_pulse + fov_bite + fov_shake

	# Flashlight actively tracks look_target so the monster is brightly illuminated
	var player: Node3D = e.player
	var flash: SpotLight3D = player.get("flash")
	var flash_on: bool = player.get("flash_on") if player.get("flash_on") != null else true
	if flash != null and is_instance_valid(flash) and flash_on:
		flash.visible = true
		flash.global_position = cam_pos + Vector3(0.0, -0.1, 0.0)
		var flash_dir := (look_target - flash.global_position).normalized()
		if flash_dir.length_squared() > 0.01:
			flash.look_at(flash.global_position + flash_dir, Vector3.UP)

	# Screen distortion: smear, colour bleed, wobble, and glitch
	var k := _smooth((t - 0.3) / 2.6)
	Game.fx_blur = k * 3.2 + bite * 2.6
	Game.fx_contrast = 1.0 + 0.35 * k
	Game.fx_sat = 1.0 - 0.5 * k + 0.6 * bite
	Game.fx_hue = sin(t * 9.0) * 14.0 * k - 8.0 * bite
	Game.fx_zoom = 1.03 + 0.05 * k + sin(t * 7.0) * 0.012 * k + 0.06 * bite
	Game.fx_skew = sin(t * 13.0) * 1.6 * k
	Game.glitch = minf(1.0, 0.5 + k)
	Game.fear = 1.0

	# The bite & claws ripping into the player:
	if not bitten and t >= BITE_AT:
		bitten = true
		ripped = true
		scares.splat()
		scares.startle(1.0)
		trauma = 1.0
		impulse_pitch = -0.45
		impulse_yaw = randf_range(-0.35, 0.35)
		impulse_roll = randf_range(-0.3, 0.3)
		Game.fx_shock = 1.0
		Game.fx_flash = 0.45
		Game.fx_blood = 0.95
		_spawn_blood_burst(mouth_pos, cam_pos - mouth_pos, 1.4)
		Death.bite(mouth_pos, p, cam_pos)

	if not second_rip and t >= BITE_AT + 0.24:
		second_rip = true
		scares.splat()
		trauma = 1.0
		impulse_pitch = randf_range(-0.25, 0.2)
		impulse_yaw = randf_range(-0.4, 0.4)
		impulse_roll = randf_range(-0.35, 0.35)
		Game.fx_shock = 0.85
		_spawn_blood_burst(mouth_pos + Vector3(randf_range(-0.12, 0.12), -0.06, randf_range(-0.12, 0.12)), cam_pos - mouth_pos, 1.1)

	if not third_rip and t >= BITE_AT + 0.50:
		third_rip = true
		scares.splat()
		trauma = 0.92
		impulse_pitch = randf_range(-0.2, 0.2)
		impulse_yaw = randf_range(-0.3, 0.3)
		Game.fx_shock = 0.7
		_spawn_blood_burst(mouth_pos, cam_pos - mouth_pos, 0.85)

	if bitten:
		# blood keeps raining from where you hang, and every drop that lands leaves a stain
		if randf() < delta * 18.0:
			Death.bite_drop(Vector3(p.x + randf_range(-0.3, 0.3), cam_pos.y - 0.4, p.z + randf_range(-0.3, 0.3)),
				Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)), randf_range(0.02, 0.05))
		if t < BITE_AT + 1.2 and randf() < delta * 15.0:
			Death.bite_drop(mouth_pos,
				Vector3(randf_range(-2.5, 2.5), randf_range(1.0, 4.0), randf_range(-2.5, 2.5)), randf_range(0.02, 0.05))

	# Heartbeat slows down as it goes on, until the flatline
	beat -= delta
	if beat <= 0.0 and t < FLATLINE_AT:
		beat = 0.55 + 0.9 * _smooth(t / FADE_AT)
		scares.heartbeat(1.7 - 0.7 * _smooth(t / FADE_AT))
	if not flat and t >= FLATLINE_AT:
		flat = true
		scares.flatline()

	# The world closes in a little at a time (never silent)
	var au: Node = e.get_parent().get_node_or_null("Audio")
	if au != null:
		au.set_dread(_smooth((t - 0.3) / 3.5))

	# The edges close in
	if t > FADE_AT:
		Game.fx_fade = _smooth((t - FADE_AT) / (TOTAL - FADE_AT))

	if t >= TOTAL:
		_end()

# Hand over to the death sequence (js endGrab(true) + killPlayer). The camera's FOV and tilt are left
# where the bite put them: the death camera eases on from there, and kill_player() hands the world's
# dread over to the dead muffle.
func _end() -> void:
	t = -1.0
	e.lunge = 0.0
	e.lunge_windup = 0.0
	Game.kill_player("THE BACTERIA")
	e.run_away()   # it has fed: it bolts away from the body (it keeps running while you lie there)
