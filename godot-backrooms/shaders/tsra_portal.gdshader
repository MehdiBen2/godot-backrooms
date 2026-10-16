// The threshold standing open in the T.S.R.A. gate (scripts/World/props/tsra_portal_gate.gd): the same fluid
// amber field as the drawn wall portals (portal_marks.gd), on a quad filling the split between the pylons.
// `open` 0 -> 1 is the opening, after the original game's yellow gate: a hot hairline flickers in while it charges, then
// the field burns into being from the middle outward through TilingNoise05, a white-yellow HDR edge (it blooms) eating
// the dark. At open = 1 the whole field stands complete.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled;

uniform vec2 portal_size = vec2(2.6, 4.3);
uniform float open : hint_range(0.0, 1.0) = 0.0;
uniform float charge : hint_range(0.0, 1.0) = 0.0;   // before it opens: the hairline flickers in, faster as it charges
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float edge_width = 0.32;                     // the burning band, in reveal units
uniform float edge_energy = 1.8;                     // HDR: well past the glow threshold so it blooms
uniform vec3 col_edge : source_color = vec3(1.0, 0.78, 0.18);
uniform float time_scale = 0.22;
uniform vec3 col_core : source_color = vec3(1.2, 1.15, 0.95);
uniform vec3 col_radiant : source_color = vec3(1.0, 0.88, 0.32);
uniform vec3 col_amber : source_color = vec3(0.82, 0.62, 0.12);
uniform vec3 col_void : source_color = vec3(0.08, 0.05, 0.01);

vec2 hash(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float noise(vec2 p) {
	const float K1 = 0.366025404;
	const float K2 = 0.211324865;
	vec2 i = floor(p + (p.x + p.y) * K1);
	vec2 a = p - i + (i.x + i.y) * K2;
	vec2 o = (a.x > a.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
	vec2 b = a - o + K2;
	vec2 c = a - 1.0 + 2.0 * K2;
	vec3 h = max(0.5 - vec3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
	vec3 n = h * h * h * h * vec3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));
	return dot(n, vec3(70.0));
}

float fbm(vec2 p) {
	float f = 0.0;
	float w = 0.5;
	for (int i = 0; i < 4; i++) {
		f += w * noise(p);
		p *= 2.02;
		w *= 0.5;
	}
	return f;
}

void fragment() {
	vec2 uv = (UV - 0.5) * portal_size;
	float t = TIME * time_scale;

	// ---- the hairline: only while it charges (it stays, hidden, inside the opening)
	float v = UV.y;
	float profile = pow(clamp(sin(3.14159 * v), 0.0, 1.0), 0.35);
	float half_w = 0.004 * profile;
	float dx = abs(UV.x - 0.5);
	float inside = smoothstep(half_w + 0.006, half_w - 0.006, dx);
	float rim = smoothstep(0.035, 0.0, abs(dx - half_w)) * profile;
	float flick = step(0.5, fract(TIME * (2.0 + 14.0 * charge) + sin(TIME * 7.1) * 0.3));
	float pre = (open > 0.0) ? 1.0 : charge * (0.45 + 0.55 * flick);

	// ---- the burn: a pixel appears once the front p passes its threshold (centre and bright noise first)
	float n = texture(noise_tex, UV * vec2(1.0, portal_size.y / portal_size.x) * 1.5 + vec2(t * 0.05, 0.0)).r;
	float dist = length(vec2(UV.x - 0.5, (UV.y - 0.5) * 0.7));
	float thresh = dist * 0.7 + (1.0 - n) * 0.85;
	float p = smoothstep(0.0, 1.0, open) * 1.6 - 0.2;
	float e = p - thresh;                             // > 0: burnt through
	float burnt = smoothstep(0.0, 0.02, e);
	float edge = (1.0 - smoothstep(0.0, edge_width, e)) * burnt;

	// ---- the field (portal_marks.gd), with a parallax depth
	vec2 view_offset = VIEW.xy * 0.45;
	vec2 uv_front = uv * 1.2 + view_offset * 0.15;
	vec2 uv_deep = uv * 1.2 + view_offset * 0.65;
	vec2 q = vec2(fbm(uv_deep * 1.4 + vec2(t * 0.3, -t * 0.2)), fbm(uv_deep * 1.4 + vec2(-t * 0.2, t * 0.25)));
	vec2 r = vec2(fbm(uv_deep * 1.8 + 2.8 * q + vec2(t * 0.35, t * 0.1)), fbm(uv_deep * 1.8 + 2.8 * q + vec2(-t * 0.2, -t * 0.25)));
	float f = fbm(uv_deep * 1.6 + 3.2 * r) * 0.5 + 0.5;
	f = mix(f, fbm(uv_front * 8.0 + vec2(t * 0.8, -t * 0.6)) * 0.5 + 0.5, 0.08);
	vec3 col = col_void;
	col = mix(col, col_amber, smoothstep(0.20, 0.42, f));
	col = mix(col, col_radiant, smoothstep(0.42, 0.68, f));
	col = mix(col, col_core, smoothstep(0.68, 0.92, f));
	float pockets = fbm(uv_deep * 2.2 + vec2(-t * 0.35, t * 0.2)) * 0.5 + 0.5;
	float dark_mask = clamp(smoothstep(0.40, 0.18, f) + smoothstep(0.35, 0.12, pockets) * 0.6, 0.0, 1.0);
	col = mix(col, col_void * 0.25, dark_mask * 0.92);
	col *= mix(0.35, 2.0, smoothstep(0.28, 0.65, f)) * (1.0 + sin(t * 4.0) * 0.04);
	if (f > 0.65) {
		col += vec3(1.4, 1.35, 1.1) * smoothstep(0.65, 0.95, f) * 2.4;
	}

	vec3 hair = col_core * 3.0 + col_core * rim * 4.5;
	vec3 field = col + col_edge * edge * edge_energy;
	field += col_core * pow(edge, 4.0) * edge_energy * 0.8;     // the hottest line goes white

	vec3 outc = mix(hair, field, burnt);
	ALBEDO = outc;
	ALPHA = clamp(max(max(inside, rim) * pre, burnt), 0.0, 1.0);
}
