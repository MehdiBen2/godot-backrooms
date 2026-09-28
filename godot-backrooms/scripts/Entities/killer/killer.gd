extends Node3D
## THE KILLER (placeholder). Character_Monster_06 from the PSX Characters Extras pack, standing still,
## facing the player. No AI yet: it only exists so `spawn killer` in the debug console shows how the
## model reads in the level (scale, texture, lighting).

const GridNav := preload("res://scripts/World/grid_nav.gd")
const MODEL := "res://models/entities/killer/Character_Monster_06.fbx"
const TEXTURE := "res://models/entities/killer/Character_Monster_06.png"
const HEIGHT := 1.9           # metres, feet to crown
const SPAWN_DIST := 3.5       # how far in front of the player it appears
const BODY_YAW_OFFSET := -90.0 # deg: the FBX's own "front" isn't -Z, so the mesh needs this correction
                                # to actually face the direction the node turns to.

var level: Node
var player: CharacterBody3D
var nav: GridNav
var body: Node3D
var present := false

func _ready() -> void:
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	nav = GridNav.new(level)
	visible = false

func _process(_delta: float) -> void:
	if not present:
		return
	var to := player.global_position - global_position
	to.y = 0.0
	if to.length_squared() > 0.01:
		rotation.y = atan2(to.x, to.z)

func _build() -> bool:
	var packed := load(MODEL) as PackedScene
	if packed == null:
		push_warning("killer: %s did not load (not imported yet?)" % MODEL)
		return false
	body = packed.instantiate()
	add_child(body)
	var tex := load(TEXTURE) as Texture2D
	var mat: StandardMaterial3D = null
	if tex != null:
		mat = StandardMaterial3D.new()
		mat.albedo_texture = tex
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# Fit to HEIGHT with its feet on y = 0, whatever units the FBX came in
	var box := AABB()
	var first := true
	for mi in body.find_children("*", "MeshInstance3D", true, false):
		if mat != null:
			mi.material_override = mat
		var b: AABB = body.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first or box.size.y <= 0.0:
		return true
	var s := HEIGHT / box.size.y
	body.scale = Vector3.ONE * s
	body.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)
	body.rotation.y = deg_to_rad(BODY_YAW_OFFSET)
	return true

## Stand it SPAWN_DIST ahead of the player (backing off if a wall is in the way), on the floor
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
			return true
		d -= 0.5
	return false

func _floor_y(at: Vector3, fallback: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 1.5, at + Vector3.DOWN * 4.0)
	q.exclude = [player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else fallback

# ---------------------------------------------------------------- A.S.R.A. scanner
# Hold Q on it with the field scanner (scripts/Player/scanner.gd) to log it in the Threshold Dossier.
func _enter_tree() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("asra_id", "killer")

## Where the scanner can take a reading off it right now; empty while it is away
func scan_points() -> Array:
	if not present or body == null:
		return []
	return [global_position + Vector3.UP * HEIGHT * 0.6]

# ---------------------------------------------------------------- debug console
func debug_active() -> bool:
	return present

func debug_spawn() -> bool:
	if body == null and not _build():
		return false
	if not _place():
		return false
	present = true
	visible = true
	return true

func debug_despawn() -> void:
	present = false
	visible = false
