extends Node3D
## The pickup tooltip for a floor item, and the pickup itself. While the player's interact focus lands on
## the item, a camera-facing "[E] PICK UP" and its name hover over it in the game's VCR font, and fade out
## when the focus goes. Add one under any pickup's root node and call setup() with its card; a new item
## needs nothing more. Full stack: the prompt flashes PACK FULL and the item stays on the floor.
## walk_over items are also taken by walking onto them. Used by battery_pickup.gd, tape_pickup.gd, flash_pickup.gd.

const REACH := 2.2             # metres from the camera
const AIM_DOT := 0.8           # how squarely the view has to point at it: loose, so the prompt only goes when you look right away
const WALK_RADIUS := 0.9       # walk_over items: taken when the player comes this close on the same floor
const GLOW := Color(0.3, 1.0, 0.6)
const CREAM := Color("d6cfb2")
const FONT := preload("res://fonts/vcr.ttf")

var item_id := ""
var item_name := ""
var item_code := ""
var item_desc := ""
var stack := 1
var model_path := ""
var sound := ""                # played when the item is taken
var height := 0.85             # metres above the item's origin the prompt hovers at
var walk_over := false
var prompt: Node3D
var key_label: Label3D
var name_label: Label3D
var backdrop: Sprite3D
var _alpha := 0.0
var _shown := false
var _full_t := 0.0             # >0: just failed to pick up, show "PACK FULL"
var _key_txt := ""             # what the labels currently show: Label3D re-shapes its text on every assignment, so only set it when it changes
var _name_txt := ""
var _was_full := false
var _taken := false

func _ready() -> void:
	add_to_group("interactables")       # the player's interact focus scans this group (see _find_interactable_door)
	_build_prompt()

## The item's card: id, name, code, desc, stack, model, sound, and optionally height and walk_over
func setup(card: Dictionary) -> void:
	item_id = card.id
	item_name = card.name
	item_code = card.code
	item_desc = card.desc
	stack = card.stack
	model_path = card.model
	sound = card.sound
	height = card.get("height", 0.85)
	walk_over = card.get("walk_over", false)
	_name_txt = ""

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

func _build_prompt() -> void:
	prompt = Node3D.new()
	prompt.top_level = true              # positioned in world space so it can trail the camera
	prompt.visible = false
	add_child(prompt)
	# soft dark pad behind the text so the flashlight's glare on the carpet can't wash it out
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0.95))
	grad.set_color(1, Color(0, 0, 0, 0))
	grad.add_point(0.55, Color(0, 0, 0, 0.85))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 640
	tex.height = 640
	backdrop = Sprite3D.new()
	backdrop.texture = tex
	backdrop.pixel_size = 0.00042
	backdrop.scale = Vector3(1.0, 0.3, 1.0)    # squashed into a wide soft ellipse
	backdrop.position = Vector3(0, -0.03, 0)
	backdrop.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	backdrop.fixed_size = true
	backdrop.no_depth_test = true
	backdrop.shaded = false
	backdrop.render_priority = 9
	backdrop.set_meta("gfx_managed", true)
	prompt.add_child(backdrop)
	key_label = _label3d("[E] PICK UP", 64, 0.00042, CREAM)
	prompt.add_child(key_label)
	name_label = _label3d("", 40, 0.00042, Color(GLOW, 0.85))
	name_label.position = Vector3(0, -0.055, 0)
	prompt.add_child(name_label)

func _process(delta: float) -> void:
	_full_t = maxf(_full_t - delta, 0.0)
	if _taken:
		return
	if walk_over and _walked_onto() and take():
		return
	var focused := _focused()
	if not focused and _alpha <= 0.0:
		return                              # out of focus and faded out: nothing below needs to run
	_alpha = move_toward(_alpha, 1.0 if focused else 0.0, delta * (5.0 if focused else 4.0))
	prompt.visible = _alpha > 0.01
	if not prompt.visible:
		_shown = false
		return
	var ease_a := 1.0 - pow(1.0 - _alpha, 3.0)
	# target: above the item, drawn a little toward where the camera is aimed so it trails the view
	var home := global_position + Vector3(0, height, 0)
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		var cp := camera.global_position
		var on_ray := cp + (-camera.global_transform.basis.z) * cp.distance_to(home)
		home = home.lerp(on_ray, 0.3)
		home.y += clampf((-camera.global_transform.basis.z).y * 1.5, 0.0, 0.7)     # lifts as you look up
	home.y += sin(Game.time * 2.0 + position.x) * 0.015
	if not _shown:
		prompt.global_position = home - Vector3(0, 0.12, 0)     # rises into place
		_shown = true
	prompt.global_position = prompt.global_position.lerp(home, 1.0 - exp(-6.0 * delta))
	prompt.scale = Vector3.ONE * lerpf(0.7, 1.0, ease_a)
	var full := _full_t > 0.0
	var txt := "PACK FULL" if full else "[E] PICK UP"
	# Label3D has no visible_characters, so "typing in" is done by showing a growing prefix of the text
	var key_now := txt.substr(0, clampi(int(ease_a * (txt.length() + 3)), 0, txt.length()))
	if key_now != _key_txt:
		_key_txt = key_now
		key_label.text = key_now
	if full != _was_full:
		_was_full = full
		key_label.modulate = Color(0.9, 0.35, 0.3, _alpha) if full else Color(CREAM, _alpha)
	var nm := item_name.to_upper()
	var name_now := nm.substr(0, clampi(int((ease_a - 0.25) / 0.75 * (nm.length() + 3)), 0, nm.length()))
	if name_now != _name_txt:
		_name_txt = name_now
		name_label.text = name_now
	key_label.modulate.a = _alpha
	name_label.modulate.a = 0.85 * _alpha
	backdrop.modulate.a = _alpha

func _focused() -> bool:
	var player: Node = Game.player
	return not _taken and player != null and is_instance_valid(player) and player.get("focused_door") == self

func _walked_onto() -> bool:
	var player := Game.player as Node3D
	if player == null or Game.dead or not Game.playing:
		return false
	var d := Vector2(player.global_position.x - global_position.x, player.global_position.z - global_position.z).length()
	return d < WALK_RADIUS and absf(player.global_position.y - global_position.y) < 2.0

## Puts the item in the inventory and takes it off the floor. False when the stack is full: it stays, and the prompt says PACK FULL
func take() -> bool:
	if _taken:
		return false
	var ui: Node = Game.main.get_node_or_null("UI") if Game.main != null else null
	if ui == null or not ui.pick_up_item(item_id, item_name, item_desc, item_code, stack, model_path):
		_full_t = 1.5                    # stack full: leave it for later
		return false
	_taken = true
	var audio: Node = Game.main.get_node_or_null("Audio") if Game.main != null else null
	if audio:
		audio.play_world(sound)
	get_parent().queue_free()
	return true

## Player focus test: close enough, looking squarely at it, nothing solid in between
func can_interact(from_pos: Vector3) -> bool:
	if _taken or Game.dead or not Game.playing:
		return false
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return false
	var aim := global_position + Vector3(0, 0.1, 0)
	if from_pos.distance_to(aim) > REACH:
		return false
	if (-camera.global_transform.basis.z).dot((aim - from_pos).normalized()) < AIM_DOT:
		return false
	var q := PhysicsRayQueryParameters3D.create(from_pos, aim, 1)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()

func interact(_player: Node3D) -> bool:
	return take()
