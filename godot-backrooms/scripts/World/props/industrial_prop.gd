extends Node3D
## A background industrial-clutter prop (barrel, gas can, cable drum, ...): one imported FBX mesh with a
## PBR material built at runtime from its loose texture set. The source packs ship geometry and textures
## as separate files with no material link between them (a marketplace convention, not a Godot one), so
## the material is assembled here the same way level_geometry.gd's _mat() builds wall materials.
##
## Placed like any other level object (level_geometry.gd _build_props(), levels/object_types.json entries
## with a "model" key). The whole instance is shifted up so the mesh's own lowest point sits on the floor,
## whatever unhelpful pivot the source file used - these packs don't agree on where "the ground" is.

static var _floodlight_cookie: Texture2D

static func _get_cookie(path: String = "") -> Texture2D:
	if not path.is_empty() and ResourceLoader.exists(path):
		return load(path)
	if _floodlight_cookie != null:
		return _floodlight_cookie
	const DEFAULT_PATH := "res://textures/lights/floodlight_cookie.png"
	if ResourceLoader.exists(DEFAULT_PATH):
		_floodlight_cookie = load(DEFAULT_PATH)
		if _floodlight_cookie != null:
			return _floodlight_cookie
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		var ny := (float(y) / float(size - 1)) * 2.0 - 1.0
		for x in range(size):
			var nx := (float(x) / float(size - 1)) * 2.0 - 1.0
			var rx := absf(nx) / 0.88
			var ry := absf(ny) / 0.65
			var p_dist := pow(pow(rx, 4.0) + pow(ry, 4.0), 0.25)
			var falloff := clampf(1.0 - smoothstep(0.65, 1.0, p_dist), 0.0, 1.0)
			var strip := exp(-pow(ny * 3.2, 2.0)) * 0.4
			var bands := sin(ny * 25.0) * 0.04 * (1.0 - absf(ny))
			var intensity := clampf((falloff * 0.8 + strip + bands) * falloff, 0.0, 1.0)
			img.set_pixel(x, y, Color(intensity, intensity, intensity, 1.0))
	_floodlight_cookie = ImageTexture.create_from_image(img)
	return _floodlight_cookie

func build(model_path: String, textures: Dictionary, light: Dictionary = {}, model_yaw: float = 0.0) -> void:
	var scene: PackedScene = load(model_path)
	var inst := scene.instantiate()
	add_child(inst)
	inst.rotation.y = deg_to_rad(model_yaw)     # some packs model the front on the wrong side: the arrow (+X) is the front
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
		mat.emission_energy_multiplier = float(textures.get("emission_energy", 3.5))
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
		if not light.is_empty():
			_add_light(light, aabb)

## T.S.R.A work lamps are real light sources ("light" in object_types.json: color, energy, range, angle =
## cone width, tilt = degrees it dips below horizontal, height = fraction of the prop's height). The beam
## goes out the way the editor's arrow points (+X), angled down toward the ground in the real shape of research
## floodlights, plus a faint bulb glow on each fixture. It fades out with distance so a room full of them
## stays cheap, and it is independent of the ceiling tubes (a power cut leaves it on).
func _add_light(cfg: Dictionary, aabb: AABB) -> void:
	var col := Color(str(cfg.get("color", "ffe2a8")))
	var base_energy := float(cfg.get("energy", 4.5))
	var base_range := float(cfg.get("range", 14.0))
	var base_angle := float(cfg.get("angle", 52.0))
	var base_tilt := float(cfg.get("tilt", 25.0))
	var atten := float(cfg.get("attenuation", 0.85))
	
	var cookie: Texture2D = null
	if cfg.get("projector", true):
		var proj_path := str(cfg.get("projector_texture", ""))
		cookie = _get_cookie(proj_path)
	
	var spots: Array = []
	if cfg.has("spots") and cfg.spots is Array:
		spots = cfg.spots
	else:
		var default_h: float = aabb.size.y * float(cfg.get("height", 0.85))
		spots = [{"offset": [0.06, default_h, 0.0], "yaw": 0.0}]
	
	for s_entry in spots:
		var off = s_entry.get("offset", [0.0, 0.0, 0.0])
		var spot_pos := Vector3(float(off[0]), float(off[1]), float(off[2]))
		var spot_yaw := float(s_entry.get("yaw", 0.0))
		var spot_tilt := float(s_entry.get("tilt", base_tilt))
		var spot_energy := float(s_entry.get("energy", base_energy))
		
		var s := SpotLight3D.new()
		s.light_color = col
		s.light_energy = spot_energy
		s.spot_range = base_range
		s.spot_angle = base_angle
		s.spot_attenuation = atten
		s.shadow_enabled = true
		if cookie != null:
			s.light_projector = cookie
		s.distance_fade_enabled = true
		s.distance_fade_begin = 30.0
		s.distance_fade_length = 10.0
		s.position = spot_pos
		s.rotation = Vector3(-deg_to_rad(spot_tilt), -PI * 0.5 + deg_to_rad(spot_yaw), 0.0)
		add_child(s)
		
		var glow := OmniLight3D.new()
		glow.light_color = col
		glow.light_energy = float(cfg.get("glow_energy", 0.35))
		glow.omni_range = float(cfg.get("glow_range", 1.2))
		glow.distance_fade_enabled = true
		glow.distance_fade_begin = 20.0
		glow.distance_fade_length = 8.0
		glow.position = spot_pos + Vector3(0.04, 0.0, 0.0)
		add_child(glow)

func _collect_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)

