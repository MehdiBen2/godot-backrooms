extends RefCounted
## The tubes on the walls of a shaft (pit_fall.gd, endless_shaft.gd): the level's own troffer model
## (models/lights, as level_fixtures.gd places it), screwed to the wall under the slab. A MultiMesh for each part
## of the model, holding every lamp of a storey. Their light is the shader's (pit_lamp.gdshader, pit_lamp_lens.gdshader):
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

## The lamps at `spots` (Transform3D): [[part id, MultiMesh of it at every spot]], empty if none. (They were merged
## into one mesh with SurfaceTool.append_from, which reads the model's vertex data back off the GPU on every call:
## 78 lamps took a third of a second. A MultiMesh draws the same with nothing to merge.)
static func build(spots: Array) -> Array:
	if spots.is_empty(): return []
	_load_parts()
	var out: Array = []
	for part: Dictionary in _parts:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = part.mesh
		mm.instance_count = spots.size()
		for i in spots.size():
			mm.set_instance_transform(i, (spots[i] as Transform3D) * (part.xf as Transform3D))
		out.append([String(part.id), mm])
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

## The lamps of `set` (from `build`) wearing `mats` (from `materials`), seen only from near
static func instance(set: Array, mats: Dictionary) -> Node3D:
	var root := Node3D.new()
	for part: Array in set:
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = part[1]
		mi.material_override = mats[part[0]]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mi.visibility_range_end = REACH
		root.add_child(mi)
	return root
