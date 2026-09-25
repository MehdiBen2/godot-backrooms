extends RefCounted
## THE BACTERIA's grab (js/game/grab.js): it doesn't just kill you, it seizes you, hauls you up and
## eats you, and the camera is yours to watch it happen, helpless. Driven by entity.gd each physics
## frame while active(); owns the entity, the player's camera and the screen effects until it ends.
##
##   0.0 - 0.5s  snatch  it snaps onto you; the view whips down to its FEET, FOV punch
##   0.5 - 2.9s  held    you are lifted while the view slowly climbs its body toward the head; the view
##                       rolls, breathes, smears and warps; heartbeat slows, the world muffles, a quiet
##                       flatline rises
##   2.9 - 3.4s  bite    the camera is dragged into its jaws; screaming + blood splatter, blood sprays
##                       through the level and stains the floor and walls
##   3.4 - 5.0s  fade    the edges close in to black
##   5.0s        death   the normal death sequence takes over (ragdoll, death camera, respawn)

const CLIMB_START := 0.25
const CLIMB_END := 1.2
const BITE_AT := 2.9
const FLATLINE_AT := 1.7
const FADE_AT := 3.5
const TOTAL := 5.0
const HOLD := 1.1                # metres between it and you
const LIFT := 1.35               # metres you are raised
const BASE_FOV := 75.0

var e: Node3D                    # the entity
var t := -1.0                    # seconds since it seized you, < 0 when it hasn't
var base := Vector3.ZERO         # where you stood
var pos := Vector3.ZERO          # where it plants itself
var head_y := 3.9
var beat := 0.0
var flat := false
var bitten := false
var dir := Vector3.FORWARD
var eye := 1.7

func _init(entity: Node3D) -> void:
	e = entity

func active() -> bool:
	return t >= 0.0

func _smooth(x: float) -> float:
	var c := clampf(x, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)

# It has you: called from the entity's reach check instead of an instant death
func start() -> void:
	var player: CharacterBody3D = e.player
	t = 0.0
	beat = 0.0
	flat = false
	bitten = false
	player.frozen = true
	player.velocity = Vector3.ZERO
	base = player.global_position
	eye = (player.cam as Camera3D).position.y
	# it stands right at you, facing you
	var d := Vector3(player.global_position.x - e.global_position.x, 0.0, player.global_position.z - e.global_position.z)
	dir = d.normalized() if d.length() > 0.001 else Vector3.FORWARD
	pos = Vector3(player.global_position.x - dir.x * HOLD, e.global_position.y, player.global_position.z - dir.z * HOLD)
	# where its head is (its model is big): the view climbs there
	head_y = maxf(1.5, e.MODEL_HEIGHT * 0.85)
	e.yaw = atan2(dir.x, dir.z)
	e.rotation.y = e.yaw
	e.vel = Vector3.ZERO
	e.stun_timer = 0.0
	e.scares.gasp()
	e.scares.startle(1.0)
	e.scares.play_scare("staticHit", 1.0)
	e.scares.heartbeat(1.8)
	Game.fx_reset()
	Death.grab_begin()

func update(delta: float) -> void:
	t += delta
	var scares: Node = e.scares
	var cam: Camera3D = e.player.cam
	var p := base

	# the entity holds its pose: a strike animation, planted in front of you; it rears back to bite
	var rearing := t > BITE_AT - 0.35 and t < BITE_AT
	e.lunge_windup = 0.1 if rearing else 0.0
	e.lunge = 0.0 if rearing else 0.1
	e.global_position = e.global_position.lerp(pos, minf(1.0, delta * 14.0))
	e.yaw = atan2(dir.x, dir.z)
	e.rotation.y = e.yaw
	e.rig.animate(delta, 0.0, "chase")
	var ep: Vector3 = e.global_position

	# camera: you are lifted off the floor and dragged toward it
	var rise := _smooth((t - 0.3) / 1.5)
	var bite := _smooth((t - BITE_AT) / 0.4)
	var lift := LIFT * rise + sin(t * 2.2) * 0.05 * rise
	var shake := 0.012 + 0.05 * _smooth((t - 0.5) / 2.0) + 0.16 * bite * (1.0 if t < FADE_AT else 0.3)
	# ...and on the bite straight into its mouth, at the top of its head height
	var pull := 0.22 * rise + 0.6 * bite
	var mouth_y := ep.y + head_y * 0.86
	var base_y := p.y + eye + lift
	var jit := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * shake
	var cam_pos := Vector3(
		p.x + (ep.x - p.x) * pull + jit.x,
		base_y + (mouth_y - base_y) * bite + jit.y,
		p.z + (ep.z - p.z) * pull + jit.z)

	# what it looks at: down at its feet on the snatch, then up its body to the head, then the jaws
	var climb := _smooth((t - CLIMB_START) / (CLIMB_END - CLIMB_START))
	var look_y := ep.y + 0.1 + (head_y - 0.1) * climb
	var to := Vector3(ep.x, look_y, ep.z) - cam_pos
	var basis_now: Basis = cam.global_transform.basis.orthonormalized()
	if to.length_squared() > 0.0001:
		var want := Basis.looking_at(to.normalized(), Vector3.UP)
		basis_now = basis_now.slerp(want, _smooth(t / 0.18))
	# rolling and swaying as it shakes you, tipping further the longer it holds
	var roll := (sin(t * 5.3) * 0.05 + sin(t * 11.0) * 0.02) * _smooth((t - 0.4) / 0.8) \
		+ 0.32 * _smooth((t - 0.8) / 2.6) + sin(t * 27.0) * 0.06 * bite
	cam.global_transform = Transform3D(basis_now.rotated(basis_now.z, roll), cam_pos)

	# FOV: a punch on impact, a slow warp with each heartbeat, a jolt on the bite
	cam.fov = BASE_FOV + 20.0 * exp(-t * 6.0) + 22.0 * _smooth((t - 0.5) / 2.2) \
		+ sin(t * 8.0) * 3.0 * _smooth((t - 0.5) / 1.0) + 14.0 * bite

	# screen distortion: smear, colour bleed, wobble, and the existing static/glitch pass
	var k := _smooth((t - 0.3) / 2.6)
	Game.fx_blur = k * 3.2 + bite * 2.0
	Game.fx_contrast = 1.0 + 0.35 * k
	Game.fx_sat = 1.0 - 0.5 * k + 0.6 * bite
	Game.fx_hue = sin(t * 9.0) * 14.0 * k - 8.0 * bite
	Game.fx_zoom = 1.03 + 0.05 * k + sin(t * 7.0) * 0.012 * k + 0.05 * bite
	Game.fx_skew = sin(t * 13.0) * 1.6 * k
	Game.glitch = minf(1.0, 0.5 + k)
	Game.fear = 1.0

	# the bite: screaming and blood splatter, blood on the glass
	if not bitten and t >= BITE_AT:
		bitten = true
		scares.splat()
		scares.startle(1.0)
		Death.bite(Vector3(ep.x + dir.x * 0.4, ep.y + head_y * 0.8, ep.z + dir.z * 0.4), p, cam_pos)
	if bitten:
		# blood keeps raining from where you hang, and every drop that lands leaves a stain
		if randf() < delta * 14.0:
			Death.bite_drop(Vector3(p.x + randf_range(-0.3, 0.3), cam_pos.y - 0.4, p.z + randf_range(-0.3, 0.3)),
				Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)), randf_range(0.02, 0.05))
		if t < BITE_AT + 1.2 and randf() < delta * 10.0:
			Death.bite_drop(Vector3(ep.x, ep.y + head_y * 0.8, ep.z),
				Vector3(randf_range(-2.5, 2.5), randf_range(1.0, 4.0), randf_range(-2.5, 2.5)), randf_range(0.02, 0.05))

	# heartbeat slows down as it goes on, until the flatline: once the line starts, the heart has stopped
	beat -= delta
	if beat <= 0.0 and t < FLATLINE_AT:
		beat = 0.55 + 0.9 * _smooth(t / FADE_AT)
		scares.heartbeat(1.7 - 0.7 * _smooth(t / FADE_AT))
	if not flat and t >= FLATLINE_AT:
		flat = true
		scares.flatline()

	# the world closes in a little at a time (never silent), the heartbeat and flatline carry on
	var au: Node = e.get_parent().get_node_or_null("Audio")
	if au != null:
		au.set_dread(_smooth((t - 0.3) / 3.5))

	# the edges close in
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
