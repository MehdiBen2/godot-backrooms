shader_type spatial;
// The glass of a wall tube (shaft_lamps.gd): a soft additive glow over the tube while its row is lit.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform float seg_h = 9.0;
uniform float cell = 4.5;
uniform float rows[16];
uniform int period = 12;
uniform vec3 tube_color : source_color = vec3(1.0, 0.93, 0.78);
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
	vec2 tp = round(wpos.xz / (0.5 * cell)) * 0.5 * cell;
	float lv = tube_level(tp, floor(wpos.y / seg_h), TIME);
	float k = (1.0 - smoothstep(fade_from, fade_to, wpos.y)) * exp(-max(wpos.y - haze_y, 0.0) * haze_k);
	ALBEDO = tube_color * tube_col(tp) * 1.4 * lv * k;
	ALPHA = 0.35;
}
