extends RefCounted
## WALLS, layer 0: plain 2D geometry for the wall graph (wall_graph.gd). No nodes, no scene tree, no level: the
## game, the level editor (which loads this file from the game's folder) and tools/test_walls.gd all use it.
##
## A wall's centre line runs from point a to point b. Straight, or an arc through both with a sagitta `s`: how
## far the middle of the arc stands off the middle of the chord, + to the left of a->b (the side (-d.y, d.x)
## points to, d the chord's direction), - to the right. |s| past half the chord is the bigger part of a circle.
## The ends are always a and b, so changing s bends the wall and never moves its ends.
##
## A "curve" is a Dictionary: {kind: LINE, a, b} or {kind: ARC, c (centre), r, a0 (angle of the start), sw (signed
## sweep, radians: + anticlockwise in the plan's maths frame)}. A parameter t runs 0 at the start to 1 at the end.

const LINE := 0
const ARC := 1
const EPS := 1e-7
## Under this much sagitta per unit of chord an arc is drawn and built straight
const FLAT := 1e-4

# ---------------------------------------------------------------- arcs from a chord and a sagitta
static func is_arc(a: Vector2, b: Vector2, s: float) -> bool:
	return absf(s) > FLAT * maxf(a.distance_to(b), 1e-3)

## The signed sweep of the arc a -> b with sagitta s (0 when straight)
static func sweep_of(a: Vector2, b: Vector2, s: float) -> float:
	var c := a.distance_to(b)
	if c < EPS or not is_arc(a, b, s): return 0.0
	return -4.0 * atan(2.0 * s / c)

## The sagitta of the arc a -> b that sweeps `sw` radians (the inverse of sweep_of)
static func sagitta_of(a: Vector2, b: Vector2, sw: float) -> float:
	return -a.distance_to(b) * 0.5 * tan(sw * 0.25)

## The centre line of a wall as a curve
static func curve(a: Vector2, b: Vector2, s: float) -> Dictionary:
	if not is_arc(a, b, s) or a.distance_to(b) < EPS:
		return {"kind": LINE, "a": a, "b": b}
	var c := a.distance_to(b)
	var d := (b - a) / c
	var n := Vector2(-d.y, d.x)
	var r := (c * c * 0.25 + s * s) / (2.0 * absf(s))
	var top := (a + b) * 0.5 + n * s
	var centre := top - n * signf(s) * r
	return {"kind": ARC, "c": centre, "r": r, "a0": (a - centre).angle(), "sw": sweep_of(a, b, s)}

static func point(cv: Dictionary, t: float) -> Vector2:
	if cv.kind == LINE: return (cv.a as Vector2).lerp(cv.b, t)
	return (cv.c as Vector2) + Vector2.from_angle(cv.a0 + cv.sw * t) * cv.r

static func start_of(cv: Dictionary) -> Vector2:
	return point(cv, 0.0)

static func end_of(cv: Dictionary) -> Vector2:
	return point(cv, 1.0)

static func length(cv: Dictionary) -> float:
	if cv.kind == LINE: return (cv.a as Vector2).distance_to(cv.b)
	return cv.r * absf(cv.sw)

## The direction of travel at t (unit)
static func tangent(cv: Dictionary, t: float) -> Vector2:
	if cv.kind == LINE:
		var d: Vector2 = cv.b - cv.a
		return d.normalized() if d.length() > EPS else Vector2.RIGHT
	var ang: float = cv.a0 + cv.sw * t
	return Vector2(-sin(ang), cos(ang)) * signf(cv.sw)

## The left-hand normal of the travel at t: (-d.y, d.x)
static func normal(cv: Dictionary, t: float) -> Vector2:
	var d := tangent(cv, t)
	return Vector2(-d.y, d.x)

## The same curve run the other way
static func reversed(cv: Dictionary) -> Dictionary:
	if cv.kind == LINE: return {"kind": LINE, "a": cv.b, "b": cv.a}
	return {"kind": ARC, "c": cv.c, "r": cv.r, "a0": cv.a0 + cv.sw, "sw": -cv.sw}

## The curve `w` to its left (negative: to its right). An arc's offset is the arc round the same centre, its
## radius grown on the outside of the bend and shrunk on the inside (never to nothing).
static func offset(cv: Dictionary, w: float) -> Dictionary:
	if cv.kind == LINE:
		var n := normal(cv, 0.0) * w
		return {"kind": LINE, "a": cv.a + n, "b": cv.b + n}
	var r: float = cv.r - signf(cv.sw) * w
	return {"kind": ARC, "c": cv.c, "r": maxf(r, 1e-4), "a0": cv.a0, "sw": cv.sw}

## How far along `cv` the point nearest `p` is (0..1, clamped to the ends) and that point:
## {t, p, d (distance)}
static func closest(cv: Dictionary, p: Vector2) -> Dictionary:
	if cv.kind == LINE:
		var a: Vector2 = cv.a
		var ab: Vector2 = cv.b - a
		var l2 := ab.length_squared()
		var t := 0.0 if l2 < EPS else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var q := a + ab * t
		return {"t": t, "p": q, "d": q.distance_to(p)}
	var t := param_of(cv, p)
	if t < 0.0 or t > 1.0:
		var pa := start_of(cv)
		var pb := end_of(cv)
		var on_a := pa.distance_to(p) <= pb.distance_to(p)
		var q := pa if on_a else pb
		return {"t": 0.0 if on_a else 1.0, "p": q, "d": q.distance_to(p)}
	var q := point(cv, t)
	return {"t": t, "p": q, "d": q.distance_to(p)}

## The parameter of `p` on the curve's carrier (the infinite line / the whole circle), unclamped. Round a
## circle it is measured from the start the way the arc runs, in [0, TAU / |sw|).
static func param_of(cv: Dictionary, p: Vector2) -> float:
	if cv.kind == LINE:
		var a: Vector2 = cv.a
		var ab: Vector2 = cv.b - a
		var l2 := ab.length_squared()
		return 0.0 if l2 < EPS else (p - a).dot(ab) / l2
	if absf(cv.sw) < EPS: return 0.0
	var ang := ((p - cv.c) as Vector2).angle()
	var delta := fposmod((ang - cv.a0) * signf(cv.sw), TAU)
	# a hair before the start counts as the start, not as most of the way round
	if delta > TAU - 1e-6: delta -= TAU
	return delta / absf(cv.sw)

# ---------------------------------------------------------------- intersections
## Where two carriers cross (infinite lines, whole circles): 0, 1 or 2 points
static func carrier_hits(c1: Dictionary, c2: Dictionary) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if c1.kind == LINE and c2.kind == LINE:
		var p = Geometry2D.line_intersects_line(c1.a, (c1.b - c1.a) as Vector2, c2.a, (c2.b - c2.a) as Vector2)
		if p != null: out.append(p)
	elif c1.kind == LINE:
		out = _line_circle(c1.a, c1.b, c2.c, c2.r)
	elif c2.kind == LINE:
		out = _line_circle(c2.a, c2.b, c1.c, c1.r)
	else:
		out = _circle_circle(c1.c, c1.r, c2.c, c2.r)
	return out

static func _line_circle(a: Vector2, b: Vector2, c: Vector2, r: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var d := b - a
	var l := d.length()
	if l < EPS: return out
	d /= l
	var f := a - c
	var bb := f.dot(d)
	var disc := bb * bb - (f.length_squared() - r * r)
	if disc < -1e-9 * maxf(r * r, 1.0): return out
	var sq := sqrt(maxf(disc, 0.0))
	out.append(a + d * (-bb - sq))
	if sq > 1e-9: out.append(a + d * (-bb + sq))
	return out

static func _circle_circle(c1: Vector2, r1: float, c2: Vector2, r2: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var d := c1.distance_to(c2)
	if d < EPS or d > r1 + r2 + 1e-9 or d < absf(r1 - r2) - 1e-9: return out
	var a := (r1 * r1 - r2 * r2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(r1 * r1 - a * a, 0.0))
	var u := (c2 - c1) / d
	var m := c1 + u * a
	var perp := Vector2(-u.y, u.x)
	out.append(m + perp * h)
	if h > 1e-9: out.append(m - perp * h)
	return out

## Where two curves cross within both: [{p, t1, t2}], each t in [0, 1] give or take `slack` (a parameter)
static func hits(c1: Dictionary, c2: Dictionary, slack := 1e-6) -> Array:
	var out: Array = []
	for p: Vector2 in carrier_hits(c1, c2):
		var t1 := param_of(c1, p)
		var t2 := param_of(c2, p)
		if t1 >= -slack and t1 <= 1.0 + slack and t2 >= -slack and t2 <= 1.0 + slack:
			out.append({"p": p, "t1": clampf(t1, 0.0, 1.0), "t2": clampf(t2, 0.0, 1.0)})
	return out

## Two straight curves on the same line (overlapping or not)
static func collinear(c1: Dictionary, c2: Dictionary, tol: float) -> bool:
	if c1.kind != LINE or c2.kind != LINE: return false
	var d1: Vector2 = (c1.b - c1.a)
	var d2: Vector2 = (c2.b - c2.a)
	if d1.length() < EPS or d2.length() < EPS: return false
	if absf(d1.normalized().cross(d2.normalized())) > 1e-4: return false
	var n := Vector2(-d1.y, d1.x).normalized()
	return absf(((c2.a - c1.a) as Vector2).dot(n)) < tol and absf(((c2.b - c1.a) as Vector2).dot(n)) < tol

# ---------------------------------------------------------------- tessellation
## How many straight pieces an arc of radius r sweeping sw is drawn with, so it is never more than `tol` off
## the true curve (metres in, whatever unit r is in); `override` > 0 wins
static func pieces(r: float, sw: float, tol := 0.01, override := 0) -> int:
	if override > 0: return clampi(override, 1, 512)
	if absf(sw) < EPS: return 1
	if r <= tol * 2.0: return clampi(ceili(absf(sw) / (PI / 4.0)), 1, 512)
	var step := 2.0 * acos(1.0 - tol / r)
	return clampi(ceili(absf(sw) / step), 1, 512)

## The curve as points, start and end included
static func polyline(cv: Dictionary, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if cv.kind == LINE:
		out.append(cv.a)
		out.append(cv.b)
		return out
	for i in n + 1: out.append(point(cv, float(i) / n))
	return out

# ---------------------------------------------------------------- polygons
static func area(poly: PackedVector2Array) -> float:
	var a := 0.0
	var n := poly.size()
	for i in n:
		var p := poly[i]
		var q := poly[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5

## Wrap an angle difference into (-PI, PI]
static func wrap(a: float) -> float:
	return fposmod(a + PI, TAU) - PI
