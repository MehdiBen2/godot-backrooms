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

## The model as a scene. A .glb Godot has not imported yet (dropped in while only the level editor was open)
## is read straight from its file, so a test run from the level editor still shows it.
static func _instance(path: String) -> Node3D:
	if ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		return scene.instantiate() as Node3D if scene != null else null
	if path.get_extension().to_lower() in ["glb", "gltf"]:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(ProjectSettings.globalize_path(path), state) == OK:
			return doc.generate_scene(state) as Node3D
	push_warning("prop model not found: " + path)
	return null

## `textures` empty: the model keeps the materials of its own file (a .glb), and `glow` (if above 0) is how
## bright their emissive parts are, whatever the file said. `model_scale`: the size it is built at (1 = the file's).
func build(model_path: String, textures: Dictionary, light: Dictionary = {}, model_yaw: float = 0.0, glow: float = 0.0, model_scale: float = 1.0) -> void:
	build_info({"model": model_path, "textures": textures, "light": light, "model_yaw": model_yaw, "glow": glow, "model_scale": model_scale})

## The prop's box in its own space once built (metres: floor at y = 0), for whoever needs its size
var bounds := AABB()

## Builds the prop from its object_types.json entry. Beyond model / textures / light / glow / model_yaw / model_scale:
##  - "model_nodes": the names of the nodes to keep (a pack holding several objects: just these), "model_drop":
##    names to leave out (a base plate, glass that would hide a window's sky). Any node on a mesh's way up counts.
##  - "model_rot": [x, y, z] degrees that stand a file the right way up / round before "model_yaw" turns it.
##  - "center": true puts the kept part's middle on the object's origin (a pack's pieces sit far from theirs).
##  - "fit": [side, metres]: its real-life size (fit_scale), instead of a "model_scale" worked out by hand.
##  - "collide": "box" (default: a solid box round it; a "mount": "wall" prop: none), "mesh" (its real shape, for
##    stairs) or "none".
func build_info(info: Dictionary, with_light := true) -> void:
	var inst := _instance(str(info.get("model", "")))
	if inst == null:
		return
	add_child(inst)
	var textures: Dictionary = info.get("textures", {})
	var glow := float(info.get("glow", 0.0))
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
	var meshes := kept_meshes(inst, info.get("model_nodes", []), info.get("model_drop", []))
	var raw := AABB()
	var first := true
	for mi in meshes:
		if not textures.is_empty():
			mi.material_override = mat
		elif glow > 0.0:
			_set_glow(mi, glow)
		mi.visibility_range_end = 45.0
		mi.visibility_range_end_margin = 8.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		# the mesh in the model's own space, through every node between the two (a .glb often nests its mesh
		# under nodes that turn and scale it)
		var box: AABB = mesh_box(mi.mesh, in_model(mi, inst))
		raw = box if first else raw.merge(box)
		first = false
	if first:
		return
	var b := fix_basis(info, fit_scale(info, raw))
	var at: AABB = Transform3D(b, Vector3.ZERO) * raw
	var off := Vector3(0.0, -at.position.y, 0.0)
	if bool(info.get("center", false)):
		var c := at.get_center()
		off.x = -c.x
		off.z = -c.z
	inst.transform = Transform3D(b, off)
	at.position += off
	bounds = at
	var light: Dictionary = info.get("light", {})
	if with_light and not light.is_empty():
		_add_light(light, at)
	# (a sign or a lamp on a wall needs nothing solid: it is up out of the way)
	_add_collision(str(info.get("collide", "none" if str(info.get("mount", "")) == "wall" else "box")), at, meshes, inst)

## The size the file is built at. "fit": [side, metres] makes the kept part that big in real life, measured on
## the file's own axes before it is turned: "h" its height, "x" / "z" its width that way, "len" its longer side.
## Without it, "model_scale" (1 = as the file has it).
static func fit_scale(info: Dictionary, raw: AABB) -> float:
	var fit: Array = info.get("fit", [])
	if fit.size() == 2:
		var have := raw.size.y
		match str(fit[0]):
			"x": have = raw.size.x
			"z": have = raw.size.z
			"len": have = maxf(raw.size.x, raw.size.z)
		if have > 0.0001:
			return float(fit[1]) / have
	return float(info.get("model_scale", 1.0))

## How the file is stood in the prop: its "model_rot" fix, then "model_yaw" round, at `scale`
static func fix_basis(info: Dictionary, scale: float) -> Basis:
	var r: Array = info.get("model_rot", [0.0, 0.0, 0.0])
	var rot := Basis.from_euler(Vector3(deg_to_rad(float(r[0])), deg_to_rad(float(r[1])), deg_to_rad(float(r[2]))))
	return Basis(Vector3.UP, deg_to_rad(float(info.get("model_yaw", 0.0)))) * rot * Basis.from_scale(Vector3.ONE * scale)

## The meshes of `inst` the prop is made of: under one of the `keep` names (all of them if `keep` is empty) and
## under none of the `drop` names. The others lose their mesh, so they draw nothing and take no part in its size.
static func kept_meshes(inst: Node, keep: Array, drop: Array) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var kept := keep.is_empty()
		var dropped := false
		var p: Node = mi
		while p != null:
			if keep.has(String(p.name)): kept = true
			if drop.has(String(p.name)): dropped = true
			if p == inst: break
			p = p.get_parent()
		if kept and not dropped:
			out.append(mi)
		else:
			mi.mesh = null
			mi.visible = false
	return out

static var _mesh_boxes := {}

## The box round the triangles `mesh` really draws, placed by `xf`. Measured on the triangles themselves: a box
## turned by a node's rotation grows (a wardrobe's came out 1.5 m square for a 1 x 0.6 m wardrobe), and some
## files carry collapsed (zero-area) triangles off the model too. Worked out once per mesh and placing.
static func mesh_box(mesh: Mesh, xf := Transform3D.IDENTITY) -> AABB:
	var key := "%d %s" % [mesh.get_instance_id(), xf]
	if _mesh_boxes.has(key):
		return _mesh_boxes[key]
	var box := xf * mesh.get_aabb()
	var faces := mesh.get_faces()
	var first := true
	var tiny := mesh.get_aabb().size.length_squared() * 1e-10
	for i in range(0, faces.size() - 2, 3):
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		if (b - a).cross(c - a).length_squared() <= tiny:
			continue
		a = xf * a
		b = xf * b
		c = xf * c
		if first:
			box = AABB(a, Vector3.ZERO)
			first = false
		box = box.expand(a).expand(b).expand(c)
	_mesh_boxes[key] = box
	return box

## `mi` placed in `inst`'s own space (every node between the two; not `inst`'s own transform)
static func in_model(mi: Node3D, inst: Node) -> Transform3D:
	var xf := mi.transform
	var up := mi.get_parent()
	while mi != inst and up != inst and up is Node3D:
		xf = (up as Node3D).transform * xf
		up = up.get_parent()
	return xf

## Something solid where the prop stands, so you can't walk through a sofa: a box round it, or its real shape
func _add_collision(kind: String, box: AABB, meshes: Array[MeshInstance3D], inst: Node3D) -> void:
	if kind == "none" or box.size.y < 0.05:
		return
	var body := StaticBody3D.new()
	body.name = "Collision"
	add_child(body)
	if kind == "mesh":
		for mi in meshes:
			var cs := CollisionShape3D.new()
			cs.shape = mi.mesh.create_trimesh_shape()
			cs.transform = inst.transform * in_model(mi, inst)
			body.add_child(cs)
		return
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(maxf(box.size.x, 0.05), box.size.y, maxf(box.size.z, 0.05))
	cs.shape = sh
	cs.position = box.get_center()
	body.add_child(cs)

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

## Every emissive material of the mesh, glowing at `glow` times its emission texture
func _set_glow(mi: MeshInstance3D, glow: float) -> void:
	if mi.mesh == null:
		return
	for s in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(s) as BaseMaterial3D
		if src == null or not src.emission_enabled:
			continue
		var lit: BaseMaterial3D = src.duplicate()
		if lit.emission_texture != null:            # the texture alone, whichever way the colour is mixed with it
			lit.emission = Color.BLACK if lit.emission_operator == BaseMaterial3D.EMISSION_OP_ADD else Color.WHITE
		lit.emission_energy_multiplier = glow
		mi.set_surface_override_material(s, lit)

func _collect_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)

