// Shared by pit_shaft.gdshader and pit_lamp*.gdshader (each declares `cell`, `rows` and `period` before including it)

float hash11(float n) { return fract(sin(n * 12.9898 + 4.1414) * 43758.5453); }
float vnoise1(float x) {
	float i = floor(x);
	float f = fract(x);
	return mix(hash11(i), hash11(i + 1.0), f * f * (3.0 - 2.0 * f));
}

// How lit row `row` is right now
float row_level(float row, float t) {
	int k = int(mod(row, float(period)));
	float kind = rows[k];
	if (kind < 0.5) return 0.0;
	if (kind < 1.5) return 0.97 + 0.03 * sin(t * 2.3 + float(k) * 1.7);   // a slow, barely-there drift
	// failing: on, then off for a beat or a burst of stutter, at its own pace
	float r = float(k);
	float beat = floor(t * (5.0 + 7.0 * hash11(r + 3.0)));
	float n = hash11(beat * 0.731 + r * 17.0);
	float burst = step(0.55, vnoise1(t * 0.6 + r * 9.0));
	return n < 0.18 + 0.5 * burst ? 0.06 : 1.0;
}

// Every tube is its own: how bright it is (from nearly out to full), how it hums, whether it is dead, whether it
// stutters, and at what pace and in what fits. `p` is where the tube is (x, z); `row` repeats with the period.
float tube_mul(vec2 p, float row, float t) {
	vec2 q = round(p / (0.5 * cell));
	float k = mod(row, float(period));
	float v = hash11(q.x * 7.31 + q.y * 131.7 + k * 17.9);
	float w = hash11(v * 91.7 + k * 3.3 + q.x - q.y);
	float m = mix(0.25, 1.0, v * v);
	m *= 0.9 + 0.1 * sin(t * (1.0 + 3.0 * w) + v * 40.0);
	if (w < 0.06) return 0.0;
	if (w < 0.30) {
		float rate = 3.0 + 12.0 * hash11(v * 13.0);
		float beat = floor(t * rate + w * 50.0);
		float burst = step(0.5, vnoise1(t * 0.4 + v * 30.0));
		float off = hash11(beat * 0.61 + v * 77.0);
		m *= off < 0.12 + 0.55 * burst ? 0.04 + 0.2 * hash11(beat + v) : 1.0;
	}
	return m;
}

// The light of one tube: its row's, times its own. In a dead row a straggler here and there still burns.
float tube_level(vec2 p, float row, float t) {
	vec2 q = round(p / (0.5 * cell));
	float rl = row_level(row, t);
	if (rl <= 0.0) rl = hash11(q.x * 3.7 + q.y * 9.1 + mod(row, float(period)) * 5.3) > 0.88 ? 0.5 : 0.0;
	return rl * tube_mul(p, row, t);
}

// The colour of one tube: some degree of yellow, from deep amber to a pale, washed-out white
vec3 tube_col(vec2 p) {
	vec2 q = round(p / (0.5 * cell));
	float v = hash11(q.x * 3.17 + q.y * 57.3 + 9.0);
	return mix(vec3(1.0, 0.7, 0.34), vec3(1.0, 0.97, 0.86), v * v * 0.5 + v * 0.5);
}
