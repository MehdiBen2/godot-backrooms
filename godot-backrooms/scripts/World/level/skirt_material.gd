extends RefCounted
## The skirting board's and the stairwell door frame's material, shared by the maze walls (level_geometry.gd) and
## the stairwells (props/stairs.gd): Plaster_001 (textures/pbr/Plaster_001) aged by shaders/skirt_aged.gdshader,
## in world space so the boards, which have no UVs, all wear it alike.

const DIR := "res://textures/pbr/Plaster_001/Plaster_001_"

## The grime photos (textures/dirt_0.jpg, dirt_1.jpg: multiply maps, clean white, mirrored so they tile), kept here
## for the walls' dirt cards (level_trim.gd)
const DIRT := ["res://textures/dirt_0.jpg", "res://textures/dirt_1.jpg"]

static var _mat: ShaderMaterial
static var _raw := {}

## A texture by path; one Godot hasn't imported yet is read straight from its file
static func tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path): return load(path)
	if not _raw.has(path):
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img != null and not img.is_empty():
			img.generate_mipmaps()
			_raw[path] = ImageTexture.create_from_image(img)
		else:
			push_warning("texture not found: " + path)
			_raw[path] = null
	return _raw[path]

static func get_material() -> ShaderMaterial:
	if _mat != null: return _mat
	var m := ShaderMaterial.new()
	_mat = m
	m.shader = load("res://shaders/skirt_aged.gdshader")
	m.set_shader_parameter("albedo_tex", load(DIR + "Color.jpg"))
	m.set_shader_parameter("rough_tex", load(DIR + "Roughness.jpg"))
	m.set_shader_parameter("normal_tex", load(DIR + "NormalGL.jpg"))
	return m
