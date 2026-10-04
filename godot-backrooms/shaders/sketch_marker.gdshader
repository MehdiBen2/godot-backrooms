shader_type spatial;
// Felt-tip marker on a wall, floor or ceiling (sketch_marks.gd draws the ribbon). The ribbon is a plain
// strip; everything that makes it look drawn by hand is done here:
//  - round ends on every stroke, dash and dot (a capsule cut out of the strip), with a ragged, bled edge
//  - ink pooled darker along the edges and where the pen came down, faint nib streaks along the stroke
//  - the surface's tooth: ink skips the tops of the grain (world space, so crossing lines share it), and
//    the grain bumps the normal so the torch rakes across it
//  - dried ink is a little glossier than painted plaster, so a light at a low angle picks it out
// Lit like everything else: it goes dark in the dark.
render_mode blend_mix, cull_disabled, depth_draw_opaque;

uniform float edge_soft = 0.18;      // share of the half width the edge fades over
uniform float ragged = 0.22;         // how far (share of the half width) the edge wanders
uniform float rim_dark = 0.3;        // how much darker the pooled ink along the edges is
uniform float streaks = 0.16;        // nib streaks along the stroke
uniform float tooth_scale = 520.0;   // grain of the surface (per metre)
uniform float tooth_skip = 0.28;     // how much ink the tops of the grain miss
uniform float tooth_bump = 0.35;     // how hard the grain tilts the normal
uniform float ink_rough = 0.55;
uniform float ink_specular = 0.4;

const float PAD = 1.4;

// The strip is PAD times wider than the ink and runs PAD half widths past both ends, room for the round
// caps and the ragged edge (sketch_marks.gd uses the same PAD).
// UV.x 0..1 across the strip, UV.y metres along it from its padded start
// UV2.x the ink's local width (m), UV2.y the strip's whole length (m)
// CUSTOM0: x style (0 solid, 1 dashed, 2 dotted), y the stroke's own seed, z the nominal width (m)
varying vec3 wpos;
varying vec3 wnorm;
varying vec3 wtan;
varying float style;
varying float stroke_seed;
varying float nominal_w;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
			mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
			mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	return vnoise(p) * 0.55 + vnoise(p * 2.03 + 7.1) * 0.3 + vnoise(p * 4.1 + 3.7) * 0.15;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	wtan = normalize((MODEL_MATRIX * vec4(TANGENT.xyz, 0.0)).xyz);
	style = CUSTOM0.x;
	stroke_seed = CUSTOM0.y;
	nominal_w = CUSTOM0.z;
}

// The centre line of the piece of ink under `v` (the whole stroke, or its dash / dot), from .x to .y metres
// along the strip; the ink is everything within a half width of it. `ends` is where the stroke's own first
// and last points are. Dashes and dots sit in the middle of their stretch, so their caps fit inside it.
vec2 piece(float v, vec2 ends, float w, float kind) {
	float period = 0.0;
	float core = 0.0;
	if (kind > 1.5) {
		period = max(0.06, w * 2.6);
	} else if (kind > 0.5) {
		period = 0.16;
		core = max(0.0, 0.10 - w);
	} else {
		return ends;
	}
	float start = ends.x + floor((v - ends.x) / period) * period;
	float a = start + (period - core) * 0.5;
	return clamp(vec2(a, a + core), ends.x, ends.y);
}

void fragment() {
	float w = max(UV2.x, 0.001);
	float r = w * 0.5;
	float rp = nominal_w * 0.5 * PAD;
	float across = (UV.x - 0.5) * w * PAD;
	float v = UV.y;
	// fine detail fades out where a pixel covers several grains, so it doesn't shimmer down a corridor
	float fine = clamp(1.5 - length(fwidth(wpos)) * tooth_scale * 0.6, 0.0, 1.0);

	// the capsule this bit of ink belongs to, and how far inside it we are (0 centre line, 1 edge)
	vec2 pc = piece(v, vec2(rp, max(rp, UV2.y - rp)), nominal_w, style);
	float d = length(vec2(v - clamp(v, pc.x, pc.y), across));
	// the edge wanders and bleeds into the surface
	float wander = (fbm(wpos * 140.0 + stroke_seed) - 0.5) * 2.0 + (vnoise(wpos * 900.0) - 0.5) * 0.6 * fine;
	float e = (d + wander * ragged * r) / r;
	float mask = 1.0 - smoothstep(1.0 - edge_soft, 1.0, e);
	if (mask <= 0.002) {
		discard;
	}

	// ink density: streaks along the stroke from the nib, a heavier blot where the pen touched down,
	// slow variation in how wet the pen was
	float streak = vnoise(vec3(UV.x * 9.0 + stroke_seed, v * 2.5, stroke_seed * 3.1));
	float density = 1.0 - streaks * smoothstep(0.35, 0.85, streak);
	density *= 0.9 + 0.1 * fbm(vec3(v * 3.0, stroke_seed, 0.0));
	float blot = exp(-max(0.0, v - rp) / (r * 1.6));
	density = min(1.0, density + 0.25 * blot);

	// the surface's tooth: the ink misses the tops of the grain, more where it is thin
	float tooth = fbm(wpos * tooth_scale);
	float skip = smoothstep(0.55, 0.85, tooth) * tooth_skip * (1.15 - density) * fine;
	float alpha = mask * clamp(density - skip, 0.0, 1.0);

	// pooled ink along the edge: darker (and a touch more saturated) than the middle
	vec3 ink = COLOR.rgb;
	float rim = smoothstep(0.45, 0.95, e);
	ink = mix(ink, ink * ink * 0.9, rim * rim_dark);
	ink *= mix(1.0, 0.88, blot);
	ALBEDO = ink;
	ALPHA = alpha * COLOR.a;

	// the grain under the ink tilts the normal, in tangent space (UV.x across, UV.y along)
	float h = 0.002;
	vec3 side = normalize(cross(wnorm, wtan));
	float tx = fbm((wpos + side * h) * tooth_scale) - tooth;
	float ty = fbm((wpos + wtan * h) * tooth_scale) - tooth;
	float bump = tooth_bump * 6.0 * fine;
	NORMAL_MAP = normalize(vec3(-tx * bump, -ty * bump, 1.0)) * 0.5 + 0.5;
	ROUGHNESS = mix(ink_rough, 0.85, skip * 2.0 + rim * 0.2);
	SPECULAR = ink_specular;
	METALLIC = 0.0;
}
