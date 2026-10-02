extends Node3D
## THE GRABBER. A gaunt, grinning thing in black, 2.3 m tall, with arms that hang past its knees.
##
##  HUNCH   It waits upside down on the ceiling of a dark stretch of corridor ahead of you, folded up, its long
##          arms dangling toward the floor and its face hanging under it. It only ever gets there, or leaves,
##          while nobody is looking. Almost silent: a joint creaking now and then, a breath.
##  DROP    Put your torch on it, stare at it, or walk underneath it, and it lets go: it falls, turning over,
##          lands in a crouch and unfolds a joint at a time, the head snapping up last.
##  CHASE   Then it runs at you, bent double, both arms reaching out in front. A shade slower than your
##          sprint: your stamina (and the adrenaline) decides it. A camera flash in its face sends it reeling
##          off into the dark for a while.
##  PEEK    Lose it and it stalks you from the corners: long fingers curl round a doorframe at head height,
##          then the head leans out, tilted on its side. Stare back and it snaps out of sight; ignore it and
##          the next corner is closer; walk at it and it comes for you. The third peek you ignore, it runs.
##  DRAG    If it reaches you it takes your ankle and drags you away down the corridors, walking backwards,
##          staring at you (grabber_drag.gd: a chance at each doorframe to grab on and tear loose). Fail and
##          you come to somewhere far off, alone, torch dead. It goes away for a few minutes either way.
##
## Its parts live beside it: grabber_body.gd (the model and its clips, built by tools/blender/build_grabber.py),
## grabber_drag.gd (the victim's side of the drag), grabber_net.gd (co-op: the host runs it, everyone else
## follows). Debug console: the GRABBER row (spawn / despawn / hunch / peek / chase / drag).

const GridNav := preload("res://scripts/World/grid_nav.gd")
const GrabberBody := preload("res://scripts/Entities/grabber/grabber_body.gd")
const GrabberDrag := preload("res://scripts/Entities/grabber/grabber_drag.gd")
const GrabberNet := preload("res://scripts/Entities/grabber/grabber_net.gd")
const CELL := 4.5
const RADIUS := 0.45
const STATES := ["away", "hunch", "drop", "land", "chase", "peek", "grab", "drag", "recoil", "flee"]

const FIRST_DELAY := Vector2(60.0, 120.0)     # s after the level starts before it first comes
const AWAY_ESCAPED := 90.0                    # s gone after you tore loose
const AWAY_TAKEN := Vector2(180.0, 300.0)     # s gone after it took someone
const AWAY_FLASHED := 40.0
const AWAY_RETRY := 6.0                       # no spot for it right now: look again in this long

const HUNCH_CELLS := Vector2i(3, 7)           # path cells from the one it waits for (13-31 m)
const MIN_CEILING := 3.6                      # m: under a lower ceiling it would be sitting on the floor
const RELOCATE_AFTER := 50.0                  # s waiting unnoticed and far off: it moves on, unseen
const UNDER_DIST := 3.2                       # m: walk this close under it and it drops
const STARE_DROP := 2.0                       # s of being looked at and it drops
const TORCH_COS := 0.97                       # ~14 degrees: the torch's hotspot on it
const TORCH_RANGE := 24.0
const SEE_COS := 0.55                         # a survivor's view cone, for "nobody is looking"
const SEE_RANGE := 50.0

const DROP_TIME := 0.5
const LAND_TIME := 1.15                       # of the 1.4 s land clip, then it runs

const CHASE_SPEED := 4.4                      # m/s: your sprint is 4.55
const ACCEL := 7.0
const LOSE_TIME := 6.0                        # s out of its sight and it goes to the corners
const CATCH_DIST := 1.2
const TURN_RATE := 8.0

const PEEK_PHASE := Vector2(30.0, 50.0)       # s it stalks the corners before going back up
const PEEK_CELLS := Vector2i(2, 5)
const PEEK_STARE := 1.1                       # s looked at, leaned out, before it snaps back
const PEEK_FLUSH := 6.0                       # m: come this close and it comes for you
const PEEK_IGNORED := 3
const PEEK_LEAN := 0.6                        # m its head moves out to the side

const DRAG_SPEED := 1.6
const DRAG_CELLS := Vector2i(5, 14)
const RECOIL_TIME := 1.6
const FLEE_SPEED := 3.6
const FLEE_TIME := 5.0

const FLASH_RANGE := 14.0
const FLASH_CONE := 0.6

var level: Node
var player: CharacterBody3D
var scares: Node
var nav: GridNav
var rng := RandomNumberGenerator.new()
var body: GrabberBody
var drag: GrabberDrag
var net: GrabberNet
var puppet := false
var enabled := false                          # the debug console's despawn turns it off

var state := "away"
var state_time := 0.0
var yaw := 0.0
var speed_now := 0.0
var away_left := 0.0
var ceiling := 0.0                            # m above its floor where it hangs
var target_id := -1                           # the survivor it is after
var stare := 0.0
var hunch_grace := 0.0                        # s the torch and eyes don't drop it (console spawn: to look at it)
var lost := 0.0
var goal := Vector3.ZERO
var flow := PackedInt32Array()
var reach := PackedInt32Array()
var _flow_key := -1
var _flow_timer := 0.0
# the corners
var peek_left := 0.0
var peek_side := ""                           # "r" / "l" while leaned round a corner, "" while hidden
var peek_ignored := 0
var peek_withdrawn := false
var _peek_retry := 0.0
# the drag
var path: Array = []                          # world points it walks back along
var path_i := 0
var victim_id := -1
var victim_local := false
# leaving
var _flee_away := 0.0                         # s it stays away once it has fled
var _flee_on_land := false                    # flashed off the ceiling: it runs instead of chasing
# sound
var _step := 0.0
var _creak := 4.0
var _disturb := 0.0

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	nav = GridNav.new(level)
	flow.resize(nav.n * nav.n)
	reach.resize(nav.n * nav.n)
	body = GrabberBody.new()
	if not body.build(self):
		body = null
	drag = GrabberDrag.new(self)
	net = GrabberNet.new(self)
	away_left = rng.randf_range(FIRST_DELAY.x, FIRST_DELAY.y)
	_set_state("away")

func _set_state(s: String) -> void:
	state = s
	state_time = 0.0
	visible = s != "away" and not (s == "peek" and peek_side == "")

# ================================================================= per frame
func _physics_process(delta: float) -> void:
	if drag.active():
		drag.update(delta)                    # this machine's own player is the one being dragged
	if Game.freeze_ai or body == null:
		return
	var online := Net.is_online()
	puppet = online and not Net.hosting
	if not Game.playing and not online:
		return
	if puppet:
		net.step(delta)
		_present(delta)
		return
	if online:
		net.send(delta)
	state_time += delta
	match state:
		"away": _think_away(delta)
		"hunch": _think_hunch(delta)
		"drop": _think_drop(delta)
		"land": _think_land(delta)
		"chase": _think_chase(delta)
		"peek": _think_peek(delta)
		"grab": _think_grab(delta)
		"drag": _think_drag(delta)
		"recoil": _think_recoil(delta)
		"flee": _think_flee(delta)
	rotation.y = yaw
	body.pose_root()
	_present(delta)

# ================================================================= who is where
## A survivor's eye and where they look: {pos, eye, look, torch, local, id, node}
func _viewer(s: Dictionary) -> Dictionary:
	var eye: Vector3 = s.pos + Vector3.UP * 1.6
	var look := Vector3.FORWARD
	var torch := false
	if s.local:
		look = -player.cam.global_transform.basis.z
		eye = player.cam.global_position
		torch = player.flash_on and player.battery > 0.0
	else:
		var r: Node3D = s.node
		var cp := cos(r.target_pitch)
		look = Vector3(-sin(r.rotation.y) * cp, sin(r.target_pitch), -cos(r.rotation.y) * cp)
		torch = r.torch_on
	return {"pos": s.pos, "eye": eye, "look": look, "torch": torch, "local": s.local, "id": s.id, "node": s.node}

func _viewers() -> Array:
	var out: Array = []
	for s in Net.survivors():
		out.append(_viewer(s))
	return out

## Is `at` in plain sight of this viewer, within their view cone (`cos_limit`)?
func _sees(v: Dictionary, at: Vector3, cos_limit := SEE_COS, range_m := SEE_RANGE) -> bool:
	var to: Vector3 = at - v.eye
	var d := to.length()
	if d > range_m or d < 0.01:
		return d < 0.01
	if to.normalized().dot(v.look) < cos_limit:
		return false
	return nav.clear_line(v.eye.x, v.eye.z, at.x, at.z)

func seen_by_anyone(at: Vector3, cos_limit := SEE_COS) -> bool:
	for v in _viewers():
		if _sees(v, at, cos_limit):
			return true
	return false

func _target() -> Dictionary:
	var best := Net.nearest_survivor(global_position, target_id)
	target_id = best.get("id", -1)
	return best

func _floor_y(at: Vector3, fallback: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 1.5, at + Vector3.DOWN * 4.0)
	q.exclude = [player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else fallback

## Every cell `lo`..`hi` path cells away in `reach` (filled by nav.bfs), shuffled: the places to try
func _cells_within(lo: int, hi: int) -> Array:
	var out: Array = []
	for k in reach.size():
		var d := reach[k]
		if d >= lo and d <= hi:
			out.append(k)
	out.shuffle()
	return out

## Height of the ceiling over the floor at `at` (INF when open to the sky or out of reach)
func _ceiling_over(at: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 1.0, at + Vector3.UP * 12.0)
	q.exclude = [player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y - at.y if hit else INF

# ================================================================= away, and choosing where to wait
func _think_away(delta: float) -> void:
	if not enabled or Game.outdoors:
		return
	away_left -= delta
	if away_left > 0.0:
		return
	if not _pick_hunch():
		away_left = AWAY_RETRY

## A dark stretch of ceiling a few cells along the way the one it wants is facing, out of everyone's sight
func _pick_hunch() -> bool:
	var s := _target()
	if s.is_empty():
		return false
	var sp: Vector3 = s.pos
	if not nav.bfs(GridNav.cell(sp.x), GridNav.cell(sp.z), reach):
		return false
	var fwd: Vector3 = s.get("fwd", Vector3.FORWARD)
	var n := nav.n
	var best := Vector3.INF
	var best_h := 0.0
	var best_score := -INF
	for k in _cells_within(HUNCH_CELLS.x, HUNCH_CELLS.y).slice(0, 40):
		var x: int = k / n
		var z: int = k % n
		var at := Vector3(x * CELL, sp.y, z * CELL)
		at.y = _floor_y(at, sp.y)
		var h := _ceiling_over(at)
		if not is_finite(h) or h < MIN_CEILING:
			continue
		var hang_at := at + Vector3.UP * (h - 1.2)
		if seen_by_anyone(hang_at, 0.3):
			continue
		var to := Vector3(at.x - sp.x, 0.0, at.z - sp.z).normalized()
		var score := to.dot(fwd) * 1.5 + rng.randf() * 0.6
		if level.has_method("tube_light_at"):
			score -= level.tube_light_at(hang_at) * 2.0
		if score > best_score:
			best_score = score
			best = at
			best_h = h
	if not best.is_finite():
		return false
	global_position = best
	ceiling = best_h
	var to_s := Vector3(sp.x - best.x, 0.0, sp.z - best.z)
	yaw = atan2(to_s.x, to_s.z)
	rotation.y = yaw
	stare = 0.0
	body.flip = 1.0
	body.hang = ceiling
	body.restart("hunch", 0.0)
	body.pose_root()
	_set_state("hunch")
	return true

# ================================================================= on the ceiling
func _think_hunch(delta: float) -> void:
	body.play("hunch")
	body.flip = 1.0
	body.hang = ceiling
	var head := body.head_pos()
	var chest := global_position + Vector3.UP * (ceiling - 0.6)
	var looked := false
	var nearest := INF
	hunch_grace = maxf(0.0, hunch_grace - delta)
	for v in _viewers():
		var flat := Vector2(v.pos.x - global_position.x, v.pos.z - global_position.z).length()
		nearest = minf(nearest, flat)
		if flat < UNDER_DIST:
			_drop()
			return
		if hunch_grace > 0.0:
			continue
		if v.torch and (_sees(v, head, TORCH_COS, TORCH_RANGE) or _sees(v, chest, TORCH_COS, TORCH_RANGE)):
			_drop()
			return
		if _sees(v, head, 0.93, 30.0):
			looked = true
	stare = stare + delta if looked else maxf(0.0, stare - delta * 0.5)
	if stare > STARE_DROP:
		_drop()
		return
	# nobody came: it moves on (while nobody is looking)
	if state_time > RELOCATE_AFTER and nearest > 30.0 and not seen_by_anyone(head, 0.3):
		if not _pick_hunch():
			_go_away(AWAY_RETRY)

func _drop() -> void:
	body.restart("land", 0.2)
	body.anim.speed_scale = 0.0              # held crouched while it falls
	var head := body.head_pos()
	scares.spawn3d(scares.synth("mannequin_creak"), head, 1.0, "Scares", 5.0, 0.8)
	var d := global_position.distance_to(player.global_position)
	if d < 20.0:
		scares.startle(0.9 * (1.0 - d / 25.0))
	_set_state("drop")

func _think_drop(_delta: float) -> void:
	var k := minf(1.0, state_time / DROP_TIME)
	body.flip = 1.0 - smoothstep(0.0, 1.0, k)
	body.hang = ceiling * (1.0 - k * k)       # it falls
	if k >= 1.0:
		body.flip = 0.0
		body.hang = 0.0
		body.anim.speed_scale = 1.0
		scares.spawn3d(scares.synth("thump"), global_position, 1.0, "Scares", 6.0, 0.8)
		scares.spawn3d(scares.synth("bone_crack"), global_position + Vector3.UP * 1.2, 0.8, "Scares", 3.0, 0.9)
		if global_position.distance_to(player.global_position) < 14.0:
			player.quake(0.9)
		_set_state("land")

func _think_land(delta: float) -> void:
	if state_time >= 0.5 and state_time - delta < 0.5:
		scares.spawn3d(scares.synth("bone_crack"), body.head_pos(), 0.6, "Scares", 3.0, 1.1)
	var s := _target()
	if not s.is_empty():
		yaw = lerp_angle(yaw, _yaw_to(s.pos), minf(1.0, delta * 3.0))
	if state_time >= LAND_TIME:
		if _flee_on_land:
			_flee_on_land = false
			_start_flee(AWAY_FLASHED)
		else:
			_start_chase()

# ================================================================= the chase
func _start_chase() -> void:
	lost = 0.0
	speed_now = maxf(speed_now, 1.5)
	_set_state("chase")

func _think_chase(delta: float) -> void:
	var s := _target()
	if s.is_empty():
		_go_away(AWAY_RETRY)
		return
	var sp: Vector3 = s.pos
	var p := global_position
	var d := Vector2(sp.x - p.x, sp.z - p.z).length()
	if d < 40.0 and nav.clear_line(p.x, p.z, sp.x, sp.z):
		lost = 0.0
	else:
		lost += delta
	if lost > LOSE_TIME:
		_start_peeking()
		return
	if d < CATCH_DIST and _can_take(s):
		_start_grab(s)
		return
	speed_now = move_toward(speed_now, CHASE_SPEED, ACCEL * delta)
	_move_toward(sp, speed_now, delta)
	body.play("chase", body.rate("chase", speed_now), 0.3)

func _can_take(s: Dictionary) -> bool:
	if s.local:
		return not player.dead and not player.frozen and player.spawn_grace <= 0.0 and not Game.god_mode
	return not s.node.dead

# ================================================================= the corners
func _start_peeking() -> void:
	peek_left = rng.randf_range(PEEK_PHASE.x, PEEK_PHASE.y)
	peek_ignored = 0
	peek_side = ""
	_peek_retry = 0.0
	speed_now = 0.0
	_set_state("peek")

func _think_peek(delta: float) -> void:
	peek_left -= delta
	var s := _target()
	if s.is_empty():
		_go_away(AWAY_RETRY)
		return
	if peek_side == "":
		# hidden, between corners
		visible = false
		if peek_left <= 0.0:
			_go_away(AWAY_RETRY)          # back up on the ceiling somewhere
			return
		_peek_retry -= delta
		if _peek_retry <= 0.0:
			_peek_retry = 0.5
			_pick_peek(s)
		return
	visible = true
	var head := body.head_pos()
	var sp: Vector3 = s.pos
	var d := Vector2(sp.x - global_position.x, sp.z - global_position.z).length()
	if d < PEEK_FLUSH:
		_start_chase()                    # you walked right up to it
		return
	var watched := false
	for v in _viewers():
		if _sees(v, head, 0.92, 40.0):
			watched = true
	var t := body.time()
	if watched and t > 0.6 and t < GrabberBody.PEEK_BACK:
		stare += delta
		if stare > PEEK_STARE:
			body.seek(GrabberBody.PEEK_BACK)     # it snaps back out of sight
			peek_withdrawn = true
	if body.done() or t >= body.length() - 0.05:
		if not peek_withdrawn:
			peek_ignored += 1
		peek_side = ""
		visible = false
		_peek_retry = rng.randf_range(1.5, 3.5)
		if peek_ignored >= PEEK_IGNORED:
			_pop_out(s)

## Behind a corner near the one it stalks: hidden where it stands, in sight once it leans out
func _pick_peek(s: Dictionary) -> bool:
	var sp: Vector3 = s.pos
	var eye: Vector3 = sp + Vector3.UP * 1.6
	if not nav.bfs(GridNav.cell(sp.x), GridNav.cell(sp.z), reach):
		return false
	var n := nav.n
	var lo := maxi(1, PEEK_CELLS.x - peek_ignored)       # closer every time it is ignored
	var hi := maxi(lo + 1, PEEK_CELLS.y - peek_ignored)
	var tries := 0
	for k in _cells_within(lo, hi):
		if tries >= 40:
			break
		var x: int = k / n
		var z: int = k % n
		var o: Vector2i = GridNav.NEIGHBOURS[rng.randi() % 4]
		if not nav.can_step(x, z, x + o.x, z + o.y):
			continue
		tries += 1
		# near the opening into the next cell
		var at := Vector3(x * CELL + o.x * 1.4, sp.y, z * CELL + o.y * 1.4)
		if not nav.open_at(at.x, at.z) or nav.clear_line(eye.x, eye.z, at.x, at.z):
			continue
		var face := Vector3(sp.x - at.x, 0.0, sp.z - at.z).normalized()
		var right := face.cross(Vector3.UP)
		var side := ""
		for c in ["r", "l"]:
			var lean: Vector3 = at + (right if c == "r" else -right) * PEEK_LEAN
			if nav.open_at(lean.x, lean.z) and nav.clear_line(eye.x, eye.z, lean.x, lean.z):
				side = c
				break
		if side == "":
			continue
		var head_at := at + Vector3.UP * 2.0 + (right if side == "r" else -right) * PEEK_LEAN
		if seen_by_anyone(head_at, 0.8):
			continue                      # it would lean out right in front of someone's eyes
		at.y = _floor_y(at, sp.y)
		global_position = at
		yaw = atan2(face.x, face.z)
		rotation.y = yaw
		peek_side = side
		peek_withdrawn = false
		stare = 0.0
		body.flip = 0.0
		body.hang = 0.0
		body.restart("peek_" + side, 0.0)
		body.pose_root()
		visible = true
		if global_position.distance_to(player.global_position) < 18.0:
			scares.spawn3d(scares.synth("mannequin_creak"), head_at, 0.5, "Scares", 3.0, 1.2)
		return true
	return false

## Ignored three times: it steps out and comes for you
func _pop_out(s: Dictionary) -> void:
	visible = true
	scares.spawn3d(scares.synth("stinger"), body.head_pos(), 0.9, "Scares", 6.0, 0.75)
	_start_chase()
	speed_now = CHASE_SPEED

# ================================================================= taking someone
func _start_grab(s: Dictionary) -> void:
	victim_id = s.id
	victim_local = s.local
	yaw = _yaw_to(s.pos)
	speed_now = 0.0
	path = _drag_path(s.pos)
	path_i = 0
	body.restart("grab", 0.1)
	_set_state("grab")
	if s.local:
		drag.start()
	else:
		Net.send_grabber_grab(s.id)

func _think_grab(delta: float) -> void:
	# it holds still, facing you, while its hand closes
	var v := _victim_pos()
	if v.is_finite():
		yaw = lerp_angle(yaw, _yaw_to(v), minf(1.0, delta * 6.0))
	if state_time >= GrabberDrag.GRAB_TIME:
		body.play("drag", 1.0, 0.25)
		_set_state("drag")

func _think_drag(delta: float) -> void:
	if state_time > GrabberDrag.DRAG_TIME + 6.0:
		_go_away(rng.randf_range(AWAY_TAKEN.x, AWAY_TAKEN.y))     # (never heard back)
		return
	var moving := path_i < path.size()
	if moving:
		var p := global_position
		var to: Vector3 = path[path_i] - p
		to.y = 0.0
		if to.length() < 0.3:
			path_i += 1
		else:
			var step := to.normalized() * DRAG_SPEED * delta
			var np := nav.resolve(p + step, RADIUS)
			global_position = Vector3(np.x, p.y, np.z)
			# walking backwards: it faces the way it came, at you
			yaw = lerp_angle(yaw, atan2(-to.x, -to.z), minf(1.0, delta * 5.0))
	body.play("drag", 1.0 if moving else 0.35, 0.25)

## A way back from where it took you: somewhere several cells off, away from the others, starting behind it
func _drag_path(victim: Vector3) -> Array:
	var p := global_position
	var cx := GridNav.cell(p.x)
	var cz := GridNav.cell(p.z)
	if not nav.bfs(cx, cz, reach):
		return []
	var n := nav.n
	var back := Vector3(p.x - victim.x, 0.0, p.z - victim.z).normalized()
	var best := -1
	var best_score := -INF
	for k in _cells_within(DRAG_CELLS.x, DRAG_CELLS.y).slice(0, 50):
		var x: int = k / n
		var z: int = k % n
		var dir := Vector3(x * CELL - p.x, 0.0, z * CELL - p.z).normalized()
		var score := dir.dot(back) * 2.0 + rng.randf()
		for s in Net.survivors():
			if s.id != victim_id:
				score -= maxf(0.0, 1.0 - Vector2(x * CELL - s.pos.x, z * CELL - s.pos.z).length() / 20.0) * 3.0
		if score > best_score:
			best_score = score
			best = x * n + z
	if best < 0:
		return []
	# walk the distances down from there to here
	var cells: Array = []
	var x := best / n
	var z := best % n
	var guard := 0
	while reach[x * n + z] > 0 and guard < 200:
		guard += 1
		cells.append(Vector3(x * CELL, p.y, z * CELL))
		var here := reach[x * n + z]
		var moved := false
		for o in GridNav.NEIGHBOURS:
			var ax: int = x + o.x
			var az: int = z + o.y
			if ax < 0 or az < 0 or ax >= n or az >= n:
				continue
			if reach[ax * n + az] == here - 1 and nav.can_step(ax, az, x, z):
				x = ax
				z = az
				moved = true
				break
		if not moved:
			break
	cells.reverse()
	return cells

func _victim_pos() -> Vector3:
	if victim_local:
		return player.global_position
	var r = Net.remotes.get(victim_id)
	return r.target_pos if r != null and is_instance_valid(r) else Vector3.INF

## Where the one it took comes to: at least `min_cells` of path from `from`, a dead end if it can find one
func far_cell(from: Vector3, min_cells: int) -> Vector3:
	if not nav.bfs(GridNav.cell(from.x), GridNav.cell(from.z), reach):
		return Vector3.INF
	var n := nav.n
	var best := -1
	var best_score := -INF
	var far := 0
	for k in reach:
		far = maxi(far, k)
	var need := mini(min_cells, maxi(1, far - 1))
	for k in _cells_within(need, far).slice(0, 120):
		var x: int = k / n
		var z: int = k % n
		var d := reach[k]
		var open := 0
		for o in GridNav.NEIGHBOURS:
			if nav.can_step(x, z, x + o.x, z + o.y):
				open += 1
		var score := float(d) * 0.05 + (1.5 if open == 1 else 0.0) + rng.randf()
		for s in Net.survivors():
			if not s.local:
				score -= maxf(0.0, 1.0 - Vector2(x * CELL - s.pos.x, z * CELL - s.pos.z).length() / 25.0) * 2.0
		if score > best_score:
			best_score = score
			best = x * n + z
	if best < 0:
		return Vector3.INF
	var at := Vector3((best / n) * CELL, from.y, (best % n) * CELL)
	at.y = _floor_y(at, from.y) + 0.05
	return at

## The drag ended (grabber_drag.gd, on the victim's machine): they tore loose, or it has them
func drag_result(escaped: bool) -> void:
	if puppet:
		Net.send_grabber_result(escaped)
		return
	_on_drag_result(escaped)

func _on_drag_result(escaped: bool) -> void:
	if state != "drag" and state != "grab":
		return
	if escaped:
		body.restart("land", 0.15)         # it reels down into a crouch, and rises
		_flee_away = AWAY_ESCAPED
		_set_state("recoil")
	else:
		_go_away(rng.randf_range(AWAY_TAKEN.x, AWAY_TAKEN.y))

## Net: this machine's player was just taken by the host's Grabber
func net_grabbed() -> void:
	drag.start()

## Net (host): how a guest's drag ended
func net_drag_result(peer_id: int, escaped: bool) -> void:
	if peer_id == victim_id:
		_on_drag_result(escaped)

func net_apply(t: float, m: Array) -> void:
	net.apply(t, m)

# ================================================================= reeling, fleeing, going
func _think_recoil(_delta: float) -> void:
	if state_time >= RECOIL_TIME:
		_start_flee(_flee_away)

func _start_flee(then_away: float) -> void:
	_flee_away = then_away
	var s := _target()
	var from: Vector3 = s.pos if not s.is_empty() else global_position
	var far := far_cell(from, 6)
	goal = far if far.is_finite() else global_position
	speed_now = 1.0
	_set_state("flee")

func _think_flee(delta: float) -> void:
	speed_now = move_toward(speed_now, FLEE_SPEED, ACCEL * delta)
	_move_toward(goal, speed_now, delta)
	body.play("run", body.rate("run", speed_now), 0.3)
	var gone := state_time > FLEE_TIME or Vector2(goal.x - global_position.x, goal.z - global_position.z).length() < 1.0
	if gone and not seen_by_anyone(body.head_pos()):
		_go_away(_flee_away)

func _go_away(seconds: float) -> void:
	away_left = seconds
	peek_side = ""
	speed_now = 0.0
	body.flip = 0.0
	body.hang = 0.0
	body.pose_root()
	_set_state("away")

# ================================================================= camera flash
## A camera flash went off at `origin`, aimed along `look` (flash_tool.gd; the host runs this for everyone's)
func flashed(origin: Vector3, look: Vector3) -> bool:
	if puppet or not visible or not enabled or state in ["away", "grab", "drag", "recoil", "flee"]:
		return false
	var head := body.head_pos()
	var to := head - origin
	if to.length() > FLASH_RANGE or to.normalized().dot(look) < FLASH_CONE:
		return false
	if not nav.clear_line(origin.x, origin.z, head.x, head.z):
		return false
	scares.spawn3d(scares.synth("stinger"), head, 0.8, "Scares", 6.0, 0.7)
	if state == "hunch":
		_drop()                           # it lets go, and runs once it lands
		_flee_on_land = true
		return true
	body.restart("land", 0.15)
	_set_state("recoil")
	_flee_away = AWAY_FLASHED
	state_time = RECOIL_TIME * 0.4       # a shorter stagger
	return true

# ================================================================= moving
func _yaw_to(at: Vector3) -> float:
	return atan2(at.x - global_position.x, at.z - global_position.z)

## Walk toward `to`: straight when it can see it, else down a flow field (cutting corners it can see past)
func _move_toward(to: Vector3, speed: float, delta: float) -> void:
	var p := global_position
	var dir := Vector3(to.x - p.x, 0.0, to.z - p.z)
	if dir.length() > 9.0 or not nav.clear_line(p.x, p.z, to.x, to.z):
		dir = _flow_dir(to)
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	yaw = lerp_angle(yaw, atan2(dir.x, dir.z), minf(1.0, delta * TURN_RATE))
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var np := nav.resolve(p + fwd.lerp(dir, 0.5).normalized() * speed * delta, RADIUS)
	global_position = Vector3(np.x, p.y, np.z)

func _flow_dir(to: Vector3) -> Vector3:
	var n := nav.n
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
			if ax < 0 or az < 0 or ax >= n or az >= n or not nav.can_step(x, z, ax, az):
				continue
			var v := flow[ax * n + az]
			if v >= 0 and v < best:
				best = v
				nx = ax
				nz = az
		if nx < 0:
			break
		x = nx
		z = nz
		if step == 0 or nav.clear_line(p.x, p.z, x * CELL, z * CELL):
			bx = x * CELL
			bz = z * CELL
		else:
			break
	return Vector3(bx - p.x, 0.0, bz - p.z)

# ================================================================= what each machine feels
## Its footfalls, the tubes stuttering over it, your heart: played on every machine for its own player
func _present(delta: float) -> void:
	if not visible or player == null:
		return
	var d := global_position.distance_to(player.global_position)
	var moving := state in ["chase", "flee", "drag"]
	if moving and body != null:
		_step -= delta
		if _step <= 0.0:
			var c: String = body.clip
			var period: float = {"chase": 0.6, "run": 0.8, "drag": 1.2}.get(c, 0.8)
			var sp: float = maxf(0.2, body.anim.speed_scale) if body.anim != null else 1.0
			_step = period * 0.5 / sp
			var loud: float = 1.0 if state == "chase" else 0.6
			scares.spawn3d(scares.synth("heel"), global_position, 0.9 * loud, "Scares", 5.0, rng.randf_range(0.8, 0.95))
			if state == "chase" and d < 12.0:
				player.quake(0.35 * (1.0 - d / 12.0))
	if state == "chase":
		_disturb -= delta
		if _disturb <= 0.0:
			_disturb = 0.45
			if level.has_method("disturb"):
				level.disturb(global_position, 7.0, 0.5)
	if state == "hunch":
		_creak -= delta
		if _creak <= 0.0:
			_creak = rng.randf_range(7.0, 14.0)
			if d < 22.0:
				if rng.randf() < 0.5:
					scares.spawn3d(scares.synth("mannequin_creak"), body.head_pos(), 0.35, "Scares", 3.0, rng.randf_range(0.8, 1.0))
				else:
					scares.breath_behind(body.head_pos(), 0.35)
	# your heart knows it is there
	if player.dead or not Game.playing:
		return
	var lvl := 0.0
	if state in ["chase", "drop", "land"]:
		lvl = 0.45 + 0.55 * clampf(1.0 - d / 25.0, 0.0, 1.0)
		# adrenaline: the Bacteria already ticks it every frame when it is about, so only nudge it then
		var ent: Node = get_parent().get_node_or_null("Entity")
		var ticked: bool = ent != null and ent.can_process() and ent.is_visible_in_tree()
		player.update_adrenaline(0.0 if ticked else delta, d < player.ADR_RANGE)
	elif state == "peek" and d < 30.0:
		lvl = 0.35
	elif state == "hunch" and d < 10.0:
		lvl = 0.25 * (1.0 - d / 10.0)
	if lvl > 0.0 and Game.heart != null:
		Game.heart.feed("grabber", lvl)

# ================================================================= T.S.R.A.
func _enter_tree() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("asra_id", "grabber")

## Where the scanner can take a reading off it right now; empty while it is away
func scan_points() -> Array:
	if not visible or body == null or state == "away":
		return []
	return [body.head_pos(), global_position + Vector3.UP * (ceiling - 0.8 if state == "hunch" else 1.4)]

const SCAN_STATES := {
	"hunch": ["INVERTED // DORMANT", "SUSPENDED FROM CEILING. DO NOT ILLUMINATE", 2],
	"drop": ["DESCENDING", "EVACUATE IMMEDIATELY", 3],
	"land": ["DESCENDING", "EVACUATE IMMEDIATELY", 3],
	"chase": ["PURSUIT", "SUBJECT ACQUIRED // BREAK LINE OF SIGHT", 3],
	"peek": ["OBSERVING FROM COVER", "HOLD EYE CONTACT. DO NOT IGNORE", 2],
	"grab": ["RELOCATING SUBJECT", "GRIP THE NEAREST FRAME", 3],
	"drag": ["RELOCATING SUBJECT", "GRIP THE NEAREST FRAME", 3],
	"recoil": ["DISENGAGED", "WITHDRAWING", 1],
	"flee": ["DISENGAGED", "WITHDRAWING", 1],
}

## C-4 deep scan (scan_readout.gd)
func scan_behavior(_at: Vector3) -> Dictionary:
	var s: Array = SCAN_STATES.get(state, ["UNKNOWN", "", 2])
	return {"state": s[0], "detail": s[1], "danger": s[2]}

# ================================================================= debug console
func debug_active() -> bool:
	return enabled and state != "away"

## Hang it from the ceiling somewhere ahead of you (or, failing that, just over you)
func debug_spawn() -> bool:
	enabled = true
	hunch_grace = 3.0
	if _pick_hunch():
		return true
	var at := player.global_position - player.global_transform.basis.z * 6.0
	if not nav.open_at(at.x, at.z):
		return false
	at.y = _floor_y(at, player.global_position.y)
	var h := _ceiling_over(at)
	if not is_finite(h) or h < 2.6:
		return false
	global_position = at
	ceiling = h
	yaw = _yaw_to(player.global_position)
	body.flip = 1.0
	body.hang = h
	body.restart("hunch", 0.0)
	_set_state("hunch")
	hunch_grace = 3.0
	return true

func debug_despawn() -> void:
	if drag.active():
		drag._abort()
		player.frozen = false
		Game.fx_reset()
	enabled = false
	_go_away(INF)

## The console's state buttons: hunch / peek / chase / drag
func debug_state(s: String) -> bool:
	enabled = true
	match s:
		"hunch":
			return debug_spawn()
		"peek":
			_start_peeking()
			return true
		"chase", "drag":
			# in front of you, backing off until nothing is in between (as killer.gd's spawn)
			var p := player.global_position
			var fwd := -player.global_transform.basis.z
			fwd.y = 0.0
			fwd = fwd.normalized()
			var dist := 8.0 if s == "chase" else 1.0
			var at := p + fwd * dist
			while dist > 1.0 and not (nav.open_at(at.x, at.z) and nav.clear_line(p.x, p.z, at.x, at.z)):
				dist -= 0.5
				at = p + fwd * dist
			at = nav.resolve(at, RADIUS)
			at.y = _floor_y(at, p.y)
			global_position = at
			yaw = _yaw_to(player.global_position)
			body.flip = 0.0
			body.hang = 0.0
			body.pose_root()
			if s == "chase":
				_start_chase()
			else:
				_start_grab(Net.survivors()[0] if not Net.survivors().is_empty() else {"id": 1, "local": true, "pos": player.global_position, "node": player})
			return true
	return false
