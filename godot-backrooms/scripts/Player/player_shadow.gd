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

var anim: AnimationPlayer
var _floor: SurvivorAnim.FloorGuard
var loco: SurvivorAnim.Locomotion
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
	var parent := get_parent() as Node3D
	if parent:
		loco.face(parent.global_rotation.y)
	return true

## `speed`: horizontal ground speed (m/s), so the stride matches the real movement; `velocity` (world)
## for its direction; `pitch` the camera's, for the head. The body hangs off the player, which turns with
## the mouse at once: this node turns back by the difference so the body lags it like a survivor's does.
func update(moving: bool, sprinting: bool, crouching: bool, dead: bool, speed: float, velocity := Vector3.ZERO, pitch := 0.0) -> void:
	if loco == null:
		return
	var parent := get_parent() as Node3D
	var look_yaw := parent.global_rotation.y if parent else 0.0
	var dt := get_process_delta_time()
	loco.update(dt, velocity if moving else Vector3.ZERO, speed if moving else 0.0, sprinting, crouching, dead, look_yaw, pitch)
	rotation.y = wrapf(loco.body_yaw - look_yaw, -PI, PI)
	_floor.on = not dead
