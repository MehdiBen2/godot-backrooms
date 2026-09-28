extends Node
## The player's blink: the lids sweep shut, hold, and open again (Game.fx_blink, drawn by the post
## shader). Whatever should not survive a blink (the eyes down the corridor) is swapped out at the
## instant the lids meet: connect to `closed`. Child of the player (player.blink).
##
## Timed like a real one: about a third of a second, the lids snapping shut faster than they open,
## and opening with a long settle at the end. `slow` above 1 is a tired blink (the mannequins' stare):
## everything slows a little and the lids stay down much longer, and now and then it comes as a
## double blink, the lids dropping again before they are fully up.

signal closed

const CLOSE := 0.1               # s, lids down
const HOLD := 0.08               # s, shut
const OPEN := 0.24               # s, lids up (slower, with a settle)
const TIRED_HOLD := 0.35         # extra s shut per unit of `slow` over 1
const DOUBLE_CHANCE := 0.3       # a tired blink's chance of a second, quick one

var _t := -1.0
var _slow := 1.0
var _close := CLOSE
var _hold := HOLD
var _open := OPEN
var _from := 0.0                 # how shut the lids were when this blink started (a double blink)
var _again := false

func blink(slow := 1.0) -> void:
	if _t >= 0.0:
		return
	_start(maxf(0.2, slow), 0.0)
	_again = _slow > 1.3 and randf() < DOUBLE_CHANCE

func blinking() -> bool:
	return _t >= 0.0

func _start(slow: float, from: float) -> void:
	_t = 0.0
	_slow = slow
	_from = from
	_close = CLOSE * sqrt(slow)
	_hold = HOLD * slow + maxf(0.0, slow - 1.0) * TIRED_HOLD
	_open = OPEN * slow

func _process(dt: float) -> void:
	if _t < 0.0:
		return
	var was := _t
	_t += dt
	# the shut moment always gets its frame and its signal, even when a slow frame jumps past it
	if was < _close and _t >= _close:
		_t = _close
		closed.emit()
	if _t < _close:
		var u := _t / _close
		Game.fx_blink = lerpf(_from, 1.0, u * u * (3.0 - 2.0 * u))
	elif _t < _close + _hold:
		Game.fx_blink = 1.0
	elif _t < _close + _hold + _open:
		var v := (_t - _close - _hold) / _open
		Game.fx_blink = pow(1.0 - v, 2.5)       # quick off the mark, then a slow settle
		if _again and v > 0.45:                  # tired: down again before they are fully up
			_again = false
			_start(randf_range(0.8, 1.0), Game.fx_blink)
	else:
		Game.fx_blink = 0.0
		_t = -1.0
