extends Node3D
## Another survivor: box figure (torso, head, swinging legs), a flashlight and a name tag,
## smoothed towards the last state received. Mirrors the web game's createRemotePlayer fallback.

const STAND_H := 1.7
const SMOOTH := 12.0

var color := Color("c9a44a")

var target_pos := Vector3.ZERO
var target_yaw := 0.0
var target_pitch := 0.0
var crouching := false
var torch_on := true
var dead := false
var seen := false

var body: Node3D
var leg_l: Node3D
var leg_r: Node3D
var head: MeshInstance3D
var light: SpotLight3D
var tag: Label3D
var _walk := 0.0
var _speed := 0.0
var _fall := 0.0

func _ready() -> void:
	body = Node3D.new()
	add_child(body)
	var jacket := StandardMaterial3D.new()
	jacket.albedo_color = color
	var trousers := StandardMaterial3D.new()
	trousers.albedo_color = Color("262a33")
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color("c09a7c")

	_box(body, Vector3(0.42, 0.62, 0.24), Vector3(0, 1.19, 0), jacket)
	head = _box(body, Vector3(0.22, 0.25, 0.22), Vector3(0, 1.64, 0), skin)
	_box(body, Vector3(0.12, 0.66, 0.13), Vector3(-0.28, 1.15, 0), jacket)
	_box(body, Vector3(0.12, 0.66, 0.13), Vector3(0.28, 1.15, 0), jacket)
	leg_l = _leg(Vector3(-0.1, 0.88, 0), trousers)
	leg_r = _leg(Vector3(0.1, 0.88, 0), trousers)

	light = SpotLight3D.new()
	light.position = Vector3(0.28, 1.4, -0.3)
	light.spot_range = 12.0
	light.spot_angle = 32.0
	light.light_energy = 2.5
	light.light_color = Color("fff0c8")
	body.add_child(light)

	tag = Label3D.new()
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.pixel_size = 0.004
	tag.font_size = 48
	tag.outline_size = 12
	tag.modulate = Color(0.94, 0.91, 0.75)
	tag.position = Vector3(0, 2.1, 0)
	tag.no_depth_test = true
	add_child(tag)
	visible = false          # until the first state arrives

func set_label(text: String) -> void:
	if tag:
		tag.text = text
	else:
		ready.connect(func(): tag.text = text, CONNECT_ONE_SHOT)

func apply_state(pos: Vector3, yaw: float, pitch: float, crouch: bool, torch: bool, is_dead: bool) -> void:
	target_pos = pos
	target_yaw = yaw
	target_pitch = pitch
	crouching = crouch
	torch_on = torch
	dead = is_dead
	if not seen:
		seen = true
		global_position = pos
		rotation.y = yaw
		visible = true

func _process(dt: float) -> void:
	if not seen:
		return
	var k := minf(1.0, dt * SMOOTH)
	var prev := global_position
	global_position = global_position.lerp(target_pos, k)
	rotation.y += wrapf(target_yaw - rotation.y, -PI, PI) * k

	var moved := Vector2(global_position.x - prev.x, global_position.z - prev.z).length()
	_speed += ((moved / dt if dt > 0.0 else 0.0) - _speed) * minf(1.0, dt * 10.0)
	var amp := minf(1.0, _speed / 2.4)
	_walk += _speed * dt * 3.4
	var swing := sin(_walk) * amp * 0.75
	leg_l.rotation.x = swing
	leg_r.rotation.x = -swing

	# a dead survivor topples onto their back; on respawn they snap upright
	_fall = minf(1.0, _fall + dt * (0.6 + _fall * 3.0)) if dead else maxf(0.0, _fall - dt * 4.0)
	body.rotation.x = _fall * _fall * -1.5
	var squash := 0.62 if crouching else 1.0
	body.scale.y = lerpf(body.scale.y, squash, k)
	head.rotation.x = target_pitch * 0.6
	light.rotation.x = target_pitch
	light.visible = torch_on and not dead
	tag.position.y = (2.1 * body.scale.y) if not dead else 0.8

func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	m.mesh = b
	m.material_override = mat
	m.position = pos
	parent.add_child(m)
	return m

# a leg pivots at the hip, the mesh hangs below it
func _leg(hip: Vector3, mat: Material) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = hip
	body.add_child(pivot)
	_box(pivot, Vector3(0.16, 0.85, 0.18), Vector3(0, -0.425, 0), mat)
	return pivot
