extends Node
## 3D Equipment Cable Tool.
## In dev builds and level editor test launches:
##  - Draw tools panel (draw_ui.gd, Y): CABLE tool draws 3D cables directly with the mouse pen.
##  - First-person dev mode: hold U on floors or walls to unspool and lay 3D cables while walking.
## Cables are permanent 3D meshes that roll, loop, and stack realistically in 3D piles.

const CableMarks := preload("res://scripts/World/props/cable_marks.gd")
const LensPointer := preload("res://scripts/UI/hud/lens_pointer.gd")

const KEY := KEY_U
const REACH := 5.0               # m reach in first-person
const CURSOR_REACH := 400.0      # m reach with cursor mode in draw_ui
const STEP := 0.035              # m between cable sample points
const LINE_STEP := 0.04
const MAX_POINTS := 800
const WORLD_MASK := 1

var player: Node                 # player.gd (set by hud.gd)
var ui                           # draw_ui.gd

# Settings (edited by draw_ui panel or defaults)
var cable_type := "random"       # "random" or one of CableMarks.TYPE_KEYS
var radius := 0.035              # m (3.5 cm)
var roll_slack := 0.6            # 0..1 roll waviness and slack
var stack_mult := 1.25           # stacking factor
var shape := "freehand"          # "freehand" or "line"

var drawing := false
var ui_down := false             # set by draw_ui.gd when world LMB is held on cable tool

var _pts: Array = []
var _normals: Array = []
var _resolved_type := "heavy_black"
var _drawn_length := 0.0
var _preview: MeshInstance3D
var _mesh := ArrayMesh.new()
var _label: Label
var _label_t := 0.0
var _prev_down := false

func _ready() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 55
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
		and not player.frozen and player.lens_up <= 0.0 and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _cursor()) \
		and CableMarks.live != null

	var key_pressed: bool = Input.is_physical_key_pressed(KEY) or Input.is_key_pressed(KEY)
	var ui_active: bool = _cursor() and ui.tool == "cable" and ui.world_lmb
	var is_down: bool = can and (key_pressed or ui_active or ui_down)

	if not is_down:
		if drawing:
			_finish()
		_prev_down = false
		return

	if not _prev_down and not _cursor():
		_show()
	_prev_down = true

	_step()

func _aim() -> Dictionary:
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	if _cursor():
		var m := LensPointer.render_pos(cam.get_viewport())
		from = cam.project_ray_origin(m)
		dir = cam.project_ray_normal(m)
	var reach := CURSOR_REACH if _cursor() else REACH
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * reach, WORLD_MASK)
	q.exclude = [player.get_rid()]
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
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
		_drawn_length = 0.0
		_resolved_type = cable_type
		if _resolved_type == "random" or not CableMarks.TYPES.has(_resolved_type):
			_resolved_type = CableMarks.TYPE_KEYS[randi() % CableMarks.TYPE_KEYS.size()]

		# Offset initial point off surface by cable radius with contact clearance
		var p_start := p + n * (radius * 1.05)
		_pts = [p_start]
		_normals = [n]

		_preview = MeshInstance3D.new()
		_preview.mesh = _mesh
		_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		CableMarks.live.add_child(_preview)
		_preview.global_transform = Transform3D.IDENTITY
		_update_preview()
		return

	# Handle line mode vs freehand mode
	if shape == "line":
		var a: Vector3 = _pts[0]
		var line_dir := p - a
		var dist := line_dir.length()
		var steps := clampi(ceili(dist / LINE_STEP), 1, MAX_POINTS)
		_pts = [a]
		_normals = [_normals[0]]
		var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
		var sag_depth := minf(dist * 0.08 * roll_slack, 0.8)
		for i in range(1, steps + 1):
			var frac := float(i) / float(steps)
			var cur_p := a.lerp(p, frac)
			var cur_n := Vector3.UP
			# Raycast vertically down onto scene floor, obstacles, crates, tables
			var q_down := PhysicsRayQueryParameters3D.create(cur_p + Vector3.UP * 0.4, cur_p - Vector3.UP * 2.5, WORLD_MASK)
			q_down.exclude = [player.get_rid()]
			var r_hit: Dictionary = space.intersect_ray(q_down)
			if not r_hit.is_empty():
				cur_p = r_hit.position
				cur_n = (r_hit.normal as Vector3).normalized()
			else:
				# Natural physical catenary gravity sag in mid-air
				var catenary_sag := 4.0 * frac * (1.0 - frac) * sag_depth
				cur_p.y -= catenary_sag

			var stack_elev := CableMarks.get_stack_elevation(cur_p, cur_n, radius) * stack_mult
			stack_elev = clampf(stack_elev, 0.0, radius * 2.2)
			cur_p += cur_n * (radius * 1.05 + stack_elev)
			_pts.append(cur_p)
			_normals.append(cur_n)
		_update_preview()
	else:
		# Freehand mode: add point when dragged past STEP
		var last_p: Vector3 = _pts[-1]
		var last_n: Vector3 = _normals[-1]
		var dist_to_last := p.distance_to(last_p)
		if dist_to_last >= STEP and _pts.size() < MAX_POINTS:
			var substeps := clampi(int(dist_to_last / STEP), 1, 10)
			var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
			for s_idx in range(1, substeps + 1):
				var frac := float(s_idx) / float(substeps)
				var target_x := lerpf(last_p.x, p.x, frac)
				var target_z := lerpf(last_p.z, p.z, frac)

				# Find where the surface / floor is at (target_x, target_z)
				var check_y := maxf(last_p.y, p.y) + 0.3
				var q_down := PhysicsRayQueryParameters3D.create(
					Vector3(target_x, check_y, target_z),
					Vector3(target_x, check_y - 3.0, target_z),
					WORLD_MASK
				)
				q_down.exclude = [player.get_rid()]
				var floor_hit: Dictionary = space.intersect_ray(q_down)

				var cur_p: Vector3
				var cur_n: Vector3

				var dist_xz_to_target := Vector2(p.x - target_x, p.z - target_z).length()
				var is_elevated_target := (p.y - last_p.y) > 0.15 or absf(n.y) < 0.5

				if not floor_hit.is_empty():
					var f_pos: Vector3 = floor_hit.position
					var f_norm: Vector3 = (floor_hit.normal as Vector3).normalized()
					if is_elevated_target and dist_xz_to_target < 0.25:
						# Within connection distance of elevated prop / socket: rise up smoothly
						var rise_t := 1.0 - clampf(dist_xz_to_target / 0.25, 0.0, 1.0)
						rise_t = rise_t * rise_t # Smooth ease-in curve
						cur_p = Vector3(target_x, lerpf(f_pos.y, p.y, rise_t), target_z)
						cur_n = f_norm.lerp(n, rise_t).normalized()
					else:
						# Hug the floor
						cur_p = f_pos
						cur_n = f_norm
				else:
					# In air: interpolate smoothly with natural gravity catenary droop
					var air_p := last_p.lerp(p, frac)
					var catenary_sag := 4.0 * frac * (1.0 - frac) * minf(dist_to_last * 0.12 * roll_slack, 0.8)
					air_p.y -= catenary_sag
					cur_p = air_p
					cur_n = last_n.lerp(n, frac).normalized()

				# 1. Stack elevation over existing placed cables (strictly clamped)
				var stack_elev := CableMarks.get_stack_elevation(cur_p, cur_n, radius) * stack_mult
				stack_elev = clampf(stack_elev, 0.0, radius * 2.2)

				# 2. Self-stacking over earlier segments of active stroke
				var pt_count := _pts.size()
				if pt_count > 12:
					for j in range(0, pt_count - 10):
						var sa: Vector3 = _pts[j]
						var sb: Vector3 = _pts[j + 1]
						var seg := sb - sa
						var l2 := seg.length_squared()
						if l2 < 0.0001:
							continue
						var t_proj := clampf((cur_p - sa).dot(seg) / l2, 0.0, 1.0)
						var proj_pt := sa + seg * t_proj
						var horiz_d := Vector2(cur_p.x - proj_pt.x, cur_p.z - proj_pt.z).length()
						if horiz_d < (radius * 2.0):
							var self_stack := clampf(radius * 1.8, 0.0, radius * 2.2)
							if self_stack > stack_elev:
								stack_elev = self_stack

				# 3. Natural rolling waviness: realistic, gentle low-frequency lateral unspool slack
				var step_len: float = (cur_p - _pts[-1]).length()
				_drawn_length += step_len
				var wave := sin(_drawn_length * 3.6) * roll_slack * (radius * 0.32) + sin(_drawn_length * 1.8 + 0.9) * roll_slack * (radius * 0.16)
				var forward_vec: Vector3 = (cur_p - _pts[-1]).normalized()
				if forward_vec.length_squared() < 0.01:
					forward_vec = Vector3.FORWARD
				var side_dir := cur_n.cross(forward_vec).normalized()
				if side_dir.length_squared() < 0.01:
					side_dir = Vector3.RIGHT

				var final_p := cur_p + cur_n * (radius * 1.05 + stack_elev) + side_dir * wave
				_pts.append(final_p)
				_normals.append(cur_n)

			_update_preview()

func _update_preview() -> void:
	if _preview == null or not is_instance_valid(_preview) or _pts.size() < 2:
		return
	CableMarks.build_cable_mesh(_pts, _normals[0], radius, _resolved_type, roll_slack, Vector3.ZERO, _mesh)

func _finish() -> void:
	drawing = false
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null

	if _pts.size() >= 2 and CableMarks.live != null:
		var opts := {
			"type": _resolved_type,
			"r": radius,
			"roll": roll_slack,
			"stack": 0
		}
		CableMarks.live.add(_pts, _normals[0], opts)
	_pts = []
	_normals = []

func _show() -> void:
	if _cursor():
		return
	var type_name: String = CableMarks.TYPES[_resolved_type].name if CableMarks.TYPES.has(_resolved_type) else "CABLE"
	_label.text = "EQUIPMENT CABLE: " + type_name + "  [Hold U to lay, Y for Draw Tools]"
	_label.add_theme_color_override("font_color", Color("ffd152"))
	_label_t = 2.0
