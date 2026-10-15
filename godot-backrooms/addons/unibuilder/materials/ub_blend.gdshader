shader_type spatial;


vec4 channel_mask(int channel) {
	return vec4(float(channel == 0), float(channel == 1),
			float(channel == 2), float(channel == 3));
}

group_uniforms Blend;

uniform float height_blend : hint_range(0.0, 1.0) = 0.0;


uniform float blend_sharpness : hint_range(0.001, 1.0) = 0.1;


uniform bool invert_mask = false;

uniform bool tint_by_vertex_color = true;
uniform float ao_light_affect : hint_range(0.0, 1.0) = 1.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

group_uniforms Parallax;


uniform bool deep_parallax = false;

uniform float parallax_scale : hint_range(-16.0, 16.0, 0.1) = 5.0;
uniform int parallax_min_layers : hint_range(1, 64) = 8;
uniform int parallax_max_layers : hint_range(1, 64) = 32;

group_uniforms LayerA;
uniform sampler2D texture_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_a : source_color = vec4(1.0);
uniform sampler2D normal_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale_a : hint_range(-16.0, 16.0) = 1.0;
uniform sampler2D roughness_map_a : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform int roughness_channel_a : hint_enum("Red", "Green", "Blue", "Alpha") = 0;
uniform float roughness_a : hint_range(0.0, 1.0) = 0.9;
uniform sampler2D metallic_map_a : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform int metallic_channel_a : hint_enum("Red", "Green", "Blue", "Alpha") = 0;
uniform float metallic_a : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D ao_map_a : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform int ao_channel_a : hint_enum("Red", "Green", "Blue", "Alpha") = 0;
uniform sampler2D height_map_a : hint_default_white, filter_linear_mipmap, repeat_enable;


uniform float height_offset_a : hint_range(-1.0, 1.0) = 0.0;
uniform sampler2D emission_map_a : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 emission_a : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy_a : hint_range(0.0, 16.0) = 1.0;
uniform vec2 uv_scale_a = vec2(1.0, 1.0);
uniform vec2 uv_offset_a = vec2(0.0, 0.0);

group_uniforms LayerB;
uniform sampler2D texture_b : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_b : source_color = vec4(1.0);
uniform sampler2D normal_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale_b : hint_range(-16.0, 16.0) = 1.0;
uniform sampler2D roughness_map_b : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform int roughness_channel_b : hint_enum("Red", "Green", "Blue", "Alpha") = 0;
uniform float roughness_b : hint_range(0.0, 1.0) = 0.9;
uniform sampler2D metallic_map_b : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform int metallic_channel_b : hint_enum("Red", "Green", "Blue", "Alpha") = 0;
uniform float metallic_b : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D ao_map_b : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform int ao_channel_b : hint_enum("Red", "Green", "Blue", "Alpha") = 0;
uniform sampler2D height_map_b : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float height_offset_b : hint_range(-1.0, 1.0) = 0.0;
uniform sampler2D emission_map_b : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 emission_b : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy_b : hint_range(0.0, 16.0) = 1.0;
uniform vec2 uv_scale_b = vec2(1.0, 1.0);
uniform vec2 uv_offset_b = vec2(0.0, 0.0);

group_uniforms;


float blended_factor(float t, float ha, float hb) {
	if (height_blend <= 0.0) {
		return t;
	}
	float top = max(ha + (1.0 - t), hb + t) - blend_sharpness;
	float wa = max(ha + (1.0 - t) - top, 0.0);
	float wb = max(hb + t - top, 0.0);
	float height_t = wb / max(wa + wb, 0.00001);
	return mix(t, height_t, height_blend);
}


float surface_height(vec2 base_uv, float paint, vec2 gx, vec2 gy) {
	float ha = textureGrad(height_map_a, base_uv * uv_scale_a + uv_offset_a,
			gx * uv_scale_a, gy * uv_scale_a).r + height_offset_a;
	float hb = textureGrad(height_map_b, base_uv * uv_scale_b + uv_offset_b,
			gx * uv_scale_b, gy * uv_scale_b).r + height_offset_b;
	return clamp(mix(ha, hb, blended_factor(paint, ha, hb)), 0.0, 1.0);
}

void fragment() {
	vec2 base_uv = UV;

	float paint = invert_mask ? 1.0 - COLOR.a : COLOR.a;
	if (deep_parallax) {

		vec3 view_dir = normalize(normalize(-VERTEX + EYE_OFFSET)
				* mat3(TANGENT, -BINORMAL, NORMAL));
		float num_layers = mix(float(parallax_max_layers), float(parallax_min_layers),
				abs(dot(vec3(0.0, 0.0, 1.0), view_dir)));
		float layer_depth = 1.0 / num_layers;
		vec2 delta = view_dir.xy * parallax_scale * 0.01 / num_layers;
		vec2 gx = dFdx(base_uv);
		vec2 gy = dFdy(base_uv);
		vec2 ofs = base_uv;
		float depth = 1.0 - surface_height(ofs, paint, gx, gy);
		float current_depth = 0.0;
		while (current_depth < depth) {
			ofs -= delta;
			depth = 1.0 - surface_height(ofs, paint, gx, gy);
			current_depth += layer_depth;
		}
		vec2 prev_ofs = ofs + delta;
		float after_depth = depth - current_depth;
		float before_depth = (1.0 - surface_height(prev_ofs, paint, gx, gy))
				- current_depth + layer_depth;
		float weight = after_depth / (after_depth - before_depth);
		base_uv = mix(ofs, prev_ofs, weight);
	}
	vec2 uv_a = base_uv * uv_scale_a + uv_offset_a;
	vec2 uv_b = base_uv * uv_scale_b + uv_offset_b;

	float ha = texture(height_map_a, uv_a).r + height_offset_a;
	float hb = texture(height_map_b, uv_b).r + height_offset_b;
	float t = blended_factor(paint, ha, hb);

	vec4 base_a = texture(texture_a, uv_a) * albedo_a;
	vec4 base_b = texture(texture_b, uv_b) * albedo_b;
	vec3 albedo = mix(base_a.rgb, base_b.rgb, t);
	if (tint_by_vertex_color) {
		albedo *= COLOR.rgb;
	}

	ALBEDO = albedo;

	NORMAL_MAP = mix(texture(normal_a, uv_a).rgb, texture(normal_b, uv_b).rgb, t);
	NORMAL_MAP_DEPTH = mix(normal_scale_a, normal_scale_b, t);

	float rough_a = dot(texture(roughness_map_a, uv_a), channel_mask(roughness_channel_a));
	float rough_b = dot(texture(roughness_map_b, uv_b), channel_mask(roughness_channel_b));
	ROUGHNESS = mix(rough_a * roughness_a, rough_b * roughness_b, t);

	float metal_a = dot(texture(metallic_map_a, uv_a), channel_mask(metallic_channel_a));
	float metal_b = dot(texture(metallic_map_b, uv_b), channel_mask(metallic_channel_b));
	METALLIC = mix(metal_a * metallic_a, metal_b * metallic_b, t);
	SPECULAR = specular;

	AO = mix(dot(texture(ao_map_a, uv_a), channel_mask(ao_channel_a)),
			dot(texture(ao_map_b, uv_b), channel_mask(ao_channel_b)), t);
	AO_LIGHT_AFFECT = ao_light_affect;

	EMISSION = mix(texture(emission_map_a, uv_a).rgb * emission_a.rgb * emission_energy_a,
			texture(emission_map_b, uv_b).rgb * emission_b.rgb * emission_energy_b, t);
}
