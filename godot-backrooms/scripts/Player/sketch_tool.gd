extends Node
## Freehand marker in the hand. Hold B looking at a wall, floor or ceiling within REACH and drag your
## aim across it: the line follows, wobbly like it was drawn by hand, and stays when you let go
## (sketch_marks.gd). N changes the colour, hold X on a line to rub it out. No inventory needed and no limit but MAX_POINTS a line.
## A line can't jump onto another surface: it ends where the surface does. Built by hud.gd.

const SketchMarks := preload("res://scripts/World/props/sketch_marks.gd")

const KEY := KEY_B
const KEY_COLOR := KEY_N
const KEY_ERASE := KEY_X
const REACH := 3.0               # m
const STEP := 0.02               # m between points
const MAX_POINTS := 800
const WORLD_MASK := 1

var player: Node                 # player.gd (set by hud.gd)
var color := 0
var drawing := false
var _pts: Array = []
var _n := Vector3.UP
var _preview: MeshInstance3D
var _mesh := ArrayMesh.new()
var _label: Label
var _label_t := 0.0
var _color_down := false

func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_label.position.y -= 150.0
	_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_label.visible = false
	layer.add_child(_label)

func _process(dt: float) -> void:
	_label_t = maxf(0.0, _label_t - dt)
	_label.visible = _label_t > 0.0
	var can: bool = player != null and Game.playing and not Game.dead and not player.dead \
		and not player.frozen and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and SketchMarks.live != null
	var c_down := can and Input.is_physical_key_pressed(KEY_COLOR)
	if c_down and not _color_down and not drawing:
		color = (color + 1) % SketchMarks.COLORS.size()
		_show()
	_color_down = c_down
	if not (can and Input.is_physical_key_pressed(KEY)):
		if drawing:
			_finish()
		if can and Input.is_physical_key_pressed(KEY_ERASE):
			_erase()
		return
	_step()

func _erase() -> void:
	var hit := _aim()
	if not hit.is_empty():
		SketchMarks.live.remove_near(hit.position, (hit.normal as Vector3).normalized())

func _aim() -> Dictionary:
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from - cam.global_transform.basis.z * REACH, WORLD_MASK)
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
	if n.dot(_n) < 0.95 or absf(_n.dot(p - _pts[0])) > 0.05 or _pts.size() >= MAX_POINTS:
		return
	if p.distance_to(_pts[-1]) >= STEP:
		_pts.append(p)
		SketchMarks.ribbon(_pts, _n, color, SketchMarks.LIFT + 0.003, Vector3.ZERO, _mesh)

func _finish() -> void:
	drawing = false
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null
	if _pts.size() >= 2 and SketchMarks.live != null:
		SketchMarks.live.add(_pts, _n, color)
	_pts = []

func _show() -> void:
	_label.text = "MARKER: " + SketchMarks.COLOR_NAMES[color] + "   (B draw, N colour, X erase)"
	_label.add_theme_color_override("font_color", SketchMarks.COLORS[color].lightened(0.25))
	_label_t = 1.6
