extends "res://scripts/Player/player_state.gd"
## What you see and feel each frame (head and camera, stamina, flashlight, sanity), the scripted door scene,
## and tight spaces: the squeeze gap, crawling, both hands on a slit, corner grab and swing.

func _update_stamina(dt: float, sprint: bool, rush: bool) -> void:
	second_wind_cd = maxf(0.0, second_wind_cd - dt)
	if Game.infinite_stamina:
		exhausted = false
		stamina = 100.0
		rest_timer = 0.0
		return
	if rush:
		exhausted = false
		stamina = maxf(stamina, 60.0)
		rest_timer = 0.6
	elif sprint:
		stamina = maxf(0.0, stamina - dt * 100.0 / (SPRINT_SECONDS * Upgrades.scale("lungs")))
		rest_timer = 0.6
		if stamina <= 0.0:
			if Upgrades.has("second_wind") and second_wind_cd <= 0.0:
				stamina = SECOND_WIND
				second_wind_cd = SECOND_WIND_COOLDOWN
				Game.fx_shock = maxf(Game.fx_shock, 0.35)     # the catch: a small punch-in as the reserve kicks in
			else:
				exhausted = true
	else:
		rest_timer = maxf(0.0, rest_timer - dt)
		if rest_timer == 0.0: stamina = minf(100.0, stamina + STAMINA_REGEN * Upgrades.scale("breath") * dt)
		if exhausted and stamina >= 15.0: exhausted = false

# Head bob + footfalls (web updateHeadBob): a step lands at the bottom of each bob. The bob, the lean
# and the landing dip are scaled by the head-bob setting; the footfalls keep their rhythm regardless.
func _update_head(dt: float, _dir: Vector2, sprint: bool, crouch: bool, moving: bool) -> void:
	var horiz := Vector2(velocity.x, velocity.z).length()
	var walking := moving and horiz > 0.3
	var y := eye
	var walk_goal := 0.0
	if not is_on_floor():
		pass                                  # no bob while airborne
	elif not walking:
		if was_stepping:
			was_stepping = false
			if not step_triggered:
				footsteps.step(false, crouch, 0.5)   # trailing foot comes down softly
				handheld.step(0.5, false)
				land_dip += 0.0015 * head_bob       # and the head settles with it
		handheld.settle()
	else:
		was_stepping = true
		walk_goal = 1.0
		# one step per PI of `bob`: the body is lowest as each foot lands, and rises over the planted leg
		# the cadence follows how fast you are really going (speeding up into a run, an adrenaline burst, a
		# wall in the way): 5.3 at a walk, and the stride lengthens as you go faster, so 8.2 at a full sprint
		var base := SPEED * maxf(Game.speed_mult, 0.01) * (CROUCH_MULT if crouch else 1.0)
		var gait_k := horiz / base
		var before := floori(bob / PI)
		bob_rate = (4.1 if crouch else 5.3) * pow(clampf(gait_k, 0.3, 2.0), 0.78) * lerpf(1.0, 0.6, tight_k) * gait_cam.mult("pace")
		bob += dt * bob_rate
		bob_amp = lerpf(bob_amp, handheld.step_amp, minf(1.0, dt * 8.0))    # no two steps the same height
		if floori(bob / PI) != before:
			footsteps.step(sprint, crouch, 1.0, clampf((gait_k - 1.0) / (SPRINT_MULT - 1.0), 0.0, 1.0))
			handheld.step(0.6 if crouch else 1.0, sprint)
			gait_cam.step()
			# the heel hits the floor: a quick jolt down through the head, springing back up
			land_dip += (0.006 if sprint else 0.003) * gait_cam.mult("height") * head_bob
			if stair_vy < -0.3:
				land_dip += 0.014 * stair_w       # stepping down a flight: each foot drops onto the tread below
		step_triggered = fposmod(bob, PI) < PI * 0.5
	gait_cam.update(dt, cam_variation, walking)
	bob_w = lerpf(bob_w, walk_goal, minf(1.0, dt * (9.0 if walk_goal > 0.0 else 5.0)))
	breath += dt * 1.5
	if is_on_floor():
		y += sin(breath) * 0.012 * head_bob * (1.0 - bob_w)    # standing: slow breathing
	# Walking view, like an inverted pendulum: a sharp low at each footfall and a rounded top, the body
	# swaying over the planted foot (one full side-to-side swing per two steps), a little roll with it and
	# a nod forward as the foot lands.
	var gait := head_bob * bob_w
	var rise := absf(sin(bob))                              # 0 at a footfall, 1 mid-stride
	var vert := 0.06 if sprint else (0.022 if crouch else 0.036)
	var side := sin(bob * 0.5)
	var bob_side := side * (0.04 if sprint else (0.016 if crouch else 0.03)) * gait * gait_cam.mult("side")
	var bob_roll := side * (0.013 if sprint else (0.005 if crouch else 0.008)) * gait * gait_cam.mult("roll")
	# squeezed through a slit: short, slow, heavy steps, the shoulders working side to side more than the head lifts
	vert *= lerpf(1.0, 0.45, tight_k) * lerpf(1.0, 0.7, crawl_k)
	bob_side *= lerpf(1.0, 2.2, tight_k) * lerpf(1.0, 1.6, crawl_k)       # crawling the body rocks over each hand in turn
	bob_roll *= lerpf(1.0, 2.6, tight_k) * lerpf(1.0, 1.8, crawl_k)
	var bob_nod := (rise - 0.5) * (0.016 if sprint else (0.005 if crouch else 0.008)) * gait * gait_cam.mult("nod")
	# the head also rocks forward a touch as each foot lands, and back as it rises: the way a body moves
	var bob_fwd := (0.5 - rise) * 0.004 * gait * gait_cam.mult("nod")
	y += (rise - 0.64) * vert * bob_amp * gait * gait_cam.mult("height")
	# Stairs: the flight's walking surface is a smooth slope, but legs take it a tread at a time. Climbing,
	# the head goes up early in each stride as the leg pushes onto the next step, then levels; going down
	# it hangs, then drops as the foot lands. Nothing at a footfall itself, so it joins the bob seamlessly.
	var dy := global_position.y - stair_prev_y
	stair_prev_y = global_position.y
	# (the slope contact can drop out for a tick as the floor snap re-seats you; that must not switch the effect
	# off and on again, or the head judders)
	if walking and is_on_floor() and _on_stair_flight(): stair_hold = 0.15
	else: stair_hold = maxf(0.0, stair_hold - dt)
	var on_flight := walking and stair_hold > 0.0
	if absf(dy) < 0.5:                                      # not a teleport or the floor swap on a far landing
		stair_vy = lerpf(stair_vy, dy / maxf(dt, 0.0001) if on_flight else 0.0, minf(1.0, dt * 4.0))
	stair_w = lerpf(stair_w, 1.0 if on_flight else 0.0, minf(1.0, dt * 4.0))
	if stair_w > 0.001:
		var stair_p := fposmod(bob, PI) / PI                # 0 at a footfall .. 1 at the next
		var stair_h := minf(absf(stair_vy) * PI / maxf(bob_rate, 0.1), 0.2)    # height won per step
		var stair_lift := (1.0 - pow(1.0 - stair_p, 2.5)) - stair_p if stair_vy > 0.0 else stair_p - pow(stair_p, 2.5)
		y += stair_lift * stair_h * stair_w * head_bob * 0.8
		if stair_vy > 0.0:
			bob_nod -= stair_lift * stair_h * stair_w * head_bob * 0.2    # leaning into the climb as you push up
	# The slope is smooth but treads are not: the view holds at the tread you are on and the next one pulls it up
	# (or down) in a quick eased step as the foot crosses the nosing, so a flight reads as steps, not a ramp.
	var snap_goal := 0.0
	if on_flight and stair_tread > 0.05 and absf(dy) < 0.5:
		var v := (global_position.y - stair_tread_base) / stair_tread
		snap_goal = (roundf(v) - v) * stair_tread * 0.9
	stair_snap = lerpf(stair_snap, snap_goal, minf(1.0, dt * (16.0 if on_flight else 8.0)))
	y += stair_snap * head_bob
	step_ease *= exp(-dt * 14.0)
	y += step_ease
	land_dip *= exp(-dt * 9.0)
	# the floor shaking under something heavy: a short low rumble, not a wobble. Squared so light steps
	# barely register and the close ones hit; scaled by the head-bob setting like the rest of the motion.
	quake_amt *= exp(-dt * 5.5)
	quake_t += dt
	var qk := quake_amt * quake_amt * head_bob
	var qx := (sin(quake_t * 31.0) + 0.6 * sin(quake_t * 53.0 + 1.7)) * 0.625
	var qy := (sin(quake_t * 37.0 + 0.4) + 0.6 * sin(quake_t * 61.0 + 2.9)) * 0.625
	cam.position = Vector3(qx * 0.025 * qk + bob_side, y- land_dip * head_bob + qy * 0.035 * qk, bob_fwd)
	# strafe / turn roll, speed and jump pitch, the landing nod, idle sway, trauma shake (camera_feel.gd)
	camera_feel.update(dt, velocity, global_transform.basis, is_on_floor(), moving, SPEED,
			turn_accum / maxf(dt, 0.0001), pitch_accum / maxf(dt, 0.0001))
	turn_accum = 0.0
	pitch_accum = 0.0
	# the camcorder in your hands: it shakes more out of breath or with your heart pounding
	var shake := 1.0 + adrenaline * 1.5 + (1.0 if exhausted else 0.0)
	var motion := (1.8 if sprint else (0.6 if crouch else 1.0)) if walking else 0.0
	# held out at your eye the camcorder never quite stills: the shake is there standing, and the longer the
	# lens the more of it you see. Crouched you brace it against your knee.
	var steady := 0.55 if crouch else 1.0
	motion = maxf(motion, 0.55 * lens_up * steady)
	shake += lens_up * (lens_zoom - 1.0) * 0.15
	handheld.update(dt, motion, shake, cam_shake)
	if torch != null:
		torch.sway_amount = maxf(head_bob, cam_shake)    # the hands trail the view unless both are off
	_update_door_camera(dt)
	cam.position += handheld.offset
	cam.position += global_transform.basis.inverse() * peek.shift + Vector3(0.0, -PEEK_DIP * peek.amount, -PEEK_FWD * peek.amount)
	# the squeeze gap's way in / out (_update_squeeze): shoulder turn, duck, pop free
	var sq_hb := maxf(head_bob, 0.3)
	cam.position += Vector3(0.0, _sq_cam[3], _sq_cam[4]) * sq_hb
	cam.position += _door_cam_pos
	cam.rotation.y = handheld.yaw - peek.side * PEEK_YAW * peek.amount + _sq_side * _sq_cam[0] * sq_hb + _door_cam_rot.y \
			+ camera_feel.yaw * head_bob
	# the rush of air in a long fall shakes the view, more the faster you go
	var buffet := fall_fx * fall_fx * head_bob
	cam.position += Vector3(sin(quake_t * 23.0) + 0.5 * sin(quake_t * 41.0 + 1.3), sin(quake_t * 29.0 + 0.7), 0.0) * 0.012 * buffet
	cam.rotation.z = camera_feel.roll * head_bob + qy * 0.01 * qk + handheld.roll + bob_roll \
			- peek.side * PEEK_ROLL * peek.amount * lerpf(0.5, 1.0, head_bob) \
			+ (sin(quake_t * 17.0) + 0.6 * sin(quake_t * 31.0 + 2.1)) * FALL_BUFFET * buffet \
			+ _sq_side * _sq_cam[1] * sq_hb \
			+ _door_cam_rot.z
	# pitch: all of it added on top of the mouse pitch as an offset (previous offset removed first) so aiming
	# and other readers stay intact
	var pitch_total: float = camera_feel.pitch * head_bob + qx * 0.006 * qk + handheld.pitch + bob_nod + float(_sq_cam[2]) * sq_hb + _door_cam_rot.x
	cam.rotation.x = clampf(cam.rotation.x - pitch_applied + pitch_total, -LOOK_DOWN_MAX - 0.05, LOOK_UP_MAX)
	pitch_applied = pitch_total
	# FOV: the base, +2.5 sprinting, +2 in the air (web updateFov), wider on adrenaline
	var fov_target: float = (2.5 if sprint else 0.0) + (2.0 if not is_on_floor() else 0.0) + float(_sq_cam[5])
	fov_kick += (fov_target - fov_kick) * minf(1.0, 9.0 * dt)
	# (Render.fov_boost: the bodycam's fisheye magnifies the middle of the picture; the render widens to give it back)
	fov_flat = base_fov + Render.fov_boost + fov_kick + ADR_FOV * adrenaline + FALL_FOV * fall_fx * fall_fx
	cam.fov = _zoomed_fov(fov_flat)

## The field of view through the camcorder's lens: `flat` narrowed by the magnification (a true zoom, so the
## picture is the middle of the wide one scaled up, not a bend of it)
func _zoomed_fov(flat: float) -> float:
	if lens_zoom <= 1.001:
		return flat
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(flat) * 0.5) / lens_zoom))

## Walking up or down a stairwell flight (its sloped solid underfoot, props/stairs.gd tags it), not a landing
func _on_stair_flight() -> bool:
	if get_floor_normal().y > 0.97:
		return false
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		if c.get_normal().y > 0.5:
			var sh = c.get_collider_shape()
			if sh is Node and sh.has_meta("surface"):
				stair_tread = float(sh.get_meta("tread", 0.0))
				stair_tread_base = float(sh.get_meta("tread_base", 0.0)) + (sh as Node3D).global_position.y   # (world height)
				return true
	return false

## How lit the spot you stand on is: the level's tubes in the backrooms, the sky (day / night cycle) outdoors,
## and daylight everywhere in a level with the day look
func ambient_light() -> float:
	if Game.outdoors:
		return Game.day_light
	if level == null: return 1.0
	return level.tube_light_at(global_position)

## Crouched, crawling or squeezed through a slit: no room to hold the torch up, the head lamp is on instead
func _tight_spot() -> bool:
	return is_crouching or crawl_k > 0.5 or tight_k > 0.4

func _update_head_lamp(dt: float) -> void:
	if head_lamp == null:
		return
	var goal := 1.0 if _tight_spot() and not dead else 0.0
	_head_k = move_toward(_head_k, goal, dt * (4.0 if goal > _head_k else 2.5))
	head_lamp.light_energy = HEAD_LAMP_ENERGY * _head_k
	head_lamp.visible = _head_k > 0.01

# ---- per-frame flashlight: battery drain, low-battery dimming/flicker, aim with slight lag ----
func _update_flashlight(dt: float) -> void:
	# both hands on a wall, or crouched / crawling / squeezed through a slit: the torch is put away, so the beam
	# fades out (and the battery rests); in a tight spot the head lamp takes over
	var hugging: bool = torch != null and torch.hugging()
	var beam_goal := 0.0 if hugging or _tight_spot() else 1.0
	_update_head_lamp(dt)
	_hug_dim = move_toward(_hug_dim, beam_goal, dt * (8.0 if beam_goal < _hug_dim else 5.0))
	if flash_on and not swap_dark and _hug_dim > 0.5:
		if Game.infinite_battery:
			battery = 100.0
		else:
			battery = maxf(0.0, battery - BATTERY_DRAIN * Upgrades.scale("filament") * (0.25 if grid_down else 1.0) * dt)
		if battery <= 0.0:
			flash_on = false
			battery_died.emit()
	var k := 1.0
	if battery < BATTERY_LOW:
		var ratio := maxf(0.12, battery / BATTERY_LOW)
		k *= 0.35 + 0.65 * ratio
		if randf() < (0.32 if battery < BATTERY_CRIT else 0.10):
			k *= 0.05 + randf() * 0.45
			if torch: torch.smack()
	k *= _contact_flicker(dt)
	# Dark adaptation: in deep darkness your pupils open up and the beam reads brighter and crisper
	var lvl := ambient_light()
	var dark_boost := lerpf(1.35, 1.0, clampf(lvl, 0.0, 1.0))
	k *= _hug_dim
	var lit := flash_on and not dead and not swap_dark and _hug_dim > 0.01
	flash.light_energy = FLASH_ENERGY_HOTSPOT * k * dark_boost if lit else 0.0
	flash.visible = lit
	if flash_spill:
		flash_spill.light_energy = FLASH_ENERGY_SPILL * k * dark_boost if lit else 0.0
		flash_spill.visible = lit
	_update_flashlight_aim(dt)

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

# ---------------------------------------------------------------- door interaction: the scripted scene
## [E] on a door plays a short scene with the player's body, eyes and left hand (the torch stays in the
## right). Opening, from shut: step up to it, eyes down to the knob, reach and turn it; the latch gives and
## the leaf falls ajar and you look through the gap, then the push, and you follow it through the doorway.
## Shutting: turn to it, take the knob, pull it to you (backing off if it comes your way) until it knocks shut.
## The left hand does it (wall_hand.gd DOOR): it reaches up on a curve, the fingers open, and closes on the handle
## (a squeeze past, then easing); it twists the knob / presses the lever down, and holds it so while the latch
## gives. Then, by the way picked (DS_WAYS): it lets go and goes to the flat of the leaf and pushes it wide, or
## keeps hold and pushes the handle. Either way the hand goes with the leaf as far as the arm reaches, then lets
## go of it (the palm pushing off) and drops away, the leaf swinging on. A glass door's bar, or a door already
## ajar, is just pushed.
## The scene tells the door when the knob turns (turn_knob: the open sound starts) and when the pull starts
## (pull); door.gd times the leaf and the sounds from there. Mouse look and walking come back at the end.
const DS_STAND := 0.7                   # m out from the door, square to the middle of it: where you open it
const DS_THROUGH := 1.4                 # m past it on the far side: where the walk through ends
const DS_STEP := 1.5                    # m/s stepping up to it
const DS_WALK := 1.05                   # m/s through: slow, careful
const DS_TURN := 1.6                    # rad/s the most the body turns
const DS_LOOK_GLIDE := 4.0              # 1/s: how quickly the eyes move on to the next thing looked at
const DS_PULL_AT := 0.4                 # m: shutting, you keep this far from the knob (the hand on it)
const DS_PULL_REACH := 0.55             # m: further than this from the knob, you step to it
const DS_STAND_HANDLE := 0.55           # m out from the door you stand to open it (you lean in to the handle from there)
const DS_FOLLOW := 0.16                 # m you step in after the door as the latch gives and you push
const DS_LEAN := Vector3(-0.03, -0.14, -0.19)   # m, camera space: reaching for the handle you lean in from the hips
const DS_ASIDE := 0.14                  # m the handle is to your left of your middle (the left hand takes it)
# the ways a door gets opened from shut, one picked each time by its odds:
#   pace   the swing takes this many times its usual time (door.gd pace)
#   ajar   s the leaf hangs ajar before the push: the hand going from the handle to the leaf, a look through the gap
#   palm   the hand goes to the flat of the leaf to push (else it pushes on the handle it holds)
#   push   how hard: the weight going in behind the hand, the head with it
#   look   how long and how far the head goes in to look through the gap
#   turn   s the turn of the handle takes
const DS_WAYS := [
	{"name": "palm", "odds": 3, "pace": 1.0, "ajar": 0.12, "palm": true, "push": 1.0, "look": 1.0, "turn": 0.14},
	{"name": "handle", "odds": 3, "pace": 0.9, "ajar": 0.0, "palm": false, "push": 0.8, "look": 0.7, "turn": 0.12},
	{"name": "careful", "odds": 1, "pace": 1.15, "ajar": 0.35, "palm": true, "push": 0.45, "look": 1.4, "turn": 0.22},
	{"name": "shove", "odds": 1, "pace": 0.8, "ajar": 0.15, "palm": true, "push": 1.7, "look": 0.4, "turn": 0.1},
]

func trigger_door_camera_animation(door: Node3D, opening: bool, swing_dir: float) -> void:
	_door_anim_active = true
	_ds = door
	_ds_t = 0.0
	_ds_open = opening
	_ds_swing = swing_dir
	_ds_pushed = false
	_ds_side = door.side_of(global_position) if door.has_method("side_of") else 1.0
	if not opening and door.has_method("face_normal"):
		# shutting, the knob on the face that looks your way (the leaf may be swung either side of you)
		_ds_side = 1.0 if door.face_normal(1.0).dot(global_position - door.knob_at(1.0)) > 0.0 else -1.0
	_ds_k = -1.0
	_ds_look_ok = false
	var knob: Vector3 = door.knob_at(_ds_side) if door.has_method("knob_at") else door.global_position
	_ds_kside = 1.0 if (cam.global_transform.basis.inverse() * (knob - cam.global_position)).x >= 0.0 else -1.0
	# how it's opened this time
	var odds := 0
	for w in DS_WAYS:
		odds += int(w.odds)
	var roll := randi() % odds
	for w in DS_WAYS:
		roll -= int(w.odds)
		if roll < 0:
			_ds_way = w
			break
	var kind: String = door.handle_kind() if door.has_method("handle_kind") else "knob"
	_ds_grip = {"knob": WallHand.Grip.KNOB, "lever": WallHand.Grip.LEVER, "bar": WallHand.Grip.BAR}.get(kind, WallHand.Grip.KNOB)
	_ds_latched = door.latched() if door.has_method("latched") else true
	if "pace" in door:
		door.pace = float(_ds_way.pace) if opening else 1.0
		door.ajar = float(_ds_way.ajar) if opening and _ds_latched else 0.0
	# where you stand to open it: before the handle, a little to its right so the left hand takes it
	# (door-local: facing the door from side s, your left is +s along z)
	var g: Vector3 = door.grip_at(_ds_side) if door.has_method("grip_at") else knob
	_ds_z = door.to_local(g).z - _ds_side * DS_ASIDE
	peek.reset()
	_corner_on = false
	_swinging = false

func _end_door_scene() -> void:
	if _ds_ghost != null and is_instance_valid(_ds_ghost):
		remove_collision_exception_with(_ds_ghost)
	_ds_ghost = null
	if _ds != null and is_instance_valid(_ds) and "scene_body" in _ds:
		_ds.scene_body = null
	_door_anim_active = false
	_ds = null
	if torch != null:
		torch.set_grab(false, -1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		torch.set_door(false)

## One tick of the scene: where the body goes, where the eyes go, whether the hand is on the door, and the
## head's own motion on top (_door_cam_pos / _door_cam_rot, camera space). Stands in for the walking update.
func _door_scene(dt: float) -> void:
	var d = _ds                        # (untyped: the door script's own members)
	if d == null or not is_instance_valid(d) or not d.has_method("knob_at"):
		_end_door_scene()
		return
	_ds_t += dt
	var t := _ds_t
	var s := _ds_side
	var knob: Vector3 = d.knob_at(s)
	var goal := global_position
	var spd := DS_STEP
	var look := knob
	var look_rate := 5.0
	var hand := false
	var palm := 0.0                   # the hand: 0 on the handle .. 1 flat on the leaf
	var turn := 0.0                   # the handle turned
	var press := 0.0                  # leaning into the push
	var way := _ds_way
	var walk_through := false
	var walk := Vector3.ZERO
	var pos := Vector3.ZERO
	var rot := Vector3.ZERO           # pitch, yaw, roll
	var ks := _ds_kside
	var done := false
	var k := _ds_k if _ds_k >= 0.0 else 1e6      # (not yet: every later beat stays in the future)
	if _ds_open:
		var lp: Vector3 = d.to_local(global_position)
		# step up before the handle, a little to its right; after the push, straight through along its middle line
		goal = d.to_global(Vector3(s * DS_STAND_HANDLE, 0.0, _ds_z))
		spd = DS_STEP
		# there and the hand closed on it: turn it (the open sound starts; the latch gives LATCH_AFTER into it)
		var there := Vector2(goal.x - global_position.x, goal.z - global_position.z).length() < 0.12
		if _ds_k < 0.0 and ((t > 0.35 and there and (torch == null or torch.door_ready())) or t > 1.5):
			_ds_k = t
			k = t
			d.turn_knob()
		var r: float = k + float(d.LATCH_AFTER)       # the latch gives, the leaf falls ajar
		var p: float = k + float(d.push_after())      # the push
		# as it gives, a short step in after it (the hand stays with the leaf, the weight goes in behind it)
		goal = d.to_global(Vector3(s * (DS_STAND_HANDLE - DS_FOLLOW * smoothstep(r - 0.05, p + 0.2, t)), 0.0, _ds_z))
		var pushed_only: bool = _ds_grip == WallHand.Grip.BAR or not _ds_latched
		# the hand: up to the handle, turned and held while the latch gives; then to the leaf, or kept on the handle
		hand = t > 0.2 and t < p + 1.4
		if not pushed_only:
			var tt: float = float(way.turn)
			turn = smoothstep(k - 0.02, k + tt, t) * (1.0 - smoothstep(r + 0.08, r + 0.08 + tt * 1.5, t))
		if pushed_only or (bool(way.palm) and t > r + 0.04):
			palm = 1.0
		press = float(way.push) * smoothstep(p - 0.12, p + 0.04, t) * (1.0 - smoothstep(p + 0.2, p + 0.65, t))
		if t > r - 0.05 and t < r + 0.1:              # the latch going: a nudge on the handle that cracks it open
			press = maxf(press, 0.5 * sin(PI * (t - r + 0.05) / 0.15))
		if t > p + 0.15 + 0.1 * float(way.look):
			walk_through = true
			var along: Vector3 = d.global_basis.x.normalized() * -s
			var across: Vector3 = d.global_basis.z.normalized()
			walk = along * DS_WALK + across * clampf(-lp.z * 4.0, -0.5, 0.5)
			if _ds_ghost == null and d.get("leaf_body") != null:
				_ds_ghost = d.leaf_body
				add_collision_exception_with(_ds_ghost)
		# a glance down to the knob (not a stare), then through the gap, then the room ahead
		if t < r:
			# the knob in the lower third of the view, the door above it (looking straight down at a knob from
			# close up the door's edges splay and the view fills with wood)
			look = knob.lerp(d.to_global(Vector3(s * 0.2, 1.3, 0.15)), 0.45)
			look_rate = 4.0
		elif t < p + 0.25 * float(way.look):
			look = d.to_global(Vector3(-s * 2.5, 1.55, 0.45))
			look_rate = 3.0
		else:
			look = d.to_global(Vector3(-s * 5.0, 1.6, 0.0))
			look_rate = 2.5
		# reaching for the knob: a small dip; turning it (the rattle, the sound's first 0.15 s): a twitch of the head
		# leaning in to the handle from the hips while the hand's on it, eased in and out (no roll: it read as the
		# floor tipping)
		var wr := smoothstep(0.1, 0.65, t) * (1.0 - smoothstep(p + 0.1, p + 0.7, t))
		pos += DS_LEAN * wr
		var wk := smoothstep(k, k + 0.06, t) * (1.0 - smoothstep(k + 0.1, k + 0.2, t))
		rot.z += ks * 0.012 * wk
		# the look through the gap: the head goes a little in toward it (a careful one further, and stays)
		var lk: float = float(way.look)
		var wp := smoothstep(r, r + 0.2 * lk, t) * (1.0 - smoothstep(p + 0.05, p + 0.35, t))
		pos += Vector3(ks * 0.03, -0.01, -0.05) * wp * minf(lk, 1.3)
		rot.z += -ks * 0.02 * wp * minf(lk, 1.3)
		# the push: weight forward behind the hand (a shove throws the shoulder in, the head turning with it)
		var pw: float = float(way.push)
		var wu := smoothstep(p - 0.08, p + 0.12 + 0.1 / pw, t) * (1.0 - smoothstep(p + 0.4, p + 0.9, t))
		pos += Vector3(0.006 * pw, -0.01 * pw, -0.035 * pw) * wu
		rot.y += -0.012 * pw * wu
		rot.z += 0.01 * (pw - 1.0) * wu
		if t >= p and not _ds_pushed:
			_ds_pushed = true
			if torch != null: torch.nudge_door(true, _ds_swing)
		done = s * lp.x < -DS_THROUGH or t > p + 4.0
	else:
		var flat := Vector3(global_position.x - knob.x, 0.0, global_position.z - knob.z)
		# the leaf swung away from you: you go in by it, and it follows you out as you pull (it passes you)
		if _ds_ghost == null and d.get("leaf_body") != null:
			_ds_ghost = d.leaf_body
			add_collision_exception_with(_ds_ghost)
		# which side of the doorway you're on, and whether the handle is on it too (the leaf swung your way, or
		# barely open) or round the far side (it swung away from you through the doorway)
		var pl: Vector3 = d.to_local(global_position)
		var mine: float = signf(pl.x) if absf(pl.x) > 0.05 else s
		var near_side: bool = (d.to_local(knob) as Vector3).x * mine > -0.05
		if near_side:
			# keep at arm's length from the knob: step to it if it's far, back off as it comes to you
			if flat.length() > DS_PULL_REACH or t > k:
				goal = Vector3(knob.x, global_position.y, knob.z) + flat.normalized() * DS_PULL_AT
		else:
			# you don't go after it: a step up to the doorway on your side and it's swung to from there
			goal = d.to_global(Vector3(mine * 0.6, pl.y, clampf(pl.z, -0.3, 0.3)))
		var in_reach: bool = near_side and flat.length() <= DS_PULL_REACH + 0.05
		# the hand on it (or nothing to reach): pull (the door times its knock into the frame to the close sound)
		if _ds_k < 0.0 and t > 0.3 and ((in_reach and (torch == null or torch.door_ready())) or not near_side or t > 1.3):
			_ds_k = t
			k = t
			d.pull()
		var shut: float = k + float(d.CLOSE_TIME)    # it meets the frame
		if t > shut - 0.1:
			# shut (or nearly): a step back off it, clear of the leaf before it's solid to you again
			goal = d.to_global(Vector3(mine * maxf(absf(pl.x), 0.55), pl.y, pl.z))
		look = knob if t < k + 0.3 else d.to_global(Vector3(s * 0.2, 1.4, 0.0))
		look_rate = 4.0 if t < k + 0.3 else 2.0
		hand = near_side and t > 0.15 and t < shut           # (round the far side it's out of reach: no hand in the air)
		press = -0.6 * smoothstep(k - 0.05, k + 0.2, t)             # pulling: the hand comes back with it
		var wr := smoothstep(0.1, 0.35, t) * (1.0 - smoothstep(k, k + 0.3, t))
		pos += Vector3(-0.015, -0.06, -0.05) * wr      # bending to the handle
		rot.z += -ks * 0.02 * wr
		# the pull: weight back, head up a touch
		var wl := smoothstep(k - 0.05, k + 0.25, t) * (1.0 - smoothstep(shut - 0.1, shut + 0.3, t))
		pos += Vector3(0.0, 0.0, 0.04) * wl
		rot += Vector3(0.02, -ks * 0.025, -ks * 0.02) * wl
		# the knock: a small flinch of the head as it shuts
		var wh := smoothstep(shut, shut + 0.04, t) * (1.0 - smoothstep(shut + 0.06, shut + 0.25, t))
		pos += Vector3(0.0, 0.0, 0.012) * wh
		rot.x += 0.01 * wh
		done = (t > shut + 0.35 and not d.blocked and absf((d.to_local(global_position) as Vector3).x) > 0.45) or t > 6.0
	# the body: walk to the goal
	var to := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	var wish := to.normalized() * minf(spd, to.length() * 3.5) if to.length() > 0.02 else Vector3.ZERO
	if walk_through:
		wish = walk
	velocity.x = move_toward(velocity.x, wish.x, ACCEL_GROUND * SPEED * dt)
	velocity.z = move_toward(velocity.z, wish.z, ACCEL_GROUND * SPEED * dt)
	if not is_on_floor():
		velocity.y = maxf(velocity.y - GRAVITY * dt, -fall_speed_max)
	move_and_slide()
	# the eyes: the point looked at glides from one beat's to the next (switching straight to a new one, the head
	# whipped round), the body turns to it, the head pitches to it
	if not _ds_look_ok:
		_ds_look = cam.global_position - cam.global_basis.z * 2.0
		_ds_look_ok = true
	_ds_look = _ds_look.lerp(look, 1.0 - exp(-dt * DS_LOOK_GLIDE))
	look = _ds_look
	var to_look := look - cam.global_position
	var yaw_goal := atan2(-to_look.x, -to_look.z)
	var yaw_step := clampf(wrapf(yaw_goal - rotation.y, -PI, PI) * (1.0 - exp(-dt * look_rate)), -DS_TURN * dt, DS_TURN * dt)
	rotate_y(yaw_step)
	var pitch_goal := clampf(atan2(to_look.y, Vector2(to_look.x, to_look.z).length()), -1.1, 0.6)
	var base := cam.rotation.x - pitch_applied
	cam.rotation.x += (pitch_goal - base) * (1.0 - exp(-dt * look_rate))
	_door_cam_pos = pos
	_door_cam_rot = rot
	# the rest of the body as walking would have it
	var moving := wish.length() > 0.25
	is_moving = moving
	is_sprinting = false
	is_crouching = false
	eye = lerpf(eye, STAND_H, minf(1.0, dt * 10.0))
	(shape.shape as CapsuleShape3D).height = eye + 0.1
	shape.position.y = (eye + 0.1) / 2.0
	_update_stamina(dt, false, false)
	peek.update(dt, self, eye, false)
	if torch:
		torch.set_hug(false, Vector3.ZERO, Vector3.ZERO, false)
		torch.set_squeeze(false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		torch.set_grab(false, -1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		# the leaf's own face and latch way for the handle and the push (the hand goes round with it as it swings)
		var leaf_n: Vector3 = d.face_normal(s)
		var leaf_l: Vector3 = d.latch_dir()
		torch.set_door(hand, d.grip_at(s), d.face_at(s, 1.2, 0.2), leaf_n, leaf_l, _ds_grip, palm, turn, press)
		torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, false)
		torch.update(dt, flash_on and not dead, false, moving, bob)
	if shadow_body:
		shadow_body.update(moving, false, false, dead, Vector2(velocity.x, velocity.z).length())
	_update_flashlight(dt)
	_update_sanity(dt)
	_update_head(dt, Vector2(0.0, -1.0) if moving else Vector2.ZERO, false, false, moving)
	if done:
		_end_door_scene()

## Outside the scene the head's door motion eases back out
func _update_door_camera(dt: float) -> void:
	if _door_anim_active:
		return
	_door_cam_pos = _door_cam_pos.lerp(Vector3.ZERO, minf(1.0, dt * 8.0))
	_door_cam_rot = _door_cam_rot.lerp(Vector3.ZERO, minf(1.0, dt * 8.0))

func _near_door() -> bool:
	if focused_door != null:
		return true
	var cp := global_position
	_refresh_door_cache()
	for d in _cached_door_nodes:
		if is_instance_valid(d) and d is Node3D:
			var d_pos: Vector3 = (d as Node3D).global_position
			var dist := Vector2(cp.x - d_pos.x, cp.z - d_pos.z).length()
			if dist < 3.2 and absf(cp.y - d_pos.y) < 2.5:
				return true
	return false

var _cached_doors: Array = []         # "doors" + "interactables": _find_interactable_door
var _cached_door_nodes: Array = []    # "doors" only: _near_door
var _door_cache_t := 0.0

## One group scan a second, shared by both door queries. An empty list re-scans every call (a level
## that is still loading), as the uncached lookup did.
func _refresh_door_cache() -> void:
	var now := Time.get_ticks_msec() * 0.001
	if now - _door_cache_t > 1.0 or _cached_door_nodes.is_empty() or _cached_doors.is_empty():
		_door_cache_t = now
		_cached_door_nodes = get_tree().get_nodes_in_group("doors")
		_cached_doors = _cached_door_nodes + get_tree().get_nodes_in_group("interactables")

func _find_interactable_door() -> Node:
	if dead or frozen or Game.draw_mode or Game.noclip:
		return null
	var cam_pos := cam.global_position
	var cam_fwd := -cam.global_transform.basis.z
	
	# 1. Direct raycast through reticle
	var space := get_world_3d().direct_space_state
	if space != null:
		var ray_end := cam_pos + cam_fwd * 2.8
		var query := PhysicsRayQueryParameters3D.create(cam_pos, ray_end, 1 | 2)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var collider: Object = hit.collider
			var d := _get_door_from_node(collider)
			if d != null and d.has_method("can_interact") and d.can_interact(cam_pos):
				return d
				
	# 2. View-cone / proximity query for nearby doors within reach (handles open doorways and side angles)
	_refresh_door_cache()

	var best_door: Node = null
	var best_dot := 0.62
	for n in _cached_doors:
		if not is_instance_valid(n): continue
		var dpos: Vector3 = (n as Node3D).global_position
		if cam_pos.distance_squared_to(dpos) > 16.0: continue
		if n.has_method("can_interact") and n.can_interact(cam_pos):
			var target_pos: Vector3 = n.get_handle_global_pos() if n.has_method("get_handle_global_pos") else dpos
			var to_door := (target_pos - cam_pos).normalized()
			var dot := cam_fwd.dot(to_door)
			var dist := cam_pos.distance_to(target_pos)
			if dist < 2.6 and dot > best_dot:
				best_dot = dot
				best_door = n
	return best_door

func _get_door_from_node(node: Object) -> Node:
	if node == null:
		return null
	if node.has_method("interact"):
		return node as Node
	if node.has_meta("door"):
		return node.get_meta("door") as Node
	if node is Node:
		var p := (node as Node).get_parent()
		if p != null:
			if p.has_method("interact"): return p
			if p.has_meta("door"): return p.get_meta("door") as Node
			var pp := p.get_parent()
			if pp != null:
				if pp.has_method("interact"): return pp
				if pp.has_meta("door"): return pp.get_meta("door") as Node
	return null

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

## Immediate partial alignment during rapid mouse motion to prevent TAA flashlight ghosting
func _sync_flashlight_aim(factor: float) -> void:
	if not is_instance_valid(flash) or not flash.visible:
		return
	var lens := cam.global_position
	if torch != null and torch.visible:
		lens = torch.lens()
	var where := _lens_clear_of_walls(cam.global_position, lens)
	beam_pos = beam_pos.lerp(where, factor)
	flash.global_position = beam_pos
	var fwd := -cam.global_transform.basis.z * 16.0
	var tilt := 0.0 if (Game.hide_hud or Game.hide_hands) else beam_tilt
	var want := beam_pos + fwd.rotated(cam.global_transform.basis.x, -tilt)
	flash_target = flash_target.lerp(want, factor)
	if flash_target.distance_to(beam_pos) > 0.01:
		flash.look_at(flash_target, Vector3.UP)

## Dynamic velocity rejection tuning for flashlight beam:
## Dynamically scales tracking rate with angular look delta. When turning rapidly, tracking ramps up
## to 85.0/s to eliminate the multi-frame lag that creates temporal ghost trails, while easing down
## to smooth organic 24.0/s during subtle breathing movement.
func _update_flashlight_aim(dt: float) -> void:
	if not is_instance_valid(flash) or not flash.visible:
		return
	var dip_target := 0.0
	if torch != null and not (Game.hide_hud or Game.hide_hands):
		dip_target = torch.lower * 0.28 + (1.0 - torch.raise) * 0.5
	var tilt_target := 0.0 if (Game.hide_hud or Game.hide_hands) else clampf(dip_target, 0.0, BEAM_TILT_MAX)
	beam_tilt = lerpf(beam_tilt, tilt_target, minf(1.0, 8.0 * dt))
	var lens := cam.global_position
	if torch != null and torch.visible:
		lens = torch.lens()
	var where := _lens_clear_of_walls(cam.global_position, lens)
	var pos_rate := lerpf(30.0, 95.0, clampf(beam_pos.distance_to(where) * 4.0, 0.0, 1.0))
	beam_pos = where if beam_pos.distance_to(where) > 2.0 else beam_pos.lerp(where, minf(1.0, pos_rate * dt))
	flash.global_position = beam_pos
	var fwd := -cam.global_transform.basis.z * 16.0
	var current_tilt := 0.0 if (Game.hide_hud or Game.hide_hands) else beam_tilt
	var want := beam_pos + fwd.rotated(cam.global_transform.basis.x, -current_tilt)
	var look_delta := (want - flash_target).length()
	var track_rate := lerpf(24.0, 85.0, clampf(look_delta * 3.0, 0.0, 1.0))
	flash_target = flash_target.lerp(want, minf(1.0, track_rate * dt))
	if flash_target.distance_to(beam_pos) > 0.01:
		flash.look_at(flash_target, Vector3.UP)

# The lens hangs ~0.4 m in front of your eye, so pressed up against a wall it sits inside the geometry
# and the beam vanishes with it. Only level walls count: a creature passing between your eye and the
# torch must not move your light.
func _lens_clear_of_walls(from: Vector3, lens: Vector3) -> Vector3:
	if from.distance_to(lens) < 0.01:
		return lens
	var space := get_world_3d().direct_space_state
	if space == null:
		return lens
	var q := PhysicsRayQueryParameters3D.create(from, lens)
	q.exclude = [get_rid()]
	for i in 3:
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return lens
		if hit.collider is StaticBody3D:
			return from
		q.exclude.append(hit.rid)                       # a body in the way is not a wall: look past it
	return lens

# Loose contact: long steady stretches, then a burst of dropouts
func _contact_flicker(dt: float) -> float:
	var fl := flash_flicker
	fl.timer -= dt
	if fl.timer > 0.0: return 1.0
	if not fl.active:
		fl.active = true
		fl.step = 0.0
		if torch: torch.smack()                         # a loose contact: knock it
	fl.step -= dt
	if fl.step <= 0.0:
		fl.step = 0.03 + randf() * 0.05
		var cut := randf() < 0.4
		fl.value = 0.03 if cut else 0.2 + randf() * 0.8
		var forced := flicker_left > 0.0
		if forced: flicker_left -= fl.step
		if (forced and flicker_left <= 0.0) or (not forced and randf() < 0.08):
			flicker_left = 0.0
			fl.active = false
			fl.value = 1.0
			fl.timer = 9.0 + randf() * 18.0
	return fl.value

# ---- sanity: darkness drains it, safe light restores it (web SANITY values) ----
# Light is what keeps you sane. Ambient light (the tubes) restores it as before. The torch is a light
# of your own: with it on you never lose sanity to the dark, and it slowly restores it. With NO light at
# all (dark area, torch off or dead) sanity drains, and the longer you stay in it the faster it goes.
func _update_sanity(dt: float) -> void:
	if Game.infinite_sanity:
		sanity = 100.0
		sanity_lock = 100.0
		insanity = 0.0
		dark_time = 0.0
		_update_mind(dt)
		return
	var ambient := ambient_light()
	var torch_lit := (flash_on and battery > 0.0 and not swap_dark) or _head_k > 0.5
	light_level = lerpf(light_level, ambient, minf(1.0, dt * 3.0))
	unnerved = maxf(0.0, unnerved - dt)
	if sanity_lock >= 0.0:
		sanity = sanity_lock                      # debug console: `sanity <n>` pins it
	elif unnerved > 0.0:
		pass                                      # no calming down while you stare at them (they drain it)
	elif light_level >= 0.45:
		var rec := minf(1.0, (light_level - 0.45) / 0.55)
		sanity = minf(100.0, sanity + 2.2 * (0.4 + 0.6 * rec) * dt)
		dark_time = 0.0
	elif torch_lit:
		# your own light: steadies you even in the dark, a little slower than a properly lit room
		sanity = minf(100.0, sanity + 1.4 * dt)
		dark_time = maxf(0.0, dark_time - dt * 3.0)
	elif light_level < 0.3:
		var dark_ratio := 1.0 - light_level / 0.3
		dark_time += dt
		var creep := 1.0 + minf(dark_time / 20.0, 1.0)         # doubles over the first 20 s of it
		sanity = maxf(0.0, sanity - (1.0 + dark_ratio * 4.5) * creep * (1.4 if grid_down else 1.0) * Upgrades.scale("psych") * dt)
	else:
		dark_time = maxf(0.0, dark_time - dt)                  # dim but not black: neither gain nor loss
	# a Drain zone (painted in the level editor): the place itself wears you down, lit or not, torch or not
	if sanity_lock < 0.0 and level != null:
		var zone = level.get("drain")
		if zone is Dictionary and zone.has(Vector2i(roundi(global_position.x / 4.5), roundi(global_position.z / 4.5))):
			sanity = maxf(0.0, sanity - DRAIN_ZONE_RATE * Upgrades.scale("psych") * dt)
	_update_mind(dt)
# A slipping mind hurts. Below HURT_SANITY the body starts to fail (faster the lower it goes), the
# picture smears and doubles (insanity, read by the post shader) and the heart runs. Recovering
# sanity stops the bleed, and health then creeps back once you are properly calm again.
func _update_mind(dt: float) -> void:
	var target := clampf((INSANE_BELOW - sanity) / INSANE_BELOW, 0.0, 1.0)
	insanity += (target - insanity) * minf(1.0, dt * 1.5)
	if Game.god_mode:
		health = 100.0
		return
	if sanity < HURT_SANITY:
		var sev := 1.0 - sanity / HURT_SANITY
		health = maxf(0.0, health - (0.6 + 3.0 * sev * sev) * dt)
		hurt_tick -= dt
		if hurt_tick <= 0.0:            # a throb of pain with the drain
			hurt_tick = 2.2 - 1.4 * sev
			Game.add_glitch(0.12 + 0.25 * sev)
			Game.beat()
		if Game.heart != null:
			Game.heart.feed("mind", 0.25 + 0.5 * sev)
		if health <= 0.0 and not dead and not frozen:
			Game.kill_player("PSYCHOLOGICAL COLLAPSE")
	elif sanity > CALM_SANITY and health < 100.0:
		health = minf(100.0, health + 0.8 * dt)
