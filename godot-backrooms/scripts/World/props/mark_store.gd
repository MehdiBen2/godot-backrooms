extends RefCounted
## Tape and sketches kept on disk, per level, so they are still there next launch. <level id>.json holds
## {"tape": [...], "sketch": [...]}, one key per tool, so a level's .lvl is never touched by it. From the
## Godot editor or a level-editor test launch it goes in the project's levels/marks/; an exported game
## can't write res://, so there it goes in user://marks/.

static func active() -> bool:
	return true

static func _path(id: String) -> String:
	if Game.test_level != "" or OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://levels/marks/%s.json" % id)
	return ProjectSettings.globalize_path("user://marks/%s.json" % id)

static func read(id: String) -> Dictionary:
	if not active() or id == "":
		return {}
	var f := FileAccess.open(_path(id), FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}

static func write(id: String, key: String, value: Array) -> void:
	if not active() or id == "":
		return
	var d := read(id)
	d[key] = value
	DirAccess.make_dir_recursive_absolute(_path(id).get_base_dir())
	var f := FileAccess.open(_path(id), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))

static func v3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

static func arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
