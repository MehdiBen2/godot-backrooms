extends Node
## T.S.R.A. (Threshold Spatial Research Agency) Field Archive: which entities the player has
## personally encountered, plus the level/entity dossier catalog the TAB terminal's [F2] DOSSIER and
## [F3] ENTRIES pages render (scripts/UI/inventory/pages/page_dossier.gd, page_entries.gd).
## Autoload name: Archive.
##
## Entities are logged by scanning them: the T.S.R.A. field scanner (scripts/Player/scanner.gd, hold
## Q) calls discover("id") once a reading completes, and the HUD toast announces the new entry.
## Anything scannable joins the SCANNABLE group with its id in the "asra_id" meta, and implements
## scan_points() -> Array of world positions it can be read from right now (empty while it is away):
## see bacteria.gd, mannequin.gd, mimic.gd, eyes.gd, killer.gd.
## It also implements scan_behavior(at) -> {state, detail, danger 0..2}: what it is doing right now,
## which the C-4 deep scan shows on the reticle (scan_readout.gd).
## New entities: add a block to levels/asra_entities.json keyed by the new id (with its classified
## annex), then give the entity an _enter_tree() + scan_points() + scan_behavior() like the others.
##
## New levels: add a block to levels/asra_dossiers.json keyed by the level's levels.json "id",
## listing the entity ids (from asra_entities.json) that can appear in it under "entities".

signal entity_discovered(entity_id: String)

const SCANNABLE := "asra_scannable"
# What T.S.R.A. stands for (terminal footer). The agency was A.S.R.A. once: internal names (asra_id,
# asra_*.json, the save files) keep that spelling so existing saves carry over.
const AGENCY := "THRESHOLD SPATIAL RESEARCH AGENCY"

const ENTITIES_PATH := "res://levels/asra_entities.json"
const DOSSIERS_PATH := "res://levels/asra_dossiers.json"

var _entities := {}
var _dossiers := {}

# No save feature yet: nothing here is written to disk, and main.gd clears it whenever a level
# starts (a new game, joining one, a respawn, a level change), so every run logs from scratch
var discovered := {}   # entity_id -> {t: unix seconds, level: levels.json id}
var unread := {}       # entity_id -> true until its entry is opened in the terminal ([F3] ENTRIES)

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

## level id (levels/levels.json "id") -> {designation, threat_classification, metrics, directives,
## entities, log_sheet (optional)}
func dossiers() -> Dictionary:
	if _dossiers.is_empty():
		_dossiers = _read_json(DOSSIERS_PATH)
	return _dossiers

## The levels.json id of whichever playlist entry Game.level_index points at ("" if none)
func current_level_id() -> String:
	var LevelData := load("res://scripts/World/level/level_data.gd")
	var levels: Array = LevelData.read_index()
	if levels.is_empty():
		return ""
	var meta: Dictionary = levels[clampi(Game.level_index, 0, levels.size() - 1)]
	return str(meta.get("id", ""))

## The dossier for the current level, falling back to "_default"
func current_dossier() -> Dictionary:
	var all := dossiers()
	return all.get(current_level_id(), all.get("_default", {}))

## Designations of every level whose dossier lists this entity, and of the one it was logged on
## (its KNOWN SITES)
func sites_of(entity_id: String) -> Array:
	var out := []
	var all := dossiers()
	for level_id in all:
		if str(level_id) != "_default" and entity_id in all[level_id].get("entities", []):
			out.append(str(all[level_id].get("designation", level_id)))
	var logged := str(logged_info(entity_id).get("level", ""))
	if logged != "":
		var where := str(all.get(logged, {}).get("designation", logged))
		if not (where in out):
			out.append(where)
	return out

## The entities a level's dossier covers: the ones its block lists, plus any logged on that level.
## Every entity node sits in every level's scene (main.tscn), so one can turn up, and be scanned,
## where its dossier doesn't list it; it still belongs under that level's PHENOMENA LOGGED.
func level_entities(level_id: String) -> Array:
	var all := dossiers()
	var block: Dictionary = all.get(level_id, all.get("_default", {}))
	var out: Array = block.get("entities", []).duplicate()
	for id in discovered:
		if str(logged_info(id).get("level", "")) == level_id and not (id in out):
			out.append(id)
	return out

## When and where it was logged: {t, level}; empty for entries from before this was recorded
func logged_info(entity_id: String) -> Dictionary:
	var v = discovered.get(entity_id, {})
	return v if v is Dictionary else {}

func is_unread(entity_id: String) -> bool:
	return unread.has(entity_id)

func has_unread() -> bool:
	return not unread.is_empty()

func mark_read(entity_id: String) -> void:
	unread.erase(entity_id)

func is_discovered(entity_id: String) -> bool:
	return discovered.has(entity_id)

## Called by the field scanner (scanner.gd) when a reading completes; idempotent.
func discover(entity_id: String) -> void:
	if discovered.has(entity_id):
		return
	discovered[entity_id] = {"t": int(Time.get_unix_time_from_system()), "level": current_level_id()}
	unread[entity_id] = true
	entity_discovered.emit(entity_id)

## Every entity back to unlogged: each level start (main.gd) and the debug console's `archive reset`
func forget_all() -> void:
	discovered.clear()
	unread.clear()
	entity_discovered.emit("")
