@tool
class_name UBTriangulate
extends RefCounted
## Ear-clipping triangulation for planar n-gon faces.
## Orientation-agnostic: emitted triangles preserve the input winding order.

## Corner tolerance for ear clipping, RELATIVE: it is scaled by the face's
## squared radius, because the cross products it is compared against scale with
## the face's size squared. An absolute 1e-8 meant nothing on a face a few
## millimetres across, where the products themselves are that small.
const EPS := 1e-8
## A face whose Newell normal (twice its area) is below this fraction of its
## squared radius has no usable plane and is fanned. Relative for the same
## reason: the old absolute test (|n|^2 <= 1e-8) fanned every face under about
## 5e-5 area, so a small CONCAVE face triangulated outside its own outline.
const DEGENERATE_REL := 1e-6


## Newell's method; positive along the CCW right-handed normal, so a face wound
## clockwise-from-front yields the negated front normal (see UBMeshData.face_normal).
## Points are centered on their centroid first: Newell multiplies coordinate
## differences by coordinate sums, and on a face far from the origin float32
## rounding in the sums would tilt the result, worst on thin faces.
static func newell_normal(points: PackedVector3Array) -> Vector3:
	var n := Vector3.ZERO
	var count := points.size()
	if count < 3:
		return n
	var center := Vector3.ZERO
	for p in points:
		center += p
	center /= float(count)
	for i in count:
		var c := points[i] - center
		var nx := points[(i + 1) % count] - center
		n.x += (c.y - nx.y) * (c.z + nx.z)
		n.y += (c.z - nx.z) * (c.x + nx.x)
		n.z += (c.x - nx.x) * (c.y + nx.y)
	return n


## Returns local index triples into `points`.
static func triangulate(points: PackedVector3Array) -> PackedInt32Array:
	var count := points.size()
	var out := PackedInt32Array()
	if count < 3:
		return out
	if count == 3:
		out.append_array(PackedInt32Array([0, 1, 2]))
		return out
	var center := Vector3.ZERO
	for p in points:
		center += p
	center /= float(count)
	var r2 := 0.0
	for p in points:
		r2 = maxf(r2, (p - center).length_squared())
	var normal := newell_normal(points)
	if r2 <= 0.0 or normal.length() <= DEGENERATE_REL * r2:
		return _fan(count)
	normal = normal.normalized()
	var axis := Vector3.RIGHT if absf(normal.x) < 0.9 else Vector3.UP
	var u := (axis - normal * axis.dot(normal)).normalized()
	var v := normal.cross(u)

	var pts := PackedVector2Array()
	pts.resize(count)
	for i in count:
		var c := points[i] - center
		pts[i] = Vector2(c.dot(u), c.dot(v))
	var orientation := signf(_signed_area(pts))
	if orientation == 0.0:
		return _fan(count)
	var remaining: Array[int] = []
	for i in count:
		remaining.append(i)
	var guard := count * count
	while remaining.size() > 3 and guard > 0:
		guard -= 1
		var ear := _find_ear(pts, remaining, orientation, EPS * r2)
		if ear < 0:
			ear = 0
		var m := remaining.size()
		out.append_array(PackedInt32Array([
			remaining[(ear - 1 + m) % m], remaining[ear], remaining[(ear + 1) % m],
		]))
		remaining.remove_at(ear)
	out.append_array(PackedInt32Array([remaining[0], remaining[1], remaining[2]]))
	return out


static func _fan(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(1, count - 1):
		out.append_array(PackedInt32Array([0, i, i + 1]))
	return out


static func _signed_area(pts: PackedVector2Array) -> float:
	var area := 0.0
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		area += a.cross(b)
	return area * 0.5


static func _find_ear(pts: PackedVector2Array, remaining: Array[int], orientation: float, eps: float) -> int:
	var m := remaining.size()
	for i in m:
		var a := pts[remaining[(i - 1 + m) % m]]
		var b := pts[remaining[i]]
		var c := pts[remaining[(i + 1) % m]]
		if (b - a).cross(c - b) * orientation <= eps:
			continue
		var blocked := false
		for j in m:
			if j == i or j == (i - 1 + m) % m or j == (i + 1) % m:
				continue
			if _point_in_triangle(pts[remaining[j]], a, b, c, orientation, eps):
				blocked = true
				break
		if not blocked:
			return i
	return -1


static func _point_in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2, orientation: float, eps: float) -> bool:
	var d1 := (b - a).cross(p - a) * orientation
	var d2 := (c - b).cross(p - b) * orientation
	var d3 := (a - c).cross(p - c) * orientation
	return d1 >= -eps and d2 >= -eps and d3 >= -eps
