extends Node

const LensPointer := preload("res://scripts/UI/hud/lens_pointer.gd")

var player: Node
var ui

var drawing := false
var p1_2d := Vector2.ZERO
var p2_2d := Vector2.ZERO
var preview_rect: ColorRect
var ui_down := false

func _ready() -> void:
	var canvas = CanvasLayer.new()
	canvas.layer = 50
	add_child(canvas)
	preview_rect = ColorRect.new()
	preview_rect.color = Color(0.8, 0.2, 1.0, 0.3)
	preview_rect.visible = false
	canvas.add_child(preview_rect)

func _cursor() -> bool:
	return ui != null and ui.cursor_mode

func _process(dt: float) -> void:
	var can: bool = player != null and Game.playing and not Game.dead and not player.dead
	var pen_down: bool = can and _cursor() and ui.tool == "portal" and ui_down
	
	if pen_down:
		var m := LensPointer.render_pos(player.cam.get_viewport())
		if not drawing:
			drawing = true
			p1_2d = m
			preview_rect.visible = true
		p2_2d = m
		
		# Update preview rect
		var min_x = minf(p1_2d.x, p2_2d.x)
		var max_x = maxf(p1_2d.x, p2_2d.x)
		var min_y = minf(p1_2d.y, p2_2d.y)
		var max_y = maxf(p1_2d.y, p2_2d.y)
		preview_rect.position = Vector2(min_x, min_y)
		preview_rect.size = Vector2(max_x - min_x, max_y - min_y)
	else:
		if drawing:
			_finish()
		drawing = false
		preview_rect.visible = false

func _aim(m: Vector2) -> Dictionary:
	var cam: Camera3D = player.cam
	var from = cam.project_ray_origin(m)
	var dir = cam.project_ray_normal(m)
	var q = PhysicsRayQueryParameters3D.create(from, from + dir * 100.0, 1) # WORLD_MASK
	q.exclude = [player.get_rid()]
	return player.get_world_3d().direct_space_state.intersect_ray(q)

func _finish() -> void:
	if p1_2d.distance_to(p2_2d) < 10.0: return # Too small
	
	var hit1 = _aim(p1_2d)
	var hit2 = _aim(p2_2d)
	
	if hit1.is_empty() or hit2.is_empty(): return
	
	var pos1: Vector3 = hit1.position
	var pos2: Vector3 = hit2.position
	var n: Vector3 = hit1.normal
	
	if n.dot(hit2.normal) < 0.9: return # Must be on the same flat surface
	
	var center = (pos1 + pos2) * 0.5
	center += n * 0.05 # Lift it slightly off the wall
	
	var portal_mesh = QuadMesh.new()
	var diff = pos2 - pos1
	var up = Vector3.UP
	if absf(n.y) > 0.9:
		up = Vector3.RIGHT
	var right = up.cross(n).normalized()
	up = n.cross(right).normalized()
	
	var width = absf(diff.dot(right))
	var height = absf(diff.dot(up))
	if width < 0.2 or height < 0.2: return
	
	portal_mesh.size = Vector2(width, height)
	
	var mi = MeshInstance3D.new()
	mi.mesh = portal_mesh
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0, 0, 0, 1)
	mi.material_override = mat
	
	var light = OmniLight3D.new()
	light.light_color = Color(0.8, 0.2, 1.0) # Neon purple
	light.light_energy = 5.0
	light.omni_range = maxf(width, height) * 3.0
	light.position = Vector3(0, 0, 0.5)
	mi.add_child(light)
	
	var parts = GPUParticles3D.new()
	parts.amount = 100
	parts.lifetime = 2.0
	var prmat = ParticleProcessMaterial.new()
	prmat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	prmat.emission_box_extents = Vector3(width/2.0, height/2.0, 0.1)
	prmat.gravity = Vector3(0, 0, 0)
	prmat.radial_accel_min = -1.5
	prmat.radial_accel_max = -0.5
	parts.process_material = prmat
	var pmat = StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.albedo_color = Color(0.9, 0.4, 1.0)
	var quad = QuadMesh.new()
	quad.size = Vector2(0.04, 0.04)
	quad.material = pmat
	parts.draw_pass_1 = quad
	parts.position = Vector3(0, 0, 0.1)
	mi.add_child(parts)
	
	var border = MeshInstance3D.new()
	var bmesh = QuadMesh.new()
	bmesh.size = Vector2(width + 0.15, height + 0.15)
	var bmat = StandardMaterial3D.new()
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.albedo_color = Color(0.8, 0.2, 1.0)
	border.mesh = bmesh
	border.material_override = bmat
	border.position = Vector3(0, 0, -0.01)
	mi.add_child(border)
	
	# Add to the level
	var level = player.get_parent().get_node_or_null("Level")
	if level != null:
		level.add_child(mi)
		mi.global_position = center
		mi.look_at(center + n, up)
