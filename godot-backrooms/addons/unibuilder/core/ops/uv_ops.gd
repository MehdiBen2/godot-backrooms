@tool
class_name UBOpUV
extends RefCounted
## Manual-UV operations for the UV editor. A corner key is
## Vector2i(face_index, corner_index). Every op is a pure mutation on UBMeshData
## and only touches faces in manual mode whose coords are parallel to the loop
## (bake_manual is how faces enter manual mode). The caller owns undo.


## Every corner of every face in the set, as corner keys.
static func corners_of(data, face_set: Dictionary) -> Dictionary:
	var out := {}
	for fi in UBOpUtils.valid_faces(data, face_set):
		for ci in data.faces[fi].vertices.size():
			out[Vector2i(fi, ci)] = true
	return out


## Convert faces to manual UVs by evaluating their current auto projection, so
## what you see is what you get. Pass the node's global transform so
## world-anchored faces bake the UVs they currently display. Faces already
## manual with valid coords are left alone.
static func bake_manual(data, face_set: Dictionary, world_transform := Transform3D.IDENTITY) -> void:
	for fi in UBOpUtils.valid_faces(data, face_set):
		var face: UBFace = data.faces[fi]
		if face.uv_manual and face.uv_coords.size() == face.vertices.size():
			continue
		var corners := PackedVector3Array()
		for vi in face.vertices:
			corners.append(data.positions[vi])
		face.uv_coords = UBUVUnwrap.face_uvs(
			corners, data.face_normal(face), face, world_transform)
		face.uv_manual = true


## Return faces to auto projection along their own normal, so uv_offset,
## uv_rotation and uv_scale apply again. Also clears a frozen projection axis
## (UBFace.uv_axis) so the face re-projects from its geometry.
static func clear_manual(data, face_set: Dictionary) -> void:
	for fi in UBOpUtils.valid_faces(data, face_set):
		var face: UBFace = data.faces[fi]
		face.uv_manual = false
		face.uv_coords = PackedVector2Array()
		face.uv_axis = Vector3.ZERO


## Apply an affine transform to the given corners' UVs.
static func transform_uvs(data, corner_set: Dictionary, xf: Transform2D) -> void:
	for key: Vector2i in _valid_corners(corner_set):
		var face := _manual_face(data, key.x)
		if face == null or key.y < 0 or key.y >= face.uv_coords.size():
			continue
		var coords := face.uv_coords
		coords[key.y] = xf * coords[key.y]
		face.uv_coords = coords


## Set corners' UVs outright. A drag-move passes original + delta, not an increment.
static func set_uvs(data, corner_uvs: Dictionary) -> void:
	for key: Vector2i in _valid_corners(corner_uvs):
		var face := _manual_face(data, key.x)
		if face == null or key.y < 0 or key.y >= face.uv_coords.size() \
				or not corner_uvs[key] is Vector2:
			continue
		var coords := face.uv_coords
		coords[key.y] = corner_uvs[key]
		face.uv_coords = coords


## Project the whole set as one island along its average normal (faces that
## share vertices stay contiguous), then optionally fit to 0-1. Makes the
## faces manual.
static func planar_project(data, face_set: Dictionary, fit := true) -> void:
	face_set = UBOpUtils.valid_faces(data, face_set)
	var normal := Vector3.ZERO
	for fi in face_set:
		normal += data.face_normal(data.faces[fi])
	if normal.length_squared() < 1e-10:
		normal = Vector3.UP
	normal = normal.normalized()
	var axis := Vector3.RIGHT if absf(normal.x) < 0.9 else Vector3.UP
	var u := (axis - normal * axis.dot(normal)).normalized()
	var w := normal.cross(u)
	for fi in face_set:
		var face: UBFace = data.faces[fi]
		var coords := PackedVector2Array()
		for vi in face.vertices:
			var p: Vector3 = data.positions[vi]
			coords.append(Vector2(p.dot(u), p.dot(w)))
		face.uv_coords = coords
		face.uv_manual = true
	if fit:
		fit_to_unit(data, face_set)


## Per-face dominant-axis projection: each face flattens without distortion
## and islands split where the orientation changes. Optionally fits the group
## to 0-1. Makes the faces manual.
static func box_project(data, face_set: Dictionary, fit := true) -> void:
	face_set = UBOpUtils.valid_faces(data, face_set)
	for fi in face_set:
		var face: UBFace = data.faces[fi]
		var frame: Array = UBUVUnwrap.projection_frame(data.face_normal(face))
		var coords := PackedVector2Array()
		for vi in face.vertices:
			var p: Vector3 = data.positions[vi]
			coords.append(Vector2(p.dot(frame[0]), p.dot(frame[1])))
		face.uv_coords = coords
		face.uv_manual = true
	if fit:
		fit_to_unit(data, face_set)


## Sew: corners in the set that share a 3D vertex move to their average UV,
## which stitches islands together at that seam.
static func weld_uvs(data, corner_set: Dictionary) -> void:
	var by_vertex := {}
	for key: Vector2i in _valid_corners(corner_set):
		var face := _manual_face(data, key.x)
		if face == null or key.y < 0 or key.y >= face.uv_coords.size():
			continue
		var vi: int = face.vertices[key.y]
		if not by_vertex.has(vi):
			by_vertex[vi] = []
		by_vertex[vi].append(key)
	for vi in by_vertex:
		var keys: Array = by_vertex[vi]
		if keys.size() < 2:
			continue
		var avg := Vector2.ZERO
		for key: Vector2i in keys:
			avg += data.faces[key.x].uv_coords[key.y]
		avg /= keys.size()
		for key: Vector2i in keys:
			var face: UBFace = data.faces[key.x]
			var coords := face.uv_coords
			coords[key.y] = avg
			face.uv_coords = coords


## Bounding rect of the set's manual UVs (Rect2() when the set has none).
static func uv_bounds(data, corner_set: Dictionary) -> Rect2:
	var has_any := false
	var rect := Rect2()
	for key: Vector2i in _valid_corners(corner_set):
		var face := _manual_face(data, key.x)
		if face == null or key.y < 0 or key.y >= face.uv_coords.size():
			continue
		var uv: Vector2 = face.uv_coords[key.y]
		if has_any:
			rect = rect.expand(uv)
		else:
			rect = Rect2(uv, Vector2.ZERO)
			has_any = true
	return rect


## Which extent fit_to_unit brings to exactly 1.
enum FitAxis { BOTH, U, V }


## Scale the set uniformly (aspect preserved) and move its minimum corner to
## the origin. BOTH makes the longest side 1, so the set lands inside the unit
## square. U or V makes that one extent 1 and lets the other run past it, so a
## wall fitted along V takes one texture height and tiles along its length.
static func fit_to_unit(data, face_set: Dictionary, axis: FitAxis = FitAxis.BOTH) -> void:
	var corner_set := corners_of(data, face_set)
	var rect := uv_bounds(data, corner_set)
	var extent := maxf(rect.size.x, rect.size.y)
	if axis == FitAxis.U:
		extent = rect.size.x
	elif axis == FitAxis.V:
		extent = rect.size.y
	var s := 1.0 / extent if extent > 1e-9 else 1.0
	transform_uvs(data, corner_set,
		Transform2D(0.0, Vector2(s, s), 0.0, -rect.position * s))


## The smallest translation that puts `rect` inside the unit square (the UV
## editor's 0-1 lock). An extent wider than 1 cannot fit, so on that axis the
## rect moves to COVER the square instead (min <= 0, max >= 1), the closest it
## can get.
static func unit_lock_offset(rect: Rect2) -> Vector2:
	return Vector2(
		_unit_lock_axis(rect.position.x, rect.end.x),
		_unit_lock_axis(rect.position.y, rect.end.y))


static func _unit_lock_axis(lo: float, hi: float) -> float:
	var a := -lo
	var b := 1.0 - hi
	return clampf(0.0, minf(a, b), maxf(a, b))


## Scale factors capped so an island of `size` stays within the unit square:
## no axis may grow past 1, or past its own current extent when it is already
## larger. Uniform scaling caps both factors together so the aspect survives;
## per-axis caps each on its own. Signs (mirroring) are kept.
static func unit_lock_factors(size: Vector2, factors: Vector2, uniform: bool) -> Vector2:
	var k := Vector2.ONE
	for a in 2:
		var grown := absf(size[a] * factors[a])
		var limit := maxf(1.0, size[a])
		if grown > limit and grown > 1e-12:
			k[a] = limit / grown
	if uniform:
		var m := minf(k.x, k.y)
		k = Vector2(m, m)
	return factors * k


## Faces in the same UV island as seed_face: floods across pairs of manual
## faces that share a 3D vertex whose corners carry the same UV (a sewn seam).
## Auto faces never join islands.
static func island_faces(data, seed_face: int, eps := 1e-5) -> Dictionary:
	if _manual_face(data, seed_face) == null:
		return {seed_face: true} if seed_face >= 0 and seed_face < data.faces.size() else {}

	var by_vertex := {}
	for fi in data.faces.size():
		var face := _manual_face(data, fi)
		if face == null:
			continue
		for ci in face.vertices.size():
			var vi: int = face.vertices[ci]
			if not by_vertex.has(vi):
				by_vertex[vi] = []
			by_vertex[vi].append([fi, face.uv_coords[ci]])
	var out := {seed_face: true}
	var queue: Array[int] = [seed_face]
	while not queue.is_empty():
		var fi: int = queue.pop_back()
		var face: UBFace = data.faces[fi]
		for ci in face.vertices.size():
			var uv: Vector2 = face.uv_coords[ci]
			for entry in by_vertex.get(face.vertices[ci], []):
				var nf: int = entry[0]
				if out.has(nf):
					continue
				if (entry[1] as Vector2).distance_to(uv) <= eps:
					out[nf] = true
					queue.append(nf)
	return out


## Copy one face's manual UVs onto every same-arity target face, verbatim by
## loop order. Rotation alignment is the artist's job. Returns the count applied.
static func copy_uvs(data, coords: PackedVector2Array, to_faces: Dictionary) -> int:
	var applied := 0
	for fi in UBOpUtils.valid_faces(data, to_faces):
		var face: UBFace = data.faces[fi]
		if face.vertices.size() != coords.size():
			continue
		face.uv_coords = coords.duplicate()
		face.uv_manual = true
		applied += 1
	return applied


## Area of a face (Newell magnitude) after `world_transform`, the node's
## global transform. Identity measures it in the mesh's own LOCAL units, which
## only equals world area on an unscaled node: under a non-uniform scale a
## face's area changes with its orientation, so islands facing different ways
## would normalize to different real densities.
static func face_world_area(data, fi: int, world_transform := Transform3D.IDENTITY) -> float:
	var pts := PackedVector3Array()
	for vi in data.faces[fi].vertices:
		pts.append(world_transform * data.positions[vi])
	return UBTriangulate.newell_normal(pts).length() * 0.5


## UV-space area of a manual face (shoelace).
static func face_uv_area(data, fi: int) -> float:
	var face := _manual_face(data, fi)
	if face == null:
		return 0.0
	var area := 0.0
	var coords := face.uv_coords
	for i in coords.size():
		area += coords[i].cross(coords[(i + 1) % coords.size()])
	return absf(area) * 0.5


## Texel-density normalize: scale every island touching face_set about its
## own UV centroid so its sqrt(uv_area / world_area) matches the reference
## face's. Faces must be manual (bake first). Pass the node's global transform
## so areas are measured in world units (see face_world_area).
static func texel_normalize(data, face_set: Dictionary, reference_face: int,
		world_transform := Transform3D.IDENTITY) -> void:
	if reference_face < 0 or reference_face >= data.faces.size():
		return
	face_set = UBOpUtils.valid_faces(data, face_set)
	var ref_world := face_world_area(data, reference_face, world_transform)
	var ref_uv := face_uv_area(data, reference_face)
	if ref_world <= 1e-12 or ref_uv <= 1e-12:
		return
	var ref_density := sqrt(ref_uv / ref_world)
	var done := {}
	for fi in face_set:
		if done.has(fi) or _manual_face(data, fi) == null:
			continue
		var island := island_faces(data, fi)
		var world := 0.0
		var uv := 0.0
		for isle_fi in island:
			done[isle_fi] = true
			world += face_world_area(data, isle_fi, world_transform)
			uv += face_uv_area(data, isle_fi)
		if world <= 1e-12 or uv <= 1e-12:
			continue
		var s := ref_density / sqrt(uv / world)
		if is_equal_approx(s, 1.0):
			continue
		var corners := corners_of(data, island)
		var pivot := uv_bounds(data, corners).get_center()
		transform_uvs(data, corners, Transform2D(0.0, pivot)
			* Transform2D(0.0, Vector2(s, s), 0.0, Vector2.ZERO)
			* Transform2D(0.0, -pivot))


## Auto faces re-project along their normal by themselves, so they need no
## coords refit. A deformation that also tilts the face would hand it a new
## plane, so a deformed and tilted auto face freezes its start normal as its
## projection axis (UBFace.uv_axis) and keeps projecting as it did before the
## drag. A rigid move does not freeze on its own; such a face only follows
## neighbours it was continuous with (see refit_drag_uvs). A face returned to
## its start pose gets its start axis back.

## Two start projection axes whose dot product is within this of 1 count as
## the same axis: the faces project alike and their texture is continuous.
const TILT_EPS := 1e-5

## A face counts as tilted once its corners' travel along the start normal
## differs between them by more than this times the coordinate scale.
## Positions are float32, so a rigid lift carries rounding well under it.
const PLANE_EPS := 1e-5

## A rigidly tilted face follows its neighbours' fixed axis only while its
## normal stays within 45 degrees of it (this is the dot product floor).
const FOLLOW_DOT := 0.70710678


## One entry per face touching any vertex in `verts`, built from `positions`
## (the drag's start positions), so call it before the first move. Manual
## faces with valid coords get {frame: UBUVFrame fitted from the current
## coords, uvs: start coords, dist: start pairwise corner distances}; faces
## the fit refuses are skipped and keep their coords. Auto faces get {normal:
## start outward normal, axis: start uv_axis, dist, lift: start corner heights
## along the normal, adj: see link_drag_patches}.
static func drag_uv_frames(data, verts: Dictionary, positions: PackedVector3Array) -> Dictionary:
	var out := {}
	for fi in data.faces.size():
		var face: UBFace = data.faces[fi]
		var touched := false
		for vi in face.vertices:
			if verts.has(vi):
				touched = true
				break
		if not touched:
			continue
		var corners := _corners_from(face, positions)

		var normal := -UBTriangulate.newell_normal(corners)
		if normal.length_squared() <= 0.0:
			continue
		if _manual_face(data, fi) == null:
			var unit := normal.normalized()
			out[fi] = {
				"normal": unit, "axis": face.uv_axis, "dist": _pair_distances(corners),
				"lift": _lifts(corners, unit),
			}
			continue
		var frame := UBUVFrame.fit(corners, face.uv_coords, normal)
		if frame == null:
			continue
		out[fi] = {"frame": frame, "uvs": face.uv_coords.duplicate(), "dist": _pair_distances(corners)}
	link_drag_patches(data, out)
	return out


## Give every auto entry its `adj`: the framed auto faces across a shared edge
## that project along the same axis at the start (frozen axis, else the start
## normal), which are the neighbours its texture is continuous with. A freeze
## spreads across those edges in refit_drag_uvs, so a face rotated rigidly
## inside a terrain does not tear along its rim.
static func link_drag_patches(data, frames: Dictionary) -> void:
	var by_edge := {}
	for fi in frames:
		var entry: Dictionary = frames[fi]
		if entry.has("frame"):
			continue
		entry["adj"] = []
		var loop: PackedInt32Array = data.faces[fi].vertices
		for i in loop.size():
			var a: int = loop[i]
			var b: int = loop[(i + 1) % loop.size()]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if not by_edge.has(key):
				by_edge[key] = []
			by_edge[key].append(fi)
	for key in by_edge:
		var sharing: Array = by_edge[key]
		for i in sharing.size():
			for j in range(i + 1, sharing.size()):
				var ea: Dictionary = frames[sharing[i]]
				var eb: Dictionary = frames[sharing[j]]
				if _start_axis(ea).dot(_start_axis(eb)) >= 1.0 - TILT_EPS:
					ea.adj.append(sharing[j])
					eb.adj.append(sharing[i])


static func _start_axis(entry: Dictionary) -> Vector3:
	var axis: Vector3 = entry.axis
	return axis.normalized() if axis != Vector3.ZERO else entry.normal


## Apply the frames against data.positions. Manual faces: deformed ones take
## the frame's UVs at their new corners, rigid ones take their start coords
## back. Auto faces: deformed and tilted ones freeze their start normal as the
## projection axis; every other case restores the start axis.
static func refit_drag_uvs(data, frames: Dictionary) -> void:

	var sources := []
	var rigid_tilted := {}
	for fi in frames:
		if fi < 0 or fi >= data.faces.size():
			continue
		var entry: Dictionary = frames[fi]
		var face: UBFace = data.faces[fi]
		var corners := _corners_from(face, data.positions)
		var rigid := _same_distances(_pair_distances(corners), entry.dist)
		if not entry.has("frame"):
			var axis: Vector3 = entry.axis
			if axis == Vector3.ZERO:
				if _tilted(entry, corners):
					if rigid:
						rigid_tilted[fi] = -UBTriangulate.newell_normal(corners).normalized()
					else:
						axis = entry.normal
			face.uv_axis = axis
			if axis != Vector3.ZERO:
				sources.append(fi)
			continue
		if _manual_face(data, fi) == null:
			continue
		if rigid:
			face.uv_coords = (entry.uvs as PackedVector2Array).duplicate()
			continue
		var frame: UBUVFrame = entry.frame
		var uvs := PackedVector2Array()
		uvs.resize(corners.size())
		for i in corners.size():
			uvs[i] = frame.uv_at(corners[i])
		face.uv_coords = uvs

	while not sources.is_empty() and not rigid_tilted.is_empty():
		var fi: int = sources.pop_back()
		for other in (frames[fi] as Dictionary).get("adj", []):
			if not rigid_tilted.has(other):
				continue
			var axis: Vector3 = data.faces[fi].uv_axis

			if (rigid_tilted[other] as Vector3).dot(axis.normalized()) < FOLLOW_DOT:
				continue
			rigid_tilted.erase(other)
			data.faces[other].uv_axis = axis
			sources.append(other)


## The framed faces' coords for the drag's undo entry: their start coords when
## `start` is true, else whatever they hold now. {face index:
## PackedVector2Array}, the shape UBMeshData.apply_uv_coords takes.
static func drag_uv_coords(data, frames: Dictionary, start: bool) -> Dictionary:
	var out := {}
	for fi in frames:
		var entry: Dictionary = frames[fi]
		if not entry.has("frame"):
			continue
		if start:
			out[fi] = (entry.uvs as PackedVector2Array).duplicate()
		else:
			var face := _manual_face(data, fi)
			if face != null:
				out[fi] = face.uv_coords.duplicate()
	return out


## The auto faces' frozen projection axes for the drag's undo entry: their
## start values when `start` is true, else whatever they hold now. {face
## index: Vector3}, the shape UBMeshData.apply_uv_axes takes. Only faces whose
## axis the drag changed are listed.
static func drag_uv_axes(data, frames: Dictionary, start: bool) -> Dictionary:
	var out := {}
	for fi in frames:
		var entry: Dictionary = frames[fi]
		if entry.has("frame") or fi < 0 or fi >= data.faces.size():
			continue
		var now: Vector3 = data.faces[fi].uv_axis
		if now == entry.axis:
			continue
		out[fi] = entry.axis if start else now
	return out


static func _lifts(corners: PackedVector3Array, normal: Vector3) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for p in corners:
		out.append(p.dot(normal))
	return out


static func _tilted(entry: Dictionary, corners: PackedVector3Array) -> bool:
	var start: PackedFloat64Array = entry.lift
	if start.size() != corners.size():
		return false
	var now := _lifts(corners, entry.normal)
	var low := INF
	var high := -INF
	var scale := 1.0
	for i in now.size():
		var travel := now[i] - start[i]
		low = minf(low, travel)
		high = maxf(high, travel)
		scale = maxf(scale, maxf(absf(corners[i].x), maxf(absf(corners[i].y), absf(corners[i].z))))
	return high - low > PLANE_EPS * scale


static func _corners_from(face: UBFace, positions: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for vi in face.vertices:
		out.append(positions[vi] if vi >= 0 and vi < positions.size() else Vector3.ZERO)
	return out


static func _pair_distances(corners: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in corners.size():
		for j in range(i + 1, corners.size()):
			out.append(corners[i].distance_to(corners[j]))
	return out


static func _same_distances(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if absf(a[i] - b[i]) > 1e-5 * maxf(1.0, b[i]):
			return false
	return true


static func _valid_corners(corner_set: Dictionary) -> Array:
	var out := []
	for key in corner_set:
		if key is Vector2i:
			out.append(key)
	return out


static func _manual_face(data, fi: int) -> UBFace:
	if fi < 0 or fi >= data.faces.size():
		return null
	var face: UBFace = data.faces[fi]
	if not face.uv_manual or face.uv_coords.size() != face.vertices.size():
		return null
	return face
