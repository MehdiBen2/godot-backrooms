shader_type spatial;
// The skirting and door-frame paint: the Plaster_001 maps blended in world space (the boards have no UVs), in a
// warm cream that sits with the yellowed wallpaper, each stretch of board a shade lighter or darker than its
// neighbour, as if touched up at different times. Clean: the walls' own wear marks the foot. Used by skirt_material.gd.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float normal_strength = 0.6;
uniform float per_metre = 1.2;
uniform vec3 tint : source_color = vec3(0.84, 0.79, 0.66);      // aged cream paint: under white, warmed to sit with the wallpaper
uniform float variation = 0.03;                                   // board to board, +/- of its brightness

varying vec3 wp;
varying vec3 wn;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash(i);
	float n100 = hash(i + vec3(1, 0, 0));
	float n010 = hash(i + vec3(0, 1, 0));
	float n110 = hash(i + vec3(1, 1, 0));
	float n001 = hash(i + vec3(0, 0, 1));
	float n101 = hash(i + vec3(1, 0, 1));
	float n011 = hash(i + vec3(0, 1, 1));
	float n111 = hash(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 w = pow(abs(wn), vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 q = wp * per_metre;
	vec3 col = texture(albedo_tex, q.zy).rgb * w.x + texture(albedo_tex, q.xz).rgb * w.y + texture(albedo_tex, q.xy).rgb * w.z;
	float rough = texture(rough_tex, q.zy).r * w.x + texture(rough_tex, q.xz).r * w.y + texture(rough_tex, q.xy).r * w.z;
	// the stretch of board it is on: a fixed lightness and a slight warm or cool lean, per 1.4 m
	vec3 cell = floor(wp * vec3(0.7, 0.0, 0.7) + vec3(0.5));
	float h = hash(cell + vec3(3.0, 7.0, 11.0));
	float h2 = hash(cell + vec3(19.0, 5.0, 2.0));
	float bright = 1.0 + (h - 0.5) * 2.0 * variation;
	vec3 lean = vec3(1.0 + (h2 - 0.5) * 0.04, 1.0, 1.0 - (h2 - 0.5) * 0.06);
	vec3 base = col * tint * bright * lean;
	ALBEDO = base;
	// the plaster's own grain, blended in world space and turned into the view's: lit like any surface
	vec2 nx = texture(normal_tex, q.zy).xy * 2.0 - 1.0;
	vec2 ny = texture(normal_tex, q.xz).xy * 2.0 - 1.0;
	vec2 nz = texture(normal_tex, q.xy).xy * 2.0 - 1.0;
	vec3 wnrm = normalize(wn + normal_strength * (vec3(0.0, nx.y, nx.x) * w.x + vec3(ny.x, 0.0, ny.y) * w.y + vec3(nz.x, nz.y, 0.0) * w.z));
	NORMAL = normalize((VIEW_MATRIX * vec4(wnrm, 0.0)).xyz);
	ROUGHNESS = clamp(0.62 + rough * 0.3, 0.0, 1.0);
	SPECULAR = 0.35;
}
