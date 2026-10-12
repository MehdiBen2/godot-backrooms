extends "res://scripts/World/props/interact_tooltip.gd"
## The pickup tooltip for a floor item, and the pickup itself. While the player's interact focus lands on
## the item, a camera-facing "[E] PICK UP" and its name hover over it in the game's VCR font, and fade out
## when the focus goes. Add one under any pickup's root node and call setup() with its card; a new item
## needs nothing more. Full stack: the prompt flashes PACK FULL and the item stays on the floor.
## walk_over items are also taken by walking onto them. Used by battery_pickup.gd, tape_pickup.gd, flash_pickup.gd.

const REACH := 2.2             # metres from the camera
const AIM_DOT := 0.8           # how squarely the view has to point at it: loose, so the prompt only goes when you look right away
const WALK_RADIUS := 0.9       # walk_over items: taken when the player comes this close on the same floor

var item_id := ""
var item_name := ""
var item_code := ""
var item_desc := ""
var stack := 1
var model_path := ""
var sound: Variant = ""        # played when the item is taken: a file under res://audio/, or an Array of takes
static var _last_take := {}    # item id -> the take played last, so a pickup never sounds the same twice running
var walk_over := false
var _full_t := 0.0             # >0: just failed to pick up, show "PACK FULL"
var _taken := false

func _ready() -> void:
	add_to_group("interactables")       # the player's interact focus scans this group (see _find_interactable_door)
	super()

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

func _process(delta: float) -> void:
	_full_t = maxf(_full_t - delta, 0.0)
	if _taken:
		return
	if walk_over and _walked_onto() and take():
		return
	_update_prompt(delta)

func _focused() -> bool:
	var player: Node = Game.player
	return not _taken and player != null and is_instance_valid(player) and player.get("focused_door") == self

func _key_text() -> String:
	return "PACK FULL" if _full_t > 0.0 else "[E] PICK UP"

func _title_text() -> String:
	return item_name

func _alert() -> bool:
	return _full_t > 0.0

func _anchor() -> Vector3:
	return global_position + Vector3(0, height, 0)

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
		audio.play_world(_pick_take())
	get_parent().queue_free()
	return true

## One of the card's takes at random, never the one this kind of item played last
func _pick_take() -> String:
	if not sound is Array:
		return str(sound)
	var takes: Array = sound.duplicate()
	if takes.size() > 1:
		takes.erase(_last_take.get(item_id, ""))
	var take: String = takes.pick_random()
	_last_take[item_id] = take
	return take

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
