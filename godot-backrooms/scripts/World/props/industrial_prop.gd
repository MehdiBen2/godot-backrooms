extends Node3D
## A background industrial-clutter prop (barrel, gas can, cable drum, ...): one imported FBX mesh with a
## PBR material built at runtime from its loose texture set. The source packs ship geometry and textures
## as separate files with no material link between them (a marketplace convention, not a Godot one), so
## the material is assembled here the same way level_geometry.gd's _mat() builds wall materials.
##
## Placed like any other level object (level_geometry.gd _build_props(), levels/object_types.json entries
## with a "model" key). The whole instance is shifted up so the mesh's own lowest point sits on the floor,
## whatever unhelpful pivot the source file used - these packs don't agree on where "the ground" is.

func build(model_path: String, textures: Dictionary) -> void:
	var scene: PackedScene = load(model_path)
	var inst := scene.instantiate()
	add_child(inst)
	var mat := StandardMaterial3D.new()
	if textures.has("albedo"):
		mat.albedo_texture = load(textures.albedo)
	if textures.has("normal"):
		mat.normal_enabled = true
		mat.normal_texture = load(textures.normal)
	if textures.has("roughness"):
		mat.roughness_texture = load(textures.roughness)
	if textures.has("metallic"):
		mat.metallic_texture = load(textures.metallic)
		mat.metallic = 1.0
	if textures.has("emissive"):
		mat.emission_enabled = true
		mat.emission_texture = load(textures.emissive)
		mat.emission_energy_multiplier = 1.5
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(inst, meshes)
	var aabb := AABB()
	var first := true
	for mi in meshes:
		mi.material_override = mat
		mi.visibility_range_end = 45.0
		mi.visibility_range_end_margin = 8.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		var box: AABB = mi.transform * mi.get_aabb()
		aabb = box if first else aabb.merge(box)
		first = false
	if not first:
		inst.position.y -= aabb.position.y

func _collect_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)
