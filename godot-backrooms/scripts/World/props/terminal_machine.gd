extends Node3D

const TerminalUI = preload("res://scripts/UI/terminal_machine_ui.gd")

var ui_instance: Control = null

func _ready() -> void:
	var base_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.7, 1.4, 0.6)
	base_mesh.mesh = box
	
	var chassis_mat := StandardMaterial3D.new()
	chassis_mat.albedo_color = Color(0.12, 0.13, 0.14)
	chassis_mat.metallic = 0.5
	chassis_mat.roughness = 0.4
	base_mesh.material_override = chassis_mat
	base_mesh.position.y = 0.7
	add_child(base_mesh)
	
	# Amber glowing CRT screen on front
	var screen_mesh := MeshInstance3D.new()
	var s_quad := QuadMesh.new()
	s_quad.size = Vector2(0.48, 0.36)
	screen_mesh.mesh = s_quad
	var screen_mat := StandardMaterial3D.new()
	screen_mat.albedo_color = Color(0.04, 0.03, 0.01)
	screen_mat.emission_enabled = true
	screen_mat.emission = Color("f0a838")
	screen_mat.emission_energy_multiplier = 2.0
	screen_mesh.material_override = screen_mat
	screen_mesh.position = Vector3(0, 0.95, 0.302)
	add_child(screen_mesh)
	
	# Warm amber screen light
	var light := OmniLight3D.new()
	light.light_color = Color("f0a838")
	light.light_energy = 1.2
	light.omni_range = 3.5
	light.position = Vector3(0, 0.95, 0.5)
	add_child(light)
	
	var static_body := StaticBody3D.new()
	var col_shape := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box.size
	col_shape.shape = shape
	col_shape.position.y = 0.7
	static_body.add_child(col_shape)
	add_child(static_body)

func can_interact(_from_pos: Vector3) -> bool:
	return true

func get_interact_prompt() -> String:
	return "ACCESS T.S.R.A. TERMINAL"

func interact(player: Node3D) -> bool:
	if ui_instance != null and is_instance_valid(ui_instance):
		return false
	
	var ui_node = Game.main.get_node_or_null("UI")
	if ui_node == null: return false
	
	ui_instance = TerminalUI.new()
	ui_instance.player = player
	if ui_node.get("inventory"):
		ui_instance.inventory = ui_node.inventory
	ui_node.add_child(ui_instance)
	
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.frozen = true
	ui_instance.connect("closed", Callable(self, "_on_ui_closed").bind(player))
	
	return true

func _on_ui_closed(player: Node3D) -> void:
	if player and is_instance_valid(player):
		player.frozen = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	ui_instance = null

