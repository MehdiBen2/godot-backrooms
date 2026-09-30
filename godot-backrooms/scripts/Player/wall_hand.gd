extends SkeletonModifier3D
## The hands while you peek round a wall edge (peek.gd). Sits under the arms' Skeleton3D (added by
## torch_model.gd), so it runs after their AnimationPlayer and can take either forearm off it.
##
## torch_model.gd puts each hand in one of four modes:
##   ANIM   left to the animation (the torch arm's pickup / hold / flinch)
##   HIDE   let down just below the view
##   CARRY  held low, only the top of the fist (and the torch, if it's in that hand) showing: the torch
##          hold (TorchHold's first frame) let down, mirrored for the left hand
##   WALL   on the edge: palm flat on the wall, knuckles on the corner, fingers hooked round it. Too far
##          off (or walking) the hand stops short and open, trembling a little
## On a change of mode the hand eases from wherever it is to the new pose on a spring: a snappy one onto
## the wall, landing with a slight overshoot, softer ones elsewhere.
##
## The arms model is forearms only, no upper arm, so a forearm on the wall has to come in from outside
## the view: from an elbow point just off the bottom corner on the wall's side, the knuckles go where
## your line of sight to the edge is one forearm from it. On screen they sit right on the corner, though
## nearer than the wall (the arms cast no shadow, so nothing gives that away).

enum Mode { ANIM, HIDE, CARRY, WALL }

const LEFT := 0
const RIGHT := 1
const FINGERS: Array[String] = ["Index", "Middle", "Ring", "Little"]
const JOINTS: Array[String] = ["Proximal", "Intermediate", "Distal"]
const THUMB: Array[String] = ["ThumbMetacarpal", "ThumbProximal", "ThumbDistal"]
const HOLD_ANIM := "TorchHold"
const HOOK: Array[float] = [0.9, 0.35, 0.15]      # rad per finger joint on top of rest: bent round the corner
const SPLAY: Array[float] = [-0.25, -0.15, -0.05] # braced: fingers straightened
const KNUCKLE := 0.14             # armature units from the wrist to the knuckles
const ELBOW := Vector3(0.21, -0.17, -0.05)        # m, camera space: the wall arm's elbow (right; x mirrored for the left)
const ELBOW_CROUCH := -0.03
const EDGE_OUT := 0.05            # m: from peek.gd's point on the wall out to just past its edge
const RISE := 0.0                 # m above the eye the hand takes the wall
const RISE_CROUCH := -0.10        # crouched it takes it lower
const CUP := 0.3                  # how far the palm turns in round the corner
const REACH := 0.85               # m: an edge this close can be taken hold of
const BRACE := 0.8                # of a forearm: how far out the open hand comes
const CARRY_DROP := 0.13          # m the carrying hand sits below the usual torch hold
const CARRY_OUT := 0.03           # m out to its side
const HIDE_DROP := 0.25           # m further down again: out of view
const ARC := 0.05                 # m the hand lifts on its way onto the wall

class Hand:
	var side := 1.0               # 1 right, -1 left
	var fore := -1                # the LowerArm bone
	var bones: Array[int] = []    # wrist, 4 fingers x 3 joints, the thumb's 3
	var rest: Array[Quaternion] = []
	var hold: Array[Quaternion] = []   # the same bones in the torch hold
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
	var hook: Array[float] = [0.0, 0.0, 0.0, 0.0]   # per finger 0 open .. 1 hooked, eased one after the other
	var edge := Vector3.ZERO      # world: peek.gd's point just in from the edge, at eye height
	var normal := Vector3.BACK
	var out := Vector3.LEFT
	var t := 0.0
	var regrip := 4.0             # s to the next shift of the grip
	var shift_t := 0.0
	var shift := 0.0              # 0..1..0 over a shift

var view: Node3D                  # the camera the hands are posed in front of
var _hands: Array[Hand] = []
var _hold_fore := Transform3D()   # the right forearm in the torch hold, relative to its parent bone
var _rng := RandomNumberGenerator.new()

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
	for s in ["Left", "Right"]:
		var h := Hand.new()
		h.side = -1.0 if s == "Left" else 1.0
		h.fore = skel.find_bone(s + "LowerArm")
		var names: Array[String] = ["Hand"]
		for f in FINGERS:
			for j in JOINTS:
				names.append(f + j)
		names.append_array(THUMB)
		for n in names:
			var b := skel.find_bone(s + n)
			if b < 0:
				return false
			h.bones.append(b)
			h.rest.append(skel.get_bone_rest(b).basis.get_rotation_quaternion())
			# the left hand holds it the way the right does, mirrored
			var q: Quaternion = rot.get("Right" + n, skel.get_bone_rest(skel.find_bone("Right" + n)).basis.get_rotation_quaternion())
			h.hold.append(q if s == "Right" else _mirror(q))
		if h.fore < 0:
			return false
		h.mode = Mode.ANIM if s == "Right" else Mode.HIDE
		h.regrip = _rng.randf_range(3.0, 6.0)
		_hands.append(h)
	return true

func set_mode(i: int, mode: Mode) -> void:
	var h := _hands[i]
	if h.mode == mode:
		return
	h.mode = mode
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
		var on_wall := h.mode == Mode.WALL
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
		# the fingers hook round once the hand has landed, index first
		var goal := h.grab * (1.0 - 0.5 * h.shift) if on_wall and h.u > 0.75 else 0.0
		for k in 4:
			h.hook[k] = lerpf(h.hook[k], goal, minf(1.0, dt * (20.0 - k * 3.5)))

## (rad/s, damping) per mode: onto the wall it snaps, lands a little past and settles
func _spring(mode: Mode) -> Vector2:
	match mode:
		Mode.WALL: return Vector2(17.0, 0.62)
		Mode.HIDE: return Vector2(14.0, 1.0)
	return Vector2(11.0, 0.9)

static func _mirror(q: Quaternion) -> Quaternion:
	return Quaternion(q.x, -q.y, -q.z, q.w)

func _process_modification_with_delta(_delta: float) -> void:
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
				q = _wall_fingers(h)
				var wall := _wall(h, cam, carry_rot, skel.get_bone_rest(h.bones[0]).origin, q[0], unit)
				pos = wall[0]
				rot = wall[1]
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

## The wrist flat (as at rest, bent back) and the fingers hooked round the corner, or open while braced
func _wall_fingers(h: Hand) -> Array[Quaternion]:
	var q: Array[Quaternion] = [h.rest[0]]
	for f in 4:
		var k := h.hook[f] if h.grab > 0.05 else 0.0
		for j in 3:
			var bend := lerpf(SPLAY[j] * (1.0 - h.grab), HOOK[j], k)
			q.append(h.rest[1 + f * 3 + j] * Quaternion(Vector3.RIGHT, bend))
	for j in 3:
		q.append(h.rest[13 + j])
	return q

## The forearm on the wall, camera space: [position, rotation]. `wrist`: the hand bone's place on the
## forearm, `wrist_rot` its turn; `base` the turn the swing starts from.
func _wall(h: Hand, cam: Transform3D, base: Quaternion, wrist: Vector3, wrist_rot: Quaternion, unit: float) -> Array:
	var to_cam := cam.affine_inverse()
	var up := (to_cam.basis * Vector3.UP).normalized()
	var knuckle := wrist + wrist_rot * Vector3(0.0, KNUCKLE, 0.0)   # forearm space
	var palm := wrist_rot * Vector3(0.0, 0.0, 1.0)                   # the fingers curl to +Z
	var reach := knuckle.length() * unit
	var elbow := Vector3(ELBOW.x * h.side, ELBOW.y + ELBOW_CROUCH * h.crouch, ELBOW.z)
	var wall := to_cam * (h.edge + h.out * EDGE_OUT + Vector3.UP * (RISE + RISE_CROUCH * h.crouch))
	var sight := wall.normalized()
	# the knuckles where the line of sight is one forearm from the elbow (or as near as it gets)
	var along := sight.dot(elbow)
	var disc := along * along - elbow.length_squared() + reach * reach
	var on := sight * minf(along + sqrt(disc), wall.length()) if disc >= 0.0 \
			else elbow + (sight * along - elbow).normalized() * reach
	var at := (elbow + (on - elbow).normalized() * reach * BRACE).lerp(on, h.grab)
	at += Vector3(sin(h.t * 7.3), sin(h.t * 9.1 + 1.0), 0.0) * 0.002 * (1.0 - h.grab)   # an open hand, not quite steady
	at += ((elbow - on).normalized() * 0.012 - up * 0.008) * h.shift                   # re-gripping
	var dir := (at - elbow).normalized()
	var rot := Quaternion((base * knuckle).normalized(), dir) * base
	# roll about the forearm so the palm faces into the wall, turned in a little round the corner
	var face := (to_cam.basis * (-h.normal - h.out * CUP)).normalized()
	var a := rot * palm
	a -= dir * a.dot(dir)
	var b := face - dir * face.dot(dir)
	if a.length_squared() > 0.0001 and b.length_squared() > 0.0001:
		rot = Quaternion(dir, atan2(dir.dot(a.cross(b)), a.dot(b))) * rot
	return [at - rot * (knuckle * unit), rot]
