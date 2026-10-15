@tool
class_name UBOpDuplicateFaces
extends RefCounted
## Copy the selected faces in place onto fresh vertices, shared within the
## duplicated set but not with the originals. Returns the new face set so the
## caller can select it for an immediate move.


static func apply(data, face_set: Dictionary) -> Dictionary:
	var new_faces := {}
	var vert_map := {}
	for fi in UBOpUtils.valid_faces(data, face_set):
		var face: UBFace = data.faces[fi]
		var copy: UBFace = face.duplicate_face()
		var verts := PackedInt32Array()
		for vi in face.vertices:
			if not vert_map.has(vi):
				vert_map[vi] = data.add_vertex(data.positions[vi])
			verts.append(vert_map[vi])
		copy.vertices = verts
		new_faces[data.faces.size()] = true
		data.faces.append(copy)
	return new_faces
