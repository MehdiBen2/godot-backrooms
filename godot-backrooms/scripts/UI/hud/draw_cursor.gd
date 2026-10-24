extends Control
## The pen's footprint on the surface under the mouse: a ring as wide as the line MARKER will lay
## (sketch_tool.gd), as wide as the ERASER's reach, or as wide as the STAMP being pressed on. It
## follows the real cursor, so what you see is where the ink lands (lens_pointer.gd does the aiming
## through the camera's bent lens; the ring's radius is measured by projecting one line width at the
## distance of the surface it hit). Built by draw_ui.gd, drawn under the panel.

const SketchMarks := preload("res://scripts/World/props/sketch_marks.gd")

var ui                       # draw_ui.gd
var sketch                   # sketch_tool.gd

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _process(_dt: float) -> void:
	var on: bool = ui != null and ui.open and ui.cursor_mode and sketch != null \
		and not ui.over_panel() and SketchMarks.live != null \
		and (ui.tool == "marker" or ui.tool == "eraser" or ui.tool == "stamp")
	visible = on
	if on:
		queue_redraw()

func _draw() -> void:
	var hit: Dictionary = sketch._aim()
	if hit.is_empty():
		return
	var cam: Camera3D = sketch.player.cam
	if cam == null:
		return
	var n: Vector3 = (hit.normal as Vector3).normalized()
	var p: Vector3 = hit.position
	# one line width across the surface, so the ring matches what sketch_marks.ribbon() will draw there
	var right := n.cross(Vector3.UP)
	if right.length() < 0.01:
		right = n.cross(Vector3.RIGHT)
	right = right.normalized()
	var reach := 0.0
	if ui.tool == "marker":
		reach = sketch.width * 0.5
	elif ui.tool == "eraser":
		reach = sketch.erase_radius
	else:
		reach = sketch.stamp_size * 0.5
	var r: float = cam.unproject_position(p).distance_to(cam.unproject_position(p + right * reach))
	if r < 1.0:
		r = 1.0
	var c := get_viewport().get_mouse_position()
	var ink: Color = sketch.color
	var col := Color(ink.r, ink.g, ink.b, 0.75)
	if ui.tool == "eraser":
		col = Color(0.92, 0.9, 0.84, 0.75)
	draw_arc(c, r, 0.0, TAU, 48, Color(0.0, 0.0, 0.0, 0.5), 3.0, true)
	draw_arc(c, r, 0.0, TAU, 48, col, 1.4, true)
	draw_line(c - Vector2(3.0, 0.0), c + Vector2(3.0, 0.0), col, 1.0, true)
	draw_line(c - Vector2(0.0, 3.0), c + Vector2(0.0, 3.0), col, 1.0, true)
