extends Node3D
## The local player's own shadow: the hazmat rig (models/player/survivor.glb), never drawn to the
## camera (you don't see your own body) but rendered into the shadow map, so the flashlight and the
## ceiling tubes throw a real humanoid shadow instead of nothing. Animated the same way
## remote_player.gd drives other survivors (survivor_anim.gd Locomotion), so the shadow's stride matches
## your own, backwards and sideways too, and its body turns after your look.

const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const SurvivorAnim := preload("res://scripts/Entities/survivor_anim.gd")
const MODEL := SurvivorAnim.MODEL
const MODEL_HEIGHT := 2.0       # metres: visor level matches the 1.7 m standing eye height
## The flashlight rides the same camera this body stands under, so at close range (looking down,
## a sprint pose swinging a limb into the beam) it clips through its own geometry and throws a
## broken shadow right underfoot. Kept off this dedicated layer so only the far-away ceiling tubes
## (which don't have that problem) light and shadow it; player.gd clears this bit from the
## flashlight's cull_mask.
const SHADOW_LAYER := 1 << 19

const LEGS_MODEL := "res://models/player/survivor_legs.glb"
## The torso above the waist is folded away (Pinch scales the Waist bone to nothing, the classic
## first-person trick), so no cut chest can swing into view: the body closes at the belt. And the clips
## carry the hips around (the run throws them ~0.3 m forward), so each frame the body slides to keep the
## waist joint, where the animation really put it, LEGS_WAIST_BEHIND behind the eye: the hips stay under
## and behind you and the legs stride out ahead.
const LEGS_PINCH_BONE := "Waist"
const LEGS_WAIST_BEHIND := 0.38 # metres, horizontally, along the look
const LEGS_TURN_START := 20.0   # degrees the view swings, standing, before the feet step round (the shadow waits for 70)
const LEGS_PUSH_MAX := 0.8      # metres the body may slide back (never forward of its own origin)
## Crouched, the knees come up to the height of the hands in view (torch_model.gd's arms), and looking down
## pulls the hands back onto them: a knee at a hand's height and side is kept LEGS_KNEE_CLEAR behind it
## (the knee pad and glove have size), the body sliding back as far as that takes.
const LEGS_KNEE_CLEAR := 0.16   # metres, along the look
const LEGS_KNEE_BAND := Vector2(0.22, 0.24)     # a knee this close to a hand (height, side, m) is in its way
const LEGS_KNEE_RELEASE := 0.25 # m/s the hold lets the body come forward again once the knees are clear
const LEGS_KNEES := [["L_Calf", "LeftHand"], ["R_Calf", "RightHand"]]   # the knee joint, the hand on its side

## Folds every bone from `bone` up to nothing at its joint. Runs after the AnimationTree and HeadLook.
class Pinch extends SkeletonModifier3D:
	var bone := -1
	func _process_modification_with_delta(_delta: float) -> void:
		var sk := get_skeleton()
		if sk != null and bone >= 0:
			sk.set_bone_pose_scale(bone, Vector3(0.001, 0.001, 0.001))

var anim: AnimationPlayer
var _floor: SurvivorAnim.FloorGuard
var loco: SurvivorAnim.Locomotion
var legs_model: Node3D
var legs_loco: SurvivorAnim.Locomotion
var _legs_floor: SurvivorAnim.FloorGuard
var _legs_sk: Skeleton3D
var _legs_waist := -1
var _legs_push := 0.15           # metres the body is slid back right now
var _legs_knees := []            # [knee bone, hand bone] per side (LEGS_KNEES), -1 where missing
var _hands_sk: Skeleton3D        # the arms in view, found on first use
var _knee_hold := 0.0            # how far back (m) the knees have lately needed the body
var clips := {}

func _init() -> void:
	name = "ShadowBody"

## Loads the rig and marks every mesh shadow-only. False if the model is missing (caller frees this).
func build() -> bool:
	var packed := load(MODEL) as PackedScene
	if packed == null:
		return false
	var root: Node3D = packed.instantiate()
	var aps := root.find_children("*", "AnimationPlayer", true, false)
	if aps.is_empty():
		root.queue_free()
		return false
	anim = aps[0]
	clips = SurvivorAnim.find_clips(anim)
	if clips["run"] == "" and clips["idle"] == "":
		root.queue_free()
		anim = null
		return false

	# stand on the floor, centred, MODEL_HEIGHT tall. The file faces +Z, the player faces -Z.
	var model := Node3D.new()
	add_child(model)
	model.add_child(root)
	root.transform = HazmatFit.fit(root, model, MODEL_HEIGHT)
	model.rotation.y = PI
	loco = SurvivorAnim.Locomotion.new(anim, clips)
	_floor = SurvivorAnim.FloorGuard.new(model, loco.tree)
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mi.layers = SHADOW_LAYER
		# SDFGI voxelizes geometry regardless of any light's cull_mask, so without this the body
		# still darkens the floor via GI occlusion even where the flashlight's direct shadow is excluded.
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_build_legs(root.transform)
	var parent := get_parent() as Node3D
	if parent:
		loco.face(parent.global_rotation.y)
		if legs_loco:
			legs_loco.face(parent.global_rotation.y)
	return true

## The visible half: survivor_legs.glb (the same rig cut below the shoulders, capped, the rest folded by
## Pinch) so looking down you see your own hips and legs. Same fit as the full rig, its own
## animation tree driven in step with it. Casts no shadow (the full rig already does); optional, a
## missing file just leaves the shadow body alone.
func _build_legs(fit: Transform3D) -> void:
	var packed := load(LEGS_MODEL) as PackedScene
	if packed == null:
		return
	var legs_root: Node3D = packed.instantiate()
	var aps := legs_root.find_children("*", "AnimationPlayer", true, false)
	if aps.is_empty():
		legs_root.queue_free()
		return
	var legs_anim: AnimationPlayer = aps[0]
	var legs_clips := SurvivorAnim.find_clips(legs_anim)
	legs_model = Node3D.new()
	add_child(legs_model)
	legs_model.add_child(legs_root)
	legs_root.transform = fit
	legs_model.rotation.y = PI
	legs_model.position.z = _legs_push
	legs_loco = SurvivorAnim.Locomotion.new(legs_anim, legs_clips)
	legs_loco.turn_start = deg_to_rad(LEGS_TURN_START)
	legs_loco.turn_idle = 7.0
	_legs_floor = SurvivorAnim.FloorGuard.new(legs_model, legs_loco.tree)
	for m in legs_root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var sks := legs_root.find_children("*", "Skeleton3D", true, false)
	if not sks.is_empty():
		_legs_sk = sks[0]
		_legs_waist = _legs_sk.find_bone(LEGS_PINCH_BONE)
		if _legs_waist >= 0:
			var pinch := Pinch.new()
			pinch.bone = _legs_waist
			_legs_sk.add_child(pinch)

## How much further back (m, 0 if none) the legs must slide so no knee is in a hand's way (LEGS_KNEE_CLEAR).
func _knees_clearance(cam: Camera3D, fwd: Vector3) -> float:
	if _legs_sk == null or cam == null:
		return 0.0
	if not is_instance_valid(_hands_sk):
		_hands_sk = null
		var torch = get_parent().get("torch")
		if torch is Node:
			for s in (torch as Node).find_children("*", "Skeleton3D", true, false):
				if (s as Skeleton3D).find_bone("LeftHand") >= 0:
					_hands_sk = s
					break
		if _hands_sk == null:
			return 0.0
		_legs_knees.clear()
		for pair in LEGS_KNEES:
			_legs_knees.append([_legs_sk.find_bone(pair[0]), _hands_sk.find_bone(pair[1])])
	if not _hands_sk.is_visible_in_tree():
		return 0.0
	var side_axis := Vector3(-fwd.z, 0.0, fwd.x)
	var c := cam.global_position
	var need := 0.0
	for pair in _legs_knees:
		if pair[0] < 0 or pair[1] < 0:
			continue
		var knee := _legs_sk.global_transform * _legs_sk.get_bone_global_pose(pair[0]).origin
		var hand := _hands_sk.global_transform * _hands_sk.get_bone_global_pose(pair[1]).origin
		if absf(knee.y - hand.y) > LEGS_KNEE_BAND.x or absf((knee - hand).dot(side_axis)) > LEGS_KNEE_BAND.y:
			continue
		need = maxf(need, (knee - c).dot(fwd) - ((hand - c).dot(fwd) - LEGS_KNEE_CLEAR))
	return need

## How much further back (m, may be negative) the legs must slide to put the posed waist joint
## LEGS_WAIST_BEHIND behind the camera along `fwd`. 0 when it can't tell.
func _legs_clearance(cam: Camera3D, fwd: Vector3) -> float:
	if _legs_waist < 0 or cam == null:
		return 0.0
	var waist := _legs_sk.global_transform * _legs_sk.get_bone_global_pose(_legs_waist).origin
	return (waist - cam.global_position).dot(fwd) + LEGS_WAIST_BEHIND

## `speed`: horizontal ground speed (m/s), so the stride matches the real movement; `velocity` (world)
## for its direction; `pitch` the camera's, for the head. The body hangs off the player, which turns with
## the mouse at once: this node turns back by the difference so the body lags it like a survivor's does.
## `stride`: your footfalls so far (player.gd's bob / PI): both rigs plant a heel on each footstep sound
## (Locomotion.stride). Below 0, they play at their own pace.
func update(moving: bool, sprinting: bool, crouching: bool, dead: bool, speed: float, velocity := Vector3.ZERO, pitch := 0.0, stride := -1.0) -> void:
	if loco == null:
		return
	var parent := get_parent() as Node3D
	var look_yaw := parent.global_rotation.y if parent else 0.0
	var dt := get_process_delta_time()
	loco.stride = stride
	if legs_loco:
		legs_loco.stride = stride
	loco.update(dt, velocity if moving else Vector3.ZERO, speed if moving else 0.0, sprinting, crouching, dead, look_yaw, pitch)
	rotation.y = wrapf(loco.body_yaw - look_yaw, -PI, PI)
	_floor.on = not dead
	if legs_loco:
		# The legs don't lag the look like the shadow does: seen from the eye, a body swivelling under
		# you on its own reads as the legs panning. They stay locked to the view (no turn, no shuffle),
		# and get no pitch, so HeadLook never bends the cut torso forward into the camera.
		# Moving, they stay locked to the view. Standing, they turn like the shadow does but sooner
		# (LEGS_TURN_START): the planted feet stay put as the view swings, then the legs shuffle round
		# with the side-step clips once the view is past it, and settle under you.
		if moving or dead:
			legs_loco.body_yaw = look_yaw
		legs_loco.update(dt, velocity if moving else Vector3.ZERO, speed if moving else 0.0, sprinting, crouching, dead, look_yaw, 0.0)
		# this node turns by the shadow's lag: undo it, then give the legs their own facing
		legs_model.rotation.y = PI - rotation.y + wrapf(legs_loco.body_yaw - look_yaw, -PI, PI)
		var cam := parent.get("cam") as Camera3D if parent else null
		var fwd := -parent.global_basis.z if parent else Vector3.FORWARD
		fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
		# each knee comes up once a stride: hold the furthest back any knee has needed, letting go slowly,
		# so the legs don't slide to and fro with every step
		_knee_hold = maxf(_legs_push + _knees_clearance(cam, fwd), _knee_hold - dt * LEGS_KNEE_RELEASE)
		var goal := clampf(maxf(_legs_push + _legs_clearance(cam, fwd), _knee_hold), 0.0, LEGS_PUSH_MAX)
		# damped, not snapped: it rides out the hips' sway within a stride without jittering
		_legs_push += (goal - _legs_push) * (1.0 - exp(-dt * 12.0))
		var back := Vector3(0.0, 0.0, _legs_push).rotated(Vector3.UP, -rotation.y)
		legs_model.position.x = back.x          # .y is the FloorGuard's
		legs_model.position.z = back.z
		_legs_floor.on = not dead
		legs_model.visible = not dead
