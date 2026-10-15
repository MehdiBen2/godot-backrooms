@tool
class_name UBOpDeleteFaces
extends RefCounted
## Delete a set of faces and compact away any vertices that become unused.
## Face indices after the op no longer match pre-op indices, so callers must
## clear face and edge selections.


static func apply(data, face_set: Dictionary) -> void:
	if face_set.is_empty():
		return
	var keep: Array[UBFace] = []
	for fi in data.faces.size():
		if not face_set.has(fi):
			keep.append(data.faces[fi])
	data.faces = keep
	UBOpUtils.remove_unused_vertices(data)
