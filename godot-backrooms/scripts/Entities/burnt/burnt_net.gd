extends RefCounted
## THE BURNT in co-op (as grabber_net.gd). The host's copy runs the brain and broadcasts itself 20 times a second
## (Net.send_burnt); everywhere else it is a puppet that glides after those snapshots and poses itself from the
## same state. Whoever it takes plays the whole sequence (hug, lift, stare, corrupt) on their own machine, told
## by Net.send_burnt_take; the host holds it still meanwhile, and the end comes back through Net.send_burnt_result.

const SnapBuffer := preload("res://scripts/Net/snap_buffer.gd")
const SEND_INTERVAL := 0.05

var e: Node3D                          # burnt.gd
var buf = SnapBuffer.new()
var _t := 0.0

func _init(entity: Node3D) -> void:
	e = entity
	buf.send_interval = SEND_INTERVAL

## Host: what it is doing, for everyone else
func send(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = SEND_INTERVAL
	var p: Vector3 = e.global_position
	Net.send_burnt([p.x, p.y, p.z, e.yaw, maxi(0, e.STATES.find(e.state)), e.t, e._walk, e.present])

## Guest: the host's latest snapshot (Net._world)
func apply(t: float, m: Array) -> void:
	if m.size() < 8:
		return
	buf.push(t, {"pos": Vector3(m[0], m[1], m[2]), "yaw": float(m[3]), "m": m})

## Guest: take up the host's place and state for this frame
func step(delta: float) -> void:
	var st: Dictionary = buf.sample(delta)
	if st.is_empty():
		return
	var m: Array = st.m
	var here := bool(m[7])
	if here and not e.present:
		if e.body == null and not e._build():
			return
		e.present = true
	elif not here and e.present:
		e._despawn_quietly()
		return
	if not here:
		return
	e.visible = Net.host_here()                       # the host's floor, not ours: it isn't in our halls
	e.global_position = st.pos
	e.yaw = st.yaw
	e.rotation.y = e.yaw
	var s: String = e.STATES[clampi(int(m[4]), 0, e.STATES.size() - 1)]
	e.state = "grab" if s == "hug" else s             # (the hug's arms are aimed at the victim's own camera)
	e.t = float(m[5])
	e._walk = float(m[6])
