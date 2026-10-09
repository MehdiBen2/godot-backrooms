extends RefCounted
## Randomised carry for the walking camera, so the bob never repeats the same way twice. A person holding a
## camera doesn't move like a metronome: each footfall lands a little differently, the pace drifts, and every
## so often they settle into another way of carrying it (chest-high and bouncy, shoulder-held and rocking,
## quick and nodding, tired and low). player.gd multiplies its bob by these values.
##
## Styles are held for HOLD_MIN..HOLD_MAX seconds, then blend over BLEND seconds, so a switch reads as the
## operator resettling rather than a jump. Each footfall also gets a small random kick (JITTER) on top.
## With variation off every value is 1.0, which leaves the steady bob the game had before.

const VARIANTS := [
	{"height": 1.0, "side": 1.0, "roll": 1.0, "nod": 1.0, "pace": 1.0},      # steady
	{"height": 1.15, "side": 0.8, "roll": 0.9, "nod": 1.2, "pace": 1.05},     # chest-high, bouncy
	{"height": 0.85, "side": 1.4, "roll": 1.5, "nod": 0.7, "pace": 0.95},    # shoulder-held, rocks side to side
	{"height": 1.1, "side": 0.9, "roll": 0.6, "nod": 1.4, "pace": 1.1},      # quick, nodding
	{"height": 0.7, "side": 0.6, "roll": 0.5, "nod": 0.6, "pace": 0.9},      # tired, low and steady
]
const KEYS := ["height", "side", "roll", "nod", "pace"]
const JITTER := {"height": 0.12, "side": 0.16, "roll": 0.15, "nod": 0.12, "pace": 0.04}   # +- per footfall
const HOLD_MIN := 14.0            # s a carry style lasts, at least...
const HOLD_MAX := 40.0            # ...and at most
const BLEND := 2.5                # s to ease into a new style
const KICK_RISE := 8.0            # 1/s: how fast a footfall's kick eases in and out

var _rng := RandomNumberGenerator.new()
var _style := 0
var _hold := 0.0
var _cur := {}                    # eased style values
var _kick := {}                   # eased per-footfall values
var _goal := {}                   # the kick this footfall wants

func _init() -> void:
	_rng.randomize()
	_style = _rng.randi() % VARIANTS.size()    # every session starts in a different carry
	_hold = _rng.randf_range(HOLD_MIN, HOLD_MAX)
	for k in KEYS:
		_cur[k] = VARIANTS[_style][k]
		_kick[k] = 1.0
		_goal[k] = 1.0

## One frame. on: the camera-variation setting. walking: kicks only show while on the move.
func update(dt: float, on: bool, walking: bool) -> void:
	_hold -= dt
	if _hold <= 0.0:
		_style = (_style + _rng.randi_range(1, VARIANTS.size() - 1)) % VARIANTS.size()    # never the same style twice running
		_hold = _rng.randf_range(HOLD_MIN, HOLD_MAX)
	var blend := 1.0 - exp(-dt / BLEND)
	var kick_blend := minf(1.0, dt * KICK_RISE)
	for k in KEYS:
		var target: float = VARIANTS[_style][k] if on else 1.0
		_cur[k] = lerpf(_cur[k], target, blend)
		_kick[k] = lerpf(_kick[k], _goal[k] if (on and walking) else 1.0, kick_blend)

## The multiplier for one part of the bob (see KEYS): the carry style times this footfall's kick
func mult(key: String) -> float:
	return _cur[key] * _kick[key]

## A footfall came down: the next stride gets its own small kick
func step() -> void:
	for k in KEYS:
		_goal[k] = 1.0 + _rng.randf_range(-JITTER[k], JITTER[k])
