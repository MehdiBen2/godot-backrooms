extends Node3D
## A door in a thin wall: the partition with a doorway cut in it, a painted gray frame (lining inside the
## opening, casing trim on both faces) and a hinged wood door (models/props/door/wood_door.glb). No interact
## [E] (player.gd) opens it away from you or shuts it. The leaf stays solid the whole time and stops
## against anyone in its way.
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
const OPEN_ANGLE := deg_to_rad(120.0)
const OPEN_TIME := 1.6       # latch, a short creak ajar, then the push
const CLOSE_TIME := 1.1
const CRACK := 0.06          # fractions of OPEN_ANGLE: where the latch lets it fall ajar...
const CREEP := 0.13          # ...and how far it creaks on its own before the push
const LEAF_MODEL := "res://models/props/door/wood_door.glb"

var pivot: Node3D
var leaf_body: AnimatableBody3D
var leaf_collision: CollisionShape3D
var frame_body: StaticBody3D
var _probe: BoxShape3D       # the leaf, a touch thicker: what the swing checks for bodies in its way
var angle := 0.0             # the leaf's swing, 0 shut .. OPEN_ANGLE
var open_amount := 0.0
var target_open_amount := 0.0
var blocked := false
var _from := 0.0
var _t := 0.0
var _opening := false
var _moving := false
var swing_dir := 1.0
var is_open := false

var audio_latch: AudioStreamPlayer3D
var audio_open: AudioStreamPlayer3D
var audio_close: AudioStreamPlayer3D

func _ready() -> void:
	add_to_group("doors")
	_setup_audio()

func _setup_audio() -> void:
	if audio_latch != null: return
	audio_latch = AudioStreamPlayer3D.new()
	if ResourceLoader.exists("res://audio/door_latch.wav"):
		audio_latch.stream = load("res://audio/door_latch.wav")
	audio_latch.bus = "World"
	audio_latch.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	audio_latch.unit_size = 2.0
	audio_latch.max_distance = 35.0
	audio_latch.position = Vector3(0, KNOB_H, DOOR_W * 0.5)
	add_child(audio_latch)

	audio_open = AudioStreamPlayer3D.new()
	if ResourceLoader.exists("res://audio/door_open.wav"):
		audio_open.stream = load("res://audio/door_open.wav")
	audio_open.bus = "World"
	audio_open.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	audio_open.unit_size = 2.2
	audio_open.max_distance = 40.0
	audio_open.position = Vector3(0, KNOB_H, DOOR_W * 0.5)
	add_child(audio_open)

	audio_close = AudioStreamPlayer3D.new()
	if ResourceLoader.exists("res://audio/door_close.wav"):
		audio_close.stream = load("res://audio/door_close.wav")
	audio_close.bus = "World"
	audio_close.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	audio_close.unit_size = 2.5
	audio_close.max_distance = 45.0
	audio_close.position = Vector3(0, KNOB_H, DOOR_W * 0.5)
	add_child(audio_close)

func build(cell: float, thick: float, wall_h: float, wall_mat: Material, frame_mat: Material, leaf_mat: Material, hw_mat: Material) -> void:
	add_to_group("doors")
	_setup_audio()
	var rw := DOOR_W + LINING * 2.0          # rough opening cut in the wall
	var rh := DOOR_H + LINING
	var side_w := (cell - rw) * 0.5
	var body := StaticBody3D.new()
	frame_body = body
	body.set_meta("door", self)
	body.add_to_group("doors")
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
	if not _model_leaf(leaf_size, leaf_pos):
		_plain_leaf(leaf_size, leaf_pos, leaf_mat, hw_mat)
	leaf_body = AnimatableBody3D.new()
	leaf_body.collision_layer = 1
	leaf_body.collision_mask = 1
	leaf_body.set_meta("door", self)
	leaf_body.add_to_group("doors")
	pivot.add_child(leaf_body)
	leaf_collision = CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = leaf_size
	leaf_collision.shape = bs
	leaf_collision.position = leaf_pos
	leaf_body.add_child(leaf_collision)
	_probe = BoxShape3D.new()
	_probe.size = leaf_size + Vector3(0.04, -0.04, -0.02)

# The leaf is wood_door.glb, which brings its own handle and hinges. In its own frame it stands X wide
# (hinges on -X, handle toward +X), Y tall from the floor, Z thick; here it is turned so its width runs
# along +Z from the hinge, and stretched to the leaf's width and height (its thickness follows the height,
# so the handle keeps its shape). False if the model isn't there (not imported yet).
func _model_leaf(leaf_size: Vector3, leaf_pos: Vector3) -> bool:
	if not ResourceLoader.exists(LEAF_MODEL):
		return false
	var packed := load(LEAF_MODEL) as PackedScene
	if packed == null:
		return false
	var model: Node3D = packed.instantiate()
	var box := AABB()
	var first := true
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != model:
			if p is Node3D:
				xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var b := xf * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first or box.size.x <= 0.0 or box.size.y <= 0.0:
		model.free()
		return false
	var sy := leaf_size.y / box.size.y
	var fit := Basis(Vector3.UP, -PI / 2.0) * Basis.from_scale(Vector3(leaf_size.z / box.size.x, sy, sy))
	model.transform = Transform3D(fit, leaf_pos - fit * box.get_center())
	pivot.add_child(model)
	return true

# The leaf built here instead (six-panel texture on a slab), with its knobs and hinges: what the door falls
# back to without the model.
func _plain_leaf(leaf_size: Vector3, leaf_pos: Vector3, leaf_mat: Material, hw_mat: Material) -> void:
	var leaf_mi := MeshInstance3D.new()
	leaf_mi.mesh = _build_leaf_mesh(leaf_size)
	leaf_mi.position = leaf_pos
	leaf_mi.material_override = leaf_mat
	pivot.add_child(leaf_mi)
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


func _physics_process(delta: float) -> void:
	if pivot == null or not _moving:
		return
	var t := minf(1.0, _t + delta / (OPEN_TIME if _opening else CLOSE_TIME))
	var a := _curve(t)
	# the leaf is solid the whole way. Shutting, it stops against anyone standing in the doorway and waits;
	# opening it swings away from you, so nothing holds it back
	if not _opening and _leaf_hits_body(a):
		blocked = true
		return
	blocked = false
	_t = t
	angle = a
	open_amount = angle / OPEN_ANGLE
	pivot.rotation.y = angle * swing_dir
	if _t >= 1.0:
		_moving = false
		if not _opening:
			_on_shut()

## The leaf's angle at progress t of the current move. Opening from shut: the latch gives and it cracks ajar,
## creaks a little further on its own while you hesitate, then your push swings it wide and the hinges slow
## it. Closing: it gathers speed into the frame.
func _curve(t: float) -> float:
	if not _opening:
		return lerpf(_from, 0.0, t * t)
	if _from > CRACK * OPEN_ANGLE:
		return lerpf(_from, OPEN_ANGLE, smoothstep(0.0, 1.0, t))
	var f: float
	if t < 0.1:
		f = CRACK * (1.0 - pow(1.0 - t / 0.1, 3.0))
	elif t < 0.32:
		f = lerpf(CRACK, CREEP, smoothstep(0.1, 0.32, t))
	else:
		f = lerpf(CREEP, 1.0, smoothstep(0.32, 1.0, t))
	return lerpf(_from, OPEN_ANGLE, f)

func _leaf_hits_body(a: float) -> bool:
	if not is_inside_tree() or leaf_body == null:
		return false
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _probe
	q.transform = global_transform * Transform3D(Basis(Vector3.UP, a * swing_dir), pivot.position) \
			* Transform3D(Basis.IDENTITY, leaf_collision.position)
	q.collision_mask = leaf_body.collision_mask
	q.exclude = [leaf_body.get_rid(), frame_body.get_rid()]
	for hit in get_world_3d().direct_space_state.intersect_shape(q, 8):
		if hit.collider is CharacterBody3D or hit.collider is RigidBody3D:
			return true
	return false

func _on_shut() -> void:
	if audio_close != null and is_inside_tree():
		audio_close.pitch_scale = randf_range(0.96, 1.04)
		audio_close.play()

func interact(player: Node3D) -> bool:
	var local := to_local(player.global_position) if player != null else Vector3.ZERO
	var will_open := target_open_amount < 0.5
	if will_open:
		# Swing away from whoever is opening it (only picked from shut: a half-open door keeps its side)
		if angle <= 0.001:
			swing_dir = -1.0 if local.x > 0.0 else 1.0
		target_open_amount = 1.0
		is_open = true
		if audio_latch != null and is_inside_tree():
			audio_latch.pitch_scale = randf_range(0.95, 1.05)
			audio_latch.play()
		if audio_open != null and is_inside_tree():
			audio_open.pitch_scale = randf_range(0.94, 1.06)
			audio_open.play()
	else:
		target_open_amount = 0.0
		is_open = false
		if audio_open != null and is_inside_tree():
			audio_open.pitch_scale = randf_range(0.88, 0.98)
			audio_open.play()
	_opening = will_open
	_from = angle
	_t = 0.0
	_moving = true
	blocked = false
	if player != null and player.has_method("trigger_door_camera_animation"):
		player.trigger_door_camera_animation(self, will_open, swing_dir)
	return true

func can_interact(from_pos: Vector3) -> bool:
	var handle_pos := get_handle_global_pos()
	var d1 := from_pos.distance_to(handle_pos)
	var d2 := from_pos.distance_to(global_position)
	return minf(d1, d2) < 2.8

func get_handle_global_pos() -> Vector3:
	if pivot != null:
		return pivot.to_global(Vector3(0, KNOB_H, DOOR_W * 0.9))
	return global_position + Vector3(0, KNOB_H, 0)

func get_interact_prompt() -> String:
	return "[E] CLOSE" if target_open_amount > 0.5 else "[E] OPEN"

