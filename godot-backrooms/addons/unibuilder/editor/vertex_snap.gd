@tool
class_name UBVertexSnap
extends RefCounted
## Vertex snapping (hold V during a move drag): the selection translates rigidly so
## its anchor vertex (the dragged vertex nearest the cursor at drag start) lands on
## the candidate vertex nearest the cursor. Candidates are the edited mesh's unmoved
## vertices plus every other UBMeshInstance3D's vertices, all in world space. The
## statics take the screen projection as a Callable, so they run without a camera.

## Cursor-to-target screen distance that arms a snap, in pixels.
const SNAP_PX := 22.0


## World-space candidates from one mesh: every vertex not in `exclude` (the dragged
## set), transformed by `xf`.
static func collect_targets(data, xf: Transform3D, exclude: Dictionary) -> PackedVector3Array:
	return collect_positions(data.positions, xf, exclude)


## collect_targets over a bare positions array (a drag's START positions, when
## the live mesh has already moved).
static func collect_positions(positions: PackedVector3Array, xf: Transform3D,
		exclude: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	for vi in positions.size():
		if not exclude.has(vi):
			out.append(xf * positions[vi])
	return out


## Appends every vertex of every UBMeshInstance3D under `root` except `skip` (the
## node being dragged), in world space.
static func collect_scene_targets(root: Node, skip: Node, out: PackedVector3Array) -> void:
	if root is UBMeshInstance3D and root != skip and root.mesh_data != null:
		var xf: Transform3D = root.global_transform
		for p in root.mesh_data.positions:
			out.append(xf * p)
	for child in root.get_children():
		collect_scene_targets(child, skip, out)


## Index of the target whose screen projection is nearest `cursor` within `max_px`,
## or -1. `project` maps a world point to a screen Vector2, or null for points that
## cannot snap (behind the camera).
static func nearest_target(
	targets: PackedVector3Array, project: Callable, cursor: Vector2, max_px: float
) -> int:
	var best := -1
	var best_d := max_px
	for i in targets.size():
		var sp: Variant = project.call(targets[i])
		if sp == null:
			continue
		var d: float = (sp as Vector2).distance_to(cursor)
		if d < best_d:
			best_d = d
			best = i
	return best
