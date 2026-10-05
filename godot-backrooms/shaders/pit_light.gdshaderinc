// Shared by pit_shaft.gdshader and pit_lamp*.gdshader (the shader declares `cell`, `rows` and `period` first)
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

// What colour a storey's tubes are, and how bright: every one some degree of yellow, from a pale, washed-out
// fluorescent to a deep amber, the older ones dimmer. Every storey is its own place.
vec3 row_color(float row) {
	float k = mod(row, float(period));
	float r = hash11(k * 5.7 + 1.3);
	float g = hash11(k * 8.1 + 3.9);
	return mix(vec3(1.0, 0.74, 0.38), vec3(1.0, 0.98, 0.88), r) * mix(0.65, 1.0, g);
}
float row_dirt(float row) { return mix(0.4, 1.9, hash11(mod(row, float(period)) * 2.9 + 7.7)); }
float row_tone(float row) { return mix(0.5, 1.0, hash11(mod(row, float(period)) * 4.3 + 2.1)); }

// One tube's light: its row's, times its own brightness. A few tubes are dead, a few stutter on their own, and in
// a dead row only a straggler or two still burn. `p` is where the tube is (x, z); `row` repeats with the period.
float tube_level(vec2 p, float row, float t) {
	vec2 q = round(p / (0.5 * cell));
	float k = mod(row, float(period));
	float v = hash11(q.x * 7.31 + q.y * 131.7 + k * 17.9);
	float w = hash11(v * 91.7 + k * 3.3 + q.x - q.y);
	float m = mix(0.5, 1.0, v * v);
	float rl = row_level(row, t);
	if (rl <= 0.0) rl = w > 0.86 ? 0.5 : 0.0;
	if (w < 0.05) return 0.0;
	if (w < 0.13) {
		float beat = floor(t * (6.0 + 6.0 * v) + w * 40.0);
		m *= hash11(beat * 0.37 + w * 55.0) < 0.35 ? 0.08 : 1.0;
	}
	return rl * m;
}

// a slightly warmer or greener tube, per tube
vec3 tube_tint(vec2 p) {
	vec2 q = round(p / (0.5 * cell));
	float v = hash11(q.x * 3.17 + q.y * 57.3 + 9.0);
	return mix(vec3(1.0, 0.94, 0.82), vec3(1.0, 0.97, 0.86), v);
}

// How lit the ceiling light at the middle of cell `lc` of storey `row` is: the tube's own level, and whole stretches
// of rooms (two cells across) that are dark
float lamp_level(vec2 lc, float row, float t) {
	vec2 blk = floor(lc / (2.0 * cell));
	float dark = hash11(blk.x * 5.31 + blk.y * 11.7 + mod(row, float(period)) * 3.1) < 0.28 ? 0.1 : 1.0;
	return tube_level(lc, row, t) * dark;
}
