@tool
class_name UBMeshCompiler
extends RefCounted
## Compiles a UBMeshData into a renderable ArrayMesh: triangulates n-gons,
## resolves smoothing-group normals, generates auto-UVs and tangents, and emits
## one surface per used material slot. The whole mesh is recompiled every time.


## `layout`, when passed, is filled with face_index -> Vector2i(surface,
## base_vertex), where each face's corners landed in the compiled mesh, in
## corner order. update_colors() uses it to patch paint strokes in place.
static func compile(data, world_transform := Transform3D.IDENTITY, layout := {}) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if data == null or data.faces.is_empty():
		return mesh
	var topo := UBTopology.build(data)
	var face_normals := PackedVector3Array()
	face_normals.resize(data.faces.size())
	for fi in data.faces.size():
		face_normals[fi] = data.face_normal(data.faces[fi])

	var by_material := {}
	for fi in data.faces.size():
		var slot: int = data.faces[fi].material_index
		if not by_material.has(slot):
			by_material[slot] = []
		by_material[slot].append(fi)

	var slots: Array = by_material.keys()
	slots.sort()
	for slot in slots:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var vert_base := 0
		var placed := []
		for fi in by_material[slot]:
			var face: UBFace = data.faces[fi]
			var verts := face.vertices
			if verts.size() < 3:
				continue
			var corners := PackedVector3Array()
			for vi in verts:
				corners.append(data.positions[vi])
			var tris := UBTriangulate.triangulate(corners)
			if tris.is_empty():
				continue

			var uvs := (
				face.uv_coords
				if face.uv_manual and face.uv_coords.size() == verts.size()
				else UBUVUnwrap.face_uvs(corners, face_normals[fi], face, world_transform)
			)

			var corner_colors := face.color_corners.size() == verts.size()
			for ci in verts.size():
				st.set_normal(corner_normal(data, topo, face_normals, fi, verts[ci]))
				st.set_uv(uvs[ci])
				st.set_color(face.color_corners[ci] if corner_colors else face.color)
				st.add_vertex(corners[ci])
			for t in tris:
				st.add_index(vert_base + t)
			placed.append([fi, vert_base])
			vert_base += verts.size()
		if vert_base == 0:
			continue
		st.generate_tangents()
		st.commit(mesh)
		var surface := mesh.get_surface_count() - 1
		for p in placed:
			layout[p[0]] = Vector2i(surface, p[1])
		if slot >= 0 and slot < data.material_slots.size() and data.material_slots[slot] != null:
			mesh.surface_set_material(surface, data.material_slots[slot])
	return mesh


## Paint fast path: rewrites only the color bytes of an already-compiled mesh,
## one attribute-buffer upload per surface, with no triangulation, tangent,
## gizmo, or collision work. `layout` must come from the compile() that produced
## `mesh`. Returns false when the mesh cannot be patched (stale layout, missing
## color format); the caller must recompile instead.
static func update_colors(mesh: ArrayMesh, data, layout: Dictionary) -> bool:
	var buffers := patched_color_buffers(mesh, data, layout)
	if buffers.is_empty():
		return false
	for s in buffers.size():
		mesh.surface_update_attribute_region(s, 0, buffers[s])
	return true


## The per-surface attribute buffers with every face's current colors written
## in, or [] when patching is not possible. Split from update_colors so the
## patched bytes can be compared against a fresh compile.
static func patched_color_buffers(mesh: ArrayMesh, data, layout: Dictionary) -> Array:
	if mesh == null or data == null or mesh.get_surface_count() == 0 or layout.is_empty():
		return []
	var buffers := []
	var strides := PackedInt32Array()
	var offsets := PackedInt32Array()
	var counts := PackedInt32Array()
	for s in mesh.get_surface_count():
		var format := mesh.surface_get_format(s)
		if not (format & Mesh.ARRAY_FORMAT_COLOR):
			return []
		var vcount := mesh.surface_get_array_len(s)
		var surf := RenderingServer.mesh_get_surface(mesh.get_rid(), s)
		buffers.append(surf["attribute_data"])
		strides.append(RenderingServer.mesh_surface_get_format_attribute_stride(format, vcount))
		offsets.append(RenderingServer.mesh_surface_get_format_offset(format, vcount, Mesh.ARRAY_COLOR))
		counts.append(vcount)
	for fi in layout:
		if fi < 0 or fi >= data.faces.size():
			return []
		var face: UBFace = data.faces[fi]
		var place: Vector2i = layout[fi]
		var n := face.vertices.size()
		if place.x >= buffers.size() or place.y + n > counts[place.x]:
			return []
		var bytes: PackedByteArray = buffers[place.x]
		var corner_colors := face.color_corners.size() == n
		for ci in n:
			var c: Color = face.color_corners[ci] if corner_colors else face.color
			var off: int = offsets[place.x] + strides[place.x] * (place.y + ci)

			bytes.encode_u8(off, clampi(int(c.r * 255.0), 0, 255))
			bytes.encode_u8(off + 1, clampi(int(c.g * 255.0), 0, 255))
			bytes.encode_u8(off + 2, clampi(int(c.b * 255.0), 0, 255))
			bytes.encode_u8(off + 3, clampi(int(c.a * 255.0), 0, 255))
		buffers[place.x] = bytes
	return buffers


## Shading normal of face `fi`'s corner at `vertex_index`: the face normal on a
## hard face (group 0), else the normalized sum of the normals of every face
## around the vertex in the same smoothing group. Shared with the OBJ exporter
## so exported `vn` lines shade exactly like the viewport.
static func corner_normal(data, topo: UBTopology, face_normals: PackedVector3Array, fi: int, vertex_index: int) -> Vector3:
	var group: int = data.faces[fi].smoothing_group
	if group == 0:
		return face_normals[fi]
	var sum := Vector3.ZERO
	for af in topo.vertex_faces[vertex_index]:
		if data.faces[af].smoothing_group == group:
			sum += face_normals[af]
	if sum.length_squared() <= 1e-12:
		return face_normals[fi]
	return sum.normalized()
