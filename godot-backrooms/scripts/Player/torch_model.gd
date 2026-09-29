extends Node3D
## The torch in your hand (models/flashlight.glb), low-right in view, held by your right arm
## (models/player/playerarms.glb; the left arm is hidden): the arm brings it up when you switch it on and
## lowers it out of view when you switch it off. Swings with your stride, dips while you sprint.
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

var raise := 0.0
var lower := 0.0

var _torch: Node3D                # the fitted flashlight
var _anim: AnimationPlayer
var _grip: Node3D                 # TorchGrip, riding the right hand bone
var _on := false

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
	var left := arms.find_child("LeftArm", true, false) as Node3D
	if left != null:
		left.visible = false
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
	_anim = players[0] as AnimationPlayer

## Where the beam leaves from: LENGTH ahead of the torch's middle, along the torch
func lens() -> Vector3:
	if _grip != null:
		return _torch.global_position - _grip.global_transform.basis.z.normalized() * LENGTH
	return global_transform.origin - global_transform.basis.z * LENGTH

## `bob`: the head-bob phase (the swing follows your stride)
func update(dt: float, shown: bool, sprinting: bool, moving: bool, bob: float) -> void:
	if _anim != null:
		_update_arm(shown)
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
	# without the arm the torch itself slides up from below; the arm's pickup does that otherwise
	var down := (1.0 - raise) * (1.0 - raise) if _anim == null else 0.0
	var step := sin(bob) if moving else 0.0
	var breathe := sin(Time.get_ticks_msec() * 0.0016) * 0.003
	position = Vector3(
		POS.x + step * 0.01 - lower * 0.03,
		POS.y + absf(step) * 0.008 + breathe - down * 0.3 - lower * 0.03,
		POS.z)
	rotation = Vector3(ROT.x - lower * 0.35 + step * 0.01, ROT.y + lower * 0.25, ROT.z + step * 0.02)

## Switching on plays the pickup, switching off plays it backwards; a switch mid-way turns it round
## where it is. `raise` follows the pickup (0 lowered .. 1 up).
func _update_arm(shown: bool) -> void:
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
		visible = false
		raise = 0.0
