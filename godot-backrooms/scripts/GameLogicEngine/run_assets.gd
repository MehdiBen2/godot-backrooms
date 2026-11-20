extends RefCounted
## Read ahead only the assets used to build the selected floor and its player and entities.

const LevelData := preload("res://scripts/World/level/level_data.gd")
const Mannequin := preload("res://scripts/Entities/mannequin/mannequin_model.gd")
const Survivor := preload("res://scripts/Entities/survivor_anim.gd")
const Torch := preload("res://scripts/Player/torch_model.gd")
const Grabber := preload("res://scripts/Entities/grabber/grabber_body.gd")
const BATCH_SIZE := 4
const TEXTURE_SETS := [
	["l0_carpet", "webp"], ["l0_ceiling", "webp"], ["l0_wallpaper", "webp"], ["tiles", "png"],
]
const COMMON := [
	Mannequin.MODEL, Survivor.MODEL, Torch.MODEL, Torch.ARMS, Torch.IDLE_HANDS, Grabber.MODEL,
	"res://models/player/survivor_legs.glb", "res://models/entities/howler.glb",
	"res://models/lights/office_lighting_troffer_light_1x4.glb", "res://models/ceiling/backrooms_blender_kit.glb",
	"res://textures/l0_carpet_height.png", "res://textures/concrete_color.jpg", "res://textures/concrete_normal.jpg",
	"res://textures/props/door/door_leaf.tres", "res://models/props/door/wood_door.glb",
]

var assets: Array[Resource] = []
var _queue: Array[String] = []
var _active: Array[String] = []
var _next := 0

func _init(level_index: int, floor_no: int) -> void:
	var paths := {}
	for path: String in COMMON + Mannequin.VARIANT_MODELS:
		paths[path] = true
	for entry in TEXTURE_SETS:
		for channel in ["color", "normal", "rough", "ao"]:
			paths["res://textures/%s_%s.%s" % [entry[0], channel, entry[1]]] = true
	var levels := LevelData.read_index()
	if not levels.is_empty():
		var raw := LevelData.read_level(levels[clampi(level_index, 0, levels.size() - 1)])
		var floor := LevelData.floor_data(raw, LevelData.floor_src(raw, floor_no))
		var materials := ["Ceiling_Office_Lit", "Wood_Dark_Knot", "Metal_Grey_Plate"]
		materials.append_array(floor.get("materials", {}).values())
		for slot: Dictionary in floor.get("paint", {}).values():
			materials.append_array(slot.keys())
		for value in materials:
			var id := str(value)
			paths["res://textures/pbr/%s/%s.tres" % [id, id]] = true
		for obj in floor.get("objects", []):
			if not obj is Dictionary:
				continue
			var info := LevelData.object_info(str(obj.get("type", "")))
			for path in [info.get("model", ""), info.get("cable_model", "")] + info.get("textures", {}).values():
				if path is String and path.begins_with("res://"):
					paths[path] = true
	for path: String in paths:
		if ResourceLoader.exists(path):
			_queue.append(path)

func poll() -> void:
	for i in range(_active.size() - 1, -1, -1):
		var path := _active[i]
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		if status != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			var resource := ResourceLoader.load_threaded_get(path)
			if resource != null:
				assets.append(resource)
		_active.remove_at(i)
	while _active.size() < BATCH_SIZE and _next < _queue.size():
		var path := _queue[_next]
		_next += 1
		if ResourceLoader.load_threaded_request(path) == OK:
			_active.append(path)

func progress() -> float:
	return float(_next - _active.size()) / _queue.size() if not _queue.is_empty() else 1.0
