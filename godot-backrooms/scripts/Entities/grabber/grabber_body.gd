extends RefCounted
## THE GRABBER's body: models/entities/grabber/grabber.glb (built by tools/blender/build_grabber.py from
## asetsuimprot/grabber.glb) and its clips. The model is already 2.3 m tall with its feet on y = 0, faces +Z,
## and carries every clip the brain plays:
##
##   idle  hunch  land  run  chase  peek_r  peek_l  grab  drag
##
## Locomotion clips are in place: their playback follows the real ground speed (NATIVE) so the feet don't
## slide. `hang` is how far it hangs from the ceiling: 0 stands it on the floor; above 0 the whole figure is
## turned upside down about its facing axis with its feet `hang` metres up (the hunch).

const MODEL := "res://models/entities/grabber/grabber.glb"
const HEIGHT := 2.3
const NATIVE := {"run": 3.2, "chase": 5.4, "drag": 1.6}     # m/s each clip covers at speed 1 (the build prints them)
const LOOPS := ["idle", "hunch", "run", "chase", "drag"]
const CLIPS := ["idle", "hunch", "land", "run", "chase", "peek_r", "peek_l", "grab", "drag"]
const BLEND := 0.25
const PEEK_BACK := 3.2               # s into a peek clip where it snaps back round the corner

var root: Node3D                     # the imported scene
var anim: AnimationPlayer
var skel: Skeleton3D
var clip := ""
var flip := 0.0                      # 0 upright .. 1 upside down (turned about its facing axis)
var hang := 0.0                      # m: where its feet are while flipped (the ceiling)

func build(host: Node3D) -> bool:
	var packed := load(MODEL) as PackedScene
	if packed == null:
		push_warning("grabber: %s did not load (not imported yet?)" % MODEL)
		return false
	root = packed.instantiate()
	host.add_child(root)
	anim = root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for n in root.find_children("*", "Skeleton3D", true, false):
		skel = n
		break
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).extra_cull_margin = 2.0       # the arms reach far outside the rest bounds
	if anim == null:
		push_warning("grabber: %s has no AnimationPlayer" % MODEL)
		return false
	for c in LOOPS:
		if anim.has_animation(c):
			anim.get_animation(c).loop_mode = Animation.LOOP_LINEAR
	play("idle", 1.0, 0.0)
	return true

func has(c: String) -> bool:
	return anim != null and anim.has_animation(c)

## Crossfade into `c` (no-op if it already plays); `speed` is the playback rate
func play(c: String, speed := 1.0, blend := BLEND) -> void:
	if anim == null or not anim.has_animation(c):
		return
	if c != clip or not anim.is_playing():
		clip = c
		anim.play(c, blend)
	anim.speed_scale = speed

## Start `c` from its first frame even if it is already playing (a peek, the grab)
func restart(c: String, blend := BLEND) -> void:
	if anim == null or not anim.has_animation(c):
		return
	clip = c
	anim.play(c, blend)
	anim.seek(0.0, true)
	anim.speed_scale = 1.0

## Playback rate for a locomotion clip moving at `mps` over the ground
func rate(c: String, mps: float) -> float:
	if not NATIVE.has(c):
		return 1.0
	return clampf(mps / float(NATIVE[c]), 0.55, 1.5)

func time() -> float:
	return anim.current_animation_position if anim != null and anim.is_playing() else 0.0

func length() -> float:
	return anim.get_animation(clip).length if anim != null and anim.has_animation(clip) else 0.0

## A one-shot clip has reached its end
func done() -> bool:
	return anim == null or not anim.is_playing() or anim.current_animation_position >= length() - 0.001

func seek(t: float) -> void:
	if anim != null and anim.is_playing():
		anim.seek(t, true)

## Place the figure: `flip` 0..1 turns it upside down about its facing axis, its feet `hang` metres up
func pose_root() -> void:
	if root == null:
		return
	root.transform = Transform3D(Basis(Vector3.BACK, flip * PI), Vector3(0.0, hang, 0.0))

## Where its head is in the world right now (the peek's lean, the hunch's hang included)
func head_pos() -> Vector3:
	if skel != null:
		var i := skel.find_bone("Head")
		if i >= 0:
			return skel.global_transform * skel.get_bone_global_pose(i).origin
	return root.global_position + Vector3.UP * HEIGHT * 0.9 if root != null else Vector3.ZERO

## Where its right hand is (the one that grabs)
func hand_pos() -> Vector3:
	if skel != null:
		var i := skel.find_bone("RightHand")
		if i >= 0:
			return skel.global_transform * skel.get_bone_global_pose(i).origin
	return head_pos()
