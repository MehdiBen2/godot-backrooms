shader_type spatial;
render_mode cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D height_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec4 albedo_tint : source_color = vec4(1.0, 0.94, 0.75, 1.0);
uniform vec2 uv_scale = vec2(0.5, 0.5);
uniform float normal_scale : hint_range(0.0, 5.0) = 2.4;
uniform float roughness_mult : hint_range(0.0, 2.0) = 0.88;
uniform float metallic_specular : hint_range(0.0, 1.0) = 0.35;
uniform float ao_light_affect : hint_range(0.0, 1.0) = 0.75;

uniform float height_scale : hint_range(0.0, 0.1) = 0.04;
uniform int min_layers : hint_range(0, 32) = 6;
uniform int max_layers : hint_range(0, 64) = 14;    // 0 turns POM off (Low preset)
uniform float near_distance : hint_range(5.0, 20.0) = 10.0;
uniform float near_fade_range : hint_range(1.0, 5.0) = 2.5;
uniform float crevice_ao_strength : hint_range(0.0, 2.0) = 0.6;

uniform float mid_distance : hint_range(15.0, 60.0) = 30.0;
uniform float mid_fade_range : hint_range(2.0, 10.0) = 5.0;

varying vec3 v_world_pos;
varying vec2 v_uv;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_uv = (length(UV) > 0.0001 ? UV : v_world_pos.xz) * uv_scale;
}

void fragment() {
	vec2 uv = v_uv;
	// Gradients taken once, up front: inside the (per-pixel, variable-length) march below implicit derivatives
	// are undefined and the GPU falls back to slow paths, and every fetch here reuses them via textureGrad.
	vec2 uv_dx = dFdx(uv);
	vec2 uv_dy = dFdy(uv);
	float dist = -VERTEX.z;
	float final_depth = 0.0;

	// Tier 1: Near Range (0 to 10m) - Full Silhouette POM & Crevice Shadowing
	if (dist < near_distance && height_scale > 0.001 && max_layers > 0) {
		float pom_weight = clamp((near_distance - dist) / near_fade_range, 0.0, 1.0);

		vec3 v_ts = vec3(
			dot(VIEW, TANGENT),
			-dot(VIEW, BINORMAL),
			dot(VIEW, NORMAL)
		);
		v_ts = normalize(v_ts);

		float num_layers = mix(float(max_layers), float(min_layers), clamp(dot(NORMAL, VIEW), 0.0, 1.0));
		float layer_step = 1.0 / num_layers;
		vec2 max_offset = -(v_ts.xy / max(v_ts.z, 0.08)) * (height_scale * pom_weight);
		vec2 delta_uv = max_offset * layer_step;

		vec2 curr_uv = uv;
		float curr_layer_depth = 0.0;
		float curr_map_depth = 1.0 - textureGrad(height_tex, curr_uv, uv_dx, uv_dy).r;
		float prev_map_depth = curr_map_depth;

		// hard-capped march (an unbounded while can spin on a flat-black height texel)
		int steps = int(num_layers) + 1;
		for (int i = 0; i < steps && curr_layer_depth < curr_map_depth; i++) {
			prev_map_depth = curr_map_depth;
			curr_uv += delta_uv;
			curr_layer_depth += layer_step;
			curr_map_depth = 1.0 - textureGrad(height_tex, curr_uv, uv_dx, uv_dy).r;
		}

		vec2 prev_uv = curr_uv - delta_uv;
		float prev_layer_depth = curr_layer_depth - layer_step;

		float after_depth = curr_layer_depth - curr_map_depth;
		float before_depth = prev_map_depth - prev_layer_depth;
		float weight = clamp(after_depth / max(after_depth + before_depth, 0.0001), 0.0, 1.0);

		uv = mix(curr_uv, prev_uv, weight);
		final_depth = mix(curr_layer_depth, prev_layer_depth, weight) * pom_weight;
	}

	// Tier 3: Far Range (30m+) - Basic Texturing (Normal map high-frequencies smoothly disabled)
	float far_fade = clamp((dist - (mid_distance - mid_fade_range)) / mid_fade_range, 0.0, 1.0);
	float active_normal_depth = mix(normal_scale, 0.0, far_fade);

	vec4 alb = textureGrad(albedo_tex, uv, uv_dx, uv_dy) * albedo_tint;
	float rough = textureGrad(roughness_tex, uv, uv_dx, uv_dy).r * roughness_mult;
	float base_ao = textureGrad(ao_tex, uv, uv_dx, uv_dy).r;

	float crevice_occ = 1.0 - pow(final_depth, 1.3) * crevice_ao_strength;
	float final_ao = clamp(base_ao * crevice_occ, 0.0, 1.0);

	ALBEDO = alb.rgb * mix(vec3(0.85), vec3(1.0), 1.0 - final_depth * 0.4);
	NORMAL_MAP = textureGrad(normal_tex, uv, uv_dx, uv_dy).rgb;
	NORMAL_MAP_DEPTH = active_normal_depth;
	ROUGHNESS = rough;
	SPECULAR = metallic_specular;
	AO = final_ao;
	AO_LIGHT_AFFECT = ao_light_affect;
}
