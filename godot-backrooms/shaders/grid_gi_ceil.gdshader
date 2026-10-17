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
// gi_color is the bounce off yellow walls and carpet, for the walls and floor. Taken as it is the ceiling went
// orange: a cream tile ceiling lit back by them is only a little warm, and it is the tile's own colour that shows
uniform float saturation = 0.4;
uniform vec3 tile = vec3(0.8, 0.77, 0.64);   // the ceiling's colour (panel_ceiling.gdshader albedo_tint times its tiles)

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz;
	vec2 uv = (p / map_cell + 0.5) / map_cells;
	// what lights a ceiling is the floor and walls just under it: the floor's own bounce (r) keeps to the lit stretch,
	// where the broad ceiling channel (g) carried a grey glow far down the dark halls past it
	vec2 g = texture(gi_map, uv).rg;
	float e = mix(g.r, g.g, 0.25) * strength * ceil_gain;
	float fog = exp(-fog_density * length(wpos - CAMERA_POSITION_WORLD));
	vec3 c = mix(vec3(dot(gi_color, vec3(0.299, 0.587, 0.114))), gi_color, saturation);
	ALBEDO = c * tile * e * fog;
}
