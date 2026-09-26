extends "res://scripts/entities/bacteria/bacteria_nav.gd"
## THE BACTERIA, layer 3: what it knows. Sight is a view cone plus a line of sight on the grid; its range
## grows with your torch and a lit room, shrinks when you crouch, and is almost nothing if you stand still
## in the dark. What it sees builds `awareness` (1 = it has you). Hearing picks up footsteps (further on
## hard floors, see footsteps.gd) and queued noises, muffled by walls. In co-op it hunts whichever
## survivor is nearest, sticking with its target unless another is clearly closer.

const FOCUS_STICK := 0.8              # squared-distance factor: a new target must be clearly closer to steal it

var awareness := 0.0
var seen_target := false
var last_known := Vector3.ZERO
var last_vel := Vector3.ZERO
var last_seen_time := 0.0
var entity_noises: Array = []
var focus: Node3D                     # the survivor it is aimed at (its head tracks them)
var tgt := {"pos": Vector3.ZERO, "look": Vector3.FORWARD, "moving": false, "sprinting": false,
	"crouching": false, "torch": false, "lit": 0.0, "dead": false, "noise": 1.0}
var _peer_dead := {}                  # peer id -> was dead last look (a fresh death near it makes it run off, fed)

## Where the one it hunts is, or INF when there is nobody
func target_pos() -> Vector3:
	return Vector3.INF if tgt.dead else tgt.pos

func hear(pos: Vector3, radius: float) -> void:
	if entity_noises.size() < 16:
		entity_noises.append({"x": pos.x, "z": pos.z, "r": radius})

# A remote survivor it has just fed on: back off (bacteria.gd), don't stand over the body
func _fed_on_remote() -> void:
	pass

func gather_target() -> void:
	var here := global_position
	var best: Node3D = null
	var best_key := INF
	if not player.dead and Game.playing:
		best = player
		best_key = here.distance_squared_to(player.global_position) * (FOCUS_STICK if focus == player else 1.0)
	for id in Net.remotes:
		var r: Node3D = Net.remotes[id]
		if not is_instance_valid(r) or not r.seen or not r.visible or not r.playing:
			continue
		if r.dead:
			if not _peer_dead.get(id, false) and here.distance_to(r.global_position) < 9.0:
				_fed_on_remote()
			_peer_dead[id] = true
			continue
		_peer_dead[id] = false
		var key := here.distance_squared_to(r.global_position) * (FOCUS_STICK if focus == r else 1.0)
		if key < best_key:
			best = r
			best_key = key
	focus = best
	tgt.dead = best == null
	if best == null:
		return
	if best == player:
		tgt.pos = player.global_position
		tgt.moving = player.is_moving
		tgt.sprinting = player.is_sprinting
		tgt.crouching = player.is_crouching
		tgt.torch = player.flash_on and player.battery > 0.0
		tgt.lit = player.light_level
		tgt.look = -player.cam.global_transform.basis.z
		tgt.noise = player.step_noise()
	else:
		# another survivor: what we can tell from what they send (no light meter, so a torch stands in)
		tgt.pos = best.target_pos              # newest known spot, not the (slightly delayed) drawn one
		tgt.moving = best.speed > 0.1
		tgt.sprinting = best.speed > 3.2
		tgt.crouching = best.crouching
		tgt.torch = best.torch_on
		tgt.lit = 0.6 if best.torch_on else 0.3
		tgt.noise = 1.0
		var cp := cos(best.target_pitch)
		tgt.look = Vector3(-sin(best.rotation.y) * cp, sin(best.target_pitch), -cos(best.rotation.y) * cp)

# Returns the loudest thing it heard this think, or null
func perceive(dt: float):
	var p := global_position
	var fwd_x := sin(yaw)
	var fwd_z := cos(yaw)
	var lurking := state == "lurk"
	var best := false
	var best_score := 0.0
	if not tgt.dead:
		var dx: float = tgt.pos.x - p.x
		var dz: float = tgt.pos.z - p.z
		var dist := Vector2(dx, dz).length()
		var rng_m := SIGHT_RANGE
		if tgt.torch: rng_m *= TORCH_SIGHT_BONUS
		if tgt.lit > 0.5: rng_m *= 1.2
		if tgt.crouching: rng_m *= CROUCH_SIGHT
		if not tgt.moving and not tgt.torch: rng_m = minf(rng_m, STILL_SIGHT)
		if state == "chase": rng_m *= 1.5
		if winded > 0.0: rng_m *= 0.55
		if dist <= rng_m:
			var cos_a := (dx * fwd_x + dz * fwd_z) / dist if dist > 0.001 else 1.0
			var in_cone := cos_a > cos(SIGHT_FOV / 2.0) or dist < 2.5 or state == "chase"
			if in_cone and nav.clear_line(p.x, p.z, tgt.pos.x, tgt.pos.z):
				best = true
				best_score = (1.0 - dist / rng_m) * (1.0 if tgt.moving else 0.5) * (1.4 if tgt.torch else 1.0)
	if best:
		var rise := AWARENESS_RISE * (0.25 + best_score) * dt * (0.4 if winded > 0.0 else 1.0) * (LURK_SENSE if lurking else 1.0)
		awareness = minf(0.85 if winded > 0.0 else 1.0, awareness + rise)
		if seen_target:
			last_vel = Vector3(tgt.pos.x - last_known.x, 0.0, tgt.pos.z - last_known.z) / maxf(dt, 0.001)
		else:
			last_vel = Vector3.ZERO
		last_known = Vector3(tgt.pos.x, 0.0, tgt.pos.z)
		last_seen_time = 0.0
	else:
		awareness = maxf(0.0, awareness - AWARENESS_FALL * dt)
		last_seen_time += dt
	seen_target = best

	# Hearing: footsteps while moving (further on hard floors), plus queued noises (gunshots)
	var res := {"heard": null, "score": 0.0}
	var ears := LURK_HEAR if lurking else 1.0
	if not tgt.dead and tgt.moving:
		var r: float = HEAR_SPRINT if tgt.sprinting else (HEAR_CROUCH if tgt.crouching else HEAR_WALK)
		_consider_noise(res, tgt.pos.x, tgt.pos.z, r * float(tgt.noise) * ears)
	for nz in entity_noises:
		_consider_noise(res, nz.x, nz.z, nz.r)
	entity_noises.clear()
	return res.heard

func _consider_noise(res: Dictionary, x: float, z: float, radius: float) -> void:
	var p := global_position
	var d := Vector2(x - p.x, z - p.z).length()
	var r: float = (radius if nav.clear_line(p.x, p.z, x, z) else radius * 0.65) * (0.6 if winded > 0.0 else 1.0)
	if d > r:
		return
	var score := radius * (1.0 - d / r)
	if score > res.score:
		res.score = score
		res.heard = {"x": x, "z": z, "radius": radius}

# Is the survivor looking (nearly) straight at it, from under 40 m?
func looking_at_me(cos_limit: float) -> bool:
	var p := global_position
	var dx: float = p.x - tgt.pos.x
	var dz: float = p.z - tgt.pos.z
	var d := Vector2(dx, dz).length()
	var look := Vector2(tgt.look.x, tgt.look.z)
	var l := look.length() * d
	var dot: float = (look.x * dx + look.y * dz) / (l if l > 0.0 else 1.0)
	return d < 40.0 and dot > cos_limit

func distance_to_target() -> float:
	if tgt.dead:
		return INF
	return Vector2(tgt.pos.x - global_position.x, tgt.pos.z - global_position.z).length()
