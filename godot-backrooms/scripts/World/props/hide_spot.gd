extends Node3D
## A smart prop: somewhere to hide (levels/object_types.json "smart": "hide"). level_geometry.gd _build_props() hangs
## one on the prop it builds (the metal cabinet, the locker). Press E at it: you pull the door open, duck in, turn round
## and pull it to behind you, leaving it open a crack on your right. Inside, the world goes dull and far off, the edges
## close in and your breath is loud; you can turn your head a little and lean to the crack, or look out between the
## louvres of the vent. Your heart picks up when THE TALL ONE is near. While you are in it `player.hidden` is true,
## which is what THE TALL ONE reads (tall_one.gd _player_hidden): it cannot see you, and a hunt that has begun loses
## you. E again shoves the door open and you climb out where you went in.
## The door faces the prop's arrow (its local +X, as every prop's front does). In the type:
##   "smart_door": {"node": the model's door node, its origin on the hinge (tools/blender/edit_metal_cabinet.py)}
##   "smart_eye": [x, y, z]: where your eyes are inside, as fractions of the prop's box (x from its back, y of its
##                height, z across, - the arrow's right): the cabinet puts you behind the door that opens

const Tooltip := preload("res://scripts/World/props/interact_tooltip.gd")
const FONT := preload("res://fonts/vcr.ttf")
# No sounds yet: the door's creak, the latch and your breath are left empty until there are better ones than the doors'
const OPEN_SOUND := ""
const CLOSE_SOUND := ""
const REACH := 2.2            # metres from the door you can still climb in
const IN_T := 1.15            # s to climb in
const OUT_T := 0.9            # s to climb out
const OPEN_ANGLE := deg_to_rad(78.0)
const CRACK_ANGLE := deg_to_rad(3.0)      # the gap on your right you look out of
const LOOK_YAW := deg_to_rad(30.0)
const LOOK_PITCH := deg_to_rad(18.0)
const LEAN := 0.06            # m your head goes toward the crack when you look that way
const FOV_IN := 8.0           # degrees narrower inside
const EDGES := 0.3            # Game.fx_fade inside: the dark closing in round the view
const NEAR_RANGE := 26.0      # m: THE TALL ONE closer than this and your heart starts to go

var prop: Node3D              # the prop this hangs on
var info := {}
var _bounds := AABB()         # the prop's box in its own space (floor at y = 0, door side at +x)
var _door: Node3D             # the door node of the model, swung about its own origin (null: no door that moves)
var _door_rest := Transform3D()
var _door_ang := 0.0
var _state := "idle"          # idle, in (climbing in), hidden, out (climbing out)
var _t := 0.0
var _player: Node3D
var _cam: Camera3D
var _from := Transform3D()    # the view as it was at the door
var _fov0 := 75.0
var _look := Vector2.ZERO     # your head inside: yaw (left +), pitch (up +), radians
var _look_s := Vector2.ZERO   # the same, eased
var _fade := 0.0              # how far the edges are closed in (ours: Game.fx_fade while we have the view)
var _fear := 0.0              # 0..1 eased: how near THE TALL ONE is
var _beat_t := 0.0
var _hint: CanvasLayer
var _hint_label: Label

func setup(p: Node3D, p_info: Dictionary) -> void:
	prop = p
	info = p_info
	_bounds = p.get("bounds")
	process_priority = 100        # after the player: its camera is ours to hold while you are inside
	add_to_group("interactables") # the player's interact focus scans this group (player.gd _find_interactable_door)
	var d: Dictionary = info.get("smart_door", {})
	if not d.is_empty() and p.get_child_count() > 0:
		_door = p.get_child(0).find_child(str(d.get("node", "")), true, false) as Node3D
		if _door != null: _door_rest = _door.transform
	var tip := Tooltip.new()
	tip.height = 0.3
	add_child(tip)

# ---------------------------------------------------------------- interaction (player.gd)
func can_interact(from_pos: Vector3) -> bool:
	if _state != "idle" or Game.dead or not Game.playing: return false
	var local := prop.to_local(from_pos)
	if local.x < _bounds.end.x * 0.3: return false            # not from behind it
	return Vector2(local.x - _bounds.end.x, local.z).length() < REACH

func get_interact_prompt() -> String:
	return "[E] HIDE"

func get_interact_title() -> String:
	return str(info.get("label", "Hiding place")).get_slice(" (", 0)

func get_handle_global_pos() -> Vector3:
	var e := _eye_local()
	return prop.to_global(Vector3(_bounds.end.x, _bounds.size.y * 0.55, e.z))

func interact(p: Node3D) -> bool:
	if _state != "idle" or p == null or not ("cam" in p): return false
	_player = p
	_cam = p.cam
	_from = _cam.global_transform
	_fov0 = _cam.fov
	_look = Vector2.ZERO
	_look_s = Vector2.ZERO
	_state = "in"
	_t = 0.0
	p.frozen = true
	p.hidden = true
	p.hiding_in = self
	_show_body(false)
	_sound(OPEN_SOUND, 1.0)
	return true

# ---------------------------------------------------------------- where things are
## Your eyes inside, in the prop's own space
func _eye_local() -> Vector3:
	var e: Array = info.get("smart_eye", [0.35, 0.8, 0.0])
	return Vector3(lerpf(_bounds.position.x, _bounds.end.x, float(e[0])), _bounds.size.y * float(e[1]),
		lerpf(_bounds.position.z, _bounds.end.z, 0.5 + float(e[2])))

func _eye_in() -> Vector3:
	return prop.to_global(_eye_local())

## Just outside the door, a little lower: you duck to get in
func _door_out() -> Vector3:
	var e := _eye_local()
	return prop.to_global(Vector3(_bounds.end.x + 0.55, e.y - 0.12, e.z))

## The view looking out of the door
func _facing() -> Basis:
	return Basis.looking_at(prop.global_transform.basis.x.normalized(), Vector3.UP)

static func _bezier(a: Vector3, b: Vector3, c: Vector3, s: float) -> Vector3:
	var r := 1.0 - s
	return a * (r * r) + b * (2.0 * r * s) + c * (s * s)

# ---------------------------------------------------------------- every frame
func _process(delta: float) -> void:
	if _state == "idle":
		if _door_ang > 0.0:                                   # left open behind you: it swings to on its own
			_swing(move_toward(_door_ang, 0.0, delta * 1.4))
		if _fade > 0.0:
			_fade = maxf(0.0, _fade - delta * 0.6)
			if not Game.dead: Game.fx_fade = _fade
		return
	if not is_instance_valid(_player) or not is_instance_valid(_cam) or _player.dead or Game.dead:
		_release(false)
		return
	_t += delta
	_tick_fear(delta)
	match _state:
		"in": _climb_in()
		"hidden": _inside(delta)
		"out": _climb_out()
	Game.fx_fade = _fade

func _climb_in() -> void:
	var u := clampf(_t / IN_T, 0.0, 1.0)
	var s := smoothstep(0.0, 1.0, u)
	var target := _facing()
	var pos := _bezier(_from.origin, _door_out(), _eye_in(), s)
	# turned round as you step in: the head goes first, then the body follows it
	var turn := smoothstep(0.15, 0.85, u)
	var q := _from.basis.get_rotation_quaternion().slerp(target.get_rotation_quaternion(), turn)
	var roll := sin(PI * turn) * 0.07
	_cam.global_transform = Transform3D(Basis(q) * Basis(Vector3.BACK, roll), pos)
	_cam.fov = lerpf(_fov0, _fov0 - FOV_IN, s)
	_fade = EDGES * smoothstep(0.5, 1.0, u)
	# the door: pulled open as you reach for it, held, then drawn to behind you; shut a moment, then let open a crack
	var ang := OPEN_ANGLE * smoothstep(0.0, 0.3, u)
	if u > 0.6: ang = lerpf(OPEN_ANGLE, 0.0, smoothstep(0.6, 0.88, u))
	if u > 0.9: ang = lerpf(0.0, CRACK_ANGLE, smoothstep(0.9, 1.0, u))
	_swing(ang)
	if u >= 1.0:
		_state = "hidden"
		_t = 0.0
		_set_muffled(true)
		_sound(CLOSE_SOUND, 1.0)
		_show_hint(true)

func _inside(delta: float) -> void:
	_look_s = _look_s.lerp(_look, 1.0 - exp(-delta * 10.0))
	# your breath: slow and held, quick and shallow with it near
	var rate := lerpf(0.9, 2.6, _fear)
	var depth := lerpf(1.0, 0.6, _fear)
	var breath := Vector2(sin(Game.time * rate * 0.5) * 0.003, sin(Game.time * rate) * 0.006 * depth)
	var shake := Vector2(sin(Game.time * 31.0), sin(Game.time * 23.0 + 1.0)) * 0.0015 * _fear * _fear
	var b := _facing() * Basis.from_euler(Vector3(_look_s.y + breath.y + shake.y, _look_s.x + breath.x + shake.x, 0.0))
	# looking toward the crack (to your right), you lean to it
	var right := prop.global_transform.basis.z.normalized()
	var lean := right * LEAN * clampf(-_look_s.x / LOOK_YAW, 0.0, 1.0)
	_cam.global_transform = Transform3D(b, _eye_in() + lean + Vector3.UP * breath.y * 0.5)
	_cam.fov = _fov0 - FOV_IN - 3.0 * _fear
	_fade = lerpf(_fade, EDGES + 0.15 * _fear, 1.0 - exp(-delta * 2.0))
	if _hint_label != null:
		_hint_label.modulate.a = clampf(_t / 0.6, 0.0, 1.0) * (1.0 - 0.6 * smoothstep(3.0, 6.0, _t))

func _climb_out() -> void:
	var u := clampf(_t / OUT_T, 0.0, 1.0)
	var s := smoothstep(0.0, 1.0, u)
	var start := Transform3D(_facing() * Basis.from_euler(Vector3(_look_s.y, _look_s.x, 0.0)), _eye_in())
	var pos := _bezier(start.origin, _door_out(), _from.origin, s)
	var q := start.basis.get_rotation_quaternion().slerp(_from.basis.get_rotation_quaternion(), smoothstep(0.2, 1.0, u))
	_cam.global_transform = Transform3D(Basis(q), pos)
	_cam.fov = lerpf(_fov0 - FOV_IN, _fov0, s)
	_fade = EDGES * (1.0 - s)
	_swing(lerpf(CRACK_ANGLE, OPEN_ANGLE, 1.0 - pow(1.0 - clampf(u / 0.25, 0.0, 1.0), 3.0)))   # shoved open
	if u >= 1.0:
		_release(true)

## How near THE TALL ONE is, eased, and the heart that goes with it
func _tick_fear(delta: float) -> void:
	var near := 0.0
	var tall: Node3D = Game.main.get_node_or_null("TallOne") if Game.main != null else null
	if tall != null and tall.visible and bool(tall.get("present")):
		var d := tall.global_position.distance_to(_player.global_position)
		near = clampf(1.0 - d / NEAR_RANGE, 0.0, 1.0)
	_fear = move_toward(_fear, near, delta * (0.8 if near > _fear else 0.25))
	if _state != "hidden" or _fear < 0.05: return
	_beat_t -= delta
	if _beat_t <= 0.0:
		_beat_t = lerpf(1.1, 0.42, _fear)
		var scares: Node = Game.main.get_node_or_null("Scares")
		if scares != null: scares.heartbeat(0.35 + 0.65 * _fear, 1.0 + 0.1 * _fear)

func _swing(angle: float) -> void:
	_door_ang = angle
	if _door != null: _door.transform = Transform3D(_door_rest.basis * Basis(Vector3.UP, angle), _door_rest.origin)

func _unhandled_input(e: InputEvent) -> void:
	if _state != "hidden": return
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var aim := float(_player.get("sens")) if _player.get("sens") != null else 0.0022
		_look.x = clampf(_look.x - e.relative.x * aim, -LOOK_YAW, LOOK_YAW)
		_look.y = clampf(_look.y - e.relative.y * aim, -LOOK_PITCH, LOOK_PITCH)
	elif _t > 0.4 and (e.is_action_pressed("interact") or (e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_E)):
		_state = "out"
		_t = 0.0
		_set_muffled(false)
		_show_hint(false)
		_sound(OPEN_SOUND, 1.0)
		get_viewport().set_input_as_handled()

## Hands the player back (`restore_view`: the eyes where they were at the door). Dead, nothing is restored: the death
## view has it, and the world's muffle is death's
func _release(restore_view: bool) -> void:
	if is_instance_valid(_player):
		_player.hidden = false
		_player.hiding_in = null
		if not _player.dead:
			_player.frozen = false
			_set_muffled(false)
		if restore_view and is_instance_valid(_cam):
			_cam.global_transform = _from
			_cam.fov = _fov0
		_show_body(true)
	_state = "idle"
	_fear = 0.0
	_show_hint(false)

func _exit_tree() -> void:
	if _state != "idle": _release(false)

## Your body (player_shadow.gd: the legs you see, the shadow) stays where you stood: out of sight while the view is in here
func _show_body(on: bool) -> void:
	var b: Node = _player.get("shadow_body")
	if b != null and is_instance_valid(b): (b as Node3D).visible = on

func _set_muffled(on: bool) -> void:
	var au: Node = Game.main.get_node_or_null("Audio") if Game.main != null else null
	if au != null and au.has_method("set_muffled"): au.set_muffled(on)

## A sound at the door (none yet: see OPEN_SOUND)
func _sound(path: String, pitch: float) -> void:
	if path == "" or not ResourceLoader.exists(path) or not is_inside_tree(): return
	var a := AudioStreamPlayer3D.new()
	a.stream = load(path)
	a.bus = "World"
	a.pitch_scale = pitch
	a.unit_size = 2.0
	a.max_distance = 40.0
	add_child(a)
	a.global_position = get_handle_global_pos()
	a.finished.connect(a.queue_free)
	a.play()

func _show_hint(on: bool) -> void:
	if not on:
		if _hint != null:
			_hint.queue_free()
			_hint = null
			_hint_label = null
		return
	if _hint != null: return
	_hint = CanvasLayer.new()
	_hint.layer = 15
	var l := Label.new()
	l.text = "[E] CLIMB OUT"
	l.add_theme_font_override("font", FONT)
	l.add_theme_font_size_override("font_size", 22)
	l.add_theme_color_override("font_color", Color(0.84, 0.81, 0.7, 0.8))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 6)
	l.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	l.offset_top = -90.0
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.modulate.a = 0.0
	_hint.add_child(l)
	_hint_label = l
	add_child(_hint)
