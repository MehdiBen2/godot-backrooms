extends Node3D
## Going under (level_geometry.gd _build_water adds one to a floor that has water, the floor you walk on only).
## Each frame it asks the level whether the camera is below a water body's surface (level_data.gd water_at); while
## it is, a quad over the whole screen (underwater.gdshader) shows everything through the water between it and
## the eye, and level.underwater rises for audio.gd to muffle the world by. Both ease in and out over a moment, so
## ducking under and coming up is a swell, not a cut.

const UnderwaterShader := preload("res://shaders/underwater.gdshader")

var level: Node
var _quad: MeshInstance3D
var _mat: ShaderMaterial
var _amount := 0.0

func setup(lv: Node) -> void:
	level = lv
	_mat = ShaderMaterial.new()
	_mat.shader = UnderwaterShader
	_mat.render_priority = 100                 # after every other see-through surface (the water's own included)
	var q := QuadMesh.new()
	q.size = Vector2(2.0, 2.0)
	_quad = MeshInstance3D.new()
	_quad.mesh = q
	_quad.material_override = _mat
	_quad.extra_cull_margin = 16384.0          # its vertices are placed on the screen by the shader: never culled
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.visible = false
	add_child(_quad)

func _process(dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or level == null: return
	var at: Vector3 = level.to_local(cam.global_position)
	var o: Dictionary = level.water_at(at)
	var depth := float(o.level) - at.y if not o.is_empty() else 0.0
	var want := clampf(depth / 0.06, 0.0, 1.0)        # the eye just under the surface is under it
	_amount = move_toward(_amount, want, dt * (6.0 if want > _amount else 3.0))
	level.underwater = _amount
	_quad.visible = _amount > 0.001
	if not _quad.visible: return
	_mat.set_shader_parameter("amount", _amount)
	if not o.is_empty():
		var tint: Array = WaterBodyTints.get(str(o.get("tint", "teal")), WaterBodyTints.teal)
		_mat.set_shader_parameter("absorb", tint[0])
		_mat.set_shader_parameter("scatter_color", tint[1])
		_mat.set_shader_parameter("surface_y", level.global_position.y + float(o.level))

const WaterBodyTints := preload("res://scripts/World/props/water_body.gd").TINTS

func _exit_tree() -> void:
	if level != null and is_instance_valid(level): level.underwater = 0.0
