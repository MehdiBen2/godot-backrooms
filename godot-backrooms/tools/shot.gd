extends SceneTree
## Dev-only capture: opens a level the way the level editor does (--test-level=<id>) and saves the frame at spawn.
## Usage: godot --path <project> --script res://tools/shot.gd -- --test-level=level0 --shot=<out.png>
## Not part of the game; delete when done.

var _frames := 0
var _out := ""
var _wait := 360

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="): _out = a.substr(7)
	change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < _wait:
		return false
	var img := root.get_texture().get_image()
	var err := img.save_png(_out)
	print("SHOT ", _out, " err=", err, " size=", img.get_size())
	quit(0)
	return true
