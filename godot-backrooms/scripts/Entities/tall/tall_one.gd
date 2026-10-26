extends "res://scripts/Entities/model_entity.gd"
## THE TALL ONE. A starved, 4.45 m figure with a human body stretched wrong and a blank face but for two real eyes.
##   roam     it wanders the level, stopping now and then to stand and cock its head
##   spot     it sees you from far off (a clear line, in front of it): the head snaps round, the body recoils...
##   flee     ...and it runs from you, out of sight
##   away     it stands where it stopped, out of sight, for a few seconds
##   scream   out of nowhere you hear it scream. You have WINDOW seconds from the first note
##   (hide)   player.hidden: you climbed into a hiding place (props/hide_spot.gd: the metal cabinet, the locker, the
##            cavity behind a weak spot you broke open in a wall, props/weak_spot.gd, whose "door" is the hole). It cannot
##            see you in there. If it watched you get in, it comes for the door:
##   stalk    it carries its run in and slows to a creep as it nears the door you went through (if it did not see you go
##            in: to where it last had you, where it stands and looks about, then roams)
##   peer     it folds down in front of the door, its face level with the vent, and stares in at you for three seconds,
##            its fingers tapping on the door. Climb out now and it has you
##   circle   it unfolds, walks round the side and stands behind it a moment, then goes back to roaming
##   hunt     the window is over and you are not hidden: running footsteps (it has moved to ~40 m of path from you,
##            unseen), coming, faster than you can run
##   kill     it leaps (the kill clip), knocks you flat, sits astride your chest and tears your face apart. The
##            camera is yours the whole way, lying on your back: pushed over, then looking straight up at it. Your
##            head is knocked about by its hands, read straight off the clip (_hands): every blow it lands kicks the
##            view the way the claws were going and throws blood up off your face and onto the lens; the rip yanks
##            it; you gasp, it screams, and the last breath goes out of you as its face comes down
## and then you are dead (Game.kill_player), lying where it left you (Death.lying). Placed with an Entity mark of Kind "tallone" in the level editor
## (roam: it wanders from the mark; lurk: it waits there until you come within LURK_WAKE).
## Its clips are baked in tall_one.glb (tools/blender/animate_tallone.py): idle, walk, run, spot, scream, kill. They
## are played here, by hand (_animate). The kill's "KillEye" node is where your eyes are, lying under it.
## Single player and the co-op host only (a guest does not see it). `spawn tallone` in the debug console puts it
## ahead of you; tallone scream / tallone hunt start the chain at those steps.

const EntityMarks := preload("res://scripts/Entities/entity_marks.gd")
const TallNet := preload("res://scripts/Entities/tall/tall_net.gd")
const STATES := ["off", "roam", "spot", "flee", "away", "scream", "hunt", "kill", "stalk", "peer", "circle"]
const CELL := 4.5
const RADIUS := 0.9

@export var roam_speed := 1.7           # m/s: what the walk clip is made for
@export var flee_speed := 10.0
@export var hunt_speed := 10.5          # faster than you can sprint
@export var see_range := 46.0           # metres: it sees you from this far, down a clear line
@export var see_cos := 0.15             # ...if you are within ~80 degrees of where it faces
@export var scream_window := 7.0        # seconds from the first note of the scream to the hunt
@export var kill_shake := 1.0           # 0..1 scales the camera shake in the kill (reduced motion)
@export var hand_push := 3.0            # how hard a hand moving at your face drags your head along with it
@export var hand_twist := 1.5           # ...and turns it
@export var blow_kick := 1.0            # how hard a blow knocks your head (the view) the way the claws were going

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
const KILL_T := 9.6                     # the clip's length
# the clip's beats (animate_tallone.py kill_hands, k + 1.7): the blows themselves are read off the hands, not timed
const TEAR_AT := 1.7                    # sat on you: its hands go to work
const LOOK_AT := 4.15                   # it stops to look at its fingers
const GRIP_AT := 5.45                   # both hands hooked into your face...
const RIP_AT := 6.76                    # ...torn free
const LIDS_AT := 8.55                   # its face coming down: your eyes start to close for good
const LAST_BREATH := 8.95
const HANDS := ["LeftHand", "RightHand"]
const BLOW_NEAR := 0.6                  # a wrist closing on your eyes this near...
const BLOW_CLOSING := 3.0               # ...at this speed (m/s) is a blow (from the clip: 9-15 m/s for a real one)
const FACE_ABOVE := 0.12                # higher over your eyes than this it is your face; lower, the floor beside it
const MARK_SPAWN_DIST := 60.0
# when you hide (props/hide_spot.gd)
const PEER_T := 5.1                     # the peer clip (animate_tallone.py PEER_T): folding down, the 3 s stare, standing
const PEER_DOOR := 1.78                 # m from the door its root stands: its face ~0.55 m off the vent, clear of the door (animate_tallone.py)
const PEER_TAPS := [2.3, 2.55, 2.8, 3.6, 3.75]    # its fingers on the door
const STALK_JOG := 4.0                  # m/s: going to where it last had you
const STALK_CREEP := 0.9                # m/s: the last few metres to the door
const STALK_RUN := 3.6                  # above this it runs (the run clip), below it walks
const LOOK_ABOUT := 4.0                 # s it stands where it lost you, looking about
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
var _trauma := 0.0
var _hand_prev := [Vector3.ZERO, Vector3.ZERO]
var _hand_v := [Vector3.ZERO, Vector3.ZERO]
var _hands_on := false
var _armed := [true, true]              # a hand away from you (or slow): its next fast approach is a blow
var _gripped := false                   # both hands holding your face: the next jerk away is a rip
var _head := Vector3.ZERO               # your head knocked off true by its hands: an offset in the view's own axes...
var _head_v := Vector3.ZERO
var _turn := Vector3.ZERO               # ...and a turn (pitch, yaw, roll)
var _turn_v := Vector3.ZERO
var _blows := 0
var _pulls := 0
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
# hiding (props/hide_spot.gd)
var _was_hidden := false
var _seen_hide := false                 # it watched you get in: it goes to the door, not just to where you were
var _hide: Node3D                       # the hiding place you are in (hide_spot.gd)
var _goal := Vector3.ZERO               # stalk: where it is going (when it did not see you get in)
var _route: Array[Vector3] = []         # circle: the way round behind the hiding place
var _hold := 0.0                        # circle: s to stand behind it
var _stalk_top := 4.0                   # stalk: m/s it goes at, at most (from a chase: all out; from a walk: a jog)
## stalk / circle: _walk is the speed it is moving at (m/s), so a co-op guest sees the same walk or run (tall_net.gd)
var _kill_light: OmniLight3D            # your torch guttering on its face, from where your eyes are

func _ready() -> void:
	super._ready()
	nav.area_kind = "tallone"
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
	var hid := _player_hidden()
	if hid and not _was_hidden: _on_player_hid()
	_was_hidden = hid
	match state:
		"roam": _roam(delta)
		"spot": _spot(delta)
		"flee": _flee(delta)
		"away": _away()
		"scream": _scream(delta)
		"hunt": _hunt(delta)
		"kill": _kill_wait(delta)
		"stalk": _stalk(delta)
		"peer": _peer(delta)
		"circle": _circle(delta)

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

## Hiding: player.hidden is set while you are inside a hiding place (props/hide_spot.gd).
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
	scares.entity_call("tall_scream", at, true, 1.7, 1.0)
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
	if tgt.is_empty():
		_begin_roam()
		return
	if (tgt.local and _player_hidden()) or _hunt_t > HUNT_MAX:     # lost you: it runs on a little, slowing, and looks about
		_begin_stalk(global_position + Vector3(sin(yaw), 0.0, cos(yaw)) * 6.0, false)
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

# ---------------------------------------------------------------- when you hide (props/hide_spot.gd)
## You just got into a hiding place. Chasing you, or roaming with you in front of it, it may have seen you go in
func _on_player_hid() -> void:
	if not state in ["roam", "hunt", "stalk", "circle"]: return       # (fleeing, screaming, out of sight: it does not know)
	_hide = _pl.get("hiding_in") as Node3D
	var saw := _saw_you_hide(state != "roam")
	if saw and _hide != null:
		_begin_stalk(Vector3.ZERO, true)
	elif state == "hunt":
		_begin_stalk(player.global_position, false)         # it had you a moment ago: it goes to where you were

## Eyes on you as you got in: a clear line, in range (chasing, it is looking at you whichever way it faces)
func _saw_you_hide(chasing: bool) -> bool:
	var eye := global_position + Vector3.UP * 4.0
	var pp: Vector3 = player.global_position
	var to := Vector3(pp.x - eye.x, 0.0, pp.z - eye.z)
	if to.length() > see_range: return false
	if not chasing and Vector3(sin(yaw), 0.0, cos(yaw)).dot(to.normalized()) < see_cos: return false
	return nav.clear_line(eye.x, eye.z, pp.x, pp.z)

## The hiding place's door, where you went in (world, on the floor), and the way out of it
func _hide_door() -> Vector3:
	var at: Vector3 = _hide.get_handle_global_pos()
	return Vector3(at.x, global_position.y, at.z)

func _hide_out() -> Vector3:
	var prop: Node3D = _hide.get("prop")
	var f := prop.global_transform.basis.x
	return Vector3(f.x, 0.0, f.z).normalized()

## Where it stands to peer in: PEER_DOOR out from the door, so its face comes down level with the vent
func _peer_stand() -> Vector3:
	var at := _hide_door() + _hide_out() * PEER_DOOR
	var np := nav.resolve(at, RADIUS)
	return Vector3(np.x, global_position.y, np.z)

func _hide_ok() -> bool:
	return _hide != null and is_instance_valid(_hide) and _player_hidden() and _pl.get("hiding_in") == _hide

## `seen`: to the door of the hiding place it watched you get into; else to `to`, where it lost you
func _begin_stalk(to: Vector3, seen: bool) -> void:
	var speed := hunt_speed * _sp if state == "hunt" else (roam_speed * _walk if state == "roam" else _walk)
	_stalk_top = hunt_speed if state == "hunt" and seen else STALK_JOG
	state = "stalk"
	t = 0.0
	_seen_hide = seen
	_goal = to
	_walk = maxf(speed, STALK_CREEP)
	_sp = 0.0
	_pause = 0.0

func _stalk(delta: float) -> void:
	if _came_out(): return
	if _seen_hide and not _hide_ok(): _seen_hide = false              # (you got out unseen, or it is gone)
	var goal := _peer_stand() if _seen_hide else _goal
	var p := global_position
	var d := Vector2(goal.x - p.x, goal.z - p.z).length()
	if _pause > 0.0:                                                  # where it lost you: it stands and looks about
		_pause -= delta
		_walk = move_toward(_walk, 0.0, delta * 3.0)
		yaw += sin(t * 0.9) * delta * 1.1
		rotation.y = yaw
		if _pause <= 0.0:
			_begin_roam()
			_pause = randf_range(1.0, 2.0)
		return
	if d < 0.4 or t > 30.0:
		if _seen_hide:
			# at the door: it turns square to it, stepping onto its mark (its face must not go through the door), then folds down
			var face := atan2(-_hide_out().x, -_hide_out().z)
			global_position = global_position.move_toward(goal, delta * 0.8)
			_walk = move_toward(_walk, 0.0, delta * 3.0)
			yaw = lerp_angle(yaw, face, minf(1.0, delta * 3.0))
			rotation.y = yaw
			if absf(angle_difference(yaw, face)) < 0.08 and _walk < 0.1 and global_position.distance_to(goal) < 0.05: _begin_peer()
		else:
			_pause = LOOK_ABOUT
		return
	# it comes on as fast as it was going and slows as it nears, the last few metres a creep
	var want := clampf((d - 1.0) * 0.8, STALK_CREEP, _stalk_top)
	_walk = move_toward(_walk, want, delta * (7.0 if want < _walk else 2.0))
	_sp = clampf((_walk - STALK_RUN) / (hunt_speed - STALK_RUN), 0.0, 1.0)
	_move_toward(goal, _walk, delta)
	rotation.y = yaw
	if _seen_hide: Game.fear = maxf(Game.fear, 0.5 + 0.5 * clampf(1.0 - d / 25.0, 0.0, 1.0))

## You got out and it can see you (or you are right under it): the hunt is back on, and close, it has you at once
func _came_out() -> bool:
	if _player_hidden() or _pl.frozen: return false
	if _sees_any() or _dist_to_player() < 8.0:
		_begin_hunt()
		_sp = 0.6
		return true
	return false

func _begin_peer() -> void:
	state = "peer"
	t = 0.0
	_walk = 0.0
	_sp = 0.0
	_sounded = {}
	if scares != null:
		scares.spawn3d(scares.synth("bone_crack"), global_position + Vector3.UP * 2.0, 0.45, "Scares", 4.0, randf_range(0.6, 0.7))

func _peer(_delta: float) -> void:
	rotation.y = yaw
	if _came_out(): return
	Game.fear = maxf(Game.fear, 0.9)
	if scares != null and _hide_ok():
		var door := _hide_door() + Vector3.UP * 1.3
		_once("breath", t >= 1.3, func(): scares.spawn3d(scares.synth("breath_close"), door + Vector3.UP * 0.4, 0.55, "Scares", 2.5, 0.62, false))
		for i in PEER_TAPS.size():
			_once("tap%d" % i, t >= PEER_TAPS[i], func(): scares.spawn3d(scares.synth("wall_knock", 0.0), door, 0.25, "Scares", 2.0, randf_range(1.3, 1.5), false))
	if t >= PEER_T:
		_begin_circle()

## Round the side of the hiding place to stand behind it (the side with room), then off. Against a wall: past it, along the wall
func _begin_circle() -> void:
	state = "circle"
	t = 0.0
	_walk = 0.0
	_hold = randf_range(2.0, 3.5)
	_route.clear()
	if _hide != null and is_instance_valid(_hide):
		var prop: Node3D = _hide.get("prop")
		var b: AABB = prop.get("bounds")
		var c := prop.global_position
		var f := _hide_out()
		var r := Vector3(-f.z, 0.0, f.x)
		var hd := b.size.x * 0.5 * prop.scale.x
		# either side (the one with more room first), as wide round it as the walls leave: kept off them by nav.resolve
		var sides: Array[float] = [1.0, -1.0]
		if randf() < 0.5: sides.reverse()
		for side: float in sides:
			for wide: float in [1.4, 1.0, 0.7]:
				var hw := b.size.z * 0.5 * prop.scale.x + wide
				var a := _floor_pt(nav.resolve(c + f * (hd + 1.0) + r * side * hw, RADIUS))
				var bk := _floor_pt(nav.resolve(c - f * (hd + 1.0) + r * side * hw, RADIUS))
				var p := global_position
				if not (nav.clear_line(p.x, p.z, a.x, a.z) and nav.clear_line(a.x, a.z, bk.x, bk.z)): continue
				if (bk - c).dot(f) > -hd * 0.5: continue                      # (the wall pushed it back round the front)
				_route = [a, bk]
				var behind := _floor_pt(nav.resolve(c - f * (hd + 1.8), RADIUS))
				if (behind - c).dot(f) < -hd and nav.clear_line(bk.x, bk.z, behind.x, behind.z): _route.append(behind)
				break
			if not _route.is_empty(): break
		if _route.is_empty():
			# its back is to a wall: it brushes past along the side of it and goes on along the wall
			for side: float in sides:
				var a := _floor_pt(nav.resolve(c + f * (hd + 0.9) + r * side * (b.size.z * 0.5 * prop.scale.x + 1.2), RADIUS))
				var on := _floor_pt(nav.resolve(a + r * side * 4.0, RADIUS))
				var p := global_position
				if nav.clear_line(p.x, p.z, a.x, a.z) and nav.clear_line(a.x, a.z, on.x, on.z) and a.distance_to(on) > 2.0:
					_route = [a, on]
					_hold = randf_range(1.0, 2.0)
					break
	if _route.is_empty(): _hold = 0.0                                 # (boxed in: nowhere round it to go)

func _floor_pt(v: Vector3) -> Vector3:
	return Vector3(v.x, global_position.y, v.z)

func _circle(delta: float) -> void:
	if _came_out(): return
	if _route.is_empty():
		_walk = move_toward(_walk, 0.0, delta * 2.0)
		rotation.y = yaw
		_hold -= delta
		if _hold <= 0.0:
			_begin_roam()
			_pause = randf_range(0.5, 1.5)
		return
	var to: Vector3 = _route[0]
	var p := global_position
	if Vector2(to.x - p.x, to.z - p.z).length() < 0.6:
		_route.remove_at(0)
		return
	_walk = move_toward(_walk, roam_speed, delta * 1.2)
	_move_toward(to, _walk, delta)
	rotation.y = yaw

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
		"stalk", "circle":
			if _walk > STALK_RUN:
				clip = "run"
				speed = maxf(0.5, _walk / RUN_CLIP_SPEED)
				fade = 0.3
			elif _walk > 0.1:
				clip = "walk"
				speed = _walk / WALK_CLIP_SPEED
				fade = 0.35
		"peer":
			clip = "peer"
			fade = 0.3
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
	_trauma = 0.0
	_hands_on = false
	_armed = [true, true]
	_gripped = false
	_head = Vector3.ZERO
	_head_v = Vector3.ZERO
	_turn = Vector3.ZERO
	_turn_v = Vector3.ZERO
	_blows = 0
	_pulls = 0
	Death.grab_begin()                  # last life's blood off the floor and the lens
	_pl.frozen = true
	player.velocity = Vector3.ZERO
	var cam: Camera3D = _pl.cam
	_from = cam.global_transform
	_from_fov = cam.fov
	Game.fx_reset()
	Game.fear = 1.0
	if _kill_light == null:
		_kill_light = OmniLight3D.new()
		_kill_light.light_color = Color(0.82, 0.88, 1.0)
		_kill_light.omni_range = 5.0
		_kill_light.shadow_enabled = false
		add_child(_kill_light)
	_kill_light.visible = true

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
	_hands(delta, eye, cam)
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
		var k2 := clampf((t - TEAR_AT) / (KILL_T - TEAR_AT), 0.0, 1.0)  # the tear: 0 at the start of it .. 1 at the end
		# wide while its hands are on you; closing in on its face as it comes down at the last
		fov = lerpf(_from_fov + 4.0, _from_fov - 16.0, smoothstep(LIDS_AT - 0.8, KILL_T, t))
		roll = 0.04 * sin(t * 3.0)
		shake = 0.003 + 0.006 * k2
		_tear(delta, pos, k2)
	# your head, knocked about by its hands (_hands): once you are down, an offset and a turn in the view's own axes
	var held := smoothstep(FALL_END - 0.2, FALL_END + 0.3, t) * kill_shake
	_trauma = maxf(0.0, _trauma - delta * 1.6)
	var tr := _trauma * _trauma * kill_shake
	var jit := Vector3(sin(Game.time * 37.0), sin(Game.time * 29.0 + 1.3), sin(Game.time * 23.0 + 2.1)) * (shake + 0.05 * tr) * kill_shake
	var b := Basis(q) * Basis.from_euler(Vector3(_turn.x * held, _turn.y * held,
		_turn.z * held + roll * kill_shake + 0.1 * tr * sin(Game.time * 41.0)))
	cam.global_transform = Transform3D(b, pos + Basis(q) * (_head * held) + jit)
	if _kill_light != null:                                   # it gutters: on the beat of every stroke, dying away at the end
		_kill_light.global_position = pos + b.y * 0.1
		var flick := 0.75 + 0.25 * sin(Game.time * 23.0) * sin(Game.time * 7.0 + 1.0)
		_kill_light.light_energy = maxf(0.0, (2.6 * flick + 1.4 * _trauma) * (1.0 - smoothstep(KILL_T - 1.0, KILL_T - 0.1, t)))
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
		scares.gasp(1.0)
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

## Sat on you, tearing. Its hands do the hurting (_hands reads them); this is the rest: the sounds on the clip's
## beats, and the picture going as you do
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
			scares.entity_call("tall_scream", _hand_pos("Head") + Vector3.UP * 0.3, true, 1.5, 1.0)
	)
	if t < TEAR_AT: return
	# your breath: caught as it studies you, at the pause, as its hands come for your face, and choking at the end
	for g: Array in [["gasp_study", 2.35, 0.8], ["gasp_look", LOOK_AT + 0.25, 0.9], ["gasp_grip", GRIP_AT - 0.4, 1.0], ["gasp_last", 8.3, 0.5]]:
		_once(g[0], t >= g[1], func():
			if scares != null: scares.gasp(g[2])
		)
	_once("ripped", t >= RIP_AT, _ripped.bind(cam_pos))
	_once("last_breath", t >= LAST_BREATH, func():
		if scares != null: scares.death_voice()
	)
	# The recording coming apart WITH you: the tape glitching (blocks, tracking tears, VHS colour bleed, dropouts, static)
	# while it is you going: your eyelids fight to stay open and fall; the world swims, doubles and sags with every blow;
	# the colour drains out of everything but the red, which creeps in from the edges; and at the last the lids close over
	# its face coming down
	var swim := 0.5 + 0.5 * sin(t * (1.3 + 1.7 * k))
	Game.fx_sat = 1.0 - 0.72 * k
	Game.fx_contrast = 1.0 + 0.28 * k
	Game.fx_blur = (0.2 + 1.2 * k) * (0.6 + 0.4 * swim) + 0.7 * _trauma
	Game.fx_warp = 0.003 + 0.012 * k * swim + 0.03 * _trauma * _trauma     # the room sags and wobbles
	Game.fx_zoom = 1.0 + 0.045 * _trauma + 0.03 * k * swim                 # each blow punches the picture in, then it sinks back
	Game.fx_skew = 2.5 * k * sin(t * 0.9)                                  # the world listing
	var lids := 0.05 + 0.18 * k * (0.5 + 0.5 * sin(t * (2.0 + 3.0 * k)))   # trying to stay awake: sagging, snapping open
	lids = maxf(lids, 0.28 * _trauma * _trauma)                            # a blow makes them flinch
	lids = lerpf(lids, 1.0, smoothstep(LIDS_AT, KILL_T - 0.15, t))         # and then they don't open again
	Game.fx_blink = clampf(lids, 0.0, 1.0)
	Game.fx_fade = smoothstep(LIDS_AT - 0.3, KILL_T, t)                    # the edges close in, last
	# the tape: Game.glitch drives the VHS damage (tracking band, line jitter, colour bleed, dropouts: render_engine.gd raises
	# `vhs` with it and Game.terror), fx_static the snow; fx_corrupt (the codec blocks) only flashes on a blow (_blow).
	# Kept under what its hands are doing: the tearing has to be seen
	Game.glitch = maxf(Game.glitch, 0.3 + 0.4 * k)
	Game.terror = maxf(Game.terror, 0.7 + 0.3 * k)
	Game.fx_static = 0.03 + 0.3 * k * k
	Game.fx_corrupt = maxf(0.0, Game.fx_corrupt - delta * 2.5)
	if randf() < delta * 1.5: Game.fx_hue = randf_range(-0.2, 0.2) * k
	_cue(delta, randf_range(0.7, 1.2), func():
		if scares != null:
			scares.spawn3d(scares.synth("wall_scratch", float(randi() % 3)), cam_pos + Vector3.UP * 0.1, 0.9, "Scares", 2.0, randf_range(0.5, 0.7), false)
			scares.heartbeat(1.0 - 0.5 * k, 1.0 - 0.45 * k)
	)

## Its hands, read off the clip every frame: how fast each moves, and how near your eyes. A hand moving at your face
## drags your head along with it and turns it (two springs, a little loose so they overshoot). One closing on your face
## fast is a blow (_blow); both holding your face, then one jerking away, is a rip (_pull); one coming down beside your
## head is a slam on the floor (_slam). Nothing here is timed: it follows whatever the clip's hands do
func _hands(delta: float, eye: Transform3D, cam: Camera3D) -> void:
	if delta <= 0.0 or skel == null: return
	var inv := eye.basis.inverse()
	var force := Vector3.ZERO
	var torque := Vector3.ZERO
	var holding := 0
	var wrench := Vector3.ZERO
	for i in 2:
		var p := _hand_pos(HANDS[i])
		if not _hands_on: _hand_prev[i] = p
		_hand_v[i] = (_hand_v[i] as Vector3).lerp((p - _hand_prev[i]) / delta, 0.6)
		_hand_prev[i] = p
		if t < FALL_END: continue
		var rel := inv * (p - eye.origin)                       # the view's axes: x right, y up the screen, -z out of your eyes
		var lv: Vector3 = inv * (_hand_v[i] as Vector3)
		var d := rel.length()
		var near := clampf(1.0 - (d - 0.3) / 0.7, 0.0, 1.0)
		near *= near
		force += lv * near * hand_push
		torque += rel.normalized().cross(lv) * near * hand_twist
		var speed := lv.length()
		var closing := -lv.dot(rel / maxf(d, 0.001))
		if _armed[i] and d < BLOW_NEAR and closing > BLOW_CLOSING:
			_armed[i] = false
			var s := clampf(closing / 12.0, 0.35, 1.0)
			if p.y - eye.origin.y > FACE_ABOVE: _blow(p, lv, s, eye, cam)
			else: _slam(p, s)
		elif d > 0.8 or speed < 0.8:
			_armed[i] = true
		var on_face := d < 0.7 and p.y - eye.origin.y > FACE_ABOVE    # (not a hand braced on the floor beside you)
		if on_face and speed < 1.0: holding += 1
		if on_face and -closing > 1.4 and lv.length() > wrench.length(): wrench = lv
	_hands_on = true
	if holding == 2:
		_gripped = true
	elif _gripped and wrench != Vector3.ZERO:
		_gripped = false
		_pull(wrench, eye, cam)
	_head_v += (force - _head * 140.0 - _head_v * 15.0) * delta
	_head += _head_v * delta
	_head = _head.clamp(Vector3(-0.12, -0.12, -0.05), Vector3(0.12, 0.12, 0.03))   # (+z is the floor behind your head)
	_turn_v += (torque - _turn * 110.0 - _turn_v * 13.0) * delta
	_turn += _turn_v * delta
	_turn = _turn.clamp(Vector3(-0.35, -0.45, -0.5), Vector3(0.35, 0.45, 0.5))

## Claws across your face (`lv`: the hand's velocity in the view's axes, `s` 0..1 how hard). The head is knocked the
## way they were going (turned with them, rolled, pressed into the floor), the tape tears, blood goes up off your face
## and onto the lens where they came down
func _blow(at: Vector3, lv: Vector3, s: float, eye: Transform3D, cam: Camera3D) -> void:
	_blows += 1
	var flat := Vector2(lv.x, lv.y)
	var dir := flat.normalized() if flat.length() > 0.01 else Vector2(randf_range(-1.0, 1.0), -1.0).normalized()
	_head_v += Vector3(dir.x * 0.9, dir.y * 0.9, 0.8) * s * blow_kick
	_turn_v += Vector3(dir.y * 2.5, -dir.x * 3.5, -dir.x * 4.0) * s * blow_kick
	_trauma = minf(1.0, _trauma + 0.45 * s)
	Game.glitch = 1.0                                         # the tape tears on every blow
	Game.fx_corrupt = maxf(Game.fx_corrupt, 0.1 + 0.15 * s)
	Game.fx_shock = maxf(Game.fx_shock, 0.35 + 0.2 * s)
	Game.fx_flash = maxf(Game.fx_flash, 0.2)
	_pl.jolt(0.6 + 0.5 * s)
	var face := eye.origin + Vector3.UP * 0.05
	Death.face_tear(face, global_position.y, eye.basis * Vector3(lv.x, lv.y, 0.0), s)
	if scares != null:
		scares.spawn3d(scares.synth("splat"), face, 1.0, "Scares", 2.0, randf_range(0.7, 1.0), false)
		if randf() < 0.3 + 0.5 * s:
			scares.spawn3d(scares.synth("bone_crack"), face, 0.5 + 0.3 * s, "Scares", 2.0, randf_range(0.6, 0.9), false)

## A hand that had hold of your face wrenches away: your head is yanked with it, and something gives
func _pull(lv: Vector3, eye: Transform3D, cam: Camera3D) -> void:
	_pulls += 1
	var flat := Vector2(lv.x, lv.y)
	var dir := flat.normalized() if flat.length() > 0.01 else Vector2(0.0, 1.0)
	_turn_v += Vector3(dir.y * 1.5, -dir.x * 2.0, -dir.x * 2.5) * blow_kick
	_trauma = minf(1.0, _trauma + 0.35)
	Game.glitch = 1.0
	Game.fx_shock = maxf(Game.fx_shock, 0.4)
	_pl.jolt(0.7)
	var face := eye.origin + Vector3.UP * 0.05
	Death.face_tear(face, global_position.y, eye.basis * Vector3(lv.x, lv.y, 0.0), 0.6)
	if scares != null:
		if not _sounded.has("blood_scream"):
			_sounded["blood_scream"] = true
			scares.splat()                                    # your scream, once, through blood (scares.gd BLOOD_SCREAM)
		scares.spawn3d(scares.synth("splat"), face, 1.1, "Scares", 2.0, randf_range(0.55, 0.7), false)
		scares.spawn3d(scares.synth("bone_crack"), face, 0.8, "Scares", 2.0, randf_range(0.5, 0.65), false)

## A hand slammed down on the floor beside your head: the thud goes through the floor into your skull
func _slam(at: Vector3, s: float) -> void:
	_head_v += Vector3(0.0, 0.0, 0.6 * s) * blow_kick
	_trauma = minf(1.0, _trauma + 0.3 * s)
	_pl.jolt(0.8 * s)
	if scares != null:
		scares.spawn3d(scares.synth("thump"), at, 0.9 * s + 0.3, "Scares", 4.0, randf_range(0.55, 0.7), false)

## The rip tears free: both arms fly up out of your face, and it screams; the blood under your head starts to spread
func _ripped(cam_pos: Vector3) -> void:
	_trauma = 1.0
	Game.fx_flash = maxf(Game.fx_flash, 0.4)
	Death.face_pool(Vector3(cam_pos.x, global_position.y, cam_pos.z))
	if scares != null:
		scares.set_entity_occlusion(false)
		scares.entity_call("tall_scream", _hand_pos("Head") + Vector3.UP * 0.2, true, 1.6, 1.0)

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
	Death.lying(global_position, _kill_dir)       # you die where it left you: on your back, chest at its root, head beyond
	Game.kill_player("THE TALL ONE", Game.DeathType.RIPPED)
	_despawn_quietly()

# ---------------------------------------------------------------- T.S.R.A. scanner
# Hold Q on it with the field scanner (scripts/Player/scanner.gd) to log it in the Threshold Dossier.
func _enter_tree() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("tsra_id", "tallone")

## Where the scanner can take a reading off it right now: its chest and its head; empty while it is away
func scan_points() -> Array:
	if not present or body == null or not visible:
		return []
	var h := height * size
	return [global_position + Vector3.UP * h * 0.6, global_position + Vector3.UP * h * 0.9]

## C-4 deep scan (scan_readout.gd)
func scan_behavior(_at: Vector3) -> Dictionary:
	match state:
		"spot", "flee":
			return {"state": "SPOOKED", "detail": "BREAKING OFF // RUNNING FROM THE SUBJECT", "danger": 1}
		"scream", "hunt", "kill":
			return {"state": "HUNTING", "detail": "SCREAM ISSUED // CLOSING FASTER THAN A SPRINT", "danger": 2}
		"stalk", "peer", "circle":
			return {"state": "STALKING", "detail": "AT THE HIDING PLACE // WAITING FOR THE DOOR", "danger": 2}
	return {"state": "ROAMING", "detail": "WANDERING // STOPS TO COCK ITS HEAD", "danger": 1}

func _despawn_quietly() -> void:
	if _kill_light != null: _kill_light.visible = false
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
		Death.grab_begin()                    # (the blood on the floor and the lens)
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
