@tool
class_name UBMaterialPalette
extends PanelContainer
## Quick material palette: a per-project library of commonly used materials,
## shown under the face panel in Face mode. Click a swatch to apply it to the
## selected faces (the whole mesh when nothing is selected). Drag materials in
## from the FileSystem dock, an inspector slot, or a recent ghost to pin them.
## Drag a swatch out onto a face; it carries the same payload as an inspector
## drag, so the viewport drop target handles it. Pinned entries persist per
## project as uid:// ids (paths where a file has none), and a missing file
## shows as a broken swatch until the file is dragged or added in again.
## Recent ghosts fill from any material application and last only the
## session. Emits requests; plugin.gd owns undo and persistence.

signal apply_requested(material: Material)
## Pinned set changed; plugin.gd persists it with the grid state.
signal changed

const SCENE := "res://addons/unibuilder/editor/material_palette.tscn"
const MAX_RECENT := 2
const TEAL := Color(0.369, 0.918, 0.831)
## Swatch tile edge in logical pixels, sized so two tiles fit per row at the
## panel's default width. The scene's "+" button is authored at this size.
const SWATCH_PX := 104.0


## One palette tile. Left-click applies, right-click opens the context menu,
## dragging carries the material like an inspector resource drag.
class Swatch:
	extends Button
	## Named "mat" because "material" would shadow CanvasItem's own property.
	var mat: Material
	var missing_path := ""
	var is_recent := false
	var palette

	func _get_drag_data(_pos: Vector2) -> Variant:
		if mat == null:
			return null
		var preview := TextureRect.new()
		preview.texture = icon
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.custom_minimum_size = Vector2(32, 32)
		set_drag_preview(preview)
		return {"type": "resource", "resource": mat, "from": self}

	func _gui_input(event: InputEvent) -> void:
		if (
			event is InputEventMouseButton and event.pressed
			and event.button_index == MOUSE_BUTTON_RIGHT
		):
			palette._show_context(self)
			accept_event()


var _pinned: Array = []


var _default_mat: Material = null
var _default_path := ""
var _recent: Array = []


var _flow: HFlowContainer
var _add: Button
var _hint: Label
var _menu: PopupMenu
var _menu_swatch: Swatch
var _add_dialog: EditorFileDialog

var _blend_preview: UBBlendPreview


## The one way to make this control (plugin and tests both use it). load(),
## not preload(): the scene references this script.
static func create() -> UBMaterialPalette:
	var palette := (load(SCENE) as PackedScene).instantiate() as UBMaterialPalette
	palette._dress()
	palette._rebuild()
	return palette


func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_flow = %Flow
		_add = %AddButton
		_hint = %Hint
		_add.pressed.connect(_open_add_dialog)


func _dress() -> void:
	var scale := EditorInterface.get_editor_scale()
	_add.custom_minimum_size *= scale
	UBPanelStyle.scale_layout(self)
	UBPanelStyle.style_header(%Header, %HeaderIcon, %Title, "uv_tile")


func pin(material: Material) -> void:
	if material == null:
		return
	var found := _find_pinned(material)
	if found >= 0:

		if _pinned[found].mat == null:
			_pinned[found] = {"path": persist_id(material.resource_path), "mat": material}
			_recent.erase(material)
			changed.emit()
			_rebuild()
		return
	_pinned.append({"path": persist_id(material.resource_path), "mat": material})
	_recent.erase(material)
	changed.emit()
	_rebuild()


func note_used(material: Material) -> void:
	if material == null or _find_pinned(material) >= 0:
		return
	_recent.erase(material)
	_recent.push_front(material)
	while _recent.size() > MAX_RECENT:
		_recent.pop_back()
	_rebuild()


## Persisted form: one id per pin, the material's uid:// where it has one so a
## file moved or renamed in the FileSystem dock still resolves next session,
## else its path. Read off the LIVE resource (the editor updates a loaded
## resource's path when its file moves), not the path it was pinned under.
## Built-in (pathless) materials cannot be reloaded next session, so they last
## only as long as the session.
func get_paths() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in _pinned:
		var id: String = entry.path
		if entry.mat != null and not (entry.mat as Material).resource_path.is_empty():
			id = persist_id(entry.mat.resource_path)
		if not id.is_empty():
			out.append(id)
	return out


## Accepts uid:// ids and plain paths (palettes saved before uids were used).
func set_paths(paths: PackedStringArray) -> void:
	_pinned = []
	for id in paths:
		var mat := _load_material(id)
		_pinned.append({"path": persist_id(mat.resource_path) if mat != null else id, "mat": mat})
	_rebuild()


## A resource path as the id the palette persists: its uid:// when the file
## has one, so a move or rename keeps it resolving; else the path itself.
static func persist_id(path: String) -> String:
	if path.is_empty() or path.begins_with("uid://"):
		return path
	var uid := ResourceLoader.get_resource_uid(path)
	return ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else path


## The resource path a persisted id names now, or "" for an unknown uid.
static func resolve_id(id: String) -> String:
	if not id.begins_with("uid://"):
		return id
	var uid := ResourceUID.text_to_id(id)
	if uid == ResourceUID.INVALID_ID or not ResourceUID.has_id(uid):
		return ""
	return ResourceUID.get_id_path(uid)


static func _load_material(id: String) -> Material:
	var path := resolve_id(id)
	if path.is_empty() or not ResourceLoader.exists(path, "Material"):
		return null
	return ResourceLoader.load(path) as Material


func set_default(material: Material) -> void:
	if material == null:
		return
	pin(material)
	_default_mat = material
	_default_path = persist_id(material.resource_path)
	changed.emit()
	_rebuild()


func clear_default() -> void:
	_default_mat = null
	_default_path = ""
	changed.emit()
	_rebuild()


func default_material() -> Material:
	if _default_mat == null and not _default_path.is_empty():
		_default_mat = _load_material(_default_path)
	return _default_mat


## Persisted like a pin (persist_id), off the live resource when loaded.
func get_default_path() -> String:
	if _default_mat != null and not _default_mat.resource_path.is_empty():
		return persist_id(_default_mat.resource_path)
	return _default_path


func set_default_path(path: String) -> void:
	_default_path = path
	_default_mat = null
	_rebuild()


func _is_default(mat: Material) -> bool:
	if mat == null:
		return false
	if mat == _default_mat:
		return true
	return _names(get_default_path(), mat)


static func _names(id: String, mat: Material) -> bool:
	if id.is_empty() or mat == null or mat.resource_path.is_empty():
		return false
	return id == mat.resource_path or id == persist_id(mat.resource_path) \
		or resolve_id(id) == mat.resource_path


func _find_pinned(material: Material) -> int:
	for i in _pinned.size():
		if _pinned[i].mat == material:
			return i
		if _names(_pinned[i].path, material):
			return i
	return -1


func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return UBMaterialDrop.extract_material(data) != null


func _drop_data(_pos: Vector2, data: Variant) -> void:
	pin(UBMaterialDrop.extract_material(data))


func _rebuild() -> void:
	for child in _flow.get_children():
		if child != _add:
			child.queue_free()
	var scale := EditorInterface.get_editor_scale()
	for entry in _pinned:
		_flow.add_child(_make_swatch(entry.mat, entry.path, false, scale))
	for mat: Material in _recent:
		_flow.add_child(_make_swatch(mat, "", true, scale))
	_flow.move_child(_add, -1)
	_hint.visible = _pinned.is_empty() and _recent.is_empty()


func _make_swatch(mat: Material, path: String, recent: bool, scale: float) -> Swatch:
	var b := Swatch.new()
	b.mat = mat
	b.is_recent = recent
	b.palette = self
	b.custom_minimum_size = Vector2.ONE * SWATCH_PX * scale
	b.expand_icon = true
	b.focus_mode = Control.FOCUS_NONE
	if mat == null:
		b.missing_path = path
		b.text = "!"
		b.tooltip_text = "Missing file: %s. Drag the material in again to repair, right-click to remove" % path
		return b
	var name := mat.resource_path.get_file()
	if name.is_empty():
		name = "built-in material (won't persist until saved to a file)"
	if recent:
		b.modulate.a = 0.55
		b.tooltip_text = "Recent: %s. Click to apply, right-click to pin" % name
	else:
		b.tooltip_text = "%s. Click to apply to the selection (whole mesh when empty), drag onto a face, right-click to remove" % name
	if _is_default(mat):

		b.tooltip_text = "DEFAULT for new shapes. " + b.tooltip_text
		var badge := PanelContainer.new()
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.12, 0.13, 0.16, 0.92)
		sb.set_corner_radius_all(roundi(4.0 * scale))
		sb.set_content_margin_all(2.0 * scale)
		badge.add_theme_stylebox_override("panel", sb)
		var glyph_tex := UBOverlayToolbar._icon("default_badge")
		if glyph_tex != null:
			var glyph := TextureRect.new()
			glyph.texture = glyph_tex
			glyph.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
			glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
			badge.add_child(glyph)
		else:
			var glyph := Label.new()
			glyph.text = "✓"
			glyph.add_theme_color_override("font_color", Color(0.984, 0.749, 0.141))
			glyph.add_theme_font_size_override("font_size", roundi(10.0 * scale))
			glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
			badge.add_child(glyph)
		b.add_child(badge)
		badge.position = Vector2.ONE * 2.0 * scale
	b.pressed.connect(func() -> void: apply_requested.emit(mat))

	if mat is BaseMaterial3D:
		var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
		img.fill((mat as BaseMaterial3D).albedo_color)
		b.icon = ImageTexture.create_from_image(img)

	if mat is UBBlendMaterial:
		_render_blend_swatch(b, mat)
		return b
	var previewer := EditorInterface.get_resource_previewer()
	if mat.resource_path.is_empty():
		previewer.queue_edited_resource_preview(mat, self, "_preview_ready", b)
	else:
		previewer.queue_resource_preview(mat.resource_path, self, "_preview_ready", b)
	return b


func _render_blend_swatch(swatch: Swatch, mat: Material) -> void:
	if _blend_preview == null or not is_instance_valid(_blend_preview):
		_blend_preview = UBBlendPreview.new()
		add_child(_blend_preview)
	var tex: Texture2D = await _blend_preview.render_material(mat)

	if tex != null and is_instance_valid(swatch):
		swatch.icon = tex


func _preview_ready(_path: String, preview: Texture2D, _thumb: Texture2D, swatch: Variant) -> void:

	if preview == null or not is_instance_valid(swatch):
		return
	var b := swatch as Swatch
	if b != null:
		b.icon = preview


func _show_context(swatch: Swatch) -> void:
	_menu_swatch = swatch
	if _menu == null or not is_instance_valid(_menu):
		_menu = PopupMenu.new()
		add_child(_menu)
		_menu.id_pressed.connect(_on_context)
	_menu.clear()
	if swatch.is_recent:
		_menu.add_item("Pin to Palette", 0)
		_menu.add_item("Set as Default for New Shapes", 2)
	elif swatch.mat != null:
		if _is_default(swatch.mat):
			_menu.add_item("Clear Default", 3)
		else:
			_menu.add_item("Set as Default for New Shapes", 2)
		_menu.add_separator()
		_menu.add_item("Remove from Palette", 1)
	else:
		_menu.add_item("Remove from Palette", 1)
	_menu.popup(Rect2(swatch.get_screen_position() + Vector2(0, swatch.size.y), Vector2.ZERO))


func _on_context(id: int) -> void:
	if _menu_swatch == null or not is_instance_valid(_menu_swatch):
		return
	if id == 0:
		pin(_menu_swatch.mat)
		return
	if id == 2:
		set_default(_menu_swatch.mat)
		return
	if id == 3:
		clear_default()
		return
	for i in _pinned.size():
		var entry: Dictionary = _pinned[i]
		if entry.mat == _menu_swatch.mat and (entry.mat != null or entry.path == _menu_swatch.missing_path):
			if entry.mat != null and _is_default(entry.mat):
				_default_mat = null
				_default_path = ""
			_pinned.remove_at(i)
			changed.emit()
			_rebuild()
			return


func _open_add_dialog() -> void:
	if _add_dialog == null or not is_instance_valid(_add_dialog):
		_add_dialog = EditorFileDialog.new()
		_add_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_add_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_add_dialog.add_filter("*.tres, *.res, *.material", "Material resources")
		_add_dialog.file_selected.connect(func(path: String) -> void:
			var mat := ResourceLoader.load(path) as Material
			if mat == null:
				push_warning("Unibuilder: %s is not a Material." % path)
				return
			pin(mat))

		add_child(_add_dialog)
	_add_dialog.popup_centered_ratio(0.5)
