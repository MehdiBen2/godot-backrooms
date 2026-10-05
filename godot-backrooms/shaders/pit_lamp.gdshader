shader_type spatial;
// A wall tube of a shaft (scripts/World/level/shaft_lamps.gd): the troffer model, lit by its storey's row, the same
// row_level() that pit_shaft.gdshader lights the walls from. The tubes glow; the housing and tray only catch some of it.
render_mode cull_disabled, shadows_disabled, ambient_light_disabled;

uniform float seg_h = 9.0;
uniform float cell = 4.5;
uniform float rows[16];
uniform int period = 12;
uniform vec3 tube_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float tube_glow = 4.0;
uniform vec3 albedo_col : source_color = vec3(0.8);
uniform float is_tube = 0.0;
uniform float rot_from = 100000000.0;
uniform float rot_to = 200000000.0;
uniform float fade_from = 100000000.0;
uniform float fade_to = 200000000.0;
uniform vec3 haze_color : source_color = vec3(0.0);
uniform float haze_k = 0.0;
uniform float haze_y = 0.0;

varying vec3 wpos;

#include "res://shaders/pit_light.gdshaderinc"

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float row = floor(wpos.y / seg_h);
	vec2 tp = round(wpos.xz / (0.5 * cell)) * 0.5 * cell;
	float lv = tube_level(tp, row, TIME);
	vec3 col = tube_color * tube_col(tp);
	float rot = smoothstep(rot_from, rot_to, wpos.y);
	ALBEDO = albedo_col;
	ROUGHNESS = 0.55;
	METALLIC = 0.2;
	vec3 emit = is_tube > 0.5 ? col * tube_glow * lv : albedo_col * col * (0.03 + 0.25 * lv);
	emit *= 1.0 - 0.5 * rot;
	float lit = 1.0 - smoothstep(fade_from, mix(fade_from, fade_to, 0.4), wpos.y);
	ALBEDO *= lit;
	emit *= 1.0 - smoothstep(fade_from, fade_to, wpos.y);
	float hz = 1.0 - exp(-max(wpos.y - haze_y, 0.0) * haze_k);
	ALBEDO *= 1.0 - hz;
	EMISSION = mix(emit, haze_color, hz);
}
