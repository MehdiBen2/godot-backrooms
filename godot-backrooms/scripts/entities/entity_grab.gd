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
##   2.9 - 3.4s  bite    it lunges; claws violently rip across the victim, camera dragged into its mouth;
##                       screams, tearing blood slashes, massive screen trauma & blood stains
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
var dir := Vector3.FORWARD
var eye := 1.7

var _start_rot := Quaternion.IDENTITY
var _start_pos := Vector3.ZERO
var _start_fov := BASE_FOV

## Procedural claw rake / tear slashes across the player's view
class ClawSlashOverlay extends Control:
	var progress := 0.0
	var alpha := 1.0
	var pts: Array[PackedVector2Array] = []
	var flipped := false

	func _init(p_flipped := false) -> void:
		flipped = p_flipped
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 4 jagged claw rake lines across the screen
		var vs := DisplayServer.window_get_size() if DisplayServer.has_method("window_get_size") else Vector2i(1280, 720)
		var cx := vs.x * (0.42 if flipped else 0.58) + randf_range(-30, 30)
		var cy := vs.y * 0.45 + randf_range(-25, 25)
		var angle := (0.42 if not flipped else 2.68) + randf_range(-0.08, 0.08)
		var fwd := Vector2(cos(angle), sin(angle))
		var perp := Vector2(-fwd.y, fwd.x)
		for c in range(-2, 2):
			var line := PackedVector2Array()
			var origin := Vector2(cx, cy) + perp * (c * 44.0 + randf_range(-6, 6)) - fwd * randf_range(180, 240)
			var length := randf_range(400, 560)
			var steps := 14
			for s in range(steps + 1):
				var f := float(s) / float(steps)
				var pt := origin + fwd * (length * f) + perp * randf_range(-4.0, 4.0)
				line.append(pt)
			pts.append(line)

	func _process(delta: float) -> void:
		progress += delta * 2.6
		alpha = clampf(1.0 - (progress - 0.4) / 1.5, 0.0, 1.0)
		queue_redraw()
		if alpha <= 0.0:
			queue_free()

	func _draw() -> void:
		if alpha <= 0.0:
			return
		var col_shadow := Color(0.12, 0.01, 0.01, alpha * 0.8)
		var col_blood := Color(0.75, 0.02, 0.03, alpha * 0.95)
		var col_flesh := Color(0.95, 0.35, 0.25, alpha * 0.65)
		var draw_len := minf(1.0, progress * 4.5)
		for line in pts:
			var count := maxi(2, int(line.size() * draw_len))
			var sub_line: PackedVector2Array = line.slice(0, count)
			if sub_line.size() >= 2:
				draw_polyline(sub_line, col_shadow, 14.0, true)
				draw_polyline(sub_line, col_blood, 7.0, true)
				draw_polyline(sub_line, col_flesh, 2.5, true)

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

func _spawn_claw_slash(flipped: bool) -> void:
	var overlay := ClawSlashOverlay.new(flipped)
	var ui: Node = e.get_parent().get_node_or_null("UI")
	if ui != null:
		ui.add_child(overlay)
	else:
		e.get_tree().current_scene.add_child(overlay)

# It has you: called from the entity's reach check instead of an instant death
func start() -> void:
	var player: CharacterBody3D = e.player
	var cam: Camera3D = player.cam
	t = 0.0
	flat = false
	bitten = false
	ripped = false
	second_rip = false
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

	# Terror tremors and bite impact shake
	var tremor := 0.01 + 0.035 * _smooth((t - 0.5) / 2.0)
	var bite_shake := 0.20 * bite * (1.0 if t < FADE_AT else 0.3)
	var jit := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * (tremor + bite_shake)

	# Base hanging camera position
	var hang_pos := Vector3(
		p.x + (ep.x - p.x) * pull + dangle_x,
		lift_y + dangle_y,
		p.z + (ep.z - p.z) * pull + dangle_z
	)

	# On bite: violently pulled forward right into the gaping mouth
	var cam_pos := hang_pos.lerp(mouth_pos, bite * 0.75) + jit
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

	# Rolling / Dutch tilt as you dangle helplessly, with violent recoil jolts when claws rip in
	var rip_kick := (0.12 if (ripped and t < BITE_AT + 0.3) else 0.0) - (0.10 if (second_rip and t < BITE_AT + 0.55) else 0.0)
	var roll := (sin(t * 3.6) * 0.045 + sin(t * 7.2) * 0.018) * _smooth((t - 0.4) / 0.8) \
		+ 0.28 * _smooth((t - 0.8) / 2.0) + sin(t * 26.0) * 0.08 * bite + rip_kick
	b = b.rotated(b.z.normalized(), roll)
	b = b.orthonormalized()

	cam.global_transform = Transform3D(b, cam_pos)

	# FOV: initial whip punch, slow dread dilation, heartbeat throb, bite surge
	var fov_kick := 18.0 * exp(-t * 6.0)
	var fov_dread := 18.0 * _smooth((t - 0.5) / 2.2)
	var fov_pulse := sin(t * 7.5) * 2.2 * _smooth((t - 0.5) / 1.0)
	var fov_bite := 16.0 * bite
	cam.fov = _start_fov + fov_kick + fov_dread + fov_pulse + fov_bite

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
		_spawn_claw_slash(false)
		Death.bite(mouth_pos, p, cam_pos)

	if not second_rip and t >= BITE_AT + 0.28:
		second_rip = true
		_spawn_claw_slash(true)
		scares.splat()

	if bitten:
		# blood keeps raining from where you hang, and every drop that lands leaves a stain
		if randf() < delta * 15.0:
			Death.bite_drop(Vector3(p.x + randf_range(-0.3, 0.3), cam_pos.y - 0.4, p.z + randf_range(-0.3, 0.3)),
				Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)), randf_range(0.02, 0.05))
		if t < BITE_AT + 1.2 and randf() < delta * 12.0:
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
