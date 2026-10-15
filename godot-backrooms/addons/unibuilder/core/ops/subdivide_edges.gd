@tool
class_name UBOpSubdivideEdges
extends RefCounted
## Split every selected edge into `segments` equal parts (segments-1 points
## inserted). All faces sharing a split edge get the points inserted into
## their loop in traversal order, so topology stays consistent.


static func apply(data, edge_set: Dictionary, segments := 2) -> void:
	segments = maxi(2, segments)

	edge_set = UBOpUtils.valid_edges(UBTopology.build(data), edge_set)
	var points := {}
	for e: Vector2i in edge_set:
		if e.x >= 0 and e.x < data.positions.size() and e.y >= 0 and e.y < data.positions.size():
			var list := PackedInt32Array()
			for s in range(1, segments):
				list.append(data.add_vertex(
					data.positions[e.x].lerp(data.positions[e.y], float(s) / float(segments))))
			points[e] = list
	if not points.is_empty():
		UBOpUtils.insert_edge_points(data, points)
