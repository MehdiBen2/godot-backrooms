extends SceneTree
## Bakes a level's global illumination: builds the level exactly as the game does, voxelizes its walls,
## floors and ceilings into a VoxelGI and saves that to levels/baked/<id>_gi.res. Only the geometry is
## baked (tubes and panels switched off, see _bake): the bounce light is computed live from whatever
## tubes are lit, so flicker and power cuts still bounce. The game uses the bake while the .lvl is unchanged (level_lighting.gd _apply_gi) and falls back
## to SDFGI otherwise. The level editor runs this after every save.
##   godot --path . --script res://tools/bake_level.gd -- --bake-level=<id from levels.json>   (all levels if no id)
## Needs a real renderer (not --headless): the voxel data lives on the GPU until it is saved.

# loaded at run time: the level scripts use the Game autoload, which a --script tool only has after the first frame
var Builder: GDScript

func _init() -> void:
	await process_frame
	var want := ""
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--bake-level="): want = a.substr(13)
	Builder = load("res://scripts/World/level/level_builder.gd")
	var levels: Array = load("res://scripts/World/level/level_data.gd").read_index()
	var game: Node = root.get_node("Game")
	for i in levels.size():
		var meta: Dictionary = levels[i]
		if want != "" and str(meta.get("id", "")) != want and str(meta.get("file", "")) != want: continue
		game.level_index = i
		await _bake(meta)
	quit()

func _bake(meta: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	var lvl: Node3D = Builder.new()
	root.add_child(lvl)
	await process_frame
	# things that move, or don't bounce light, stay out of the voxels
	for n in lvl.find_children("*", "GeometryInstance3D", true, false):
		var gi: GeometryInstance3D = n
		var moving: bool = n.get_parent() != lvl and not (n.get_parent() is StaticBody3D)
		var see_through: bool = gi.material_override is BaseMaterial3D and (gi.material_override as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
		gi.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC if (moving or see_through) else GeometryInstance3D.GI_MODE_STATIC
	# The voxels keep whatever glows at bake time as a permanent light source (the per-instance colours
	# that switch a tube off are ignored by the voxelizer): every tube and panel would go on lighting its
	# ceiling in-game even burnt out, flickering or in a power cut. The glowing tube / diffuser meshes stay
	# out of the bake, and the panel ceiling bakes as plain tiles; the live tubes supply every light.
	for mmi: MultiMeshInstance3D in lvl.find_children("*", "MultiMeshInstance3D", true, false):
		if mmi.multimesh == null: continue
		if mmi.multimesh == lvl.tubes_mm or mmi.multimesh == lvl.lens_mm or mmi == lvl.reflect_mmi:
			mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		elif mmi.multimesh == lvl.panels_mm:
			var plain := StandardMaterial3D.new()
			plain.albedo_texture = (mmi.material_override as ShaderMaterial).get_shader_parameter("albedo_tex")
			mmi.material_override = plain
	var box: Dictionary = lvl.gi_bounds()
	var vgi := VoxelGI.new()
	vgi.position = box.center
	vgi.size = box.size
	vgi.subdiv = VoxelGI.SUBDIV_512 if box.size.x > 110.0 or box.size.z > 110.0 else VoxelGI.SUBDIV_256
	lvl.add_child(vgi)
	vgi.bake(lvl)
	var data: VoxelGIData = vgi.data
	if data == null:
		push_error("bake failed for " + str(meta.get("id")))
		lvl.queue_free()
		return
	data.set_meta("lvl_hash", lvl.bake_hash())
	data.set_meta("center", box.center)
	data.set_meta("size", box.size)
	data.set_meta("subdiv", vgi.subdiv)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://levels/baked"))
	var path: String = lvl.gi_path()
	var err := ResourceSaver.save(data, path, ResourceSaver.FLAG_COMPRESS)
	print("baked %s -> %s  (%s, %d cells, %d ms)" % [meta.get("id"), path, error_string(err), data.get_octree_cells().size() / 32, Time.get_ticks_msec() - t0])
	lvl.queue_free()
	await process_frame
