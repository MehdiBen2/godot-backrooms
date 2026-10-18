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
## Stalking, it also hides at the corners of the walls: it goes to stand behind one, curls a hand round its edge
## and leans its head out, laid over on its side, to watch you (peek).
## Its clips are baked in theburnt_animated.glb (tools/blender/animate_burnt.py): idle, walk, run, crouch, skid,
## heave, windup, peek_r/peek_l (+ _hold) and kill. They are played here, by hand (_animate), and only its head
## (turned on to you, the twitch) and the hug's arms are posed on top of them. `spawn burnt` in the debug console
## stands it in front of you.

const EntityMarks := preload("res://scripts/Entities/entity_marks.gd")
const LURK_WAKE := 14.0             # metres: a Burnt placed to lurk starts to stalk when you come this close
const BurntError := preload("res://scripts/Entities/burnt/burnt_error.gd")
const BurntNet := preload("res://scripts/Entities/burnt/burnt_net.gd")
const STATES := ["off", "stalk", "windup", "charge", "held", "grab", "lift", "stare", "corrupt", "hug", "peek", "withdraw"]
const PEEK_PHASES := ["", "go", "set", "in", "hold", "out"]
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
const HUG_HEAD_BACK := 0.45         # metres the middle of its skull is kept behind your eyes in the hug (_hug_place)
const FADE_IN := 0.9                # back out of the black, facing it
const WINDUP_TIME := 0.45           # seconds it coils before it takes you: the tell (you can still back off)
const GRAB_TIME := 0.7
const LIFT_TIME := 6.0
const STARE_TIME := 3.4
const CORRUPT_TIME := 2.4

# its clips (tools/blender/animate_burnt.py): how fast each one's feet go by at speed 1, in the model's own units
# (times body.scale for metres), and where in each a foot comes down
const WALK_CLIP_SPEED := 0.2855
const RUN_CLIP_SPEED := 1.9
const WALK_FALLS := [0.0, 1.378]
const RUN_FALLS := [0.0, 0.433]
const LOOPED := ["idle", "walk", "run", "heave", "peek_r_hold", "peek_l_hold"]
const FREEZE_HOLD := 1.2            # seconds caught mid-stride, held there, before it settles into its stance
const KILL_AT := {"grab": 0.0, "lift": 0.7, "stare": 6.7, "corrupt": 10.1}   # where each beat starts in the kill clip
const KILL_EYE := 0.06              # model units from its grip (the wrists) up to your eyes, held in it

# the peek: the corner of a wall block, its hand round the edge, its head out past it
const PEEK_EDGE := Vector2(0.16, 0.15)  # model units: the edge it grips, off its midline / ahead of it (the wall's face)
const PEEK_HEAD := Vector2(0.075, 0.065) # ...and where its head comes out: past the edge / short of the face
const PEEK_MIN := 7.0               # metres from you it will hide and watch from
const PEEK_MAX := 26.0
const PEEK_IN := 1.6                # the peek_r / peek_l clips
const PEEK_OUT := 1.3               # (the same, backwards and a little faster)
const PEEK_LOST := 2.0              # seconds you are out of its sight before it lets go of the edge
const PEEK_COOLDOWN := 14.0
const RETREAT_WATCH := 1.2          # seconds stared at before it may walk off to hide (the smart move: not stand and be watched)
const FLANK_TIME := 25.0            # seconds it keeps working round behind you after it has hidden
const FLANK_BEHIND := 5.0           # metres behind you it aims for
const FLANK_NEAR := 6.0             # ...and the nearest it goes round before it comes straight at you
const CAUGHT_HOLD := 0.5            # seconds caught hanging off its corner, dead still, before it whips back behind the wall
const CAUGHT_BACK := 2.4            # ...that many times faster than it lets go of the edge on its own
const HIDE_MIN := 12.0              # metres from you it goes to hide, out of your sight (withdraw)
const HIDE_MAX := 32.0
const HIDE_STEPS := 9               # cells it will walk, at most, to get there
const HIDE_WAIT := Vector2(5.0, 11.0)       # seconds it stays hidden before it comes back
const WITHDRAW_PACE := 1.25         # walking off: a little quicker than its stalk (it never runs from you)
const CREEP_PACE := 0.55            # coming back: slower than its stalk
const CREEP_TIME := 14.0
const KEEP_DIST := 11.0             # metres: until it commits it shadows you from about here, and comes no nearer
const COMMIT_AFTER := Vector2(70.0, 130.0)  # seconds of hunting before it stops shadowing you and closes in
const SHADOW_SHIFT := Vector2(7.0, 14.0)    # seconds stood shadowing before it slips off to come at you from elsewhere
const SFX_LOUD := 0.2               # every sound it makes is matched to this loudness before its own level (_sfx)
const BREATH := "res://audio/entity/burnt/breath_"   # its breaths: recordings, baked at SFX_LOUD (audio/CREDITS.txt)

@export var charge_watch := 4.0     # seconds of being stared at, from afar, before it stops waiting and runs at you
@export var charge_min := 9.0       # metres: nearer than this it simply stalks
@export var charge_max := 42.0
@export var charge_speed := 11.0    # m/s at a full run: faster than you can sprint, until the adrenaline kicks in
@export var charge_cooldown := 25.0 # seconds before it will charge again

const CHARGE_PREP := 0.9            # seconds it drops into a crouch and breathes in before it goes
const CHARGE_RUN := 6.0             # seconds it will run before it gives up
const BRAKE_STOP := 3.0             # metres it skids over, from a full run to a standstill
const STOP_GAP := 1.6               # metres beyond its reach that it stops: room to turn, break its line and hide
const BRAKE_HOLD := 2.2             # seconds it stands there, heaving, before it goes back to stalking

var _mark_pending := false          # the level has a Burnt mark it has yet to stand at
var _lod_go := false                 # EntityLOD has said its mark may be stood at (lod_spawn)
var _lurk := false                  # placed to lurk: it waits where it stands until you are close
var state := "off"                  # off, stalk, windup, charge, grab, lift, stare, corrupt (+ held: co-op, a guest is being taken)
var t := 0.0
var yaw := 0.0
var _walk := 0.0                    # 0..1 how much it is walking (eased)
var _watch_t := 0.0                 # how long it has been stared at, from afar (decays when you look away)
var _charge_cd := 0.0
var _sp := 0.0                      # 0..1 its speed as a fraction of a full run (what the run clip's speed follows)
var _braking := false               # the charge has seen you in front of it and is skidding to a halt short of you
var _brake_t := 0.0                 # seconds spent standing at the end of the skid
var _rush := 0.0                    # 0..1 the high the player is on while it runs at them (and for a while after)
var _rush_sat := 0.0                # what the rush has added to Game.fx_sat / fx_contrast, to take back out again
var _rush_con := 0.0
var _head_yaw := 0.0                # radians the head is turned off the body to keep its eyes on you
var _hitch_t := 0.0                 # a dropped-frame stutter in the walk or the run: clip and feet hold for a beat
var _hitch_next := 0.6
var _is_seen := false               # someone has their eyes on it (this physics frame): a peek holds still
var _peek_side := 1                 # the edge it holds: +1 on its right (peek_r), -1 on its left (peek_l)
var _peek_phase := ""               # go (to the spot), set (turned to the wall), in, hold, out (back behind it)
var _peek_t := 0.0
var _peek_at := Vector3.ZERO        # where it stands behind the wall
var _peek_yaw := 0.0                # facing the wall
var _peek_head := Vector3.ZERO      # where its head comes out past the edge (what it sees you from)
var _peek_hold := 4.0               # seconds it hangs there watching
var _peek_lost := 0.0               # seconds you have been out of its sight from the edge
var _peek_cd := 4.0
var _peek_scan := 0.0
var _retreat := false               # the peek began because it was stared at: it walks off in plain sight, not only unseen
var _flank_t := 0.0                 # after hiding, seconds left that it circles round to come at you from behind
var _caught_t := 0.0                # seconds it has been seen hanging off the edge
var _caught := false                # caught peeking: it whips back behind the wall, then withdraws
var _hide_at := Vector3.ZERO        # withdraw: where it goes to be out of your sight
var _hide_wait := 0.0               # ...and how long it stays there
var _reach := PackedInt32Array()    # (steps from where it stands to every cell, for finding _hide_at)
var _pace := 1.0                    # its walk as a fraction of STALK_SPEED (the walk clip follows it)
var _creep_t := 0.0                 # back from hiding: seconds left it comes on at CREEP_PACE
var _hunt_t := 0.0                  # seconds it has hunted since it came
var _commit_at := 90.0              # ...when it stops shadowing you and closes in
var _shadow_t := 0.0                # seconds stood shadowing you at KEEP_DIST
var _shadow_for := 10.0
static var _loud := {}              # "name:arg" -> a sound's loudness (_match)
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

# its skeleton and its clips
var skel: Skeleton3D
var _ap: AnimationPlayer            # advanced by hand in _animate (its head is posed on top, after)
var _clip := ""                     # what _animate last started (a peek played backwards ends in "<")
var _still_t := 0.0                 # seconds it has stood still, stalking
var _clip_pos := 0.0                # the clip's time last frame (a foot comes down as it passes a footfall)
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
	var marks := EntityMarks.of_kind(level, "burnt")
	_mark_pending = not marks.is_empty()
	# placed with a mark: EntityLOD stands it there when you come within MARK_SPAWN_DIST of it, or after MARK_ARRIVE_AFTER s
	# (it stalks you from wherever it is, slowly: it does not need to start close)
	EntityLOD.register(self, {} if marks.is_empty() else {"mark": EntityMarks.world_pos(marks[0]), "spawn_dist": MARK_SPAWN_DIST, "arrive_after": MARK_ARRIVE_AFTER})

const MARK_SPAWN_DIST := 60.0
const MARK_ARRIVE_AFTER := 240.0

func lod_spawned() -> bool:
	return present or _lod_go

func lod_engaged() -> bool:
	return state != "stalk" and state != "off"

func lod_spawn(_at_mark: bool) -> void:
	_lod_go = true                       # (_physics_process stands it on its mark now)

## A Burnt mark in the level editor: it stands there from the start of the level. Placed to roam it stalks you
## at once; placed to lurk it stays put, motionless, until you come within LURK_WAKE of it.
func _spawn_from_mark() -> void:
	var marks := EntityMarks.of_kind(level, "burnt")
	if marks.is_empty() or not spawn_at(EntityMarks.world_pos(marks[0])):
		return
	yaw = rotation.y
	state = "stalk"
	_walk = 0.0
	_lamp_t = 0.0
	_lurk = EntityMarks.lurks(marks[0])
	_fresh_hunt()

## Come anew: it shadows you for a long while before it closes in
func _fresh_hunt() -> void:
	_hunt_t = 0.0
	_commit_at = randf_range(COMMIT_AFTER.x, COMMIT_AFTER.y)
	_creep_t = 0.0
	_shadow_t = 0.0
	_shadow_for = randf_range(SHADOW_SHIFT.x, SHADOW_SHIFT.y)
	_caught = false
	_caught_t = 0.0
	_pace = 1.0

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
	var aps := body.find_children("*", "AnimationPlayer", true, false)
	_ap = aps[0] as AnimationPlayer if not aps.is_empty() else null
	if _ap != null:
		_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for a in LOOPED:
			if _ap.has_animation(a): _ap.get_animation(a).loop_mode = Animation.LOOP_LINEAR
	else:
		push_warning("Burnt: %s has no clips (theburnt_animated.glb?): it will stand at rest" % model)
	# A skinned mesh is culled by its rest-pose box: arms posed reaching round the camera, metres in front of a body
	# standing behind it, would be culled away. A wide margin keeps them drawn (one entity: it costs nothing).
	for mi: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
		mi.extra_cull_margin = 8.0
	return true

# ---------------------------------------------------------------- stalking
func _physics_process(delta: float) -> void:
	var _pt := Time.get_ticks_usec()
	_physics_process_timed(delta)
	Perf.add("Burnt", _pt)

func _physics_process_timed(delta: float) -> void:
	puppet = Net.is_online() and not Net.hosting
	if puppet:
		_physics_puppet(delta)
		return
	_rush_fx(delta)
	if Net.is_online(): net.send(delta)
	if _mark_pending and Game.playing and not Game.dead and player != null and EntityLOD.is_spawned(self):
		_mark_pending = false
		_spawn_from_mark()
	if not present or player == null: return
	_burn_lamps(delta)
	if Game.freeze_ai: return
	if state == "held":                  # a guest is being taken: their machine plays it out
		_held_t += delta
		if _held_t > HELD_MAX: _despawn_quietly()
		return
	_charge_cd = maxf(0.0, _charge_cd - delta)
	_peek_cd = maxf(0.0, _peek_cd - delta)
	_is_seen = false
	if state == "windup":
		_windup(delta)
		return
	if state == "charge":
		_charge(delta)
		return
	if state in ["stalk", "peek", "withdraw"]: _hunt_t += delta
	if state == "peek":
		_peek(delta)
		return
	if state == "withdraw":
		_withdraw(delta)
		return
	if state != "stalk": return
	var tgt := _target()
	if tgt.is_empty(): return
	var pp: Vector3 = tgt.pos
	var p := global_position
	var d := Vector2(pp.x - p.x, pp.z - p.z).length()
	if _lurk:
		if d > LURK_WAKE: return
		_lurk = false
	if d < GRAB_DIST and _can_take(tgt):
		state = "windup"
		t = 0.0
		return
	_is_seen = _seen()
	if _is_seen:
		_walk = move_toward(_walk, 0.0, delta * 8.0)      # caught moving: it stops dead
		# ...but hold its eye long enough, from far enough off, and it stops waiting: it runs
		_watch_t += delta
		# ...or, smarter, it gives up being watched: walks off to a wall corner, hides, and comes round behind you
		_peek_scan -= delta
		if _watch_t >= RETREAT_WATCH and _peek_cd <= 0.0 and _peek_scan <= 0.0 and d >= PEEK_MIN and d <= PEEK_MAX:
			_peek_scan = 0.5
			if randf() < 0.6 and _find_peek(pp):
				_begin_peek(true)
				return
		if _watch_t >= charge_watch and _charge_cd <= 0.0 and d >= charge_min and d <= charge_max and _can_take(tgt):
			_begin_charge()
			return
	else:
		_watch_t = maxf(0.0, _watch_t - delta * 0.6)
		# out of your sight, near enough, a wall corner to hand: it goes and hides behind it, and watches
		_peek_scan -= delta
		if _peek_cd <= 0.0 and _peek_scan <= 0.0 and d >= PEEK_MIN and d <= PEEK_MAX:
			_peek_scan = 0.5
			if not nav.clear_line(p.x, p.z, pp.x, pp.z) and _find_peek(pp):
				_begin_peek()
				return
		_creep_t = maxf(0.0, _creep_t - delta)
		_pace = CREEP_PACE if _creep_t > 0.0 else 1.0
		if _hunt_t < _commit_at and d < KEEP_DIST:
			# not yet: it shadows you from the dark, no nearer, turned on you. Come at it, or let it stand long enough,
			# and it slips away out of your sight, to come at you again from somewhere else
			_shadow_t += delta
			if (d < KEEP_DIST * 0.6 or _shadow_t > _shadow_for) and _begin_withdraw(pp):
				return
			_walk = move_toward(_walk, 0.0, delta * 3.0)
			yaw = lerp_angle(yaw, _yaw_to(pp), minf(1.0, delta * 1.5))
			rotation.y = yaw
			return
		_walk = move_toward(_walk, 1.0, delta * 2.5)
		var goal := pp
		if _flank_t > 0.0:                                    # working round behind you
			_flank_t -= delta
			if d > FLANK_NEAR: goal = _flank_point(tgt)
			else: _flank_t = 0.0
		_move_toward(goal, STALK_SPEED * _pace * _walk * (0.0 if _hitch_t > 0.0 else 1.0), delta)
	rotation.y = yaw

# ---------------------------------------------------------------- the peek
## A corner to hide behind and watch you from, near it: the end of a wall block's face, with you beyond that face.
## It stands behind the face, square to it, the edge just off its shoulder, where you can't see it; leaning out, its
## head comes past the edge to where it can. The nearest that works. Sets _peek_at / _peek_yaw / _peek_side / _peek_head.
func _find_peek(pp: Vector3) -> bool:
	if body == null: return false
	var k := body.scale.x
	var p := global_position
	var cx := GridNav.cell(p.x)
	var cz := GridNav.cell(p.z)
	var h := CELL * 0.5
	var best := INF
	for ox in range(-3, 4):
		for oz in range(-3, 4):
			var w := Vector2i(cx + ox, cz + oz)
			if not nav.is_wall(w.x, w.y): continue
			for n: Vector2i in GridNav.NEIGHBOURS:              # the face it would stand before (n: out of the block)
				if nav.blocked(w.x + n.x, w.y + n.y): continue   # buried
				for e: Vector2i in [Vector2i(n.y, -n.x), Vector2i(-n.y, n.x)]:   # ...and the end of that face it holds
					if nav.blocked(w.x + e.x, w.y + e.y) or nav.blocked(w.x + e.x + n.x, w.y + e.y + n.y):
						continue                                   # the wall goes on (no edge there), or an inside corner
					var n3 := Vector3(n.x, 0.0, n.y)
					var e3 := Vector3(e.x, 0.0, e.y)
					var fwd := -n3
					var corner := Vector3(w.x * CELL, p.y, w.y * CELL) + (n3 + e3) * h
					var at := corner - e3 * PEEK_EDGE.x * k - fwd * PEEK_EDGE.y * k
					var head := corner + e3 * PEEK_HEAD.x * k + n3 * PEEK_HEAD.y * k
					var dsq := at.distance_squared_to(p)
					if dsq >= best or dsq > 225.0: continue
					if (pp - corner).dot(fwd) < 1.0: continue    # you are on its side of the wall, not beyond it
					if not nav.open_at(at.x, at.z) or nav.resolve(at, RADIUS).distance_to(at) > 0.05: continue
					if nav.clear_line(at.x, at.z, pp.x, pp.z): continue           # it would be stood in plain sight
					if not nav.clear_line(head.x, head.z, pp.x, pp.z): continue   # and could not see you from the edge
					if not nav.clear_line(p.x, p.z, at.x, at.z): continue         # (it walks there straight)
					best = dsq
					_peek_at = at
					_peek_yaw = atan2(fwd.x, fwd.z)
					_peek_head = head
					_peek_side = 1 if fwd.cross(Vector3.UP).dot(e3) > 0.0 else -1
	return best < INF

## A point behind the survivor (the way they face), where it comes at them from: the unseen side
func _flank_point(tgt: Dictionary) -> Vector3:
	var pp: Vector3 = tgt.pos
	var look: Vector3 = tgt.get("fwd", Vector3.FORWARD)
	if tgt.local: look = -(_pl.cam as Camera3D).global_transform.basis.z
	look = Vector3(look.x, 0.0, look.z).normalized()
	for r in [FLANK_BEHIND, FLANK_BEHIND * 0.5]:
		var c: Vector3 = pp - look * r
		if nav.open_at(c.x, c.z): return c
	return pp

func _begin_peek(retreat := false) -> void:
	state = "peek"
	_retreat = retreat
	_peek_phase = "go"
	_peek_t = 0.0
	_peek_lost = 0.0
	_peek_hold = randf_range(3.5, 7.0)
	_caught = false
	_caught_t = 0.0
	_pace = 1.0

func _end_peek() -> void:
	state = "stalk"
	_peek_phase = ""
	_peek_cd = PEEK_COOLDOWN * randf_range(0.8, 1.5)
	_walk = 0.0
	if _retreat or randf() < 0.5: _flank_t = FLANK_TIME     # hid: now it comes round behind you
	_retreat = false
	_caught = false
	_caught_t = 0.0

## Goes to the spot, turns square to the wall, reaches round the edge and leans out (in), hangs there watching you
## (hold), and pulls back behind the wall (out) once it has watched long enough, or you have gone from its sight.
## Caught at it, it holds dead still a beat, then whips back behind the wall and withdraws out of your sight
## (_withdraw): it never runs at you from a corner.
func _peek(delta: float) -> void:
	_peek_t += delta
	var tgt := _target()
	if tgt.is_empty():
		_end_peek()
		return
	var pp: Vector3 = tgt.pos
	var d := Vector2(pp.x - global_position.x, pp.z - global_position.z).length()
	if d < GRAB_DIST and _can_take(tgt):
		_peek_phase = ""
		state = "windup"
		t = 0.0
		return
	_is_seen = _seen()
	if _is_seen:
		_watch_t += delta
		if _peeking() and not _caught:
			_caught_t += delta
			if _caught_t >= CAUGHT_HOLD:                  # it has seen you see it
				_caught = true
				_peek_phase = "out"
				_peek_t = 0.0
				if scares != null:                         # the scrape of it snatching back round the edge
					_sfx("creak", _peek_head + Vector3.UP * 3.0, 0.5, 4.0, randf_range(1.15, 1.35))
	else:
		_watch_t = maxf(0.0, _watch_t - delta * 0.6)
		_caught_t = 0.0
	match _peek_phase:
		"go":
			if _is_seen and not _retreat:
				_walk = move_toward(_walk, 0.0, delta * 8.0)
				_end_peek()                                    # seen getting there: the hiding place is no good
				return
			_walk = move_toward(_walk, 1.0, delta * 2.5)
			_move_toward(_peek_at, STALK_SPEED * _walk * (0.0 if _hitch_t > 0.0 else 1.0), delta)
			if Vector2(_peek_at.x - global_position.x, _peek_at.z - global_position.z).length() < 0.35:
				_peek_phase = "set"
				_peek_t = 0.0
			elif _peek_t > 10.0:
				_end_peek()
		"set":
			_walk = move_toward(_walk, 0.0, delta * 4.0)
			if _is_seen: return
			global_position = global_position.lerp(Vector3(_peek_at.x, global_position.y, _peek_at.z), 1.0 - exp(-8.0 * delta))
			yaw = lerp_angle(yaw, _peek_yaw, 1.0 - exp(-6.0 * delta))
			if _peek_t > 0.7:
				global_position = Vector3(_peek_at.x, global_position.y, _peek_at.z)
				yaw = _peek_yaw
				_peek_phase = "in"
				_peek_t = 0.0
				if scares != null:                         # its nails finding the edge
					_sfx("creak", _peek_head + Vector3.UP * 3.0, 0.35, 3.0, randf_range(0.8, 0.95))
		"in":
			if _is_seen: _peek_t -= delta
			elif _peek_t >= PEEK_IN:
				_peek_phase = "hold"
				_peek_t = 0.0
		"hold":
			_peek_lost = 0.0 if nav.clear_line(_peek_head.x, _peek_head.z, pp.x, pp.z) else _peek_lost + delta
			if not _is_seen and (_peek_t > _peek_hold or _peek_lost > PEEK_LOST):
				_peek_phase = "out"
				_peek_t = 0.0
		"out":
			if _caught:
				if _peek_t >= PEEK_OUT / CAUGHT_BACK:
					_end_peek()
					_begin_withdraw(pp)
			elif _is_seen: _peek_t -= delta
			elif _peek_t >= PEEK_OUT: _end_peek()
	rotation.y = yaw

## Off out of your sight: somewhere HIDE_MIN-HIDE_MAX from you that you can't see, further from you than it is now if
## it can, the fewest steps away it can walk to (HIDE_STEPS at most). In the open, with nowhere you can't see, it
## backs off into the dark as far from you as it can walk (its lamps die round it). False if it can't get further off.
func _begin_withdraw(pp: Vector3) -> bool:
	var p := global_position
	var n: int = nav.n
	var cx := GridNav.cell(p.x)
	var cz := GridNav.cell(p.z)
	if not nav.bfs(cx, cz, _reach): return false
	var now := Vector2(pp.x - p.x, pp.z - p.z).length()
	var best := HIDE_STEPS + 1
	var best_any := HIDE_STEPS + 1
	var any := Vector3.ZERO
	var far := now + 4.0
	var far_at := Vector3.INF
	for ox in range(-HIDE_STEPS, HIDE_STEPS + 1):
		for oz in range(-HIDE_STEPS, HIDE_STEPS + 1):
			var x := cx + ox
			var z := cz + oz
			if x < 0 or z < 0 or x >= n or z >= n: continue
			var steps := _reach[x * n + z]
			if steps < 1 or (steps >= best_any and steps >= best): continue
			var c := Vector3(x * CELL, p.y, z * CELL)
			var dp := Vector2(c.x - pp.x, c.z - pp.z).length()
			if dp > far and dp <= HIDE_MAX:
				far = dp
				far_at = c
			if dp < HIDE_MIN or dp > HIDE_MAX or nav.clear_line(c.x, c.z, pp.x, pp.z): continue
			if dp > now and steps < best:
				best = steps
				_hide_at = c
			if steps < best_any:
				best_any = steps
				any = c
	if best > HIDE_STEPS:
		if best_any <= HIDE_STEPS: _hide_at = any
		elif far_at != Vector3.INF: _hide_at = far_at
		else: return false
	state = "withdraw"
	_peek_phase = ""
	t = 0.0
	_watch_t = 0.0
	_shadow_t = 0.0
	_caught = false
	_caught_t = 0.0
	_pace = WITHDRAW_PACE
	_hide_wait = randf_range(HIDE_WAIT.x, HIDE_WAIT.y)
	return true

## Walks off to _hide_at, seen or not, its head still turned back on you; waits there, still, out of your sight;
## then comes back for you slowly (CREEP_PACE), working round behind you, ready to peek again from a new corner.
func _withdraw(delta: float) -> void:
	t += delta
	var tgt := _target()
	if tgt.is_empty():
		state = "stalk"
		return
	var pp: Vector3 = tgt.pos
	var p := global_position
	if Vector2(pp.x - p.x, pp.z - p.z).length() < GRAB_DIST and _can_take(tgt):   # you ran it down
		state = "windup"
		t = 0.0
		return
	_is_seen = _seen()
	if Vector2(_hide_at.x - p.x, _hide_at.z - p.z).length() > 0.5 and t < 20.0:
		_pace = WITHDRAW_PACE
		_walk = move_toward(_walk, 1.0, delta * 2.5)
		_move_toward(_hide_at, STALK_SPEED * _pace * _walk * (0.0 if _hitch_t > 0.0 else 1.0), delta)
	else:
		_walk = move_toward(_walk, 0.0, delta * 3.0)
		if not _is_seen: _hide_wait -= delta
		if _hide_wait <= 0.0:
			state = "stalk"
			_creep_t = CREEP_TIME
			_flank_t = FLANK_TIME
			_peek_cd = randf_range(5.0, 9.0)
			_shadow_t = 0.0
			_shadow_for = randf_range(SHADOW_SHIFT.x, SHADOW_SHIFT.y)
			if scares != null:                             # somewhere out there, it has started back
				_sfx("creak", p + Vector3.UP * 2.0, 0.3, 8.0, randf_range(0.55, 0.7))
	rotation.y = yaw

## Hanging off a corner, what shows is its face: that is what you see it by, not its middle (behind the wall)
func _peeking() -> bool:
	return state == "peek" and (_peek_phase == "in" or _peek_phase == "hold" or _peek_phase == "out")

## It has been looked at too long. It drops into a crouch, turns to you and breathes in (the tell), then runs.
func _begin_charge() -> void:
	state = "charge"
	t = 0.0
	_cue_t = 0.0
	_sounded = {}
	_watch_t = 0.0
	_charge_cd = charge_cooldown
	_tw_next = 0.0
	_sp = 0.0
	_braking = false
	_brake_t = 0.0
	if scares != null:
		_sfx(BREATH + "charge.wav", _face(), 0.9, 8.0, randf_range(0.95, 1.03))

## The run: nothing like its walk. Very fast, lurching and uneven (_process), straight at you, every tube round it
## dying as it comes. It never catches you on its own: as it closes it throws itself into a skid and stops short of
## its reach (the near miss, and the room to turn a corner and hide), stands heaving, then goes back to stalking.
## Only a player who runs at it, or is walked into, ends in the grab.
func _charge(delta: float) -> void:
	t += delta
	var tgt := _target()
	if tgt.is_empty() or not _can_take(tgt):
		_end_charge()
		return
	var pp: Vector3 = tgt.pos
	var d := Vector2(pp.x - global_position.x, pp.z - global_position.z).length()
	if t < CHARGE_PREP:
		_walk = move_toward(_walk, 0.0, delta * 8.0)
		yaw = lerp_angle(yaw, _yaw_to(pp), minf(1.0, delta * TURN_RATE * 2.0))
		rotation.y = yaw
		return
	# the start of the run: air drawn in sharply
	_once("go", true, func(): _sfx("stinger", global_position + Vector3.UP * 2.0, 0.6, 8.0, 0.7))
	if d < GRAB_DIST:
		_start_grab(tgt)
		return
	if tgt.local: _pl.update_adrenaline(delta, d < _pl.ADR_RANGE)     # the player's own rush, as in the Bacteria's chase
	Game.fear = maxf(Game.fear, 0.85)
	if not _braking:
		if t > CHARGE_PREP + CHARGE_RUN:
			_end_charge()
			return
		_sp = smoothstep(CHARGE_PREP, CHARGE_PREP + 0.6, t)             # it gets up to speed, it does not start there
		_walk = maxf(_sp, 0.4)
		# the skid takes BRAKE_STOP metres from a full run (less from slower): start it that far plus the gap short of you
		if _sp > 0.3 and d <= GRAB_DIST + STOP_GAP + BRAKE_STOP * _sp * _sp:
			_begin_brake()
		_cue(delta, 0.5, func(): scares.heartbeat(0.9))
	else:
		_sp = move_toward(_sp, 0.0, delta * charge_speed / (2.0 * BRAKE_STOP))
		_walk = _sp
		if _sp <= 0.0:
			_brake_t += delta                                           # stood there, facing you, the chest heaving
			yaw = lerp_angle(yaw, _yaw_to(pp), minf(1.0, delta * TURN_RATE))
			if _brake_t >= BRAKE_HOLD: _end_charge()
	_move_toward(pp, charge_speed * _sp * (0.0 if _hitch_t > 0.0 else 1.0), delta)
	rotation.y = yaw

## Close enough: it throws its weight back and skids, the ground shuddering, a breath dragged in
func _begin_brake() -> void:
	_braking = true
	_brake_t = 0.0
	_tw_next = 0.0
	Game.fx_shock = maxf(Game.fx_shock, 0.9)         # the picture punches in on the near miss
	if scares != null:
		_sfx("bone_crack", global_position + Vector3.UP * 1.5, 0.8, 6.0, 0.6)
		_sfx(BREATH + ("rasp1.wav" if randf() < 0.5 else "rasp2.wav"), _face(), 1.0, 8.0, randf_range(0.9, 0.98))
		scares.heartbeat(1.3)
	if _pl != null: _pl.quake(0.6)

func _end_charge() -> void:
	state = "stalk"
	_braking = false
	_sp = 0.0
	_walk = 0.0
	_watch_t = 0.0

## The high: while it runs at the player the world gets sharper and richer (on top of the player's adrenaline, which
## brings the speed and the tunnel), and it fades over a couple of seconds once it has stopped, so the escape feels
## like something won. Added to Game.fx_sat / fx_contrast as a delta, so it never fights anything else that sets them.
func _rush_fx(delta: float) -> void:
	var on: bool = state == "charge" and t > CHARGE_PREP and not _pl.dead and not _pl.frozen
	_rush = move_toward(_rush, 1.0 if on else 0.0, delta * (4.0 if on else 0.5))
	var sat := 0.3 * _rush
	var con := 0.14 * _rush
	Game.fx_sat += sat - _rush_sat
	Game.fx_contrast += con - _rush_con
	_rush_sat = sat
	_rush_con = con

func _rush_clear() -> void:
	Game.fx_sat -= _rush_sat
	Game.fx_contrast -= _rush_con
	_rush = 0.0
	_rush_sat = 0.0
	_rush_con = 0.0

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
	var mid := _face() if _peeking() else global_position + Vector3.UP * height * 0.55
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

# ---------------------------------------------------------------- its body: the clips, its head on top
func _process(delta: float) -> void:
	var _pt := Time.get_ticks_usec()
	_process_timed(delta)
	Perf.add("Burnt (pose)", _pt)

func _process_timed(delta: float) -> void:
	if not present or body == null: return
	# far off and only stalking (EntityLOD ASLEEP): not drawn and not posed; it still walks (_physics_process)
	var asleep := EntityLOD.tier(self) == EntityLOD.ASLEEP
	if body.visible == asleep:
		body.visible = not asleep
	if asleep: return
	if puppet:                          # (the guest is told how fast it goes by _walk, and that it is skidding by its drop)
		_sp = _walk
	_hitches(delta)
	# (the clips carry its weight, bob and lean; the body is only tipped over you in the hug from behind)
	body.position = Vector3.ZERO
	body.rotation = Vector3(_lean, deg_to_rad(yaw_offset), 0.0)
	_animate(delta)
	_pose_head(delta)
	if state == "hug" and (not puppet or _net_taken):
		_hug_place()
		_hug_arms()
	if state in ["hug", "grab", "lift", "stare", "corrupt"] and (not puppet or _net_taken):
		_sequence(delta)

## Broken rhythm: every few seconds of the walk (every second or so of the run) the clip and its feet hold for a
## beat, a dropped frame, then go on. In the run a joint cracks with it.
func _hitches(delta: float) -> void:
	_hitch_t = maxf(0.0, _hitch_t - delta)
	var walking := (state == "stalk" or state == "withdraw" or (state == "peek" and _peek_phase == "go")) and _walk > 0.6
	var running := state == "charge" and t > CHARGE_PREP and not _braking and _sp > 0.5
	if not (walking or running): return
	_hitch_next -= delta
	if _hitch_next > 0.0: return
	_hitch_t = randf_range(0.1, 0.18) if running else randf_range(0.12, 0.22)
	_hitch_next = randf_range(0.5, 1.2) if running else randf_range(2.5, 6.0)
	if running and scares != null:
		_sfx("bone_crack", global_position + Vector3.UP * 1.5, 0.35, 6.0, randf_range(0.9, 1.2))

## Which clip, how fast and how it blends in, from what it is doing; then the clip is advanced by hand and a foot
## that comes down in it is heard (and in the run, felt).
func _animate(delta: float) -> void:
	if _ap == null: return
	var k := body.scale.x
	var clip := "idle"
	var speed := 1.0
	var fade := 0.4
	var back := false
	_still_t = 0.0 if _walk > 0.02 else _still_t + delta
	var walk_speed := _walk * STALK_SPEED * _pace / (WALK_CLIP_SPEED * k)
	match state:
		"stalk", "withdraw":
			# caught mid-stride it holds the stride, dead still; only after a while does it settle into its stance
			if _walk > 0.02 or (_clip == "walk" and _still_t < FREEZE_HOLD):
				clip = "walk"
				speed = walk_speed
				fade = 0.3
			else:
				fade = 1.2 if _clip == "walk" else 0.4
		"windup":
			clip = "windup"
			fade = 0.1
		"charge":
			if t < CHARGE_PREP:
				clip = "crouch"
				fade = 0.15
			elif _braking:
				clip = "skid" if _sp > 0.0 else "heave"
				fade = 0.1 if clip == "skid" else 0.5
			else:
				clip = "run"
				speed = maxf(0.6, _sp * charge_speed / (RUN_CLIP_SPEED * k))
				fade = 0.2
		"peek":
			var c := "peek_r" if _peek_side > 0 else "peek_l"
			match _peek_phase:
				"go":
					clip = "walk"
					speed = walk_speed
					fade = 0.3
				"in":
					clip = c
					fade = 0.25
				"hold":
					clip = c + "_hold"
					fade = 0.3
				"out":
					clip = c
					back = true
					speed = PEEK_IN / PEEK_OUT * (CAUGHT_BACK if _caught else 1.0)
					fade = 0.1 if _caught else 0.2
			if _is_seen and _peek_phase != "go" and not _caught: speed = 0.0   # caught at it: frozen where it is (a beat)
		"hug":
			fade = 0.3                                               # (stood, its arms posed round you on top)
		"grab", "lift", "stare", "corrupt":
			clip = "kill"
			fade = 0.0 if _from_hug else 0.08                        # (out of the black: no blend to see)
	if _hitch_t > 0.0: speed = 0.0
	var key := clip + ("<" if back else "")
	if key != _clip:
		if not _ap.has_animation(clip): return
		if back: _ap.play_backwards(clip, fade)
		else: _ap.play(clip, fade)
		if clip == "kill" and KILL_AT.has(state): _ap.seek(KILL_AT[state] + t, true)
		_clip = key
		_clip_pos = _ap.current_animation_position
	_ap.speed_scale = speed
	_ap.advance(delta)
	var at := _ap.current_animation_position
	if clip == "walk" or clip == "run":
		for f: float in (WALK_FALLS if clip == "walk" else RUN_FALLS):
			if (_clip_pos < f and f <= at) or (at < _clip_pos and (f > _clip_pos or f <= at)):
				_footfall(clip == "run")
	_clip_pos = at

## A foot coming down. Walking: slow, heavy and soft (a big weight set down on carpet over concrete), felt more than
## heard. Running: each stride lands in the player's own view, the floor shudders, the picture punches in on the beat.
func _footfall(running: bool) -> void:
	if scares == null: return
	if not running:
		_sfx("thump", global_position, 0.32, 3.0, randf_range(0.9, 1.0))
		return
	_sfx("thump", global_position, 0.6, 7.0, randf_range(0.72, 0.9))
	var near := clampf(1.0 - global_position.distance_to(_pl.global_position) / 22.0, 0.0, 1.0)
	_pl.jolt(0.9 * near)
	Game.fx_shock = maxf(Game.fx_shock, 0.12 * near)

## Turn bone `name` by `angle` about a world axis, on top of the pose the clip has given it
func _turn(name: String, world_axis: Vector3, angle: float) -> void:
	if skel == null or not _bone.has(name): return
	var i: int = _bone[name]
	var parent := skel.get_bone_parent(i)
	var pb := skel.global_transform.basis
	if parent >= 0: pb = pb * skel.get_bone_global_pose(parent).basis
	var pq := pb.orthonormalized().get_rotation_quaternion()
	var q := pq.inverse() * Quaternion(world_axis.normalized(), angle) * pq
	skel.set_bone_pose_rotation(i, q * skel.get_bone_pose_rotation(i))

## Its head, over the clip: kept on you whichever way the body turns (stalking, running, hanging off an edge), and
## the twitch. Stillness is what's wrong with it. Now and then (not often) the head gives one small, sharp tick, a
## few degrees round or over, never up and down (that read as nodding), holds it, and eases back very slowly. It
## ticks faster the longer it is stared at; in the run it will not keep its head still at all. (Holding you, the
## kill clip has its own.)
func _pose_head(delta: float) -> void:
	if skel == null: return
	var fwd := Vector3(sin(rotation.y), 0.0, cos(rotation.y))
	_tw_next -= delta
	var may_tick := state == "stalk" or state == "withdraw" or state == "charge" or (state == "peek" and _peek_phase == "hold")
	if _tw_next <= 0.0 and may_tick:
		if state == "charge": _tw_next = randf_range(0.12, 0.35)
		elif _watch_t > charge_watch * 0.5: _tw_next = randf_range(0.8, 1.6)
		else: _tw_next = randf_range(4.0, 9.0) if state == "stalk" else randf_range(1.5, 3.5)
		_tw_axis = fwd if randf() < 0.6 else Vector3.UP       # a tilt over, or a turn: nothing else
		_tw_goal = randf_range(0.07, 0.13) * (1.0 if randf() < 0.5 else -1.0) * (2.2 if state == "charge" else 1.0)
	elif not may_tick:
		_tw_goal = 0.0
	_tw_amt = move_toward(_tw_amt, _tw_goal, delta * 14.0)      # snaps...
	_tw_goal = move_toward(_tw_goal, 0.0, delta * 0.05)         # ...and creeps back over seconds
	var look_at := 0.0
	var tracking := state == "stalk" or state == "withdraw" or state == "charge" or (state == "peek" and _peek_phase != "set")
	if tracking and player != null and not (state == "peek" and _is_seen and _peek_phase != "go" and not _caught):
		var aim := player.global_position
		var from := _peek_head if _peeking() else global_position
		var reach := 1.6 if state == "withdraw" else 1.0     # walking off, it looks back over its shoulder further than it should
		look_at = clampf(wrapf(atan2(aim.x - from.x, aim.z - from.z) - rotation.y, -PI, PI), -reach, reach)
	elif state == "peek" and _is_seen:
		look_at = _head_yaw                                      # (caught: it doesn't move, not even its eyes)
	_head_yaw = lerpf(_head_yaw, look_at, 1.0 - exp(-4.0 * delta))
	var head := Quaternion(Vector3.UP, _head_yaw) * Quaternion(_tw_axis, _tw_amt)
	if head.get_angle() > 0.0001:
		_turn("Head", head.get_axis(), head.get_angle())

## Taken from behind, its head has to stay behind yours: the clip's stoop carries it forward over you, and the
## camera would be inside it. Every frame of the hug the body is slid back along the way you face until the middle
## of its skull is HUG_HEAD_BACK behind your eyes (it is behind you: nothing sees it go; the arms are aimed after).
func _hug_place() -> void:
	if skel == null or not _bone.has("Head"): return
	var c: Vector3 = (_pl.cam as Camera3D).global_position
	var skull := (skel.global_transform * skel.get_bone_global_pose(_bone["Head"]).origin + _face()) * 0.5
	var ahead := (skull - c).dot(_hug_dir) + HUG_HEAD_BACK
	if ahead > 0.0:
		global_position -= _hug_dir * ahead

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
	_braking = false
	_sp = 0.0
	_rush_clear()
	Game.fx_reset()
	if _seen():
		_face_on()
		_hit()
	else:
		_behind()
		state = "hug"
		# no hit yet: a slow breath at the back of your head, and its joints as its arms come round
		if scares != null:
			_sfx(BREATH + "neck.wav", cam.global_position - _hug_dir * 0.4 + Vector3.UP * 0.3, 1.0, 2.0, randf_range(0.96, 1.02))
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
		_sfx("bone_crack", global_position + Vector3.UP * 2.0, 1.0, 4.0, 0.7)

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

## Where your eyes are while it holds you, face on: between its wrists and KILL_EYE above (the kill clip holds you
## by the chest, palms in, so this follows its grip, its breathing and its lunge)
func _held() -> Vector3:
	if skel == null or not (_bone.has("R_Hand") and _bone.has("L_Hand")):
		return _face() + _fwd * 0.6
	var a := skel.global_transform * skel.get_bone_global_pose(_bone["R_Hand"]).origin
	var b := skel.global_transform * skel.get_bone_global_pose(_bone["L_Hand"]).origin
	return (a + b) * 0.5 + skel.global_transform.basis * Vector3(0.0, KILL_EYE, 0.0)

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
	# (face on, the kill clip stoops it over you, lunges and leans in; the hug's lean is set by _behind)
	if state != "hug": _lean = 0.0
	# You are where its hands hold you (_held): the camera rides the clip, its grip, its breathing heaving you
	match state:
		"hug":
			# your own view, held still and trembling, its arms coming round you and closing; then black
			var tight := smoothstep(HUG_REACH, HUG_TIME, t)
			pos = _from.origin
			look = _from.origin - _from.basis.z * 3.0 - Vector3.UP * 0.35 * tight
			shake = 0.003 + 0.012 * tight
			_set_black(smoothstep(HUG_TIME - HUG_FADE, HUG_TIME, t))
			_once("joints", t > 0.6, func(): _sfx("creak", _shoulders(), 0.6, 2.0, 0.62))
			if t >= HUG_TIME:
				_turn_round()
				return
		"grab":
			if _from_hug: _set_black(1.0 - smoothstep(0.0, FADE_IN, t))
			# jerked round to face it, pulled in against it, off your feet
			var k := smoothstep(0.0, GRAB_TIME, t)
			var x := clampf(t / GRAB_TIME, 0.0, 1.0) - 1.0
			var slam := 1.0 + 2.70158 * x * x * x + 1.70158 * x * x           # ease-out-back: it pulls you a little past, and you rebound
			pos = _from.origin.lerp(_held(), slam)
			look = (_from.origin - _from.basis.z * 3.0).lerp(_body_at(0.06), k)
			# the hit: trauma that falls off as its square, a FOV kick that eases back, the view thrown over
			shake = 0.07 * pow(1.0 - clampf(t / GRAB_TIME, 0.0, 1.0), 2.0) + 0.01
			fov = _from_fov + 16.0 * exp(-t * 8.0)
			roll = 0.12 * exp(-t * 6.0)
			_once("slam", true, func(): _sfx("thump", _body_at(0.0), 0.9, 6.0, 0.5))
			if t >= GRAB_TIME: _next("lift")
		"lift":
			# raised up the length of it, your light on it all the way, until you are level with its face
			var k := t / LIFT_TIME
			var s := k * k * k * (k * (k * 6.0 - 15.0) + 10.0)                # (the clip raises you on the same curve)
			pos = _held()
			look = _body_at(minf(1.0, s + 0.1)).lerp(face, smoothstep(0.7, 1.0, s))
			fov = lerpf(_from_fov, 58.0, s)
			shake = 0.008 + 0.004 * sin(t * 1.7)
			roll = 0.03 * sin(t * 0.9)                                     # hung from its arms: a slow swing
			# its own laboured breath, over you, twice on the way up
			_once("lb1", s > 0.45, func(): _sfx(BREATH + "rasp1.wav", face, 0.6, 3.0, 0.97))
			_once("lb2", s > 0.85, func(): _sfx(BREATH + "rasp2.wav", face, 0.8, 2.0, 0.93))
			# the camera already struggling near its face: a block or two breaking up, now and then
			if s > 0.6 and randf() < delta * 1.2 * s: Game.fx_corrupt = maxf(Game.fx_corrupt, 0.12)
			# its charred joints taking your weight, right by you, now and then; your heart, quietly
			var at := pos
			_cue(delta, randf_range(1.0, 1.8), func() -> void:
				_sfx("creak", at, 0.55, 2.0, randf_range(0.6, 0.75))
				scares.heartbeat(0.6 + 0.6 * s)
			)
			if t >= LIFT_TIME: _next("stare")
		"stare":
			# held there, drawn in closer while its head tilts over
			# (it stops closing in for 0.4 s at 2.0 s, the head ticks, then it comes on: the hold is the beat, in the clip)
			var tt := t if t < 2.0 else (2.0 if t < 2.4 else t - 0.4)
			var k := smoothstep(0.0, STARE_TIME - 0.4, tt)
			pos = _held()
			look = face
			fov = lerpf(58.0, 48.0, k)
			shake = 0.004
			# your view leans over to meet its tilted head: the room goes crooked
			roll = 0.2 * smoothstep(1.2, STARE_TIME, t)
			_once("tin", true, func(): _sfx_flat("tinnitus", 0.15))
			_once("hold", t > 2.0, func(): _sfx("bone_crack", face, 0.5, 2.0, 0.8))
			Game.fx_contrast = 1.0 + 0.2 * k
			Game.fx_sat = 1.0 - 0.4 * k
			if randf() < delta * 1.5: Game.add_glitch(0.15)
			# the picture of its face coming apart in squares: short bursts, more and worse as it goes on
			if randf() < delta * (0.8 + 3.0 * k): Game.fx_corrupt = maxf(Game.fx_corrupt, 0.15 + 0.35 * k)
			# dead silence (even your heart), then it breathes in, slowly, right in your face
			_once("breath", t > 1.5, func():
				_sfx(BREATH + "in.wav", face, 1.0, 2.0, 0.97))
			if t >= STARE_TIME: _next("corrupt")
		"corrupt":
			# the tape can't hold it: tearing, warping, static, the frame jumping closer to its face
			var k := clampf(t / CORRUPT_TIME, 0.0, 1.0)
			var jump := 0.35 * floorf(k * 4.0) / 4.0 if randf() < 0.2 + 0.6 * k else 0.1 * k
			pos = _held().lerp(face, jump)
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
			_once("drone", true, func(): _sfx_flat("drone", 0.9, 3.0))
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

# ---------------------------------------------------------------- its sounds
## One of its sounds at `pos`, matched in loudness to the rest (_match), then at `level`. Nearer you than `ref` it is
## not boosted past `level`: a breath at the back of your neck stays a breath. `name`: a scare_synth.gd sound, or a
## recording (res://...), already baked at SFX_LOUD.
func _sfx(name: String, pos: Vector3, level: float, ref: float, pitch := 1.0, arg := 0.0) -> void:
	if scares == null: return
	var near := ref if _pl == null else (_pl.cam as Camera3D).global_position.distance_to(pos)
	if name.begins_with("res://"):
		scares.spawn3d(load(name), pos, level, "Scares", clampf(near, 0.5, ref), pitch)
		return
	var w: AudioStreamWAV = scares.synth(name, arg)
	scares.spawn3d(w, pos, level * _match(name, arg, w), "Scares", clampf(near, 0.5, ref), pitch)

func _sfx_flat(name: String, level: float, arg := 0.0) -> void:
	if scares == null: return
	var w: AudioStreamWAV = scares.synth(name, arg)
	scares.spawn_flat(w, level * _match(name, arg, w))

## The gain that brings `w` to SFX_LOUD: scare_synth.gd peak-normalizes, so a breath (all body) plays far louder than
## a joint cracking (one click) at the same level. Loudness here: its loudest ~50 ms, RMS. Worked out once a sound.
static func _match(name: String, arg: float, w: AudioStreamWAV) -> float:
	var key := "%s:%s" % [name, arg]
	if not _loud.has(key):
		var d := w.data
		var n := d.size() / 2
		var win := mini(1102, n)
		var best := 0.0001
		var i := 0
		while i + win <= n:
			var sum := 0.0
			for j in range(i, i + win, 4):
				var v := d.decode_s16(j * 2) / 32768.0
				sum += v * v
			best = maxf(best, sqrt(sum / ceilf(win / 4.0)))
			i += maxi(1, win / 2)
		_loud[key] = best
	return minf(SFX_LOUD / _loud[key], 3.0)

## Off, without touching the player (their death owns the camera from here)
# ---------------------------------------------------------------- T.S.R.A. scanner
# Hold Q on it with the field scanner (scripts/Player/scanner.gd) to log it in the Threshold Dossier.
func _enter_tree() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("tsra_id", "burnt")

## Where the scanner can take a reading off it right now: its chest and its head; empty while it is away
func scan_points() -> Array:
	if not present or body == null or not visible:
		return []
	var h := height * size
	return [global_position + Vector3.UP * h * 0.55, global_position + Vector3.UP * h * 0.9]

## C-4 deep scan (scan_readout.gd)
func scan_behavior(_at: Vector3) -> Dictionary:
	match state:
		"windup", "charge":
			return {"state": "CHARGING", "detail": "RUNNING AT THE SUBJECT // BREAK LINE OF SIGHT", "danger": 2}
		"grab", "lift", "stare", "corrupt", "hug", "held":
			return {"state": "FEEDING", "detail": "SUBJECT IN ITS GRIP", "danger": 2}
		"peek":
			return {"state": "WATCHING", "detail": "AT A WALL CORNER // HEAD LEANED OUT", "danger": 1}
		"withdraw":
			return {"state": "WITHDRAWN", "detail": "OUT OF SIGHT // IT WILL COME BACK", "danger": 1}
	return {"state": "STALKING", "detail": "MOVES ONLY UNOBSERVED // LAMPS DEAD AROUND IT", "danger": 2}

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
	_watch_t = 0.0
	_hitch_t = 0.0
	_braking = false
	_sp = 0.0
	_peek_phase = ""
	_is_seen = false
	_caught = false
	_pace = 1.0
	_rush_clear()
	if _black != null: _set_black(0.0)
	_clip = ""
	if _ap != null: _ap.stop()

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
	_peek_phase = ""
	_peek_cd = 4.0
	_clip = ""
	_fresh_hunt()
	return true

## Console: it hides at a wall corner and leans out to watch you. retreat: it starts where you can see it and walks
## off to the corner in plain sight (then works round behind you, the flank). Moved to a spot that has a corner if
## where it stands has none.
func debug_peek(retreat := false) -> bool:
	if not _debug_ready(): return false
	var pp: Vector3 = _target().pos
	var d := Vector2(pp.x - global_position.x, pp.z - global_position.z).length()
	var in_sight := nav.clear_line(global_position.x, global_position.z, pp.x, pp.z)
	if not (d >= PEEK_MIN and d <= PEEK_MAX and in_sight == retreat and _find_peek(pp)) and not _debug_corner(pp, retreat):
		last_error = "no wall corner within %d-%d m of you to peek round: stand in a corridor, near a corner" % [int(PEEK_MIN), int(PEEK_MAX)]
		return false
	_watch_t = 0.0
	_begin_peek(retreat)
	return true

## Console: it runs at you, from at least charge_min off down a straight line (the way you look, else the nearest
## way round that has one)
func debug_charge() -> bool:
	if not _debug_ready(): return false
	var pp: Vector3 = _target().pos
	if Vector2(pp.x - global_position.x, pp.z - global_position.z).length() < charge_min or not nav.clear_line(global_position.x, global_position.z, pp.x, pp.z):
		var look := -(_pl.cam as Camera3D).global_transform.basis.z
		var a0 := atan2(look.x, look.z)
		var at := Vector3.INF
		for i in 8:                                       # 0, +45, -45, +90, -90... degrees off your view
			var dir := Vector3(sin(a0 + PI / 4.0 * ceilf(i / 2.0) * (1 - 2 * (i % 2))), 0.0, cos(a0 + PI / 4.0 * ceilf(i / 2.0) * (1 - 2 * (i % 2))))
			var r := 22.0
			while r >= charge_min:
				var c := pp + dir * r
				if nav.open_at(c.x, c.z) and nav.clear_line(pp.x, pp.z, c.x, c.z):
					at = c
					break
				r -= 0.5
			if at != Vector3.INF: break
		if at == Vector3.INF:
			last_error = "no straight run of %d m from you in any direction: go into a long hall" % int(charge_min)
			return false
		global_position = Vector3(at.x, global_position.y, at.z)
		yaw = _yaw_to(pp)
		rotation.y = yaw
	_begin_charge()
	return true

## Console: it works round to come at you from behind (what it does after it has hidden)
func debug_flank() -> bool:
	if not _debug_ready(): return false
	var pp: Vector3 = _target().pos
	if Vector2(pp.x - global_position.x, pp.z - global_position.z).length() <= FLANK_NEAR and not _debug_corner(pp, false, false):
		last_error = "too close (%d m or nearer it just comes straight at you) and nowhere out of your sight to start from" % int(FLANK_NEAR)
		return false
	state = "stalk"
	_peek_phase = ""
	_flank_t = FLANK_TIME
	return true

## Console: it walks off out of your sight, waits, and comes back slowly
func debug_hide() -> bool:
	if not _debug_ready(): return false
	if not _begin_withdraw(_target().pos):
		last_error = "nowhere %d-%d m from you out of your sight" % [int(HIDE_MIN), int(HIDE_MAX)]
		return false
	return true

## Console: stop shadowing you, close in now
func debug_commit() -> bool:
	if not _debug_ready(): return false
	_hunt_t = _commit_at
	return true

## Console: it takes you where it stands (face on if you see it, the hug from behind if not)
func debug_grab() -> bool:
	if not _debug_ready(): return false
	var tgt := _target()
	if not tgt.local or _pl.dead:
		last_error = "only the host's own player"
		return false
	_peek_phase = ""
	_start_grab(tgt)
	return true

## Console: what it is doing, and each gate that keeps it from peeking / retreating / charging / flanking now
func debug_status() -> String:
	if not present: return "burnt: not in the scene (lod %s)" % EntityLOD.tier_name(self)
	var tgt := _target()
	if tgt.is_empty(): return "burnt: %s, nobody to hunt" % state
	var pp: Vector3 = tgt.pos
	var p := global_position
	var d := Vector2(pp.x - p.x, pp.z - p.z).length()
	var los := nav.clear_line(p.x, p.z, pp.x, pp.z)
	var keep := [_peek_at, _peek_yaw, _peek_head, _peek_side]     # (_find_peek writes over the spot it may be using)
	var corner := _find_peek(pp)
	_peek_at = keep[0]; _peek_yaw = keep[1]; _peek_head = keep[2]; _peek_side = keep[3]
	var why: Array[String] = []
	if Game.freeze_ai: why.append("monsters frozen")
	if _lurk: why.append("lurking until you are within %d m" % int(LURK_WAKE))
	if d < PEEK_MIN or d > PEEK_MAX: why.append("peek needs %d-%d m" % [int(PEEK_MIN), int(PEEK_MAX)])
	if _peek_cd > 0.0: why.append("peek cooldown %.0f s" % _peek_cd)
	if not corner: why.append("no wall corner near it to peek round")
	if los and not _is_seen: why.append("unseen peek needs a wall between you")
	if not _can_take(tgt): why.append("can't take you (god mode / grace / frozen): no charge, no grab")
	if d < charge_min or d > charge_max: why.append("charge needs %d-%d m" % [int(charge_min), int(charge_max)])
	if _hunt_t < _commit_at: why.append("shadowing from %d m for %.0f s more" % [int(KEEP_DIST), _commit_at - _hunt_t])
	if _charge_cd > 0.0: why.append("charge cooldown %.0f s" % _charge_cd)
	return "burnt: %s%s  d %.1f m  seen %s  line to you %s  watched %.1f s (retreat %.1f, charge %.1f)  flank %.0f s  lod %s\n  blocked: %s" % [
			state, "/" + _peek_phase if _peek_phase != "" else "", d, _is_seen, los, _watch_t, RETREAT_WATCH, charge_watch,
			_flank_t, EntityLOD.tier_name(self), ", ".join(why) if not why.is_empty() else "nothing"]

## Spawned (or already here), hunting, and nothing running that a debug action would cut into
func _debug_ready() -> bool:
	if not present and not debug_spawn(): return false
	if state in ["hug", "grab", "lift", "stare", "corrupt", "held"]:
		last_error = "busy (%s)" % state
		return false
	if _target().is_empty():
		last_error = "nobody to hunt"
		return false
	_lurk = false
	_peek_cd = 0.0
	return true

## Moves it to the nearest open cell PEEK_MIN-PEEK_MAX from you that has a corner to peek from (corner) or any: out of
## your line of sight, or (seen) in it. Puts it back if there is none.
func _debug_corner(pp: Vector3, seen: bool, corner := true) -> bool:
	var was := global_position
	var cx := GridNav.cell(pp.x)
	var cz := GridNav.cell(pp.z)
	var r := ceili(PEEK_MAX / CELL)
	var cells: Array[Vector3] = []
	for ox in range(-r, r + 1):
		for oz in range(-r, r + 1):
			var c := Vector3((cx + ox) * CELL, was.y, (cz + oz) * CELL)
			var d := Vector2(c.x - pp.x, c.z - pp.z).length()
			if d >= PEEK_MIN and d <= PEEK_MAX and nav.open_at(c.x, c.z) and nav.clear_line(c.x, c.z, pp.x, pp.z) == seen:
				cells.append(c)
	cells.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_squared_to(pp) < b.distance_squared_to(pp))
	for c in cells:
		global_position = c
		if not corner or _find_peek(pp):
			yaw = _yaw_to(pp)
			rotation.y = yaw
			return true
	global_position = was
	return false

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
	_burn_lamps(delta)                    # (its footfalls come off the clips, in _animate, here as on the host)

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
