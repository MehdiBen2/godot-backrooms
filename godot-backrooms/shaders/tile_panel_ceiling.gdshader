shader_type spatial;
// A tiled ceiling with its light panels set in among the tiles: the pool rooms' white tiles (textures/pbr/
// Tile_White_Grid_Lit, a ceiling material with "metadata/tile_panels"). Built like the other panel ceilings by
// level_fixtures.gd _build_panel_ceiling, one quad a cell from a MultiMesh whose instance colour is that cell's
// glow (black where the cell isn't one of the lit ones, or its panel is burnt out, or the power is cut), so
// flicker and power cuts reach the panel exactly as they reach the light hidden behind it.
//
// The tiles are laid in world space, one texture every tile_repeat metres, so they run on unbroken across the
// cells, and every cell's middle falls on a grout line. A lit cell's panel is the block of panel_tiles x panel_tiles
// tiles round its middle glowing through their glaze: the grout between them stays dark, so it reads as tiles lit
// from behind, the way the pool rooms' ceilings are, not a sheet of light stuck on.
render_mode cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tile_repeat = 2.25;        // metres one repeat of the texture covers
uniform float tiles_across = 8.0;        // tiles in one repeat of it (Tile_White_Grid: 8 x 8)
uniform float panel_tiles = 4.0;         // a panel is this many tiles square
uniform float round_spots = 0.0;         // 1: the light is a small round downlight (any tile colour), not a block of tiles
uniform float spot_radius = 0.17;        // m
uniform float cell = 4.5;                // level_data.gd CELL
uniform float ao_light_affect = 0.2;
// Found-footage bounce light off the room below (level_lighting.gd drives it, as for the other ceilings), pooled
// round the lit cells (every other cell each way, level_fixtures.gd _place_panel_fixtures)
uniform float ceiling_fill = 0.0;
uniform float fill_between = 0.35;
uniform vec3 world_shift = vec3(0.0);   // endless halls: a copy of the level one period away (level_builder.gd)
uniform vec3 glaze_tint : source_color = vec3(0.97, 0.98, 1.0);

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz + world_shift.xz;
	vec2 uv = world / tile_repeat;
	vec3 alb = texture(albedo_tex, uv).rgb;
	float face_raw = smoothstep(0.72, 0.9, dot(alb, vec3(0.333)));     // the glazed face of a tile, not the grout
	float face = mix(face_raw, 1.0, round_spots);                     // a round lamp shines whatever tile is round it
	vec2 local = world - floor(world / cell + 0.5) * cell;           // from this cell's middle
	float half_w = panel_tiles * 0.5 * tile_repeat / tiles_across;
	float panel = step(abs(local.x), half_w) * step(abs(local.y), half_w);
	float glow = max(max(COLOR.r, COLOR.g), COLOR.b);
	float spot_d = length(local);
	float spot = step(spot_d, spot_radius);
	// the lamps sit in every other cell each way (the cells that hold a light); the rest are plain tile
	vec2 idx = floor(world / cell + 0.5);
	float fixture = round_spots * step(abs(mod(idx.x, 2.0)), 0.5) * step(abs(mod(idx.y, 2.0)), 0.5);
	float rim = (step(spot_d, spot_radius + 0.035) - spot) * fixture;      // the dark trim ring round the lamp
	float lit = mix(panel, spot, round_spots) * step(0.02, glow);
	float lens = spot * fixture;                                            // the lamp's own face: no tile shows through it, lit or not
	ALBEDO = mix(alb * glaze_tint, vec3(0.97, 0.98, 1.0), lit * 0.5);
	// the diffuser's plastic: frosted grain, fine concentric prism ridges, a slightly domed face (thicker at the middle)
	float rr = clamp(spot_d / spot_radius, 0.0, 1.0);
	float grain = hash21(floor(world * 900.0));
	float ridges = 0.5 + 0.5 * sin(rr * 95.0);
	float plastic = 1.0 - 0.07 * grain - 0.06 * ridges - 0.12 * rr * rr;
	vec3 off_col = vec3(0.70, 0.72, 0.73) * plastic;
	ALBEDO = mix(ALBEDO, off_col, lens * (1.0 - lit));       // switched off: a pale frosted diffuser
	ALBEDO = mix(ALBEDO, vec3(0.03), rim);                                   // solid trim: no tile shows through
	vec2 radial = spot_d > 0.001 ? local / spot_d : vec2(0.0);
	vec3 dome = vec3(0.5 + radial.x * rr * 0.22 + (grain - 0.5) * 0.03, 0.5 + radial.y * rr * 0.22 + (grain - 0.5) * 0.03, 1.0);
	NORMAL_MAP = mix(mix(texture(normal_tex, uv).rgb, vec3(0.5, 0.5, 1.0), rim), dome, lens);
	ROUGHNESS = mix(texture(rough_tex, uv).r, mix(0.3, 0.38 + 0.12 * grain, lens), max(max(lit, lens), rim));
	SPECULAR = 0.5;
	AO_LIGHT_AFFECT = ao_light_affect;
	// far off a panel's tiles shrink to a pixel or two and the filter averages glaze and grout in HDR: settle the
	// glow to its average and down to 1x, as panel_ceiling.gdshader does, so the far ceiling doesn't burn white
	float footprint = max(length(dFdx(world)), length(dFdy(world)));
	float far_k = smoothstep(0.03, 0.2, footprint);
	float peak = max(glow, 1.0);
	vec3 emit = COLOR.rgb * lit * mix(face, 0.8, far_k) * mix(1.0, 1.0 / peak, far_k);
	emit *= mix(1.0, mix(1.0, plastic * 1.12, round_spots), 1.0 - far_k);   // the lit diffuser: brightest at the middle, fine ridges and grain in it
	vec2 to_lit = (fract(world / (2.0 * cell) + 0.5) - 0.5) * 2.0 * cell;
	float pool = 1.0 - smoothstep(1.0, cell * 1.1, length(to_lit));
	EMISSION = emit + ALBEDO * ceiling_fill * mix(fill_between, 1.0, pool);
}
