extends RefCounted
## The survivor suit's clips (models/player/survivor.glb, built by tools/blender/build_player_hazmat.py) and
## which one a body in a given state plays. Shared by remote_player.gd, player_shadow.gd and mimic.gd so a
## teammate, your own shadow and the thing copying them all move the same way.
##
##   idle_lookaround  standing, breathing, turning to scan the room
##   walk             moving normally (the player's 2.6 m/s, a survivor's walk)
##   run              sprinting
##   crouch_idle      squatting still        crouch_walk   creeping, heel to toe
##   lobby_idle_*     idle variants for the lobby corridor (tools/blender/add_survivor_lobby_idles.py): slump,
##                    sway, adjust (a hand to the hood), hips, glance. Each is its own role.
##   death            falls onto its back and holds the last frame
##   death_neck_snap  THE MANNEQUIN's kill seen from outside (tools/blender/add_survivor_neck_snap.py), timed
##                    to mannequin_snap.gd: frozen, the head wrenched round, hanging limp in its grip, then
##                    down on the knees and face down. Holds the last frame. Locomotion.play_kill()
## and, for a body whose real velocity is known (Locomotion below; tools/blender/add_survivor_directions.py):
##   walk_back / run_back / crouch_walk_back                       going backwards (a backpedal when running)
##   strafe_l/_r / run_strafe_l/_r / crouch_strafe_l/_r            side-steps, a side shuffle when running

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
	"idle": "look|^idle", "walk": "^walk$", "run": "^run$", "sprint": "sprint",
	"crouch_idle": "crouch.*idle", "crouch_walk": "^crouch_walk$", "death": "^death$", "neck_snap": "neck_snap",
}
const ONCE := ["death", "neck_snap"]       # every other clip loops
## A role the model has no clip for plays the nearest one it does have.
const FALLBACK := {"crouch_walk": "walk", "crouch_idle": "idle", "sprint": "run", "run": "walk", "walk": "run", "idle": "walk"}

## role -> animation name in `anim` ("" when the model has none). Every clip loops except ONCE.
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
			anim.get_animation(clips[role]).loop_mode = Animation.LOOP_NONE if role in ONCE else Animation.LOOP_LINEAR
	for n in anim.get_animation_list():                 # the lobby's idle variants: each is its own role
		if String(n).begins_with("lobby_idle"):
			clips[String(n)] = String(n)
			anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	return clips

## The suit's cloth in another colour (models/player/survivor_suit_<name>.jpg, tools/gen_hazmat_variants.py);
## "" keeps the yellow it comes in. Every surface that wears the suit's texture gets its own copy of the material.
static func apply_suit_variant(root: Node, variant: String) -> void:
	if variant == "":
		return
	var tex: Texture2D = load("res://models/player/survivor_suit_%s.jpg" % variant)
	if tex == null:
		return
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in mi.get_surface_override_material_count():
			var mat := mi.get_active_material(i)
			if mat is StandardMaterial3D and mat.albedo_texture != null:
				var c: StandardMaterial3D = mat.duplicate()
				c.albedo_texture = tex
				mi.set_surface_override_material(i, c)

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


## gait -> its clips going [forward, back, left, right]; left / right are the suit's own
const DIRS := {
	"walk": ["walk", "walk_back", "strafe_l", "strafe_r"],
	"run": ["run", "run_back", "run_strafe_l", "run_strafe_r"],
	"crouch": ["crouch_walk", "crouch_walk_back", "crouch_strafe_l", "crouch_strafe_r"],
}
## Ground speed (m/s) each gait's clips cover at speed 1 going (forward, back, sideways), as
## add_survivor_directions.py prints them; and the playback range that still looks like that gait.
const DIR_NATIVE := {"walk": Vector3(1.2, 1.17, 0.94), "run": Vector3(4.2, 2.58, 2.4), "crouch": Vector3(1.4, 1.4, 1.11)}
const DIR_RANGE := {"walk": Vector2(0.6, 1.3), "run": Vector2(0.6, 1.6), "crouch": Vector2(0.5, 2.0)}
## Where each heel comes down in each moving clip, as fractions of the clip, in order (tools/measure_strikes.gd
## prints them; rerun it if the clips change). Locomotion.stride locks the feet to an outside footfall count
## with these: footfall k lands on strike k. walk / run hold two strides, the side-steps more steps.
const STRIKES := {
	"walk": [0.109, 0.302, 0.609, 0.802], "walk_back": [0.125, 0.391, 0.625, 0.885],
	"strafe_l": [0.12, 0.245, 0.37, 0.495, 0.62, 0.745, 0.87, 0.995],
	"strafe_r": [0.125, 0.25, 0.37, 0.495, 0.625, 0.75, 0.87, 0.995],
	"run": [0.177, 0.432, 0.714, 0.922], "run_back": [0.13, 0.443, 0.651, 0.932],
	"run_strafe_l": [0.089, 0.328, 0.422, 0.656, 0.755, 0.99],
	"run_strafe_r": [0.089, 0.328, 0.422, 0.656, 0.755, 0.99],
	"crouch_walk": [0.182, 0.688], "crouch_walk_back": [0.354, 0.854],
	"crouch_strafe_l": [0.25, 0.521, 0.755, 0.99], "crouch_strafe_r": [0.25, 0.49, 0.755, 0.99],
}


## Moves a body the way it is really going. An AnimationTree (built here, next to the suit's AnimationPlayer)
## blends each gait's four directional clips in a 2D blend space by the velocity in the body's own frame, so
## going backwards plays walk_back / run_back and sideways a side-step, never the forward run. Idle, gait,
## run, crouch and death cross-fade by damped weights. The body's yaw follows the look with a lag (standing,
## the head alone turns until the look is past `turn_start`, then the feet shuffle round) and the HeadLook
## modifier turns chest, neck and head the rest of the way, damped: no snapping.
##   var loco := SurvivorAnim.Locomotion.new(anim, clips)
##   each frame: loco.update(dt, world_velocity, speed, sprinting, crouching, dead, look_yaw, look_pitch)
##   then use loco.body_yaw as the body's rotation.y (the node faces -Z)
class Locomotion:
	var fade_rate := 10.0                       # 1/s: idle / gait / run / crouch / death weights (~FADE to settle)
	var dir_rate := 7.0                         # 1/s: the blend following a change of direction
	var turn_moving := 9.0                      # 1/s: body yaw catching up with the look while moving
	var turn_idle := 5.0                        # 1/s: ... standing, once it has started to turn
	var turn_start := deg_to_rad(70.0)          # standing: how far the head turns alone before the feet follow
	var turn_stop := deg_to_rad(5.0)
	var head_rate := 12.0                       # 1/s: head after the look (smooths network steps, never snaps)
	var head_max_yaw := deg_to_rad(85.0)
	var head_max_pitch := deg_to_rad(60.0)

	var tree: AnimationTree
	var look: HeadLook
	var body_yaw := 0.0
	var _ang := 0.0                             # direction of travel in the body's frame: 0 forward, + right
	var _move := 0.0
	var _run := 0.0
	var _crouch := 0.0
	var _dead := 0.0
	var _was_dead := false
	var _turning := false
	var killing := false                        # play_kill(): the kill clip has the body until end_kill()
	var _kill := 0.0
	var _has_kill := false
	## Footfalls so far (any real number, counting up; e.g. the player's head-bob phase / PI): while moving,
	## the gait clips are held so footfall k lands on heel strike k (STRIKES) instead of playing at their own
	## rate, so the feet hit the floor with the footstep sounds. Below 0: free-running (remote survivors).
	var stride := -1.0
	var _player: AnimationPlayer
	var _played := {}                           # gait -> the clip at each of its 4 blend points

	func _init(player: AnimationPlayer, clips: Dictionary) -> void:
		_player = player
		tree = AnimationTree.new()
		tree.name = "Locomotion"
		player.get_parent().add_child(tree)            # a sibling: the same root for the track paths
		tree.anim_player = tree.get_path_to(player)
		player.stop()
		player.active = false                           # the tree poses the skeleton now, not the player
		var bt := AnimationNodeBlendTree.new()
		var anim_node := func(n: String, fallback: String) -> AnimationNodeAnimation:
			var a := AnimationNodeAnimation.new()
			a.animation = n if player.has_animation(n) else fallback
			return a
		# the idle without its scripted look-around: HeadLook turns the head where they really look
		var idle := "idle_still" if player.has_animation("idle_still") else str(clips.get("idle", ""))
		if idle == "idle_still":
			player.get_animation(idle).loop_mode = Animation.LOOP_LINEAR
		var walk := str(clips.get("walk", idle))
		bt.add_node("idle", anim_node.call(idle, walk))
		bt.add_node("crouch_idle", anim_node.call(str(clips.get("crouch_idle", "")), idle))
		var death := AnimationNodeAnimation.new()
		death.animation = str(clips.get("death", "")) if str(clips.get("death", "")) != "" else idle
		bt.add_node("death", death)
		bt.add_node("death_seek", AnimationNodeTimeSeek.new())
		bt.connect_node("death_seek", 0, "death")
		for gait in DIRS:
			var names: Array = DIRS[gait]
			var fwd := str(names[0]) if player.has_animation(names[0]) else walk
			var bs := AnimationNodeBlendSpace2D.new()
			bs.sync = true                                   # same-length clips: the feet stay in step
			var pts := [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]
			for i in 4:
				var a: AnimationNodeAnimation = anim_node.call(str(names[i]), fwd)
				if i == 1 and not player.has_animation(names[1]):
					a.play_mode = AnimationNodeAnimation.PLAY_MODE_BACKWARD     # no back clip: the forward one reversed
				bs.add_blend_point(a, pts[i], -1, ["forward", "back", "left", "right"][i])
			for i in 4:
				if player.has_animation(names[i]):
					player.get_animation(names[i]).loop_mode = Animation.LOOP_LINEAR
			bt.add_node(gait + "_dir", bs)
			bt.add_node(gait + "_seek", AnimationNodeTimeSeek.new())        # stride lock (update())
			bt.connect_node(gait + "_seek", 0, gait + "_dir")
			bt.add_node(gait + "_rate", AnimationNodeTimeScale.new())
			bt.connect_node(gait + "_rate", 0, gait + "_seek")
			var played: Array = []                                          # what each point really plays
			for i in 4:
				played.append(str(names[i]) if player.has_animation(names[i]) else fwd)
			_played[gait] = played
		for b in ["gait", "stand", "crouch", "posture", "life"]:
			bt.add_node(b, AnimationNodeBlend2.new())
		bt.connect_node("gait", 0, "walk_rate")
		bt.connect_node("gait", 1, "run_rate")
		bt.connect_node("stand", 0, "idle")
		bt.connect_node("stand", 1, "gait")
		bt.connect_node("crouch", 0, "crouch_idle")
		bt.connect_node("crouch", 1, "crouch_rate")
		bt.connect_node("posture", 0, "stand")
		bt.connect_node("posture", 1, "crouch")
		bt.connect_node("life", 0, "posture")
		bt.connect_node("life", 1, "death_seek")
		# the mannequin's kill over all of it, the fall included: it plays from the start and holds its end
		var kill := AnimationNodeAnimation.new()
		_has_kill = str(clips.get("neck_snap", "")) != ""
		kill.animation = str(clips.get("neck_snap", "")) if _has_kill else idle
		bt.add_node("kill", kill)
		bt.add_node("kill_seek", AnimationNodeTimeSeek.new())
		bt.connect_node("kill_seek", 0, "kill")
		bt.add_node("fate", AnimationNodeBlend2.new())
		bt.connect_node("fate", 0, "life")
		bt.connect_node("fate", 1, "kill_seek")
		bt.connect_node("output", 0, "fate")
		tree.tree_root = bt
		tree.active = true
		var sks := player.get_parent().find_children("*", "Skeleton3D", true, false)
		if not sks.is_empty():
			look = HeadLook.new()
			sks[0].add_child(look)

	## THE MANNEQUIN has them: its kill clip from the start, over everything (the death that follows too)
	## until end_kill(). False if the suit has no such clip (they just fall the usual way when they die).
	func play_kill() -> bool:
		if not _has_kill:
			return false
		killing = true
		_turning = false
		tree.set("parameters/kill_seek/seek_request", 0.0)
		return true

	## Back on their feet (respawned), or it never came to a death
	func end_kill() -> void:
		killing = false

	## Where `clip` should be (s) for `stride` footfalls: between strike k and strike k+1 in step with the
	## footfall count, so each whole footfall lands exactly on a heel strike even where the clip's steps
	## aren't evenly spaced.
	func _strike_time(clip: String) -> float:
		var length := _player.get_animation(clip).length
		var s: Array = STRIKES.get(clip, [])
		if s.is_empty():
			return fposmod(stride * 0.5, 1.0) * length         # no table: two footfalls a cycle
		var n := s.size()
		var whole := floori(stride)
		var k := posmod(whole, n)
		var a: float = s[k]
		var b: float = s[(k + 1) % n] + (1.0 if k + 1 >= n else 0.0)
		return fposmod(lerpf(a, b, stride - whole), 1.0) * length

	## Snap to a facing without turning (first sight, respawn, coming back into view).
	func face(yaw: float) -> void:
		body_yaw = yaw
		_turning = false

	func update(dt: float, vel: Vector3, speed: float, sprinting: bool, crouching: bool, dead: bool, look_yaw: float, look_pitch: float) -> void:
		var moving := speed > MOVING_ABOVE and not dead and not killing
		# ---- body yaw: lags the look; standing, only once the head can't cover it
		var before := body_yaw
		var diff := wrapf(look_yaw - body_yaw, -PI, PI)
		if dead or killing:
			_turning = false                            # lies where it fell (held where it was caught)
		elif moving:
			_turning = false
			body_yaw += diff * (1.0 - exp(-turn_moving * dt))
		else:
			if absf(diff) > turn_start:
				_turning = true
			if _turning:
				body_yaw += diff * (1.0 - exp(-turn_idle * dt))
				if absf(wrapf(look_yaw - body_yaw, -PI, PI)) < turn_stop:
					_turning = false
		body_yaw = wrapf(body_yaw, -PI, PI)
		var turn_rate := wrapf(body_yaw - before, -PI, PI) / maxf(dt, 1e-4)      # rad/s, + = to the left

		# ---- direction of travel in the body's frame (x right, y forward; the body faces -Z)
		var right := Vector3(cos(body_yaw), 0.0, -sin(body_yaw))
		var fwd := Vector3(-sin(body_yaw), 0.0, -cos(body_yaw))
		var local := Vector2(vel.dot(right), vel.dot(fwd))
		var step := 0.0                             # turning on the spot: the feet shuffle round with it
		if moving and local.length() > 0.05:
			_ang = lerp_angle(_ang, atan2(local.x, local.y), 1.0 - exp(-dir_rate * dt))
		elif _turning and not crouching:
			step = clampf(absf(turn_rate) / PI, 0.0, 0.6)
			_ang = lerp_angle(_ang, -PI / 2.0 if turn_rate > 0.0 else PI / 2.0, 1.0 - exp(-dir_rate * 2.0 * dt))
		var p := Vector2(sin(_ang), cos(_ang))
		p /= absf(p.x) + absf(p.y)                  # onto the diamond the four clips span
		var k := 1.0 - exp(-fade_rate * dt)
		_move = lerpf(_move, maxf(1.0 if moving else 0.0, step), k)
		_run = lerpf(_run, 1.0 if sprinting and moving else 0.0, k)
		_crouch = lerpf(_crouch, 1.0 if crouching else 0.0, k)
		_dead = lerpf(_dead, 1.0 if dead else 0.0, k)
		# into the kill fast (it starts with a jump), back out at the usual pace once they are up again
		_kill = lerpf(_kill, 1.0 if killing else 0.0, 1.0 - exp(-(30.0 if killing else fade_rate) * dt))
		if dead and not _was_dead:
			tree.set("parameters/death_seek/seek_request", 0.0)     # falls from the start, holds the end
		_was_dead = dead
		var gait_speed := speed if moving else 0.9 * step
		var locked := stride >= 0.0 and moving
		# the point the direction leans on most: its clip's strikes set the phase for the whole blend
		var lead := (0 if p.y >= 0.0 else 1) if absf(p.y) >= absf(p.x) else (2 if p.x < 0.0 else 3)
		for gait in DIRS:
			tree.set("parameters/%s_dir/blend_position" % gait, p)
			if locked:
				var clip: String = _played[gait][lead]
				tree.set("parameters/%s_rate/scale" % gait, 0.0)        # the seek alone moves it
				tree.set("parameters/%s_seek/seek_request" % gait, _strike_time(clip))
				continue
			var nat: Vector3 = DIR_NATIVE[gait]
			var native := absf(p.y) * (nat.x if p.y >= 0.0 else nat.y) + absf(p.x) * nat.z
			var r: Vector2 = DIR_RANGE[gait]
			tree.set("parameters/%s_rate/scale" % gait, clampf(gait_speed / native, r.x, r.y))
		tree.set("parameters/gait/blend_amount", _run)
		tree.set("parameters/stand/blend_amount", _move)
		tree.set("parameters/crouch/blend_amount", _move)
		tree.set("parameters/posture/blend_amount", _crouch)
		tree.set("parameters/life/blend_amount", _dead)
		tree.set("parameters/fate/blend_amount", _kill)

		# ---- head: the rest of the look, damped, within what a neck can do
		if look:
			var hk := 1.0 - exp(-head_rate * dt)
			var want_yaw := 0.0 if dead else clampf(wrapf(look_yaw - body_yaw, -PI, PI), -head_max_yaw, head_max_yaw)
			var want_pitch := 0.0 if dead else clampf(look_pitch, -head_max_pitch, head_max_pitch)
			look.yaw = lerpf(look.yaw, want_yaw, hk)
			look.pitch = lerpf(look.pitch, want_pitch, hk)
			look.influence = (1.0 - _dead) * (1.0 - _kill)     # the clip turns the head (all the way round)


## Turns the chest, neck and head after the animation is posed: `yaw` (rad, + = to its left) and `pitch`
## (rad, + = up), each shared out along the spine so no single joint takes it all. Skeleton space, so it
## doesn't care how the rig's bones are rolled. The suit faces +Z in its own file, up +Y.
class HeadLook extends SkeletonModifier3D:
	const SHARES := [["Spine02", 0.25, 0.15], ["NeckTwist01", 0.3, 0.35], ["Head", 0.45, 0.5]]   # bone, yaw, pitch
	var yaw := 0.0
	var pitch := 0.0
	var _bones: Array = []                          # [bone index, parent index, yaw share, pitch share]

	func _process_modification_with_delta(_delta: float) -> void:
		var sk := get_skeleton()
		if sk == null:
			return
		if _bones.is_empty():
			for s in SHARES:
				var i := sk.find_bone(s[0])
				if i >= 0:
					_bones.append([i, sk.get_bone_parent(i), s[1], s[2]])
		var turned := 0.0
		for b in _bones:
			turned += yaw * float(b[2])
			var qy := Quaternion(Vector3.UP, yaw * float(b[2]))
			var qp := Quaternion(Quaternion(Vector3.UP, turned) * Vector3.LEFT, pitch * float(b[3]))   # nods about its own (turned) side axis
			var gp := sk.get_bone_global_pose(b[0])
			var pg := sk.get_bone_global_pose(b[1]) if int(b[1]) >= 0 else Transform3D.IDENTITY
			var local := pg.basis.orthonormalized().inverse() * (Basis(qp * qy) * gp.basis.orthonormalized())
			sk.set_bone_pose_rotation(b[0], local.get_rotation_quaternion())
