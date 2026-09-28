shader_type spatial;
// The cover thrown over a standing mannequin (mannequin_model.gd _sheet). No UVs: everything is worked out
// from the object-space position (feet at y = 0, about 1.9 m tall).
//   kind 0  linen dust sheet: fine weave, brown water stains, grime rising from the hem
//   kind 1  moving blanket: quilted diamond stitching, felt-like, darker
//   kind 2  plastic wrap: clear, glossy and crinkled, the figure inside shows through
render_mode cull_disabled, depth_prepass_alpha;

uniform int kind = 0;
uniform vec3 tint : source_color = vec3(0.78, 0.76, 0.7);
uniform float seed = 0.0;

varying vec3 obj;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	obj = VERTEX;
}

void fragment() {
	vec3 p = obj + vec3(seed * 13.7, 0.0, seed * 7.3);
	float ang = atan(obj.z, obj.x);                          // around the figure: threads follow the drape
	vec2 cloth = vec2(ang * 0.35, obj.y);
	if (kind == 2) {
		// clear plastic: mostly see-through, milky where it bunches, glossy crinkles
		float crinkle = fbm(p * 14.0);
		float milk = 0.12 + 0.25 * smoothstep(0.45, 0.8, crinkle) + 0.15 * smoothstep(0.3, 0.0, obj.y);
		ALBEDO = mix(vec3(0.85, 0.88, 0.86), tint, 0.3);
		ALPHA = milk;
		ROUGHNESS = 0.08 + 0.2 * crinkle;
		SPECULAR = 0.9;
		NORMAL_MAP = normalize(vec3((vnoise(p * 30.0) - 0.5) * 0.6, (vnoise(p * 30.0 + 11.0) - 0.5) * 0.6, 1.0)) * 0.5 + 0.5;
	} else {
		vec3 c = tint;
		float rough = 0.95;
		if (kind == 0) {
			// linen: a fine weave, a faint check where the threads bunch
			float weave = 0.5 + 0.5 * sin(cloth.x * 1400.0) * sin(cloth.y * 1400.0);
			c *= 0.93 + 0.07 * weave;
		} else {
			// moving blanket: diamond quilting, each pad puffed in the middle, stitched lines darker
			vec2 q = vec2(cloth.x * 9.0 + cloth.y * 9.0, cloth.x * 9.0 - cloth.y * 9.0);
			vec2 f = abs(fract(q) - 0.5);
			float stitch = smoothstep(0.46, 0.5, max(f.x, f.y));
			float puff = 1.0 - max(f.x, f.y) * 1.2;
			c *= (0.78 + 0.22 * puff) * (1.0 - 0.35 * stitch);
			c *= 0.9 + 0.1 * vnoise(p * 60.0);                  // felt fuzz
		}
		// large, soft mottling so it isn't one flat colour
		c *= 0.88 + 0.2 * fbm(p * 2.5);
		// water stains: tide-marked rings, browner at the edge
		float st = fbm(p * 3.0 + 4.0);
		float stain = smoothstep(0.58, 0.64, st) - smoothstep(0.66, 0.75, st) * 0.6;
		c = mix(c, c * vec3(0.72, 0.6, 0.42), clamp(stain, 0.0, 1.0) * 0.7);
		// grime rising from the floor where it drags, patchy
		float grime = smoothstep(0.55, 0.0, obj.y + (fbm(p * 5.0) - 0.5) * 0.35);
		c = mix(c, vec3(0.2, 0.17, 0.12), grime * 0.75);
		// a few dust streaks running down the folds
		float streak = smoothstep(0.7, 0.9, vnoise(vec3(cloth.x * 40.0, obj.y * 1.5, seed)));
		c *= 1.0 - 0.15 * streak;
		ALBEDO = c;
		ROUGHNESS = rough;
	}
}
