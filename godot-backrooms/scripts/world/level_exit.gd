extends Node3D
## The level's exit (js/level.js createLevel0ExitDoor, simplified): a lit doorway at the exit cell.
## Walking into it goes to the next level in the playlist; the last one wraps to the first.
## Papers / unlock are not ported yet, so it is always open.

const TRIGGER_RADIUS := 1.3

var light: OmniLight3D
var used := false

func _ready() -> void:
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.16, 0.17, 0.17)
	steel.metallic = 0.8
	steel.roughness = 0.45
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.2, 1.0, 0.6)
	glow.emission_enabled = true
	glow.emission = Color(0.2, 1.0, 0.6)
	glow.emission_energy_multiplier = 2.5
	# [size, position, material]: two posts, a lintel, a light strip and a floor pad
	for part in [[Vector3(0.25, 3.0, 0.3), Vector3(-1.1, 1.5, 0), steel], [Vector3(0.25, 3.0, 0.3), Vector3(1.1, 1.5, 0), steel],
			[Vector3(2.45, 0.25, 0.3), Vector3(0, 3.0, 0), steel], [Vector3(2.0, 0.06, 0.06), Vector3(0, 2.8, 0.16), glow],
			[Vector3(1.9, 0.02, 1.9), Vector3(0, 0.02, 0.0), glow]]:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = part[0]
		mi.mesh = box
		mi.position = part[1]
		mi.material_override = part[2]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	light = OmniLight3D.new()
	light.light_color = Color(0.3, 1.0, 0.65)
	light.omni_range = 9.0
	light.position = Vector3(0, 2.6, 0.8)
	add_child(light)

func _process(_delta: float) -> void:
	light.light_energy = 1.6 + sin(Game.time * 3.0) * 0.4
	if used or Game.dead or not Game.playing:
		return
	var player: Node3D = get_parent().player
	if player == null:
		return
	var d := Vector2(player.global_position.x - global_position.x, player.global_position.z - global_position.z).length()
	if d < TRIGGER_RADIUS:
		used = true
		Game.next_level()
