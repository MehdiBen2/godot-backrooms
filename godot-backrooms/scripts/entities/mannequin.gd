extends Node3D
## THE MANNEQUIN (js/game/mannequin.js). A room packed with still mannequins and one that is real.
## The real one only moves while you can't see it (a Weeping Angel), in stiff stop-motion steps; it
## hunts for 30 s, rests, and every third rest freezes for five minutes. It reaches you unseen and
## your neck is snapped.
##
## The model is a set of separate meshes (torso, head, eyes, two arms, two legs). Decoys are drawn
## with one MultiMesh per part (so 59 figures cost 7 draw calls); the real one has its own meshes
## and is re-posed on every step.
##
## Dev key: F2 warps you to the room.

const GridNav := preload("res://scripts/world/grid_nav.gd")
const CELL := 4.5
const MODEL := "res://models/entities/creepy_mannequin.glb"

# MANNEQUIN config (js/config.js)
const HEIGHT := 1.85
const COUNT := 60
const ROOM := Rect2i(33, 19, 8, 3)           # cell rectangle x0,z0 and size (x1 = 41, z1 = 22)
const SPACING := 1.5
const RADIUS := 0.34
const WAKE_DISTANCE := 17.0
const VIEW_RANGE := 30.0
const STEP_TIME := 0.34
const STEP_LENGTH := 1.05
const KILL_DISTANCE := 1.15
const HUNT_TIME := 30.0
const REST_TIME := 20.0
const LONG_PAUSE_EVERY := 3
const LONG_PAUSE_TIME := 300.0
const LOUDNESS := 1.0
const SNAP_AT := 2.3
const SNAP_TOTAL := 4.6

var level: Node
var player: CharacterBody3D
var scares: Node
var nav
var n := 0
var rng := RandomNumberGenerator.new()

# Exact joint pivots in normalized 1.76m mannequin space (computed from creepy_mannequin.glb)
const PIVOT_TORSO := Vector3(0.0, 0.818858, -0.099118)
const PIVOT_HEAD := Vector3(0.000199, 1.490816, -0.121748)
const PIVOT_ARM_L := Vector3(0.133415, 1.406008, -0.119121)
const PIVOT_ARM_R := Vector3(-0.132625, 1.405924, -0.118877)
const PIVOT_LEG_L := Vector3(0.082134, 0.8199, -0.099109)
const PIVOT_LEG_R := Vector3(-0.080462, 0.819955, -0.099065)
const HIP_HEIGHT := 0.8199

var parts: Array = []                        # {mesh, xf, kind, side}
var hip_pivot := PIVOT_TORSO
var norm_xf := Transform3D.IDENTITY          # model space -> figure space (feet on y = 0, HEIGHT tall)
var ready_ok := false

var decoys: Array = []                       # {x, z, yaw, pose}
var real_node: Node3D
var real_meshes: Array = []
var real_pose := {}
var real_yaw := 0.0
var hunt := {}
var awake := false
var moving := false
var rest_left := 0.0
var hunt_clock := 0.0
var rest_count := 0
var killed := false
var last_step_sound := 0.0
var flank_sign := 1.0
var flow := PackedInt32Array()

# snap sequence
var snap_active := false
var snap_t := 0.0
var snapped := false
var snap_beat := 0.0
var snap_twitch := 0.0
var snap_jerk := 0.0
var snap_start := Vector3.ZERO
var snap_cam_pos := Vector3.ZERO
var snap_light: OmniLight3D
var snap_trauma := 0.0
var snap_prepped := false
var snap_yaw0 := 0.0
var snap_pitch0 := 0.0
var snap_pitch_t := 0.0
var snap_delta := 0.0
var snap_cam_pitch := 0.0

const POSE_KEYS := ["legL", "legR", "armL", "armR", "splayL", "splayR", "rollL", "rollR", "headYaw", "headTilt", "headNod", "lean", "twist", "bob"]

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	nav = GridNav.new(level)
	n = nav.n
	flow.resize(n * n)
	if not _load_template():
		push_warning("mannequin: model failed to load")
		return
	reset()

# ================================================================= model
func _part_kind(node: Node) -> String:
	var name := ""
	var o: Node = node
	while o != null:
		name += " " + String(o.name)
		o = o.get_parent()
	name = name.to_lower()
	if name.contains("auge") or name.contains("eye"): return "eyes"
	if name.contains("kopf") or name.contains("head"): return "head"
	if name.contains("torso") or name.contains("body"): return "torso"
	if name.contains("arm"): return "arm"
	if name.contains("bein") or name.contains("leg"): return "leg"
	return "torso"

var top_x := Vector2.ZERO   # x extent of the last arm's shoulder slice

func _top_centroid(mesh: Mesh, xf: Transform3D, b: AABB) -> Vector3:
	var limit := b.end.y - b.size.y * 0.06
	var sum := Vector3.ZERO
	var cnt := 0
	top_x = Vector2(INF, -INF)
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts = arrays[Mesh.ARRAY_VERTEX]
		if verts == null:
			continue
		for v in verts:
			var w: Vector3 = xf * v
			if w.y >= limit:
				sum += w
				cnt += 1
				top_x = Vector2(minf(top_x.x, w.x), maxf(top_x.y, w.x))
	if cnt == 0:
		return Vector3(b.get_center().x, b.end.y, b.get_center().z)
	return sum / cnt

func _load_template() -> bool:
	var packed := load(MODEL) as PackedScene
	if packed == null:
		return false
	var root: Node3D = packed.instantiate()
	add_child(root)
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != root:
			if p is Node3D:
				xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var b := xf * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
		var kind := _part_kind(mi)
		var pivot := Vector3.ZERO
		if kind == "leg": pivot = Vector3(b.get_center().x, b.end.y, b.get_center().z)
		elif kind == "arm":
			# Shoulder pivot: top of the arm AABB (where it meets the torso socket).
			# The original code subtracted 1.5 here, which put the pivot near ground level
			# (≈ 0 m) when the shoulder is at ~1.5 m – causing the arm to rotate about
			# the floor and fling the hands wildly out of position.
			# Use the real shoulder joint: the centroid of the vertices in the top slice of the arm,
			# not the AABB centre (which is off to the side when the arm hangs at an angle).
			pivot = _top_centroid(mi.mesh, xf, b)
		elif kind == "head" or kind == "eyes":
			# Neck pivot: bottom of the head AABB (base of the neck).
			# The original code added 1.0 here, placing the pivot above the head entirely.
			pivot = Vector3(b.get_center().x, b.position.y, b.get_center().z)
		# torso pivot is the hips (a little above the leg tops): set below
		parts.append({"mesh": mi.mesh, "xf": xf, "pivot": pivot, "kind": kind, "cx": b.get_center().x, "b": b, "top_x": top_x})
	root.queue_free()
	if parts.is_empty() or box.size.y <= 0.0:
		return false
	var s := HEIGHT / box.size.y
	var c := box.get_center()
	norm_xf = Transform3D(Basis.from_scale(Vector3(s, s, s)), Vector3(-c.x, -box.position.y, -c.z) * s)
	# left / right from where the part sits (the model's own labels are mirrored); L is +X
	var hip_y := -3.0
	for pt in parts:
		if pt.kind == "leg":
			hip_y = pt.b.end.y
		if pt.kind == "arm" or pt.kind == "leg":
			pt["side"] = "L" if pt.cx > c.x else "R"
			if pt.kind == "arm":
				# swing about the inner edge of the shoulder so the joint stays closed against the torso
				var tx: Vector2 = pt.top_x
				pt.pivot.x = tx.x if pt.side == "L" else tx.y
		elif pt.kind == "head" or pt.kind == "eyes":
			pt["side"] = ""
			# the head pivot is shared: at the base of the head (set by the head part; eyes copy it)
	var head_pivot := Vector3.ZERO
	for pt in parts:
		if pt.kind == "head":
			head_pivot = pt.pivot
	for pt in parts:
		if pt.kind == "eyes":
			pt.pivot = head_pivot
	hip_pivot = Vector3(c.x, hip_y, c.z)
	ready_ok = true
	return true

func rest_pose() -> Dictionary:
	var d := {}
	for k in POSE_KEYS:
		d[k] = 0.0
	return d

func _rot_about(pivot: Vector3, axis: Vector3, angle: float) -> Transform3D:
	var b := Basis(axis, angle)
	return Transform3D(b, pivot - b * pivot)

# Every part's transform in figure space for a pose
func part_transforms(pose: Dictionary) -> Array:
	var out: Array = []
	var lean := _rot_about(hip_pivot, Vector3.RIGHT, pose.lean)
	var twist := _rot_about(hip_pivot, Vector3.UP, pose.twist)
	for pt in parts:
		var t: Transform3D = pt.xf
		match pt.kind:
			"torso":
				t = twist * lean * t
			"head", "eyes":
				var h := _rot_about(pt.pivot, Vector3.UP, pose.headYaw) * _rot_about(pt.pivot, Vector3.BACK, pose.headTilt) \
					* _rot_about(pt.pivot, Vector3.RIGHT, pose.headNod)
				t = twist * lean * h * t
			"arm":
				var s: String = pt.side
				var swing: float = pose["arm" + s]
				var splay: float = pose["splay" + s]
				var a := _rot_about(pt.pivot, Vector3.BACK, splay * (1.0 if s == "L" else -1.0)) * _rot_about(pt.pivot, Vector3.RIGHT, -swing)
				t = twist * lean * a * t
			"leg":
				var s2: String = pt.side
				t = _rot_about(pt.pivot, Vector3.RIGHT, -float(pose["leg" + s2])) * t
		out.append(norm_xf * t)
	return out

func random_pose() -> Dictionary:
	var p := rest_pose()
	p.legL = rng.randf_range(-0.12, 0.12); p.legR = rng.randf_range(-0.12, 0.12)
	p.armL = rng.randf_range(0.0, 0.35); p.armR = rng.randf_range(0.0, 0.35)
	p.splayL = rng.randf_range(0.0, 0.08); p.splayR = rng.randf_range(0.0, 0.08)
	p.headYaw = rng.randf_range(-0.6, 0.6); p.headTilt = rng.randf_range(-0.2, 0.2); p.headNod = rng.randf_range(-0.1, 0.2)
	p.lean = rng.randf_range(0.0, 0.06); p.twist = rng.randf_range(-0.1, 0.1)
	return p

# Decoys are frozen mid-something: some with an arm reaching, some with the head snapped far round
func decoy_pose() -> Dictionary:
	var p := random_pose()
	var roll := rng.randf()
	p["mode"] = "stand"
	if roll < 0.12:
		p.armL = rng.randf_range(1.3, 1.6)
	elif roll < 0.24:
		p.armR = rng.randf_range(1.3, 1.6)
	elif roll < 0.32:
		p.armL = rng.randf_range(1.3, 1.6); p.armR = rng.randf_range(1.3, 1.6)
	elif roll < 0.4:
		p.headYaw = rng.randf_range(-1.1, 1.1); p.headTilt = rng.randf_range(-0.4, 0.4)
	elif roll < 0.5:
		p["mode"] = "lie_up"       # on its back, arms to the ceiling or flopped out
		var up := rng.randf() < 0.5
		p.armL = 1.5 if up else 0.3; p.armR = 1.5 if up else 0.3
		p.splayL = rng.randf_range(0.2, 0.8); p.splayR = rng.randf_range(0.2, 0.8)
		p.legL = rng.randf_range(-0.1, 0.2); p.legR = rng.randf_range(-0.1, 0.2)
		p.lean = 0.0; p.twist = 0.0
	elif roll < 0.58:
		p["mode"] = "prone"        # face down, one or both arms reaching ahead
		p.armL = 2.8; p.armR = 2.8 if rng.randf() < 0.6 else 0.3
		p.splayL = rng.randf_range(0.1, 0.5); p.splayR = rng.randf_range(0.1, 0.5)
		p.headYaw = rng.randf_range(-1.0, 1.0)
		p.lean = 0.0; p.twist = 0.0
	elif roll < 0.66:
		p["mode"] = "side"         # curled up on its side
		p.armL = rng.randf_range(0.4, 1.0); p.armR = rng.randf_range(0.2, 0.6)
		p.legL = rng.randf_range(0.2, 0.7); p.legR = rng.randf_range(0.4, 0.9)
		p.lean = 0.0; p.twist = 0.0
	return p

# Whole-figure transform (in figure space) for a decoy's mode: lying ones are laid on the floor
func mode_base(mode: String) -> Transform3D:
	match mode:
		"lie_up":
			return Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(0, 0.13, HEIGHT * 0.5))
		"prone":
			return Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0, 0.13, -HEIGHT * 0.5))
		"side":
			var roll := Basis(Vector3.BACK, PI / 2.0 * (1.0 if rng.randf() < 0.5 else -1.0))
			return Transform3D(roll * Basis(Vector3.RIGHT, -PI / 2.0), Vector3(0, 0.2, HEIGHT * 0.5))
		"sit":
			return Transform3D(Basis.IDENTITY, Vector3(0, -0.74, 0))
	return Transform3D.IDENTITY

# ================================================================= room
func room_slots(count: int) -> Array:
	var cells: Array = []
	for x in range(ROOM.position.x, ROOM.end.x + 1):
		for z in range(ROOM.position.y, ROOM.end.y + 1):
			if not nav.blocked(x, z):
				cells.append(Vector2i(x, z))
	var slots: Array = []
	if cells.is_empty():
		return slots
	var jitter := CELL / 2.0 - RADIUS - 0.15
	var tries := 0
	while tries < count * 60 and slots.size() < count:
		tries += 1
		var c: Vector2i = cells[rng.randi() % cells.size()]
		var x := c.x * CELL + rng.randf_range(-jitter, jitter)
		var z := c.y * CELL + rng.randf_range(-jitter, jitter)
		var ok := true
		for s in slots:
			if Vector2(s.x - x, s.z - z).length() < SPACING:
				ok = false
				break
		if ok:
			slots.append({"x": x, "z": z})
	return slots

func room_centre() -> Vector3:
	return Vector3((ROOM.position.x + ROOM.end.x) / 2.0 * CELL, 0.0, (ROOM.position.y + ROOM.end.y) / 2.0 * CELL)

func in_room(p: Vector3) -> bool:
	var x := GridNav.cell(p.x)
	var z := GridNav.cell(p.z)
	return x >= ROOM.position.x - 1 and x <= ROOM.end.x + 1 and z >= ROOM.position.y - 1 and z <= ROOM.end.y + 1

# Re-deal the room: everyone gets a new spot and a new pose, and one of them is the real one
func reset() -> void:
	if not ready_ok:
		return
	for c in get_children():
		c.queue_free()
	killed = false
	hunt_clock = 0.0
	rest_left = 0.0
	rest_count = 0
	awake = false
	moving = false
	snap_active = false
	var slots := room_slots(COUNT)
	if slots.size() < 3:
		push_warning("mannequin room has no floor")
		return
	var centre := room_centre()
	var dealt: Array = []
	for s in slots:
		var face := atan2(centre.x - s.x, centre.z - s.z)
		dealt.append({"x": s.x, "z": s.z,
			"yaw": face + (rng.randf_range(-0.6, 0.6) if rng.randf() < 0.7 else rng.randf_range(-PI, PI)),
			"pose": decoy_pose()})
	var real_idx := rng.randi() % dealt.size()
	var r: Dictionary = dealt[real_idx]
	r.pose = random_pose()          # the real one always stands
	dealt.remove_at(real_idx)
	decoys = dealt
	_build_crowd()
	_build_real(r)

func _build_crowd() -> void:
	var count := decoys.size()
	var mms: Array = []
	for pt in parts:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = pt.mesh
		mm.instance_count = count
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		add_child(mmi)
		mms.append(mm)
	for i in count:
		var d: Dictionary = decoys[i]
		var g := Transform3D(Basis(Vector3.UP, d.yaw), Vector3(d.x, 0.0, d.z))
		var xfs := part_transforms(d.pose)
		var mode: String = d.pose.get("mode", "stand")
		var base := mode_base(mode)
		for j in parts.size():
			(mms[j] as MultiMesh).set_instance_transform(i, g * base * xfs[j])
		# they are solid (lying ones stay walk-over-able)
		if mode != "stand" and mode != "sit":
			continue
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = RADIUS
		cyl.height = HEIGHT
		cs.shape = cyl
		cs.position.y = HEIGHT / 2.0
		body.add_child(cs)
		body.position = Vector3(d.x, 0.0, d.z)
		add_child(body)

func _build_real(r: Dictionary) -> void:
	real_node = Node3D.new()
	add_child(real_node)
	real_meshes.clear()
	for pt in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = pt.mesh
		real_node.add_child(mi)
		real_meshes.append(mi)
	real_node.position = Vector3(r.x, 0.0, r.z)
	real_yaw = r.yaw
	real_node.rotation.y = real_yaw
	real_pose = r.pose
	_apply_pose(real_pose)
	_start_hunt()
	# solid too
	var body := AnimatableBody3D.new()
	body.name = "RealBody"
	body.sync_to_physics = false
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	cs.shape = cyl
	cs.position.y = HEIGHT / 2.0
	body.add_child(cs)
	real_node.add_child(body)

func _apply_pose(pose: Dictionary) -> void:
	var xfs := part_transforms(pose)
	for j in real_meshes.size():
		(real_meshes[j] as MeshInstance3D).transform = xfs[j]

func _start_hunt() -> void:
	hunt = {"step_t": 0.0, "step_idx": 0, "from": real_pose.duplicate(), "to": real_pose.duplicate(),
		"yaw_from": real_yaw, "yaw_to": real_yaw, "move_from": null, "move_to": null, "stepped": false, "dur": STEP_TIME}

# ================================================================= being watched
# Any part of it inside your view, with nothing solid in between
func seen(pos: Vector3) -> bool:
	if player.dead or player.frozen:
		return false
	var cam: Camera3D = player.cam
	var d := Vector2(pos.x - cam.global_position.x, pos.z - cam.global_position.z).length()
	if d > VIEW_RANGE:
		return false
	if not (cam.is_position_in_frustum(Vector3(pos.x, HEIGHT * 0.5, pos.z)) \
			or cam.is_position_in_frustum(Vector3(pos.x, HEIGHT * 0.9, pos.z)) \
			or cam.is_position_in_frustum(Vector3(pos.x, 0.2, pos.z))):
		return false
	# sight lines to its middle and both shoulders, so peeking round a corner still counts
	var ex := cam.global_position.x
	var ez := cam.global_position.z
	var dx := pos.x - ex
	var dz := pos.z - ez
	var l := maxf(sqrt(dx * dx + dz * dz), 0.001)
	var sx := -dz / l * 0.35
	var sz := dx / l * 0.35
	for k in [0, 1, -1]:
		if nav.clear_line(ex, ez, pos.x + sx * k, pos.z + sz * k, 0.6):
			return true
	return false

# ================================================================= hunting
# Walking distance from the player's cell, so it can step downhill
func step_target(pos: Vector3, tgt: Vector3) -> Vector3:
	if nav.clear_line(pos.x, pos.z, tgt.x, tgt.z, 0.6):
		return tgt
	var cx := GridNav.cell(pos.x)
	var cz := GridNav.cell(pos.z)
	if not nav.bfs(GridNav.cell(tgt.x), GridNav.cell(tgt.z), flow):
		return tgt
	var best := flow[cx * n + cz] if (cx >= 0 and cz >= 0 and cx < n and cz < n) else -1
	var target := tgt
	for o in GridNav.NEIGHBOURS:
		var nx: int = cx + o.x
		var nz: int = cz + o.y
		if nx < 0 or nz < 0 or nx >= n or nz >= n:
			continue
		var d := flow[nx * n + nz]
		if d != -1 and (best == -1 or d < best):
			best = d
			target = Vector3(nx * CELL, 0.0, nz * CELL)
	return target

# Player's facing on the ground plane
func _player_forward() -> Vector3:
	var f := -player.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.001 else Vector3.FORWARD

# Is `at` behind the player (outside a wide rear arc)?
func _is_behind(at: Vector3) -> bool:
	var to := Vector3(at.x - player.global_position.x, 0.0, at.z - player.global_position.z)
	if to.length() < 0.001:
		return true
	return to.normalized().dot(_player_forward()) < -0.25

func begin_step(tgt: Vector3) -> void:
	# It doesn't come at you from the side: closing in, it aims for the spot right behind you
	var d_to := Vector2(tgt.x - real_node.position.x, tgt.z - real_node.position.z).length()
	var behind_k := clampf(1.0 - (d_to - 3.0) / 5.0, 0.0, 1.0)
	tgt = tgt - _player_forward() * 1.0 * behind_k
	var pos := real_node.position
	var target := step_target(pos, tgt)
	var to_x := tgt.x - pos.x
	var to_z := tgt.z - pos.z
	var to_dist := maxf(Vector2(to_x, to_z).length(), 0.001)
	# flanking: don't follow in a single file line
	var perp := Vector3(-to_z / to_dist, 0.0, to_x / to_dist)
	if flank_sign == 1.0:
		flank_sign = (-1.0 if rng.randf() < 0.5 else 1.0) * (0.8 + rng.randf() * 1.5)
	if to_dist > 2.2:
		var fw := minf(2.5, to_dist * 0.22)
		var f := target + perp * flank_sign * fw
		if not nav.blocked(GridNav.cell(f.x), GridNav.cell(f.z)):
			target = f
	var dx := target.x - pos.x
	var dz := target.z - pos.z
	var dist := maxf(Vector2(dx, dz).length(), 0.001)
	var length := maxf(0.15, minf(STEP_LENGTH, minf(dist, to_dist - 0.3)))
	hunt.step_idx += 1
	hunt.step_t = 0.0
	hunt.stepped = false
	hunt["from"] = real_pose.duplicate()
	hunt.yaw_from = real_yaw
	hunt.yaw_to = real_yaw + wrapf(atan2(dx, dz) - real_yaw, -PI, PI)
	hunt.move_from = Vector2(pos.x, pos.z)
	hunt.move_to = Vector2(pos.x + dx / dist * length, pos.z + dz / dist * length)
	hunt.dur = STEP_TIME * rng.randf_range(0.85, 1.15) * (1.6 if rng.randf() < 0.08 else 1.0)
	var flip := 1.0 if hunt.step_idx % 2 == 1 else -1.0
	var to := rest_pose()
	to.legL = flip * rng.randf_range(0.4, 0.55); to.legR = -flip * rng.randf_range(0.25, 0.4)
	to.armL = -flip * rng.randf_range(0.2, 0.45); to.armR = flip * rng.randf_range(0.2, 0.45)
	to.splayL = rng.randf_range(0.05, 0.3); to.splayR = rng.randf_range(0.05, 0.3)
	# the head snaps to a new wrong angle every step
	to.headYaw = rng.randf_range(-0.45, 0.45); to.headTilt = rng.randf_range(-0.22, 0.22); to.headNod = rng.randf_range(-0.05, 0.18)
	to.twist = -flip * rng.randf_range(0.01, 0.04); to.lean = rng.randf_range(0.03, 0.08)
	# close in: more and more often it comes with its arms out, head fixed on you
	var close := clampf(1.0 - to_dist / 8.0, 0.0, 1.0)
	if close > 0.0 and rng.randf() < 0.25 + close * 0.75:
		to.armL = rng.randf_range(1.3, 1.6); to.armR = rng.randf_range(1.3, 1.6)
		to.splayL = rng.randf_range(0.04, 0.14); to.splayR = rng.randf_range(0.04, 0.14)
		to.headYaw = rng.randf_range(-0.1, 0.1); to.headNod = rng.randf_range(-0.08, 0.04)
	hunt["to"] = to

func smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func update_real(delta: float) -> void:
	moving = false
	if player.dead:
		return
	var tgt := player.global_position
	var pos := real_node.position
	if not awake:
		if Vector2(tgt.x - pos.x, tgt.z - pos.z).length() < WAKE_DISTANCE or in_room(tgt):
			awake = true
		else:
			return
	# watched by anyone: it holds its pose, silent, exactly where it is
	if seen(pos):
		return
	if rest_left > 0.0:
		rest_left -= delta
		return
	hunt_clock += delta
	if hunt_clock >= HUNT_TIME:
		hunt_clock = 0.0
		rest_count += 1
		if rest_count >= LONG_PAUSE_EVERY:
			rest_count = 0
			rest_left = LONG_PAUSE_TIME
		else:
			rest_left = REST_TIME
		return
	moving = true
	if hunt.move_to == null:
		begin_step(tgt)
	hunt.step_t += delta
	# the pose snaps in over the first moments of a step and is then held: stop-motion
	var snap := smooth(hunt.step_t / 0.11)
	var p := {}
	for k in POSE_KEYS:
		p[k] = lerpf(hunt["from"][k], hunt["to"][k], snap)
	real_pose = p
	_apply_pose(real_pose)
	real_yaw = lerpf(hunt.yaw_from, hunt.yaw_to, snap)
	real_node.rotation.y = real_yaw
	# the body lurches forward as the foot lands, then stands still for the rest of the step
	var mv := 1.0 - pow(1.0 - clampf(hunt.step_t / (hunt.dur * 0.4), 0.0, 1.0), 3.0)
	var mf: Vector2 = hunt.move_from
	var mt: Vector2 = hunt.move_to
	var np := Vector3(lerpf(mf.x, mt.x, mv), 0.0, lerpf(mf.y, mt.y, mv))
	np = nav.resolve(np, RADIUS)
	# don't walk through the crowd
	for d in decoys:
		var ddx: float = np.x - d.x
		var ddz: float = np.z - d.z
		var mn := RADIUS * 2.0
		var dsq := ddx * ddx + ddz * ddz
		if dsq < mn * mn:
			var l := maxf(sqrt(dsq), 0.0001)
			np.x = d.x + ddx / l * mn
			np.z = d.z + ddz / l * mn
	real_node.position = np
	# the foot lands
	if not hunt.stepped and hunt.step_t > 0.05:
		hunt.stepped = true
		var now := Time.get_ticks_msec() / 1000.0
		var dd := Vector2(tgt.x - np.x, tgt.z - np.z).length()
		if now - last_step_sound > 0.22 and dd < 28.0:
			last_step_sound = now
			var close := maxf(0.0, 1.0 - dd / 28.0)
			# Physics: Alternating left and right bipedal feet with accurate hip width & forward stride
			# flip > 0 (odd step_idx) swings left leg forward; even swings right leg forward
			var is_left := (hunt.step_idx % 2 == 1)
			var foot_side := 1.0 if is_left else -1.0 # In model coordinates, +X is left
			var side_dir := real_node.global_transform.basis.x.normalized()
			var fwd_dir := -real_node.global_transform.basis.z.normalized()
			# Hip width separation is ~0.34m (offset +-0.17m from center), landing foot planted forward ~0.28m
			var foot_pos := np + side_dir * (foot_side * 0.17) + fwd_dir * 0.28
			foot_pos.y = 0.05
			var step_weight := (0.45 + close * 0.95) * LOUDNESS
			scares.mannequin_step(foot_pos, step_weight, is_left, real_node)
	if hunt.step_t >= hunt.dur:
		hunt.move_to = null
		begin_step(tgt)
	# it reaches you while you weren't looking
	var reach := Vector2(tgt.x - np.x, tgt.z - np.z).length()
	# not while the bacteria has you (frozen): two death sequences would fight over the camera
	if reach < KILL_DISTANCE and _is_behind(np) and not player.dead and not player.frozen and player.spawn_grace <= 0.0 and not killed:
		killed = true
		start_snap()

# The entity is terrified of it while it hunts
func threat():
	if not ready_ok or not awake or real_node == null:
		return null
	return real_node.position

func _physics_process(delta: float) -> void:
	if not ready_ok or real_node == null or not Game.playing:
		return
	if snap_active:
		update_snap(delta)
		return
	update_real(delta)

# ================================================================= the snap
# It reaches you and you can't move: the view shakes with dread for a second, then your head is
# wrenched round to face it (a neck snap), and the normal death sequence follows.
func start_snap() -> void:
	snap_active = true
	snap_t = 0.0
	snapped = false
	snap_prepped = false
	snap_trauma = 0.0
	snap_beat = 0.0
	player.frozen = true
	player.velocity = Vector3.ZERO
	snap_start = real_node.position
	snap_cam_pos = player.cam.position
	snap_cam_pitch = player.cam.rotation.x
	scares.gasp()
	scares.startle(0.8)
	scares.heartbeat(1.8)
	# arms out, head still straight while it waits for you to look
	var to := player.global_position - real_node.position
	real_yaw = atan2(to.x, to.z)
	real_node.rotation.y = real_yaw
	real_pose = rest_pose()
	real_pose.armL = 1.45; real_pose.armR = 1.45; real_pose.splayL = 0.1; real_pose.splayR = 0.1; real_pose.lean = 0.08
	_apply_pose(real_pose)

# Smooth pseudo-noise in about -1..1 (sum of sines), for the trauma shake
func _snap_noise(seed_v: float, t: float) -> float:
	return sin(t * 13.1 + seed_v * 4.7) * 0.5 + sin(t * 7.3 + seed_v * 8.1) * 0.3 + sin(t * 23.7 + seed_v * 2.9) * 0.2

func update_snap(delta: float) -> void:
	snap_t += delta
	var t := snap_t
	var cam: Camera3D = player.cam
	var dread := smooth(t / SNAP_AT)
	# js mqUpdateSnap: the turn is a violent whip (fast out, slight overshoot, settle), not a cut
	var turn_x := clampf((t - SNAP_AT) / 0.3, 0.0, 1.0)
	var whip := 0.0 if turn_x <= 0.0 else minf(1.06, 1.0 - pow(1.0 - turn_x, 3.0) + sin(turn_x * PI) * 0.06)
	var p := player.global_position
	# it lunges in at the same time, its head ending up right at your eyes
	if turn_x > 0.0:
		var k := 1.0 - pow(1.0 - turn_x, 4.0)
		var to := Vector3(snap_start.x - p.x, 0.0, snap_start.z - p.z)
		var l := maxf(to.length(), 0.001)
		var target := Vector3(p.x + to.x / l * 0.75, 0.0, p.z + to.z / l * 0.75)
		real_node.position = snap_start.lerp(target, k)
		var tug := sin((t - SNAP_AT) * 38.0) * 0.06 * exp(-(t - SNAP_AT - 0.3) * 1.2) if turn_x >= 1.0 else 0.0
		var reach := 1.0 + 0.8 * k + tug
		var pose := rest_pose()
		pose.lean = 0.08 + 0.35 * k; pose.headNod = 0.2 * k; pose.headTilt = 0.5 * k; pose.headYaw = 0.35 * k
		pose.armL = reach; pose.armR = reach; pose.splayL = 0.1 - 0.3 * k; pose.splayR = 0.1 - 0.3 * k
		real_pose = pose
		_apply_pose(pose)
	# ---- camera. Trauma-based shake (Eiserloh, GDC 2016): amplitude = trauma^2 on smooth noise, mostly
	# rotational. Choreography: dread (tremble, breathing sway, twitches) -> flinch as the hands touch your
	# head -> a fixed-direction whip onto its face that overshoots and settles -> head lolling, sagging.
	var a := maxf(0.0, t - SNAP_AT)
	snap_trauma = maxf(0.0, snap_trauma - delta * 1.1)
	if t < SNAP_AT:
		snap_trauma = maxf(snap_trauma, 0.10 + 0.32 * dread * dread)
	var flinch := smooth((t - (SNAP_AT - 0.3)) / 0.12) * (1.0 - smooth((t - SNAP_AT) / 0.05))
	var tr2 := snap_trauma * snap_trauma
	# the whip's turn direction and end point are fixed the moment it starts, so it never flips or wanders
	if t >= SNAP_AT and not snap_prepped:
		snap_prepped = true
		var toh := Vector3(snap_start.x - p.x, 0.0, snap_start.z - p.z)
		var yaw_t := atan2(-toh.x, -toh.z)
		snap_yaw0 = player.rotation.y
		snap_pitch0 = cam.rotation.x
		snap_delta = wrapf(yaw_t - snap_yaw0, -PI, PI)
		if absf(snap_delta) > PI - 0.2:
			snap_delta = PI * (1.0 if rng.randf() < 0.5 else -1.0)   # it is right behind you: pick a side
		var head_h := HEIGHT * 0.92 - (snap_cam_pos.y + p.y)
		snap_pitch_t = clampf(atan2(head_h, 0.75) + 0.08, -0.6, 1.0)
		snap_trauma = 1.0
	var roll := 0.0
	var yaw_add := 0.0
	var pitch_add := 0.0
	if t < SNAP_AT:
		roll = sin(t * 2.1) * 0.035 * dread + 0.07 * dread * dread
		pitch_add = sin(t * 1.3) * 0.025 * dread - 0.03 * dread - 0.06 * flinch
		snap_twitch -= delta
		if snap_twitch <= 0.0:
			snap_twitch = 0.7 - 0.5 * dread + rng.randf() * 0.4
			snap_jerk = (rng.randf() - 0.5) * 0.35 * (0.4 + dread)
		snap_jerk *= exp(-delta * 9.0)
		yaw_add = snap_jerk * 0.3
		cam.position = snap_cam_pos + Vector3(0.0, -0.05 * dread - 0.05 * flinch, 0.0)
		player.rotation.y += yaw_add * delta * 6.0
		cam.rotation.x = snap_cam_pitch + pitch_add
	else:
		# ease-out-back: fast out, overshoot, settle
		var x := clampf(a / 0.2, 0.0, 1.0)
		var c1 := 2.2
		var e := 1.0 + (c1 + 1.0) * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0)
		player.rotation.y = snap_yaw0 + snap_delta * e + _snap_noise(1.0, t) * 0.09 * tr2
		cam.rotation.x = clampf(snap_pitch0 + (snap_pitch_t - snap_pitch0) * e + _snap_noise(2.0, t) * 0.07 * tr2, -1.4, 1.4)
		# head cranked over at a wrong angle, then lolling. The view holds its height and keeps staring
		# into its face: no sinking, the death camera lifts away from right here
		roll = 0.34 * e + 0.06 * smooth(a / 1.8) + sin(a * 2.4) * 0.03 * smooth(a / 0.6)
		cam.position = snap_cam_pos + Vector3(_snap_noise(3.0, t), _snap_noise(4.0, t), _snap_noise(5.0, t)) * 0.05 * tr2
	cam.rotation.z = roll + _snap_noise(6.0, t) * 0.12 * tr2
	if not snapped and t >= SNAP_AT:
		snapped = true
		scares.splat()
		scares.startle(1.0)
		scares.flatline(SNAP_TOTAL - SNAP_AT + 6.0)
		Game.add_glitch(1.0)
		# blood sprays from its face and splatters the glass
		var mouth := real_node.position + Vector3(0, HEIGHT * 0.9, 0)
		Death.bite(mouth, player.global_position, cam.global_position)
	Game.fear = 1.0
	if t < SNAP_AT:
		Game.add_glitch(0.3 * dread)
	# js: blur(1.2px -> 0 over 0.5 s) saturate(1.4) contrast(1.3) once snapped; edges close in from 3.7 s
	if whip > 0.0:
		Game.fx_blur = 1.2 * (1.0 - minf(1.0, (t - SNAP_AT) * 2.0))
		Game.fx_sat = 1.4
		Game.fx_contrast = 1.3
		var kb := (t - SNAP_AT)
		Game.fx_blood = 0.7 * smooth(kb / 0.5)
		Game.fx_static = 0.3 + 0.1 * sin(t * 9.0)
		Game.fx_warp = 0.003 + 0.006 * exp(-kb * 3.0)
	if t > 3.7:
		Game.fx_fade = smooth((t - 3.7) / (SNAP_TOTAL - 3.7))
	# a cold lamp between you and its head: flares at the snap, flickers
	if snap_light == null:
		snap_light = OmniLight3D.new()
		snap_light.light_color = Color(0.875, 0.9, 1.0)
		snap_light.omni_range = 5.0
		snap_light.light_energy = 0.0
		player.get_parent().add_child(snap_light)
	var hp := real_node.position + Vector3(0, HEIGHT * 0.92, 0)
	var cp := cam.global_position
	snap_light.global_position = Vector3(cp.x + (hp.x - cp.x) * 0.5, hp.y + 0.25, cp.z + (hp.z - cp.z) * 0.5)
	snap_light.light_energy = ((5.0 + 3.0 * exp(-(t - SNAP_AT) * 6.0)) * (0.85 + rng.randf() * 0.15) * 0.15) if whip > 0.0 else 0.6 * dread * 0.15
	cam.fov = player.BASE_FOV - 12.0 * dread * (1.0 - clampf(whip, 0.0, 1.0)) - 4.0 * flinch + 9.0 * exp(-maxf(0.0, t - SNAP_AT) * 9.0) * (1.0 if whip > 0.0 else 0.0)
	# heartbeat quickens toward the snap
	snap_beat -= delta
	if snap_beat <= 0.0 and t < SNAP_AT:
		snap_beat = 0.6 - 0.35 * dread
		scares.heartbeat(1.5 + dread)
	if t >= SNAP_TOTAL:
		snap_active = false
		# the head stays lolled over: the death camera eases the view round from there
		if snap_light != null:
			snap_light.queue_free()
			snap_light = null
		Game.kill_player("THE MANNEQUIN")

# ================================================================= dev
func warp_to_room() -> void:
	var c := room_centre()
	# the open cell in (or at the doorway of) the room that is clearest of mannequins
	var best := Vector2i(-1, -1)
	var best_d := -1.0
	for x in range(ROOM.position.x - 1, ROOM.end.x + 2):
		for z in range(ROOM.position.y - 1, ROOM.end.y + 2):
			if nav.blocked(x, z):
				continue
			var md := INF
			for d in decoys:
				md = minf(md, Vector2(d.x - x * CELL, d.z - z * CELL).length())
			if md > best_d:
				best_d = md
				best = Vector2i(x, z)
	if best.x < 0:
		return
	player.global_position = Vector3(best.x * CELL, 0.1, best.y * CELL)
	player.rotation.y = atan2(-(c.x - best.x * CELL), -(c.z - best.y * CELL))

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_F2:
		warp_to_room()
