@tool
class_name UBMaterialDrop
extends Control
## Drop target for materials over a 3D viewport's "surface" control (the one
## _forward_3d_draw_over_viewport hands out), where the editor forwards native drops.
## mouse_filter stays IGNORE except during a material drag, so the surface's own
## interactive children keep the mouse. A declined drop falls through to the
## editor's native handling.

## Prints filter flips and drop tests, for drop debugging.
const DEBUG := false

var plugin: EditorPlugin
var viewport: SubViewport


func _init() -> void:
	name = "_UBMaterialDrop"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if viewport != null:
		var wanted_size := Vector2(viewport.size)
		if size != wanted_size:
			size = wanted_size
		if position != Vector2.ZERO:
			position = Vector2.ZERO
	var vp := get_viewport()
	if vp == null:
		return
	var dragging := vp.gui_is_dragging() and extract_material(vp.gui_get_drag_data()) != null
	var want := Control.MOUSE_FILTER_PASS if dragging else Control.MOUSE_FILTER_IGNORE
	if mouse_filter != want:
		mouse_filter = want
		if DEBUG:
			print("UBMaterialDrop: drag=%s filter=%s size=%s parent=%s parent_size=%s" % [
				dragging, want, size, get_parent().get_class(), (get_parent() as Control).size])


func _notification(what: int) -> void:
	if plugin == null:
		return
	match what:
		NOTIFICATION_DRAG_BEGIN:
			var vp := get_viewport()
			if vp != null:
				plugin.material_drag_began(extract_material(vp.gui_get_drag_data()))
		NOTIFICATION_DRAG_END:
			plugin.material_drag_ended()


func _can_drop_data(position: Vector2, data: Variant) -> bool:
	var ok: bool = plugin != null and plugin.can_drop_material(viewport, position, data)
	if DEBUG:
		print("UBMaterialDrop._can_drop_data at %s -> %s" % [position, ok])
	return ok


func _drop_data(position: Vector2, data: Variant) -> void:
	if plugin != null:
		plugin.drop_material(viewport, position, data)


## The dragged Material, or null. Handles FileSystem drags ({"type": "files"})
## and inspector resource drags ({"type": "resource"}).
static func extract_material(data: Variant) -> Material:
	if typeof(data) != TYPE_DICTIONARY:
		return null
	match data.get("type", ""):
		"resource":
			return data.get("resource") as Material
		"files":
			var files: Array = data.get("files", [])
			if files.size() != 1:
				return null

			if not ResourceLoader.exists(files[0], "Material"):
				return null
			return ResourceLoader.load(files[0]) as Material
	return null
