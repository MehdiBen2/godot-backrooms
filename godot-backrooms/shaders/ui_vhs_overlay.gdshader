shader_type canvas_item;
// Premultiplied: TEXTURE is a transparent SubViewport, whose colour is already multiplied by its
// alpha (it composites over transparent black), and the bloom is added on top (lighting the view
// around the panels, not just the panels).
render_mode blend_premul_alpha;
// Camcorder-viewfinder composite for the inventory panel: a real fisheye bulge (unlike the
// full-screen post.gdshader, this is deliberately NOT overscan-corrected by default — the point is
// a visibly round lens with the corners falling into shadow, like looking through a camcorder
// viewfinder), plus chromatic fringing, scanlines, film grain and a VHS tracking glitch driven by
// `glitch` (0..1, set from GDScript on open and on random idle ticks). The glitch moves the picture
// rather than painting over it, the way a worn tape does: bands of rows slide sideways (mixed
// thicknesses, ragged inside), colour splits along the tear, and a tracking bar rolls down the
// picture with sparse horizontal dropout streaks in it.
// fit_corners: scale the bulge back so the corners land exactly on the corners — a CRT screen
// curve that never crops, for full-screen use (inventory.gd mirrors this in _through_lens()).
// Bloom: bloom_tex is the terminal's bright parts blurred at half resolution (ui_bloom.gdshader,
// inventory.gd _bloom_pass), added back through the same warp, pulled toward the amber phosphor
// hue (bloom_tint) and held back on pixels that are already bright (bloom_damp), so the lines and
// bars glow without washing their own segments out.
// TEXTURE is the SubViewport this panel's own controls are rendered into (see inventory.gd).
uniform float aspect = 1.5;
uniform float distortion : hint_range(0.0, 1.0) = 0.5;
uniform bool fit_corners = false;
uniform float chroma_amt : hint_range(0.0, 0.05) = 0.014;
uniform float scan_amt : hint_range(0.0, 1.0) = 0.22;
uniform float grain_amt : hint_range(0.0, 1.0) = 0.09;
uniform float vignette_amt : hint_range(0.0, 1.0) = 0.5;
uniform float glitch : hint_range(0.0, 1.0) = 0.0;
// overall opacity for the power-on flicker: writing COLOR drops the node's modulate, so the
// fade has to come in as a uniform
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D bloom_tex : hint_default_black, filter_linear, repeat_disable;
uniform float bloom_amt : hint_range(0.0, 4.0) = 0.0;
uniform float bloom_tint : hint_range(0.0, 1.0) = 0.5;
uniform float bloom_damp : hint_range(0.0, 1.0) = 0.6;

const vec3 PHOSPHOR = vec3(1.0, 0.7, 0.234);   // the terminal's amber, brightest channel at 1

// the node's modulate (its own and its parents'): writing COLOR in fragment() would drop it, so it is
// caught here and applied at the end — the HUD fades these under the pause menu and the terminal
varying vec4 v_modulate;

void vertex() {
	v_modulate = COLOR;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// 1 inside the panel, 0 outside (TEXTURE itself can only be sampled in fragment(): neither using it in a
// helper nor passing it into one compiles)
float inside(vec2 uv) {
	return (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) ? 0.0 : 1.0;
}

void fragment() {
	vec2 uv = UV;

	// VHS tracking glitch: row offsets first, so the tear moves the picture itself
	float jit = 0.0;
	float bar = 0.0;
	float tick = floor(TIME * 24.0);
	if (glitch > 0.002) {
		float hb = hash12(vec2(floor(uv.y * 18.0), tick));
		float hs = hash12(vec2(floor(uv.y * 90.0), tick + 17.0));
		float band = step(0.82, hb) * (0.4 + 0.6 * hs);
		float thin = step(0.95, hs);
		jit = ((hb - 0.5) * 0.07 * band + (hs - 0.5) * 0.025 * thin) * glitch;
		bar = (1.0 - smoothstep(0.0, 0.03, abs(uv.y - fract(TIME * 0.35)))) * glitch;
		jit += (hash12(vec2(floor(uv.y * 360.0), tick + 5.0)) - 0.5) * 0.02 * bar;
		uv.x += jit;
	}

	vec2 p = uv - 0.5;
	p.x *= aspect;
	float r2 = dot(p, p);

	// barrel bulge, no overscan correction: corners sample past the edge and fall to transparent,
	// reading as a round lens rather than a rectangular warped card
	vec2 pd = p * (1.0 + distortion * r2);
	if (fit_corners) {
		pd /= 1.0 + distortion * (0.25 * aspect * aspect + 0.25);
	}

	float dist_r = sqrt(r2);
	vec2 ca_dir = (dist_r > 0.0001) ? (p / dist_r) : vec2(0.0);
	float ca_disp = dist_r * dist_r * chroma_amt;

	vec2 pr = pd + ca_dir * ca_disp; pr.x /= aspect; pr += 0.5;
	vec2 pg = pd;                    pg.x /= aspect; pg += 0.5;
	vec2 pb = pd - ca_dir * ca_disp; pb.x /= aspect; pb += 0.5;
	// colour splits along a tear, the way a mistracked head smears chroma
	float split = abs(jit) * 0.5;
	pr.x += split;
	pb.x -= split;

	vec4 tr = texture(TEXTURE, clamp(pr, 0.0, 1.0)) * inside(pr);
	vec4 tg = texture(TEXTURE, clamp(pg, 0.0, 1.0)) * inside(pg);
	vec4 tb = texture(TEXTURE, clamp(pb, 0.0, 1.0)) * inside(pb);
	vec3 col = vec3(tr.r, tg.g, tb.b);
	float alpha = max(tr.a, max(tg.a, tb.a));

	vec3 glow = texture(bloom_tex, clamp(pg, 0.0, 1.0)).rgb * inside(pg);
	float glow_l = max(glow.r, max(glow.g, glow.b));
	glow = mix(glow, glow_l * PHOSPHOR, bloom_tint);
	float own = smoothstep(0.3, 0.75, max(col.r, max(col.g, col.b)));
	col += glow * bloom_amt * (1.0 - bloom_damp * own);
	// where anything is drawn at all, the panel or its glow: grain and tears stay off the bare view
	float cover = max(alpha, clamp(glow_l * bloom_amt, 0.0, 1.0));

	// scanlines at real pixel density (FRAGCOORD, not UV) so they read as lines, not a grey wash
	float sl = 0.5 + 0.5 * sin(FRAGCOORD.y * 1.05);
	col *= 1.0 - scan_amt * sl;

	// film grain: a fresh hash every frame, stretched a little sideways like tape noise, and riding on
	// the picture's brightness so the dark fill doesn't turn into a grey wash
	float g = hash12(vec2(floor(FRAGCOORD.x / 2.0), FRAGCOORD.y) + fract(TIME * 11.3) * 191.0);
	float lum = max(col.r, max(col.g, col.b));
	col += (g - 0.5) * grain_amt * 2.0 * cover * (0.3 + 0.7 * lum);

	// vignette toward the lens edge, doubling as the fisheye's own falloff
	float vig = smoothstep(0.28, 0.85, dist_r);
	col = mix(col, vec3(0.0), clamp(vig * vignette_amt, 0.0, 1.0));

	// dropout in the tracking bar: short broken streaks, not a solid stripe
	if (bar > 0.001) {
		float n = hash12(vec2(floor(FRAGCOORD.x / 7.0), floor(FRAGCOORD.y / 2.0)) + tick * 3.1);
		col += vec3(0.9) * step(0.93, n) * bar * 0.45 * cover;
	}

	COLOR = vec4(clamp(col, 0.0, 1.0), alpha) * fade * v_modulate.a;
}
