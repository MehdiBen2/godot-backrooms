shader_type spatial;
// A ceiling light of the rooms behind a shaft's wall (scripts/World/level/shaft_lamps.gd): the troffer model, lit
// by the same lamp_level() as the room under it, so the tube, the lens and the pool of light agree.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float cell = 4.5;
uniform float seg_h = 9.0;
uniform float rows[16];
uniform int period = 12;
uniform vec3 tube_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float tube_glow = 3.2;
uniform float fade_from = 100000000.0;
uniform float fade_to = 200000000.0;
uniform vec3 haze_color : source_color = vec3(0.0);
uniform float haze_k = 0.0;
uniform float haze_y = 0.0;
uniform float down_k = 0.0;
#include "res://shaders/pit_light.gdshaderinc"
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float lamp_now() {
	// (the model hangs under the ceiling, so its own height is in the storey the light is lit in)
	float row = floor((wpos.y + 0.2) / seg_h);
	return lamp_level(cell * round(wpos.xz / cell), row, TIME);
}
vec3 lamp_color() {
	float row = floor((wpos.y + 0.2) / seg_h);
	return tube_color * row_color(row) * tube_tint(cell * round(wpos.xz / cell));
}
void fragment() {
	float l = lamp_now();
	float lit = 1.0 - smoothstep(fade_from, fade_to, wpos.y);
	float sink = 1.0 - exp(-max(-wpos.y, 0.0) * down_k);
	float hz = 1.0 - exp(-max(wpos.y - haze_y, 0.0) * haze_k);
	float k = lit * (1.0 - 0.8 * sink) * (1.0 - hz);
	ALBEDO = lamp_color() * 0.5 * l * k;
	ALPHA = 0.35;
}
