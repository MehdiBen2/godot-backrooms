shader_type spatial;
// Procedural meadow: patchy greens, dry yellow on crests, dirt on slopes, road from vertex colour.
uniform vec3 grass_a : source_color = vec3(0.16, 0.28, 0.07);
uniform vec3 grass_b : source_color = vec3(0.36, 0.42, 0.13);
uniform vec3 dry_col : source_color = vec3(0.5, 0.45, 0.2);
uniform vec3 dirt_col : source_color = vec3(0.3, 0.22, 0.13);
uniform vec3 road_col : source_color = vec3(0.24, 0.22, 0.19);

varying vec3 wpos;
varying float road;
varying float upness;

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
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.05 + vec2(11.3, 5.9);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	road = COLOR.r;
	upness = NORMAL.y;
}

void fragment() {
	float blotch = fbm(wpos.xz * 0.045);
	float fine = fbm(wpos.xz * 1.7);
	float streak = vnoise(wpos.xz * vec2(9.0, 9.0));
	vec3 g = mix(grass_a, grass_b, smoothstep(0.25, 0.75, blotch));
	g = mix(g, dry_col, smoothstep(0.55, 0.85, fbm(wpos.xz * 0.02 + 7.0)) * 0.55);
	g *= 0.72 + 0.5 * fine;
	g *= 0.9 + 0.2 * streak;
	float slope = smoothstep(0.8, 0.62, upness) * 0.7;
	vec3 col = mix(g, dirt_col * (0.8 + 0.4 * fine), slope);
	float r = smoothstep(0.25, 0.75, road);
	col = mix(col, road_col * (0.8 + 0.4 * fine), r);
	ALBEDO = col;
	ROUGHNESS = mix(0.95, 0.85, r);
	SPECULAR = 0.15;
}
