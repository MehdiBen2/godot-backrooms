extends Node3D
## A door in a thin wall: the partition with a doorway cut in it, a painted gray frame (lining inside the
## opening, casing trim on both faces), a hinged wood door and a metal knob on each side. No interact
## key, like the level's other props: it swings open away from you as you walk up and eases shut
## once you've gone.
##
## Built in local space with the passage along X and the wall spanning Z; level_geometry.gd rotates
## the node to match the corridor.

const DOOR_W := 1.05         # clear opening inside the frame
const DOOR_H := 2.15
const LINING := 0.035        # frame boards lining the opening
const CASING_W := 0.09       # trim around the opening on each face
const CASING_D := 0.025
const LEAF_T := 0.045
const KNOB_H := 0.95
const OPEN_ANGLE := deg_to_rad(95.0)
const OPEN_DIST := 1.7       # player this close to the doorway (either side) and it opens
const CLOSE_DIST := 2.4
const SWING_TIME := 0.9

var pivot: Node3D
var leaf_collision: CollisionShape3D
var open_amount := 0.0
var swing_dir := 1.0

func build(cell: float, thick: float, wall_h: float, wall_mat: Material, frame_mat: Material, leaf_mat: Material, hw_mat: Material) -> void:
	var rw := DOOR_W + LINING * 2.0          # rough opening cut in the wall
	var rh := DOOR_H + LINING
	var side_w := (cell - rw) * 0.5
	var body := StaticBody3D.new()
	add_child(body)
	# the wall around the opening (leaving the doorway clear as a baked portal)
	for s: float in [-1.0, 1.0]:
		var side_size := Vector3(thick, wall_h, side_w)
		var side_pos := Vector3(0, wall_h * 0.5, s * (rw + side_w) * 0.5)
		_solid(body, side_size, side_pos, wall_mat)
		var oi := OccluderInstance3D.new()
		var bo := BoxOccluder3D.new()
		bo.size = side_size
		oi.occluder = bo
		oi.position = side_pos
		add_child(oi)
	if wall_h > rh:
		var top_size := Vector3(thick, wall_h - rh, rw)
		var top_pos := Vector3(0, rh + (wall_h - rh) * 0.5, 0)
		_solid(body, top_size, top_pos, wall_mat)
		var oi_top := OccluderInstance3D.new()
		var bo_top := BoxOccluder3D.new()
		bo_top.size = top_size
		oi_top.occluder = bo_top
		oi_top.position = top_pos
		add_child(oi_top)
	# frame: lining boards inside the opening...
	for s: float in [-1.0, 1.0]:
		_box(Vector3(thick + 0.01, rh, LINING), Vector3(0, rh * 0.5, s * (DOOR_W + LINING) * 0.5), frame_mat, self)
	_box(Vector3(thick + 0.01, LINING, rw), Vector3(0, DOOR_H + LINING * 0.5, 0), frame_mat, self)
	# ...and casing trim around it on both faces
	for f: float in [-1.0, 1.0]:
		var x := f * (thick + CASING_D) * 0.5
		for s: float in [-1.0, 1.0]:
			_box(Vector3(CASING_D, DOOR_H + CASING_W, CASING_W), Vector3(x, (DOOR_H + CASING_W) * 0.5, s * (DOOR_W + CASING_W) * 0.5), frame_mat, self)
		_box(Vector3(CASING_D, CASING_W, DOOR_W + CASING_W * 2.0), Vector3(x, DOOR_H + CASING_W * 0.5, 0), frame_mat, self)

	# the door, hinged on its -Z edge
	pivot = Node3D.new()
	pivot.position = Vector3(0, 0, -DOOR_W * 0.5)
	add_child(pivot)
	var leaf_size := Vector3(LEAF_T, DOOR_H - 0.012, DOOR_W - 0.01)
	var leaf_pos := Vector3(0, 0.006 + leaf_size.y * 0.5, DOOR_W * 0.5)
	var leaf_mi := MeshInstance3D.new()
	leaf_mi.mesh = _build_leaf_mesh(leaf_size)
	leaf_mi.position = leaf_pos
	leaf_mi.material_override = leaf_mat
	pivot.add_child(leaf_mi)
	var leaf_body := AnimatableBody3D.new()
	pivot.add_child(leaf_body)
	leaf_collision = CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = leaf_size
	leaf_collision.shape = bs
	leaf_collision.position = leaf_pos
	leaf_body.add_child(leaf_collision)
	# a knob on each face, near the free edge: round rose, short neck, ball
	for f: float in [-1.0, 1.0]:
		var face := f * LEAF_T * 0.5
		var z := DOOR_W - 0.075
		_cyl(0.032, 0.012, Vector3(face + f * 0.006, KNOB_H, z), hw_mat)
		_cyl(0.011, 0.045, Vector3(face + f * 0.03, KNOB_H, z), hw_mat)
		var ball := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = 0.03
		sph.height = 0.055
		ball.mesh = sph
		ball.position = Vector3(face + f * 0.062, KNOB_H, z)
		ball.material_override = hw_mat
		pivot.add_child(ball)
	# hinge barrels on the frame side
	for hy: float in [0.25, DOOR_H * 0.5, DOOR_H - 0.25]:
		var hinge := MeshInstance3D.new()
		var hc := CylinderMesh.new()
		hc.top_radius = 0.012
		hc.bottom_radius = 0.012
		hc.height = 0.1
		hinge.mesh = hc
		hinge.position = Vector3(LEAF_T * 0.5, hy, -DOOR_W * 0.5)
		hinge.material_override = hw_mat
		add_child(hinge)

func _box(size: Vector3, pos: Vector3, mat: Material, parent: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi

func _solid(body: StaticBody3D, size: Vector3, pos: Vector3, mat: Material) -> void:
	_box(size, pos, mat, self)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	body.add_child(cs)

# A short cylinder lying along X (the knob parts stick straight out of the door's face)
func _cyl(radius: float, length: float, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = length
	mi.mesh = cm
	mi.rotation.z = PI / 2.0
	mi.position = pos
	mi.material_override = mat
	pivot.add_child(mi)

static func _build_leaf_mesh(size: Vector3) -> ArrayMesh:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var add_quad = func(n: Vector3, p: Array, uvs: Array) -> void:
		st.set_normal(n)
		st.set_uv(uvs[0]); st.add_vertex(p[0])
		st.set_uv(uvs[1]); st.add_vertex(p[1])
		st.set_uv(uvs[2]); st.add_vertex(p[2])

		st.set_uv(uvs[0]); st.add_vertex(p[0])
		st.set_uv(uvs[2]); st.add_vertex(p[2])
		st.set_uv(uvs[3]); st.add_vertex(p[3])

	# Front face (+X)
	add_quad.call(Vector3(1, 0, 0), [
		Vector3(hx, hy, -hz), Vector3(hx, hy, hz),
		Vector3(hx, -hy, hz), Vector3(hx, -hy, -hz)
	], [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])

	# Back face (-X)
	add_quad.call(Vector3(-1, 0, 0), [
		Vector3(-hx, hy, hz), Vector3(-hx, hy, -hz),
		Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz)
	], [Vector2(1, 0), Vector2(0, 0), Vector2(0, 1), Vector2(1, 1)])

	# Hinge edge (-Z)
	add_quad.call(Vector3(0, 0, -1), [
		Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz),
		Vector3(hx, -hy, -hz), Vector3(-hx, -hy, -hz)
	], [Vector2(0.01, 0), Vector2(0.04, 0), Vector2(0.04, 1), Vector2(0.01, 1)])

	# Latch edge (+Z)
	add_quad.call(Vector3(0, 0, 1), [
		Vector3(hx, hy, hz), Vector3(-hx, hy, hz),
		Vector3(-hx, -hy, hz), Vector3(hx, -hy, hz)
	], [Vector2(0.96, 0), Vector2(0.99, 0), Vector2(0.99, 1), Vector2(0.96, 1)])

	# Top edge (+Y)
	add_quad.call(Vector3(0, 1, 0), [
		Vector3(-hx, hy, -hz), Vector3(-hx, hy, hz),
		Vector3(hx, hy, hz), Vector3(hx, hy, -hz)
	], [Vector2(0, 0.01), Vector2(1, 0.01), Vector2(1, 0.04), Vector2(0, 0.04)])

	# Bottom edge (-Y)
	add_quad.call(Vector3(0, -1, 0), [
		Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz),
		Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz)
	], [Vector2(0, 0.99), Vector2(0, 0.96), Vector2(1, 0.96), Vector2(1, 0.99)])

	st.generate_tangents()
	return st.commit()


func _process(delta: float) -> void:
	var lvl := get_parent()
	var player: Node3D = lvl.player if lvl != null else null
	var want_open := false
	if player != null:
		var local := to_local(player.global_position)
		var reach := OPEN_DIST if open_amount < 0.5 else CLOSE_DIST
		want_open = Vector2(local.x, local.z).length() < reach
		if want_open and open_amount <= 0.0:
			swing_dir = -1.0 if local.x > 0.0 else 1.0     # swing away from whoever is opening it
	open_amount = clampf(open_amount + (1.0 if want_open else -1.0) * delta / SWING_TIME, 0.0, 1.0)
	var eased := open_amount * open_amount * (3.0 - 2.0 * open_amount)
	pivot.rotation.y = eased * OPEN_ANGLE * swing_dir
	if leaf_collision != null:
		leaf_collision.disabled = open_amount > 0.1
