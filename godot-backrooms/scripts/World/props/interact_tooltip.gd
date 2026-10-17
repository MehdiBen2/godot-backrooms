extends Node3D
## The world tooltip for anything the player can interact with: while the player's interact focus lands on
## the parent, a camera-facing key prompt (e.g. "[E] OPEN") and a name hover over it in the game's VCR font,
## and fade out when the focus goes. Add one under any interactable (door, terminal...) that has
## get_interact_prompt() -> String, and optionally get_interact_title() -> String and get_handle_global_pos().
## pickup_prompt.gd extends this for floor items.

const GLOW := Color(0.3, 1.0, 0.6)
const CREAM := Color("d6cfb2")
const ALERT := Color(0.9, 0.35, 0.3)
const FONT := preload("res://fonts/vcr.ttf")

var height := 0.85             # metres above the anchor the prompt hovers at
var prompt: Node3D
var key_label: Label3D
var name_label: Label3D
var backdrop: Sprite3D
var _alpha := 0.0
var _shown := false
var _key_txt := ""             # what the labels currently show: Label3D re-shapes its text on every assignment, so only set it when it changes
var _name_txt := ""
var _was_alert := false

func _ready() -> void:
	_build_prompt()

# ---- what a tooltip shows; pickup_prompt.gd overrides these
func _focused() -> bool:
	var player: Node = Game.player
	return player != null and is_instance_valid(player) and player.get("focused_door") == get_parent()

func _key_text() -> String:
	var p := get_parent()
	return p.get_interact_prompt() if p.has_method("get_interact_prompt") else "[E]"

func _title_text() -> String:
	var p := get_parent()
	return p.get_interact_title() if p.has_method("get_interact_title") else ""

func _alert() -> bool:
	return false

func _anchor() -> Vector3:
	var p := get_parent() as Node3D
	var at: Vector3 = p.get_handle_global_pos() if p.has_method("get_handle_global_pos") else p.global_position
	return at + Vector3(0, height, 0)

func _label3d(text: String, size: int, px: float, color: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = FONT
	l.font_size = size
	l.pixel_size = px
	l.outline_size = 10
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.modulate = color
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true                 # constant on-screen size whatever the distance
	l.no_depth_test = true
	l.shaded = false
	l.render_priority = 10
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	l.set_meta("gfx_managed", true)
	return l

## The soft dark pad behind every tooltip: one texture for all of them. Each tooltip made its own 640 px
## GradientTexture2D, worked out pixel by pixel on the CPU the frame after it was made, so the dozen pickups a
## new floor scatters cost a few hundred milliseconds in one frame. A soft radial blur needs far fewer pixels.
const PAD_PX := 128
static var _pad: GradientTexture2D

static func _pad_texture() -> GradientTexture2D:
	if _pad != null: return _pad
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0.95))
	grad.set_color(1, Color(0, 0, 0, 0))
	grad.add_point(0.55, Color(0, 0, 0, 0.85))
	_pad = GradientTexture2D.new()
	_pad.gradient = grad
	_pad.fill = GradientTexture2D.FILL_RADIAL
	_pad.fill_from = Vector2(0.5, 0.5)
	_pad.fill_to = Vector2(1.0, 0.5)
	_pad.width = PAD_PX
	_pad.height = PAD_PX
	return _pad

func _build_prompt() -> void:
	prompt = Node3D.new()
	prompt.top_level = true              # positioned in world space so it can trail the camera
	prompt.visible = false
	add_child(prompt)
	# soft dark pad behind the text so the flashlight's glare on the carpet can't wash it out
	backdrop = Sprite3D.new()
	backdrop.texture = _pad_texture()
	backdrop.pixel_size = 0.00042 * 640.0 / PAD_PX     # (the size a 640 px pad had)
	backdrop.scale = Vector3(1.0, 0.3, 1.0)    # squashed into a wide soft ellipse
	backdrop.position = Vector3(0, -0.03, 0)
	backdrop.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	backdrop.fixed_size = true
	backdrop.no_depth_test = true
	backdrop.shaded = false
	backdrop.render_priority = 9
	backdrop.set_meta("gfx_managed", true)
	prompt.add_child(backdrop)
	key_label = _label3d("", 64, 0.00042, CREAM)
	prompt.add_child(key_label)
	name_label = _label3d("", 40, 0.00042, Color(GLOW, 0.85))
	name_label.offset = Vector2(0, -50)     # in label pixels, so the gap holds at any distance (a world-unit offset doesn't scale with fixed_size)
	prompt.add_child(name_label)

func _process(delta: float) -> void:
	_update_prompt(delta)

func _update_prompt(delta: float) -> void:
	var focused := _focused()
	if not focused and _alpha <= 0.0:
		return                              # out of focus and faded out: nothing below needs to run
	_alpha = move_toward(_alpha, 1.0 if focused else 0.0, delta * (5.0 if focused else 4.0))
	prompt.visible = _alpha > 0.01
	if not prompt.visible:
		_shown = false
		return
	var ease_a := 1.0 - pow(1.0 - _alpha, 3.0)
	# target: above the anchor, drawn a little toward where the camera is aimed so it trails the view
	var home := _anchor()
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		var cp := camera.global_position
		var on_ray := cp + (-camera.global_transform.basis.z) * cp.distance_to(home)
		home = home.lerp(on_ray, 0.3)
		home.y += clampf((-camera.global_transform.basis.z).y * 1.5, 0.0, 0.7)     # lifts as you look up
	home.y += sin(Game.time * 2.0 + global_position.x) * 0.015
	if not _shown:
		prompt.global_position = home - Vector3(0, 0.12, 0)     # rises into place
		_shown = true
	prompt.global_position = prompt.global_position.lerp(home, 1.0 - exp(-6.0 * delta))
	prompt.scale = Vector3.ONE * lerpf(0.7, 1.0, ease_a)
	var alert := _alert()
	var txt := _key_text()
	# Label3D has no visible_characters, so "typing in" is done by showing a growing prefix of the text
	var key_now := txt.substr(0, clampi(int(ease_a * (txt.length() + 3)), 0, txt.length()))
	if key_now != _key_txt:
		_key_txt = key_now
		key_label.text = key_now
	if alert != _was_alert:
		_was_alert = alert
		key_label.modulate = Color(ALERT, _alpha) if alert else Color(CREAM, _alpha)
	var nm := _title_text().to_upper()
	var name_now := nm.substr(0, clampi(int((ease_a - 0.25) / 0.75 * (nm.length() + 3)), 0, nm.length()))
	if name_now != _name_txt:
		_name_txt = name_now
		name_label.text = name_now
	key_label.modulate.a = _alpha
	name_label.modulate.a = 0.85 * _alpha
	backdrop.modulate.a = _alpha
