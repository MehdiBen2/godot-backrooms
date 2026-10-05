extends RefCounted
## The tubes on the walls of a shaft (pit_fall.gd, endless_shaft.gd): the level's own troffer model
## (models/lights, as level_fixtures.gd places it), screwed to the wall under the slab. One mesh of all the lamps of a
## storey, a surface for each part of the model. Their light is the shader's (pit_lamp.gdshader, pit_lamp_lens.gdshader):
## the row's level, the same one pit_shaft.gdshader lights the walls from, so the tube, the glass and the wall agree.

const MODEL := "res://models/lights/office_lighting_troffer_light_1x4.glb"
const TOP_Y := 0.1432132           # troffer housing top, baked model coordinates (level_fixtures.gd)
const SCALE := 0.6                 # the model is 2.1 m long: a wall tube is about 1.2
const REACH := 70.0                # m: past this a lamp is not drawn (the wall's own light still shows)
const LampShader := preload("res://shaders/pit_lamp.gdshader")
const LensShader := preload("res://shaders/pit_lamp_lens.gdshader")
## what the lamps take from the shaft's own material, so that they are lit, faded and hazed with it
const SHARED := ["rows", "period", "seg_h", "cell", "tube_color", "rot_from", "rot_to", "fade_from", "fade_to", "haze_color", "haze_k", "haze_y"]

static var _parts: Array = []      # [{mesh, xf, id}] housing, tray, tubes, lens

static func _load_parts() -> void:
	if not _parts.is_empty(): return
	var scene: PackedScene = load(MODEL)
	var root: Node3D = scene.instantiate()
	for id: String in ["Object_3", "Object_4", "Object_5", "Object_2"]:
		var node := root.find_child(id, true, false) as MeshInstance3D
		if node == null: continue
		var t := Transform3D.IDENTITY
		var n: Node = node
		while n != null:
			if n is Node3D: t = (n as Node3D).transform * t
			if n == root: break
			n = n.get_parent()
		_parts.append({"mesh": node.mesh, "xf": Transform3D(Basis(), Vector3(0.0, -TOP_Y, 0.0)) * t, "id": id})
	root.free()

## Where a wall tube goes: its housing's top flat to the wall (`n` points into the shaft), lying along `dir`
static func spot(at: Vector3, dir: Vector3, n: Vector3) -> Transform3D:
	var b := Basis(dir, -n, dir.cross(-n)).scaled(Vector3.ONE * SCALE)
	return Transform3D(b, at + n * 0.02)

## One mesh of the lamps at `spots` (Transform3D), or null
static func build(spots: Array) -> ArrayMesh:
	if spots.is_empty(): return null
	_load_parts()
	if _parts.is_empty(): return null
	var out := ArrayMesh.new()
	for part: Dictionary in _parts:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var src: Mesh = part.mesh
		for sp: Transform3D in spots:
			st.append_from(src, 0, sp * (part.xf as Transform3D))
		st.commit(out)
		out.surface_set_name(out.get_surface_count() - 1, String(part.id))
	return out

## The materials, by part, taking what they share from the shaft's material `src`
static func materials(src: ShaderMaterial) -> Dictionary:
	var out := {}
	for id: String in ["Object_3", "Object_4", "Object_5"]:
		var m := ShaderMaterial.new()
		m.shader = LampShader
		m.set_shader_parameter("albedo_col", Color("cfcabf") if id == "Object_3" else (Color("eeece4") if id == "Object_4" else Color(0.9, 0.9, 0.85)))
		m.set_shader_parameter("is_tube", 1.0 if id == "Object_5" else 0.0)
		out[id] = m
	var lens := ShaderMaterial.new()
	lens.shader = LensShader
	out["Object_2"] = lens
	sync(out, src)
	return out

## Take again what the lamps share from `src` (after it has changed), or only `keys` of it
static func sync(mats: Dictionary, src: ShaderMaterial, keys: Array = SHARED) -> void:
	for k: String in keys:
		var v: Variant = src.get_shader_parameter(k)
		if v == null: continue
		for m: ShaderMaterial in mats.values(): m.set_shader_parameter(k, v)

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
