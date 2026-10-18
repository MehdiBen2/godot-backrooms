extends SceneTree
## The quick item strip (hud/item_strip.gd): idle, then a battery pickup, then wheel steps through the slots,
## saving the view each time, then opens the terminal for a last one. Needs a window. Env: LEVEL (index, default 0), SHOT (output prefix, default res://strip).
## powershell -File tools/run_bg.ps1 -Offscreen -GodotArgs "--resolution 1280x720 --script res://tools/shot_strip.gd"

func _initialize() -> void:
	var game: Node = root.get_node("Game")
	game.level_index = int(OS.get_environment("LEVEL")) if OS.get_environment("LEVEL") != "" else 0
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(3.0).timeout
	game.playing = true
	var prefix: String = OS.get_environment("SHOT") if OS.get_environment("SHOT") != "" else "res://strip"
	var ui: Node = main.get_node("UI")
	var inv: Node = ui.inventory
	var strip: Node = null
	for c in ui.hud_root.get_children():
		if c.get_script() != null and str(c.get_script().resource_path).ends_with("item_strip.gd"):
			strip = c
	print("strip ", strip, " slots ", strip.slots.size() if strip else -1)
	await create_timer(4.0).timeout
	root.get_texture().get_image().save_png(prefix + "_idle.png")
	ui.pick_up_item("battery", "AA Battery Pack", "", "BAT", 6, "res://models/aa_batteries.glb")
	await create_timer(0.4).timeout
	root.get_texture().get_image().save_png(prefix + "_pickup.png")
	await create_timer(4.0).timeout
	strip._step(1)
	strip._step(1)
	await create_timer(0.8).timeout
	root.get_texture().get_image().save_png(prefix + "_scroll.png")
	print("sel ", strip.sel_id, " slots ", strip.slots.size())
	# the hotbar: a click does what the item in hand does
	var pl: Node = main.get_node("Player")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await create_timer(0.3).timeout
	var on0: bool = pl.flash_on
	strip.sel_id = "torch"
	strip._click()
	print("torch click: ", on0, " -> ", pl.flash_on)
	strip._click()
	strip.sel_id = "scanner"
	var down: InputEventMouseButton = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	Input.parse_input_event(down)
	await create_timer(0.1).timeout
	print("scanner held: using=", strip.using("scanner"), " tape using=", strip.using("tape"), " can_use=", strip._can_use())
	var up: InputEventMouseButton = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	Input.parse_input_event(up)
	strip.sel_id = "flash"
	var f0: int = inv.item_count("flash")
	strip._click()
	print("flash click: ", f0, " -> ", inv.item_count("flash"))
	strip.sel_id = "torch"
	strip._step(0)
	await create_timer(0.6).timeout
	root.get_texture().get_image().save_png(prefix + "_hotbar.png")
	inv.set_shown(true)
	await create_timer(2.0).timeout
	root.get_texture().get_image().save_png(prefix + "_terminal.png")
	quit()
