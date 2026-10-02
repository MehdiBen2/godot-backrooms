extends Node3D
## A model-only entity (placeholder, like THE KILLER): no behavior logic yet. `spawn <name>` in the debug
## console stands it in front of the player, turned to face them, to show how the model reads in the level
## (scale, texture, lighting). It stays put after that, so you can walk round it. Shared by the SkinStealer
## and Burnt nodes in main.tscn, which set the model and its size.

const GridNav := preload("res://scripts/World/grid_nav.gd")
const SPAWN_DIST := 3.5       # how far in front of the player it appears

@export_file("*.glb") var model := ""
@export var height := 1.9     # metres, feet to crown
## How tall the model stands in its own file, with its feet on its origin. Measured from the .glb's rest
## pose instead of read off the mesh nodes: both models are skinned, and a skinned mesh's bounds don't carry
## its armature's offset, so fitting by AABB (killer.gd) would sink it into the floor.
@export var source_height := 1.0
@export var yaw_offset := 0.0 # deg, for a model whose own front isn't +Z

var level: Node
var player: CharacterBody3D
var nav: GridNav
var body: Node3D
var present := false
var last_error := ""          # why the last debug_spawn() failed, for the console

func _ready() -> void:
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	nav = GridNav.new(level)
	visible = false

func _build() -> bool:
	var packed: PackedScene = null
	if ResourceLoader.exists(model):
		packed = load(model) as PackedScene
	if packed == null:
		last_error = "model not imported yet: open the project in the Godot editor once"
		push_warning("%s: %s did not load (not imported yet?)" % [name, model])
		return false
	body = packed.instantiate()
	add_child(body)
	body.scale = Vector3.ONE * (height / source_height)
	body.rotation.y = deg_to_rad(yaw_offset)
	for mi in body.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return true

## Stand it SPAWN_DIST ahead of the player (backing off if a wall is in the way), on the floor, facing them
func _place() -> bool:
	var p := player.global_position
	var fwd := -player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var d := SPAWN_DIST
	while d >= 1.5:
		var t := p + fwd * d
		if nav.open_at(t.x, t.z) and nav.clear_line(p.x, p.z, t.x, t.z):
			global_position = Vector3(t.x, _floor_y(t, p.y), t.z)
			rotation.y = atan2(-fwd.x, -fwd.z)
			return true
		d -= 0.5
	return false

func _floor_y(at: Vector3, fallback: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 1.5, at + Vector3.DOWN * 4.0)
	q.exclude = [player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else fallback

# ---------------------------------------------------------------- debug console
func debug_active() -> bool:
	return present

func debug_spawn() -> bool:
	last_error = ""
	if body == null and not _build():
		return false
	if not _place():
		last_error = "no room to spawn here, try another spot"
		return false
	present = true
	visible = true
	return true

func debug_despawn() -> void:
	present = false
	visible = false
