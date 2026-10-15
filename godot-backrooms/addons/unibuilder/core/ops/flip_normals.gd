@tool
class_name UBOpFlipNormals
extends RefCounted
## Reverse the winding (and therefore the normal) of the given faces.
## An empty set flips every face.


static func apply(data, face_set: Dictionary) -> void:
	var targets: Array = (
		UBOpUtils.valid_faces(data, face_set).keys() if not face_set.is_empty()
		else range(data.faces.size())
	)
	for fi in targets:
		UBOpUtils.reverse_face_loop(data.faces[fi])
