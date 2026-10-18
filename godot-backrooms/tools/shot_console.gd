extends SceneTree
## Opens the debug console on its own (no level) and saves a picture of each tab to user://console_*.png:
##   powershell -File tools/run_bg.ps1 -Offscreen -GodotArgs "--resolution 1280x720 --script res://tools/shot_console.gd"

func _init() -> void:
	await process_frame
	var holder := Node.new()
	holder.name = "Main"
	root.add_child(holder)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.06, 0.04)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bgl := CanvasLayer.new()
	bgl.layer = -1
	bgl.add_child(bg)
	holder.add_child(bgl)
	var con: CanvasLayer = load("res://scripts/UI/debug/debug_console.gd").new()
	con.name = "Console"
	holder.add_child(con)
	await process_frame
	con.unlocked = true
	con.open_menu()
	for cmd in ["help", "levels", "mark spot", "marks", "timescale 0.5", "timescale 1", "echo hello", "bogus"]:
		con._submit(cmd)
	con.input.text = "sp"
	con._update_hint("sp")
	con._complete()
	for tab in ["console", "cheats", "entities", "world", "teleport", "game", "anim"]:
		con._switch_tab(tab)
		for i in 4:
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		img.save_png("user://console_%s.png" % tab)
		print("saved ", ProjectSettings.globalize_path("user://console_%s.png" % tab))
	quit()
