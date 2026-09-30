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

var m: Node3D                                # mannequin.gd
var decoys: Array = []                       # {x, z, yaw, pose, g, body, variant}
var mms: Array = []                          # one MultiMesh per model part
var variant_mm: MultiMesh                    # one MultiMesh for the plain variant sculpt (whole figure)
var shufflers: Array = []                    # {i, seen}: every standing decoy
var stalker := -1                            # decoy index of the one that creeps toward you
var tick := 0.0
var cooldown := 4.0
var _blink_used := false

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
	tick += delta
	if tick < 0.1:
		return
	var dt := tick
	tick = 0.0
	var player: Node3D = m.player
	var cam: Camera3D = player.cam
	var pp := player.global_position
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
		if pp.distance_to(Vector3(d.x, 0.0, d.z)) > SHUFFLE_RANGE:
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
