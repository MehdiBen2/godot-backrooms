// The ripples of light a water surface throws (props/water_body.gd): thin bright lines that wander and swell,
// where the light bent by the ripples gathers. Drawn as the borders of drifting cells: two layers of them at
// different sizes and speeds, brightest where their lines cross. `p` in metres along the lit surface, `t` in
// seconds. About 0 .. 1.4. Used by water.gdshader (on what lies under the water) and water_caustics.gdshader
// (on the walls and ceiling over it).

vec2 caustic_hash(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

// 0 on the border between two cells, growing towards a cell's middle
float caustic_edge(vec2 p, float t) {
	vec2 g = floor(p);
	vec2 f = fract(p);
	float d1 = 8.0;
	float d2 = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(float(x), float(y));
			vec2 h = caustic_hash(g + o);
			vec2 r = o + 0.5 + 0.42 * sin(t * (0.6 + 0.5 * h) + 6.2831 * h) - f;
			float d = dot(r, r);
			if (d < d1) {
				d2 = d1;
				d1 = d;
			} else if (d < d2) {
				d2 = d;
			}
		}
	}
	return sqrt(d2) - sqrt(d1);
}

float caustic_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = caustic_hash(i).x;
	float b = caustic_hash(i + vec2(1.0, 0.0)).x;
	float c = caustic_hash(i + vec2(0.0, 1.0)).x;
	float d = caustic_hash(i + vec2(1.0, 1.0)).x;
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float caustics(vec2 p, float t) {
	// a slow, soft warp: the cells wander, stretch and pinch instead of sitting in a grid
	vec2 w = vec2(caustic_noise(p * 0.35 + t * 0.07), caustic_noise(p * 0.35 + 9.1 - t * 0.06)) - 0.5;
	p += w * 1.7;
	float a = caustic_edge(p * 1.35, t * 0.85);
	float b = caustic_edge(p * 2.15 + vec2(3.7, 1.3), t * 1.15);
	// thin bright threads, brightest where two cross
	float la = exp(-a * a * 85.0);
	float lb = exp(-b * b * 150.0);
	float c = la * 0.55 + lb * 0.35 + la * lb * 1.1;
	// and the whole of it brighter in some places than others, as on a real pool floor
	return c * (0.45 + 1.0 * caustic_noise(p * 0.21 - t * 0.05));
}
