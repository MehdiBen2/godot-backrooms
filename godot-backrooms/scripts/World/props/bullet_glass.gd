extends RefCounted
## The one glass material of the T.S.R.A. outpost (shaders/glass.gdshader): the panes of the "glazing" openings in
## the walls (props/outpost_glazing.gd) and the glass in the outpost's model props (object_types.json "glass_mats":
## the names of a model's own materials it stands in for, industrial_prop.gd). Shared, so every pane is one material.

static var _mat: ShaderMaterial

static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = load("res://shaders/glass.gdshader")
		_mat.set_shader_parameter("smudge", load("res://textures/glass_smudge.png"))
	return _mat

## Puts the glass material on every surface of `mi` whose own material is one of `names`
static func swap(mi: MeshInstance3D, names: Array) -> void:
	if mi.mesh == null: return
	for s in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(s)
		if m != null and names.has(m.resource_name):
			mi.set_surface_override_material(s, material())
