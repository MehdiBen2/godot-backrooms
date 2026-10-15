@tool
class_name UBOpSplitVertices
extends RefCounted
## Un-share the selected vertices: every face touching a selected vertex gets
## its own coincident copy (the first face keeps the original). The faces can
## then be pulled apart; weld reverses this.


static func apply(data, vert_set: Dictionary) -> void:
	var topo := UBTopology.build(data)
	for v in UBOpUtils.valid_vertices(data, vert_set):
		var touching: Array = topo.vertex_faces[v]
		for k in range(1, touching.size()):
			var fi: int = touching[k]
			var copy: int = data.add_vertex(data.positions[v])
			var verts: PackedInt32Array = data.faces[fi].vertices
			for i in verts.size():
				if verts[i] == v:
					verts[i] = copy
			data.faces[fi].vertices = verts
