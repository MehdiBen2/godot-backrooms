extends "res://scripts/Entities/model_entity.gd"
## THE BURNT. A charred figure twice your height that lives where the lamps have died: every tube near it goes
## out and stays out while it is there, and pops back on once it has gone. It only moves while you aren't
## looking at it; watched, it stands stock still, only its head twitching. Get within its reach and it takes
## you:
##   grab     it has you: the view jolts round to it, you are off the ground
##   lift     you are raised slowly up the length of its body (your torch on it all the way), to its face
##   stare    held there, closer and closer, while its head tilts
##   corrupt  the tape can't take it: the picture tears, warps and breaks up into static
## and then you are dead, and the camera's own error screen comes up instead of the picture (burnt_error.gd).
## The model has a skeleton but no animations: its stalking gait, the twitch, the head tilt and the arms
## reaching out are all posed here, bone by bone. `spawn burnt` in the debug console stands it in front of you.

const BurntError := preload("res://scripts/Entities/burnt/burnt_error.gd")
const CELL := 4.5
const RADIUS := 0.6
const STALK_SPEED := 2.2            # m/s, and only while nobody is looking
const TURN_RATE := 5.0
const GRAB_DIST := 2.3              # metres, feet to feet: its reach
const SEE_COS := 0.78               # within ~39 degrees of where you look, with nothing between: it is seen
const LAMP_REACH := 6.5             # metres: the tubes it burns out round it
const LAMP_HOLD := 1.4              # seconds a tube stays out after it has moved off
const HUG_REACH := 1.4              # its arms coming round you from behind...
const HUG_TIME := 2.8               # ...holding you, and the view going black over the end of it
const HUG_FADE := 0.8
const FADE_IN := 0.9                # back out of the black, facing it
const GRAB_TIME := 0.7
const LIFT_TIME := 6.0
const STARE_TIME := 3.4
const CORRUPT_TIME := 2.4

var state := "off"                  # off, stalk, grab, lift, stare, corrupt
var t := 0.0
var yaw := 0.0
var _walk := 0.0                    # 0..1 how much it is walking (eased)
var _gait := 0.0
var _step_t := 0.0
var _lamp_t := 0.0
var _fwd := Vector3.FORWARD         # its facing when it took you
var _from := Transform3D.IDENTITY   # your view when it took you
var _from_fov := 75.0
var _cue_t := 0.0
var _sounded := {}                  # one-off sounds of the sequence already played
var _lean := 0.0                    # radians it is bent forward (over you, from behind)
var _hug_dir := Vector3.FORWARD     # the way you faced when it took you from behind
var _from_hug := false              # the grab came out of the black after a hug
var _black: ColorRect               # the black the hug ends in
var flow := PackedInt32Array()
var _flow_key := -1
var _flow_timer := 0.0
var scares                          # (untyped: the Scares node's own methods)
var _pl                             # the player, untyped (player.gd's own fields: cam, dead, frozen...)
var _lv                             # the level, untyped (its fixture methods)

# its skeleton, posed by hand
var skel: Skeleton3D
var _bone := {}                     # name -> index (the ones it moves)
var _rest := {}                     # index -> rest rotation
var _tw_axis := Vector3.RIGHT       # the head's twitch: a jerk to one side and back
var _tw_amt := 0.0
var _tw_goal := 0.0
var _tw_next := 2.0

func _ready() -> void:
	super._ready()
	process_priority = 100              # after the player: its camera is ours to hold during the sequence
	scares = get_parent().get_node_or_null("Scares")
	_pl = player
	_lv = level

func _build() -> bool:
	if not super._build(): return false
	var found := body.find_children("*", "Skeleton3D", true, false)
	skel = found[0] as Skeleton3D if not found.is_empty() else null
	if skel != null:
		for n in ["Head", "NeckTwist01", "Spine01", "Spine02", "BoneRoot", "R_Eye", "L_Eye",
				"R_Upperarm", "L_Upperarm", "R_Forearm", "L_Forearm", "R_Hand", "L_Hand"]:
			var i := skel.find_bone(n)
			if i >= 0:
				_bone[n] = i
				_rest[i] = skel.get_bone_rest(i).basis.get_rotation_quaternion()
	# A skinned mesh is culled by its rest-pose box: arms posed reaching round the camera, metres in front of a body
	# standing behind it, would be culled away. A wide margin keeps them drawn (one entity: it costs nothing).
	for mi: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
		mi.extra_cull_margin = 8.0
	return true

# ---------------------------------------------------------------- stalking
func _physics_process(delta: float) -> void:
	if not present or player == null: return
	_burn_lamps(delta)
	if Game.freeze_ai or state != "stalk": return
	var pp := player.global_position
	var p := global_position
	var d := Vector2(pp.x - p.x, pp.z - p.z).length()
	if d < GRAB_DIST and _can_take():
		_start_grab()
		return
	if _seen():
		_walk = move_toward(_walk, 0.0, delta * 8.0)      # caught moving: it stops dead
	else:
		_walk = move_toward(_walk, 1.0, delta * 2.5)
		_move_toward(pp, STALK_SPEED * _walk, delta)
		# its steps: slow, heavy and soft (a big weight set down on carpet over concrete), felt more than heard
		_step_t -= delta * _walk
		if _step_t <= 0.0:
			_step_t = 0.95
			if scares != null:
				scares.spawn3d(scares.synth("thump"), global_position, 0.32, "Scares", 3.0, randf_range(0.9, 1.0))
	rotation.y = yaw

## Seen: within the player's view cone, with a clear line from their eyes to it
func _seen() -> bool:
	var cam: Camera3D = _pl.cam
	var eye := cam.global_position
	var mid := global_position + Vector3.UP * height * 0.55
	var to := mid - eye
	if to.length() > 60.0: return false
	if (-cam.global_transform.basis.z).dot(to.normalized()) < SEE_COS: return false
	return nav.clear_line(eye.x, eye.z, mid.x, mid.z)

func _can_take() -> bool:
	return not _pl.dead and not _pl.frozen and _pl.spawn_grace <= 0.0 and not Game.god_mode

## Every tube near it dies, and stays dead while it stays near (the cut is topped up, never left to run out)
func _burn_lamps(delta: float) -> void:
	_lamp_t -= delta
	if _lamp_t > 0.0 or not _lv.has_method("fixtures_near"): return
	_lamp_t = 0.3
	for f: Dictionary in _lv.fixtures_near(global_position, LAMP_REACH):
		if f.black > 0.0:
			f.black = maxf(f.black, LAMP_HOLD)
		else:
			_lv.cut_fixture(f, LAMP_HOLD)
			_lv.fixture_event.emit(f, false)               # the pop of a tube going out

func _yaw_to(at: Vector3) -> float:
	return atan2(at.x - global_position.x, at.z - global_position.z)

## Walk toward `to`: straight when it can see it, else down a flow field over the grid (as the grabber does)
func _move_toward(to: Vector3, speed: float, delta: float) -> void:
	var p := global_position
	var dir := Vector3(to.x - p.x, 0.0, to.z - p.z)
	if dir.length() > 9.0 or not nav.clear_line(p.x, p.z, to.x, to.z):
		dir = _flow_dir(to)
	if dir.length_squared() < 0.0001: return
	dir = dir.normalized()
	yaw = lerp_angle(yaw, atan2(dir.x, dir.z), minf(1.0, delta * TURN_RATE))
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var np := nav.resolve(p + fwd.lerp(dir, 0.5).normalized() * speed * delta, RADIUS)
	global_position = Vector3(np.x, p.y, np.z)

func _flow_dir(to: Vector3) -> Vector3:
	var n: int = nav.n
	if flow.size() != n * n: flow.resize(n * n)
	var gx := GridNav.cell(to.x)
	var gz := GridNav.cell(to.z)
	var key := gx * n + gz
	_flow_timer -= get_physics_process_delta_time()
	if key != _flow_key or _flow_timer <= 0.0:
		_flow_key = key
		_flow_timer = 0.4
		nav.bfs(gx, gz, flow)
	var p := global_position
	var x := GridNav.cell(p.x)
	var z := GridNav.cell(p.z)
	var bx := to.x
	var bz := to.z
	for step in 4:
		var here := flow[x * n + z] if (x >= 0 and z >= 0 and x < n and z < n) else -1
		var best: float = INF if here < 0 else float(here)
		var nx := -1
		var nz := -1
		for o in GridNav.NEIGHBOURS:
			var ax: int = x + o.x
			var az: int = z + o.y
			if ax < 0 or az < 0 or ax >= n or az >= n or not nav.can_step(x, z, ax, az): continue
			var v := flow[ax * n + az]
			if v >= 0 and v < best:
				best = v
				nx = ax
				nz = az
		if nx < 0: break
		x = nx
		z = nz
		if step == 0 or nav.clear_line(p.x, p.z, x * CELL, z * CELL):
			bx = x * CELL
			bz = z * CELL
		else:
			break
	return Vector3(bx - p.x, 0.0, bz - p.z)

# ---------------------------------------------------------------- its body, posed
func _process(delta: float) -> void:
	if not present or body == null: return
	# the gait: a slow, heavy sway as it walks, leaning into it
	_gait += delta * 3.2 * _walk
	body.position = Vector3(0.0, absf(sin(_gait)) * 0.07 * _walk, 0.0)
	body.rotation = Vector3(0.1 * _walk + _lean, deg_to_rad(yaw_offset), sin(_gait) * 0.04 * _walk)
	_pose(delta)
	if state in ["hug", "grab", "lift", "stare", "corrupt"]:
		_sequence(delta)

## Turn bone `name` by `angle` about a world axis, from its rest pose
func _turn(name: String, world_axis: Vector3, angle: float) -> void:
	if skel == null or not _bone.has(name): return
	var i: int = _bone[name]
	var parent := skel.get_bone_parent(i)
	var pb := skel.global_transform.basis
	if parent >= 0: pb = pb * skel.get_bone_global_pose(parent).basis
	var pq := pb.orthonormalized().get_rotation_quaternion()
	var q := pq.inverse() * Quaternion(world_axis.normalized(), angle) * pq
	skel.set_bone_pose_rotation(i, q * (_rest[i] as Quaternion))

func _pose(delta: float) -> void:
	if skel == null: return
	var fwd := Vector3(sin(rotation.y), 0.0, cos(rotation.y))
	var side := Vector3.UP.cross(fwd)
	# Stillness is what's wrong with it. Now and then (not often) the head gives one small, sharp tick, a few
	# degrees round or over, never up and down (that read as nodding), holds it, and eases back very slowly.
	# Holding you it doesn't twitch at all until the very end of the stare.
	_tw_next -= delta
	var may_tick := state == "stalk" or (state == "stare" and t > STARE_TIME - 0.6)
	if _tw_next <= 0.0 and may_tick:
		_tw_next = randf_range(4.0, 9.0) if state == "stalk" else 99.0
		_tw_axis = fwd if randf() < 0.6 else Vector3.UP       # a tilt over, or a turn: nothing else
		_tw_goal = randf_range(0.07, 0.13) * (1.0 if randf() < 0.5 else -1.0)
	_tw_amt = move_toward(_tw_amt, _tw_goal, delta * 14.0)      # snaps...
	_tw_goal = move_toward(_tw_goal, 0.0, delta * 0.05)         # ...and creeps back over seconds
	# while it holds you: dead still at first, then the head tilts over, slowly, as it studies you
	var tilt := 0.0
	if state == "stare": tilt = 0.38 * smoothstep(1.2, STARE_TIME, t)
	elif state == "corrupt": tilt = 0.38
	var q_tw := Quaternion(_tw_axis, _tw_amt)
	var q_tilt := Quaternion(fwd, tilt)
	var head := q_tilt * q_tw
	_turn("Head", head.get_axis() if head.get_angle() > 0.0001 else Vector3.UP, head.get_angle())
	if state == "hug":
		_hug_arms()
		return
	# its arms come up to hold you
	var reach := 0.0
	match state:
		"grab": reach = smoothstep(0.0, GRAB_TIME, t)
		"lift", "stare", "corrupt": reach = 1.0
	for s in ["R_Forearm", "L_Forearm", "R_Hand", "L_Hand"]:
		if _bone.has(s): skel.set_bone_pose_rotation(_bone[s], _rest[_bone[s]])
	_turn("R_Upperarm", side, -1.2 * reach)
	_turn("L_Upperarm", side, -1.2 * reach)

## The hug from behind: each arm aimed bone by bone (works whatever pose the model rests its arms in). The upper
## arm aims its elbow out beside your head, the forearm aims its hand across in front of your chest, the two
## hands crossing; they come round slowly, then tighten.
func _hug_arms() -> void:
	var cam: Camera3D = _pl.cam
	var c := cam.global_position
	var f := -cam.global_transform.basis.z
	f = Vector3(f.x, 0.0, f.z).normalized()
	var r := f.cross(Vector3.UP).normalized()
	var p := smoothstep(0.0, HUG_REACH, t)                     # how far round they have come
	var tight := smoothstep(HUG_REACH, HUG_TIME, t)            # ...and how hard they hold
	for s in ["R", "L"]:
		if not (_bone.has(s + "_Upperarm") and _bone.has(s + "_Forearm") and _bone.has(s + "_Hand")): continue
		for b in [s + "_Upperarm", s + "_Forearm", s + "_Hand"]:
			skel.set_bone_pose_rotation(_bone[b], _rest[_bone[b]])
		skel.force_update_all_bone_transforms()
		var shoulder := skel.global_transform * skel.get_bone_global_pose(_bone[s + "_Upperarm"]).origin
		var sgn := signf((shoulder - c).dot(r))
		if sgn == 0.0: sgn = 1.0 if s == "R" else -1.0
		var elbow := c + r * sgn * lerpf(0.55, 0.42, tight) + f * 0.05 - Vector3.UP * 0.2
		var hand := c + f * lerpf(0.5, 0.36, tight) - r * sgn * 0.14 - Vector3.UP * lerpf(0.42, 0.3, tight)
		_aim(s + "_Upperarm", s + "_Forearm", elbow, p)
		skel.force_update_all_bone_transforms()
		_aim(s + "_Forearm", s + "_Hand", hand, p)

## Turn bone `bone` (on top of its current pose) so that its child `child` swings toward `target`, by `amount`
func _aim(bone: String, child: String, target: Vector3, amount: float) -> void:
	var i: int = _bone[bone]
	var a := skel.global_transform * skel.get_bone_global_pose(i).origin
	var b := skel.global_transform * skel.get_bone_global_pose(_bone[child]).origin
	var cur := (b - a).normalized()
	var want := (target - a).normalized()
	if cur.dot(want) > 0.9999: return
	var q := Quaternion.IDENTITY.slerp(Quaternion(cur, want), amount)
	var parent := skel.get_bone_parent(i)
	var pb := skel.global_transform.basis
	if parent >= 0: pb = pb * skel.get_bone_global_pose(parent).basis
	var pq := pb.orthonormalized().get_rotation_quaternion()
	skel.set_bone_pose_rotation(i, (pq.inverse() * q * pq) * skel.get_bone_pose_rotation(i))

# ---------------------------------------------------------------- it has you
## It has you. Come at unseen (how it hunts), it takes you from behind: its arms come round you first (hug),
## then the world goes black and you come to facing it, held. Walked into while you were looking at it, it
## just takes you, face on.
func _start_grab() -> void:
	t = 0.0
	_walk = 0.0
	_pl.frozen = true
	player.velocity = Vector3.ZERO
	var cam: Camera3D = _pl.cam
	_from = cam.global_transform
	_from_fov = cam.fov
	_cue_t = 0.0
	_sounded = {}
	_from_hug = false
	Game.fx_reset()
	if _seen():
		_face_on()
		_hit()
	else:
		_behind()
		state = "hug"
		# no hit yet: a slow breath at the back of your head, and its joints as its arms come round
		if scares != null:
			scares.spawn3d(scares.synth("breath_close", 0.0), cam.global_position - _hug_dir * 0.4 + Vector3.UP * 0.3, 1.0, "Scares", 2.0, 0.62)
	_quiet()
	Game.fear = 1.0

## Turned to face you where it stands, and the grab begins
func _face_on() -> void:
	state = "grab"
	_lean = 0.0
	yaw = _yaw_to(player.global_position)
	rotation.y = yaw
	_fwd = Vector3(sin(yaw), 0.0, cos(yaw))

## Stood right behind you, facing the way you face, bent forward over you: its shoulders just above and behind
## your head, so its arms come down round you
func _behind() -> void:
	var cam: Camera3D = _pl.cam
	var c := cam.global_position
	var f := -cam.global_transform.basis.z
	_hug_dir = Vector3(f.x, 0.0, f.z).normalized()
	yaw = atan2(_hug_dir.x, _hug_dir.z)
	rotation.y = yaw
	_lean = 0.0
	body.rotation = Vector3(0.0, deg_to_rad(yaw_offset), 0.0)
	global_position = Vector3(c.x, global_position.y, c.z) - _hug_dir * 0.5
	# how tall its shoulders stand, straight: lean it over until they are just above your head...
	var sh := _shoulders()
	var tall := maxf(sh.y - global_position.y, 0.5)
	var want := (c.y + 0.35) - global_position.y
	_lean = acos(clampf(want / tall, 0.2, 1.0))
	body.rotation.x = _lean
	# ...then slide it so they sit a little behind it
	var now := _shoulders()
	var goal := c - _hug_dir * 0.3
	global_position += Vector3(goal.x - now.x, 0.0, goal.z - now.z)

func _shoulders() -> Vector3:
	if skel == null or not (_bone.has("R_Upperarm") and _bone.has("L_Upperarm")):
		return global_position + Vector3.UP * height * 0.8
	var a := skel.global_transform * skel.get_bone_global_pose(_bone["R_Upperarm"]).origin
	var b := skel.global_transform * skel.get_bone_global_pose(_bone["L_Upperarm"]).origin
	return (a + b) * 0.5

## The hit: a body blow and a joint cracking
func _hit() -> void:
	Game.fx_shock = 1.0
	if scares != null:
		scares.seize()
		scares.spawn3d(scares.synth("bone_crack"), global_position + Vector3.UP * 2.0, 1.0, "Scares", 4.0, 0.7)

## Then the world drops away: the hum dies, everything goes muffled and far off, and what is left is its body,
## close (_sequence). No screams and no stacked stingers: it is the quiet that gets you.
func _quiet() -> void:
	var root := get_parent()
	var au: Node = root.get_node_or_null("Audio")
	if au != null:
		au.set_muffled(true)
		au.set_dread(0.0)
	var amb: Node = root.get_node_or_null("Audio/Ambience")
	if amb != null: amb.hush_for(0.02, HUG_TIME + GRAB_TIME + LIFT_TIME + STARE_TIME + CORRUPT_TIME + 2.0)

## A point on its body, `s` from where your eyes were (0) up to its face (1), along its spine
func _body_at(s: float) -> Vector3:
	var pts: Array[Vector3] = [global_position + Vector3.UP * minf(_from.origin.y - global_position.y, height * 0.5)]
	for n in ["Spine01", "Spine02", "NeckTwist01"]:
		if _bone.has(n):
			var w := skel.global_transform * skel.get_bone_global_pose(_bone[n]).origin
			if w.y > pts[-1].y + 0.05: pts.append(w)
	pts.append(_face())
	var lens: Array[float] = [0.0]
	for i in range(1, pts.size()): lens.append(lens[-1] + pts[i].distance_to(pts[i - 1]))
	var at := clampf(s, 0.0, 1.0) * lens[-1]
	for i in range(1, pts.size()):
		if at <= lens[i]:
			return pts[i - 1].lerp(pts[i], (at - lens[i - 1]) / maxf(lens[i] - lens[i - 1], 0.0001))
	return pts[-1]

## Between its eyes (the head, a little up, if the model has no eye bones)
func _face() -> Vector3:
	if skel != null and _bone.has("R_Eye") and _bone.has("L_Eye"):
		var a := skel.global_transform * skel.get_bone_global_pose(_bone["R_Eye"]).origin
		var b := skel.global_transform * skel.get_bone_global_pose(_bone["L_Eye"]).origin
		return (a + b) * 0.5
	if skel != null and _bone.has("Head"):
		return skel.global_transform * skel.get_bone_global_pose(_bone["Head"]).origin + Vector3.UP * 0.1
	return global_position + Vector3.UP * height * 0.92

func _sequence(delta: float) -> void:
	if _pl.dead:
		_finish()
		return
	t += delta
	var cam: Camera3D = _pl.cam
	var face := _face()
	var pos: Vector3
	var look: Vector3
	var fov := _from_fov
	var shake := 0.0
	match state:
		"hug":
			# your own view, held still and trembling, its arms coming round you and closing; then black
			var tight := smoothstep(HUG_REACH, HUG_TIME, t)
			pos = _from.origin
			look = _from.origin - _from.basis.z * 3.0 - Vector3.UP * 0.35 * tight
			shake = 0.003 + 0.012 * tight
			_set_black(smoothstep(HUG_TIME - HUG_FADE, HUG_TIME, t))
			_once("joints", t > 0.6, func(): scares.spawn3d(scares.synth("creak"), _shoulders(), 0.6, "Scares", 2.0, 0.62))
			if t >= HUG_TIME:
				_turn_round()
				return
		"grab":
			if _from_hug: _set_black(1.0 - smoothstep(0.0, FADE_IN, t))
			# jerked round to face it, pulled in against it, off your feet
			var k := smoothstep(0.0, GRAB_TIME, t)
			pos = _from.origin.lerp(_body_at(0.0) + _fwd * 1.1, k)
			look = (_from.origin - _from.basis.z * 3.0).lerp(_body_at(0.06), k)
			shake = 0.05 * (1.0 - k) + 0.01
			if t >= GRAB_TIME: _next("lift")
		"lift":
			# raised up the length of it, your light on it all the way, until you are level with its face
			var k := t / LIFT_TIME
			var s := k * k * k * (k * (k * 6.0 - 15.0) + 10.0)
			pos = _body_at(s) + _fwd * lerpf(1.1, 0.9, s)
			look = _body_at(minf(1.0, s + 0.1)).lerp(face, smoothstep(0.7, 1.0, s))
			fov = lerpf(_from_fov, 58.0, s)
			shake = 0.008 + 0.004 * sin(t * 1.7)
			# the camera already struggling near its face: a block or two breaking up, now and then
			if s > 0.6 and randf() < delta * 1.2 * s: Game.fx_corrupt = maxf(Game.fx_corrupt, 0.12)
			# its charred joints taking your weight, right by you, now and then; your heart, quietly
			var at := pos
			_cue(delta, randf_range(1.0, 1.8), func() -> void:
				scares.spawn3d(scares.synth("creak"), at, 0.55, "Scares", 2.0, randf_range(0.6, 0.75))
				scares.heartbeat(0.6 + 0.6 * s)
			)
			if t >= LIFT_TIME: _next("stare")
		"stare":
			# held there, drawn in closer while its head tilts over
			var k := smoothstep(0.0, STARE_TIME, t)
			pos = face + _fwd * lerpf(0.9, 0.42, k)
			look = face
			fov = lerpf(58.0, 48.0, k)
			shake = 0.004
			Game.fx_contrast = 1.0 + 0.2 * k
			Game.fx_sat = 1.0 - 0.4 * k
			if randf() < delta * 1.5: Game.add_glitch(0.15)
			# the picture of its face coming apart in squares: short bursts, more and worse as it goes on
			if randf() < delta * (0.8 + 3.0 * k): Game.fx_corrupt = maxf(Game.fx_corrupt, 0.15 + 0.35 * k)
			# dead silence (even your heart), then it breathes in, slowly, right in your face
			_once("breath", t > 1.5, func():
				scares.spawn3d(scares.synth("breath_close", 0.0), face, 1.0, "Scares", 2.0, 0.62))
			if t >= STARE_TIME: _next("corrupt")
		"corrupt":
			# the tape can't hold it: tearing, warping, static, the frame jumping closer to its face
			var k := clampf(t / CORRUPT_TIME, 0.0, 1.0)
			var jump := 0.42 - 0.25 * floorf(k * 4.0) / 4.0 if randf() < 0.2 + 0.6 * k else 0.42 - 0.12 * k
			pos = face + _fwd * jump
			look = face + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.06 * k
			fov = 48.0 - 10.0 * k
			shake = 0.01 + 0.04 * k
			Game.glitch = maxf(Game.glitch, 0.35 + 0.65 * k)
			Game.fx_static = 0.2 + 0.8 * k
			Game.fx_corrupt = 0.3 + 0.7 * k
			Game.fx_warp = 0.004 + 0.03 * k
			Game.fx_hue = randf_range(-0.3, 0.3) * k if randf() < 0.3 else Game.fx_hue
			Game.fx_shock = maxf(Game.fx_shock, 0.4 * k)
			# a low swell under it, and the signal breaking up faster and faster
			_once("drone", true, func(): scares.spawn_flat(scares.synth("drone", 3.0), 0.9))
			_cue(delta, 0.45 - 0.3 * k, func(): scares.play_scare("staticHit", 0.4 + 0.6 * k))
			if t >= CORRUPT_TIME:
				_die()
				return
	var jitter := Vector3(sin(Game.time * 37.0), sin(Game.time * 29.0 + 1.3), sin(Game.time * 23.0 + 2.1)) * shake
	var xf := Transform3D(Basis(), pos + jitter)
	if look.distance_to(pos) > 0.01:
		xf = xf.looking_at(look, Vector3.UP)
	cam.global_transform = xf
	cam.fov = fov
	player.velocity = Vector3.ZERO

## A sound cue every `every` seconds while a phase lasts
func _cue(delta: float, every: float, call: Callable) -> void:
	if scares == null: return
	_cue_t -= delta
	if _cue_t <= 0.0:
		_cue_t = every
		call.call()

## In the black: it lets go behind you and is in front of you, facing you, when the picture comes back. The hit
## lands as it does.
func _turn_round() -> void:
	var c: Vector3 = (_pl.cam as Camera3D).global_position
	global_position = nav.resolve(Vector3(c.x, global_position.y, c.z) + _hug_dir * 1.4, RADIUS)
	_face_on()
	_from_hug = true
	t = 0.0
	_cue_t = 0.0
	_hit()

## The screen's black, 0..1 (made the first time it is needed)
func _set_black(a: float) -> void:
	if _black == null:
		var layer := CanvasLayer.new()
		layer.layer = 20
		add_child(layer)
		_black = ColorRect.new()
		_black.color = Color.BLACK
		_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_black.set_anchors_preset(Control.PRESET_FULL_RECT)
		layer.add_child(_black)
	_black.modulate.a = clampf(a, 0.0, 1.0)
	_black.visible = a > 0.001

## A sound played once in the sequence, the first frame `when` holds
func _once(key: String, when: bool, call: Callable) -> void:
	if not when or _sounded.has(key) or scares == null: return
	_sounded[key] = true
	call.call()

func _next(s: String) -> void:
	state = s
	t = 0.0
	_cue_t = 0.0

func _die() -> void:
	var err := BurntError.new()
	get_tree().root.add_child(err)
	_pl.frozen = false
	Game.kill_player("THE BURNT")
	_despawn_quietly()

## Off, without touching the player (their death owns the camera from here)
func _despawn_quietly() -> void:
	state = "off"
	present = false
	visible = false
	_walk = 0.0
	_lean = 0.0
	if _black != null: _set_black(0.0)
	if skel != null:
		for i: int in _rest: skel.set_bone_pose_rotation(i, _rest[i])

## The player died some other way in the middle of it: let go
func _finish() -> void:
	_despawn_quietly()

# ---------------------------------------------------------------- debug console
func debug_spawn() -> bool:
	if not super.debug_spawn(): return false
	yaw = rotation.y
	state = "stalk"
	_walk = 0.0
	_lamp_t = 0.0
	return true

func debug_despawn() -> void:
	if state in ["hug", "grab", "lift", "stare", "corrupt"] and player != null and not _pl.dead:
		_pl.frozen = false
		Game.fx_reset()
		var au: Node = get_parent().get_node_or_null("Audio")
		if au != null: au.set_muffled(false)
	_despawn_quietly()
	super.debug_despawn()
