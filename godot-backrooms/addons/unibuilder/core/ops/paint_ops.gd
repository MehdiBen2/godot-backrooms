@tool
class_name UBOpPaint
extends RefCounted
## Vertex-paint ops. Colors live per corner (UBFace.color_corners, parallel to the
## loop); faces enter per-corner mode lazily, seeded from their face color. The
## channel mask keeps color-coding and alpha blend-masking apart: MASK_RGB writes
## color and preserves each corner's alpha exactly, MASK_A the reverse.

enum { MASK_RGBA, MASK_RGB, MASK_A }


## Paints every corner of every face in the set.
static func paint_faces(data, face_set: Dictionary, color: Color, mask := MASK_RGBA) -> void:
	for fi in UBOpUtils.valid_faces(data, face_set):
		var face: UBFace = data.faces[fi]
		var colors := _corner_colors(face)
		for ci in colors.size():
			colors[ci] = _blend(colors[ci], color, mask)
		face.color_corners = colors


## Inverts the alpha of every face in the set, swapping a painted blend mask's two
## layers. Per-corner faces invert each corner; a uniform face inverts its face
## color without minting corners. RGB is untouched.
static func invert_alpha(data, face_set: Dictionary) -> void:
	for fi in UBOpUtils.valid_faces(data, face_set):
		var face: UBFace = data.faces[fi]
		if face.color_corners.size() == face.vertices.size():
			var colors := face.color_corners.duplicate()
			for ci in colors.size():
				var c: Color = colors[ci]
				colors[ci] = Color(c.r, c.g, c.b, 1.0 - c.a)
			face.color_corners = colors
		else:
			face.color = Color(face.color.r, face.color.g, face.color.b, 1.0 - face.color.a)


## Per-vertex brush weights for a dab at `hit_world`. Every vertex within `radius`
## (world units) gets `strength` scaled by the falloff: full inside
## (1-softness)*radius, smoothstepped to 0 at the rim. Softness 0 is a hard circle,
## 1 falls off from the center. Distances are measured in world space, so scaled
## nodes keep a scene-true brush size.
static func brush_weights(
	data, world_transform: Transform3D, hit_world: Vector3,
	radius: float, strength: float, softness: float
) -> Dictionary:
	var weights := {}
	if radius <= 0.0 or strength <= 0.0:
		return weights
	var hard_t := 1.0 - clampf(softness, 0.0, 1.0)
	for vi in data.positions.size():
		var world: Vector3 = world_transform * data.positions[vi]
		var t := world.distance_to(hit_world) / radius
		if t >= 1.0:
			continue
		var w := strength if t <= hard_t else strength * (1.0 - smoothstep(hard_t, 1.0, t))
		if w > 0.0:
			weights[vi] = w
	return weights


## Brush dab: blends every corner of a weighted vertex toward `color` by its weight,
## reading base colors from `base` (the stroke-start snapshot, topology-parallel to
## `data`). Re-applying accumulated weights never compounds; pass the stroke's peak
## weight per vertex.
static func paint_weighted(data, base, weights: Dictionary, color: Color, mask := MASK_RGBA) -> void:
	for fi in data.faces.size():
		var face: UBFace = data.faces[fi]
		var verts: PackedInt32Array = face.vertices
		var touched := false
		for ci in verts.size():
			if weights.has(verts[ci]):
				touched = true
				break
		if not touched:
			continue
		var colors := _corner_colors(face)
		for ci in verts.size():
			var w: float = weights.get(verts[ci], 0.0)
			if w <= 0.0:
				continue
			var base_color := sample(base, fi, ci)
			colors[ci] = base_color.lerp(_blend(base_color, color, mask), w)
		face.color_corners = colors


## The color under one corner (eyedropper).
static func sample(data, fi: int, ci: int) -> Color:
	if fi < 0 or fi >= data.faces.size():
		return Color.WHITE
	var face: UBFace = data.faces[fi]
	if face.color_corners.size() == face.vertices.size() and ci >= 0 and ci < face.color_corners.size():
		return face.color_corners[ci]
	return face.color


## Index of the point nearest `click`, or -1 when `points` is empty. The eyedropper
## uses it on a face's screen-projected loop to pick the corner under the cursor.
static func nearest_corner(points: PackedVector2Array, click: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in points.size():
		var d := points[i].distance_squared_to(click)
		if d < best_d:
			best_d = d
			best = i
	return best


static func _corner_colors(face: UBFace) -> PackedColorArray:
	if face.color_corners.size() == face.vertices.size():
		return face.color_corners.duplicate()
	var colors := PackedColorArray()
	colors.resize(face.vertices.size())
	colors.fill(face.color)
	return colors


static func _blend(old: Color, paint: Color, mask: int) -> Color:
	match mask:
		MASK_RGB:
			return Color(paint.r, paint.g, paint.b, old.a)
		MASK_A:
			return Color(old.r, old.g, old.b, paint.a)
	return paint
