extends "res://scripts/Player/player_doors.gd"
## Tight spaces and hands on walls: the squeeze gap, crawl camera clips, both hands on a slit, corner grab and swing.

## At a squeeze gap (a slit through a wall): the body goes slim in its funnel so it fits, and inside the slit
## you're squeezed: slow, breathing hard, the view glancing aside and back as you go in
func _update_squeeze(dt: float) -> void:
	_sq = Game.level.squeeze_at(global_position) if Game.level != null and Game.level.has_method("squeeze_at") and not dead else {}
	var cap := shape.shape as CapsuleShape3D
	if _sq_radius <= 0.0:
		_sq_radius = cap.radius
	cap.radius = move_toward(cap.radius, SQUEEZE_RADIUS if not _sq.is_empty() else _sq_radius, dt * (3.0 if not _sq.is_empty() else 0.8))
	var inside: bool = not _sq.is_empty() and absf((_sq.local as Vector3).x) <= Game.level.CELL * 0.5 + 0.1
	tight_k = lerpf(tight_k, 1.0 if inside else 0.0, minf(1.0, dt * 3.0))
	# the camera's way in and out (thresholds apart, so hovering at the mouth doesn't restart them)
	if tight_k >= 0.35 and (_sq_cam_anim == 0 or _sq_cam_anim == 3):
		if _sq_cam_anim == 0:
			_sq_side = 1.0 if randf() < 0.5 else -1.0
		_sq_cam_play(1, SQ_ENTER)
	elif tight_k < 0.25 and (_sq_cam_anim == 1 or _sq_cam_anim == 2):
		_sq_cam_play(3, SQ_EXIT)
	if _sq_cam_anim == 1 or _sq_cam_anim == 3:
		_sq_cam_t += dt
		_sq_cam = _sq_cam_sample(_sq_cam_keys, _sq_cam_t)
		if _sq_cam_t >= float(_sq_cam_keys[-1][0]):
			_sq_cam_anim = 2 if _sq_cam_anim == 1 else 0
	# the hands in the slit: their slow drift, and now and then one comes up off the wall and goes back
	_sq_clock += dt
	for i in 2:
		if _sq_raise_t[i] >= 0.0:
			_sq_raise_t[i] += dt
			if _sq_raise_t[i] >= SQ_RAISE_TIME * 0.5 and _sq_raise_t[i] - dt < SQ_RAISE_TIME * 0.5:
				_sq_raise_dy[i] = randf_range(-0.05, 0.05)     # put back somewhere a little different
			if _sq_raise_t[i] >= SQ_RAISE_TIME:
				_sq_raise_t[i] = -1.0
	if tight_k > 0.5:
		_sq_raise_in -= dt * (1.0 if is_moving else 0.4)
		if _sq_raise_in <= 0.0:
			_sq_raise_in = randf_range(SQ_RAISE_EVERY.x, SQ_RAISE_EVERY.y)
			var i := randi() % 2
			if _sq_raise_t[i] < 0.0:
				_sq_raise_t[i] = 0.0

## Start camera clip `keys` (SQ_ENTER / SQ_EXIT) from wherever the camera is now, so cutting one short for
## the other never jumps
func _sq_cam_play(anim: int, keys: Array) -> void:
	_sq_cam_anim = anim
	_sq_cam_t = 0.0
	_sq_cam_keys = keys.duplicate(true)
	var first: Array = [0.0]
	first.append_array(_sq_cam)
	_sq_cam_keys[0] = first

## The clip at `t`: eased (smoothstep) from key to key
func _sq_cam_sample(keys: Array, t: float) -> Array:
	for k in range(1, keys.size()):
		var b: Array = keys[k]
		if t <= float(b[0]) or k == keys.size() - 1:
			var a: Array = keys[k - 1]
			var u := smoothstep(float(a[0]), float(b[0]), t)
			var out: Array = []
			for j in range(1, 7):
				out.append(lerpf(float(a[j]), float(b[j]), u))
			return out
	return _sq_cam

## Both hands flat on the slit's walls (or, crawling, on the floor), fingers on the way through, while you're in it
func _set_squeeze_hands() -> void:
	if torch == null:
		return
	if crawl_k > 0.5 and tight_k < 0.5:
		# crawling: a hand flat on the floor each side, going forward and back in turn with the stride
		var fwd := -global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := global_transform.basis.x
		right.y = 0.0
		right = right.normalized()
		# A crawl gait, a hand per footfall: each hand is planted on the carpet (it stays put in the world while you
		# move over it), then lifts, reaches forward on an arc and comes down exactly on a footstep (bob = k * PI),
		# the right on one, the left on the next. Where it lands leads you by how far you'll travel while it's
		# down, so it ends its stance about as far behind as it started ahead.
		var dt := get_physics_process_delta_time()
		var floor_at := global_position
		var speed := Vector3(velocity.x, 0.0, velocity.z).length()
		var cycle := TAU / maxf(bob_rate, 0.5)                  # s for both hands (two footfalls)
		var lead := minf(CRAWL_REACH + speed * cycle * (1.0 - CRAWL_SWING_SHARE) * 0.5, CRAWL_LEAD_MAX)
		var hands: Array = []
		for i in 2:                                             # 0 left, 1 right
			var side := 1.0 if i == 1 else -1.0
			var rest := floor_at + fwd * CRAWL_REACH + right * (CRAWL_WIDTH * side)
			var target := floor_at + fwd * lead + right * (CRAWL_WIDTH * side)
			if not _cr_on:
				_cr_plant[i] = rest
				_cr_from[i] = rest
			# the right lands on even footfalls, the left on odd ones
			var ph := fposmod(bob / TAU + CRAWL_SWING_SHARE - (0.0 if i == 1 else 0.5), 1.0)
			var at: Vector3
			if ph < CRAWL_SWING_SHARE:
				if not _cr_swinging[i]:
					_cr_swinging[i] = true
					_cr_from[i] = _cr_plant[i]
				var u := smoothstep(0.0, CRAWL_SWING_SHARE, ph)
				at = (_cr_from[i] as Vector3).lerp(target, u) + Vector3.UP * (CRAWL_LIFT * sin(PI * ph / CRAWL_SWING_SHARE))
				_cr_plant[i] = target
			else:
				_cr_swinging[i] = false
				# stopped (or turned on the spot): a planted hand left far off creeps back under you
				var p: Vector3 = _cr_plant[i]
				var off := p - rest
				if speed < 0.2 or off.length() > CRAWL_REACH * 1.4:
					_cr_plant[i] = p.lerp(rest, minf(1.0, dt * 2.5))
				at = _cr_plant[i]
			hands.append(at)
		_cr_on = true
		torch.set_squeeze(true, hands[1], Vector3.UP, hands[0], Vector3.UP, fwd)
		return
	_cr_on = false
	if tight_k < 0.5 or _sq.is_empty():
		torch.set_squeeze(false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		return
	var xf: Transform3D = Game.level.object_transform(_sq.o)
	var gap: float = _sq.gap
	var along := signf((-global_transform.basis.z).dot(xf.basis.x))
	if along == 0.0:
		along = 1.0
	var half: float = Game.level.CELL * 0.5 - 0.1
	var here: float = (_sq.local as Vector3).x
	# The hands ride along the walls with you, a little ahead (the right a touch further than the left), drifting
	# slowly up and down and fore and aft so they never sit dead still; every so often one comes up off the wall
	# and is put back a bit higher or lower (_sq_raise, timed in _update_squeeze).
	var ly := global_position.y - xf.origin.y + eye - 0.2
	var hands := {}
	for z: float in [-1.0, 1.0]:
		var p0: Vector3 = xf * Vector3(0.0, 0.0, z * gap * 0.5)
		var side := 1 if (p0 - global_position).dot(global_transform.basis.x) > 0.0 else 0
		var ph := _sq_clock * (0.8 if side == 1 else 0.67) + side * 2.1
		var lx := clampf(here + along * (SQ_AHEAD[side] + sin(ph) * SQ_WANDER.x), -half, half)
		var lift := sin(PI * clampf(_sq_raise_t[side] / SQ_RAISE_TIME, 0.0, 1.0)) if _sq_raise_t[side] >= 0.0 else 0.0
		var y := ly + sin(ph * 1.3 + 0.8) * SQ_WANDER.y + _sq_raise_dy[side] + SQ_LIFT_UP * lift
		var n: Vector3 = -xf.basis.z.normalized() * z
		var p: Vector3 = xf * Vector3(lx, y, z * gap * 0.5) + n * (SQ_LIFT_OUT * lift)
		hands[side] = [p, n]
	if not (hands.has(0) and hands.has(1)):
		return
	torch.set_squeeze(true, hands[1][0], hands[1][1], hands[0][0], hands[0][1], xf.basis.x.normalized() * along)

## Walking forward along a wall that ends just ahead: the hand on that side reaches out, takes hold of the
## corner, and the grip draws you round it with a burst of speed. Every corner, with a cooldown.
func _update_corner(dt: float, sprint: bool, crouch: bool) -> void:
	_corner_cd = maxf(0.0, _corner_cd - dt)
	_corner_boost = maxf(0.0, _corner_boost - dt / CORNER_FADE)
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		_corner_on = false
		return
	fwd = fwd.normalized()
	var free := is_on_floor() and not crouch and not dead and peek.side == 0 and not peek.hug
	if _corner_on:
		_corner_t += dt
		var eye_at := global_position + Vector3.UP * eye
		var passed := (corner.point - eye_at).dot(fwd) < 0.15            # the corner is beside you: let go
		if _corner_t >= CORNER_TIME or passed or not free:
			_corner_on = false
		return
	var v := Vector3(velocity.x, 0.0, velocity.z)
	if _corner_cd > 0.0 or sprint or not free or _swinging or v.length() < CORNER_SPEED_MIN or v.normalized().dot(fwd) < 0.8:
		return
	if corner.scan(self, eye, fwd):
		_corner_on = true
		_corner_t = 0.0
		_corner_cd = CORNER_COOLDOWN
		_corner_boost = 1.0
		land_dip = maxf(land_dip, 0.025)       # a little dip as the weight goes onto the hand

## Walking, an edge in reach and you're already heading out round it: the hand takes hold, and the grab
## pulls you round it with a push and a short burst of speed. Once per corner (cooldown).
func _update_swing(dt: float, crouch: bool) -> void:
	_swing_cd = maxf(0.0, _swing_cd - dt)
	_swing_boost = maxf(0.0, _swing_boost - dt / SWING_FADE)
	var v := Vector3(velocity.x, 0.0, velocity.z)
	var ok := peek.leaning and peek.side != 0 and peek.amount > 0.5 and is_on_floor() and not crouch \
		and peek.dist <= 1.15 and v.length() >= SWING_MIN_SPEED and v.dot(peek.out) >= SWING_SIDE_SPEED
	if ok and not _swinging and _swing_cd <= 0.0:
		_swinging = true
		_swing_cd = SWING_COOLDOWN
		_swing_boost = 1.0
		velocity += peek.out * SWING_KICK + v.normalized() * (SWING_KICK * 0.4)
	elif _swinging and (not ok or _swing_cd < SWING_COOLDOWN - 0.5):
		_swinging = false           # the hand keeps hold for half a second, then lets go
