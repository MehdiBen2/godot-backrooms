extends SceneTree
## Cuts a heavy .glb (high-poly models come in at millions of triangles) down to about TRIS
## triangles with Godot's own LOD simplifier (meshoptimizer), keeping its UVs, normals, tangents and
## material, and writes a small .glb with JPEG textures. First surface of the first mesh only.
## models/camera_flash.glb came from asetsuimprot/camera+flash+3d+model.glb this way (1.97M -> 15k
## triangles, 66.7 MB -> 1.3 MB):
##   IN=../asetsuimprot/camera+flash+3d+model.glb OUT=models/camera_flash.glb TRIS=16000 \
##     godot --headless --path . --script res://tools/simplify_model.gd
func _initialize() -> void:
	var target := int(OS.get_environment("TRIS")) if OS.get_environment("TRIS") != "" else 16000
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(OS.get_environment("IN"), st) != OK:
		push_error("load failed"); quit(1); return
	var scene := doc.generate_scene(st)
	var mi: MeshInstance3D = scene.find_children("*", "MeshInstance3D", true, false)[0]
	var src_mesh: Mesh = mi.mesh
	var arrays := src_mesh.surface_get_arrays(0)
	var mat := src_mesh.surface_get_material(0)
	print("in: verts ", arrays[Mesh.ARRAY_VERTEX].size(), " tris ", arrays[Mesh.ARRAY_INDEX].size() / 3)
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, mat)
	im.generate_lods(25.0, 60.0, [])
	var best := PackedInt32Array()
	for i in im.get_surface_lod_count(0):
		var idx := im.get_surface_lod_indices(0, i)
		print("  lod ", i, " tris ", idx.size() / 3)
		if best.is_empty() or absi(idx.size() / 3 - target) < absi(best.size() / 3 - target):
			best = idx
	var remap := {}
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	var keep := PackedInt32Array()
	var new_idx := PackedInt32Array()
	for v in best:
		if not remap.has(v):
			remap[v] = keep.size()
			keep.append(v)
		new_idx.append(remap[v])
	for a in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV]:
		var srcA = arrays[a]
		if srcA == null: continue
		var dst = srcA.duplicate(); dst.resize(keep.size())
		for i in keep.size(): dst[i] = srcA[keep[i]]
		out[a] = dst
	if arrays[Mesh.ARRAY_TANGENT] != null:
		var t: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		var tt := PackedFloat32Array(); tt.resize(keep.size() * 4)
		for i in keep.size():
			for c in 4: tt[i * 4 + c] = t[keep[i] * 4 + c]
		out[Mesh.ARRAY_TANGENT] = tt
	out[Mesh.ARRAY_INDEX] = new_idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	am.surface_set_material(0, mat)
	print("out: verts ", keep.size(), " tris ", new_idx.size() / 3)
	var base := OS.get_environment("OUT").get_file().get_basename()
	var root := Node3D.new(); root.name = base
	var m2 := MeshInstance3D.new(); m2.name = base + "_mesh"; m2.mesh = am
	root.add_child(m2); m2.owner = root
	var doc2 := GLTFDocument.new()
	doc2.image_format = "JPEG"
	doc2.lossy_quality = 0.85
	var st2 := GLTFState.new()
	doc2.append_from_scene(root, st2)
	print("write: ", doc2.write_to_filesystem(st2, OS.get_environment("OUT")))
	quit()
