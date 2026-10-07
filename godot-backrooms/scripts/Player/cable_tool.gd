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
		_resolved_type = cable_type
		if _resolved_type == "random" or not CableMarks.TYPES.has(_resolved_type):
			_resolved_type = CableMarks.TYPE_KEYS[randi() % CableMarks.TYPE_KEYS.size()]

		# Offset initial point off surface by cable radius with contact clearance
		var p_start := p + n * (radius * 1.12)
		var cam: Camera3D = player.cam
		var stub_dir := -cam.global_transform.basis.z
		stub_dir = (stub_dir - n * stub_dir.dot(n)).normalized()
		if stub_dir.length_squared() < 0.01:
			stub_dir = Vector3.FORWARD
		var p_second := p_start + stub_dir * 0.02
		_pts = [p_start, p_second]
		_normals = [n, n]

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
		for i in range(1, steps + 1):
			var frac := float(i) / float(steps)
			var cur_p := a.lerp(p, frac)
			var cur_n := n
			# Raycast onto scene floor and objects to drape cleanly over obstacles
			var q_down := PhysicsRayQueryParameters3D.create(cur_p + n * 0.8, cur_p - n * 1.2, WORLD_MASK)
			q_down.exclude = [player.get_rid()]
			var r_hit: Dictionary = space.intersect_ray(q_down)
			if not r_hit.is_empty():
				cur_p = r_hit.position
				cur_n = (r_hit.normal as Vector3).normalized()
			# Evaluate stack elevation
			var stack_elev := CableMarks.get_stack_elevation(cur_p, cur_n, radius) * stack_mult
			cur_p += cur_n * (radius * 1.12 + stack_elev)
			_pts.append(cur_p)
			_normals.append(cur_n)
		_update_preview()
	else:
		# Freehand mode: add point when dragged past STEP
		var last_p: Vector3 = _pts[-1]
		var dist_to_last := p.distance_to(last_p)
		if dist_to_last >= STEP and _pts.size() < MAX_POINTS:
			# Multi-step interpolation when moving fast so we don't cut corners through obstacles
			var substeps := clampi(int(dist_to_last / STEP), 1, 6)
			var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
			for s_idx in range(1, substeps + 1):
				var frac := float(s_idx) / float(substeps)
				var mid_contact := last_p.lerp(p, frac)
				var cur_n := n

				# Raycast onto surface to hug obstacles, crates, tables, and ledges
				var q_probe := PhysicsRayQueryParameters3D.create(mid_contact + n * 0.6, mid_contact - n * 0.8, WORLD_MASK)
				q_probe.exclude = [player.get_rid()]
				var p_hit: Dictionary = space.intersect_ray(q_probe)
				if not p_hit.is_empty():
					mid_contact = p_hit.position
					cur_n = (p_hit.normal as Vector3).normalized()

				# 1. Check elevation over existing placed cables
				var stack_elev := CableMarks.get_stack_elevation(mid_contact, cur_n, radius) * stack_mult

				# 2. Check self-stacking over earlier segments of THIS active stroke
				var pt_count := _pts.size()
				if pt_count > 10:
					for j in range(0, pt_count - 8):
						var sa: Vector3 = _pts[j]
						var sb: Vector3 = _pts[j + 1]
						var s_seg := sb - sa
						var sl2 := s_seg.length_squared()
						if sl2 < 0.00001:
							continue
						var st_t := clampf((mid_contact - sa).dot(s_seg) / sl2, 0.0, 1.0)
						var s_proj := sa + s_seg * st_t
						var s_diff := s_proj - mid_contact
						var s_diff_along_n := s_diff.dot(cur_n)
						var s_perp := (s_diff - cur_n * s_diff_along_n).length()
						var s_r_crest := (radius * 2.0) * 1.15
						var s_r_bridge := s_r_crest + 0.20
						if s_perp < s_r_bridge:
							var s_other_top := s_diff_along_n + radius
							var s_req_center := s_other_top + radius + 0.006
							var s_needed := maxf(0.0, s_req_center - (radius * 1.12))
							var s_elev := 0.0
							if s_perp <= s_r_crest:
								s_elev = s_needed
							else:
								var s_ramp := (s_perp - s_r_crest) / (s_r_bridge - s_r_crest)
								var s_factor := cos(s_ramp * (PI * 0.5))
								s_factor *= s_factor
								s_elev = s_needed * s_factor
							if s_elev > stack_elev:
								stack_elev = s_elev

				# 3. Smooth catenary back-propagation across preceding points
				if stack_elev > 0.002 and _pts.size() > 2:
					var span := mini(10, _pts.size() - 1)
					for k in range(1, span + 1):
						var b_idx := _pts.size() - k
						var b_frac := 1.0 - (float(k) / float(span + 1))
						var b_ramp := cos((1.0 - b_frac) * (PI * 0.5))
						b_ramp *= b_ramp
						var target_lift := stack_elev * b_ramp
						var cur_prev: Vector3 = _pts[b_idx]
						var prev_n: Vector3 = _normals[b_idx]
						var cur_lift := (cur_prev - mid_contact).dot(prev_n)
						if target_lift > cur_lift:
							_pts[b_idx] = cur_prev + prev_n * (target_lift - cur_lift)

				# Natural rolling waviness: micro lateral curl
				var curl_val := sin(_pts.size() * 0.45) * roll_slack * (radius * 0.8)
				var forward_vec := (p - last_p).normalized()
				var side_dir := cur_n.cross(forward_vec)
				if side_dir.length_squared() < 0.01:
					side_dir = Vector3.RIGHT

				var elevated_p := mid_contact + cur_n * (radius * 1.12 + stack_elev) + side_dir * curl_val
				_pts.append(elevated_p)
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
