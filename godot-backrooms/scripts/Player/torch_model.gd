extends Node3D
## The torch in your hand (models/flashlight.glb), low-right in view, held by your right arm
## (models/player/playerarms.glb): the arm brings it up when you switch it on and lowers it out of view
## when you switch it off. Swings with your stride, dips while you sprint and crouch, and jerks up across
## your face when something is right in front of you (flinch()).
## Peeking round a wall edge (peek.gd, set_peek()), the hand on the wall's side takes hold of the edge and
## the other one hangs low, only just in view, with the torch if it's on (wall_hand.gd): peeking left the
## right hand goes on the wall, so the torch is passed to the left hand first, below the view. The left
## arm is out of view otherwise.
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
const WallHand := preload("res://scripts/Player/wall_hand.gd")
const CROUCH_DIP := 0.03          # m the torch hand sits lower crouched

var raise := 0.0
var lower := 0.0

var _torch: Node3D                # the fitted flashlight
var _anim: AnimationPlayer
var _grip: Node3D                 # the grip the torch rides: TorchGrip on the right hand, or its mirror on the left
var _grips: Array[Node3D] = [null, null]   # left, right
var _torch_in := 1                # which hand has it (WallHand.LEFT / RIGHT)
var _on := false
var _flinching := false
var _hands: WallHand              # both hands while you peek round a wall edge
var _arms: Array[Node3D] = [null, null]    # the LeftArm / RightArm meshes
var _crouch := 0.0
var _crouch_goal := 0.0

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
	var wrap := Node3D.new()
	add_child(wrap)
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
		return false
	var size := box.size
	var axis := 0 if (size.x >= size.y and size.x >= size.z) else (1 if size.y >= size.z else 2)
	var scale_f := LENGTH / maxf(0.0001, size[axis])
	inner.scale = Vector3.ONE * scale_f
	inner.position = -box.get_center() * scale_f
	if axis == 0: wrap.rotation.y = PI / 2.0
	elif axis == 1: wrap.rotation.x = -PI / 2.0
	_torch = wrap
	_build_arms()
	return true

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

## Where the beam leaves from: LENGTH ahead of the torch's middle, along the torch
func lens() -> Vector3:
	if _grip != null:
		return _torch.global_position - _grip.global_transform.basis.z.normalized() * LENGTH
	return global_transform.origin - global_transform.basis.z * LENGTH

## `bob`: the head-bob phase (the swing follows your stride)
func update(dt: float, shown: bool, sprinting: bool, moving: bool, bob: float) -> void:
	if _hands != null:
		_hands.tick(dt)
	if _anim != null:
		_update_arm(shown)
		_show_arms()
	else:
		visible = shown
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
		POS.z)
	rotation = Vector3(ROT.x - lower * 0.35 + step * 0.01, ROT.y + lower * 0.25, ROT.z + step * 0.02)

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
	var busy := _anim.current_animation == PICKUP and _anim.is_playing()
	if leaning and side != 0 and not busy:
		var wall := right if side < 0 else left
		var free := 1 - wall
		_hands.aim(wall, edge, normal, out, slow and dist <= WallHand.REACH, crouching)
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
	_torch.visible = not away
	visible = right_seen or left_seen

## The arm jerks up to shield your face. With the torch off it comes up from below for it and goes back
## down after. A flinch already under way plays out.
func flinch() -> void:
	if _anim == null or _anim.current_animation == FLINCH:
		return
	_flinching = true
	visible = true
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
