extends RefCounted
## THE GRABBER in co-op (as bacteria_net.gd). The host's copy runs the brain and broadcasts itself 20 times a
## second (Net.send_grabber); everywhere else it is a puppet that glides after those snapshots and plays the
## same clip at the same point. Whoever it takes plays the drag on their own machine (grabber_drag.gd), told by
## Net.send_grabber_grab; how it ended comes back to the host through Net.send_grabber_result.

const SnapBuffer := preload("res://scripts/Net/snap_buffer.gd")
const SEND_INTERVAL := 0.05
const RESYNC := 0.3                    # s: the clip drifted this far from the host's, jump to it

var e: Node3D                          # grabber.gd
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
	var b = e.body
	var clip_i: int = b.CLIPS.find(b.clip) if b != null else -1
	Net.send_grabber([p.x, p.y, p.z, e.yaw, maxi(0, e.STATES.find(e.state)), clip_i,
		b.time() if b != null else 0.0, b.anim.speed_scale if b != null and b.anim != null else 1.0,
		b.flip if b != null else 0.0, b.hang if b != null else 0.0, e.visible])

## Guest: the host's latest snapshot (Net._grabber_snap_rpc)
func apply(t: float, m: Array) -> void:
	buf.push(t, {"pos": Vector3(m[0], m[1], m[2]), "yaw": float(m[3]), "m": m})

## Guest: take up the host's place, state and clip for this frame
func step(delta: float) -> void:
	var st: Dictionary = buf.sample(delta)
	if st.is_empty():
		return
	var m: Array = st.m
	e.global_position = st.pos
	e.yaw = st.yaw
	e.rotation.y = e.yaw
	var s: String = e.STATES[clampi(int(m[4]), 0, e.STATES.size() - 1)]
	if s != e.state:
		e.state = s
		e.state_time = 0.0
	e.visible = bool(m[10])
	var b = e.body
	if b == null:
		return
	var ci := int(m[5])
	if ci >= 0 and ci < b.CLIPS.size():
		var c: String = b.CLIPS[ci]
		var host_t := float(m[6])
		if c != b.clip:
			b.restart(c, 0.15)
			b.seek(host_t)
		elif absf(b.time() - host_t) > RESYNC and host_t < b.length() - 0.05:
			b.seek(host_t)
		if b.anim != null:
			b.anim.speed_scale = float(m[7])
	b.flip = float(m[8])
	b.hang = float(m[9])
	b.pose_root()
