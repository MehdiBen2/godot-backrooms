@tool
class_name UBOpTriangulateFaces
extends RefCounted
## Replace each selected n-gon with its ear-clipping triangles, the same ones
## the compiler would emit. Properties carry over per triangle, and parallel
## manual UVs are re-indexed through the triangulation so they stay attached.
## Faces that are already triangles pass through untouched.


static func apply(data, face_set: Dictionary) -> void:
	var out: Array[UBFace] = []
	for fi in data.faces.size():
		var face: UBFace = data.faces[fi]
		if not face_set.has(fi) or face.vertices.size() <= 3:
			out.append(face)
			continue
		var corners := PackedVector3Array()
		for vi in face.vertices:
			corners.append(data.positions[vi])
		var tris := UBTriangulate.triangulate(corners)
		if tris.is_empty():
			out.append(face)
			continue
		var manual := face.uv_manual and face.uv_coords.size() == face.vertices.size()
		var painted := face.color_corners.size() == face.vertices.size()
		for t in range(0, tris.size(), 3):
			var tf: UBFace = face.duplicate_face()
			tf.vertices = PackedInt32Array([
				face.vertices[tris[t]], face.vertices[tris[t + 1]], face.vertices[tris[t + 2]]])
			if manual:
				tf.uv_coords = PackedVector2Array([
					face.uv_coords[tris[t]], face.uv_coords[tris[t + 1]], face.uv_coords[tris[t + 2]]])

			if painted:
				tf.color_corners = PackedColorArray([
					face.color_corners[tris[t]], face.color_corners[tris[t + 1]],
					face.color_corners[tris[t + 2]]])
			out.append(tf)
	data.faces.clear()
	for f in out:
		data.faces.append(f)
