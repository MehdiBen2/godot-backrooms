extends Node3D
## A heavy spool / drum of industrial equipment cables, built in code for inventory icons and props.
## Lies flat or on its side, showing wound heavy rubber/industrial cable on a drum core.

const CableMarks := preload("res://scripts/World/props/cable_marks.gd")

const H := 0.22                  # height of spool drum
const R_OUT := 0.16              # outer flange radius
const R_CABLE := 0.135           # wound cable radius
const R_CORE := 0.055            # inner drum axle radius
const SEG := 24

static var _wood_mat: StandardMaterial3D
static var _metal_mat: StandardMaterial3D

func _init() -> void:
	var mesh := ArrayMesh.new()

	# 1. Wound heavy equipment cable on the drum (surface 0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var round_v := TAU * R_CABLE
	for i in SEG:
		var a0 := TAU * i / SEG
		var a1 := TAU * (i + 1) / SEG
		var n0 := Vector3(cos(a0), 0, sin(a0))
		var n1 := Vector3(cos(a1), 0, sin(a1))
		var p0 := n0 * R_CABLE + Vector3(0, 0.02, 0)
		var p1 := n0 * R_CABLE + Vector3(0, H - 0.02, 0)
		var p2 := n1 * R_CABLE + Vector3(0, H - 0.02, 0)
		var p3 := n1 * R_CABLE + Vector3(0, 0.02, 0)
		var nm := (n0 + n1).normalized()

		st.set_normal(nm)
		st.set_uv(Vector2(0, float(i)))
		st.add_vertex(p0)
		st.set_uv(Vector2(1, float(i)))
		st.add_vertex(p1)
		st.set_uv(Vector2(1, float(i + 1)))
		st.add_vertex(p2)

		st.set_uv(Vector2(0, float(i)))
		st.add_vertex(p0)
		st.set_uv(Vector2(1, float(i + 1)))
		st.add_vertex(p2)
		st.set_uv(Vector2(0, float(i + 1)))
		st.add_vertex(p3)

	# Tail of cable coming off the spool
	var t0 := Vector3(R_CABLE, 0.04, 0)
	var t1 := Vector3(R_CABLE + 0.15, 0.02, 0.18)
	var t_dir := (t1 - t0).normalized()
	var t_up := Vector3.UP
	var t_side := t_dir.cross(t_up).normalized() * 0.03
	st.set_normal(Vector3.UP)
	st.add_vertex(t0 - t_side)
	st.add_vertex(t0 + t_side)
	st.add_vertex(t1 + t_side)
	st.add_vertex(t0 - t_side)
	st.add_vertex(t1 + t_side)
	st.add_vertex(t1 - t_side)

	st.generate_tangents()
	st.commit(mesh)
	mesh.surface_set_material(0, CableMarks.get_material("heavy_black"))

	# 2. Outer flanges (top & bottom disks of the spool drum)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_disk(st, R_OUT, 0.0, Vector3.DOWN)
	_disk(st, R_OUT, 0.02, Vector3.UP)
	_disk(st, R_OUT, H - 0.02, Vector3.DOWN)
	_disk(st, R_OUT, H, Vector3.UP)
	st.commit(mesh)
	mesh.surface_set_material(1, flange_material())

	# 3. Metal center arbor / rim
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEG:
		var a0 := TAU * i / SEG
		var a1 := TAU * (i + 1) / SEG
		var n0 := Vector3(cos(a0), 0, sin(a0))
		var n1 := Vector3(cos(a1), 0, sin(a1))
		# Outer rim of bottom flange
		_quad(st, (n0 + n1).normalized(), n0 * R_OUT, n0 * R_OUT + Vector3(0, 0.02, 0),
			n1 * R_OUT + Vector3(0, 0.02, 0), n1 * R_OUT)
		# Outer rim of top flange
		_quad(st, (n0 + n1).normalized(), n0 * R_OUT + Vector3(0, H - 0.02, 0), n0 * R_OUT + Vector3(0, H, 0),
			n1 * R_OUT + Vector3(0, H, 0), n1 * R_OUT + Vector3(0, H - 0.02, 0))
	st.commit(mesh)
	mesh.surface_set_material(2, metal_material())

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)

func _disk(st: SurfaceTool, r: float, y: float, norm: Vector3) -> void:
	st.set_normal(norm)
	var center := Vector3(0, y, 0)
	for i in SEG:
		var a0 := TAU * i / SEG
		var a1 := TAU * (i + 1) / SEG
		var p0 := center + Vector3(cos(a0) * r, 0, sin(a0) * r)
		var p1 := center + Vector3(cos(a1) * r, 0, sin(a1) * r)
		if norm.y > 0:
			st.add_vertex(center)
			st.add_vertex(p0)
			st.add_vertex(p1)
		else:
			st.add_vertex(center)
			st.add_vertex(p1)
			st.add_vertex(p0)

func _quad(st: SurfaceTool, norm: Vector3, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	st.set_normal(norm)
	st.add_vertex(p0)
	st.add_vertex(p1)
	st.add_vertex(p2)
	st.add_vertex(p0)
	st.add_vertex(p2)
	st.add_vertex(p3)

static func flange_material() -> StandardMaterial3D:
	if _wood_mat == null:
		_wood_mat = StandardMaterial3D.new()
		_wood_mat.albedo_color = Color("4a3c2a")
		_wood_mat.roughness = 0.85
	return _wood_mat

static func metal_material() -> StandardMaterial3D:
	if _metal_mat == null:
		_metal_mat = StandardMaterial3D.new()
		_metal_mat.albedo_color = Color("2d2f33")
		_metal_mat.metallic = 0.8
		_metal_mat.roughness = 0.35
	return _metal_mat
