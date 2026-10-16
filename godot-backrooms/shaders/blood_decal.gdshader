// The blood splat decal laid on a surface (death_fx.gd). See the comment above DECAL_SHADER there.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;
uniform float grow = 1.0;
uniform float wet = 1.0;
uniform float seed = 0.0;
uniform vec3 splat_normal = vec3(0.0, 1.0, 0.0);
uniform vec2 impact_dir = vec2(0.0);   // in the card's plane; its length is how hard it hit (0 = a pool)
uniform vec2 link_to = vec2(0.0);      // a second pool centre (bp-space, 0,0 = none): bridged into one puddle
uniform float extent = 1.2;            // card size / pool size (see fragment)
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
float hs(float n) { return fract(sin(n * 12.9898 + seed * 78.233) * 43758.5453); }
float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
// compact metaball kernel: 1 at the centre, 0 at radius r, smooth everywhere
float ball(vec2 p, vec2 c, float r) {
	vec2 q = p - c;
	float x = clamp(1.0 - dot(q, q) / (r * r), 0.0, 1.0);
	return x * x * x;
}
// the same kernel around a segment whose radius tapers from ra to rb: a finger of thrown blood
float seg(vec2 p, vec2 a, vec2 b, float ra, float rb) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
	float r = mix(ra, rb, h);
	vec2 q = pa - ba * h;
	float x = clamp(1.0 - dot(q, q) / (r * r), 0.0, 1.0);
	return x * x * x;
}
float vno(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm2(vec2 p) {
	float a = 0.5, s = 0.0;
	for (int i = 0; i < 3; i++) { s += a * vno(p); p = p * 2.17 + 13.0; a *= 0.5; }
	return s;
}
// the mottling, sampled at WORLD position with NO per-decal offset: every splat on the same surface reads the
// same field, so where two overlap the pattern keeps running instead of jump-cutting to a different noise at
// the boundary (which is what made overlapping splats read as two stickers stacked on top of each other).
// Splats land on floors and upright walls (death_blood.gd): one planar read along the surface does what the
// triplanar blend did at a third of the cost.
float mottle(vec3 p) {
	vec3 a = abs(splat_normal);
	if (a.y > 0.5) { return fbm2(p.xz); }
	return a.x > a.z ? fbm2(p.zy) : fbm2(p.xy);
}
float field(vec2 p) {
	float hit = clamp(length(impact_dir), 0.0, 1.0);
	vec2 dir = hit > 0.001 ? impact_dir / length(impact_dir) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	// organic edge: a two-octave domain warp, so no outline is ever a clean circle
	p += (vec2(vno(p * 3.0 + seed * 3.1), vno(p * 3.0 - seed * 1.7)) - 0.5) * 0.14;
	p += (vec2(vno(p * 9.0 + seed * 5.3), vno(p * 9.0 - seed * 2.9)) - 0.5) * 0.04;
	// on an upright wall blood does not pool: it clings, sags and runs. The card's +y is up the wall here, so the
	// body is stretched downward (below the hit point) and runs of blood trickle down from it (added below)
	bool wall = abs(splat_normal.y) < 0.5;
	vec2 wp = p;
	if (wall && p.y < 0.0) { p.y *= 0.5; }
	// local frame: x runs along the direction the blood was travelling
	vec2 lp = vec2(dot(p, dir), dot(p, side));
	vec2 bp = vec2(lp.x / (1.0 + 0.55 * hit), lp.y) / max(grow, 0.02);
	float f = 0.0;
	// the body: lobes clustered about the centre, merging into one pool
	for (int i = 0; i < 8; i++) {
		float fi = float(i);
		float a = hs(fi * 3.7) * 6.2832;
		float d = sqrt(hs(fi * 5.3 + 1.0)) * 0.42;
		f += ball(bp, vec2(cos(a), sin(a)) * d, 0.24 + 0.18 * hs(fi * 7.1 + 2.0));
	}
	// a second pool (e.g. the victim's, beside the kill) gets its own lobe cluster plus a stream
	// bridging the two centres, so however far apart they are this is one continuous field - not
	// two separately-shaded decals whose independent rims would show as a seam where they touch
	if (dot(link_to, link_to) > 0.0001) {
		for (int i = 0; i < 8; i++) {
			float fi = float(i);
			float a = hs(fi * 3.7 + 40.0) * 6.2832;
			float d = sqrt(hs(fi * 5.3 + 41.0)) * 0.42;
			f += ball(bp - link_to, vec2(cos(a), sin(a)) * d, 0.24 + 0.18 * hs(fi * 7.1 + 42.0));
		}
		f += seg(bp, vec2(0.0), link_to, 0.34, 0.3);
	}
	// runs: thin streaks that creep down the wall from the splat, each ending in a fat bead, slowly lengthening
	if (wall) {
		float creep = smoothstep(0.08, 1.0, grow);
		for (int i = 0; i < 5; i++) {
			float fi = float(i);
			float x = (hs(fi * 3.1 + 20.0) - 0.5) * 0.8;
			float len = (0.2 + 0.45 * hs(fi * 5.7 + 21.0)) * creep;
			vec2 a = vec2(x, -0.08);
			vec2 b = vec2(x + (hs(fi * 2.9 + 22.0) - 0.5) * 0.08, -0.08 - len);
			f += 1.1 * seg(wp, a, b, 0.11, 0.07);
			f += ball(wp, b, 0.1 + 0.03 * hs(fi * 9.1 + 23.0));
		}
	}
	// fingers and droplets land on impact, before the pool has spread
	float appear = smoothstep(0.0, 0.25, grow);
	for (int i = 0; i < 5; i++) {
		float fi = float(i);
		float a = (hs(fi * 2.3 + 9.0) - 0.5) * 1.7;
		vec2 fd = vec2(cos(a), sin(a));
		float len = (0.3 + 0.45 * hs(fi * 4.1 + 3.0)) * appear;
		f += hit * 0.9 * seg(lp, fd * 0.2, fd * (0.2 + len), 0.11, 0.03);
	}
	for (int i = 0; i < 9; i++) {
		float fi = float(i);
		if (hs(fi * 11.0 + 7.0) > mix(0.3, 1.0, hit)) { continue; }
		float a = (hs(fi * 6.7 + 4.0) - 0.5) * mix(6.2832, 2.2, hit);
		float d = 0.6 + 0.32 * hs(fi * 1.9 + 5.0);
		f += appear * ball(lp, vec2(cos(a), sin(a)) * d, 0.04 + 0.05 * hs(fi * 8.3 + 6.0));
	}
	return f;
}
void fragment() {
	vec2 pu = (UV - 0.5) * 2.0;
	// the card is `extent` times bigger than the pool it holds, so no lobe, finger or linked pool ever reaches the
	// quad's edge (where the field used to be sliced off in a straight line); a last soft fade covers the warp
	vec2 p = pu * extent;
	// the card is far bigger than the pool it holds (a linked pool's card spans both ends, ~9x the area of the
	// old one), and the field costs ~35 lobes a pixel: bail out cheaply anywhere past the farthest lobe, finger
	// or droplet (~1.1 from a centre, plus the warp) of either centre or the stream between them. Without this,
	// the dozens of overlapping cards under the death camera ran long enough for the driver to reset the GPU.
	vec2 ab = link_to * 1.1;
	float ab2 = dot(ab, ab);
	float seg_t = ab2 > 1e-4 ? clamp(dot(p, ab) / ab2, 0.0, 1.0) : 0.0;
	vec2 off = p - ab * seg_t;
	if (dot(off, off) > 1.96) { discard; }
	const float TH = 0.3;
	float f = field(p);
	f *= 1.0 - smoothstep(0.82, 1.0, max(abs(pu.x), abs(pu.y)));
	float aa = max(fwidth(f), 1e-4);
	float m = smoothstep(TH - aa, TH + aa, f);
	if (m < 0.01) { discard; }
	float thick = clamp((f - TH) / 0.9, 0.0, 1.0);
	float lip = 1.0 - smoothstep(0.0, 0.35, thick);
	// the rim of a puddle bulges up (surface tension): tilt the normal there so it catches the light.
	// Kept subtle - each splat computes this from only its own shape, so a strong bump here is what
	// let one splat's rim show up as a ring drawn over a neighbour it happens to overlap.
	// The field's slope comes from the screen-space derivatives of f and p (the chain rule), not from two more
	// evaluations of field(): those tripled the cost of every pixel of every splat, and the bite lays dozens of
	// them, overlapping, right under a camera looking down at them (a 750 ms frame on an RX 5700 XT).
	vec2 px = dFdx(p);
	vec2 py = dFdy(p);
	float det = px.x * py.y - px.y * py.x;
	vec2 gr = abs(det) > 1e-9 ? vec2(dFdx(f) * py.y - dFdy(f) * px.y, dFdy(f) * px.x - dFdx(f) * py.x) / det : vec2(0.0);
	// on a wall the rim bump and the shine are what made a splat read as a glossy bubble stuck on in front of it
	// rather than a stain in it: flatten them there
	bool on_wall = abs(splat_normal.y) < 0.5;
	NORMAL_MAP = normalize(vec3(clamp(-gr * 0.018 * lip * (on_wall ? 0.15 : 1.0), vec2(-0.35), vec2(0.35)), 1.0)) * 0.5 + 0.5;
	float n = mottle(wpos * 3.0);   // world-aligned mottling: clotting, shared by overlapping splats
	vec3 thin_col = vec3(0.15, 0.006, 0.007);
	vec3 thick_col = vec3(0.1, 0.003, 0.005);
	vec3 dried = vec3(0.04, 0.002, 0.003);
	vec3 col = mix(thin_col, thick_col, smoothstep(0.0, 0.5, thick));
	// dries at a flat rate across the whole body (not faster at the rim): that per-splat rim was
	// another ring that showed through wherever splats overlapped
	float dry = 1.0 - wet;
	col = mix(col, dried, dry);
	ALBEDO = col * (0.85 + 0.3 * n);
	// fully opaque everywhere but the true silhouette edge (m already is that edge, antialiased by
	// fwidth above): a partial alpha across the whole body was what let one splat's outline show
	// through as a ghost ring wherever it overlapped another splat's opaque centre
	ALPHA = m;
	// wet blood is glossy; dried blood is matte (any leftover sheen reads as grey plastic)
	ROUGHNESS = mix(0.9, mix(0.25, 0.08, thick), wet);
	ROUGHNESS = on_wall ? max(ROUGHNESS, 0.6) : ROUGHNESS;
	SPECULAR = mix(0.05, 0.6, wet) * (on_wall ? 0.35 : 1.0);
	METALLIC = 0.0;
}
