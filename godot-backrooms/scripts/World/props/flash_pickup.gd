extends Node3D
## A spare camera flash standing on the carpet. Walking over it puts it in the inventory,
## where each one is one charge (up to STACK); G fires one (flash_tool.gd). With the stack full it
## stays on the floor. Rare: spawned at random open cells by level_builder._spawn_flashes.

const ItemIcon := preload("res://scripts/UI/inventory/item_icon.gd")

const TRIGGER_RADIUS := 0.9
const ITEM_ID := "flash"
const ITEM_NAME := "Camera Flash"
const ITEM_CODE := "FLSH"
const STACK := 3
const START := 2               # charges every run starts with (hud.gd _build_flash)
const MODEL_PATH := "res://models/camera_flash.glb"   # from asetsuimprot/camera+flash+3d+model.glb, decimated
const MODEL_SIZE := 0.26         # metres, longest side: oversized like the battery packs, so it reads from standing height
const ITEM_DESC := "A camera speedlight with one charge left in its capacitor. Press G (or right click) to fire " \
	+ "it: anything in front of you that catches it full in the eyes is blinded for a few seconds. " \
	+ "Get out of its sight before it can see again and it has lost you. The pop is loud: miss, and " \
	+ "you have told it where you are."

static var model_scene: PackedScene    # a .glb can't be preloaded off the main thread (battery_pickup.gd)

var used := false
var light: OmniLight3D

func _ready() -> void:
	if model_scene == null:
		model_scene = load(MODEL_PATH)
	var model: Node3D = model_scene.instantiate()
	add_child(model)
	# fit it to MODEL_SIZE along its longest side and stand it on the floor
	var box := ItemIcon.mesh_aabb(model, Transform3D.IDENTITY)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if longest > 0.0:
		var k := MODEL_SIZE / longest
		model.scale = Vector3.ONE * k
		var c := box.get_center()
		model.position = Vector3(-c.x * k, -box.position.y * k, -c.z * k)
	light = OmniLight3D.new()           # the ready lamp's faint red glow, so it can be found in the dark
	light.light_color = Color(1.0, 0.25, 0.15)
	light.omni_range = 1.1
	light.light_energy = 0.35
	light.shadow_enabled = false
	light.position = Vector3(0, 0.2, 0)
	add_child(light)

func _process(_delta: float) -> void:
	light.light_energy = 0.25 + 0.2 * absf(sin(Game.time * 1.7 + position.z))
	if used or Game.dead or not Game.playing:
		return
	var player: Node3D = get_parent().player
	if player == null:
		return
	var d := Vector2(player.global_position.x - global_position.x, player.global_position.z - global_position.z).length()
	if d < TRIGGER_RADIUS and absf(player.global_position.y - global_position.y) < 2.0:
		var ui: Node = Game.main.get_node_or_null("UI") if Game.main != null else null
		if ui == null or not ui.pick_up_item(ITEM_ID, ITEM_NAME, ITEM_DESC, ITEM_CODE, STACK, MODEL_PATH):
			return                       # stack full: leave it for later
		used = true
		var audio: Node = Game.main.get_node_or_null("Audio")
		if audio:
			audio.play_world("flash_click_on.wav")
		queue_free()
