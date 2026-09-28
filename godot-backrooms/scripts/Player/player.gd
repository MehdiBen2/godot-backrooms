extends CharacterBody3D
## First-person controller. Values mirror PLAYER_DEFAULTS / JUMP in the web game.
## Movement reads PHYSICAL keys, so WASD works as ZQSD on AZERTY (and any other layout).
##
## Its parts live beside it: footsteps.gd (your footfalls), torch_model.gd (the torch in your hand),
## blink.gd (your eyelids). The flashlight beam, stamina, adrenaline and sanity are here.

const Footsteps := preload("res://scripts/Player/footsteps.gd")
const TorchModel := preload("res://scripts/Player/torch_model.gd")
const Blink := preload("res://scripts/Player/blink.gd")
const PlayerShadow := preload("res://scripts/Player/player_shadow.gd")
const Handheld := preload("res://scripts/Player/handheld.gd")

const SPEED := 2.6
const SPRINT_MULT := 1.75
const CROUCH_MULT := 0.52
const STAND_H := 1.7
const CROUCH_H := 1.0
const JUMP_SPEED := 5.0
const GRAVITY := 20.0
# Movement feel: weighty but responsive, forgiving jumps
const ACCEL_GROUND := 16.0        # x speed per second towards the wished velocity (was an instant 40 m/s^2)
const DECEL_GROUND := 22.0        # a touch snappier when letting go, so stops feel deliberate
const ACCEL_AIR := 5.0            # limited steering in the air
const COYOTE_TIME := 0.10         # can still jump this long after walking off an edge
const JUMP_BUFFER := 0.12         # a press this soon before landing still jumps
const LEAN_WALK := 0.010          # camera roll into a strafe (rad)
const LEAN_SPRINT := 0.018
const SPRINT_SECONDS := 30.0
const STAMINA_REGEN := 18.0
# Adrenaline (ADRENALINE in js/config.js): hunted by the bacteria up close, you get a burst of speed
# and endless sprint to break away, then a crash
const ADR_RANGE := 22.0          # metres: it must be chasing you from at least this close
const ADR_BOOST := 0.5           # +50% movement speed
const ADR_RAMP := 0.35           # seconds to reach full strength
const ADR_MAX_TIME := 10.0       # longest a burst can last
const ADR_AFTERGLOW := 3.5       # seconds it lingers after the chase ends
const ADR_CRASH_STAMINA := 25.0  # stamina you're left with when it fades
const ADR_COOLDOWN := 22.0       # seconds before it can kick in again
const ADR_FOV := 9.0             # extra field of view at full strength (degrees)
# three.js fov is vertical; Godot's default keeps height too (KEEP_HEIGHT)
const BASE_FOV := 75.0
const INSANE_BELOW := 60.0     # the picture starts to go and the eyes open below this
const HURT_SANITY := 30.0      # health starts draining below this
const CALM_SANITY := 60.0      # health starts coming back above this
const FLASH_ENERGY_HOTSPOT := 6.5
const FLASH_ENERGY_SPILL := 2.0
const BATTERY_DRAIN := 100.0 / 75.0     # % per second while on (75 s of light)
const BATTERY_LOW := 25.0
const BATTERY_CRIT := 10.0

@onready var cam: Camera3D = $Camera3D
@onready var flash: SpotLight3D = $Camera3D/Flashlight
@onready var shape: CollisionShape3D = $CollisionShape3D
var flash_spill: SpotLight3D
var footsteps: Footsteps
var torch: TorchModel
var blink: Blink
var shadow_body: PlayerShadow
var level: Node

signal jumped
signal landed(strength: float)
signal battery_died
signal dead_click
signal contact_click(off: bool)
signal adrenaline_started
signal adrenaline_faded

# settings (menu.gd pushes them in through hud.apply_settings)
var sens := 0.0022
var base_fov := BASE_FOV
var head_bob := 1.0              # 0 = steady camera, 1 = full bob / lean / landing dip

var is_sprinting := false
var is_moving := false
var is_crouching := false
var was_airborne := false
var air_time := 0.0
var last_vy := 0.0
var eye := STAND_H
var was_stepping := false
var step_triggered := false
var fov_kick := 0.0
var handheld := Handheld.new()   # camcorder-in-the-hands offsets: weight, tremor, uneven steps (handheld.gd)
var pitch_accum := 0.0           # mouse pitch since the last physics tick (rad), for the handheld weight
var bob_amp := 1.0               # eased per-step bob height from handheld.step_amp
var health := 100.0
var sanity := 100.0
var sanity_lock := -1.0        # >= 0 pins sanity there (debug console)
var insanity := 0.0            # 0..1 how far gone: blur, double vision, the eyes
var hurt_tick := 0.0
var battery := 100.0          # flashlight battery, %
var flash_on := true
var light_level := 1.0
var flash_target := Vector3.ZERO
var flash_flicker := {"timer": 6.0, "active": false, "step": 0.0, "value": 1.0}
var flicker_left := 0.0
var dead := false
var grid_down := false       # power cut: the torch drains slowly
var spawn_grace := 0.0
var frozen := false          # grabbed / snapped: no input
var stamina := 100.0
var exhausted := false
var rest_timer := 0.0
var adrenaline := 0.0          # 0..1 strength of the burst, eased in and out
var adr_active := false
var adr_time := 0.0
var adr_glow := 0.0
var adr_cooldown := 0.0
var bob := 0.0
var click_player: AudioStreamPlayer
var click_on: AudioStream = load("res://audio/on.mp3")
var click_off: AudioStream = load("res://audio/off.mp3")
var space_prev := false
var jump_buffer := 0.0
var coyote := 0.0
var land_dip := 0.0
var quake_amt := 0.0          # 0..1: something heavy walking nearby shaking the floor (and the view)
var quake_t := 0.0
var lean := 0.0
const TURN_ROLL_MAX := 0.045
var turn_accum := 0.0         # mouse yaw since the last physics tick (rad)
var turn_roll := 0.0
var idle_time := 0.0
var idle_amt := 0.0
var pitch_off := 0.0          # motion pitch offset currently added onto cam.rotation.x
var pitch_applied := 0.0
var dark_time := 0.0          # how long you have been in the dark with no light of your own
var beam_tilt := 0.0          # eased sprint/crouch dip: the beam drops with the hand, not just the model
var beam_pos := Vector3.ZERO  # eased light origin: the torch lens, pulled back to the eye inside walls
const BEAM_TILT_MAX := 0.30   # rad: how far the arm may drop the beam (any more and it only skims the floor)

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	level = get_parent().get_node_or_null("Level")
	# The beam leaves from the low hand now, so it skims the floor: at that grazing angle the shadow map
	# bands across it, which a normal bias lifts. Level lamps set theirs in code too, not in the scene.
	flash.shadow_normal_bias = 2.0
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
		flash_spill.spot_attenuation = 1.1
		flash_spill.spot_angle_attenuation = 1.1
		flash_spill.shadow_enabled = false
		flash.add_child(flash_spill)
	torch = TorchModel.new()
	cam.add_child(torch)
	if not torch.build():
		torch.queue_free()
		torch = null
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
	footsteps = Footsteps.new()
	footsteps.name = "Footsteps"
	add_child(footsteps)
	blink = Blink.new()
	blink.name = "Blink"
	add_child(blink)
	click_player = AudioStreamPlayer.new()
	click_player.volume_db = -4.4
	add_child(click_player)

func _key(code: Key) -> bool:
	return Input.is_physical_key_pressed(code)

func _unhandled_input(e: InputEvent) -> void:
	if dead or frozen: return
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-e.relative.x * sens)
		turn_accum += -e.relative.x * sens
		pitch_accum += -e.relative.y * sens
		# set the Euler pitch directly: rotate_x() on a camera with lean/roll (rotation.z) mixes axes,
		# so the clamp read back a wrapped angle and let the view flip past straight down
		cam.rotation.x = clampf(cam.rotation.x - e.relative.y * sens, -1.49, 1.49)
	elif e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_F \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if not flash_on and battery <= 0.0:
			dead_click.emit()          # dead battery: a dry hollow click, nothing else
			return
		flash_on = not flash_on
		click_player.stream = click_on if flash_on else click_off
		click_player.play()

func _physics_process(dt: float) -> void:
	spawn_grace = maxf(0.0, spawn_grace - dt)
	if dead or frozen:
		if adrenaline > 0.0 or adr_active: end_adrenaline()
		velocity.x = 0.0
		velocity.z = 0.0
		is_moving = false
		is_sprinting = false
		if not is_on_floor(): velocity.y -= GRAVITY * dt
		move_and_slide()
		if shadow_body: shadow_body.update(false, false, is_crouching, dead, 0.0)
		if dead:
			if torch: torch.update(dt, false, false, false, bob)
			flash.visible = false
			flash.light_energy = 0.0
			if flash_spill:
				flash_spill.visible = false
				flash_spill.light_energy = 0.0
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if Game.noclip:
		_fly(dt)
		return
	var crouch := _key(KEY_C) or _key(KEY_CTRL)
	var dir := Vector2.ZERO
	if _key(KEY_W) or _key(KEY_UP): dir.y -= 1
	if _key(KEY_S) or _key(KEY_DOWN): dir.y += 1
	if _key(KEY_A) or _key(KEY_LEFT): dir.x -= 1
	if _key(KEY_D) or _key(KEY_RIGHT): dir.x += 1
	var moving := dir != Vector2.ZERO
	var rush := adrenaline > 0.5 and adr_active     # sprint is free during a burst
	var sprint := _key(KEY_SHIFT) and not crouch and moving and (rush or (not exhausted and stamina > 0.0))
	is_sprinting = sprint
	is_moving = moving
	is_crouching = crouch
	_update_stamina(dt, sprint, rush)

	eye = lerpf(eye, CROUCH_H if crouch else STAND_H, minf(1.0, dt * 10.0))
	(shape.shape as CapsuleShape3D).height = eye + 0.1
	shape.position.y = (eye + 0.1) / 2.0

	var speed := SPEED * (SPRINT_MULT if sprint else (CROUCH_MULT if crouch else 1.0))
	speed *= 1.0 + ADR_BOOST * adrenaline
	var wish := (transform.basis * Vector3(dir.x, 0, dir.y)).normalized() * speed
	var rate := ACCEL_AIR
	if is_on_floor():
		rate = ACCEL_GROUND if moving else DECEL_GROUND
	velocity.x = move_toward(velocity.x, wish.x, rate * speed * dt)
	velocity.z = move_toward(velocity.z, wish.z, rate * speed * dt)

	var space := _key(KEY_SPACE)
	if space and not space_prev:
		jump_buffer = JUMP_BUFFER
	space_prev = space
	jump_buffer = maxf(0.0, jump_buffer - dt)
	coyote = COYOTE_TIME if is_on_floor() else maxf(0.0, coyote - dt)
	if (space or jump_buffer > 0.0) and coyote > 0.0:
		velocity.y = JUMP_SPEED
		jump_buffer = 0.0
		coyote = 0.0
		jumped.emit()
	elif not is_on_floor():
		velocity.y -= GRAVITY * dt
	last_vy = velocity.y
	move_and_slide()
	# Landing: both feet down, thud scales with the drop
	if is_on_floor():
		if was_airborne and air_time > 0.15 and last_vy < -2.0:
			var strength := minf(1.0, absf(last_vy) / 12.0)
			landed.emit(strength)
			land_dip = 0.04 + 0.10 * strength
			footsteps.step(true, false, 1.0)
		was_airborne = false
		air_time = 0.0
	else:
		was_airborne = true
		air_time += dt
	if torch:
		torch.update(dt, flash_on and not dead, is_sprinting, is_moving, bob)
	if shadow_body:
		shadow_body.update(is_moving, is_sprinting, is_crouching, dead, Vector2(velocity.x, velocity.z).length())
	_update_flashlight(dt)
	_update_sanity(dt)
	_update_head(dt, dir, sprint, crouch, moving)

	# fell down a pit: the picture dissolves into static and you come to at the spawn, no hard cut
	if global_position.y < -30.0 and not Death.respawn_busy:
		Death.respawn_transition(_back_to_spawn)

# Stamina: 30 s of sprint, brief rest delay, exhaustion until it recovers a bit
## Noclip (editor test launch): free flight along the camera, straight through walls and floors.
## WASD move, Space up, C/Ctrl down, Shift fast.
func _fly(dt: float) -> void:
	shape.disabled = true
	var dir := Vector3.ZERO
	if _key(KEY_W) or _key(KEY_UP): dir.z -= 1
	if _key(KEY_S) or _key(KEY_DOWN): dir.z += 1
	if _key(KEY_A) or _key(KEY_LEFT): dir.x -= 1
	if _key(KEY_D) or _key(KEY_RIGHT): dir.x += 1
	var wish := cam.global_transform.basis * dir
	if _key(KEY_SPACE): wish.y += 1.0
	if _key(KEY_C) or _key(KEY_CTRL): wish.y -= 1.0
	velocity = Vector3.ZERO
	is_moving = false
	is_sprinting = false
	global_position += wish.normalized() * (18.0 if _key(KEY_SHIFT) else 7.0) * dt

func _update_stamina(dt: float, sprint: bool, rush: bool) -> void:
	if rush:
		exhausted = false
		stamina = maxf(stamina, 60.0)
		rest_timer = 0.6
	elif sprint:
		stamina = maxf(0.0, stamina - dt * 100.0 / SPRINT_SECONDS)
		rest_timer = 0.6
		if stamina <= 0.0: exhausted = true
	else:
		rest_timer = maxf(0.0, rest_timer - dt)
		if rest_timer == 0.0: stamina = minf(100.0, stamina + STAMINA_REGEN * dt)
		if exhausted and stamina >= 15.0: exhausted = false

# Head bob + footfalls (web updateHeadBob): a step lands at the bottom of each bob. The bob, the lean
# and the landing dip are scaled by the head-bob setting; the footfalls keep their rhythm regardless.
func _update_head(dt: float, dir: Vector2, sprint: bool, crouch: bool, moving: bool) -> void:
	var horiz := Vector2(velocity.x, velocity.z).length()
	var walking := moving and horiz > 0.3
	var y := eye
	if not is_on_floor():
		pass                                  # no bob while airborne
	elif not walking:
		if was_stepping:
			was_stepping = false
			if not step_triggered:
				footsteps.step(false, crouch, 0.5)   # trailing foot comes down softly
				handheld.step(0.5, false)
		handheld.settle()
		bob += dt * 1.5
		y = eye + sin(bob) * 0.012 * head_bob
	else:
		was_stepping = true
		var freq := 12.0 if sprint else (6.0 if crouch else 8.5)
		bob += dt * freq
		var b := sin(bob)
		bob_amp = lerpf(bob_amp, handheld.step_amp, minf(1.0, dt * 8.0))    # no two steps the same height
		y = eye + b * (0.07 if sprint else 0.035) * head_bob * bob_amp
		if b < -0.85 and not step_triggered:
			step_triggered = true
			footsteps.step(sprint, crouch, 1.0)
			handheld.step(0.6 if crouch else 1.0, sprint)
		elif b > 0.0:
			step_triggered = false
	land_dip *= exp(-dt * 9.0)
	# the floor shaking under something heavy: a short low rumble, not a wobble. Squared so light steps
	# barely register and the close ones hit; scaled by the head-bob setting like the rest of the motion.
	quake_amt *= exp(-dt * 5.5)
	quake_t += dt
	var qk := quake_amt * quake_amt * head_bob
	var qx := (sin(quake_t * 31.0) + 0.6 * sin(quake_t * 53.0 + 1.7)) * 0.625
	var qy := (sin(quake_t * 37.0 + 0.4) + 0.6 * sin(quake_t * 61.0 + 2.9)) * 0.625
	cam.position = Vector3(qx * 0.025 * qk, y - land_dip * head_bob + qy * 0.035 * qk, 0.0)
	var lean_target := -dir.x * (LEAN_SPRINT if sprint else LEAN_WALK) * head_bob if walking else 0.0
	lean = lerpf(lean, lean_target, minf(1.0, dt * 7.0))
	# turning banks the view into the turn (smoothed mouse yaw rate); rate is in rad/s
	var yaw_rate := turn_accum / maxf(dt, 0.0001)
	turn_accum = 0.0
	var pitch_rate := pitch_accum / maxf(dt, 0.0001)
	pitch_accum = 0.0
	# the camcorder in your hands: it shakes more out of breath or with your heart pounding
	var shake := 1.0 + adrenaline * 1.5 + (1.0 if exhausted else 0.0)
	handheld.update(dt, yaw_rate, pitch_rate, shake, head_bob)
	cam.position += handheld.offset
	cam.rotation.y = handheld.yaw
	turn_roll = lerpf(turn_roll, clampf(yaw_rate * 0.012, -TURN_ROLL_MAX, TURN_ROLL_MAX), minf(1.0, dt * 6.0))
	# idle: after a moment of standing still the view drifts in a slow breathing sway
	idle_time = 0.0 if (moving or not is_on_floor()) else idle_time + dt
	idle_amt = lerpf(idle_amt, clampf((idle_time - 1.0) / 1.5, 0.0, 1.0), minf(1.0, dt * 2.0))
	var sway_z := (sin(idle_time * 0.55) * 0.010 + sin(idle_time * 0.9 + 1.3) * 0.005) * idle_amt
	var sway_x := (sin(idle_time * 0.42 + 0.7) * 0.007 + sin(idle_time * 0.77) * 0.003) * idle_amt
	cam.rotation.z = lean + (turn_roll + sway_z) * head_bob + qy * 0.01 * qk + handheld.roll
	# pitch: dip into forward motion, rise on the jump, nose down while falling. Added on top of the
	# mouse pitch as an offset (previous offset removed first) so aiming and other readers stay intact.
	var fwd := -velocity.dot(global_transform.basis.z)
	var pitch_target := -clampf(fwd / SPEED, -1.0, 1.6) * 0.018
	if not is_on_floor():
		pitch_target += clampf(velocity.y * 0.008, -0.07, 0.05)
	pitch_target = (pitch_target + sway_x) * head_bob
	pitch_off = lerpf(pitch_off, pitch_target, minf(1.0, dt * 6.0))
	var pitch_total := pitch_off + qx * 0.006 * qk + handheld.pitch
	cam.rotation.x = clampf(cam.rotation.x - pitch_applied + pitch_total, -1.49, 1.49)
	pitch_applied = pitch_total
	# FOV: the base, +2.5 sprinting, +2 in the air (web updateFov), wider on adrenaline
	var fov_target := (2.5 if sprint else 0.0) + (2.0 if not is_on_floor() else 0.0)
	fov_kick += (fov_target - fov_kick) * minf(1.0, 9.0 * dt)
	cam.fov = base_fov + fov_kick + ADR_FOV * adrenaline

## How far your footsteps carry right now (the entity's hearing multiplies by this)
func step_noise() -> float:
	return footsteps.noise() if footsteps else 1.0

# Something heavy landed nearby (the bacteria's footfalls in a chase): the view dips with the floor
func jolt(amount: float) -> void:
	land_dip = maxf(land_dip, clampf(amount, 0.0, 1.0) * 0.035)

# The floor shaking under something heavy nearby: 0..1, the view rumbles and settles
func quake(amount: float) -> void:
	quake_amt = maxf(quake_amt, clampf(amount, 0.0, 1.0))

# Adrenaline: the bacteria calls this every frame with whether it is hunting you close by
func update_adrenaline(dt: float, hunted: bool) -> void:
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
	was_airborne = false
	air_time = 0.0

## How lit the spot you stand on is: the level's tubes in the backrooms, the sky (day / night cycle) outdoors
func ambient_light() -> float:
	if Game.outdoors:
		return Game.day_light
	return level.tube_light_at(global_position) if level != null else 1.0

# ---- per-frame flashlight: battery drain, low-battery dimming/flicker, aim with slight lag ----
func _update_flashlight(dt: float) -> void:
	if flash_on:
		battery = maxf(0.0, battery - BATTERY_DRAIN * (0.25 if grid_down else 1.0) * dt)
		if battery <= 0.0:
			flash_on = false
			battery_died.emit()
	var k := 1.0
	if battery < BATTERY_LOW:
		var ratio := maxf(0.12, battery / BATTERY_LOW)
		k *= 0.35 + 0.65 * ratio
		if randf() < (0.32 if battery < BATTERY_CRIT else 0.10):
			k *= 0.05 + randf() * 0.45
	k *= _contact_flicker(dt)
	# Dark adaptation: in deep darkness your pupils open up and the beam reads brighter and crisper
	var lvl := ambient_light()
	var dark_boost := lerpf(1.35, 1.0, clampf(lvl, 0.0, 1.0))
	var lit := flash_on and not dead
	flash.light_energy = FLASH_ENERGY_HOTSPOT * k * dark_boost if lit else 0.0
	flash.visible = lit
	if flash_spill:
		flash_spill.light_energy = FLASH_ENERGY_SPILL * k * dark_boost if lit else 0.0
		flash_spill.visible = lit
	# The beam rides the torch in your hand: it leaves from the lens, and drops with the arm when you
	# sprint (and as the arm comes up), instead of staying welded to the eye.
	var dip_target := 0.0
	if torch != null:
		dip_target = torch.lower * 0.28 + (1.0 - torch.raise) * 0.5
	beam_tilt = lerpf(beam_tilt, clampf(dip_target, 0.0, BEAM_TILT_MAX), minf(1.0, 6.0 * dt))
	var lens := cam.global_position
	if torch != null and torch.visible:
		lens = torch.global_transform.origin - torch.global_transform.basis.z * TorchModel.LENGTH
	# Eased so the light can't jump the half-metre when the lens crosses from clear air into a wall.
	# Over 2 m away is a teleport (respawn, level change), not a step: snap rather than fly across it.
	var where := _lens_clear_of_walls(cam.global_position, lens)
	beam_pos = where if beam_pos.distance_to(where) > 2.0 else beam_pos.lerp(where, minf(1.0, 25.0 * dt))
	flash.global_position = beam_pos
	var fwd := -cam.global_transform.basis.z * 16.0
	var want := beam_pos + fwd.rotated(cam.global_transform.basis.x, -beam_tilt)
	flash_target = flash_target.lerp(want, minf(1.0, 14.0 * dt))
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

## The torch stutters for `secs` seconds (an event, or something big coming close)
func trigger_flicker(secs: float) -> void:
	flash_flicker.timer = 0.0
	flash_flicker.active = true
	flash_flicker.step = 0.0
	flicker_left = maxf(flicker_left, secs)

# Loose contact: long steady stretches, then a burst of dropouts
func _contact_flicker(dt: float) -> float:
	var fl := flash_flicker
	fl.timer -= dt
	if fl.timer > 0.0: return 1.0
	if not fl.active:
		fl.active = true
		fl.step = 0.0
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
	var ambient := ambient_light()
	var torch_lit := flash_on and battery > 0.0
	light_level = lerpf(light_level, ambient, minf(1.0, dt * 3.0))
	if sanity_lock >= 0.0:
		sanity = sanity_lock                      # debug console: `sanity <n>` pins it
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
		sanity = maxf(0.0, sanity - (1.0 + dark_ratio * 4.5) * creep * (1.4 if grid_down else 1.0) * dt)
	else:
		dark_time = maxf(0.0, dark_time - dt)                  # dim but not black: neither gain nor loss
	_update_mind(dt)

# A slipping mind hurts. Below HURT_SANITY the body starts to fail (faster the lower it goes), the
# picture smears and doubles (insanity, read by the post shader) and the heart runs. Recovering
# sanity stops the bleed, and health then creeps back once you are properly calm again.
func _update_mind(dt: float) -> void:
	var target := clampf((INSANE_BELOW - sanity) / INSANE_BELOW, 0.0, 1.0)
	insanity += (target - insanity) * minf(1.0, dt * 1.5)
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
