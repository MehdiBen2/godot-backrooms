extends RefCounted
## Snapshot interpolation (gafferongames.com/post/snapshot_interpolation, Valve's entity interpolation):
## every snapshot carries the SENDER's clock. We draw the remote object a short delay in the past,
## between the two snapshots around that moment, so it follows the exact path it took (round
## corners, not through them) at an even pace however bursty the network is. No extrapolation:
## when the stream stalls it holds the last known spot rather than guessing into a wall.
##
## The delay adapts to the connection: ~1.5 send intervals plus a margin for the jitter measured
## (a Cloudflare tunnel is TCP, so late packets arrive in bursts rather than getting lost).

const TELEPORT := 4.0           # metres between two snapshots: it was moved (respawn, summon), don't slide
const MIN_DELAY := 0.07
const MAX_DELAY := 0.45
const KEEP := 64

var snaps: Array = []           # [{t, pos, yaw, ...}] oldest first
var send_interval := 0.05
var _offset := 0.0              # local clock - remote clock, tracked from the fastest recent arrivals
var _jitter := 0.02
var _delay := 0.12
var _have_offset := false

static func now() -> float:
	return Time.get_ticks_usec() / 1000000.0

func push(t: float, s: Dictionary) -> void:
	var sample := now() - t
	if not _have_offset:
		_offset = sample
		_have_offset = true
	elif sample < _offset:
		_offset = sample                                   # a faster packet: less latency than we thought
	else:
		_offset += (sample - _offset) * 0.01               # slowly follow a latency rise / clock drift
	_jitter += (absf(sample - _offset) - _jitter) * 0.1
	if not snaps.is_empty() and t <= snaps[-1].t:
		return                                              # stale or duplicate
	s.t = t
	snaps.append(s)
	if snaps.size() > KEEP:
		snaps.pop_front()

func is_empty() -> bool:
	return snaps.is_empty()

## Returns {pos, yaw, ...} for this frame (the older snapshot's other fields), or {} before the first one
func sample(dt: float) -> Dictionary:
	if snaps.is_empty():
		return {}
	var target := clampf(send_interval * 1.5 + _jitter * 2.5 + 0.02, MIN_DELAY, MAX_DELAY)
	_delay += (target - _delay) * minf(1.0, dt * 0.8)       # ease it so the picture never jumps
	var rt := now() - _offset - _delay                       # the remote moment we are drawing
	# drop what is too old to be needed (keep one snapshot before rt)
	while snaps.size() > 2 and snaps[1].t <= rt:
		snaps.pop_front()
	var a: Dictionary = snaps[0]
	if snaps.size() == 1 or rt <= a.t:
		return a.duplicate()
	var b: Dictionary = snaps[1]
	if rt >= b.t:
		return b.duplicate()                                 # stream stalled: hold, don't extrapolate
	if (b.pos as Vector3).distance_to(a.pos) > TELEPORT:
		return a.duplicate()                                 # snaps to b once rt passes it
	var k: float = (rt - a.t) / maxf(b.t - a.t, 0.0001)
	var out := a.duplicate()
	out.pos = (a.pos as Vector3).lerp(b.pos, k)
	out.yaw = lerp_angle(a.yaw, b.yaw, k)
	if a.has("pitch"):
		out.pitch = lerpf(a.pitch, b.pitch, k)
	if a.has("speed"):
		out.speed = lerpf(a.speed, b.speed, k)
	return out

## Latest known position, for AI that must react to where they are now rather than drawn
func latest() -> Dictionary:
	return {} if snaps.is_empty() else snaps[-1]
