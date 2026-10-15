@tool
@icon("res://addons/unibuilder/icons/ub_mesh_instance.svg")
class_name UBMeshInstance3D
extends MeshInstance3D
## Renders a UBMeshData by compiling it to an ArrayMesh whenever the data changes.
## The node is a MeshInstance3D, so the compiled mesh is saved with the scene and
## still renders when the plugin is disabled. Baking to a plain mesh swaps the node
## type and drops `mesh_data`.

@export var mesh_data: UBMeshData:
	set(value):
		if mesh_data == value:
			return
		if mesh_data != null:

			if mesh_data.changed.is_connected(_on_mesh_data_changed):
				mesh_data.changed.disconnect(_on_mesh_data_changed)
			if mesh_data.colors_changed.is_connected(_on_mesh_colors_changed):
				mesh_data.colors_changed.disconnect(_on_mesh_colors_changed)

		var keep := mesh_data == null and value != null and not value.resource_path.is_empty() \
			and _is_stamped_compile_of(mesh, value)
		mesh_data = value
		if mesh_data != null:
			mesh_data.changed.connect(_on_mesh_data_changed)
			mesh_data.colors_changed.connect(_on_mesh_colors_changed)
		if keep:
			_own_mesh = mesh

			_color_layout = {}
			update_gizmos()
			refresh_collision()
		else:
			rebuild()

enum CollisionMode { NONE, CONVEX, TRIMESH, RAMP }
enum EntityType { NORMAL, COLLIDER, TRIGGER }

const COLLISION_BODY_NAME := "_UBCollision"


func _validate_property(property: Dictionary) -> void:
	if property.name == "mesh_data":
		property.usage |= PROPERTY_USAGE_ALWAYS_DUPLICATE

## Auto collision: a transient child StaticBody3D rebuilt on recompile and on scene load.
@export var collision_mode := CollisionMode.NONE:
	set(value):
		if collision_mode == value:
			return
		collision_mode = value
		refresh_collision()

## Collider/Trigger meshes hide in game, leaving only a physics body (Trigger: Area3D).
@export var entity_type := EntityType.NORMAL:
	set(value):
		if entity_type == value:
			return
		entity_type = value
		refresh_collision()
		_refresh_entity_display()

## Editor tint materials per entity type, a reuse cache. A tint is recognised by
## its meta tag, not by identity against this dict.
static var _entity_tints := {}


var _tint_stripped_for_save := false


const EDIT_LOCK_META := &"_edit_lock_"
const PLUGIN_LOCK_META := &"_ub_gizmo_lock_"
var _plugin_lock := false
var _lock_stripped_for_save := false


var _color_layout := {}


const COMPILE_HASH_META := &"ub_compile_hash"
const COMPILE_XFORM_META := &"ub_compile_xform"


var _own_mesh: Mesh = null

## Texel size for live lightmap UV2 on the compiled mesh, set from the editor prefs.
## 0 (the default) turns it off. Rebuilds only schedule an unwrap, debounced until
## edits go quiet, because unwrap cost scales with chart count.
static var live_uv2_texel := 0.0
## Set false to skip live UV2 on this instance (the shape tool's draw preview does).
var live_uv2 := true


var _uv2_due_ms := 0
var _uv2_timer_live := false

const LIVE_UV2_DEBOUNCE := 0.5
## Re-arm delay when another instance already unwrapped this frame.
const LIVE_UV2_RETRY := 0.05
## Frame of the most recent unwrap, shared by every instance; only one unwrap runs
## per frame.
static var _uv2_frame := -1
## Editor-only, never saved: every in-tree instance, so a prefs change can reach them.
const LIVE_UV2_GROUP := &"_ub_live_uv2"


const UV2_TEXEL_META := &"ub_uv2_texel"
const UV2_SCALE_META := &"ub_uv2_scale"
const UV2_SCALE_EPS := 1e-3

enum UV2Result { SKIPPED, CURRENT, REBUILT, FAILED }

## Called with (node, UV2Result) after an automatic unwrap rebuilt or failed.
## The editor plugin sets it to mark the scene modified and to report failures;
## a Callable keeps this script free of editor classes.
static var uv2_hook := Callable()

var _uv2_error := OK


## Queues the unwrap on every in-tree mesh whose UV2 is missing or stale. The
## plugin calls this when it applies its prefs: a node that entered the tree
## while the texel was 0 (live UV2 off, or prefs not applied yet) queued
## nothing, and a changed texel makes every unwrapped mesh stale. Detached
## background tabs are not reached; they queue on re-entry instead.
static func requeue_live_uv2(tree: SceneTree) -> void:
	if tree == null:
		return
	for n in tree.get_nodes_in_group(LIVE_UV2_GROUP):
		if n is UBMeshInstance3D:
			(n as UBMeshInstance3D)._schedule_live_uv2()


func _init() -> void:
	set_notify_transform(true)


## Used by the editor plugin: padlock this node while its own gizmo replaces the
## native one, or release it.
func set_plugin_lock(on: bool) -> void:
	_plugin_lock = on
	if on:
		set_meta(EDIT_LOCK_META, true)
		set_meta(PLUGIN_LOCK_META, true)
	else:
		remove_meta(EDIT_LOCK_META)
		remove_meta(PLUGIN_LOCK_META)


## True when the node carries a padlock the plugin did not set.
func has_foreign_lock() -> bool:
	return has_meta(EDIT_LOCK_META) and not has_meta(PLUGIN_LOCK_META)


func _heal_stale_plugin_lock() -> void:
	if not _plugin_lock and has_meta(PLUGIN_LOCK_META):
		set_plugin_lock(false)


func _enter_tree() -> void:

	_heal_stale_plugin_lock()
	if Engine.is_editor_hint():
		_heal_shared_mesh_data(get_tree().edited_scene_root)

	if mesh_data != null and mesh_data.uses_world_space_uvs() and not _world_uv_current() \
			and (Engine.is_editor_hint() or not _mesh_has_uv2()):
		_compile_mesh()

	if Engine.is_editor_hint():
		add_to_group(LIVE_UV2_GROUP)
		_schedule_live_uv2()


func _ready() -> void:

	if not Engine.is_editor_hint() and entity_type != EntityType.NORMAL:
		visible = false

	if not Engine.is_editor_hint() and UBEdition.DEMO:
		_ensure_demo_watermark()


func rebuild() -> void:
	if mesh_data == null:
		mesh = null
		_color_layout = {}
	elif not Engine.is_editor_hint() and _mesh_has_uv2():

		pass
	else:
		_compile_mesh()
	update_gizmos()
	refresh_collision()


func _compile_mesh() -> void:
	var xform := global_transform if is_inside_tree() else transform
	var layout := {}
	var compiled := UBMeshCompiler.compile(mesh_data, xform, layout)
	if mesh_data.uses_world_space_uvs():
		compiled.set_meta(COMPILE_XFORM_META, xform)
	mesh = compiled
	_own_mesh = compiled
	_color_layout = layout
	_schedule_live_uv2()


func _stamp_compile() -> void:
	if mesh_data != null and mesh != null and mesh == _own_mesh:
		mesh.set_meta(COMPILE_HASH_META, mesh_data.content_hash())


static func _is_stamped_compile_of(m: Mesh, data: UBMeshData) -> bool:
	if not (m is ArrayMesh) or data == null or not m.has_meta(COMPILE_HASH_META):
		return false
	return int(m.get_meta(COMPILE_HASH_META)) == data.content_hash()


func _world_uv_current() -> bool:
	if mesh == null or not mesh.has_meta(COMPILE_XFORM_META):
		return false
	var stamped = mesh.get_meta(COMPILE_XFORM_META)
	var now := global_transform if is_inside_tree() else transform
	return stamped is Transform3D and (stamped as Transform3D).is_equal_approx(now)


func _heal_shared_mesh_data(scene_root: Node) -> bool:
	if mesh_data == null or scene_root == null or owner != scene_root:
		return false
	for c in mesh_data.changed.get_connections():
		var other: Object = (c["callable"] as Callable).get_object()
		if other == self or not is_instance_valid(other) or not (other is UBMeshInstance3D):
			continue
		var n := other as UBMeshInstance3D
		if n.is_inside_tree() and n.owner == scene_root:

			mesh_data = mesh_data.duplicate()
			return true
	return false


## Brings the transient collision child in line with the current mesh and mode.
func refresh_collision() -> void:
	var body: Node = get_node_or_null(NodePath(COLLISION_BODY_NAME))
	var mode := _effective_collision_mode()
	if mode == CollisionMode.NONE or mesh == null or mesh.get_surface_count() == 0:
		if body != null:
			remove_child(body)
			body.free()
		return
	var want_area := entity_type == EntityType.TRIGGER
	if body != null and (body is Area3D) != want_area:
		remove_child(body)
		body.free()
		body = null
	if body == null:
		body = Area3D.new() if want_area else StaticBody3D.new()
		body.name = COLLISION_BODY_NAME
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		body.add_child(cs)
		add_child(body)
	_sync_collision_shapes(body, _collision_shapes(mode, want_area))


func _sync_collision_shapes(body: Node3D, shapes: Array[Shape3D]) -> void:
	for i in shapes.size():
		var cs := body.get_node_or_null(NodePath(_shape_child_name(i))) as CollisionShape3D
		if cs == null:
			cs = CollisionShape3D.new()
			cs.name = _shape_child_name(i)
			body.add_child(cs)
		cs.shape = shapes[i]
	var extra := shapes.size()
	while true:
		var stale := body.get_node_or_null(NodePath(_shape_child_name(extra)))
		if stale == null:
			break
		body.remove_child(stale)
		stale.free()
		extra += 1


static func _shape_child_name(i: int) -> String:
	return "Shape" if i == 0 else "Shape%d" % (i + 1)


func _effective_collision_mode() -> CollisionMode:
	if collision_mode == CollisionMode.NONE and entity_type != EntityType.NORMAL:
		return CollisionMode.CONVEX if entity_type == EntityType.TRIGGER else CollisionMode.TRIMESH
	return collision_mode


func _collision_shapes(mode: CollisionMode, want_area: bool) -> Array[Shape3D]:
	if want_area and mode == CollisionMode.TRIMESH:

		mode = CollisionMode.CONVEX
	match mode:
		CollisionMode.CONVEX:
			return [mesh.create_convex_shape(true, false)]
		CollisionMode.RAMP:
			return _ramp_shapes()
		_:
			return [mesh.create_trimesh_shape()]


## Returns a standalone collision body for the current mesh, or null when it has
## none. The body belongs to the caller; make_baked hands it to the baked node,
## which has no script to rebuild one.
func build_collision_body() -> Node3D:
	var mode := _effective_collision_mode()
	if mode == CollisionMode.NONE or mesh == null or mesh.get_surface_count() == 0:
		return null
	var want_area := entity_type == EntityType.TRIGGER
	var body: Node3D = Area3D.new() if want_area else StaticBody3D.new()
	body.name = COLLISION_BODY_NAME
	_sync_collision_shapes(body, _collision_shapes(mode, want_area))
	return body


func _refresh_entity_display() -> void:
	if not Engine.is_editor_hint():
		return
	if entity_type == EntityType.NORMAL:
		if _is_entity_tint(material_override):
			material_override = null
	else:
		material_override = _entity_tint(entity_type)


static func _is_entity_tint(mat: Material) -> bool:
	return is_instance_valid(mat) and mat.has_meta("ub_entity_tint")


static func _entity_tint(type: EntityType) -> StandardMaterial3D:
	if not _entity_tints.has(type):
		var m := StandardMaterial3D.new()
		m.set_meta("ub_entity_tint", true)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = (
			Color(1.0, 0.55, 0.15, 0.4) if type == EntityType.COLLIDER
			else Color(0.35, 0.55, 1.0, 0.4)
		)
		_entity_tints[type] = m
	return _entity_tints[type]


func _ramp_shapes() -> Array[Shape3D]:
	var out: Array[Shape3D] = []
	var spec: Dictionary = mesh_data.shape_spec if mesh_data != null else {}
	if int(spec.get("kind", -1)) == UBPrimitives.STAIRS_SPEC_KIND:
		var dims: Dictionary = spec.get("dims", {})
		var box := Vector3(float(dims.get("su", 0.0)), float(dims.get("ah", 0.0)), float(dims.get("sv", 0.0)))
		if mesh.get_aabb().size.is_equal_approx(box):
			var pieces := UBPrimitives.stairs_ramp_pieces(dims, spec.get("params", {}))
			if pieces.size() > 1:

				var shift := mesh.get_aabb().position + box * 0.5
				for pts in pieces:
					for i in pts.size():
						pts[i] += shift
					var shape := ConvexPolygonShape3D.new()
					shape.points = pts
					out.append(shape)
				return out
	out.append(_ramp_shape())
	return out


func _ramp_shape() -> ConvexPolygonShape3D:
	var aabb := mesh.get_aabb()
	var lo := aabb.position
	var hi := aabb.end
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z),
		Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z),
	])
	return shape


## Returns a plain MeshInstance3D carrying the compiled ArrayMesh and this node's
## identity, with all editing data stripped. `lightmap_texel` above 0 unwraps
## lightmap UV2 unless the mesh already has it. Replacing the node in the tree and
## recording undo are the caller's job.
func make_baked(lightmap_texel := 0.0) -> MeshInstance3D:
	var baked := MeshInstance3D.new()
	baked.name = name
	baked.mesh = mesh

	if lightmap_texel > 0.0 and mesh != null and not _uv2_is_current(lightmap_texel):
		var unwrapped := _unwrapped_copy(lightmap_texel)
		if unwrapped != null:
			baked.mesh = unwrapped

	var skip := {
		"script": true, "mesh": true, "mesh_data": true, "collision_mode": true,
		"entity_type": true, "material_override": true, "visible": true,
	}
	if _plugin_lock or has_meta(PLUGIN_LOCK_META):
		skip["metadata/" + str(EDIT_LOCK_META)] = true
	skip["metadata/" + str(PLUGIN_LOCK_META)] = true
	for p in get_property_list():
		var prop: String = p["name"]
		if not (int(p["usage"]) & PROPERTY_USAGE_STORAGE) or skip.has(prop):
			continue
		if prop.begins_with("metadata/") or prop in baked:
			baked.set(prop, get(prop))
	if not _is_entity_tint(material_override):
		baked.material_override = material_override

	baked.visible = visible and entity_type == EntityType.NORMAL

	var body := build_collision_body()
	if body != null:
		baked.add_child(body)
	return baked


func _unwrapped_copy(texel_size: float) -> ArrayMesh:
	var xform := global_transform if is_inside_tree() else transform
	var source := mesh as ArrayMesh
	if _mesh_has_uv2() and mesh_data != null:
		source = UBMeshCompiler.compile(mesh_data, xform)
	var copy := ArrayMesh.new()
	for s in source.get_surface_count():
		copy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source.surface_get_arrays(s))
		copy.surface_set_material(s, source.surface_get_material(s))
	var err := copy.lightmap_unwrap(xform, texel_size)
	if err != OK:
		_uv2_error = err
		push_warning("Unibuilder: lightmap unwrap failed on \"%s\" (error %d)." % [name, err])
		return null
	copy.set_meta(UV2_TEXEL_META, texel_size)
	copy.set_meta(UV2_SCALE_META, xform.basis.get_scale())

	if source == mesh and mesh.has_meta(COMPILE_XFORM_META):
		copy.set_meta(COMPILE_XFORM_META, mesh.get_meta(COMPILE_XFORM_META))
	elif source != mesh and mesh_data.uses_world_space_uvs():
		copy.set_meta(COMPILE_XFORM_META, xform)
	return copy


func _uv2_is_current(texel: float) -> bool:
	if not _mesh_has_uv2() or not mesh.has_meta(UV2_TEXEL_META):
		return false
	if not is_equal_approx(float(mesh.get_meta(UV2_TEXEL_META)), texel):
		return false
	var stamped = mesh.get_meta(UV2_SCALE_META, Vector3.ONE)
	if not (stamped is Vector3):
		return false
	var xform := global_transform if is_inside_tree() else transform
	var now := xform.basis.get_scale()
	for i in 3:
		if absf(now[i] - stamped[i]) > UV2_SCALE_EPS * maxf(1.0, absf(now[i])):
			return false
	return true


## Unwraps lightmap UV2 at `texel` unless the mesh already carries a current one;
## `force` unwraps regardless. A failure keeps the mesh as it was and raises a node
## warning in the Scene dock.
func rebuild_lightmap_uv2(texel: float, force := false) -> UV2Result:
	if texel <= 0.0 or mesh == null or mesh.get_surface_count() == 0:
		return UV2Result.SKIPPED
	if not force and _uv2_is_current(texel):
		return UV2Result.CURRENT
	var failed_before := _uv2_error != OK
	var unwrapped := _unwrapped_copy(texel)
	if unwrapped != null:
		_uv2_error = OK

		mesh = unwrapped
		_own_mesh = unwrapped
		_color_layout = {}
	if failed_before != (_uv2_error != OK) and is_inside_tree():
		update_configuration_warnings()
	return UV2Result.REBUILT if unwrapped != null else UV2Result.FAILED


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _uv2_error != OK:
		out.append(("Lightmap UV2 unwrap failed (error %d), so lightmap bakes will skip or"
			+ " mislight this mesh. Check it for zero-area faces, then run"
			+ " Tools > Rebuild Lightmap UV2.") % _uv2_error)
	return out


func _schedule_live_uv2(delay := LIVE_UV2_DEBOUNCE) -> void:
	if live_uv2_texel <= 0.0 or not live_uv2 or not Engine.is_editor_hint():
		return
	if not is_inside_tree() or mesh == null or mesh.get_surface_count() == 0:
		return
	if _uv2_is_current(live_uv2_texel):
		return
	_uv2_due_ms = Time.get_ticks_msec() + int(delay * 1000.0)
	if _uv2_timer_live:
		return
	_arm_uv2_timer(delay)


func _arm_uv2_timer(delay: float) -> void:
	_uv2_timer_live = true
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		if not is_instance_valid(self):
			return
		_uv2_timer_live = false
		if not is_inside_tree():
			return

		var remaining_ms := _uv2_due_ms - Time.get_ticks_msec()
		if remaining_ms > 0:
			_arm_uv2_timer(remaining_ms / 1000.0)
			return

		var frame := Engine.get_process_frames()
		if _uv2_frame == frame:
			_arm_uv2_timer(LIVE_UV2_RETRY)
			return
		_uv2_frame = frame
		var result := _apply_live_uv2()
		if uv2_hook.is_valid() \
				and (result == UV2Result.REBUILT or result == UV2Result.FAILED):
			uv2_hook.call(self, result))


func _apply_live_uv2() -> UV2Result:
	return rebuild_lightmap_uv2(live_uv2_texel)


func _mesh_has_uv2() -> bool:
	var am := mesh as ArrayMesh
	if am == null or am.get_surface_count() == 0:
		return false
	return (am.surface_get_format(0) & Mesh.ARRAY_FORMAT_TEX_UV2) != 0


func _on_mesh_data_changed() -> void:
	rebuild()


func _on_mesh_colors_changed() -> void:

	if mesh == null or _mesh_has_uv2() \
			or not UBMeshCompiler.update_colors(mesh, mesh_data, _color_layout):
		rebuild()
	else:

		_schedule_live_uv2()


func _notification(what: int) -> void:

	if what == NOTIFICATION_TRANSFORM_CHANGED:
		if Engine.is_editor_hint() and mesh_data != null and mesh_data.uses_world_space_uvs():
			if not _world_uv_current():
				_compile_mesh()
		elif _mesh_has_uv2():

			_schedule_live_uv2()

	elif what == NOTIFICATION_EDITOR_PRE_SAVE:

		if live_uv2 and live_uv2_texel > 0.0 and mesh_data != null \
				and mesh != null and mesh.get_surface_count() > 0:
			_apply_live_uv2()

		_stamp_compile()
		if _is_entity_tint(material_override):
			material_override = null
			_tint_stripped_for_save = true
		if _plugin_lock and has_meta(PLUGIN_LOCK_META):
			remove_meta(EDIT_LOCK_META)
			remove_meta(PLUGIN_LOCK_META)
			_lock_stripped_for_save = true
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		if _tint_stripped_for_save:
			_tint_stripped_for_save = false
			if entity_type != EntityType.NORMAL:
				material_override = _entity_tint(entity_type)
		if _lock_stripped_for_save:
			_lock_stripped_for_save = false
			if _plugin_lock:
				set_plugin_lock(true)


## One overlay per game run, however many UB meshes the scene holds.
static var _demo_watermark_up := false


func _ensure_demo_watermark() -> void:
	if _demo_watermark_up:
		return
	_demo_watermark_up = true
	var layer := CanvasLayer.new()
	layer.layer = 100
	var label := Label.new()
	label.text = "Made with the Unibuilder demo: " + UBEdition.STORE_URL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.modulate = Color(1, 1, 1, 0.55)
	label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	label.offset_left = -520
	label.offset_top = -36
	label.offset_right = -12
	label.offset_bottom = -10
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	layer.add_child(label)

	get_tree().root.add_child.call_deferred(layer)
