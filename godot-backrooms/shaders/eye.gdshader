shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;
// One eye on a wall or the ceiling (scripts/world/eyes.gd). Unshaded so it still reads in the dark,
// but kept dim: a stained, grimy filter is laid over it so it looks painted into the wallpaper
// rather than glowing, and it fades out with distance. Everything animated here is per eye through
// instance uniforms, so all the eyes share one material.
uniform sampler2D eye_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float halo_size = 1.5;            // the quad is this much bigger than the eye itself
uniform float glint_amt = 0.28;          // eyeshine: HDR so the far pair gleams through the environment bloom
uniform float brightness = 0.55;          // overall level of the picture
uniform vec3 filter_tint : source_color = vec3(0.80, 0.74, 0.58);   // the dirty wallpaper wash
instance uniform float alpha = 0.0;       // overall visibility
instance uniform float lid = 0.0;         // 0 shut .. 1 wide open (the eye seeps in, then opens)
instance uniform float seed = 0.0;
instance uniform vec2 look = vec2(0.0);   // gaze in the surface's own axes, -1..1
instance uniform float squint = 0.0;      // the torch is in its eye: pupil pinches, lid narrows
instance uniform float madness = 0.0;     // 0..1: bloodshot, wider halo, twitchier

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	return fract(p * (p + p));
}
float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x), mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}

void fragment() {
	float t = TIME + seed * 91.0;
	vec2 e = (UV - 0.5) * halo_size;             // eye space: the eye fills -0.5..0.5

	// these eyes never blink: it is the player who has to
	float blink = 0.0;
	// opening: a slow slit, a small over-wide flick at the end, then it sags half-lidded and drifts
	float open_amt = lid * (1.0 + 0.10 * sin(clamp(lid, 0.0, 1.0) * 3.14159) * step(0.5, lid));
	float droop = 0.84 + 0.16 * sin(t * 0.35 + seed * 30.0) - 0.10 * madness * sin(t * 0.9 + seed * 12.0);
	float twitch = 1.0;
	float l = clamp(open_amt * droop * (1.0 - blink) * (1.0 - squint * 0.6) * twitch, 0.0, 1.1);

	// squash the picture toward the horizontal midline as the lid closes
	vec2 p = vec2(e.x, e.y / max(l, 0.03));

	// the pupil follows the script's gaze, shakes a little, and pinches in the torchlight
	float inner = 1.0 - smoothstep(0.16, 0.40, length(p * vec2(1.0, 1.4)));
	vec2 tremor = vec2(sin(t * 17.0 + seed * 9.0), sin(t * 13.0 + seed * 5.0)) * (0.004 + 0.010 * madness);
	vec2 g = (look + tremor * 6.0) * vec2(0.075, -0.06);
	float dil = 1.0 + squint * 0.55 - 0.10 * sin(t * 1.9 + seed * 7.0) * (0.4 + madness);
	vec2 sp = p * mix(1.0, dil, inner) - g * inner;
	vec2 uv = sp + 0.5;

	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	vec4 tx = texture(eye_tex, clamp(uv, 0.0, 1.0));
	// it seeps in: a noisy stain forms first, the eye shows through as the lid opens
	float n = vnoise(e * 8.0 + seed * 30.0);
	float reveal = smoothstep(0.0, 0.3, lid * 1.7 - n * 0.65);
	float eye_a = tx.a * inside * smoothstep(0.0, 0.07, l) * reveal;

	float luma = dot(tx.rgb, vec3(0.299, 0.587, 0.114));
	float sclera = smoothstep(0.12, 0.5, luma) * (1.0 - inner);
	vec3 col = tx.rgb;
	// bloodshot, dull: sickly at the edges, veins flicker in with the madness
	col = mix(col, col * vec3(1.25, 0.6, 0.5), madness * 0.7 * sclera);
	float vein = smoothstep(0.62, 0.9, sin(atan(p.y, p.x) * 23.0 + length(p) * 30.0 + seed * 20.0) * 0.5 + 0.5);
	col = mix(col, vec3(0.32, 0.03, 0.02), vein * sclera * madness * 0.45);
	// the filter: dirty wash, grime blotches, darker lid rim and a soft dark edge
	float grime = 0.55 + 0.45 * vnoise(e * 6.0 + seed * 20.0 + TIME * 0.02);
	float rim = smoothstep(0.30, 0.5, abs(p.y)) * 0.5 + smoothstep(0.34, 0.5, abs(p.x)) * 0.5;
	col *= filter_tint * grime * (1.0 - 0.5 * rim) * brightness;
	// eyeshine: glint_amt above 1 is HDR, so it blooms into a faint gleam at a distance
	float glint = smoothstep(0.62, 0.92, luma) * inner;
	col += glint * glint_amt * (1.0 + 0.3 * sin(t * 2.3 + seed * 6.0)) * filter_tint;

	// the dark stain the eye sits in: it looks like it is watching from a rot in the wall
	float r = length(e * vec2(1.0, 1.5));
	float stain_n = 0.75 + 0.5 * vnoise(e * 5.0 + seed * 17.0);
	float halo = (1.0 - smoothstep(0.26, 0.78, r * (2.0 - stain_n))) * (0.3 + 0.3 * madness) * (0.15 + 0.85 * smoothstep(0.0, 0.5, lid)) * (0.5 + 0.5 * l);
	vec3 halo_col = mix(vec3(0.0), vec3(0.06, 0.0, 0.0), madness);

	float a = eye_a + halo * (1.0 - eye_a);
	float dist_fade = 1.0 - smoothstep(46.0, 70.0, length(VERTEX));
	ALBEDO = mix(halo_col, col, eye_a / max(a, 0.0001));
	ALPHA = clamp(a * alpha * dist_fade, 0.0, 1.0);
}
