extends RefCounted
## The camera as a camcorder held in someone's hands (found-footage feel). Everything here is an offset
## added on top of where you aim, never a change to the aim itself, so mouse look stays exact:
##
##   weight     the camera trails a little behind a turn and overshoots when you stop, like a real mass on
##              a wrist (an underdamped spring driven by how fast you turn / look up and down)
##   tremor     a constant, never-repeating hand shake and a slow breathing sway, even standing still;
##              stronger when you are out of breath or on adrenaline
##   steps      every footfall kicks the camera a little differently (height, side, roll), so the walk bob
##              is uneven like a person's, not a sine wave
##
## player.gd feeds it the turn rates and footfalls and reads `pitch`, `yaw`, `roll` (rad) and `offset` (m).
## Scaled by the head-bob setting: 0 turns all of it off.

# weight: how far the camera trails per rad/s of turning, and its spring (Hz, damping ratio < 1 overshoots)
const LAG_YAW := 0.022
const LAG_PITCH := 0.018
const LAG_MAX := 0.06
const SPRING_HZ := 2.3
const SPRING_DAMP := 0.42
# tremor (rad): fast hand shake, slow breathing, and a slower wander of where the hands settle
const TREMOR := 0.0011
const BREATH := 0.0032
const WANDER := 0.0045
# footfalls: random kick sizes
const STEP_ROLL := 0.010
const STEP_PITCH := 0.006
const STEP_YAW := 0.004
const STEP_SIDE := 0.012          # metres of side-to-side shift per step
const STEP_KICK_DECAY := 7.0

var pitch := 0.0
var yaw := 0.0
var roll := 0.0
var offset := Vector3.ZERO
var step_amp := 1.0               # this step's bob height (player.gd multiplies its vertical bob by it)

var _lag := Vector2.ZERO          # (yaw, pitch) spring position
var _lag_v := Vector2.ZERO
var _kick := Vector3.ZERO         # footfall kick (pitch, yaw, roll), decaying
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

## One frame. yaw_rate / pitch_rate: how fast you are turning (rad/s). shake: 1 normal, more when
## exhausted or scared. amount: the head-bob setting (0..1).
func update(dt: float, yaw_rate: float, pitch_rate: float, shake: float, amount: float) -> void:
	_t += dt
	# weight: the spring chases a lag proportional to the turn rate; when the turn stops the target drops
	# to zero and the spring swings past it before settling
	var goal := Vector2(clampf(-yaw_rate * LAG_YAW, -LAG_MAX, LAG_MAX), clampf(-pitch_rate * LAG_PITCH, -LAG_MAX, LAG_MAX))
	var w := TAU * SPRING_HZ
	_lag_v += ((goal - _lag) * w * w - _lag_v * 2.0 * SPRING_DAMP * w) * dt
	_lag += _lag_v * dt
	# tremor: three layers of noise at different speeds (separate noise rows per axis so they don't move together)
	var n := func(row: float, speed: float) -> float: return _noise.get_noise_2d(_t * speed, row * 37.0)
	var tp: float = n.call(1.0, 7.0) * TREMOR * shake + n.call(2.0, 0.28) * BREATH + n.call(3.0, 0.07) * WANDER
	var ty: float = n.call(4.0, 6.0) * TREMOR * shake + n.call(5.0, 0.09) * WANDER
	var tr: float = n.call(6.0, 5.0) * TREMOR * shake + n.call(7.0, 0.22) * BREATH * 0.8
	# footfalls: kicks decay, the side shift eases toward whichever foot is down
	_kick *= exp(-dt * STEP_KICK_DECAY)
	_side = lerpf(_side, _side_goal, minf(1.0, dt * 6.0))
	pitch = (_lag.y + tp + _kick.x) * amount
	yaw = (_lag.x + ty + _kick.y) * amount
	roll = (tr + _kick.z) * amount
	offset = Vector3(_side, 0.0, 0.0) * amount

## A foot came down. weight: 0..1 (a soft trailing step is less), run: sprinting
func step(weight: float, run: bool) -> void:
	_foot = -_foot
	var k := weight * (1.6 if run else 1.0)
	_kick += Vector3(_rng.randf_range(0.4, 1.0) * STEP_PITCH, _rng.randf_range(-1.0, 1.0) * STEP_YAW,
		_foot * _rng.randf_range(0.5, 1.0) * STEP_ROLL) * k
	_side_goal = _foot * STEP_SIDE * _rng.randf_range(0.6, 1.2) * (1.4 if run else 1.0)
	step_amp = _rng.randf_range(0.75, 1.25)

## Standing still: the weight shifts back to the middle
func settle() -> void:
	_side_goal = 0.0
