extends RefCounted
## THE GRABBER has you. This is the victim's side: it runs on the machine of whoever was taken, against that
## machine's own player (in co-op the Grabber there is only a puppet of the host's, which walks the drag).
##
##   grab   its hand closes on your ankle and the view is slammed down onto the floor
##   drag   it walks backwards, bent over, staring at you, and you are pulled along the carpet feet first with
##          the ceiling sliding past overhead. Three times a doorframe or a corner goes by within reach:
##          MASH [E] (or Space) to grab it. Each chance is a little easier than the last.
##   free   you caught it: its grip tears, it reels, and you are back on your feet
##   black  you didn't: everything goes black, and you come to far away, lying on the floor, alone, your
##          torch dead and your nerves shot. It is gone, for now.
##
## The Grabber (grabber.gd) is told how it ended through drag_result(escaped).

const GRAB_TIME := 0.8
const DRAG_TIME := 11.0              # s of dragging before it has you
const HOLD := 1.7                    # m: your feet-first body lies this far in front of it (its arm)
const EYE := 0.26                    # m: your eye, on the floor
const WINDOWS := [2.4, 5.6, 8.8]     # s into the drag each chance opens
const WINDOW_LEN := 1.7
const PRESSES := [14, 11, 8]
const FREE_TIME := 0.8
const BLACK_IN := 0.6
const BLACK_HOLD := 3.2              # s in the dark (you are moved half-way through)
const WAKE_TIME := 2.8
const TAKE_MIN_CELLS := 10           # where you wake: at least this many cells of path from where it took you
const SANITY_HIT := 25.0
const FONT := "res://fonts/vcr.ttf"
const CREAM := Color("d6cfb2")

var e: Node3D                        # grabber.gd
var phase := ""
var t := 0.0
var window := -1                     # the chance open now, -1 when none
var _last_window := -1               # the last chance that opened (each opens once)
var presses := 0
var trauma := 0.0
var _key_prev := false
var _scrape := 0.0
var _beat := 0.0
var _moved := false
var _from_pos := Vector3.ZERO
var _from_basis := Basis.IDENTITY
var _from_fov := 75.0
var _wake_yaw := 0.0
var ui: CanvasLayer
var prompt: Label
var meter: ColorRect
var meter_back: ColorRect
var black: ColorRect

func _init(entity: Node3D) -> void:
	e = entity

func active() -> bool:
	return phase != ""

func _player() -> Node:
	return e.player

func start() -> void:
	var p: Node = _player()
	if p == null or p.dead or active():
		return
	phase = "grab"
	t = 0.0
	window = -1
	presses = 0
	trauma = 0.9
	_moved = false
	p.frozen = true
	p.velocity = Vector3.ZERO
	var cam: Camera3D = p.cam
	_from_pos = cam.global_position
	_from_basis = cam.global_transform.basis
	_from_fov = cam.fov
	_build_ui()
	e.scares.gasp()
	e.scares.seize()
	e.scares.heartbeat(1.8)
	e.scares.startle(0.9)
	Game.fx_reset()
	Game.fx_shock = 0.9
	Game.fear = 1.0

func update(delta: float) -> void:
	if not active():
		return
	var p: Node = _player()
	if p == null or not is_instance_valid(p) or p.dead:
		_abort()
		return
	t += delta
	match phase:
		"grab":
			_update_drag_body(delta, smoothstep(0.0, 1.0, t / GRAB_TIME))
			if t >= GRAB_TIME:
				phase = "drag"
				t = 0.0
		"drag":
			_update_drag_body(delta, 1.0)
			_update_windows(delta)
			if phase == "drag" and t >= DRAG_TIME:
				_to_black()
		"free":
			_update_free(delta)
		"black":
			_update_black(delta)
		"wake":
			_update_wake(delta)

# ---------------------------------------------------------------- being dragged
func _facing() -> Vector3:
	return Vector3(sin(e.yaw), 0.0, cos(e.yaw))

## Your body: in front of it (it faces you, walking backwards), on the floor
func _victim_spot() -> Vector3:
	var ep: Vector3 = e.global_position
	var at := ep + _facing() * HOLD
	at = e.nav.resolve(at, 0.3)
	return at

func _update_drag_body(delta: float, k: float) -> void:
	var p: Node = _player()
	var cam: Camera3D = p.cam
	var spot := _victim_spot()
	var here: Vector3 = p.global_position
	var pull := minf(1.0, delta * (4.0 + 10.0 * k))
	p.global_position = Vector3(lerpf(here.x, spot.x, pull), here.y, lerpf(here.z, spot.z, pull))
	p.velocity = Vector3.ZERO
	# the view: slammed down onto the floor, then dragged along it looking up at it
	var slam := smoothstep(0.0, 1.0, minf(1.0, t / 0.3)) if phase == "grab" else 1.0
	var bump := sin(Game.time * 13.0) * 0.015 + sin(Game.time * 5.3) * 0.02
	var eye_pos := Vector3(p.global_position.x, p.global_position.y + EYE + bump, p.global_position.z)
	var cam_pos := _from_pos.lerp(eye_pos, slam)
	var head: Vector3 = e.body.head_pos() if e.body != null else e.global_position + Vector3.UP * 2.0
	var hand: Vector3 = e.body.hand_pos() if e.body != null else head
	var look_at := hand.lerp(head, 0.35 + 0.35 * k)
	var to := look_at - cam_pos
	if to.length_squared() < 0.0001:
		to = _facing()
	var want := Basis.looking_at(to.normalized(), Vector3.UP if absf(to.normalized().y) < 0.98 else Vector3.BACK)
	want = want.rotated(want.z, 0.32 * k + sin(Game.time * 1.7) * 0.04)
	var b := _from_basis.slerp(want.orthonormalized(), slam)
	trauma = move_toward(trauma, 0.25, delta * 0.8)
	var sh := trauma * trauma
	b = b.rotated(b.x, (randf() - 0.5) * 0.08 * sh).rotated(b.y, (randf() - 0.5) * 0.08 * sh)
	cam.global_transform = Transform3D(b.orthonormalized(), cam_pos)
	cam.fov = lerpf(_from_fov, _from_fov + 12.0, slam) + sin(Game.time * 7.0) * 1.5 * k
	# your torch is somewhere behind you on the floor
	p.flash.visible = false
	p.flash.light_energy = 0.0
	if p.flash_spill:
		p.flash_spill.visible = false
		p.flash_spill.light_energy = 0.0
	Game.fx_blur = 0.8 * k + sh
	Game.fx_contrast = 1.0 + 0.25 * k
	Game.fx_sat = 1.0 - 0.35 * k
	Game.fear = 1.0
	Game.glitch = maxf(Game.glitch, 0.25 * k)
	# the carpet scraping under you, your heart hammering
	_scrape -= delta
	if _scrape <= 0.0 and phase == "drag":
		_scrape = randf_range(0.45, 0.7)
		e.scares.spawn3d(e.scares.synth("howler_drag"), p.global_position, 0.6, "Scares", 3.0, randf_range(0.8, 1.05))
		if randf() < 0.45:
			e.scares.wall_scratch(p.global_position + Vector3.UP * 0.1, 0.6)
	_beat -= delta
	if _beat <= 0.0:
		_beat = 0.36
		e.scares.heartbeat(1.7, 1.08)

func _update_windows(delta: float) -> void:
	var mash := Input.is_physical_key_pressed(KEY_E) or Input.is_physical_key_pressed(KEY_SPACE)
	var pressed := mash and not _key_prev
	_key_prev = mash
	if window < 0:
		for i in WINDOWS.size():
			if t >= WINDOWS[i] and t < WINDOWS[i] + WINDOW_LEN and i > _last_window:
				window = i
				_last_window = i
				presses = 0
				trauma = maxf(trauma, 0.5)
				e.scares.knock(_player().global_position + _facing().cross(Vector3.UP) * 1.2, 0.6)
				break
	if window < 0:
		_show_prompt(false)
		return
	if pressed:
		presses += 1
		trauma = maxf(trauma, 0.45)
	var need: int = PRESSES[window]
	_show_prompt(true, float(presses) / need, 1.0 - (t - WINDOWS[window]) / WINDOW_LEN)
	if presses >= need:
		_break_free()
	elif t >= WINDOWS[window] + WINDOW_LEN:
		window = -1
		e.scares.heartbeat(1.9, 1.12)

# ---------------------------------------------------------------- endings
func _break_free() -> void:
	phase = "free"
	t = 0.0
	window = -1
	_show_prompt(false)
	var head: Vector3 = e.body.head_pos() if e.body != null else e.global_position
	e.scares.spawn3d(e.scares.synth("stinger"), head, 1.0, "Scares", 6.0, 0.62)
	e.scares.spawn3d(e.scares.synth("bone_crack"), head, 0.7, "Scares", 3.0, 0.9)
	e.scares.startle(0.8)
	Game.fx_shock = 0.8
	var cam: Camera3D = _player().cam
	_from_pos = cam.global_position
	_from_basis = cam.global_transform.basis
	e.drag_result(true)

func _update_free(delta: float) -> void:
	var p: Node = _player()
	var cam: Camera3D = p.cam
	var k := smoothstep(0.0, 1.0, t / FREE_TIME)
	# back on your feet, facing it as it reels
	var eye_pos: Vector3 = p.global_position + Vector3.UP * p.eye
	var to: Vector3 = e.global_position + Vector3.UP * 1.6 - eye_pos
	to.y *= 0.4
	var b := _from_basis.slerp(Basis.looking_at(to.normalized(), Vector3.UP), k)
	cam.global_transform = Transform3D(b.orthonormalized(), _from_pos.lerp(eye_pos, k))
	Game.fx_blur = 0.8 * (1.0 - k)
	if t >= FREE_TIME:
		p.rotation.y = atan2(-to.x, -to.z)
		_release()

func _to_black() -> void:
	phase = "black"
	t = 0.0
	window = -1
	_show_prompt(false)
	e.scares.tinnitus(3.0)
	e.drag_result(false)

func _update_black(delta: float) -> void:
	var p: Node = _player()
	black.color.a = clampf(t / BLACK_IN, 0.0, 1.0)
	if t < BLACK_IN:
		_update_drag_body(delta, 1.0)
	if not _moved and t >= BLACK_HOLD * 0.5:
		_moved = true
		var spot: Vector3 = e.far_cell(p.global_position, TAKE_MIN_CELLS)
		if spot.is_finite():
			p.global_position = spot
		p.velocity = Vector3.ZERO
		_wake_yaw = randf() * TAU
		p.rotation.y = _wake_yaw
		p.battery = 0.0
		p.flash_on = false
		if p.sanity_lock < 0.0:
			p.sanity = maxf(1.0, p.sanity - SANITY_HIT)
		e.scares.breath_behind(p.global_position + Vector3.UP * 0.4, 0.5)
		Game.fx_reset(true)
	if t >= BLACK_HOLD:
		phase = "wake"
		t = 0.0

func _update_wake(delta: float) -> void:
	var p: Node = _player()
	var cam: Camera3D = p.cam
	var k := smoothstep(0.0, 1.0, t / WAKE_TIME)
	black.color.a = 1.0 - smoothstep(0.0, 1.0, t / (WAKE_TIME * 0.6))
	# lying on your back, then sitting up and getting to your feet
	var eye_y: float = lerpf(0.25, p.eye, smoothstep(0.35, 1.0, k))
	var fwd := Vector3(-sin(_wake_yaw), 0.0, -cos(_wake_yaw))
	var up_look := Basis.looking_at((fwd * 0.2 + Vector3.UP).normalized(), fwd)
	var ahead := Basis.looking_at(fwd, Vector3.UP)
	var b := up_look.slerp(ahead, smoothstep(0.2, 0.9, k))
	cam.global_transform = Transform3D(b.orthonormalized(), p.global_position + Vector3.UP * eye_y)
	Game.fx_blur = 1.5 * (1.0 - k)
	if t >= WAKE_TIME:
		_release()

## Hand the view back to the player
func _release() -> void:
	var p: Node = _player()
	var cam: Camera3D = p.cam
	cam.position = Vector3(0.0, p.eye, 0.0)
	cam.rotation = Vector3.ZERO
	cam.fov = p.base_fov
	p.frozen = false
	p.velocity = Vector3.ZERO
	Game.fx_reset()
	phase = ""
	_last_window = -1
	_free_ui()

## Something else took over (you died): drop everything
func _abort() -> void:
	phase = ""
	_last_window = -1
	_free_ui()

# ---------------------------------------------------------------- the prompt and the dark
func _build_ui() -> void:
	_free_ui()
	ui = CanvasLayer.new()
	ui.layer = 60
	e.add_child(ui)
	var font := load(FONT) as Font
	prompt = Label.new()
	prompt.text = "MASH  [E]  -  GRAB THE FRAME"
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	prompt.position = Vector2(-260, -190)
	prompt.size = Vector2(520, 40)
	if font != null:
		prompt.add_theme_font_override("font", font)
	prompt.add_theme_font_size_override("font_size", 26)
	prompt.add_theme_color_override("font_color", CREAM)
	prompt.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	ui.add_child(prompt)
	meter_back = ColorRect.new()
	meter_back.color = Color(0, 0, 0, 0.55)
	meter_back.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	meter_back.position = Vector2(-160, -140)
	meter_back.size = Vector2(320, 12)
	ui.add_child(meter_back)
	meter = ColorRect.new()
	meter.color = CREAM
	meter.position = Vector2(2, 2)
	meter.size = Vector2(0, 8)
	meter_back.add_child(meter)
	black = ColorRect.new()
	black.color = Color(0, 0, 0, 0)
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(black)
	_show_prompt(false)

func _show_prompt(on: bool, fill := 0.0, left := 1.0) -> void:
	if prompt == null:
		return
	prompt.visible = on
	meter_back.visible = on
	if on:
		meter.size.x = 316.0 * clampf(fill, 0.0, 1.0)
		prompt.modulate.a = 0.55 + 0.45 * absf(sin(Game.time * 9.0))
		meter.color = CREAM.lerp(Color("ff3b30"), clampf(1.0 - left, 0.0, 1.0))

func _free_ui() -> void:
	if ui != null and is_instance_valid(ui):
		ui.queue_free()
	ui = null
	prompt = null
	meter = null
	meter_back = null
	black = null
