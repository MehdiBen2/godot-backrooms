extends "res://scripts/Entities/bacteria/bacteria_skeleton.gd"
## THE BACTERIA's body, part 2: poses its skeleton procedurally every frame (js entity.js gait +
## poseTargets). bacteria_skeleton.gd loads howler.glb and provides the bones, IK and mist; this layer keeps
## only animation state and reads what the entity is doing from `e`.
##
## Gait: the stride is measured in metres walked, so planted feet don't skate. Steps get longer as it
## speeds up and a little shorter and quicker the closer it is to you; turning on the spot it still
## shuffles its feet round. Each foot lands with the leg stretched out, the body at its lowest, a dip of
## its whole weight (and `stepped`, the footfall sound's cue). It banks into turns and pitches forward as
## it surges ahead, while the head stays level, locked on what it's looking at.

signal stepped(weight: float, dragging: bool, run: float)   # dragging: the short, limping leg came down

const CHASE_SPEED := 6.0
const PIVOT := 0.7             # turning on the spot, its feet travel as if round a circle this wide

var phase := 0.0
var anim_time := 0.0
var anim_state := ""
var arm_s := {}                # per arm: reach / out / elbow, lagging behind the pose so the long arms swing with weight
var step_len := STRIDE
var step_side := 0
var gait_w := 0.0              # how much of the walk cycle is showing, eased in and out (no pop on setting off)
var glitch_timer := 2.0
var head_yaw := 0.0            # head turn relative to the body (jerks toward what it watches)
var head_yaw_goal := 0.0
var head_hop := 0.0
# ---- peeking round a corner (bacteria_stalk.gd says how far out it is: e.peek_amt)
var peek_lean := 0.0           # the chest leaning out past the edge, along the wall (e.stalk_side)
var peek_tilt := 0.0           # the head laid over on its side (+ = top toward its right)
var head_out := 0.0            # how far out the head is: it goes first, and snaps back first
var peek_prev := 0.0
var peek_rise := false         # creeping further out this frame
var ducked := 0.0              # > 0 just after it ducked back into cover: everything snaps in
var grip_w := 0.0              # its leading hand hooked round the wall's edge, 0 .. 1
var grip_hold := 0.0           # ducked away, its fingers stay on the edge this much longer
var grip_gone := false         # let go after ducking away; it takes hold again as it creeps back out
var grip_arm := ""             # "l" / "r": the arm that has hold
var grip_at := Vector3.ZERO    # the edge it took hold of (floor level) and how high: fixed as the body moves
var grip_n := Vector3.ZERO     # that corner's wall face and its way along it, kept while the hand lets go
var grip_s := Vector3.ZERO
var tap_clock := 0.0
var bank := 0.0                # leaning into a turn (+ = to its left)
var surge := 0.0               # pitching forward as it speeds up, back as it brakes
var stomp := 0.0               # the dip as a foot takes its weight, 1 on landing
var _prev_yaw := NAN
var _prev_speed := 0.0
# The pose it's aiming for, from its state and what it's doing (js poseTargets)
func _pose_targets(st: String, run: float, moving: bool) -> void:
	var P := pose_t
	P.hunch = 0.35 + run * 0.15; P.crouch = 0.0; P.neck = 0.1; P.head_pitch = -0.1; P.head_roll = 0.0
	P.look = 1.0; P.still = 0.0; P.claw = 0.3
	P.reach_a = 0.15; P.reach_b = 0.15; P.out_a = 0.06; P.out_b = 0.06; P.elbow_a = 0.25; P.elbow_b = 0.25
	P.shoulder_up = 0.0; P.arm_spread = 0.0; P.finger_splay = 0.0; P.duck_reach = 0.0
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
		if e.peek_dir == 0.0:
			# sneaking up on its corner: folded low, long arms carried low and ahead, head down
			P.hunch = 0.95; P.crouch = 0.4; P.neck = 0.3; P.head_pitch = -0.25; P.claw = 0.9
			P.reach_a = 0.45; P.reach_b = 0.45; P.out_a = 0.15; P.out_b = 0.15; P.elbow_a = 0.7; P.elbow_b = 0.7
		else:
			# pressed flat behind the corner, upright so its hunch clears the wall; the head is laid over on
			# its side by _peek_motion, the leading hand hooked round the edge by _grip_corner
			P.still = 1.0; P.hunch = 0.2; P.crouch = 0.7; P.neck = 0.25; P.head_pitch = -0.1; P.claw = 1.2
			# both arms hang close at its sides, out of sight, whenever a hand isn't hooked on the edge
			P.reach_a = -0.25; P.reach_b = -0.25; P.out_a = 0.1; P.out_b = 0.1; P.elbow_a = 0.5; P.elbow_b = 0.5
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
			# Violent rip: claws drive straight forward, each on its own side, tearing through the victim
			P.hunch = 1.45; P.crouch = 0.08; P.neck = 0.2; P.head_pitch = -0.2; P.claw = 2.4
			P.reach_a = 2.2; P.reach_b = 2.2; P.out_a = 0.12; P.out_b = 0.12; P.elbow_a = 0.3; P.elbow_b = 0.3
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
	step_len = (0.95 + run * 1.15) / 0.95 * stride * (1.0 - close * 0.2)
	if moving:
		phase += PI * gait_speed * delta / step_len
	# a foot lands where the legs are furthest apart (phase = PI/2 + k*PI)
	var side := floori((phase - PI * 0.5) / PI)
	if side != step_side:
		step_side = side
		if moving:
			stomp = 1.0
			# the feet alternate: one long stride, then the short leg it drags (see the legs below)
			stepped.emit((0.45 + run * 0.55) * (0.5 + close * 1.6) * (0.3 if quiet else 1.0), posmod(side, 2) == 1, run)
	# the weight settles slowly into the landed leg: something this big doesn't bounce back
	stomp = maxf(0.0, stomp - delta * 4.0)
	# leaning into turns like anything heavy running (only when it's actually moving), and into a surge
	var bank_goal := clampf(atan(move_speed * yaw_rate / 9.8) * 0.6, -0.3, 0.3)
	bank += (bank_goal - bank) * minf(1.0, delta * 5.0)
	surge += (clampf(accel * 0.025, -0.12, 0.2) - surge) * minf(1.0, delta * 4.0)

	_peek_motion(delta, st)
	_pose_targets(st, run, moving)
	_update_squeeze(delta, move_speed, st)
	if squeeze > 0.001:
		# under a low ceiling or arch: knees down, back rounded over, head carried low and forward,
		# hands rising up ahead of the head as if feeling out the low roof it's folding under
		pose_t.crouch += 0.45 * squeeze
		pose_t.hunch = minf(2.3, pose_t.hunch + 0.8 * squeeze)
		pose_t.neck += 0.35 * squeeze
		pose_t.head_pitch -= 0.15 * squeeze
		# whatever the state was asking for, a wide-flung / overhead arm pose would poke straight
		# through the low roof it's folded under: fold the arms back in as squeeze rises
		var fold: float = clampf(squeeze, 0.0, 1.0)
		pose_t.arm_spread *= 1.0 - fold
		pose_t.shoulder_up *= 1.0 - fold
		pose_t.out_a = lerpf(pose_t.out_a, minf(pose_t.out_a, 0.2), fold)
		pose_t.out_b = lerpf(pose_t.out_b, minf(pose_t.out_b, 0.2), fold)
		var arms_free: bool = st != "grab" and st != "screech" and e.lunge <= 0.0 and e.lunge_windup <= 0.0
		if arms_free:
			# squeeze itself can run well past 1 under a very low ceiling; the overlay below has to
			# stay bounded or it swings the arm past vertical and straight through the roof it's ducking under
			pose_t.duck_reach = fold
	# heavy: it eases between poses, only the scream, the hit and the grab snap
	var rate := 14.0 if (st == "screech" or st == "stunned" or st == "grab") else (9.0 if st == "chase" else (2.2 if quiet else 3.5))
	for k in pose:
		pose[k] = lerpf(pose[k], pose_t[k], 1.0 - exp(-rate * delta))
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
			var look_dir := Vector2(to_p.x, to_p.z).normalized()
			if st == "stalk" and e.peek_dir != 0.0:
				# behind its corner it looks along the wall to the edge; only leaning out does it turn to you
				var sd: Vector3 = e.stalk_side
				look_dir = look_dir.lerp(Vector2(sd.x, sd.z), 1.0 - head_out)
			# turned further than a neck should
			look_rel = clampf(wrapf(atan2(look_dir.x, look_dir.y) - e.yaw, -PI, PI), -2.3, 2.3)
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
	_turn(_b("chest"), fwd, sin(phase) * 0.08 * w + 0.05 * alive - bank * 0.5)
	# peeking: tipped straight along the wall toward the edge, whichever way it faces
	var lean_axis: Vector3 = global_transform.basis.inverse() * Vector3.UP.cross(e.stalk_side)
	if peek_lean > 0.0001 and lean_axis.length_squared() > 0.01:
		_turn(_b("chest"), lean_axis.normalized(), peek_lean * 0.85)

	# ---- neck and head: the maw stays aimed where it looks however far it is folded over
	var fold: float = pose.hunch * 0.45 + pose.neck * 0.5
	_turn(_b("neck"), right, pose.neck * 0.5 + _noise(30.0, tj) * 0.1 * twitch + screech_shiver * 1.3)
	_turn(_b("neck"), up, head_yaw * 0.35)
	_turn(_b("neck"), fwd, pose.head_roll * 0.25 + bank * 0.4 + peek_tilt * 0.35)
	_turn(_b("head"), right, pose.head_pitch * 0.6 - fold * pose.look * 0.75 - surge * 0.8 * pose.look + _noise(31.0, tj) * 0.2 * twitch)
	_turn(_b("head"), up, head_yaw * 0.65)
	_turn(_b("head"), fwd, pose.head_roll * 0.75 + bank * 0.5 + peek_tilt * 0.65 + _noise(32.0, tj) * 0.15 * twitch)
	_glitch_turn("neck", g_angle)
	_glitch_turn("head", g_angle)

	# ---- the whole body: crouch (and a low ceiling) sinks it, it bobs lowest as a foot strikes and
	# rises at midstance, and its weight rolls onto whichever leg is planted (the "l" leg mid-stance at
	# 0.95*PI). Set before the legs, so the planted feet below are solved against where the body really is.
	var gait_bob: float = -absf(sin(phase)) * (0.09 + run * 0.08) * w
	position.y = (-pose.crouch * 0.5 + gait_bob - land * 0.13 + breath * 0.15) * size_k - squeeze * 0.1 * model_h
	position.x = cos(phase - 0.95 * PI) * (0.07 - run * 0.03) * w * size_k * side_flip

	# ---- legs: realistic biped articulation with monstrous asymmetry and uncanny horror gait
	var pel_l: int = _b("pelvis_l")
	var pel_r: int = _b("pelvis_r")

	for leg in ["l", "r"]:
		var is_left: bool = leg == "l"
		var sgn := (1.0 if is_left else -1.0) * side_flip    # +1 = this leg is on its left (+X)
		var ph := wrapf(phase + (0.0 if is_left else PI), 0.0, TAU)

		# Stance phase: foot on ground (0.45*PI to 1.45*PI)
		# Swing phase: foot airborne (1.45*PI to 2.45*PI / 0.45*PI)
		var is_stance: bool = ph >= 0.45 * PI and ph < 1.45 * PI
		leg_phase[leg].stance = is_stance
		leg_phase[leg].prog = (ph - 0.45 * PI) / PI if is_stance else 0.0

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

	# the walk cycle above only says roughly where each foot goes; this pins them to the floor
	_plant_feet(w)

	# ---- arms: predatory alternating lunges when running; open arms threat when spotting
	var clawing := (1.0 if (st == "chase" and e.lunge <= 0.0 and e.lunge_windup <= 0.0) else 0.0) * maxf(w, 0.4 * run)
	var threat_spread: float = pose.get("arm_spread", 0.0)
	var f_splay: float = pose.get("finger_splay", 0.0)

	for arm in ["a", "b"]:
		var arm_side := "l" if arm == "a" else "r"
		var sgn := (1.0 if arm_side == "l" else -1.0) * side_flip    # +1 = this arm is on its left (+X)
		var seed_v := 10.0 if arm == "a" else 20.0
		var ph2 := phase + (PI if arm_side == "l" else 0.0)
		var swing_suppress: float = clampf(1.0 - threat_spread * 0.7, 0.0, 1.0)
		var hang := sin(ph2) * 0.3 * w * (1.0 - clawing) * swing_suppress
		var claw_swing := sin(ph2) * (0.75 * run if run > 0.3 else 0.4) * clawing * swing_suppress
		var reach_goal: float = pose["reach_" + arm] + hang + claw_swing
		var out_goal: float = pose["out_" + arm] + maxf(0.0, -bank * sgn) * 0.6 + threat_spread * 0.5
		var elbow_goal: float = pose["elbow_" + arm] + maxf(0.0, -sin(ph2)) * clawing * (1.2 * run if run > 0.3 else 0.9) * swing_suppress \
			+ sin(ph2 + 1.0) * 0.25 * w * (1.0 - clawing) * swing_suppress
		# the long arms are heavy: they trail the body's motion a beat and overshoot a little on the way
		if not arm_s.has(arm):
			arm_s[arm] = {"reach": reach_goal, "out": out_goal, "elbow": elbow_goal, "v": 0.0}
		var s: Dictionary = arm_s[arm]
		var om := 16.0 if (st == "grab" or st == "screech") else 8.0     # spring frequency, rad/s
		var dts := minf(delta, 0.05)
		s.v += ((reach_goal - s.reach) * om * om - s.v * 2.0 * 0.65 * om) * dts
		s.reach += s.v * dts
		var lag := 1.0 - exp(-om * dts)
		s.out += (out_goal - s.out) * lag
		s.elbow += (elbow_goal - s.elbow) * lag

		var reach: float = s.reach + _noise(seed_v, tj) * 0.18 * twitch + thrash * _noise(seed_v, clock * 12.0) * 0.9
		# never below a little outward: a negative "out" pulls the arm across its chest to the other side
		var out: float = maxf(0.06, s.out + sin(clock * 0.9 + (0.0 if arm == "a" else 2.0)) * 0.04 * alive)
		var open_yaw: float = sgn * maxf(0.0, threat_spread * 0.75 + screech_shiver * 0.4)
		var elbow: float = s.elbow + _noise(seed_v + 3.0, tj) * 0.25 * twitch

		# Single compound rotation for the upper arm (pitch, roll, yaw combined cleanly without overwriting)
		_turn_compound(_b("arm_" + arm_side), -(reach * 0.85), sgn * out * 0.65, open_yaw)

		# Forearm is a pure elbow hinge - pitch only, never twisted on other axes
		_turn(_b("fore_" + arm_side), right, -(elbow * 0.85 + reach * 0.15))

		# leaning out round a corner, the arm not on the edge hangs straight down instead of tipping with it
		if peek_lean > 0.0001 and lean_axis.length_squared() > 0.01 and (arm_side != grip_arm or grip_w <= 0.0):
			_turn(_b("arm_" + arm_side), lean_axis.normalized(), -peek_lean * 0.85)

		# ducking under a low ceiling or an arch's crown: both arms rise up ahead of the head, elbows
		# bending in, as if bracing against / feeling out the roof it's folding itself under
		var duck: float = clampf(pose.get("duck_reach", 0.0), 0.0, 1.0)
		if duck > 0.001:
			_turn(_b("arm_" + arm_side), right, -duck * 0.6)
			_turn(_b("arm_" + arm_side), fwd, sgn * duck * 0.15)
			_turn(_b("fore_" + arm_side), right, -duck * 0.5)

		# a glitching arm wrenches outward, never in across the body
		_glitch_turn("arm_" + arm_side, absf(g_angle) * sgn * 0.6)
		_glitch_turn("fore_" + arm_side, absf(g_angle) * sgn * 0.6)

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
			
			# splay apart: the inner (index) finger toward the body's midline, the outer (ring) away from it
			if idx_fingers.has(f_bone):
				_turn(f_bone, fwd, -sgn * f_splay * 0.18)
			elif ring_fingers.has(f_bone):
				_turn(f_bone, fwd, sgn * f_splay * 0.18)

	_grip_corner(delta, st)

# ================================================================= peeking round a corner
# The entity only says how far out it is (e.peek_amt, in stop-motion steps) and which way (e.peek_dir).
# This makes it read: the head goes first in a quick jerk and the chest follows, the head lies over flat on
# its side the further out it gets, slowly tipping as it watches; and when it ducks back (peek_amt dropping
# fast) the head and chest snap in together.
func _peek_motion(delta: float, st: String) -> void:
	var at_corner: bool = st == "stalk" and e.peek_dir != 0.0
	var amt: float = e.peek_amt if at_corner else 0.0
	if amt < peek_prev - maxf(delta, 0.02) * 1.5:
		ducked = 0.5
	peek_rise = amt > peek_prev + 0.001
	peek_prev = amt
	ducked = maxf(0.0, ducked - delta)
	var head_rate := 18.0 if ducked > 0.0 else (8.0 if amt > head_out else 3.0)
	head_out += (amt - head_out) * (1.0 - exp(-head_rate * delta))
	var lean_goal: float = 0.85 * amt if at_corner else 0.0
	peek_lean += (lean_goal - peek_lean) * (1.0 - exp(-(12.0 if ducked > 0.0 else 3.5) * delta))
	var tilt_goal := 0.0
	if at_corner:
		tilt_goal = -e.peek_dir * (lerpf(0.45, 1.5, head_out) + sin(clock * 0.6) * 0.18 * head_out)
	peek_tilt += (tilt_goal - peek_tilt) * (1.0 - exp(-(14.0 if ducked > 0.0 else 4.0) * delta))

# Which way to bow the gripping arm's elbow (a world direction for _arm_ik): of all the places the elbow
# could be with the wrist on the edge, the one that keeps it back behind the edge and out off the wall,
# jutting up like a folded insect leg. A fixed direction can't: the arm comes at the edge from all angles.
func _grip_elbow(wrist: Vector3, s: Vector3, n: Vector3) -> Vector3:
	var fingers: Array = bones.get("fingers_" + grip_arm, [])
	var A := get_bone_global_pos("arm_" + grip_arm)
	var B := get_bone_global_pos("fore_" + grip_arm)
	var l1 := A.distance_to(B)
	var l2 := B.distance_to(skel.global_transform * skel.get_bone_global_pose(fingers[0]).origin) if not fingers.is_empty() else l1
	var to := wrist - A
	var d := clampf(to.length(), absf(l1 - l2) + 0.001, (l1 + l2) * 0.999)
	var dir := to.normalized()
	var ca := clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var mid := A + dir * (l1 * ca)
	var r := l1 * sqrt(1.0 - ca * ca)
	var u := (Vector3.UP - dir * dir.y).normalized() if absf(dir.y) < 0.99 else (s - dir * dir.dot(s)).normalized()
	var v := dir.cross(u)
	var best := u
	var best_score := -INF
	for i in 16:
		var a := TAU * i / 16.0
		var off := u * cos(a) + v * sin(a)
		var el: Vector3 = mid + off * r - Vector3(grip_at.x, 0.0, grip_at.z)
		var score := minf(-el.dot(s), 0.6) + minf(el.dot(n), 0.6) * 1.5 + el.y * 0.3
		if score > best_score:
			best_score = score
			best = off
	return best

# The leading hand hooks round the wall's edge: the wrist on the corner, the long fingers wrapped round onto
# the face beyond, fanned along the edge with the claw tips dug in. It takes hold as soon as it reaches its
# corner, so the first you may see of it is the fingers. Every so often they drum on the wall one after
# another. When it ducks back they stay on the edge a moment longer, then slide back out of sight; they
# take hold again as it creeps back out.
func _grip_corner(delta: float, st: String) -> void:
	var n: Vector3 = e.stalk_wall_n
	var at_corner: bool = st == "stalk" and e.peek_dir != 0.0 and n != Vector3.ZERO
	var goal := 0.0
	if at_corner:
		if grip_w < 0.01:
			grip_arm = "l" if e.peek_dir * side_flip > 0.0 else "r"
		if ducked > 0.0 and grip_hold <= 0.0 and not grip_gone and grip_w > 0.5:
			grip_hold = rng.randf_range(0.9, 1.6)
		if peek_rise:
			grip_gone = false
			grip_hold = 0.0
		elif grip_hold > 0.0:
			grip_hold -= delta
			if grip_hold <= 0.0:
				grip_gone = true
		goal = 0.0 if grip_gone else 1.0
	else:
		grip_hold = 0.0
		grip_gone = false
	if grip_w < 0.01 and goal > 0.0 and grip_arm != "":
		# taking hold: about level with your face, far enough under its shoulder that the long arm reaches
		# down to it with the elbow still back behind the edge
		grip_at = e.stalk_corner
		grip_at.y = clampf(get_bone_global_pos("arm_" + grip_arm).y - 2.0, 1.1, 2.2)
		grip_n = n
		grip_s = e.stalk_side
	grip_w = move_toward(grip_w, goal, delta * (2.2 if goal > grip_w else (1.6 if at_corner else 6.0)))
	if grip_w <= 0.0 or grip_arm == "" or grip_n == Vector3.ZERO:
		return
	n = grip_n
	var s := grip_s
	var w := smoothstep(0.0, 1.0, grip_w)
	# the hand arcs up and comes down on the edge; letting go it slides back along the face out of sight
	var slide := (1.0 - grip_w) * 0.8 if (grip_gone or not at_corner) else 0.0
	var wrist: Vector3 = grip_at + s * (0.06 - slide) + n * 0.14 + Vector3.UP * sin(grip_w * PI) * 0.3
	_arm_ik(grip_arm, wrist, _grip_elbow(wrist, s, n), w)
	var inv := skel.global_transform.basis.inverse()
	tap_clock += delta
	var tc := fmod(tap_clock, 3.4)
	var groups: Array = ["finger_index_", "finger_mid_", "finger_ring_"]
	var fan: Array = [0.5, 0.0, -0.5]
	for j in 3:
		var chain: Array = bones.get(groups[j] + grip_arm, [])
		if chain.size() < 2:
			continue
		# they close round the edge one by one (and let go the same way)
		var fw := clampf((grip_w - 0.15 * j) / 0.55, 0.0, 1.0) * w
		# drumming: each lifts off the wall and taps back down, a beat after the one before
		var tap := sin(clampf((tc - 0.16 * j) / 0.22, 0.0, 1.0) * PI) * grip_w
		var knuckle: Vector3 = (-n * 0.85 + s * (0.35 + tap * 0.5) + Vector3.UP * fan[j] * 0.5).normalized()
		var tip: Vector3 = (-n * 0.7 - s * (0.55 - tap * 1.1) + Vector3.UP * fan[j] * 0.25).normalized()
		_aim_bone(chain[0], inv * knuckle, fw)
		_aim_bone(chain[1], inv * tip, fw)
