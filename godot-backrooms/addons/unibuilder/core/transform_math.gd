@tool
class_name UBTransformMath
extends RefCounted
## Pure element-transform math for the rotate and scale gizmos. Applied to a
## snapshot of the positions each drag frame, so undo is a positions swap. All
## arguments are in the mesh's local space; the editor layer converts
## world-space gizmo results.


## Rotate the given vertices about pivot around axis by angle (radians).
static func rotate_positions(positions: PackedVector3Array, verts: Dictionary,
		pivot: Vector3, axis: Vector3, angle: float) -> PackedVector3Array:
	var out := positions.duplicate()
	if axis.length_squared() < 1e-12 or is_zero_approx(angle):
		return out
	var rot := Basis(axis.normalized(), angle)
	for vi in verts:
		if vi >= 0 and vi < out.size():
			out[vi] = pivot + rot * (out[vi] - pivot)
	return out


## Scale the given vertices about pivot by per-axis factors expressed in the
## `orientation` basis (identity = mesh-local axes; a normal-aligned basis
## makes factors.z scale along the face normal).
static func scale_positions(positions: PackedVector3Array, verts: Dictionary,
		pivot: Vector3, orientation: Basis, factors: Vector3) -> PackedVector3Array:
	var out := positions.duplicate()
	var inv := orientation.inverse()
	for vi in verts:
		if vi >= 0 and vi < out.size():
			var local := inv * (out[vi] - pivot)
			out[vi] = pivot + orientation * (local * factors)
	return out


## The free move `offset` adjusted so `ref + offset` lands on the grid, rather
## than the offset being a whole number of steps (which keeps an off-grid
## selection off the grid). The lattice is `origin + k * step` per world axis.
## `axis` Vector3.ZERO means a free (view-plane) move: every coordinate snaps.
## An axis move stays on its line: the axis's dominant world coordinate lands
## on a grid line, which for a tilted axis is the nearest crossing of the grid
## lines it runs across.
static func snap_offset_absolute(ref: Vector3, offset: Vector3, step: float,
		origin := Vector3.ZERO, axis := Vector3.ZERO) -> Vector3:
	if step <= 0.0:
		return offset
	if axis.length_squared() < 1e-12:
		return (ref + offset - origin).snapped(Vector3.ONE * step) + origin - ref
	var n := axis.normalized()
	var k := n.abs().max_axis_index()
	var target := snappedf(ref[k] + offset[k] - origin[k], step) + origin[k]
	return n * ((target - ref[k]) / n[k])


## `p` snapped to the nearest point of the lattice `origin + k * step` (every
## coordinate). Per-Element Snap's quantizer: the origin carries the grid
## plane's offset, so vertices land on the visible lines after Align Grid.
static func snap_point(p: Vector3, step: float, origin := Vector3.ZERO) -> Vector3:
	if step <= 0.0:
		return p
	return (p - origin).snapped(Vector3.ONE * step) + origin


## Low corner of the given vertices' bounds after `xf` (empty `verts` = every
## position), the reference point absolute snapping lands on the grid. A lone
## vertex is its own corner. Returns `fallback` when no vertex is in range.
static func bounds_min(positions: PackedVector3Array, verts: Dictionary,
		xf: Transform3D, fallback: Vector3) -> Vector3:
	var out := Vector3.INF
	var keys: Variant = verts.keys() if not verts.is_empty() else range(positions.size())
	for vi in keys:
		if vi is int and vi >= 0 and vi < positions.size():
			out = out.min(xf * positions[vi])
	return out if out.is_finite() else fallback


## Translate each vertex by `offset` scaled by its weight.
static func translate_weighted(positions: PackedVector3Array, weights: Dictionary,
		offset: Vector3) -> PackedVector3Array:
	var out := positions.duplicate()
	for vi in weights:
		if vi >= 0 and vi < out.size():
			out[vi] += offset * float(weights[vi])
	return out


## Rotate each vertex about pivot around axis by `angle` scaled by its weight,
## so soft neighbours sweep a fraction of the arc on their own circle.
static func rotate_weighted(positions: PackedVector3Array, weights: Dictionary,
		pivot: Vector3, axis: Vector3, angle: float) -> PackedVector3Array:
	var out := positions.duplicate()
	if axis.length_squared() < 1e-12 or is_zero_approx(angle):
		return out
	var n := axis.normalized()
	for vi in weights:
		if vi >= 0 and vi < out.size():
			out[vi] = pivot + Basis(n, angle * float(weights[vi])) * (out[vi] - pivot)
	return out


## Scale each vertex about pivot by factors blended toward 1 by its weight.
static func scale_weighted(positions: PackedVector3Array, weights: Dictionary,
		pivot: Vector3, orientation: Basis, factors: Vector3) -> PackedVector3Array:
	var out := positions.duplicate()
	var inv := orientation.inverse()
	for vi in weights:
		if vi >= 0 and vi < out.size():
			var f := Vector3.ONE.lerp(factors, float(weights[vi]))
			var local := inv * (out[vi] - pivot)
			out[vi] = pivot + orientation * (local * f)
	return out


## True when `basis` is a rotation (or reflection) times a uniform scale, so a
## local-space rotation about inverse(basis) * axis equals the world rotation.
static func is_conformal(basis: Basis, eps := 1e-5) -> bool:
	var lx := basis.x.length_squared()
	var ly := basis.y.length_squared()
	var lz := basis.z.length_squared()
	var m := maxf(lx, maxf(ly, lz))
	if m < 1e-24:
		return false
	return (
		absf(lx - ly) <= eps * m and absf(lx - lz) <= eps * m
		and absf(basis.x.dot(basis.y)) <= eps * m
		and absf(basis.x.dot(basis.z)) <= eps * m
		and absf(basis.y.dot(basis.z)) <= eps * m)


## The mesh-local linear map of a world rotation about `world_axis` by `angle`
## on a node whose basis is `basis`: inverse(B) * R * B.
static func local_rotation(basis: Basis, world_axis: Vector3, angle: float) -> Basis:
	return basis.inverse() * Basis(world_axis.normalized(), angle) * basis


## rotate_positions for a WORLD axis on a node with basis `basis`. Conformal
## bases take the local-axis path, so their results are exactly what
## rotate_positions always gave; other bases rotate by local_rotation, which
## keeps the motion a rigid world rotation instead of a shear.
static func rotate_positions_basis(positions: PackedVector3Array, verts: Dictionary,
		pivot: Vector3, world_axis: Vector3, angle: float, basis: Basis) -> PackedVector3Array:
	if world_axis.length_squared() < 1e-12 or is_zero_approx(angle):
		return positions.duplicate()
	if is_conformal(basis):
		return rotate_positions(positions, verts, pivot,
			(basis.inverse() * world_axis).normalized(), angle)
	var m := local_rotation(basis, world_axis, angle)
	var out := positions.duplicate()
	for vi in verts:
		if vi >= 0 and vi < out.size():
			out[vi] = pivot + m * (out[vi] - pivot)
	return out


## rotate_weighted for a WORLD axis on a node with basis `basis` (see
## rotate_positions_basis): each vertex turns by its weight's share of the
## angle, as a world rotation.
static func rotate_weighted_basis(positions: PackedVector3Array, weights: Dictionary,
		pivot: Vector3, world_axis: Vector3, angle: float, basis: Basis) -> PackedVector3Array:
	if world_axis.length_squared() < 1e-12 or is_zero_approx(angle):
		return positions.duplicate()
	if is_conformal(basis):
		return rotate_weighted(positions, weights, pivot,
			(basis.inverse() * world_axis).normalized(), angle)
	var out := positions.duplicate()
	var inv := basis.inverse()
	var n := world_axis.normalized()
	for vi in weights:
		if vi >= 0 and vi < out.size():
			out[vi] = pivot + (inv * Basis(n, angle * float(weights[vi])) * basis) * (out[vi] - pivot)
	return out
