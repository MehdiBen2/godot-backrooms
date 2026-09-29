extends Node3D
## The camera flash as a 3D model, built in code from primitive meshes: an old hammerhead flash
## unit, a black battery grip with a tilted reflector head on top, its frosted window facing +Z,
## the red ready lamp and the test button on the back, and a strip of hazard tape round the grip
## where some agent marked it as T.S.R.A. kit. Stands upright, about 15 cm tall. Made in _init so
## its size is known before it enters the tree; item_icon.gd renders the inventory icon from it and
## the floor pickup (flash_pickup.gd) lies it down (hud.gd passes this script's path as the model).

const TAPE_TEXTURE := "res://textures/items/hazard_tapes/hazardous_tapes.jpg"

const GRIP := Vector3(0.042, 0.1, 0.034)       # the battery grip (m)
const HEAD := Vector3(0.078, 0.046, 0.05)      # the reflector head across the top of it

static var _mats := {}

func _init() -> void:
	var body := _mat("body", Color(0.07, 0.07, 0.075), 0.1, 0.55)
	var trim := _mat("trim", Color(0.55, 0.56, 0.58), 0.8, 0.3)
	var lens := _mat("lens", Color(0.92, 0.94, 0.97), 0.0, 0.15, Color(0.25, 0.27, 0.3))
	var red := _mat("red", Color(0.9, 0.1, 0.06), 0.0, 0.3, Color(0.8, 0.08, 0.03))

	# the grip, with a silver foot where it would slide into a camera's shoe
	_box(GRIP, Vector3(0, GRIP.y * 0.5, 0), body)
	_box(Vector3(GRIP.x * 0.8, 0.006, GRIP.z * 0.8), Vector3(0, 0.003, 0), trim)
	# hazard tape wrapped round the middle of the grip
	_box(Vector3(GRIP.x + 0.002, 0.014, GRIP.z + 0.002), Vector3(0, GRIP.y * 0.45, 0), _tape_mat())
	# the head, tipped back a little like a bounce flash, on a silver collar
	var head := Node3D.new()
	head.position = Vector3(0, GRIP.y + HEAD.y * 0.5 + 0.004, 0.004)
	head.rotation.x = -0.12
	add_child(head)
	_box(Vector3(GRIP.x * 0.9, 0.008, GRIP.z * 0.9), Vector3(0, GRIP.y + 0.002, 0), trim)
	_box(HEAD, Vector3.ZERO, body, head)
	# the window: a silver rim, then the frosted face over the tube
	_box(Vector3(HEAD.x - 0.004, HEAD.y - 0.004, 0.004), Vector3(0, 0, HEAD.z * 0.5 + 0.001), trim, head)
	_box(Vector3(HEAD.x - 0.012, HEAD.y - 0.012, 0.003), Vector3(0, 0, HEAD.z * 0.5 + 0.003), lens, head)
	# the back: the ready lamp and the test button
	_box(Vector3(0.008, 0.008, 0.004), Vector3(-0.012, 0.004, -HEAD.z * 0.5 - 0.001), red, head)
	_box(Vector3(0.012, 0.007, 0.005), Vector3(0.012, 0.004, -HEAD.z * 0.5 - 0.001), trim, head)

func _box(size: Vector3, pos: Vector3, mat: Material, parent: Node = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi

static func _mat(key: String, col: Color, metal: float, rough: float, glow := Color.BLACK) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.metallic = metal
		m.roughness = rough
		if glow != Color.BLACK:
			m.emission_enabled = true
			m.emission = glow
		_mats[key] = m
	return _mats[key]

static func _tape_mat() -> StandardMaterial3D:
	if not _mats.has("tape"):
		var m := StandardMaterial3D.new()
		m.albedo_texture = load(TAPE_TEXTURE)
		m.uv1_scale = Vector3(3.0, 0.5, 1.0)
		m.roughness = 0.5
		_mats["tape"] = m
	return _mats["tape"]
