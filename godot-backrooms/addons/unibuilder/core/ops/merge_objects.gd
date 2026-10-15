@tool
class_name UBOpMergeObjects
extends RefCounted
## Append another mesh's data into the target with the source-to-target
## transform baked in (through UBOpPivot.apply_transform, so a mirroring
## transform flips windings). Material slots remap by resource identity: a slot
## holding the same Material reuses the target's slot, unmatched materials
## append, and unmaterialed faces stay unmaterialed without adding slots. The
## caller owns undo and scene-tree surgery.


static func apply(target, source, source_to_target: Transform3D) -> void:
	var src = source.duplicate_data()
	UBOpPivot.apply_transform(src, source_to_target)
	var base: int = target.positions.size()
	var pos: PackedVector3Array = target.positions.duplicate()
	pos.append_array(src.positions)
	target.positions = pos
	var slot_map := {}
	for f in src.faces:
		var nf: UBFace = f.duplicate_face()
		var verts: PackedInt32Array = nf.vertices
		for i in verts.size():
			verts[i] += base
		nf.vertices = verts
		nf.material_index = _map_slot(target, src.material_slots, f.material_index, slot_map)
		target.faces.append(nf)


static func _map_slot(target, src_slots: Array, idx: int, cache: Dictionary) -> int:
	if cache.has(idx):
		return cache[idx]
	var mat: Material = src_slots[idx] if idx >= 0 and idx < src_slots.size() else null
	var mapped := -1
	for ti in target.material_slots.size():
		if target.material_slots[ti] == mat:
			mapped = ti
			break
	if mapped < 0:
		if mat == null and idx >= target.material_slots.size():

			mapped = idx
		else:
			target.material_slots.append(mat)
			mapped = target.material_slots.size() - 1
	cache[idx] = mapped
	return mapped
