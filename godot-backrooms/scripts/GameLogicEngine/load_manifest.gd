extends RefCounted
## What a level reads off the disk while it is built, learned, so the next time it can be read ahead.
##
## On the way into a run (main_menu.gd _finish_loading to a few seconds after main.gd _ready) a watching
## ResourceFormatLoader notes every file that is actually loaded (a cached one never reaches a loader): models,
## textures, sounds, shaders. It claims none of them, so each load goes on to the real loader as before. The list
## is kept in user://load_manifest.cfg under the level's id.
##
## The title screen (main_menu.gd _warm_level_resources) asks for all of them on loader threads, so by the time
## PLAY is pressed they are decoded and in memory, and the level's own load() calls find them there instead of
## reading ~230 files one after another while the screen is frozen. release() hands them back once the level
## holds its own references, so a level left behind does not stay pinned in memory.

const FILE := "user://load_manifest.cfg"
const REV := 1
const WATCH_AFTER_READY := 4.0       # s: the run's deferred warm-ups (death.gd warmup) load things then too

class Watch extends ResourceFormatLoader:
	var seen := {}
	var lock := Mutex.new()
	func _get_recognized_extensions() -> PackedStringArray:
		return PackedStringArray()
	func _handles_type(_type: StringName) -> bool:
		return true
	## Called for every file that is really loaded, on whichever thread loads it: noted, and never claimed
	func _recognize_path(path: String, _type: StringName) -> bool:
		if path.begins_with("res://") and not path.begins_with("res://.godot/") and not path.get_extension() in ["gd", "tscn"]:
			lock.lock()
			seen[path] = true
			lock.unlock()
		return false

static var _watch: Watch
static var _key := ""
static var _held := {}                   # path -> true: asked for ahead (warm), not yet handed back (release)

static func key_of(level_index: int) -> String:
	var levels: Array = load("res://scripts/World/level/level_data.gd").read_index()
	if levels.is_empty():
		return ""
	return str(levels[clampi(level_index, 0, levels.size() - 1)].get("id", ""))

## The files level `level_index` loaded the last time it was built (those still in the project)
static func paths(level_index: int) -> PackedStringArray:
	var out := PackedStringArray()
	var cfg := ConfigFile.new()
	var key := key_of(level_index)
	if key == "" or cfg.load(FILE) != OK or int(cfg.get_value("meta", "rev", 0)) != REV:
		return out
	for p: String in cfg.get_value("levels", key, PackedStringArray()):
		if ResourceLoader.exists(p):
			out.append(p)
	return out

## Start watching what is loaded: the run on level `level_index` is about to be built
static func record(level_index: int) -> void:
	if _watch != null:
		ResourceLoader.remove_resource_format_loader(_watch)
		_watch = null
	_key = key_of(level_index)
	if _key == "":
		return
	_watch = Watch.new()
	ResourceLoader.add_resource_format_loader(_watch, true)

## Stop watching (after `delay` seconds of the tree's time) and keep what was seen, with what was already known for
## the level (a file the build found in memory this time, because something else had it, may not be next time)
static func finish(tree: SceneTree, delay := WATCH_AFTER_READY) -> void:
	if _watch == null:
		return
	var w := _watch
	await tree.create_timer(delay, true).timeout
	if w == _watch:
		_stop()

static func _stop() -> void:
	ResourceLoader.remove_resource_format_loader(_watch)
	_watch.lock.lock()
	var seen := _watch.seen.duplicate()
	_watch.lock.unlock()
	_watch = null
	release()
	if _key == "" or seen.is_empty():
		return
	var cfg := ConfigFile.new()
	if cfg.load(FILE) != OK or int(cfg.get_value("meta", "rev", 0)) != REV:
		cfg = ConfigFile.new()
	for p: String in cfg.get_value("levels", _key, PackedStringArray()):
		if ResourceLoader.exists(p):
			seen[p] = true
	var list := PackedStringArray(seen.keys())
	list.sort()
	cfg.set_value("meta", "rev", REV)
	cfg.set_value("levels", _key, list)
	cfg.save(FILE)

## Ask for `list` on loader threads (whatever is already loading or loaded is left be). Returns the paths asked for.
static func warm(list: PackedStringArray) -> Array[String]:
	var out: Array[String] = []
	for p in list:
		if _held.has(p):
			out.append(p)
		elif ResourceLoader.exists(p) and ResourceLoader.load_threaded_request(p) == OK:
			_held[p] = true
			out.append(p)
	return out

## Hand back what warm() asked for: the run holds its own references by now
static func release() -> void:
	for p: String in _held:
		if ResourceLoader.load_threaded_get_status(p) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			ResourceLoader.load_threaded_get(p)
	_held.clear()
