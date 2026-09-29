extends Node
## Freehand marker in the hand. Two ways to use it:
##  - keys: hold B looking at a wall, floor or ceiling within REACH and drag your aim across it; N changes
##    the colour, hold X on a line to rub it out.
##  - the draw tools panel (draw_ui.gd, Y): the mouse cursor is the pen. The MARKER tool draws under the
##    left button, the ERASER rubs out; the panel sets the colour, width, wobble, opacity, dashes and
##    whether it is FREEHAND or a straight LINE.
## The line stays when you let go (sketch_marks.gd). No inventory needed and no limit but MAX_POINTS a
## line. A line can't jump onto another surface: it ends where the surface does. Built by hud.gd.

const SketchMarks := preload("res://scripts/World/props/sketch_marks.gd")

const KEY := KEY_B
const KEY_COLOR := KEY_N
const KEY_ERASE := KEY_X
const LensPointer := preload("res://scripts/UI/hud/lens_pointer.gd")
const CURSOR_REACH := 300.0     # m: with the draw tools panel open the pen reaches this far
const REACH := 3.0               # m
const STEP := 0.02               # m between points
const LINE_STEP := 0.01          # m between points on a straight line
const MAX_POINTS := 800
const WORLD_MASK := 1

var player: Node                 # player.gd (set by hud.gd)
var ui                           # draw_ui.gd, or null when the panel isn't built

# the pen (the panel edits these)
var color := Color("d92b2b")
var width := SketchMarks.WIDTH
var wobble := 1.0
var opacity := 1.0
var style := "solid"             # solid / dashed / dotted
var shape := "freehand"          # freehand / line

var drawing := false
var _pts: Array = []
var _n := Vector3.UP
var _pen := {}                   # the pen as it was when this line started
var _preview: MeshInstance3D
var _mesh := ArrayMesh.new()
var _label: Label
var _label_t := 0.0
var _color_down := false
var _palette := 0

func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_label.position.y -= 150.0
	_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_label.visible = false
	layer.add_child(_label)

func _cursor() -> bool:
	return ui != null and ui.cursor_mode

func _process(dt: float) -> void:
	_label_t = maxf(0.0, _label_t - dt)
	_label.visible = _label_t > 0.0
	var can: bool = player != null and Game.playing and not Game.dead and not player.dead \
		and not player.frozen and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _cursor()) \
		and SketchMarks.live != null
	var c_down := can and Input.is_physical_key_pressed(KEY_COLOR)
	if c_down and not _color_down and not drawing:
		_palette = (_palette + 1) % SketchMarks.COLORS.size()
		color = SketchMarks.COLORS[_palette]
		if ui != null:
			ui.sync_from_tool()
		_show()
	_color_down = c_down
	var pen_down: bool = can and (Input.is_physical_key_pressed(KEY) \
		or (_cursor() and ui.tool == "marker" and ui.world_lmb))
	var erase_down: bool = can and (Input.is_physical_key_pressed(KEY_ERASE) \
		or (_cursor() and ui.tool == "eraser" and ui.world_lmb))
	if not pen_down:
		if drawing:
			_finish()
		if erase_down:
			_erase()
		return
	_step()

func _erase() -> void:
	var hit := _aim()
	if not hit.is_empty():
		SketchMarks.live.remove_near(hit.position, (hit.normal as Vector3).normalized())

## What the pen points at: through the cursor with the panel open, else the middle of the screen
func _aim() -> Dictionary:
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	if _cursor():
		var m := LensPointer.render_pos(cam.get_viewport())
		from = cam.project_ray_origin(m)
		dir = cam.project_ray_normal(m)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * (CURSOR_REACH if _cursor() else REACH), WORLD_MASK)
	q.exclude = [player.get_rid()]
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or not (hit.collider is StaticBody3D):
		return {}
	return hit

func _step() -> void:
	var hit := _aim()
	if hit.is_empty():
		return
	var p: Vector3 = hit.position
	var n: Vector3 = (hit.normal as Vector3).normalized()
	if not drawing:
		drawing = true
		_pts = [p]
		_n = n
		_pen = {"col": Color(color, opacity), "w": width, "wob": wobble, "style": style, "shape": shape}
		_preview = MeshInstance3D.new()
		_preview.mesh = _mesh
		_preview.material_override = SketchMarks.material()
		_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		SketchMarks.live.add_child(_preview)
		_preview.global_transform = Transform3D.IDENTITY
		_mesh.clear_surfaces()
		_show()
		return
	# stay on the surface the line started on
	if n.dot(_n) < 0.95 or absf(_n.dot(p - _pts[0])) > 0.05:
		return
	if _pen.shape == "line":
		var a: Vector3 = _pts[0]
		var steps := clampi(ceili(a.distance_to(p) / LINE_STEP), 1, MAX_POINTS)
		_pts = [a]
		for i in range(1, steps + 1):
			_pts.append(a.lerp(p, float(i) / steps))
		SketchMarks.ribbon(_pts, _n, _pen, SketchMarks.LIFT + 0.003, Vector3.ZERO, _mesh)
	elif _pts.size() < MAX_POINTS and p.distance_to(_pts[-1]) >= STEP:
		_pts.append(p)
		SketchMarks.ribbon(_pts, _n, _pen, SketchMarks.LIFT + 0.003, Vector3.ZERO, _mesh)

func _finish() -> void:
	drawing = false
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null
	if _pts.size() >= 2 and SketchMarks.live != null:
		SketchMarks.live.add(_pts, _n, _pen)
	_pts = []

func _show() -> void:
	if _cursor():
		return                   # the panel shows the pen
	_label.text = "MARKER: " + SketchMarks.COLOR_NAMES[_palette] + "   (B draw, N colour, X erase, Y tools)"
	_label.add_theme_color_override("font_color", color.lightened(0.25))
	_label_t = 1.6
