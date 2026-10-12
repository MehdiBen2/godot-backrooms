extends RefCounted
## The still mannequins filling the room (the decoys): drawn with one MultiMesh per body part, so the
## whole crowd costs a handful of draw calls, and solid where they stand.
##
## Only ever while you are looking away from them, the crowd shifts. Of the decoys nearest you, ONE
## creeps toward you a little at a time (the same one, so it really is closing in); the others just
## trade places with each other. Turn back and the room is not quite as you left it.

const MannequinModel := preload("res://scripts/Entities/mannequin/mannequin_model.gd")
const MMBuffer := preload("res://scripts/World/mm_buffer.gd")
const SHUFFLE_POOL := 10                     # the this-many standing decoys nearest you take part
const SHUFFLE_RANGE := 16.0
const STALK_STEP := 0.9
const STALK_MIN_DIST := 2.2                  # it never crowds closer than this by itself
const VARIANT_CHANCE := 0.32                 # of the standing decoys, how many wear a plain sculpt (any one of them)
# Walking decoys: still figures that start stepping toward you (the real one's own stride, the same footsteps)
# when you catch it on the move, and sometimes on their own. They never kill, and they stop a few metres off.
const MAX_WALKERS := 2
const WALK_LIFE := 12.0                      # s a walker keeps coming before it gives up and stands still
const WALK_STOP_DIST := 2.6                  # it stops this close to you
const WALK_RANGE := 26.0                     # ...or gives up when you are further than this
const WALK_CHANCE_MIN := 10.0                # s between the walkers that start on their own
const WALK_CHANCE_MAX := 18.0

var m: Node3D                                # mannequin.gd
var decoys: Array = []                       # {x, z, yaw, pose, g, body, variant}
var mms: Array = []                          # one MultiMesh per model part
var variant_mm: MultiMesh                    # one MultiMesh for the plain variant sculpt (whole figure)
var shufflers: Array = []                    # {i, seen}: every standing decoy
var stalker := -1                            # decoy index of the one that creeps toward you
var tick := 0.0
var cooldown := 4.0
var _blink_used := false
var walkers: Array = []                      # {i, life, t, dur, moving, stepped, step_idx, from, to, yaw_from, yaw_to, pose_from, pose_to}
var walk_cd := 12.0

func _init(owner: Node3D) -> void:
	m = owner

func build(dealt: Array) -> void:
	decoys = dealt
	mms.clear()
	variant_mm = null
	var model: MannequinModel = m.model
	var count := decoys.size()
	var bufs: Array[PackedFloat32Array] = []   # one flat instance buffer per part, uploaded once at the end
	for pt in model.parts:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = pt.mesh
		mm.instance_count = count
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		m.add_child(mmi)
		mms.append(mm)
		bufs.append(MMBuffer.alloc(mm))  # zeroed = a zero-scale transform: every slot starts hidden
	var vbuf := PackedFloat32Array()
	if model.variant_ok and not model.variant_rigged:     # rigged variants are posed copies of their own
		variant_mm = MultiMesh.new()
		variant_mm.transform_format = MultiMesh.TRANSFORM_3D
		variant_mm.mesh = model.variant_mesh
		variant_mm.instance_count = count
		vbuf = MMBuffer.alloc(variant_mm)   # unused slots stay zero: hidden (identity would stack them all at the origin)
		var vmmi := MultiMeshInstance3D.new()
		vmmi.multimesh = variant_mm
		m.add_child(vmmi)
	for i in count:
		var d: Dictionary = decoys[i]
		var g := Transform3D(Basis(Vector3.UP, d.yaw), Vector3(d.x, 0.0, d.z))
		var mode: String = d.pose.get("mode", "stand")
		# the variant sculpt stands (it is one piece: no lying / sitting base poses), but in the decoy's own pose
		var is_variant: bool = model.variant_ok and mode == "stand" and m.rng.randf() < VARIANT_CHANCE
		d["variant"] = is_variant
		if is_variant:
			var vidx: int = m.rng.randi() % model.variant_count()   # which sculpt this decoy wears
			d["vidx"] = vidx
			d["g"] = g                       # its part slots stay zero (hidden)
			var vn := model.make_variant(d.pose, MannequinModel.variant_style(m.rng), vidx)
			if vn != null:                   # rigged: its own posed copy
				vn.transform = g * model.variant_root_xf_at(vidx)
				m.add_child(vn)
				d["vnode"] = vn
			else:                            # no rig: the shared mesh at rest
				MMBuffer.put(vbuf, i * 12, g * model.variant_xf_at(vidx))
		else:
			var xfs := model.part_transforms(d.pose)
			var base := MannequinModel.mode_base(mode, m.rng)
			d["g"] = g * base
			for j in model.parts.size():
				MMBuffer.put(bufs[j], i * 12, g * base * xfs[j])
		# they are solid (lying ones stay walk-over-able)
		if mode != "stand" and mode != "sit":
			continue
		var body := StaticBody3D.new()
		# Its own layer, off the level-geometry layer (1): a flying blood blob's raycast (mask 1) would
		# otherwise treat this body-height cylinder as a splatterable surface, gluing a decal to its
		# invisible collision shape well above the (much thinner) visible figure - blood stuck floating
		# by the head. See player.gd's collision_mask, widened to still bump into these.
		body.collision_layer = 2
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = m.RADIUS
		cyl.height = MannequinModel.HEIGHT
		cs.shape = cyl
		cs.position.y = MannequinModel.HEIGHT / 2.0
		body.add_child(cs)
		body.position = Vector3(d.x, 0.0, d.z)
		m.add_child(body)
		d["body"] = body
	for j in mms.size():
		(mms[j] as MultiMesh).buffer = bufs[j]
	if variant_mm != null:
		variant_mm.buffer = vbuf
	shufflers.clear()
	stalker = -1
	for i in decoys.size():
		if decoys[i].pose.get("mode", "stand") == "stand":
			shufflers.append({"i": i, "seen": false})

func _head_pos(x: float, z: float) -> Vector3:
	return Vector3(x, MannequinModel.HEIGHT * 0.8, z)

# Move decoy i to (x, z) facing `yaw`: its figure, its collision body and the record the real one avoids
func _place(i: int, x: float, z: float, yaw: float) -> void:
	var d: Dictionary = decoys[i]
	d.x = x
	d.z = z
	d.yaw = yaw
	d.g = Transform3D(Basis(Vector3.UP, yaw), Vector3(x, 0.0, z))
	if d.get("variant", false):
		var vidx: int = d.get("vidx", 0)
		var vn = d.get("vnode")
		if vn != null and is_instance_valid(vn):
			(vn as Node3D).transform = d.g * m.model.variant_root_xf_at(vidx)
		else:
			variant_mm.set_instance_transform(i, d.g * m.model.variant_xf_at(vidx))
	else:
		var xfs: Array = m.model.part_transforms(d.pose)
		for j in xfs.size():
			(mms[j] as MultiMesh).set_instance_transform(i, d.g * xfs[j])
	var body = d.get("body")
	if body != null and is_instance_valid(body):
		(body as Node3D).position = Vector3(x, 0.0, z)

func update(delta: float) -> void:
	_walk(delta)
	tick += delta
	if tick < 0.1:
		return
	var dt := tick
	tick = 0.0
	var player: Node3D = m.player
	if player == null or not is_instance_valid(player):
		return
	var pp := player.global_position

	# Early-out if the player is far from the mannequin room
	if m.room_box.size != Vector2i.ZERO:
		var rc := Vector3((m.room_box.position.x + m.room_box.size.x * 0.5) * m.CELL, 0.0, (m.room_box.position.y + m.room_box.size.y * 0.5) * m.CELL)
		var max_r: float = maxf(m.room_box.size.x, m.room_box.size.y) * m.CELL * 0.5 + SHUFFLE_RANGE + 4.0
		if pp.distance_squared_to(rc) > max_r * max_r:
			return

	var cam: Camera3D = player.cam
	var pool := shufflers.duplicate()
	pool.sort_custom(func(a, b):
		var da: Dictionary = decoys[a.i]
		var db: Dictionary = decoys[b.i]
		return Vector2(da.x - pp.x, da.z - pp.z).length_squared() < Vector2(db.x - pp.x, db.z - pp.z).length_squared())
	pool = pool.slice(0, SHUFFLE_POOL)
	# note which of them you have had on screen, and which are off it right now
	var hidden: Array = []
	for s in pool:
		var d: Dictionary = decoys[s.i]
		if is_walking(s.i) or pp.distance_to(Vector3(d.x, 0.0, d.z)) > SHUFFLE_RANGE:
			continue
		if cam.is_position_in_frustum(_head_pos(d.x, d.z)) and not m.eyes_shut():
			s.seen = true
		elif s.seen:
			hidden.append(s.i)
	cooldown -= dt
	# a blink is a free move: the moment the lids meet, the crowd shifts (once per blink)
	if m.eyes_shut():
		if not _blink_used:
			_blink_used = true
			cooldown = 0.0
	else:
		_blink_used = false
	if cooldown > 0.0 or hidden.is_empty():
		return
	cooldown = m.rng.randf_range(3.0, 8.0)
	# the one that closes in
	if stalker < 0:
		stalker = hidden[m.rng.randi() % hidden.size()]
	if hidden.has(stalker):
		var d: Dictionary = decoys[stalker]
		var to := Vector2(pp.x - d.x, pp.z - d.z)
		var dist := to.length()
		if dist > STALK_MIN_DIST + STALK_STEP:
			var step := to / dist * STALK_STEP
			var np: Vector3 = m.nav.resolve(Vector3(d.x + step.x, 0.0, d.z + step.y), m.RADIUS)
			if _spot_free(np, stalker) and not cam.is_position_in_frustum(_head_pos(np.x, np.z)):
				_place(stalker, np.x, np.z, atan2(pp.x - np.x, pp.z - np.z))
		hidden.erase(stalker)
	# everyone else just trades places, two or three pairs at a time
	hidden.shuffle()
	var pairs := mini(hidden.size() / 2, m.rng.randi_range(1, 3))
	for k in pairs:
		var a: Dictionary = decoys[hidden[k * 2]]
		var b: Dictionary = decoys[hidden[k * 2 + 1]]
		var ax: float = a.x
		var az: float = a.z
		_place(hidden[k * 2], b.x, b.z, a.yaw)
		_place(hidden[k * 2 + 1], ax, az, b.yaw)

func is_walking(i: int) -> bool:
	for w in walkers:
		if w.i == i:
			return true
	return false

## A still decoy that can be walked: standing, and a jointed figure (the rigged or plain sculpts can't be posed here)
func _walkable(i: int) -> bool:
	var d: Dictionary = decoys[i]
	return d.pose.get("mode", "stand") == "stand" and not d.get("variant", false) and not is_walking(i)

## You caught it on the move: it stops, and `count` of the still ones near it take up the chase. They only move
## while unseen, like it does, so which one is coming is something you have to work out. Ones in view are picked
## first, so the player has to look away from the very figures that may start walking.
func handoff(near: Vector3, count: int) -> void:
	var cam: Camera3D = m.player.cam
	var seen_c := []
	var other := []
	for i in decoys.size():
		if not _walkable(i):
			continue
		var d: Dictionary = decoys[i]
		var dd := Vector2(d.x - near.x, d.z - near.z).length()
		if dd < 1.0 or dd > 14.0:
			continue
		if cam.is_position_in_frustum(_head_pos(d.x, d.z)):
			seen_c.append(i)
		else:
			other.append(i)
	var pool := seen_c if not seen_c.is_empty() else other
	while count > 0 and not pool.is_empty() and walkers.size() < MAX_WALKERS:
		var pick: int = pool[m.rng.randi() % pool.size()]
		pool.erase(pick)
		_start_walk(pick)
		count -= 1

func _start_walk(i: int) -> void:
	var d: Dictionary = decoys[i]
	var w := {"i": i, "life": WALK_LIFE, "t": 0.0, "dur": 0.0, "moving": false, "stepped": false, "step_idx": 0,
		"from": Vector2(d.x, d.z), "to": Vector2(d.x, d.z), "yaw_from": d.yaw, "yaw_to": d.yaw,
		"pose_from": d.pose.duplicate(), "pose_to": d.pose.duplicate()}
	walkers.append(w)
	if not _next_step(w):
		walkers.erase(w)

## Plan the next stride toward the player. False when it has got as close as it means to (or is blocked).
func _next_step(w: Dictionary) -> bool:
	var d: Dictionary = decoys[w.i]
	var player: Node3D = m.player
	var pp := player.global_position
	var from := Vector2(d.x, d.z)
	var to_p := Vector2(pp.x - from.x, pp.z - from.y)
	var dist := to_p.length()
	if dist < WALK_STOP_DIST:
		return false
	# round corners the way the real one does (the next cell on the way to you when there is no straight line)
	var way: Vector3 = m.step_target(Vector3(from.x, 0.0, from.y), Vector3(pp.x, 0.0, pp.z))
	var to_w := Vector2(way.x - from.x, way.z - from.y)
	var wd := maxf(to_w.length(), 0.001)
	if wd < 0.05:
		return false                                      # no way to you from here: it stands where it is
	var step := to_w / wd * maxf(0.15, minf(minf(m.STEP_LENGTH, wd), dist - WALK_STOP_DIST + 0.2))
	var np: Vector3 = m.nav.resolve(Vector3(from.x + step.x, 0.0, from.y + step.y), m.RADIUS)
	# never through a wall: no clear line to where the stride lands, no stride
	if not m.nav.clear_line(from.x, from.y, np.x, np.z, 0.2) or not _spot_free(np, w.i):
		return false
	w.step_idx += 1
	w.from = from
	w.to = Vector2(np.x, np.z)
	w.pose_from = d.pose.duplicate()
	w.yaw_from = d.yaw
	w.yaw_to = atan2(pp.x - np.x, pp.z - np.z)
	var flip := 1.0 if w.step_idx % 2 == 1 else -1.0
	var pose := MannequinModel.step_pose(m.rng, flip, dist)
	pose["mode"] = "stand"
	w.pose_to = pose
	w.dur = m.STEP_TIME * m.rng.randf_range(0.85, 1.15)
	w.t = 0.0
	w.stepped = false
	w.moving = true
	return true

func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

## Each walker: the same stop-motion stride as the real one (pose snaps, then the body lurches as the foot lands),
## and a footfall. Runs every frame, so the stride keeps its timing.
func _walk(delta: float) -> void:
	if walkers.is_empty():
		_maybe_start_walk(delta)
		return
	var player: Node3D = m.player
	if player == null or not is_instance_valid(player):
		return
	var pp := player.global_position
	for w in walkers.duplicate():
		var d: Dictionary = decoys[w.i]
		# like the real one, it only moves while nobody is looking at it (a blink counts as not looking)
		if m.seen(Vector3(d.x, 0.0, d.z)):
			continue
		w.life -= delta
		if w.life <= 0.0 or pp.distance_to(Vector3(d.x, 0.0, d.z)) > WALK_RANGE:
			walkers.erase(w)
			continue
		w.t += delta
		var snap_k := _smooth(w.t / 0.11)
		var p := {"mode": "stand"}
		for k in MannequinModel.POSE_KEYS:
			p[k] = lerpf(w.pose_from[k], w.pose_to[k], snap_k)
		d.pose = p
		var mv := 1.0 - pow(1.0 - clampf(w.t / (w.dur * 0.4), 0.0, 1.0), 3.0)
		var np: Vector2 = w.from.lerp(w.to, mv)
		var yaw := lerpf(w.yaw_from, w.yaw_to, snap_k)
		_place(w.i, np.x, np.y, yaw)
		if not w.stepped and w.t > 0.05:
			w.stepped = true
			var dd := Vector2(pp.x - np.x, pp.z - np.y).length()
			var close := maxf(0.0, 1.0 - dd / 28.0)
			m.scares.mannequin_step(Vector3(np.x, 0.05, np.y), (0.45 + close * 0.95) * m.LOUDNESS)
		if w.t >= w.dur and not _next_step(w):
			walkers.erase(w)

## Now and then a still one starts walking on its own, so the chase is not always started by you looking
func _maybe_start_walk(delta: float) -> void:
	if m.real_node == null or not m.awake:
		return
	walk_cd -= delta
	if walk_cd > 0.0:
		return
	walk_cd = m.rng.randf_range(WALK_CHANCE_MIN, WALK_CHANCE_MAX)
	handoff(m.real_node.position, 1)

# Clear floor for a decoy: not on top of another decoy, the real one, or you
func _spot_free(p: Vector3, self_i: int) -> bool:
	var mn: float = m.RADIUS * 2.2
	for i in decoys.size():
		if i == self_i:
			continue
		var o: Dictionary = decoys[i]
		if Vector2(o.x - p.x, o.z - p.z).length() < mn:
			return false
	var real: Node3D = m.real_node
	if real != null and Vector2(real.position.x - p.x, real.position.z - p.z).length() < mn:
		return false
	return Vector2(m.player.global_position.x - p.x, m.player.global_position.z - p.z).length() > 1.5
