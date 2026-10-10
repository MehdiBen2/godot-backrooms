extends SceneTree
## Draws a picture of every model prop (object_types.json "model") and saves it as res://thumbs/<type>.png,
## which the level editor's PROPS tab shows on each tile. Run it once, and again after a model changes:
##   Godot_v4.7.2-stable_win64_console.exe --path level-editor --script res://tools/render_prop_thumbs.gd
## It needs a real window (not --headless): it renders with the editor's own 3D code (level_editor_3d.gd, prop_thumb).
## The game folder is the same one the editor uses: BACKROOMS_GAME_DIR, else ../godot-backrooms.

const Host := preload("res://tools/thumb_host.gd")
const View := preload("res://level_editor_3d.gd")
const OUT_DIR := "res://thumbs"

func _initialize() -> void:
	var game: String = OS.get_environment("BACKROOMS_GAME_DIR") if OS.has_environment("BACKROOMS_GAME_DIR") \
		else ProjectSettings.globalize_path("res://").path_join("../godot-backrooms").simplify_path()
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(game.path_join("levels/object_types.json")))
	if not (parsed is Dictionary):
		push_error("cannot read levels/object_types.json in " + game)
		quit(1)
		return
	var host := Host.new()
	host.GAME = game
	for t in parsed:
		if str(t).begins_with("_") or not (parsed[t] is Dictionary): continue
		var inf: Dictionary = parsed[t].duplicate()
		inf["col"] = Color(str(inf.get("color", "a39c8a")))
		host.OBJ_INFO[t] = inf
	root.add_child(host)
	var view = View.new(host)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var done := 0
	var failed: Array = []
	for t in host.OBJ_INFO:
		if not host.OBJ_INFO[t].has("model"): continue
		var tex: Texture2D = await view.prop_thumb(t)
		if tex == null:
			failed.append(t)
			continue
		tex.get_image().save_png(OUT_DIR.path_join(t + ".png"))
		done += 1
		print("drew %s" % t)
	print("%d pictures written to %s" % [done, ProjectSettings.globalize_path(OUT_DIR)])
	if not failed.is_empty(): print("no model could be read for: %s" % ", ".join(failed))
	quit(0)
