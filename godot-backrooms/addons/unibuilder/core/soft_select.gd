@tool
class_name UBSoftSelect
extends RefCounted
## Proportional editing (soft selection) weights: unselected vertices near the
## selection follow a transform drag with a distance falloff, so a move shapes
## a hill instead of tearing a cliff. Pure and headless. The editor computes
## weights once at drag start (and again on a mid-drag radius change) and hands
## them to UBTransformMath's weighted appliers.

## Falloff curves. All weigh 1 at the selection and, except CONSTANT, 0 at the
## radius; they differ in how influence is spread between. CONSTANT is full
## weight everywhere inside the radius and nothing outside. There is no RANDOM:
## weights must be a pure function of their inputs, because a mid-drag radius
## change recomputes them and replays the motion.
enum Falloff { SMOOTH, SPHERE, ROOT, INVERSE_SQUARE, SHARP, LINEAR, CONSTANT }

## UI labels, indexed by Falloff.
const FALLOFF_NAMES: PackedStringArray = [
	"Smooth", "Sphere", "Root", "Inverse Square", "Sharp", "Linear", "Constant",
]


## Weight for a normalized distance t (0 at the selection, 1 at the radius).
## Curves are written in x = 1 - t, the remaining-influence convention. SMOOTH
## is smoothstep and the default.
static func falloff_weight(t: float, falloff: int) -> float:
	var x := clampf(1.0 - t, 0.0, 1.0)
	match falloff:
		Falloff.SPHERE:
			return sqrt(x * (2.0 - x))
		Falloff.ROOT:
			return sqrt(x)
		Falloff.INVERSE_SQUARE:
			return x * (2.0 - x)
		Falloff.SHARP:
			return x * x
		Falloff.LINEAR:
			return x
		Falloff.CONSTANT:
			return 1.0
		_:
			return x * x * (3.0 - 2.0 * x)


## Per-vertex drag weights: every selected vertex at exactly 1.0, every other
## vertex within `radius` of its nearest selected vertex at the chosen
## falloff. Vertices at or beyond the radius are omitted, so the result doubles
## as the set of what moves (CONSTANT included). Distances are measured in
## world space through `xf`; the radius is in world units and does not shrink
## on a scaled node.
static func weights(positions: PackedVector3Array, selected: Dictionary,
		radius: float, xf: Transform3D = Transform3D.IDENTITY,
		falloff: int = Falloff.SMOOTH) -> Dictionary:
	var out := {}
	for vi in selected:
		if vi >= 0 and vi < positions.size():
			out[vi] = 1.0
	if radius <= 0.0 or out.is_empty():
		return out
	var anchors := PackedVector3Array()
	for vi in out:
		anchors.append(xf * positions[vi])
	for vi in positions.size():
		if out.has(vi):
			continue
		var wp: Vector3 = xf * positions[vi]
		var best := radius
		for a in anchors:
			var d := wp.distance_to(a)
			if d < best:
				best = d
		if best < radius:
			var w := falloff_weight(best / radius, falloff)
			if w > 0.0:
				out[vi] = w
	return out
