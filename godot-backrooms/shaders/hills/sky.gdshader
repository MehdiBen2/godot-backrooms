shader_type sky;
// Warm late-afternoon sky: gradient, sun haze, soft layered clouds.
uniform vec3 sun_dir = vec3(0.35, 0.3, -0.9);
uniform vec3 zenith_col : source_color = vec3(0.2, 0.4, 0.75);
uniform vec3 mid_col : source_color = vec3(0.55, 0.68, 0.85);
uniform vec3 horizon_col : source_color = vec3(1.0, 0.82, 0.55);
uniform vec3 sun_col : source_color = vec3(1.0, 0.85, 0.55);
uniform float cloud_cover = 0.66;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.7);
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 sd_v = normalize(sun_dir);
	float sd = max(dot(d, sd_v), 0.0);
	float up = clamp(d.y, 0.0, 1.0);

	vec3 col = mix(horizon_col, mid_col, smoothstep(0.0, 0.18, up));
	col = mix(col, zenith_col, smoothstep(0.1, 0.8, up));
	col += sun_col * (pow(sd, 6.0) * 0.28 + pow(sd, 48.0) * 0.5);

	if (d.y > 0.0) {
		vec2 uv = d.xz / (d.y + 0.2) * 0.9;
		float c = fbm(uv * 1.3);
		c = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.35, c);
		// light cloud from the sun side: compare density a step toward the sun
		float toward = fbm(uv * 1.3 + sd_v.xz * 0.12);
		float lit = clamp(0.55 + (fbm(uv * 1.3) - toward) * 5.0, 0.0, 1.0);
		vec3 dark = vec3(0.42, 0.45, 0.55);
		vec3 bright = mix(vec3(1.0, 0.95, 0.88), sun_col * 1.3, pow(sd, 3.0));
		vec3 ccol = mix(dark, bright, lit);
		c *= smoothstep(0.0, 0.14, d.y);
		col = mix(col, ccol, c * 0.97);
	}
	if (d.y < 0.0) {
		col = mix(horizon_col * 0.85, vec3(0.3, 0.27, 0.18), smoothstep(0.0, 0.4, -d.y));
	}
	// sun disc: HDR so glow blooms it
	col += sun_col * smoothstep(0.9992, 0.9998, sd) * 12.0;
	COLOR = col;
}
