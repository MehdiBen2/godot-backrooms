@tool
class_name UBRayAccel
extends RefCounted
## Cached triangle soup and BVH over a UBMeshData, in mesh-local space, for the
## editor's ray queries: face picking and the occlusion test behind click and
## marquee selection. Triangulation happens once per mesh version and each ray
## is a log-depth descent of the tree. Local space means the accelerator
## survives node moves untouched; callers convert their rays first
## (UBPicking._local_ray).

## A node holding this many triangles or fewer becomes a leaf.
const LEAF_SIZE := 8
const MAX_DEPTH := 32


var _tri := PackedVector3Array()

var _tri_face := PackedInt32Array()

var _order := PackedInt32Array()


var _centroid := PackedVector3Array()
var _tmin := PackedVector3Array()
var _tmax := PackedVector3Array()


var _bmin := PackedVector3Array()
var _bmax := PackedVector3Array()
var _left := PackedInt32Array()
var _right := PackedInt32Array()
var _start := PackedInt32Array()
var _count := PackedInt32Array()


## Cap on accelerators held by build_cached, which keys entries by mesh
## instance id against data.version, holds each mesh weakly, and evicts the
## least recently used entry. The cache is for read-only callers: an op that
## queries mid-mutation, before the version bump lands, would get an
## accelerator for the mesh it is halfway through rewriting.
const CACHE_MAX := 64

static var _cache := {}


static func build_cached(data) -> UBRayAccel:
	if data == null:
		return UBRayAccel.new()
	var id: int = data.get_instance_id()
	var hit: Dictionary = _cache.get(id, {})
	if not hit.is_empty() and hit["ref"].get_ref() == data and hit["version"] == data.version:

		_cache.erase(id)
		_cache[id] = hit
		return hit["accel"]

	if _cache.size() >= CACHE_MAX:
		for key in _cache.keys():
			if _cache[key]["ref"].get_ref() == null:
				_cache.erase(key)
	if _cache.size() >= CACHE_MAX:
		_cache.erase(_cache.keys()[0])
	var accel := build(data)
	_cache.erase(id)
	_cache[id] = {"ref": weakref(data), "version": data.version, "accel": accel}
	return accel


## Drop every cached accelerator. Call on scene change and plugin teardown so
## closed scenes leave nothing behind.
static func clear_cache() -> void:
	_cache.clear()


static func build(data) -> UBRayAccel:
	var accel := UBRayAccel.new()
	if data == null:
		return accel
	for fi in data.faces.size():
		var verts: PackedInt32Array = data.faces[fi].vertices
		if verts.size() < 3:
			continue
		var corners := PackedVector3Array()
		for vi in verts:
			corners.append(data.positions[vi])
		var tris := UBTriangulate.triangulate(corners)
		for t in range(0, tris.size() - 2, 3):
			accel._tri.append(corners[tris[t]])
			accel._tri.append(corners[tris[t + 1]])
			accel._tri.append(corners[tris[t + 2]])
			accel._tri_face.append(fi)
	var count := accel._tri_face.size()
	accel._order.resize(count)
	accel._centroid.resize(count)
	accel._tmin.resize(count)
	accel._tmax.resize(count)
	for i in count:
		accel._order[i] = i
		var base := i * 3
		var p0 := accel._tri[base]
		var p1 := accel._tri[base + 1]
		var p2 := accel._tri[base + 2]
		accel._centroid[i] = (p0 + p1 + p2) / 3.0
		accel._tmin[i] = p0.min(p1).min(p2)
		accel._tmax[i] = p0.max(p1).max(p2)
	if count > 0:
		accel._build_node(0, count, 0)

	accel._centroid = PackedVector3Array()
	accel._tmin = PackedVector3Array()
	accel._tmax = PackedVector3Array()
	return accel


func triangle_count() -> int:
	return _tri_face.size()


## Nearest forward hit as [face_index, t], or [-1, INF] on a miss. `t` is the
## distance along a normalized dir, matching UBPicking's ray convention.
func nearest(origin: Vector3, dir: Vector3) -> Array:
	var best_t := INF
	var best_face := -1
	if _left.is_empty():
		return [best_face, best_t]
	var inv := _inv_dir(dir)
	var stack := PackedInt32Array([0])
	while not stack.is_empty():
		var node := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		if _slab_entry(node, origin, inv) >= best_t:
			continue
		if _left[node] < 0:
			for i in range(_start[node], _start[node] + _count[node]):
				var tri := _order[i]
				var t := _tri_hit(tri, origin, dir)
				if t < best_t:
					best_t = t
					best_face = _tri_face[tri]
		else:
			stack.append(_left[node])
			stack.append(_right[node])
	return [best_face, best_t]


## The occlusion test: true when some triangle is hit strictly before `limit`.
## Exits at the first qualifying hit instead of resolving the nearest one.
func occluded_before(origin: Vector3, dir: Vector3, limit: float) -> bool:
	if _left.is_empty() or limit <= 0.0:
		return false
	var inv := _inv_dir(dir)
	var stack := PackedInt32Array([0])
	while not stack.is_empty():
		var node := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		if _slab_entry(node, origin, inv) >= limit:
			continue
		if _left[node] < 0:
			for i in range(_start[node], _start[node] + _count[node]):
				if _tri_hit(_order[i], origin, dir) < limit:
					return true
		else:
			stack.append(_left[node])
			stack.append(_right[node])
	return false


func _tri_hit(tri: int, origin: Vector3, dir: Vector3) -> float:
	var base := tri * 3
	var hit = Geometry3D.ray_intersects_triangle(
		origin, dir, _tri[base], _tri[base + 1], _tri[base + 2])
	if hit == null:
		return INF
	return (hit - origin).dot(dir)


func _inv_dir(dir: Vector3) -> Vector3:
	return Vector3(
		1.0 / dir.x if absf(dir.x) > 1e-12 else 1e30,
		1.0 / dir.y if absf(dir.y) > 1e-12 else 1e30,
		1.0 / dir.z if absf(dir.z) > 1e-12 else 1e30,
	)


func _slab_entry(node: int, origin: Vector3, inv: Vector3) -> float:
	var lo: Vector3 = _bmin[node]
	var hi: Vector3 = _bmax[node]
	var t1 := (lo.x - origin.x) * inv.x
	var t2 := (hi.x - origin.x) * inv.x
	var tmin := minf(t1, t2)
	var tmax := maxf(t1, t2)
	t1 = (lo.y - origin.y) * inv.y
	t2 = (hi.y - origin.y) * inv.y
	tmin = maxf(tmin, minf(t1, t2))
	tmax = minf(tmax, maxf(t1, t2))
	t1 = (lo.z - origin.z) * inv.z
	t2 = (hi.z - origin.z) * inv.z
	tmin = maxf(tmin, minf(t1, t2))
	tmax = minf(tmax, maxf(t1, t2))
	if tmax < maxf(tmin, 0.0):
		return INF
	return maxf(tmin, 0.0)


func _build_node(start: int, count: int, depth: int) -> int:
	var node := _left.size()
	_bmin.append(Vector3.ZERO)
	_bmax.append(Vector3.ZERO)
	_left.append(-1)
	_right.append(-1)
	_start.append(start)
	_count.append(count)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var clo := lo
	var chi := hi
	for i in range(start, start + count):
		var tri: int = _order[i]

		lo = lo.min(_tmin[tri])
		hi = hi.max(_tmax[tri])
		var c := _centroid[tri]
		clo = clo.min(c)
		chi = chi.max(c)
	_bmin[node] = lo
	_bmax[node] = hi
	if count <= LEAF_SIZE or depth >= MAX_DEPTH:
		return node

	var extent := chi - clo
	var axis := 0
	if extent.y > extent.x and extent.y >= extent.z:
		axis = 1
	elif extent.z > extent.x and extent.z >= extent.y:
		axis = 2
	if extent[axis] <= 0.0:

		return node
	var split := (clo[axis] + chi[axis]) * 0.5
	var mid := _partition(start, count, axis, split)
	if mid == start or mid == start + count:
		mid = start + count / 2

	var l := _build_node(start, mid - start, depth + 1)
	var r := _build_node(mid, start + count - mid, depth + 1)
	_left[node] = l
	_right[node] = r
	return node


func _partition(start: int, count: int, axis: int, split: float) -> int:
	var i := start
	var j := start + count - 1
	while i <= j:
		if _centroid[_order[i]][axis] < split:
			i += 1
		else:
			var swap := _order[i]
			_order[i] = _order[j]
			_order[j] = swap
			j -= 1
	return i
