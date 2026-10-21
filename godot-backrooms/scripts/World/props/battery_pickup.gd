extends Node3D
## A battery pack lying on the carpet, glowing a faint green so it can be found in the dark. Look at it
## and press E to put it in the inventory, where packs stack (up to STACK); R loads one into the flashlight
## (hud.gd use_battery). With the stack full it stays on the floor. The pickup tooltip is pickup_prompt.gd.
## Spawned at random open cells by level_builder._spawn_batteries.

const PickupPrompt := preload("res://scripts/World/props/pickup_prompt.gd")
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
# into the backpack: a hand swish, the bag, a quiet zip (four recorded takes, audio/CREDITS.txt)
const PICKUP_TAKES := ["items/pickups/battery_pickup_1.wav", "items/pickups/battery_pickup_2.wav",
	"items/pickups/battery_pickup_3.wav", "items/pickups/battery_pickup_4.wav"]
static var model_scene: PackedScene    # a .glb can't be preloaded off the main thread, so the menu's threaded load would stall on it

var light: OmniLight3D

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
	var prompt := PickupPrompt.new()
	add_child(prompt)
	prompt.setup({"id": ITEM_ID, "name": ITEM_NAME, "code": ITEM_CODE, "desc": ITEM_DESC, "stack": STACK,
		"model": MODEL_PATH, "sound": PICKUP_TAKES, "height": 0.85})
	_apply_vis_range(model)

func _apply_vis_range(n: Node) -> void:
	if n is GeometryInstance3D:
		n.visibility_range_end = 90.0
		n.visibility_range_end_margin = 12.0
		n.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for c in n.get_children():
		_apply_vis_range(c)

func _process(_delta: float) -> void:
	light.light_energy = 0.3 + 0.15 * sin(Game.time * 2.5 + position.x)
