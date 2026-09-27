extends SceneTree
# Temporary: screenshot the settings sliders with the old (14px) and new (26px) control heights
var menu: Control
var frames := 0
var mode := ""

func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	menu = load("res://scenes/main_menu.tscn").instantiate()
	root.add_child(menu)

func _sliders() -> Array:
	return menu.settings_menu.sections["settings"].find_children("*", "HSlider", true, false)

func _shot(tag: String) -> void:
	var img := root.get_texture().get_image()
	var file := "/tmp/sliders_%s.png" % tag
	img.save_png(file)
	print("saved %s %s" % [file, img.get_size()])

func _process(_dt: float) -> bool:
	frames += 1
	if frames == 5:
		menu._open_panel("settings")
	if frames == 25:
		for s in _sliders():
			s.custom_minimum_size = Vector2(0, 14)
	if frames == 30:
		_shot("14")
		for s in _sliders():
			s.custom_minimum_size = Vector2(0, 26)
	if frames == 35:
		_shot("26")
	if frames == 40:
		return true
	return false
