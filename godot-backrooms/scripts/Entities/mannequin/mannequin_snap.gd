extends RefCounted
## THE MANNEQUIN's kill. It reaches you and you can't move: the view shakes with dread for a moment
## while your heart races, its joints creak as the hands close on your head, then your head is wrenched
## round to face it: the crack, and your heart stops on the spot. The death camera takes over from there.
##
## Camera work is trauma-based shake (Eiserloh, GDC 2016): amplitude = trauma^2 on smooth noise, mostly
## rotational. Dread (tremble, breathing sway, twitches) -> a flinch as the hands touch -> a fixed-
## direction whip onto its face that overshoots and settles -> the head lolling over.

const MannequinModel := preload("res://scripts/Entities/mannequin/mannequin_model.gd")
const SNAP_AT := 2.3
const TOTAL := 4.6
const FLINCH := 0.3                 # seconds before the snap its hands touch your head
const HEIGHT := MannequinModel.HEIGHT

var m: Node3D                       # mannequin.gd
var active := false
var t := 0.0
var snapped := false
var touched := false
var beat := 0.0
var twitch := 0.0
var jerk := 0.0
var start_pos := Vector3.ZERO
var cam_pos := Vector3.ZERO
var cam_pitch := 0.0
var light: OmniLight3D
var trauma := 0.0
var prepped := false
var yaw0 := 0.0
var pitch0 := 0.0
var pitch_t := 0.0
var yaw_delta := 0.0

func _init(owner: Node3D) -> void:
	m = owner

func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

# Smooth pseudo-noise in about -1..1 (sum of sines), for the trauma shake
func _noise(seed_v: float, time: float) -> float:
	return sin(time * 13.1 + seed_v * 4.7) * 0.5 + sin(time * 7.3 + seed_v * 8.1) * 0.3 + sin(time * 23.7 + seed_v * 2.9) * 0.2

func start() -> void:
	var player: CharacterBody3D = m.player
	var real: Node3D = m.real_node
	active = true
	t = 0.0
	snapped = false
	touched = false
	prepped = false
	trauma = 0.0
	beat = 0.6              # the start beats once already: 0 would fire a second one next frame
	player.frozen = true
	player.velocity = Vector3.ZERO
	# however it got here, it ends up standing right behind you, so the neck snap is always the same
	# full turn onto its face and never a clipped half-turn from the side
	var fwd: Vector3 = m.player_forward()
	var behind: Vector3 = m.nav.resolve(player.global_position - fwd * 0.95, m.RADIUS)
	behind.y = 0.0
	var to_b := Vector3(behind.x - player.global_position.x, 0.0, behind.z - player.global_position.z)
	if to_b.length() > 0.4 and to_b.normalized().dot(fwd) < -0.8:
		real.position = behind
	start_pos = real.position
	cam_pos = player.cam.position
	cam_pitch = player.cam.rotation.x
	m.scares.gasp()
	m.scares.startle(0.8)
	m.scares.heartbeat(1.8)
	# arms out, head still straight while it waits for you to look
	var to := player.global_position - real.position
	m.real_yaw = atan2(to.x, to.z)
	real.rotation.y = m.real_yaw
	var pose := MannequinModel.rest_pose()
	pose.armL = 1.45; pose.armR = 1.45; pose.splayL = 0.1; pose.splayR = 0.1; pose.lean = 0.08
	pose["align"] = 1.0
	m.set_pose(pose)

func update(delta: float) -> void:
	t += delta
	var player: CharacterBody3D = m.player
	var cam: Camera3D = player.cam
	var real: Node3D = m.real_node
	var scares: Node = m.scares
	var dread := _smooth(t / SNAP_AT)
	# js mqUpdateSnap: the turn is a violent whip (fast out, slight overshoot, settle), not a cut
	var turn_x := clampf((t - SNAP_AT) / 0.3, 0.0, 1.0)
	var whip := 0.0 if turn_x <= 0.0 else minf(1.06, 1.0 - pow(1.0 - turn_x, 3.0) + sin(turn_x * PI) * 0.06)
	var p := player.global_position
	if turn_x > 0.0:
		# it does NOT lunge or lean in: the body stays exactly where it stood behind you, and only the
		# head tilts and the hands settle, so nothing reads as the figure sliding toward the camera
		var k := 1.0 - pow(1.0 - turn_x, 4.0)
		real.position = start_pos
		var reach := 1.0 + 0.25 * k
		var pose := MannequinModel.rest_pose()
		pose.lean = 0.08; pose.headNod = 0.2 * k; pose.headTilt = 0.5 * k; pose.headYaw = 0.35 * k
		pose.armL = reach; pose.armR = reach; pose.splayL = 0.1 - 0.3 * k; pose.splayR = 0.1 - 0.3 * k
		pose["align"] = 1.0
		m.set_pose(pose)
	var a := maxf(0.0, t - SNAP_AT)
	trauma = maxf(0.0, trauma - delta * 1.1)
	if t < SNAP_AT:
		trauma = maxf(trauma, 0.10 + 0.32 * dread * dread)
	var flinch := _smooth((t - (SNAP_AT - FLINCH)) / 0.12) * (1.0 - _smooth((t - SNAP_AT) / 0.05))
	var tr2 := trauma * trauma
	# its hands close on your head: the dry joints creak right behind you
	if not touched and t >= SNAP_AT - FLINCH:
		touched = true
		scares.mannequin_settle(real.position + Vector3(0.0, HEIGHT * 0.8, 0.0), 1.3)
	# the whip's turn direction and end point are fixed the moment it starts, so it never flips or wanders
	if t >= SNAP_AT and not prepped:
		prepped = true
		var toh := Vector3(start_pos.x - p.x, 0.0, start_pos.z - p.z)
		var yaw_t := atan2(-toh.x, -toh.z)
		yaw0 = player.rotation.y
		pitch0 = cam.rotation.x
		yaw_delta = wrapf(yaw_t - yaw0, -PI, PI)
		if absf(yaw_delta) > PI - 0.2:
			yaw_delta = PI * (1.0 if m.rng.randf() < 0.5 else -1.0)   # it is right behind you: pick a side
		var head_h := HEIGHT * 0.92 - (cam_pos.y + p.y)
		pitch_t = clampf(atan2(head_h, maxf(toh.length(), 0.5)) + 0.08, -0.6, 1.0)
		trauma = 1.0
	var roll := 0.0
	if t < SNAP_AT:
		roll = sin(t * 2.1) * 0.035 * dread + 0.07 * dread * dread
		var pitch_add := sin(t * 1.3) * 0.025 * dread - 0.03 * dread - 0.06 * flinch
		twitch -= delta
		if twitch <= 0.0:
			twitch = 0.7 - 0.5 * dread + m.rng.randf() * 0.4
			jerk = (m.rng.randf() - 0.5) * 0.35 * (0.4 + dread)
		jerk *= exp(-delta * 9.0)
		cam.position = cam_pos + Vector3(0.0, -0.05 * dread - 0.05 * flinch, 0.0)
		player.rotation.y += jerk * 0.3 * delta * 6.0
		cam.rotation.x = cam_pitch + pitch_add
	else:
		# ease-out-back: fast out, overshoot, settle
		var x := clampf(a / 0.2, 0.0, 1.0)
		var c1 := 2.2
		var e := 1.0 + (c1 + 1.0) * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0)
		player.rotation.y = yaw0 + yaw_delta * e + _noise(1.0, t) * 0.09 * tr2
		cam.rotation.x = clampf(pitch0 + (pitch_t - pitch0) * e + _noise(2.0, t) * 0.07 * tr2, -1.4, 1.4)
		# head cranked over at a wrong angle, then lolling. The view holds its height and keeps staring
		# into its face: no sinking, the death camera lifts away from right here
		roll = 0.34 * e + 0.06 * _smooth(a / 1.8) + sin(a * 2.4) * 0.03 * _smooth(a / 0.6)
		cam.position = cam_pos + Vector3(_noise(3.0, t), _noise(4.0, t), _noise(5.0, t)) * 0.05 * tr2
	cam.rotation.z = roll + _noise(6.0, t) * 0.12 * tr2
	if not snapped and t >= SNAP_AT:
		snapped = true
		scares.death_reaction(Game.DeathType.NECK_SNAP)
		scares.startle(1.0)
		scares.flatline()             # the heart stops with the neck
		Game.add_glitch(1.0)
		# blood sprays from its face and splatters the glass
		Death.bite(real.position + Vector3(0, HEIGHT * 0.9, 0), player.global_position, cam.global_position)
	Game.fear = 1.0
	if t < SNAP_AT:
		Game.add_glitch(0.3 * dread)
	# js: blur(1.2px -> 0 over 0.5 s) saturate(1.4) contrast(1.3) once snapped; edges close in from 3.7 s
	if whip > 0.0:
		Game.fx_blur = 1.2 * (1.0 - minf(1.0, (t - SNAP_AT) * 2.0))
		Game.fx_sat = 1.4
		Game.fx_contrast = 1.3
		var kb := t - SNAP_AT
		Game.fx_blood = 0.7 * _smooth(kb / 0.5)
		Game.fx_static = 0.3 + 0.1 * sin(t * 9.0)
		Game.fx_warp = 0.003 + 0.006 * exp(-kb * 3.0)
	if t > 3.7:
		Game.fx_fade = _smooth((t - 3.7) / (TOTAL - 3.7))
	# a cold lamp between you and its head: flares at the snap, flickers
	if light == null:
		light = OmniLight3D.new()
		light.light_color = Color(0.875, 0.9, 1.0)
		light.omni_range = 5.0
		light.light_energy = 0.0
		player.get_parent().add_child(light)
	var hp := real.position + Vector3(0, HEIGHT * 0.92, 0)
	var cp := cam.global_position
	light.global_position = Vector3(cp.x + (hp.x - cp.x) * 0.5, hp.y + 0.25, cp.z + (hp.z - cp.z) * 0.5)
	light.light_energy = ((5.0 + 3.0 * exp(-(t - SNAP_AT) * 6.0)) * (0.85 + m.rng.randf() * 0.15) * 0.15) if whip > 0.0 else 0.6 * dread * 0.15
	# the lens holds still: narrowing it during the dread read as the camera itself creeping forward
	cam.fov = player.base_fov - 1.5 * dread * (1.0 - clampf(whip, 0.0, 1.0)) + 3.0 * exp(-maxf(0.0, t - SNAP_AT) * 9.0) * (1.0 if whip > 0.0 else 0.0)
	# heartbeat quickens toward the snap
	beat -= delta
	if beat <= 0.0 and t < SNAP_AT:
		beat = 0.6 - 0.35 * dread
		scares.heartbeat(1.5 + dread)
	if t >= TOTAL:
		finish()
		# the head stays lolled over: the death camera eases the view round from there
		Game.kill_player("THE MANNEQUIN", Game.DeathType.NECK_SNAP)

func finish() -> void:
	active = false
	if light != null and is_instance_valid(light):
		light.queue_free()
	light = null
