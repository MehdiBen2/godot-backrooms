extends RefCounted
## THE SHROUD in co-op (as tall_net.gd). The host's copy runs the brain and broadcasts itself SEND_RATE times a second
## (Net.send_shroud), every survivor's stare with it; everywhere else it is a puppet that glides after those
## snapshots and plays the same clip for the same state. Each guest reads its own stare out of the snapshot, so the
## tunnelling, the heartbeat, the failing torch and the drag on the view happen on their own screen. Whoever it takes
## plays the pull and the death scene on their own machine (Net.send_shroud_take); the host plays the kill clip in
## the world for everyone else and waits for Net.send_shroud_result.

const SnapBuffer := preload("res://scripts/Net/snap_buffer.gd")

var e: Node3D                          # shroud.gd
var buf = SnapBuffer.new()

func _init(entity: Node3D) -> void:
	e = entity
	buf.send_interval = Net.SEND_INTERVAL

## Host: what it is doing, and every survivor's stare (id, stare, id, stare, ...)
func send(delta: float) -> void:
	if not Net.send_tick:
		return                              # all snapshots go out together, on Net's send step
	var p: Vector3 = e.global_position
	var locks: Array = []
	for id in e._locks:
		locks.append(int(id))
		locks.append(snappedf(float(e._locks[id]), 0.01))
	Net.send_shroud([p.x, p.y, p.z, e.yaw, maxi(0, e.STATES.find(e.state)), e.t, e._speed, e.present, locks])

## Guest: the host's latest snapshot (Net._world)
func apply(t: float, m: Array) -> void:
	if m.size() < 9:
		return
	buf.push(t, {"pos": Vector3(m[0], m[1], m[2]), "yaw": float(m[3]), "m": m})

## Guest: take up the host's place and state for this frame
func step(_delta: float) -> void:
	var st: Dictionary = buf.sample(_delta)
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
	if s != e.state and s == "kill":
		e._clip = ""                                  # (the clip starts over at the snapshot's time)
	e.state = s
	e.t = float(m[5])
	e._speed = float(m[6])
	# this machine's own stare
	var me: int = e._local_id()
	var mine := 0.0
	var locks = m[8]
	if locks is Array:
		for i in range(0, (locks as Array).size() - 1, 2):
			if int(locks[i]) == me:
				mine = float(locks[i + 1])
				break
	e._set_lock(mine)
