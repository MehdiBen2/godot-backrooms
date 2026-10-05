extends RefCounted
## The ceiling lights of the rooms behind a shaft's walls (pit_fall.gd `_hall`, `_corridor`): the level's own troffer
## model (models/lights, as level_fixtures.gd places it), one mesh of all the lamps of a storey, with a surface for
## each part of it. Their light is the shader's (pit_lamp.gdshader, pit_lamp_lens.gdshader), the same lamp_level() the
## room under each of them is lit by.

const MODEL := "res://models/lights/office_lighting_troffer_light_1x4.glb"
const TOP_Y := 0.1432132           # troffer housing top, baked model coordinates (level_fixtures.gd)
const REACH := 48.0                # m: past this a lamp is not drawn (the room's own light still shows)
const LampShader := preload("res://shaders/pit_lamp.gdshader")
const LensShader := preload("res://shaders/pit_lamp_lens.gdshader")

static var _parts: Array = []      # [{mesh, xf}] housing, tray, tubes, lens

static func _load_parts() -> void:
	if not _parts.is_empty(): return
	var scene: PackedScene = load(MODEL)
	var root: Node3D = scene.instantiate()
	for name in ["Object_3", "Object_4", "Object_5", "Object_2"]:
		var node := root.find_child(name, true, false) as MeshInstance3D
		if node == null: continue
		var t := Transform3D.IDENTITY
		var n: Node = node
		while n != null:
			if n is Node3D: t = (n as Node3D).transform * t
			if n == root: break
			n = n.get_parent()
		_parts.append({"mesh": node.mesh, "xf": Transform3D(Basis(), Vector3(0.0, -TOP_Y, 0.0)) * t, "name": name})
	root.free()

## One mesh of the lamps at `spots` (Transform3D: where the top of the housing is, and which way it lies), or null
static func build(spots: Array) -> ArrayMesh:
	if spots.is_empty(): return null
	_load_parts()
	if _parts.is_empty(): return null
	var out := ArrayMesh.new()
	for part: Dictionary in _parts:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var src: Mesh = part.mesh
		for spot: Transform3D in spots:
			st.append_from(src, 0, spot * (part.xf as Transform3D))
		st.commit(out)
		var at := out.get_surface_count() - 1
		out.surface_set_name(at, String(part.name))
	return out

## The materials, one per surface of `build`'s mesh, sharing the shaft's tube pattern and its fades
static func materials(rows: PackedFloat32Array, seg_h: float, cell: float, tube_color: Color) -> Dictionary:
	var out := {}
	for name in ["Object_3", "Object_4", "Object_5"]:
		var m := ShaderMaterial.new()
		m.shader = LampShader
		m.set_shader_parameter("albedo_col", Color("cfcabf") if name == "Object_3" else (Color("eeece4") if name == "Object_4" else Color(0.9, 0.9, 0.85)))
		m.set_shader_parameter("is_tube", 1.0 if name == "Object_5" else 0.0)
		out[name] = m
	var lens := ShaderMaterial.new()
	lens.shader = LensShader
	out["Object_2"] = lens
	for m: ShaderMaterial in out.values():
		m.set_shader_parameter("rows", rows)
		m.set_shader_parameter("period", PitFallPeriod)
		m.set_shader_parameter("seg_h", seg_h)
		m.set_shader_parameter("cell", cell)
		m.set_shader_parameter("tube_color", tube_color)
	return out

const PitFallPeriod := 12            # pit_fall.gd ROW_PERIOD

## A MeshInstance3D of `mesh` wearing `mats` (from `materials`), seen only from near
static func instance(mesh: ArrayMesh, mats: Dictionary) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	for i in mesh.get_surface_count():
		mi.set_surface_override_material(i, mats[mesh.surface_get_name(i)])
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.visibility_range_end = REACH
	return mi
