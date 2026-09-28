extends RefCounted
## The camera as a camcorder held in someone's hands (found-footage feel), kept subtle on purpose. Every value
## is an offset added on top of where you aim; the aim itself is never delayed or moved.
##
## What causes motion sickness is motion around 0.5-2 Hz, horizontal panning at 0.35-1 Hz worst, so:
##   tremor   a tiny, fast (5-9 Hz) hand shake: reads as "held", far above the sickness band
##   wander   a very slow (< 0.15 Hz) drift of where the hands settle, pitch and roll only, never yaw
##   steps    each footfall dips and rolls the camera a little differently (no two steps alike), eased in
##            and out rather than kicked, and never sideways
## No mouse-driven lag or overshoot (that made the view wobble every time you moved the mouse), and no
## breathing sway (player.gd already has one when you stand still).
##
## player.gd feeds it the footfalls and reads `pitch`, `roll` (rad) and `offset` (m). Scaled by the head-bob
## setting: 0 turns all of it off.

const AMOUNT := 1.0               # master scale for all of it
# tremor (rad): fast and tiny
const TREMOR := 0.00035
const TREMOR_SPEED := 7.0
# wander (rad): slow settle of the hands
const WANDER := 0.0016
const WANDER_SPEED := 0.1
# footfalls
const STEP_PITCH := 0.0035        # rad: the dip as the foot takes the weight
const STEP_ROLL := 0.003          # rad: a little lean onto that foot
const STEP_SIDE := 0.005          # m: the body shifting over the foot
const STEP_RISE := 14.0           # 1/s: how fast a step's dip eases in
const STEP_FALL := 5.0            # 1/s: and eases back out

var pitch := 0.0
var yaw := 0.0                    # kept at 0 (no horizontal sway); left for player.gd
var roll := 0.0
var offset := Vector3.ZERO
var step_amp := 1.0               # this step's bob height (player.gd multiplies its vertical bob by it)

var _step_goal := Vector2.ZERO    # (pitch, roll) this step wants, fading out
var _step := Vector2.ZERO         # eased toward _step_goal
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

## One frame. shake: 1 normal, more when out of breath or on adrenaline. amount: the head-bob setting (0..1).
func update(dt: float, shake: float, amount: float) -> void:
	_t += dt
	var k := amount * AMOUNT
	# separate noise rows per axis so they don't move together
	var tp := _noise.get_noise_2d(_t * TREMOR_SPEED, 11.0) * TREMOR * shake + _noise.get_noise_2d(_t * WANDER_SPEED, 23.0) * WANDER
	var tr := _noise.get_noise_2d(_t * TREMOR_SPEED * 0.8, 37.0) * TREMOR * shake + _noise.get_noise_2d(_t * WANDER_SPEED * 0.7, 51.0) * WANDER * 0.8
	_step_goal *= exp(-dt * STEP_FALL)
	_step = _step.lerp(_step_goal, minf(1.0, dt * STEP_RISE))
	_side = lerpf(_side, _side_goal, minf(1.0, dt * 4.0))
	pitch = (tp + _step.x) * k
	roll = (tr + _step.y) * k
	yaw = 0.0
	offset = Vector3(_side * k, 0.0, 0.0)

## A foot came down. weight: 0..1 (a soft trailing step is less), run: sprinting
func step(weight: float, run: bool) -> void:
	_foot = -_foot
	var w := weight * (1.5 if run else 1.0)
	_step_goal = Vector2(_rng.randf_range(0.6, 1.0) * STEP_PITCH, _foot * _rng.randf_range(0.5, 1.0) * STEP_ROLL) * w
	_side_goal = _foot * STEP_SIDE * _rng.randf_range(0.7, 1.1) * (1.3 if run else 1.0)
	step_amp = _rng.randf_range(0.88, 1.12)

## Standing still: the weight shifts back to the middle
func settle() -> void:
	_side_goal = 0.0
