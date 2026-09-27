extends Node
## F2 teleports the player between the backrooms and the hills level, and back.
## The hills scene is built on the first visit and kept for later ones. While away, the backrooms
## level is hidden with its collision off, and the things that hunt the player are paused.

const HILLS_SCENE := preload("res://scenes/hills.tscn")
const PAUSED := ["Entity", "Mannequin", "Mimic", "Watcher", "Eyes", "Events", "Level"]
const HILLS_FAR := 2500.0

var hills: Node3D
var in_hills := false
var saved_env: Environment
var saved_far := 200.0
var return_pos := Vector3.ZERO
var return_yaw := 0.0
var shapes: Array[CollisionShape3D] = []

func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_F2 and not e.shift_pressed):
		return
	if not Game.playing or Game.dead or Death.respawn_busy:
		return
	get_viewport().set_input_as_handled()
	if in_hills:
		_leave()
	else:
		_enter()

func _enter() -> void:
	var main := get_parent()
	var player: CharacterBody3D = main.get_node("Player")
	var level: Node3D = main.get_node("Level")
	if hills == null:
		hills = HILLS_SCENE.instantiate()
		hills.standalone = false
	main.add_child(hills)               # first time this builds the terrain, so expect a short hitch
	in_hills = true
	Game.outdoors = true
	return_pos = player.global_position
	return_yaw = player.rotation.y
	var we: WorldEnvironment = main.get_node("WorldEnvironment")
	saved_env = we.environment
	we.environment = hills.env
	saved_far = player.cam.far
	player.cam.far = HILLS_FAR
	shapes.clear()
	for c in level.find_children("*", "CollisionShape3D", true, false):
		shapes.append(c)
		c.set_deferred("disabled", true)
	level.visible = false
	for n in PAUSED:
		var node := main.get_node_or_null(n)
		if node:
			node.process_mode = Node.PROCESS_MODE_DISABLED
	player.velocity = Vector3.ZERO
	player.global_position = hills.spawn_position()

func _leave() -> void:
	var main := get_parent()
	var player: CharacterBody3D = main.get_node("Player")
	var level: Node3D = main.get_node("Level")
	in_hills = false
	Game.outdoors = false
	main.remove_child(hills)
	main.get_node("WorldEnvironment").environment = saved_env
	player.cam.far = saved_far
	for c in shapes:
		if is_instance_valid(c):
			c.set_deferred("disabled", false)
	shapes.clear()
	level.visible = true
	for n in PAUSED:
		var node := main.get_node_or_null(n)
		if node:
			node.process_mode = Node.PROCESS_MODE_INHERIT
	player.velocity = Vector3.ZERO
	player.global_position = return_pos
	player.rotation.y = return_yaw
