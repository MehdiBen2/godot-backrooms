extends Node3D
## THE MIMIC (js/game/mimicPeer.js). Something that passes for a survivor.
##
##  ECHO   It walks where someone walked, minutes ago (mimic_echo.gd keeps everyone's last four
##         minutes: feet, facing, look, crouch, torch). It picks a moment on that route that nobody can
##         see right now, 8-35 m from you, from which the route brings it into your view within half a
##         minute, appears there unseen and walks it back in real time: stopping where they stopped,
##         crouching where they crouched, looking at the walls they looked at, torch on where theirs
##         was. It isn't coming for you. It is doing what a person did, which is why it passes for one.
##         It moves and sounds exactly like a survivor on the network (remote_player.gd: the same clips
##         at the same speeds, silent feet, the torch pitched where it looks) and does not raise your
##         heartbeat. Watch it from close by and, after a moment, it stops and looks back, as anyone
##         would, then carries on (NOTICE). Walk right up to it and it bolts (FLEE). It only ever goes
##         when nobody is looking. Alone, it walks your own route behind you.
##  CHARGE A power cut: it comes to you in the dark the way a teammate would, walking, torch on. Watched,
##         it stops at talking distance and stands there; turn your back and it closes in and strikes
##         once (it hurts and stuns). Catch it in your torch up close and it walks off. One try per
##         blackout, then it is gone until the lights are back.
## It stirs once there are ECHO_START seconds of anyone's route to walk (or a power cut, or F5).
##
## In co-op it wears the face of the survivor whose route it walks: their colour and their name tag,
## exactly as a teammate's (remote_player.gd), and now and then it says something they said lately, in
## their own voice (Voice.clip_of: each machine keeps everyone's last few sentences). It walks someone
## else's route than the survivor it is nearest, and nobody ever sees it wearing their own face. The
## field scanner is the one thing it can't fool: it locks onto the Mimic, never onto a person, and a
## deep scan says whose face it wears.
## Dev keys: F5 toggles the Mimic.

const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const MimicEcho := preload("res://scripts/Entities/mimic/mimic_echo.gd")
const MimicSounds := preload("res://scripts/Entities/mimic/mimic_sounds.gd")
const GridNav := preload("res://scripts/World/grid_nav.gd")
const SnapBuffer := preload("res://scripts/Net/snap_buffer.gd")
const SurvivorAnim := preload("res://scripts/Entities/survivor_anim.gd")
const MODEL := SurvivorAnim.MODEL
const MODEL_HEIGHT := 2.0

# MIMIC_PEER config
const SPAWN_MIN := 12.0
const SPAWN_MAX := 20.0
const VIEW_CONE := 0.62
const FLEE_DONE_DIST := 26.0
const CHARGE_STOP := 2.5
const HIT_DAMAGE := 40.0
const HIT_STUN := 2.0
const HIT_COOLDOWN := 8.0
const CAUGHT_DIST := 6.0             # m: your torch on it this close in a blackout, and it walks off
const DARK_STAND := 4.0              # m: watched in a blackout, it comes no closer than this
const LEAVE_SPEED := 3.8             # m/s: leaving, brisk, a survivor in a hurry

# the echo
const ECHO_START := 120.0            # s of someone's route before it stirs on its own
const ECHO_MIN_AGE := 45.0           # s: it walks where someone was at least this long ago...
const ECHO_MAX_AGE := 230.0          # ...and at most this long ago
const ECHO_NEAR := 8.0               # m from you where it starts, out of sight
const ECHO_FAR := 35.0
const ECHO_VIEW := 25.0              # m: the route has to come within your view, this close...
const ECHO_SHOW_WITHIN := 30.0       # ...within this many seconds of where it starts
const ECHO_SEG := Vector2(40.0, 90.0)    # s it keeps walking before it goes (once nobody is looking)
const ECHO_REST := Vector2(40.0, 100.0)  # s before it walks again
const NOTICE_DIST := 8.0             # m: watched this close, it notices
const NOTICE_REACT := Vector2(0.4, 1.2)  # s before it does: a person's reaction, never the same twice
const NOTICE_HOLD := Vector2(1.5, 3.5)   # s it stands and looks back
const NOTICE_COOLDOWN := 12.0
const BOLT_DIST := 3.5               # m: walk right up to it and it runs
# the lure: having caught your eye, it tries to get you to follow
const LURE_CHANCE := 0.75            # after it notices you (the rest of the time it just carries on)
const LURE_CELLS := Vector2i(4, 14)  # how far it leads you, in cells walked (18-63 m)
const LURE_SPEED := 2.6              # a survivor's walk
const LURE_HURRY := 3.4              # you are right behind it: it keeps its lead
const LURE_LEAD := 5.0               # m: closer than this and it walks on at once
const LURE_FOLLOW := 16.0            # m, in plain line: you are following
const LURE_STOP_EVERY := 12.0        # m of straight hall between looks back (and at every corner)
const LURE_WAIT := Vector2(0.8, 1.6)     # s it waits once it sees you coming
const LURE_PATIENCE := Vector2(6.0, 9.0) # s it waits for you to show before it gives up on you
const LURE_BOLT := 2.5               # m: catch up with it and it runs
const LURE_BAIT_SHORT := 3           # cells short of the Bacteria it stops
const LURE_HEAR := 35.0              # m: the noise it makes there, for the Bacteria
const LURE_CUT_GAP := 200.0          # s since the last power cut before a dead end can cut the lights

var level: Node
var player: CharacterBody3D
var scares: Node
var nav
var rng := RandomNumberGenerator.new()

# ---- peer
var session := false
var spawned := false
var summoned := false                  # the console started a session; without it only a trigger spawns it
var wait := 0.0
var mode := "echo"
var speed := 0.0
var step := 0.0
var flee_until := 0.0
var react_at := 0.0
var hit_ready := 0.0
var body: Node3D

# ---- co-op: the host runs the body (hunting the nearest survivor); guests follow it from snapshots.
const MODES := ["echo", "notice", "flee", "charge", "lure", "wander"]
var puppet := false
var net_buf = SnapBuffer.new()
var t_id := -1
var t_pos := Vector3.ZERO
var t_fwd := Vector3.FORWARD
var _net_t := 0.0
var anim: AnimationPlayer
var body_yaw := 0.0

# ---- the disguise (co-op only): whose face it wears, and what it says in their voice
const VOICE_MIN_DIST := 5.0          # m from its target: it talks from further off, never in your face
const VOICE_MAX_DIST := 30.0
const VOICE_GAP := Vector2(18.0, 40.0)   # s between lines, random in this range
const VoiceSpeaker := preload("res://scripts/Voice/voice_speaker.gd")   # a survivor's voice: the same pipeline
const MOUTH_BUS := "Voice_mimic"
var disguise_id := 0                 # host: the survivor it pretends to be (0: none); sent to the guests
var shown_id := 0                    # who it looks like on THIS machine (never yourself)
var voice_n := 0                     # host: counts its lines; a guest plays one when this ticks over
var _voice_heard := 0
var _next_voice := 0.0
var _tint_mats: Array = []           # [StandardMaterial3D, base albedo]: the suit, tinted to its disguise
var tag: Label3D
var torch: SpotLight3D
var mouth: AudioStreamPlayer3D
var _mouth_cut := 20000.0
var _mouth_db := 0.0
var _clips := {}                     # role -> the suit's clip (survivor_anim.gd, as a survivor's)
var _floor: SurvivorAnim.FloorGuard   # keeps its feet out of the floor between clips
var _role := ""
var echo := MimicEcho.new()          # host: everyone's last few minutes
var echo_src := -1                   # whose route it walks
var echo_clock := 0.0                # s of game time: the routes are stamped with it and every timer runs
                                     # on it (not the wall clock: the game can pause or run slow)
var play_t := 0.0                    # the moment on that route it is at (echo_clock time)
var seg_end := 0.0
var notice_until := 0.0
var notice_ready := 0.0
var crouch := false                  # its pose, from the route (sent to the guests)
var torch_on := false
var pitch := 0.0
var _torch_was := false
var clicker: AudioStreamPlayer3D
var sounds: Node                     # mimic_sounds.gd: copied sounds, and its own footsteps
var _dark_done := false              # this blackout's try is spent
var _route_mode := ""                # which mode lure_path was planned for (flee / charge), "" none
var _route_at := 0.0                 # when to re-plan the way to you (charge)
var lure_kind := ""                  # dead_end / pit / bacteria: where it is taking you
var lure_path: Array = []            # waypoints (cell centres; a pit crossing goes straight over the hole)
var lure_i := 0
var lure_from := Vector3.ZERO        # where the current leg started
var lure_state := "walk"             # walk / wait / arrived
var lure_walked := 0.0               # m since it last looked back
var lure_go_at := 0.0
var lure_patience_until := 0.0
var lure_spoke := false
var wander_start := 0.0

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	nav = GridNav.new(level)
	_build_body()
	sounds = MimicSounds.new()                  # your own sounds, from the next corridor (every machine, its own player)
	sounds.mimic = self
	add_child(sounds)

# ================================================================= peer
func _build_body() -> void:
	body = Node3D.new()
	body.visible = false
	add_child(body)
	var packed := load(MODEL) as PackedScene
	if packed == null:
		return
	var root: Node3D = packed.instantiate()
	body.add_child(root)
	root.transform = HazmatFit.fit(root, body, MODEL_HEIGHT)
	var aps := root.find_children("*", "AnimationPlayer", true, false)
	if not aps.is_empty():
		anim = aps[0]
		_floor = SurvivorAnim.FloorGuard.new(root, anim)    # it never dies on screen: always on
		_clips = SurvivorAnim.find_clips(anim)
		_clips["death"] = ""                     # it never dies on screen: never pick that clip
	# its own copy of the suit's materials, so it can take a survivor's colour (remote_player.gd _tint)
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in mi.get_surface_override_material_count():
			var mat := mi.get_active_material(i)
			if mat is StandardMaterial3D:
				var c: StandardMaterial3D = mat.duplicate()
				mi.set_surface_override_material(i, c)
				_tint_mats.append([c, c.albedo_color])
	# a name tag, a torch and a voice, all as a survivor's (remote_player.gd), off until it has a face
	tag = Label3D.new()
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.pixel_size = 0.004
	tag.font_size = 48
	tag.outline_size = 12
	tag.modulate = Color(0.94, 0.91, 0.75)
	tag.position = Vector3(0, 2.25, 0)
	tag.no_depth_test = true
	tag.visible = false
	body.add_child(tag)
	torch = SpotLight3D.new()
	torch.position = Vector3(0.28, 1.4, 0.3)
	torch.rotation.y = PI                      # the model faces +Z
	torch.spot_range = 12.0
	torch.spot_angle = 32.0
	torch.light_energy = 2.5
	torch.light_color = Color("fff0c8")
	torch.shadow_enabled = int(Gfx.s.get("shadows", 1)) > 0
	torch.shadow_bias = 0.04
	torch.shadow_normal_bias = 1.5
	torch.visible = false
	body.add_child(torch)
	# its voice goes out exactly as a survivor's does over voice chat (voice_speaker.gd): the same
	# falloff, top-end loss with distance and panning, through a bus of its own with the same two
	# low-passes the walls pull down (_update_mouth). Nothing about how it sounds is off.
	mouth = AudioStreamPlayer3D.new()
	mouth.position = Vector3(0, VoiceSpeaker.HEAD_HEIGHT, 0)
	mouth.unit_size = 5.0
	mouth.max_distance = 45.0
	mouth.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	mouth.attenuation_filter_cutoff_hz = 9000.0
	mouth.attenuation_filter_db = -14.0
	mouth.panning_strength = 1.2
	if AudioServer.get_bus_index(MOUTH_BUS) < 0:
		AudioServer.add_bus()
		var bi := AudioServer.bus_count - 1
		AudioServer.set_bus_name(bi, MOUTH_BUS)
		AudioServer.set_bus_send(bi, "Master")
		for k in 2:
			var lp := AudioEffectLowPassFilter.new()
			lp.resonance = 0.6
			AudioServer.add_bus_effect(bi, lp)
	mouth.bus = MOUTH_BUS
	body.add_child(mouth)
	clicker = AudioStreamPlayer3D.new()        # its torch switch, alone (a survivor's makes no sound over the net)
	clicker.position = Vector3(0.28, 1.4, 0.3)
	clicker.unit_size = 3.0
	clicker.max_distance = 25.0
	body.add_child(clicker)

# The grid just went down: it comes for you in the dark (called by the power cut event)
func grid_down() -> void:
	if not session:
		session = true
		wait = 2.0
	elif not spawned:
		wait = minf(wait, 2.0)

func toggle_session() -> void:
	session = not session
	summoned = session
	if session:
		wait = 1.0
	else:
		spawned = false
		body.visible = false

func view_dot(x: float, z: float) -> float:
	var p := t_pos
	var fwd := t_fwd
	var dx := x - p.x
	var dz := z - p.z
	var l := maxf(sqrt(dx * dx + dz * dz), 0.001)
	return (fwd.x * dx + fwd.z * dz) / l

func watched_by(x: float, z: float, cone: float) -> bool:
	var p := t_pos
	return Vector2(x - p.x, z - p.z).length() < 45.0 and view_dot(x, z) > cone

# An open spot spawn_min..spawn_max metres away, out of your sight
func spot_around() -> Variant:
	var p := t_pos
	var angles: Array = []
	for i in 16:
		angles.append(i * PI / 8.0)
	angles.shuffle()
	for a in angles:
		var dx := sin(a)
		var dz := cos(a)
		var reach := 0.0
		var d := 1.0
		while d <= SPAWN_MAX:
			if not nav.open_at(p.x + dx * d, p.z + dz * d):
				break
			reach = d
			d += 0.8
		if reach < SPAWN_MIN:
			continue
		d = SPAWN_MIN + rng.randf() * (reach - SPAWN_MIN)
		var x := p.x + dx * d
		var z := p.z + dz * d
		if not watched_by(x, z, VIEW_CONE - 0.1):
			return Vector2(x, z)
	return null

## A power cut: it turns up out of your sight, near you, to charge (the echo has its own way in)
func appear() -> bool:
	var spot = spot_around()
	if spot == null:
		return false
	var p := t_pos
	body.global_position = Vector3(spot.x, p.y, spot.y)
	speed = 0.0
	mode = "charge"
	_route_mode = ""
	spawned = true
	body.visible = true
	disguise_id = _pick_disguise()
	_next_voice = echo_clock + rng.randf_range(4.0, 10.0)
	return true

# ---------------------------------------------------------------- T.S.R.A. scanner
# Hold Q on it with the field scanner (scripts/Player/scanner.gd) to log it in the Threshold Dossier.
func _enter_tree() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("asra_id", "mimic")

## Where the scanner can take a reading off it right now; empty while it is away
func scan_points() -> Array:
	if not spawned or body == null or not body.is_visible_in_tree():
		return []
	return [body.global_position + Vector3.UP * 1.3]

## C-4 deep scan (scan_readout.gd): what it is doing right now. danger 0 calm / 1 wary / 2 after you
const SCAN_MODES := {
	"echo": ["RETRACING A ROUTE", "WALKING WHERE A SURVIVOR WALKED MINUTES AGO", 1],
	"notice": ["WATCHING YOU", "IT SAW YOU LOOKING - DO NOT WALK UP TO IT", 1],
	"lure": ["LEADING YOU", "IT WANTS YOU TO FOLLOW - DO NOT", 2],
	"wander": ["WANDERING OFF", "IT GAVE UP ON YOU", 1],
	"flee": ["LEAVING", "IT IS GOING - LET IT GO", 0],
	"charge": ["APPROACHING", "COMING TO YOU IN THE DARK - DO NOT TURN YOUR BACK", 2],
}

func scan_behavior(_at: Vector3) -> Dictionary:
	var s: Array = SCAN_MODES.get(mode, [mode.to_upper(), "", 1])
	if shown_id != 0:
		return {"state": s[0], "detail": "WEARING %s'S FACE - IT IS NOT THEM" % Net.label_for(shown_id), "danger": 2}
	if mode == "echo" and not puppet and not Net.is_online():
		return {"state": s[0], "detail": "WALKING YOUR ROUTE FROM %d S AGO" % roundi(echo_clock - play_t), "danger": 1}
	return {"state": s[0], "detail": s[1], "danger": s[2]}

## Its feet: silent while it passes for a survivor (theirs make no sound over the net either). Leaving,
## its cover blown, you hear it go: a person's footsteps (your own takes, on that floor, as loud as
## yours would be from a few metres; mimic_sounds.gd step_at), paced to how fast it moves
func footsteps(delta: float, dist: float) -> void:
	if mode != "flee" or speed < 1.0 or dist > 30.0 or sounds == null:
		step = 0.0
		return
	step -= delta
	if step <= 0.0:
		step = clampf(1.35 / speed, 0.3, 0.6)
		var pos := body.global_position
		sounds.step_at(Vector3(pos.x, pos.y + 0.1, pos.z), "sprint" if speed > 3.2 else "walk")

func update_peer(delta: float) -> void:
	echo_clock += delta
	var t := echo_clock
	if not player.grid_down:
		_dark_done = false                          # the lights are on: the next blackout is a new try                             # every timer here runs on game time, like the route
	echo.record(delta, echo_clock)
	if not session:
		if echo.longest_span() < ECHO_START:
			return
		session = true                              # enough of someone's route to walk it back
		wait = 0.0
	var tg := Net.nearest_survivor(body.global_position if spawned else player.global_position, t_id)
	if tg.is_empty():
		return                                       # nobody alive and in the game
	t_id = tg.id
	t_pos = tg.pos
	t_fwd = tg.fwd
	if not spawned:
		if not summoned:
			return                                  # it never starts on its own: a trigger (appear) or the console brings it in
		wait -= delta
		if wait > 0.0:
			return
		if player.grid_down:
			if not _dark_done:
				appear()
		elif not _begin_echo(t):
			wait = 2.0                              # nowhere it could walk into your view from yet
		return
	if _acting() and not player.grid_down:
		match mode:
			"lure": _lure_step(delta, t)
			"wander": _wander_step(delta, t)
			_: _echo_step(delta, t)
		return
	var pos := body.global_position
	var pp: Vector3 = t_pos
	var lp := player.global_position
	var ldist := Vector2(lp.x - pos.x, lp.z - pos.z).length()      # sound and heartbeat follow THIS player, not the target
	var dx := pp.x - pos.x
	var dz := pp.z - pos.z
	var dist := maxf(Vector2(dx, dz).length(), 0.001)
	var to_player := atan2(dx, dz)
	var watched := watched_by(pos.x, pos.z, VIEW_CONE)
	if Game.heart != null:
		var near := clampf(1.0 - ldist / 12.0, 0.0, 1.0)
		Game.heart.feed("mimic", 0.9 if mode == "charge" else 0.2 + 0.5 * clampf(1.0 - ldist / 25.0, 0.0, 1.0), 3.0 * near * near)

	# decide what it is doing. A blackout is one try, never a loop: it comes to you like a teammate
	# would in the dark, and either strikes once (your back turned) or is caught in your torch and walks
	# off. Either way it is gone until the lights are back (_dark_done).
	var charging: bool = player.grid_down
	if _acting():
		mode = "charge"                             # the grid went down mid-act: it comes to you instead
		step = 0.0
	if not charging and mode == "charge":
		mode = "flee"                               # the lights are back: out of sight, then gone
		flee_until = t + 1.0
	if mode == "flee":
		if t > flee_until and (dist > FLEE_DONE_DIST or (not watched and dist > 16.0)) and not _seen_by_anyone(pos):
			_dark_done = charging                   # left in the dark: not again this blackout
			_vanish()
			return
	elif charging:
		mode = "charge"
		# caught full in your torch, close up: like anyone caught out, it turns and walks off
		if watched and dist < CAUGHT_DIST and _target_torch():
			if react_at == 0.0:
				react_at = t + rng.randf_range(0.3, 0.9)
			elif t >= react_at:
				mode = "flee"
				flee_until = t + 2.0
				react_at = 0.0
				_dark_done = true
		else:
			react_at = 0.0

	# where it goes: always along the real way through the halls (breadth-first, gridnav.gd), never
	# steering blind at a wall (boxed into a corner that turned it in circles)
	if mode == "flee":
		if _route_mode != "flee" or lure_i >= lure_path.size():
			if _route_mode == "flee" and not _seen_by_anyone(pos):
				_dark_done = _dark_done or charging
				_vanish()                           # got where it was going, out of sight: gone
				return
			_plan_leave()
		if lure_path.is_empty():
			speed = 0.0                             # nowhere to go: it stands its ground, like anyone cornered
			body_yaw = lerp_angle(body_yaw, atan2(dx, dz), minf(1.0, delta * 4.0))
		else:
			_walk_path(delta, LEAVE_SPEED)
	elif mode == "charge":
		# watched, it walks up to talking distance and stands there, torch on you; back turned, it closes in
		var goal := 0.0
		if watched:
			goal = LURE_SPEED if dist > DARK_STAND else 0.0
		else:
			goal = LURE_HURRY if dist > CHARGE_STOP else 0.0
		if goal == 0.0:
			speed = 0.0
			body_yaw = lerp_angle(body_yaw, atan2(dx, dz), minf(1.0, delta * 5.0))
		elif dist < 9.0 and nav.clear_line(pos.x, pos.z, pp.x, pp.z):
			var dir := Vector2(dx, dz) / dist       # in plain line: straight to you
			var np := Vector3(pos.x + dir.x * goal * delta, pos.y, pos.z + dir.y * goal * delta)
			if nav.open_at(np.x, np.z):
				body.global_position = np
			speed = goal
			body_yaw = lerp_angle(body_yaw, atan2(dx, dz), minf(1.0, delta * 8.0))
			_route_mode = ""
		else:
			if _route_mode != "charge" or t >= _route_at:
				_route_to(pp)                       # the way to you, kept fresh as you move
				_route_at = t + 0.5
			_walk_path(delta, goal)
	pos = body.global_position
	pos.y = pp.y
	body.global_position = pos

	# it reaches you with your back turned: a blow that stuns and hurts, then it leaves
	if mode == "charge" and dist < CHARGE_STOP + 0.5 and not watched and t >= hit_ready:
		hit_ready = t + HIT_COOLDOWN
		mode = "flee"
		flee_until = t + 3.0 + rng.randf() * 2.0
		_dark_done = true
		if tg.local:
			hit_player()
		else:
			Net.send_mm_hit(tg.id)               # the blow lands on their machine

	footsteps(delta, ldist)

	body.rotation.y = body_yaw
	pitch = 0.0
	crouch = false
	_animate()

# ================================================================= the echo
## Somewhere on someone's route to be, out of everyone's sight, from which it will walk into view.
## In co-op the route is someone else's than the survivor it is nearest if it can (they would know
## where they have been); alone, it is yours.
func _begin_echo(t: float) -> bool:
	var sources: Array = []
	if Net.is_online():
		for s in Net.survivors():
			if s.id != t_id:
				sources.append(s.id)
	sources.shuffle()
	sources.append(t_id)                            # nothing good on theirs: its target's own will do
	for src in sources:
		var tr: Array = echo.track(src)
		var start := _pick_start(tr, echo_clock)
		if start < 0.0:
			continue
		var st := echo.sample(tr, start)
		echo_src = src
		play_t = start
		body.global_position = st.p
		body_yaw = st.h
		body.rotation.y = body_yaw
		pitch = st.pitch
		crouch = st.crouch
		torch_on = st.torch
		_torch_was = torch_on
		speed = st.speed
		mode = "echo"
		spawned = true
		body.visible = true
		disguise_id = src if Net.is_online() else 0
		seg_end = t + rng.randf_range(ECHO_SEG.x, ECHO_SEG.y)
		notice_ready = t + 2.0
		react_at = 0.0
		_next_voice = t + rng.randf_range(6.0, 14.0)
		return true
	return false

## The start time of a stretch of `tr` worth walking: a moment ECHO_MIN_AGE..ECHO_MAX_AGE ago, where
## nobody can see it now, ECHO_NEAR..ECHO_FAR from its target, from which the route comes into the
## target's view within ECHO_SHOW_WITHIN seconds, the way a person comes round a corner. -1: none.
func _pick_start(tr: Array, t: float) -> float:
	var n := tr.size()
	if n < 8:
		return -1.0
	var ahead := int(ECHO_SHOW_WITHIN / MimicEcho.RATE)
	# whether each point of the route is in the target's view, worked out only for the points a
	# candidate actually looks ahead to (0 unknown, 1 no, 2 yes): a whole route's worth of line-of-sight
	# checks every retry would cost a frame
	var shows := PackedByteArray()
	shows.resize(n)
	var picks: Array = []
	var j := 0
	while j < n:
		var age := t - float(tr[j].t)
		var p: Vector3 = tr[j].p
		var d := Vector2(p.x - t_pos.x, p.z - t_pos.z).length()
		if age >= ECHO_MIN_AGE and age <= ECHO_MAX_AGE and d >= ECHO_NEAR and d <= ECHO_FAR and not _seen_by_anyone(p):
			for k in range(j + 4, mini(n, j + ahead), 2):
				if tr[k].cut or tr[k - 1].cut:
					break
				if shows[k] == 0:
					var q: Vector3 = tr[k].p
					var in_view: bool = Vector2(q.x - t_pos.x, q.z - t_pos.z).length() < ECHO_VIEW and nav.clear_line(t_pos.x, t_pos.z, q.x, q.z)
					shows[k] = 2 if in_view else 1
				if shows[k] == 2:
					picks.append(float(tr[j].t))
					break
		j += 4
	return picks.pick_random() if not picks.is_empty() else -1.0

## One frame of the act: walk the route, or stop and look back at someone watching from close by
func _echo_step(delta: float, t: float) -> void:
	var pos := body.global_position
	var dx := t_pos.x - pos.x
	var dz := t_pos.z - pos.z
	var dist := Vector2(dx, dz).length()
	var seen: bool = dist < 45.0 and view_dot(pos.x, pos.z) > VIEW_CONE and nav.clear_line(t_pos.x, t_pos.z, pos.x, pos.z)
	# someone walks right up to it: it runs
	if dist < BOLT_DIST:
		mode = "flee"
		flee_until = t + 2.0 + rng.randf()
		speed = maxf(speed, 2.0)
		return
	# watched from close by: after a moment, like anyone, it stops and looks back
	if mode == "echo":
		if seen and dist < NOTICE_DIST and t >= notice_ready:
			if react_at == 0.0:
				react_at = t + rng.randf_range(NOTICE_REACT.x, NOTICE_REACT.y)
			elif t >= react_at:
				mode = "notice"
				react_at = 0.0
				notice_until = t + rng.randf_range(NOTICE_HOLD.x, NOTICE_HOLD.y)
				notice_ready = t + NOTICE_COOLDOWN
				if disguise_id != 0 and rng.randf() < 0.6:
					_talk(t)                        # and says something, in their voice
		else:
			react_at = 0.0
	var ended := false
	if mode == "notice":
		speed = 0.0
		body_yaw = lerp_angle(body_yaw, atan2(dx, dz), minf(1.0, delta * 5.0))
		pitch = lerpf(pitch, 0.0, minf(1.0, delta * 5.0))
		if t >= notice_until:
			# it has your attention: now it wants you to follow. Or it just carries on where it left off
			if not (rng.randf() < LURE_CHANCE and _plan_lure(t)):
				mode = "echo"
	else:
		play_t += delta
		var st := echo.sample(echo.track(echo_src), play_t)
		if st.is_empty():
			_vanish()
			return
		body.global_position = st.p
		body_yaw = lerp_angle(body_yaw, st.h, minf(1.0, delta * 12.0))
		pitch = st.pitch
		crouch = st.crouch
		torch_on = st.torch
		speed = st.speed
		ended = st.end                              # their route stops here (for now): it stands
	body.rotation.y = body_yaw
	if disguise_id != 0 and mode == "echo" and dist > VOICE_MIN_DIST and dist < VOICE_MAX_DIST and t >= _next_voice:
		_talk(t)
	# it goes when nobody is looking, never in front of anyone
	if (t >= seg_end or ended) and not _seen_by_anyone(body.global_position):
		_vanish()
		return
	_animate()

# ================================================================= the lure
func _acting() -> bool:
	return mode == "echo" or mode == "notice" or mode == "lure" or mode == "wander"

## Somewhere to lead you, and the way there (breadth-first over the grid, gridnav.gd): a dead end (the
## lights go when you get there), the far side of a pit (it walks straight over the hole; follow it and
## you go in), or the halls just short of where the Bacteria roams (it gives you away there). False
## when there is nowhere to take you from here.
func _plan_lure(t: float) -> bool:
	var here := body.global_position
	var sc := Vector2i(GridNav.cell(here.x), GridNav.cell(here.z))
	var n: int = nav.n
	var field := PackedInt32Array()
	field.resize(n * n)
	if not nav.bfs(sc.x, sc.y, field):
		return false
	var tc := Vector2(GridNav.cell(t_pos.x), GridNav.cell(t_pos.z))
	var mine := Vector2(sc).distance_to(tc)
	var dead_ends: Array = []
	var pits: Array = []
	for x in n:
		for z in n:
			var d := field[x * n + z]
			if d < LURE_CELLS.x or d > LURE_CELLS.y or _open_ways(x, z) != 1:
				continue
			if Vector2(x, z).distance_to(tc) > mine:        # it leads you away from where you are
				dead_ends.append(Vector2i(x, z))
	for c in level.pits:
		for o in GridNav.NEIGHBOURS:
			var a: Vector2i = c - o
			var b: Vector2i = c + o
			if nav.blocked(a.x, a.y) or nav.blocked(b.x, b.y):
				continue
			var d := field[a.x * n + a.y]
			if d >= 2 and d <= LURE_CELLS.y:
				pits.append([a, c, b])
	var bait := Vector2i(-1, -1)
	var ent := _bacteria()
	if ent != null:
		var ec := Vector2i(GridNav.cell(ent.global_position.x), GridNav.cell(ent.global_position.z))
		if ec.x >= 0 and ec.y >= 0 and ec.x < n and ec.y < n:
			var d := field[ec.x * n + ec.y]
			if d >= LURE_BAIT_SHORT + 3 and d <= 22:
				bait = ec
	var kinds: Array = []
	var weights: Array = []
	if not dead_ends.is_empty(): kinds.append("dead_end"); weights.append(1.0)
	if not pits.is_empty(): kinds.append("pit"); weights.append(1.2)
	if bait.x >= 0: kinds.append("bacteria"); weights.append(1.5)
	if kinds.is_empty():
		return false
	var kind: String = kinds[rng.rand_weighted(PackedFloat32Array(weights))]
	var cells: Array
	var extra: Array = []
	match kind:
		"dead_end":
			cells = _path(field, dead_ends.pick_random())
		"pit":
			var pick: Array = pits.pick_random()
			cells = _path(field, pick[0])
			extra = [_cell_pos(pick[1]), _cell_pos(pick[2])]    # straight over the hole, and out the far side
		"bacteria":
			cells = _path(field, bait)
			cells = cells.slice(0, maxi(2, cells.size() - LURE_BAIT_SHORT))
	lure_path = []
	for i in range(1, cells.size()):
		lure_path.append(_cell_pos(cells[i]))
	lure_path.append_array(extra)
	if lure_path.is_empty():
		return false
	lure_kind = kind
	lure_i = 0
	_route_mode = ""
	lure_from = here
	lure_walked = 0.0
	lure_spoke = false
	mode = "lure"
	_lure_stop(t)                                   # it starts by standing there, looking at you
	return true

## Ways out of a cell (1: a dead end)
func _open_ways(x: int, z: int) -> int:
	if nav.blocked(x, z):
		return 0
	var k := 0
	for o in GridNav.NEIGHBOURS:
		if nav.can_step(x, z, x + o.x, z + o.y):
			k += 1
	return k

## The cells from here to `goal` down a breadth-first field (nav.bfs), here first
func _path(field: PackedInt32Array, goal: Vector2i) -> Array:
	var n: int = nav.n
	var out: Array = [goal]
	var cur := goal
	var d := field[cur.x * n + cur.y]
	while d > 0:
		var stepped := false
		for o in GridNav.NEIGHBOURS:
			var p: Vector2i = cur + o
			if p.x < 0 or p.y < 0 or p.x >= n or p.y >= n:
				continue
			if field[p.x * n + p.y] == d - 1 and nav.can_step(p.x, p.y, cur.x, cur.y):
				cur = p
				stepped = true
				break
		if not stepped:
			break
		d -= 1
		out.push_front(cur)
	return out

func _cell_pos(c: Vector2i) -> Vector3:
	return Vector3(c.x * GridNav.CELL, body.global_position.y, c.y * GridNav.CELL)

func _bacteria() -> Node3D:
	var ent: Node3D = get_parent().get_node_or_null("Entity")
	if ent == null or ent.process_mode == Node.PROCESS_MODE_DISABLED or not ent.is_visible_in_tree():
		return null
	var st: String = ent.get("state") if ent.get("state") != null else ""
	return ent if st == "roam" or st == "investigate" or st == "search" or st == "lurk" else null

## Stop and look back, and wait for them to come
func _lure_stop(t: float) -> void:
	lure_state = "wait"
	lure_go_at = 0.0
	lure_patience_until = t + rng.randf_range(LURE_PATIENCE.x, LURE_PATIENCE.y)
	# in co-op, this is when it calls out in their teammate's voice
	if disguise_id != 0 and (not lure_spoke or rng.randf() < 0.4):
		lure_spoke = true
		_talk(t)

## Walk the path at `sp`; true when it reached a waypoint this frame (lure_i has moved on)
func _walk_path(delta: float, sp: float) -> bool:
	if lure_i >= lure_path.size():
		speed = 0.0
		return false
	var pos := body.global_position
	var wp: Vector3 = lure_path[lure_i]
	var to := Vector2(wp.x - pos.x, wp.z - pos.z)
	var stride := sp * delta
	speed = sp
	if to.length() <= stride:
		lure_walked += to.length()
		lure_from = Vector3(wp.x, pos.y, wp.z)
		body.global_position = lure_from
		lure_i += 1
		return true
	var dir := to / to.length()
	body.global_position = Vector3(pos.x + dir.x * stride, pos.y, pos.z + dir.y * stride)
	lure_walked += stride
	body_yaw = lerp_angle(body_yaw, atan2(dir.x, dir.y), minf(1.0, delta * 8.0))
	return false

## Does the path turn at the waypoint it just reached?
func _turns_here() -> bool:
	if lure_i <= 0 or lure_i >= lure_path.size():
		return false
	var a: Vector3 = lure_path[lure_i - 2] if lure_i >= 2 else lure_from
	var b: Vector3 = lure_path[lure_i - 1]
	var c: Vector3 = lure_path[lure_i]
	var d1 := Vector2(b.x - a.x, b.z - a.z).normalized()
	var d2 := Vector2(c.x - b.x, c.z - b.z).normalized()
	return d1.dot(d2) < 0.5

## One frame of leading: walk on, stop at corners and look back, wait for you, give up if you don't come
func _lure_step(delta: float, t: float) -> void:
	var pos := body.global_position
	var dx := t_pos.x - pos.x
	var dz := t_pos.z - pos.z
	var dist := Vector2(dx, dz).length()
	var following: bool = dist < LURE_FOLLOW and nav.clear_line(t_pos.x, t_pos.z, pos.x, pos.z)
	if dist < LURE_BOLT and lure_kind != "pit":
		mode = "flee"                               # you caught up with it: it runs
		flee_until = t + 2.0 + rng.randf()
		speed = maxf(speed, 2.0)
		return
	match lure_state:
		"walk":
			var hurry := dist < LURE_LEAD
			if _walk_path(delta, LURE_HURRY if hurry else LURE_SPEED):
				if lure_i >= lure_path.size():
					_lure_arrive(t)
				elif not hurry and (_turns_here() or lure_walked >= LURE_STOP_EVERY):
					_lure_stop(t)
			elif lure_i >= lure_path.size():
				_lure_arrive(t)
		"wait":
			speed = 0.0
			body_yaw = lerp_angle(body_yaw, atan2(dx, dz), minf(1.0, delta * 5.0))     # looking back at you
			if following:
				if lure_go_at == 0.0:
					lure_go_at = t + rng.randf_range(LURE_WAIT.x, LURE_WAIT.y)
				if t >= lure_go_at or dist < LURE_LEAD:
					lure_state = "walk"
					lure_walked = 0.0
			elif t >= lure_patience_until:
				_start_wander(t)                    # you didn't come: it gives up on you
				return
		"arrived":
			_lure_arrived_step(delta, t, dist, following)
			if mode != "lure":
				return
	body.rotation.y = body_yaw
	_animate()

## It got where it was taking you
func _lure_arrive(t: float) -> void:
	lure_state = "arrived"
	speed = 0.0
	lure_patience_until = t + rng.randf_range(LURE_PATIENCE.x, LURE_PATIENCE.y) * 1.5
	if lure_kind == "bacteria":
		# right where it roams: it makes a noise for it, and slips off, leaving you there
		var ent := _bacteria()
		if ent != null and ent.has_method("hear"):
			ent.hear(body.global_position, LURE_HEAR)
		_start_wander(t)
	elif lure_kind == "pit" and disguise_id != 0:
		_talk(t)                                    # across the hole: come here

func _lure_arrived_step(delta: float, t: float, dist: float, following: bool) -> void:
	speed = 0.0
	match lure_kind:
		"dead_end":
			# it stands at the end with its back to you. Come up behind it and the lights go
			if following and dist < 8.0 and _power_cut():
				return                              # the grid is going down: next frame it charges
			if dist < 8.0:
				body_yaw = lerp_angle(body_yaw, atan2(t_pos.x - body.global_position.x, t_pos.z - body.global_position.z), minf(1.0, delta * 0.8))
		"pit":
			body_yaw = lerp_angle(body_yaw, atan2(t_pos.x - body.global_position.x, t_pos.z - body.global_position.z), minf(1.0, delta * 5.0))
			if t_pos.y < body.global_position.y - 3.0:
				if not _seen_by_anyone(body.global_position):
					_vanish()                       # you went in: it was never there
				return
	if not following and t >= lure_patience_until:
		_start_wander(t)
	elif following and dist < LURE_LEAD and lure_kind != "dead_end":
		_start_wander(t)                            # you came round it: nothing more to do here

## A dead end's payoff: the power goes (the events' own power cut, so co-op gets it too), unless one
## went too recently
func _power_cut() -> bool:
	var ev: Node = get_parent().get_node_or_null("Events")
	if ev == null or player.grid_down or ev.process_mode == Node.PROCESS_MODE_DISABLED:
		return false
	var last: float = ev.history.get("powerCut", -INF)
	if Game.time - last < LURE_CUT_GAP:
		return false
	return ev.run_event("powerCut")

## It gives up on you (or is done with you): it walks off somewhere else, and goes once nobody sees it
func _start_wander(t: float) -> void:
	mode = "wander"
	_route_mode = ""
	wander_start = t
	lure_path = []
	lure_i = 0
	var here := body.global_position
	var sc := Vector2i(GridNav.cell(here.x), GridNav.cell(here.z))
	var n: int = nav.n
	var field := PackedInt32Array()
	field.resize(n * n)
	if not nav.bfs(sc.x, sc.y, field):
		return
	var tc := Vector2(GridNav.cell(t_pos.x), GridNav.cell(t_pos.z))
	var picks: Array = []
	for x in n:
		for z in n:
			var d := field[x * n + z]
			if d >= 5 and d <= 12 and Vector2(x, z).distance_to(tc) > Vector2(sc).distance_to(tc):
				picks.append(Vector2i(x, z))
	if picks.is_empty():
		return
	var cells := _path(field, picks.pick_random())
	for i in range(1, cells.size()):
		lure_path.append(_cell_pos(cells[i]))
	lure_from = here

func _wander_step(delta: float, t: float) -> void:
	var pos := body.global_position
	var dist := Vector2(t_pos.x - pos.x, t_pos.z - pos.z).length()
	if dist < LURE_BOLT:
		mode = "flee"
		flee_until = t + 2.0
		return
	_walk_path(delta, LURE_SPEED)
	if lure_i >= lure_path.size():
		body_yaw += delta * 0.4                     # at the end of the way: it stands and looks about
	if t - wander_start > 2.0 and not _seen_by_anyone(body.global_position):
		_vanish()
		return
	body.rotation.y = body_yaw
	_animate()

## Leaving: somewhere 3-14 cells' walk away, out of its target's sight, preferring places further from
## them than from it; the real way there. If the only way out is past them, it walks past them, as a
## person would. Nothing reachable: lure_path stays empty and it stands its ground.
func _plan_leave() -> void:
	_route_mode = "flee"
	lure_path = []
	lure_i = 0
	var here := body.global_position
	var n: int = nav.n
	var mine := PackedInt32Array()
	mine.resize(n * n)
	if not nav.bfs(GridNav.cell(here.x), GridNav.cell(here.z), mine):
		return
	var yours := PackedInt32Array()
	yours.resize(n * n)
	var have_yours: bool = nav.bfs(GridNav.cell(t_pos.x), GridNav.cell(t_pos.z), yours)
	var best: Array = []
	for x in n:
		for z in n:
			var d := mine[x * n + z]
			if d < 3 or d > 14:
				continue
			var p := Vector3(x * GridNav.CELL, here.y, z * GridNav.CELL)
			if nav.clear_line(t_pos.x, t_pos.z, p.x, p.z):
				continue                            # still in your sight from there
			var dy: int = yours[x * n + z] if have_yours else d
			best.append([float((dy if dy >= 0 else 99) - d) + rng.randf(), Vector2i(x, z)])
	if best.is_empty():
		return
	best.sort_custom(func(a, b): return a[0] > b[0])
	var cells := _path(mine, best[rng.randi_range(0, mini(4, best.size() - 1))][1])
	for i in range(1, cells.size()):
		lure_path.append(_cell_pos(cells[i]))
	lure_from = here

## The way to `p` through the halls (blackout approach)
func _route_to(p: Vector3) -> void:
	_route_mode = "charge"
	lure_path = []
	lure_i = 0
	var here := body.global_position
	var n: int = nav.n
	var mine := PackedInt32Array()
	mine.resize(n * n)
	var goal := Vector2i(GridNav.cell(p.x), GridNav.cell(p.z))
	if not nav.bfs(GridNav.cell(here.x), GridNav.cell(here.z), mine) or goal.x < 0 or goal.y < 0 \
			or goal.x >= n or goal.y >= n or mine[goal.x * n + goal.y] < 0:
		return
	var cells := _path(mine, goal)
	for i in range(1, cells.size()):
		lure_path.append(_cell_pos(cells[i]))
	lure_from = here

## Is the survivor it is after holding a lit torch?
func _target_torch() -> bool:
	for s in Net.survivors():
		if s.id == t_id:
			var n: Node = s.node
			return (n.flash_on and n.battery > 0.0) if s.local else bool(n.torch_on)
	return false

## Could anyone see a body standing at `p` right now? (close behind you counts: you would hear it)
func _seen_by_anyone(p: Vector3) -> bool:
	for s in Net.survivors():
		var d := Vector2(p.x - s.pos.x, p.z - s.pos.z)
		var l := d.length()
		if l < 4.0:
			return true
		var f: Vector3 = s.fwd
		if l < 45.0 and (f.x * d.x + f.z * d.y) / l > VIEW_CONE - 0.15 and nav.clear_line(s.pos.x, s.pos.z, p.x, p.z):
			return true
	return false

## Gone, unseen; it walks again after a while
func _vanish() -> void:
	spawned = false
	_route_mode = ""
	body.visible = false
	mode = "echo"
	speed = 0.0
	echo_src = -1
	disguise_id = 0
	wait = rng.randf_range(ECHO_REST.x, ECHO_REST.y)

func _talk(t: float) -> void:
	_next_voice = t + rng.randf_range(VOICE_GAP.x, VOICE_GAP.y)
	voice_n += 1

# ================================================================= the disguise
## Host, for a charge: a survivor to pretend to be. Never the one it hunts (they would know it isn't
## them); a random other one who is in the game. 0 when there is nobody else (and always, offline).
## (Walking a route, it wears the face of whoever walked it: _begin_echo.)
func _pick_disguise() -> int:
	if not Net.is_online():
		return 0
	var ids: Array = []
	for s in Net.survivors():
		if s.id != t_id:
			ids.append(s.id)
	return ids.pick_random() if not ids.is_empty() else 0

## Every machine: wear the face the host chose, unless it is this player's own, then another
## survivor's (a face you would believe: you can't be over there), or none. Speak when the host says.
func _update_disguise() -> void:
	if tag == null:
		return                                  # the suit's model never loaded: nothing to dress up
	var want := 0
	if Net.is_online() and spawned and disguise_id != 0:
		var me := multiplayer.get_unique_id()
		if disguise_id != me and Net.remotes.has(disguise_id):
			want = disguise_id
		else:
			for id in Net.remotes:
				if id != me and is_instance_valid(Net.remotes[id]) and not Net.remotes[id].dead:
					want = id
					break
	if want != shown_id:
		shown_id = want
		_wear(want)
	if voice_n != _voice_heard:
		_voice_heard = voice_n
		if shown_id != 0:
			_say(Voice.clip_of(shown_id))
	if tag.visible:
		# the tag goes green while it "talks", like a survivor's on voice chat
		tag.modulate = Color(0.55, 1.0, 0.6) if mouth.playing else Color(0.94, 0.91, 0.75)
	_present()

## The torch and the tag, as a survivor's: the torch on where the route had it on (or while it wears
## a face in a charge), pitched where it looks; the tag lower when it crouches. Alone, it even clicks
## its torch where you clicked yours (a survivor's switch makes no sound over the net, so in co-op it
## keeps quiet too).
func _present() -> void:
	var acting := _acting()
	if mouth.playing:
		_update_mouth(get_physics_process_delta_time())
	torch.visible = spawned and (torch_on if acting else true)      # in the dark a survivor has theirs on
	torch.rotation = Vector3(pitch, PI, 0.0)
	tag.position.y = 1.75 if crouch else 2.25
	if acting and spawned and torch_on != _torch_was and not Net.is_online() and body.is_visible_in_tree():
		clicker.stream = player.click_on if torch_on else player.click_off     # your own switch
		clicker.play()
	_torch_was = torch_on

## Take `id`'s colour and name tag (0: back to the plain suit, no tag, no torch)
func _wear(id: int) -> void:
	var tint := Color.WHITE
	if id != 0:
		tint = Color.WHITE.lerp(Net.PEER_COLORS[id % Net.PEER_COLORS.size()], 0.3)
		tag.text = Net.label_for(id)
	for e in _tint_mats:
		(e[0] as StandardMaterial3D).albedo_color = (e[1] as Color) * tint
	tag.visible = id != 0

## Play one of their lines back from where it stands, as their voice would come over voice chat. Not
## while you have everyone muted (deafened): you would hear it and nobody else, a giveaway.
func _say(samples: PackedFloat32Array) -> void:
	if samples.is_empty() or Voice.deafened:
		return                                  # nothing of theirs worth repeating, or you can't hear anyone
	var pcm := PackedByteArray()
	pcm.resize(samples.size() * 2)
	for i in samples.size():
		pcm.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 16000
	wav.stereo = false
	wav.data = pcm
	mouth.stream = wav
	_mouth_cut = VoiceSpeaker.OPEN_CUTOFF
	_mouth_db = 0.0
	_update_mouth(1.0)
	mouth.play()

## The walls between you and it, as voice_speaker.gd does for a survivor: every metre of wall pulls the
## two low-passes down and the level with them; and the level that survivor's voice is set to here.
func _update_mouth(dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	mouth.position.y = VoiceSpeaker.HEAD_HEIGHT * (0.7 if crouch else 1.0)
	var wall_m := Voice.wall_thickness(cam.global_position, mouth.global_position)
	var cut_t := clampf(VoiceSpeaker.OPEN_CUTOFF * exp(-VoiceSpeaker.MUFFLE_PER_M * wall_m), VoiceSpeaker.MIN_CUTOFF, VoiceSpeaker.OPEN_CUTOFF)
	var k := minf(1.0, dt * 9.0)
	_mouth_cut = exp(lerpf(log(_mouth_cut), log(cut_t), k))
	_mouth_db = lerpf(_mouth_db, -minf(wall_m * VoiceSpeaker.DB_PER_M, VoiceSpeaker.MAX_WALL_DB), k)
	var bi := AudioServer.get_bus_index(MOUTH_BUS)
	if bi >= 0:
		for e in 2:
			(AudioServer.get_bus_effect(bi, e) as AudioEffectLowPassFilter).cutoff_hz = _mouth_cut
		AudioServer.set_bus_volume_db(bi, _mouth_db)
	var sp = Voice.speakers.get(shown_id)
	var own: float = sp.volume if sp != null and is_instance_valid(sp) else 1.0
	mouth.volume_db = linear_to_db(maxf(Voice.voice_volume * own, 0.0001))

## Its body, as a survivor's (survivor_anim.gd): the same clips at the same speeds, crouching where the
## route crouched. It never stands wrong: nothing in how it moves gives it away.
func _animate() -> void:
	if anim == null or _clips.is_empty():
		return
	var want := SurvivorAnim.pick_role(_clips, _role, speed, speed > SurvivorAnim.SPRINT_ABOVE, crouch, false)
	if want == "":
		return
	if want != _role or not anim.is_playing():
		_role = want
		anim.play(_clips[want], SurvivorAnim.FADE)
	anim.speed_scale = SurvivorAnim.speed_scale(want, speed)

func hit_player() -> void:
	if player.dead or player.frozen or Game.god_mode:
		return
	player.health = maxf(0.0, player.health - HIT_DAMAGE)
	player.frozen = true
	Game.add_glitch(1.0)
	scares.gasp()
	if player.health <= 0.0:
		Game.kill_player("A SURVIVOR")    # the death plays the hit itself: don't stack a second one
		return
	scares.startle(0.9)
	scares.play_scare("staticHit", 1.0)
	get_tree().create_timer(HIT_STUN).timeout.connect(func():
		if not Game.dead:
			player.frozen = false)

# ================================================================= frame
func _physics_process(delta: float) -> void:
	if Game.freeze_ai:
		return
	var online := Net.is_online()
	puppet = online and not Net.hosting
	if not online and (not Game.playing or Game.dead):
		return
	if puppet:
		_puppet_step(delta)
	else:
		update_peer(delta)
		if online:
			_net_send(delta)
	_update_disguise()

# ================================================================= co-op
func _net_send(delta: float) -> void:
	_net_t -= delta
	if _net_t > 0.0:
		return
	_net_t = 0.05
	var p := body.global_position
	Net.send_mm([p.x, p.y, p.z, body_yaw, speed, spawned, maxi(0, MODES.find(mode)), disguise_id, voice_n, crouch, torch_on, pitch])

func net_apply(t: float, m: Array) -> void:
	net_buf.send_interval = 0.05
	net_buf.push(t, {"pos": Vector3(m[0], m[1], m[2]), "yaw": float(m[3]), "speed": float(m[4]), "m": m})

# Guest: the host's Mimic, drawn smoothly, with its own footfalls and the heartbeat for THIS player
func _puppet_step(delta: float) -> void:
	var st: Dictionary = net_buf.sample(delta)
	if st.is_empty():
		return
	var m: Array = st.m
	spawned = m[5]
	body.visible = spawned
	if m.size() >= 9:
		disguise_id = int(m[7])
		voice_n = int(m[8])
	if m.size() >= 12:
		crouch = bool(m[9])
		torch_on = bool(m[10])
		pitch = float(m[11])
	if not spawned:
		return
	mode = MODES[clampi(int(m[6]), 0, MODES.size() - 1)]
	speed = st.speed
	body.global_position = st.pos
	body_yaw = st.yaw
	body.rotation.y = body_yaw
	var pos := body.global_position
	var lp := player.global_position
	var ldist := Vector2(lp.x - pos.x, lp.z - pos.z).length()
	# walking a route it passes for a survivor: your heart has no reason to race (only once it runs or charges)
	if Game.heart != null and Game.playing and not player.dead and not _acting():
		var near := clampf(1.0 - ldist / 12.0, 0.0, 1.0)
		Game.heart.feed("mimic", 0.9 if mode == "charge" else 0.2 + 0.5 * clampf(1.0 - ldist / 25.0, 0.0, 1.0), 3.0 * near * near)
	footsteps(delta, ldist)
	_animate()

func _unhandled_input(e: InputEvent) -> void:
	if not Game.dev_keys or not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.physical_keycode == KEY_F5:
		toggle_session()

# ---------------------------------------------------------------- debug console
func debug_active() -> bool:
	return session

func debug_despawn() -> void:
	session = false
	spawned = false
	body.visible = false

func debug_spawn() -> bool:
	session = true
	if not spawned:
		wait = 0.1
	return true
