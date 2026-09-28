extends Node3D
## Every strip of reflective hazard tape stuck on this level's walls and floors (tape_tool.gd lays
## them). The strips are kept per level in a static list, so they are still there after a respawn
## or a trip to another level and back: the whole point is to find your own marks again when the
## corridors loop. In co-op each strip goes to the others as well (Net.send_tape) and theirs come
## in through receive().
##
## A strip is a flat quad a few millimetres off the surface, WIDTH across, with the tape texture
## repeating along it; the chevrons point from where you started pulling to where you let go.
## The look (glossy vinyl, retroreflective under the torch) is shaders/reflective_tape.gdshader.
## Built by level_builder.gd.

const WIDTH := 0.075                 # m: a standard 75 mm roll
const LIFT := 0.004                  # m off the surface
const LIFT_STEP := 0.0007            # each later strip sits a hair higher, so crossings don't z-fight
const MAX_PER_LEVEL := 240           # the oldest strip comes off past this
const TEXTURE := "res://textures/items/hazard_tapes/hazardous_tapes.jpg"
const TEX_ASPECT := 998.0 / 561.0    # the texture's height over its width: one repeat is this many widths
const SHADER := preload("res://shaders/reflective_tape.gdshader")

static var placed := {}              # level index -> Array of [a, b, n] (Vector3s)
static var mine: Array = []          # [level, a, b, n] of the strips laid on this PC (resent to newcomers)
static var live = null               # the TapeMarks of the level loaded right now
static var _mat: ShaderMaterial

var strips: Array[MeshInstance3D] = []

func _ready() -> void:
	live = self
	for s in placed.get(Game.level_index, []):
		_spawn(s[0], s[1], s[2])

func _exit_tree() -> void:
	if live == self:
		live = null

## Lay a strip from `a` to `b` on the surface with normal `n` (called by tape_tool.gd on release)
func place(a: Vector3, b: Vector3, n: Vector3) -> void:
	_store(Game.level_index, a, b, n)
	mine.append([Game.level_index, a, b, n])
	if mine.size() > MAX_PER_LEVEL * 4:
		mine.pop_front()
	_spawn(a, b, n)
	Net.send_tape([[Game.level_index, a, b, n]])

## A strip from another survivor (Net._tape_rpc): kept for its level, drawn if that's this one
static func receive(level: int, a: Vector3, b: Vector3, n: Vector3) -> void:
	_store(level, a, b, n)
	if live != null and is_instance_valid(live) and level == Game.level_index:
		live._spawn(a, b, n)

static func _store(level: int, a: Vector3, b: Vector3, n: Vector3) -> void:
	if not placed.has(level):
		placed[level] = []
	var list: Array = placed[level]
	list.append([a, b, n])
	if list.size() > MAX_PER_LEVEL:
		list.pop_front()

func _spawn(a: Vector3, b: Vector3, n: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = strip_mesh(a - global_position, b - global_position, n, LIFT + LIFT_STEP * (strips.size() % 8))
	mi.material_override = material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	strips.append(mi)
	if strips.size() > MAX_PER_LEVEL:
		strips.pop_front().queue_free()

## The shared tape material (strips, the one being pulled, the roll's outside)
static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		_mat.set_shader_parameter("albedo_tex", load(TEXTURE))
	return _mat

## A flat strip `a` -> `b` lying on a surface facing `n`, `lift` off it. Into `mesh` if given
## (the strip being pulled reuses its mesh every frame), else a new one.
static func strip_mesh(a: Vector3, b: Vector3, n: Vector3, lift: float, mesh: ArrayMesh = null) -> ArrayMesh:
	if mesh == null:
		mesh = ArrayMesh.new()
	mesh.clear_surfaces()
	var along := b - a
	var length := along.length()
	if length < 0.001:
		return mesh
	var dir := along / length
	var side := n.cross(dir).normalized() * WIDTH * 0.5
	var up := n * lift
	var v_end := length / (WIDTH * TEX_ASPECT)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	quad(st, n,
		[a - side + up, a + side + up, b + side + up, b - side + up],
		[Vector2(0, 0), Vector2(1, 0), Vector2(1, v_end), Vector2(0, v_end)])
	st.commit(mesh)
	return mesh

## Two triangles facing `n` (Godot's front faces wind clockwise; the order is fixed up here so
## callers can list the corners either way round). `normals`: one per corner for a curved face.
static func quad(st: SurfaceTool, n: Vector3, p: Array, uv: Array, normals: Array = []) -> void:
	for t in [[0, 1, 2], [0, 2, 3]]:
		var i: Array = t
		if (p[i[1]] - p[i[0]]).cross(p[i[2]] - p[i[0]]).dot(n) > 0.0:
			i = [i[0], i[2], i[1]]
		for k in i:
			st.set_normal(normals[k] if normals.size() == 4 else n)
			st.set_uv(uv[k])
			st.add_vertex(p[k])
