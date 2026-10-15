@tool
class_name UBPreferencesPanel
extends PopupPanel
## Preferences popup: overlay colours and vertex handle size. Emits each edit
## at once for live preview; plugin.gd owns the dict, applies it and persists it.

signal pref_changed(key: String, value: Variant)
signal reset_requested

const SCENE := "res://addons/unibuilder/editor/preferences_panel.tscn"


var _vertex_spin: SpinBox
var _grow_spin: SpinBox
var _lightmap_spin: SpinBox
var _live_uv2_check: CheckBox
var _pickers := {}


## The one way to make this control (plugin and tests both use it). load(),
## not preload(): the scene references this script.
static func create() -> UBPreferencesPanel:
	return (load(SCENE) as PackedScene).instantiate() as UBPreferencesPanel


func _notification(what: int) -> void:
	if what != NOTIFICATION_SCENE_INSTANTIATED:
		return
	_vertex_spin = %VertexSize
	_grow_spin = %GrowAngle
	_lightmap_spin = %LightmapTexel
	_live_uv2_check = %LiveUV2
	_pickers = {
		"color_edge": %ColorEdge, "color_edge_selected": %ColorEdgeSelected,
		"color_vertex": %ColorVertex, "color_vertex_selected": %ColorVertexSelected,
		"color_face_selected": %ColorFaceSelected,
	}
	_vertex_spin.value_changed.connect(func(v: float) -> void: pref_changed.emit("vertex_size", v))
	_grow_spin.value_changed.connect(func(v: float) -> void: pref_changed.emit("grow_angle", v))
	_lightmap_spin.value_changed.connect(func(v: float) -> void:
		pref_changed.emit("lightmap_texel", v)
		_sync_live_uv2_enabled())
	_live_uv2_check.toggled.connect(func(v: bool) -> void: pref_changed.emit("live_uv2", v))
	for key: String in _pickers:
		(_pickers[key] as ColorPickerButton).color_changed.connect(func(c: Color) -> void:
			pref_changed.emit(key, c))
	(%Reset as Button).pressed.connect(func() -> void: reset_requested.emit())


func _sync_live_uv2_enabled() -> void:
	var off: bool = _lightmap_spin.value <= 0.0
	_live_uv2_check.disabled = off
	_live_uv2_check.tooltip_text = (
		"Set a bake lightmap texel above 0 to enable live UV2. It unwraps at that size."
		if off else
		"Keep live meshes lightmap-ready: unwrap UV2s (at the bake texel size)"
		+ " shortly after each edit settles, so LightmapGI works without baking"
		+ " to MeshInstance3D first.")


func set_values(p: Dictionary) -> void:
	_vertex_spin.set_value_no_signal(p.vertex_size)
	_grow_spin.set_value_no_signal(p.get("grow_angle", 180.0))
	_lightmap_spin.set_value_no_signal(p.get("lightmap_texel", 0.2))
	_live_uv2_check.set_pressed_no_signal(p.get("live_uv2", true))
	_sync_live_uv2_enabled()
	for key: String in _pickers:
		_pickers[key].color = p[key]
