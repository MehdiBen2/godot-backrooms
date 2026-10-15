@tool
@icon("res://addons/unibuilder/icons/blend_material.svg")
class_name UBBlendMaterial
extends ShaderMaterial
## The dual-layer PBR blend shader (materials/ub_blend.gdshader) as a named resource
## type, so it appears in a material slot's "New Resource" list beside
## StandardMaterial3D. The shader is assigned on construction only when the slot is
## empty, so a material loaded from disk keeps the shader it was saved with.

const SHADER_PATH := "res://addons/unibuilder/materials/ub_blend.gdshader"

enum Layer { A, B }

## Uniform base names carried per layer. Each exists in the shader as "<name>_a"
## and "<name>_b"; the suffix is the only difference between the two layers.
const LAYER_UNIFORMS: Array[String] = [
	"texture", "albedo", "normal", "normal_scale",
	"roughness_map", "roughness_channel", "roughness",
	"metallic_map", "metallic_channel", "metallic",
	"ao_map", "ao_channel", "height_map", "height_offset",
	"emission_map", "emission", "emission_energy",
	"uv_scale", "uv_offset",
]


func _init() -> void:
	if shader == null:
		shader = load(SHADER_PATH)


static func layer_suffix(layer: int) -> String:
	return "_b" if layer == Layer.B else "_a"


## Returns the current values of one layer's uniforms, keyed by base name. A uniform
## the material never overrode reads back as null, since get_shader_parameter
## reports overrides only. Applying that null through apply_layer erases the
## override again, so a snapshot round-trips.
func layer_values(layer: int) -> Dictionary:
	var suffix := layer_suffix(layer)
	var out := {}
	for name in LAYER_UNIFORMS:
		out[name] = get_shader_parameter(name + suffix)
	return out


## Writes a layer snapshot back. Keys not present are left alone, so a partial
## dictionary is a valid patch.
func apply_layer(layer: int, values: Dictionary) -> void:
	var suffix := layer_suffix(layer)
	for name in values:
		set_shader_parameter(String(name) + suffix, values[name])


## Maps a StandardMaterial3D or ORMMaterial3D onto one blend layer's uniforms:
## albedo, normal, roughness, metallic, AO, height, emission and the UV1 transform.
## Features with no shader equivalent (rim, clearcoat, subsurface, detail maps,
## triplanar, transparency) are dropped.
static func layer_from_standard(src: BaseMaterial3D) -> Dictionary:
	var values := {
		"texture": src.albedo_texture,
		"albedo": src.albedo_color,

		"normal": src.normal_texture if src.normal_enabled else null,
		"normal_scale": src.normal_scale,
		"roughness_map": src.roughness_texture,
		"roughness_channel": _shader_channel(src.roughness_texture_channel),
		"roughness": src.roughness,
		"metallic_map": src.metallic_texture,
		"metallic_channel": _shader_channel(src.metallic_texture_channel),
		"metallic": src.metallic,
		"ao_map": src.ao_texture if src.ao_enabled else null,
		"ao_channel": _shader_channel(src.ao_texture_channel),

		"height_map": src.heightmap_texture if src.heightmap_enabled else null,
		"emission_map": src.emission_texture if src.emission_enabled else null,
		"emission": src.emission if src.emission_enabled else Color(0, 0, 0, 1),
		"emission_energy": src.emission_energy_multiplier,
		"uv_scale": Vector2(src.uv1_scale.x, src.uv1_scale.y),
		"uv_offset": Vector2(src.uv1_offset.x, src.uv1_offset.y),
	}

	var orm := src.get_texture(BaseMaterial3D.TEXTURE_ORM)
	if orm != null:
		values.ao_map = orm
		values.ao_channel = 0
		values.roughness_map = orm
		values.roughness_channel = 1
		values.metallic_map = orm
		values.metallic_channel = 2
	return values


func import_layer(layer: int, src: BaseMaterial3D) -> void:
	apply_layer(layer, layer_from_standard(src))


static func _shader_channel(channel: int) -> int:
	return channel if channel >= 0 and channel <= 3 else 0
