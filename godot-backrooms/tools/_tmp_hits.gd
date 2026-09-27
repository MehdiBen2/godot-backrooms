extends SceneTree
# Temporary probe: where are the settings panel and its clickable parts, after layout?
var menu: Control
var frames := 0

func _initialize() -> void:
	menu = load("res://scenes/main_menu.tscn").instantiate()
	root.add_child(menu)

func _r(c: Control, tag: String) -> void:
	var g := c.get_global_rect()
	print("%-26s pos=(%d,%d) size=(%d,%d) filter=%s%s" % [
		tag, g.position.x, g.position.y, g.size.x, g.size.y, c.mouse_filter,
		(" text='%s'" % c.text) if c is Label or c is Button else ""])

func _walk(c: Control, depth: int) -> void:
	for ch in c.get_children():
		if not (ch is Control):
			continue
		var cls := str(ch).get_slice("<", 0).get_slice(":", 1)
		_r(ch, "  ".repeat(depth) + cls)
		_walk(ch as Control, depth + 1)

func _process(_dt: float) -> bool:
	frames += 1
	if frames < 4:
		return false
	if frames == 4:
		menu._open_panel("settings")
	if frames == 8:
		var m: Control = menu.settings_menu
		_r(m.panel, "panel")
		print("--- SETTINGS ---")
		_walk(m.sections["settings"], 0)
		menu._open_panel("graphics")
	if frames == 12:
		var m2: Control = menu.settings_menu
		_r(m2.panel, "panel")
		print("--- GRAPHICS ---")
		_walk(m2.sections["graphics"], 0)
		return true
	return false
