extends "res://scripts/Player/player_view.gd"
## The scripted scene when [E] works a door, and the door lookups that feed it.

# ---------------------------------------------------------------- door interaction: the scripted scene
## [E] on a door plays a short scene with the player's body, eyes and left hand (the torch stays in the
## right). Opening, from shut: step up to it, eyes down to the knob, reach and turn it; the latch gives and
## the leaf falls ajar and you look through the gap, then the push, and you follow it through the doorway.
## Shutting: turn to it, take the knob, pull it to you (backing off if it comes your way) until it knocks shut.
## The left hand does it (wall_hand.gd DOOR): it reaches up on a curve, the fingers open, and closes on the handle
## (a squeeze past, then easing); it twists the knob / presses the lever down, and holds it so while the latch
## gives. Then, by the way picked (DS_WAYS): it lets go and goes to the flat of the leaf and pushes it wide, or
## keeps hold and pushes the handle. Either way the hand goes with the leaf as far as the arm reaches, then lets
## go of it (the palm pushing off) and drops away, the leaf swinging on. A glass door's bar, or a door already
## ajar, is just pushed.
## The scene tells the door when the knob turns (turn_knob: the open sound starts) and when the pull starts
## (pull); door.gd times the leaf and the sounds from there. Mouse look and walking come back at the end.
const DS_STAND := 0.7                   # m out from the door, square to the middle of it: where you open it
const DS_THROUGH := 1.4                 # m past it on the far side: where the walk through ends
const DS_STEP := 1.5                    # m/s stepping up to it
const DS_WALK := 1.05                   # m/s through: slow, careful
const DS_TURN := 1.6                    # rad/s the most the body turns
const DS_LOOK_GLIDE := 4.0              # 1/s: how quickly the eyes move on to the next thing looked at
const DS_PULL_AT := 0.4                 # m: shutting, you keep this far from the knob (the hand on it)
const DS_PULL_REACH := 0.55             # m: further than this from the knob, you step to it
const DS_STAND_HANDLE := 0.55           # m out from the door you stand to open it (you lean in to the handle from there)
const DS_FOLLOW := 0.16                 # m you step in after the door as the latch gives and you push
const DS_LEAN := Vector3(-0.03, -0.14, -0.19)   # m, camera space: reaching for the handle you lean in from the hips
const DS_ASIDE := 0.14                  # m the handle is to your left of your middle (the left hand takes it)
# the ways a door gets opened from shut, one picked each time by its odds:
#   pace   the swing takes this many times its usual time (door.gd pace)
#   ajar   s the leaf hangs ajar before the push: the hand going from the handle to the leaf, a look through the gap
#   palm   the hand goes to the flat of the leaf to push (else it pushes on the handle it holds)
#   push   how hard: the weight going in behind the hand, the head with it
#   look   how long and how far the head goes in to look through the gap
#   turn   s the turn of the handle takes
const DS_WAYS := [
	{"name": "palm", "odds": 3, "pace": 1.0, "ajar": 0.12, "palm": true, "push": 1.0, "look": 1.0, "turn": 0.14},
	{"name": "handle", "odds": 3, "pace": 0.9, "ajar": 0.0, "palm": false, "push": 0.8, "look": 0.7, "turn": 0.12},
	{"name": "careful", "odds": 1, "pace": 1.15, "ajar": 0.35, "palm": true, "push": 0.45, "look": 1.4, "turn": 0.22},
	{"name": "shove", "odds": 1, "pace": 0.8, "ajar": 0.15, "palm": true, "push": 1.7, "look": 0.4, "turn": 0.1},
]

func trigger_door_camera_animation(door: Node3D, opening: bool, swing_dir: float) -> void:
	_door_anim_active = true
	_ds = door
	_ds_t = 0.0
	_ds_open = opening
	_ds_swing = swing_dir
	_ds_pushed = false
	_ds_side = door.side_of(global_position) if door.has_method("side_of") else 1.0
	if not opening and door.has_method("face_normal"):
		# shutting, the knob on the face that looks your way (the leaf may be swung either side of you)
		_ds_side = 1.0 if door.face_normal(1.0).dot(global_position - door.knob_at(1.0)) > 0.0 else -1.0
	_ds_k = -1.0
	_ds_look_ok = false
	var knob: Vector3 = door.knob_at(_ds_side) if door.has_method("knob_at") else door.global_position
	_ds_kside = 1.0 if (cam.global_transform.basis.inverse() * (knob - cam.global_position)).x >= 0.0 else -1.0
	# how it's opened this time
	var odds := 0
	for w in DS_WAYS:
		odds += int(w.odds)
	var roll := randi() % odds
	for w in DS_WAYS:
		roll -= int(w.odds)
		if roll < 0:
			_ds_way = w
			break
	var kind: String = door.handle_kind() if door.has_method("handle_kind") else "knob"
	_ds_grip = {"knob": WallHand.Grip.KNOB, "lever": WallHand.Grip.LEVER, "bar": WallHand.Grip.BAR}.get(kind, WallHand.Grip.KNOB)
	_ds_latched = door.latched() if door.has_method("latched") else true
	if "pace" in door:
		door.pace = float(_ds_way.pace) if opening else 1.0
		door.ajar = float(_ds_way.ajar) if opening and _ds_latched else 0.0
	# where you stand to open it: before the handle, a little to its right so the left hand takes it
	# (door-local: facing the door from side s, your left is +s along z)
	var g: Vector3 = door.grip_at(_ds_side) if door.has_method("grip_at") else knob
	_ds_z = door.to_local(g).z - _ds_side * DS_ASIDE
	peek.reset()
	_corner_on = false
	_swinging = false

func _end_door_scene() -> void:
	if _ds_ghost != null and is_instance_valid(_ds_ghost):
		remove_collision_exception_with(_ds_ghost)
	_ds_ghost = null
	if _ds != null and is_instance_valid(_ds) and "scene_body" in _ds:
		_ds.scene_body = null
	_door_anim_active = false
	_ds = null
	if torch != null:
		torch.set_grab(false, -1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		torch.set_door(false)

## One tick of the scene: where the body goes, where the eyes go, whether the hand is on the door, and the
## head's own motion on top (_door_cam_pos / _door_cam_rot, camera space). Stands in for the walking update.
func _door_scene(dt: float) -> void:
	var d = _ds                        # (untyped: the door script's own members)
	if d == null or not is_instance_valid(d) or not d.has_method("knob_at"):
		_end_door_scene()
		return
	_ds_t += dt
	var t := _ds_t
	var s := _ds_side
	var knob: Vector3 = d.knob_at(s)
	var goal := global_position
	var spd := DS_STEP
	var look := knob
	var look_rate := 5.0
	var hand := false
	var palm := 0.0                   # the hand: 0 on the handle .. 1 flat on the leaf
	var turn := 0.0                   # the handle turned
	var press := 0.0                  # leaning into the push
	var way := _ds_way
	var walk_through := false
	var walk := Vector3.ZERO
	var pos := Vector3.ZERO
	var rot := Vector3.ZERO           # pitch, yaw, roll
	var ks := _ds_kside
	var done := false
	var k := _ds_k if _ds_k >= 0.0 else 1e6      # (not yet: every later beat stays in the future)
	if _ds_open:
		var lp: Vector3 = d.to_local(global_position)
		# step up before the handle, a little to its right; after the push, straight through along its middle line
		goal = d.to_global(Vector3(s * DS_STAND_HANDLE, 0.0, _ds_z))
		spd = DS_STEP
		# there and the hand closed on it: turn it (the open sound starts; the latch gives LATCH_AFTER into it)
		var there := Vector2(goal.x - global_position.x, goal.z - global_position.z).length() < 0.12
		if _ds_k < 0.0 and ((t > 0.35 and there and (torch == null or torch.door_ready())) or t > 1.5):
			_ds_k = t
			k = t
			d.turn_knob()
		var r: float = k + float(d.LATCH_AFTER)       # the latch gives, the leaf falls ajar
		var p: float = k + float(d.push_after())      # the push
		# as it gives, a short step in after it (the hand stays with the leaf, the weight goes in behind it)
		goal = d.to_global(Vector3(s * (DS_STAND_HANDLE - DS_FOLLOW * smoothstep(r - 0.05, p + 0.2, t)), 0.0, _ds_z))
		var pushed_only: bool = _ds_grip == WallHand.Grip.BAR or not _ds_latched
		# the hand: up to the handle, turned and held while the latch gives; then to the leaf, or kept on the handle
		hand = t > 0.2 and t < p + 1.4
		if not pushed_only:
			var tt: float = float(way.turn)
			turn = smoothstep(k - 0.02, k + tt, t) * (1.0 - smoothstep(r + 0.08, r + 0.08 + tt * 1.5, t))
		if pushed_only or (bool(way.palm) and t > r + 0.04):
			palm = 1.0
		press = float(way.push) * smoothstep(p - 0.12, p + 0.04, t) * (1.0 - smoothstep(p + 0.2, p + 0.65, t))
		if t > r - 0.05 and t < r + 0.1:              # the latch going: a nudge on the handle that cracks it open
			press = maxf(press, 0.5 * sin(PI * (t - r + 0.05) / 0.15))
		if t > p + 0.15 + 0.1 * float(way.look):
			walk_through = true
			var along: Vector3 = d.global_basis.x.normalized() * -s
			var across: Vector3 = d.global_basis.z.normalized()
			walk = along * DS_WALK + across * clampf(-lp.z * 4.0, -0.5, 0.5)
			if _ds_ghost == null and d.get("leaf_body") != null:
				_ds_ghost = d.leaf_body
				add_collision_exception_with(_ds_ghost)
		# a glance down to the knob (not a stare), then through the gap, then the room ahead
		if t < r:
			# the knob in the lower third of the view, the door above it (looking straight down at a knob from
			# close up the door's edges splay and the view fills with wood)
			look = knob.lerp(d.to_global(Vector3(s * 0.2, 1.3, 0.15)), 0.45)
			look_rate = 4.0
		elif t < p + 0.25 * float(way.look):
			look = d.to_global(Vector3(-s * 2.5, 1.55, 0.45))
			look_rate = 3.0
		else:
			look = d.to_global(Vector3(-s * 5.0, 1.6, 0.0))
			look_rate = 2.5
		# reaching for the knob: a small dip; turning it (the rattle, the sound's first 0.15 s): a twitch of the head
		# leaning in to the handle from the hips while the hand's on it, eased in and out (no roll: it read as the
		# floor tipping)
		var wr := smoothstep(0.1, 0.65, t) * (1.0 - smoothstep(p + 0.1, p + 0.7, t))
		pos += DS_LEAN * wr
		var wk := smoothstep(k, k + 0.06, t) * (1.0 - smoothstep(k + 0.1, k + 0.2, t))
		rot.z += ks * 0.012 * wk
		# the look through the gap: the head goes a little in toward it (a careful one further, and stays)
		var lk: float = float(way.look)
		var wp := smoothstep(r, r + 0.2 * lk, t) * (1.0 - smoothstep(p + 0.05, p + 0.35, t))
		pos += Vector3(ks * 0.03, -0.01, -0.05) * wp * minf(lk, 1.3)
		rot.z += -ks * 0.02 * wp * minf(lk, 1.3)
		# the push: weight forward behind the hand (a shove throws the shoulder in, the head turning with it)
		var pw: float = float(way.push)
		var wu := smoothstep(p - 0.08, p + 0.12 + 0.1 / pw, t) * (1.0 - smoothstep(p + 0.4, p + 0.9, t))
		pos += Vector3(0.006 * pw, -0.01 * pw, -0.035 * pw) * wu
		rot.y += -0.012 * pw * wu
		rot.z += 0.01 * (pw - 1.0) * wu
		if t >= p and not _ds_pushed:
			_ds_pushed = true
			if torch != null: torch.nudge_door(true, _ds_swing)
		done = s * lp.x < -DS_THROUGH or t > p + 4.0
	else:
		var flat := Vector3(global_position.x - knob.x, 0.0, global_position.z - knob.z)
		# the leaf swung away from you: you go in by it, and it follows you out as you pull (it passes you)
		if _ds_ghost == null and d.get("leaf_body") != null:
			_ds_ghost = d.leaf_body
			add_collision_exception_with(_ds_ghost)
		# which side of the doorway you're on, and whether the handle is on it too (the leaf swung your way, or
		# barely open) or round the far side (it swung away from you through the doorway)
		var pl: Vector3 = d.to_local(global_position)
		var mine: float = signf(pl.x) if absf(pl.x) > 0.05 else s
		var near_side: bool = (d.to_local(knob) as Vector3).x * mine > -0.05
		if near_side:
			# keep at arm's length from the knob: step to it if it's far, back off as it comes to you
			if flat.length() > DS_PULL_REACH or t > k:
				goal = Vector3(knob.x, global_position.y, knob.z) + flat.normalized() * DS_PULL_AT
		else:
			# you don't go after it: a step up to the doorway on your side and it's swung to from there
			goal = d.to_global(Vector3(mine * 0.6, pl.y, clampf(pl.z, -0.3, 0.3)))
		var in_reach: bool = near_side and flat.length() <= DS_PULL_REACH + 0.05
		# the hand on it (or nothing to reach): pull (the door times its knock into the frame to the close sound)
		if _ds_k < 0.0 and t > 0.3 and ((in_reach and (torch == null or torch.door_ready())) or not near_side or t > 1.3):
			_ds_k = t
			k = t
			d.pull()
		var shut: float = k + float(d.CLOSE_TIME)    # it meets the frame
		if t > shut - 0.1:
			# shut (or nearly): a step back off it, clear of the leaf before it's solid to you again
			goal = d.to_global(Vector3(mine * maxf(absf(pl.x), 0.55), pl.y, pl.z))
		look = knob if t < k + 0.3 else d.to_global(Vector3(s * 0.2, 1.4, 0.0))
		look_rate = 4.0 if t < k + 0.3 else 2.0
		hand = near_side and t > 0.15 and t < shut           # (round the far side it's out of reach: no hand in the air)
		press = -0.6 * smoothstep(k - 0.05, k + 0.2, t)             # pulling: the hand comes back with it
		var wr := smoothstep(0.1, 0.35, t) * (1.0 - smoothstep(k, k + 0.3, t))
		pos += Vector3(-0.015, -0.06, -0.05) * wr      # bending to the handle
		rot.z += -ks * 0.02 * wr
		# the pull: weight back, head up a touch
		var wl := smoothstep(k - 0.05, k + 0.25, t) * (1.0 - smoothstep(shut - 0.1, shut + 0.3, t))
		pos += Vector3(0.0, 0.0, 0.04) * wl
		rot += Vector3(0.02, -ks * 0.025, -ks * 0.02) * wl
		# the knock: a small flinch of the head as it shuts
		var wh := smoothstep(shut, shut + 0.04, t) * (1.0 - smoothstep(shut + 0.06, shut + 0.25, t))
		pos += Vector3(0.0, 0.0, 0.012) * wh
		rot.x += 0.01 * wh
		done = (t > shut + 0.35 and not d.blocked and absf((d.to_local(global_position) as Vector3).x) > 0.45) or t > 6.0
	# the body: walk to the goal
	var to := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	var wish := to.normalized() * minf(spd, to.length() * 3.5) if to.length() > 0.02 else Vector3.ZERO
	if walk_through:
		wish = walk
	velocity.x = move_toward(velocity.x, wish.x, ACCEL_GROUND * SPEED * dt)
	velocity.z = move_toward(velocity.z, wish.z, ACCEL_GROUND * SPEED * dt)
	if not is_on_floor():
		velocity.y = maxf(velocity.y - GRAVITY * dt, -fall_speed_max)
	move_and_slide()
	# the eyes: the point looked at glides from one beat's to the next (switching straight to a new one, the head
	# whipped round), the body turns to it, the head pitches to it
	if not _ds_look_ok:
		_ds_look = cam.global_position - cam.global_basis.z * 2.0
		_ds_look_ok = true
	_ds_look = _ds_look.lerp(look, 1.0 - exp(-dt * DS_LOOK_GLIDE))
	look = _ds_look
	var to_look := look - cam.global_position
	var yaw_goal := atan2(-to_look.x, -to_look.z)
	var yaw_step := clampf(wrapf(yaw_goal - rotation.y, -PI, PI) * (1.0 - exp(-dt * look_rate)), -DS_TURN * dt, DS_TURN * dt)
	rotate_y(yaw_step)
	var pitch_goal := clampf(atan2(to_look.y, Vector2(to_look.x, to_look.z).length()), -1.1, 0.6)
	var base := cam.rotation.x - pitch_applied
	cam.rotation.x += (pitch_goal - base) * (1.0 - exp(-dt * look_rate))
	_door_cam_pos = pos
	_door_cam_rot = rot
	# the rest of the body as walking would have it
	var moving := wish.length() > 0.25
	is_moving = moving
	is_sprinting = false
	is_crouching = false
	eye = lerpf(eye, STAND_H, minf(1.0, dt * 10.0))
	(shape.shape as CapsuleShape3D).height = eye + 0.1
	shape.position.y = (eye + 0.1) / 2.0
	_update_stamina(dt, false, false)
	peek.update(dt, self, eye, false)
	if torch:
		torch.set_hug(false, Vector3.ZERO, Vector3.ZERO, false)
		torch.set_squeeze(false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		torch.set_grab(false, -1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		# the leaf's own face and latch way for the handle and the push (the hand goes round with it as it swings)
		var leaf_n: Vector3 = d.face_normal(s)
		var leaf_l: Vector3 = d.latch_dir()
		torch.set_door(hand, d.grip_at(s), d.face_at(s, 1.2, 0.2), leaf_n, leaf_l, _ds_grip, palm, turn, press)
		torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, false)
		torch.update(dt, flash_on and not dead, false, moving, bob)
	if shadow_body:
		shadow_body.update(moving, false, false, dead, Vector2(velocity.x, velocity.z).length())
	_update_flashlight(dt)
	_update_sanity(dt)
	_update_head(dt, Vector2(0.0, -1.0) if moving else Vector2.ZERO, false, false, moving)
	if done:
		_end_door_scene()

## Outside the scene the head's door motion eases back out
func _update_door_camera(dt: float) -> void:
	if _door_anim_active:
		return
	_door_cam_pos = _door_cam_pos.lerp(Vector3.ZERO, minf(1.0, dt * 8.0))
	_door_cam_rot = _door_cam_rot.lerp(Vector3.ZERO, minf(1.0, dt * 8.0))

func _near_door() -> bool:
	if focused_door != null:
		return true
	var cp := global_position
	_refresh_door_cache()
	for d in _cached_door_nodes:
		if is_instance_valid(d) and d is Node3D:
			var d_pos: Vector3 = (d as Node3D).global_position
			var dist := Vector2(cp.x - d_pos.x, cp.z - d_pos.z).length()
			if dist < 3.2 and absf(cp.y - d_pos.y) < 2.5:
				return true
	return false

var _cached_doors: Array = []         # "doors" + "interactables": _find_interactable_door
var _cached_door_nodes: Array = []    # "doors" only: _near_door
var _door_cache_t := 0.0

## One group scan a second, shared by both door queries. An empty list re-scans every call (a level
## that is still loading), as the uncached lookup did.
func _refresh_door_cache() -> void:
	var now := Time.get_ticks_msec() * 0.001
	if now - _door_cache_t > 1.0 or _cached_door_nodes.is_empty() or _cached_doors.is_empty():
		_door_cache_t = now
		_cached_door_nodes = get_tree().get_nodes_in_group("doors")
		_cached_doors = _cached_door_nodes + get_tree().get_nodes_in_group("interactables")

func _find_interactable_door() -> Node:
	if dead or frozen or Game.draw_mode or Game.noclip:
		return null
	var cam_pos := cam.global_position
	var cam_fwd := -cam.global_transform.basis.z
	
	# 1. Direct raycast through reticle
	var space := get_world_3d().direct_space_state
	if space != null:
		var ray_end := cam_pos + cam_fwd * 2.8
		var query := PhysicsRayQueryParameters3D.create(cam_pos, ray_end, 1 | 2)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var collider: Object = hit.collider
			var d := _get_door_from_node(collider)
			if d != null and d.has_method("can_interact") and d.can_interact(cam_pos):
				return d
				
	# 2. View-cone / proximity query for nearby doors within reach (handles open doorways and side angles)
	_refresh_door_cache()

	var best_door: Node = null
	var best_dot := 0.62
	for n in _cached_doors:
		if not is_instance_valid(n): continue
		var dpos: Vector3 = (n as Node3D).global_position
		if cam_pos.distance_squared_to(dpos) > 16.0: continue
		if n.has_method("can_interact") and n.can_interact(cam_pos):
			var target_pos: Vector3 = n.get_handle_global_pos() if n.has_method("get_handle_global_pos") else dpos
			var to_door := (target_pos - cam_pos).normalized()
			var dot := cam_fwd.dot(to_door)
			var dist := cam_pos.distance_to(target_pos)
			if dist < 2.6 and dot > best_dot:
				best_dot = dot
				best_door = n
	return best_door

func _get_door_from_node(node: Object) -> Node:
	if node == null:
		return null
	if node.has_method("interact"):
		return node as Node
	if node.has_meta("door"):
		return node.get_meta("door") as Node
	if node is Node:
		var p := (node as Node).get_parent()
		if p != null:
			if p.has_method("interact"): return p
			if p.has_meta("door"): return p.get_meta("door") as Node
			var pp := p.get_parent()
			if pp != null:
				if pp.has_method("interact"): return pp
				if pp.has_meta("door"): return pp.get_meta("door") as Node
	return null
