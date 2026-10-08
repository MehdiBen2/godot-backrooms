extends SceneTree

func _init():
	var l = SpotLight3D.new()
	l.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	print("Direction: ", -l.global_transform.basis.z)
	quit()
