extends RefCounted
## Automatic corner peek: facing a wall whose edge is close beside you, the view leans out past the edge
## so you can see round it. No key. player.gd feeds it once per physics tick and reads `offset` (m, + is
## right), `amount` (0..1, eased) and `side` (-1 left, +1 right, 0 none) to move the camera, and hands
## the edge (`edge`, `normal`, `out`, `dist`) on to the torch model so a free hand can take hold of it
## (wall_hand.gd).
##
## Found from the un-leaned eye along the way the body faces:
##   wall     a ray straight ahead has to hit a wall that faces you, within REACH
##   edge     stepping out to each side, a ray forward from beside the eye has to get well past where the
##            wall was: the wall ends there. The nearer edge wins; a wall right beside you shuts that side
##   refine   a few halvings put the edge within a centimetre or two, for the hand
## It leans once the edge has been there ENGAGE s and lets go RELEASE s after it went, so walking along a
## wall or brushing past a corner never makes it flicker. Changing sides lets go of the old one first.
## The lean itself is a spring that settles with a touch of overshoot.

const REACH := 1.0                # m: how far ahead the wall can be
const FACING := 0.6               # it has to face you this squarely (cos of the angle)
const STEPS: Array[float] = [0.15, 0.25, 0.35, 0.45, 0.55]   # m: how far out to the side the edge is looked for
const PAST := 0.6                 # m: a probe that runs this far past the wall has found the gap
const CLEAR := 0.18               # m: room kept between the leaned eye and anything beside it
const LEAN_MAX := 0.42            # m: furthest the eye leans out
const LEAN_MIN := 0.16            # m: less room than this to lean into and there's no peek
const LEAN_PAST := 0.12           # m: the eye leans this far past the edge
const INSET := 0.04               # m: the hand takes the wall this far in from its edge
const ENGAGE := 0.18
const RELEASE := 0.25
const SPRING := 14.0              # rad/s: ~0.35 s to settle
const DAMP := 0.8                 # < 1: a slight overshoot as it settles

var side := 0                     # -1 left, +1 right, 0 none (held while easing back out)
var amount := 0.0                 # 0..~1.02 how far into the lean, sprung
var leaning := false              # going into / holding the lean (false while it eases back out)
var offset := 0.0                 # m sideways, signed: what the camera moves by
var edge := Vector3.ZERO          # world: a point on the wall face just in from its edge, at eye height
var normal := Vector3.ZERO        # world: the wall face's normal
var out := Vector3.ZERO           # world: from the wall towards its edge (the way you lean)
var dist := 0.0                   # m from the eye to `edge`

var _lean := 0.0                  # m, eased towards the lean the edge asks for
var _vel := 0.0
var _seen := 0.0                  # s the edge has been there
var _gone := 0.0                  # s since it went
var _found := 0                   # this tick's side (0 none) and what was found there
var _f_lean := 0.0
var _f_edge := Vector3.ZERO
var _f_normal := Vector3.ZERO
var _f_out := Vector3.ZERO
var _f_dist := 0.0

## One physics tick. `eye_h`: eye height above the feet. `can`: on the floor, not sprinting, in control.
func update(dt: float, body: CharacterBody3D, eye_h: float, can: bool) -> void:
	_found = _detect(body, eye_h) if can else 0
	if _found != 0 and (side == 0 or _found == side):
		_seen += dt
		_gone = 0.0
		if side == 0 and _seen >= ENGAGE:
			side = _found
		if side != 0:
			_lean = lerpf(_lean, _f_lean, minf(1.0, dt * 6.0)) if amount > 0.05 else _f_lean
			edge = _f_edge
			normal = _f_normal
			out = _f_out
			dist = _f_dist
	else:
		_seen = 0.0 if _found == 0 else _seen
		_gone += dt
	var want := 1.0 if side != 0 and (_found == side or _gone < RELEASE) else 0.0
	leaning = want > 0.0
	_vel += (SPRING * SPRING * (want - amount) - 2.0 * DAMP * SPRING * _vel) * dt
	amount += _vel * dt
	if amount <= 0.0 and want == 0.0:
		amount = 0.0
		_vel = 0.0
		if side != 0:
			side = 0              # fully back: free to lean the other way
			_seen = 0.0
	offset = side * _lean * amount

## -1 / +1: the side with an edge to peek round (and the edge fields set for it), 0: none
func _detect(body: CharacterBody3D, eye_h: float) -> int:
	var space := body.get_world_3d().direct_space_state
	if space == null:
		return 0
	var eye := body.global_position + Vector3.UP * eye_h
	var fwd := -body.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return 0
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var hit := _ray(space, body, eye, eye + fwd * REACH)
	if hit.is_empty() or (hit.normal as Vector3).dot(-fwd) < FACING:
		return 0
	var ahead: float = (hit.position - eye).dot(fwd)
	var best := 0
	var best_rank := INF
	var best_e := Vector3.ZERO
	for s in [-1, 1]:
		var e := _edge(space, body, eye, fwd, right * s, ahead)
		if e.x < 0.0:
			continue
		# a tie keeps the side you're already on, else the left (the hand without the torch)
		var rank := e.x - (0.02 if s == side else 0.0) - (0.01 if s < 0 else 0.0)
		if rank < best_rank:
			best = s
			best_rank = rank
			best_e = e
	if best == 0:
		return 0
	_f_out = right * best
	_f_edge = eye + _f_out * maxf(0.0, best_e.x - INSET) + fwd * best_e.y
	_f_normal = hit.normal
	_f_dist = eye.distance_to(_f_edge)
	_f_lean = best_e.z
	return best

## Out along `dir`: Vector3(how far out the wall in front ends, how far ahead its face is there, the lean
## that clears it), or x < 0 when it doesn't end within reach or there's no room to lean that way.
func _edge(space: PhysicsDirectSpaceState3D, body: CharacterBody3D, eye: Vector3, fwd: Vector3, dir: Vector3, ahead: float) -> Vector3:
	var far: float = STEPS[-1] + CLEAR
	var beside := _ray(space, body, eye, eye + dir * far)
	var room := far if beside.is_empty() else eye.distance_to(beside.position)
	var inside := 0.0
	var face := ahead
	for o in STEPS:
		if o > room - 0.05:
			return Vector3(-1.0, 0.0, 0.0)          # walled in on that side before the edge
		var d := _probe(space, body, eye + dir * o, fwd, ahead)
		if d < 0.0:
			var lo := inside
			var hi: float = o
			for i in 4:
				var mid := (lo + hi) * 0.5
				var dm := _probe(space, body, eye + dir * mid, fwd, ahead)
				if dm < 0.0:
					hi = mid
				else:
					lo = mid
					face = dm
			var at := (lo + hi) * 0.5
			var lean := minf(minf(at + LEAN_PAST, LEAN_MAX), room - CLEAR)
			if lean < LEAN_MIN:
				return Vector3(-1.0, 0.0, 0.0)
			return Vector3(at, face, lean)
		inside = o
		face = d
	return Vector3(-1.0, 0.0, 0.0)

## Straight ahead from `from`: how far ahead the wall is there, or -1 if it runs well past `ahead` (a gap)
func _probe(space: PhysicsDirectSpaceState3D, body: CharacterBody3D, from: Vector3, fwd: Vector3, ahead: float) -> float:
	var hit := _ray(space, body, from, from + fwd * (ahead + PAST))
	if hit.is_empty():
		return -1.0
	var d: float = (hit.position - from).dot(fwd)
	return -1.0 if d > ahead + PAST * 0.8 else d

## The first wall along the segment (level geometry only: a creature or a prop in the way is looked past)
func _ray(space: PhysicsDirectSpaceState3D, body: CharacterBody3D, from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [body.get_rid()]
	for i in 3:
		var hit := space.intersect_ray(q)
		if hit.is_empty() or hit.collider is StaticBody3D:
			return hit
		q.exclude.append(hit.rid)
	return {}
