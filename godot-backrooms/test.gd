extends SceneTree

func _init():
	var l = SpotLight3D.new()
	var CEIL_LAYER = 1 << 18
	var SHELL_LAYERS = (1 << 10) | (1 << 11)
	print("Initial: ", l.light_cull_mask)
	l.light_cull_mask &= ~(CEIL_LAYER | SHELL_LAYERS)
	print("Final: ", l.light_cull_mask)
	quit()
