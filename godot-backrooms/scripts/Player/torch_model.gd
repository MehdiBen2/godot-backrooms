extends Node3D
## The torch in your hand (models/flashlight.glb), low-right in view, held by your right arm
## (models/player/playerarms.glb, built by tools/build_player_arms.py: whole arms, shoulder to fingertips,
## the fist closed on this torch's barrel): the arm brings it up when you switch it on and lowers it out of
## view when you switch it off. Swings with your stride, dips while you sprint and crouch, and jerks up across
## your face when something is right in front of you (flinch()).
## Peeking round a wall edge (peek.gd, set_peek()), the hand on the wall's side takes hold of the edge and
## the other one hangs low, only just in view, with the torch if it's on (wall_hand.gd): peeking left the
## right hand goes on the wall, so the torch is passed to the left hand first, below the view. The left
## arm is out of view otherwise.
## Standing with the torch up, the hand doesn't stay frozen: every few seconds it squeezes the barrel, rolls
## its fingers off it and back, or opens and takes a fresh hold (FIDGETS). And when the beam stutters it
## gives the torch a couple of sharp knocks (smack()).
## swap() changes the batteries: the right arm turns the torch level, the left hand comes up, unscrews the
## tail cap, the old cells drop out, the new pair goes in and the cap goes back on (TorchReload, close to
## 7 s). The light is out while the cap is off: swap_started / swap_dark / swap_done tell the player when.
## A child of the camera, built by the player. Without the arms model the torch floats on its own.

const MODEL := "res://models/flashlight.glb"
const ARMS := "res://models/player/playerarms.glb"
const LENGTH := 0.27
const POS := Vector3(0.2, -0.2, -0.38)
const ROT := Vector3(0.16, 0.14, 0.0)
const ARMS_SCALE := 0.6           # the arms model is built about 1.7x life size
const GRIP_BACK := 0.018          # the fist closes on the handle this far behind the torch's middle
const PICKUP := "TorchPickup"     # arm swings the torch up into view (played backwards to put it away)
const HOLD := "TorchHold"         # held up, breathing
const FLINCH := "TorchFlinch"     # thrown up across the face, trembling, then slowly back down
const FIDGETS: Array[String] = ["TorchSqueeze", "TorchFingers", "TorchRegrip"]   # one-shots over the hold
const SMACK := "TorchSmack"       # two sharp knocks, for a torch that flickers
const RELOAD := "TorchReload"     # the battery swap, both hands
const CELLS := "res://models/aa_batteries.glb"
const CELLS_LENGTH := 0.07        # m: the new pair, in the left fist
const SWAP_OUT := 1.50            # s into the swap: the cap comes loose and the light dies
const SWAP_IN := 5.50             # the cap is tight again: the light is back, on the new cells
const SWAP_CELLS := Vector2(3.10, 4.18)   # the new pair is in the left hand from, to
const SWAP_WAIT := 1.5            # s it waits for the torch to be up in the right hand before it skips the show
const FIDGET_EVERY := Vector2(6.0, 14.0)   # s from one fidget to the next
const SMACK_GAP := Vector2(4.0, 8.0)       # s before it will knock the torch again
const WallHand := preload("res://scripts/Player/wall_hand.gd")
const HUG_SPREAD := 0.12          # m: each hand's fingertips are this far off the middle of the wall in front
const HUG_LOWER := 0.12           # m below eye height the hands go

signal swap_started               # the hands begin (audio/battery_swap.wav is cut to the clip)
signal swap_dark(dark: bool)      # the cap is off, no light / it's back on
signal swap_done                  # the new cells are in
signal swap_cut                   # it was cut short (a flinch): the sound has to stop
const TIP_REACH := 0.72           # m: how far ahead of the camera the torch's front reaches at rest
const WALL_GAP := 0.04            # m kept between the torch's front and a wall
const WALL_TUCK := 0.07           # m the torch also drops, and
const WALL_TILT := 0.45           # rad it noses up, as it's pulled right back
const CROUCH_DIP := 0.03          # m the torch hand sits lower crouched

const SWAY_W := 15.0              # rad/s: how fast the hands catch up with the view
const SWAY_Z := 0.45              # damping: under 1 so they overshoot a touch and settle
const SWAY_MAX_RATE := 8.0        # rad/s: a mouse flick beyond this doesn't throw them further
const SWAY_MAX_VEL := 3.0         # m/s

var raise := 0.0
var lower := 0.0
var sway_amount := 1.0            # 0 = hands rigid with the camera (player.gd: head bob / camera shake settings)

var _have_prev := false
var _prev_basis := Basis.IDENTITY
var _prev_pos := Vector3.ZERO
var _lag := Vector3.ZERO          # camera space, m: how far the hands trail
var _lag_v := Vector3.ZERO
var _lag_rot := Vector3.ZERO      # rad (pitch, yaw, roll)
var _lag_rot_v := Vector3.ZERO

var _torch: Node3D                # the fitted flashlight
var _anim: AnimationPlayer
var _grip: Node3D                 # the grip the torch rides: TorchGrip on the right hand, or its mirror on the left
var _grips: Array[Node3D] = [null, null]   # left, right
var _torch_in := 1                # which hand has it (WallHand.LEFT / RIGHT)
var _on := false
var _flinching := false
var _in_reach := false            # the edge is near enough to take hold of (with hysteresis)
var _hug := false                 # both hands on the wall in front (set_hug)
var _hug_point := Vector3.ZERO
var _hug_normal := Vector3.ZERO
var _hug_slow := false
var _hands: WallHand              # both hands while you peek round a wall edge
var _arms: Array[Node3D] = [null, null]    # the LeftArm / RightArm meshes
var _crouch := 0.0
var _pull := 0.0                  # m a close wall has drawn the torch back
var _crouch_goal := 0.0
var _fidgets: Array[String] = []  # the FIDGETS this model has
var _fidget_in := 8.0             # s to the next one
var _fidget_last := ""
var _smack_in := 0.0              # s to a knock that's been asked for (0: none)
var _smack_wait := 0.0            # s before another can be
var _swap := 0                    # the battery swap: 0 none, 1 getting the torch up for it, 2 under way
var _swap_t := 0.0                # s waited to start it
var _swap_dark := false
var _swap_in := false             # the new cells are in (swap_done has gone out)
var _cells: Node3D                # the new pair, in the left fist

func _init() -> void:
	name = "TorchModel"
	position = POS
	rotation = ROT
	visible = false

## Load the model and fit it: long axis down -Z, LENGTH long, centred on the fist. False if missing.
func build() -> bool:
	var scn := load(MODEL) as PackedScene
	if scn == null:
		return false
	_torch = _hang(self, scn, LENGTH)
	if _torch == null:
		return false
	_build_arms()
	return true

## A model hung under `at`: its long axis down -Z, `length` long, centred there, casting no shadow.
## Null if it has no mesh.
func _hang(at: Node3D, scn: PackedScene, length: float) -> Node3D:
	var wrap := Node3D.new()
	at.add_child(wrap)
	var inner := scn.instantiate() as Node3D
	wrap.add_child(inner)
	# merge the mesh bounds (in wrap space) to find the long axis and centre
	var box := AABB()
	var first := true
	for n in inner.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var b := wrap.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first:
		wrap.queue_free()
		return null
	var size := box.size
	var axis := 0 if (size.x >= size.y and size.x >= size.z) else (1 if size.y >= size.z else 2)
	var scale_f := length / maxf(0.0001, size[axis])
	inner.scale = Vector3.ONE * scale_f
	inner.position = -box.get_center() * scale_f
	if axis == 0: wrap.rotation.y = PI / 2.0
	elif axis == 1: wrap.rotation.x = -PI / 2.0
	return wrap

## Put the torch in the right hand: the arms sit so that TorchGrip, in the TorchHold pose, lands on this
## node's origin, and the torch rides TorchGrip from then on. The torch floats alone if anything is missing.
func _build_arms() -> void:
	var scn := load(ARMS) as PackedScene
	if scn == null:
		return
	var arms := scn.instantiate() as Node3D
	add_child(arms)
	var grip := arms.find_child("TorchGrip", true, false) as Node3D
	var anchor := arms.find_child("TorchAnchor", true, false) as Node3D
	var players := arms.find_children("*", "AnimationPlayer", true, false)
	if grip == null or anchor == null or players.is_empty():
		arms.queue_free()
		return
	_arms = [arms.find_child("LeftArm", true, false) as Node3D, arms.find_child("RightArm", true, false) as Node3D]
	if _arms[0] != null:
		_arms[0].visible = false  # only out while peeking (wall_hand.gd)
	var skel := arms.find_children("*", "Skeleton3D", true, false)
	if not skel.is_empty() and get_parent() is Node3D and grip.get_parent() is BoneAttachment3D:
		_hands = WallHand.new()
		skel[0].add_child(_hands)
		if _hands.setup(get_parent() as Node3D, players[0] as AnimationPlayer):
			# the left hand's grip: TorchGrip mirrored onto the left hand bone (the rig is symmetric)
			var at := BoneAttachment3D.new()
			at.bone_name = "LeftHand"
			skel[0].add_child(at)
			var left_grip := Node3D.new()
			left_grip.name = "TorchGripLeft"
			at.add_child(left_grip)
			var m := Basis(Vector3(-1.0, 0.0, 0.0), Vector3.UP, Vector3.BACK)
			left_grip.transform = Transform3D(m * grip.transform.basis * m, m * grip.transform.origin)
			_grips = [left_grip, grip]
		else:
			_hands.queue_free()
			_hands = null
	for n in arms.find_children("*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the new cells for a battery swap, in the left fist
	var seat := arms.find_child("BatteryGrip", true, false) as Node3D
	var cells := load(CELLS) as PackedScene
	if seat != null and cells != null and _hands != null:
		_cells = _hang(seat, cells, CELLS_LENGTH / ARMS_SCALE)
		if _cells != null:
			_cells.visible = false
	var hold_at := Vector3.ZERO
	var node: Node = anchor
	while node != arms:
		hold_at = (node as Node3D).transform * hold_at
		node = node.get_parent()
	arms.scale = Vector3.ONE * ARMS_SCALE
	arms.position = -hold_at * ARMS_SCALE
	_torch.reparent(grip, false)
	_torch.scale = Vector3.ONE / ARMS_SCALE
	_torch.position = Vector3(0.0, 0.0, -GRIP_BACK / ARMS_SCALE)
	_grip = grip
	_grips[1] = grip
	_anim = players[0] as AnimationPlayer
	# the one-shots ease back into the hold they're queued before
	for clip in FIDGETS:
		if _anim.has_animation(clip):
			_anim.set_blend_time(clip, HOLD, 0.2)
			_fidgets.append(clip)
	for clip in [SMACK, RELOAD]:
		if _anim.has_animation(clip):
			_anim.set_blend_time(clip, HOLD, 0.2)

## Where the beam leaves from: LENGTH ahead of the torch's middle, along the torch
func lens() -> Vector3:
	if _grip != null:
		return _torch.global_position - _grip.global_transform.basis.z.normalized() * LENGTH
	return global_transform.origin - global_transform.basis.z * LENGTH

## `bob`: the head-bob phase (the swing follows your stride)
func update(dt: float, shown: bool, sprinting: bool, moving: bool, bob: float) -> void:
	_follow_camera(dt)
	if _hands != null:
		_hands.tick(dt)
	if _anim != null:
		_update_arm(shown or _swap != 0)    # a swap brings the torch up whether it's on or not
		_swap_tick(dt)
		_fidget(dt, sprinting)
		_show_arms()
	else:
		visible = shown and not (Game.hide_hud or Game.hide_hands)
		if not shown:
			raise = 0.0
			lower = 0.0
			return
		raise = minf(1.0, raise + dt * 3.0)
	if not visible:
		lower = 0.0
		return
	lower += ((1.0 if sprinting else 0.0) - lower) * minf(1.0, dt * 8.0)
	_crouch = lerpf(_crouch, _crouch_goal, minf(1.0, dt * 8.0))
	# without the arm the torch itself slides up from below; the arm's pickup does that otherwise
	var down := (1.0 - raise) * (1.0 - raise) if _anim == null else 0.0
	var step := sin(bob) if moving else 0.0
	var breathe := sin(Time.get_ticks_msec() * 0.0016) * 0.003
	position = Vector3(
		POS.x + step * 0.01 - lower * 0.03,
		POS.y + absf(step) * 0.008 + breathe - down * 0.3 - lower * 0.03 - _crouch * CROUCH_DIP,
		POS.z) + _lag * sway_amount
	# a wall closer than the torch is long: draw it back (and tuck it down and up) so it never goes into it
	_pull = lerpf(_pull, _wall_pull(), minf(1.0, dt * 12.0))
	var tuck := clampf(_pull / 0.25, 0.0, 1.0)
	position += Vector3(0.0, -WALL_TUCK * tuck, _pull)
	rotation = Vector3(ROT.x - WALL_TILT * tuck - lower * 0.35 + step * 0.01, ROT.y + lower * 0.25, ROT.z + step * 0.02) + _lag_rot * sway_amount

## How far back the torch has to come for its front to clear the wall straight ahead of the camera
func _wall_pull() -> float:
	var cam := get_parent() as Node3D
	if cam == null or not cam.is_inside_tree():
		return 0.0
	var space := cam.get_world_3d().direct_space_state
	if space == null:
		return 0.0
	var from := cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from - cam.global_transform.basis.z * TIP_REACH)
	var body := cam.get_parent() as CollisionObject3D
	if body != null:
		q.exclude = [body.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty() or not hit.collider is StaticBody3D:
		return 0.0
	return maxf(0.0, TIP_REACH + WALL_GAP - from.distance_to(hit.position))

## The hands are held, not bolted to the camera: they trail behind a turn of the view and behind the
## bounce of a step, then catch up with a slight overshoot (a damped spring). The camera's own motion
## (mouse look, head bob, camcorder shake, landings) is read off its transform, so anything that moves
## the view moves the hands after it. In camera space the hand drifts opposite to the way the view goes.
func _follow_camera(dt: float) -> void:
	var cam := get_parent() as Node3D
	if cam == null or dt <= 0.0:
		return
	var basis_now := cam.global_transform.basis.orthonormalized()
	var pos_now := cam.position
	if not _have_prev:
		_have_prev = true
		_prev_basis = basis_now
		_prev_pos = pos_now
		return
	var e := (_prev_basis.inverse() * basis_now).get_euler()
	var rate := (Vector3(e.x, e.y, e.z) / dt).clampf(-SWAY_MAX_RATE, SWAY_MAX_RATE)    # pitch, yaw, roll rad/s
	var vel := ((pos_now - _prev_pos) / dt).clampf(-SWAY_MAX_VEL, SWAY_MAX_VEL)        # m/s
	_prev_basis = basis_now
	_prev_pos = pos_now
	var goal := Vector3(rate.y * 0.010, -rate.x * 0.010, 0.0) - vel * 0.035
	var goal_rot := Vector3(-rate.x * 0.016, -rate.y * 0.016, -rate.z * 0.020) + Vector3(vel.y * 0.12, 0.0, -vel.x * 0.15)
	var step := minf(dt, 0.033)
	_lag_v += (SWAY_W * SWAY_W * (goal - _lag) - 2.0 * SWAY_Z * SWAY_W * _lag_v) * step
	_lag += _lag_v * step
	_lag_rot_v += (SWAY_W * SWAY_W * (goal_rot - _lag_rot) - 2.0 * SWAY_Z * SWAY_W * _lag_rot_v) * step
	_lag_rot += _lag_rot_v * step
	_lag = _lag.clampf(-0.06, 0.06)
	_lag_rot = _lag_rot.clampf(-0.25, 0.25)

## The peek this tick (peek.gd): which side you lean to (-1 left, +1 right, 0 none), whether you're
## leaning in, the edge (world point at eye height, wall normal, the way it lies, how far from the eye),
## whether you're slow enough to take hold of it, crouched. The hand on the wall's side goes on the edge
## and the other carries, low; holding the torch up in the hand the wall needs, it's passed over first,
## both hands out of view. Leaning back, the torch goes back to the right hand the same way. A flinch
## takes it straight back, and the torch coming up or going away waits for the hands to be off the wall.
func set_peek(side: int, leaning: bool, edge: Vector3, normal: Vector3, out: Vector3, dist: float, slow: bool, crouching: bool) -> void:
	_crouch_goal = 1.0 if crouching else 0.0
	if _hands == null:
		return
	var left := WallHand.LEFT
	var right := WallHand.RIGHT
	if _flinching:
		_hand_torch(right)
		_hands.set_mode(right, WallHand.Mode.ANIM)
		_hands.set_mode(left, WallHand.Mode.HIDE)
		return
	if _swap == 2:                    # both hands are on the torch, and the animation's
		_hands.set_mode(right, WallHand.Mode.ANIM)
		_hands.set_mode(left, WallHand.Mode.ANIM)
		return
	var busy := _anim.current_animation == PICKUP and _anim.is_playing()
	if _hug and not leaning and not busy and _swap == 0:
		var across := (-_hug_normal).cross(Vector3.UP).normalized()          # your right, along the wall
		var at := _hug_point + Vector3.DOWN * HUG_LOWER
		_hands.aim(right, at + across * HUG_SPREAD, _hug_normal, -across, _hug_slow, crouching)
		_hands.aim(left, at - across * HUG_SPREAD, _hug_normal, across, _hug_slow, crouching)
		_hands.set_mode(right, WallHand.Mode.WALL)
		_hands.set_mode(left, WallHand.Mode.WALL)
		return
	if leaning and side != 0 and not busy and _swap == 0:
		var wall := right if side < 0 else left
		var free := 1 - wall
		# in reach with some give either way, so a hand at the limit doesn't take hold and let go by turns
		_in_reach = dist <= WallHand.REACH + (0.1 if _in_reach else 0.0)
		_hands.aim(wall, edge, normal, out, slow and _in_reach, crouching)
		if _on and _torch_in == wall:
			_hands.set_mode(wall, WallHand.Mode.HIDE)
			_hands.set_mode(free, WallHand.Mode.HIDE)
			if _hands.hidden(wall) and _hands.hidden(free):
				_hand_torch(free)
		else:
			_hands.set_mode(wall, WallHand.Mode.WALL)
			_hands.set_mode(free, WallHand.Mode.CARRY)
	elif _torch_in != right:
		_hands.set_mode(left, WallHand.Mode.HIDE)
		_hands.set_mode(right, WallHand.Mode.HIDE)
		if _hands.hidden(left) and _hands.hidden(right):
			_hand_torch(right)
	else:
		_hands.set_mode(left, WallHand.Mode.HIDE)
		_hands.set_mode(right, WallHand.Mode.ANIM)

## Up against a wall with both hands free to go on it (peek.gd's hug): palms flat either side of where you
## face, fingers angled in. Taken up by set_peek when you're not leaning round an edge.
func set_hug(on: bool, point: Vector3, normal: Vector3, slow: bool) -> void:
	_hug = on
	_hug_point = point
	_hug_normal = normal
	_hug_slow = slow

## Both hands are on the wall (hugging it): the torch is out of hand, so the beam goes off
func hugging() -> bool:
	return _hug and _hands != null and _hands.mode_of(WallHand.RIGHT) == WallHand.Mode.WALL and _hands.mode_of(WallHand.LEFT) == WallHand.Mode.WALL

## Put the torch in hand `i` (WallHand.LEFT / RIGHT): it keeps the same place on either grip
func _hand_torch(i: int) -> void:
	if _torch_in == i or _grips[i] == null:
		return
	_torch_in = i
	_grip = _grips[i]
	_torch.reparent(_grip, false)

## What's in view: the right arm while the torch is up (or on its way) or while it's off the animation and
## not let down, the left arm while it's not let down, the torch while it's on
func _show_arms() -> void:
	if Game.hide_hud or Game.hide_hands:
		if _arms[0] != null: _arms[0].visible = false
		if _arms[1] != null: _arms[1].visible = false
		if _torch != null: _torch.visible = false
		visible = false
		return
	var away := not _on and not _anim.is_playing() and not _flinching
	var right_seen := not away
	var left_seen := false
	if _hands != null:
		var r := WallHand.RIGHT
		right_seen = _flinching or (not away or not _hands.settled(r) if _hands.mode_of(r) == WallHand.Mode.ANIM else not _hands.hidden(r))
		left_seen = not _hands.hidden(WallHand.LEFT)
	if _arms[0] != null:
		_arms[0].visible = left_seen
	if _arms[1] != null:
		_arms[1].visible = right_seen
	_torch.visible = not away and not (_hug and _hands != null and _hands.mode_of(WallHand.RIGHT) == WallHand.Mode.WALL)
	visible = right_seen or left_seen

## Just holding the torch up: on, in the right hand, that hand left to the animation and not flinching
func _holding() -> bool:
	if not _on or _flinching or _torch_in != WallHand.RIGHT:
		return false
	return _hands == null or (_hands.mode_of(WallHand.RIGHT) == WallHand.Mode.ANIM and _hands.settled(WallHand.RIGHT))

## Life in the holding hand: a fidget now and then while it's just holding (not sprinting), and the knock
## that smack() asked for. Each plays once over the hold and eases back into it; switching off, a flinch
## or a peek cut it short the way they cut the hold.
func _fidget(dt: float, sprinting: bool) -> void:
	var now := String(_anim.current_animation)
	_smack_wait = maxf(0.0, _smack_wait - dt)
	if _smack_in > 0.0:
		_smack_in -= dt
		if _smack_in <= 0.0:
			_smack_in = 0.0
			if _holding() and (now == HOLD or _fidgets.has(now)):
				_anim.clear_queue()
				_anim.play(SMACK, 0.08)
				_anim.queue(HOLD)
				_smack_wait = randf_range(SMACK_GAP.x, SMACK_GAP.y)
				_fidget_in = randf_range(FIDGET_EVERY.x, FIDGET_EVERY.y)
		return
	if _fidgets.is_empty() or sprinting or now != HOLD or not _holding():
		return
	_fidget_in -= dt
	if _fidget_in > 0.0:
		return
	_fidget_in = randf_range(FIDGET_EVERY.x, FIDGET_EVERY.y)
	var pick: String = _fidgets.pick_random()
	if pick == _fidget_last and _fidgets.size() > 1:
		pick = _fidgets[(_fidgets.find(pick) + 1) % _fidgets.size()]
	_fidget_last = pick
	_anim.play(pick, 0.2)
	_anim.queue(HOLD)

## The beam is stuttering: `after` s from now the hand knocks the torch, if it's just holding it then.
## Asked again before SMACK_GAP is up, or with one already on its way, nothing more happens.
func smack(after := 0.3) -> void:
	if _anim == null or not _on or _smack_in > 0.0 or _smack_wait > 0.0 or not _anim.has_animation(SMACK):
		return
	_smack_in = after

## Change the batteries. True if the hands will do it: swap_started when they begin, swap_dark while the
## cap is off, swap_done when the new cells are in (a flinch cuts it short: the cells are in at once).
## False if they can't (no arms, an arms model without the clip, one already under way): nothing follows.
func swap() -> bool:
	if _anim == null or _hands == null or _swap != 0 or not _anim.has_animation(RELOAD):
		return false
	_swap = 1
	_swap_t = 0.0
	_swap_in = false
	return true

func swapping() -> bool:
	return _swap != 0

## Whatever is left of a swap happens at once: light back, cells in, hands back to the hold
func end_swap() -> void:
	if _swap == 0:
		return
	var begun := _swap == 2
	if _swap == 1:
		swap_started.emit()
	_swap = 0
	if _swap_dark:
		_swap_dark = false
		swap_dark.emit(false)
	if not _swap_in:
		_swap_in = true
		if begun:
			swap_cut.emit()
		swap_done.emit()
	if _cells != null:
		_cells.visible = false
	if _anim.current_animation == RELOAD:
		_anim.clear_queue()
		_anim.play(HOLD, 0.2)

## The swap: waits for the torch to be up in the right hand (it may have been off, or in the left for a
## peek), plays the clip, and says when the light goes and comes back as the clip gets there
func _swap_tick(dt: float) -> void:
	if _swap == 0:
		return
	var now := String(_anim.current_animation)
	if _swap == 1:
		_swap_t += dt
		if _holding() and (now == HOLD or now == SMACK or _fidgets.has(now)):
			_swap = 2
			_anim.clear_queue()
			_anim.play(RELOAD, 0.15)
			_anim.queue(HOLD)
			swap_started.emit()
		elif _swap_t > SWAP_WAIT:
			end_swap()
		return
	if now != RELOAD:                 # played out, or a flinch took over
		end_swap()
		return
	var at := _anim.current_animation_position
	if at >= SWAP_OUT and at < SWAP_IN and not _swap_dark and not _swap_in:
		_swap_dark = true
		swap_dark.emit(true)
	if at >= SWAP_IN and not _swap_in:
		_swap_in = true
		_swap_dark = false
		swap_dark.emit(false)
		swap_done.emit()
	if _cells != null:
		_cells.visible = at >= SWAP_CELLS.x and at < SWAP_CELLS.y

## The arm jerks up to shield your face. With the torch off it comes up from below for it and goes back
## down after. A flinch already under way plays out.
func flinch() -> void:
	if _anim == null or _anim.current_animation == FLINCH:
		return
	_flinching = true
	visible = not (Game.hide_hud or Game.hide_hands)
	_anim.clear_queue()
	_anim.play(FLINCH, 0.06)

## Switching on plays the pickup, switching off plays it backwards; a switch mid-way turns it round
## where it is. `raise` follows the pickup (0 lowered .. 1 up). A switch during a flinch waits for it.
func _update_arm(shown: bool) -> void:
	if _flinching:
		_on = shown
		if _anim.current_animation == FLINCH:
			raise = 1.0
			return
		_flinching = false
		if _on:
			_anim.play(HOLD, 0.2)
		else:
			_anim.play_backwards(PICKUP, 0.15)
	if shown != _on:
		_on = shown
		var mid := _anim.current_animation == PICKUP and _anim.is_playing()
		var at := _anim.current_animation_position if mid else 0.0
		_anim.clear_queue()
		if shown:
			visible = true
			_anim.play(PICKUP)
			_anim.seek(at, true)
			_anim.queue(HOLD)
		else:
			_anim.play_backwards(PICKUP, 0.1)
			if mid:
				_anim.seek(at, true)
	if _anim.current_animation == PICKUP:
		raise = clampf(_anim.current_animation_position / maxf(0.001, _anim.current_animation_length), 0.0, 1.0)
	else:
		raise = 1.0 if _on else 0.0
	if not _on and not _anim.is_playing():
		raise = 0.0

# ---------------------------------------------------------------- debug console
## Play one of the arm's one-shots now (console: anim <name>), past the timers that space them out in
## play. "" if it's playing, else why not. The battery swap isn't asked for here: it goes through
## player.gd swap_battery(), which brings its sound and the light with it.
func debug_play(clip: String) -> String:
	if _anim == null:
		return "no arms model"
	if not _anim.has_animation(clip):
		return "the arms model has no clip " + clip
	if clip == FLINCH:
		flinch()
		return ""
	if _swap != 0:
		return "a battery swap is under way"
	if not _holding():
		return "the torch has to be on, and up in the right hand"
	_anim.clear_queue()
	_anim.play(clip, 0.1)
	_anim.queue(HOLD)
	return ""
