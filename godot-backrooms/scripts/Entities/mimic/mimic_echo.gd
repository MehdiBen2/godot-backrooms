extends RefCounted
## THE MIMIC's memory (mimic.gd): where every survivor has been. RATE times a second, for the last KEEP
## seconds, it notes each one's feet, facing, look pitch, crouch and torch, from what the host already
## knows (the local player, and the snapshots every guest sends, remote_player.gd). The Mimic walks
## these routes back later, in real time: stopping where they stopped, crouching where they crouched,
## looking where they looked, torch on where theirs was.
## A survivor missing for a while (dead, in the menu, loading) leaves a cut in their track: the Mimic
## never walks across one.

const RATE := 0.25               # s between samples
const KEEP := 240.0              # s of history kept per survivor
const CUT_GAP := 1.0             # s without a sample: the next one starts a new stretch

var tracks := {}                 # survivor id -> Array of samples, oldest first
var _acc := 0.0

## Host: note where everyone is, every RATE seconds. `t`: the Mimic's game-time clock (mimic.gd echo_clock).
func record(dt: float, t: float) -> void:
	_acc -= dt
	if _acc > 0.0:
		return
	_acc = RATE
	for s in Net.survivors():
		var n: Node = s.node
		var yaw: float
		var pitch: float
		var crouch: bool
		var torch: bool
		if s.local:
			yaw = n.rotation.y
			pitch = n.cam.rotation.x
			crouch = n.is_crouching
			torch = n.flash_on and n.battery > 0.0
		else:
			yaw = n.target_yaw
			pitch = n.target_pitch
			crouch = n.crouching
			torch = n.torch_on
		var tr: Array = tracks.get(s.id, [])
		var cut: bool = tr.is_empty() or t - float(tr[-1].t) > CUT_GAP
		# heading: which way the body faces, in the Mimic's convention (atan2(dx, dz), the model faces +Z)
		tr.append({"t": t, "p": s.pos, "h": wrapf(yaw + PI, -PI, PI), "pitch": pitch, "crouch": crouch, "torch": torch, "cut": cut})
		while not tr.is_empty() and t - float(tr[0].t) > KEEP:
			tr.pop_front()
		tracks[s.id] = tr

func track(id: int) -> Array:
	return tracks.get(id, [])

## Seconds of unbroken track the longest-remembered survivor has
func longest_span() -> float:
	var best := 0.0
	for id in tracks:
		var tr: Array = tracks[id]
		if tr.size() > 1:
			best = maxf(best, float(tr[-1].t) - float(tr[0].t))
	return best

## Last sample at or before `t` (binary search), -1 before the track starts
func index_at(tr: Array, t: float) -> int:
	var lo := 0
	var hi := tr.size() - 1
	if hi < 0 or t < float(tr[0].t):
		return -1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if float(tr[mid].t) <= t:
			lo = mid
		else:
			hi = mid - 1
	return lo

## Where they were at `t`, eased between samples: {p, h, pitch, crouch, torch, speed, end}. `end` when
## the track runs out or reaches a cut: it holds the last pose there, standing.
func sample(tr: Array, t: float) -> Dictionary:
	var i := index_at(tr, t)
	if i < 0:
		return {}
	var a: Dictionary = tr[i]
	if i + 1 >= tr.size() or tr[i + 1].cut:
		return {"p": a.p, "h": a.h, "pitch": a.pitch, "crouch": a.crouch, "torch": a.torch, "speed": 0.0, "end": true}
	var b: Dictionary = tr[i + 1]
	var span := maxf(float(b.t) - float(a.t), 0.001)
	var k := clampf((t - float(a.t)) / span, 0.0, 1.0)
	var pa: Vector3 = a.p
	var pb: Vector3 = b.p
	var flat := Vector2(pb.x - pa.x, pb.z - pa.z).length()
	return {"p": pa.lerp(pb, k), "h": lerp_angle(float(a.h), float(b.h), k), "pitch": lerpf(a.pitch, b.pitch, k),
		"crouch": a.crouch, "torch": a.torch, "speed": flat / span, "end": false}
