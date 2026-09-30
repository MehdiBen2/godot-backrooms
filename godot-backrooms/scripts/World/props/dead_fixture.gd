extends Node3D
## Fallen / Burnt Fluorescent Troffer Fixture.
## An anomalous ballast casing with broken tubes and scorched capacitor housing.
## Scannable with the Field Scanner (hold Q) to earn Research Yield (+25 YLD).
## Uses the ceiling troffer model (burnt out), with distance-based visibility culling.

const ArchiveScript := preload("res://scripts/GameLogicEngine/asra_archive.gd")
const ASRA_ID := "dead_ballast"
const TROFFER := preload("res://models/lights/office_lighting_troffer_light_1x4.glb")
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

## The same troffer model the ceilings use (level_fixtures.gd), burnt out and fallen: flipped onto its back
## with one end propped up, resting on the floor.
func _build_mesh() -> void:
	mesh_root = Node3D.new()
	add_child(mesh_root)

	var model: Node3D = TROFFER.instantiate()
	# mesh parts as level_fixtures.gd names them: 3 housing, 4 tray, 5 tubes, 2 diffuser lens
	var housing_mat := StandardMaterial3D.new()
	housing_mat.albedo_color = Color("8f8a80"); housing_mat.roughness = 0.75; housing_mat.metallic = 0.3
	var tray_mat := StandardMaterial3D.new()
	tray_mat.albedo_color = Color("a8a499"); tray_mat.roughness = 0.6; tray_mat.metallic = 0.25
	var tubes_mat := StandardMaterial3D.new()
	tubes_mat.albedo_color = Color("221f1a"); tubes_mat.roughness = 0.9; tubes_mat.metallic = 0.1
	var lens_mat := StandardMaterial3D.new()
	lens_mat.albedo_color = Color(0.2, 0.188, 0.157, 0.65)
	lens_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	lens_mat.roughness = 0.85
	var mats := {"Object_2": lens_mat, "Object_3": housing_mat, "Object_4": tray_mat, "Object_5": tubes_mat}
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		mi.material_override = mats.get(String(mi.name), housing_mat)
		mi.visibility_range_end = 45.0
		mi.visibility_range_end_margin = 8.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

	# fell out of the grid and landed flat on its back (lens up); a tilt across a 1.2m-long fixture reads as floating
	model.rotation = Vector3(0.0, 0.0, PI)
	mesh_root.add_child(model)
	# rest its lowest point on the floor, whatever the model's own origin is
	var lowest := INF
	var inv := mesh_root.global_transform.affine_inverse() if mesh_root.is_inside_tree() else Transform3D.IDENTITY
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var t := inv * mi.global_transform
		var box := mi.mesh.get_aabb()
		for i in 8:
			lowest = minf(lowest, (t * box.get_endpoint(i)).y)
	if lowest != INF:
		model.position.y -= lowest - 0.01  # sink slightly into the carpet so no gap shows

	# occasional spark/crackle light out of the dead ballast
	spark_light = OmniLight3D.new()
	spark_light.light_color = Color(0.4, 0.7, 1.0)
	spark_light.light_energy = 0.0
	spark_light.omni_range = 3.5
	spark_light.shadow_enabled = false
	spark_light.position = Vector3(0, 0.15, 0)
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
