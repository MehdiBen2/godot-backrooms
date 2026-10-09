extends Node

const LensPointer := preload("res://scripts/UI/hud/lens_pointer.gd")
const PortalMarks := preload("res://scripts/World/props/portal_marks.gd")

var player: Node
var ui

var drawing := false
var mouse_start_screen := Vector2.ZERO
var wall_pos1 := Vector3.ZERO
var wall_pos2 := Vector3.ZERO
var wall_normal := Vector3.ZERO
var preview_rect: ColorRect
var preview_3d: MeshInstance3D
var preview_mesh: QuadMesh
var ui_down := false

func _ready() -> void:
	var canvas = CanvasLayer.new()
	canvas.layer = 50
	add_child(canvas)
	preview_rect = ColorRect.new()
	preview_rect.color = Color(1.0, 0.85, 0.2, 0.25)
	preview_rect.visible = false
	canvas.add_child(preview_rect)
	
	# Real-time 3D preview on the wall plane
	preview_mesh = QuadMesh.new()
	preview_3d = MeshInstance3D.new()
	preview_3d.mesh = preview_mesh
	preview_3d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pmat = StandardMaterial3D.new()
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.albedo_color = Color(1.0, 0.9, 0.3, 0.45)
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	preview_3d.material_override = pmat
	preview_3d.visible = false
	add_child(preview_3d)

func _cursor() -> bool:
	return ui != null and ui.cursor_mode

func _ray_from_screen(screen_pos: Vector2) -> Dictionary:
	var cam: Camera3D = player.cam
	var vp: Viewport = cam.get_viewport()
	var render_p = LensPointer.screen_to_render(screen_pos, vp)
	var from = cam.project_ray_origin(render_p)
	var dir = cam.project_ray_normal(render_p)
	return {"from": from, "dir": dir}

func _intersect_world(screen_pos: Vector2) -> Dictionary:
	var r = _ray_from_screen(screen_pos)
	var q = PhysicsRayQueryParameters3D.create(r.from, r.from + r.dir * 100.0, 1) # WORLD_MASK
	q.exclude = [player.get_rid()]
	return player.get_world_3d().direct_space_state.intersect_ray(q)

func _process(dt: float) -> void:
	var can: bool = player != null and Game.playing and not Game.dead and not player.dead
	var pen_down: bool = can and _cursor() and ui.tool == "portal" and ui_down
	var vp: Viewport = player.cam.get_viewport() if player != null and player.cam != null else null
	
	if pen_down and vp != null:
		var cur_screen := vp.get_mouse_position()
		if not drawing:
			var hit = _intersect_world(cur_screen)
			if hit.is_empty() or not (hit.collider is StaticBody3D):
				return
			drawing = true
			mouse_start_screen = cur_screen
			wall_pos1 = hit.position
			wall_pos2 = hit.position
			wall_normal = (hit.normal as Vector3).normalized()
			preview_rect.visible = true
			preview_3d.visible = true
		
		# 1) 2D screen preview matches mouse exactly
		var min_x = minf(mouse_start_screen.x, cur_screen.x)
		var max_x = maxf(mouse_start_screen.x, cur_screen.x)
		var min_y = minf(mouse_start_screen.y, cur_screen.y)
		var max_y = maxf(mouse_start_screen.y, cur_screen.y)
		preview_rect.position = Vector2(min_x, min_y)
		preview_rect.size = Vector2(max_x - min_x, max_y - min_y)
		
		# 2) 3D ray projection onto the wall's plane (through fisheye lens)
		var r = _ray_from_screen(cur_screen)
		var denom = wall_normal.dot(r.dir)
		if denom < -0.01:
			var t = wall_normal.dot(wall_pos1 - r.from) / denom
			if t > 0.0:
				wall_pos2 = r.from + r.dir * t
		
		# Update 3D preview on the wall plane
		_update_preview_3d()
	else:
		if drawing:
			_finish()
		drawing = false
		preview_rect.visible = false
		preview_3d.visible = false

func _update_preview_3d() -> void:
	var diff = wall_pos2 - wall_pos1
	var up = Vector3.UP
	if absf(wall_normal.y) > 0.9:
		up = Vector3.RIGHT
	var right = up.cross(wall_normal).normalized()
	up = wall_normal.cross(right).normalized()
	
	var width = absf(diff.dot(right))
	var height = absf(diff.dot(up))
	if width < 0.1 or height < 0.1:
		preview_3d.visible = false
		return
	
	preview_3d.visible = true
	preview_mesh.size = Vector2(width, height)
	var center = (wall_pos1 + wall_pos2) * 0.5 + wall_normal * 0.005
	preview_3d.global_position = center
	preview_3d.look_at(center - wall_normal, up)

func _finish() -> void:
	preview_rect.visible = false
	preview_3d.visible = false
	
	var diff = wall_pos2 - wall_pos1
	var up = Vector3.UP
	if absf(wall_normal.y) > 0.9:
		up = Vector3.RIGHT
	var right = up.cross(wall_normal).normalized()
	up = wall_normal.cross(right).normalized()
	
	var width = absf(diff.dot(right))
	var height = absf(diff.dot(up))
	if width < 0.2 or height < 0.2:
		return # Too small
	
	if PortalMarks.live != null:
		PortalMarks.live.place(wall_pos1, wall_pos2, wall_normal)

func undo() -> bool:
	if PortalMarks.live != null:
		return PortalMarks.live.undo()
	return false

func redo() -> bool:
	if PortalMarks.live != null:
		return PortalMarks.live.redo()
	return false

func remove_near(pos: Vector3, radius: float) -> void:
	if PortalMarks.live != null:
		PortalMarks.live.remove_near(pos, radius)
