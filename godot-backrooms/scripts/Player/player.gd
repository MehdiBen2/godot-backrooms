extends "res://scripts/Player/player_squeeze.gd"
## First-person controller. Values mirror PLAYER_DEFAULTS / JUMP in the web game.
## Movement reads PHYSICAL keys, so WASD works as ZQSD on AZERTY (and any other layout).
##
## Its parts live beside it: footsteps.gd (your footfalls), torch_model.gd (the torch in your hand),
## blink.gd (your eyelids). The flashlight beam, stamina, adrenaline and sanity are here.

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# stairs and ramps (props/vertical_pieces.gd, props/stairs.gd): as fast up a slope as on the flat, held down onto
	# it going down instead of skipping off each tread, and a slope a little past 45 degrees still a floor
	floor_constant_speed = true
	floor_snap_length = 0.45
	floor_max_angle = deg_to_rad(48.0)
	level = get_parent().get_node_or_null("Level")
	# The beam leaves from the low hand now, so it skims the floor: at that grazing angle the shadow map
	# bands across it, which a normal bias lifts. Level lamps set theirs in code too, not in the scene.
	flash.shadow_normal_bias = 2.0
	flash.shadow_blur = 1.0
	flash.spot_angle_attenuation = 1.45
	flash.spot_attenuation = 1.2
	flash.light_projector = beam_cookie()          # the lens pattern of a real torch (a texture, not a flat disc)
	# the beam is not drawn into the fog: there the lens pattern showed as a flat picture in the air
	# in front of the camera, instead of on the walls
	flash.light_volumetric_fog_energy = 0.0
	flash.top_level = true
	flash.visible = true
	flash_spill = flash.get_node_or_null("Spill") as SpotLight3D
	if flash_spill == null:
		flash_spill = SpotLight3D.new()
		flash_spill.name = "Spill"
		flash_spill.light_color = Color(1.0, 0.94, 0.84, 1.0)
		flash_spill.light_energy = FLASH_ENERGY_SPILL
		flash_spill.spot_range = 20.0
		flash_spill.spot_angle = 58.0
		flash_spill.spot_attenuation = 1.2
		flash_spill.spot_angle_attenuation = 1.3
		flash_spill.shadow_enabled = false
		flash.add_child(flash_spill)
	head_lamp = SpotLight3D.new()
	head_lamp.name = "HeadLamp"
	head_lamp.position = HEAD_LAMP_AT
	head_lamp.light_color = Color(1.0, 0.93, 0.8)
	head_lamp.spot_range = HEAD_LAMP_RANGE
	head_lamp.spot_angle = HEAD_LAMP_ANGLE
	head_lamp.spot_attenuation = 1.4
	head_lamp.spot_angle_attenuation = 1.6
	head_lamp.shadow_enabled = true
	head_lamp.shadow_normal_bias = 2.0
	head_lamp.shadow_blur = 1.5
	head_lamp.light_energy = 0.0
	head_lamp.visible = false
	cam.add_child(head_lamp)
	torch = TorchModel.new()
	cam.add_child(torch)
	if not torch.build():
		torch.queue_free()
		torch = null
	else:
		torch.swap_started.connect(func(): battery_swap.emit())
		torch.swap_cut.connect(func(): battery_swap_cut.emit())
		torch.swap_dark.connect(func(dark: bool): swap_dark = dark)
		torch.swap_done.connect(_swap_done)
	shadow_body = PlayerShadow.new()
	add_child(shadow_body)
	if not shadow_body.build():
		shadow_body.queue_free()
		shadow_body = null
	else:
		# The flashlight is mounted on this same body, so up close it clips through its own
		# shadow-only geometry (worst when looking down or mid-sprint). Only the ceiling tubes,
		# far enough away not to self-intersect, are left to light/shadow it. Both masks matter:
		# light_cull_mask alone only stops the flashlight from lighting the body, shadow_caster_mask
		# is the one that actually keeps it out of the flashlight's shadow map.
		flash.light_cull_mask &= ~PlayerShadow.SHADOW_LAYER
		flash.shadow_caster_mask &= ~PlayerShadow.SHADOW_LAYER
		flash_spill.light_cull_mask &= ~PlayerShadow.SHADOW_LAYER
		flash_spill.shadow_caster_mask &= ~PlayerShadow.SHADOW_LAYER
		head_lamp.light_cull_mask &= ~PlayerShadow.SHADOW_LAYER
		head_lamp.shadow_caster_mask &= ~PlayerShadow.SHADOW_LAYER
	footsteps = Footsteps.new()
	footsteps.name = "Footsteps"
	add_child(footsteps)
	blink = Blink.new()
	blink.name = "Blink"
	add_child(blink)
	click_player = AudioStreamPlayer.new()
	click_player.volume_db = -4.4
	add_child(click_player)
	fullbright_light = OmniLight3D.new()
	fullbright_light.name = "FullbrightLight"
	fullbright_light.omni_range = 250.0
	fullbright_light.omni_attenuation = 0.35
	fullbright_light.light_energy = 2.2
	fullbright_light.light_color = Color(1.0, 0.98, 0.94)
	fullbright_light.shadow_enabled = false
	fullbright_light.visible = Game.fullbright
	cam.add_child(fullbright_light)


func _key(code: Key) -> bool:
	return Input.is_physical_key_pressed(code)

func _unhandled_input(e: InputEvent) -> void:
	if dead or frozen or _door_anim_active: return     # the door scene has the view and the hands
	if e is InputEventMouseMotion and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		look_from = -1
	elif e is InputEventMouseMotion:
		# capturing warps the cursor to the centre and reports it as one big move, which would spin you
		# off the direction the level spawns you facing: ignore motion for a moment after capture
		if look_from < 0: look_from = Time.get_ticks_msec()
		if Time.get_ticks_msec() - look_from < 150: return
		# zoomed in, the same hand movement sweeps a smaller slice of the world: the aim slows with the lens
		var aim := sens / pow(lens_zoom, 0.8)
		rotate_y(-e.relative.x * aim)
		turn_accum += -e.relative.x * aim
		pitch_accum += -e.relative.y * aim
		# set the Euler pitch directly: rotate_x() on a camera with lean/roll (rotation.z) mixes axes,
		# so the clamp read back a wrapped angle and let the view flip past straight down
		cam.rotation.x = clampf(cam.rotation.x - e.relative.y * aim, -LOOK_DOWN_MAX, LOOK_UP_MAX)
		_sync_flashlight_aim(0.35)
	elif e.is_action_pressed("flashlight") and lens_up <= 0.0 \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		toggle_flashlight()
	elif (e.is_action_pressed("interact") or (e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_E)) \
			and lens_up <= 0.0 and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if focused_door != null and focused_door.has_method("interact"):
			focused_door.interact(self)
			_sync_flashlight_aim(0.35)
			if is_inside_tree(): get_viewport().set_input_as_handled()

## F, or a click with the torch selected on the hotbar (item_strip.gd)
func toggle_flashlight() -> void:
	if not flash_on and battery <= 0.0:
		dead_click.emit()          # dead battery: a dry hollow click, nothing else
		return
	flash_on = not flash_on
	click_player.stream = click_on if flash_on else click_off
	click_player.play()

func _process(delta: float) -> void:
	var _pt := Time.get_ticks_usec()
	_process_timed(delta)
	Perf.add("Player", _pt)

func _process_timed(delta: float) -> void:
	if not dead and not frozen:
		_update_flashlight_aim(delta)
	focused_door = _find_interactable_door() if not dead and not frozen and not _door_anim_active else null
	_update_fall_fx(delta)

func _physics_process(dt: float) -> void:
	var _pt := Time.get_ticks_usec()
	_physics_process_timed(dt)
	Perf.add("Player (physics)", _pt)

func _physics_process_timed(dt: float) -> void:
	spawn_grace = maxf(0.0, spawn_grace - dt)
	# nothing is hunting you any more (or nothing is left to say so): let the burst wind down on its own
	adr_idle += dt
	if adr_idle > 0.5 and (adr_active or adrenaline > 0.0):
		_tick_adrenaline(dt, false)
	if torch:
		torch.caught = dead or (frozen and not held_by_event)   # held by an entity, or dead: the hands are gone
		# held by an event: a start as it takes hold of you, then the hands stay, the torch as it was
		if frozen and held_by_event and not dead and not _event_flinched:
			torch.flinch()
		_event_flinched = frozen and held_by_event
	if dead or frozen:
		if _door_anim_active: _end_door_scene()        # grabbed, or worse, with a hand on the door
		if adrenaline > 0.0 or adr_active: end_adrenaline()
		velocity.x = 0.0
		velocity.z = 0.0
		is_moving = false
		is_sprinting = false
		if not is_on_floor(): velocity.y -= GRAVITY * dt
		move_and_slide()
		peek.update(dt, self, eye, false)
		if torch:
			torch.set_hug(false, Vector3.ZERO, Vector3.ZERO, false)
			torch.set_grab(false, 1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			torch.set_squeeze(false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			torch.set_peek(peek.side, false, peek.edge, peek.normal, peek.out, peek.dist, false, is_crouching)
		if shadow_body: shadow_body.update(false, false, is_crouching, dead, 0.0)
		if torch:
			if dead:
				torch.end_swap()
			# (held too: the hands' last reach plays out, then they're gone; by an event they stay, the torch as it was)
			torch.update(dt, flash_on and held_by_event and not dead, false, false, bob)
		if dead:
			flash.visible = false
			flash.light_energy = 0.0
			if flash_spill:
				flash_spill.visible = false
				flash_spill.light_energy = 0.0
		return
	if _door_anim_active:            # (it plays out even with the mouse let go: the door waits on it)
		_door_scene(dt)
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not Game.draw_mode:
		return
	if Game.noclip or Game.draw_mode:
		_fly(dt)
		_was_flying = true
		return
	if _was_flying:
		_was_flying = false
		shape.disabled = false         # the draw tools panel closed: solid again
	var crouch := Input.is_action_pressed("crouch")
	_update_squeeze(dt)
	var crawling: bool = Game.level != null and "crawl" in Game.level and (Game.level.crawl as Dictionary).has(Vector2i(roundi(global_position.x / Game.level.CELL), roundi(global_position.z / Game.level.CELL))) and not dead
	crawl_k = lerpf(crawl_k, 1.0 if crawling else 0.0, minf(1.0, dt * 4.0))
	if crawling:
		crouch = true                  # no standing up under a ceiling like that
	var dir := Vector2.ZERO
	if Input.is_action_pressed("move_forward"): dir.y -= 1
	if Input.is_action_pressed("move_backward"): dir.y += 1
	if Input.is_action_pressed("move_left"): dir.x -= 1
	if Input.is_action_pressed("move_right"): dir.x += 1
	var moving := dir != Vector2.ZERO
	var rush := adrenaline > 0.5 and adr_active     # sprint is free during a burst
	# wading (a Water object, level_data.gd water_depth_at): the deeper, the slower; past the waist no running
	var wade: float = Game.level.water_depth_at(global_position) if Game.level != null and Game.level.has_method("water_depth_at") else 0.0
	wade_k = lerpf(wade_k, clampf(wade / WADE_DEEP, 0.0, 1.0), minf(1.0, dt * 6.0))
	var sprint := Input.is_action_pressed("sprint") and not crouch and moving and (rush or (not exhausted and stamina > 0.0)) and tight_k < 0.25 and wade < 0.9
	is_sprinting = sprint
	is_moving = moving
	is_crouching = crouch
	_update_stamina(dt, sprint, rush)

	eye = lerpf(eye, CRAWL_EYE if crawling else (CROUCH_H if crouch else STAND_H), minf(1.0, dt * (6.0 if crawling else 10.0)))
	(shape.shape as CapsuleShape3D).height = eye + 0.1
	shape.position.y = (eye + 0.1) / 2.0

	var speed := SPEED * (SPRINT_MULT if sprint else (CROUCH_MULT if crouch else 1.0))
	speed *= 1.0 + ADR_BOOST * adrenaline
	speed *= 1.0 + SWING_BOOST * _swing_boost
	speed *= 1.0 + CORNER_BOOST * _corner_boost
	speed *= lerpf(1.0, SQUEEZE_SPEED, tight_k) * lerpf(1.0, CRAWL_SPEED, crawl_k)
	speed *= lerpf(1.0, WADE_SPEED, wade_k)
	speed *= Game.speed_mult
	var wish := (transform.basis * Vector3(dir.x, 0, dir.y)).normalized() * speed
	if _corner_on and wish.length_squared() > 0.0001:
		# the hand on the corner draws you round it
		var pull := sin(PI * clampf(_corner_t / CORNER_TIME, 0.0, 1.0)) * CORNER_STEER
		wish = wish.normalized().lerp(corner.dir, pull).normalized() * speed
	var rate := ACCEL_AIR
	if is_on_floor():
		rate = ACCEL_GROUND if moving else DECEL_GROUND
	velocity.x = move_toward(velocity.x, wish.x, rate * speed * dt)
	velocity.z = move_toward(velocity.z, wish.z, rate * speed * dt)

	var space := Input.is_action_pressed("jump")
	if space and not space_prev:
		jump_buffer = JUMP_BUFFER
	space_prev = space
	jump_buffer = maxf(0.0, jump_buffer - dt)
	coyote = COYOTE_TIME if is_on_floor() else maxf(0.0, coyote - dt)
	# Deep water (a pool, a flood over your chin): you float with your head out of it. Space swims up, crouch
	# dives, and pushing on into the pool's side heaves you up and out over it.
	# (afloat, the water stands at eye - SWIM_FLOAT: well clear of where you start and stop, so it never flickers)
	swimming = wade > eye - SWIM_FLOAT - 0.05 or (swimming and wade > eye - SWIM_FLOAT - 0.5 and not is_on_floor())
	if swimming and is_on_wall() and moving and dir.y < 0.0 and wade < eye + 0.4 and _climb_out <= 0.0:
		_climb_out = CLIMB_OUT_TIME                  # hands on the side, heave: carried on until you are over it
	if _climb_out > 0.0:
		_climb_out -= dt
		velocity.y = CLIMB_OUT_SPEED
		if not is_on_wall() and wade <= 0.05: _climb_out = 0.0      # over the rim: on you go
		jump_buffer = 0.0
		coyote = 0.0
	elif swimming:
		var want := clampf((wade - (eye - SWIM_FLOAT)) * 2.5, -1.2, 1.4)
		if crouch: want = -1.5
		elif space: want = 1.8
		velocity.y = move_toward(velocity.y, want, dt * 7.0)
		jump_buffer = 0.0
		coyote = 0.0
	elif crawling:
		jump_buffer = 0.0              # no room to jump under a crawl-space ceiling
		if not is_on_floor():
			velocity.y = maxf(velocity.y - GRAVITY * dt, -fall_speed_max)
	elif (space or jump_buffer > 0.0) and coyote > 0.0:
		velocity.y = JUMP_SPEED * Game.jump_mult
		jump_buffer = 0.0
		coyote = 0.0
		jumped.emit()
	elif not is_on_floor():
		velocity.y = maxf(velocity.y - GRAVITY * dt, -fall_speed_max)
	last_vy = velocity.y
	var was_floor := is_on_floor()
	var y_was := global_position.y
	if was_floor and velocity.y <= 0.0 and not swimming and _climb_out <= 0.0: _step_up(dt)
	move_and_slide()
	# down a real step: the floor snap drops the body onto the tread below at once, so the view follows it down
	if was_floor and is_on_floor() and get_floor_normal().y > 0.97:
		var drop := y_was - global_position.y
		if drop > 0.03 and drop < STEP_UP + 0.05: step_ease += drop
	# Landing: both feet down, thud scales with the drop
	if is_on_floor():
		if was_airborne and air_time > 0.15 and last_vy < -2.0:
			var strength := minf(1.0, absf(last_vy) / 12.0)
			landed.emit(strength)
			land_dip = 0.04 + 0.10 * strength
			camera_feel.land(strength)
			footsteps.step(true, false, 1.0)
		was_airborne = false
		air_time = 0.0
	else:
		was_airborne = true
		air_time += dt
	var near_door := _near_door()
	if near_door:
		peek.reset()
		_corner_on = false
		_swinging = false
		_corner_cd = maxf(_corner_cd, 1.0)
		_swing_cd = maxf(_swing_cd, 1.0)

	peek.update(dt, self, eye, is_on_floor() and not sprint and tight_k < 0.3 and not near_door)    # no peeking from inside a slit or near doors
	if not near_door:
		_update_swing(dt, crouch)
		_update_corner(dt, sprint, crouch)
	else:
		_corner_on = false
		_swinging = false

	if torch:
		var flat_speed := Vector2(velocity.x, velocity.z).length()
		_peek_slow = flat_speed < PEEK_HOLD_SPEED * (1.5 if _peek_slow else 0.8)   # hysteresis: hovering at the limit doesn't flicker the grip
		var slow := _peek_slow or _swinging      # swinging round, the hand holds on though you're moving
		_set_squeeze_hands()
		if near_door:
			torch.set_grab(false, 0, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			torch.set_hug(false, Vector3.ZERO, Vector3.ZERO, false)
			torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, crouch)
		else:
			torch.set_grab(_corner_on, corner.side, corner.point, corner.normal, corner.out)
			torch.set_hug(peek.hug, peek.hug_point, peek.hug_normal, slow)
			torch.set_peek(peek.side, peek.leaning, peek.edge, peek.normal, peek.out, peek.dist, slow, crouch)
		torch.ambient = light_level                    # (in the dark, with the torch down, the free hand gropes ahead)
		torch.update(dt, flash_on and not dead and not _tight_spot(), is_sprinting, is_moving, bob)
		if lens_up > 0.02:
			torch.visible = false        # the camcorder is at your eye: both hands are on it
	if shadow_body:
		# bob / PI counts footfalls (_update_head plays one each PI): the legs plant a heel on each
		shadow_body.update(is_moving, is_sprinting, is_crouching, dead, Vector2(velocity.x, velocity.z).length(), velocity, cam.rotation.x, bob / PI)
	_update_flashlight(dt)
	_update_sanity(dt)
	_update_head(dt, dir, sprint, crouch, moving)

	# fell down a pit or drop hole: seamless descent to floor below, or loop to spawn (no loading screen).
	# (A pit that opens into the floor below never gets this far: level_builder.gd hands you to that floor.)
	# (A bottomless pit's fall is pit_fall.gd's, Game.freefall.)
	if global_position.y < -12.0 and not Death.respawn_busy and not Game.freefall:
		if Game.level_floor > 0:
			Game.change_floor(Game.level_floor - 1, Vector2(global_position.x / 4.5, global_position.z / 4.5), "drop_hole")
		elif global_position.y < -30.0:
			_back_to_spawn()

# Stamina: 30 s of sprint, brief rest delay, exhaustion until it recovers a bit
## Noclip (editor test launch): free flight along the camera, straight through walls and floors.
## WASD move, Space up, C/Ctrl down, Shift fast.
var _was_flying := false

func _fly(dt: float) -> void:
	shape.disabled = true
	var dir := Vector3.ZERO
	if Input.is_action_pressed("move_forward"): dir.z -= 1
	if Input.is_action_pressed("move_backward"): dir.z += 1
	if Input.is_action_pressed("move_left"): dir.x -= 1
	if Input.is_action_pressed("move_right"): dir.x += 1
	var wish := cam.global_transform.basis * dir
	if Input.is_action_pressed("jump"): wish.y += 1.0
	if Input.is_action_pressed("crouch"): wish.y -= 1.0
	velocity = Vector3.ZERO
	is_moving = false
	is_sprinting = false
	var fly_spd := (18.0 if Input.is_action_pressed("sprint") else 7.0) * Game.speed_mult
	global_position += wish.normalized() * fly_spd * dt

## The long fall on the screen: the post shader smears the picture along the way things stream past (out of
## the point you are falling towards, or into the one you are falling away from) and bends the lens a little.
## Run every frame, so the streaks go the moment you land, die or freeze.
func _update_fall_fx(dt: float) -> void:
	var want := 0.0
	if not (dead or frozen or Game.noclip or Game.draw_mode or is_on_floor()):
		want = smoothstep(FALL_FX_FROM, FALL_FX_FULL, -velocity.y)
	fall_fx += (want - fall_fx) * minf(1.0, dt * (4.0 if want > fall_fx else 9.0))
	var post := Gfx.post_mat
	if post == null: return
	if fall_fx < 0.002:
		if _fall_post:
			_fall_post = false
			post.set_shader_parameter("fall_blur", 0.0)
			post.set_shader_parameter("fall_warp", 0.0)
		return
	_fall_post = true
	# where the way you are going lands on the screen (Godot's fov is vertical); behind you, its opposite,
	# which the streaks run into instead of out of: the same lines either way
	var d := cam.global_transform.basis.inverse() * velocity.normalized()
	if d.z > 0.0: d = -d
	var t := tan(deg_to_rad(cam.fov) * 0.5)
	var vp := get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	var z := maxf(-d.z, 0.001)
	var foe := Vector2(0.5 + 0.5 * clampf(d.x / z / (t * aspect), -2000.0, 2000.0), 0.5 - 0.5 * clampf(d.y / z / t, -2000.0, 2000.0))
	post.set_shader_parameter("fall_foe", foe)
	post.set_shader_parameter("fall_blur", FALL_BLUR * fall_fx * fall_fx)
	post.set_shader_parameter("fall_warp", FALL_WARP * fall_fx)

## Real steps (a spiral's treads, props/vertical_pieces.gd): walking into a riser no higher than STEP_UP lifts you
## onto the tread, as a foot would. Only into something wall-like with a floor on top of it: a slope you walk up
## anyway, and a wall is still a wall. The view trails the lift and eases up after it (step_ease).
const STEP_UP := 0.32
func _step_up(dt: float) -> void:
	var motion := Vector3(velocity.x, 0.0, velocity.z) * dt
	if motion.length_squared() < 0.000001: return
	var from := global_transform
	var hit := KinematicCollision3D.new()
	if not test_move(from, motion): return                                        # nothing ahead
	var lift := STEP_UP
	if test_move(from, Vector3(0, STEP_UP, 0), hit): lift = hit.get_travel().y   # (a ceiling over you)
	if lift < 0.05: return
	var raised := from.translated(Vector3(0, lift, 0))
	if test_move(raised, motion): return                                          # still blocked: a wall
	if not test_move(raised.translated(motion), Vector3(0, -lift, 0), hit): return   # nothing to stand on up there
	if hit.get_normal().y < cos(floor_max_angle): return
	var rise := lift + hit.get_travel().y
	# a slope you could walk up gains less than this over the same stride: move_and_slide takes those
	if rise < maxf(0.04, motion.length() * tan(floor_max_angle)): return
	global_position.y += rise
	step_ease -= rise

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

## How far your footsteps carry right now (the entity's hearing multiplies by this)
func step_noise() -> float:
	return footsteps.noise() if footsteps else 1.0

# Something heavy landed nearby (the bacteria's footfalls in a chase): the view dips with the floor
func jolt(amount: float) -> void:
	land_dip = maxf(land_dip, clampf(amount, 0.0, 1.0) * 0.035)

# The floor shaking under something heavy nearby: 0..1, the view rumbles and settles
func quake(amount: float) -> void:
	quake_amt = maxf(quake_amt, clampf(amount, 0.0, 1.0))

## A blast, a heavy impact, a big footfall: amount 0..1 of trauma shakes the view and dies away
## (camera_feel.gd). from: where it came from (world), to throw the head away from it; leave it out for a
## shake with no direction.
func add_trauma(amount: float, from := Vector3.INF) -> void:
	var push := Vector3.ZERO
	if from.is_finite():
		push = cam.global_basis.inverse() * (cam.global_position - from).normalized()
	camera_feel.add_trauma(amount, push)

# Face to face with the bacteria up close: your torch arm jerks up in front of your face
func flinch() -> void:
	if torch != null and not dead and not frozen:
		torch.flinch()

# Adrenaline: the bacteria calls this every frame with whether it is hunting you close by
func update_adrenaline(dt: float, hunted: bool) -> void:
	adr_idle = 0.0
	_tick_adrenaline(dt, hunted)

func _tick_adrenaline(dt: float, hunted: bool) -> void:
	if dead or frozen: hunted = false
	adr_cooldown = maxf(0.0, adr_cooldown - dt)
	if not adr_active and hunted and adr_cooldown <= 0.0:
		adr_active = true
		adr_time = 0.0
		adr_glow = ADR_AFTERGLOW
		Game.fx_shock = maxf(Game.fx_shock, 0.7)     # the jolt as it hits: the picture punches in
		var sc := get_parent().get_node_or_null("Scares")
		if sc != null:
			sc.startle(0.35)
			sc.heartbeat(1.6)
		adrenaline_started.emit()
	if adr_active:
		adr_time += dt
		adr_glow = ADR_AFTERGLOW if hunted else adr_glow - dt
		if adr_time > ADR_MAX_TIME or adr_glow <= 0.0 or dead:
			adr_active = false
			adr_cooldown = ADR_COOLDOWN
			if not dead:
				stamina = minf(stamina, ADR_CRASH_STAMINA)
				rest_timer = 2.5
				adrenaline_faded.emit()
	var target := 1.0 if adr_active else 0.0
	var rate := 1.0 / ADR_RAMP if target > adrenaline else 1.0 / 1.5
	adrenaline = move_toward(adrenaline, target, rate * dt)

# Drop straight out of adrenaline (death, grab, respawn): no crash, no cooldown
func end_adrenaline() -> void:
	adr_active = false
	adr_cooldown = 0.0
	adrenaline = 0.0

func _back_to_spawn() -> void:
	end_adrenaline()
	global_position = level.spawn_pos
	velocity = Vector3.ZERO
	land_dip = 0.0
	quake_amt = 0.0
	camera_feel.reset()
	was_airborne = false
	air_time = 0.0

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

## Load a battery pack worth `charge` % (hud.gd, R). The hands change the cells (torch_model.gd swap()):
## the light is out while the cap is off, and the charge goes in when it's back on. Without the arms it
## just goes in.
func swap_battery(charge: float) -> void:
	swap_charge += charge
	if torch == null or not torch.swap():
		battery_swap.emit()
		_swap_done()

func swapping() -> bool:
	return torch != null and torch.swapping()

func _swap_done() -> void:
	battery = minf(100.0, battery + swap_charge)
	swap_charge = 0.0

## The torch stutters for `secs` seconds (an event, or something big coming close)
func trigger_flicker(secs: float) -> void:
	flash_flicker.timer = 0.0
	flash_flicker.active = true
	flash_flicker.step = 0.0
	flicker_left = maxf(flicker_left, secs)
	if torch: torch.smack()

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

## Player gasps in fright (e.g. when seized or startled by an entity)
func gasp() -> void:
	var sc: Node = get_parent().get_node_or_null("Scares")
	if sc != null:
		sc.gasp()

func set_fullbright(on: bool) -> void:
	Game.fullbright = on
	if is_instance_valid(fullbright_light):
		fullbright_light.visible = on
	var we := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and we.environment:
		var env := we.environment
		if on:
			if not env.has_meta("orig_ambient_energy"):
				env.set_meta("orig_ambient_energy", env.ambient_light_energy)
				env.set_meta("orig_ambient_color", env.ambient_light_color)
				env.set_meta("orig_fog", env.fog_enabled)
			env.ambient_light_energy = 2.2
			env.ambient_light_color = Color.WHITE
			env.fog_enabled = false
		else:
			if env.has_meta("orig_ambient_energy"):
				env.ambient_light_energy = float(env.get_meta("orig_ambient_energy"))
				env.ambient_light_color = env.get_meta("orig_ambient_color")
				env.fog_enabled = bool(env.get_meta("orig_fog"))
