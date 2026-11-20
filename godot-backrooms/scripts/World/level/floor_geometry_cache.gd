class_name FloorGeometryCache
extends Resource
## Immutable geometry resources for a floor. Live nodes and materials attach to them each visit.

# Bump when the generated geometry changes between builds.
const FORMAT_VERSION := 2
const CACHE_DIR := "user://floor_geometry"
const MEMORY_LIMIT := 4
const DISK_LIMIT := 24

@export var fingerprint := ""
@export var entries := {}

var _dirty := false
var _path := ""

static func for_floor(meta: Dictionary, raw: Dictionary, floor_number: int, object_schema: String, shell: bool, recent: Dictionary) -> FloorGeometryCache:
	var renderer := "%s/%s" % [DisplayServer.get_name(), RenderingServer.get_current_rendering_method()]
	var identity := "%s/%s/%d/%s/%s" % [meta.get("file", ""), meta.get("id", ""), floor_number, renderer, "shell" if shell else "full"]
	var revision := "%d/%s/%s/%s" % [FORMAT_VERSION, Engine.get_version_info().hash, object_schema, JSON.stringify(raw, "", true, true).sha256_text()]
	var path := "%s/%s.res" % [CACHE_DIR, identity.sha256_text()]
	var cache: FloorGeometryCache = recent.get(path)
	if cache == null or cache.fingerprint != revision:
		cache = null
		if FileAccess.file_exists(path):
			cache = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as FloorGeometryCache
		if cache == null or cache.fingerprint != revision:
			cache = FloorGeometryCache.new()
			cache.fingerprint = revision
		cache._path = path
	recent.erase(path)
	recent[path] = cache
	if recent.size() > MEMORY_LIMIT:
		recent.erase(recent.keys()[0])
	return cache

func store(key: String, value: Variant) -> void:
	entries[key] = value
	_dirty = true

func save() -> void:
	if not _dirty or _path.is_empty():
		return
	if DirAccess.make_dir_recursive_absolute(CACHE_DIR) != OK:
		return
	var temporary := "%s.%d.tmp.res" % [_path, OS.get_process_id()]
	if ResourceSaver.save(self, temporary, ResourceSaver.FLAG_COMPRESS) == OK and DirAccess.rename_absolute(temporary, _path) == OK:
		_dirty = false
		_prune_disk()
	elif FileAccess.file_exists(temporary):
		DirAccess.remove_absolute(temporary)

func _prune_disk() -> void:
	var paths: Array[String] = []
	for filename: String in DirAccess.get_files_at(CACHE_DIR):
		var path := CACHE_DIR.path_join(filename)
		if filename.length() == 68 and filename.ends_with(".res") and path != _path:
			paths.append(path)
	if paths.size() < DISK_LIMIT:
		return
	paths.sort_custom(func(a: String, b: String) -> bool: return FileAccess.get_modified_time(a) < FileAccess.get_modified_time(b))
	for path in paths.slice(0, paths.size() - DISK_LIMIT + 1):
		DirAccess.remove_absolute(path)
