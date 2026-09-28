shader_type spatial;
// Drop ceiling with square light panels baked into its texture (textures/pbr/BRC_A). One quad per level
// cell, drawn from a MultiMesh (level_lighting.gd, _build_panel_ceiling). Each cell's instance colour is
// that cell's panel glow: level_lighting.gd sets it per fixture, so burnt cells, flicker, power cuts and
// event tints reach the panels exactly as they reach the real lights under them.
// A panel that isn't lit is drawn as a plain ceiling tile: BRC_A's colour map bakes the lit-panel squares in,
// so it borrows the tile one to the right, which in BRC_A's layout is never a panel.
// Every tile gets its own slight shade (a few are yellowed with age) so the ceiling isn't one flat colour.
render_mode cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
// Anisotropic like the others. With plain mipmaps the far ceiling (seen almost edge-on) dropped to tiny mips
// where each bright panel was averaged over its whole tile: the entire far ceiling glowed, and past a certain
// distance the dead-panel test below failed too, so the switched-off panels lit up as well.
uniform sampler2D emission_tex : source_color, hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 albedo_tint : source_color = vec3(0.96, 0.9, 0.7);   // the reference ceilings are cream-yellow, not grey
uniform float tile_size = 0.75;         // metres: BRC_A has 6 x 6 tiles per 4.5 m cell
uniform float tile_vary = 0.05;         // how much one tile's shade differs from the next
uniform float stained = 0.08;           // share of tiles yellowed with age
uniform float normal_depth = 1.0;
uniform float ao_light_affect = 0.2;   // AO belongs on bounce light, not on the panels' own direct light
uniform float specular = 0.4;
// Found-footage look: a real drop ceiling under this much light is one of the brightest things in the room
// (light bouncing off the carpet and walls). The tube lights skip the ceiling layer, so level_lighting.gd
// drives this fill instead: 0 = off, fades with power cuts.
uniform float ceiling_fill = 0.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec3 emit = texture(emission_tex, UV).rgb;
	float panel = clamp(dot(emit, vec3(0.333)) * 1.4, 0.0, 1.0);
	float glow = clamp(max(max(COLOR.r, COLOR.g), COLOR.b), 0.0, 1.0);
	float dead = panel * (1.0 - glow);   // 1 inside the square of a panel that is off
	vec2 tuv = UV + vec2(dead > 0.5 ? 1.0 / 6.0 : 0.0, 0.0);
	vec3 orm = texture(orm_tex, tuv).rgb;
	// which tile this is, in world space (tile edges sit at (x + tile/2) / tile = whole numbers)
	vec2 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz;
	vec2 tile = floor((world + tile_size * 0.5) / tile_size);
	float h = hash12(tile);
	vec3 shade = vec3(1.0 + (h - 0.5) * 2.0 * tile_vary);
	if (hash12(tile + 17.3) < stained) shade *= vec3(0.97, 0.92, 0.78);
	ALBEDO = texture(albedo_tex, tuv).rgb * albedo_tint * mix(shade, vec3(1.0), panel * glow);
	NORMAL_MAP = texture(normal_tex, tuv).rgb;
	NORMAL_MAP_DEPTH = normal_depth;
	AO = orm.r;
	AO_LIGHT_AFFECT = ao_light_affect;
	ROUGHNESS = max(orm.g, 0.55);         // painted steel T-bars and mineral tiles: matte, so a torch lights them
	METALLIC = 0.0;                       // (the ORM marks the grid as bare metal, which ignores diffuse light)
	SPECULAR = specular;
	EMISSION = emit * COLOR.rgb + ALBEDO * ceiling_fill;
}
