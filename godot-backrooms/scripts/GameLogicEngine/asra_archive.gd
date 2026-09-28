extends Node
## A.S.R.A. (Threshold Spatial Research Agency) Field Archive: which entities the player has
## personally encountered, plus the level/entity dossier catalog the inventory's ARCHIVE tab
## renders (scripts/UI/inventory/inventory.gd). Autoload name: Archive.
##
## Entities/*.gd register a sighting by calling discover("id") from wherever they first become
## visible/active in-game (see killer.gd debug_spawn(), mannequin.gd debug_spawn(), bacteria.gd
## summon()/debug_spawn(), mimic.gd appear(), eyes.gd _add()).
## New entities: add a block to levels/asra_entities.json keyed by that same id, then call
## discover() from the entity's own "just became visible" point.
##
## New levels: add a block to levels/asra_dossiers.json keyed by the level's levels.json "id",
## listing the entity ids (from asra_entities.json) that can appear in it under "entities".

signal entity_discovered(entity_id: String)

const ENTITIES_PATH := "res://levels/asra_entities.json"
const DOSSIERS_PATH := "res://levels/asra_dossiers.json"
const SAVE_PATH := "user://asra_archive.cfg"

var _entities := {}
var _dossiers := {}

var discovered := {}   # entity_id -> true, persisted across sessions

func _ready() -> void:
	_load()

func _read_json(path: String) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("cannot read " + path)
		return {}
	var out := {}
	for k in parsed:
		if not str(k).begins_with("_"): out[k] = parsed[k]
	return out

## entity_id -> {code, common_name, threat_class, behavior_vector, directive}
func entities() -> Dictionary:
	if _entities.is_empty():
		_entities = _read_json(ENTITIES_PATH)
	return _entities

func entity_info(id: String) -> Dictionary:
	return entities().get(id, {})

## level id (levels/levels.json "id") -> {designation, threat_classification, metrics, directives, entities}
func dossiers() -> Dictionary:
	if _dossiers.is_empty():
		_dossiers = _read_json(DOSSIERS_PATH)
	return _dossiers

## The dossier for whichever playlist entry Game.level_index points at, falling back to "_default"
func current_dossier() -> Dictionary:
	var LevelData := load("res://scripts/World/level/level_data.gd")
	var levels: Array = LevelData.read_index()
	var all := dossiers()
	if levels.is_empty():
		return all.get("_default", {})
	var meta: Dictionary = levels[clampi(Game.level_index, 0, levels.size() - 1)]
	return all.get(str(meta.get("id", "")), all.get("_default", {}))

func is_discovered(entity_id: String) -> bool:
	return discovered.has(entity_id)

## Called by an entity script the moment it becomes visible/active to the player; idempotent.
func discover(entity_id: String) -> void:
	if discovered.has(entity_id):
		return
	discovered[entity_id] = true
	_save()
	entity_discovered.emit(entity_id)

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return
	for id in cf.get_section_keys("discovered"):
		discovered[id] = true

func _save() -> void:
	var cf := ConfigFile.new()
	for id in discovered:
		cf.set_value("discovered", id, true)
	cf.save(SAVE_PATH)
