extends Node3D
## Abandoned Survey Clipboard. Left behind by previous T.S.R.A. exploration teams.
## Scannable with the Field Scanner (hold Q) to extract lost surveyor notes and earn Research Yield (+40 YLD).
## Built with distance-based visibility culling.

const ArchiveScript := preload("res://scripts/GameLogicEngine/asra_archive.gd")
const ASRA_ID := "survey_clipboard"
const YIELD_AMOUNT := 40
const SCAN_RANGE := 3.5
const Prop := preload("res://scripts/World/props/industrial_prop.gd")
## The note is one sheet (or a few) of A4 from paper_debris.glb, at its real size (the file is in centimetres)
const PAPER_MODEL := "res://models/props/asset_pack/paper_debris.glb"
const PAPER_SCALE := 0.01
const PAPERS := {"fold": "SM_A4_paper_fold_1", "fold_2": "SM_A4_paper_fold_2", "pile": "SM_A4_paper_pile",
	"flat": "SM_A4_paper", "crumpled": "SM_A4_paper_crumbled"}
const RANDOM_PAPERS := ["fold", "fold_2", "pile", "flat"]     # what a scattered note can be (crumpled only if asked)

var inspected := false
var paper := ""          # which of PAPERS, set before it is added ("" or unknown: picked from where it lies)
var mesh_root: Node3D

func _ready() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("asra_id", ASRA_ID)
	_build_mesh()

func _build_mesh() -> void:
	mesh_root = Node3D.new()
	add_child(mesh_root)

	# 1. The paper: one of the A4 sheets, its middle on the note's origin, lying on the floor
	var top := 0.03
	var model := Prop._instance(PAPER_MODEL)
	if model != null:
		var key := paper
		if not PAPERS.has(key):                     # the same paper every time for a note in the same place
			var spot := Vector2i(roundi(global_position.x * 10.0), roundi(global_position.z * 10.0))
			key = RANDOM_PAPERS[absi(hash(spot)) % RANDOM_PAPERS.size()]
		var box := AABB()
		var first := true
		for mi in Prop.kept_meshes(model, [PAPERS[key]], []):
			var b := Prop.mesh_box(mi.mesh, Prop.in_model(mi, model))
			box = b if first else box.merge(b)
			first = false
		_merge_parts(model)
		model.scale = Vector3.ONE * PAPER_SCALE
		model.position = Vector3(-box.get_center().x, -box.position.y, -box.get_center().z) * PAPER_SCALE + Vector3(0, 0.002, 0)
		mesh_root.rotation.y = float(absi(hash(Vector2i(roundi(global_position.x * 7.0), roundi(global_position.z * 7.0)))) % 360) * PI / 180.0
		mesh_root.add_child(model)
		top = box.size.y * PAPER_SCALE + 0.004
	else:
		push_warning("Survey note: paper model missing (" + PAPER_MODEL + ")")
		var fallback := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.21, 0.01, 0.297)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.RED
		fallback.mesh = box
		fallback.material_override = mat
		mesh_root.add_child(fallback)



## The model (a paper, or several) can be many small meshes, each with its own material and visibility. They are merged here
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
