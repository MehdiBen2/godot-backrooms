extends Node

const LensPointer := preload("res://scripts/UI/hud/lens_pointer.gd")
const PortalMarks := preload("res://scripts/World/props/portal_marks.gd")

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
	
	var diff = pos2 - pos1
	var up = Vector3.UP
	if absf(n.y) > 0.9:
		up = Vector3.RIGHT
	var right = up.cross(n).normalized()
	up = n.cross(right).normalized()
	
	var width = absf(diff.dot(right))
	var height = absf(diff.dot(up))
	if width < 0.2 or height < 0.2: return
	
	if PortalMarks.live != null:
		PortalMarks.live.place(pos1, pos2, n)

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
