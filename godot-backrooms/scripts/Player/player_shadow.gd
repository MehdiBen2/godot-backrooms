extends Node3D
## The local player's own shadow: the hazmat rig (models/player/hazmat.glb), never drawn to the
## camera (you don't see your own body) but rendered into the shadow map, so the flashlight and the
## ceiling tubes throw a real humanoid shadow instead of nothing. Animated the same way
## remote_player.gd drives other survivors, so the shadow's stride matches your own.

const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const MODEL := "res://models/player/hazmat.glb"
const MODEL_HEIGHT := 2.0       # metres: visor level matches the 1.7 m standing eye height
const FADE := 0.22              # clip cross-fade, seconds
const MOVING_ABOVE := 0.1       # m/s
const SPRINT_ABOVE := 3.2

var anim: AnimationPlayer
var clips := {}
var _role := ""

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
	clips = {
		"run": _find("^run"), "sprint": _find("sprint"), "idle": _find("^idle"),
		"crouch_idle": _find("crouch.*idle"), "crouch_walk": _find("crouch.*walk"), "death": _find("death"),
	}
	if clips["run"] == "" and clips["idle"] == "":
		root.queue_free()
		anim = null
		return false
	for role in clips:
		if clips[role] != "":
			anim.get_animation(clips[role]).loop_mode = Animation.LOOP_NONE if role == "death" else Animation.LOOP_LINEAR

	# stand on the floor, centred, MODEL_HEIGHT tall. The file faces +Z, the player faces -Z.
	var model := Node3D.new()
	add_child(model)
	model.add_child(root)
	root.transform = HazmatFit.fit(root, model, MODEL_HEIGHT)
	model.rotation.y = PI
	for m in root.find_children("*", "MeshInstance3D", true, false):
		(m as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	_play("idle")
	return true

func _find(pattern: String) -> String:
	var re := RegEx.new()
	re.compile("(?i)" + pattern)
	for n in anim.get_animation_list():
		if re.search(n):
			return n
	return ""

func _play(role: String) -> void:
	if role == "" or role == _role:
		return
	_role = role
	anim.play(clips[role], FADE)
	if role == "death":
		anim.speed_scale = 1.0

func _pick_role(moving: bool, sprinting: bool, crouching: bool, dead: bool) -> String:
	if dead:
		return "death" if clips.get("death", "") != "" else "idle"
	var want := ""
	if crouching:
		want = "crouch_walk" if moving else "crouch_idle"
	elif moving:
		want = "sprint" if sprinting else "run"
	else:
		want = "idle"
	var fallback := {"crouch_walk": "run", "crouch_idle": "idle", "sprint": "run", "run": "idle", "idle": "run"}
	while want != "" and clips.get(want, "") == "":
		want = fallback.get(want, "")
	return want

func _anim_speed(speed: float) -> float:
	match _role:
		"run": return clampf(speed / 2.8, 0.5, 2.0)
		"sprint": return clampf(speed / 4.0, 0.7, 1.6)
		"crouch_walk": return clampf(speed / 1.4, 0.5, 2.0)
	return 1.0

## `speed`: horizontal ground speed (m/s), so the stride matches the real movement.
func update(moving: bool, sprinting: bool, crouching: bool, dead: bool, speed: float) -> void:
	if anim == null:
		return
	_play(_pick_role(moving and not dead, sprinting, crouching, dead))
	anim.speed_scale = _anim_speed(speed)
