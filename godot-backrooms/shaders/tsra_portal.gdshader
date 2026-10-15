// The threshold standing open in the T.S.R.A. gate (scripts/World/props/tsra_portal_gate.gd): the same fluid
// amber field as the drawn wall portals (portal_marks.gd), on a quad filling the split between the pylons.
// `open` 0 -> 1 is the opening: a hot hairline down the middle that tears wide into the field, the edge burning.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled;

uniform vec2 portal_size = vec2(2.6, 4.3);
uniform float open : hint_range(0.0, 1.0) = 0.0;
uniform float charge : hint_range(0.0, 1.0) = 0.0;   // before it opens: the hairline flickers in, faster as it charges
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

	// ---- the tear: half its width at each height, in UV (0.5 = the whole split), soft at the top and bottom
	float v = UV.y;
	float profile = pow(clamp(sin(3.14159 * v), 0.0, 1.0), 0.35);
	float wob = fbm(vec2(v * 6.0, t * 3.0)) * 0.025 * open;
	float half_w = (0.004 + 0.5 * smoothstep(0.0, 1.0, open)) * profile + wob;
	float dx = abs(UV.x - 0.5);
	float inside = smoothstep(half_w + 0.006, half_w - 0.006, dx);
	float rim = smoothstep(0.035, 0.0, abs(dx - half_w)) * profile;

	// before it opens the hairline only flickers, faster as the charge builds
	float flick = step(0.5, fract(TIME * (2.0 + 14.0 * charge) + sin(TIME * 7.1) * 0.3));
	float pre = (open > 0.0) ? 1.0 : charge * (0.45 + 0.55 * flick);

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

	// a narrow tear is all hot light; the field shows through as it widens
	col = mix(col_core * 3.0, col, smoothstep(0.02, 0.18, half_w));
	col += col_core * rim * (2.5 + 2.0 * (1.0 - open));

	ALBEDO = col;
	ALPHA = clamp(max(inside, rim) * pre, 0.0, 1.0);
}
