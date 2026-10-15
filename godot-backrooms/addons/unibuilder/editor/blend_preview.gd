@tool
class_name UBBlendPreview
extends SubViewport
## Renders thumbnails for UBBlendMaterial. The editor's own material preview shows a
## blend material as layer B alone, because its preview sphere has no vertex colours
## and the blend factor is the vertex alpha. This one renders a sphere whose vertex
## alpha is smooth 3D noise, so both layers and the transition between them show.

## Swatch size in pixels.
const SIZE := 64
## Noise period over the unit sphere; low enough for a few large patches at swatch size.
const NOISE_PERIOD := 0.55
## Noise band mapped across the full 0-1 alpha range. Noise outside it saturates to
## one layer, so both layers get solid, readable area.
const NOISE_CONTRAST := 0.12

static var _mesh: ArrayMesh

var _mesh_instance: MeshInstance3D


var _busy := false


func _init() -> void:
	size = Vector2i(SIZE, SIZE)
	transparent_bg = true

	own_world_3d = true
	world_3d = World3D.new()
	render_target_update_mode = SubViewport.UPDATE_DISABLED

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = noise_sphere()
	add_child(_mesh_instance)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.1
	camera.position = Vector3(0, 0, 3)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.57, 0.6)
	env.ambient_light_energy = 1.0
	camera.environment = env
	add_child(camera)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, -35, 0)
	key.light_energy = 1.3
	add_child(key)


## Unit sphere with white vertex colours whose alpha is smooth 3D noise. Built once
## and shared; every swatch renders the same mesh with a different material.
static func noise_sphere() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var source := SphereMesh.new()
	source.radius = 1.0
	source.height = 2.0
	source.radial_segments = 48
	source.rings = 24
	var arrays: Array = source.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = NOISE_PERIOD
	noise.seed = 1
	var colors := PackedColorArray()
	colors.resize(verts.size())
	for i in verts.size():

		var n := noise.get_noise_3dv(verts[i] * 4.0)
		var a := clampf(0.5 + n / (2.0 * NOISE_CONTRAST), 0.0, 1.0)
		colors[i] = Color(1, 1, 1, a)
	arrays[Mesh.ARRAY_COLOR] = colors
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _mesh


## Renders one material and returns its thumbnail, or null when there is nothing to
## render into (callers keep their placeholder). Must be awaited.
func render_material(material: Material) -> Texture2D:
	if material == null or not is_inside_tree():
		return null

	if DisplayServer.get_name().contains("headless"):
		return null

	var tree := get_tree()
	while _busy:
		await tree.process_frame
		if not is_inside_tree():
			return null
	_busy = true
	var tex := await _render_now(material)
	_busy = false
	return tex


func _render_now(material: Material) -> Texture2D:
	_mesh_instance.material_override = material
	render_target_update_mode = SubViewport.UPDATE_ONCE

	await RenderingServer.frame_post_draw
	var tex := get_texture()
	if tex == null:
		return null
	var img := tex.get_image()
	_mesh_instance.material_override = null
	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)
