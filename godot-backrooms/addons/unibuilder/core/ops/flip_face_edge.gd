@tool
class_name UBOpFlipFaceEdge
extends RefCounted
## Rotate each selected face's vertex loop by one. The polygon is unchanged,
## but ear-clipping triangulation is seeded by loop order, so on a non-planar
## quad this rotates the internal diagonal; apply twice to get the original
## back. Parallel per-corner arrays rotate too, so manual UVs stay attached
## to their corners.


static func apply(data, face_set: Dictionary) -> void:
	for fi in UBOpUtils.valid_faces(data, face_set):
		var face: UBFace = data.faces[fi]
		var n := face.vertices.size()
		if n < 4:
			continue
		var verts := PackedInt32Array()
		for i in n:
			verts.append(face.vertices[(i + 1) % n])
		face.vertices = verts
		if face.uv_manual and face.uv_coords.size() == n:
			var coords := PackedVector2Array()
			for i in n:
				coords.append(face.uv_coords[(i + 1) % n])
			face.uv_coords = coords
		if face.color_corners.size() == n:
			var colors := PackedColorArray()
			for i in n:
				colors.append(face.color_corners[(i + 1) % n])
			face.color_corners = colors
