extends Node3D
## A roll of reflective hazard tape, built in code: the wound tape (the same glossy reflective
## material as the strips on the walls), its edges, the cardboard core and a loose end curling
## off it. Lies flat, axis up, resting on y = 0. Made in _init so its size is known before it
## enters the tree: the floor pickup (tape_pickup.gd) and the inventory icon (item_icon.gd,
## which takes this script's path as the item's model) both use it.

const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")

const H := TapeMarks.WIDTH           # the roll is as tall as the tape is wide
const R_OUT := 0.11                  # outside of the wound tape (a fat roll: 250 m on it)
const R_CORE := 0.06                 # where the tape meets the cardboard
const R_IN := 0.052                  # the hole
const SEG := 32
const TAIL := 0.14                   # the loose end peeling off, m

static var _edge_mat: StandardMaterial3D
static var _core_mat: StandardMaterial3D

func _init() -> void:
	var mesh := ArrayMesh.new()
	# outside: the tape itself, wrapped round, chevrons running round the roll
	var st := _begin()
	var round_v := TAU * R_OUT / (H * TapeMarks.TEX_ASPECT)
	for i in SEG:
		var a0 := TAU * i / SEG
		var a1 := TAU * (i + 1) / SEG
		var n0 := Vector3(cos(a0), 0, sin(a0))
		var n1 := Vector3(cos(a1), 0, sin(a1))
		var v0 := round_v * i / SEG
		var v1 := round_v * (i + 1) / SEG
		TapeMarks.quad(st, (n0 + n1).normalized(),
			[n0 * R_OUT, n0 * R_OUT + Vector3(0, H, 0), n1 * R_OUT + Vector3(0, H, 0), n1 * R_OUT],
			[Vector2(0, v0), Vector2(1, v0), Vector2(1, v1), Vector2(0, v1)], [n0, n0, n1, n1])
	# the loose end: a short ribbon carrying on along the tangent, bowing out a little
	var t0 := Vector3(R_OUT, 0, 0)
	var t1 := Vector3(R_OUT + 0.024, 0, TAIL)
	TapeMarks.quad(st, Vector3(1, 0, -0.17).normalized(),
		[t0, t0 + Vector3(0, H, 0), t1 + Vector3(0, H, 0), t1],
		[Vector2(0, 0), Vector2(1, 0), Vector2(1, TAIL / (H * TapeMarks.TEX_ASPECT)), Vector2(0, TAIL / (H * TapeMarks.TEX_ASPECT))])
	st.commit(mesh)
	mesh.surface_set_material(0, TapeMarks.material())
	# the two faces of the wound tape: layer on layer of it seen edge-on
	st = _begin()
	_ring(st, R_CORE, R_OUT, 0.0, Vector3.DOWN)
	_ring(st, R_CORE, R_OUT, H, Vector3.UP)
	st.commit(mesh)
	mesh.surface_set_material(1, edge_material())
	# cardboard core: its two rims and the inside of the hole
	st = _begin()
	_ring(st, R_IN, R_CORE, 0.001, Vector3.DOWN)
	_ring(st, R_IN, R_CORE, H - 0.001, Vector3.UP)
	for i in SEG:
		var a0 := TAU * i / SEG
		var a1 := TAU * (i + 1) / SEG
		var n0 := -Vector3(cos(a0), 0, sin(a0))
		var n1 := -Vector3(cos(a1), 0, sin(a1))
		TapeMarks.quad(st, (n0 + n1).normalized(),
			[-n0 * R_IN, -n0 * R_IN + Vector3(0, H, 0), -n1 * R_IN + Vector3(0, H, 0), -n1 * R_IN],
			[Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO], [n0, n0, n1, n1])
	st.commit(mesh)
	mesh.surface_set_material(2, core_material())
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.visibility_range_end = 45.0
	mi.visibility_range_end_margin = 8.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mi)

static func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st

## A flat annulus from r0 to r1 at height y, facing n (up or down)
static func _ring(st: SurfaceTool, r0: float, r1: float, y: float, n: Vector3) -> void:
	for i in SEG:
		var a0 := TAU * i / SEG
		var a1 := TAU * (i + 1) / SEG
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var up := Vector3(0, y, 0)
		TapeMarks.quad(st, n,
			[d0 * r0 + up, d0 * r1 + up, d1 * r1 + up, d1 * r0 + up],
			[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])

static func edge_material() -> StandardMaterial3D:
	if _edge_mat == null:
		_edge_mat = StandardMaterial3D.new()
		_edge_mat.albedo_color = Color(0.42, 0.33, 0.04)     # yellow and black layers blurred together
		_edge_mat.roughness = 0.3
		_edge_mat.clearcoat_enabled = true
		_edge_mat.clearcoat = 0.6
		_edge_mat.clearcoat_roughness = 0.2
	return _edge_mat

static func core_material() -> StandardMaterial3D:
	if _core_mat == null:
		_core_mat = StandardMaterial3D.new()
		_core_mat.albedo_color = Color(0.52, 0.4, 0.26)       # brown cardboard
		_core_mat.roughness = 0.95
	return _core_mat
