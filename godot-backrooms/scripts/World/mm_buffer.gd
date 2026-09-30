extends RefCounted
## Fill a MultiMesh in one go: the instances are written into a flat PackedFloat32Array and handed to
## MultiMesh.buffer as a single upload, instead of one set_instance_transform() / set_instance_color()
## call (and one RenderingServer round trip) per instance.
##
## Layout per instance (TRANSFORM_3D): the 3x4 matrix row by row, then RGBA if use_colors, then the custom
## data if use_custom_data:  bx.x by.x bz.x o.x | bx.y by.y bz.y o.y | bx.z by.z bz.z o.z | r g b a | ...

## Floats per instance for this MultiMesh (set transform_format / use_colors / use_custom_data first)
static func stride(mm: MultiMesh) -> int:
	return 12 + (4 if mm.use_colors else 0) + (4 if mm.use_custom_data else 0)

## A zeroed buffer sized for mm.instance_count
static func alloc(mm: MultiMesh) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	buf.resize(mm.instance_count * stride(mm))
	return buf

static func put(buf: PackedFloat32Array, o: int, t: Transform3D) -> void:
	var b := t.basis
	buf[o] = b.x.x; buf[o + 1] = b.y.x; buf[o + 2] = b.z.x; buf[o + 3] = t.origin.x
	buf[o + 4] = b.x.y; buf[o + 5] = b.y.y; buf[o + 6] = b.z.y; buf[o + 7] = t.origin.y
	buf[o + 8] = b.x.z; buf[o + 9] = b.y.z; buf[o + 10] = b.z.z; buf[o + 11] = t.origin.z

## Just a translation (identity basis): the common case for grid-placed blocks
static func put_at(buf: PackedFloat32Array, o: int, p: Vector3) -> void:
	buf[o] = 1.0; buf[o + 3] = p.x
	buf[o + 5] = 1.0; buf[o + 7] = p.y
	buf[o + 10] = 1.0; buf[o + 11] = p.z

static func put_color(buf: PackedFloat32Array, o: int, c: Color) -> void:
	buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = c.a
