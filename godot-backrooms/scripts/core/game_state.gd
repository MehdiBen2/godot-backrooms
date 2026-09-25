extends Node
## Shared run state (the web game's `game` object): clocks, fear channels the post shader reads,
## and the death sequence. Autoload name: Game.

signal player_died(reason: String)

const CREAM := Color("e4e1c6")
const DIM_CREAM := Color(0.902, 0.882, 0.804, 0.55)
const KILLER_CREAM := Color(0.902, 0.882, 0.804, 0.50)
const BTN_CREAM := Color(0.902, 0.882, 0.804, 0.80)
const LINE_CREAM := Color(0.902, 0.882, 0.804, 0.35)
const TITLE_COLOR := Color("d8d3bd")
const DOT_RED := Color("c4271f")
const SHADOW_RED := Color(0.627, 0.078, 0.059, 0.55)

var playing := false          # false on the start screen / pause menu
var time := 0.0               # seconds of play time (events, mannequin timers)
var event_fear := 0.0         # fear pulse from random events, decays on its own
var glitch := 0.0             # 0..1 visual tracking tear from events and scares
var terror := 0.0             # entity proximity only (0..1)
var fear := 0.0               # everything: terror, sanity, darkness, events
var presence := 0.0           # 0..1 how near the entity is (drives dread audio)
var hunted := false
var pulse := 0.0              # heartbeat envelope 0..1 for the tunnel vision
var dead := false
var death_reason := ""
# Grab / snap screen effects, read by the post shader (web: CSS filter/transform on the canvas + #grab-fade)
var fx_blur := 0.0
var fx_contrast := 1.0
var fx_sat := 1.0
var fx_hue := 0.0
var fx_zoom := 1.0
var fx_skew := 0.0
var fx_fade := 0.0
var fx_flash := 0.0
var fx_shock := 0.0
var fx_blood := 0.0
var fx_static := 0.0
var fx_warp := 0.0
var level_index := 0          # which levels/levels.json entry is loaded (survives the scene reload)
var level_count := 1
var respawned := false        # the level was reloaded by a respawn: skip the title screen
var fx_fade_release := false   # after death the black/red edges clear over 1.8s (endGrab(dying))

func fx_reset(keep_fade := false) -> void:
	fx_blur = 0.0; fx_contrast = 1.0; fx_sat = 1.0; fx_hue = 0.0; fx_zoom = 1.0; fx_skew = 0.0; fx_flash = 0.0; fx_shock = 0.0
	if not keep_fade:
		fx_blood = 0.0; fx_static = 0.0; fx_warp = 0.0
	if not keep_fade:
		fx_fade = 0.0
	fx_fade_release = false

var player: Node
var level: Node
var main: Node

var _overlay: CanvasLayer = null
var _overlay_root: Control = null
var _death_box_inner: VBoxContainer = null
var _death_box_anchor: Control = null
var _respawn_box: Control = null
var _tag_dot: ColorRect = null
var _death_t := 0.0

# The death shot plays for this long before a click or key respawns you, so the button you were
# mashing when it got you doesn't skip it
const RESPAWN_READY := 1.6

func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	if ResourceLoader.exists("res://fonts/vcr.ttf"):
		fv.base_font = load("res://fonts/vcr.ttf")
	fv.spacing_glyph = int(spacing)
	return fv

func _process(dt: float) -> void:
	fx_flash *= exp(-dt * 18.0)
	fx_shock *= exp(-dt * 9.0)
	if fx_fade_release:
		fx_fade = maxf(0.0, fx_fade - dt / 1.8)
		fx_static = maxf(0.0, fx_static - dt * 0.12)
		fx_warp = maxf(0.0, fx_warp - dt * 0.004)
		fx_blood = maxf(0.0, fx_blood - dt * 0.12)
	if playing and not dead:
		time += dt
	event_fear = maxf(0.0, event_fear - dt * 0.22)
	glitch = maxf(0.0, glitch - dt * 0.6)
	pulse = maxf(0.0, pulse - dt * 3.0)
	if dead:
		_death_t += dt
		# #death-screen transition: opacity 0.5s ease-out
		if _overlay_root:
			_overlay_root.modulate.a = clampf(_death_t / 0.5, 0.0, 1.0)
		# .death-box animation: deathIn 1.2s ease-out (fade + translateY 8px -> 0), a beat after the hit
		if _death_box_inner:
			var p := 1.0 - pow(1.0 - clampf((_death_t - 0.25) / 1.2, 0.0, 1.0), 3.0)
			_death_box_inner.modulate.a = p
			_death_box_anchor.position.y = 8.0 * (1.0 - p)
		# the respawn prompt only shows once a click will be taken, then breathes slowly
		if _respawn_box:
			var r := clampf((_death_t - RESPAWN_READY) / 0.6, 0.0, 1.0)
			_respawn_box.modulate.a = r * (0.75 + 0.25 * cos((_death_t - RESPAWN_READY) * 2.2))
		# .death-tag i blink: 1.1s steps(1) infinite (50% on, 50% off)
		if _tag_dot:
			_tag_dot.visible = fmod(_death_t, 1.1) < 0.55

func bind(p: Node, l: Node, m: Node) -> void:
	player = p
	level = l
	main = m

func haunt(amount: float) -> void:
	event_fear = maxf(event_fear, amount)

func add_glitch(amount: float) -> void:
	glitch = maxf(glitch, amount)

func beat() -> void:
	pulse = 1.0

# The entity, the mannequin or the dark got you
func kill_player(reason: String) -> void:
	if dead:
		return
	dead = true
	# a grab or snap has already closed the edges in; anything else kills you out of nowhere
	var sudden := fx_fade < 0.5
	fx_reset(true)
	fx_fade_release = true
	if sudden:
		# it lands as a blow: a shock burst, and the edges slam shut, then open on the body
		fx_shock = 1.0
		fx_fade = 0.75
	death_reason = reason if reason != "" else "THE BACKROOMS"
	_death_t = 0.0
	glitch = 1.0
	var scene := get_tree().current_scene
	var sc: Node = scene.get_node_or_null("Scares") if scene else null
	if sc != null:
		sc.play_scare("staticHit", 1.2)
		sc.startle(0.9)
		sc.heart_stop()          # ends in a quiet flatline that holds until the respawn
	# every death, not only the grab: the world settles into a dull, distant muffle until the respawn,
	# and you stop breathing (a broken neck doesn't even get the last breath out)
	var au: Node = scene.get_node_or_null("Audio") if scene else null
	if au != null:
		au.set_dread(0.0)
		au.set_muffled(true)
		if death_reason != "THE MANNEQUIN":
			au.breathing.last_breath()
	if player:
		player.set("dead", true)
		# the held flashlight and hand belong to the first-person view: gone once the death camera pulls out
		var held = player.get("holder")
		if held is Node3D:
			(held as Node3D).visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Start the death camera sequence (death.gd autoload)
	if player and Death:
		var cam: Camera3D = player.get_node_or_null("Camera3D")
		var cam_world: Vector3 = cam.global_position if cam else player.global_position + Vector3(0, 1.7, 0)
		if cam:
			var xf := cam.global_transform
			cam.top_level = true   # detach from player transform so orbit works in world space
			cam.global_transform = xf
		Death.bind(cam, player, sc)
		Death.start(reason, player.global_position, cam_world, player.rotation.y)
	_build_overlay()
	player_died.emit(reason)

func _build_overlay() -> void:
	if _overlay != null:
		_overlay.queue_free()
	_overlay = CanvasLayer.new()
	_overlay.layer = 30
	add_child(_overlay)

	_overlay_root = Control.new()
	_overlay_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_root.modulate.a = 0.0
	_overlay.add_child(_overlay_root)

	# 1. Vertical dark gradient: linear-gradient(to top, rgba(0,0,0,0.85) 0%, rgba(0,0,0,0.35) 45%, rgba(0,0,0,0) 75%)
	var v_grad := Gradient.new()
	v_grad.offsets = PackedFloat32Array([0.0, 0.45, 0.75, 1.0])
	v_grad.colors = PackedColorArray([
		Color(0.0, 0.0, 0.0, 0.85),
		Color(0.0, 0.0, 0.0, 0.35),
		Color(0.0, 0.0, 0.0, 0.0),
		Color(0.0, 0.0, 0.0, 0.0)
	])
	var v_tex := GradientTexture2D.new()
	v_tex.gradient = v_grad
	v_tex.width = 64
	v_tex.height = 256
	v_tex.fill = GradientTexture2D.FILL_LINEAR
	v_tex.fill_from = Vector2(0.0, 1.0)
	v_tex.fill_to = Vector2(0.0, 0.0)

	var v_rect := TextureRect.new()
	v_rect.texture = v_tex
	v_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	v_rect.stretch_mode = TextureRect.STRETCH_SCALE
	v_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_root.add_child(v_rect)

	# 2. Radial vignette gradient: radial-gradient(circle at center, rgba(0,0,0,0) 45%, rgba(20,0,0,0.7) 100%)
	var r_grad := Gradient.new()
	r_grad.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	r_grad.colors = PackedColorArray([
		Color(0.0, 0.0, 0.0, 0.0),
		Color(0.0, 0.0, 0.0, 0.0),
		Color(0.08, 0.0, 0.0, 0.70)
	])
	var r_tex := GradientTexture2D.new()
	r_tex.gradient = r_grad
	r_tex.width = 256
	r_tex.height = 256
	r_tex.fill = GradientTexture2D.FILL_RADIAL
	r_tex.fill_from = Vector2(0.5, 0.5)
	r_tex.fill_to = Vector2(1.0, 1.0)

	var r_rect := TextureRect.new()
	r_rect.texture = r_tex
	r_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	r_rect.stretch_mode = TextureRect.STRETCH_SCALE
	r_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_root.add_child(r_rect)

	# 3. .death-box: left 8vw, bottom 14vh
	var death_box_anchor := Control.new()
	death_box_anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	death_box_anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_root.add_child(death_box_anchor)
	_death_box_anchor = death_box_anchor

	_death_box_inner = VBoxContainer.new()
	# bottom-left corner at (8vw, 86vh); grows up and right so the whole box stays on screen
	_death_box_inner.anchor_left = 0.08
	_death_box_inner.anchor_right = 0.08
	_death_box_inner.anchor_top = 0.86
	_death_box_inner.anchor_bottom = 0.86
	_death_box_inner.grow_horizontal = Control.GROW_DIRECTION_END
	_death_box_inner.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_death_box_inner.add_theme_constant_override("separation", 6)
	_death_box_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_box_inner.modulate.a = 0.0
	death_box_anchor.add_child(_death_box_inner)

	# .death-tag: [dot] SIGNAL LOST
	var tag_row := HBoxContainer.new()
	tag_row.add_theme_constant_override("separation", 8)
	tag_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	tag_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_box_inner.add_child(tag_row)

	var dot_center := CenterContainer.new()
	dot_center.custom_minimum_size = Vector2(8, 16)
	dot_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag_row.add_child(dot_center)

	_tag_dot = ColorRect.new()
	_tag_dot.custom_minimum_size = Vector2(8, 8)
	_tag_dot.color = DOT_RED
	_tag_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot_center.add_child(_tag_dot)

	var tag_label := Label.new()
	tag_label.text = "SIGNAL LOST"
	tag_label.add_theme_font_override("font", _font(4.0))
	tag_label.add_theme_font_size_override("font_size", 13)
	tag_label.add_theme_color_override("font_color", DIM_CREAM)
	tag_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag_row.add_child(tag_label)

	# .death-title: YOU DIED
	var title := Label.new()
	title.text = "YOU DIED"
	title.add_theme_font_override("font", _font(2.0))
	title.add_theme_font_size_override("font_size", 76)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.add_theme_color_override("font_shadow_color", SHADOW_RED)
	title.add_theme_constant_override("shadow_offset_x", 2)
	title.add_theme_constant_override("shadow_offset_y", 0)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_box_inner.add_child(title)

	# .death-killer: THE MANNEQUIN / THE BACTERIA / etc.
	var killer := Label.new()
	killer.text = death_reason.to_upper()
	killer.add_theme_font_override("font", _font(4.0))
	killer.add_theme_font_size_override("font_size", 14)
	killer.add_theme_color_override("font_color", KILLER_CREAM)
	killer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_box_inner.add_child(killer)

	# Margin top 28px
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 24)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_box_inner.add_child(spacer)

	# .death-respawn-btn: CLICK OR PRESS SPACE TO RESPAWN with bottom border
	var respawn_box := VBoxContainer.new()
	respawn_box.add_theme_constant_override("separation", 4)
	respawn_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	respawn_box.modulate.a = 0.0
	_death_box_inner.add_child(respawn_box)
	_respawn_box = respawn_box

	var respawn_label := Label.new()
	respawn_label.text = "CLICK OR PRESS SPACE TO RESPAWN"
	respawn_label.add_theme_font_override("font", _font(3.0))
	respawn_label.add_theme_font_size_override("font_size", 13)
	respawn_label.add_theme_color_override("font_color", BTN_CREAM)
	respawn_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	respawn_box.add_child(respawn_label)

	var respawn_line := ColorRect.new()
	respawn_line.custom_minimum_size = Vector2(0, 1)
	respawn_line.color = LINE_CREAM
	respawn_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	respawn_box.add_child(respawn_line)

func _unhandled_input(e: InputEvent) -> void:
	if not dead or not playing:     # the pause menu is open over the death screen: it has the input
		return
	if _death_t < RESPAWN_READY:
		return
	if e is InputEventMouseButton and e.pressed:
		_respawn()
	elif e is InputEventKey and e.pressed and not e.echo:
		if e.keycode == KEY_SPACE or e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
			_respawn()

# Respawn dissolves through TV static (death.js): the level is only reloaded once the screen is covered
func _respawn() -> void:
	if Death.respawn_busy:
		return
	Death.respawn_transition(restart)

# Switch level (wraps around the playlist) through the TV-static dissolve, like a respawn
func change_level(idx: int) -> void:
	if Death.respawn_busy:
		return
	level_index = posmod(idx, maxi(level_count, 1))
	Death.respawn_transition(restart)

func next_level() -> void:
	change_level(level_index + 1)

func restart() -> void:
	respawned = true
	dead = false
	fx_reset()
	time = 0.0
	event_fear = 0.0
	glitch = 0.0
	terror = 0.0
	fear = 0.0
	presence = 0.0
	hunted = false
	playing = true
	if _overlay:
		_overlay.queue_free()
		_overlay = null
		_overlay_root = null
		_death_box_inner = null
		_death_box_anchor = null
		_respawn_box = null
		_tag_dot = null
	if Death:
		Death.stop()
	get_tree().reload_current_scene()
