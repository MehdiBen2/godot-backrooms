shader_type spatial;
// Terrain: dark under the grass, fading to the meadow colours with distance (GodotGrass ground look),
// with the road, slope dirt and grass-matched lighting on top.
uniform vec3 grass_a : source_color = vec3(0.16, 0.28, 0.07);
uniform vec3 grass_b : source_color = vec3(0.36, 0.42, 0.13);
uniform vec3 dry_col : source_color = vec3(0.5, 0.45, 0.2);
uniform vec3 dirt_col : source_color = vec3(0.3, 0.22, 0.13);
uniform vec3 road_col : source_color = vec3(0.24, 0.22, 0.19);
uniform vec3 under_grass_col : source_color = vec3(0.04, 0.15, 0.01);
uniform vec3 subsurface_scattering_color : source_color = vec3(1.0, 0.75, 0.1);
uniform float grass_range = 90.0;   // where the grass tiles end (hills.gd GRASS_RADIUS)
uniform sampler2D turf_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D turf_rough : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D turf_ao : filter_linear_mipmap_anisotropic, repeat_enable;
// two path materials, patched together at random so the road and dirt never look uniform
uniform sampler2D path_a_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D path_a_rough : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D path_a_ao : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D path_b_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D path_b_rough : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D path_b_ao : filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 wpos;
varying float road;
varying float upness;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.05 + vec2(11.3, 5.9);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	road = COLOR.r;
	upness = NORMAL.y;
}

// two scales blended so the tiling never reads
vec3 tex2(sampler2D t, vec2 p, float k) {
	return mix(texture(t, p * 0.42).rgb, texture(t, p * 0.083 + 0.37).rgb, k);
}

float fbm2(vec2 p) {
	return 0.66 * vnoise(p) + 0.34 * vnoise(p * 2.1 + vec2(11.3, 5.9));
}

void fragment() {
	vec2 p = wpos.xz;
	float slope = (1.0 - smoothstep(0.5, 0.7, upness)) * 0.6;
	float r = smoothstep(0.25, 0.75, road);
	float solid = max(r, slope);
	float dist = length(wpos.xz - CAMERA_POSITION_WORLD.xz);
	float far_t = smoothstep(grass_range * 0.3, grass_range * 0.95, dist);
	// under the blades the ground reads dark; the textures below are only sampled where they can be seen
	// (road, steep slopes, and beyond the grass), which keeps the meadow around you cheap
	vec3 col = under_grass_col * 0.15;
	float rough = 1.0;
	float ao = 1.0;
	if (far_t > 0.001 || solid > 0.001) {
		float tile_mix = 0.45;
		float blotch = fbm2(p * 0.045);
		vec3 turf = tex2(turf_color, p, tile_mix);
		vec3 g = turf * mix(grass_a, grass_b, smoothstep(0.25, 0.75, blotch)) * 3.2;
		g = mix(g, turf * dry_col * 3.0, smoothstep(0.6, 0.9, vnoise(p * 0.02 + 7.0)) * 0.2);
		g *= 0.85 + 0.3 * vnoise(p * 1.7);
		float turf_r = texture(turf_rough, p * 0.42).r;
		float turf_a = texture(turf_ao, p * 0.42).r;
		vec3 solid_col = g;
		float solid_r = turf_r;
		float solid_a = turf_a;
		if (solid > 0.001) {
			// irregular patches decide which path material shows where
			float pm = smoothstep(0.38, 0.62, vnoise(p * 0.13 + 3.1) * 0.65 + vnoise(p * 0.6 + 9.7) * 0.35);
			vec3 soil = mix(tex2(path_a_color, p, tile_mix), tex2(path_b_color, p, tile_mix), pm);
			solid_col = soil * mix(0.85, 0.95, r);
			solid_r = mix(texture(path_a_rough, p * 0.42).r, texture(path_b_rough, p * 0.42).r, pm);
			solid_a = mix(texture(path_a_ao, p * 0.42).r, texture(path_b_ao, p * 0.42).r, pm);
		}
		col = mix(mix(col, g, far_t), solid_col, solid);
		rough = mix(mix(1.0, turf_r, far_t), solid_r, solid);
		ao = mix(mix(1.0, turf_a, far_t), solid_a, solid);
	}
	ALBEDO = col;
	ROUGHNESS = mix(rough, 1.0, 0.1);
	AO = ao;
	AO_LIGHT_AFFECT = 0.6;
	SPECULAR = 0.1;
}

void light() {
	float diffuse_factor = pow(4.0, dot(NORMAL, LIGHT)) / 4.0; // never drops to 0: fake ambient bounce
	float sss_factor = max(-dot(VIEW, LIGHT), 0.0) * 0.5;
	DIFFUSE_LIGHT += (diffuse_factor + sss_factor * subsurface_scattering_color * 0.5) * ATTENUATION * LIGHT_COLOR;
}
