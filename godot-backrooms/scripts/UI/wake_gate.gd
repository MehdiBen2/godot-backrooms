extends CanvasLayer
## Between the loading screen and the run (main_menu.gd _finish_loading). The loading screen itself is carried over
## the scene change and stays up over the level while it is built and settles under it, the run held (Game.playing
## false, the mouse not caught, so the player takes no input). Only once all of it stands (level_builder.gd settled:
## the floor and the look-only floors round it) and the frames come steady (the shaders compiled, the lamps faded
## in) does it ask for a key. The key lifts it off the shut lids and the player wakes into the level (blink.gd wake).
## Launched from the level editor (`ask` false) it goes on by itself once ready.

const SETTLE_FRAMES := 20       # frames in a row under SETTLE_MS once the level stands
const SETTLE_MS := 40.0
const MIN_SETTLE := 0.6         # s at least between the level standing and the prompt (the lamps fade in, the eyes adapt)
const GIVE_UP := 15.0           # s: past this it goes on anyway, whatever is still settling
const LIFT := 0.35              # s the screen takes to fade off the shut lids (blink.gd WAKE holds them shut 0.6 s)
const MUSIC_FADE := 2.5         # s (main_menu.gd LOAD_FADE)

var ask := true
var _screen: Control            # the loading screen (main_menu.gd _build_loading), ours now
var _status: Label
var _emblem: TextureRect
var _glow: TextureRect
var _progress := 0.0            # the emblem's fill, from where the menu left it
var _t := 0.0
var _stood := -1.0              # s since the level said it was all there
var _steady := 0
var _last_us := 0
var _held := false
var _asking := false
var _gone := false

func setup(screen: Control, status: Label, emblem: TextureRect, glow: TextureRect, progress: float, wants_key: bool) -> void:
	name = "WakeGate"
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	_screen = screen
	_status = status
	_emblem = emblem
	_glow = glow
	_progress = progress
	ask = wants_key

func _process(dt: float) -> void:
	_t += dt
	var now := Time.get_ticks_usec()
	var frame_ms := (now - _last_us) / 1000.0 if _last_us > 0 else 1000.0
	_last_us = now
	if _gone: return
	_glow.modulate.a = 0.65 + 0.35 * (0.5 + 0.5 * sin(_t * 1.3))
	if _asking:
		_status.modulate.a = 0.4 + 0.6 * (0.5 + 0.5 * sin(_t * 3.2))
		return
	var n := int(_t * 2.0) % 4                  # (main_menu.gd _loading_motion)
	_status.text = "   LOADING" + ".".repeat(n) + " ".repeat(3 - n)
	var lv: Node = Game.level
	var main: Node = Game.main
	if lv == null or not is_instance_valid(lv) or main == null or not is_instance_valid(main) or not main.is_inside_tree():
		_fill(0.85, dt)                         # the run's scene is still coming
		if _t > GIVE_UP * 2.0: queue_free()     # (it never came: nothing to hold)
		return
	if not _held:
		_held = true
		Game.playing = false
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	var stands: bool = lv.settled()
	if stands and _stood < 0.0: _stood = 0.0
	if _stood >= 0.0: _stood += dt
	_steady = _steady + 1 if (stands and frame_ms < SETTLE_MS) else 0
	_fill(0.97 if stands else 0.9, dt)
	if (stands and _steady >= SETTLE_FRAMES and _stood >= MIN_SETTLE) or _t > GIVE_UP:
		if _t > GIVE_UP and not stands: Stability.trace("wake gate: still settling after %d s, going on" % int(GIVE_UP))
		if ask: _ask()
		else: _continue()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN      # (a focus change catches it again: main.gd)
		Game.playing = false

func _fill(to: float, dt: float) -> void:
	_progress = move_toward(_progress, to, dt * 0.5)
	_emblem.material.set_shader_parameter("progress", _progress)

## All of it stands: the emblem fills and flashes once, the halo swells, the status line asks for a key, the
## loading music fades
func _ask() -> void:
	_asking = true
	_emblem.material.set_shader_parameter("progress", 1.0)
	var tw := create_tween().set_parallel(true)
	tw.tween_method(func(v: float) -> void: _emblem.material.set_shader_parameter("flash", v), 1.0, 0.0, 0.9).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(_glow, "scale", Vector2(1.25, 1.25), 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.chain().tween_property(_glow, "scale", Vector2.ONE, 1.2).set_trans(Tween.TRANS_SINE)
	_status.text = "PRESS ANY KEY TO CONTINUE"
	load("res://scripts/UI/menu/main_menu.gd")._fade_loading_music(MUSIC_FADE)

## Nothing gets past while it is up; a key or a click once it asks wakes the player
func _input(e: InputEvent) -> void:
	if _gone: return
	if not (e is InputEventKey or e is InputEventMouseButton or e is InputEventMouseMotion): return
	get_viewport().set_input_as_handled()
	if _asking and e.is_pressed() and not e.is_echo() and not (e is InputEventMouseMotion):
		_continue()

func _continue() -> void:
	_asking = false
	_gone = true
	load("res://scripts/UI/menu/main_menu.gd")._fade_loading_music(MUSIC_FADE)
	if Game.main != null and is_instance_valid(Game.main):
		Game.main.set_paused(false)             # the run starts: playing, the mouse caught
	Game.fx_blink = 0.0
	Game.fx_blur = 0.0
	var tw := create_tween()
	tw.tween_property(_screen, "modulate:a", 0.0, LIFT).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(queue_free)
