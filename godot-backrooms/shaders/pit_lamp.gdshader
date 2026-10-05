shader_type spatial;
// A ceiling light of the rooms behind a shaft's wall (scripts/World/level/shaft_lamps.gd): the troffer model, lit
// by the same lamp_level() as the room under it, so the tube, the lens and the pool of light agree.
render_mode cull_disabled, shadows_disabled, ambient_light_disabled;
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
uniform vec3 albedo_col : source_color = vec3(0.8);
uniform float is_tube = 0.0;       // 1: the tubes themselves: they are the light
void fragment() {
	float l = lamp_now();
	vec3 c = lamp_color();
	ALBEDO = albedo_col;
	ROUGHNESS = 0.55;
	METALLIC = 0.2;
	// the housing and tray catch the room's light a little, lit or not; the tubes glow with it
	vec3 emit = is_tube > 0.5 ? c * tube_glow * l : albedo_col * c * (0.04 + 0.35 * l);
	float lit = 1.0 - smoothstep(fade_from, fade_to, wpos.y);
	float sink = 1.0 - exp(-max(-wpos.y, 0.0) * down_k);
	float hz = 1.0 - exp(-max(wpos.y - haze_y, 0.0) * haze_k);
	ALBEDO *= lit * (1.0 - 0.8 * sink);
	emit *= lit * (1.0 - 0.8 * sink);
	EMISSION = mix(emit, haze_color, max(hz, sink * 0.4));
	ALBEDO *= 1.0 - hz;
}
