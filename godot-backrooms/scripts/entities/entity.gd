extends Node3D
## THE BACTERIA (the Howler). Port of js/game/entity.js.
##
## AI: roam -> investigate (noise / glimpse) -> screech (first sighting) -> chase -> search (lost you);
## stunned when shot; stalk (peeks from behind a corner) -> flee when you look at it or come close.
## Senses: view cone + line of sight (range grows with your torch, shrinks when you crouch, almost
## nothing if you stand still in the dark) that builds up awareness, and hearing (muffled by walls).
##
## Dev keys: F10 summon it in front of you, F4 send it to stalk you.

const GridNav := preload("res://scripts/world/grid_nav.gd")
const CELL := 4.5

# ENTITY config (js/config.js)
const RADIUS := 0.6
const TERROR_DISTANCE := 18.0
const ROAM_SPEED := 1.1
const INVESTIGATE_SPEED := 2.0
const SEARCH_SPEED := 1.6
const CHASE_SPEED := 6.0
const LUNGE_SPEED := 7.5
const TURN_RATE := 6.0
const SIGHT_RANGE := 16.0
const SIGHT_FOV := 2.2
const TORCH_SIGHT_BONUS := 1.6
const CROUCH_SIGHT := 0.55
const STILL_SIGHT := 3.5
const AWARENESS_RISE := 2.2
const AWARENESS_FALL := 0.3
const HEAR_SPRINT := 15.0
const HEAR_WALK := 6.0
const HEAR_CROUCH := 1.2
const HEAR_GUNSHOT := 45.0
const LOSE_TRACK_TIME := 3.5
const SEARCH_TIME := 16.0
const LUNGE_RANGE := 2.6
const MENACE_TIME := 50.0
const GIVE_UP_DISTANCE := 20.0
const GIVE_UP_TIME := 1.8
const WINDED_TIME := 8.0
const LOUDNESS := 0.85
const STALK_COOLDOWN := 60.0
const STALK_CHANCE := 0.35
const STALK_MIN_DIST := 9.0
const STALK_MAX_DIST := 26.0
const STALK_TIME := 14.0
const STALK_WATCHED := 0.5
const STALK_FLUSH_DIST := 6.0
const MANNEQUIN_FEAR_RANGE := 12.0
const FLEE_SPEED := 9.5
const RESPAWN_MIN_CELLS := 18
const SPAWN_GRACE := 8.0
const MODEL_HEIGHT := 4.6
const MODEL_YAW := -PI / 2.0
const SKIN := Color("15120e")
const KILL_DISTANCE := 1.35

var level: Node
var player: CharacterBody3D
var scares: Node
var mannequin: Node                    # optional: it bolts from THE MANNEQUIN
var nav
var n := 0

# ---- model / animation
var visual: Node3D
var skel: Skeleton3D
var bones := {}                        # role -> bone index
var pose := {}
var pose_t := {}
var phase := 0.0
var anim_time := 0.0
var anim_state := ""
var step_len := 1.4
var clock := 0.0                      # free-running animation time (noise, breathing)
var glitch := {}                      # a limb/head briefly twisting to a wrong angle
var glitch_timer := 2.0
var head_yaw := 0.0                   # head turn relative to the body (jerks toward what it watches)
var head_yaw_goal := 0.0
var head_hop := 0.0
var peek_amt := 0.0                   # 0 hidden behind the corner .. 1 leaned out watching you
var peek_mode := "hide"
var peek_timer := 0.0
var peek_step := 0.0
var peek_gaze := 0.0                  # how long it has been in your view while peeking
var peek_count := 0
var rest_bones_ready := false

# ---- navigation
var flow := PackedInt32Array()
var reach := PackedInt32Array()
var goal := Vector3.ZERO
var goal_key := -1
var flow_timer := 0.0
var goal_reachable := true
var visited := {}
var roam_clock := 0.0
var prune_timer := 0.0
var interest := {"x": 0.0, "z": 0.0, "at": -1e9}
var winded := 0.0

# ---- senses
var awareness := 0.0
var seen_target := false
var last_known := Vector3.ZERO
var last_vel := Vector3.ZERO
var last_seen_time := 0.0
var entity_noises: Array = []
var tgt := {"pos": Vector3.ZERO, "look": Vector3.FORWARD, "moving": false, "sprinting": false,
	"crouching": false, "torch": false, "lit": 0.0}

# ---- state machine
var state := "roam"
var state_time := 0.0
var pause := 0.0
var look_yaw := NAN
var search_left := 0.0
var lunge := 0.0
var lunge_windup := 0.0
var since_encounter := 0.0
var yaw := 0.0
var speed_now := 0.0
var stun_timer := 0.0
var enraged := 0.0
var staring := 0.0
var stare_cooldown := 5.0
var vel := Vector3.ZERO
var last_pos := Vector3.ZERO
var stuck_timer := 0.0
var fear_timer := 0.0
var far_timer := 0.0
var think_timer := 0.0
var voice_state := ""
var voice_timer := 3.0
var occl_timer := 0.0
var grab_t := -1.0
var grab_base := Vector3.ZERO

# ---- stalking
var stalk_cooldown := STALK_COOLDOWN * 0.5
var stalk_active := false
var stalk_phase := "approach"
var stalk_watched := 0.0
var stalk_lost := 0.0
var stalk_moves := 0
var stalk_hide := Vector3.ZERO
var stalk_peek := Vector3.ZERO
var stalk_side := Vector3.ZERO
var peek_lean := 0.0
var peek_lean_target := 0.0

var rng := RandomNumberGenerator.new()

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	nav = GridNav.new(level)
	n = nav.n
	flow.resize(n * n)
	reach.resize(n * n)
	var sp: Array = level.level_data.get("entity", [n - 12, 18])
	global_position = Vector3(sp[0] * CELL, 0.0, sp[1] * CELL)
	_build_model()
	set_goal(global_position.x, global_position.z)
	pick_spot(3, 18)

# ================================================================= model
func _build_model() -> void:
	visual = Node3D.new()
	add_child(visual)
	var packed := load("res://models/entities/howler.glb") as PackedScene
	if packed == null:
		_build_fallback()
		return
	var root: Node3D = packed.instantiate()
	visual.add_child(root)
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var t := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != visual:
			if p is Node3D:
				t = (p as Node3D).transform * t
			p = p.get_parent()
		var b := t * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if box.size.y <= 0.0:
		_build_fallback()
		return
	var sc := MODEL_HEIGHT / box.size.y
	var c := box.get_center()
	var rot := Basis(Vector3.UP, MODEL_YAW) * Basis.from_scale(Vector3(sc, sc, sc))
	root.transform = Transform3D(rot, rot * Vector3(-c.x, -box.position.y, -c.z))
	var mat := StandardMaterial3D.new()
	mat.albedo_color = SKIN
	mat.roughness = 0.85
	mat.metallic = 0.0
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.extra_cull_margin = 8.0
	var sks := root.find_children("*", "Skeleton3D", true, false)
	if not sks.is_empty():
		skel = sks[0]
		_find_bones()
	for k in ["hunch", "crouch", "neck", "head_pitch", "head_roll", "look", "reach_a", "reach_b", "out_a", "out_b", "elbow_a", "elbow_b", "claw", "still"]:
		pose[k] = 0.0
		pose_t[k] = 0.0

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
	visual.add_child(spine)

func _find_bones() -> void:
	for i in skel.get_bone_count():
		var nm := skel.get_bone_name(i).to_lower()
		var side := ""
		if nm.contains(" r_") or nm.ends_with(" r"): side = "r"
		elif nm.contains(" l_") or nm.ends_with(" l"): side = "l"
		if nm.begins_with("chest"): bones["chest"] = i
		elif nm.begins_with("hip"): bones["hip"] = i
		elif nm.begins_with("neck"): bones["neck"] = i
		elif nm.begins_with("head"): bones["head"] = i
		elif nm.begins_with("upper arm") and side != "": bones["arm_" + side] = i
		elif nm.begins_with("lower arm") and side != "": bones["fore_" + side] = i
		elif nm.begins_with("upper leg") and side != "": bones["thigh_" + side] = i
		elif nm.begins_with("lower leg") and side != "": bones["shin_" + side] = i
		elif nm.begins_with("foot") and side != "": bones["foot_" + side] = i
		elif nm.contains("finger") and side != "":
			if not bones.has("fingers_" + side): bones["fingers_" + side] = []
			bones["fingers_" + side].append(i)

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

func _b(role: String) -> int:
	return bones.get(role, -1)

# The pose it's aiming for, from its state and what it's doing (js poseTargets)
func _pose_targets(st: String, run: float, moving: bool) -> void:
	var P := pose_t
	P.hunch = 0.35 + run * 0.15; P.crouch = 0.0; P.neck = 0.1; P.head_pitch = -0.1; P.head_roll = 0.0
	P.look = 1.0; P.still = 0.0; P.claw = 0.3
	P.reach_a = 0.15; P.reach_b = 0.15; P.out_a = 0.06; P.out_b = 0.06; P.elbow_a = 0.25; P.elbow_b = 0.25
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
		if staring > 0.0:
			# being looked at: it freezes solid and its head slowly tips over as it stares back
			P.still = 1.0; P.hunch = 0.5
			P.head_roll = minf(1.2, 0.3 + anim_time * 0.35) * (1.0 if head_yaw >= 0.0 else -1.0)
			P.reach_a = 0.2; P.reach_b = 0.2
	elif st == "chase":
		P.hunch = 1.0; P.crouch = 0.22; P.neck = 0.25; P.head_pitch = 0.0; P.claw = 0.8
		P.reach_a = 1.05; P.reach_b = 1.05; P.out_a = 0.22; P.out_b = 0.22; P.elbow_a = 0.55; P.elbow_b = 0.55
		if lunge_windup > 0.0:
			P.hunch = 0.45; P.crouch = 0.35; P.claw = 1.0
			P.reach_a = 1.9; P.reach_b = 1.9; P.out_a = 0.6; P.out_b = 0.6; P.elbow_a = 0.2; P.elbow_b = 0.2
		elif lunge > 0.0:
			P.hunch = 1.25; P.crouch = 0.1; P.claw = 1.0
			P.reach_a = 1.55; P.reach_b = 1.55; P.out_a = 0.3; P.out_b = 0.3; P.elbow_a = 0.0; P.elbow_b = 0.0
	elif st == "screech":
		# rears back with its maw to the ceiling, then snaps it down at you and howls
		var thrown := anim_time < 0.4
		P.hunch = -0.5 if thrown else -0.1; P.crouch = 0.15; P.neck = 0.35 if thrown else 0.3
		P.head_pitch = 1.0 if thrown else 0.0; P.look = 0.0 if thrown else 1.0; P.claw = 1.2
		P.reach_a = 0.65; P.reach_b = 0.65; P.out_a = 1.3; P.out_b = 1.3; P.elbow_a = 0.95; P.elbow_b = 0.95
	elif st == "stalk":
		# low behind the corner, one hand gripping the wall's edge, the head tipped almost flat
		P.still = 1.0; P.hunch = 0.3; P.crouch = 0.45; P.neck = 0.2; P.head_pitch = 0.0; P.claw = 0.9
		var peek_side := -1.0 if peek_lean > 0.02 else 1.0
		P.head_roll = -1.4 * peek_side * lerpf(0.35, 1.0, peek_amt)
		var grip := "a" if peek_side > 0.0 else "b"
		var other := "b" if grip == "a" else "a"
		P["reach_" + grip] = 0.6; P["out_" + grip] = 0.85; P["elbow_" + grip] = 0.95
		P["reach_" + other] = 0.05; P["out_" + other] = 0.0; P["elbow_" + other] = 0.15
	elif st == "flee":
		P.hunch = 1.1; P.crouch = 0.4; P.neck = 0.35; P.head_pitch = 0.1; P.look = 0.0; P.claw = 0.2
		P.reach_a = -0.55; P.reach_b = -0.55; P.out_a = 0.25; P.out_b = 0.25; P.elbow_a = 0.8; P.elbow_b = 0.8
	elif st == "stunned":
		P.hunch = -0.45; P.crouch = 0.3; P.neck = 0.4; P.head_pitch = 0.6; P.look = 0.0; P.claw = 1.2
		P.reach_a = 0.9; P.reach_b = -0.3; P.out_a = 0.7; P.out_b = 0.7

# Smooth pseudo-noise, about -1..1 (sums of sines). Fresh random numbers every frame would just vibrate.
func _noise(seed_v: float, t: float) -> float:
	return sin(t * 1.7 + seed_v * 4.1) * 0.5 + sin(t * 3.3 + seed_v * 7.7) * 0.3 + sin(t * 7.9 + seed_v * 2.3) * 0.2

func _glitch_turn(role: String, g_angle: float) -> void:
	if glitch.is_empty() or glitch.bone != role:
		return
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	_turn(_b(role), axes[glitch.axis], g_angle)

func animate(delta: float, move_speed: float, st: String) -> void:
	if st != anim_state:
		anim_state = st
		anim_time = 0.0
	anim_time += delta
	clock += delta
	if skel == null:
		return
	var moving := move_speed > 0.25
	var run := clampf(move_speed / CHASE_SPEED, 0.0, 1.0)
	if moving:
		phase += TAU * move_speed * delta / (2.0 * step_len)
	_pose_targets(st, run, moving)
	var rate := 12.0 if (st == "chase" or st == "screech" or st == "stunned") else (2.5 if st == "stalk" else 5.0)
	for k in pose:
		pose[k] = lerpf(pose[k], pose_t[k], 1.0 - exp(-rate * delta))
	peek_lean += (peek_lean_target - peek_lean) * minf(1.0, delta * 4.0)
	skel.reset_bone_poses()

	var w := 0.0 if not moving else clampf(move_speed / 1.5, 0.3, 1.0)
	var alive: float = 1.0 - pose.still * 0.85             # how much it breathes and sways
	# twitching: how much the joints shiver. Frozen while staring (tiny tremor), violent when hurt
	var twitch := 0.35
	match st:
		"chase", "screech":
			twitch = 1.0
		"flee":
			twitch = 0.8
		"stunned":
			twitch = 1.8
		"stalk":
			twitch = 0.15
	if staring > 0.0:
		twitch = 0.08
	var tj := clock * 9.0

	# glitches: now and then one limb or the head twists to a wrong angle for a moment
	glitch_timer -= delta
	if glitch_timer <= 0.0:
		glitch_timer = (1.5 if (st == "chase" or st == "flee") else (5.0 if st == "stalk" else 3.0)) + rng.randf() * 4.0
		var pool: Array = ["head"] if st == "stalk" else ["arm_l", "arm_r", "fore_l", "fore_r", "head", "neck"]
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
	var to_p := player.global_position - global_position
	var dist := Vector2(to_p.x, to_p.z).length()
	var slow_head: bool = st == "stalk" or staring > 0.0
	var interested: bool = st == "chase" or st == "screech" or st == "stalk" or st == "stunned" or staring > 0.0 \
		or (seen_target and dist < 20.0 and st != "flee")
	var look_rel := 0.0
	if pose.look > 0.4:
		if interested:
			# turned further than a neck should
			look_rel = clampf(wrapf(atan2(to_p.x, to_p.z) - yaw, -PI, PI), -2.3, 2.3)
		else:
			look_rel = sin(clock * 0.35) * 0.55 + (0.5 if moving else 0.0) * sin(clock * 0.9)
	head_hop -= delta
	if head_hop <= 0.0:
		# it snaps in hops, not a smooth pan; stalking and staring it barely twitches at all
		if slow_head:
			head_hop = rng.randf_range(1.2, 3.5)
		elif interested:
			head_hop = rng.randf_range(0.15, 0.5)
		else:
			head_hop = rng.randf_range(0.6, 1.5)
		head_yaw_goal = look_rel + rng.randf_range(-0.18, 0.18) * (0.3 if slow_head else 1.0)
		if not slow_head and rng.randf() < 0.2:
			head_yaw_goal += rng.randf_range(-0.5, 0.5)            # a wrong little overshoot
	else:
		head_yaw_goal = lerpf(head_yaw_goal, look_rel, minf(1.0, delta * (0.8 if slow_head else 3.0)))
	head_yaw += (head_yaw_goal - head_yaw) * (1.0 - exp(-(4.0 if slow_head else 22.0) * delta))

	# ---- spine: hunch, a heaving breath, a lopsided twist with the stride
	var breath: float = sin(clock * (1.4 + pose.hunch * 3.0)) * 0.06 * alive
	var sway: float = sin(clock * 1.1) * 0.03 * alive
	var thrash := 1.0 if st == "stunned" else 0.0
	_turn(_b("hip"), up, sin(phase) * 0.12 * w)
	_turn(_b("hip"), fwd, sin(phase) * 0.05 * w)
	_turn(_b("chest"), right, pose.hunch * 0.45 + breath + sway + _noise(1.0, tj) * 0.1 * twitch + thrash * _noise(3.0, clock * 14.0) * 0.3)
	_turn(_b("chest"), up, -sin(phase) * 0.12 * w)
	_turn(_b("chest"), fwd, peek_lean * 0.6 + sin(phase) * 0.06 * w + 0.05 * alive)
	# ---- neck and head: the maw stays aimed where it looks however far it is folded over
	var fold: float = pose.hunch * 0.45 + pose.neck * 0.5
	_turn(_b("neck"), right, pose.neck * 0.5 + _noise(30.0, tj) * 0.1 * twitch)
	_turn(_b("neck"), up, head_yaw * 0.35)
	_turn(_b("neck"), fwd, pose.head_roll * 0.25)
	_turn(_b("head"), right, pose.head_pitch * 0.6 - fold * pose.look * 0.75 + _noise(31.0, tj) * 0.2 * twitch)
	_turn(_b("head"), up, head_yaw * 0.65)
	_turn(_b("head"), fwd, pose.head_roll * 0.75 + _noise(32.0, tj) * 0.15 * twitch)
	_glitch_turn("neck", g_angle)
	_glitch_turn("head", g_angle)

	# ---- legs: it limps, one long stride and one short dragging one, knees bent when it stalks
	for side in ["l", "r"]:
		var ph := phase + (0.0 if side == "l" else PI)
		var limp := 1.0 if side == "l" else 0.55
		var swing := sin(ph) * (0.35 + run * 0.35) * w * limp
		var knee: float = maxf(0.0, -cos(ph)) * (0.6 if side == "l" else 0.3) * w + pose.crouch * 0.7
		_turn(_b("thigh_" + side), right, -swing - pose.crouch * 0.5)
		_turn(_b("shin_" + side), right, knee)
		_turn(_b("foot_" + side), right, swing * 0.3 - (0.12 if (side == "r" and moving) else 0.0))

	# ---- arms: a loose pendulum when it walks; running, alternating claws, each a beat out of step
	var clawing := (1.0 if (st == "chase" and lunge <= 0.0 and lunge_windup <= 0.0) else 0.0) * maxf(w, 0.4 * run)
	for side in ["a", "b"]:
		var arm_side := "l" if side == "a" else "r"
		var sgn := 1.0 if arm_side == "l" else -1.0
		var seed_v := 10.0 if side == "a" else 20.0
		var ph2 := phase + (PI if arm_side == "l" else 0.0)
		var hang := sin(ph2) * 0.3 * w * (1.0 - clawing)
		var claw_swing := sin(ph2) * 0.4 * clawing
		var reach: float = pose["reach_" + side] + hang + claw_swing + _noise(seed_v, tj) * 0.15 * twitch \
			+ thrash * _noise(seed_v, clock * 12.0) * 0.9
		var out: float = pose["out_" + side] + sin(clock * 0.9 + (0.0 if side == "a" else 2.0)) * 0.04 * alive
		var elbow: float = pose["elbow_" + side] + maxf(0.0, -sin(ph2)) * clawing * 0.9 \
			+ sin(ph2 + 1.0) * 0.25 * w * (1.0 - clawing) + _noise(seed_v + 3.0, tj) * 0.25 * twitch
		_turn(_b("arm_" + arm_side), right, -(reach * 0.9))
		_turn(_b("arm_" + arm_side), fwd, sgn * out * 0.6)
		_turn(_b("fore_" + arm_side), right, -(elbow * 0.9 + reach * 0.2))
		_glitch_turn("arm_" + arm_side, g_angle * sgn)
		_glitch_turn("fore_" + arm_side, g_angle * sgn)
		# fingers curl into a claw and ripple like a spider's legs
		var fingers: Array = bones.get("fingers_" + arm_side, [])
		for i in fingers.size():
			var curl: float = (sin(clock * (2.5 if st == "stalk" else 5.0) + float(i) * 1.7) * 0.3 * (0.4 + alive * 0.6) + pose.claw) * 0.6
			_turn(fingers[i], right, -curl)
	# crouch sinks the whole body; a breathing bob and the step bounce ride on top
	visual.position.y = -pose.crouch * 0.5 + absf(sin(phase)) * 0.06 * w + breath * 0.15

# ================================================================= navigation
func blocked(cx: int, cz: int) -> bool:
	return nav.blocked(cx, cz)

func set_goal(x: float, z: float) -> void:
	goal = Vector3(x, 0.0, z)
	var gx := GridNav.cell(x)
	var gz := GridNav.cell(z)
	if not blocked(gx, gz):
		return
	var best := INF
	for ox in range(-2, 3):
		for oz in range(-2, 3):
			if blocked(gx + ox, gz + oz):
				continue
			var wx := (gx + ox) * CELL
			var wz := (gz + oz) * CELL
			var d := Vector2(wx - x, wz - z).length()
			if d < best:
				best = d
				goal = Vector3(wx, 0.0, wz)

# Direction to walk: straight at the goal when it's in view, otherwise the farthest visible cell
# a few steps down the flow field (smooth corners)
func steer(delta: float) -> Vector3:
	var p := global_position
	var gx := GridNav.cell(goal.x)
	var gz := GridNav.cell(goal.z)
	var key := gx * n + gz
	flow_timer -= delta
	if key != goal_key or flow_timer <= 0.0:
		goal_key = key
		flow_timer = 0.5
		goal_reachable = nav.bfs(gx, gz, flow)
	if Vector2(goal.x - p.x, goal.z - p.z).length() < 10.0 and nav.clear_line(p.x, p.z, goal.x, goal.z):
		return Vector3(goal.x - p.x, 0.0, goal.z - p.z)
	var x := GridNav.cell(p.x)
	var z := GridNav.cell(p.z)
	var have := false
	var bx := 0.0
	var bz := 0.0
	for step in 4:
		var here := flow[x * n + z] if (x >= 0 and z >= 0 and x < n and z < n) else -1
		var nx := -1
		var nz := -1
		var best: float = INF if here < 0 else float(here)
		for o in GridNav.NEIGHBOURS:
			var ax: int = x + o.x
			var az: int = z + o.y
			if ax < 0 or az < 0 or ax >= n or az >= n:
				continue
			var v := flow[ax * n + az]
			if v >= 0 and v < best:
				best = v
				nx = ax
				nz = az
		if nx < 0:
			break
		x = nx
		z = nz
		var wx := x * CELL
		var wz := z * CELL
		if step == 0 or nav.clear_line(p.x, p.z, wx, wz):
			bx = wx
			bz = wz
			have = true
		else:
			break
	if not have:
		return Vector3(goal.x - p.x, 0.0, goal.z - p.z)
	return Vector3(bx - p.x, 0.0, bz - p.z)

func vkey(x: int, z: int) -> int:
	return x * n + z

func mark_visited() -> void:
	var gx := GridNav.cell(global_position.x)
	var gz := GridNav.cell(global_position.z)
	for ox in range(-2, 3):
		for oz in range(-2, 3):
			visited[vkey(gx + ox, gz + oz)] = roam_clock
	prune_timer -= 1.0
	if prune_timer <= 0.0:
		prune_timer = 300.0
		for k in visited.keys():
			if roam_clock - visited[k] > 400.0:
				visited.erase(k)

func note_interest(x: float, z: float) -> void:
	interest.x = x
	interest.z = z
	interest.at = roam_clock

# Best of a handful of candidate spots 4-20 cells away, scored on how long since it last went
# there, whether it's a junction, and how close it is to what interests it
func roam_spot() -> bool:
	var p := global_position
	if not nav.bfs(GridNav.cell(p.x), GridNav.cell(p.z), reach):
		return false
	var options: Array = []
	for x in range(1, n - 1):
		for z in range(1, n - 1):
			var d := reach[x * n + z]
			if d >= 4 and d <= 20:
				options.append(x * n + z)
	if options.is_empty():
		return false
	var who := player.global_position
	var menace := since_encounter > MENACE_TIME
	var interest_fresh: bool = roam_clock - interest.at < 70.0
	var best := -1
	var best_score := -INF
	for i in 16:
		var k: int = options[rng.randi() % options.size()]
		var gx := k / n
		var gz := k % n
		var wx := gx * CELL
		var wz := gz * CELL
		var since: float = roam_clock - visited.get(vkey(gx, gz), -200.0)
		var score := minf(1.0, since / 150.0) * 2.0 + rng.randf() * 0.4
		var open := 0
		for o in GridNav.NEIGHBOURS:
			if not blocked(gx + o.x, gz + o.y):
				open += 1
		if open >= 3:
			score += 0.35
		if interest_fresh:
			score += maxf(0.0, 1.0 - Vector2(wx - interest.x, wz - interest.z).length() / (10.0 * CELL)) * 1.6
		if menace:
			score += maxf(0.0, 1.0 - Vector2(wx - who.x, wz - who.z).length() / (9.0 * CELL)) * 1.2
		if reach[k] < 6:
			score -= 0.4
		if score > best_score:
			best_score = score
			best = k
	set_goal((best / n) * CELL, (best % n) * CELL)
	return true

# A random reachable floor spot between min_cells and max_cells of path away, optionally close to `near`
func pick_spot(min_cells: int, max_cells: int, near = null, near_cells := 0.0) -> bool:
	var p := global_position
	if not nav.bfs(GridNav.cell(p.x), GridNav.cell(p.z), reach):
		return false
	var options: Array = []
	for x in range(1, n - 1):
		for z in range(1, n - 1):
			var d := reach[x * n + z]
			if d < min_cells or d > max_cells:
				continue
			if near != null and Vector2(x * CELL - near.x, z * CELL - near.z).length() > near_cells * CELL:
				continue
			options.append(x * n + z)
	if options.is_empty():
		return false
	var k: int = options[rng.randi() % options.size()]
	set_goal((k / n) * CELL, (k % n) * CELL)
	return true

# ================================================================= senses
func hear(pos: Vector3, radius: float) -> void:
	if entity_noises.size() < 16:
		entity_noises.append({"x": pos.x, "z": pos.z, "r": radius})

func gather_target() -> void:
	tgt.pos = player.global_position
	tgt.moving = player.is_moving
	tgt.sprinting = player.is_sprinting
	tgt.crouching = player.is_crouching
	tgt.torch = player.flash_on and player.battery > 0.0
	tgt.lit = player.light_level
	tgt.look = -player.cam.global_transform.basis.z

# Returns the loudest thing it heard this think, or null
func perceive(dt: float):
	var p := global_position
	var fwd_x := sin(yaw)
	var fwd_z := cos(yaw)
	var best := false
	var best_score := 0.0
	if not player.dead:
		var dx: float = tgt.pos.x - p.x
		var dz: float = tgt.pos.z - p.z
		var dist := Vector2(dx, dz).length()
		var rng_m := SIGHT_RANGE
		if tgt.torch: rng_m *= TORCH_SIGHT_BONUS
		if tgt.lit > 0.5: rng_m *= 1.2
		if tgt.crouching: rng_m *= CROUCH_SIGHT
		if not tgt.moving and not tgt.torch: rng_m = minf(rng_m, STILL_SIGHT)
		if state == "chase": rng_m *= 1.5
		if winded > 0.0: rng_m *= 0.55
		if dist <= rng_m:
			var cos_a := (dx * fwd_x + dz * fwd_z) / dist if dist > 0.001 else 1.0
			var in_cone := cos_a > cos(SIGHT_FOV / 2.0) or dist < 2.5 or state == "chase"
			if in_cone and nav.clear_line(p.x, p.z, tgt.pos.x, tgt.pos.z):
				best = true
				best_score = (1.0 - dist / rng_m) * (1.0 if tgt.moving else 0.5) * (1.4 if tgt.torch else 1.0)
	if best:
		awareness = minf(0.85 if winded > 0.0 else 1.0, awareness + AWARENESS_RISE * (0.25 + best_score) * dt * (0.4 if winded > 0.0 else 1.0))
		if seen_target:
			last_vel = Vector3(tgt.pos.x - last_known.x, 0.0, tgt.pos.z - last_known.z) / maxf(dt, 0.001)
		else:
			last_vel = Vector3.ZERO
		last_known = Vector3(tgt.pos.x, 0.0, tgt.pos.z)
		last_seen_time = 0.0
	else:
		awareness = maxf(0.0, awareness - AWARENESS_FALL * dt)
		last_seen_time += dt
	seen_target = best

	# Hearing: footsteps while moving, plus queued noises (gunshots)
	var res := {"heard": null, "score": 0.0}
	if not player.dead and tgt.moving:
		_consider_noise(res, tgt.pos.x, tgt.pos.z, HEAR_SPRINT if tgt.sprinting else (HEAR_CROUCH if tgt.crouching else HEAR_WALK))
	for nz in entity_noises:
		_consider_noise(res, nz.x, nz.z, nz.r)
	entity_noises.clear()
	return res.heard

func _consider_noise(res: Dictionary, x: float, z: float, radius: float) -> void:
	var p := global_position
	var d := Vector2(x - p.x, z - p.z).length()
	var r: float = (radius if nav.clear_line(p.x, p.z, x, z) else radius * 0.65) * (0.6 if winded > 0.0 else 1.0)
	if d > r:
		return
	var score := radius * (1.0 - d / r)
	if score > res.score:
		res.score = score
		res.heard = {"x": x, "z": z, "radius": radius}

# ================================================================= state machine
func set_state(s: String) -> void:
	if state == s:
		return
	state = s
	state_time = 0.0
	pause = 0.0
	look_yaw = NAN

func update_occlusion(delta: float) -> void:
	occl_timer -= delta
	if occl_timer > 0.0:
		return
	occl_timer = 0.05
	var ex := global_position.x
	var ez := global_position.z
	var px := player.global_position.x
	var pz := player.global_position.z
	var dx := ex - px
	var dz := ez - pz
	var l := maxf(sqrt(dx * dx + dz * dz), 0.001)
	var sx := -dz / l * 0.6
	var sz := dx / l * 0.6
	var blocked_all: bool = not player.dead and not nav.clear_line(px, pz, ex, ez) \
		and not nav.clear_line(px, pz, ex + sx, ez + sz) and not nav.clear_line(px, pz, ex - sx, ez - sz)
	scares.set_entity_occlusion(blocked_all)

# Its voice, driven by its state. One call at a time; the detection scream and hurt cry cut in.
func vocalize(delta: float, st: String) -> void:
	update_occlusion(delta)
	var pos := global_position + Vector3(0, 2.4, 0)
	scares.entity_move(pos)
	var d := INF if player.dead else pos.distance_to(player.global_position)
	if st != voice_state:
		var was := voice_state
		voice_state = st
		if st == "screech":
			scares.entity_call("scream", pos, true)
			scares.startle(0.4)
		elif st == "chase" and was != "screech":
			scares.entity_call("scream", pos, true)
			scares.startle(0.4)
		elif st == "stunned":
			scares.entity_call("hurt", pos, true)
		elif st == "flee":
			scares.entity_call("flee", pos, true)
		voice_timer = (1.5 + rng.randf() * 1.5) if st == "chase" else (2.0 if st == "stalk" else 4.0 + rng.randf() * 4.0)
		return
	voice_timer -= delta
	if voice_timer > 0.0 or d > 45.0:
		return
	if st == "chase":
		if scares.entity_call("chase", pos):
			voice_timer = 3.5 + rng.randf() * 3.5
	elif st == "stalk":
		if speed_now < 0.6 and d < 40.0:
			var dx := pos.x - player.global_position.x
			var dz := pos.z - player.global_position.z
			var l := maxf(sqrt(dx * dx + dz * dz), 0.001)
			var ear := Vector3(player.global_position.x + dx / l * 1.2, 1.7, player.global_position.z + dz / l * 1.2)
			if scares.entity_whisper(pos, ear):
				voice_timer = 4.0 + rng.randf() * 4.0
		elif d < 22.0 and scares.entity_call("stalk", pos):
			voice_timer = 7.0 + rng.randf() * 6.0
	elif st == "roam" or st == "investigate" or st == "search":
		if d < 32.0 and scares.entity_call("idle", pos):
			voice_timer = 8.0 + rng.randf() * 10.0
	if voice_timer <= 0.0:
		voice_timer = 1.0

# It lost you: stop chasing, catch its breath, and wander off toward where you were heading
func give_up() -> void:
	far_timer = 0.0
	winded = WINDED_TIME
	awareness = 0.0
	enraged = 0.0
	note_interest(last_known.x + last_vel.x * 2.0, last_known.z + last_vel.z * 2.0)
	set_state("roam")
	pause = 1.5
	look_yaw = yaw + (-2.0 if rng.randf() < 0.5 else 2.0)
	if not pick_spot(3, 12, interest, 5.0):
		roam_spot()

# ---------------------------------------------------------------- stalking
# A corner near `who`: an open cell C they can see, next to an open cell H they can't.
# Walking from H toward C, the first point in their view is the edge of the wall.
func find_stalk_spot(who: Vector3, anywhere := false) -> bool:
	var p := global_position
	var walkable: bool = nav.bfs(GridNav.cell(p.x), GridNav.cell(p.z), reach)
	if not walkable and not anywhere:
		return false
	var tcx := GridNav.cell(who.x)
	var tcz := GridNav.cell(who.z)
	var R := ceili(STALK_MAX_DIST / CELL)
	var best_score := -INF
	var found := false
	for gx in range(tcx - R, tcx + R + 1):
		for gz in range(tcz - R, tcz + R + 1):
			if gx < 1 or gz < 1 or gx >= n - 1 or gz >= n - 1:
				continue
			if not _stalk_open(gx, gz, anywhere):
				continue
			var wx := gx * CELL
			var wz := gz * CELL
			var d := Vector2(wx - who.x, wz - who.z).length()
			if d < STALK_MIN_DIST or d > STALK_MAX_DIST or not nav.clear_line(wx, wz, who.x, who.z):
				continue
			for o in GridNav.NEIGHBOURS:
				var hx: int = gx + o.x
				var hz: int = gz + o.y
				if hx < 0 or hz < 0 or hx >= n or hz >= n or not _stalk_open(hx, hz, anywhere):
					continue
				var hwx := hx * CELL
				var hwz := hz * CELL
				if nav.clear_line(hwx, hwz, who.x, who.z):
					continue
				var edge := -1.0
				var s := 0.05
				while s <= 1.001:
					if nav.clear_line(hwx + (wx - hwx) * s, hwz + (wz - hwz) * s, who.x, who.z):
						edge = s * CELL
						break
					s += 0.05
				if edge < 0.0:
					continue
				# leaning out sideways across their view beats stepping straight toward them
				var sx := float(-o.x)
				var sz := float(-o.y)
				var side := absf(sx * (who.z - wz) - sz * (who.x - wx)) / d
				var score := side * 1.5 - absf(d - 15.0) / 15.0 - (0.0 if anywhere else reach[hx * n + hz] / 40.0) + rng.randf() * 0.4
				if score <= best_score:
					continue
				best_score = score
				found = true
				stalk_side = Vector3(sx, 0.0, sz)
				stalk_hide = Vector3(hwx + sx * maxf(0.0, edge - 0.9), 0.0, hwz + sz * maxf(0.0, edge - 0.9))
				stalk_peek = Vector3(hwx + sx * (edge + 0.15), 0.0, hwz + sz * (edge + 0.15))
	if not found:
		return false
	peek_lean_target = 0.0
	peek_amt = 0.0
	set_goal(stalk_hide.x, stalk_hide.z)
	return true

func _stalk_open(x: int, z: int, anywhere: bool) -> bool:
	return not blocked(x, z) if anywhere else reach[x * n + z] >= 0

func begin_stalk(teleport := false) -> bool:
	if player.dead:
		return false
	var d := Vector2(player.global_position.x - global_position.x, player.global_position.z - global_position.z).length()
	if not teleport and d > STALK_MAX_DIST * 3.0:
		return false
	if not find_stalk_spot(player.global_position, teleport):
		return false
	if teleport:
		global_position = stalk_hide
		vel = Vector3.ZERO
		goal_key = -1
	set_state("stalk")
	stalk_active = true
	stalk_phase = "approach"
	stalk_watched = 0.0
	stalk_lost = 0.0
	stalk_moves = 0
	return true

# Caught: turn and run somewhere far from them and out of their sight.
# `from` = something else it's running from (THE MANNEQUIN)
func start_flee(from = null) -> void:
	var who: Vector3 = from if from != null else player.global_position
	var watcher: bool = from == null and stalk_active
	set_state("flee")
	stalk_active = false
	peek_lean_target = 0.0
	awareness = 0.0
	stalk_cooldown = STALK_COOLDOWN * (1.0 + rng.randf() * 0.6)
	var p := global_position
	if nav.bfs(GridNav.cell(p.x), GridNav.cell(p.z), reach):
		var best_k := -1
		var best_score := -INF
		for i in 200:
			var k := rng.randi() % (n * n)
			var d := reach[k]
			if d < 5 or d > 30:
				continue
			var wx := (k / n) * CELL
			var wz := (k % n) * CELL
			var score := Vector2(wx - who.x, wz - who.z).length() - Vector2(wx - p.x, wz - p.z).length() * 0.5 \
				- (15.0 if nav.clear_line(wx, wz, who.x, who.z) else 0.0)
			if score > best_score:
				best_score = score
				best_k = k
		if best_k >= 0:
			set_goal((best_k / n) * CELL, (best_k % n) * CELL)
		else:
			pick_spot(4, 20)
	if watcher:
		scares.startle(0.3)

func end_flee() -> void:
	set_state("roam")
	awareness = 0.0
	winded = WINDED_TIME
	if not roam_spot():
		pick_spot(5, 18)

# Is the survivor looking (nearly) straight at it, from under 40 m?
func looking_at_me(cos_limit: float) -> bool:
	var p := global_position
	var dx: float = p.x - tgt.pos.x
	var dz: float = p.z - tgt.pos.z
	var d := Vector2(dx, dz).length()
	var look := Vector2(tgt.look.x, tgt.look.z)
	var l := look.length() * d
	var dot: float = (look.x * dx + look.y * dz) / (l if l > 0.0 else 1.0)
	return d < 40.0 and dot > cos_limit

func stalk_is_watched() -> bool:
	var p := global_position
	if not nav.clear_line(p.x, p.z, tgt.pos.x, tgt.pos.z):
		return false
	return looking_at_me(0.96)

# The peek: it doesn't just slide out. It waits hidden, eases past the edge in stop-motion creeps,
# holds and watches, and pulls back into cover the moment you turn toward it (before it is caught),
# then tries again a little later, bolder each time.
func _update_peek(dt: float) -> void:
	var gazed := looking_at_me(0.8)          # in the cone of your view, even if you haven't quite focused
	peek_gaze = peek_gaze + dt if gazed else maxf(0.0, peek_gaze - dt * 0.7)
	peek_timer -= dt
	match peek_mode:
		"hide":
			peek_amt = maxf(0.0, peek_amt - dt * 1.6)
			if peek_timer <= 0.0 and not gazed:
				peek_mode = "creep"
				peek_step = 0.0
		"creep":
			# stop-motion: hold, then a quick shuffle further out
			peek_step -= dt
			if peek_step <= 0.0:
				peek_amt = minf(1.0, peek_amt + rng.randf_range(0.1, 0.28))
				peek_step = rng.randf_range(0.3, 1.1)
			if peek_amt >= 1.0:
				peek_mode = "watch"
				peek_timer = rng.randf_range(2.5, 6.0)
			elif peek_gaze > 0.35 + 0.25 * peek_count:
				_peek_retreat()
		"watch":
			# unblinking, with a tiny creep forward and back
			peek_amt = clampf(0.98 + sin(clock * 1.3) * 0.04, 0.0, 1.0)
			if peek_gaze > 0.5 + 0.3 * peek_count:
				_peek_retreat()
			elif peek_timer <= 0.0:
				# lose interest for a moment, then look again from cover
				peek_mode = "hide"
				peek_timer = rng.randf_range(2.0, 4.5)

func _peek_retreat() -> void:
	peek_mode = "hide"
	peek_count += 1
	peek_gaze = 0.0
	peek_timer = rng.randf_range(2.5, 5.0)

func think_stalk(dt: float) -> void:
	if not stalk_active or player.dead:
		end_flee()
		return
	var p := global_position
	var d := Vector2(tgt.pos.x - p.x, tgt.pos.z - p.z).length()
	if d < STALK_FLUSH_DIST:
		start_flee()
		return
	if stalk_is_watched():
		stalk_watched += dt
		# caught sneaking up: it runs at once. Watching from its corner: a beat of eye contact first
		if (stalk_phase == "approach" and state_time > 1.0) or stalk_watched > STALK_WATCHED:
			start_flee()
			return
	else:
		stalk_watched = maxf(0.0, stalk_watched - dt * 0.5)
	if stalk_phase == "approach":
		if Vector2(stalk_hide.x - p.x, stalk_hide.z - p.z).length() < 0.7:
			stalk_phase = "peek"
			state_time = 0.0
			peek_mode = "hide"
			peek_amt = 0.0
			peek_timer = rng.randf_range(1.2, 2.8)
			peek_step = 0.0
			peek_gaze = 0.0
			peek_count = 0
		elif state_time > 30.0 or not goal_reachable:
			end_flee()
		return
	_update_peek(dt)
	# peeking: they moved out of its view -- find a new corner, or give up
	if not nav.clear_line(stalk_peek.x, stalk_peek.z, tgt.pos.x, tgt.pos.z):
		stalk_lost += dt
		if stalk_lost > 2.5:
			stalk_lost = 0.0
			stalk_moves += 1
			if stalk_moves > 2 or not find_stalk_spot(tgt.pos):
				end_flee()
			else:
				stalk_phase = "approach"
				state_time = 0.0
	else:
		stalk_lost = 0.0
	if state == "stalk" and state_time > STALK_TIME:
		start_flee()

func think(dt: float) -> void:
	var heard = perceive(dt)
	state_time += dt
	since_encounter += dt
	roam_clock += dt
	winded = maxf(0.0, winded - dt)
	stalk_cooldown -= dt
	mark_visited()
	var p := global_position

	# Terrified of THE MANNEQUIN: while that hunts, this bolts from it, out of any state
	fear_timer -= dt
	if fear_timer <= 0.0 and state != "stunned" and mannequin != null and mannequin.has_method("threat"):
		var th = mannequin.threat()
		if th != null:
			var d := Vector2(th.x - p.x, th.z - p.z).length()
			if d < MANNEQUIN_FEAR_RANGE and (d < 4.0 or nav.clear_line(p.x, p.z, th.x, th.z)) and (state != "flee" or d < 7.0):
				enraged = 0.0
				lunge = 0.0
				lunge_windup = 0.0
				staring = 0.0
				start_flee(th)
				fear_timer = 1.5

	match state:
		"roam", "investigate", "search":
			if awareness >= 1.0 or (enraged > 0.0 and seen_target):
				since_encounter = 0.0
				set_state("chase" if enraged > 0.0 else "screech")
			elif seen_target and awareness > 0.3:
				# a glimpse: turn and walk over to look
				set_state("investigate")
				set_goal(last_known.x, last_known.z)
			elif heard != null and (state != "investigate" or heard.radius >= HEAR_SPRINT):
				set_state("investigate")
				set_goal(heard.x, heard.z)
				note_interest(heard.x, heard.z)
				if heard.radius >= HEAR_GUNSHOT:
					awareness = maxf(awareness, 0.6)
			# now and then, instead of wandering, it goes to watch someone from a corner
			elif state == "roam" and stalk_cooldown <= 0.0 and winded <= 0.0 and rng.randf() < STALK_CHANCE * dt:
				if not begin_stalk():
					stalk_cooldown = 8.0
		"stalk":
			think_stalk(dt)
		"flee":
			if state_time > 8.0 or Vector2(goal.x - p.x, goal.z - p.z).length() < 1.2 or not goal_reachable:
				end_flee()
		"screech":
			if state_time > 0.9:
				set_state("chase")
		"chase":
			if seen_target:
				set_goal(tgt.pos.x, tgt.pos.z)
				since_encounter = 0.0
				var d := Vector2(tgt.pos.x - p.x, tgt.pos.z - p.z).length()
				if d < LUNGE_RANGE and lunge <= 0.0 and lunge_windup <= 0.0:
					lunge_windup = 0.28
			else:
				# head for where they were going
				var lead := minf(last_seen_time, 1.5)
				set_goal(last_known.x + last_vel.x * lead, last_known.z + last_vel.z * lead)
				if heard != null:
					last_known = Vector3(heard.x, 0.0, heard.z)
					last_seen_time = minf(last_seen_time, 1.0)
				if last_seen_time > LOSE_TRACK_TIME:
					give_up()
			# outrun: far behind for a while and it gives up on its own
			var nearest := Vector2(tgt.pos.x - p.x, tgt.pos.z - p.z).length()
			if nearest > GIVE_UP_DISTANCE:
				far_timer += dt
				if far_timer > GIVE_UP_TIME:
					give_up()
			else:
				far_timer = 0.0

	# Being watched: look straight at it from a distance and it stops dead and stares back
	staring = maxf(0.0, staring - dt)
	stare_cooldown -= dt
	if (state == "roam" or state == "search" or state == "investigate") and staring <= 0.0 and stare_cooldown <= 0.0 and not player.dead:
		var dx: float = p.x - tgt.pos.x
		var dz: float = p.z - tgt.pos.z
		var d2 := Vector2(dx, dz).length()
		if d2 > 5.0 and d2 < 26.0 and looking_at_me(0.95) and nav.clear_line(p.x, p.z, tgt.pos.x, tgt.pos.z):
			staring = 1.6 + rng.randf() * 1.8
			stare_cooldown = 10.0 + rng.randf() * 8.0
			pause = staring
			look_yaw = atan2(-dx, -dz)

	# arrival / idle behaviour for the wandering states
	var at_goal := Vector2(goal.x - p.x, goal.z - p.z).length() < 0.9 or not goal_reachable
	if state == "roam" and at_goal and pause <= 0.0:
		pause = 1.0 + rng.randf() * 2.5
		look_yaw = yaw + (rng.randf() - 0.5) * 2.5
		if not roam_spot() and not pick_spot(5, 18):
			pick_spot(1, 60)
	elif state == "investigate" and at_goal and pause <= 0.0:
		pause = 2.2
		look_yaw = yaw + (-1.3 if rng.randf() < 0.5 else 1.3)
		set_state("search")
		search_left = SEARCH_TIME * 0.5
		pause = 2.2
	elif state == "search":
		search_left -= dt
		if search_left <= 0.0:
			set_state("roam")
			roam_spot()
		elif at_goal and pause <= 0.0:
			pause = 1.0 + rng.randf() * 1.5
			look_yaw = yaw + (rng.randf() - 0.5) * 3.0
			if not pick_spot(1, 6, last_known, 4.0):
				pick_spot(1, 8)

# ================================================================= movement
func turn_toward(target_yaw: float, rate: float, delta: float) -> void:
	var d := wrapf(target_yaw - yaw, -PI, PI)
	yaw += clampf(d, -rate * delta, rate * delta)

func move(delta: float) -> void:
	var speed := 0.0
	var dir := Vector3.ZERO
	var p := global_position
	if pause > 0.0:
		pause -= delta
		if not is_nan(look_yaw):
			turn_toward(look_yaw, 2.0, delta)
	elif state == "stalk" and stalk_phase == "peek" and stalk_active:
		# face them and ease out past the edge of the wall, leaning the rest of the way
		turn_toward(atan2(tgt.pos.x - p.x, tgt.pos.z - p.z), 3.0, delta)
		var spot := stalk_hide.lerp(stalk_peek, peek_amt)
		dir = Vector3(spot.x - p.x, 0.0, spot.z - p.z)
		var d := dir.length()
		if d > 0.03:
			speed = minf(0.9, d * 2.5)
			dir /= d
		var right := stalk_side.x * cos(yaw) - stalk_side.z * sin(yaw)
		peek_lean_target = -signf(right) * 0.22 * peek_amt
	elif state == "screech":
		if seen_target:
			turn_toward(atan2(tgt.pos.x - p.x, tgt.pos.z - p.z), TURN_RATE, delta)
	else:
		speed = CHASE_SPEED if state == "chase" else (INVESTIGATE_SPEED if state == "investigate" else \
			(SEARCH_SPEED if state == "search" else (INVESTIGATE_SPEED if state == "stalk" else (FLEE_SPEED if state == "flee" else ROAM_SPEED))))
		if enraged > 0.0:
			speed = CHASE_SPEED
		dir = steer(delta)
		if lunge_windup > 0.0:
			lunge_windup -= delta
			speed *= 0.3
			if lunge_windup <= 0.0:
				lunge = 0.35
		if lunge > 0.0:
			lunge -= delta
			speed = LUNGE_SPEED
			if seen_target:
				dir = Vector3(tgt.pos.x - p.x, 0.0, tgt.pos.z - p.z)
		if dir.length_squared() > 0.0004:
			var want := atan2(dir.x, dir.z)
			turn_toward(want, TURN_RATE * (3.0 if state == "flee" else (1.5 if state == "chase" else 1.0)), delta)
			# slow down for sharp turns so it rounds corners instead of sliding
			var off := absf(wrapf(want - yaw, -PI, PI))
			speed *= maxf(0.75 if state == "flee" else 0.25, 1.0 - off / 1.6)
			dir = dir.normalized()
		else:
			speed = 0.0
	vel = vel.lerp(dir * speed, minf(1.0, delta * (16.0 if state == "flee" else 7.0)))
	if speed == 0.0:
		vel *= maxf(0.0, 1.0 - delta * 8.0)
	last_pos = global_position
	var np := global_position + vel * delta
	np = nav.resolve(np, RADIUS)
	np.y = 0.0
	global_position = np
	speed_now = last_pos.distance_to(global_position) / maxf(delta, 0.0001)

	# stuck on something while trying to move: pick somewhere else
	if speed > 0.5 and speed_now < 0.2:
		stuck_timer += delta
		if stuck_timer > 1.5:
			stuck_timer = 0.0
			if state == "stalk":
				end_flee()
			elif state != "chase":
				pick_spot(2, 12)
			goal_key = -1
	else:
		stuck_timer = 0.0

# ================================================================= per frame
func _physics_process(delta: float) -> void:
	if not Game.playing:
		return
	if grab_t >= 0.0:
		_update_grab(delta)
		return
	if not is_finite(global_position.x) or not is_finite(global_position.z):
		relocate()
		vel = Vector3.ZERO
	gather_target()
	if stun_timer > 0.0:
		stun_timer -= delta
		if stun_timer <= 0.0:
			enraged = 6.0
			awareness = 1.0
			set_state("chase")
			set_goal(last_known.x, last_known.z)
		animate(delta, 0.0, "stunned")
		vocalize(delta, "stunned")
		rotation.y = yaw
		update_fear(delta)
		return
	enraged = maxf(0.0, enraged - delta)
	think_timer -= delta
	if think_timer <= 0.0:
		var dt := 0.1 - think_timer
		think_timer = 0.1
		think(dt)
	move(delta)
	rotation.y = yaw
	animate(delta, speed_now, state)
	vocalize(delta, state)
	update_fear(delta)

# ---------------------------------------------------------------- fear, sanity, the kill
var static_timer := 0.0
var heart_timer := 0.0

func update_fear(delta: float) -> void:
	var dist := global_position.distance_to(player.global_position)
	var near: bool = dist < TERROR_DISTANCE and not player.dead
	var hunting := state == "chase" or state == "screech"
	var presence := 0.0 if player.dead else maxf(0.0, 1.0 - dist / 30.0)
	Game.presence += (minf(1.0, presence * (1.3 if hunting else 1.0)) * LOUDNESS - Game.presence) * minf(1.0, delta * 2.0)
	Game.hunted = hunting and dist < 40.0
	var terror := (1.0 - dist / TERROR_DISTANCE) if near else 0.0
	Game.terror = terror
	if near:
		player.sanity = maxf(0.0, player.sanity - 15.0 * terror * delta)
		static_timer -= delta
		if static_timer <= 0.0:
			scares.entity_static()
			static_timer = 0.12 + rng.randf() * (0.9 - 0.7 * terror)
		heart_timer += delta * (1.5 + terror * 2.5)
		if heart_timer > 1.0:
			scares.heartbeat(1.5)
			heart_timer = 0.0
		if player.sanity <= 0.0 and not player.dead:
			Game.kill_player("PSYCHOLOGICAL COLLAPSE")
	# fear channel for the post shader: terror, sanity and darkness
	var tremor := 0.25 * terror if (near and rng.randf() < 0.2) else 0.0
	var sanity_fear: float = (100.0 - player.sanity) / 100.0 * 0.6
	var dark_fear: float = maxf(0.0, (0.22 - player.light_level) / 0.22) * 0.25
	var psych := minf(0.85, sanity_fear + dark_fear)
	var target_fear := minf(1.0, maxf(maxf(terror * 0.85 + tremor, psych), Game.event_fear))
	Game.fear += (target_fear - Game.fear) * minf(1.0, delta * 6.0)

	if dist < KILL_DISTANCE and not player.dead and player.spawn_grace <= 0.0 and grab_t < 0.0 and stun_timer <= 0.0:
		_start_grab()

# The grab (js/game/grab.js): it doesn't just kill you, it seizes you, hauls you up and eats you,
# and the camera is yours to watch it happen, helpless.
#   0.0 - 0.5s  snatch  it snaps onto you; the view whips down to its FEET, FOV punch
#   0.5 - 2.9s  held    you are lifted while the view slowly climbs its body toward the head; the view
#                       rolls, breathes, smears and warps; heartbeat slows, the world muffles, a quiet
#                       flatline rises
#   2.9 - 3.4s  bite    the camera is dragged into its jaws; screaming + blood splatter, blood sprays
#                       through the level and stains the floor and walls
#   3.4 - 5.0s  fade    the edges close in to black
#   5.0s        death   the normal death sequence takes over (ragdoll, death camera, respawn)
const GRAB_SNATCH := 0.5
const GRAB_CLIMB_START := 0.4
const GRAB_CLIMB_END := 2.9
const GRAB_BITE_AT := 2.9
const GRAB_FLATLINE_AT := 1.7
const GRAB_FADE_AT := 3.5
const GRAB_TOTAL := 5.0
const GRAB_HOLD := 1.1                # metres between it and you
const GRAB_LIFT := 1.35               # metres you are raised
const GRAB_BASE_FOV := 75.0

var grab_pos := Vector3.ZERO
var grab_head_y := 3.9
var grab_beat := 0.0
var grab_flat := false
var grab_bitten := false
var grab_dir := Vector3.FORWARD
var grab_eye := 1.7

func _gsmooth(x: float) -> float:
	var c := clampf(x, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)

func _audio() -> Node:
	return get_parent().get_node_or_null("Audio")

# The entity has you: called from the collision check instead of an instant death
func _start_grab() -> void:
	grab_t = 0.0
	grab_beat = 0.0
	grab_flat = false
	grab_bitten = false
	player.frozen = true
	player.velocity = Vector3.ZERO
	grab_base = player.global_position
	grab_eye = (player.cam as Camera3D).position.y
	# it stands right at you, facing you
	var d := Vector3(player.global_position.x - global_position.x, 0.0, player.global_position.z - global_position.z)
	grab_dir = d.normalized() if d.length() > 0.001 else Vector3.FORWARD
	grab_pos = Vector3(player.global_position.x - grab_dir.x * GRAB_HOLD, global_position.y, player.global_position.z - grab_dir.z * GRAB_HOLD)
	# where its head is (its model is big): the view climbs there
	grab_head_y = maxf(1.5, MODEL_HEIGHT * 0.85)
	yaw = atan2(grab_dir.x, grab_dir.z)
	rotation.y = yaw
	vel = Vector3.ZERO
	stun_timer = 0.0
	var a := _audio()
	if a != null:
		a.set_muffled(true)
	scares.startle(1.0)
	scares.play_scare("staticHit", 1.0)
	scares.heartbeat(1.8)
	Game.fx_reset()
	Death.grab_begin()

func _update_grab(delta: float) -> void:
	grab_t += delta
	var t := grab_t
	var cam: Camera3D = player.cam
	var p := grab_base

	# the entity holds its pose: a strike animation, planted in front of you; it rears back to bite
	var rearing := t > GRAB_BITE_AT - 0.35 and t < GRAB_BITE_AT
	lunge_windup = 0.1 if rearing else 0.0
	lunge = 0.0 if rearing else 0.1
	global_position = global_position.lerp(grab_pos, minf(1.0, delta * 14.0))
	yaw = atan2(grab_dir.x, grab_dir.z)
	rotation.y = yaw
	animate(delta, 0.0, "chase")
	var e := global_position

	# camera: you are lifted off the floor and dragged toward it
	var rise := _gsmooth((t - 0.3) / 1.5)
	var bite := _gsmooth((t - GRAB_BITE_AT) / 0.4)
	var lift := GRAB_LIFT * rise + sin(t * 2.2) * 0.05 * rise
	var shake := 0.012 + 0.05 * _gsmooth((t - 0.5) / 2.0) + 0.16 * bite * (1.0 if t < GRAB_FADE_AT else 0.3)
	# ...and on the bite straight into its mouth, at the top of its head height
	var pull := 0.22 * rise + 0.6 * bite
	var mouth_y := e.y + grab_head_y * 0.86
	var base_y := p.y + grab_eye + lift
	var jit := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * shake
	var cam_pos := Vector3(
		p.x + (e.x - p.x) * pull + jit.x,
		base_y + (mouth_y - base_y) * bite + jit.y,
		p.z + (e.z - p.z) * pull + jit.z)

	# what it looks at: down at its feet on the snatch, then up its body to the head, then the jaws
	var climb := _gsmooth((t - GRAB_CLIMB_START) / (GRAB_CLIMB_END - GRAB_CLIMB_START))
	var look_y := e.y + 0.1 + (grab_head_y - 0.1) * climb
	var to := Vector3(e.x, look_y, e.z) - cam_pos
	var basis_now: Basis = cam.global_transform.basis.orthonormalized()
	if to.length_squared() > 0.0001:
		var want := Basis.looking_at(to.normalized(), Vector3.UP)
		basis_now = basis_now.slerp(want, _gsmooth(t / 0.18))
	# rolling and swaying as it shakes you, tipping further the longer it holds
	var roll := (sin(t * 5.3) * 0.05 + sin(t * 11.0) * 0.02) * _gsmooth((t - 0.4) / 0.8) \
		+ 0.32 * _gsmooth((t - 0.8) / 2.6) + sin(t * 27.0) * 0.06 * bite
	cam.global_transform = Transform3D(basis_now.rotated(basis_now.z, roll), cam_pos)

	# FOV: a punch on impact, a slow warp with each heartbeat, a jolt on the bite
	cam.fov = GRAB_BASE_FOV + 20.0 * exp(-t * 6.0) + 22.0 * _gsmooth((t - 0.5) / 2.2) \
		+ sin(t * 8.0) * 3.0 * _gsmooth((t - 0.5) / 1.0) + 14.0 * bite

	# screen distortion: smear, colour bleed, wobble, and the existing static/glitch pass
	var k := _gsmooth((t - 0.3) / 2.6)
	Game.fx_blur = k * 3.2 + bite * 2.0
	Game.fx_contrast = 1.0 + 0.35 * k
	Game.fx_sat = 1.0 - 0.5 * k + 0.6 * bite
	Game.fx_hue = sin(t * 9.0) * 14.0 * k - 8.0 * bite
	Game.fx_zoom = 1.03 + 0.05 * k + sin(t * 7.0) * 0.012 * k + 0.05 * bite
	Game.fx_skew = sin(t * 13.0) * 1.6 * k
	Game.glitch = minf(1.0, 0.5 + k)
	Game.fear = 1.0

	# the bite: screaming and blood splatter, blood on the glass
	if not grab_bitten and t >= GRAB_BITE_AT:
		grab_bitten = true
		scares.splat()
		scares.startle(1.0)
		Death.bite(Vector3(e.x + grab_dir.x * 0.4, e.y + grab_head_y * 0.8, e.z + grab_dir.z * 0.4), p, cam_pos)
	if grab_bitten:
		# blood keeps raining from where you hang, and every drop that lands leaves a stain
		if randf() < delta * 14.0:
			Death.bite_drop(Vector3(p.x + randf_range(-0.3, 0.3), cam_pos.y - 0.4, p.z + randf_range(-0.3, 0.3)),
				Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)), randf_range(0.02, 0.05))
		if t < GRAB_BITE_AT + 1.2 and randf() < delta * 10.0:
			Death.bite_drop(Vector3(e.x, e.y + grab_head_y * 0.8, e.z),
				Vector3(randf_range(-2.5, 2.5), randf_range(1.0, 4.0), randf_range(-2.5, 2.5)), randf_range(0.02, 0.05))

	# heartbeat slows down as it goes on, until the flatline
	grab_beat -= delta
	if grab_beat <= 0.0 and t < GRAB_BITE_AT:
		grab_beat = 0.55 + 0.9 * _gsmooth(t / GRAB_FADE_AT)
		scares.heartbeat(1.7 - 0.7 * _gsmooth(t / GRAB_FADE_AT))
	if not grab_flat and t >= GRAB_FLATLINE_AT:
		grab_flat = true
		scares.flatline(GRAB_TOTAL - GRAB_FLATLINE_AT + 6.0)

	# the edges close in
	if t > GRAB_FADE_AT:
		Game.fx_fade = _gsmooth((t - GRAB_FADE_AT) / (GRAB_TOTAL - GRAB_FADE_AT))

	if t >= GRAB_TOTAL:
		_end_grab()

# Put the screen back to normal and hand over to the death sequence (js endGrab(true) + killPlayer)
func _end_grab() -> void:
	grab_t = -1.0
	lunge = 0.0
	lunge_windup = 0.0
	var cam: Camera3D = player.cam
	cam.fov = GRAB_BASE_FOV
	var a := _audio()
	if a != null:
		a.set_muffled(false)
	Game.kill_player("THE BACTERIA")
	run_away()   # it has fed: it bolts away from the body (it keeps running while you lie there)

# ================================================================= public API (dev / other systems)
func relocate() -> void:
	var sp: Array = level.level_data.get("entity", [n - 12, 18])
	global_position = Vector3(sp[0] * CELL, 0.0, sp[1] * CELL)
	goal_key = -1
	awareness = 0.0
	set_state("roam")
	pick_spot(3, 18)

func summon(x: float, z: float, tx: float, tz: float) -> void:
	global_position = Vector3(x, 0.0, z)
	vel = Vector3.ZERO
	stun_timer = 0.0
	enraged = 0.0
	yaw = atan2(tx - x, tz - z)
	rotation.y = yaw
	awareness = 1.0
	since_encounter = 0.0
	last_known = Vector3(tx, 0.0, tz)
	last_vel = Vector3.ZERO
	last_seen_time = 0.0
	goal_key = -1
	set_goal(tx, tz)
	state = "roam"
	set_state("screech")

func stun(seconds: float, kx: float, kz: float) -> void:
	stun_timer = maxf(stun_timer, seconds)
	global_position += Vector3(kx, 0.0, kz)
	global_position = nav.resolve(global_position, RADIUS)
	set_state("stunned")
	var l := maxf(Vector2(kx, kz).length(), 0.001)
	last_known = Vector3(global_position.x - kx / l * 8.0, 0.0, global_position.z - kz / l * 8.0)
	last_vel = Vector3.ZERO
	last_seen_time = 0.0
	yaw = atan2(-kx, -kz)

func run_away() -> void:
	stun_timer = 0.0
	enraged = 0.0
	pause = 0.0
	lunge = 0.0
	lunge_windup = 0.0
	start_flee()

func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.physical_keycode == KEY_F10:
		var f := -player.global_transform.basis.z
		var p := player.global_position + f * 14.0
		if nav.open_at(p.x, p.z):
			summon(p.x, p.z, player.global_position.x, player.global_position.z)
	elif e.physical_keycode == KEY_F4:
		gather_target()
		begin_stalk(true)
