extends Node3D
## THE BACTERIA's body, part 1: the skeleton and the tools that pose it. Loads howler.glb (or a boxy
## fallback), finds its bones and which way it faces, measures its rest pose, and gives bacteria_rig.gd
## what it animates with: two-bone leg IK with planted feet, bone turns, the squeeze under low ceilings,
## the mist it trails, and world positions of its head, chest and feet for the rest of the game.

const MODEL_YAW := -PI / 2.0   # fallback only: howler.glb faces +X (head section first); the real facing comes from its arms
const SKIN := Color("15120e")
const STRIDE := 1.2            # metres per step at a walk; about twice that at a full run
var e: Node3D                  # the entity: yaw, player, staring, lunge, peek_amt, seen_target...
var skel: Skeleton3D
var bones := {}                # role -> bone index
var pose := {}
var pose_t := {}
var stride := STRIDE           # metres per walking step, from its height (set in build)
var side_flip := 1.0           # -1 when its "l" bones are on its right (the model's naming is mirrored)
var size_k := 1.0             # its height over the 2.8 m the bob / dip amounts were tuned at
var clock := 0.0               # free-running animation time (noise, breathing)
var glitch := {}               # a limb/head briefly twisting to a wrong angle
var rng := RandomNumberGenerator.new()
var mist_mat: StandardMaterial3D
var mist_ring_mat: StandardMaterial3D
var mist_puffs := []             # black smoke curling off it, thicker while it hunts

# ---- low ceilings: it folds itself down to fit under them
const HEAD_CLEAR := 0.15       # metres it keeps between the top of its head and the ceiling
var model_h := 2.8
var top_off := 0.0             # how far the top of the model sits above its head bone, standing
var squeeze := 0.0             # 0 = standing tall, ~1 = folded down under a 2.3 m ceiling
var squeeze_trim := 0.0        # correction learned from where its head actually is

# ---- planted feet: each foot stays where it landed until it lifts (two-bone IK over the walk cycle)
var ankle_h := {"l": 0.0, "r": 0.0}     # ankle bone height above the floor, standing
var feet := {"l": {"planted": false, "pos": Vector3.ZERO}, "r": {"planted": false, "pos": Vector3.ZERO}}
var leg_phase := {"l": {"stance": false, "prog": 0.0}, "r": {"stance": false, "prog": 0.0}}

# ================================================================= model
func build(entity: Node3D, height: float) -> void:
	e = entity
	rng.randomize()
	_build_mist()
	var packed := load("res://models/entities/howler.glb") as PackedScene
	if packed == null:
		_build_fallback()
		return
	var root: Node3D = packed.instantiate()
	add_child(root)
	var box := _mesh_box(root)
	if box.size.y <= 0.0:
		_build_fallback()
		return
	var sc := height / box.size.y
	size_k = height / 2.8
	stride = height * 0.36
	var sks := root.find_children("*", "Skeleton3D", true, false)
	if not sks.is_empty():
		skel = sks[0]
		_find_bones()
	root.transform = Transform3D(Basis.from_scale(Vector3(sc, sc, sc)), Vector3.ZERO)
	# every pose below assumes it faces +Z with its left side on +X; turned any other way, "arms out"
	# swings them across its chest. So face it by where its own left and right arms actually are.
	root.transform = Transform3D(Basis(Vector3.UP, _facing_fix()) * root.transform.basis, Vector3.ZERO)
	_find_side_flip()
	# feet on the ground (y=0), centred over its own origin
	var rbox := _mesh_box(root)
	var rc := rbox.get_center()
	root.position = Vector3(-rc.x, -rbox.position.y, -rc.z)
	model_h = height
	_measure_rest()
	var mat := StandardMaterial3D.new()
	var col_tex: Texture2D = load("res://textures/bacteria_color.png")
	var norm_tex: Texture2D = load("res://textures/bacteria_normal.png")
	var rough_tex: Texture2D = load("res://textures/bacteria_rough.png")
	if col_tex != null:
		mat.albedo_texture = col_tex
		mat.albedo_color = Color(1.0, 1.0, 1.0)
	else:
		mat.albedo_color = SKIN
	if norm_tex != null:
		mat.normal_enabled = true
		mat.normal_texture = norm_tex
		mat.normal_scale = 1.35
	if rough_tex != null:
		mat.roughness_texture = rough_tex
		mat.roughness = 1.0
	else:
		mat.roughness = 0.75
	mat.metallic = 0.05
	# Seamless triplanar mapping covers un-UV'd wire geometry with rich, organic grainy surface detail
	mat.uv1_triplanar = true
	mat.uv1_triplanar_sharpness = 3.5
	mat.uv1_scale = Vector3(2.5, 2.5, 2.5)
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.extra_cull_margin = 8.0
	for k in ["hunch", "crouch", "neck", "head_pitch", "head_roll", "look", "reach_a", "reach_b", "out_a", "out_b", "elbow_a", "elbow_b", "claw", "still", "shoulder_up", "arm_spread", "finger_splay", "duck_reach"]:
		pose[k] = 0.0
		pose_t[k] = 0.0

# `n`'s transform in this rig's own space
func _to_rig(n: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var p: Node = n
	while p != null and p != self:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t

func _mesh_box(root: Node) -> AABB:
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var b := _to_rig(mi) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box

# The yaw that turns the model to face +Z, from its arms: its left arm must end up on +X
func _facing_fix() -> float:
	var l := _b("arm_l")
	var r := _b("arm_r")
	if skel == null or l < 0 or r < 0:
		return MODEL_YAW
	var to_rig := _to_rig(skel)
	var left := to_rig * skel.get_bone_global_rest(l).origin - to_rig * skel.get_bone_global_rest(r).origin
	left.y = 0.0
	if left.length() < 0.001:
		return MODEL_YAW
	# the long head section is its front: that's the opposite way to what its arm bones' names suggest
	var fwd := -left.cross(Vector3.UP)
	return -atan2(fwd.x, fwd.z)

# +1 if the bones named "l" sit on its left (+X) once it faces +Z, -1 if the naming is mirrored
func _find_side_flip() -> void:
	var l := _b("arm_l")
	var r := _b("arm_r")
	if skel == null or l < 0 or r < 0:
		return
	var to_rig := _to_rig(skel)
	var dx := (to_rig * skel.get_bone_global_rest(l).origin).x - (to_rig * skel.get_bone_global_rest(r).origin).x
	side_flip = 1.0 if dx >= 0.0 else -1.0

# Standing heights, read off the rest pose once it's scaled and on the floor
func _measure_rest() -> void:
	if skel == null:
		return
	var to_rig := _to_rig(skel)
	for leg in ["l", "r"]:
		var f := _b("foot_" + leg)
		if f >= 0:
			ankle_h[leg] = maxf(0.0, (to_rig * skel.get_bone_global_rest(f).origin).y)
	var h := _b("head")
	if h >= 0:
		top_off = maxf(0.0, model_h - (to_rig * skel.get_bone_global_rest(h).origin).y)

# ================================================================= low ceilings
# The lowest ceiling over where it stands, the ground just behind it and where it's about to be, so it
# ducks before it walks in, and doesn't stand up until all of it is out
func _ceiling_near(move_speed: float) -> float:
	var lv = e.get("level")
	if lv == null or not lv.has_method("ceiling_height"):
		return INF
	var p := e.global_position
	var f := Vector3(sin(e.yaw), 0.0, cos(e.yaw))
	var has_arch: bool = lv.has_method("arch_clearance")
	var lowest := INF
	for d in [-1.2, 0.0, 1.5, 1.5 + move_speed * 0.5]:
		var q: Vector3 = p + f * float(d)
		var c: Vector2i = lv.cell_of(q)
		var ch: float = lv.ceiling_height(c)
		if has_arch:
			ch = minf(ch, lv.arch_clearance(q))
		lowest = minf(lowest, ch)
	return lowest

# Where the top of it is right now (last frame's pose), above the floor
func _top_y() -> float:
	var h := _b("head")
	if h < 0:
		return model_h
	return (skel.global_transform * skel.get_bone_global_pose(h).origin).y - e.global_position.y + top_off

func _update_squeeze(delta: float, move_speed: float, st: String) -> void:
	var ceil_h := _ceiling_near(move_speed)
	var need := model_h + HEAD_CLEAR - ceil_h
	var goal := 0.0
	if need > 0.0:
		# roughly how far to fold for this ceiling, then trimmed by where its head actually ends up
		var poke := _top_y() + HEAD_CLEAR - ceil_h
		squeeze_trim = clampf(squeeze_trim + poke * 1.5 * delta, -0.4, 0.8)
		goal = clampf(need / (model_h * 0.5), 0.0, 1.4) + squeeze_trim
	else:
		squeeze_trim = move_toward(squeeze_trim, 0.0, delta)
	var fast := st == "chase" or st == "flee"
	squeeze += (maxf(0.0, goal) - squeeze) * (1.0 - exp(-(6.0 if fast else 3.5) * delta))

# ================================================================= planted feet
# In stance a foot stays exactly where it came down while the body travels over it; standing about, both
# feet stay put; in swing it's left to the walk cycle, only never through the floor. Each stance lets go
# over its last stretch, so the foot peels off into the swing instead of snapping.
func _plant_feet(w: float) -> void:
	var ground := e.global_position.y
	for leg in ["l", "r"]:
		var c_i := _b("foot_" + leg)
		if c_i < 0:
			continue
		var fk := skel.global_transform * skel.get_bone_global_pose(c_i).origin
		var floor_y: float = ground + ankle_h[leg]
		var ft: Dictionary = feet[leg]
		var lp: Dictionary = leg_phase[leg]
		var standing := w < 0.35
		var target := fk
		var weight := 0.0
		if lp.stance or standing:
			var p: Vector3 = ft.pos
			# first contact, or knocked / teleported too far from where it was planted: put it down here
			if not ft.planted or Vector2(p.x - fk.x, p.z - fk.z).length() > stride * 0.9:
				ft.planted = true
				ft.pos = Vector3(fk.x, floor_y, fk.z)
			var planted: Vector3 = ft.pos
			ft.pos = Vector3(planted.x, floor_y, planted.z)
			target = ft.pos
			weight = 1.0 if standing else clampf((1.0 - lp.prog) / 0.18, 0.0, 1.0)
		else:
			ft.planted = false
			if fk.y < floor_y:
				target = Vector3(fk.x, floor_y, fk.z)
				weight = 1.0
		if weight > 0.001:
			_leg_ik(leg, target, weight)

# Rotate `bone` by `rot`, given in skeleton space
func _rotate_skel(bone: int, rot: Basis) -> void:
	var g := skel.get_bone_global_pose(bone)
	var parent := skel.get_bone_parent(bone)
	var pg := skel.get_bone_global_pose(parent) if parent >= 0 else Transform3D.IDENTITY
	var local := pg.basis.inverse() * (rot * g.basis)
	skel.set_bone_pose_rotation(bone, local.get_rotation_quaternion())

# Two-bone IK: bend the knee to the right distance, then swing the thigh so the ankle lands on `target_w`
# (world space). The knee always bends forward, the way the walk cycle bends it, so it never flips.
func _leg_ik(leg: String, target_w: Vector3, weight: float) -> void:
	var a_i := _b("thigh_" + leg)
	var b_i := _b("shin_" + leg)
	var c_i := _b("foot_" + leg)
	if a_i < 0 or b_i < 0 or c_i < 0:
		return
	var inv := skel.global_transform.affine_inverse()
	var knee_axis := (inv.basis * (global_transform.basis * Vector3.RIGHT)).normalized()
	var T := skel.get_bone_global_pose(c_i).origin.lerp(inv * target_w, weight)
	for _pass in 2:
		var A := skel.get_bone_global_pose(a_i).origin
		var B := skel.get_bone_global_pose(b_i).origin
		var C := skel.get_bone_global_pose(c_i).origin
		var l1 := A.distance_to(B)
		var l2 := B.distance_to(C)
		if l1 < 0.0001 or l2 < 0.0001:
			return
		var d := clampf(A.distance_to(T), absf(l1 - l2) + 0.001, (l1 + l2) * 0.995)
		# 1. the knee: signed angle shin -> thigh about the knee's hinge (positive = bent forward)
		var ba := (A - B).normalized()
		var n := (knee_axis - ba * knee_axis.dot(ba)).normalized()
		if n.length_squared() < 0.5:
			return
		var bc := C - B
		bc = (bc - n * bc.dot(n)).normalized()
		var cur := bc.signed_angle_to(ba, n)
		var want := acos(clampf((l1 * l1 + l2 * l2 - d * d) / (2.0 * l1 * l2), -1.0, 1.0))
		_rotate_skel(b_i, Basis(n, cur - want))
		# 2. the thigh: aim the whole leg at the target
		C = skel.get_bone_global_pose(c_i).origin
		var from := C - A
		var to := T - A
		if from.length_squared() > 0.000001 and to.length_squared() > 0.000001:
			var fn := from.normalized()
			var tn := to.normalized()
			if fn.dot(tn) < 0.99999:
				_rotate_skel(a_i, Basis(Quaternion(fn, tn)))

# Black mist pooled around its feet and curling off its body: a flat ground haze it drags with it,
# plus a handful of big soft wisps that climb its legs and dissolve, thicker and faster while it hunts.
const MIST_PUFF_COUNT := 7

func _mist_texture(edge_a: float, edge_b: float) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	g.colors = PackedColorArray([Color(0, 0, 0, edge_a), Color(0, 0, 0, edge_b), Color(0, 0, 0, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	return tex

func _build_mist() -> void:
	mist_mat = StandardMaterial3D.new()
	mist_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mist_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mist_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mist_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mist_mat.albedo_texture = _mist_texture(0.9, 0.5)
	mist_mat.albedo_color = Color(1, 1, 1, 0)
	# a flat pool lying on the floor, unaffected by camera angle, so it reads as fog on the ground and
	# not a sprite standing in the corridor
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring_mat.albedo_texture = _mist_texture(0.75, 0.4)
	ring_mat.albedo_color = Color(1, 1, 1, 0)
	var ring := MeshInstance3D.new()
	var rq := QuadMesh.new()
	rq.size = Vector2(3.4, 3.4)
	ring.mesh = rq
	ring.material_override = ring_mat
	ring.rotation.x = -PI / 2.0
	ring.position.y = 0.03
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	mist_ring_mat = ring_mat
	for i in MIST_PUFF_COUNT:
		var m := MeshInstance3D.new()
		var q := QuadMesh.new()
		var sz := rng.randf_range(1.1, 1.9)
		q.size = Vector2(sz, sz)
		m.mesh = q
		var mm := mist_mat.duplicate()
		m.material_override = mm
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(m)
		mist_puffs.append({"n": m, "mat": mm, "ang": rng.randf() * TAU, "rad": rng.randf_range(0.15, 0.5),
			"y0": rng.randf_range(0.05, 0.35), "rise": rng.randf_range(0.5, 1.1),
			"spd": rng.randf_range(0.08, 0.22) * (1.0 if i % 2 == 0 else -1.0),
			"cyc": rng.randf_range(2.5, 4.5), "ph": rng.randf() * TAU})

# intensity: 0..1, how much it's stirred up (hunting/lunging makes it billow harder and rise faster)
func _update_mist(intensity: float) -> void:
	if mist_mat == null:
		return
	if mist_ring_mat != null:
		mist_ring_mat.albedo_color = Color(1, 1, 1, minf(0.8, 0.4 + intensity * 0.35))
	for p in mist_puffs:
		var cyc: float = p.cyc / (1.0 + intensity * 1.2)
		var life := fmod(clock / cyc + p.ph, 1.0)                # 0 = born low, 1 = dissolved up high
		var ang: float = p.ang + clock * p.spd * (1.0 + intensity)
		var r: float = p.rad + life * 0.35
		var y: float = p.y0 + life * p.rise * (1.0 + intensity * 0.6)
		p.n.position = Vector3(cos(ang) * r, y, sin(ang) * r)
		var fade: float = sin(life * PI)                         # smooth in, smooth out, never pops
		p.mat.albedo_color = Color(1, 1, 1, fade * (0.45 + intensity * 0.4))

# Stick-figure placeholder if the model fails to load
func _build_fallback() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = SKIN
	var spine := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.08; cyl.bottom_radius = 0.08; cyl.height = 2.6
	spine.mesh = cyl
	spine.material_override = mat
	spine.position.y = 1.3
	add_child(spine)

func _find_bones() -> void:
	for i in skel.get_bone_count():
		var nm := skel.get_bone_name(i).to_lower()
		var side := ""
		if nm.contains(" r_") or nm.ends_with(" r"): side = "r"
		elif nm.contains(" l_") or nm.ends_with(" l"): side = "l"
		if nm.begins_with("chest"): bones["chest"] = i
		elif nm.begins_with("hip"): bones["hip"] = i
		elif nm.begins_with("main"): bones["main"] = i
		elif nm.begins_with("neck"): bones["neck"] = i
		elif nm.begins_with("head"): bones["head"] = i
		elif nm.begins_with("shoulder") and side != "": bones["shoulder_" + side] = i
		elif nm.begins_with("upper arm") and side != "": bones["arm_" + side] = i
		elif nm.begins_with("lower arm") and side != "": bones["fore_" + side] = i
		elif nm.begins_with("pelvis") and side != "": bones["pelvis_" + side] = i
		elif nm.begins_with("upper leg") and side != "": bones["thigh_" + side] = i
		elif nm.begins_with("lower leg") and side != "": bones["shin_" + side] = i
		elif nm.begins_with("foot") and side != "": bones["foot_" + side] = i
		elif nm.contains("finger") and side != "":
			if not bones.has("fingers_" + side): bones["fingers_" + side] = []
			bones["fingers_" + side].append(i)
			if nm.contains("index"):
				if not bones.has("finger_index_" + side): bones["finger_index_" + side] = []
				bones["finger_index_" + side].append(i)
			elif nm.contains("ring"):
				if not bones.has("finger_ring_" + side): bones["finger_ring_" + side] = []
				bones["finger_ring_" + side].append(i)
			elif nm.contains("middle"):
				if not bones.has("finger_mid_" + side): bones["finger_mid_" + side] = []
				bones["finger_mid_" + side].append(i)

# Extra rotation of `bone` about an axis given in the entity's own space (x right, y up, z forward)
func _turn(bone: int, axis: Vector3, angle: float) -> void:
	if bone < 0 or absf(angle) < 0.0001:
		return
	var to_skel := skel.global_transform.basis.orthonormalized().inverse() * global_transform.basis
	var ax := (to_skel * axis).normalized()
	var g := skel.get_bone_global_pose(bone)
	var parent := skel.get_bone_parent(bone)
	var pg := skel.get_bone_global_pose(parent) if parent >= 0 else Transform3D.IDENTITY
	var new_basis := Basis(ax, angle) * g.basis
	var local := pg.basis.inverse() * new_basis
	skel.set_bone_pose_rotation(bone, local.get_rotation_quaternion())

# Compound rotation of `bone` combining pitch (right), roll (fwd) and yaw (up) in entity space
func _turn_compound(bone: int, rot_right: float, rot_fwd: float, rot_up: float) -> void:
	if bone < 0:
		return
	if absf(rot_right) < 0.0001 and absf(rot_fwd) < 0.0001 and absf(rot_up) < 0.0001:
		return
	var to_skel := skel.global_transform.basis.orthonormalized().inverse() * global_transform.basis
	var ax_r := (to_skel * Vector3.RIGHT).normalized()
	var ax_f := (to_skel * Vector3.BACK).normalized()
	var ax_u := (to_skel * Vector3.UP).normalized()
	var rot := Basis(ax_u, rot_up) * Basis(ax_f, rot_fwd) * Basis(ax_r, rot_right)
	var g := skel.get_bone_global_pose(bone)
	var parent := skel.get_bone_parent(bone)
	var pg := skel.get_bone_global_pose(parent) if parent >= 0 else Transform3D.IDENTITY
	var new_basis := rot * g.basis
	var local := pg.basis.inverse() * new_basis
	skel.set_bone_pose_rotation(bone, local.get_rotation_quaternion())

func _b(role: String) -> int:
	return bones.get(role, -1)

func get_bone_global_pos(role: String) -> Vector3:
	var idx: int = _b(role)
	if skel != null and idx >= 0:
		return skel.global_transform * skel.get_bone_global_pose(idx).origin
	return Vector3.ZERO

func get_head_global_pos() -> Vector3:
	var p := get_bone_global_pos("head")
	if p != Vector3.ZERO:
		return p
	var neck_p := get_bone_global_pos("neck")
	if neck_p != Vector3.ZERO:
		return neck_p + Vector3(0.0, 0.45, 0.0)
	var ep: Vector3 = e.global_position if e else global_position
	var fwd := Vector3(sin(e.yaw), 0.0, cos(e.yaw)) if e else -global_transform.basis.z
	return ep + Vector3(0.0, 2.4, 0.0) + fwd * 0.35

func get_chest_global_pos() -> Vector3:
	var p := get_bone_global_pos("chest")
	if p != Vector3.ZERO:
		return p
	var ep: Vector3 = e.global_position if e else global_position
	return ep + Vector3(0.0, 1.6, 0.0)

func get_feet_global_pos() -> Vector3:
	var fl := get_bone_global_pos("foot_l")
	var fr := get_bone_global_pos("foot_r")
	if fl != Vector3.ZERO and fr != Vector3.ZERO:
		return (fl + fr) * 0.5
	if fl != Vector3.ZERO: return fl
	if fr != Vector3.ZERO: return fr
	var ep: Vector3 = e.global_position if e else global_position
	return ep + Vector3(0.0, 0.2, 0.0)

# Smooth pseudo-noise, about -1..1 (sums of sines). Fresh random numbers every frame would just vibrate.
func _noise(seed_v: float, t: float) -> float:
	return sin(t * 1.7 + seed_v * 4.1) * 0.5 + sin(t * 3.3 + seed_v * 7.7) * 0.3 + sin(t * 7.9 + seed_v * 2.3) * 0.2

func _glitch_turn(role: String, g_angle: float) -> void:
	if glitch.is_empty() or glitch.bone != role:
		return
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	_turn(_b(role), axes[glitch.axis], g_angle)
