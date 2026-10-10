extends Node3D
## Abandoned Survey Clipboard. Left behind by previous T.S.R.A. exploration teams.
## Scannable with the Field Scanner (hold Q) to extract lost surveyor notes and earn Research Yield (+40 YLD).
## Built with distance-based visibility culling.

const ArchiveScript := preload("res://scripts/GameLogicEngine/asra_archive.gd")
const ASRA_ID := "survey_clipboard"
const YIELD_AMOUNT := 40
const SCAN_RANGE := 3.5

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

	# 1. Load notebook model
	var model_scene = load("res://models/props/single_spiral_notepad.glb")
	if model_scene:
		var model = model_scene.instantiate()
		_merge_parts(model)
		
		# Adjust scale and shift it down slightly if the model's origin was placing it too high
		model.scale = Vector3(1.0, 1.0, 1.0)
		model.position = Vector3(0, -0.02, 0) # Shift down into the floor slightly
		
		# Give it a slight casual tilt so it rests more naturally
		model.rotation.x = randf_range(-0.05, 0.05)
		model.rotation.z = randf_range(-0.05, 0.05)
		mesh_root.add_child(model)
		print("DEBUG: Notebook model loaded successfully!")
	else:
		print("ERROR: Notebook model failed to load! Is it imported?")
		var fallback := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.3, 0.1, 0.4)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.RED
		fallback.mesh = box
		fallback.material_override = mat
		mesh_root.add_child(fallback)

	# 4. Reflective T.S.R.A. survey marker tag
	glow_indicator = MeshInstance3D.new()
	var tag_box := BoxMesh.new()
	tag_box.size = Vector3(0.06, 0.008, 0.06) # Slightly bigger tag
	glow_indicator.mesh = tag_box
	glow_indicator.position = Vector3(0.0, 0.03, 0.0) # Centered and slightly lifted so it sits on the cover
	var g_mat := StandardMaterial3D.new()
	g_mat.albedo_color = Color(0.95, 0.65, 0.15)
	glow_indicator.material_override = g_mat
	glow_indicator.visibility_range_end = 45.0
	glow_indicator.visibility_range_end_margin = 8.0
	glow_indicator.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mesh_root.add_child(glow_indicator)

## The notebook model is dozens of small meshes, each with its own material and visibility. They are merged here
## into one mesh per material (SurfaceTool), so a clipboard is a few nodes, not dozens. Each merged mesh is darkened
## and matted the way the parts were, and fades out past 45 m as they did.
func _merge_parts(model: Node3D) -> void:
	var groups := {}                                   # source material (or null) -> SurfaceTool
	var parts := model.find_children("*", "MeshInstance3D", true, false)
	for part: MeshInstance3D in parts:
		if part.mesh == null or part.skin != null: continue
		var xf := Transform3D()                        # the part's transform in the model's own space
		var q: Node = part
		while q != model:
			xf = (q as Node3D).transform * xf
			q = q.get_parent()
		for i in part.mesh.get_surface_count():
			var mat: Material = part.get_active_material(i)
			if not groups.has(mat):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				groups[mat] = st
			(groups[mat] as SurfaceTool).append_from(part.mesh, i, xf)
	for part in parts:
		if is_instance_valid(part) and part.get_parent() != null and part.skin == null:
			part.get_parent().remove_child(part)
			part.free()
	for mat in groups:
		var m: Material = mat
		if mat is StandardMaterial3D:
			var sm := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
			sm.roughness = 1.0                                 # paper: matte, no sheen
			sm.specular = 0.5                                  # keep the model's albedo; a soft highlight, not a shine
			m = sm
		var mi := MeshInstance3D.new()
		mi.mesh = (groups[mat] as SurfaceTool).commit()
		mi.material_override = m
		mi.visibility_range_end = 45.0
		mi.visibility_range_end_margin = 8.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		model.add_child(mi)

## Scanner interface for Q (scanner.gd)
func scan_points() -> Array:
	return [global_position + Vector3(0, 0.1, 0)]

## How near the scanner has to be to read it (scanner.gd): an object, so up close
func scan_range() -> float:
	return SCAN_RANGE

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
