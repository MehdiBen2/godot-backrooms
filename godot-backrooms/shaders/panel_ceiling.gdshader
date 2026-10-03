shader_type spatial;
// Drop ceiling with square light panels baked into its texture (textures/pbr/BRC_A). One quad per level
// cell, drawn from a MultiMesh (level_lighting.gd, _build_panel_ceiling). Each cell's instance colour is
// that cell's panel glow: level_lighting.gd sets it per fixture, so burnt cells, flicker, power cuts and
// event tints reach the panels exactly as they reach the real lights under them.
// A panel that isn't lit is drawn as a plain ceiling tile: BRC_A's colour map bakes the lit-panel squares in,
// so it borrows the tile one to the right, which in BRC_A's layout is never a panel.
// Every tile gets its own slight shade (a few are yellowed with age) so the ceiling isn't one flat colour.
//
// No repeat: the texture is laid once per cell, so its own darker / yellowed tiles came back in the same spots
// every 4.5 m and the whole ceiling read as one stamped pattern. Each tile now borrows a random plain tile of
// the texture instead (picked by where the tile is in the world, so the halves of a tile split by a cell edge
// agree). Only a lit panel keeps its own square. Wide, faint water stains run across many tiles on top.
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
uniform float water_stains = 0.55;      // the wide stains across many tiles (0 = none)
uniform float normal_depth = 1.0;
uniform float ao_light_affect = 0.2;   // AO belongs on bounce light, not on the panels' own direct light
uniform float specular = 0.4;
// Found-footage look: a real drop ceiling under this much light is one of the brightest things in the room
// (light bouncing off the carpet and walls). The tube lights skip the ceiling layer, so level_lighting.gd
// drives this fill instead: 0 = off, fades with power cuts.
// Bounce light pools round the lights: it is brightest under the lit cells and falls away between them (a flat
// fill made every tile glow alike, near a light or not, and read as a painted, fake ceiling). Lit cells sit on
// every other cell each way (level_fixtures.gd _place_panel_fixtures), so the nearest one is found from the
// world position alone.
uniform float ceiling_fill = 0.0;
uniform float cell = 4.5;               // level_data.gd CELL
uniform float fill_between = 0.3;       // share of the fill left halfway between two lit cells
// A drop ceiling is never flat: some tiles sit a little tilted in their grid and catch the light unevenly
uniform float tilted = 0.2;             // share of tiles that do
// endless halls (level_builder.gd _build_wrap_copies): a copy of the level drawn one period away sets this to
// minus its offset, so it samples the world exactly as the level it copies does (no jump in the pattern at the seam)
uniform vec3 world_shift = vec3(0.0);

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

// In BRC_A's layout (6 x 6 tiles a cell, tile k centred at UV k / 6) the panels are tiles (1,1) (5,1) (1,5)
// (5,5) and (3,3): the middle and the four diagonals (level_fixtures.gd PANEL_OFFSETS)
bool is_panel_tile(ivec2 k) {
	return (k == ivec2(3)) || ((k.x == 1 || k.x == 5) && (k.y == 1 || k.y == 5));
}

void fragment() {
	vec3 emit = texture(emission_tex, UV).rgb;
	float panel = clamp(dot(emit, vec3(0.333)) * 1.4, 0.0, 1.0);
	float glow = clamp(max(max(COLOR.r, COLOR.g), COLOR.b), 0.0, 1.0);
	// which tile this is, in world space (tile edges sit at (x + tile/2) / tile = whole numbers)
	vec2 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz + world_shift.xz;
	vec2 tile = floor((world + tile_size * 0.5) / tile_size);
	// this tile in the cell's texture, and where in the tile this point is (-0.5 .. 0.5)
	vec2 kf = floor(UV * 6.0 + 0.5);
	vec2 local = UV * 6.0 - kf;
	ivec2 k = ivec2(kf);
	vec2 tuv = UV;
	vec2 flip = vec2(1.0);
	// a lit panel keeps its own square (its glow is drawn from it); every other tile, a switched-off panel
	// included, wears a random plain tile: (1..5, 1..5), never a panel ((2, any) never is), mirrored at random
	// (BRC_A's tiles are all alike apart from their speckle: 20 of them alone still showed as a pattern)
	if (!(is_panel_tile(k) && glow > 0.5)) {
		vec2 src = vec2(1.0) + floor(vec2(hash12(tile + 41.7), hash12(tile + 93.1)) * 4.999);
		if (is_panel_tile(ivec2(src))) src.x = 2.0;
		flip = step(vec2(0.5), vec2(hash12(tile + 7.7), hash12(tile + 63.2))) * 2.0 - 1.0;
		tuv = (src + local * flip) / 6.0;
	}
	// sampled with the cell's own UV slopes: the jump from one borrowed tile to the next is not a slope, and
	// read as one it dropped the grid lines to the tiniest mip (a bright seam along every T-bar)
	vec2 gx = dFdx(UV) * flip;
	vec2 gy = dFdy(UV) * flip;
	vec3 orm = textureGrad(orm_tex, tuv, gx, gy).rgb;
	float h = hash12(tile);
	vec3 shade = vec3(1.0 + (h - 0.5) * 2.0 * tile_vary);
	if (hash12(tile + 17.3) < stained) shade *= vec3(0.97, 0.92, 0.78);
	// a tilted tile: one side a touch brighter than the other
	if (hash12(tile + 5.1) < tilted) shade *= 1.0 + dot(local, vec2(hash12(tile + 2.2), hash12(tile + 3.3)) - 0.5) * 0.22;
	// wide water stains: soft yellow-brown patches a few metres across, over many tiles at once
	float blot = vnoise(world / 6.5) * 0.65 + vnoise(world / 2.2 + 31.0) * 0.35;
	shade *= mix(vec3(1.0), vec3(0.93, 0.87, 0.72), smoothstep(0.58, 0.85, blot) * water_stains);
	ALBEDO = textureGrad(albedo_tex, tuv, gx, gy).rgb * albedo_tint * mix(shade, vec3(1.0), panel * glow);
	vec3 nm = textureGrad(normal_tex, tuv, gx, gy).rgb;
	// a mirrored tile's bumps lean the other way
	if (flip.x < 0.0) nm.r = 1.0 - nm.r;
	if (flip.y < 0.0) nm.g = 1.0 - nm.g;
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = normal_depth;
	AO = orm.r;
	AO_LIGHT_AFFECT = ao_light_affect;
	ROUGHNESS = max(orm.g, 0.55);         // painted steel T-bars and mineral tiles: matte, so a torch lights them
	METALLIC = 0.0;                       // (the ORM marks the grid as bare metal, which ignores diffuse light)
	SPECULAR = specular;
	// Far away a panel and the tiles round it shrink into a pixel or two, and the texture filter averages them
	// in HDR, before the tonemapper clips anything: a panel glowing at 3.6x white smeared over its whole tile
	// made the far ceiling glow white. Up close the camera clips each panel to white anyway, so as a panel
	// shrinks under a few pixels its glow is brought down to 1x: the average then matches what a camera sees.
	// (UV runs 0..1 across one cell; a panel is about 1/6 of that.)
	float footprint = max(length(dFdx(UV)), length(dFdy(UV)));
	float far_k = smoothstep(0.025, 0.1, footprint);
	float peak = max(max(max(COLOR.r, COLOR.g), COLOR.b), 1.0);
	// offset from the nearest lit cell's centre (they sit every 2 cells each way, at the world origin's parity)
	vec2 to_lit = (fract(world / (2.0 * cell) + 0.5) - 0.5) * 2.0 * cell;
	float pool = 1.0 - smoothstep(1.0, cell * 1.1, length(to_lit));
	EMISSION = emit * COLOR.rgb * mix(1.0, 1.0 / peak, far_k) + ALBEDO * ceiling_fill * mix(fill_between, 1.0, pool);
}
