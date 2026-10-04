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
const BurntNet := preload("res://scripts/Entities/burnt/burnt_net.gd")
const STATES := ["off", "stalk", "windup", "charge", "held", "grab", "lift", "stare", "corrupt", "hug"]
const HELD_MAX := 40.0              # co-op host: seconds it waits on the victim's machine before it lets go
const CELL := 4.5
const RADIUS := 0.6
const STALK_SPEED := 1.4            # m/s, and only while nobody is looking
const TURN_RATE := 5.0
const GRAB_DIST := 2.3              # metres, feet to feet: its reach
const SEE_COS := 0.78               # within ~39 degrees of where you look, with nothing between: it is seen
const LAMP_REACH := 6.5             # metres: the tubes it burns out round it
const LAMP_HOLD := 1.4              # seconds a tube stays out after it has moved off
const HUG_REACH := 1.4              # its arms coming round you from behind...
const HUG_TIME := 2.8               # ...holding you, and the view going black over the end of it
const HUG_FADE := 0.8
const FADE_IN := 0.9                # back out of the black, facing it
const WINDUP_TIME := 0.45           # seconds it coils before it takes you: the tell (you can still back off)
const GRAB_TIME := 0.7
const LIFT_TIME := 6.0
const STARE_TIME := 3.4
const CORRUPT_TIME := 2.4

@export var leg_swing := 0.3        # radians the thighs swing fore and aft at a full stride
@export var knee_bend := 0.35       # radians a knee folds as its leg comes through
@export var hip_twist := 0.05       # radians the pelvis turns against the shoulders each step
@export var coil_lean := 0.45       # radians the spine has folded forward by the end of the wind-up

@export var arm_swing := 0.0        # radians the arms swing against the legs when it walks (they hang loose, so they lag)
@export var charge_watch := 4.0     # seconds of being stared at, from afar, before it stops waiting and runs at you
@export var charge_min := 9.0       # metres: nearer than this it simply stalks
@export var charge_max := 42.0
@export var charge_speed := 6.5     # m/s at a full run
@export var charge_cooldown := 25.0 # seconds before it will charge again

const CHARGE_PREP := 0.9            # seconds it drops into a crouch and breathes in before it goes
const CHARGE_RUN := 5.5             # seconds it will run before it gives up

var state := "off"                  # off, stalk, windup, charge, grab, lift, stare, corrupt (+ held: co-op, a guest is being taken)
var t := 0.0
var yaw := 0.0
var _walk := 0.0                    # 0..1 how much it is walking (eased)
var _gait := 0.0
var _watch_t := 0.0                 # how long it has been stared at, from afar (decays when you look away)
var _charge_cd := 0.0
var _run := 0.0                     # 0..1 how far into a run it is (eased)
var _crouch := 0.0                  # 0..1 the crouch it drops into before it runs
var _head_yaw := 0.0                # radians the head is turned off the body to keep its eyes on you
var _hitch_t := 0.0                 # a dropped-frame stutter in the run: the gait holds for a beat
var _hitch_next := 0.6
var _last_step := 0
var _arm := [0.0, 0.0]              # R, L upper arm angle and speed: sprung, so they hang loose and lag
var _arm_v := [0.0, 0.0]
var _stride := 0.0                 # 0..1 how much its legs swing: holds while it is watched, settles when it stops stalking
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
var net: BurntNet
var puppet := false                 # co-op guest: it follows the host's snapshots instead of thinking
var _tid := -1                      # co-op: the survivor it hunts (Net.survivors() id)
var _victim_id := -1                # host: the guest it has handed over to
var _held_t := 0.0
var _net_taken := false             # guest: the host's Burnt took this machine's player, the sequence runs here
var _snub := 0.0                    # guest: ignore the host's snapshots for a moment after our sequence (it despawns it)
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
	net = BurntNet.new(self)
	_pl = player
	_lv = level

func _build() -> bool:
	if not super._build(): return false
	var found := body.find_children("*", "Skeleton3D", true, false)
	skel = found[0] as Skeleton3D if not found.is_empty() else null
	if skel != null:
		for n in ["Head", "NeckTwist01", "Spine01", "Spine02", "BoneRoot", "R_Eye", "L_Eye",
				"R_Upperarm", "L_Upperarm", "R_Forearm", "L_Forearm", "R_Hand", "L_Hand",
				"Pelvis", "R_Thigh", "L_Thigh", "R_Calf", "L_Calf", "R_Foot", "L_Foot"]:
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
	puppet = Net.is_online() and not Net.hosting
	if puppet:
		_physics_puppet(delta)
		return
	if Net.is_online(): net.send(delta)
	if not present or player == null: return
	_burn_lamps(delta)
	if Game.freeze_ai: return
	if state == "held":                  # a guest is being taken: their machine plays it out
		_held_t += delta
		if _held_t > HELD_MAX: _despawn_quietly()
		return
	_charge_cd = maxf(0.0, _charge_cd - delta)
	if state == "windup":
		_windup(delta)
		return
	if state == "charge":
		_charge(delta)
		return
	if state != "stalk": return
	var tgt := _target()
	if tgt.is_empty(): return
	var pp: Vector3 = tgt.pos
	var p := global_position
	var d := Vector2(pp.x - p.x, pp.z - p.z).length()
	if d < GRAB_DIST and _can_take(tgt):
		state = "windup"
		t = 0.0
		return
	if _seen():
		_walk = move_toward(_walk, 0.0, delta * 8.0)      # caught moving: it stops dead
		# ...but hold its eye long enough, from far enough off, and it stops waiting: it runs
		_watch_t += delta
		if _watch_t >= charge_watch and _charge_cd <= 0.0 and d >= charge_min and d <= charge_max and _can_take(tgt):
			_begin_charge()
			return
	else:
		_watch_t = maxf(0.0, _watch_t - delta * 0.6)
		_walk = move_toward(_walk, 1.0, delta * 2.5)
		_move_toward(pp, STALK_SPEED * _walk, delta)
		# its steps: slow, heavy and soft (a big weight set down on carpet over concrete), felt more than heard
		_step_t -= delta * _walk
		if _step_t <= 0.0:
			_step_t = 1.3
			if scares != null:
				scares.spawn3d(scares.synth("thump"), global_position, 0.32, "Scares", 3.0, randf_range(0.9, 1.0))
	rotation.y = yaw

## It has been looked at too long. It drops into a crouch, turns to you and breathes in (the tell), then runs.
func _begin_charge() -> void:
	state = "charge"
	t = 0.0
	_cue_t = 0.0
	_sounded = {}
	_watch_t = 0.0
	_charge_cd = charge_cooldown
	_tw_next = 0.0
	if scares != null:
		scares.spawn3d(scares.synth("breath_close", 0.0), _face(), 0.9, "Scares", 8.0, 0.55)

## The run: nothing like its walk. Fast, lurching and uneven (_process), straight at you, every tube round it
## dying as it comes. It runs out of breath if you are far enough, and ends in the grab if you are not.
func _charge(delta: float) -> void:
	t += delta
	var tgt := _target()
	if tgt.is_empty() or not _can_take(tgt):
		state = "stalk"
		return
	var pp: Vector3 = tgt.pos
	var d := Vector2(pp.x - global_position.x, pp.z - global_position.z).length()
	if t < CHARGE_PREP:
		_walk = move_toward(_walk, 0.0, delta * 8.0)
		yaw = lerp_angle(yaw, _yaw_to(pp), minf(1.0, delta * TURN_RATE * 2.0))
		rotation.y = yaw
		return
	# the start of the run: air drawn in sharply
	_once("go", true, func(): scares.spawn3d(scares.synth("stinger"), global_position + Vector3.UP * 2.0, 0.6, "Scares", 8.0, 0.7))
	if d < GRAB_DIST:
		_start_grab(tgt)
		return
	if t > CHARGE_PREP + CHARGE_RUN:
		state = "stalk"
		return
	_walk = 1.0
	var ramp := smoothstep(CHARGE_PREP, CHARGE_PREP + 0.7, t)          # it gets up to speed, it does not start there
	_move_toward(pp, charge_speed * ramp * (0.0 if _hitch_t > 0.0 else 1.0), delta)
	rotation.y = yaw
	Game.fear = maxf(Game.fear, 0.85)
	_cue(delta, 0.5, func(): scares.heartbeat(0.9))

## The tell: it stops dead and turns to you, draws back, then folds forward over you (_pose). Out of reach by the
## end of it and it lets the grab go and stalks on.
func _windup(delta: float) -> void:
	t += delta
	_walk = move_toward(_walk, 0.0, delta * 8.0)
	var tgt := _target()
	if tgt.is_empty():
		state = "stalk"
		return
	var pp: Vector3 = tgt.pos
	yaw = lerp_angle(yaw, _yaw_to(pp), minf(1.0, delta * TURN_RATE * 2.0))
	rotation.y = yaw
	if t < WINDUP_TIME: return
	var d := Vector2(pp.x - global_position.x, pp.z - global_position.z).length()
	if d < GRAB_DIST + 1.2 and _can_take(tgt):
		_start_grab(tgt)
	else:
		state = "stalk"

## Seen: by any survivor, within their view cone, with a clear line from their eyes to it
func _seen() -> bool:
	for s: Dictionary in Net.survivors():
		if _seen_by(s): return true
	return false

func _seen_by(s: Dictionary) -> bool:
	var eye: Vector3 = s.pos + Vector3.UP * 1.6
	var look: Vector3 = s.fwd
	if s.local:
		var cam: Camera3D = _pl.cam
		eye = cam.global_position
		look = -cam.global_transform.basis.z
	var mid := global_position + Vector3.UP * height * 0.55
	var to := mid - eye
	if to.length() > 60.0: return false
	var dir := to.normalized() if s.local else Vector3(to.x, 0.0, to.z).normalized()
	if look.dot(dir) < SEE_COS: return false
	return nav.clear_line(eye.x, eye.z, mid.x, mid.z)

## The survivor it hunts: the nearest, and the one it already has keeps a small edge
func _target() -> Dictionary:
	var best := Net.nearest_survivor(global_position, _tid)
	_tid = best.get("id", -1)
	return best

func _can_take(tgt: Dictionary) -> bool:
	if not tgt.local: return true
	return not _pl.dead and not _pl.frozen and _pl.spawn_grace <= 0.0 and not Game.god_mode

## Every tube near it dies, and stays dead while it stays near (the cut is topped up, never left to run out)
func _burn_lamps(delta: float) -> void:
	_lamp_t -= delta
	if _lamp_t > 0.0 or not _lv.has_method("fixtures_near"): return
	_lamp_t = 0.3
	for f: Dictionary in _lv.fixtures_near(global_position, LAMP_REACH * (1.6 if state == "charge" else 1.0)):
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
	var charging := state == "charge"
	_run = lerpf(_run, 1.0 if charging and t > CHARGE_PREP else 0.0, 1.0 - exp(-6.0 * delta))
	_crouch = lerpf(_crouch, 1.0 if charging and t < CHARGE_PREP else 0.0, 1.0 - exp(-9.0 * delta))
	# the run is uneven: the cadence wanders, and every second or so the gait drops a beat and catches up
	# walking: slow and lurching, it lingers at each footfall then snaps through the step
	var cadence := lerpf(2.4 * (1.0 + 0.6 * sin(2.0 * _gait + 1.0)), 7.0, _run) * (1.0 + _run * (0.3 * sin(Game.time * 4.7) + 0.15 * sin(Game.time * 11.3)))
	_hitch_t = maxf(0.0, _hitch_t - delta)
	if charging and _run > 0.5:
		_hitch_next -= delta
		if _hitch_next <= 0.0:
			_hitch_t = randf_range(0.1, 0.18)
			_hitch_next = randf_range(0.5, 1.2)
			if scares != null: scares.spawn3d(scares.synth("bone_crack"), global_position + Vector3.UP * 1.5, 0.35, "Scares", 6.0, randf_range(0.9, 1.2))
	_gait += delta * cadence * _walk * (0.0 if _hitch_t > 0.0 else 1.0)
	# a heavy footfall as each foot comes down in the run (the walk's are timed in _physics_process)
	var step := int(floorf(_gait / PI))
	if step != _last_step:
		_last_step = step
		if charging and _run > 0.5 and scares != null:
			scares.spawn3d(scares.synth("thump"), global_position, 0.6, "Scares", 7.0, randf_range(0.72, 0.9))
	# highest as the legs pass, lowest as a foot comes down: the weight lands on each step
	body.position = Vector3(0.0, (1.0 - absf(sin(_gait))) * lerpf(0.03, 0.1, _run) * _walk - 0.2 * _crouch, 0.0)
	body.rotation = Vector3(0.04 * _walk + _lean + 0.3 * _run, deg_to_rad(yaw_offset), sin(_gait) * lerpf(0.015, 0.06, _run) * _walk)
	var stride_to := 0.0
	if state == "stalk": stride_to = 1.0 if _walk > 0.3 else 0.5   # caught mid-step it holds, then sinks into a wide stance
	elif charging: stride_to = 1.0 if t > CHARGE_PREP else 0.0
	_stride = lerpf(_stride, stride_to, 1.0 - exp(-2.5 * delta))
	_pose(delta)
	if state in ["hug", "grab", "lift", "stare", "corrupt"] and (not puppet or _net_taken):
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
	# the wind-up of the grab: k runs 0..1 over it. Spine and arms draw back first (anticipation), then fold
	# forward over you, ease-in, the arms coming back down to hang so the reach starts from rest
	var coil := 0.0
	var draw := 0.0
	if state == "windup":
		var k := clampf(t / WINDUP_TIME, 0.0, 1.0)
		var go := pow(smoothstep(0.4, 1.0, k), 2.0)
		var back := smoothstep(0.0, 0.4, k)
		coil = lerpf(-0.25, 1.0, go) * coil_lean if k >= 0.4 else -0.25 * coil_lean * back
		draw = lerpf(0.45, 0.0, go) if k >= 0.4 else 0.45 * back
	# the crouch before the run: folded over, arms drawn back, like a sprinter's set
	coil += _crouch * coil_lean * 1.3
	draw += _crouch * 0.6
	_pose_gait(side, coil)
	# Stillness is what's wrong with it. Now and then (not often) the head gives one small, sharp tick, a few
	# degrees round or over, never up and down (that read as nodding), holds it, and eases back very slowly.
	# Holding you it doesn't twitch at all until the very end of the stare.
	_tw_next -= delta
	# (it ticks faster the longer it is stared at, and in the run it will not keep its head still at all; held, the
	# one tick comes just as the camera has stopped closing in)
	var may_tick := state == "stalk" or state == "charge" or (state == "stare" and t > 1.9)
	if _tw_next <= 0.0 and may_tick:
		if state == "charge": _tw_next = randf_range(0.12, 0.35)
		elif state == "stalk": _tw_next = randf_range(0.8, 1.6) if _watch_t > charge_watch * 0.5 else randf_range(4.0, 9.0)
		else: _tw_next = 99.0
		_tw_axis = fwd if randf() < 0.6 else Vector3.UP       # a tilt over, or a turn: nothing else
		_tw_goal = randf_range(0.07, 0.13) * (1.0 if randf() < 0.5 else -1.0) * (2.2 if state == "charge" else 1.0)
	_tw_amt = move_toward(_tw_amt, _tw_goal, delta * 14.0)      # snaps...
	_tw_goal = move_toward(_tw_goal, 0.0, delta * 0.05)         # ...and creeps back over seconds
	# while it holds you: dead still at first, then the head tilts over, slowly, as it studies you
	var tilt := 0.0
	if state == "stare": tilt = 0.38 * smoothstep(1.2, STARE_TIME, t)
	elif state == "corrupt": tilt = 0.38
	if state == "stalk": tilt += 0.1 * _stride
	tilt += 0.4 * _run                                               # the head hangs over to one side as the body runs under it
	# its head stays on you whichever way the body turns to go round a wall
	var look_at := 0.0
	if (state == "stalk" or state == "charge") and player != null:
		look_at = clampf(wrapf(_yaw_to(player.global_position) - rotation.y, -PI, PI), -1.0, 1.0)
	_head_yaw = lerpf(_head_yaw, look_at, 1.0 - exp(-4.0 * delta))
	var q_tw := Quaternion(_tw_axis, _tw_amt)
	var q_tilt := Quaternion(fwd, tilt)
	var head := Quaternion(Vector3.UP, _head_yaw) * q_tilt * q_tw * Quaternion(side, coil * 0.5)      # (the head dips with the fold)
	_turn("Head", head.get_axis() if head.get_angle() > 0.0001 else Vector3.UP, head.get_angle())
	if state == "hug":
		_hug_arms()
		return
	# its arms come up to hold you
	# the arms snap up (ease-out with a little overshoot, 0.3 s), then tighten as it lifts you, a tremor in the grip
	var reach := 0.0
	var grip := 0.0
	match state:
		"grab":
			var x := clampf(t / 0.3, 0.0, 1.0) - 1.0
			reach = 1.0 + 2.70158 * x * x * x + 1.70158 * x * x
		"lift":
			reach = 1.0 + 0.15 * smoothstep(0.0, LIFT_TIME, t)
			grip = 0.03
		"stare": reach = 1.15; grip = 0.03 + 0.03 * smoothstep(0.0, STARE_TIME, t)
		"corrupt": reach = 1.15; grip = 0.08
	reach += grip * sin(Game.time * 31.0)
	# arms hanging loose otherwise: each swings against the opposite leg on a spring (k 45, c 4: underdamped), so it
	# lags the stride and keeps swinging when the legs stop. In the run they are flung back and flail.
	var wild := 1.0
	var held := 1.0 - clampf(reach, 0.0, 1.0)
	var sway := 0.04 * sin(Game.time * 0.8)
	var goal := [
		-arm_swing * wild * _stride * sin(_gait + PI * 1.08) + 0.3 * _run + 0.04 * _crouch + sway - 0.06,
		-arm_swing * wild * _stride * sin(_gait) + 0.3 * _run + 0.04 * _crouch - sway - 0.06,
	]
	for i in 2:
		_arm_v[i] += ((goal[i] - _arm[i]) * 45.0 - _arm_v[i] * 4.0) * delta
		_arm[i] = clampf(_arm[i] + _arm_v[i] * delta, -1.1, 1.1)
	for s in ["R_Forearm", "L_Forearm", "R_Hand", "L_Hand"]:
		if _bone.has(s): skel.set_bone_pose_rotation(_bone[s], _rest[_bone[s]])
	_turn("R_Upperarm", side, -1.2 * reach + draw + _arm[0] * held)
	_turn("L_Upperarm", side, -1.2 * reach + draw + _arm[1] * held)
	# the elbows give as an arm swings forward, and pump in the run (after the upper arms: _turn reads the parent)
	_turn("R_Forearm", side, (-0.15 - 0.5 * maxf(0.0, -_arm[0]) - 0.2 * _run) * held)
	_turn("L_Forearm", side, (-0.15 - 0.5 * maxf(0.0, -_arm[1]) - 0.2 * _run) * held)

## Legs, hips and spine: a heavy lurching walk off the gait phase. Forward is negative about `side` for a limb
## hanging down, and positive for the spine standing up. Parents first (_turn reads the parent's current pose).
func _pose_gait(side: Vector3, coil: float) -> void:
	if skel == null or not _bone.has("Pelvis"): return
	var a := _stride
	var legs := [["R", _gait, 1.0], ["L", _gait + PI * 1.08, 0.86]]       # not quite opposite, one a little short
	# which side of it the left hip is on, so the hips turn the right way whichever way the model is built
	var lr := skel.global_transform.basis * (skel.get_bone_global_pose(_bone["L_Thigh"]).origin - skel.get_bone_global_pose(_bone["R_Thigh"]).origin)
	var twist := -signf(lr.dot(side)) * hip_twist * (1.0 + _run) * a * (sin(legs[1][1]) - sin(legs[0][1])) * 0.5
	_turn("Pelvis", Vector3.UP, twist)
	for leg in legs:
		var ph: float = leg[1]
		var amp: float = leg[2] * a
		var thigh := -leg_swing * (1.0 + 0.3 * _run) * amp * sin(ph) - 0.45 * _crouch
		var knee := knee_bend * (1.0 + 0.2 * _run) * amp * maxf(0.0, cos(ph)) + 0.8 * _crouch   # folds as the leg swings through
		_turn(leg[0] + "_Thigh", side, thigh)
		_turn(leg[0] + "_Calf", side, knee)
		_turn(leg[0] + "_Foot", side, -(thigh + knee) * 0.8)                # the foot stays near flat
	# shoulders turn against the hips; the spine folds forward in the wind-up
	var spine := Quaternion(Vector3.UP, -twist * 0.75) * Quaternion(side, coil * 0.5)
	_turn("Spine01", spine.get_axis() if spine.get_angle() > 0.0001 else Vector3.UP, spine.get_angle())
	_turn("Spine02", spine.get_axis() if spine.get_angle() > 0.0001 else Vector3.UP, spine.get_angle())

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
func _start_grab(tgt: Dictionary) -> void:
	if not tgt.local:
		# a guest's survivor: their machine plays the sequence, we hold still until it is over
		_victim_id = tgt.id
		_held_t = 0.0
		_walk = 0.0
		state = "held"
		Net.send_burnt_take(_victim_id)
		return
	_begin_sequence()

func _begin_sequence() -> void:
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
	var roll := 0.0
	# it stoops over you: a lunge on the grab that settles into a hunch, then leans in as it studies you
	var lean_to := 0.0
	match state:
		"grab": lean_to = 0.32 if t < 0.25 else 0.12
		"lift": lean_to = 0.12
		"stare": lean_to = 0.12 + 0.12 * smoothstep(0.0, STARE_TIME, t)
		"corrupt": lean_to = 0.24
	if state != "hug":                  # (the hug's lean is set by _behind)
		_lean = lerpf(_lean, lean_to, 1.0 - exp(-(14.0 if state == "grab" and t < 0.25 else 4.0) * delta))
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
			var x := clampf(t / GRAB_TIME, 0.0, 1.0) - 1.0
			var slam := 1.0 + 2.70158 * x * x * x + 1.70158 * x * x           # ease-out-back: it pulls you a little past, and you rebound
			pos = _from.origin.lerp(_body_at(0.0) + _fwd * 1.1, slam)
			look = (_from.origin - _from.basis.z * 3.0).lerp(_body_at(0.06), k)
			# the hit: trauma that falls off as its square, a FOV kick that eases back, the view thrown over
			shake = 0.07 * pow(1.0 - clampf(t / GRAB_TIME, 0.0, 1.0), 2.0) + 0.01
			fov = _from_fov + 16.0 * exp(-t * 8.0)
			roll = 0.12 * exp(-t * 6.0)
			_once("slam", true, func(): scares.spawn3d(scares.synth("thump"), _body_at(0.0), 0.9, "Scares", 6.0, 0.5))
			if t >= GRAB_TIME: _next("lift")
		"lift":
			# raised up the length of it, your light on it all the way, until you are level with its face
			var k := t / LIFT_TIME
			var s := k * k * k * (k * (k * 6.0 - 15.0) + 10.0)
			pos = _body_at(s) + _fwd * lerpf(1.1, 0.9, s) + Vector3.UP * 0.012 * sin(t * 2.2)     # its breathing, heaving you
			look = _body_at(minf(1.0, s + 0.1)).lerp(face, smoothstep(0.7, 1.0, s))
			fov = lerpf(_from_fov, 58.0, s)
			shake = 0.008 + 0.004 * sin(t * 1.7)
			roll = 0.03 * sin(t * 0.9)                                     # hung from its arms: a slow swing
			# its own laboured breath, over you, twice on the way up
			_once("lb1", s > 0.45, func(): scares.spawn3d(scares.synth("breath_close", 0.0), face, 0.6, "Scares", 3.0, 0.55))
			_once("lb2", s > 0.85, func(): scares.spawn3d(scares.synth("breath_close", 0.0), face, 0.8, "Scares", 2.0, 0.5))
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
			# (it stops closing in for 0.4 s at 2.0 s, the head ticks, then it comes on: the hold is the beat)
			var tt := t if t < 2.0 else (2.0 if t < 2.4 else t - 0.4)
			var k := smoothstep(0.0, STARE_TIME - 0.4, tt)
			pos = face + _fwd * (lerpf(0.9, 0.42, k) + 0.012 * sin(t * 2.4))
			look = face
			fov = lerpf(58.0, 48.0, k)
			shake = 0.004
			# your view leans over to meet its tilted head: the room goes crooked
			roll = 0.2 * smoothstep(1.2, STARE_TIME, t)
			_once("tin", true, func(): scares.spawn_flat(scares.synth("tinnitus"), 0.15))
			_once("hold", t > 2.0, func(): scares.spawn3d(scares.synth("bone_crack"), face, 0.5, "Scares", 2.0, 0.8))
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
			roll = 0.2 + 0.1 * k * sin(t * 40.0)
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
	xf.basis = xf.basis * Basis(Vector3.BACK, roll)
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
	if _net_taken:                        # our sequence is over: tell the host, and ignore its stale snapshots a moment
		_net_taken = false
		_snub = 2.0
		Net.send_burnt_result()
	_victim_id = -1
	state = "off"
	present = false
	visible = false
	_walk = 0.0
	_lean = 0.0
	_run = 0.0
	_crouch = 0.0
	_watch_t = 0.0
	_hitch_t = 0.0
	if _black != null: _set_black(0.0)
	if skel != null:
		for i: int in _rest: skel.set_bone_pose_rotation(i, _rest[i])

## The player died some other way in the middle of it: let go
func _finish() -> void:
	_despawn_quietly()

# ---------------------------------------------------------------- debug console
func debug_spawn() -> bool:
	if puppet:
		last_error = "only the host can spawn it in co-op"
		return false
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

# ---------------------------------------------------------------- co-op
## Guest: follow the host's Burnt (or, while it has us, play the sequence here)
func _physics_puppet(delta: float) -> void:
	_snub = maxf(0.0, _snub - delta)
	if not _net_taken and _snub <= 0.0: net.step(delta)
	if not present or body == null: return
	_burn_lamps(delta)
	if _net_taken: return
	_step_t -= delta * _walk
	if _step_t <= 0.0 and state == "stalk":
		_step_t = 1.3
		if scares != null:
			scares.spawn3d(scares.synth("thump"), global_position, 0.32, "Scares", 3.0, randf_range(0.9, 1.0))

func net_apply(t_: float, m: Array) -> void:
	net.apply(t_, m)

## Net (guest): the host's Burnt has this machine's player
func net_taken() -> void:
	if _pl.dead or _net_taken or (body == null and not _build()):
		Net.send_burnt_result()
		return
	_net_taken = true
	present = true
	visible = true
	_begin_sequence()

## Net (host): the guest it took is done (dead, or the sequence was cut short)
func net_result(peer_id: int) -> void:
	if peer_id == _victim_id: _despawn_quietly()
