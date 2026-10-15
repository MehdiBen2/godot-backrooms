@tool
class_name UBShapeTool
extends RefCounted
## Interactive shape drawing on the active grid plane. Rect shapes: press and
## drag the base, release, pull the height, click to commit. Poly Shape: click
## points, close via the first point or Enter, pull the height, click to commit.
## Esc cancels and Backspace removes the last poly point. The cursor and sizes
## snap to the grid step. The live preview is an ownerless node under the edited
## scene root, so the scene dock never shows it and it is never saved.

## Append new kinds only: the value is stored in every saved shape_spec.
enum Kind { CUBE, PLANE, CYLINDER, CONE, PRISM, STAIRS, ARCH, POLY, DOOR, SPHERE, TORUS, PIPE, CURVED_STAIRS, TRIM, TRIM_WALLS, WALL }
enum Stage { IDLE, WAIT, DRAG_BASE, PLACE_POINTS, HEIGHT, PLACE_WALLS }

const CLOSE_PX := 14.0
const SIDES := 16
## Trim profiles built from arcs (UBPrimitives.TrimProfile indices for Round,
## Cove and Ogee). Arc Segs and Smooth apply only to these.
const CURVED_PROFILES := [2, 3, 4]

## Adjust-panel schema of the post-commit parameters per shape kind. Kinds not
## listed commit as-is. Defaults come from _default_params, since they depend
## on the drawn size, not from this schema.
const SHAPE_PARAMS := {
	Kind.PLANE: [
		{"key": "div_u", "label": "Divisions U", "type": "int", "min": 1, "max": 32, "step": 1},
		{"key": "div_v", "label": "Divisions V", "type": "int", "min": 1, "max": 32, "step": 1},
	],
	Kind.CYLINDER: [
		{"key": "sides", "label": "Sides", "type": "int", "min": 3, "max": 64, "step": 1},
		{"key": "smooth", "label": "Smooth", "type": "bool"},
	],
	Kind.CONE: [
		{"key": "sides", "label": "Sides", "type": "int", "min": 3, "max": 64, "step": 1},
		{"key": "smooth", "label": "Smooth", "type": "bool"},
	],
	Kind.STAIRS: [

		{"key": "steps", "label": "Steps", "type": "int", "min": 1, "max": 64, "step": 1},
		{"key": "riser", "label": "Riser Height", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},

		{"key": "turn", "label": "Turn", "type": "enum", "options": ["None", "Left", "Right", "U Left", "U Right"]},
		{"key": "split", "label": "Turn After", "type": "int", "min": 0, "max": 63, "step": 1, "requires": {"turn": true}},
		{"key": "flight_w", "label": "Flight Width", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01, "requires": {"turn": true}},
		{"key": "landing", "label": "Landing", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01, "requires": {"turn": true}},
		{"key": "open", "label": "Open Risers", "type": "bool"},
		{"key": "stringer", "label": "Stringer", "type": "float", "min": 0.0, "max": 64.0, "step": 0.01, "requires": {"open": true}},

		{"key": "overhang", "label": "Overhang", "type": "float", "min": 0.0, "max": 64.0, "step": 0.01},
		{"key": "lip", "label": "Lip", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01, "requires": [{"overhang": true}, {"open": true}]},
		{"key": "bevel", "label": "Bevel", "type": "float", "min": 0.0, "max": 64.0, "step": 0.01},
		{"key": "bevel_segs", "label": "Bevel Segs", "type": "int", "min": 1, "max": 8, "step": 1, "requires": {"bevel": true}},
		{"key": "smooth", "label": "Smooth", "type": "bool", "requires": {"bevel": true, "bevel_segs": {"min": 2}}},
	],
	Kind.ARCH: [
		{"key": "radius", "label": "Radius", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
		{"key": "sides", "label": "Arc Segs", "type": "int", "min": 2, "max": 64, "step": 1},
		{"key": "smooth", "label": "Smooth", "type": "bool"},
	],
	Kind.DOOR: [

		{"key": "door_height", "label": "Door Height", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
		{"key": "opening", "label": "Doorway Width", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
		{"key": "arched", "label": "Arched", "type": "bool"},
		{"key": "sides", "label": "Arc Segs", "type": "int", "min": 2, "max": 64, "step": 1, "requires": {"arched": true}},
		{"key": "smooth", "label": "Smooth", "type": "bool", "requires": {"arched": true}},
	],
	Kind.SPHERE: [
		{"key": "subdivisions", "label": "Subdivs", "type": "int", "min": 1, "max": 12, "step": 1},
		{"key": "smooth", "label": "Smooth", "type": "bool"},
	],
	Kind.TORUS: [
		{"key": "tube", "label": "Tube Radius", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
		{"key": "sides", "label": "Ring Segs", "type": "int", "min": 3, "max": 64, "step": 1},
		{"key": "tube_segs", "label": "Tube Segs", "type": "int", "min": 3, "max": 64, "step": 1},
	],
	Kind.PIPE: [
		{"key": "thickness", "label": "Thickness", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
		{"key": "sides", "label": "Sides", "type": "int", "min": 3, "max": 64, "step": 1},
	],
	Kind.CURVED_STAIRS: [
		{"key": "steps", "label": "Steps", "type": "int", "min": 1, "max": 64, "step": 1},
		{"key": "arc", "label": "Arc (°)", "type": "float", "min": 5.0, "max": 355.0, "step": 1.0},
		{"key": "inner", "label": "Inner Radius", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
	],
	Kind.TRIM: [

		{"key": "profile", "label": "Profile", "type": "enum", "options": ["Flat", "Chamfer", "Round", "Cove", "Ogee", "Stepped"]},
		{"key": "depth", "label": "Depth", "type": "float", "min": 0.005, "max": 64.0, "step": 0.005},
		{"key": "height", "label": "Height", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
		{"key": "segs", "label": "Arc Segs", "type": "int", "min": 1, "max": 32, "step": 1, "requires": {"profile": CURVED_PROFILES}},
		{"key": "upright", "label": "On Wall", "type": "bool"},
		{"key": "flip", "label": "Flip Side", "type": "bool"},
		{"key": "invert", "label": "Upside Down", "type": "bool"},
		{"key": "smooth", "label": "Smooth", "type": "bool", "requires": {"profile": CURVED_PROFILES}},
	],
	Kind.TRIM_WALLS: [

		{"key": "profile", "label": "Profile", "type": "enum", "options": ["Flat", "Chamfer", "Round", "Cove", "Ogee", "Stepped"]},
		{"key": "depth", "label": "Depth", "type": "float", "min": 0.005, "max": 64.0, "step": 0.005},
		{"key": "height", "label": "Height", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
		{"key": "segs", "label": "Arc Segs", "type": "int", "min": 1, "max": 32, "step": 1, "requires": {"profile": CURVED_PROFILES}},
		{"key": "placement", "label": "Placement", "type": "enum", "options": ["Bottom", "Top"]},
		{"key": "offset", "label": "Offset", "type": "float", "min": -64.0, "max": 64.0, "step": 0.01},
		{"key": "invert", "label": "Upside Down", "type": "bool"},
		{"key": "smooth", "label": "Smooth", "type": "bool", "requires": {"profile": CURVED_PROFILES}},
	],
	Kind.WALL: [

		{"key": "thickness", "label": "Thickness", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
		{"key": "height", "label": "Height", "type": "float", "min": 0.01, "max": 64.0, "step": 0.01},
		{"key": "side", "label": "Side", "type": "enum", "options": ["Centre", "Left", "Right"]},
	],
}

## Kinds that place their own geometry against the drawing plane and move it
## from the panel (a trim's Placement or Offset), so they skip the base lift
## of _build and build_placed.
const SELF_ANCHORED := [Kind.POLY, Kind.TRIM, Kind.TRIM_WALLS, Kind.WALL]

## Trim depth for a project that has never set one: a 5 cm skirting.
const DEFAULT_TRIM_DEPTH := 0.05

## Doorway for a project that has never drawn a door: a standard interior door
## in world units, whatever the frame's size (the builder clamps it inside a
## smaller frame). Later doors take the last door's values.
const DEFAULT_DOOR_HEIGHT := 2.1
const DEFAULT_DOOR_WIDTH := 0.9

## Params the draw gesture decides, so the remembered values of the last shape
## of that kind never override them (see _default_params): a staircase's step
## count follows the remembered riser and the pulled height, a trim's height is
## the drawn across extent and its orientation comes from the plane and anchor,
## a torus's tube is the pull.
const DRAW_DERIVED := {
	Kind.STAIRS: ["steps"],
	Kind.TRIM: ["height", "upright", "flip"],
	Kind.TORUS: ["tube"],
}

## Default collision per shape kind, applied at commit: convex for solid convex
## primitives, ramp for stairs (a turned layout lays the ramp out per flight
## from its spec, see UBMeshInstance3D), trimesh for concave or hollow kinds
## (arch, door, torus, pipe, poly, curved stairs, where a straight +Z ramp
## wedge would be wrong) and for the flat plane, whose convex hull is
## degenerate.
const SHAPE_COLLISION := {
	Kind.CUBE: UBMeshInstance3D.CollisionMode.CONVEX,
	Kind.PLANE: UBMeshInstance3D.CollisionMode.TRIMESH,
	Kind.CYLINDER: UBMeshInstance3D.CollisionMode.CONVEX,
	Kind.CONE: UBMeshInstance3D.CollisionMode.CONVEX,
	Kind.PRISM: UBMeshInstance3D.CollisionMode.CONVEX,
	Kind.STAIRS: UBMeshInstance3D.CollisionMode.RAMP,
	Kind.ARCH: UBMeshInstance3D.CollisionMode.TRIMESH,
	Kind.POLY: UBMeshInstance3D.CollisionMode.TRIMESH,
	Kind.DOOR: UBMeshInstance3D.CollisionMode.TRIMESH,
	Kind.SPHERE: UBMeshInstance3D.CollisionMode.CONVEX,
	Kind.TORUS: UBMeshInstance3D.CollisionMode.TRIMESH,
	Kind.PIPE: UBMeshInstance3D.CollisionMode.TRIMESH,
	Kind.CURVED_STAIRS: UBMeshInstance3D.CollisionMode.TRIMESH,

	Kind.TRIM: UBMeshInstance3D.CollisionMode.CONVEX,

	Kind.TRIM_WALLS: UBMeshInstance3D.CollisionMode.TRIMESH,

	Kind.WALL: UBMeshInstance3D.CollisionMode.TRIMESH,
}

## Grid cells each arm of the cursor's grid-line highlight spans (see
## _draw_grid_highlight).
const GRID_HIGHLIGHT_STEPS := 8.0

var plugin: EditorPlugin
var kind := Kind.CUBE
var stage := Stage.IDLE

var _u := Vector3.RIGHT
var _v := Vector3(0, 0, 1)
var _n := Vector3.UP
var _basis := Basis()
var _plane := Plane(Vector3.UP, 0)
var _anchor := Vector3.ZERO
var _corner := Vector3.ZERO
var _height := 0.0
var _cursor := Vector3.ZERO

var _free_cursor := Vector3.ZERO
var _poly: Array[Vector3] = []
var _preview: UBMeshInstance3D


var _move_frame := {}


var _hover_loop := PackedVector3Array()
var _hover_on_plane := false

var _hover_node: UBMeshInstance3D
var _hover_face := -1


var _walls: Array = []
var _wall_params := {}


var _wall_closed := false


func _directional_kind() -> bool:
	return kind == Kind.STAIRS or kind == Kind.DOOR or kind == Kind.TRIM


func _two_click_kind() -> bool:
	return kind == Kind.TRIM


func active() -> bool:
	return stage != Stage.IDLE


func begin(new_kind: int) -> void:
	cancel()
	kind = new_kind as Kind
	_setup_plane()
	stage = Stage.WAIT
	if kind == Kind.POLY or kind == Kind.WALL:
		stage = Stage.PLACE_POINTS
	elif kind == Kind.TRIM_WALLS:
		stage = Stage.PLACE_WALLS

		plugin._commit_adjust()
		plugin._ensure_panels_discovered()
		_wall_params = _default_params({})
		if plugin.adjust_panel != null:
			plugin.adjust_panel.show_action("Trim Walls", SHAPE_PARAMS[Kind.TRIM_WALLS], _wall_params)
			plugin._refresh_presets()
			plugin.adjust_panel.visible = true


## Re-capture the drawing plane after the grid changed (axis, offset or step)
## while the tool is armed but not mid-gesture, so clicks land where the grid
## now shows. Once a gesture holds geometry (base drag, height pull, placed
## poly points) the captured plane is kept, since that geometry lies on it.
func refresh_plane() -> void:
	if stage == Stage.WAIT or (stage == Stage.PLACE_POINTS and _poly.is_empty()):
		_setup_plane()
		_cursor = _plane.project(_cursor)


func cancel() -> void:
	_free_preview()
	if stage == Stage.PLACE_WALLS and plugin.adjust_panel != null and plugin.adjust.is_empty():
		plugin.adjust_panel.visible = false
	stage = Stage.IDLE
	_poly.clear()
	_walls.clear()
	_wall_params = {}
	_wall_closed = false
	_height = 0.0
	_move_frame = {}
	_hover_loop = PackedVector3Array()
	_hover_node = null
	_hover_face = -1


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventKey and event.keycode == KEY_SHIFT and not event.echo:

		if stage == Stage.PLACE_POINTS and not _poly.is_empty():
			_apply_axis_lock(event.pressed)
			if kind == Kind.WALL:
				_rebuild_preview()
			plugin.refresh_shape_overlay()
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if event is InputEventKey and event.pressed and not event.echo:

		var drawing: bool = (
			stage == Stage.DRAG_BASE or stage == Stage.HEIGHT
			or (stage == Stage.PLACE_POINTS and not _poly.is_empty())
			or (stage == Stage.PLACE_WALLS and not _walls.is_empty())
		)
		if (
			drawing and event.is_command_or_control_pressed()
			and (event.keycode == KEY_Z or event.keycode == KEY_Y)
		):
			cancel()
			plugin.refresh_shape_overlay()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		match event.keycode:
			KEY_ESCAPE:
				cancel()
				plugin.refresh_shape_overlay()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			KEY_ENTER, KEY_KP_ENTER:
				if stage == Stage.PLACE_POINTS and kind == Kind.WALL:

					if _poly.size() >= 2:
						_wall_closed = false
						_commit()
						plugin.refresh_shape_overlay()
				elif stage == Stage.PLACE_POINTS and _poly.size() >= 3:
					_to_height_stage()
					plugin.refresh_shape_overlay()
				elif stage == Stage.PLACE_WALLS and not _walls.is_empty():
					_commit()
					plugin.refresh_shape_overlay()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			KEY_BACKSPACE:
				if stage == Stage.PLACE_POINTS and not _poly.is_empty():
					_poly.pop_back()
					_rebuild_preview()
					plugin.refresh_shape_overlay()
				elif stage == Stage.PLACE_WALLS and not _walls.is_empty():
					_walls.pop_back()
					_rebuild_preview()
					plugin.refresh_shape_overlay()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion:

		if stage == Stage.WAIT or stage == Stage.PLACE_POINTS or stage == Stage.PLACE_WALLS:
			_update_hover_surface(camera, event.position)
		_update_cursor(camera, event.position, event.shift_pressed)
		match stage:
			Stage.DRAG_BASE:

				if _directional_kind() and not _two_click_kind() \
						and (_cursor - _corner).length_squared() > 1e-10:
					_move_frame = stairs_frame(_u, _v, _n, _cursor - _corner)
				_corner = _cursor
				_rebuild_preview()
			Stage.HEIGHT:
				_height = _height_from_mouse(camera, event.position)
				_rebuild_preview()
			Stage.PLACE_POINTS:

				if kind == Kind.WALL and not _poly.is_empty():
					_rebuild_preview()
		plugin.refresh_shape_overlay()
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_update_cursor(camera, event.position, event.shift_pressed)
			match stage:
				Stage.WAIT:
					_anchor = _cursor
					_corner = _cursor
					_move_frame = {}
					_hover_loop = PackedVector3Array()
					stage = Stage.DRAG_BASE
					_rebuild_preview()
				Stage.PLACE_POINTS:
					if _poly.size() >= 3 and _near_first_point(camera, event.position):
						if kind == Kind.WALL:

							_wall_closed = true
							_commit()
						else:
							_to_height_stage()
					elif _accepts_point(_cursor):
						_poly.append(_cursor)
						_rebuild_preview()
				Stage.PLACE_WALLS:

					if event.double_click:
						if not _walls.is_empty():
							_commit()
					else:
						_update_hover_surface(camera, event.position)
						if _hover_node != null:
							toggle_wall(_hover_node, _hover_face)
				Stage.DRAG_BASE:

					if _two_click_kind() and _cursor.distance_to(_anchor) > 1e-4:
						_corner = _cursor
						_commit()
				Stage.HEIGHT:
					_commit()
			plugin.refresh_shape_overlay()
			return EditorPlugin.AFTER_GUI_INPUT_STOP

		if stage == Stage.DRAG_BASE:
			if _two_click_kind():
				pass
			elif kind == Kind.PLANE or kind == Kind.SPHERE:
				_commit()
			else:
				_to_height_stage()
			plugin.refresh_shape_overlay()
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func draw_overlay(overlay: Control, camera: Camera3D) -> void:
	if camera == null or not active():
		return

	var accent := Color(0.369, 0.918, 0.831)
	match stage:
		Stage.WAIT:
			_draw_grid_highlight(overlay, camera)
			_draw_hover_surface(overlay, camera)
			_draw_marker(overlay, camera, _cursor, accent)
		Stage.DRAG_BASE, Stage.HEIGHT:
			if stage == Stage.DRAG_BASE:
				_draw_grid_highlight(overlay, camera)
			var delta := _corner - _anchor
			var corners := [
				_anchor, _anchor + _u * delta.dot(_u), _corner, _anchor + _v * delta.dot(_v),
			]
			for i in 4:
				_draw_segment(overlay, camera, corners[i], corners[(i + 1) % 4], accent)
			if _directional_kind():
				_draw_direction_arrow(overlay, camera)
			_draw_dims_label(overlay, camera)
		Stage.PLACE_WALLS:
			_draw_hover_surface(overlay, camera)
			for wall in _walls:
				_draw_world_loop(overlay, camera, wall.loop, Color(0.984, 0.749, 0.141, 0.18),
					Color(0.984, 0.749, 0.141, 0.9))
		Stage.PLACE_POINTS:
			_draw_grid_highlight(overlay, camera)
			_draw_hover_surface(overlay, camera)
			for i in _poly.size():
				var closable := i == 0 and _poly.size() >= 3
				_draw_marker(overlay, camera, _poly[i], Color(0.984, 0.749, 0.141) if closable else accent)
				if i > 0:
					_draw_segment(overlay, camera, _poly[i - 1], _poly[i], accent)
			if not _poly.is_empty():
				_draw_segment(overlay, camera, _poly.back(), _cursor, Color(accent, 0.5))
			_draw_marker(overlay, camera, _cursor, accent)

			for i in range(1, _poly.size()):
				_draw_length_label(overlay, camera, _poly[i - 1], _poly[i])
			if not _poly.is_empty():
				_draw_length_label(overlay, camera, _poly.back(), _cursor)


func _current_draw_frame() -> Dictionary:
	if not _move_frame.is_empty():
		return _move_frame
	return stairs_frame(_u, _v, _n, _corner - _anchor)


func _draw_direction_arrow(overlay: Control, camera: Camera3D) -> void:
	var delta := _corner - _anchor
	var frame := _current_draw_frame()
	var amber := Color(0.984, 0.749, 0.141)
	var center := _base_center()
	if kind == Kind.DOOR:
		var axis: Vector3 = _n.cross(frame.dir).normalized()

		var half := maxf(absf(delta.dot(frame.dir)) * 0.25, 0.15)
		var a := center - axis * half
		var b := center + axis * half
		_draw_segment(overlay, camera, a, b, amber)
		var head := half * 0.35
		var side: Vector3 = frame.dir * (head * 0.6)
		_draw_segment(overlay, camera, b, b - axis * head + side, amber)
		_draw_segment(overlay, camera, b, b - axis * head - side, amber)
		_draw_segment(overlay, camera, a, a + axis * head + side, amber)
		_draw_segment(overlay, camera, a, a + axis * head - side, amber)
		return
	var dir: Vector3 = frame.dir
	var run := absf(delta.dot(dir))
	if run < 1e-4:
		return
	var tip := center + dir * (run * 0.35)
	_draw_segment(overlay, camera, center - dir * (run * 0.35), tip, amber)
	var head := maxf(run * 0.12, 0.02)
	var side := _n.cross(dir) * (head * 0.6)
	_draw_segment(overlay, camera, tip, tip - dir * head + side, amber)
	_draw_segment(overlay, camera, tip, tip - dir * head - side, amber)


func _setup_plane() -> void:

	match plugin.toolbar.grid_axis:
		0:
			_n = Vector3.RIGHT
			_u = Vector3(0, 0, 1)
			_v = Vector3.UP
		2:
			_n = Vector3(0, 0, 1)
			_u = Vector3.UP
			_v = Vector3.RIGHT
		_:
			_n = Vector3.UP
			_u = Vector3.RIGHT
			_v = Vector3(0, 0, 1)
	_basis = Basis(_u, _n, _v)
	_plane = Plane(_n, plugin.grid_offset)


func _snap_step() -> float:
	return plugin.toolbar.snap_step if plugin.toolbar.snap_enabled else 0.0


func _update_cursor(camera: Camera3D, pos: Vector2, axis_lock := false) -> void:
	var hit = _plane.intersects_ray(camera.project_ray_origin(pos), camera.project_ray_normal(pos))
	if hit == null:
		return
	var p: Vector3 = hit
	var step := _snap_step()
	if step > 0.0:
		p = _u * snappedf(p.dot(_u), step) + _v * snappedf(p.dot(_v), step) + _n * _plane.d
	_free_cursor = p
	_apply_axis_lock(axis_lock)


func _apply_axis_lock(locked: bool) -> void:
	_cursor = _free_cursor
	if locked and stage == Stage.PLACE_POINTS and not _poly.is_empty():
		_cursor = constrain_to_axis(_poly.back(), _free_cursor, _u, _v)


## Whether a click at `p` adds a corner: not on top of the last one (the
## second press of a double click, or two clicks snapping to one grid point),
## which would leave a zero-length edge and a zero-area side face.
func _accepts_point(p: Vector3) -> bool:
	return _poly.is_empty() or _poly.back().distance_to(p) > 1e-4


## The point on whichever of the two in-plane axes through `from` lies
## closest to `to` (ties go to u).
static func constrain_to_axis(from: Vector3, to: Vector3, u: Vector3, v: Vector3) -> Vector3:
	var delta := to - from
	var du := delta.dot(u)
	var dv := delta.dot(v)
	if absf(du) >= absf(dv):
		return from + u * du
	return from + v * dv


func _to_height_stage() -> void:
	stage = Stage.HEIGHT
	_height = 0.0
	_rebuild_preview()


func _base_center() -> Vector3:
	if kind == Kind.POLY:
		var sum := Vector3.ZERO
		for p in _poly:
			sum += p
		return sum / maxf(1.0, _poly.size())
	return (_anchor + _corner) * 0.5


func _height_from_mouse(camera: Camera3D, pos: Vector2) -> float:
	var o := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var w := _base_center() - o
	var b := _n.dot(dir)
	var denom := 1.0 - b * b
	if absf(denom) < 1e-6:
		return _height
	var t := (b * dir.dot(w) - _n.dot(w)) / denom
	var step := _snap_step()
	return snappedf(t, step) if step > 0.0 else t


func _update_hover_surface(camera: Camera3D, pos: Vector2) -> void:
	_hover_loop = PackedVector3Array()
	_hover_node = null
	_hover_face = -1
	var root := EditorInterface.get_edited_scene_root()
	if root == null or camera == null:
		return
	var best_dist := INF
	var best_node: UBMeshInstance3D = null
	var best_face := -1
	var cam_pos := camera.global_position
	for node: UBMeshInstance3D in root.find_children("*", "UBMeshInstance3D", true, false):
		if node == _preview or not node.visible or node.mesh_data == null:
			continue
		var ray := UBPicking._local_ray(node, camera, pos)
		var data: UBMeshData = node.mesh_data

		var hit: Array = UBRayAccel.build_cached(data).nearest(ray[0], ray[1])
		if hit[0] < 0:
			continue
		var world_hit: Vector3 = node.global_transform * (ray[0] + ray[1] * hit[1])
		var dist := cam_pos.distance_to(world_hit)
		if dist < best_dist:
			best_dist = dist
			best_node = node
			best_face = hit[0]
	var surface_mode: bool = plugin.toolbar != null and plugin.toolbar.draw_on_surface
	var plane_free: bool = (
		stage == Stage.WAIT or (stage == Stage.PLACE_POINTS and _poly.is_empty()))
	if best_node == null:

		if surface_mode and plane_free:
			_setup_plane()
		return
	var data: UBMeshData = best_node.mesh_data
	var face: UBFace = data.faces[best_face]
	var xf := best_node.global_transform
	for vi in face.vertices:
		_hover_loop.append(xf * data.positions[vi])
	var world_normal := (xf.basis * data.face_normal(face)).normalized()
	_hover_node = best_node
	_hover_face = best_face
	if stage == Stage.PLACE_WALLS:

		_hover_on_plane = (world_normal - Vector3.UP * world_normal.dot(Vector3.UP)).length() \
			>= UBTrimPath.WALL_MIN_HORIZONTAL
		return
	if surface_mode and plane_free:

		_apply_surface_plane(world_normal, _hover_loop[0])
		_hover_on_plane = true
		return
	_hover_on_plane = (
		absf(world_normal.dot(_n)) > 0.999
		and absf(_plane.distance_to(_hover_loop[0])) < 0.01
	)


func _apply_surface_plane(normal: Vector3, origin: Vector3) -> void:
	_n = normal
	var ref := Vector3.RIGHT if absf(_n.x) < 0.9 else Vector3.UP
	_u = (ref - _n * ref.dot(_n)).normalized()
	_v = _u.cross(_n)
	_basis = Basis(_u, _n, _v)
	_plane = Plane(_n, origin.dot(_n))
	_cursor = _plane.project(_cursor)


func _near_first_point(camera: Camera3D, pos: Vector2) -> bool:
	var wp := _poly[0]
	if camera.is_position_behind(wp):
		return false
	return camera.unproject_position(wp).distance_to(pos) <= CLOSE_PX


## Stairs ascent frame from an in-plane delta: the delta's dominant axis, with
## its sign. During a draw the delta is the last cursor movement (see
## _stairs_move_frame), so the top of the stairs follows the last drag; the
## anchor to corner displacement is the fallback when no movement was recorded.
## Returns the ascent direction, the node basis (right-handed, local +Z =
## ascent, +Y = plane normal) and whether the draw dims must swap (ascent
## along the u tangent instead of v).
static func stairs_frame(u: Vector3, v: Vector3, n: Vector3, delta: Vector3) -> Dictionary:
	var du := delta.dot(u)
	var dv := delta.dot(v)
	var dir := v * (1.0 if dv >= 0.0 else -1.0)
	var swap := false
	if absf(du) > absf(dv):
		dir = u * (1.0 if du >= 0.0 else -1.0)
		swap = true
	return {"dir": dir, "swap": swap, "basis": Basis(n.cross(dir), n, dir)}


## Trim Walls: apply a parameter edited in the panel before the commit.
func set_wall_param(key: String, value: float) -> void:
	if stage != Stage.PLACE_WALLS:
		return
	_wall_params[key] = value
	_rebuild_preview()


## Trim Walls: add a wall face to the selection, or remove it if it is already
## there. Floors and ceilings (faces whose normal is mostly vertical) are
## refused. Public so it can be driven without a mouse.
func toggle_wall(node: UBMeshInstance3D, face: int) -> void:
	if node == null or node.mesh_data == null or face < 0 or face >= node.mesh_data.faces.size():
		return
	for i in _walls.size():
		if _walls[i].node == node and _walls[i].face == face:
			_walls.remove_at(i)
			_rebuild_preview()
			return
	var data: UBMeshData = node.mesh_data
	var xf := node.global_transform
	if UBTrimPath.wall_segments(data, xf, face, Vector3.UP).is_empty():
		return
	var loop := PackedVector3Array()
	for vi in data.faces[face].vertices:
		loop.append(xf * data.positions[vi])
	_walls.append({"node": node, "face": face, "loop": loop})
	_rebuild_preview()


static func _trim_pivot(data: UBMeshData) -> Vector3:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for p in data.positions:
		lo = lo.min(p)
		hi = hi.max(p)
	return Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)


static func _shift_paths(dims: Dictionary, by: Vector3) -> void:
	for key in ["bottom", "top"]:
		for path in dims.get(key, []):
			var pts: PackedVector3Array = path.points
			for i in pts.size():
				pts[i] += by
			path.points = pts


func _wall_dims(params: Dictionary) -> Dictionary:
	var walls: Array = []
	for w in _walls:
		if not is_instance_valid(w.node) or w.node.mesh_data == null:
			continue
		walls.append({"data": w.node.mesh_data, "xf": w.node.global_transform, "face": w.face})
	var solids: Array = []
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		for node: UBMeshInstance3D in root.find_children("*", "UBMeshInstance3D", true, false):
			if node == _preview or node.mesh_data == null:
				continue
			solids.append({"data": node.mesh_data, "xf": node.global_transform})
	var lift: float = maxf(float(params.get("height", 0.15)), 0.01) * 0.5
	return {
		"bottom": UBTrimPath.paths_from_walls(walls, solids, Vector3.UP, lift, false),
		"top": UBTrimPath.paths_from_walls(walls, solids, Vector3.UP, lift, true),
	}


func _draw_world_loop(overlay: Control, camera: Camera3D, loop: PackedVector3Array,
		fill: Color, line: Color) -> void:
	var clipped := _clip_loop_to_camera(camera, loop)
	if clipped.size() < 3:
		return
	var pts := PackedVector2Array()
	for wp in clipped:
		pts.append(camera.unproject_position(wp))
	if not Geometry2D.triangulate_polygon(pts).is_empty():
		overlay.draw_colored_polygon(pts, fill)
	for i in pts.size():
		overlay.draw_line(pts[i], pts[(i + 1) % pts.size()], line, 2.0, true)


func _build(provisional := false) -> Dictionary:
	if kind == Kind.WALL:
		var pts: Array = _poly.duplicate()

		if provisional and not pts.is_empty() and _cursor.distance_to(pts.back()) > 1e-4:
			pts.append(_cursor)
		if pts.size() < 2:
			return {}
		var params := _default_params({})
		var pivot := Vector3.ZERO
		for p in pts:
			pivot += p
		pivot /= pts.size()
		var packed := PackedVector3Array()
		for p in pts:
			packed.append(p - pivot)
		var dims := {"points": packed, "closed": _wall_closed and pts.size() >= 3, "up": _n}
		var wall := build_shape(kind, dims, params)
		if wall.faces.is_empty():
			return {}
		return {"data": wall, "transform": Transform3D(Basis(), pivot), "dims": dims, "params": params}
	if kind == Kind.TRIM_WALLS:
		if _walls.is_empty():
			return {}
		var wall_params := _wall_params.duplicate() if not _wall_params.is_empty() else _default_params({})
		var wall_dims := _wall_dims(wall_params)
		var trim := build_shape(kind, wall_dims, wall_params)
		if trim.faces.is_empty():
			return {}

		var origin := _trim_pivot(trim)
		_shift_paths(wall_dims, -origin)
		UBOpPivot.translate_all(trim, -origin)
		return {"data": trim, "transform": Transform3D(Basis(), origin), "dims": wall_dims, "params": wall_params}
	if kind == Kind.POLY:
		if _poly.size() < 3:
			return {}
		var origin: Vector3 = _poly[0]
		var pts := PackedVector2Array()
		var inv := _basis.inverse()
		for p in _poly:
			var local := inv * (p - origin)
			pts.append(Vector2(local.x, local.z))

		if UBPrimitives.dedupe_loop(pts, true).size() < 3:
			return {}
		if _height < 0.0:
			origin += _n * _height
		return {
			"data": UBPrimitives.make_polygon_prism(pts, maxf(absf(_height), 0.001)),
			"transform": Transform3D(_basis, origin),
		}
	var dims := _dims()
	var basis := _basis
	if _directional_kind():

		var frame := _current_draw_frame()
		basis = frame.basis
		if frame.swap:
			var tmp: float = dims.su
			dims.su = dims.sv
			dims.sv = tmp
	var params := _default_params(dims)
	var center := _base_center() + _n * (_height * 0.5)
	if kind == Kind.PLANE or kind == Kind.TRIM:
		center = _base_center()
	elif kind == Kind.SPHERE:

		center = _base_center() + _n * (maxf(dims.su, dims.sv) * 0.5)

	var placed := build_shape(kind, dims, params)
	var min_y := stand_on_base(placed)

	var origin := _base_center() if kind == Kind.TORUS else center + basis.y * min_y
	return {
		"data": placed,
		"transform": Transform3D(basis, origin),
		"dims": dims,
		"params": params,
	}


func _dims() -> Dictionary:

	var step := maxf(_snap_step(), 0.05)
	var delta := _corner - _anchor
	return {
		"su": maxf(absf(delta.dot(_u)), step),
		"sv": maxf(absf(delta.dot(_v)), step),
		"ah": maxf(absf(_height), 0.001),
	}


## The plugin's per-project memory key for a kind's last-used parameters.
static func memory_key(shape_kind: int) -> String:
	return "shape_" + str(Kind.keys()[shape_kind]).to_lower()


## The plugin's preset slot for a kind. Trim and Trim Walls sweep the same
## profiles, so they share one list (each applies the keys it has: a Trim
## Walls preset's Placement/Offset mean nothing to a drawn strip). Last-used
## memory stays per kind (memory_key).
static func preset_key(shape_kind: int) -> String:
	if shape_kind == Kind.TRIM_WALLS:
		return memory_key(Kind.TRIM)
	return memory_key(shape_kind)


func _default_params(dims: Dictionary) -> Dictionary:
	var params := _base_params(dims)
	var mem = plugin.action_options.get(memory_key(kind), {}) if plugin != null else {}
	if mem is Dictionary:
		var skip: Array = DRAW_DERIVED.get(kind, [])
		for spec in SHAPE_PARAMS.get(kind, []):
			var key: String = spec.key
			if mem.has(key) and not skip.has(key):
				params[key] = mem[key]
	if kind == Kind.STAIRS:
		var riser := float(params.get("riser", 0.0))
		if riser > 0.0:
			params["steps"] = clampi(roundi(dims.ah / riser), 1, 64)
	return params


func _base_params(dims: Dictionary) -> Dictionary:
	match kind:
		Kind.PLANE:
			return {"div_u": 1, "div_v": 1}
		Kind.CYLINDER, Kind.CONE:
			return {"sides": SIDES, "smooth": 0.0}
		Kind.STAIRS:

			var step := maxf(plugin.toolbar.snap_step, 0.05)
			var steps := clampi(roundi(dims.sv / step), 1, 64)

			var riser: float = dims.ah / steps

			var half := minf(dims.su, dims.sv) * 0.5
			return {"steps": steps, "riser": riser,
				"turn": 0, "split": 0, "flight_w": half, "landing": half,
				"open": 0.0, "stringer": 0.0,
				"overhang": 0.0, "lip": 0.1, "bevel": 0.0, "bevel_segs": 1, "smooth": 1.0}
		Kind.ARCH:
			return {"radius": dims.sv * 0.4, "sides": 8, "smooth": 0.0}
		Kind.DOOR:
			return {"door_height": DEFAULT_DOOR_HEIGHT, "opening": DEFAULT_DOOR_WIDTH,
				"arched": 0.0, "sides": 8, "smooth": 0.0}
		Kind.SPHERE:

			return {"subdivisions": 4, "smooth": 1.0}
		Kind.TORUS:
			var extent: float = maxf(dims.su, dims.sv) * 0.5
			var tube: float = dims.ah * 0.5 if dims.ah > 0.01 else extent * 0.25
			return {"tube": tube, "sides": 24, "tube_segs": 12}
		Kind.PIPE:
			return {"thickness": maxf(dims.su, dims.sv) * 0.125, "sides": SIDES}
		Kind.CURVED_STAIRS:
			return {"steps": 8, "arc": 90.0, "inner": maxf(dims.su, dims.sv) * 0.4}
		Kind.TRIM:

			var upright := absf(_n.y) < 0.7
			var across: Vector3 = _current_draw_frame().basis.x
			var flip := across.dot(Vector3.UP) < 0.0 if upright \
				else (_anchor - _base_center()).dot(across) > 0.0
			return {"profile": UBPrimitives.TrimProfile.CHAMFER,
				"depth": DEFAULT_TRIM_DEPTH, "height": dims.su,
				"segs": 6, "upright": 1.0 if upright else 0.0,
				"flip": 1.0 if flip else 0.0, "invert": 0.0, "smooth": 1.0}
		Kind.TRIM_WALLS:

			return {"profile": UBPrimitives.TrimProfile.CHAMFER,
				"depth": DEFAULT_TRIM_DEPTH, "height": 0.15, "segs": 6,
				"placement": 0, "offset": 0.0, "invert": 0.0, "smooth": 1.0}
		Kind.WALL:

			return {"thickness": 0.2, "height": 2.0, "side": 0}
	return {}


## Pure parametric builder shared by the draw preview and the post-commit
## adjust session: kind + draw dims {su, sv, ah} + params -> UBMeshData.
## Values are clamped so any panel input yields valid geometry.
static func build_shape(shape_kind: int, dims: Dictionary, params := {}) -> UBMeshData:
	var su: float = dims.get("su", 1.0)
	var sv: float = dims.get("sv", 1.0)
	var ah: float = dims.get("ah", 1.0)
	match shape_kind:
		Kind.PLANE:
			return UBPrimitives.make_plane(Vector2(su, sv), Vector2i(
				clampi(int(params.get("div_u", 1)), 1, 32),
				clampi(int(params.get("div_v", 1)), 1, 32)))
		Kind.CYLINDER:
			return UBPrimitives.make_cylinder(maxf(su, sv) * 0.5, ah,
				clampi(int(params.get("sides", SIDES)), 3, 64),
				bool(params.get("smooth", false)))
		Kind.CONE:
			return UBPrimitives.make_cone(maxf(su, sv) * 0.5, ah,
				clampi(int(params.get("sides", SIDES)), 3, 64),
				bool(params.get("smooth", false)))
		Kind.PRISM:
			return UBPrimitives.make_prism(Vector3(su, ah, sv))
		Kind.STAIRS:

			return UBPrimitives.make_stairs(Vector3(su, ah, sv),
				clampi(int(params.get("steps", 4)), 1, 64),
				maxf(float(params.get("overhang", 0.0)), 0.0),
				maxf(float(params.get("lip", 0.1)), 0.001),
				maxf(float(params.get("bevel", 0.0)), 0.0),
				clampi(int(params.get("bevel_segs", 1)), 1, 8),
				bool(params.get("smooth", true)),
				{
					"turn": clampi(int(params.get("turn", 0)), 0, UBPrimitives.StairTurn.size() - 1),
					"split": clampi(int(params.get("split", 0)), 0, 63),
					"flight_w": maxf(float(params.get("flight_w", minf(su, sv) * 0.5)), 0.0),
					"landing": maxf(float(params.get("landing", minf(su, sv) * 0.5)), 0.0),
					"open": bool(params.get("open", false)),
					"stringer": maxf(float(params.get("stringer", 0.0)), 0.0),
				})
		Kind.ARCH:

			var r_hi := minf(ah, sv * 0.5) * 0.95
			var radius := clampf(float(params.get("radius", sv * 0.4)), minf(0.01, r_hi), r_hi)
			return UBPrimitives.make_arch(sv, ah, su, radius,
				clampi(int(params.get("sides", 8)), 2, 64),
				bool(params.get("smooth", false)))
		Kind.DOOR:

			var ped: float = ah - float(params.get("door_height", DEFAULT_DOOR_HEIGHT))
			var side: float = (sv - float(params.get("opening", DEFAULT_DOOR_WIDTH))) * 0.5
			return UBPrimitives.make_door(sv, ah, su,
				clampf(ped, 0.01, ah * 0.95),
				clampf(side, 0.01, sv * 0.5 * 0.95),
				bool(params.get("arched", false)),
				clampi(int(params.get("sides", 8)), 2, 64),
				bool(params.get("smooth", false)))
		Kind.SPHERE:

			return UBPrimitives.make_sphere(maxf(su, sv) * 0.5,
				clampi(int(params.get("subdivisions", 4)), 1, 12),
				bool(params.get("smooth", true)))
		Kind.TORUS:
			var extent := maxf(su, sv) * 0.5
			var tube := clampf(float(params.get("tube", extent * 0.25)), 0.001, extent * 0.45)
			return UBPrimitives.make_torus(extent - tube, tube,
				clampi(int(params.get("sides", 24)), 3, 64),
				clampi(int(params.get("tube_segs", 12)), 3, 64))
		Kind.PIPE:
			var radius := maxf(su, sv) * 0.5
			var thickness := clampf(float(params.get("thickness", radius * 0.25)), 0.001, radius * 0.95)
			return UBPrimitives.make_pipe(radius, radius - thickness, ah,
				clampi(int(params.get("sides", SIDES)), 3, 64))
		Kind.CURVED_STAIRS:

			var outer := maxf(su, sv)
			return UBPrimitives.fit_xz(UBPrimitives.make_curved_stairs(
				clampf(float(params.get("inner", outer * 0.4)), 0.001, outer * 0.95),
				outer, ah,
				clampi(int(params.get("steps", 8)), 1, 64),
				clampf(float(params.get("arc", 90.0)), 5.0, 355.0)), outer)
		Kind.TRIM:
			var upright := bool(params.get("upright", false))
			return UBPrimitives.make_trim(sv, su,
				maxf(float(params.get("depth", DEFAULT_TRIM_DEPTH)), 0.001),
				maxf(float(params.get("height", su)), 0.001),
				clampi(int(params.get("profile", UBPrimitives.TrimProfile.CHAMFER)), 0,
					UBPrimitives.TrimProfile.size() - 1),
				clampi(int(params.get("segs", 6)), 1, 32),
				upright, bool(params.get("flip", false)), bool(params.get("invert", false)),
				bool(params.get("smooth", true)))
		Kind.TRIM_WALLS:

			var hang := int(params.get("placement", 0)) == 1
			var paths: Array = dims.get("top" if hang else "bottom", [])
			var out := UBMeshData.new()
			for path in paths:
				var piece := UBPrimitives.make_trim_path(path.points, path.normals, bool(path.closed),
					Vector3.UP,
					maxf(float(params.get("depth", DEFAULT_TRIM_DEPTH)), 0.001),
					maxf(float(params.get("height", 0.15)), 0.001),
					clampi(int(params.get("profile", UBPrimitives.TrimProfile.CHAMFER)), 0,
						UBPrimitives.TrimProfile.size() - 1),
					clampi(int(params.get("segs", 6)), 1, 32),
					hang, bool(params.get("invert", false)),
					float(params.get("offset", 0.0)), bool(params.get("smooth", true)))
				UBOpMergeObjects.apply(out, piece, Transform3D.IDENTITY)
			return out
		Kind.WALL:

			var raw: PackedVector3Array = dims.get("points", PackedVector3Array())
			var up: Vector3 = dims.get("up", Vector3.UP)
			var closed := bool(dims.get("closed", false))
			var pts := PackedVector3Array()
			for p in raw:
				if pts.is_empty() or pts[pts.size() - 1].distance_to(p) > 1e-4:
					pts.append(p)
			if closed and pts.size() > 1 and pts[0].distance_to(pts[pts.size() - 1]) <= 1e-4:
				pts.remove_at(pts.size() - 1)
			if pts.size() < 2 or (closed and pts.size() < 3):
				return UBMeshData.new()
			var thickness := maxf(float(params.get("thickness", 0.2)), 0.001)
			var seg_count := pts.size() if closed else pts.size() - 1
			var normals := PackedVector3Array()
			for i in seg_count:
				var d := (pts[(i + 1) % pts.size()] - pts[i]).normalized()
				normals.append(d.cross(up).normalized())
			var side := clampi(int(params.get("side", 0)), 0, 2)
			var out_offset := -thickness * 0.5 if side == 0 else (-thickness if side == 1 else 0.0)
			var height := maxf(float(params.get("height", 2.0)), 0.001)

			var runs := wall_runs(pts, normals, closed,
				maxf(absf(out_offset), absf(thickness + out_offset)))
			if runs.size() == 1:
				return UBPrimitives.make_trim_path(pts, normals, closed, up, thickness, height,
					UBPrimitives.TrimProfile.FLAT, 1, false, false, 0.0, false, out_offset, false)
			var merged := UBMeshData.new()
			for run in runs:
				UBOpMergeObjects.apply(merged, UBPrimitives.make_trim_path(run.points, run.normals,
					false, up, thickness, height, UBPrimitives.TrimProfile.FLAT, 1, false, false,
					0.0, false, out_offset, false), Transform3D.IDENTITY)
			return merged
	return UBPrimitives.make_cube(Vector3(su, ah, sv))


## A wall's corners split into runs that each sweep cleanly. A corner turning
## back on itself has no usable mitre: at an exact retrace there is none at
## all, and close to one the mitre spike reaches past the neighbouring corner
## (its reach along the wall, `width` times the mitre's along-line component,
## exceeds an adjacent segment), so the rings cross and the solid turns inside
## out. The run is cut there instead, each side ending in a square cap, the
## same answer UBTrimPath.chain gives a fold-back. Runs are open, {points,
## normals}; a closed loop with a fold opens at its first one. A clean wall
## comes back as the one run it was, closed or not.
static func wall_runs(pts: PackedVector3Array, normals: PackedVector3Array, closed: bool,
		width: float) -> Array:
	var n := pts.size()
	var seg_count := n if closed else n - 1
	var folds: Array[int] = []
	for i in (range(n) if closed else range(1, n - 1)):
		var n0: Vector3 = normals[(i - 1 + seg_count) % seg_count]
		var n1: Vector3 = normals[i % seg_count]
		var prev: Vector3 = pts[(i - 1 + n) % n]
		var next: Vector3 = pts[(i + 1) % n]
		var d := 1.0 + n0.dot(n1)
		if d <= 1e-4:
			folds.append(i)
			continue
		var dir_in := (pts[i] - prev).normalized()
		var reach := absf(((n0 + n1) / d).dot(dir_in)) * width
		if reach >= minf(pts[i].distance_to(prev), pts[i].distance_to(next)):
			folds.append(i)
	if folds.is_empty():
		return [{"points": pts, "normals": normals}]

	var seq_pts := PackedVector3Array()
	var seq_ns := PackedVector3Array()
	var cuts: Array[int] = []
	if closed:
		var s: int = folds[0]
		for k in n + 1:
			seq_pts.append(pts[(s + k) % n])
		for k in n:
			seq_ns.append(normals[(s + k) % n])
		for f in folds:
			var k := (f - s + n) % n
			if k > 0:
				cuts.append(k)
	else:
		seq_pts = pts
		seq_ns = normals
		cuts = folds
	cuts.append(seq_pts.size() - 1)
	var runs: Array = []
	var start := 0
	for c in cuts:
		runs.append({"points": seq_pts.slice(start, c + 1), "normals": seq_ns.slice(start, c)})
		start = c
	return runs


## Keep Steps and Riser Height agreeing after one of them was edited: a riser
## edit sets the count (as many risers of that height as fit the drawn rise),
## a count edit reports the riser it gives. The typed riser is kept as typed,
## not rounded back. The mesh is always built from Steps.
static func derive_stairs_params(dims: Dictionary, values: Dictionary, changed_key: String) -> void:
	var ah: float = dims.get("ah", 1.0)
	if changed_key == "riser":
		var riser := maxf(float(values.get("riser", 0.0)), 0.001)
		values["steps"] = clampi(roundi(ah / riser), 1, 64)
	else:
		values["riser"] = ah / maxf(float(values.get("steps", 1)), 1.0)


## Lift a freshly built primitive so its lowest point sits at local y = 0.
## Returns the old minimum y (the lift's negative), or 0 when nothing moved.
static func stand_on_base(data: UBMeshData) -> float:
	if data == null or data.positions.is_empty():
		return 0.0
	var min_y := INF
	for p in data.positions:
		min_y = minf(min_y, p.y)
	if absf(min_y) < 1e-9:
		return 0.0
	UBOpPivot.translate_all(data, Vector3(0.0, -min_y, 0.0))
	return min_y


## build_shape plus the base lift a committed shape carries (its spec's
## "base"), so a rebuild lands where the mesh already is.
static func build_placed(shape_kind: int, dims: Dictionary, params: Dictionary, base: bool) -> UBMeshData:
	var data := build_shape(shape_kind, dims, params)
	if base:
		stand_on_base(data)
	return data


## The mesh's shape_spec while its parameters are still live: the data was
## drawn as a parametric shape and still matches what that spec builds.
## Empty otherwise. Once the mesh has been edited (a vertex moved, a face
## extruded or painted, the transform frozen into the vertices) a rebuild
## would throw that work away, so the shape counts as baked. Material
## assignment is the one exception; see UBMeshData.same_shape.
##
## Costs one primitive build per call, so do not run it per frame.
static func editable_spec(data: UBMeshData) -> Dictionary:
	if data == null or data.shape_spec.is_empty():
		return {}
	var spec := data.shape_spec
	var kind_id := int(spec.get("kind", -1))
	if not SHAPE_PARAMS.has(kind_id):
		return {}
	var dims: Dictionary = spec.get("dims", {})
	var params: Dictionary = spec.get("params", {})
	if not data.same_shape(build_placed(kind_id, dims, params, bool(spec.get("base", false)))):
		return {}
	return spec


## Adjust-panel title for a shape kind ("Adjust Stairs").
static func shape_title(shape_kind: int) -> String:
	return "Adjust " + str(Kind.keys()[shape_kind]).capitalize()


func _rebuild_preview() -> void:
	var result := _build(true)
	if result.is_empty():
		if is_instance_valid(_preview):
			_preview.mesh_data = null
		return
	if not is_instance_valid(_preview):
		var root := EditorInterface.get_edited_scene_root()
		if root == null:
			return
		_preview = UBMeshInstance3D.new()
		_preview.name = "_UBShapePreview"
		_preview.live_uv2 = false
		root.add_child(_preview)
	plugin.apply_default_material(result.data)
	_preview.global_transform = result.transform
	_preview.mesh_data = result.data


func _commit() -> void:
	var result := _build()
	var root := EditorInterface.get_edited_scene_root()
	if result.is_empty() or root == null:
		cancel()
		return

	if (
		plugin._demo_node_wall("Adding a shape")
		or plugin._demo_face_wall(0, result.data.faces.size(), "Drawing this shape")
	):
		cancel()
		return
	_free_preview()

	plugin._commit_adjust()
	plugin.apply_default_material(result.data)
	if plugin.toolbar != null:
		plugin.toolbar.set_last_shape(kind)
		plugin._save_grid_settings()

	var params: Array = SHAPE_PARAMS.get(kind, [])
	var dims: Dictionary = result.get("dims", {})
	var defaults: Dictionary = result.get("params", {})
	var title := shape_title(kind)

	if not params.is_empty():
		result.data.shape_spec = {
			"kind": kind, "dims": dims.duplicate(), "params": defaults.duplicate(),
			"base": not (kind in SELF_ANCHORED),
		}
	var node := UBMeshInstance3D.new()
	node.name = "UB" + str(Kind.keys()[kind]).capitalize()
	node.mesh_data = result.data
	node.collision_mode = SHAPE_COLLISION.get(kind, UBMeshInstance3D.CollisionMode.NONE)
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	ur.create_action("Add Unibuilder Shape")
	ur.add_do_method(root, "add_child", node, true)
	ur.add_do_method(node, "set_owner", root)
	ur.add_do_reference(node)
	ur.add_undo_method(root, "remove_child", node)
	ur.commit_action()
	node.global_transform = result.transform
	stage = Stage.IDLE
	_poly.clear()
	_walls.clear()
	_wall_params = {}
	_wall_closed = false
	_height = 0.0

	var esel := EditorInterface.get_selection()
	esel.clear()
	esel.add_node(node)

	if not params.is_empty():
		plugin.begin_shape_adjust(node, kind, dims, params, defaults, title, not (kind in SELF_ANCHORED))


func _free_preview() -> void:
	if is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null


func _draw_hover_surface(overlay: Control, camera: Camera3D) -> void:
	if _hover_loop.size() < 3:
		return

	var clipped := _clip_loop_to_camera(camera, _hover_loop)
	if clipped.size() < 3:
		return
	var pts := PackedVector2Array()
	for wp in clipped:
		pts.append(camera.unproject_position(wp))
	if _hover_on_plane:

		if not Geometry2D.triangulate_polygon(pts).is_empty():
			overlay.draw_colored_polygon(pts, Color(0.369, 0.918, 0.831, 0.10))
		for i in pts.size():
			overlay.draw_line(pts[i], pts[(i + 1) % pts.size()], Color(0.369, 0.918, 0.831, 0.7), 2.0, true)
	else:
		for i in pts.size():
			overlay.draw_line(pts[i], pts[(i + 1) % pts.size()], Color(0.984, 0.749, 0.141, 0.55), 1.5, true)


func _clip_loop_to_camera(camera: Camera3D, loop: PackedVector3Array) -> PackedVector3Array:
	var fwd := -camera.global_transform.basis.z
	var near_plane := Plane(fwd, camera.global_position + fwd * maxf(camera.near * 2.0, 0.01))
	var out := PackedVector3Array()
	var n := loop.size()
	for i in n:
		var a := loop[i]
		var b := loop[(i + 1) % n]
		var da := near_plane.distance_to(a)
		var db := near_plane.distance_to(b)
		if da >= 0.0:
			out.append(a)
		if (da >= 0.0) != (db >= 0.0):
			out.append(a + (b - a) * (da / (da - db)))
	return out


func _draw_grid_highlight(overlay: Control, camera: Camera3D) -> void:
	var step := _snap_step()
	if step <= 0.0:
		return

	var extent := maxf(step * GRID_HIGHLIGHT_STEPS, camera.global_position.distance_to(_cursor) * 0.3)
	var color := Color(0.369, 0.918, 0.831, 0.85)
	for dir: Vector3 in [_u, -_u, _v, -_v]:
		_draw_fading_ray(overlay, camera, _cursor, dir, extent, color)


func _draw_fading_ray(overlay: Control, camera: Camera3D, from: Vector3, dir: Vector3,
		length: float, color: Color) -> void:
	var fwd := -camera.global_transform.basis.z
	var near_plane := Plane(fwd, camera.global_position + fwd * maxf(camera.near * 2.0, 0.01))
	var d_from := near_plane.distance_to(from)
	if d_from <= 0.0:
		return
	var to := from + dir * length
	var shown := 1.0
	var d_to := near_plane.distance_to(to)
	if d_to < 0.0:
		shown = d_from / (d_from - d_to)
		to = from + dir * (length * shown)
	var pts := PackedVector2Array([camera.unproject_position(from), camera.unproject_position(to)])
	var colors := PackedColorArray([color, Color(color, color.a * (1.0 - shown))])
	overlay.draw_polyline_colors(pts, colors, 2.0, true)


func _draw_marker(overlay: Control, camera: Camera3D, world: Vector3, color: Color) -> void:
	if camera.is_position_behind(world):
		return
	var p := camera.unproject_position(world)
	overlay.draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)), color, false, 2.0)


func _draw_segment(overlay: Control, camera: Camera3D, a: Vector3, b: Vector3, color: Color) -> void:

	var fwd := -camera.global_transform.basis.z
	var near_plane := Plane(fwd, camera.global_position + fwd * maxf(camera.near * 2.0, 0.01))
	var da := near_plane.distance_to(a)
	var db := near_plane.distance_to(b)
	if da < 0.0 and db < 0.0:
		return
	if da < 0.0:
		a = a + (b - a) * (da / (da - db))
	elif db < 0.0:
		b = b + (a - b) * (db / (db - da))
	overlay.draw_line(camera.unproject_position(a), camera.unproject_position(b), color, 2.0, true)


func _draw_length_label(overlay: Control, camera: Camera3D, a: Vector3, b: Vector3) -> void:
	var length := a.distance_to(b)
	if length < 1e-4 or camera.is_position_behind(a) or camera.is_position_behind(b):
		return
	var sa := camera.unproject_position(a)
	var sb := camera.unproject_position(b)
	var along := sb - sa
	if along.length() < 24.0:
		return
	var font := overlay.get_theme_font("font", "Label")
	var size := overlay.get_theme_font_size("font_size", "Label")
	var text := "%.2f" % length
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	var normal := Vector2(-along.y, along.x).normalized()

	if normal.y > 0.0:
		normal = -normal
	var centre := (sa + sb) * 0.5 + normal * (text_size.y * 0.5 + 6.0)
	var pos := centre + Vector2(-text_size.x * 0.5, text_size.y * 0.5 - font.get_descent(size))
	overlay.draw_string(font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.8))
	overlay.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color.WHITE)


func _draw_dims_label(overlay: Control, camera: Camera3D) -> void:
	if camera.is_position_behind(_cursor):
		return
	var delta := _corner - _anchor
	var text := "%.2f x %.2f" % [absf(delta.dot(_u)), absf(delta.dot(_v))]
	if stage == Stage.HEIGHT:
		text += "  h %.2f" % _height
	var font := overlay.get_theme_font("font", "Label")
	var size := overlay.get_theme_font_size("font_size", "Label")
	var pos := camera.unproject_position(_cursor) + Vector2(14, -10)
	overlay.draw_string(font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.8))
	overlay.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color.WHITE)
