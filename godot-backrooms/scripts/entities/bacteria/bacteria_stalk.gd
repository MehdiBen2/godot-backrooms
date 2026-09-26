extends "res://scripts/entities/bacteria/bacteria_senses.gd"
## THE BACTERIA, layer 4: the ways it hunts without charging. It stalks (goes to a corner near you and
## leans out to watch, pulling back when you look), it flees (caught, fed, or frightened by the
## mannequin) and it lies in wait (lurk: crouched in silence where it guessed you would pass).

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
var peek_lean_target := 0.0            # the rig leans the body out past the corner by this
var peek_amt := 0.0                    # 0 hidden behind the corner .. 1 leaned out watching you
var peek_mode := "hide"
var peek_timer := 0.0
var peek_step := 0.0
var peek_gaze := 0.0                   # how long it has been in your view while peeking
var peek_count := 0
# ---- lying in wait
var lurk_waiting := false

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
				var edge := _edge(hwx, hwz, wx, wz, who)
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

# Walking from the hidden cell (hx, hz) toward the seen one (wx, wz): how far until `who` could see it
func _edge(hx: float, hz: float, wx: float, wz: float, who: Vector3) -> float:
	var s := 0.05
	while s <= 1.001:
		if nav.clear_line(hx + (wx - hx) * s, hz + (wz - hz) * s, who.x, who.z):
			return s * CELL
		s += 0.05
	return -1.0

func _stalk_open(x: int, z: int, anywhere: bool) -> bool:
	return not blocked(x, z) if anywhere else reach[x * n + z] >= 0

func begin_stalk(teleport := false) -> bool:
	if tgt.dead:
		return false
	if not teleport and distance_to_target() > STALK_MAX_DIST * 3.0:
		return false
	if not find_stalk_spot(tgt.pos, teleport):
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
	var who: Vector3 = from if from != null else tgt.pos
	var watcher: bool = from == null and stalk_active
	set_state("flee")
	stalk_active = false
	lurk_waiting = false
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
	if not roam_spot(target_pos()):
		pick_spot(5, 18)

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
			peek_amt = clampf(0.98 + sin(rig.clock * 1.3) * 0.04, 0.0, 1.0)
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
	if not stalk_active or tgt.dead:
		end_flee()
		return
	var p := global_position
	var d := distance_to_target()
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

# ---------------------------------------------------------------- lying in wait
## Having lost you, go and wait where you were heading: a reachable spot near there that you can't see
## from where you are now, so you walk into it. False when there is nowhere suitable.
func begin_lurk(near: Vector3) -> bool:
	var p := global_position
	if not nav.bfs(GridNav.cell(p.x), GridNav.cell(p.z), reach):
		return false
	var who: Vector3 = tgt.pos
	var cx := GridNav.cell(near.x)
	var cz := GridNav.cell(near.z)
	var best_k := -1
	var best_score := -INF
	for x in range(cx - 3, cx + 4):
		for z in range(cz - 3, cz + 4):
			if x < 1 or z < 1 or x >= n - 1 or z >= n - 1:
				continue
			var d := reach[x * n + z]
			if d < 1 or d > 14:
				continue
			var wx := x * CELL
			var wz := z * CELL
			if not tgt.dead and nav.clear_line(wx, wz, who.x, who.z):
				continue                         # they would see it get there
			# junctions are where people pass; closer to the guess is better
			var open := 0
			for o in GridNav.NEIGHBOURS:
				if not blocked(x + o.x, z + o.y):
					open += 1
			var score := (0.6 if open >= 3 else 0.0) - Vector2(wx - near.x, wz - near.z).length() / (4.0 * CELL) + rng.randf() * 0.3
			if score > best_score:
				best_score = score
				best_k = x * n + z
	if best_k < 0:
		return false
	set_goal((best_k / n) * CELL, (best_k % n) * CELL)
	set_state("lurk")
	lurk_waiting = false
	awareness = 0.0
	return true

func think_lurk(heard) -> void:
	var d := distance_to_target()
	# it has you: out of the dark, from right beside you
	if awareness >= 1.0 or (seen_target and d < LURK_POUNCE):
		lurk_waiting = false
		since_encounter = 0.0
		awareness = 1.0
		set_state("screech")
		return
	if not lurk_waiting and at_goal(1.2):
		lurk_waiting = true
		state_time = 0.0
		look_yaw = yaw + (rng.randf() - 0.5) * 2.0
	if lurk_waiting and heard != null:
		# a sound: it turns its head toward it, and listens harder
		look_yaw = atan2(heard.x - global_position.x, heard.z - global_position.z)
		awareness = minf(0.9, awareness + 0.15)
	if state_time > LURK_TIME or (not lurk_waiting and state_time > 20.0):
		lurk_waiting = false
		set_state("roam")
		if not roam_spot(target_pos()):
			pick_spot(4, 16)
