extends "res://scripts/Entities/model_entity.gd"
## THE TALL ONE. A starved, 4.45 m figure with a human body stretched wrong and a blank face but for two real eyes.
##   roam     it wanders the level, stopping now and then to stand and cock its head
##   spot     it sees you from far off (a clear line, in front of it): the head snaps round, the body recoils...
##   flee     ...and it runs from you, out of sight
##   away     it stands where it stopped, out of sight, for a few seconds
##   scream   out of nowhere you hear it scream. You have WINDOW seconds from the first note
##   (hide)   hiding is not in the game yet: player.hidden (any truthy field on the player) stands in for it
##   hunt     the window is over and you are not hidden: running footsteps (it has moved to ~40 m of path from you,
##            unseen), coming, faster than you can run
##   kill     it leaps (the kill clip), knocks you flat, sits astride your chest and tears your face apart. The
##            camera is yours the whole way, lying on your back: pushed over, then looking straight up at it
## and then you are dead (Game.kill_player). Placed with an Entity mark of Kind "tallone" in the level editor
## (roam: it wanders from the mark; lurk: it waits there until you come within LURK_WAKE).
## Its clips are baked in tall_one.glb (tools/blender/animate_tallone.py): idle, walk, run, spot, scream, kill. They
## are played here, by hand (_animate). The kill's "KillEye" node is where your eyes are, lying under it.
## Single player and the co-op host only (a guest does not see it). `spawn tallone` in the debug console puts it
## ahead of you; tallone scream / tallone hunt start the chain at those steps.

const EntityMarks := preload("res://scripts/Entities/entity_marks.gd")
const TallNet := preload("res://scripts/Entities/tall/tall_net.gd")
const STATES := ["off", "roam", "spot", "flee", "away", "scream", "hunt", "kill"]
const CELL := 4.5
const RADIUS := 0.9

@export var roam_speed := 1.7           # m/s: what the walk clip is made for
@export var flee_speed := 10.0
@export var hunt_speed := 10.5          # faster than you can sprint
@export var see_range := 46.0           # metres: it sees you from this far, down a clear line
@export var see_cos := 0.15             # ...if you are within ~80 degrees of where it faces
@export var scream_window := 7.0        # seconds from the first note of the scream to the hunt
@export var kill_shake := 1.0           # 0..1 scales the camera shake in the kill (reduced motion)

const WALK_CLIP_SPEED := 1.7
const RUN_CLIP_SPEED := 10.0
const WALK_FALLS := [0.0, 0.5]          # fractions of the clip where a foot comes down
const RUN_FALLS := [0.0, 0.5]
const LOOPED := ["idle", "walk", "run"]
const TURN_RATE := 6.0
const LURK_WAKE := 16.0
const SPOT_TIME := 0.9
const SPOT_TURN_AT := 0.5               # seconds into the spot that it spins and goes
const FLEE_MAX := 9.0
const AWAY_MIN := 5.0                   # seconds out of sight before the scream
const AWAY_MAX := 10.0
const SCREAM_CLIP := 3.6
const WARP_AT := 3.8                    # the scream is over: unseen, it moves to where the hunt starts
const AMBUSH_MIN := 8                   # cells of path from you (~36 m) ...
const AMBUSH_MAX := 11                  # ... to ~50 m
const HUNT_MAX := 30.0                  # seconds it will run before it gives up
const POUNCE_FROM := 6.0                # the kill clip's hips start this far behind its root
const POUNCE_DIST := 5.2                # so it leaps when it is this far from you
const HIT_AT := 0.30                    # seconds into the kill that its hands reach you
const FALL_END := 1.0                   # ... and you are flat on the floor
const KILL_T := 9.0                     # the clip's length
const MARK_SPAWN_DIST := 60.0
const MARK_ARRIVE_AFTER := 240.0

var state := "off"
var t := 0.0
var yaw := 0.0
var _walk := 0.0                        # 0..1 how much it is walking
var _sp := 0.0                          # 0..1 how much it is running
var _pause := 0.0
var _wp := Vector3.ZERO                 # roam: where it is going
var _wp_t := 0.0
var _flee_to := Vector3.ZERO
var _flee_tries := 0
var _away_for := 6.0
var _warped := false
var _screamed := false
var _lurk := false
var _mark_pending := false
var _lod_go := false                 # EntityLOD has said its mark may be stood at (lod_spawn)
var _hunt_t := 0.0
var flow := PackedInt32Array()
var _flow_key := -1
var _flow_timer := 0.0
# the kill
var _from := Transform3D.IDENTITY       # your view when it leapt
var _from_fov := 75.0
var _kill_dir := Vector3.FORWARD
var _eye: Node3D                        # "KillEye" in the model
var _near := [false, false]             # a hand close to your face (a stroke)
var _trauma := 0.0
var _sounded := {}
var _cue_t := 0.0
var _hit_done := false
var skel: Skeleton3D
var _ap: AnimationPlayer
var _clip := ""
var _clip_pos := 0.0
var _bone := {}
var scares
var _pl                                 # the player, untyped (player.gd's own fields: cam, dead, frozen...)
var net: TallNet
var puppet := false                     # co-op guest: it follows the host's snapshots instead of thinking
var _tid := -1                          # the survivor it hunts (Net.survivors() id)
var _victim_id := -1                    # host: the guest it has leapt at (their machine plays the camera)
var _net_taken := false                 # guest: the host's Tall One killed this machine's player: the sequence runs here
var _snub := 0.0                        # guest: ignore the host's snapshots for a moment after our sequence
var _victim_t := 0.0

func _ready() -> void:
	super._ready()
	process_priority = 100              # after the player: its camera is ours to hold during the kill
	scares = get_parent().get_node_or_null("Scares")
	_pl = player
	net = TallNet.new(self)
	var marks := EntityMarks.of_kind(level, "tallone")
	_mark_pending = not marks.is_empty()
	EntityLOD.register(self, {} if marks.is_empty() else {"mark": EntityMarks.world_pos(marks[0]), "spawn_dist": MARK_SPAWN_DIST, "arrive_after": MARK_ARRIVE_AFTER})

func lod_spawned() -> bool:
	return present or _lod_go

func lod_engaged() -> bool:
	return state != "roam" and state != "off" and state != "away"

func lod_spawn(_at_mark: bool) -> void:
	_lod_go = true                       # (_physics_process stands it on its mark now)

func _spawn_from_mark() -> void:
	var marks := EntityMarks.of_kind(level, "tallone")
	if marks.is_empty() or not spawn_at(EntityMarks.world_pos(marks[0])):
		return
	_begin_roam()
	_lurk = EntityMarks.lurks(marks[0])

func _build() -> bool:
	if not super._build(): return false
	var found := body.find_children("*", "Skeleton3D", true, false)
	skel = found[0] as Skeleton3D if not found.is_empty() else null
	if skel != null:
		for n in ["Head", "LeftHand", "RightHand", "Hips"]:
			var i := skel.find_bone(n)
			if i >= 0: _bone[n] = i
	var aps := body.find_children("*", "AnimationPlayer", true, false)
	_ap = aps[0] as AnimationPlayer if not aps.is_empty() else null
	if _ap != null:
		_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for a in LOOPED:
			if _ap.has_animation(a): _ap.get_animation(a).loop_mode = Animation.LOOP_LINEAR
	else:
		push_warning("TallOne: %s has no clips: it will stand at rest" % model)
	_eye = body.find_child("KillEye", true, false) as Node3D
	# a skinned mesh is culled by its rest-pose box: arms thrown round the camera would be culled away
	for mi: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
		mi.extra_cull_margin = 8.0
	return true

# ---------------------------------------------------------------- the mind
func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	puppet = Net.is_online() and not Net.hosting
	if puppet:
		_physics_puppet(delta)
		return
	if Net.is_online(): net.send(delta)
	if _mark_pending and Game.playing and not Game.dead and player != null and EntityLOD.is_spawned(self):
		_mark_pending = false
		_spawn_from_mark()
	if not present or player == null: return
	if Game.freeze_ai: return
	if _pl.dead and state != "off" and _victim_id < 0:
		_finish()
		return
	t += delta
	match state:
		"roam": _roam(delta)
		"spot": _spot(delta)
		"flee": _flee(delta)
		"away": _away()
		"scream": _scream(delta)
		"hunt": _hunt(delta)
		"kill": _kill_wait(delta)

func _begin_roam() -> void:
	state = "roam"
	t = 0.0
	yaw = rotation.y
	_walk = 0.0
	_sp = 0.0
	_pause = randf_range(1.0, 3.0)
	_wp_t = 0.0
	_flee_tries = 0
	_warped = false
	_screamed = false
	_pick_waypoint()

func _roam(delta: float) -> void:
	if _lurk:
		if _nearest_dist() > LURK_WAKE: return
		_lurk = false
	if _sees_any():
		_begin_spot()
		return
	if _pause > 0.0:
		_pause -= delta
		_walk = move_toward(_walk, 0.0, delta * 3.0)
		rotation.y = yaw
		return
	_wp_t += delta
	var p := global_position
	if Vector2(_wp.x - p.x, _wp.z - p.z).length() < 2.5 or _wp_t > 45.0:
		_pause = randf_range(2.0, 6.0)         # it stops and stands, head cocked
		_pick_waypoint()
		return
	_walk = move_toward(_walk, 1.0, delta * 1.5)
	_move_toward(_wp, roam_speed * _walk, delta)
	rotation.y = yaw

func _pick_waypoint() -> void:
	var p := global_position
	_wp_t = 0.0
	for i in 14:
		var a := randf() * TAU
		var d := randf_range(16.0, 45.0)
		var c := Vector3(p.x + cos(a) * d, p.y, p.z + sin(a) * d)
		if not nav.open_at(c.x, c.z): continue
		var f := _field(c)
		var here := _cell_val(f, p)
		if here < 0 or here > 40: continue
		_wp = Vector3(GridNav.cell(c.x) * CELL, p.y, GridNav.cell(c.z) * CELL)
		return
	_wp = p

## Any survivor it can see: nothing between, close enough, in front of it, and not hidden. Remembers which
func _sees_any() -> bool:
	for sv: Dictionary in Net.survivors():
		if _sees(sv):
			_tid = sv.id
			return true
	return false

func _sees(sv: Dictionary) -> bool:
	var tgt: Vector3 = sv.pos + Vector3.UP * 1.6
	if sv.local:
		if _pl.frozen or _pl.spawn_grace > 0.0 or Game.god_mode or _player_hidden(): return false
		tgt = (_pl.cam as Camera3D).global_position
	var eye := global_position + Vector3.UP * 4.0
	var to := tgt - eye
	if to.length() > see_range: return false
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var flat := Vector3(to.x, 0.0, to.z).normalized()
	if fwd.dot(flat) < see_cos: return false
	return nav.clear_line(eye.x, eye.z, tgt.x, tgt.z)

## Hiding is not in the game yet. Anything that sets a truthy `hidden` on the player stands in for it.
func _player_hidden() -> bool:
	var h = _pl.get("hidden")
	return h != null and bool(h)

## The survivor it hunts: the nearest, and the one it already has keeps a small edge ({} if nobody is left)
func _target() -> Dictionary:
	var best := Net.nearest_survivor(global_position, _tid)
	_tid = best.get("id", -1)
	return best

## Where its target is (the local player if there is no survivor to be had)
func _tpos() -> Vector3:
	var tg := _target()
	return tg.pos if not tg.is_empty() else player.global_position

func _nearest_dist() -> float:
	var p := global_position
	var q := _tpos()
	return Vector2(q.x - p.x, q.z - p.z).length()

func _dist_to_player() -> float:
	var p := global_position
	var q := player.global_position
	return Vector2(q.x - p.x, q.z - p.z).length()

## Is any survivor looking at where it stands?
func _in_any_view() -> bool:
	for sv: Dictionary in Net.survivors():
		var eye: Vector3 = sv.pos + Vector3.UP * 1.6
		var look: Vector3 = sv.fwd
		if sv.local:
			var cam: Camera3D = _pl.cam
			eye = cam.global_position
			look = -cam.global_transform.basis.z
		var to := global_position + Vector3.UP * 2.0 - eye
		if to.length() > 90.0: continue
		var dir := to.normalized() if sv.local else Vector3(to.x, 0.0, to.z).normalized()
		if look.dot(dir) < 0.25: continue
		if nav.clear_line(eye.x, eye.z, global_position.x, global_position.z): return true
	return false

func _begin_spot() -> void:
	state = "spot"
	t = 0.0
	_walk = 0.0
	_clip = ""
	if scares != null:
		scares.spawn3d(scares.synth("bone_crack"), global_position + Vector3.UP * 3.0, 0.5, "Scares", 8.0, 0.7)

func _spot(delta: float) -> void:
	var to := _tpos() - global_position
	if t < SPOT_TURN_AT:
		yaw = lerp_angle(yaw, atan2(to.x, to.z), minf(1.0, delta * 14.0))      # the head is on you: so is the body
	else:
		if _flee_to == Vector3.ZERO or t - delta < SPOT_TURN_AT:
			_pick_flee()
		var d := Vector3(_flee_to.x - global_position.x, 0.0, _flee_to.z - global_position.z)
		yaw = lerp_angle(yaw, atan2(d.x, d.z), minf(1.0, delta * 10.0))
	rotation.y = yaw
	if t >= SPOT_TIME:
		state = "flee"
		t = 0.0
		_sp = 0.0

func _pick_flee() -> void:
	var pf := _field(_tpos())
	var ef := _field(global_position)
	var n: int = nav.n
	var best := -INF
	var at := Vector3.ZERO
	for x in n:
		for z in n:
			var pv := pf[x * n + z]
			var ev := ef[x * n + z]
			if pv < 9 or ev < 3 or ev > 22: continue
			var w := Vector3(x * CELL, global_position.y, z * CELL)
			var score := float(pv - ev) + randf() * 3.0
			if score > best:
				best = score
				at = w
	if best == -INF:                                                             # nowhere far: straight away from you
		var away := (global_position - _tpos()).normalized()
		at = global_position + Vector3(away.x, 0.0, away.z) * 20.0
	_flee_to = at

func _flee(delta: float) -> void:
	_sp = move_toward(_sp, 1.0, delta * 2.5)
	_move_toward(_flee_to, flee_speed * _sp, delta)
	rotation.y = yaw
	var p := global_position
	var arrived := Vector2(_flee_to.x - p.x, _flee_to.z - p.z).length() < 3.0
	if arrived or t > FLEE_MAX:
		if _in_any_view() and _flee_tries < 3:           # still in sight: run on
			_flee_tries += 1
			t = 0.0
			_pick_flee()
			return
		state = "away"
		t = 0.0
		_sp = 0.0
		_away_for = randf_range(AWAY_MIN, AWAY_MAX)
		_clip = ""

func _away() -> void:
	rotation.y = yaw
	if t >= _away_for:
		_begin_scream()

func _begin_scream() -> void:
	state = "scream"
	t = 0.0
	_clip = ""
	_warped = false
	_screamed = false
	var tp := _tpos()
	var fwd := Vector3(tp.x - global_position.x, 0.0, tp.z - global_position.z)
	if fwd.length() > 0.1: yaw = atan2(fwd.x, fwd.z)          # it turns to where you are before it screams
	rotation.y = yaw

func _scream(delta: float) -> void:
	rotation.y = yaw
	if not _screamed and t >= 0.5:                             # on the release: the head goes back
		_screamed = true
		_voice_scream()
	# the window: you have `scream_window` seconds from the first note (the clip's head-back is at ~0.55 s)
	if not _warped and t >= WARP_AT and not _in_any_view():
		_warped = true
		_ambush_warp()
	if t >= scream_window + 0.5:
		if _target_hidden():                                   # you hid: it loses you and goes back to roaming
			_begin_roam()
			_pause = randf_range(4.0, 8.0)
			return
		_begin_hunt()

func _voice_scream() -> void:
	if scares == null: return
	var at := global_position + Vector3.UP * 3.8
	var blocked := not nav.clear_line(global_position.x, global_position.z, player.global_position.x, player.global_position.z)
	scares.set_entity_occlusion(blocked)
	scares.entity_call("scream", at, true, 1.7, 0.7)
	Game.fx_shock = maxf(Game.fx_shock, 0.35)
	Game.fear = maxf(Game.fear, 0.8)

## Unseen, it moves to ~40 m of path from you, where the run begins
func _ambush_warp() -> void:
	var pp := _tpos()
	var pf := _field(pp)
	var n: int = nav.n
	var picks: Array[Vector3] = []
	for x in n:
		for z in n:
			var v := pf[x * n + z]
			if v < AMBUSH_MIN or v > AMBUSH_MAX: continue
			var w := Vector3(x * CELL, global_position.y, z * CELL)
			if not nav.open_at(w.x, w.z) or nav.clear_line(pp.x, pp.z, w.x, w.z): continue
			picks.append(w)
	if picks.is_empty(): return
	var at: Vector3 = picks[randi() % picks.size()]
	global_position = Vector3(at.x, global_position.y, at.z)
	_flow_key = -1

func _begin_hunt() -> void:
	state = "hunt"
	t = 0.0
	_hunt_t = 0.0
	_sp = 0.0
	_clip = ""
	var to := _tpos() - global_position
	yaw = atan2(to.x, to.z)
	rotation.y = yaw

func _hunt(delta: float) -> void:
	_hunt_t += delta
	var tgt := _target()
	if tgt.is_empty() or (tgt.local and _player_hidden()) or _hunt_t > HUNT_MAX:
		_begin_roam()
		return
	var pp: Vector3 = tgt.pos
	var p := global_position
	var d := Vector2(pp.x - p.x, pp.z - p.z).length()
	if d <= POUNCE_DIST and nav.clear_line(p.x, p.z, pp.x, pp.z) and _can_take(tgt):
		_begin_kill(tgt)
		return
	_sp = move_toward(_sp, 1.0, delta * 3.0)
	_move_toward(pp, hunt_speed * _sp, delta)
	rotation.y = yaw
	if tgt.local: Game.fear = maxf(Game.fear, 0.6 + 0.4 * clampf(1.0 - d / 40.0, 0.0, 1.0))

func _can_take(tgt: Dictionary) -> bool:
	if not tgt.local: return true
	return not _pl.dead and not _pl.frozen and not Game.god_mode

## Hidden: only the local player can be (nothing tells the host a guest has hidden yet)
func _target_hidden() -> bool:
	var tgt := _target()
	return not tgt.is_empty() and tgt.local and _player_hidden()

# ---------------------------------------------------------------- moving
func _yaw_to(at: Vector3) -> float:
	return atan2(at.x - global_position.x, at.z - global_position.z)

## Toward `to`: straight when it can see it, else down a flow field over the grid
func _move_toward(to: Vector3, speed: float, delta: float) -> void:
	var p := global_position
	var dir := Vector3(to.x - p.x, 0.0, to.z - p.z)
	if dir.length() > 9.0 or not nav.clear_line(p.x, p.z, to.x, to.z):
		dir = _flow_dir(to)
	if dir.length_squared() < 0.0001: return
	dir = dir.normalized()
	yaw = lerp_angle(yaw, atan2(dir.x, dir.z), minf(1.0, delta * TURN_RATE * (1.0 + _sp)))
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var np := nav.resolve(p + fwd.lerp(dir, 0.5).normalized() * speed * delta, RADIUS)
	global_position = Vector3(np.x, p.y, np.z)

## Path length in cells from the cell holding `at` to every cell (-1: unreachable), as nav.bfs makes it
func _field(at: Vector3) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(nav.n * nav.n)
	nav.bfs(GridNav.cell(at.x), GridNav.cell(at.z), out)
	return out

func _cell_val(f: PackedInt32Array, at: Vector3) -> int:
	var x := GridNav.cell(at.x)
	var z := GridNav.cell(at.z)
	var n: int = nav.n
	if x < 0 or z < 0 or x >= n or z >= n: return -1
	return f[x * n + z]

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

# ---------------------------------------------------------------- its body: the clips
func _process(delta: float) -> void:
	if not present or body == null: return
	var asleep := EntityLOD.tier(self) == EntityLOD.ASLEEP and state in ["roam", "away"]
	if body.visible == asleep:
		body.visible = not asleep
	if asleep: return
	body.position = Vector3.ZERO
	body.rotation = Vector3(0.0, deg_to_rad(yaw_offset), 0.0)
	_animate(delta)
	if state == "kill" and _victim_id < 0 and (not puppet or _net_taken):
		_kill(delta)

func _animate(delta: float) -> void:
	if puppet and state == "scream" and not _screamed and t >= 0.5:
		_screamed = true
		_voice_scream()
	if _ap == null: return
	var clip := "idle"
	var speed := 1.0
	var fade := 0.4
	match state:
		"roam":
			if _walk > 0.02:
				clip = "walk"
				speed = _walk * roam_speed / WALK_CLIP_SPEED
				fade = 0.3
		"spot":
			clip = "spot"
			fade = 0.05
		"flee":
			clip = "run"
			speed = maxf(0.5, _sp * flee_speed / RUN_CLIP_SPEED)
			fade = 0.15
		"hunt":
			clip = "run"
			speed = maxf(0.5, _sp * hunt_speed / RUN_CLIP_SPEED)
			fade = 0.2
		"scream":
			if t < SCREAM_CLIP:
				clip = "scream"
				fade = 0.15
			else:
				fade = 1.0
		"kill":
			clip = "kill"
			fade = 0.1
	if clip != _clip:
		if not _ap.has_animation(clip): return
		_ap.play(clip, fade)
		if clip == "kill" and puppet and not _net_taken: _ap.seek(t, true)
		_clip = clip
		_clip_pos = _ap.current_animation_position
	_ap.speed_scale = speed
	_ap.advance(delta)
	var at := _ap.current_animation_position
	if clip == "walk" or clip == "run":
		var len := _ap.current_animation_length
		for f: float in (WALK_FALLS if clip == "walk" else RUN_FALLS):
			var ft := f * len
			if (_clip_pos < ft and ft <= at) or (at < _clip_pos and (ft > _clip_pos or ft <= at)):
				_footfall(clip == "run")
	_clip_pos = at

## A foot down. Walking: slow and heavy. Running: you hear it coming from far off, and the floor shudders when it is near
func _footfall(running: bool) -> void:
	if scares == null: return
	if not running:
		scares.spawn3d(scares.synth("thump"), global_position, 0.45, "Scares", 6.0, randf_range(0.55, 0.65))
		return
	var d := _dist_to_player()
	scares.spawn3d(scares.synth("thump"), global_position, 1.0, "Scares", 11.0, randf_range(0.5, 0.62))
	scares.spawn3d(scares.synth("howler_far"), global_position, 0.7, "Scares", 14.0, randf_range(0.7, 0.85))
	var near := clampf(1.0 - d / 30.0, 0.0, 1.0)
	_pl.jolt(1.2 * near)
	Game.fx_shock = maxf(Game.fx_shock, 0.15 * near)

# ---------------------------------------------------------------- the kill
## It leaps at `tgt`. The local player gets the camera sequence here; a guest is told (Net) and plays it on their own
## machine, while the clip plays in the world here for everyone else
func _begin_kill(tgt: Dictionary) -> void:
	_root_kill(tgt.pos)
	if tgt.local:
		_start_kill_view()
	else:
		_victim_id = tgt.id
		_victim_t = 0.0
		Net.send_tall_take(_victim_id)

## Its root is where your chest will end up; the clip begins POUNCE_FROM behind it, right where it is now
func _root_kill(pp: Vector3) -> void:
	state = "kill"
	t = 0.0
	_sp = 0.0
	_clip = ""
	var f := Vector3(pp.x - global_position.x, 0.0, pp.z - global_position.z)
	_kill_dir = f.normalized() if f.length() > 0.01 else Vector3(sin(yaw), 0.0, cos(yaw))
	global_position += _kill_dir * POUNCE_FROM
	yaw = atan2(_kill_dir.x, _kill_dir.z)
	rotation.y = yaw

## You are the one it has: freeze, take the view
func _start_kill_view() -> void:
	_sounded = {}
	_hit_done = false
	_cue_t = 0.0
	_near = [false, false]
	_trauma = 0.0
	_pl.frozen = true
	player.velocity = Vector3.ZERO
	var cam: Camera3D = _pl.cam
	_from = cam.global_transform
	_from_fov = cam.fov
	Game.fx_reset()
	Game.fear = 1.0

## Where your eyes are lying under it, looking up: the model's KillEye (else worked out from its root)
func _eye_xf() -> Transform3D:
	if _eye != null:
		var xf := _eye.global_transform
		xf.basis = xf.basis.orthonormalized()
		return xf
	var up := _kill_dir
	var look := Vector3.UP
	var right := look.cross(up).normalized()
	return Transform3D(Basis(right, up, -look), global_position + _kill_dir * 0.62 + Vector3.UP * 0.18)

func _hand_pos(name: String) -> Vector3:
	if skel == null or not _bone.has(name): return global_position + Vector3.UP
	return skel.global_transform * skel.get_bone_global_pose(_bone[name]).origin

func _kill(delta: float) -> void:
	if _pl.dead:
		_finish()
		return
	var cam: Camera3D = _pl.cam
	var eye := _eye_xf()
	var pos := _from.origin
	var q := _from.basis.get_rotation_quaternion()
	var fov := _from_fov
	var roll := 0.0
	var shake := 0.0
	if t < HIT_AT:
		# it is on you: the view holds, and the picture starts to press in
		fov = _from_fov + 8.0 * smoothstep(0.0, HIT_AT, t)
		shake = 0.004 + 0.01 * smoothstep(0.0, HIT_AT, t)
	elif t < FALL_END:
		# the blow, and you go over backwards: eyes swing round the heels to the floor, the view thrown up at it
		var h := t - HIT_AT
		var k := smoothstep(HIT_AT, FALL_END, t)
		pos = _from.origin.lerp(eye.origin, k) + Vector3.UP * 0.5 * sin(PI * k) * (1.0 - k)
		q = _from.basis.get_rotation_quaternion().slerp(eye.basis.get_rotation_quaternion(), k)
		fov = _from_fov + 24.0 * exp(-h * 6.0)
		roll = 0.3 * exp(-h * 4.0) * sin(h * 9.0)
		shake = 0.06 * exp(-h * 5.0)
		if not _hit_done:
			_hit_done = true
			_hit()
	else:
		pos = eye.origin
		q = eye.basis.get_rotation_quaternion()
		var k2 := clampf((t - 1.7) / (KILL_T - 1.7), 0.0, 1.0)         # the tear: 0 at the start of it .. 1 at the end
		fov = lerpf(_from_fov - 5.0, _from_fov - 26.0, smoothstep(0.0, 1.0, k2))
		roll = 0.05 * sin(t * 3.0) + 0.04 * k2 * sin(t * 17.0)
		shake = 0.006 + 0.02 * k2
		_tear(delta, pos, k2)
	_trauma = maxf(0.0, _trauma - delta * 1.6)
	var tr := _trauma * _trauma * kill_shake
	var jit := Vector3(sin(Game.time * 37.0), sin(Game.time * 29.0 + 1.3), sin(Game.time * 23.0 + 2.1)) * (shake + 0.07 * tr) * kill_shake
	var b := Basis(q) * Basis(Vector3.BACK, roll * kill_shake + 0.12 * tr * sin(Game.time * 41.0))
	cam.global_transform = Transform3D(b, pos + jit)
	cam.fov = fov
	player.velocity = Vector3.ZERO
	if t >= KILL_T:
		_die()

## The blow
func _hit() -> void:
	Game.fx_shock = 1.0
	_trauma = 1.0
	_pl.jolt(2.0)
	_quiet()
	if scares != null:
		scares.seize()
		scares.spawn3d(scares.synth("thump"), global_position + _kill_dir * -1.5, 1.2, "Scares", 8.0, 0.45)
		scares.spawn3d(scares.synth("bone_crack"), (_pl.cam as Camera3D).global_position, 0.9, "Scares", 3.0, 0.7)

## The world drops away: the hum dies, everything muffled and far off; what is left is it
func _quiet() -> void:
	var root := get_parent()
	var au: Node = root.get_node_or_null("Audio")
	if au != null:
		au.set_muffled(true)
		au.set_dread(0.0)
	var amb: Node = root.get_node_or_null("Audio/Ambience")
	if amb != null: amb.hush_for(0.02, KILL_T + 2.0)

## Sat on you, tearing: each time a hand comes down across your face is a stroke (camera jolt, a wet sound, more blood)
func _tear(delta: float, cam_pos: Vector3, k: float) -> void:
	var landed := t >= 1.05
	_once("land", landed, func():
		_trauma = 1.0
		_pl.jolt(1.5)
		if scares != null:
			scares.spawn3d(scares.synth("thump"), global_position, 1.2, "Scares", 6.0, 0.5)
			scares.heartbeat(1.0)
	)
	_once("scream", t >= 1.5, func():
		if scares != null:
			scares.set_entity_occlusion(false)
			scares.entity_call("scream", _hand_pos("Head") + Vector3.UP * 0.3, true, 1.5, 0.62)
	)
	if t < 1.7: return
	# the picture comes apart with you
	Game.fx_blood = maxf(Game.fx_blood, 0.12 + 0.8 * k)
	Game.fx_sat = 1.0 - 0.55 * k
	Game.fx_contrast = 1.0 + 0.3 * k
	Game.glitch = maxf(Game.glitch, 0.15 + 0.7 * k)
	Game.fx_warp = 0.003 + 0.02 * k
	Game.fx_static = 0.05 + 0.6 * k * k
	if randf() < delta * (1.0 + 4.0 * k): Game.fx_corrupt = maxf(Game.fx_corrupt, 0.15 + 0.4 * k)
	Game.fx_fade = smoothstep(7.4, KILL_T, t)                  # the edges close in, last
	var hands := ["LeftHand", "RightHand"]
	for i in 2:
		var d := _hand_pos(hands[i]).distance_to(cam_pos)
		if d < 0.6 and not _near[i]:
			_near[i] = true
			_stroke(cam_pos, k)
		elif d > 0.8:
			_near[i] = false
	_cue(delta, randf_range(0.7, 1.2), func():
		if scares != null:
			scares.spawn3d(scares.synth("wall_scratch", float(randi() % 3)), cam_pos + Vector3.UP * 0.1, 0.9, "Scares", 2.0, randf_range(0.5, 0.7), false)
			scares.heartbeat(1.0 - 0.4 * k)
	)

func _stroke(cam_pos: Vector3, k: float) -> void:
	_trauma = minf(1.0, _trauma + 0.55)
	Game.fx_shock = maxf(Game.fx_shock, 0.45)
	Game.fx_flash = maxf(Game.fx_flash, 0.25)
	Game.fx_blood = minf(1.0, Game.fx_blood + 0.05)
	_pl.jolt(0.8)
	if scares != null:
		scares.spawn3d(scares.synth("splat"), cam_pos, 1.0, "Scares", 2.0, randf_range(0.7, 1.0), false)
		if randf() < 0.5:
			scares.spawn3d(scares.synth("bone_crack"), cam_pos, 0.6, "Scares", 2.0, randf_range(0.6, 0.9), false)

func _cue(delta: float, every: float, call: Callable) -> void:
	_cue_t -= delta
	if _cue_t <= 0.0:
		_cue_t = every
		call.call()

func _once(key: String, when: bool, call: Callable) -> void:
	if not when or _sounded.has(key): return
	_sounded[key] = true
	call.call()

func _die() -> void:
	_pl.frozen = false
	Game.kill_player("THE TALL ONE", Game.DeathType.RIPPED)
	_despawn_quietly()

func _despawn_quietly() -> void:
	if _net_taken:                        # our sequence is over: tell the host, and ignore its stale snapshots a moment
		_net_taken = false
		_snub = 2.0
		Net.send_tall_result()
	_victim_id = -1
	state = "off"
	present = false
	visible = false
	_walk = 0.0
	_sp = 0.0
	_clip = ""
	if _ap != null: _ap.stop()

## The player died some other way in the middle of it: let go
func _finish() -> void:
	_despawn_quietly()

# ---------------------------------------------------------------- debug console
func debug_spawn() -> bool:
	if Net.is_online() and not Net.hosting:
		last_error = "only the host can spawn it in co-op"
		return false
	last_error = ""
	if body == null and not _build():
		return false
	var p := player.global_position
	var fwd := -player.global_transform.basis.z
	fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
	for turn in [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, PI]:       # ahead first, then round you
		var dir := fwd.rotated(Vector3.UP, turn)
		var d := 26.0
		while d >= 4.0:
			var c := p + dir * d
			if nav.open_at(c.x, c.z) and nav.clear_line(p.x, p.z, c.x, c.z):
				global_position = Vector3(c.x, _floor_y(c, p.y), c.z)
				yaw = atan2(-dir.x, -dir.z)         # facing you: it sees you at once
				rotation.y = yaw
				present = true
				visible = true
				_begin_roam()
				_pause = 0.0
				return true
			d -= 2.0
	last_error = "no room to spawn here, try another spot"
	return false

## Console: start the chain at the scream (it stands out of sight and screams at once)
func debug_scream() -> bool:
	if not present and not debug_spawn(): return false
	_begin_scream()
	return true

## Console: it is already running at you
func debug_hunt() -> bool:
	if not present and not debug_spawn(): return false
	_ambush_warp()
	_begin_hunt()
	return true

func debug_despawn() -> void:
	if state == "kill" and player != null and not _pl.dead:
		_pl.frozen = false
		Game.fx_reset()
		var au: Node = get_parent().get_node_or_null("Audio")
		if au != null: au.set_muffled(false)
	_despawn_quietly()
	super.debug_despawn()

# ---------------------------------------------------------------- co-op
## Host: a guest is the one it has leapt at: the clip plays here for the others; their machine plays the camera
func _kill_wait(delta: float) -> void:
	if _victim_id < 0: return
	_victim_t += delta
	if _victim_t > KILL_T + 6.0: _despawn_quietly()     # (their result never came)

## Guest: follow the host's Tall One (or, while it has us, play the kill here)
func _physics_puppet(delta: float) -> void:
	_snub = maxf(0.0, _snub - delta)
	if _net_taken:
		t += delta
		return
	if _snub <= 0.0: net.step(delta)

func net_apply(t_: float, m: Array) -> void:
	net.apply(t_, m)

## Net (guest): the host's Tall One has this machine's player
func net_taken() -> void:
	if _pl.dead or _net_taken or (body == null and not _build()):
		Net.send_tall_result()
		return
	_net_taken = true
	present = true
	visible = true
	_root_kill(player.global_position)
	_start_kill_view()

## Net (host): the guest it killed is done (dead, or the sequence was cut short)
func net_result(peer_id: int) -> void:
	if peer_id == _victim_id: _despawn_quietly()
