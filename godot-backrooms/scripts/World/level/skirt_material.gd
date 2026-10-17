extends RefCounted
## The skirting board's and the stairwell door frame's material, shared by the maze walls (level_geometry.gd) and
## the stairwells (props/stairs.gd): Plaster_001 (textures/pbr/Plaster_001) aged by shaders/skirt_aged.gdshader,
## in world space so the boards, which have no UVs, all wear it alike.

const DIR := "res://textures/pbr/Plaster_001/Plaster_001_"

static var _mat: ShaderMaterial

static func get_material() -> ShaderMaterial:
	if _mat != null: return _mat
	var m := ShaderMaterial.new()
	_mat = m
	m.shader = load("res://shaders/skirt_aged.gdshader")
	m.set_shader_parameter("albedo_tex", load(DIR + "Color.jpg"))
	m.set_shader_parameter("rough_tex", load(DIR + "Roughness.jpg"))
	m.set_shader_parameter("normal_tex", load(DIR + "NormalGL.jpg"))
	return m
