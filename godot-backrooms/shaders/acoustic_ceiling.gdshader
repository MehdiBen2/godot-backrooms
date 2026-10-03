shader_type spatial;
// Level 0 drop ceiling: mineral-fibre acoustic tiles in a painted T-bar grid (textures/l0_ceiling_*,
// tools/generate_ceiling_textures.py). Built on level_geometry.gd's cell quads, whose UV is world x/z in metres.
// Painted mineral fibre is rough at a scale far below the texture: under a torch the lit patch reads as a fine,
// even grain (each speck of fibre catching the light at its own angle), with now and then a single pinprick
// glint off a mica fleck. Both are procedural normal detail in world space, so they are lit by the engine's
// own lighting: invisible in the dark, strongest in the beam, and locked to the surface as you move.
// The painted grid catches a thin satin line of light.
// Every tile also gets its own slight shade (a few yellowed with age) so the 3.6 m texture doesn't repeat.
render_mode cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_roughness_g, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 albedo_tint : source_color = vec3(0.89, 0.85, 0.74);
uniform float uv_scale = 0.278;        // texture repeats per metre (6 x 6 tiles, ~0.6 m each)
uniform float normal_depth = 1.4;
uniform float specular = 0.42;
uniform float ao_light_affect = 0.2;   // AO belongs on bounce light (level_geometry.gd AO_DIRECT)
uniform float tile_vary = 0.035;
uniform float stained = 0.07;
// the painted steel T-bars (the rough map marks them ~0.35): a satin line that catches the torch
uniform float rail_roughness = 0.3;
uniform float rail_specular = 0.6;
// fibre grain: fine normal + cavity noise, sized to the pixel (see fragment)
uniform float grain_cell = 0.0012;      // metres: finest grain, up close
uniform float grain_px = 1.0;           // a grain cell is never smaller than this many pixels (the camera's
                                        // VHS softness / TAA smear anything finer back to flat)
uniform float grain_strength = 0.07;    // normal slope of the grain (how much light it scatters)
uniform float grain_albedo = 0.012;     // colour speckle, light and dark
// The grain's pits also darken the ambient / bounce light (AO) and the fill glow, not just the direct
// light: most of the ceiling is lit by those, and without this it read perfectly flat outside the torch.
uniform float grain_cavity = 0.035;
// rare mica flecks: single-pixel glints
uniform float glint_density = 0.012;    // share of grain cells that hold a fleck
uniform float glint_tilt = 0.25;        // typical lean of a fleck off the tile (tangent-space slope, gaussian)
// per-fleck range: the smooth ones flash hard, the rest shimmer. Floor of 0.2: below it a fleck's highlight
// under a close light can overflow the half-float HDR buffer to Inf, which glow smears into coloured blocks.
uniform vec2 glint_roughness = vec2(0.2, 0.35);
// F0 = 0.16 * specular^2: 1.0 gives ~16% reflectance against painted fibre's ~3%. Kept at or under 1.0 (the
// engine's range) for the same reason. Kept dielectric so an unlit fleck still has the tile's diffuse colour.
uniform float glint_specular = 1.0;
uniform float glint_far = 60.0;         // metres: grain and flecks fade out with distance (the ceiling is 5+ m up,
                                        // so most of what you see of it is 6-20 m away)
// Found-footage look: bounce-light fill driven by level_lighting.gd (0 = off, fades with power cuts)
uniform float ceiling_fill = 0.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

// A leak stain: a yellowed blotch with brown tide lines round it (see drop_ceiling.gdshader, the same stains)
vec2 leak(vec2 w, float aa) {
	vec2 reg = floor(w / 3.0);
	if (hash12(reg + 151.0) > 0.18) return vec2(0.0);
	vec2 c = (reg + 0.5 + (vec2(hash12(reg + 7.0), hash12(reg + 13.0)) - 0.5) * 0.23) * 3.0;
	float r = 0.25 + 0.4 * hash12(reg + 29.0);
	vec2 q = (w - c) * vec2(1.0, 0.8 + 0.4 * hash12(reg + 41.0));
	float wob = vnoise(w * 2.4 + reg * 5.0) * 0.6 + vnoise(w * 7.0 + reg * 3.0) * 0.4;
	float d = length(q) + (wob - 0.5) * r * 0.45 - r;          // metres outside the edge (< 0 inside)
	aa = max(aa, 0.003);
	// the water sat longest at its edge: the brown gathers there, patchy, and fades toward the middle
	float inside = 1.0 - smoothstep(-aa, aa, d);
	float body = inside * (0.3 + 0.7 * smoothstep(-r * 0.7, 0.0, d)) * (0.55 + 0.45 * vnoise(w * 9.0 + reg * 7.0));
	// one tide line where it stopped: uneven in width and broken along its length, never a drawn circle
	float run = vnoise(w * 5.0 + reg * 2.0);
	float wdt = 0.003 + 0.008 * run;
	float line = (1.0 - smoothstep(wdt - aa, wdt + aa, abs(d))) * smoothstep(0.15, 0.55, run);
	// and on some, a fainter one from an older leak, a little further out and off true with this one
	if (hash12(reg + 61.0) < 0.4) {
		float d2 = d - r * (0.1 + 0.12 * hash12(reg + 71.0)) - (vnoise(w * 3.1 + reg * 4.0) - 0.5) * r * 0.3;
		float run2 = vnoise(w * 4.0 - reg * 3.0);
		line = max(line, (1.0 - smoothstep(0.003 - aa, 0.003 + aa, abs(d2))) * 0.4 * smoothstep(0.35, 0.7, run2));
	}
	return vec2(body, line) * (0.55 + 0.45 * hash12(reg + 57.0));
}

// Smooth value noise of random vec3s (xy = normal slope, z = albedo speckle), -1..1, in cell units
vec3 grain_noise(vec2 g) {
	vec2 i = floor(g);
	vec2 f = g - i;
	f = f * f * (3.0 - 2.0 * f);
	vec3 a = vec3(hash22(i), hash12(i + 5.3));
	vec3 b = vec3(hash22(i + vec2(1.0, 0.0)), hash12(i + vec2(6.3, 5.3)));
	vec3 c = vec3(hash22(i + vec2(0.0, 1.0)), hash12(i + vec2(5.3, 6.3)));
	vec3 d = vec3(hash22(i + vec2(1.0, 1.0)), hash12(i + 6.3));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) * 2.0 - 1.0;
}

// One octave of flecks: xy = the fleck's tilted normal slope, z = weight (a soft dot in its cell),
// w = its own roughness pick (0..1). The cell grid is turned off the tile grid and each level of it by a
// different angle, and the dots jitter round their cells, so the flecks never line up into rows.
vec4 flecks(vec2 world, float cell, float density, float level) {
	float a = 0.61 + level * 1.13;
	vec2 g = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * world / cell + level * 17.3;
	vec2 id = floor(g);
	float pick = hash12(id);
	if (pick > density) return vec4(0.0);
	vec2 centre = 0.25 + 0.5 * hash22(id + 11.7);
	float d = length(fract(g) - centre);
	float w = 1.0 - smoothstep(0.1, 0.25, d);
	// gaussian lean (Box-Muller): most flecks lie near flat, a few steep, so glints spread across the beam
	vec2 r = hash22(id + 3.1);
	vec2 slope = sqrt(-2.0 * log(max(r.x, 1e-4))) * vec2(cos(6.2832 * r.y), sin(6.2832 * r.y)) * glint_tilt;
	return vec4(slope, w, pick / density);
}

void fragment() {
	vec2 world = UV;                    // metres
	vec2 tuv = world * uv_scale;
	float rough = texture(rough_tex, tuv).g;
	float ao = texture(ao_tex, tuv).r;
	vec3 nm = texture(normal_tex, tuv).rgb;

	vec2 tile = floor(tuv * 6.0);
	vec3 shade = vec3(1.0 + (hash12(tile) - 0.5) * 2.0 * tile_vary);
	if (hash12(tile + 17.3) < stained) shade *= vec3(0.98, 0.93, 0.8);
	// far off a tile shrinks to a few pixels and its own shade flickers from pixel to pixel: settle it
	float tpp = max(length(dFdx(tuv)), length(dFdy(tuv))) * 6.0;
	shade = mix(vec3(0.999, 0.996, 0.988), shade, 1.0 - smoothstep(0.08, 0.25, tpp));
	vec2 lk = leak(world, length(fwidth(world)));
	shade *= mix(vec3(1.0), vec3(0.95, 0.9, 0.77), lk.x * 0.7) * mix(vec3(1.0), vec3(0.7, 0.58, 0.4), lk.y);
	ALBEDO = texture(albedo_tex, tuv).rgb * albedo_tint * shade;

	float rail = 1.0 - smoothstep(0.38, 0.45, rough);     // T-bar face
	float open = smoothstep(0.7, 0.9, ao) * (1.0 - rail);  // flat tile face: no flecks down fissures or pinholes

	// Grain and flecks are sized to the pixel, not the metre: at a 5 m ceiling one pixel already covers about
	// a centimetre, so millimetre detail would average away in the filtering / TAA. The cell size doubles in
	// steps as the footprint grows and the two nearest steps cross-fade, so the grain stays about a pixel
	// fine at any distance and never pops.
	// geometric mean of the two axes: at a grazing angle the max stretched each grain into a long soft smear
	float px = sqrt(length(dFdx(world)) * length(dFdy(world)));
	float lod = max(log2(px * grain_px / grain_cell), 0.0);
	float l = floor(lod);
	float t = lod - l;
	float cell = grain_cell * exp2(l);
	float dist_k = 1.0 - smoothstep(glint_far * 0.5, glint_far, length(VERTEX));
	float tile_face = 1.0 - rail;

	// two octaves per level (the second at half size) so each grain has a crisp edge, not a soft blob
	vec3 gn = mix(grain_noise(world / cell + l * 17.3) * 0.55 + grain_noise(world * 2.03 / cell + l * 5.1) * 0.6,
		grain_noise(world / (cell * 2.0) + (l + 1.0) * 17.3) * 0.55 + grain_noise(world * 1.015 / cell + (l + 1.0) * 5.1) * 0.6, t);
	gn = clamp(gn * 1.4, -1.0, 1.0) * dist_k * tile_face;   // value noise is soft: push it to a speckle
	float pit = smoothstep(0.2, 0.9, -gn.z);
	ALBEDO *= (1.0 + gn.z * grain_albedo) * (1.0 - pit * grain_cavity);

	vec4 fa = flecks(world, cell, glint_density, l);
	vec4 fb = flecks(world, cell * 2.0, glint_density, l + 1.0);
	fa.z *= 1.0 - t;
	fb.z *= t;
	vec4 f = fa.z >= fb.z ? fa : fb;
	float gw = f.z * open * dist_k;

	// the grain tilts the texture's own normal (tangent-space slopes add), a fleck replaces it
	vec3 tn = nm * 2.0 - 1.0;
	tn = normalize(vec3(tn.xy / max(tn.z, 0.2) + gn.xy * grain_strength, 1.0));
	NORMAL_MAP = mix(tn * 0.5 + 0.5, normalize(vec3(f.xy, 1.0)) * 0.5 + 0.5, gw);
	NORMAL_MAP_DEPTH = normal_depth;
	ROUGHNESS = mix(mix(rough, rail_roughness, rail), mix(glint_roughness.x, glint_roughness.y, f.w), gw);
	SPECULAR = mix(mix(specular, rail_specular, rail), glint_specular, gw);
	METALLIC = 0.0;
	AO = ao * (1.0 - pit * grain_cavity);
	AO_LIGHT_AFFECT = ao_light_affect;
	EMISSION = ALBEDO * ceiling_fill;
}
