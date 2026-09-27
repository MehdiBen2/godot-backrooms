extends Node3D
## A battery pack lying on the carpet. Walking over it tops up the flashlight.
## Spawned at random open cells by level_builder._spawn_batteries.

const TRIGGER_RADIUS := 0.9
const CHARGE := 45.0           # % of battery restored

const MODEL_PATH := "res://models/aa_batteries.glb"
const MODEL_SIZE := 0.3          # metres, longest side
static var model_scene: PackedScene    # a .glb can't be preloaded off the main thread, so the menu's threaded load would stall on it

var used := false
var light: OmniLight3D

func _ready() -> void:
	if model_scene == null:
		model_scene = load(MODEL_PATH)
	var model: Node3D = model_scene.instantiate()
	add_child(model)
	# fit the model to ~MODEL_SIZE along its longest side and rest it on the floor
	var box := _mesh_aabb(model, Transform3D.IDENTITY)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if longest > 0.0:
		var k := MODEL_SIZE / longest
		model.scale = Vector3.ONE * k
		var c := box.get_center()
		model.position = Vector3(-c.x * k, -box.position.y * k, -c.z * k)
	light = OmniLight3D.new()           # faint green glint so it can be found in the dark
	light.light_color = Color(0.3, 1.0, 0.6)
	light.omni_range = 1.2
	light.light_energy = 0.4
	light.shadow_enabled = false
	light.position = Vector3(0, 0.25, 0)
	add_child(light)

func _process(_delta: float) -> void:
	light.light_energy = 0.3 + 0.15 * sin(Game.time * 2.5 + position.x)
	if used or Game.dead or not Game.playing:
		return
	var player: Node3D = get_parent().player
	if player == null or player.battery >= 100.0:
		return                           # full battery: leave it for later
	var d := Vector2(player.global_position.x - global_position.x, player.global_position.z - global_position.z).length()
	if d < TRIGGER_RADIUS and absf(player.global_position.y - global_position.y) < 2.0:
		used = true
		player.battery = minf(100.0, player.battery + CHARGE)
		var audio: Node = Game.main.get_node_or_null("Audio") if Game.main != null else null
		if audio:
			audio.play_world("flash_click_on.wav")
		queue_free()

func _mesh_aabb(n: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	var t: Transform3D = xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	var mi := n as MeshInstance3D
	if mi and mi.mesh:
		out = t * mi.mesh.get_aabb()
		first = false
	for ch in n.get_children():
		var sub := _mesh_aabb(ch, t)
		if sub.size == Vector3.ZERO: continue
		out = sub if first else out.merge(sub)
		first = false
	return out
