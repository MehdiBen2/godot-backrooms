@tool
class_name UBGrid
extends RefCounted
## Reference grid renderer. The grid plane is created directly through
## RenderingServer in the edited scene's World3D and never added to the scene
## tree, so it cannot leak into saved scenes. It can sit on any axis plane
## with an offset along that axis; line density always matches the snap
## step. Independent of the editor's native grid.

const PLANE_SIZE := 4000.0

var _mesh: PlaneMesh
var _material: ShaderMaterial
var _instance := RID()
var _scenario := RID()


func _init() -> void:
	_mesh = PlaneMesh.new()
	_mesh.size = Vector2(PLANE_SIZE, PLANE_SIZE)
	_material = ShaderMaterial.new()
	_material.shader = preload("res://addons/unibuilder/editor/grid.gdshader")
	_material.render_priority = -10


## Sync the grid to the given world and settings. Recreates the RS instance
## when the edited scene's world changes (scene tab switches).
func update(world: World3D, visible: bool, axis: int, offset: float, step: float) -> void:
	if world == null:
		if _instance.is_valid():
			RenderingServer.instance_set_visible(_instance, false)
		return
	if not _instance.is_valid() or _scenario != world.scenario:
		_free_instance()
		_scenario = world.scenario
		_instance = RenderingServer.instance_create2(_mesh.get_rid(), _scenario)
		RenderingServer.instance_geometry_set_material_override(_instance, _material.get_rid())
		RenderingServer.instance_geometry_set_cast_shadows_setting(
			_instance, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	RenderingServer.instance_set_visible(_instance, visible)

	var basis := Basis()
	var origin := Vector3.ZERO
	match axis:
		0:
			basis = Basis(Vector3(0, 0, 1), -PI / 2.0)
			origin = Vector3(offset, 0, 0)
		2:
			basis = Basis(Vector3(1, 0, 0), PI / 2.0)
			origin = Vector3(0, 0, offset)
		_:
			origin = Vector3(0, offset, 0)
	RenderingServer.instance_set_transform(_instance, Transform3D(basis, origin))

	_material.set_shader_parameter("grid_step", step)
	_material.set_shader_parameter("axis", axis)
	_material.set_shader_parameter("fade_distance", maxf(150.0, step * 200.0))


func cleanup() -> void:
	_free_instance()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _instance.is_valid():
		RenderingServer.free_rid(_instance)
		_instance = RID()


func _free_instance() -> void:
	if _instance.is_valid():
		RenderingServer.free_rid(_instance)
		_instance = RID()
	_scenario = RID()
