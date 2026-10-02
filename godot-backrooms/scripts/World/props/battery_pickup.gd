extends Node3D
## A battery pack lying on the carpet. Walking over it puts it in the inventory, where packs
## stack (up to STACK); R loads one into the flashlight (hud.gd use_battery). With the stack
## full it stays on the floor. Spawned at random open cells by level_builder._spawn_batteries.

const TRIGGER_RADIUS := 0.9
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
	light.light_color = Color(0.3, 1.0, 0.6)
	light.omni_range = 1.2
	light.light_energy = 0.4
	light.shadow_enabled = false
	light.position = Vector3(0, 0.25, 0)
	add_child(light)
	_apply_vis_range(model)

func _apply_vis_range(n: Node) -> void:
	if n is GeometryInstance3D:
		n.visibility_range_end = 45.0
		n.visibility_range_end_margin = 8.0
		n.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for c in n.get_children():
		_apply_vis_range(c)

func _process(_delta: float) -> void:
	light.light_energy = 0.3 + 0.15 * sin(Game.time * 2.5 + position.x)
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
			audio.play_world("battery_pickup.wav")
		queue_free()
