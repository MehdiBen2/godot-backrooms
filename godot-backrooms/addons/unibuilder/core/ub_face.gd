@tool
class_name UBFace
extends Resource
## One n-gon face: an ordered loop of indices into UBMeshData.positions.
## Winding is clockwise when viewed from the front (Godot's front-face order);
## the normal is always derived from the winding, never stored.

@export var vertices := PackedInt32Array()
@export var material_index := 0
## 0 = hard-shaded; faces sharing a nonzero group smooth normals across shared vertices.
@export var smoothing_group := 0
@export var uv_offset := Vector2.ZERO
@export var uv_rotation := 0.0
@export var uv_scale := Vector2.ONE
## When true, UVs are projected from world-space positions so the texture stays
## put while the face moves; otherwise the texture follows the face.
@export var uv_world_space := false
## Frozen projection normal for the auto mapping, in local space. Zero means
## project along the face's own normal. A move drag sets it on an auto face it
## deforms and tilts, so a plane sculpted into terrain keeps projecting top-down
## and the texture stays continuous across the tilted quads. Loop rewrites keep
## it; the UV editor's Auto button clears it.
@export var uv_axis := Vector3.ZERO
## Manual UVs: when true and `uv_coords` is parallel to `vertices`, the compiler
## uses these per-corner coordinates verbatim and ignores the auto-UV settings.
## Topology ops that rewrite the loop leave the counts mismatched, and the face
## falls back to auto until it is re-baked.
@export var uv_manual := false
@export var uv_coords := PackedVector2Array()
@export var color := Color.WHITE
## Per-corner colors from vertex paint. When parallel to `vertices` the compiler
## uses these instead of `color`; a mismatched count falls back to `color`, the
## same rule as manual UVs.
@export var color_corners := PackedColorArray()


## Copy that owns its vertex loop. Resource.duplicate() copies packed-array
## properties by reference in Godot 4, so a plain duplicate shares `vertices`
## with the original and in-place loop rewrites would corrupt every snapshot
## holding such a copy. Snapshot paths must use this instead of duplicate().
func duplicate_face() -> UBFace:
	var d := duplicate() as UBFace
	d.vertices = vertices.duplicate()
	d.uv_coords = uv_coords.duplicate()
	d.color_corners = color_corners.duplicate()
	return d
