extends Node3D
## THE MANNEQUIN (js/game/mannequin.js). A room packed with still mannequins and one that is real.
## The real one only moves while you can't see it (a Weeping Angel), in stiff stop-motion steps; it
## hunts for 30 s, rests, and every third rest freezes for five minutes. It reaches you unseen and
## your neck is snapped.
##
## Its parts live beside it: mannequin_model.gd (the body taken apart into posable parts),
## mannequin_crowd.gd (the decoys, and how they shift while you look away), mannequin_snap.gd (the kill).
## Being near the real one is felt before it is seen: your heart, whispers at your ear, the tubes over
## you dying. And when you turn and find it has moved, its joints are still creaking.
##
## Dev key: F2 warps you to the room.

const GridNav := preload("res://scripts/World/grid_nav.gd")
const MannequinModel := preload("res://scripts/Entities/mannequin/mannequin_model.gd")
const MannequinCrowd := preload("res://scripts/Entities/mannequin/mannequin_crowd.gd")
const MannequinSnap := preload("res://scripts/Entities/mannequin/mannequin_snap.gd")
const Blink := preload("res://scripts/Player/blink.gd")
const SnapBuffer := preload("res://scripts/Net/snap_buffer.gd")
const EntityMarks := preload("res://scripts/Entities/entity_marks.gd")
const CELL := 4.5
const MARK_RADIUS := 2                       # cells each way round a Mannequin mark that make its room
const HEIGHT := MannequinModel.HEIGHT
const POSE_KEYS := MannequinModel.POSE_KEYS

# MANNEQUIN config (js/config.js)
const COUNT := 60
const ROOM := Rect2i(33, 19, 8, 3)           # fallback when the level paints no Mannequin zone: cell rectangle x0,z0 and size
const SPACING := 1.5
const RADIUS := 0.34
const WAKE_DISTANCE := 17.0
const VIEW_RANGE := 30.0
const STEP_TIME := 0.34
const STEP_LENGTH := 1.05
const KILL_DISTANCE := 1.15
const HUNT_TIME := 30.0
const ZONE_LOSE_DISTANCE := 40.0             # out of its zone, past this far from it, it counts you as lost...
const LOSE_TIME := 6.0                       # ...once that has gone on this long
# Corner lurk: now and then it doesn't come straight at you but goes round a corner or into a doorway ahead of you,
# out of your sight, and stands there still until you walk into it (it only ever moves unseen, like the rest)
const LURK_CD_MIN := 18.0                    # s between the times it may try this
const LURK_CD_MAX := 32.0
const LURK_CHANCE := 0.55                    # of those tries, how many it goes through with
const LURK_SPRING_DIST := 4.5                # m: you come this close to its corner and it comes out after you
const LURK_MAX := 25.0                       # s it will wait there before the hunt goes on
const LURK_PATH_MAX := 28                    # cells: no corner further than this by foot from it
const REST_TIME := 20.0
const LONG_PAUSE_EVERY := 3
const LONG_PAUSE_TIME := 300.0
const LOUDNESS := 1.0
# The real one's body: usually the jointed sculpt (model.parts), but sometimes wears one of the crowd's
# rigged variant sculpts instead (model's VARIANT_MODELS), re-rolled every reset() so which killer you get
# varies room to room. Its "align" arm-centering pose key (mannequin_snap.gd's reach) isn't implemented for
# the variant rigs - untested how their kill-pose hand placement reads, so playtest a variant-bodied kill.
const REAL_VARIANT_CHANCE := 0.3
# Presence
const HEART_RANGE := 7.0
const LIGHT_RANGE := 5.0
const SETTLE_RANGE := 10.0                   # turn and catch it this close after it moved: its joints creak
const WHISPER_PATH := "res://audio/entity/mannequin_whisper.mp3"
const WHISPER_RANGE := 7.0
# Staring them down: eyes can't stay open forever. After a few seconds of watching, your eyes sting and you
# start to blink at random, more often and slower the longer you stare, and while the lids are shut nobody is
# watching: the real one steps, the crowd shifts. Every second you watch costs a little sanity.
const STARE_STING := 4.0                     # s of staring before the blinks start
const STARE_RAMP := 10.0                     # s more to reach the full blink urge
const STARE_BLINK_RATE := 0.35               # blinks per second at full urge
const STARE_SANITY := 0.25                   # sanity per second while watching them...
const STARE_SANITY_MAX := 0.6                # ...rising to this after a long stare

var room_cells: Array[Vector2i] = []
var room_near := {}                          # room cells and their neighbours
var zone_cells := {}                         # exactly the painted cells: standing in one, it is always coming for you
var room_box := Rect2i()
var level: Node
var player: CharacterBody3D
var scares: Node
var nav: GridNav
var n := 0
var rng := RandomNumberGenerator.new()
var model := MannequinModel.new()
var crowd: MannequinCrowd
var snap: MannequinSnap
var ready_ok := false

var decoys: Array:
	get: return crowd.decoys if crowd else []
var real_node: Node3D
var real_meshes: Array = []
var real_variant_idx := -1                 # -1 = classic jointed body; >= 0 = which model variant sculpt
var real_sk: Skeleton3D                    # only set when real_variant_idx >= 0
var real_vbones := {}
var real_vprofile := {}
var real_arm_l_pivot := Vector3.INF
var real_pose := {}
var real_yaw := 0.0
var hunt := {}
var awake := false
var summoned := false             # a trigger / the debug warp asked for it; otherwise it only exists where the level paints a Mannequin zone
var moving := false
var rest_left := 0.0
var lose_t := 0.0                          # s out of its zone and out of reach (see ZONE_LOSE_DISTANCE)
var lurking := false                       # on its way to a corner, or standing in it (see LURK_*)
var lurk_cell := Vector2i.ZERO
var lurk_t := 0.0                          # s since it chose the corner
var lurk_cd := 14.0                        # s until it may choose another
var _lurk_trip := false                    # this step is a walk to the corner, not a stride at you (begin_step)
var pause_left := 0.0                      # s it is standing still mid-hunt (a random few-second stop)
var pause_cd := 8.0                        # s until the next chance of such a stop
var _hunt_seen := false                    # watched last frame (the handoff to a walking decoy fires when this turns true)
var hunt_clock := 0.0
var rest_count := 0
var killed := false
var last_step_sound := 0.0
var flank_sign := 1.0
var flow := PackedInt32Array()
var light_cd := 3.0
var whisper_cd := 4.0
var whisper_stream: AudioStream
var _was_seen := true
var _moved_unseen := false
var _last_real_pos := Vector3.ZERO

# ---- co-op: the host rolls the room (one seed) and runs the real one, hunting the nearest survivor and only
# moving while NOBODY is looking at it. Everyone else builds the same room from the seed and follows the real
# one from snapshots; each machine still plays its own whispers, shuffling decoys and neck snap.
var seed_value := 0
var puppet := false
var net_buf = SnapBuffer.new()
var net_step_idx := -1
var t_id := -1
var t_pos := Vector3.ZERO
var t_fwd := Vector3.FORWARD
var _net_t := 0.0
var _view_t := 0.0
var _snap_cd := {}
var _watch := {}                  # {id, t, pos, at, blinked, cut} while another survivor is being killed (net_watch_kill)

# the kill in progress (mannequin_snap.gd)
var snap_active: bool:
	get: return snap != null and snap.active
	set(v):
		if snap != null and not v:
			snap.finish()
var snap_t: float:
	get: return snap.t if snap else 0.0

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	nav = GridNav.new(level)
	n = nav.n
	_find_room()
	flow.resize(n * n)
	crowd = MannequinCrowd.new(self)
	snap = MannequinSnap.new(self)
	if not model.load_template(self):
		push_warning("mannequin: model failed to load")
		return
	model.load_variant(self, rng)     # optional: crowd looks fine without it, just less varied
	ready_ok = true
	reset()
	EntityLOD.register(self)

## EntityLOD measures it from the real one, not the node (which stays at the room's origin)
func lod_position() -> Vector3:
	return real_node.global_position if real_node != null else global_position

func lod_engaged() -> bool:
	return awake or snap.active or not _watch.is_empty()

# ================================================================= room
## The room's cells: the level's painted Mannequin zone (level editor), else the fixed ROOM rectangle
func _find_room() -> void:
	room_cells.clear()
	room_near.clear()
	var marks := EntityMarks.of_kind(level, "mannequin")
	if not marks.is_empty():
		# a Mannequin mark in the level editor: the room is the stretch of floor round the first one
		var mc := EntityMarks.cell(marks[0])
		for dx in range(-MARK_RADIUS, MARK_RADIUS + 1):
			for dz in range(-MARK_RADIUS, MARK_RADIUS + 1):
				room_cells.append(mc + Vector2i(dx, dz))
	else:
		for c: Vector2i in level.mannequin:
			room_cells.append(c)
	if room_cells.is_empty():
		for x in range(ROOM.position.x, ROOM.end.x + 1):
			for z in range(ROOM.position.y, ROOM.end.y + 1):
				room_cells.append(Vector2i(x, z))
	var lo := room_cells[0]
	var hi := room_cells[0]
	for c in room_cells:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				room_near[c + Vector2i(dx, dz)] = true
	room_box = Rect2i(lo, hi - lo)
	zone_cells.clear()
	for c in room_cells:
		zone_cells[c] = true

func room_slots(count: int) -> Array:
	var cells: Array = []
	for c in room_cells:
		if not nav.blocked(c.x, c.y):
			cells.append(c)
	var slots: Array = []
	if cells.is_empty():
		return slots
	var jitter := CELL / 2.0 - RADIUS - 0.15
	var tries := 0
	while tries < count * 60 and slots.size() < count:
		tries += 1
		var c: Vector2i = cells[rng.randi() % cells.size()]
		var x := c.x * CELL + rng.randf_range(-jitter, jitter)
		var z := c.y * CELL + rng.randf_range(-jitter, jitter)
		var ok := true
		for s in slots:
			if Vector2(s.x - x, s.z - z).length() < SPACING:
				ok = false
				break
		if ok:
			slots.append({"x": x, "z": z})
	return slots

func room_centre() -> Vector3:
	var sum := Vector2.ZERO
	for c in room_cells:
		sum += Vector2(c)
	sum /= room_cells.size()
	return Vector3(sum.x * CELL, 0.0, sum.y * CELL)

func in_room(p: Vector3) -> bool:
	var x := GridNav.cell(p.x)
	var z := GridNav.cell(p.z)
	return room_near.has(Vector2i(x, z))

## Standing on one of the painted cells (the white area in the level editor)
func in_zone(p: Vector3) -> bool:
	return zone_cells.has(Vector2i(GridNav.cell(p.x), GridNav.cell(p.z)))

# Re-deal the room: everyone gets a new spot and a new pose, and one of them is the real one
func reset() -> void:
	if not ready_ok:
		return
	# every survivor must stand in the same room: the host (or single player) rolls a seed, guests use the host's
	if Net.is_online() and not Net.hosting:
		if Net.mq_level != Game.level_index:
			return                                  # the host's seed hasn't arrived yet: net_seed() will call us again
		seed_value = Net.mq_seed
	else:
		seed_value = rng.randi()
		Net.send_mq_seed(seed_value)
	rng.seed = seed_value
	_snap_cd.clear()
	net_step_idx = -1
	for c in get_children():
		c.queue_free()
	killed = false
	_watch = {}
	hunt_clock = 0.0
	rest_left = 0.0
	rest_count = 0
	awake = false
	moving = false
	lurking = false
	snap.finish()
	if level.mannequin.is_empty() and not summoned and EntityMarks.of_kind(level, "mannequin").is_empty():
		real_node = null                # no zone painted in this level: no mannequins
		return
	var slots := room_slots(COUNT)
	if slots.size() < 3:
		push_warning("mannequin room has no floor")
		return
	var centre := room_centre()
	var dealt: Array = []
	for s in slots:
		var face := atan2(centre.x - s.x, centre.z - s.z)
		dealt.append({"x": s.x, "z": s.z,
			"yaw": face + (rng.randf_range(-0.6, 0.6) if rng.randf() < 0.7 else rng.randf_range(-PI, PI)),
			"pose": MannequinModel.decoy_pose(rng)})
	var real_idx := rng.randi() % dealt.size()
	var r: Dictionary = dealt[real_idx]
	r.pose = MannequinModel.random_pose(rng)          # the real one always stands
	dealt.remove_at(real_idx)
	crowd.build(dealt)
	_build_real(r)
	rng.randomize()                 # the room is dealt: from here on it behaves differently every run

func _build_real(r: Dictionary) -> void:
	real_node = Node3D.new()
	add_child(real_node)
	real_meshes.clear()
	real_sk = null
	real_variant_idx = -1
	var cand: Array = []
	for idx in model.variant_count():
		if model.variant_is_rigged(idx):
			cand.append(idx)
	if not cand.is_empty() and rng.randf() < REAL_VARIANT_CHANCE:
		real_variant_idx = cand[rng.randi() % cand.size()]
	if real_variant_idx >= 0:
		var body := model.spawn_variant_body(real_variant_idx)
		real_node.add_child(body.node)
		body.node.transform = model.variant_root_xf_at(real_variant_idx)
		real_sk = body.sk
		real_vbones = body.vbones
		real_vprofile = body.profile
		real_arm_l_pivot = body.arm_l_pivot
	else:
		for pt in model.parts:
			var mi := MeshInstance3D.new()
			mi.mesh = pt.mesh
			real_node.add_child(mi)
			real_meshes.append(mi)
	real_node.position = Vector3(r.x, 0.0, r.z)
	_last_real_pos = real_node.position
	real_yaw = r.yaw
	real_node.rotation.y = real_yaw
	set_pose(r.pose)
	_start_hunt()
	# solid too
	var body := AnimatableBody3D.new()
	body.name = "RealBody"
	body.sync_to_physics = false
	# Same layer as the crowd's decoy bodies (2, not the level-geometry layer 1): keeps this body's
	# collision cylinder invisible to death_fx.gd's blood-blob raycasts, which would otherwise splat a
	# decal onto the cylinder itself and leave blood floating beside the actual (thinner) figure.
	body.collision_layer = 2
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	cs.shape = cyl
	cs.position.y = HEIGHT / 2.0
	body.add_child(cs)
	real_node.add_child(body)

## Pose the real one
func set_pose(pose: Dictionary) -> void:
	real_pose = pose
	if real_variant_idx >= 0:
		if real_sk != null:
			model.pose_variant(real_sk, pose, real_vbones, real_vprofile, real_arm_l_pivot)
		return
	var xfs := model.part_transforms(pose)
	for j in real_meshes.size():
		(real_meshes[j] as MeshInstance3D).transform = xfs[j]

func rest_pose() -> Dictionary:
	return MannequinModel.rest_pose()

func _start_hunt() -> void:
	hunt = {"step_t": 0.0, "step_idx": 0, "from": real_pose.duplicate(), "to": real_pose.duplicate(),
		"yaw_from": real_yaw, "yaw_to": real_yaw, "move_from": null, "move_to": null, "stepped": false, "dur": STEP_TIME}

# ================================================================= being watched
# Any part of it inside your view, with nothing solid in between
## The lids are (nearly) shut: you see nothing, so for this moment nothing is watched
func eyes_shut() -> bool:
	return player.blink != null and player.blink.blinking() and Game.fx_blink > 0.55

func seen(pos: Vector3) -> bool:
	if player.dead or player.frozen or not Game.playing or eyes_shut():
		return false
	var cam: Camera3D = player.cam
	var d := Vector2(pos.x - cam.global_position.x, pos.z - cam.global_position.z).length()
	if d > VIEW_RANGE:
		return false
	if not (cam.is_position_in_frustum(Vector3(pos.x, HEIGHT * 0.5, pos.z)) \
			or cam.is_position_in_frustum(Vector3(pos.x, HEIGHT * 0.9, pos.z)) \
			or cam.is_position_in_frustum(Vector3(pos.x, 0.2, pos.z))):
		return false
	# sight lines to its middle and both shoulders, so peeking round a corner still counts
	var ex := cam.global_position.x
	var ez := cam.global_position.z
	var dx := pos.x - ex
	var dz := pos.z - ez
	var l := maxf(sqrt(dx * dx + dz * dz), 0.001)
	var sx := -dz / l * 0.35
	var sz := dx / l * 0.35
	for k in [0, 1, -1]:
		if nav.clear_line(ex, ez, pos.x + sx * k, pos.z + sz * k, 0.6):
			return true
	return false

# You turn, and it is closer than it was. Its joints are still settling: one dry creak, and your
# heart jumps. Only when it really moved while you weren't looking, and only up close.
func _update_settle() -> void:
	var pos := real_node.position
	if pos.distance_squared_to(_last_real_pos) > 0.0004:
		_last_real_pos = pos
		if not _was_seen:
			_moved_unseen = true
	var now := seen(pos)
	if now and not _was_seen and _moved_unseen and not snap.active:
		_moved_unseen = false
		var d := player.global_position.distance_to(pos)
		if d < SETTLE_RANGE:
			var close := 1.0 - d / SETTLE_RANGE
			scares.mannequin_settle(pos + Vector3(0.0, HEIGHT * 0.75, 0.0), 0.6 + 0.8 * close)
			if Game.heart != null:
				Game.heart.feed("mannequin_turn", 0.5 + 0.45 * close)
			Game.add_glitch(0.1 + 0.25 * close)
	_was_seen = now

# ================================================================= hunting
# Walking distance from the player's cell, so it can step downhill
func step_target(pos: Vector3, tgt: Vector3) -> Vector3:
	if nav.clear_line(pos.x, pos.z, tgt.x, tgt.z, 0.6):
		return tgt
	n = nav.n                          # (a new floor can be a different size; bfs sizes the field to it)
	var cx := GridNav.cell(pos.x)
	var cz := GridNav.cell(pos.z)
	# the field is grown from the goal's cell. A goal in a cell it can't enter (a wall, a Safe zone, a pit's rim)
	# is grown from the open cell beside it that is nearest the goal instead
	var gx := GridNav.cell(tgt.x)
	var gz := GridNav.cell(tgt.z)
	if nav.blocked(gx, gz):
		var near_c := Vector2i(-1, -1)
		var near_d := INF
		for ox in range(-1, 2):
			for oz in range(-1, 2):
				if nav.blocked(gx + ox, gz + oz):
					continue
				var dd := Vector2((gx + ox) * CELL - tgt.x, (gz + oz) * CELL - tgt.z).length()
				if dd < near_d:
					near_d = dd
					near_c = Vector2i(gx + ox, gz + oz)
		if near_c.x < 0:
			return pos                 # nowhere it can go: it holds where it is rather than walking at the wall
		gx = near_c.x
		gz = near_c.y
	if not nav.bfs(gx, gz, flow):
		return pos
	var best := flow[cx * n + cz] if (cx >= 0 and cz >= 0 and cx < n and cz < n) else -1
	var target := pos                  # (no way downhill: it holds where it is)
	for o in GridNav.NEIGHBOURS:
		var nx: int = cx + o.x
		var nz: int = cz + o.y
		if nx < 0 or nz < 0 or nx >= n or nz >= n:
			continue
		if not nav.can_step(cx, cz, nx, nz):
			continue                   # a thin wall or a door's edge is in the way: the field's lower number is not a way through
		var d := flow[nx * n + nz]
		if d != -1 and (best == -1 or d < best):
			best = d
			target = Vector3(nx * CELL, 0.0, nz * CELL)
	return target

## The player's facing on the ground plane
func player_forward() -> Vector3:
	var f := -player.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.001 else Vector3.FORWARD

# Is `at` behind the one it hunts (outside a wide rear arc)?
func _is_behind(at: Vector3) -> bool:
	var to := Vector3(at.x - t_pos.x, 0.0, at.z - t_pos.z)
	if to.length() < 0.001:
		return true
	return to.normalized().dot(t_fwd) < -0.5     # well behind you (over ~120 deg round), never at your side

func begin_step(tgt: Vector3) -> void:
	# It doesn't come at you from the side: closing in, it aims for the spot right behind you
	var d_to := Vector2(tgt.x - real_node.position.x, tgt.z - real_node.position.z).length()
	var behind_k := 0.0 if _lurk_trip else clampf(1.0 - (d_to - 3.0) / 5.0, 0.0, 1.0)
	var aim := tgt
	tgt = tgt - t_fwd * 1.0 * behind_k
	# ...but not into a wall: with your back to one, the spot behind you is inside it
	if behind_k > 0.0 and (nav.blocked(GridNav.cell(tgt.x), GridNav.cell(tgt.z)) or not nav.clear_line(aim.x, aim.z, tgt.x, tgt.z, 0.2)):
		tgt = aim
	var pos := real_node.position
	var target := step_target(pos, tgt)
	var to_x := tgt.x - pos.x
	var to_z := tgt.z - pos.z
	var to_dist := maxf(Vector2(to_x, to_z).length(), 0.001)
	# flanking: don't follow in a single file line
	var perp := Vector3(-to_z / to_dist, 0.0, to_x / to_dist)
	if flank_sign == 1.0:
		flank_sign = (-1.0 if rng.randf() < 0.5 else 1.0) * (0.8 + rng.randf() * 1.5)
	if to_dist > 2.2 and not _lurk_trip and target.distance_to(pos) > 0.05:
		var fw := minf(2.5, to_dist * 0.22)
		var f := target + perp * flank_sign * fw
		# (only to a spot it can see from here: an open cell on the far side of a wall is no flank)
		if not nav.blocked(GridNav.cell(f.x), GridNav.cell(f.z)) and nav.clear_line(pos.x, pos.z, f.x, f.z, 0.3):
			target = f
	var dx := target.x - pos.x
	var dz := target.z - pos.z
	var dist := maxf(Vector2(dx, dz).length(), 0.001)
	var heading := atan2(dx, dz) if dist > 0.01 else real_yaw         # (holding in place: it keeps its facing)
	var length := maxf(0.15, minf(STEP_LENGTH, minf(dist, to_dist - 0.3)))
	hunt.step_idx += 1
	hunt.step_t = 0.0
	hunt.stepped = false
	hunt["from"] = real_pose.duplicate()
	hunt.yaw_from = real_yaw
	hunt.yaw_to = real_yaw + wrapf(heading - real_yaw, -PI, PI)
	hunt.move_from = Vector2(pos.x, pos.z)
	hunt.move_to = Vector2(pos.x + dx / dist * length, pos.z + dz / dist * length)
	hunt.dur = STEP_TIME * rng.randf_range(0.85, 1.15) * (1.6 if rng.randf() < 0.08 else 1.0)
	var flip := 1.0 if hunt.step_idx % 2 == 1 else -1.0
	hunt["to"] = MannequinModel.step_pose(rng, flip, 99.0 if _lurk_trip else to_dist)

## Choose a corner or doorway a few cells from you, ahead of where you are heading, out of your line of sight and
## reachable on foot from where it stands. False when there is none (it just keeps hunting).
func _pick_lurk(pos: Vector3, tgt: Vector3) -> bool:
	n = nav.n
	var pc := Vector2i(GridNav.cell(tgt.x), GridNav.cell(tgt.z))
	var rc := Vector2i(GridNav.cell(pos.x), GridNav.cell(pos.z))
	if rc.x < 0 or rc.y < 0 or rc.x >= n or rc.y >= n:
		return false
	var ahead: Array[Vector2i] = []
	var other: Array[Vector2i] = []
	for dx in range(-4, 5):
		for dz in range(-4, 5):
			if maxi(absi(dx), absi(dz)) < 2:
				continue
			var c := pc + Vector2i(dx, dz)
			if nav.blocked(c.x, c.y):
				continue
			var walls_round := int(nav.blocked(c.x - 1, c.y)) + int(nav.blocked(c.x + 1, c.y)) \
				+ int(nav.blocked(c.x, c.y - 1)) + int(nav.blocked(c.x, c.y + 1))
			if walls_round != 2:
				continue                                  # neither a corner nor a doorway
			var cw := Vector3(c.x * CELL, 0.0, c.y * CELL)
			if nav.clear_line(tgt.x, tgt.z, cw.x, cw.z, 0.3):
				continue                                  # you would see it standing there
			var to_c := Vector3(cw.x - tgt.x, 0.0, cw.z - tgt.z).normalized()
			if to_c.dot(t_fwd) > 0.2:
				ahead.append(c)
			else:
				other.append(c)
	var pool: Array[Vector2i] = ahead if not ahead.is_empty() else other
	pool.shuffle()
	for k in mini(pool.size(), 6):
		var c: Vector2i = pool[k]
		if not nav.bfs(c.x, c.y, flow):
			continue
		var steps := flow[rc.x * n + rc.y]
		# on its way to you, not a detour away from you: about as far on foot as you are in a line, plus a few cells
		var cells_to_you := Vector2(tgt.x - pos.x, tgt.z - pos.z).length() / CELL
		if steps >= 0 and steps <= mini(LURK_PATH_MAX, int(cells_to_you) + 3):
			lurk_cell = c
			lurking = true
			lurk_t = 0.0
			return true
	return false

func smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func update_real(delta: float) -> void:
	var was_moving := moving
	moving = false
	var tg := Net.nearest_survivor(real_node.position, t_id)
	if tg.is_empty():
		return                                       # nobody alive and in the game
	t_id = tg.id
	t_pos = tg.pos
	t_fwd = tg.fwd
	var tgt: Vector3 = tg.pos
	var pos := real_node.position
	var d_tgt := Vector2(tgt.x - pos.x, tgt.z - pos.z).length()
	var zone := in_zone(tgt)
	if not awake:
		# it stays dormant (silent, no footsteps) until you step into its painted zone
		if zone:
			awake = true
		else:
			return
	# out of the zone and well away from it: after a few seconds it loses you and goes dormant again
	if zone or d_tgt < ZONE_LOSE_DISTANCE:
		lose_t = 0.0
	else:
		lose_t += delta
		if lose_t >= LOSE_TIME:
			lose_t = 0.0
			awake = false
			rest_left = 0.0
			hunt_clock = 0.0
			rest_count = 0
			pause_left = 0.0
			lurking = false
			hunt.move_to = null
			return
	# watched by anyone: it holds its pose, silent, exactly where it is
	var now_seen := seen(pos) or Net.mq_seen_by_peers()
	if now_seen and not _hunt_seen and was_moving:
		# caught on the move: it stops, and one or two of the still ones start coming for you instead
		crowd.handoff(pos, 1 if rng.randf() < 0.6 else 2)
	_hunt_seen = now_seen
	if now_seen:
		return
	if zone:
		# standing in the zone it never rests or pauses: it is always coming
		rest_left = 0.0
		hunt_clock = 0.0
		pause_left = 0.0
	if rest_left > 0.0:
		rest_left -= delta
		return
	hunt_clock += delta
	if hunt_clock >= HUNT_TIME:
		hunt_clock = 0.0
		rest_count += 1
		if rest_count >= LONG_PAUSE_EVERY:
			rest_count = 0
			rest_left = LONG_PAUSE_TIME
		else:
			rest_left = REST_TIME
		return
	# out in the open it sometimes just stops for a few seconds, so the chase never runs on a fixed clock
	if pause_left > 0.0:
		pause_left -= delta
		return
	if not zone:
		pause_cd -= delta
		if pause_cd <= 0.0:
			pause_cd = rng.randf_range(7.0, 13.0)
			if rng.randf() < 0.7:
				pause_left = rng.randf_range(4.0, 6.0)
				return
	# corner lurk: now and then it doesn't come straight at you but goes round a corner ahead and waits there,
	# out of sight, for you to walk into it
	var goal := tgt
	_lurk_trip = false
	if lurking:
		lurk_t += delta
		var lp := Vector3(lurk_cell.x * CELL, 0.0, lurk_cell.y * CELL)
		if d_tgt < LURK_SPRING_DIST or lurk_t > LURK_MAX or d_tgt > ZONE_LOSE_DISTANCE:
			lurking = false                              # you are on top of it, or it waited long enough: the hunt goes on
		elif Vector2(lp.x - pos.x, lp.z - pos.z).length() < 1.2:
			hunt.move_to = null                          # there: it stands in the corner, still, and waits
			return
		else:
			goal = lp
			_lurk_trip = true
	elif d_tgt > 12.0 and d_tgt < ZONE_LOSE_DISTANCE:
		lurk_cd -= delta
		if lurk_cd <= 0.0:
			lurk_cd = rng.randf_range(LURK_CD_MIN, LURK_CD_MAX)
			if rng.randf() < LURK_CHANCE and _pick_lurk(pos, tgt):
				goal = Vector3(lurk_cell.x * CELL, 0.0, lurk_cell.y * CELL)
				_lurk_trip = true
	moving = true
	if hunt.move_to == null:
		begin_step(goal)
	hunt.step_t += delta
	# the pose snaps in over the first moments of a step and is then held: stop-motion
	var snap_k := smooth(hunt.step_t / 0.11)
	var p := {}
	for k in POSE_KEYS:
		p[k] = lerpf(hunt["from"][k], hunt["to"][k], snap_k)
	set_pose(p)
	real_yaw = lerpf(hunt.yaw_from, hunt.yaw_to, snap_k)
	real_node.rotation.y = real_yaw
	# the body lurches forward as the foot lands, then stands still for the rest of the step
	var mv := 1.0 - pow(1.0 - clampf(hunt.step_t / (hunt.dur * 0.4), 0.0, 1.0), 3.0)
	var mf: Vector2 = hunt.move_from
	var mt: Vector2 = hunt.move_to
	var np := Vector3(lerpf(mf.x, mt.x, mv), 0.0, lerpf(mf.y, mt.y, mv))
	np = nav.resolve(np, RADIUS)
	# don't walk through the crowd
	for d in decoys:
		var ddx: float = np.x - d.x
		var ddz: float = np.z - d.z
		var mn := RADIUS * 2.0
		var dsq := ddx * ddx + ddz * ddz
		if dsq < mn * mn:
			var l := maxf(sqrt(dsq), 0.0001)
			np.x = d.x + ddx / l * mn
			np.z = d.z + ddz / l * mn
	real_node.position = np
	# the foot lands
	if not hunt.stepped and hunt.step_t > 0.05:
		hunt.stepped = true
		_footfall(np, int(hunt.step_idx))
	if hunt.step_t >= hunt.dur:
		hunt.move_to = null
		begin_step(goal)
	# it reaches you while you weren't looking
	var reach := Vector2(tgt.x - np.x, tgt.z - np.z).length()
	if reach < KILL_DISTANCE and _is_behind(np):
		if tg.local:
			# not while the bacteria has you (frozen): two death sequences would fight over the camera
			if not player.frozen and player.spawn_grace <= 0.0 and not killed:
				killed = true
				start_snap()
		else:
			# a remote survivor: their own machine plays the snap (with a cooldown so it isn't sent every frame)
			var t_now := Time.get_ticks_msec() / 1000.0
			if t_now > _snap_cd.get(tg.id, 0.0):
				_snap_cd[tg.id] = t_now + 25.0
				Net.send_mq_kill(tg.id)

# A foot comes down: left and right alternate at hip width, the landing foot planted a little ahead.
# Heavier the closer it is to you.
func _footfall(np: Vector3, idx: int) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var dd := Vector2(player.global_position.x - np.x, player.global_position.z - np.z).length()
	if now - last_step_sound <= 0.22 or dd >= 28.0:
		return
	last_step_sound = now
	var close := maxf(0.0, 1.0 - dd / 28.0)
	var side := 1.0 if idx % 2 == 1 else -1.0          # in model space +X is its left
	var side_dir := real_node.global_transform.basis.x.normalized()
	var fwd_dir := -real_node.global_transform.basis.z.normalized()
	var foot_pos: Vector3 = np + side_dir * (side * 0.17) + fwd_dir * 0.28
	foot_pos.y = 0.05
	scares.mannequin_step(foot_pos, (0.45 + close * 0.95) * LOUDNESS)

# The entity is terrified of it while it hunts
func threat():
	if not ready_ok or not awake or real_node == null:
		return null
	return real_node.position

func _physics_process(delta: float) -> void:
	var _pt := Time.get_ticks_usec()
	_physics_process_timed(delta)
	Perf.add("Mannequin", _pt)

func _physics_process_timed(delta: float) -> void:
	if Game.freeze_ai:
		return
	var online := Net.is_online()
	puppet = online and not Net.hosting
	if not ready_ok or real_node == null:
		return
	# in co-op it keeps hunting the others even while this player has the menu open
	if not Game.playing and not online:
		return
	if snap.active:
		snap.update(delta)
		if online and not puppet:
			_net_send(delta)                     # the others watch it at your neck
		return
	# far from its room and nothing has woken it (EntityLOD ASLEEP): nothing to do until you come near
	if not online and not awake and _watch.is_empty() and EntityLOD.tier(self) == EntityLOD.ASLEEP and not in_zone(player.global_position):
		return
	if puppet:
		if _watch.is_empty():
			_puppet_step(delta)
		else:
			_update_watch(delta)                 # our own staging of a kill, not the host's (see net_watch_kill)
		_view_t -= delta
		if _view_t <= 0.0:
			_view_t = 0.1
			Net.send_mq_view(Game.playing and not player.dead and seen(real_node.position))
	else:
		if _watch.is_empty():
			update_real(delta)
		else:
			_update_watch(delta)
		if online:
			_net_send(delta)
	if Game.playing:
		_update_stare(delta)
		_update_settle()
		_update_whisper(delta)
		_update_presence(delta)
		crowd.update(delta)

func start_snap() -> void:
	if Game.god_mode:
		return
	snap.start()

# ================================================================= co-op
func _net_send(delta: float) -> void:
	_net_t -= delta
	if _net_t > 0.0:
		return
	_net_t = 0.05
	var pose: Array = []
	for k in POSE_KEYS:
		pose.append(float(real_pose.get(k, 0.0)))
	Net.send_mq([real_node.position.x, real_node.position.z, real_yaw, int(hunt.get("step_idx", 0)), awake, moving, pose])

func net_apply(t: float, m: Array) -> void:
	if m.size() < 7 or not (m[6] is Array) or (m[6] as Array).size() < POSE_KEYS.size():
		return
	net_buf.send_interval = 0.05
	net_buf.push(t, {"pos": Vector3(m[0], 0.0, m[1]), "yaw": float(m[2]), "m": m})

# The host's seed arrived after our room was built (or before we had one): build it now
func net_seed(_seed_v: int) -> void:
	if real_node == null or seed_value != Net.mq_seed:
		reset()

# Guest: put the real one where the host has it, in the pose it holds, and play its footfalls
func _puppet_step(delta: float) -> void:
	var st: Dictionary = net_buf.sample(delta)
	if st.is_empty():
		return
	var m: Array = st.m
	real_node.position = st.pos
	real_yaw = st.yaw
	real_node.rotation.y = real_yaw
	var pose := {}
	var vals: Array = m[6]
	for i in POSE_KEYS.size():
		pose[POSE_KEYS[i]] = vals[i]
	set_pose(pose)
	awake = m[4]
	moving = m[5]
	var idx := int(m[3])
	if idx != net_step_idx:
		if net_step_idx >= 0 and moving:
			_footfall(st.pos, idx)
		net_step_idx = idx

## Another survivor's machine has started its neck snap (net.gd, on every machine but theirs). Each of us
## stages it ourselves, so the cut lines up with our own eyes: it holds still where it caught them while
## they shake; at the crack anyone looking at them blinks, and the lids open on it right behind them, hands
## on their head, neck broken. It never moves while it is seen (see _update_watch).
func net_watch_kill(id: int) -> void:
	var r: Node3D = Net.remotes.get(id)
	if r == null or not is_instance_valid(r):
		return
	if watch_kill(r.target_pos, r.rotation.y, id):       # their body's facing: the clip turns the head on it
		_snap_cd[id] = Time.get_ticks_msec() / 1000.0 + 25.0

## Stages the kill on a body standing at `at` facing `yaw` (it faces -Z): a survivor over the network, or a
## debug stand-in. `body`, if it has a `time_scale` (the debug walker's slow motion), sets the pace.
func watch_kill(at: Vector3, yaw: float, id := -1, body: Node = null) -> bool:
	if not ready_ok or real_node == null or snap.active or not _watch.is_empty():
		return false
	var behind := _spot_behind(at, yaw, MannequinSnap.SNAP_DISTANCE)
	_watch = {"id": id, "t": 0.0, "pos": behind, "at": at, "blinked": false, "cut": false, "body": body}
	moving = false
	return true

## Where it stands `dist` behind a body at `at` facing `yaw`: straight behind if that's open floor, else the
## nearest open spot round their back (their back to a wall), else wherever it can get
func _spot_behind(at: Vector3, yaw: float, dist: float) -> Vector3:
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	for ang in [0.0, 0.5, -0.5, 1.0, -1.0, 1.57, -1.57]:
		var want := at - fwd.rotated(Vector3.UP, ang) * dist
		var got := nav.resolve(want, RADIUS)
		if Vector2(got.x - want.x, got.z - want.z).length() < 0.1:
			got.y = 0.0
			return got
	var spot := nav.resolve(at - fwd * dist, RADIUS)
	spot.y = 0.0
	return spot

## A blink long enough to hide their head going round (death_neck_snap's whip and settle) and its cut
const WATCH_BLINK := 1.6

func _update_watch(delta: float) -> void:
	var body = _watch.body
	var rate: float = body.get("time_scale") if body != null and is_instance_valid(body) and body.get("time_scale") != null else 1.0
	_watch.t += delta * rate
	var at: Vector3 = _watch.at
	var pos: Vector3 = _watch.pos
	var slow := WATCH_BLINK / maxf(rate, 0.05)          # in slow motion the lids stay down as long, in its time
	var lids := Blink.CLOSE * sqrt(slow) * rate
	# the crack is coming: if you are looking at them or at it, your eyes shut on it, the lids meeting right
	# as the head goes round
	if not _watch.blinked and _watch.t >= MannequinSnap.SNAP_AT - lids:
		_watch.blinked = true
		if player.blink != null and (seen(Vector3(at.x, 0.0, at.z)) or seen(real_node.position) or seen(pos)):
			player.blink.blink(slow)
	# the cut: only once the crack has come, and only while you can't see it (eyes shut, looking away)
	if not _watch.cut and _watch.t >= MannequinSnap.SNAP_AT and not seen(real_node.position) and not seen(pos):
		_watch.cut = true
		real_node.position = pos
		real_yaw = atan2(at.x - pos.x, at.z - pos.z)
		real_node.rotation.y = real_yaw
		set_pose(MannequinSnap.pose_at(_watch.t))
	# done: it goes back to hunting (or, for a guest, to following the host) when nobody here sees the change
	if _watch.t > MannequinSnap.TOTAL + 0.5 and (not puppet or not seen(real_node.position)):
		_watch = {}
		if not hunt.is_empty():
			hunt.move_to = null                  # the next step starts from where it stands now

## Debug: stands it where it has just caught a body at `at` facing `yaw` (a step behind, facing it), out of
## sight: call it with your eyes shut
func _debug_catch(at: Vector3, yaw: float) -> void:
	var caught := _spot_behind(at, yaw, 1.0)
	real_node.position = caught
	real_yaw = atan2(at.x - caught.x, at.z - caught.z)
	real_node.rotation.y = real_yaw

## Debug: open floor a few metres ahead of you, in plain view (your feet's height)
func _open_spot_ahead() -> Vector3:
	var p0 := player.global_position
	var fwd := player_forward()
	var at := p0 + fwd * 2.0
	for d in [3.5, 3.0, 2.5, 2.0]:
		var want: Vector3 = p0 + fwd * float(d)
		var c := nav.resolve(want, RADIUS + 0.2)
		if Vector2(c.x - want.x, c.z - want.z).length() < 0.05 and nav.clear_line(p0.x, p0.z, c.x, c.z, 0.3):
			at = c
			break
	at.y = p0.y
	return at

## Debug: summons it if this level has none out. False if it can't be had here, or a kill is already on.
func _debug_ready() -> bool:
	if snap.active or not _watch.is_empty() or player.blink == null or player.frozen:
		return false
	process_mode = Node.PROCESS_MODE_INHERIT
	visible = true
	if real_node == null:
		summoned = true
		reset()
	return real_node != null

## Debug (the animation tab's walker): its neck snap with the real thing round it. Your eyes shut, and it is
## standing just behind the walker when they open; then the kill is staged on the walker exactly as on a
## friend (you blink at the crack), at the walker's slow-motion pace. False if there's no mannequin to be had.
func debug_walker_kill(w: Node3D) -> bool:
	if not _debug_ready():
		return false
	_debug_walker_run(w)
	return true

func _debug_walker_run(w: Node3D) -> void:
	while player.blink.blinking():
		await get_tree().process_frame
	player.blink.blink(2.0)
	await player.blink.closed
	if not is_instance_valid(w):
		return
	var home: Vector3 = w.global_position
	var open := nav.resolve(home, RADIUS)
	if Vector2(open.x - home.x, open.z - home.z).length() > 0.05:
		w.move_home(_open_spot_ahead())        # it was summoned into a wall: out onto the floor, unseen
	w.prepare_kill()
	_debug_catch(w.global_position, w.kill_yaw())
	await get_tree().create_timer(0.3, false).timeout   # (still behind your lids)
	if is_instance_valid(w) and w.snap_neck():
		watch_kill(w.global_position, w.kill_yaw(), -1, w)

# The host says the real one has reached this survivor: play the neck snap here
func net_snap() -> void:
	if killed or snap.active or real_node == null or player.dead or player.frozen:
		return
	killed = true
	start_snap()

# ------------------------------------------------------------ presence
var stare := 0.0                              # s you have been watching them (eases back down when you stop)
var _watching := false
var _watch_t := 0.0

## Is any of them in plain sight: the real one, or one of the dozen decoys nearest you
func _any_in_sight() -> bool:
	if seen(real_node.position):
		return true
	var pp := player.global_position
	var near: Array = []
	for d in decoys:
		var dd := Vector2(d.x - pp.x, d.z - pp.z).length_squared()
		if dd < 16.0 * 16.0:
			near.append([dd, d])
	near.sort_custom(func(a, b): return a[0] < b[0])
	for k in mini(near.size(), 12):
		var d: Dictionary = near[k][1]
		if seen(Vector3(d.x, 0.0, d.z)):
			return true
	return false

func _update_stare(delta: float) -> void:
	if player.dead or player.frozen or player.blink == null:
		stare = 0.0
		return
	_watch_t -= delta
	if _watch_t <= 0.0:
		_watch_t = 0.1
		_watching = _any_in_sight()
	var watching := _watching
	if not watching:
		stare = maxf(0.0, stare - delta * 2.0)
		return
	if player.blink.blinking():
		return
	stare += delta
	player.unnerved = 0.5                          # light doesn't calm you while you hold their gaze
	player.sanity = maxf(0.0, player.sanity - minf(STARE_SANITY + stare * 0.02, STARE_SANITY_MAX) * delta)
	var urge := clampf((stare - STARE_STING) / STARE_RAMP, 0.0, 1.0)
	if urge > 0.0 and rng.randf() < urge * STARE_BLINK_RATE * delta:
		player.blink.blink(1.0 + urge * 0.8)          # tired eyes: the lids stay down a little longer
		stare *= 0.5

func _in_view(at: Vector3) -> bool:
	var to := Vector3(at.x - player.global_position.x, 0.0, at.z - player.global_position.z)
	if to.length() < 0.001:
		return true
	return to.normalized().dot(player_forward()) > 0.35

# Being near the real one is felt before it is seen: a heartbeat that quickens as it closes in, and
# the tubes above you dropping out when it is close and you are not looking its way.
func _update_presence(delta: float) -> void:
	var d := player.global_position.distance_to(real_node.global_position)
	if d < HEART_RANGE and Game.heart != null:
		var close := 1.0 - d / HEART_RANGE
		# staying near it wears your sanity down: up to 4 a second at arm's length
		Game.heart.feed("mannequin", 0.3 + 0.7 * close, 4.0 * close * close)
	light_cd -= delta
	if d < LIGHT_RANGE and light_cd <= 0.0 and not _in_view(real_node.global_position):
		light_cd = rng.randf_range(5.0, 12.0)
		if rng.randf() < 0.6 and level != null:
			var near_f: Array = []
			for f in level.lit:
				if f.black <= 0.0 and (f.pos as Vector3).distance_to(player.global_position) < 7.0:
					near_f.append(f)
			near_f.sort_custom(func(a, b): return (a.pos as Vector3).distance_squared_to(player.global_position) < (b.pos as Vector3).distance_squared_to(player.global_position))
			for i in mini(near_f.size(), rng.randi_range(1, 3)):
				level.cut_fixture(near_f[i], rng.randf_range(0.2, 0.7))

# ------------------------------------------------------------ whispers
# Get close to the real one and now and then something whispers right beside one ear. Random gaps,
# side, pitch, loudness and a random slice of the recording, so it never plays the same way twice.
func _update_whisper(delta: float) -> void:
	var d := player.global_position.distance_to(real_node.global_position)
	if d > WHISPER_RANGE:
		whisper_cd = maxf(whisper_cd, 3.0)      # a beat of grace after you step into range
		return
	whisper_cd -= delta
	if whisper_cd > 0.0:
		return
	whisper_cd = rng.randf_range(6.0, 16.0)
	if rng.randf() < 0.35:                      # and sometimes it stays quiet
		return
	if whisper_stream == null:
		if not ResourceLoader.exists(WHISPER_PATH):
			return
		whisper_stream = preload("res://scripts/Audio/sfx_pool.gd").get_stream(WHISPER_PATH)
	var closeness := 1.0 - clampf(d / WHISPER_RANGE, 0.0, 1.0)
	var right: Vector3 = player.cam.global_transform.basis.x
	# random side, but about half the time it is the side the real one is actually on: a clue
	var side := 1.0 if rng.randf() < 0.5 else -1.0
	var true_side := false
	var off := real_node.global_position - player.global_position
	if rng.randf() < 0.5 and absf(off.dot(right)) > 0.6:
		side = signf(off.dot(right))
		true_side = true
	var back: Vector3 = player.cam.global_transform.basis.z
	var pos: Vector3 = player.cam.global_position + right * side * rng.randf_range(0.5, 1.3) + back * rng.randf_range(0.0, 0.6)
	# beside your ear, not in the room: nothing muffles it (not even the bacteria's walls)
	var p: AudioStreamPlayer3D = scares.spawn3d(whisper_stream, pos, 0.7 + closeness * 1.1, "Scares", 1.5, rng.randf_range(0.75, 1.1), false)
	var len := whisper_stream.get_length()
	p.stop()
	p.play(rng.randf_range(0.0, maxf(len - 3.0, 0.0)))     # a random slice of it
	# the music fades out under it, then comes back once the whisper is gone
	var amb: Node = scares.get_parent().get_node_or_null("Audio/Ambience")
	if amb != null:
		amb.hush_for(0.05, 4.5)
	# a true-side whisper stays on its side; a random one drifts across to the other ear
	var tw := p.create_tween()
	var drift := right * side * (0.3 if true_side else -rng.randf_range(0.8, 2.0))
	tw.tween_property(p, "global_position", pos + drift, rng.randf_range(1.5, 3.5))
	tw.parallel().tween_property(p, "volume_db", -40.0, 3.5).set_delay(1.0)
	tw.tween_callback(p.queue_free)

# ================================================================= dev
func warp_to_room() -> void:
	if not summoned:
		summoned = true
		reset()
	var c := room_centre()
	# the open cell in (or at the doorway of) the room that is clearest of mannequins
	var best := Vector2i(-1, -1)
	var best_d := -1.0
	for x in range(room_box.position.x - 1, room_box.end.x + 2):
		for z in range(room_box.position.y - 1, room_box.end.y + 2):
			if nav.blocked(x, z) or not room_near.has(Vector2i(x, z)):
				continue
			var md := INF
			for d in decoys:
				md = minf(md, Vector2(d.x - x * CELL, d.z - z * CELL).length())
			if md > best_d:
				best_d = md
				best = Vector2i(x, z)
	if best.x < 0:
		return
	player.global_position = Vector3(best.x * CELL, 0.1, best.y * CELL)
	player.rotation.y = atan2(-(c.x - best.x * CELL), -(c.z - best.y * CELL))

func _unhandled_input(e: InputEvent) -> void:
	if Game.dev_keys and e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_F2 and e.shift_pressed:
		warp_to_room()

# ---------------------------------------------------------------- T.S.R.A. scanner
# Hold Q on it with the field scanner (scripts/Player/scanner.gd) to log it in the Threshold Dossier.
func _enter_tree() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("tsra_id", "mannequin")

## Where the scanner can take a reading off it right now; empty while it is away
func scan_points() -> Array:
	if not ready_ok or process_mode == Node.PROCESS_MODE_DISABLED or not is_visible_in_tree():
		return []
	var out := []
	if real_node and real_node.is_visible_in_tree():
		out.append(real_node.global_position + Vector3.UP * HEIGHT * 0.75)
	for d in decoys:
		out.append(global_transform * Vector3(d.x, HEIGHT * 0.75, d.z))
	return out

## C-4 deep scan (scan_readout.gd): which one is real, and where it is in its hunt / rest cycle.
## `at` is the scan point the reading is locked on (the real one's, or a decoy's)
func scan_behavior(at: Vector3) -> Dictionary:
	if real_node == null or Vector2(at.x - real_node.global_position.x, at.z - real_node.global_position.z).length() > 0.5:
		return {"state": "INERT FIXTURE", "detail": "NOT THE ACTIVE SPECIMEN", "danger": 0}
	if not awake:
		return {"state": "DORMANT", "detail": "ACTIVE SPECIMEN // NOTHING HAS WOKEN IT YET", "danger": 1}
	if rest_left > REST_TIME:
		return {"state": "DEEP DORMANCY", "detail": "ACTIVE SPECIMEN // WAKES IN %d S // LEAVE NOW" % ceili(rest_left), "danger": 1}
	if rest_left > 0.0:
		return {"state": "RESTING", "detail": "ACTIVE SPECIMEN // HUNTS AGAIN IN %d S" % ceili(rest_left), "danger": 1}
	return {"state": "HUNTING", "detail": "ACTIVE SPECIMEN // FROZEN ONLY WHILE WATCHED // DO NOT BLINK", "danger": 2}

# ---------------------------------------------------------------- debug console
func debug_active() -> bool:
	return process_mode != Node.PROCESS_MODE_DISABLED

func debug_despawn() -> void:
	process_mode = Node.PROCESS_MODE_DISABLED
	visible = false
	snap.finish()
	awake = false

func debug_spawn() -> bool:
	process_mode = Node.PROCESS_MODE_INHERIT
	visible = true
	reset()
	return true

## Debug: watch it kill another survivor, the way a friend sees it in co-op. Under a blink a stand-in
## (remote_player.gd, fed snapshots as the network would) appears a few metres in front of you, side-on,
## with the real one just behind it where it caught them; then the kill runs through net_watch_kill like
## the real thing (you blink at the crack), and the body lies there a while. False if this level has no
## mannequin, or a kill is already going on.
const DEBUG_VICTIM := 7777
func debug_watch_kill() -> bool:
	if Net.remotes.has(DEBUG_VICTIM) or not _debug_ready():
		return false
	_debug_watch_run()
	return true

func _debug_watch_run() -> void:
	while player.blink.blinking():
		await get_tree().process_frame
	player.blink.blink(2.0)
	await player.blink.closed
	# a clear spot ahead of you; they stand side-on (facing your left), it a step behind them
	var at := _open_spot_ahead()
	var yaw := player.rotation.y + PI / 2.0
	_debug_catch(at, yaw)
	var r: Node3D = load("res://scripts/Net/remote_player.gd").new()
	r.peer_id = DEBUG_VICTIM
	add_child(r)                                  # goes with the level (reset() clears it too)
	r.set_label("STAND-IN")
	Net.remotes[DEBUG_VICTIM] = r
	r.tree_exiting.connect(func(): Net.remotes.erase(DEBUG_VICTIM))
	# a snapshot every 0.05 s, as the network would: standing, torch on, playing; dead from TOTAL in
	var t := 0.0
	var kill_at := 0.3                            # (once they have a body, still behind your lids)
	var started := false
	var t0 := SnapBuffer.now()
	while is_instance_valid(r):
		t = SnapBuffer.now() - t0
		var dead := t >= kill_at + MannequinSnap.TOTAL
		r.push_state(SnapBuffer.now(), at, yaw, 0.0, 0.0, 2 | 8 | (4 if dead else 0), Game.level_index, Game.level_floor)
		if t >= kill_at and not started:
			started = true
			r.play_kill()
			net_watch_kill(DEBUG_VICTIM)
		# the body lies there a while, and goes when you aren't looking
		if t > 14.0 and (not seen(at) or t > 40.0):
			r.queue_free()
			return
		await get_tree().create_timer(0.05, false).timeout

## Debug: summon it and run the kill right now (it appears behind you, as in the real thing), to test the
## gasp / neck snap / voice without waiting for it to hunt you. False if this level has no mannequin.
func debug_snap_now() -> bool:
	if player.frozen or snap.active:
		return false
	process_mode = Node.PROCESS_MODE_INHERIT
	visible = true
	summoned = true
	reset()
	if real_node == null:
		return false
	killed = true
	start_snap()
	return true
