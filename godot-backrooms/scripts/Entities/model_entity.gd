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
## Plays the file's idle clip (one named "idle", else its first), looped. Just the clip: no behaviour.
@export var auto_anim := false

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
	body.rotation.y = deg_to_rad(yaw_offset)
	if source_height > 0.0:
		body.scale = Vector3.ONE * (height / source_height)
	else:
		_fit()
	for mi in body.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		(mi as MeshInstance3D).extra_cull_margin = 2.0          # (a skinned mesh's box doesn't follow its pose)
	if auto_anim:
		_play_idle()
	return true

## source_height 0: measure the model as it stands in its file and scale it to `height` (0: as it is), its feet on
## the floor and its middle on the origin. A rigged model is measured on its bones (a skinned mesh's box is its
## bind pose, often a hundredth or a hundred times the size it is drawn at): the crown and the toes stand a little
## past the head and foot bones, hence the 12% more.
func _fit() -> void:
	var lo := Vector3.INF
	var hi := -Vector3.INF
	var rigged := false
	for sk in body.find_children("*", "Skeleton3D", true, false):
		var skel := sk as Skeleton3D
		if skel.get_bone_count() < 3: continue
		var to_body := _in_body(skel)
		for b in skel.get_bone_count():
			var q := to_body * skel.get_bone_global_rest(b).origin
			lo = lo.min(q)
			hi = hi.max(q)
		rigged = true
	if rigged:
		var pad := (hi.y - lo.y) * 0.06
		lo.y -= pad
		hi.y += pad
	else:
		for n in body.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi.mesh == null: continue
			var box := _in_body(mi) * mi.mesh.get_aabb()
			lo = lo.min(box.position)
			hi = hi.max(box.end)
	if lo.x == INF or hi.y - lo.y < 0.0001: return
	var k := 1.0 if height <= 0.0 else height / (hi.y - lo.y)
	var mid := (lo + hi) * 0.5
	body.scale = Vector3.ONE * k
	body.position = body.basis * Vector3(-mid.x, -lo.y, -mid.z)

## `n`'s transform in the body's own space (before the body is turned or scaled)
func _in_body(n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var p: Node = n
	while p != null and p != body:
		xf = (p as Node3D).transform * xf if p is Node3D else xf
		p = p.get_parent()
	return xf

func _play_idle() -> void:
	var ap: AnimationPlayer = null
	for n in body.find_children("*", "AnimationPlayer", true, false):
		ap = n as AnimationPlayer
		break
	if ap == null: return
	var names := ap.get_animation_list()
	var pick := ""
	for a in names:
		if a == "RESET": continue
		if pick == "": pick = a
		if a.to_lower().contains("idle"):
			pick = a
			break
	if pick == "": return
	ap.get_animation(pick).loop_mode = Animation.LOOP_LINEAR
	ap.play(pick)

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

## Stand it on the floor at `at`, turned to face the player (a level editor mark places it here)
func spawn_at(at: Vector3) -> bool:
	last_error = ""
	if body == null and not _build():
		return false
	global_position = Vector3(at.x, _floor_y(at, player.global_position.y), at.z)
	var to := player.global_position - global_position
	rotation.y = atan2(to.x, to.z)
	present = true
	visible = true
	return true
