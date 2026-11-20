extends RefCounted
## Snapshot interpolation (gafferongames.com/post/snapshot_interpolation, Valve's entity interpolation):
## every snapshot carries the SENDER's clock. We draw the remote object a short delay in the past,
## between the two snapshots around that moment, so it follows the exact path it took (round
## corners, not through them) at an even pace however bursty the network is. When the stream stalls it
## holds the last known spot, except a `continuous` one (survivors: they send every step, so a gap is only a
## late packet, not a monster standing still that the host stopped repeating) carries on along its last
## heading for up to one send interval first, instead of freezing.
##
## The delay adapts to the connection: ~1.5 send intervals plus a margin for the jitter measured
## (a Cloudflare tunnel is TCP, so late packets arrive in bursts rather than getting lost). It grows
## quickly when packets start coming late and shrinks slowly once they don't; a continuous stream that
## still runs dry (a stall is what shows) adds to it.

const TELEPORT := 4.0           # metres between two snapshots: it was moved (respawn, summon), don't slide
const MIN_DELAY := 0.05
const MAX_DELAY := 0.45
const KEEP := 64
const SLEW := 0.03              # the drawn clock may run at most 3% fast while it catches up: no visible jumps
const SLEW_UP := 0.10           # ...and up to 10% slow while the delay grows (packets came late: get ahead of the next stall)
const STALL_GROW := 2.5         # continuous: s of extra delay per s spent drawing more than an interval past the newest snapshot
const STALL_EASE := 0.05        # ...given back this fast once the stream is steady again

var snaps: Array = []           # [{t, pos, yaw, ...}] oldest first
var send_interval := 1.0 / 30.0  # the sender's rate (Net.SEND_INTERVAL)
var continuous := false         # the sender sends every step (survivors), so a gap means lateness: run on, and widen the delay
var _stall := 0.0               # extra delay owed to recent stalls, eases off
var _target_off := 0.0          # local clock - remote clock, tracked from the fastest recent arrivals
var _offset := 0.0              # what we actually use: slews toward _target_off
var _jitter := 0.02
var _delay := 0.12
var _have_offset := false

static func now() -> float:
	return Time.get_ticks_usec() / 1000000.0

func push(t: float, s: Dictionary) -> void:
	var sample := now() - t
	if not _have_offset:
		_target_off = sample
		_offset = sample
		_have_offset = true
	elif sample < _target_off:
		_target_off = sample                               # a faster packet: less latency than we thought
	else:
		_target_off += (sample - _target_off) * 0.01       # slowly follow a latency rise / clock drift
	_jitter += (absf(sample - _target_off) - _jitter) * 0.1
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
	_stall = maxf(0.0, _stall - dt * STALL_EASE)
	var target := clampf(send_interval * 1.5 + _jitter * 2.5 + 0.015 + _stall, MIN_DELAY, MAX_DELAY)
	_delay += clampf(target - _delay, -SLEW * dt, SLEW_UP * dt)
	var step := SLEW * dt
	if absf(_target_off - _offset) > 1.0:
		_offset = _target_off                                # a huge gap (hitch, clock reset): just jump
	else:
		_offset += clampf(_target_off - _offset, -step, step)
	var rt := now() - _offset - _delay                       # the remote moment we are drawing
	# drop what is too old to be needed (keep one snapshot before rt)
	while snaps.size() > 2 and snaps[1].t <= rt:
		snaps.pop_front()
	var a: Dictionary = snaps[0]
	if snaps.size() == 1 or rt <= a.t:
		return a.duplicate()
	var b: Dictionary = snaps[1]
	if rt >= b.t:
		# we are drawing past the newest snapshot: hold (continuous: run on a moment, and widen the delay)
		var out_b := b.duplicate()
		if not continuous:
			return out_b
		var over: float = rt - float(b.t)
		if over > send_interval:
			_stall = minf(MAX_DELAY, _stall + (over - send_interval) * STALL_GROW * dt)
		var gap: float = b.t - a.t
		if gap > 0.0001 and gap < send_interval * 4.0 and (b.pos as Vector3).distance_to(a.pos) < TELEPORT:
			out_b.pos = (b.pos as Vector3) + ((b.pos as Vector3) - (a.pos as Vector3)) / gap * minf(over, send_interval)
		return out_b
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

## Latest known position, for entities that must react to where they are now rather than drawn
func latest() -> Dictionary:
	return {} if snaps.is_empty() else snaps[-1]
