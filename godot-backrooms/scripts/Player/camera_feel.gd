class_name CameraFeel
extends Resource
## The view's weight: it rolls into a strafe and banks into a quick turn, pitches with your speed and with
## speeding up or braking, tips up on the way up a jump and down on the way down, dips and springs back on
## landing, drifts in a slow figure-eight / Perlin sway once you stand still long enough, and shakes under
## trauma (add_trauma). player.gd feeds it the body's motion each physics tick and adds roll / pitch / yaw on
## top of the mouse look (pitch as an offset it takes off again the next tick), so aiming is never touched.
##
## Every effect has its own multiplier: 1 = as tuned, 0 = off, negative = the other way round. The motion
## offsets ride on damped springs (implicit Euler, stable at any frame rate and tick length), so they ease back
## to 0 when the motion stops and run into each other without seams. The shake is added after the springs, so
## they don't smooth it away.

@export_group("Intensity")
@export var intensity := 1.0         ## everything below at once
@export var strafe_roll := 1.0       ## roll into a sideways step
@export var turn_roll := 1.0         ## bank into a quick mouse turn
@export var move_pitch := 1.0        ## nose down going forward, up going back
@export var accel_pitch := 1.0       ## nose down speeding up, up braking
@export var vertical_pitch := 1.0    ## up on the rise of a jump, down falling
@export var landing_dip := 1.0       ## the nod and spring back as you land
@export var idle_sway := 1.0         ## the drift standing still
@export var trauma_shake := 1.0      ## add_trauma's shake and kick

@export_group("Springs")
@export var roll_hz := 1.6           ## how quickly the roll follows (Hz)
@export var roll_damping := 0.8      ## 1 = no overshoot, lower = it swings past and settles
@export var pitch_hz := 1.6
@export var pitch_damping := 0.7

@export_group("Idle")
@export var idle_delay := 1.5        ## s standing still, not looking around, before the sway comes in
@export var idle_blend := 1.5        ## s for it to come in fully
@export var idle_speed := 1.0        ## the sway's pace

@export_group("Trauma")
@export var trauma_decay := 1.1      ## trauma lost per second (1 = a full hit dies away in a second)
@export var trauma_speed := 16.0     ## the shake's pace

# rad at multiplier 1
const STRAFE_ROLL := 0.010           # per walking speed of sideways velocity (0.0175 at a sprint)
const TURN_ROLL := 0.012             # per rad/s of mouse turn...
const TURN_ROLL_MAX := 0.045         # ...and no further
const MOVE_PITCH := 0.018            # per walking speed forward
const ACCEL_PITCH := 0.012           # per ACCEL_REF of forward acceleration
const ACCEL_REF := 16.0              # m/s^2 (player.gd ACCEL_GROUND)
const RISE_PITCH := 0.008            # per m/s up or down, airborne...
const RISE_MAX := 0.05               # ...up to this nose up...
const FALL_MAX := 0.07               # ...and this nose down
const LAND_KICK := 0.25              # rad/s down into the pitch spring on the lightest landing...
const LAND_KICK_HEAVY := 0.6         # ...and this much more on the heaviest
const IDLE_ROLL := 0.012
const IDLE_PITCH := 0.008
const LOOK_STILL := 0.05             # rad/s of mouse movement under which you count as not looking around
const SHAKE := Vector3(0.05, 0.04, 0.06)   # pitch, yaw, roll at full trauma
const KICK := 1.2                    # rad/s into the springs per unit of directional trauma

var roll := 0.0                      # the result, rad: rotation.z...
var pitch := 0.0                     # ...an offset on rotation.x...
var yaw := 0.0                       # ...and rotation.y (only the shake turns the view)

var _roll := Vector2.ZERO            # spring: x = angle, y = angular velocity
var _pitch := Vector2.ZERO
var _prev_vel := Vector3.ZERO
var _acc := 0.0                      # eased forward acceleration (m/s^2)
var _idle_time := 0.0
var _idle := 0.0                     # 0..1 eased: how much of the sway is in
var _t := 0.0                        # runs on, so the sway never jumps back to its start
var _trauma := 0.0
var _noise := FastNoiseLite.new()

func _init() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise.frequency = 1.0
	_noise.seed = randi()

## One physics tick. vel: the body's velocity (world). basis: the body's facing (yaw only). ref_speed: walking
## speed, the scale for the speed-led effects. yaw_rate / pitch_rate: the mouse look this tick (rad/s).
func update(dt: float, vel: Vector3, basis: Basis, on_floor: bool, moving: bool, ref_speed: float,
		yaw_rate: float, pitch_rate: float) -> void:
	if dt <= 0.0: return
	_t += dt
	var local := basis.inverse() * vel
	var speed := maxf(ref_speed, 0.01)

	# forward acceleration from the horizontal velocity's change (turning swings it sideways, not forward)
	var dv := vel - _prev_vel
	_prev_vel = vel
	dv.y = 0.0
	var fwd_acc := clampf(dv.dot(-basis.z) / dt, -ACCEL_REF * 2.0, ACCEL_REF * 2.0)
	_acc = lerpf(_acc, fwd_acc, 1.0 - exp(-dt * 10.0))

	var roll_goal := -clampf(local.x / speed, -2.0, 2.0) * STRAFE_ROLL * strafe_roll
	roll_goal += clampf(yaw_rate * TURN_ROLL, -TURN_ROLL_MAX, TURN_ROLL_MAX) * turn_roll
	var pitch_goal := clampf(local.z / speed, -1.6, 1.0) * MOVE_PITCH * move_pitch    # local -z is forward
	pitch_goal -= clampf(_acc / ACCEL_REF, -1.0, 1.0) * ACCEL_PITCH * accel_pitch
	if not on_floor:
		pitch_goal += clampf(vel.y * RISE_PITCH, -FALL_MAX, RISE_MAX) * vertical_pitch

	# idle: no walking, no looking around, feet down
	var still := on_floor and not moving and absf(yaw_rate) + absf(pitch_rate) < LOOK_STILL
	_idle_time = _idle_time + dt if still else 0.0
	var idle_goal := smoothstep(0.0, 1.0, (_idle_time - idle_delay) / maxf(idle_blend, 0.01))
	_idle = lerpf(_idle, idle_goal, 1.0 - exp(-dt * (1.5 if idle_goal > _idle else 4.0)))
	if _idle > 0.0001:
		# a slow figure-eight (roll : pitch at 1 : 2) wandered off its line by Perlin noise
		var s := _t * idle_speed
		var sway_r := sin(s * 0.5) * 0.65 + _noise.get_noise_2d(s * 0.23, 11.0) * 0.6
		var sway_p := sin(s * 1.0 + 0.4) * 0.5 + _noise.get_noise_2d(s * 0.31, 47.0) * 0.6
		roll_goal += sway_r * IDLE_ROLL * _idle * idle_sway
		pitch_goal += sway_p * IDLE_PITCH * _idle * idle_sway

	_roll = _spring(_roll, roll_goal * intensity, roll_hz, roll_damping, dt)
	_pitch = _spring(_pitch, pitch_goal * intensity, pitch_hz, pitch_damping, dt)

	_trauma = maxf(0.0, _trauma - trauma_decay * dt)
	var shake := _trauma * _trauma * trauma_shake * intensity     # squared: light hits barely register
	var n := _t * trauma_speed
	pitch = _pitch.x + _noise.get_noise_2d(n, 101.0) * SHAKE.x * shake
	yaw = _noise.get_noise_2d(n, 211.0) * SHAKE.y * shake
	roll = _roll.x + _noise.get_noise_2d(n, 307.0) * SHAKE.z * shake

## Feet back on the ground after a fall. strength 0..1, light to heavy.
func land(strength: float) -> void:
	_pitch.y -= (LAND_KICK + LAND_KICK_HEAVY * clampf(strength, 0.0, 1.0)) * landing_dip * intensity

## Shake the view: amount 0..1 adds to the trauma (capped at 1). push: the way the hit throws the head, camera
## space (x right, y up, z back), its length scaling the kick; zero for a shake with no direction.
func add_trauma(amount: float, push := Vector3.ZERO) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)
	var k := amount * KICK * trauma_shake * intensity
	_roll.y -= push.x * k            # thrown right, the head tips right
	_pitch.y += push.z * k           # thrown back, the nose goes up

## Respawned or teleported: everything back to rest, so the jump in velocity doesn't read as a lurch
func reset() -> void:
	_roll = Vector2.ZERO
	_pitch = Vector2.ZERO
	_prev_vel = Vector3.ZERO
	_acc = 0.0
	_idle_time = 0.0
	_idle = 0.0
	_trauma = 0.0
	roll = 0.0
	pitch = 0.0
	yaw = 0.0

# A damped spring toward goal (s.x angle, s.y its velocity), by implicit Euler: stable for any dt
static func _spring(s: Vector2, goal: float, hz: float, damping: float, dt: float) -> Vector2:
	var w := TAU * maxf(hz, 0.0)
	var k := w * w
	var v := (s.y + dt * k * (goal - s.x)) / (1.0 + dt * 2.0 * damping * w + dt * dt * k)
	return Vector2(s.x + v * dt, v)
