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

const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")

const DOOR_W := 1.05
const DOOR_H := 2.15
const JAMB := 0.07           # the frame's boards, across
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
const SIGN_GREEN := Color(0.04, 0.5, 0.22)
const SIGN_WHITE := Color(0.9, 1.0, 0.92)

var backing: Material        # set before _ready: the wall material of a slab to stand in (null: there is a wall)
var backing_h := 5.4
var pivot: Node3D
var open_amount := 0.0
var used := false

func _ready() -> void:
	var paint := StandardMaterial3D.new()          # frame and leaf: near-black green enamel
	paint.albedo_color = Color(0.035, 0.05, 0.04)
	paint.metallic = 0.3
	paint.roughness = 0.4
	var brass := StandardMaterial3D.new()
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

	# the leaf, hinged on its -Z edge and opening into the room, with a push bar and the running-man plate
	pivot = Node3D.new()
	pivot.position = Vector3(0.05, 0, -DOOR_W * 0.5)
	pivot.rotation.y = AJAR_ANGLE
	add_child(pivot)
	var leaf_h := DOOR_H - 0.012
	var face := LEAF_T * 0.5
	_box(Vector3(LEAF_T, leaf_h, DOOR_W - 0.01), Vector3(0, 0.006 + leaf_h * 0.5, DOOR_W * 0.5), paint, pivot)
	_box(Vector3(0.045, 0.06, DOOR_W * 0.8), Vector3(face + 0.055, BAR_H, DOOR_W * 0.5), brass, pivot)
	for s: float in [-1.0, 1.0]:
		_box(Vector3(0.055, 0.1, 0.09), Vector3(face + 0.0275, BAR_H, DOOR_W * 0.5 + s * (DOOR_W * 0.4 - 0.045)), brass, pivot)
	_plate(Vector2(0.4, 0.7), Vector3(face + 0.003, 1.62, DOOR_W * 0.5), _sign_material(_man_image(), 0.45), pivot)

	# the EXIT sign over the door, and the green it throws
	var sign_y := DOOR_H + 0.3
	_box(Vector3(0.06, 0.2, 0.66), Vector3(0.05, sign_y, 0), paint, self)
	_plate(Vector2(0.64, 0.18), Vector3(0.082, sign_y, 0), _sign_material(_exit_image(), 1.8), self)
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

# A flat sign facing +X
func _plate(size: Vector2, pos: Vector3, mat: Material, parent: Node3D) -> void:
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size
	mi.mesh = quad
	mi.position = pos
	mi.rotation.y = PI / 2.0
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

func _sign_material(img: Image, glow: float) -> StandardMaterial3D:
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.roughness = 0.6
	mat.emission_enabled = true
	mat.emission = Color.WHITE
	mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	mat.emission_texture = tex
	mat.emission_energy_multiplier = glow
	return mat

# ---------------------------------------------------------------- the signs, drawn here
const GLYPHS := {
	"E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
	"X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
	"I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
	"T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
}

## < EXIT >, white on green
func _exit_image() -> Image:
	var img := Image.create(256, 72, false, Image.FORMAT_RGBA8)
	img.fill(SIGN_GREEN)
	var px := 7                                   # one dot of a 5 x 7 letter
	var x0 := 44
	for ch: String in "EXIT":
		var rows: Array = GLYPHS[ch]
		for r in rows.size():
			for k in 5:
				if (rows[r] as String)[k] == "1":
					img.fill_rect(Rect2i(x0 + k * px, 11 + r * px, px, px), SIGN_WHITE)
		x0 += 5 * px + 9
	_tri(img, Vector2(10, 36), Vector2(30, 20), Vector2(30, 52), SIGN_WHITE)
	_tri(img, Vector2(246, 36), Vector2(226, 20), Vector2(226, 52), SIGN_WHITE)
	return img

## The running man making for a door, and an arrow down, white on green
func _man_image() -> Image:
	var img := Image.create(128, 224, false, Image.FORMAT_RGBA8)
	img.fill(SIGN_GREEN)
	img.fill_rect(Rect2i(12, 30, 36, 98), SIGN_WHITE)                          # the door
	_stroke(img, Vector2(90, 44), Vector2(90, 44), 9.0, SIGN_WHITE)            # head
	_stroke(img, Vector2(85, 60), Vector2(75, 92), 5.5, SIGN_WHITE)            # body
	_stroke(img, Vector2(83, 64), Vector2(64, 73), 4.0, SIGN_WHITE)            # arm ahead
	_stroke(img, Vector2(86, 64), Vector2(103, 78), 4.0, SIGN_WHITE)           # arm behind
	_stroke(img, Vector2(75, 92), Vector2(59, 104), 4.5, SIGN_WHITE)           # leg ahead
	_stroke(img, Vector2(59, 104), Vector2(55, 124), 4.5, SIGN_WHITE)
	_stroke(img, Vector2(75, 92), Vector2(89, 108), 4.5, SIGN_WHITE)           # leg behind
	_stroke(img, Vector2(89, 108), Vector2(107, 112), 4.5, SIGN_WHITE)
	img.fill_rect(Rect2i(59, 150, 10, 36), SIGN_WHITE)                         # the arrow
	_tri(img, Vector2(46, 185), Vector2(82, 185), Vector2(64, 206), SIGN_WHITE)
	return img

# A round-ended line `r` thick each side (a == b: a disc)
func _stroke(img: Image, a: Vector2, b: Vector2, r: float, col: Color) -> void:
	var lo := a.min(b) - Vector2(r, r)
	var hi := a.max(b) + Vector2(r, r)
	for y in range(maxi(int(lo.y), 0), mini(int(hi.y) + 1, img.get_height())):
		for x in range(maxi(int(lo.x), 0), mini(int(hi.x) + 1, img.get_width())):
			var p := Vector2(x + 0.5, y + 0.5)
			if p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) <= r:
				img.set_pixel(x, y, col)

func _tri(img: Image, a: Vector2, b: Vector2, c: Vector2, col: Color) -> void:
	var lo := a.min(b).min(c)
	var hi := a.max(b).max(c)
	for y in range(maxi(int(lo.y), 0), mini(int(hi.y) + 1, img.get_height())):
		for x in range(maxi(int(lo.x), 0), mini(int(hi.x) + 1, img.get_width())):
			if Geometry2D.point_is_inside_triangle(Vector2(x + 0.5, y + 0.5), a, b, c):
				img.set_pixel(x, y, col)
