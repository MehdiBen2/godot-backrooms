extends RefCounted
## THE SURFACES (render engine v2): how glossy each kind of surface may be, in one place.
##
## A highlight is the light's own image in the surface, blurred by its roughness. Nothing real is as smooth as a
## material set to roughness 0.02 by a model file or a hand-tuned constant: under a bright panel that gave a spot
## many times brighter than the screen, the glow blew it into a ball, and on a moving view it sparkled. Each class
## here has a floor under its roughness (and real-world reflectance), and limit() holds every standard material
## of a built floor to it (level_builder.gd _floor_ready). A material only ever gets rougher, never smoother.
## Shader materials set their own (the glass: shaders/glass.gdshader; the ceilings and tubes: their shaders).
##
##   glass    see-through (transparency on): a film of dust and fingerprints on it, never a perfect mirror
##   metal    metallic over half: brushed, painted or worn steel, chrome at its best
##   glazed   glossy dielectrics: tile glaze, varnish, laminate, plastic
##   rough    the rest is left as it is (paint, plaster, carpet, fabric, concrete are rough already)

const RULES := {
	"glass": {"min_rough": 0.06},
	"metal": {"min_rough": 0.18},
	"glazed": {"min_rough": 0.12},
}

## The class of standard material `m`
static func class_of(m: BaseMaterial3D) -> String:
	if m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and m.albedo_color.a < 0.9: return "glass"
	if m.metallic > 0.5: return "metal"
	return "glazed"

## Holds every standard material under `root` (overrides, per-surface overrides, the meshes' own) to its class's
## floor. Materials are shared, so each is looked at once.
static func limit(root: Node) -> void:
	var seen := {}
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		_fix(g.material_override, seen)
		var mi := g as MeshInstance3D
		if mi == null or mi.mesh == null: continue
		for s in mi.mesh.get_surface_count():
			_fix(mi.get_surface_override_material(s), seen)
			_fix(mi.mesh.surface_get_material(s), seen)

static func _fix(m: Material, seen: Dictionary) -> void:
	if m == null or seen.has(m): return
	seen[m] = true
	var b := m as BaseMaterial3D
	if b == null: return
	var floor_r: float = RULES[class_of(b)].min_rough
	if b.roughness < floor_r: b.roughness = floor_r
	if b.next_pass != null: _fix(b.next_pass, seen)

## A textures/pbr material for something built in code or a model's own part: tinted (`tint` multiplies the
## texture, so one Powder_Coat set is a charcoal frame, a putty desk or a cream cabinet) and laid on triplanar,
## one repeat every `repeat_m` metres, in world space (`world`: things that stand still where they are built) or
## the mesh's own (a prop, whose texture should go where it goes). Cached: one material per set of arguments.
static var _pbr := {}

static func pbr(id: String, tint := Color.WHITE, repeat_m := 1.0, world := false) -> StandardMaterial3D:
	var key := "%s|%s|%s|%s" % [id, tint.to_html(false), repeat_m, world]
	if _pbr.has(key): return _pbr[key]
	var path := "res://textures/pbr/%s/%s.tres" % [id, id]
	var m: StandardMaterial3D
	if ResourceLoader.exists(path): m = (load(path) as StandardMaterial3D).duplicate()
	else: m = StandardMaterial3D.new()
	m.albedo_color = tint
	m.uv1_triplanar = true
	m.uv1_world_triplanar = world
	m.uv1_scale = Vector3.ONE / maxf(repeat_m, 0.01)
	m.uv1_triplanar_sharpness = 4.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_pbr[key] = m
	return m

## Swaps a model's own materials, by name, for textures/pbr ones (object_types.json "pbr_mats": {material name:
## [pbr id, tint (hex), metres a repeat]}): the outpost's furniture, built in Blender with flat colours, wears the
## real scanned surfaces this way without being rebuilt
static func swap_named(mi: MeshInstance3D, map: Dictionary) -> void:
	if mi.mesh == null: return
	for s in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(s)
		if m == null or not map.has(m.resource_name): continue
		var spec: Array = map[m.resource_name]
		mi.set_surface_override_material(s, pbr(str(spec[0]), Color(str(spec[1])), float(spec[2])))
