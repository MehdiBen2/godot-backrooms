extends Node3D
## A battery pack lying on the carpet, glowing a faint green so it can be found in the dark. Look at it
## and press E (the player's door/interact focus) to put it in the inventory, where packs stack
## (up to STACK); R loads one into the flashlight (hud.gd use_battery). With the stack full it stays
## on the floor. A camera-facing 3D prompt in the game's VCR font hovers over it while it's in focus. Spawned at random open cells by level_builder._spawn_batteries.

const REACH := 2.2             # metres from the camera
const AIM_DOT := 0.8           # how squarely the view has to point at it: loose, so the prompt only goes when you look right away
const CREAM := Color("d6cfb2")
const GLOW := Color(0.3, 1.0, 0.6)
const CHARGE := 45.0           # % of battery one pack restores
const ITEM_ID := "battery"
const ITEM_NAME := "AA Battery Pack"
const ITEM_CODE := "BAT"
const STACK := 6
const ITEM_DESC := "A shrink-wrapped pair of AA cells, still holding a charge. Press R to load one " \
	+ "into the flashlight: +45% battery."

const ItemIcon := preload("res://scripts/UI/inventory/item_icon.gd")
const MODEL_PATH := "res://models/aa_batteries.glb"
const MODEL_SIZE := 0.3          # metres, longest side
static var model_scene: PackedScene    # a .glb can't be preloaded off the main thread, so the menu's threaded load would stall on it

var used := false
var light: OmniLight3D
var prompt: Node3D
var key_label: Label3D
var name_label: Label3D
var backdrop: Sprite3D
var _alpha := 0.0
var _shown := false
var _full_t := 0.0             # >0: just failed to pick up, show "PACK FULL"

func _ready() -> void:
	if model_scene == null:
		model_scene = load(MODEL_PATH)
	var model: Node3D = model_scene.instantiate()
	add_child(model)
	# fit the model to ~MODEL_SIZE along its longest side and rest it on the floor
	var box := ItemIcon.mesh_aabb(model, Transform3D.IDENTITY)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if longest > 0.0:
		var k := MODEL_SIZE / longest
		model.scale = Vector3.ONE * k
		var c := box.get_center()
		model.position = Vector3(-c.x * k, -box.position.y * k, -c.z * k)
	light = OmniLight3D.new()           # faint green glint so it can be found in the dark
	light.light_color = GLOW
	light.omni_range = 1.2
	light.light_energy = 0.4
	light.shadow_enabled = false
	light.position = Vector3(0, 0.25, 0)
	add_child(light)
	_build_prompt()
	add_to_group("interactables")       # the player's interact focus scans this group (see _find_interactable_door)
	_apply_vis_range(model)

func _label3d(text: String, size: int, px: float, color: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = load("res://fonts/vcr.ttf")
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
	name_label = _label3d(ITEM_NAME.to_upper(), 40, 0.00042, Color(GLOW, 0.85))
	name_label.position = Vector3(0, -0.055, 0)
	prompt.add_child(name_label)

func _apply_vis_range(n: Node) -> void:
	if n is GeometryInstance3D:
		n.visibility_range_end = 45.0
		n.visibility_range_end_margin = 8.0
		n.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for c in n.get_children():
		_apply_vis_range(c)

func _process(delta: float) -> void:
	light.light_energy = 0.3 + 0.15 * sin(Game.time * 2.5 + position.x)
	var player = get_parent().get("player") if get_parent() != null else null
	var focused: bool = not used and player != null and "focused_door" in player and player.focused_door == self
	_full_t = maxf(_full_t - delta, 0.0)
	_alpha = move_toward(_alpha, 1.0 if focused else 0.0, delta * (5.0 if focused else 4.0))
	prompt.visible = _alpha > 0.01
	if not prompt.visible:
		_shown = false
		return
	var ease_a := 1.0 - pow(1.0 - _alpha, 3.0)
	# target: well above the pack, drawn a little toward where the camera is aimed so it trails the view
	var home := global_position + Vector3(0, 0.85, 0)
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
	key_label.text = txt
	key_label.visible_characters = clampi(int(ease_a * (txt.length() + 3)), 0, txt.length())      # types in
	key_label.modulate = Color(0.9, 0.35, 0.3, _alpha) if full else Color(CREAM, _alpha)
	var nm := ITEM_NAME.to_upper()
	name_label.visible_characters = clampi(int((ease_a - 0.25) / 0.75 * (nm.length() + 3)), 0, nm.length())
	name_label.modulate = Color(GLOW, 0.85 * _alpha)
	backdrop.modulate.a = _alpha

## Player focus test: close enough, looking squarely at it, nothing solid in between
func can_interact(from_pos: Vector3) -> bool:
	if used or Game.dead or not Game.playing:
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
	if used:
		return false
	var ui: Node = Game.main.get_node_or_null("UI") if Game.main != null else null
	if ui == null or not ui.pick_up_item(ITEM_ID, ITEM_NAME, ITEM_DESC, ITEM_CODE, STACK, MODEL_PATH):
		_full_t = 1.5                    # stack full: leave it for later
		return false
	used = true
	var audio: Node = Game.main.get_node_or_null("Audio")
	if audio:
		audio.play_world("battery_pickup.wav")
	queue_free()
	return true
