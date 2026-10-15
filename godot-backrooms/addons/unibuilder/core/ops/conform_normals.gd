@tool
class_name UBOpConformNormals
extends RefCounted
## Make windings consistent per connected component by flooding across shared
## edges; two faces agree when they traverse a shared edge in opposite
## directions. Within each component the majority orientation wins, so a
## mostly outward mesh has its strays flipped rather than the bulk.
## Non-manifold edges (3+ faces) are skipped as ambiguous.


static func apply(data) -> void:
	var topo := UBTopology.build(data)
	var visited := {}
	for seed in data.faces.size():
		if visited.has(seed):
			continue
		var component: Array[int] = [seed]
		var flip := {seed: false}
		visited[seed] = true
		var queue: Array[int] = [seed]
		while not queue.is_empty():
			var fi: int = queue.pop_back()
			var verts: PackedInt32Array = data.faces[fi].vertices
			for i in verts.size():
				var a := verts[i]
				var b := verts[(i + 1) % verts.size()]
				var key := UBSelectQueries.edge_key(a, b)
				var sharers: Array = topo.edge_faces.get(key, [])
				if sharers.size() != 2:
					continue
				for nf in sharers:
					if nf == fi or visited.has(nf):
						continue

					var same := _traverses_same_direction(data.faces[nf].vertices, a, b)
					flip[nf] = (not flip[fi]) if same else flip[fi]
					visited[nf] = true
					component.append(nf)
					queue.append(nf)
		var flips := 0
		for fi in component:
			if flip[fi]:
				flips += 1
		var invert := flips * 2 > component.size()
		for fi in component:
			if flip[fi] != invert:
				UBOpUtils.reverse_face_loop(data.faces[fi])


static func _traverses_same_direction(verts: PackedInt32Array, a: int, b: int) -> bool:
	for i in verts.size():
		if verts[i] == a and verts[(i + 1) % verts.size()] == b:
			return true
	return false
