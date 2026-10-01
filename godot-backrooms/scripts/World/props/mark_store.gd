extends RefCounted
## Tape and sketches kept on disk, per level, so they are still there next launch. <level id>.json holds
## {"tape": [...], "sketch": [...]}, one key per tool, so a level's .lvl is never touched by it. From the
## Godot editor or a level-editor test launch it goes in the project's levels/marks/; an exported game
## can't write res://, so there it goes in user://marks/.

## Only level-editor test launches save marks: there they are part of the level being built, and every
## run (exported or not) loads them with the level. What a player lays in a normal run is never saved.
static func active() -> bool:
	return Game.editor_test

## Marks belong to one floor of one level: the key the static lists are filed under (Net sends it as the
## strip's "level" too, so survivors on the same floor see each other's tape)
static func key(l: int = Game.level_index, f: int = Game.level_floor) -> int:
	return l * 1000 + (f + 500)

## The file name for the level's meta id on the floor being played (floor 0 keeps the plain id)
static func file_id(level_id: String, f: int = Game.level_floor) -> String:
	if level_id == "" or f == 0:
		return level_id
	return ("%s_b%d" % [level_id, -f]) if f < 0 else ("%s_f%d" % [level_id, f])

static func _path(id: String) -> String:
	if Game.editor_test or OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://levels/marks/%s.json" % id)
	return ProjectSettings.globalize_path("user://marks/%s.json" % id)

## The marks saved with the level. An exported game reads them from inside its .pck (res://), so
## the path is left unglobalized there.
static func read(id: String) -> Dictionary:
	if id == "":
		return {}
	var p := _path(id) if active() else "res://levels/marks/%s.json" % id
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null and id.contains("_b"):
		var alt := id.replace("_b", "_f-")
		f = FileAccess.open(_path(alt) if active() else "res://levels/marks/%s.json" % alt, FileAccess.READ)
	elif f == null and id.contains("_f-"):
		var alt := id.replace("_f-", "_b")
		f = FileAccess.open(_path(alt) if active() else "res://levels/marks/%s.json" % alt, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}

static func write(id: String, key: String, value: Array) -> bool:
	if not active() or id == "":
		return false
	var d := read(id)
	d[key] = value
	DirAccess.make_dir_recursive_absolute(_path(id).get_base_dir())
	var f := FileAccess.open(_path(id), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d))
	return true

static func v3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

static func arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
