extends SkeletonModifier3D
## The hands while you peek round a wall edge (peek.gd). Sits under the arms' Skeleton3D (added by
## torch_model.gd), so it runs after their AnimationPlayer and can take either forearm off it.
##
## torch_model.gd puts each hand in one of four modes:
##   ANIM   left to the animation (the torch arm's pickup / hold / flinch)
##   HIDE   let down just below the view
##   CARRY  held low, only the top of the fist (and the torch, if it's in that hand) showing: the torch
##          hold (TorchHold's first frame) let down, mirrored for the left hand
##   WALL   on the edge: palm flat on the wall face, fingers straight out towards the edge, their tips
##          at it, the thumb flat beside the palm (the WallPalm pose); landing, the fingers press flat one
##          after the other. Too far off (or walking) the hand stops short and open, trembling a little
## On a change of mode the hand eases from wherever it is to the new pose on a spring: a snappy one onto
## the wall, landing with a slight overshoot, softer ones elsewhere.
##
## The arms model is a whole arm, shoulder to fingertips (tools/build_player_arms.py). Its forearm bone
## hangs under the root, placed by the animation, and the upper arm is that bone's child, pointing back
## from the elbow. So an arm on the wall is reached for the way yours is: from a shoulder beside and below
## the eye, square to the body, the elbow bends and sags to put the hand on the wall, and the shoulder
## leans in after it when the wall is further than the arm is long. A wall further off than that again is
## not reached, and the hand never hangs in the air short of it: it waits low, rising into the bottom of the
## view as the wall comes near, and reaches up for it once the arm can get there. On the wall it stays put
## while you move; as the arm runs out the grip lightens to the fingertips, and stretched past its length it
## lets go: the palm pushes off the face and the arm drops away out of view. Anything else in the way (a
## wall beside you, a door frame) pushes the hand back along the line of sight, never nearer than NEAR.

##   SLIDE  squeezed through a slit: palm flat on the wall at exactly the point given (no probing, no reach
##          limit, no line-of-sight fallback), so it slides along with you; the arm follows from the shoulder
##   DOOR   working a door (player.gd's door scene, through door()): the fingers closed on its handle (the
##          DoorKnob / DoorLever pose), twisting it, or the palm flat on the leaf pushing (DoorPush), moving
##          from one to the other as told. The handle and the leaf move as the door swings and the hand goes
##          with them as far as the arm reaches; past that it lets go, as off a wall
enum Mode { ANIM, HIDE, CARRY, WALL, SLIDE, DOOR }

const LEFT := 0
const RIGHT := 1
const FINGERS: Array[String] = ["Index", "Middle", "Ring", "Little"]
const JOINTS: Array[String] = ["Proximal", "Intermediate", "Distal"]
const THUMB: Array[String] = ["ThumbMetacarpal", "ThumbProximal", "ThumbDistal"]
const HOLD_ANIM := "TorchHold"
const PALM_ANIM := "WallPalm"     # one pose: the thumbs laid flat beside the palm (at rest they point into the wall)
const WRAP: Array[float] = [-0.05, 0.06, 0.04]    # rad each finger joint bends pressed on the wall: flat
const OPEN: Array[float] = [0.2, 0.15, 0.08]      # braced / landing: fingers relaxed, a little bent
const LIFT: Array[float] = [0.0, 0.0, -0.04, -0.12]  # rad, per finger (index..little): the knuckle lifts a touch so the outer fingers don't dig in
const LIFT_JOINT: Array[float] = [1.0, -0.6, -0.6]   # the two joints beyond it bend back the other way, so the finger lies flat again (no kink)
const SLIDE_SHOULDER := Vector3(0.24, -0.2, 0.14)   # m, camera space: SLIDE's shoulder, off the lower corner and behind the eye
const SLIDE_SHOULDER_FRONT := 0.03  # m, camera z: leaning after a hand, SLIDE's shoulder comes no further forward than this
const SLIDE_TILT := 1.2         # in a slit the fingers point forward and well up (the hand slides, not grips)
const TILT := 0.6               # the fingers point out over the edge and up this much
const SNAP := 30.0                # rad/s: how fast a finger presses flat (a little past, then back)
const SNAP_DAMP := 0.5
const SNAP_STAGGER := 0.04        # s between one finger and the next, index first
const SHOULDER := Vector3(0.25, -0.27, 0.10)      # m from the eye, in the body's frame: the wall arm's shoulder,
                                                  # off the bottom corner on its side and behind the eye
                                                  # (right; x mirrored for the left)
const SHOULDER_FRONT := -0.12     # m (camera z): leaning in, the shoulder comes no further forward than this,
                                  # so the sleeve's open end never shows
const UPPER := 0.43               # armature units from the elbow to the shoulder end of the sleeve
const STRETCH := 0.97             # the arm never goes quite straight
const SAG := 0.45                 # the elbow hangs down and this much out to its side
const EDGE_OUT := -0.08           # m: from peek.gd's point on the wall (4 cm in) to the knuckles: a
                                  # finger's length short of the edge, so the fingertips reach it
const RISE := 0.0                 # m above the eye the hand takes the wall
const RISE_CROUCH := -0.10        # crouched it takes it lower
const SHOULDER_OFF := 0.02       # m: the shoulder stays at least this far out from the wall's plane
const REACH := 1.15              # m: an edge this close can be taken hold of
const BRACE_BACK := 0.12          # braced, the hand stays this much of the way back towards the shoulder
const CARRY_DROP := 0.13          # m the carrying hand sits below the usual torch hold
const CARRY_OUT := 0.03           # m out to its side
const HIDE_DROP := 0.25           # m further down again: out of view
const ARC := 0.05                 # m the hand lifts on its way onto the wall
const FINGER := 0.17              # armature units from the knuckles to the fingertips
const NEAR := 0.15                # m: the hand never comes nearer the camera than this
const HUG_RANGE := 0.2            # m: how far either side of the hand the wall face is looked for
const HUG_GAP := 0.02           # m: the palm's rest off the wall holding on
const HUG_GAP_BRACED := 0.04      # m: braced, it stays a little off
const AT_SMOOTH := 30.0           # 1/s: the knuckles' target is low-passed, so a probe flicker never shows as the hand jumping
const CLEAR_SMOOTH := 18.0        # 1/s: how fast the hand follows an obstruction coming or going
const CLEAR := 0.03              # m kept between the fingertips and anything in the way
const LET_GO := 0.06              # m: on the wall, the arm (shoulder leant in) stretches this far past its reach before it lets go
const TAKE := 0.01                # m: off it, the wall has to be this much within reach to be taken again,
const TAKE_WAIT := 0.1            # s and for this long (so a hand at the limit doesn't grab and drop by turns)
const READY := 0.3                # m: off the wall, nearer than this out of reach the hand rises into the view, ready
const STRAIN := 0.1               # m: within this of letting go the grip lightens to the fingertips
const APPROACH := 0.05            # m the hand swings out off the wall face on its way onto it, coming in square to land
const IMPACT := 0.006             # m the palm presses into the wall as it lands, then eases back
const IMPACT_TIME := 0.14         # s
const PEEL := 0.06                # m the palm pushes off the face as it lets go, before the arm drops
const DROP := Vector2(9.0, 1.0)   # (rad/s, damping) letting go: a slow peel, then the arm falls away
const DOOR_POSES: Array[String] = ["DoorKnob", "DoorLever", "DoorPush"]   # playerarms_idle.glb (build_idle_hands.py)
enum Grip { KNOB, LEVER, BAR }
const KNOB_PALM := 0.042          # m from a knob's ball (its middle) out to the palm closed round it
const LEVER_PALM := 0.03          # and from a lever's grip up to the palm on top of it
const KNOB_TWIST := 0.75          # rad the wrist turns the knob through, about its stalk
const LEVER_DIP := 0.03           # m the lever goes down under the hand
const LEVER_TIP := 0.45           # rad the hand tips with it
const GRIP_RISE := 0.25           # the fingers on a handle point this much up from the line of the reach
const GRIP_BACK := -0.03          # m along the fingers from the knuckles back to where the handle sits in the hand
const PUSH_UP := 0.2              # the fingers flat on the leaf point across, towards the hinge, and this much up
const WRIST_MAX := deg_to_rad(65.0)   # the most the wrist bends on a door (from the forearm's line)
const DOOR_FRONT := -0.15         # m (camera z): reaching down for a handle the shoulder comes this far forward (you bend to it)
const DOOR_TAKE := 0.02           # m: a handle this little out of reach is reached for already (the shoulder gives the rest,
                                  # and you're still leaning in): the hand goes as you get there, not after
const DOOR_DROP := Vector2(14.0, 1.0)   # letting go of a door the arm drops away quicker (the door swings on, you go through)
const DOOR_LET_GO := 0.1          # m: on a door the arm goes a little further after it before letting go
const DOOR_LIFT := 0.06           # m the hand comes up off the leaf, moving from the handle to the flat of it
const DOOR_PRESS := 0.015         # m the palm sinks into its push (the leaf gives under it)
const GRIP_SPRING := Vector2(26.0, 0.55)   # (rad/s, damping) the fingers closing on a handle: a squeeze past, then easing
const PALM_SPRING := Vector2(11.0, 0.85)   # the hand from the handle to the leaf and back

class Hand:
	var side := 1.0               # 1 right, -1 left
	var fore := -1                # the LowerArm bone
	var bones: Array[int] = []    # wrist, 4 fingers x 3 joints, the thumb's 3, the upper arm (if the rig has one)
	var knuckle := Vector3.ZERO   # armature units, in the hand's space: the middle knuckle
	var rest: Array[Quaternion] = []
	var rest_curl: Array[float] = []   # how far each is already bent at rest (about X)
	var hold: Array[Quaternion] = []   # the same bones in the torch hold
	var palm: Array[Quaternion] = []   # the thumb's 3 flat on a wall
	var mode := Mode.HIDE
	var u := 1.0                  # 0..1 from the old pose to the mode's, sprung
	var vel := 0.0
	var pace := 1.0               # the spring's speed for this change of mode (set_mode), 1 = the mode's own
	var seen := false             # posed at least once (so there's a pose to set out from)
	var from_pos := Vector3.ZERO  # camera space: where it set out from
	var from_rot := Quaternion.IDENTITY
	var from_q: Array[Quaternion] = []
	var cur_pos := Vector3.ZERO   # camera space: where it was last frame
	var cur_rot := Quaternion.IDENTITY
	var cur_q: Array[Quaternion] = []
	var holding := false          # the edge is in reach and you're nearly still
	var grab := 0.0               # 0 braced .. 1 holding, eased
	var crouch := 0.0
	var crouch_goal := 0.0
	var hook: Array[float] = [0.0, 0.0, 0.0, 0.0]   # per finger 0 open .. 1 hooked, sprung one after the other
	var hook_vel: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var landed := 0.0             # s since the hand got to the wall (the fingers go after it)
	var edge := Vector3.ZERO      # world: peek.gd's point just in from the edge, at eye height
	var normal := Vector3.BACK
	var out := Vector3.LEFT
	var t := 0.0
	var regrip := 4.0             # s to the next shift of the grip
	var shift_t := 0.0
	var shift := 0.0              # 0..1..0 over a shift
	var at_s := Vector3.ZERO      # camera space: the smoothed knuckle target
	var at_ok := false
	var clear_k := 1.0            # smoothed share of the way out along the line of sight the obstruction allows
	var off := false              # WALL: the wall is out of the arm's reach, so the hand is down, not on it
	var take_t := 0.0             # s the wall has been back in reach (off)
	var over := 0.0               # m the arm would have to stretch past its reach to the wall (< 0: in reach)
	var strain := 0.0             # 0..1: on the wall, how near the arm is to letting go
	var peel := false             # this change of pose sets out from the wall: push off its face first
	var door_q: Array = []        # [knob, lever, push]: each the fingers' and thumb's 15 turns (empty: not in the file)
	var grip_at := Vector3.ZERO   # DOOR, world: the handle where the hand closes on it
	var push_at := Vector3.ZERO   # world: where the palm goes on the leaf
	var latch := Vector3.FORWARD  # world: along the leaf to its free edge
	var kind := Grip.KNOB
	var palm_goal := 0.0          # 0 on the handle .. 1 flat on the leaf (asked), and as it goes, sprung
	var palm_k := 0.0
	var palm_v := 0.0
	var turn := 0.0               # 0..1 the knob twisted / the lever down
	var press := 0.0              # 0..1 leaning into the push
	var grip := 0.0               # 0 open .. 1 closed on the handle, sprung (runs a touch past: the squeeze)
	var grip_v := 0.0
	var let_go := false           # DOOR: it has let go of this door (the leaf swung out of reach): it doesn't take it again

var view: Node3D                  # the camera the hands are posed in front of
var _hands: Array[Hand] = []
var _hold_fore := Transform3D()   # the right forearm in the torch hold, relative to its parent bone
var _rng := RandomNumberGenerator.new()
var _dt := 0.016

## Find both arms' bones and read the torch hold off `anim`. False if the rig isn't the one expected.
func setup(cam: Node3D, anim: AnimationPlayer) -> bool:
	var skel := get_skeleton()
	if skel == null or anim == null or not anim.has_animation(HOLD_ANIM):
		return false
	view = cam
	_rng.randomize()
	var a := anim.get_animation(HOLD_ANIM)
	var rot := {}
	var pos := {}
	for i in a.get_track_count():
		var bone := String(a.track_get_path(i).get_concatenated_subnames())
		match a.track_get_type(i):
			Animation.TYPE_ROTATION_3D: rot[bone] = a.rotation_track_interpolate(i, 0.0)
			Animation.TYPE_POSITION_3D: pos[bone] = a.position_track_interpolate(i, 0.0)
	if not rot.has("RightLowerArm") or not pos.has("RightLowerArm"):
		return false
	_hold_fore = Transform3D(Basis(rot["RightLowerArm"] as Quaternion), pos["RightLowerArm"] as Vector3)
	var flat := {}
	if anim.has_animation(PALM_ANIM):
		var p := anim.get_animation(PALM_ANIM)
		for i in p.get_track_count():
			if p.track_get_type(i) == Animation.TYPE_ROTATION_3D:
				flat[String(p.track_get_path(i).get_concatenated_subnames())] = p.rotation_track_interpolate(i, 0.0)
	for s in ["Left", "Right"]:
		var h := Hand.new()
		h.side = -1.0 if s == "Left" else 1.0
		h.fore = skel.find_bone(s + "LowerArm")
		var names: Array[String] = ["Hand"]
		for f in FINGERS:
			for j in JOINTS:
				names.append(f + j)
		names.append_array(THUMB)
		if skel.find_bone(s + "UpperArm") >= 0:
			names.append("UpperArm")
		for n in names:
			var b := skel.find_bone(s + n)
			if b < 0:
				return false
			h.bones.append(b)
			var r := skel.get_bone_rest(b).basis.get_rotation_quaternion()
			h.rest.append(r)
			h.rest_curl.append(2.0 * atan2(r.x, r.w))
			# the left hand holds it the way the right does, mirrored
			var q: Quaternion = rot.get("Right" + n, skel.get_bone_rest(skel.find_bone("Right" + n)).basis.get_rotation_quaternion())
			h.hold.append(q if s == "Right" else _mirror(q))
		if h.fore < 0:
			return false
		h.knuckle = skel.get_bone_rest(skel.find_bone(s + "MiddleProximal")).origin
		for j in 3:
			var open_q: Quaternion = flat.get("Right" + THUMB[j], skel.get_bone_rest(skel.find_bone("Right" + THUMB[j])).basis.get_rotation_quaternion())
			h.palm.append(open_q if s == "Right" else _mirror(open_q))
		h.mode = Mode.ANIM if s == "Right" else Mode.HIDE
		h.regrip = _rng.randf_range(3.0, 6.0)
		_hands.append(h)
	return true

## `pace` under 1 eases the hand there more slowly than the mode would (an idle reach in the dark)
func set_mode(i: int, mode: Mode, pace := 1.0) -> void:
	var h := _hands[i]
	if h.mode == mode:
		return
	var was_on := _on_wall(h)
	h.mode = mode
	h.pace = pace
	if mode == Mode.DOOR:              # a fresh door: open-handed, on the handle
		h.let_go = false
		h.palm_k = 0.0
		h.palm_v = 0.0
		h.grip = 0.0
		h.grip_v = 0.0
	h.clear_k = 1.0
	h.off = false
	h.take_t = 0.0
	_set_out(h, was_on)

## The hand sets out afresh from where it is now, towards whatever its pose is from here on. `peel`: it
## sets out from the wall, so the palm pushes off its face first
func _set_out(h: Hand, peel: bool) -> void:
	h.peel = peel
	h.at_ok = false
	h.from_pos = h.cur_pos
	h.from_rot = h.cur_rot
	h.from_q = h.cur_q.duplicate()
	h.u = 0.0 if h.seen else 1.0
	h.vel = 0.0

## On a wall or a slit's side, palm to it (not let go of it, or not yet reached)
static func _on_wall(h: Hand) -> bool:
	return (h.mode in [Mode.WALL, Mode.DOOR] and not h.off) or h.mode == Mode.SLIDE

func mode_of(i: int) -> Mode:
	return _hands[i].mode

## Arrived in its mode (near enough)
func settled(i: int) -> bool:
	return _hands[i].u > 0.97

## Out of view: let down and there
func hidden(i: int) -> bool:
	return _hands[i].mode == Mode.HIDE and _hands[i].u > 0.97

## Where the hand's wall is: peek.gd's edge point, the wall's normal and the way the edge lies (world),
## whether to take hold (in reach, nearly still), crouched or not
func aim(i: int, edge: Vector3, normal: Vector3, out: Vector3, holding: bool, crouch: bool) -> void:
	var h := _hands[i]
	h.edge = edge
	h.normal = normal
	h.out = out
	h.holding = holding
	h.crouch_goal = 1.0 if crouch else 0.0

## The door poses (DOOR_POSES) off the idle hands' player (torch_model.gd's, from playerarms_idle.glb): their
## Left* finger and thumb tracks, mirrored for the right hand. Without them DOOR leaves the fingers as they are
func read_door_poses(idle: AnimationPlayer) -> void:
	if idle == null:
		return
	var names: Array[String] = []
	for f in FINGERS:
		for j in JOINTS:
			names.append(f + j)
	names.append_array(THUMB)
	var poses: Array = []
	for clip in DOOR_POSES:
		if not idle.has_animation(clip):
			return
		var a := idle.get_animation(clip)
		var rot := {}
		for i in a.get_track_count():
			if a.track_get_type(i) == Animation.TYPE_ROTATION_3D:
				var path := String(a.track_get_path(i).get_concatenated_subnames())
				rot[path.substr(path.rfind(":") + 1)] = a.rotation_track_interpolate(i, 0.0)
		poses.append(rot)
	for h in _hands:
		h.door_q = []
		for rot in poses:
			var q: Array[Quaternion] = []
			for k in names.size():
				var have: bool = rot.has("Left" + names[k])
				var lq: Quaternion = rot["Left" + names[k]] if have else h.rest[1 + k]
				q.append(lq if h.side < 0.0 or not have else _mirror(lq))
			h.door_q.append(q)

## The door scene's hand (DOOR): `grip` the handle (world) of `kind`, `push` the point on the leaf for the palm,
## `normal` the leaf's face towards you and `latch` along it to its free edge; `palm` 0 on the handle .. 1 flat on
## the leaf (the hand moves between them on a spring), `turn` 0..1 the knob twisted / the lever down, `press`
## 0..1 the weight going into the push
func door(i: int, grip: Vector3, push: Vector3, normal: Vector3, latch: Vector3, kind: Grip, palm: float, turn: float, press: float) -> void:
	var h := _hands[i]
	h.grip_at = grip
	h.push_at = push
	h.normal = normal
	h.latch = latch
	h.kind = kind
	h.palm_goal = palm
	h.turn = turn
	h.press = press
	h.holding = true

## On the door and closed on its handle (or flat on the leaf): what the scene waits for to turn it
func door_ready(i: int) -> bool:
	var h := _hands[i]
	return h.mode == Mode.DOOR and not h.off and h.u > 0.9 and (h.grip > 0.8 or (h.palm_goal > 0.5 and h.palm_k > 0.8))

## One physics tick: the springs, the grip, the odd shift of it
func tick(dt: float) -> void:
	for h in _hands:
		# the door: the hand from the handle to the leaf and back; the fingers close on the handle once there
		var on_door := h.mode == Mode.DOOR and not h.off
		h.palm_v += (PALM_SPRING.x * PALM_SPRING.x * (h.palm_goal - h.palm_k) - 2.0 * PALM_SPRING.y * PALM_SPRING.x * h.palm_v) * dt
		h.palm_k += h.palm_v * dt
		var g := 1.0 - smoothstep(0.1, 0.5, h.palm_k) if on_door and h.u > 0.8 else 0.0
		h.grip_v += (GRIP_SPRING.x * GRIP_SPRING.x * (g - h.grip) - 2.0 * GRIP_SPRING.y * GRIP_SPRING.x * h.grip_v) * dt
		h.grip += h.grip_v * dt
		var s := ((DOOR_DROP if h.mode == Mode.DOOR else DROP) if h.off else _spring(h.mode)) * Vector2(h.pace, 1.0)
		h.vel += (s.x * s.x * (1.0 - h.u) - 2.0 * s.y * s.x * h.vel) * dt
		h.u += h.vel * dt
		h.crouch = lerpf(h.crouch, h.crouch_goal, minf(1.0, dt * 8.0))
		var on_wall := _on_wall(h)
		# stretched near letting go, only the fingertips keep hold
		h.grab = lerpf(h.grab, 1.0 - 0.7 * h.strain if on_wall and h.holding else 0.0, minf(1.0, dt * 8.0))
		h.t += dt
		# holding on: every few seconds the hand eases off a touch and takes a fresh grip
		if h.grab > 0.9:
			h.regrip -= dt
			if h.regrip <= 0.0:
				h.regrip = _rng.randf_range(3.0, 6.0)
				h.shift_t = 0.4
		h.shift_t = maxf(0.0, h.shift_t - dt)
		h.shift = sin(PI * (1.0 - h.shift_t / 0.4)) if h.shift_t > 0.0 else 0.0
		# once the hand is on the wall the fingers press flat, index first; they let go at once
		h.landed = h.landed + dt if on_wall and h.u > 0.75 else 0.0
		for k in 4:
			var goal := h.grab * (1.0 - 0.5 * h.shift) if h.landed > k * SNAP_STAGGER else 0.0
			h.hook_vel[k] += (SNAP * SNAP * (goal - h.hook[k]) - 2.0 * SNAP_DAMP * SNAP * h.hook_vel[k]) * dt
			h.hook[k] += h.hook_vel[k] * dt

## (rad/s, damping) per mode: onto the wall it snaps, lands a little past and settles
func _spring(mode: Mode) -> Vector2:
	match mode:
		Mode.WALL: return Vector2(17.0, 0.62)
		Mode.DOOR: return Vector2(16.0, 0.72)
		Mode.HIDE: return Vector2(14.0, 1.0)
	return Vector2(11.0, 0.9)

static func _mirror(q: Quaternion) -> Quaternion:
	return Quaternion(q.x, -q.y, -q.z, q.w)

func _process_modification_with_delta(delta: float) -> void:
	_dt = clampf(delta, 0.001, 0.05)
	var skel := get_skeleton()
	if skel == null or view == null or _hands.is_empty():
		return
	var cam := view.global_transform
	var cam_from_skel := cam.affine_inverse() * skel.global_transform
	var skel_from_cam := cam_from_skel.affine_inverse()
	var c_rot := cam_from_skel.basis.orthonormalized().get_rotation_quaternion()
	var unit := cam_from_skel.basis.get_scale().x                   # m per armature unit
	# the torch hold in camera space (both hands carry off it)
	var hold := skel.get_bone_global_pose(skel.get_bone_parent(_hands[RIGHT].fore)) * _hold_fore
	var hold_pos := cam_from_skel * hold.origin
	var hold_rot := c_rot * hold.basis.orthonormalized().get_rotation_quaternion()
	for h in _hands:
		var anim := skel.get_bone_global_pose(h.fore)
		var anim_q: Array[Quaternion] = []
		for b in h.bones:
			anim_q.append(skel.get_bone_pose_rotation(b))
		if h.mode == Mode.ANIM and h.u >= 0.995:
			h.cur_pos = cam_from_skel * anim.origin
			h.cur_rot = c_rot * anim.basis.orthonormalized().get_rotation_quaternion()
			h.cur_q = anim_q
			h.seen = true
			continue
		# the mode's pose, camera space
		var carry_pos := Vector3(hold_pos.x * h.side, hold_pos.y, hold_pos.z) + Vector3(CARRY_OUT * h.side, -CARRY_DROP, 0.02)
		var carry_rot := hold_rot if h.side > 0.0 else _mirror(hold_rot)
		var pos := carry_pos
		var rot := carry_rot
		var q: Array[Quaternion] = h.hold
		match h.mode:
			Mode.ANIM:
				pos = cam_from_skel * anim.origin
				rot = c_rot * anim.basis.orthonormalized().get_rotation_quaternion()
				q = anim_q
			Mode.HIDE:
				pos = carry_pos + Vector3(0.0, -HIDE_DROP, 0.05)
			Mode.WALL:
				var wall := _wall(h, cam, skel.get_bone_rest(h.bones[0]).origin, unit, _space())
				if h.off:
					# down out of view, rising into the bottom of it as the wall comes into reach
					var ready := smoothstep(READY, 0.0, h.over)
					pos = (carry_pos + Vector3(0.0, -HIDE_DROP, 0.05)).lerp(carry_pos, ready)
				else:
					pos = wall[0]
					rot = wall[1]
					q = _wall_fingers(h, wall[2])
					if h.bones.size() > q.size():
						q.append(wall[3])
			Mode.DOOR:
				var dr := _door(h, cam, skel.get_bone_rest(h.bones[0]).origin, unit)
				if h.off:
					pos = carry_pos + Vector3(0.0, -HIDE_DROP, 0.05)
				else:
					pos = dr[0]
					rot = dr[1]
					q = _door_fingers(h, dr[2])
					if h.bones.size() > q.size():
						q.append(dr[3])
			Mode.SLIDE:
				var slid := _slide(h, cam, skel.get_bone_rest(h.bones[0]).origin, unit)
				pos = slid[0]
				rot = slid[1]
				q = _wall_fingers(h, slid[2])
				if h.bones.size() > q.size():
					q.append(slid[3])
		if not h.seen:
			h.from_pos = pos
			h.from_rot = rot
			h.from_q = q.duplicate()
			h.seen = true
		var e := clampf(h.u, 0.0, 1.0)
		var at := h.from_pos.lerp(pos, h.u)
		var n := (cam.affine_inverse().basis * h.normal).normalized()
		if h.mode in [Mode.WALL, Mode.DOOR] and not h.off:
			# onto the wall on an arc: up and out off the face, coming in square to it to land
			at += (cam.affine_inverse().basis * Vector3.UP).normalized() * ARC * sin(PI * e)
			at += n * APPROACH * sin(PI * e)
			# the weight going onto it: a little press into the face, eased back out
			if h.landed > 0.0 and h.landed < IMPACT_TIME:
				at -= n * IMPACT * sin(PI * h.landed / IMPACT_TIME)
		elif h.peel:
			# letting go: the palm pushes off the face before the arm falls away
			at += n * PEEL * sin(PI * minf(1.0, e * 1.5))
		var turn := h.from_rot.slerp(rot, e)
		h.cur_pos = at
		h.cur_rot = turn
		h.cur_q.resize(q.size())
		for k in q.size():
			h.cur_q[k] = h.from_q[k].slerp(q[k], e) if k < h.from_q.size() else q[k]
		skel.set_bone_global_pose(h.fore, Transform3D(Basis(c_rot.inverse() * turn), skel_from_cam * at))
		for k in h.bones.size():
			skel.set_bone_pose_rotation(h.bones[k], h.cur_q[k])

## The wrist as the wall needs it; the fingers pressed flat (one after the other), or relaxed while
## braced; the thumb flat beside the palm
func _wall_fingers(h: Hand, wrist: Quaternion) -> Array[Quaternion]:
	var q: Array[Quaternion] = [wrist]
	for f in 4:
		for j in 3:
			var k := 1 + f * 3 + j
			# the outer fingers sit lower than the middle ones, so they're held a little back off the wall (the pinky most)
			var bend := lerpf(OPEN[j], WRAP[j] + LIFT[f] * LIFT_JOINT[j], h.hook[f])
			q.append(h.rest[k] * Quaternion(Vector3.RIGHT, bend - h.rest_curl[k]))
	for j in 3:
		q.append(h.palm[j])
	return q

## On the wall, camera space: [forearm position (the elbow), forearm turn, wrist turn (local to the
## forearm), upper arm turn (local to the forearm)]. The hand lies flat on the wall face, fingers pointing
## out towards the edge, their tips at it; shoulder, elbow and wrist make the triangle that reaches it, the
## elbow hanging down and a little out. `wrist`: where the hand bone sits on the forearm (armature units).
func _wall(h: Hand, cam: Transform3D, wrist: Vector3, unit: float, space: PhysicsDirectSpaceState3D) -> Array:
	var to_cam := cam.affine_inverse()
	var up := (to_cam.basis * Vector3.UP).normalized()
	var n := (to_cam.basis * h.normal).normalized()
	var out := (to_cam.basis * h.out).normalized()
	# the hand: palm (+Z, the way the fingers curl) into the wall, fingers (+Y) along it, out to the edge
	var fingers := out + up * TILT
	fingers = (fingers - n * fingers.dot(n)).normalized()
	var hand := Basis(fingers.cross(-n), fingers, -n).get_rotation_quaternion()
	var fore_len := wrist.length() * unit
	var upper_len := UPPER * unit
	var reach := (fore_len + upper_len) * STRETCH
	var knuckle := hand * (h.knuckle * unit)                         # wrist to knuckles
	var wall := to_cam * (h.edge + h.out * EDGE_OUT + Vector3.UP * (RISE + RISE_CROUCH * h.crouch))
	var sight := wall.normalized()
	# the shoulder, square to the body however the head is turned; short of the wall, it leans in
	var body := view.get_parent() as Node3D
	var square := to_cam.basis * (body.global_transform.basis.orthonormalized() if body != null else cam.basis)
	var shoulder := square * Vector3(SHOULDER.x * h.side, SHOULDER.y, SHOULDER.z)
	shoulder = _lean(h, wall, knuckle, shoulder, n, reach, LET_GO)
	# the knuckles on the line of sight to their spot, as far along it as the arm then reaches
	var c := -knuckle - shoulder
	var along := sight.dot(c)
	var disc := along * along - c.length_squared() + reach * reach
	var at := sight * minf(-along + sqrt(maxf(disc, 0.0)), wall.length())
	# braced: short of the edge, back towards the shoulder, not quite steady
	var brace := at.lerp(shoulder, BRACE_BACK) + Vector3(sin(h.t * 7.3), sin(h.t * 9.1 + 1.0), 0.0) * 0.002
	at = brace.lerp(at, h.grab)
	at += ((shoulder - at).normalized() * 0.012 - up * 0.008) * h.shift  # re-gripping
	at = _clear(h, cam, at, at + fingers * (FINGER * unit), space)
	# laid onto the wall face (the shoulder gives the last few cm, in _limb); stretched near letting go, the
	# palm comes up off it a touch, the fingertips last to leave
	at = _hug(cam, at, h.normal, h.grab, space) + n * 0.012 * h.strain
	# whatever the probes did this frame, the hand moves smoothly
	h.at_s = h.at_s.lerp(at, 1.0 - exp(-_dt * AT_SMOOTH)) if h.at_ok else at
	h.at_ok = true
	at = h.at_s
	return _limb(h, at, hand, knuckle, shoulder, square, up, n, fore_len, upper_len, reach)

## The shoulder (camera space) leant in towards `target` (where the knuckles go, on the face with normal `n`)
## as far as it can; and the hand let go when that's still `let_go` short, or taken back to it once it's in reach
## again. Out of reach the hand doesn't hang in the air short of the wall: it's off it (h.off)
func _lean(h: Hand, target: Vector3, knuckle: Vector3, shoulder: Vector3, n: Vector3, reach: float, let_go: float, front := SHOULDER_FRONT, take := -TAKE, wait := TAKE_WAIT) -> Vector3:
	# never inside the wall itself (a squeeze gap is barely wider than the shoulders): the arm would run through it
	var in_wall := (shoulder - target).dot(n)
	if in_wall < SHOULDER_OFF:
		shoulder += n * (SHOULDER_OFF - in_wall)
	var lean := target - knuckle - shoulder
	var short := lean.length() - reach
	h.over = short                    # how far the arm is short of the wall once the shoulder has leant all it can
	if short > 0.0:
		var toward := lean.normalized()
		var room := (shoulder.z - front) / -toward.z if toward.z < -0.001 else short
		shoulder += toward * clampf(short, 0.0, maxf(0.0, room))
		h.over = short - maxf(0.0, room) if toward.z < -0.001 else -1.0
	h.strain = smoothstep(let_go - STRAIN, let_go, h.over)
	if h.off:
		h.take_t = h.take_t + _dt if h.over < take and not h.let_go else 0.0
		if h.take_t >= wait:
			h.off = false
			_set_out(h, false)
	elif h.over > let_go:
		h.off = true
		# (in the push, or on its way to the leaf for it: not a slip as the latch gives, which it takes back)
		h.let_go = h.mode == Mode.DOOR and h.u > 0.6 and (h.palm_goal > 0.5 or h.press > 0.6)
		h.take_t = 0.0
		_set_out(h, h.u > 0.6)            # (only a hand that got there pushes off the face)
	return shoulder

## On the door (DOOR), camera space: [forearm position (the elbow), forearm turn, wrist turn (local to the
## forearm), upper arm turn (local)]. On the handle the palm faces the leaf and the fingers wrap the knob (up
## over it, leaning in towards the body) or hook over the lever from above (pointing at the leaf); turned, the
## hand twists about the knob's stalk or tips down with the lever. On the leaf the palm is flat to it, fingers
## up and a little towards the hinge. Between the two it lifts off the face and comes back to it
func _door(h: Hand, cam: Transform3D, wrist: Vector3, unit: float) -> Array:
	var to_cam := cam.affine_inverse()
	var up := (to_cam.basis * Vector3.UP).normalized()
	var n := (to_cam.basis * h.normal).normalized()
	var flat_up := (up - n * up.dot(n)).normalized()
	var fore_len := wrist.length() * unit
	var upper_len := UPPER * unit
	var reach := (fore_len + upper_len) * STRETCH
	var body := view.get_parent() as Node3D
	var square := to_cam.basis * (body.global_transform.basis.orthonormalized() if body != null else cam.basis)
	var shoulder := square * Vector3(SHOULDER.x * h.side, SHOULDER.y, SHOULDER.z)
	var inward := square * Vector3(-h.side, 0.0, 0.0)                  # across the body, from this hand's side
	inward = (inward - n * inward.dot(n)).normalized()
	# on the handle. The hand carries on the line of the forearm, as a real one does: the fingers point along the
	# reach from the shoulder (a little up from it), round the knob with the palm turned in to it and the thumb
	# up, or over the lever with the palm down on it. (Palm square to the leaf with the fingers up, the wrist had
	# to fold back past 110 degrees and the glove went into the sleeve: checked in Blender on this rig.) The turn
	# of the handle is then a roll of the forearm about the handle's stalk
	var grip := to_cam * h.grip_at
	var along := (grip - shoulder).normalized()
	var fing := (along + up * GRIP_RISE).normalized()
	var g_rot: Quaternion
	var g_at: Vector3
	var roll := 0.0
	if h.kind == Grip.LEVER:
		var palm_n := -up - fing * (-up).dot(fing)                      # palm down on top of the grip
		palm_n = palm_n.normalized()
		g_rot = Basis(fing.cross(palm_n), fing, palm_n).get_rotation_quaternion()
		g_at = grip - palm_n * LEVER_PALM - fing * GRIP_BACK - up * LEVER_DIP * h.turn
		# pressed down: the far end of the lever (towards the hinge) goes down, the hand rolling with it
		roll = -LEVER_TIP * h.turn * signf(n.cross(inward).dot(up))
	else:
		var palm_n := inward - fing * inward.dot(fing)                  # palm turned in to the knob, thumb up
		palm_n = palm_n.normalized()
		g_rot = Basis(fing.cross(palm_n), fing, palm_n).get_rotation_quaternion()
		g_at = grip - palm_n * KNOB_PALM - fing * GRIP_BACK
		if h.kind == Grip.KNOB:
			roll = KNOB_TWIST * h.turn * -h.side
	if roll != 0.0:
		var twist := Quaternion(n, roll)                                # about the stalk (the handle stays put)
		g_rot = twist * g_rot
		g_at = grip + twist * (g_at - grip)
	# flat on the leaf: the fingers across towards the hinge and a little up (the wrist bent back ~65 degrees,
	# as it is pushing anything; fingers straight up it went past 85 and pinched the cuff)
	var p_fing := (flat_up * PUSH_UP + inward).normalized()
	var p_rot := Basis(p_fing.cross(-n), p_fing, -n).get_rotation_quaternion()
	var p_at := to_cam * h.push_at + p_rot * (h.knuckle * unit) * 0.5 + n * (HUG_GAP - DOOR_PRESS * h.press)
	var pk := clampf(h.palm_k, 0.0, 1.0)
	var at := g_at.lerp(p_at, pk) + n * DOOR_LIFT * sin(PI * pk)
	var hand := g_rot.slerp(p_rot, smoothstep(0.0, 1.0, pk))
	var knuckle := hand * (h.knuckle * unit)
	at -= n * DOOR_PRESS * 0.5 * h.press * (1.0 - pk)                  # leaning on the handle too
	# the wrist never bends back further than a wrist does: past WRIST_MAX the hand tips round the wrist towards
	# the forearm (the heel of the palm stays on the leaf, the fingers lift a little off it)
	var wrist_at := at - knuckle
	var fore_dir := (wrist_at - shoulder).normalized()
	var fingers_dir := hand * Vector3.UP
	var bent := fingers_dir.angle_to(fore_dir)
	if bent > WRIST_MAX:
		var axis := fingers_dir.cross(fore_dir)
		if axis.length() > 0.001:
			hand = Quaternion(axis.normalized(), bent - WRIST_MAX) * hand
			knuckle = hand * (h.knuckle * unit)
			at = wrist_at + knuckle
	shoulder = _lean(h, at, knuckle, shoulder, n, reach, DOOR_LET_GO, DOOR_FRONT, DOOR_TAKE, 0.06)
	return _limb(h, at, hand, knuckle, shoulder, square, up, n, fore_len, upper_len, reach, DOOR_FRONT)

## The door's fingers: the wrist as _door() has it, then open (the push pose) closing on the handle by `grip`
## (a bar is pushed, not held), or flat on the leaf. Without the poses, the hand's own wall fingers
func _door_fingers(h: Hand, wrist: Quaternion) -> Array[Quaternion]:
	if h.door_q.size() < 3:
		return _wall_fingers(h, wrist)
	var held: Array = h.door_q[1] if h.kind == Grip.LEVER else (h.door_q[2] if h.kind == Grip.BAR else h.door_q[0])
	var flat: Array = h.door_q[2]
	var k := clampf(h.grip, 0.0, 1.0)
	var q: Array[Quaternion] = [wrist]
	for i in flat.size():
		q.append((flat[i] as Quaternion).slerp(held[i] as Quaternion, k))
	return q

## Squeezed through a slit (SLIDE): the knuckles right on the wall at `h.edge` (world, already where the hand
## should be), the palm flat on it, fingers forward along the slit and up. Nothing probed: it goes where it's told.
func _slide(h: Hand, cam: Transform3D, wrist: Vector3, unit: float) -> Array:
	var to_cam := cam.affine_inverse()
	var up := (to_cam.basis * Vector3.UP).normalized()
	var n := (to_cam.basis * h.normal).normalized()
	var out := (to_cam.basis * h.out).normalized()
	var fingers := out + up * SLIDE_TILT
	fingers = (fingers - n * fingers.dot(n)).normalized()
	var hand := Basis(fingers.cross(-n), fingers, -n).get_rotation_quaternion()
	var fore_len := wrist.length() * unit
	var upper_len := UPPER * unit
	var reach := (fore_len + upper_len) * STRETCH
	var knuckle := hand * (h.knuckle * unit)
	var at := to_cam * (h.edge + h.normal * HUG_GAP)
	# the shoulder rides the camera here, not the body: crawling you look straight down past your own shoulders,
	# and a shoulder placed off the body then sat right in view with the sleeve's open end showing. Kept behind
	# the eye (camera z > 0), its end is never in front of the lens, wherever you look.
	var square := Basis.IDENTITY
	var shoulder := Vector3(SLIDE_SHOULDER.x * h.side, SLIDE_SHOULDER.y, SLIDE_SHOULDER.z)
	var in_wall := (shoulder - at).dot(n)
	if in_wall < SHOULDER_OFF:
		shoulder += n * (SHOULDER_OFF - in_wall)
	# out of reach: the shoulder leans after the hand, but never past the eye (the sleeve's open end would show);
	# what's still too far, the hand stops short of
	var span := at - knuckle - shoulder
	if span.length() > reach:
		shoulder += span.normalized() * (span.length() - reach)
		shoulder.z = maxf(shoulder.z, SLIDE_SHOULDER_FRONT)
		span = at - knuckle - shoulder
		if span.length() > reach:
			at = shoulder + knuckle + span.normalized() * reach
	return _limb(h, at, hand, knuckle, shoulder, square, up, n, fore_len, upper_len, reach)

## Shoulder, elbow, wrist putting the knuckles at `at` (camera space) with the hand turned `hand`: [forearm
## position (the elbow), forearm turn, wrist turn (local to the forearm), upper arm turn (local to the forearm)]
func _limb(h: Hand, at: Vector3, hand: Quaternion, knuckle: Vector3, shoulder: Vector3, square: Basis, up: Vector3, n: Vector3, fore_len: float, upper_len: float, reach: float, front := -INF) -> Array:
	var wrist_at := at - knuckle
	# shoulder, elbow, wrist: whatever moved the hand, the shoulder gives before the arm stretches
	var span := wrist_at - shoulder
	var far := span.length()
	if far > reach:
		shoulder = wrist_at - span / far * reach
		# (but never further forward than `front`, camera z: the sleeve's open end would come into view; the
		# arm goes straight and the hand stops short instead, for the moment before it lets go)
		if shoulder.z < front:
			shoulder.z = front
		far = minf((wrist_at - shoulder).length(), reach)
	far = maxf(far, absf(upper_len - fore_len) + 0.01)
	var to_wrist := (wrist_at - shoulder).normalized()
	var bend := clampf((upper_len * upper_len + far * far - fore_len * fore_len) / (2.0 * upper_len * far), -1.0, 1.0)
	var sag := square * Vector3(SAG * h.side, 0.0, 0.0) - up
	sag = sag.normalized()
	sag -= n * minf(0.0, sag.dot(n))                                       # the elbow hangs along the wall, never into it
	sag = sag.normalized()
	sag = (sag - to_wrist * sag.dot(to_wrist)).normalized()
	var elbow := shoulder + (to_wrist * bend + sag * sqrt(1.0 - bend * bend)) * upper_len
	var dir := (wrist_at - elbow).normalized()
	var fore := Quaternion((hand * Vector3.UP).normalized(), dir) * hand
	# the upper arm, from the elbow back to the shoulder: swung there from where it rests on the forearm
	var upper := Quaternion.IDENTITY
	if h.bones.size() > 16:
		var rests := fore * h.rest[16]
		upper = fore.inverse() * (Quaternion((rests * Vector3.UP).normalized(), (shoulder - elbow).normalized()) * rests)
	return [elbow, fore, fore.inverse() * hand, upper]

## `at` (camera space) laid onto the wall face right under it (along the wall's normal), so the palm rests
## on the surface instead of floating in front of it; braced (not holding) it keeps a bit of a gap
func _hug(cam: Transform3D, at: Vector3, normal: Vector3, grab: float, space: PhysicsDirectSpaceState3D) -> Vector3:
	if space == null:
		return at
	var p := cam * at
	var q := PhysicsRayQueryParameters3D.create(p + normal * HUG_RANGE, p - normal * HUG_RANGE)
	var body := view.get_parent() as CollisionObject3D
	if body != null:
		q.exclude = [body.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty() or not hit.collider is StaticBody3D:
		return at
	var snug: Vector3 = hit.position + normal * lerpf(HUG_GAP_BRACED, HUG_GAP, grab)
	return cam.affine_inverse() * snug

## The physics space and the player's body (the camera's parent), for _clear()
func _space() -> PhysicsDirectSpaceState3D:
	return view.get_world_3d().direct_space_state if view.is_inside_tree() else null

## `at` (camera space), slid back along the line of sight so nothing lies between the camera and `tip`
## (the fingertips, camera space), and never nearer than NEAR: the hand stays where it is on screen
func _clear(h: Hand, cam: Transform3D, at: Vector3, tip: Vector3, space: PhysicsDirectSpaceState3D) -> Vector3:
	var scale := 1.0
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(cam.origin, cam * (tip * 1.1))
		var body := view.get_parent() as CollisionObject3D
		if body != null:
			q.exclude = [body.get_rid()]
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var d: float = cam.origin.distance_to(hit.position)
			scale = minf(1.0, (d - CLEAR) / maxf(0.001, tip.length()))
	h.clear_k = lerpf(h.clear_k, scale, 1.0 - exp(-_dt * CLEAR_SMOOTH))
	return at * clampf(h.clear_k, NEAR / maxf(0.001, at.length()), 1.0)
