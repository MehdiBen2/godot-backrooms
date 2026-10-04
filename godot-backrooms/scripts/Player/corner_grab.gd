extends RefCounted
## Walking along a wall that ends at a corner just ahead: finds the corner, so the hand on that side can take
## hold of its edge and pull you round it (player.gd feeds it, torch_model.gd poses the hand).
##
## From the eye, a ray out to each side finds a wall running beside you. Stepping forward along it, rays
## out to the same side keep hitting it until the wall ends (they miss, or the wall is much further off):
## that is the corner. A few halvings put it within a centimetre or two. It has to be far enough ahead for
## the hand to be in view (AHEAD_MIN) and near enough to be worth it (AHEAD_MAX).

const SIDE := 0.85                # m: a wall this close beside you
const FACING := 0.85              # it has to face you this squarely (cos)
const STEP := 0.15                # m: how far forward each probe goes
const AHEAD_MIN := 0.5
const AHEAD_MAX := 1.2
const GAP := 0.6                  # m: a wall this much further off than beside you has ended
const INSET := 0.04               # m: the hand takes the wall this far in from its edge

var side := 0                     # -1 left, +1 right
var dir := Vector3.ZERO           # world: from you to the wall (and round the corner)
var point := Vector3.ZERO         # world: the wall face just in from its end, at eye height
var normal := Vector3.ZERO        # world: the wall face's normal (towards you)
var out := Vector3.ZERO           # world: along the wall to its end (the way you're going)
var ahead := 0.0                  # m: how far ahead the corner is

## True if there's a corner to take hold of (and the fields are set for it). `fwd`: the way you're going, flat.
func scan(body: CharacterBody3D, eye_h: float, fwd: Vector3) -> bool:
	var space := body.get_world_3d().direct_space_state
	if space == null:
		return false
	var eye := body.global_position + Vector3.UP * eye_h
	var best := INF
	var found := false
	for s: int in [-1, 1]:
		var d := Vector3(-fwd.z, 0.0, fwd.x) * s
		var first := _ray(space, body, eye, eye + d * SIDE)
		if first.is_empty() or (first.normal as Vector3).dot(-d) < FACING:
			continue
		var beside: float = (first.position - eye).dot(d)
		if beside >= best:
			continue                  # both sides have a wall: the nearer one
		var end := _end(space, body, eye, fwd, d, beside)
		if end.x < 0.0:
			continue
		best = beside
		found = true
		side = s
		dir = d
		out = fwd
		ahead = end.x
		normal = first.normal
		point = eye + fwd * maxf(0.0, end.x - INSET) + d * end.y
	return found

## Vector2(how far ahead the wall ends, how far off its face is there), x < 0 if it doesn't end in range
func _end(space: PhysicsDirectSpaceState3D, body: CharacterBody3D, eye: Vector3, fwd: Vector3, d: Vector3, beside: float) -> Vector2:
	var prev := 0.0
	var face := beside
	var t := STEP
	while t <= AHEAD_MAX + 0.001:
		var f := _face(space, body, eye + fwd * t, d, beside)
		if f < 0.0:
			if t < AHEAD_MIN:
				return Vector2(-1.0, 0.0)          # too late: the corner is already beside you
			var lo := prev
			var hi := t
			for i in 4:
				var mid := (lo + hi) * 0.5
				var fm := _face(space, body, eye + fwd * mid, d, beside)
				if fm < 0.0:
					hi = mid
				else:
					lo = mid
					face = fm
			return Vector2((lo + hi) * 0.5, face)
		face = f
		prev = t
		t += STEP
	return Vector2(-1.0, 0.0)

## How far off the wall's face is from `from` (out along `d`), or -1 if it isn't there: no wall, or one well beyond
func _face(space: PhysicsDirectSpaceState3D, body: CharacterBody3D, from: Vector3, d: Vector3, beside: float) -> float:
	var hit := _ray(space, body, from, from + d * (beside + GAP))
	if hit.is_empty() or (hit.normal as Vector3).dot(-d) < FACING:
		return -1.0
	var f: float = (hit.position - from).dot(d)
	return -1.0 if f > beside + GAP * 0.8 else f

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
