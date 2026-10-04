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
## not reached: the knuckles stop on your line of sight to their spot, so on screen they still sit right on
## the corner, though nearer than the wall (the arms cast no shadow, so nothing gives that away). Anything
## else in the way (a wall beside you, a door frame) pushes the hand back along that line, never nearer
## than NEAR.

##   SLIDE  squeezed through a slit: palm flat on the wall at exactly the point given (no probing, no reach
##          limit, no line-of-sight fallback), so it slides along with you; the arm follows from the shoulder
enum Mode { ANIM, HIDE, CARRY, WALL, SLIDE }

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
const SNAP_HYST := 0.03           # m: the arm has to be this much within / beyond its reach to go onto / come off the wall face
const CLEAR := 0.03              # m kept between the fingertips and anything in the way

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
	var on_face := false          # the hand is laid on the wall face (with hysteresis)

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

func set_mode(i: int, mode: Mode) -> void:
	var h := _hands[i]
	if h.mode == mode:
		return
	h.mode = mode
	h.at_ok = false
	h.clear_k = 1.0
	h.from_pos = h.cur_pos
	h.from_rot = h.cur_rot
	h.from_q = h.cur_q.duplicate()
	h.u = 0.0 if h.seen else 1.0
	h.vel = 0.0

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

## One physics tick: the springs, the grip, the odd shift of it
func tick(dt: float) -> void:
	for h in _hands:
		var s := _spring(h.mode)
		h.vel += (s.x * s.x * (1.0 - h.u) - 2.0 * s.y * s.x * h.vel) * dt
		h.u += h.vel * dt
		h.crouch = lerpf(h.crouch, h.crouch_goal, minf(1.0, dt * 8.0))
		var on_wall := h.mode == Mode.WALL or h.mode == Mode.SLIDE
		h.grab = lerpf(h.grab, 1.0 if on_wall and h.holding else 0.0, minf(1.0, dt * 8.0))
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
				pos = wall[0]
				rot = wall[1]
				q = _wall_fingers(h, wall[2])
				if h.bones.size() > q.size():
					q.append(wall[3])
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
		if h.mode == Mode.WALL:
			at += (cam.affine_inverse().basis * Vector3.UP).normalized() * ARC * sin(PI * e)
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
	# never inside the wall itself (a squeeze gap is barely wider than the shoulders): the arm would run through it
	var in_wall := (shoulder - wall).dot(n)
	if in_wall < SHOULDER_OFF:
		shoulder += n * (SHOULDER_OFF - in_wall)
	var lean := wall - knuckle - shoulder
	var short := lean.length() - reach
	if short > 0.0:
		var toward := lean.normalized()
		var room := (shoulder.z - SHOULDER_FRONT) / -toward.z if toward.z < -0.001 else short
		shoulder += toward * clampf(short, 0.0, maxf(0.0, room))
	var slack := reach + 0.02                                        # the shoulder gives this much more
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
	# onto the wall face, if the arm is long enough for that; else it stays short of it, on the line of sight
	# (it takes more to come off than to go on, so a hand at the limit of its reach doesn't flip between the two)
	var on_wall := _hug(cam, at, h.normal, h.grab, space)
	var arm := (on_wall - knuckle - shoulder).length()
	h.on_face = arm <= slack + (SNAP_HYST if h.on_face else -SNAP_HYST)
	if h.on_face:
		at = on_wall
	# whatever the probes did this frame, the hand moves smoothly
	h.at_s = h.at_s.lerp(at, 1.0 - exp(-_dt * AT_SMOOTH)) if h.at_ok else at
	h.at_ok = true
	at = h.at_s
	return _limb(h, at, hand, knuckle, shoulder, square, up, n, fore_len, upper_len, reach)

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
func _limb(h: Hand, at: Vector3, hand: Quaternion, knuckle: Vector3, shoulder: Vector3, square: Basis, up: Vector3, n: Vector3, fore_len: float, upper_len: float, reach: float) -> Array:
	var wrist_at := at - knuckle
	# shoulder, elbow, wrist: whatever moved the hand, the shoulder gives before the arm stretches
	var span := wrist_at - shoulder
	var far := span.length()
	if far > reach:
		shoulder = wrist_at - span / far * reach
		far = reach
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
