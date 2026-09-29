extends RefCounted
## The survivor suit's clips (models/player/survivor.glb, built by tools/blender/build_player_hazmat.py) and
## which one a body in a given state plays. Shared by remote_player.gd, player_shadow.gd and mimic.gd so a
## teammate, your own shadow and the thing copying them all move the same way.
##
##   idle_lookaround  standing, breathing, turning to scan the room
##   walk             moving normally (the player's 2.6 m/s, a survivor's walk)
##   run              sprinting
##   crouch_idle      squatting still        crouch_walk   creeping, heel to toe
##   death            falls onto its back and holds the last frame

const MODEL := "res://models/player/survivor.glb"
const FADE := 0.22              # clip cross-fade, seconds
const MOVING_ABOVE := 0.1       # m/s
const SPRINT_ABOVE := 3.2       # the player moves 2.6 m/s and sprints about 4.5
## Ground speed (m/s) each clip covers at speed_scale 1 with the suit fitted 2 m tall; playback follows the
## real speed so the feet don't slide, within a range that still looks like the same gait. The walk's
## stride is short for 2.6 m/s, so its playback is capped at a natural walking cadence (~2 steps a
## second): the legs keep a calm pace and the feet slip a little instead of pedalling.
const NATIVE := {"walk": 1.2, "run": 4.2, "sprint": 4.2, "crouch_walk": 1.4}
const SCALE_RANGE := {"walk": Vector2(0.6, 1.25), "run": Vector2(0.6, 1.5), "sprint": Vector2(0.7, 1.6), "crouch_walk": Vector2(0.5, 2.0)}

const PATTERNS := {
	"idle": "look|^idle", "walk": "^walk", "run": "^run", "sprint": "sprint",
	"crouch_idle": "crouch.*idle", "crouch_walk": "crouch.*walk", "death": "death",
}
## A role the model has no clip for plays the nearest one it does have.
const FALLBACK := {"crouch_walk": "walk", "crouch_idle": "idle", "sprint": "run", "run": "walk", "walk": "run", "idle": "walk"}

## role -> animation name in `anim` ("" when the model has none). Every clip loops except death.
static func find_clips(anim: AnimationPlayer) -> Dictionary:
	var clips := {}
	for role in PATTERNS:
		var re := RegEx.new()
		re.compile("(?i)" + str(PATTERNS[role]))
		clips[role] = ""
		for n in anim.get_animation_list():
			if re.search(n):
				clips[role] = n
				break
		if clips[role] != "":
			anim.get_animation(clips[role]).loop_mode = Animation.LOOP_NONE if role == "death" else Animation.LOOP_LINEAR
	return clips

## The role to play: walk when moving, run when sprinting. `_current` is the role playing now. "" if nothing fits.
static func pick_role(clips: Dictionary, _current: String, speed: float, sprinting: bool, crouching: bool, dead: bool) -> String:
	var want := "idle"
	if dead:
		want = "death"
	elif crouching:
		want = "crouch_walk" if speed > MOVING_ABOVE else "crouch_idle"
	elif speed > MOVING_ABOVE:
		want = "sprint" if sprinting else "walk"
	var tried := {}
	while clips.get(want, "") == "" and not tried.has(want):
		tried[want] = true
		want = FALLBACK.get(want, "idle")
	return want if clips.get(want, "") != "" else ""

## Playback speed for `role` at `speed` m/s.
static func speed_scale(role: String, speed: float) -> float:
	if not NATIVE.has(role):
		return 1.0
	var r: Vector2 = SCALE_RANGE[role]
	return clampf(speed / float(NATIVE[role]), r.x, r.y)


## Keeps the suit's feet out of the floor while two very different clips cross-fade: a crouch walk blending
## into a run (or standing up) bends the knees halfway while the hips are only halfway up, and for a tenth
## of a second a foot sinks through the floor. Each frame this lifts `holder` (the node the suit hangs from)
## by however far the lower toe has gone under where a flat foot's toe sits, right after the mixer poses the
## skeleton (so it is never a frame late). Set `on` false while dead: a body lying down is meant to be low.
class FloorGuard:
	var _holder: Node3D
	var _sk: Skeleton3D
	var _toes: Array[int] = []
	var _base := 0.0          # holder's own height, without the lift
	var _flat := 0.0          # a toe's height (holder's parent space) with the foot flat on the floor
	var lift := 0.0
	var on := true

	func _init(holder: Node3D, mixer: AnimationMixer) -> void:
		_holder = holder
		_base = holder.position.y
		var sks := holder.find_children("*", "Skeleton3D", true, false)
		if sks.is_empty():
			return
		_sk = sks[0]
		for n in ["L_ToeBase", "R_ToeBase"]:
			var i := _sk.find_bone(n)
			if i >= 0:
				_toes.append(i)
		_flat = INF
		for i in _toes:
			_flat = minf(_flat, _to_parent(_sk.get_bone_global_rest(i).origin).y)
		mixer.mixer_applied.connect(_update)

	# skeleton space -> the holder's parent's space (works before the suit is in the tree)
	func _to_parent(p: Vector3) -> Vector3:
		var xf := Transform3D.IDENTITY
		var n: Node = _sk
		while n != null:
			if n is Node3D:
				xf = (n as Node3D).transform * xf
			if n == _holder:
				break
			n = n.get_parent()
		return xf * p

	func _update() -> void:
		if _toes.is_empty() or not is_instance_valid(_holder):
			return
		var need := 0.0
		if on:
			for i in _toes:
				need = maxf(need, _flat - (_to_parent(_sk.get_bone_global_pose(i).origin).y - lift))
		lift = need
		_holder.position.y = _base + lift
