extends SceneTree
## Bakes a level's global illumination: builds the level exactly as the game does, voxelizes its walls,
## floors and ceilings into a VoxelGI and saves that to levels/baked/<id>_gi.res. Only the geometry is
## baked: the bounce light is computed live from whatever tubes are lit, so flicker and power cuts still
## bounce. The game uses the bake while the .lvl is unchanged (level_lighting.gd _apply_gi) and falls back
## to SDFGI otherwise. The level editor runs this after every save.
##   godot --path . --script res://tools/bake_level.gd -- --bake-level=<id from levels.json>   (all levels if no id)
## Needs a real renderer (not --headless): the voxel data lives on the GPU until it is saved.

const LevelData := preload("res://scripts/World/level/level_data.gd")
const Builder := preload("res://scripts/World/level/level_builder.gd")

func _init() -> void:
	await process_frame
	var want := ""
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--bake-level="): want = a.substr(13)
	var levels := LevelData.read_index()
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
