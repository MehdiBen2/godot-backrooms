shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
// 3D Equipment Cable Physical PBR Shader.
// Authentic industrial vulcanized rubber, flexible armored conduit, and hazard cords.
// Uses tangent-space NORMAL_MAP, micro-surface roughness detail, ambient occlusion,
// and grazing Fresnel rim specular response.

uniform vec4 cable_color : source_color = vec4(0.10, 0.10, 0.11, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.48;
uniform float metallic : hint_range(0.0, 1.0) = 0.03;
uniform float specular : hint_range(0.0, 1.0) = 0.55;
uniform int cable_style = 0; // 0 = heavy rubber, 1 = ribbed conduit, 2 = hazard striped, 3 = braided snake
uniform float rib_freq = 38.0;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ao_tex : filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec2 uv_scale = vec2(1.5, 5.0);
uniform float normal_depth : hint_range(0.0, 3.0) = 1.1;
uniform float rough_detail_strength : hint_range(0.0, 1.0) = 0.6;
uniform float color_texture_blend : hint_range(0.0, 1.0) = 0.45;

varying vec2 v_uv;
varying float v_end_mask;

void vertex() {
	v_uv = UV;
	v_end_mask = COLOR.r;
}

void fragment() {
	vec2 tex_uv = vec2(v_uv.x * uv_scale.x, v_uv.y * uv_scale.y);

	// Sample high-resolution PBR maps
	vec4 base_tex = texture(albedo_tex, tex_uv);
	vec3 norm_sample = texture(normal_tex, tex_uv).rgb;
	float rough_sample = texture(rough_tex, tex_uv).r;
	float ao_sample = texture(ao_tex, tex_uv).r;

	// Authentic jacket coloration with micro-surface grain
	vec3 col = cable_color.rgb;
	col = mix(col, col * (base_tex.rgb * 1.6), color_texture_blend);

	// Surface roughness with micro-grit and scuff detail
	float r_val = mix(roughness, roughness * (0.6 + 0.8 * rough_sample), rough_detail_strength);
	float m_val = metallic;
	vec3 n_tangent = norm_sample * 2.0 - 1.0;

	// Style 1: Ribbed flexible armored conduit
	if (cable_style == 1) {
		float rib = sin(v_uv.y * rib_freq * 3.14159 * 2.0);
		float rib_shade = smoothstep(-0.8, 0.8, rib);
		col *= mix(0.75, 1.2, rib_shade);
		r_val = mix(0.32, 0.58, rib_shade);
		m_val = 0.65;
		// Perturb tangent-space normal along Y (cable length)
		n_tangent.y += rib * 0.5;
		n_tangent = normalize(n_tangent);
	}
	// Style 2: Hazard striped warning cable
	else if (cable_style == 2) {
		// anti-aliased: the hard stripe edge turned into a flickering dotted line from a distance. The band blurs as
		// wide as a pixel covers (fwidth), so far away the stripes settle into an even yellow-black average
		float phase = v_uv.y * 3.2 + v_uv.x * 1.5;
		float k = clamp(fwidth(phase) * 5.0, 0.02, 1.0);
		float yel = smoothstep(-k, k, sin(phase * 6.28318));
		vec3 yellow = vec3(0.96, 0.78, 0.10) * (0.85 + 0.3 * base_tex.r);
		vec3 black = vec3(0.10, 0.10, 0.11) * (0.85 + 0.3 * base_tex.r);
		col = mix(black, yellow, yel);
		r_val = mix(r_val * 1.15, r_val * 0.85, yel);
	}
	// Style 3: Braided technical nylon sheath
	else if (cable_style == 3) {
		float b1 = sin((v_uv.x * 14.0 + v_uv.y * 24.0) * 3.14159);
		float b2 = sin((v_uv.x * 14.0 - v_uv.y * 24.0) * 3.14159);
		float braid = (b1 + b2) * 0.5;
		col *= mix(0.85, 1.15, smoothstep(-0.5, 0.5, braid));
		n_tangent.x += b1 * 0.25;
		n_tangent.y += b2 * 0.25;
		n_tangent = normalize(n_tangent);
		r_val = mix(r_val, 0.75, 0.5);
	}

	// Molded vulcanized rubber strain-relief boot & metal plug at cable ends
	if (v_end_mask > 0.05) {
		if (v_end_mask > 0.6) {
			// Industrial metal ferrule / plug collar
			col = mix(vec3(0.72, 0.70, 0.67), vec3(0.22, 0.22, 0.24), 0.3) * (0.85 + 0.3 * rough_sample);
			m_val = 0.88;
			r_val = 0.22 + 0.15 * rough_sample;
			n_tangent.xy *= 0.3;
			n_tangent = normalize(n_tangent);
		} else {
			// Heavy molded black rubber collar
			col = vec3(0.06, 0.06, 0.07);
			m_val = 0.02;
			r_val = 0.55 + 0.2 * rough_sample;
		}
	}

	// Physical PBR surface parameters with authentic tangential response
	ALBEDO = col;
	NORMAL_MAP = clamp(n_tangent * 0.5 + 0.5, vec3(0.0), vec3(1.0));
	NORMAL_MAP_DEPTH = normal_depth;
	ROUGHNESS = clamp(r_val, 0.05, 0.98);
	METALLIC = clamp(m_val, 0.0, 1.0);
	SPECULAR = specular;
	RIM = 0.28;
	RIM_TINT = 0.15;
	AO = clamp(ao_sample, 0.25, 1.0);
	AO_LIGHT_AFFECT = 0.5;
}
