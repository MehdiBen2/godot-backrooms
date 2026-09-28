extends RefCounted
## The phosphor glow's unsteadiness, shared by the TAB terminal (inventory.gd) and the HUD's CRT
## layers (crt_layer.gd): a faint shimmer all the time and, every few seconds, a short stutter where
## the glow jumps between dim and over-bright, now and then dropping out for a frame. Stutters come
## up to four times as often as something closes in (Game.terror, which also drives the terminal's
## LINK STATUS). update() returns the multiplier for the glow strength this frame.

const SHIMMER := 0.06            # constant unsteadiness (fraction of the glow)
const GAP := Vector2(2.5, 7.0)   # seconds between stutters, at calm
const LENGTH := Vector2(0.12, 0.55)   # how long one stutter lasts

var level := 1.0                 # eased toward target
var target := 1.0
var burst := 0.0                 # seconds left in the current stutter
var step := 0.0                  # seconds until the stutter jumps to a new level
var next := 3.0
var t := 0.0

func update(dt: float) -> float:
	t += dt
	if burst > 0.0:
		burst -= dt
		step -= dt
		if step <= 0.0:
			step = randf_range(0.03, 0.09)
			target = 0.0 if randf() < 0.2 else randf_range(0.2, 1.35)
		if burst <= 0.0:
			target = 1.0
	else:
		next -= dt * (1.0 + 3.0 * Game.terror)
		if next <= 0.0:
			kick(randf_range(LENGTH.x, LENGTH.y))
	# steps land almost at once (a flicker, not a fade), just not in a single hard frame
	level = lerpf(level, target, minf(1.0, dt * 35.0))
	return level * (1.0 + SHIMMER * (0.6 * sin(t * 47.0) + 0.4 * sin(t * 13.3 + 1.7)))

## Start a stutter now; `from_dark` also drops the glow to nothing first (a tube warming up)
func kick(length: float, from_dark := false) -> void:
	burst = maxf(burst, length)
	step = 0.0
	next = randf_range(GAP.x, GAP.y)
	if from_dark:
		level = 0.0
