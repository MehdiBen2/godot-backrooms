shader_type spatial;
render_mode cull_disabled;
// Grass tufts: base-to-tip colour, wind sway, normals forced up so blades shade like the ground.
uniform vec3 base_col : source_color = vec3(0.07, 0.14, 0.03);
uniform vec3 tip_col : source_color = vec3(0.5, 0.58, 0.2);
uniform float wind_strength = 0.22;
uniform float wind_speed = 1.3;

varying float tip;
varying vec3 tint;

void vertex() {
	tip = UV.y;
	tint = COLOR.rgb;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * wind_speed;
	float gust = sin(t + wp.x * 0.35 + wp.z * 0.2) + 0.5 * sin(t * 2.3 + wp.x * 0.9 - wp.z * 0.6);
	vec3 w = vec3(gust, 0.0, 0.6 * gust + 0.3 * sin(t * 1.7 + wp.z * 0.5)) * wind_strength * tip * tip;
	VERTEX += inverse(mat3(MODEL_MATRIX)) * w;
	NORMAL = normalize(inverse(mat3(MODEL_MATRIX)) * vec3(0.0, 1.0, 0.0));
}

void fragment() {
	vec3 c = mix(base_col, tip_col, smoothstep(0.0, 1.0, tip)) * tint;
	ALBEDO = c;
	ROUGHNESS = 0.7;
	SPECULAR = 0.2;
	BACKLIGHT = c * 0.35;
}
