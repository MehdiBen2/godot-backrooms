extends Node3D
## Fallen / Burnt Fluorescent Troffer Fixture.
## An anomalous ballast casing with broken tubes and scorched capacitor housing.
## Scannable with the Field Scanner (hold Q) to earn Research Yield (+25 YLD).
## Built with distance-based visibility culling.

const ArchiveScript := preload("res://scripts/GameLogicEngine/asra_archive.gd")
const ASRA_ID := "dead_ballast"
const YIELD_AMOUNT := 25

var inspected := false
var mesh_root: Node3D
var spark_light: OmniLight3D
var spark_timer := 0.0

func _ready() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("asra_id", ASRA_ID)
	_build_mesh()

func _process(dt: float) -> void:
	spark_timer -= dt
	if spark_timer <= 0.0:
		spark_timer = randf_range(2.5, 7.0)
		if spark_light != null and not inspected:
			spark_light.light_energy = randf_range(0.8, 2.2)
			get_tree().create_timer(randf_range(0.05, 0.12)).timeout.connect(func():
				if is_instance_valid(spark_light): spark_light.light_energy = 0.0
			)

func _build_mesh() -> void:
	mesh_root = Node3D.new()
	add_child(mesh_root)

	# 1. Bent metal troffer housing
	var body := MeshInstance3D.new()
	var b_box := BoxMesh.new()
	b_box.size = Vector3(1.2, 0.08, 0.35)
	body.mesh = b_box
	var b_mat := StandardMaterial3D.new()
	b_mat.albedo_color = Color(0.28, 0.29, 0.28) # Oxidized, scorched steel
	b_mat.metallic = 0.7
	b_mat.roughness = 0.55
	body.material_override = b_mat
	body.visibility_range_end = 45.0
	body.visibility_range_end_margin = 8.0
	body.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mesh_root.add_child(body)

	# 2. Shattered tube fragments
	for i in range(-1, 2):
		var tube := MeshInstance3D.new()
		var t_cyl := CylinderMesh.new()
		t_cyl.top_radius = 0.02
		t_cyl.bottom_radius = 0.02
		t_cyl.height = randf_range(0.35, 0.6)
		tube.mesh = t_cyl
		tube.rotation.z = PI / 2.0
		tube.position = Vector3(randf_range(-0.2, 0.2), -0.02, i * 0.09)
		var t_mat := StandardMaterial3D.new()
		t_mat.albedo_color = Color(0.18, 0.16, 0.14) # Burnt phosphor glass
		t_mat.roughness = 0.35
		t_mat.metallic_specular = 0.9
		tube.material_override = t_mat
		tube.visibility_range_end = 45.0
		tube.visibility_range_end_margin = 8.0
		tube.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mesh_root.add_child(tube)

	# 3. Occasional spark/crackle light
	spark_light = OmniLight3D.new()
	spark_light.light_color = Color(0.4, 0.7, 1.0)
	spark_light.light_energy = 0.0
	spark_light.omni_range = 3.5
	spark_light.shadow_enabled = false
	mesh_root.add_child(spark_light)

## Scanner interface for Q (scanner.gd)
func scan_points() -> Array:
	return [global_position + Vector3(0, 0.1, 0)]

## Scanner behavior readout (scanner.gd)
func scan_behavior(_at: Vector3) -> Dictionary:
	return {
		"state": "ANOMALOUS HARMONIC" if not inspected else "EXHAUSTED CELL",
		"danger": 1 if not inspected else 0,
		"detail": "60Hz Residual Resonance (+%d YLD) // Severed Feed" % YIELD_AMOUNT
	}

## Called when scan completes
func on_scanned() -> void:
	if not inspected:
		inspected = true
		Clearance.grant(YIELD_AMOUNT)
		if spark_light != null:
			spark_light.light_energy = 0.0
