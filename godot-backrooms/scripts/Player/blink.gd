extends Node
## The player's blink: the lids sweep shut, hold, and open again (Game.fx_blink, drawn by the post
## shader). Whatever should not survive a blink (the eyes down the corridor) is swapped out at the
## instant the lids meet: connect to `closed`. Child of the player (player.blink).

signal closed

const CLOSE := 0.17
const HOLD := 0.16
const OPEN := 0.45

var _t := -1.0
var _slow := 1.0

func blink(slow := 1.0) -> void:
	if _t >= 0.0:
		return
	_t = 0.0
	_slow = maxf(0.2, slow)

func blinking() -> bool:
	return _t >= 0.0

func _process(dt: float) -> void:
	if _t < 0.0:
		return
	var was := _t
	_t += dt / _slow
	if _t < CLOSE:
		var u := _t / CLOSE
		Game.fx_blink = u * u * (3.0 - 2.0 * u)
	elif _t < CLOSE + HOLD:
		Game.fx_blink = 1.0
		if was < CLOSE:
			closed.emit()
	elif _t < CLOSE + HOLD + OPEN:
		var v := (_t - CLOSE - HOLD) / OPEN
		Game.fx_blink = 1.0 - v * v * (3.0 - 2.0 * v)
	else:
		Game.fx_blink = 0.0
		_t = -1.0
