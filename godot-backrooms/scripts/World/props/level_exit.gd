extends Node3D
## The level's exit: a fire door in a wall, standing ajar on the dark behind it, with a lit green EXIT sign
## over it and a running-man plate on the leaf. It swings wide as you walk up; walking into the doorway
## goes to the next level in the playlist (the last one wraps to the first).
## Papers / unlock are not ported yet, so it is always open.
##
## Built in local space against a wall whose face is the plane x = 0, the room on +X and the door spanning
## Z; level_builder.gd (_build_exit) finds the wall and turns the node to it. Nothing is cut in the wall:
## the doorway is a black panel on its face. With no wall near the exit cell, `backing` is set and the
## door stands in a slab of its own.
## Its textures (textures/props/exit/) are made by tools/generate_exit_textures.py.

const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")

const DOOR_W := 1.05
const DOOR_H := 2.15
const JAMB := 0.07           # the frame's boards, across
const CASING := 0.05         # the flange round them, flat on the wall
const CASING_D := 0.02
const FRAME_D := 0.08        # how far the frame stands off the wall
const LEAF_T := 0.045
const BAR_H := 1.0           # push bar
const AJAR_ANGLE := deg_to_rad(18.0)
const OPEN_ANGLE := deg_to_rad(84.0)
const OPEN_DIST := 3.2       # player this close and it swings wide
const SWING_TIME := 1.1
const TRIGGER_DEPTH := 0.8   # this far in front of the doorway, and within its width, and you are through
const SLAB_T := 0.3
const SLAB_W := 4.5          # a cell (level_data.gd CELL)
const TEX := "res://textures/props/exit/"
const BAR_MAT := "res://textures/pbr/Metal038/Metal038.tres"
const SIGN_GREEN := Color(0.04, 0.5, 0.22)      # a sign whose texture is missing

var backing: Material        # set before _ready: the wall material of a slab to stand in (null: there is a wall)
var backing_h := 5.4
var pivot: Node3D
var open_amount := 0.0
var used := false

func _ready() -> void:
	var paint := StandardMaterial3D.new()          # frame, sign housing and the leaf's edges: dark green enamel
	if ResourceLoader.exists(TEX + "exit_frame.png"):
		paint.albedo_texture = load(TEX + "exit_frame.png")
		paint.normal_enabled = true
		paint.normal_texture = load(TEX + "exit_frame_normal.png")
		paint.roughness_texture = load(TEX + "exit_frame_rough.png")
		paint.uv1_triplanar = true                 # the texture is a metre square
	else:
		paint.albedo_color = Color(0.13, 0.2, 0.16)
		paint.roughness = 0.45
	var leaf_mat := paint
	if ResourceLoader.exists(TEX + "exit_leaf.png"):
		leaf_mat = StandardMaterial3D.new()
		leaf_mat.albedo_texture = load(TEX + "exit_leaf.png")
		leaf_mat.normal_enabled = true
		leaf_mat.normal_texture = load(TEX + "exit_leaf_normal.png")
		leaf_mat.roughness_texture = load(TEX + "exit_leaf_rough.png")
		leaf_mat.metallic = 1.0
		leaf_mat.metallic_texture = load(TEX + "exit_leaf_metal.png")
	var brass: StandardMaterial3D
	if ResourceLoader.exists(BAR_MAT):
		brass = (load(BAR_MAT) as StandardMaterial3D).duplicate()
		brass.roughness = 0.35
	else:
		brass = StandardMaterial3D.new()
		brass.albedo_color = Color(0.72, 0.64, 0.4)
		brass.metallic = 0.6
		brass.roughness = 0.3
	var void_mat := StandardMaterial3D.new()
	void_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	void_mat.albedo_color = Color.BLACK

	if backing != null:
		var slab_size := Vector3(SLAB_T, backing_h, SLAB_W)
		var slab_pos := Vector3(-SLAB_T * 0.5, backing_h * 0.5, 0)
		_box(slab_size, slab_pos, backing, self)
		var body := StaticBody3D.new()
		add_child(body)
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = slab_size
		cs.shape = bs
		cs.position = slab_pos
		body.add_child(cs)

	# the dark in the doorway, and the frame round it
	_box(Vector3(0.01, DOOR_H, DOOR_W), Vector3(0.008, DOOR_H * 0.5, 0), void_mat, self)
	for s: float in [-1.0, 1.0]:
		_box(Vector3(FRAME_D, DOOR_H + JAMB, JAMB), Vector3(FRAME_D * 0.5, (DOOR_H + JAMB) * 0.5, s * (DOOR_W + JAMB) * 0.5), paint, self)
	_box(Vector3(FRAME_D, JAMB, DOOR_W), Vector3(FRAME_D * 0.5, DOOR_H + JAMB * 0.5, 0), paint, self)
	var casing_h := DOOR_H + JAMB + CASING
	for s: float in [-1.0, 1.0]:
		_box(Vector3(CASING_D, casing_h, CASING), Vector3(CASING_D * 0.5, casing_h * 0.5, s * (DOOR_W * 0.5 + JAMB + CASING * 0.5)), paint, self)
	_box(Vector3(CASING_D, CASING, DOOR_W + JAMB * 2.0), Vector3(CASING_D * 0.5, casing_h - CASING * 0.5, 0), paint, self)

	# the leaf, hinged on its -Z edge and opening into the room, with a push bar and the running-man plate
	pivot = Node3D.new()
	pivot.position = Vector3(0.05, 0, -DOOR_W * 0.5)
	pivot.rotation.y = AJAR_ANGLE
	add_child(pivot)
	var leaf_h := DOOR_H - 0.012
	var face := LEAF_T * 0.5
	var leaf_at := Vector3(0, 0.006 + leaf_h * 0.5, DOOR_W * 0.5)
	_box(Vector3(LEAF_T, leaf_h, DOOR_W - 0.01), leaf_at, paint, pivot)
	for f: float in [-1.0, 1.0]:                   # its two faces, skinned over the box
		_plate(Vector2(DOOR_W - 0.01, leaf_h), leaf_at + Vector3(f * (face + 0.001), 0, 0), leaf_mat, pivot, f)
	_box(Vector3(0.045, 0.06, DOOR_W * 0.8), Vector3(face + 0.055, BAR_H, DOOR_W * 0.5), brass, pivot)
	for s: float in [-1.0, 1.0]:
		_box(Vector3(0.055, 0.1, 0.09), Vector3(face + 0.0275, BAR_H, DOOR_W * 0.5 + s * (DOOR_W * 0.4 - 0.045)), brass, pivot)
	for hy: float in [0.25, DOOR_H * 0.5, DOOR_H - 0.25]:      # hinge barrels
		var hinge := MeshInstance3D.new()
		var barrel := CylinderMesh.new()
		barrel.top_radius = 0.012
		barrel.bottom_radius = 0.012
		barrel.height = 0.11
		hinge.mesh = barrel
		hinge.position = Vector3(face + 0.008, hy, -0.004)
		hinge.material_override = brass
		pivot.add_child(hinge)
	_plate(Vector2(0.4, 0.7), Vector3(face + 0.004, 1.62, DOOR_W * 0.5), _sign_material("exit_man.png", 0.3), pivot)

	# the EXIT sign over the door, and the green it throws
	var sign_y := DOOR_H + 0.3
	_box(Vector3(0.06, 0.2, 0.66), Vector3(0.05, sign_y, 0), paint, self)
	_plate(Vector2(0.64, 0.18), Vector3(0.082, sign_y, 0), _sign_material("exit_sign.png", 1.8), self)
	var light := OmniLight3D.new()
	light.light_color = Color(0.35, 1.0, 0.55)
	light.light_energy = 0.9
	light.omni_range = 6.0
	light.position = Vector3(0.6, sign_y - 0.1, 0)
	add_child(light)

func _process(delta: float) -> void:
	var player: Node3D = get_parent().player
	if player == null:
		return
	var local := to_local(player.global_position)
	var near := Vector2(local.x, local.z).length() < OPEN_DIST and local.x > 0.0
	open_amount = clampf(open_amount + (1.0 if near else -1.0) * delta / SWING_TIME, 0.0, 1.0)
	var eased := open_amount * open_amount * (3.0 - 2.0 * open_amount)
	pivot.rotation.y = lerpf(AJAR_ANGLE, OPEN_ANGLE, eased)
	if used or Game.dead or not Game.playing:
		return
	if local.x > 0.0 and local.x < TRIGGER_DEPTH and absf(local.z) < DOOR_W * 0.5 + 0.2:
		used = true
		# a taped trail all the way here documents the route (asra_clearance.gd file_route)
		Clearance.file_route(TapeMarks.mine_on(TapeMarks.MarkStore.key()), global_position)
		Game.next_level()

func _box(size: Vector3, pos: Vector3, mat: Material, parent: Node3D) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position = pos
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

# A flat panel facing +X (`facing` 1) or -X (-1)
func _plate(size: Vector2, pos: Vector3, mat: Material, parent: Node3D, facing := 1.0) -> void:
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size
	mi.mesh = quad
	mi.position = pos
	mi.rotation.y = facing * PI / 2.0
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

func _sign_material(file: String, glow: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.5
	mat.emission_enabled = true
	mat.emission_energy_multiplier = glow
	if ResourceLoader.exists(TEX + file):
		var tex: Texture2D = load(TEX + file)
		mat.albedo_texture = tex
		mat.emission = Color.WHITE
		mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		mat.emission_texture = tex
	else:
		mat.albedo_color = SIGN_GREEN
		mat.emission = SIGN_GREEN
	return mat
