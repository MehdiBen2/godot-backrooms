shader_type spatial;
// Bounce light from the level's grid GI (scripts/World/level/grid_gi.gd), drawn as a second pass over the floors,
// walls and ceilings (the next_pass of their own materials). The light a surface gets back from the room round it:
// brightest near the working lamps, fading with distance and stopped by walls, carried along corridors, tinted by
// the yellow walls and carpet it bounced off. The low-frequency light a real (baked) GI gives a room, which an
// even ambient fill can't: darker between the lamps and down a long hall.
//
// It multiplies what the surface already is (blend_mul) rather than adding a colour on top: the wallpaper's print,
// the normal map's relief and the grime stay exactly as the base pass drew them, only lit more or less (x (1 +
// bounce)). Floors and walls only: a ceiling's light panels are drawn in its own material, and a multiply over it
// dimmed the panels too (grid_gi.gd attach leaves the ceiling layer alone).
// Unshaded: the renderer's own lights, shadows and fog are in the base pass; the fog's share is kept out of the
// multiplier here by hand, so the far haze isn't brightened along with the surface behind it.
render_mode unshaded, blend_mul, depth_draw_never, cull_back, fog_disabled, shadows_disabled;

uniform sampler2D gi_map : filter_linear, repeat_disable;   // r: bounce at the floor, g: at the ceiling, a texel a cell
uniform float map_cells = 64.0;
uniform float map_cell = 4.5;
uniform float hi_height = 5.4;      // the height the "ceiling" channel is for
uniform float strength = 0.0;
uniform vec3 gi_color = vec3(1.0, 0.88, 0.6);       // the bounce's tint times the lamps' white
uniform float fog_density = 0.0;
uniform float probe = 0.45;         // cells: how far off a wall face into the room its bounce is read

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// a wall face reads the room in front of it, not the wall block it belongs to
	vec2 p = wpos.xz + wnrm.xz * map_cell * probe;
	vec2 uv = (p / map_cell + 0.5) / map_cells;
	vec2 g = texture(gi_map, uv).rg;
	float t = clamp(wpos.y / hi_height, 0.0, 1.0);
	float e = mix(g.r, g.g, smoothstep(0.0, 1.0, t)) * strength;
	vec3 m = vec3(1.0) + gi_color * e;
	// the fogged share of the pixel is fog, not surface: leave it as it is
	float fog = exp(-fog_density * length(wpos - CAMERA_POSITION_WORLD));
	ALBEDO = mix(vec3(1.0), m, fog);
}
