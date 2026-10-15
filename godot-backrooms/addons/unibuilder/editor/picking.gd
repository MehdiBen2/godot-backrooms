@tool
class_name UBPicking
extends RefCounted
## Screen-space element picking and marquee tests against UBMeshData. Rays
## run against our own face data, not physics, so picking works without
## collision shapes. Positions are tested in the node's local space.

const VERTEX_PX := 12.0
const EDGE_PX := 9.0
const T_EPS := 1e-3

const NO_EDGE := Vector2i(-1, -1)


## Nearest face hit under the cursor, or -1.
static func pick_face(node, camera: Camera3D, screen_pos: Vector2) -> int:
	var data = node.mesh_data
	var ray := _local_ray(node, camera, screen_pos)
	return UBRayAccel.build_cached(data).nearest(ray[0], ray[1])[0]


## Nearest face hit under the cursor plus the local-space hit point:
## [face_index, Vector3]. face_index is -1 on a miss.
static func pick_face_point(node, camera: Camera3D, screen_pos: Vector2) -> Array:
	var data = node.mesh_data
	var ray := _local_ray(node, camera, screen_pos)
	var hit: Array = UBRayAccel.build_cached(data).nearest(ray[0], ray[1])
	if hit[0] < 0:
		return [-1, Vector3.ZERO]
	return [hit[0], ray[0] + ray[1] * hit[1]]


## Vertex within max_px of the cursor; prefers the screen-nearest candidate.
static func pick_vertex(node, camera: Camera3D, screen_pos: Vector2, visible_only := true, max_px := VERTEX_PX) -> int:
	var data = node.mesh_data
	var best := -1
	var best_d := max_px
	for vi in data.positions.size():
		var wp: Vector3 = node.global_transform * data.positions[vi]
		if camera.is_position_behind(wp):
			continue
		var d := camera.unproject_position(wp).distance_to(screen_pos)
		if d >= best_d:
			continue
		if visible_only and _occluded(data, node, camera, data.positions[vi]):
			continue
		best = vi
		best_d = d
	return best


## Edge whose projected segment passes within max_px of the cursor, or NO_EDGE.
static func pick_edge(node, camera: Camera3D, screen_pos: Vector2, visible_only := true, max_px := EDGE_PX) -> Vector2i:
	var data = node.mesh_data

	var topo := UBTopology.build_cached(data)
	var best := NO_EDGE
	var best_d := max_px
	for key: Vector2i in topo.edge_faces:
		var d := _edge_screen_distance(node, camera, data, key, screen_pos)
		if d >= best_d:
			continue
		var mid: Vector3 = (data.positions[key.x] + data.positions[key.y]) * 0.5
		if visible_only and _occluded(data, node, camera, mid):
			continue
		best = key
		best_d = d
	return best


## Among the edges of one face, the one nearest the cursor (for face loops).
static func nearest_face_edge(node, camera: Camera3D, face_index: int, screen_pos: Vector2) -> Vector2i:
	var data = node.mesh_data
	var best := NO_EDGE
	var best_d := INF
	for key in UBSelectQueries.face_edges(data.faces[face_index]):
		var d := _edge_screen_distance(node, camera, data, key, screen_pos)
		if d < best_d:
			best_d = d
			best = key
	return best


static func marquee_vertices(node, camera: Camera3D, rect: Rect2, select_through: bool) -> Array:
	var data = node.mesh_data
	var out := []
	for vi in data.positions.size():
		var wp: Vector3 = node.global_transform * data.positions[vi]
		if camera.is_position_behind(wp):
			continue
		if not rect.has_point(camera.unproject_position(wp)):
			continue
		if not select_through and _occluded(data, node, camera, data.positions[vi]):
			continue
		out.append(vi)
	return out


## An edge is inside the marquee when both endpoints are.
static func marquee_edges(node, camera: Camera3D, rect: Rect2, select_through: bool) -> Array:
	var data = node.mesh_data

	var topo := UBTopology.build_cached(data)
	var out := []
	for key: Vector2i in topo.edge_faces:
		var wa: Vector3 = node.global_transform * data.positions[key.x]
		var wb: Vector3 = node.global_transform * data.positions[key.y]
		if camera.is_position_behind(wa) or camera.is_position_behind(wb):
			continue
		if not (rect.has_point(camera.unproject_position(wa)) and rect.has_point(camera.unproject_position(wb))):
			continue
		if not select_through and _occluded(data, node, camera, (data.positions[key.x] + data.positions[key.y]) * 0.5):
			continue
		out.append(key)
	return out


## A face is inside the marquee when its center is, so partially covered
## faces count.
static func marquee_faces(node, camera: Camera3D, rect: Rect2, select_through: bool) -> Array:
	var data = node.mesh_data
	var out := []
	for fi in data.faces.size():
		var center: Vector3 = data.face_center(data.faces[fi])
		var wc: Vector3 = node.global_transform * center
		if camera.is_position_behind(wc):
			continue
		if not rect.has_point(camera.unproject_position(wc)):
			continue
		if not select_through and _occluded(data, node, camera, center):
			continue
		out.append(fi)
	return out


static func _local_ray(node, camera: Camera3D, screen_pos: Vector2) -> Array:
	var inv: Transform3D = node.global_transform.affine_inverse()
	var origin := inv * camera.project_ray_origin(screen_pos)
	var dir := (inv.basis * camera.project_ray_normal(screen_pos)).normalized()
	return [origin, dir]


static func _occluded(data, node, camera: Camera3D, local_point: Vector3) -> bool:
	var wp: Vector3 = node.global_transform * local_point
	if camera.is_position_behind(wp):
		return true
	var sp := camera.unproject_position(wp)
	var inv: Transform3D = node.global_transform.affine_inverse()
	var origin := inv * camera.project_ray_origin(sp)
	var dir := (inv.basis * camera.project_ray_normal(sp)).normalized()
	var t_point := (local_point - origin).dot(dir)
	var limit := t_point - maxf(T_EPS, t_point * T_EPS)
	return UBRayAccel.build_cached(data).occluded_before(origin, dir, limit)


static func _edge_screen_distance(node, camera: Camera3D, data, key: Vector2i, screen_pos: Vector2) -> float:
	var wa: Vector3 = node.global_transform * data.positions[key.x]
	var wb: Vector3 = node.global_transform * data.positions[key.y]
	if camera.is_position_behind(wa) or camera.is_position_behind(wb):
		return INF
	var sa := camera.unproject_position(wa)
	var sb := camera.unproject_position(wb)
	return Geometry2D.get_closest_point_to_segment(screen_pos, sa, sb).distance_to(screen_pos)
