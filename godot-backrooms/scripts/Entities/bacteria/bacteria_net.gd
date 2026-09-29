extends RefCounted
## THE BACTERIA in co-op. The host's copy runs the AI and broadcasts itself 20 times a second
## (Net.send_entity); on every other machine the entity is a puppet that glides after those snapshots.
## Its fear, sounds and the grab still play on each machine, against that machine's own player.

const SnapBuffer := preload("res://scripts/Net/snap_buffer.gd")
const SEND_INTERVAL := 0.05

var e: Node3D                          # bacteria.gd
var buf = SnapBuffer.new()
var have := false
var speed := 0.0
var state := "roam"
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
	var fid := 0
	if e.focus != null and is_instance_valid(e.focus):
		fid = e.multiplayer.get_unique_id() if e.focus == e.player else Net.id_of(e.focus)
	var p: Vector3 = e.global_position
	var c: Vector3 = e.stalk_corner
	var wn: Vector3 = e.stalk_wall_n
	var sd: Vector3 = e.stalk_side
	Net.send_entity([p.x, p.z, e.yaw, maxi(0, e.STATES.find(e.state)), e.speed_now,
		e.lunge, e.lunge_windup, e.peek_amt, e.staring, e.seen_target, fid, e.process_mode != Node.PROCESS_MODE_DISABLED,
		e.peek_dir, c.x, c.z, wn.x, wn.z, sd.x, sd.z])

## Guest: the host's latest snapshot (Net._entity)
func apply(t: float, m: Array) -> void:
	buf.push(t, {"pos": Vector3(m[0], 0.0, m[1]), "yaw": float(m[2]), "speed": float(m[4]), "m": m})

## Guest: take up the host's pose and state for this frame
func step(delta: float) -> void:
	var st: Dictionary = buf.sample(delta)
	if st.is_empty():
		return
	var m: Array = st.m
	have = true
	e.global_position = st.pos
	e.yaw = st.yaw
	speed = st.speed
	state = e.STATES[clampi(int(m[3]), 0, e.STATES.size() - 1)]
	e.lunge = m[5]
	e.lunge_windup = m[6]
	e.peek_amt = m[7]
	e.staring = m[8]
	e.seen_target = m[9]
	e.focus = e.player if int(m[10]) == e.multiplayer.get_unique_id() else Net.remotes.get(int(m[10]))
	e.visible = m[11]
	# its corner: the rig hooks the same hand round the same edge here
	e.peek_dir = m[12]
	e.stalk_corner = Vector3(m[13], 0.0, m[14])
	e.stalk_wall_n = Vector3(m[15], 0.0, m[16])
	e.stalk_side = Vector3(m[17], 0.0, m[18])
