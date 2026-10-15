@tool
class_name UBUVFrame
extends RefCounted
## The affine map between a face's plane and its UV space, fitted from the
## face's own corners: uv(p) = uv0 + du * l.x + dv * l.y, where l is p's offset
## from the corner mean in an orthonormal in-plane basis (t, b). Every UV map a
## face can carry is affine in position, so the fit reproduces it exactly;
## hand-edited coords get the best affine approximation. The frame also holds
## the inverse, so dir_u/dir_v give the direction in space each UV axis runs.
## Space-agnostic: corners may be local or world, and `normal` must match.

var origin := Vector3.ZERO  ## corner mean
var normal := Vector3.UP
var t := Vector3.RIGHT  ## in-plane basis, orthonormal
var b := Vector3.DOWN
var uv0 := Vector2.ZERO  ## UV at the corner mean
var du := Vector2.ZERO  ## d(uv) per unit of l.x
var dv := Vector2.ZERO  ## d(uv) per unit of l.y
var _inv := Transform2D.IDENTITY  ## UV offset -> l offset


## Fit from parallel corner positions and UVs. Returns null when the corners
## cannot condition the fit (fewer than 3, mismatched arity, collinear) or the
## UV map has no extent (every corner on one UV line), since a singular map
## has no +U direction to draw or drag along.
static func fit(corners: PackedVector3Array, uvs: PackedVector2Array, face_normal: Vector3) -> UBUVFrame:
	var n := corners.size()
	if n < 3 or uvs.size() != n:
		return null
	var basis := UBUVUnwrap.projection_frame(face_normal)
	var f := UBUVFrame.new()
	f.normal = face_normal.normalized()
	f.t = basis[0]
	f.b = basis[1]
	var mean := Vector3.ZERO
	var mean_uv := Vector2.ZERO
	for i in n:
		mean += corners[i]
		mean_uv += uvs[i]
	f.origin = mean / n
	f.uv0 = mean_uv / n
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	var sxu := Vector2.ZERO
	var syu := Vector2.ZERO
	for i in n:
		var l := f._local(corners[i])
		var duv := uvs[i] - f.uv0
		sxx += l.x * l.x
		sxy += l.x * l.y
		syy += l.y * l.y
		sxu += duv * l.x
		syu += duv * l.y
	var det := sxx * syy - sxy * sxy
	var span := sxx + syy

	if span < 1e-18 or det < 1e-9 * span * span:
		return null
	f.du = (sxu * syy - syu * sxy) / det
	f.dv = (syu * sxx - sxu * sxy) / det

	var fwd := Transform2D(f.du, f.dv, Vector2.ZERO)
	var fdet := absf(fwd.determinant())
	if fdet <= 1e-12 or fdet < 1e-9 * (f.du.length_squared() + f.dv.length_squared()):
		return null
	f._inv = fwd.affine_inverse()
	return f


func _local(p: Vector3) -> Vector2:
	var d := p - origin
	return Vector2(d.dot(t), d.dot(b))


## The UV the face's map assigns at a position (on or near the plane; the
## out-of-plane component is ignored).
func uv_at(p: Vector3) -> Vector2:
	var l := _local(p)
	return uv0 + du * l.x + dv * l.y


## The point on the plane that carries the given UV.
func point_at(uv: Vector2) -> Vector3:
	var l := _inv.basis_xform(uv - uv0)
	return origin + t * l.x + b * l.y


## Unit direction in space along which U increases with V held constant.
func dir_u() -> Vector3:
	var l := _inv.basis_xform(Vector2.RIGHT)
	return (t * l.x + b * l.y).normalized()


## Unit direction in space along which V increases with U held constant.
func dir_v() -> Vector3:
	var l := _inv.basis_xform(Vector2.DOWN)
	return (t * l.x + b * l.y).normalized()


func plane() -> Plane:
	return Plane(normal, origin)
