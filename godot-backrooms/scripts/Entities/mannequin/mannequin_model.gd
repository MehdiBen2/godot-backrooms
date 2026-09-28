extends RefCounted
## THE MANNEQUIN's body: creepy_mannequin.glb taken apart into its separate meshes (torso, head, eyes,
## two arms, two legs), each with the joint it swings about, and the poses. A pose is a Dictionary of
## POSE_KEYS angles; part_transforms() turns one into a transform per part in figure space (feet on
## y = 0, HEIGHT tall). Shared by the real one (its own meshes) and the decoys (one MultiMesh per part).

const MODEL := "res://models/entities/creepy_mannequin.glb"
const HEIGHT := 1.85
const POSE_KEYS := ["legL", "legR", "armL", "armR", "splayL", "splayR", "rollL", "rollR", "headYaw", "headTilt", "headNod", "lean", "twist", "bob"]

# A second sculpt mixed into the standing crowd for variety. It is one skinned mesh with a simple rig
# (Hips > LegL, LegR, Spine > ArmL, ArmR, Head), posed through its bones with the same pose Dictionaries
# as the jointed one (pose_variant), so no two of them stand alike.
const VARIANT_MODEL := "res://models/entities/mannequin_variant.glb"
# Its rest pose is a catwalk stride with a hand on the hip. A frozen mannequin reads better planted, so the
# legs are brought most of the way back under it before a pose is applied (0 = keep the stride).
const VARIANT_PLANT := 0.75

var parts: Array = []                        # {mesh, xf, pivot, kind, side, ...}
var hip_pivot := Vector3(0.0, 0.818858, -0.099118)
var norm_xf := Transform3D.IDENTITY          # model space -> figure space
var ok := false
var _top_x := Vector2.ZERO                   # x extent of the last arm's shoulder slice

var variant_mesh: Mesh
var variant_xf := Transform3D.IDENTITY       # model space -> figure space, feet on y = 0, HEIGHT tall
var variant_ok := false
var variant_scene: PackedScene
var variant_root_xf := Transform3D.IDENTITY  # scene root -> figure space (the whole rigged scene is instanced)
var variant_rigged := false
var _vbones := {}                            # bone name -> index
var _varm_l_pivot := Vector3.INF             # corrected left shoulder (skeleton space), see load_variant

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

func _top_centroid(mesh: Mesh, xf: Transform3D, b: AABB) -> Vector3:
	var limit := b.end.y - b.size.y * 0.06
	var sum := Vector3.ZERO
	var cnt := 0
	_top_x = Vector2(INF, -INF)
	for s in mesh.get_surface_count():
		var verts = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		if verts == null:
			continue
		for v in verts:
			var w: Vector3 = xf * v
			if w.y >= limit:
				sum += w
				cnt += 1
				_top_x = Vector2(minf(_top_x.x, w.x), maxf(_top_x.y, w.x))
	if cnt == 0:
		return Vector3(b.get_center().x, b.end.y, b.get_center().z)
	return sum / cnt

# Centre of the shoulder socket: the flat disc of the arm that sits against the torso is the inner-most
# slice of the mesh, and its middle (not the top of the arm) is where the joint really is. Swinging
# the arm about the top of the disc lifts the socket off the torso peg once the arm is raised.
func _socket_centroid(mesh: Mesh, xf: Transform3D, b: AABB, inner_is_min_x: bool) -> Vector3:
	var band := maxf(0.01, b.size.x * 0.04)
	var edge := b.position.x if inner_is_min_x else b.end.x
	var sum := Vector3.ZERO
	var cnt := 0
	for s in mesh.get_surface_count():
		var verts = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		if verts == null:
			continue
		for v in verts:
			var w: Vector3 = xf * v
			if absf(w.x - edge) <= band:
				sum += w
				cnt += 1
	if cnt == 0:
		return Vector3.INF
	var c := sum / cnt
	c.x = edge
	return c

## Load the model and work out every part's joint. `host` holds the instance while it is measured.
func load_template(host: Node) -> bool:
	var packed := load(MODEL) as PackedScene
	if packed == null:
		return false
	var root: Node3D = packed.instantiate()
	host.add_child(root)
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
		if kind == "leg":
			pivot = Vector3(b.get_center().x, b.end.y, b.get_center().z)
		elif kind == "arm":
			# the real shoulder joint: the centroid of the top slice of the arm, not the AABB centre
			# (which is off to the side when the arm hangs at an angle)
			pivot = _top_centroid(mi.mesh, xf, b)
		elif kind == "head" or kind == "eyes":
			pivot = Vector3(b.get_center().x, b.position.y, b.get_center().z)   # base of the neck
		# torso pivot is the hips (a little above the leg tops): set below
		parts.append({"mesh": mi.mesh, "xf": xf, "pivot": pivot, "kind": kind, "cx": b.get_center().x, "b": b, "top_x": _top_x})
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
				# how far out from vertical the arm hangs in the model: raised forward, that angle would
				# spread the hands wide, so the reaching poses can cancel it (pose.align)
				var out_x: float = (pt.cx - pt.pivot.x) * (1.0 if pt.side == "L" else -1.0)
				pt["rest_ang"] = atan2(out_x, pt.pivot.y - pt.b.get_center().y)
				# swing about the inner edge of the shoulder so the joint stays closed against the torso
				var tx: Vector2 = pt.top_x
				pt.pivot.x = tx.x if pt.side == "L" else tx.y
				# and about the middle of the socket disc, so the joint stays on the torso peg
				var sock := _socket_centroid(pt.mesh, pt.xf, pt.b, pt.side == "L")
				if sock.is_finite():
					pt.pivot = sock
		elif pt.kind == "head" or pt.kind == "eyes":
			pt["side"] = ""
	# the head pivot is shared: at the base of the head (set by the head part; the eyes copy it)
	var head_pivot := Vector3.ZERO
	for pt in parts:
		if pt.kind == "head":
			head_pivot = pt.pivot
	for pt in parts:
		if pt.kind == "eyes":
			pt.pivot = head_pivot
	hip_pivot = Vector3(c.x, hip_y, c.z)
	ok = true
	return true

## Load the plain variant sculpt: a single static mesh, normalised the same way (feet on y = 0, HEIGHT tall).
func load_variant(host: Node) -> bool:
	var packed := load(VARIANT_MODEL) as PackedScene
	if packed == null:
		return false
	var root: Node3D = packed.instantiate()
	host.add_child(root)
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		root.queue_free()
		return false
	var mi := meshes[0] as MeshInstance3D
	var xf := Transform3D.IDENTITY
	var p: Node = mi
	while p != null and p != root:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	var b := xf * mi.get_aabb()
	var skels := root.find_children("*", "Skeleton3D", true, false)
	if not skels.is_empty():
		var sk := skels[0] as Skeleton3D
		for i in sk.get_bone_count():
			_vbones[sk.get_bone_name(i)] = i
		variant_rigged = ["Spine", "Head", "ArmL", "ArmR", "LegL", "LegR"].all(func(n): return _vbones.has(n))
		# The rig's left shoulder joint sits at hip height (the right one is at the shoulder), so swinging
		# ArmL about its own origin would pivot the arm from the waist. Mirror the right shoulder instead.
		if variant_rigged:
			var r: Vector3 = sk.get_bone_global_rest(_vbones.ArmR).origin
			var l: Vector3 = sk.get_bone_global_rest(_vbones.ArmL).origin
			if absf(l.y - r.y) > 0.1:
				_varm_l_pivot = Vector3(-r.x, r.y, r.z)
	root.queue_free()
	if b.size.y <= 0.0:
		return false
	var s := HEIGHT / b.size.y
	var c := b.get_center()
	var norm := Transform3D(Basis.from_scale(Vector3(s, s, s)), Vector3(-c.x, -b.position.y, -c.z) * s)
	variant_mesh = mi.mesh
	variant_xf = norm * xf
	variant_root_xf = norm
	variant_scene = packed
	variant_ok = true
	return true

## A posed copy of the variant sculpt (its own rigged scene), in figure space. Null without a rig.
func make_variant(pose: Dictionary) -> Node3D:
	if not variant_rigged:
		return null
	var n: Node3D = variant_scene.instantiate()
	var sk := n.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	# a Skeleton3D only schedules its update while in the tree: posed before that, it keeps showing its rest
	sk.ready.connect(func(): pose_variant(sk, pose), CONNECT_ONE_SHOT)
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return n

## Turn one bone by `rot`, a rotation in skeleton space about `pivot` (its own joint when INF). Its parent's
## pose still applies on top, so an arm swings with a leaning torso.
func _vturn(sk: Skeleton3D, bone: String, rot: Basis, pivot := Vector3.INF) -> void:
	var i: int = _vbones[bone]
	var g := sk.get_bone_global_rest(i)
	var rest := sk.get_bone_rest(i)
	sk.set_bone_pose_rotation(i, (rest.basis * (g.basis.inverse() * rot * g.basis)).get_rotation_quaternion())
	if pivot.is_finite():
		var parent := sk.get_bone_parent(i)
		var pg := sk.get_bone_global_rest(parent) if parent >= 0 else Transform3D.IDENTITY
		sk.set_bone_pose_position(i, pg.affine_inverse() * (pivot + rot * (g.origin - pivot)))

## How far (0..1) to turn a limb bone from where it points at rest toward straight down
func _vplant(sk: Skeleton3D, bone: String, k: float) -> Basis:
	var d := sk.get_bone_global_rest(_vbones[bone]).basis.y.normalized()
	if d.dot(Vector3.DOWN) > 0.9999 or k <= 0.0:
		return Basis.IDENTITY
	return Basis(Quaternion.IDENTITY.slerp(Quaternion(d, Vector3.DOWN), k))

## The variant in a pose Dictionary (POSE_KEYS), the same axes and signs as part_transforms()
func pose_variant(sk: Skeleton3D, pose: Dictionary) -> void:
	sk.reset_bone_poses()
	_vturn(sk, "Spine", Basis(Vector3.UP, pose.twist) * Basis(Vector3.RIGHT, pose.lean))
	_vturn(sk, "Head", Basis(Vector3.UP, pose.headYaw) * Basis(Vector3.BACK, pose.headTilt) * Basis(Vector3.RIGHT, pose.headNod))
	for side in ["L", "R"]:
		var sg := 1.0 if side == "L" else -1.0
		var arm := Basis(Vector3.BACK, float(pose["splay" + side]) * sg) * Basis(Vector3.RIGHT, -float(pose["arm" + side]))
		_vturn(sk, "Arm" + side, arm, _varm_l_pivot if side == "L" else Vector3.INF)
		_vturn(sk, "Leg" + side, Basis(Vector3.RIGHT, -float(pose["leg" + side])) * _vplant(sk, "Leg" + side, VARIANT_PLANT))

# ================================================================= poses
static func rest_pose() -> Dictionary:
	var d := {}
	for k in POSE_KEYS:
		d[k] = 0.0
	return d

static func _rot_about(pivot: Vector3, axis: Vector3, angle: float) -> Transform3D:
	var b := Basis(axis, angle)
	return Transform3D(b, pivot - b * pivot)

## Every part's transform in figure space for a pose
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
				var sg := 1.0 if s == "L" else -1.0
				# align: bring the hanging arm in to vertical BEFORE it is raised, so a forward reach
				# has the hands in front of the shoulders instead of flung out to the sides
				var align: float = pose.get("align", 0.0) * float(pt.get("rest_ang", 0.0))
				var a := _rot_about(pt.pivot, Vector3.BACK, splay * sg) * _rot_about(pt.pivot, Vector3.RIGHT, -swing) \
					* _rot_about(pt.pivot, Vector3.BACK, -align * sg)
				t = twist * lean * a * t
			"leg":
				var s2: String = pt.side
				t = _rot_about(pt.pivot, Vector3.RIGHT, -float(pose["leg" + s2])) * t
		out.append(norm_xf * t)
	return out

static func random_pose(rng: RandomNumberGenerator) -> Dictionary:
	var p := rest_pose()
	p.legL = rng.randf_range(-0.12, 0.12); p.legR = rng.randf_range(-0.12, 0.12)
	p.armL = rng.randf_range(0.0, 0.35); p.armR = rng.randf_range(0.0, 0.35)
	p.splayL = rng.randf_range(0.0, 0.08); p.splayR = rng.randf_range(0.0, 0.08)
	p.headYaw = rng.randf_range(-0.6, 0.6); p.headTilt = rng.randf_range(-0.2, 0.2); p.headNod = rng.randf_range(-0.1, 0.2)
	p.lean = rng.randf_range(0.0, 0.06); p.twist = rng.randf_range(-0.1, 0.1)
	return p

## Decoys are frozen mid-something: some with an arm reaching, some with the head snapped far round,
## some lying on the floor
static func decoy_pose(rng: RandomNumberGenerator) -> Dictionary:
	var p := random_pose(rng)
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

## Whole-figure transform (in figure space) for a decoy's mode: lying ones are laid on the floor
static func mode_base(mode: String, rng: RandomNumberGenerator) -> Transform3D:
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
