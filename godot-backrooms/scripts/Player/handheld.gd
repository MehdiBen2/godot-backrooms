extends RefCounted
## The camera as a camcorder held in someone's hands (found-footage feel). Everything here is an offset
## added on top of where you aim; the aim itself is never delayed or moved, so mouse look stays exact.
##
## Real handheld shake is layered (a slow sway of the operator's body and arms, small corrections, and a
## fast hand tremor, together spanning about 1-10 Hz) and gets stronger and rougher when walking and running.
## Motion sickness comes mostly from 0.5-2 Hz, sideways panning at 0.35-1 Hz worst, so the big layers are
## kept out of that band: the sway is slow (~0.2 Hz), the corrections small, the tremor fast (~8 Hz).
##
##   sway        slow drift of pitch / yaw / roll, about +-0.5 deg standing, more when moving
##   correction  the operator's small, quicker re-aims (+-0.1 deg)
##   tremor      fast hand shake (+-0.05 deg), more when out of breath
##   steps       each footfall dips and rolls the camera differently, eased in and out
##
## player.gd feeds it footfalls and how hard you move, and reads `pitch`, `yaw`, `roll` (rad) and `offset` (m).
## Scaled by the head-bob setting: 0 turns all of it off; AMOUNT scales everything.

const AMOUNT := 1.5               # 1.0 = about 1 deg of sway standing; lower it for less
# layers: amplitude (rad) and noise speed (roughly Hz)
const SWAY_PITCH := 0.012
const SWAY_YAW := 0.009
const SWAY_ROLL := 0.010
const SWAY_SPEED := 0.2
const CORRECT := 0.0025
const CORRECT_SPEED := 2.2
const TREMOR := 0.001
const TREMOR_SPEED := 8.0
# footfalls
const STEP_PITCH := 0.010         # rad: the dip as the foot takes the weight
const STEP_ROLL := 0.008          # rad: a lean onto that foot
const STEP_SIDE := 0.012          # m: the body shifting over the foot
const STEP_RISE := 14.0           # 1/s: how fast a step's dip eases in
const STEP_FALL := 5.0            # 1/s: and eases back out

var pitch := 0.0
var yaw := 0.0
var roll := 0.0
var offset := Vector3.ZERO
var step_amp := 1.0               # this step's bob height (player.gd multiplies its vertical bob by it)

var _motion := 0.0                # eased: 0 standing, 1 walking, ~1.8 sprinting
var _step_goal := Vector2.ZERO    # (pitch, roll) this step wants, fading out
var _step := Vector2.ZERO
var _side := 0.0
var _side_goal := 0.0
var _foot := 1.0
var _t := 0.0
var _noise := FastNoiseLite.new()
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_rng.randomize()
	_noise.seed = _rng.randi()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 1.0

func _n(row: float, speed: float) -> float:
	return _noise.get_noise_2d(_t * speed, row * 31.0)

## One frame. motion: 0 standing, 1 walking, 1.8 sprinting. shake: 1 normal, more when out of breath or
## on adrenaline. amount: the head-bob setting (0..1).
func update(dt: float, motion: float, shake: float, amount: float) -> void:
	_t += dt
	_motion = lerpf(_motion, motion, minf(1.0, dt * 3.0))
	var sway := 1.0 + 0.7 * _motion
	var corr := 1.0 + 1.2 * _motion
	var trem := shake * (1.0 + 0.8 * _motion)
	var p := _n(1.0, SWAY_SPEED) * SWAY_PITCH * sway + _n(2.0, CORRECT_SPEED) * CORRECT * corr + _n(3.0, TREMOR_SPEED) * TREMOR * trem
	var y := _n(4.0, SWAY_SPEED * 0.8) * SWAY_YAW * sway + _n(5.0, CORRECT_SPEED * 0.9) * CORRECT * corr + _n(6.0, TREMOR_SPEED * 1.1) * TREMOR * trem
	var r := _n(7.0, SWAY_SPEED * 0.7) * SWAY_ROLL * sway + _n(8.0, CORRECT_SPEED * 0.8) * CORRECT * corr + _n(9.0, TREMOR_SPEED * 0.9) * TREMOR * trem
	_step_goal *= exp(-dt * STEP_FALL)
	_step = _step.lerp(_step_goal, minf(1.0, dt * STEP_RISE))
	_side = lerpf(_side, _side_goal, minf(1.0, dt * 4.0))
	var k := amount * AMOUNT
	pitch = (p + _step.x) * k
	yaw = y * k
	roll = (r + _step.y) * k
	offset = Vector3(_side * k, 0.0, 0.0)

## A foot came down. weight: 0..1 (a soft trailing step is less), run: sprinting
func step(weight: float, run: bool) -> void:
	_foot = -_foot
	var w := weight * (1.5 if run else 1.0)
	_step_goal = Vector2(_rng.randf_range(0.6, 1.0) * STEP_PITCH, _foot * _rng.randf_range(0.5, 1.0) * STEP_ROLL) * w
	_side_goal = _foot * STEP_SIDE * _rng.randf_range(0.7, 1.1) * (1.3 if run else 1.0)
	step_amp = _rng.randf_range(0.85, 1.15)

## Standing still: the weight shifts back to the middle
func settle() -> void:
	_side_goal = 0.0
