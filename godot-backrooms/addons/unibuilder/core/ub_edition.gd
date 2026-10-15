class_name UBEdition
## Which build this is. The demo packager sets DEMO to true and leaves the
## exporter scripts (export_obj.gd, export_gltf.gd) out of the zip, so plugin.gd
## must load those classes by path at the moment of use, never statically.
## Lives in core/ because nodes/ub_mesh_instance.gd reads DEMO for the runtime
## watermark and nodes/ has no editor dependencies.

const DEMO := true

## The public store URL, used by the toolbar chip, the buy dialog and the watermark.
const STORE_URL := "https://calinleafshade.itch.io/unibuilder"

## Minutes between the demo's periodic reminder toasts.
const NAG_MINUTES := 60

## Demo capacity caps: meshes per edited scene and faces per mesh. Sized so no
## default primitive trips the face cap. They are honor-system limits in plain
## GDScript, and demo scenes open untouched in the full version.
const DEMO_MAX_NODES := 12
const DEMO_MAX_FACES := 500


## True when a mutation taking one mesh from `before` to `after` faces must be
## refused. Only growth is refused: a mesh already over the cap can still be
## moved, painted, or edited down. `demo` is a parameter so the rule can be
## tested in the full edition.
static func face_cap_blocks(before: int, after: int, demo := DEMO) -> bool:
	return demo and after > DEMO_MAX_FACES and after > before


## True when adding `adding` Unibuilder meshes to a scene that already holds
## `existing` must be refused.
static func node_cap_blocks(existing: int, adding := 1, demo := DEMO) -> bool:
	return demo and existing + adding > DEMO_MAX_NODES
