shader_type spatial;
// The ceiling's share of the grid GI (scripts/World/level/grid_gi.gd): light bounced up off the lit floor and walls
// round a lamp, added over a ceiling so it is not black between the panels. Additive (blend_add), so it never darkens
// anything: the tiles and the light panels keep their own colour, and the panels only get brighter where they are
// near the lamps. Kept small (ceil_gain): a stronger lift turns the whole ceiling white.
render_mode unshaded, blend_add, depth_draw_never, cull_back, fog_disabled, shadows_disabled;

uniform sampler2D gi_map : filter_linear, repeat_disable;   // g: the bounce at ceiling height, a texel a cell
uniform float map_cells = 64.0;
uniform float map_cell = 4.5;
uniform float strength = 0.0;
uniform float ceil_gain = 0.0;      // how much of the bounce the ceiling takes (per look)
uniform vec3 gi_color = vec3(1.0, 0.88, 0.6);
uniform float fog_density = 0.0;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz;
	vec2 uv = (p / map_cell + 0.5) / map_cells;
	float e = texture(gi_map, uv).g * strength * ceil_gain;
	float fog = exp(-fog_density * length(wpos - CAMERA_POSITION_WORLD));
	ALBEDO = gi_color * e * fog;
}
