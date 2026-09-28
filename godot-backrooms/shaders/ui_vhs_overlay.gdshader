shader_type canvas_item;
// Camcorder-viewfinder composite for the inventory panel: a real fisheye bulge (unlike the
// full-screen post.gdshader, this is deliberately NOT overscan-corrected by default — the point is
// a visibly round lens with the corners falling into shadow, like looking through a camcorder
// viewfinder), plus chromatic fringing, scanlines, film grain and a tear-glitch burst driven by
// `glitch` (0..1, set from GDScript on open and on random idle ticks).
// fit_corners: scale the bulge back so the corners land exactly on the corners — a CRT screen
// curve that never crops, for full-screen use (inventory.gd mirrors this in _through_lens()).
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

	vec4 tr = texture(TEXTURE, clamp(pr, 0.0, 1.0)) * inside(pr);
	vec4 tg = texture(TEXTURE, clamp(pg, 0.0, 1.0)) * inside(pg);
	vec4 tb = texture(TEXTURE, clamp(pb, 0.0, 1.0)) * inside(pb);
	vec3 col = vec3(tr.r, tg.g, tb.b);
	float alpha = max(tr.a, max(tg.a, tb.a));

	// scanlines at real pixel density (FRAGCOORD, not UV) so they read as lines, not a grey wash
	float sl = 0.5 + 0.5 * sin(FRAGCOORD.y * 1.05);
	col *= 1.0 - scan_amt * sl;

	// film grain: a fresh hash every frame
	float g = hash12(FRAGCOORD.xy + fract(TIME * 11.3) * 191.0);
	col += (g - 0.5) * grain_amt * 2.0;

	// vignette toward the lens edge, doubling as the fisheye's own falloff
	float vig = smoothstep(0.28, 0.85, dist_r);
	col = mix(col, vec3(0.0), clamp(vig * vignette_amt, 0.0, 1.0));

	// glitch burst: a handful of torn, offset scanlines flashing brighter
	if (glitch > 0.002) {
		float row = floor(uv.y * 70.0);
		float tick = floor(TIME * 42.0);
		float tear = step(0.9, hash12(vec2(row, tick)));
		col += vec3(0.85, 0.9, 0.95) * tear * glitch;
	}

	COLOR = vec4(clamp(col, 0.0, 1.0), alpha * fade);
}
