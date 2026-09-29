extends "res://scripts/Entities/bacteria/bacteria_stalk.gd"
## THE BACTERIA (the Howler). Port of js/game/entity.js.
##
## AI: roam -> investigate (noise / glimpse) -> screech (first sighting) -> chase -> search (lost you);
## stunned when shot, blinded by a camera flash (flashed: get out of its sight before its eyes clear
## and it has lost you); stalk (peeks from behind a corner) -> flee when you look at it or come close;
## lurk (lost you: it waits in silence where you were heading and springs when you walk into it).
## Senses: bacteria_senses.gd. Body and gait: bacteria_rig.gd. The kill: bacteria_grab.gd.
##
## You can hear it before you see it: a wet, growling breath (creature_voice.gd) that quickens in a
## chase, and the tubes stutter and buzz as it runs underneath them.
##
## Dev keys: F10 summon it in front of you, F4 send it to stalk you.

const BacteriaRig := preload("res://scripts/Entities/bacteria/bacteria_rig.gd")
const BacteriaGrab := preload("res://scripts/Entities/bacteria/bacteria_grab.gd")
const BacteriaNet := preload("res://scripts/Entities/bacteria/bacteria_net.gd")
const BREATH_RANGE := 16.0            # metres: how far off you can hear it breathing
const DISTURB_RADIUS := 8.0           # the tubes within this of it stutter while it hunts

var puppet := false                   # co-op: this copy only follows the host
var net: BacteriaNet
var grab: BacteriaGrab                # the grab-and-eat kill sequence
var search_left := 0.0
var stare_cooldown := 5.0
var last_pos := Vector3.ZERO
var stuck_timer := 0.0
var fear_timer := 0.0
var far_timer := 0.0
var think_timer := 0.0
var voice_state := ""
var voice_timer := 3.0
var occl_timer := 0.0
var static_timer := 0.0
var disturb_timer := 0.0
var blinded := false                  # this stun is a camera flash: coming to, it may have lost you

# The camera flash (scripts/Player/flash_tool.gd)
const FLASH_RANGE := 16.0             # m: further off it is just a light going off somewhere
const FLASH_CONE := 0.6               # cos: how near the middle of the frame it has to be
const FLASH_BLIND := 4.5              # s it reels, blind
const FLASH_REACQUIRE := 12.0         # m: still in plain sight this close when its eyes clear, it's back on you
const FLASH_POP := 14.0               # m: how far the pop carries (a flash that misses gives you away)

# Face it up close and you flinch (player.flinch(): the torch arm jerks up across your face). Once per
# encounter: it has to be out of reach or out of your sight for FLINCH_REARM before it happens again.
const FLINCH_RANGE := 4.5             # m
const FLINCH_CONE := 0.8              # cos: how near the middle of your view it has to be
const FLINCH_REARM := 4.0             # s
var flinch_armed := true
var flinch_away := 0.0

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	_setup_nav()
	var sp := _spawn_cell()
	global_position = Vector3(sp[0] * CELL, 0.0, sp[1] * CELL)
	_build_model()
	grab = BacteriaGrab.new(self)
	net = BacteriaNet.new(self)
	set_goal(global_position.x, global_position.z)
	pick_spot(3, 18)

# ================================================================= model
# The body and its procedural animation live in bacteria_rig.gd; its footfalls come back here as sound
func _build_model() -> void:
	rig = BacteriaRig.new()
	add_child(rig)
	rig.build(self, MODEL_HEIGHT)
	rig.stepped.connect(_on_step)

# A footfall from the rig's gait: heavy and near when it hunts, a faint creep when it stalks
func _on_step(weight: float, dragging: bool, run: float) -> void:
	var d := global_position.distance_to(player.global_position)
	if d < 70.0:
		scares.howler_step(global_position, weight * LOUDNESS, dragging, run)
	if player.dead:
		return
	# the floor carries its weight: near enough, you feel every step come down. Further and harder the
	# faster it moves; the short dragged leg lands lighter. Walking past at a distance it's a faint tremor,
	# bearing down on you in a chase the view jolts and rumbles with each one.
	var reach := 10.0 + 8.0 * run
	if d < reach:
		var k := (1.0 - d / reach) * (1.0 - d / reach)
		var hit := k * (0.35 + 0.65 * run) * (0.55 if dragging else 1.0) * clampf(weight, 0.2, 1.6)
		player.jolt(hit * 1.3)
		player.quake(hit)
		if state == "chase":
			Game.fx_shock = maxf(Game.fx_shock, 0.12 * k)
		# the tubes overhead rattle in their housings: a hard step close by and they stutter
		if hit > 0.25 and level.has_method("disturb"):
			level.disturb(global_position, 4.0 + 3.0 * run, clampf(hit * 0.3, 0.0, 0.35))

# ================================================================= its voice, its breath
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
# Lying in wait it makes no sound at all.
func vocalize(delta: float, st: String) -> void:
	update_occlusion(delta)
	var pos := global_position + Vector3(0, 2.0, 0)
	scares.entity_move(pos)
	var d := INF if player.dead else pos.distance_to(player.global_position)
	if st != voice_state:
		var was := voice_state
		voice_state = st
		if st == "screech" or (st == "chase" and was != "screech"):
			scares.entity_call("scream", pos, true)
			scares.startle(0.7 if was == "lurk" else 0.4)      # out of the dark beside you: much worse
			_screech_fx(d)
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

# It has seen you: the tubes over it stutter, and close enough your own torch falters
func _screech_fx(d: float) -> void:
	if level.has_method("disturb"):
		level.disturb(global_position, DISTURB_RADIUS * 1.6, 1.0)
	if d < 25.0 and not player.dead:
		player.trigger_flicker(0.5 + 0.6 * (1.0 - d / 25.0))
		Game.add_glitch(0.35)

# Its breath: slow and wet while it wanders, held low while it stalks or waits, ragged in a chase
func _breathe() -> void:
	var d := INF if player.dead else global_position.distance_to(player.global_position)
	var lvl := 0.55
	var pitch := 1.0
	match state:
		"chase", "screech":
			lvl = 1.0; pitch = 1.3
		"flee":
			lvl = 0.7; pitch = 1.4
		"stunned":
			lvl = 0.9; pitch = 1.1
		"stalk":
			lvl = 0.35; pitch = 0.85
		"lurk":
			lvl = 0.25 if lurk_waiting else 0.4; pitch = 0.8
	if grab.active():
		lvl = 1.2; pitch = 1.15
	var near := clampf(1.0 - d / BREATH_RANGE, 0.0, 1.0)
	scares.entity_breathe(lvl * pow(near, 1.2), pitch)

# Running the corridors after you, it sets the tubes it passes under stuttering
func _disturb_lights(delta: float) -> void:
	disturb_timer -= delta
	if disturb_timer > 0.0:
		return
	disturb_timer = 0.45
	if hunting() and speed_now > 2.0 and level.has_method("disturb"):
		level.disturb(global_position, DISTURB_RADIUS, 0.55)

# ================================================================= the brain
# It lost you: stop chasing, catch its breath, and wander off toward where you were heading. Or, as
# often as not, go there and wait for you.
func give_up() -> void:
	far_timer = 0.0
	winded = WINDED_TIME
	awareness = 0.0
	enraged = 0.0
	var guess := Vector3(last_known.x + last_vel.x * 2.0, 0.0, last_known.z + last_vel.z * 2.0)
	note_interest(guess.x, guess.z)
	if rng.randf() < LURK_CHANCE and begin_lurk(guess):
		winded = WINDED_TIME * 0.4
		return
	set_state("roam")
	pause = 1.5
	look_yaw = yaw + (-2.0 if rng.randf() < 0.5 else 2.0)
	if not pick_spot(3, 12, interest, 5.0):
		roam_spot(target_pos())

# A survivor it has just fed on (their own machine played the grab): it backs off, it doesn't stand over them
func _fed_on_remote() -> void:
	if not puppet:
		run_away()

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
		"lurk":
			think_lurk(heard)
		"flee":
			if state_time > 8.0 or at_goal(1.2):
				end_flee()
		"screech":
			if state_time > 1.15:
				set_state("chase")
		"chase":
			_think_chase(dt, heard)

	# Being watched: look straight at it from a distance and it stops dead and stares back
	staring = maxf(0.0, staring - dt)
	stare_cooldown -= dt
	if (state == "roam" or state == "search" or state == "investigate") and staring <= 0.0 and stare_cooldown <= 0.0 and not tgt.dead:
		var dx: float = p.x - tgt.pos.x
		var dz: float = p.z - tgt.pos.z
		var d2 := Vector2(dx, dz).length()
		if d2 > 5.0 and d2 < 26.0 and looking_at_me(0.95) and nav.clear_line(p.x, p.z, tgt.pos.x, tgt.pos.z):
			staring = 1.6 + rng.randf() * 1.8
			stare_cooldown = 10.0 + rng.randf() * 8.0
			pause = staring
			look_yaw = atan2(-dx, -dz)

	# arrival / idle behaviour for the wandering states
	var arrived := at_goal()
	if state == "roam" and arrived and pause <= 0.0:
		pause = 1.0 + rng.randf() * 2.5
		look_yaw = yaw + (rng.randf() - 0.5) * 2.5
		if not roam_spot(target_pos()) and not pick_spot(5, 18):
			pick_spot(1, 60)
	elif state == "investigate" and arrived and pause <= 0.0:
		set_state("search")
		search_left = SEARCH_TIME * 0.5
		pause = 2.2
		look_yaw = yaw + (-1.3 if rng.randf() < 0.5 else 1.3)
	elif state == "search":
		search_left -= dt
		if search_left <= 0.0:
			set_state("roam")
			roam_spot(target_pos())
		elif arrived and pause <= 0.0:
			pause = 1.0 + rng.randf() * 1.5
			look_yaw = yaw + (rng.randf() - 0.5) * 3.0
			if not pick_spot(1, 6, last_known, 4.0):
				pick_spot(1, 8)

func _think_chase(dt: float, heard) -> void:
	if seen_target:
		set_goal(tgt.pos.x, tgt.pos.z)
		since_encounter = 0.0
		if distance_to_target() < LUNGE_RANGE and lunge <= 0.0 and lunge_windup <= 0.0:
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
			return
	# outrun: far behind for a while and it gives up on its own
	if distance_to_target() > GIVE_UP_DISTANCE:
		far_timer += dt
		if far_timer > GIVE_UP_TIME:
			give_up()
	else:
		far_timer = 0.0

# ================================================================= movement
func _state_speed() -> float:
	match state:
		"chase": return CHASE_SPEED
		"investigate", "stalk": return INVESTIGATE_SPEED
		"search": return SEARCH_SPEED
		"flee": return FLEE_SPEED
		"lurk": return 0.0 if lurk_waiting else LURK_SPEED
	return ROAM_SPEED

func move(delta: float) -> void:
	var speed := 0.0
	var dir := Vector3.ZERO
	var p := global_position
	if pause > 0.0:
		pause -= delta
		if not is_nan(look_yaw):
			turn_toward(look_yaw, 2.0, delta)
	elif state == "stalk" and stalk_phase == "peek" and stalk_active:
		# turned half toward them, half along the wall to its edge, it eases out past the edge in quick
		# shuffles (the rig leans it the rest of the way), and darts back behind it when it ducks away
		var to_t := Vector2(tgt.pos.x - p.x, tgt.pos.z - p.z).normalized()
		turn_toward(atan2(to_t.x + stalk_side.x, to_t.y + stalk_side.z), 3.0, delta)
		var spot := stalk_hide.lerp(stalk_peek, peek_amt)
		dir = Vector3(spot.x - p.x, 0.0, spot.z - p.z)
		var d := dir.length()
		if d > 0.03:
			speed = minf(3.0 if peek_mode == "hide" else 1.6, d * 5.0)
			dir /= d
	elif state == "screech":
		if seen_target:
			turn_toward(atan2(tgt.pos.x - p.x, tgt.pos.z - p.z), TURN_RATE, delta)
	elif state == "lurk" and lurk_waiting:
		# crouched and still; only the head turns toward what it hears
		if not is_nan(look_yaw):
			turn_toward(look_yaw, 1.2, delta)
	else:
		speed = CHASE_SPEED if enraged > 0.0 else _state_speed()
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
			# folded down under a low ceiling it can't stride out: somewhat slower in there
			var folded: float = rig.squeeze
			speed *= 1.0 - 0.25 * clampf(folded, 0.0, 1.0)
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
			elif state == "lurk":
				lurk_waiting = true                 # can't get there: wait here instead
				state_time = 0.0
			elif state != "chase":
				pick_spot(2, 12)
			goal_key = -1
	else:
		stuck_timer = 0.0

# ================================================================= per frame
func _physics_process(delta: float) -> void:
	var online := Net.is_online()
	puppet = online and not Net.hosting
	# in co-op it keeps hunting even while this player has the menu open: the others are still in the game
	if not Game.playing and not online:
		return
	if online and not puppet:
		net.send(delta)
	if puppet:
		_puppet_step(delta)
		return
	if grab.active():
		grab.update(delta)
		_breathe()
		return
	if not is_finite(global_position.x) or not is_finite(global_position.z):
		relocate()
		vel = Vector3.ZERO
	gather_target()
	if stun_timer > 0.0:
		stun_timer -= delta
		if stun_timer <= 0.0:
			if blinded:
				_come_to()
			else:
				enraged = 6.0
				awareness = 1.0
				set_state("chase")
				set_goal(last_known.x, last_known.z)
		rig.animate(delta, 0.0, "stunned")
		vocalize(delta, "stunned")
		rotation.y = yaw
		update_fear(delta)
		_breathe()
		return
	enraged = maxf(0.0, enraged - delta)
	think_timer -= delta
	if think_timer <= 0.0:
		var dt := 0.1 - think_timer
		think_timer = 0.1
		think(dt)
	move(delta)
	rotation.y = yaw
	rig.animate(delta, speed_now, state)
	_present(delta)

# Everything each machine plays for itself: the voice, the breath, the tubes, your fear
func _present(delta: float) -> void:
	vocalize(delta, state)
	_breathe()
	_disturb_lights(delta)
	update_fear(delta)

# Guest: glide to the host's entity; the fear, sound and the grab still play here, against this player
func _puppet_step(delta: float) -> void:
	if grab.active():
		grab.update(delta)
		_breathe()
		return
	net.step(delta)
	rotation.y = yaw
	speed_now = net.speed
	if net.state != state:
		set_state(net.state)
	state_time += delta
	rig.animate(delta, speed_now, state)
	_present(delta)

# ---------------------------------------------------------------- fear, sanity, the kill
func update_fear(delta: float) -> void:
	if not Game.playing:
		return                       # menu open (co-op): nothing may hurt you from there
	var dist := global_position.distance_to(player.global_position)
	var near: bool = dist < TERROR_DISTANCE and not player.dead
	var hunts := hunting()
	var presence := 0.0 if player.dead else maxf(0.0, 1.0 - dist / 30.0)
	Game.presence += (minf(1.0, presence * (1.3 if hunts else 1.0)) * LOUDNESS - Game.presence) * minf(1.0, delta * 2.0)
	Game.hunted = hunts and dist < 40.0
	player.update_adrenaline(delta, hunts and dist < player.ADR_RANGE)
	# on top of the footstep jolts, a steady tremor while it's actively bearing down on you (quake()'s
	# effect is squared, so this needs to sit well above the footstep hits to read as anything at all)
	if state == "chase":
		player.quake(0.4 + 0.35 * clampf(1.0 - dist / 20.0, 0.0, 1.0))
	var terror := (1.0 - dist / TERROR_DISTANCE) if near else 0.0
	Game.terror = terror
	_check_flinch(delta, dist)
	if near:
		player.sanity = maxf(0.0, player.sanity - 15.0 * terror * delta)
		# while something has hold of you (the mannequin's snap) it owns your heart: no proximity
		# crackle or heartbeat running over its flatline
		static_timer -= delta
		# not while it hides and watches (stalking, lying in wait): it doesn't give itself away
		if static_timer <= 0.0 and not player.frozen and state != "stalk" and state != "lurk":
			scares.entity_static()
			static_timer = 0.12 + rng.randf() * (0.9 - 0.7 * terror)
		# not while something else already has hold of you (the mannequin's snap): it would cut that short
		# and two scripts would fight over the camera
		if player.sanity <= 0.0 and not player.dead and not player.frozen:
			Game.kill_player("PSYCHOLOGICAL COLLAPSE")
	# the heart (heart.gd) does the beating; this only says how scared the entity makes you
	if Game.heart != null and not player.dead:
		var lvl := 0.0
		if near:
			lvl = 0.6 + 0.4 * terror
		elif hunts and dist < 40.0:
			lvl = 0.3 + 0.5 * (1.0 - dist / 40.0)
		elif stalk_active and state == "stalk":
			# being stalked: it builds while it watches you from the corner, worst when it leans out
			lvl = 0.4 + 0.35 * peek_amt
		if lvl > 0.0:
			Game.heart.feed("bacteria", lvl)
	# fear channel for the post shader: terror, sanity and darkness
	var tremor := 0.25 * terror if (near and rng.randf() < 0.2) else 0.0
	var sanity_fear: float = (100.0 - player.sanity) / 100.0 * 0.6
	var dark_fear: float = maxf(0.0, (0.22 - player.light_level) / 0.22) * 0.25
	var psych := minf(0.85, sanity_fear + dark_fear)
	var target_fear := minf(1.0, maxf(maxf(terror * 0.85 + tremor, psych), Game.event_fear))
	Game.fear += (target_fear - Game.fear) * minf(1.0, delta * 6.0)

	# frozen = the mannequin is already snapping your neck, or a survivor's blow has you stunned
	if dist < KILL_DISTANCE and not player.dead and not player.frozen and player.spawn_grace <= 0.0 and not grab.active() and stun_timer <= 0.0:
		grab.start()

# You look straight at it, close, nothing in between: you flinch (see FLINCH_RANGE)
func _check_flinch(delta: float, dist: float) -> void:
	var cam: Camera3D = player.cam
	var eye := cam.global_position
	var p := global_position
	var facing: bool = dist < FLINCH_RANGE and not player.dead and not player.frozen and is_visible_in_tree() \
		and (p + Vector3.UP * 1.2 - eye).normalized().dot(-cam.global_transform.basis.z) > FLINCH_CONE \
		and nav.clear_line(eye.x, eye.z, p.x, p.z)
	if not facing:
		flinch_away += delta
		if flinch_away > FLINCH_REARM:
			flinch_armed = true
		return
	flinch_away = 0.0
	if flinch_armed:
		flinch_armed = false
		player.flinch()

# ================================================================= public API (dev / other systems)
## Guest: the host's latest snapshot (Net._entity)
func net_apply(t: float, m: Array) -> void:
	net.apply(t, m)

## The level editor writes "entity": null when no spawn is placed
func _spawn_cell() -> Array:
	var sp = level.level_data.get("entity")
	return sp if sp is Array and sp.size() >= 2 else [n - 12, 18]

func relocate() -> void:
	var sp := _spawn_cell()
	global_position = Vector3(sp[0] * CELL, 0.0, sp[1] * CELL)
	goal_key = -1
	awareness = 0.0
	lurk_waiting = false
	set_state("roam")
	pick_spot(3, 18)

func summon(x: float, z: float, tx: float, tz: float) -> void:
	global_position = Vector3(x, 0.0, z)
	vel = Vector3.ZERO
	stun_timer = 0.0
	blinded = false
	enraged = 0.0
	yaw = atan2(tx - x, tz - z)
	rotation.y = yaw
	awareness = 1.0
	since_encounter = 0.0
	last_known = Vector3(tx, 0.0, tz)
	last_vel = Vector3.ZERO
	last_seen_time = 0.0
	goal_key = -1
	lurk_waiting = false
	set_goal(tx, tz)
	state = "roam"
	set_state("screech")

func stun(seconds: float, kx: float, kz: float) -> void:
	stun_timer = maxf(stun_timer, seconds)
	global_position += Vector3(kx, 0.0, kz)
	blinded = false
	global_position = nav.resolve(global_position, RADIUS)
	set_state("stunned")
	var l := maxf(Vector2(kx, kz).length(), 0.001)
	last_known = Vector3(global_position.x - kx / l * 8.0, 0.0, global_position.z - kz / l * 8.0)
	last_vel = Vector3.ZERO
	last_seen_time = 0.0
	yaw = atan2(-kx, -kz)

## A camera flash went off at `origin`, aimed along `look` (flash_tool.gd; in co-op the host runs
## this for everyone's flashes). Caught in it (close enough, near the middle of the frame, nothing in
## between) it is blinded for FLASH_BLIND; otherwise it only hears the pop. True when it was blinded.
func flashed(origin: Vector3, look: Vector3) -> bool:
	if puppet or process_mode == Node.PROCESS_MODE_DISABLED or not is_visible_in_tree() or grab.active():
		return false
	var p := global_position
	var to := p + Vector3.UP * 1.6 - origin
	var flat := Vector2(to.x, to.z)
	var d := flat.length()
	var aimed := to.normalized().dot(look) > FLASH_CONE
	var point_blank := d < 2.5 and flat.normalized().dot(Vector2(look.x, look.z).normalized()) > 0.2
	if d > FLASH_RANGE or not (aimed or point_blank) or not nav.clear_line(origin.x, origin.z, p.x, p.z):
		hear(origin, FLASH_POP)
		return false
	blind(FLASH_BLIND, origin)
	return true

## Blinded: it reels for `seconds`, facing where the flash came from, and can't see a thing. All it
## knows is where you were when it went off. What happens when its eyes clear is _come_to().
func blind(seconds: float, from: Vector3) -> void:
	var p := global_position
	stun_timer = maxf(stun_timer, seconds)
	set_state("stunned")
	blinded = true
	enraged = 0.0
	lunge = 0.0
	lunge_windup = 0.0
	awareness = 0.0
	last_known = Vector3(from.x, 0.0, from.z)
	last_vel = Vector3.ZERO
	last_seen_time = 0.0
	yaw = atan2(from.x - p.x, from.z - p.z)

## Its eyes clear after a flash. Whoever it hunts still in plain sight and close: straight back after
## them, furious. Round a corner or far enough down the hall: it has lost them, and does what it
## does when it loses someone (give_up: wander off toward where they were, or wait there).
func _come_to() -> void:
	blinded = false
	gather_target()
	var p := global_position
	if not tgt.dead and distance_to_target() < FLASH_REACQUIRE and nav.clear_line(p.x, p.z, tgt.pos.x, tgt.pos.z):
		enraged = 3.0
		awareness = 1.0
		last_known = Vector3(tgt.pos.x, 0.0, tgt.pos.z)
		last_seen_time = 0.0
		set_state("chase")
		set_goal(tgt.pos.x, tgt.pos.z)
	else:
		give_up()

func run_away() -> void:
	stun_timer = 0.0
	blinded = false
	enraged = 0.0
	pause = 0.0
	lunge = 0.0
	lunge_windup = 0.0
	start_flee()

func _unhandled_input(e: InputEvent) -> void:
	if not Game.dev_keys or not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.physical_keycode == KEY_F10:
		var f := -player.global_transform.basis.z
		var p := player.global_position + f * 14.0
		if nav.open_at(p.x, p.z):
			summon(p.x, p.z, player.global_position.x, player.global_position.z)
	elif e.physical_keycode == KEY_F4:
		debug_stalk()

# ---------------------------------------------------------------- T.S.R.A. scanner
# Hold Q on it with the field scanner (scripts/Player/scanner.gd) to log it in the Threshold Dossier.
func _enter_tree() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("asra_id", "bacteria")

## Where the scanner can take a reading off it right now; empty while it is away
func scan_points() -> Array:
	if process_mode == Node.PROCESS_MODE_DISABLED or not is_visible_in_tree():
		return []
	return [global_position + Vector3.UP * 1.6]

## C-4 deep scan (scan_readout.gd): what it is doing right now, in the agency's words.
## danger 0 calm / 1 wary / 2 after you
const SCAN_STATES := {
	"roam": ["ROAMING", "HAS NOT NOTICED YOU", 0],
	"investigate": ["INVESTIGATING", "HEADING FOR A NOISE", 1],
	"search": ["SEARCHING", "LOOKING WHERE IT LOST YOU", 1],
	"chase": ["IN PURSUIT", "HUNTING YOU - BREAK LINE OF SIGHT", 2],
	"screech": ["SCREECHING", "IT HAS SEEN YOU", 2],
	"stalk": ["STALKING", "WATCHING YOU FROM COVER - FACE IT", 1],
	"stunned": ["STUNNED", "DISORIENTED - GET OUT OF ITS SIGHT", 0],
	"flee": ["RETREATING", "BREAKING OFF", 0],
	"lurk": ["LYING IN WAIT", "AMBUSH - DO NOT WALK INTO IT", 2],
}

func scan_behavior(_at: Vector3) -> Dictionary:
	var s: Array = SCAN_STATES.get(state, [state.to_upper(), "", 1])
	var detail: String = s[1]
	if state == "roam" or state == "investigate" or state == "search":
		detail += " // AWARENESS %d%%" % roundi(clampf(awareness, 0.0, 1.0) * 100.0)
	return {"state": s[0], "detail": detail, "danger": s[2]}

# ---------------------------------------------------------------- debug console
func debug_active() -> bool:
	return process_mode != Node.PROCESS_MODE_DISABLED

func debug_despawn() -> void:
	process_mode = Node.PROCESS_MODE_DISABLED
	visible = false
	scares.entity_breathe(0.0)

func debug_stalk() -> bool:
	if process_mode == Node.PROCESS_MODE_DISABLED:
		process_mode = Node.PROCESS_MODE_INHERIT
		visible = true
	gather_target()
	return begin_stalk(true)

func debug_spawn() -> bool:
	process_mode = Node.PROCESS_MODE_INHERIT
	visible = true
	var f := -player.global_transform.basis.z
	var pp := player.global_position
	for dist in [14.0, 10.0, 7.0]:
		var p: Vector3 = pp + f * dist
		if nav.open_at(p.x, p.z) and nav.clear_line(pp.x, pp.z, p.x, p.z):
			summon(p.x, p.z, pp.x, pp.z)
			return true
	relocate()
	return true
