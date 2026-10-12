extends Node3D
## A spare camera flash standing on the carpet. Walking over it, or looking at it and pressing E, puts it in
## the inventory, where each one is one charge (up to STACK); G fires one (flash_tool.gd). With the stack full
## it stays on the floor. The pickup tooltip is pickup_prompt.gd. Rare: spawned at random open cells by
## level_builder._spawn_flashes.

const ItemIcon := preload("res://scripts/UI/inventory/item_icon.gd")
const PickupPrompt := preload("res://scripts/World/props/pickup_prompt.gd")

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
	var prompt := PickupPrompt.new()
	add_child(prompt)
	prompt.setup({"id": ITEM_ID, "name": ITEM_NAME, "code": ITEM_CODE, "desc": ITEM_DESC, "stack": STACK,
		"model": MODEL_PATH, "sound": "items/torch/flash_click_on.wav", "height": 0.6, "walk_over": true})
	_apply_vis_range(model)

func _apply_vis_range(n: Node) -> void:
	if n is GeometryInstance3D:
		n.visibility_range_end = 45.0
		n.visibility_range_end_margin = 8.0
		n.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for c in n.get_children():
		_apply_vis_range(c)
