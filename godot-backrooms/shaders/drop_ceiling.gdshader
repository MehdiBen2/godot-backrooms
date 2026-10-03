shader_type spatial;
// A real suspended (drop) ceiling, built tile by tile: Yasu's Backrooms Material Pack (CC BY 4.0, @mvyasu), the
// textures/pbr/YBR_Ceiling* materials. One quad per level cell, drawn from a MultiMesh (level_fixtures.gd,
// _build_panel_ceiling), like panel_ceiling.gdshader, but nothing is baked into a cell-sized picture:
//   - every tile picks one of the pack's tiles (2 x 2 square ones, or 2 x 4 long ones) at random, mirrored at
//     random, and ages on its own: a shade of its own, some yellowed, a few newer and whiter (replaced), a few
//     sitting a little tilted in the grid, and wide water stains running over many tiles at once;
//   - the light panels sit on the lit cells' fixtures (the middle tile and the four diagonals, 1.5 m out:
//     level_fixtures.gd PANEL_OFFSETS) and glow by the instance colour (flicker, power cuts, tints, burnt out);
//     a burnt-out fixture is a dead grey diffuser, not a missing light;
//   - the return-air grilles (3D models, level_fixtures.gd _build_vents) get a dark opening behind their slots.
// Everything is placed from the world position, so a tile cut by a cell edge is the same tile on both sides.
render_mode cull_back;

uniform sampler2D tile_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tile_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tile_rough : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D light_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D light_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D light_rough : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D light_metal : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
// (anisotropic, see panel_ceiling.gdshader: the far ceiling seen edge-on must not average a panel over its tile)
uniform sampler2D light_emit : source_color, hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float long_tiles = 0.0;         // 1: 2 x 4 tiles and troffers (1.5 x 0.75 m), long side along world x
uniform float cell = 4.5;               // level_data.gd CELL: 6 tiles of 0.75 m a cell
uniform vec3 albedo_tint : source_color = vec3(0.9, 0.87, 0.76);   // aged cream: the pack's tiles are near white
uniform vec3 light_tint : source_color = vec3(0.96, 0.96, 0.94);
uniform float light_gain = 0.85;        // over the instance colour (level_fixtures.gd PANEL_GLOW)
uniform float tile_vary = 0.045;        // how much one tile's shade differs from the next
uniform float stained = 0.06;           // share of tiles yellowed with age
uniform float replaced = 0.035;         // share of tiles put in later: whiter, not yet yellowed
uniform float tilted = 0.12;            // share of tiles sitting a little tilted (one side catches more light)
uniform float water_stains = 0.5;       // the wide stains across many tiles (0 = none)
uniform float normal_depth = 1.0;
uniform float specular = 0.35;
// bounce light on the ceiling (level_lighting.gd); pools round the lit cells like panel_ceiling.gdshader's
uniform float ceiling_fill = 0.0;
uniform float fill_between = 0.3;

varying vec4 info;      // INSTANCE_CUSTOM: x, y two vents (0 none, see level_fixtures.gd _vent_code), z 1 on a lit-grid cell

void vertex() {
	info = INSTANCE_CUSTOM;
}

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

// A grille's dark opening: `code` is level_fixtures.gd _vent_code (1 + type * 1024 + (ix + 16) + (iz + 16) * 32,
// ix / iz its centre in 0.375 m steps from the cell's middle; type 1 is a return grille)
bool in_grille(float code, vec2 p) {
	int c = int(code + 0.5);
	if (c <= 0) return false;
	c -= 1;
	if (c / 1024 != 1) return false;
	int r = c % 1024;
	vec2 at = vec2(float(r % 32 - 16), float(r / 32 - 16)) * (cell / 12.0);
	return all(lessThan(abs(p - at), vec2(cell / 6.0 * 0.47)));
}

void fragment() {
	float ts = cell / 6.0;
	bool longt = long_tiles > 0.5;
	vec2 tsz = longt ? vec2(ts * 2.0, ts) : vec2(ts);
	vec2 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz;
	vec2 p = world - round(world / cell) * cell;        // metres from this cell's middle
	vec2 wt = world / tsz;
	vec2 tile = round(wt);                              // the tile, world wide (shared by the cells it spans)
	vec2 l = wt - tile;                                 // where in the tile, -0.5 .. 0.5
	vec2 rel = round(p / tsz);                          // the tile within this cell
	bool panel_spot = longt
		? ((rel.x == 0.0 && rel.y == 0.0) || (abs(rel.x) == 1.0 && abs(rel.y) == 2.0))
		: ((rel.x == 0.0 && rel.y == 0.0) || (abs(rel.x) == 2.0 && abs(rel.y) == 2.0));
	bool is_light = panel_spot && info.z > 0.5;
	// which of the pack's tiles, mirrored which way: 2 x 2 square ones, or 2 long ones (one a row)
	vec2 flip = step(vec2(0.5), vec2(hash12(tile + 7.7), hash12(tile + 63.2))) * 2.0 - 1.0;
	vec2 pick = step(vec2(0.5), vec2(hash12(tile + 41.7), hash12(tile + 93.1)));
	vec2 uv;
	vec2 per;                                           // texture units per tile unit
	if (longt) {
		uv = vec2(0.5 + l.x * flip.x, (pick.y + 0.5 + l.y * flip.y) * 0.5);
		per = vec2(1.0, 0.5);
	} else {
		uv = (pick + 0.5 + l * flip) * 0.5;
		per = vec2(0.5);
	}
	// slopes from the world position, not from uv: the jump from one tile to the next is not a slope, and read
	// as one it dropped the grid bars to the tiniest mip (a bright seam along every T-bar)
	vec2 gx = dFdx(wt) * per * flip;
	vec2 gy = dFdy(wt) * per * flip;

	vec3 alb;
	vec3 nm;
	float rough;
	float metal = 0.0;
	vec3 emit = vec3(0.0);
	if (is_light) {
		alb = textureGrad(light_albedo, uv, gx, gy).rgb * light_tint;
		nm = textureGrad(light_normal, uv, gx, gy).rgb;
		rough = textureGrad(light_rough, uv, gx, gy).r;
		metal = textureGrad(light_metal, uv, gx, gy).r;
		emit = textureGrad(light_emit, uv, gx, gy).rgb;
	} else {
		alb = textureGrad(tile_albedo, uv, gx, gy).rgb * albedo_tint;
		nm = textureGrad(tile_normal, uv, gx, gy).rgb;
		rough = max(textureGrad(tile_rough, uv, gx, gy).r, 0.5);    // mineral fibre: matte, so a torch lights it
		float h = hash12(tile);
		vec3 shade = vec3(1.0 + (h - 0.5) * 2.0 * tile_vary);
		float age = hash12(tile + 17.3);
		if (age < stained) shade *= vec3(0.97, 0.91, 0.76);
		else if (age > 1.0 - replaced) shade *= vec3(1.05, 1.07, 1.14);
		if (hash12(tile + 5.1) < tilted) shade *= 1.0 + dot(l, vec2(hash12(tile + 2.2), hash12(tile + 3.3)) - 0.5) * 0.2;
		float blot = vnoise(world / 6.5) * 0.65 + vnoise(world / 2.2 + 31.0) * 0.35;
		shade *= mix(vec3(1.0), vec3(0.93, 0.87, 0.72), smoothstep(0.58, 0.85, blot) * water_stains);
		alb *= shade;
		// behind a return grille: the dark of the ceiling void, seen through its slots
		if (in_grille(info.x, p) || in_grille(info.y, p)) {
			alb = vec3(0.02);
			nm = vec3(0.5, 0.5, 1.0);
			rough = 1.0;
		}
	}
	// a mirrored tile's bumps lean the other way
	if (flip.x < 0.0) nm.r = 1.0 - nm.r;
	if (flip.y < 0.0) nm.g = 1.0 - nm.g;
	ALBEDO = alb;
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = normal_depth;
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = specular;
	// Far away a panel shrinks to a pixel or two and the filter averages its HDR glow over the tiles round it,
	// which lit the whole far ceiling: as it shrinks its glow is brought down to 1x (see panel_ceiling.gdshader)
	float footprint = max(length(dFdx(UV)), length(dFdy(UV)));
	float far_k = smoothstep(0.025, 0.1, footprint);
	float peak = max(max(max(COLOR.r, COLOR.g), COLOR.b), 1.0);
	vec2 to_lit = (fract(world / (2.0 * cell) + 0.5) - 0.5) * 2.0 * cell;
	float pool = 1.0 - smoothstep(1.0, cell * 1.1, length(to_lit));
	EMISSION = emit * COLOR.rgb * light_gain * mix(1.0, 1.0 / peak, far_k) + ALBEDO * ceiling_fill * mix(fill_between, 1.0, pool);
}
