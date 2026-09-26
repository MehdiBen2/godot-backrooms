extends SceneTree
## Compiles every script under res://scripts and res://tools and reports the ones that fail.
## godot --headless --path . --script res://tools/check_scripts.gd

var _done := false

func _process(_dt: float) -> bool:
	if _done:
		return true
	_done = true
	var bad := 0
	var count := 0
	for dir in ["res://scripts", "res://tools"]:
		for path in _scripts(dir):
			count += 1
			var s: Script = load(path)
			if s == null or not s.can_instantiate():
				bad += 1
				print("FAILED: ", path)
	print("checked %d scripts, %d failed" % [count, bad])
	quit(1 if bad > 0 else 0)
	return false

func _scripts(dir: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		out.append_array(_scripts(dir.path_join(sub)))
	return out
