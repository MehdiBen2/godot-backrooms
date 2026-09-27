extends Node3D
## THE BACTERIA's body: loads howler.glb and poses its skeleton procedurally every frame (js entity.js
## gait + poseTargets). It keeps only animation state and reads what the entity is doing from `e`.
##
## Gait: the stride is measured in metres walked, so planted feet don't skate. Steps get longer as it
## speeds up and a little shorter and quicker the closer it is to you; turning on the spot it still
## shuffles its feet round. Each foot lands with the leg stretched out, the body at its lowest, a dip of
## its whole weight (and `stepped`, the footfall sound's cue). It banks into turns and pitches forward as
## it surges ahead, while the head stays level, locked on what it's looking at.

signal stepped(weight: float, dragging: bool)   # dragging: the short, limping leg came down

const MODEL_YAW := -PI / 2.0
const SKIN := Color("15120e")
const CHASE_SPEED := 6.0
const STRIDE := 1.2            # metres per step at a walk; about twice that at a full run
const PIVOT := 0.7             # turning on the spot, its feet travel as if round a circle this wide

var e: Node3D                  # the entity: yaw, player, staring, lunge, peek_amt, seen_target...
var skel: Skeleton3D
var bones := {}                # role -> bone index
var pose := {}
var pose_t := {}
var phase := 0.0
var anim_time := 0.0
var anim_state := ""
var step_len := STRIDE
var step_side := 0
var gait_w := 0.0              # how much of the walk cycle is showing, eased in and out (no pop on setting off)
var clock := 0.0               # free-running animation time (noise, breathing)
var glitch := {}               # a limb/head briefly twisting to a wrong angle
var glitch_timer := 2.0
var head_yaw := 0.0            # head turn relative to the body (jerks toward what it watches)
var head_yaw_goal := 0.0
var head_hop := 0.0
var peek_lean := 0.0
var bank := 0.0                # leaning into a turn (+ = to its left)
var surge := 0.0               # pitching forward as it speeds up, back as it brakes
var stomp := 0.0               # the dip as a foot takes its weight, 1 on landing
var _prev_yaw := NAN
var _prev_speed := 0.0
var rng := RandomNumberGenerator.new()
var mist_mat: StandardMaterial3D
var mist_ring_mat: StandardMaterial3D
var mist_puffs := []             # black smoke curling off it, thicker while it hunts

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
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var t := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != self:
			if p is Node3D:
				t = (p as Node3D).transform * t
			p = p.get_parent()
		var b := t * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if box.size.y <= 0.0:
		_build_fallback()
		return
	var sc := height / box.size.y
	var rot := Basis(Vector3.UP, MODEL_YAW) * Basis.from_scale(Vector3(sc, sc, sc))
	root.transform = Transform3D(rot, Vector3.ZERO)
	# recompute the box with that rotation and scale actually applied, then shift the root so its
	# feet sit on the ground (y=0) and it's centred over its own origin, not wherever the mesh happened to be
	var rbox := AABB()
	first = true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var t := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != self:
			if p is Node3D:
				t = (p as Node3D).transform * t
			p = p.get_parent()
		var b := t * mi.get_aabb()
		rbox = b if first else rbox.merge(b)
		first = false
	var rc := rbox.get_center()
	root.position = Vector3(-rc.x, -rbox.position.y, -rc.z)
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
	var sks := root.find_children("*", "Skeleton3D", true, false)
	if not sks.is_empty():
		skel = sks[0]
		_find_bones()
	for k in ["hunch", "crouch", "neck", "head_pitch", "head_roll", "look", "reach_a", "reach_b", "out_a", "out_b", "elbow_a", "elbow_b", "claw", "still", "shoulder_up", "arm_spread", "finger_splay"]:
		pose[k] = 0.0
		pose_t[k] = 0.0

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

# The pose it's aiming for, from its state and what it's doing (js poseTargets)
func _pose_targets(st: String, run: float, moving: bool) -> void:
	var P := pose_t
	P.hunch = 0.35 + run * 0.15; P.crouch = 0.0; P.neck = 0.1; P.head_pitch = -0.1; P.head_roll = 0.0
	P.look = 1.0; P.still = 0.0; P.claw = 0.3
	P.reach_a = 0.15; P.reach_b = 0.15; P.out_a = 0.06; P.out_b = 0.06; P.elbow_a = 0.25; P.elbow_b = 0.25
	P.shoulder_up = 0.0; P.arm_spread = 0.0; P.finger_splay = 0.0
	if st == "roam" or st == "investigate" or st == "search":
		if not moving:
			# standing: listening. Head cocked, arms dead still
			P.hunch = 0.45
			P.head_roll = 0.45 * signf(sin(anim_time * 0.37 + 1.0))
			P.reach_a = 0.2; P.reach_b = 0.1
		if st == "investigate":
			# nose first: low, head forward and down, sniffing, hands raised a little
			P.hunch = 0.6; P.crouch = 0.12; P.head_pitch = -0.3
			P.reach_a = 0.4; P.reach_b = 0.4; P.elbow_a = 0.5; P.elbow_b = 0.5
		elif st == "search":
			P.hunch = 0.55; P.crouch = 0.08; P.reach_a = 0.35; P.reach_b = 0.25
			P.elbow_a = 0.45; P.elbow_b = 0.45; P.claw = 0.5
		if e.staring > 0.0:
			# being looked at: it freezes solid and its head slowly tips over as it stares back
			P.still = 1.0; P.hunch = 0.5
			P.head_roll = minf(1.2, 0.3 + anim_time * 0.35) * (1.0 if head_yaw >= 0.0 else -1.0)
			P.reach_a = 0.2; P.reach_b = 0.2
			P.arm_spread = 0.2; P.finger_splay = 0.6
		elif e.seen_target:
			# spotted the player from afar while roaming: sudden alertness, arms flare
			P.shoulder_up = 0.4; P.arm_spread = 0.35; P.out_a = 0.25; P.out_b = 0.25
			P.finger_splay = 0.5; P.claw = 0.6
	elif st == "chase":
		# Low, hunched, aggressive predator posture; head thrust forward, claws hooked to snatch
		P.hunch = 1.15 + run * 0.45
		P.crouch = 0.16 + run * 0.18
		P.neck = 0.35 + run * 0.15
		P.head_pitch = -0.15 * run
		P.claw = 1.1 + run * 0.5
		P.reach_a = 1.25 + run * 0.55
		P.reach_b = 1.25 + run * 0.55
		P.out_a = 0.3 + run * 0.15
		P.out_b = 0.3 + run * 0.15
		P.elbow_a = 0.6
		P.elbow_b = 0.6
		# Bearing down on the player: arms spread wide in a terrifying envelopment posture
		var player_node: Node3D = e.focus if is_instance_valid(e.focus) else e.player
		var d_p: float = (player_node.global_position - e.global_position).length() if player_node else 10.0
		var close_p: float = clampf(1.0 - d_p / 16.0, 0.0, 1.0)
		P.arm_spread = 0.2 + 0.5 * close_p
		P.out_a += 0.4 * close_p
		P.out_b += 0.4 * close_p
		P.finger_splay = 0.4 + 0.6 * close_p
		if e.lunge_windup > 0.0:
			P.hunch = 0.35; P.crouch = 0.38; P.claw = 1.5
			P.arm_spread = 0.7
			P.reach_a = 1.6; P.reach_b = 1.6; P.out_a = 0.95; P.out_b = 0.95; P.elbow_a = 0.4; P.elbow_b = 0.4
			P.finger_splay = 1.4
		elif e.lunge > 0.0:
			P.hunch = 1.45; P.crouch = 0.08; P.claw = 1.6
			P.arm_spread = 0.15
			P.reach_a = 2.0; P.reach_b = 2.0; P.out_a = 0.2; P.out_b = 0.2; P.elbow_a = 0.15; P.elbow_b = 0.15
			P.finger_splay = 0.8
	elif st == "screech":
		# SPOTTED PLAYER:
		# Phase 1 (0.0-0.20s): Sudden lock-on, spine snaps erect, arms begin rising
		# Phase 2 (0.20-0.85s): VIOLENT OPEN ARMS SCREECH! Broad intimidating wingspan threat display
		# Phase 3 (0.85s+): Coils down low, arms whip forward into predatory reach
		if anim_time < 0.20:
			P.hunch = -0.35; P.crouch = 0.12; P.neck = 0.35; P.head_pitch = 0.4; P.look = 1.0; P.claw = 1.0
			P.arm_spread = 0.35
			P.reach_a = 0.35; P.reach_b = 0.35; P.out_a = 0.6; P.out_b = 0.6; P.elbow_a = 0.35; P.elbow_b = 0.35
			P.finger_splay = 0.6
		elif anim_time < 0.85:
			# Massive open arms threat posture!
			P.hunch = -0.35; P.crouch = 0.05; P.neck = 0.55; P.head_pitch = 1.15; P.look = 0.4; P.claw = 1.5
			P.arm_spread = 0.65
			P.reach_a = 0.55; P.reach_b = 0.55; P.out_a = 1.25; P.out_b = 1.25; P.elbow_a = 0.45; P.elbow_b = 0.45
			P.finger_splay = 1.2
		else:
			# Coiling to sprint: drops low, arms whip forward from wide open into grasping claws
			P.hunch = 1.25; P.crouch = 0.32; P.neck = 0.35; P.head_pitch = -0.2; P.look = 1.0; P.claw = 1.3
			P.arm_spread = 0.2
			P.reach_a = 1.35; P.reach_b = 1.35; P.out_a = 0.35; P.out_b = 0.35; P.elbow_a = 0.5; P.elbow_b = 0.5
			P.finger_splay = 0.6
	elif st == "stalk":
		# Low behind the corner, leading hand gripping and hooking the wall's edge, head tilted nearly flat
		P.still = 1.0; P.hunch = 0.4; P.crouch = 0.55; P.neck = 0.3; P.head_pitch = -0.15; P.claw = 1.5
		var peek_side := -1.0 if peek_lean > 0.02 else 1.0
		P.head_roll = -1.55 * peek_side * lerpf(0.5, 1.0, e.peek_amt)
		var grip := "a" if peek_side > 0.0 else "b"
		var other := "b" if grip == "a" else "a"
		# gripping hand hooks forward around the corner edge, claws digging into the wall
		P["reach_" + grip] = 0.8 + 0.35 * e.peek_amt
		P["out_" + grip] = 0.95
		P["elbow_" + grip] = 0.85
		# non-gripping arm tucked close to the ribs
		P["reach_" + other] = -0.1
		P["out_" + other] = 0.1
		P["elbow_" + other] = 0.4
	elif st == "grab":
		# Seizing and ripping the player: arms wrap around the camera, claws clench and tear
		var snatching: bool = anim_time < 0.45
		var rearing: bool = e.lunge_windup > 0.0
		var lunging: bool = e.lunge > 0.0
		P.still = 0.0; P.look = 1.0
		if snatching:
			P.hunch = 0.65; P.crouch = 0.35; P.neck = 0.2; P.head_pitch = -0.3; P.claw = 1.6
			P.reach_a = 1.5; P.reach_b = 1.5; P.out_a = 0.38; P.out_b = 0.38; P.elbow_a = 0.75; P.elbow_b = 0.75
		elif rearing:
			P.hunch = -0.2; P.crouch = 0.25; P.neck = 0.45; P.head_pitch = 0.45; P.claw = 1.8
			P.reach_a = 1.1; P.reach_b = 1.1; P.out_a = 0.8; P.out_b = 0.8; P.elbow_a = 1.05; P.elbow_b = 1.05
		elif lunging:
			# Violent rip: claws drive forward and cross inward, tearing through the victim!
			P.hunch = 1.45; P.crouch = 0.08; P.neck = 0.2; P.head_pitch = -0.2; P.claw = 2.4
			P.reach_a = 2.5; P.reach_b = 2.5; P.out_a = -0.25; P.out_b = -0.25; P.elbow_a = 0.3; P.elbow_b = 0.3
		else:
			# hoisted in the air: arms bracket the camera from the sides, claws digging in and clutching
			P.hunch = 0.55; P.crouch = 0.15; P.neck = 0.25; P.head_pitch = -0.1; P.claw = 1.7
			P.reach_a = 1.85; P.reach_b = 1.85; P.out_a = 0.24; P.out_b = 0.24; P.elbow_a = 0.62; P.elbow_b = 0.62
	elif st == "flee":
		P.hunch = 1.1; P.crouch = 0.4; P.neck = 0.35; P.head_pitch = 0.1; P.look = 0.0; P.claw = 0.2
		P.reach_a = -0.55; P.reach_b = -0.55; P.out_a = 0.25; P.out_b = 0.25; P.elbow_a = 0.8; P.elbow_b = 0.8
	elif st == "stunned":
		P.hunch = -0.45; P.crouch = 0.3; P.neck = 0.4; P.head_pitch = 0.6; P.look = 0.0; P.claw = 1.2
		P.reach_a = 0.9; P.reach_b = -0.3; P.out_a = 0.7; P.out_b = 0.7
	elif st == "lurk":
		if moving:
			# creeping into place: low, long-armed, knuckles near the carpet
			P.hunch = 0.85; P.crouch = 0.3; P.neck = 0.25; P.head_pitch = -0.2; P.claw = 0.9
			P.reach_a = 0.5; P.reach_b = 0.5; P.out_a = 0.15; P.out_b = 0.15; P.elbow_a = 0.6; P.elbow_b = 0.6
		else:
			# waiting: folded down on itself, dead still, arms drawn in to spring, head cocked to listen
			P.still = 1.0; P.hunch = 1.0; P.crouch = 0.5; P.neck = 0.35; P.head_pitch = -0.25; P.claw = 1.2
			P.head_roll = 0.35 * signf(sin(anim_time * 0.21 + 0.5))
			P.reach_a = 0.65; P.reach_b = 0.65; P.out_a = 0.2; P.out_b = 0.2; P.elbow_a = 0.9; P.elbow_b = 0.9

# Smooth pseudo-noise, about -1..1 (sums of sines). Fresh random numbers every frame would just vibrate.
func _noise(seed_v: float, t: float) -> float:
	return sin(t * 1.7 + seed_v * 4.1) * 0.5 + sin(t * 3.3 + seed_v * 7.7) * 0.3 + sin(t * 7.9 + seed_v * 2.3) * 0.2

func _glitch_turn(role: String, g_angle: float) -> void:
	if glitch.is_empty() or glitch.bone != role:
		return
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	_turn(_b(role), axes[glitch.axis], g_angle)

# ================================================================= per frame
func animate(delta: float, move_speed: float, st: String) -> void:
	if st != anim_state:
		anim_state = st
		anim_time = 0.0
	anim_time += delta
	clock += delta
	var quiet := st == "stalk" or st == "lurk"      # hiding: slow, soft, barely a twitch
	# how fast it is turning (rad/s, + = to its left) and speeding up: for the bank, the surge, the shuffle
	var dt := maxf(delta, 0.0001)
	var yaw_rate: float = 0.0 if is_nan(_prev_yaw) else wrapf(e.yaw - _prev_yaw, -PI, PI) / dt
	_prev_yaw = e.yaw
	var accel := (move_speed - _prev_speed) / dt
	_prev_speed = move_speed
	var mist_intensity := clampf(move_speed / CHASE_SPEED, 0.0, 1.0)
	if st == "chase" or st == "screech" or st == "grab":
		mist_intensity = maxf(mist_intensity, 0.6)
	_update_mist(mist_intensity)
	if skel == null:
		return
	var player: Node3D = e.focus if is_instance_valid(e.focus) else e.player
	var to_p := player.global_position - e.global_position
	var dist := Vector2(to_p.x, to_p.z).length()
	var close := maxf(0.0, 1.0 - dist / 25.0)
	var run := clampf(move_speed / CHASE_SPEED, 0.0, 1.0)

	# ---- gait. Turning on the spot it still has to walk its feet round.
	var gait_speed := maxf(move_speed, absf(yaw_rate) * PIVOT)
	var moving := gait_speed > 0.25
	gait_w += ((clampf(gait_speed / 1.5, 0.3, 1.0) if moving else 0.0) - gait_w) * minf(1.0, delta * 6.0)
	step_len = (0.95 + run * 1.15) / 0.95 * STRIDE * (1.0 - close * 0.2)
	if moving:
		phase += PI * gait_speed * delta / step_len
	# a foot lands where the legs are furthest apart (phase = PI/2 + k*PI)
	var side := floori((phase - PI * 0.5) / PI)
	if side != step_side:
		step_side = side
		if moving:
			stomp = 1.0
			# the feet alternate: one long stride, then the short leg it drags (see the legs below)
			stepped.emit((0.45 + run * 0.55) * (0.5 + close * 1.6) * (0.3 if quiet else 1.0), posmod(side, 2) == 1)
	stomp = maxf(0.0, stomp - delta * 6.0)
	# leaning into turns like anything heavy running (only when it's actually moving), and into a surge
	var bank_goal := clampf(atan(move_speed * yaw_rate / 9.8) * 0.6, -0.3, 0.3)
	bank += (bank_goal - bank) * minf(1.0, delta * 5.0)
	surge += (clampf(accel * 0.025, -0.12, 0.2) - surge) * minf(1.0, delta * 4.0)

	_pose_targets(st, run, moving)
	var rate := 14.0 if (st == "chase" or st == "screech" or st == "stunned" or st == "grab") else (2.5 if quiet else 5.0)
	for k in pose:
		pose[k] = lerpf(pose[k], pose_t[k], 1.0 - exp(-rate * delta))
	peek_lean += (e.peek_lean_target - peek_lean) * minf(1.0, delta * 4.0)
	skel.reset_bone_poses()

	var w := gait_w
	var land := stomp * stomp * w * (0.4 + run)       # how hard the last foot came down
	var alive: float = 1.0 - pose.still * 0.85             # how much it breathes and sways
	# twitching: how much the joints shiver. Frozen while staring (tiny tremor), violent when hurt
	var twitch := 0.35
	match st:
		"chase", "screech", "grab":
			twitch = 1.0
		"flee":
			twitch = 0.8
		"stunned":
			twitch = 1.8
		"stalk", "lurk":
			twitch = 0.15
	if e.staring > 0.0:
		twitch = 0.08
	var tj := clock * 9.0

	# glitches: now and then one limb or the head twists to a wrong angle for a moment
	glitch_timer -= delta
	if glitch_timer <= 0.0:
		glitch_timer = (1.5 if (st == "chase" or st == "flee") else (5.0 if quiet else 3.0)) + rng.randf() * 4.0
		var pool: Array = ["head"] if quiet else ["arm_l", "arm_r", "fore_l", "fore_r", "head", "neck"]
		glitch = {"bone": pool[rng.randi() % pool.size()], "axis": rng.randi() % 3,
			"angle": (-1.0 if rng.randf() < 0.5 else 1.0) * (0.6 + rng.randf() * 0.9), "t": 0.18 + rng.randf() * 0.3}
		glitch["total"] = glitch.t
	var g_angle := 0.0
	if not glitch.is_empty():
		glitch.t -= delta
		if glitch.t <= 0.0:
			glitch = {}
		else:
			g_angle = glitch.angle * minf(1.0, minf((glitch.total - glitch.t) / 0.06, glitch.t / 0.1))

	var right := Vector3.RIGHT
	var fwd := Vector3.BACK
	var up := Vector3.UP

	# ---- where the head wants to look: at you when it hunts, stalks or stares, else scanning
	var slow_head: bool = quiet or e.staring > 0.0
	var interested: bool = st == "chase" or st == "screech" or st == "stalk" or st == "stunned" or st == "grab" or e.staring > 0.0 \
		or (e.seen_target and dist < 20.0 and st != "flee")
	var look_rel := 0.0
	if pose.look > 0.4:
		if interested:
			# turned further than a neck should
			look_rel = clampf(wrapf(atan2(to_p.x, to_p.z) - e.yaw, -PI, PI), -2.3, 2.3)
		else:
			look_rel = sin(clock * 0.35) * 0.55 + (0.5 if moving else 0.0) * sin(clock * 0.9)
	head_hop -= delta
	if head_hop <= 0.0:
		# it snaps in hops, not a smooth pan; stalking and staring it barely twitches at all
		if slow_head:
			head_hop = rng.randf_range(1.2, 3.5)
		elif interested:
			head_hop = rng.randf_range(0.12, 0.4)
		else:
			head_hop = rng.randf_range(0.6, 1.5)
		head_yaw_goal = look_rel + rng.randf_range(-0.18, 0.18) * (0.3 if slow_head else 1.0)
		if not slow_head and rng.randf() < 0.2:
			head_yaw_goal += rng.randf_range(-0.5, 0.5)            # a wrong little overshoot
	else:
		head_yaw_goal = lerpf(head_yaw_goal, look_rel, minf(1.0, delta * (0.8 if slow_head else 3.0)))
	head_yaw += (head_yaw_goal - head_yaw) * (1.0 - exp(-(4.0 if slow_head else 22.0) * delta))

	# ---- spine: hunch, a heaving breath, a lopsided twist with the stride, banked into turns
	var breath: float = sin(clock * (1.4 + pose.hunch * 3.0)) * 0.06 * alive
	var sway: float = sin(clock * 1.1) * 0.03 * alive
	var thrash := 1.0 if st == "stunned" else 0.0
	var screech_shiver := sin(clock * 48.0) * 0.22 if (st == "screech" and anim_time >= 0.20 and anim_time < 0.85) else 0.0
	_turn(_b("hip"), up, sin(phase) * (0.16 + run * 0.14) * w)
	_turn(_b("hip"), fwd, sin(phase) * (0.10 + run * 0.08) * w - bank * 0.5)
	_turn(_b("hip"), right, pose.hunch * 0.15 + surge * 0.8)
	_turn(_b("chest"), right, pose.hunch * 0.45 + breath + sway + surge * 1.2 + land * 0.14 \
		+ _noise(1.0, tj) * 0.1 * twitch + thrash * _noise(3.0, clock * 14.0) * 0.3 + screech_shiver * 1.4)
	_turn(_b("chest"), up, -sin(phase) * (0.14 + run * 0.18) * w)
	_turn(_b("chest"), fwd, peek_lean * 0.85 + sin(phase) * 0.08 * w + 0.05 * alive - bank * 0.5)

	# ---- neck and head: the maw stays aimed where it looks however far it is folded over
	var fold: float = pose.hunch * 0.45 + pose.neck * 0.5
	_turn(_b("neck"), right, pose.neck * 0.5 + _noise(30.0, tj) * 0.1 * twitch + screech_shiver * 1.3)
	_turn(_b("neck"), up, head_yaw * 0.35)
	_turn(_b("neck"), fwd, pose.head_roll * 0.25 + bank * 0.4)
	_turn(_b("head"), right, pose.head_pitch * 0.6 - fold * pose.look * 0.75 - surge * 0.8 * pose.look + _noise(31.0, tj) * 0.2 * twitch)
	_turn(_b("head"), up, head_yaw * 0.65)
	_turn(_b("head"), fwd, pose.head_roll * 0.75 + bank * 0.5 + _noise(32.0, tj) * 0.15 * twitch)
	_glitch_turn("neck", g_angle)
	_glitch_turn("head", g_angle)

	# ---- legs: realistic biped articulation with monstrous asymmetry and uncanny horror gait
	var pel_l: int = _b("pelvis_l")
	var pel_r: int = _b("pelvis_r")

	for leg in ["l", "r"]:
		var is_left: bool = leg == "l"
		var sgn := 1.0 if is_left else -1.0
		var ph := wrapf(phase + (0.0 if is_left else PI), 0.0, TAU)

		# Stance phase: foot on ground (0.45*PI to 1.45*PI)
		# Swing phase: foot airborne (1.45*PI to 2.45*PI / 0.45*PI)
		var is_stance: bool = ph >= 0.45 * PI and ph < 1.45 * PI
		
		var thigh_pitch := 0.0
		var knee_flex := 0.0
		var ankle_pitch := 0.0
		var thigh_splay := 0.0
		var thigh_yaw := 0.0

		if is_stance:
			# STANCE: foot bearing weight, sweeping backward to propel monster
			var st_prog := (ph - 0.45 * PI) / PI  # 0.0 (strike) to 1.0 (toe-off)
			
			# Thigh sweeps backward smoothly
			var stride_amp := 0.42 + run * 0.48
			thigh_pitch = lerpf(stride_amp * (1.1 if is_left else 0.85), -stride_amp * (0.85 if is_left else 1.15), st_prog)
			
			# Knee: slight flexion under load at plant (shock absorption), then straightens
			var plant_impact: float = maxf(0.0, 1.0 - st_prog * 4.0) * land * 0.3
			knee_flex = 0.12 + plant_impact + pose.crouch * 0.75 + (0.15 if not is_left else 0.0)
			
			# Ankle: strikes flat, rolls forward, pushes off at the end
			if st_prog < 0.2:
				ankle_pitch = lerpf(-0.25, 0.0, st_prog / 0.2)
			elif st_prog < 0.75:
				ankle_pitch = 0.02
			else:
				var push := (st_prog - 0.75) / 0.25
				ankle_pitch = push * (0.45 + run * 0.3)
			
			thigh_splay = sgn * (0.14 + run * 0.08)
			thigh_yaw = -sgn * 0.04
		else:
			# SWING: leg airborne, lifting, reaching forward
			var sw_prog := wrapf(ph - 1.45 * PI, 0.0, TAU) / PI  # 0.0 (toe-off) to 1.0 (strike)
			
			if is_left:
				# LEFT LEG: High predatory hitch / crane-like monster step
				var swing_reach := 0.48 + run * 0.52
				thigh_pitch = -lerpf(swing_reach * 0.8, -swing_reach * 1.1, sin(sw_prog * PI * 0.5))
				
				# High knee flexion in mid-swing to clear ground and stalk menacingly
				var knee_lift := sin(sw_prog * PI) * (1.25 + run * 0.6)
				var extension := maxf(0.0, sw_prog - 0.75) / 0.25 * 0.3
				knee_flex = maxf(0.05, knee_lift - extension) + pose.crouch * 0.75
				
				if sw_prog < 0.6:
					ankle_pitch = sin(sw_prog / 0.6 * PI) * 0.3
				else:
					ankle_pitch = -((sw_prog - 0.6) / 0.4) * 0.3
				
				thigh_splay = sgn * (0.14 + sin(sw_prog * PI) * 0.22)
				thigh_yaw = sgn * sin(sw_prog * PI) * 0.12
			else:
				# RIGHT LEG: Grotesque dragging limb that lags then snaps forward
				if sw_prog < 0.42:
					var drag_t := sw_prog / 0.42
					thigh_pitch = -(0.55 + run * 0.4) * (1.0 - drag_t * 0.25)
					knee_flex = 0.15 + sin(drag_t * PI) * 0.25 + pose.crouch * 0.75
					var scrape_spasm := sin(clock * 32.0) * 0.08 if moving else 0.0
					ankle_pitch = 0.45 + scrape_spasm
					thigh_splay = sgn * 0.08
					thigh_yaw = 0.0
				else:
					var whip_t := (sw_prog - 0.42) / 0.58
					var whip_curve := sin(whip_t * PI * 0.5)
					thigh_pitch = lerpf(-(0.4 + run * 0.3), (0.42 + run * 0.45), whip_curve)
					var whip_knee := sin(whip_t * PI) * (1.0 + run * 0.5)
					knee_flex = maxf(0.08, whip_knee) + pose.crouch * 0.75
					ankle_pitch = lerpf(0.4, -0.25, whip_t)
					thigh_splay = sgn * (0.12 + sin(whip_t * PI) * 0.15)
					thigh_yaw = sgn * 0.08

		# Blend in gait weight (smooth transition from idle to walk)
		thigh_pitch *= w
		knee_flex = lerpf(pose.crouch * 0.75, knee_flex, w)
		ankle_pitch *= w
		thigh_splay *= w
		thigh_yaw *= w

		_turn(_b("thigh_" + leg), right, -thigh_pitch - pose.crouch * 0.5)
		_turn(_b("thigh_" + leg), fwd, thigh_splay)
		_turn(_b("thigh_" + leg), up, thigh_yaw)
		_turn(_b("shin_" + leg), right, knee_flex)
		_turn(_b("foot_" + leg), right, ankle_pitch)

		var pel_bone: int = pel_l if is_left else pel_r
		if pel_bone >= 0:
			var pel_tilt: float = (0.08 + run * 0.06) * (1.0 if is_stance else -0.6) * w
			_turn(pel_bone, fwd, sgn * pel_tilt)
			_turn(pel_bone, right, (0.05 if is_stance else -0.04) * w)

	# ---- arms: predatory alternating lunges when running; open arms threat when spotting
	var clawing := (1.0 if (st == "chase" and e.lunge <= 0.0 and e.lunge_windup <= 0.0) else 0.0) * maxf(w, 0.4 * run)
	var threat_spread: float = pose.get("arm_spread", 0.0)
	var f_splay: float = pose.get("finger_splay", 0.0)

	for arm in ["a", "b"]:
		var arm_side := "l" if arm == "a" else "r"
		var sgn := 1.0 if arm_side == "l" else -1.0
		var seed_v := 10.0 if arm == "a" else 20.0
		var ph2 := phase + (PI if arm_side == "l" else 0.0)
		var swing_suppress: float = clampf(1.0 - threat_spread * 0.7, 0.0, 1.0)
		var hang := sin(ph2) * 0.3 * w * (1.0 - clawing) * swing_suppress
		var claw_swing := sin(ph2) * (0.75 * run if run > 0.3 else 0.4) * clawing * swing_suppress
		var reach: float = pose["reach_" + arm] + hang + claw_swing + _noise(seed_v, tj) * 0.18 * twitch \
			+ thrash * _noise(seed_v, clock * 12.0) * 0.9
		
		var out: float = pose["out_" + arm] + sin(clock * 0.9 + (0.0 if arm == "a" else 2.0)) * 0.04 * alive \
			+ maxf(0.0, -bank * sgn) * 0.6 + threat_spread * 0.5
		
		var open_yaw: float = sgn * (threat_spread * 0.75 + screech_shiver * 0.4)
		
		var elbow: float = pose["elbow_" + arm] + maxf(0.0, -sin(ph2)) * clawing * (1.2 * run if run > 0.3 else 0.9) * swing_suppress \
			+ sin(ph2 + 1.0) * 0.25 * w * (1.0 - clawing) * swing_suppress + _noise(seed_v + 3.0, tj) * 0.25 * twitch

		# Single compound rotation for the upper arm (pitch, roll, yaw combined cleanly without overwriting)
		_turn_compound(_b("arm_" + arm_side), -(reach * 0.85), sgn * out * 0.65, open_yaw)
		
		# Forearm is a pure elbow hinge - pitch only, never twisted on other axes
		_turn(_b("fore_" + arm_side), right, -(elbow * 0.85 + reach * 0.15))
		
		_glitch_turn("arm_" + arm_side, g_angle * sgn)
		_glitch_turn("fore_" + arm_side, g_angle * sgn)

		# fingers: claw clench + natural wide splay when spotting player
		var fingers: Array = bones.get("fingers_" + arm_side, [])
		var idx_fingers: Array = bones.get("finger_index_" + arm_side, [])
		var ring_fingers: Array = bones.get("finger_ring_" + arm_side, [])
		var grab_clench := (sin(clock * 11.0 + (0.0 if arm == "a" else 1.5)) * 0.35 + sin(clock * 23.0) * 0.15) if st == "grab" else 0.0

		for i in fingers.size():
			var f_bone: int = fingers[i]
			var run_twitch := sin(clock * 16.0 + float(i) * 1.8) * 0.25 * run
			var screech_twitch := sin(clock * 48.0 + float(i) * 2.3) * 0.22 * (1.0 if screech_shiver != 0.0 else 0.0)
			var curl: float = (sin(clock * (2.5 if quiet else 5.0) + float(i) * 1.7) * 0.3 * (0.4 + alive * 0.6) \
				+ pose.claw + grab_clench + run_twitch - f_splay * 0.25) * 0.65
			_turn(f_bone, right, -curl + screech_twitch)
			
			if idx_fingers.has(f_bone):
				_turn(f_bone, fwd, sgn * f_splay * 0.18)
			elif ring_fingers.has(f_bone):
				_turn(f_bone, fwd, -sgn * f_splay * 0.18)

	# crouch sinks the whole body, body bobs lowest at foot strikes and rises at midstance
	var gait_bob: float = -absf(sin(phase)) * (0.09 + run * 0.08) * w
	position.y = -pose.crouch * 0.5 + gait_bob - land * 0.09 + breath * 0.15
