extends Node3D
## Abandoned Survey Clipboard. Left behind by previous T.S.R.A. exploration teams.
## Scannable with the Field Scanner (hold Q) to extract lost surveyor notes and earn Research Yield (+40 YLD).
## Built with distance-based visibility culling.

const ArchiveScript := preload("res://scripts/GameLogicEngine/asra_archive.gd")
const ASRA_ID := "survey_clipboard"
const YIELD_AMOUNT := 40

var inspected := false
var mesh_root: Node3D
var glow_indicator: MeshInstance3D

func _ready() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("asra_id", ASRA_ID)
	_build_mesh()

func _build_mesh() -> void:
	mesh_root = Node3D.new()
	add_child(mesh_root)

	# 1. Wooden clipboard body
	var board := MeshInstance3D.new()
	var b_box := BoxMesh.new()
	b_box.size = Vector3(0.32, 0.02, 0.44)
	board.mesh = b_box
	var b_mat := StandardMaterial3D.new()
	b_mat.albedo_color = Color(0.36, 0.24, 0.14) # Aged pressed hardboard
	b_mat.roughness = 0.85
	board.material_override = b_mat
	board.visibility_range_end = 45.0
	board.visibility_range_end_margin = 8.0
	board.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mesh_root.add_child(board)

	# 2. Paper sheet on top
	var paper := MeshInstance3D.new()
	var p_box := BoxMesh.new()
	p_box.size = Vector3(0.28, 0.005, 0.38)
	paper.mesh = p_box
	paper.position = Vector3(0, 0.012, 0.01)
	var p_mat := StandardMaterial3D.new()
	p_mat.albedo_color = Color(0.92, 0.89, 0.78) # Yellowed manila paper
	p_mat.roughness = 0.95
	paper.material_override = p_mat
	paper.visibility_range_end = 45.0
	paper.visibility_range_end_margin = 8.0
	paper.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mesh_root.add_child(paper)

	# 3. Steel clip at top
	var clip := MeshInstance3D.new()
	var c_box := BoxMesh.new()
	c_box.size = Vector3(0.14, 0.025, 0.06)
	clip.mesh = c_box
	clip.position = Vector3(0, 0.02, -0.17)
	var c_mat := StandardMaterial3D.new()
	c_mat.albedo_color = Color(0.6, 0.62, 0.65)
	c_mat.metallic = 0.85
	c_mat.roughness = 0.3
	clip.material_override = c_mat
	clip.visibility_range_end = 45.0
	clip.visibility_range_end_margin = 8.0
	clip.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mesh_root.add_child(clip)

	# 4. Reflective T.S.R.A. survey marker tag
	glow_indicator = MeshInstance3D.new()
	var tag_box := BoxMesh.new()
	tag_box.size = Vector3(0.04, 0.008, 0.04)
	glow_indicator.mesh = tag_box
	glow_indicator.position = Vector3(0.1, 0.016, 0.16)
	var g_mat := StandardMaterial3D.new()
	g_mat.albedo_color = Color(0.95, 0.65, 0.15)
	g_mat.emission_enabled = true
	g_mat.emission = Color(0.95, 0.65, 0.15)
	g_mat.emission_energy_multiplier = 0.8
	glow_indicator.material_override = g_mat
	glow_indicator.visibility_range_end = 45.0
	glow_indicator.visibility_range_end_margin = 8.0
	glow_indicator.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mesh_root.add_child(glow_indicator)

## Scanner interface for Q (scanner.gd)
func scan_points() -> Array:
	return [global_position + Vector3(0, 0.1, 0)]

## Scanner behavior readout (scanner.gd)
func scan_behavior(_at: Vector3) -> Dictionary:
	return {
		"state": "RECOVERED LOG" if inspected else "UNFILED LOG",
		"danger": 0,
		"detail": "Survey Yield Fragment (+%d YLD) // Team Kestrel Log" % YIELD_AMOUNT
	}

## Called when scan completes
func on_scanned() -> void:
	if not inspected:
		inspected = true
		Clearance.grant(YIELD_AMOUNT)
		if is_instance_valid(glow_indicator) and glow_indicator.material_override:
			var mat: StandardMaterial3D = glow_indicator.material_override
			mat.albedo_color = Color(0.2, 0.9, 0.4)
			mat.emission = Color(0.2, 0.9, 0.4)
