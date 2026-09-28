shader_type spatial;
// Wear on a mannequin variant, drawn as a material_overlay on top of its own texture (mannequin_model.gd):
//   cracks:  hairline cracks in the plaster, heaviest round the head, with a few dark chips
//   clothes: a display-shop outfit painted on the pieces by which bone they hang from (shirt on the chest,
//            sleeves on the upper arms, skirt / shorts on the pelvis), from the skin's bone indices
// Everything else of the overlay is transparent, so the sculpt shows through.
render_mode blend_mix, depth_draw_never, cull_back;

uniform float cracks = 0.0;                   // 0..1
uniform float clothes = 0.0;                  // 0 / 1
uniform vec3 shirt_color : source_color = vec3(0.35, 0.33, 0.4);
uniform vec3 bottom_color : source_color = vec3(0.2, 0.2, 0.22);
uniform float sleeves = 1.0;                  // 1: the shirt covers the upper arms too
// skin bind indices of the bones the clothes follow (-1: none)
uniform int bone_chest = -1;
uniform int bone_pelvis = -1;
uniform int bone_arm_l = -1;
uniform int bone_arm_r = -1;

varying vec3 obj;
varying float shirt;
varying float bottom;

float owns(uvec4 idx, vec4 w, int bone) {
	if (bone < 0) return 0.0;
	uint b = uint(bone);
	return (idx.x == b ? w.x : 0.0) + (idx.y == b ? w.y : 0.0) + (idx.z == b ? w.z : 0.0) + (idx.w == b ? w.w : 0.0);
}

vec3 hash3(vec3 p) {
	p = vec3(dot(p, vec3(127.1, 311.7, 74.7)), dot(p, vec3(269.5, 183.3, 246.1)), dot(p, vec3(113.5, 271.9, 124.6)));
	return fract(sin(p) * 43758.5453123);
}

// distance to the nearest crack: the edge between two Voronoi cells
float crack_dist(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	float d1 = 8.0;
	float d2 = 8.0;
	for (int x = -1; x <= 1; x++)
	for (int y = -1; y <= 1; y++)
	for (int z = -1; z <= 1; z++) {
		vec3 g = vec3(float(x), float(y), float(z));
		vec3 o = hash3(i + g);
		float d = length(g + o - f);
		if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
	}
	return d2 - d1;
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash3(i).x, hash3(i + vec3(1, 0, 0)).x, f.x), mix(hash3(i + vec3(0, 1, 0)).x, hash3(i + vec3(1, 1, 0)).x, f.x), f.y),
		mix(mix(hash3(i + vec3(0, 0, 1)).x, hash3(i + vec3(1, 0, 1)).x, f.x), mix(hash3(i + vec3(0, 1, 1)).x, hash3(i + vec3(1, 1, 1)).x, f.x), f.y), f.z);
}

void vertex() {
	obj = VERTEX;
	shirt = owns(BONE_INDICES, BONE_WEIGHTS, bone_chest) + sleeves * (owns(BONE_INDICES, BONE_WEIGHTS, bone_arm_l) + owns(BONE_INDICES, BONE_WEIGHTS, bone_arm_r));
	bottom = owns(BONE_INDICES, BONE_WEIGHTS, bone_pelvis);
}

void fragment() {
	float a = 0.0;
	vec3 c = vec3(0.0);
	float rough = 0.9;
	if (clothes > 0.5 && (shirt > 0.5 || bottom > 0.5)) {
		// woven fabric: fine threads, a little mottling, darker in the folds the sculpt already has
		float weave = 0.5 + 0.5 * sin(obj.x * 900.0) * sin(obj.y * 900.0);
		float mottle = vnoise(obj * 18.0);
		c = (shirt > 0.5 ? shirt_color : bottom_color) * (0.85 + 0.1 * weave + 0.12 * mottle);
		a = 1.0;
		rough = 0.95;
	}
	if (cracks > 0.0) {
		// denser round the head; a mask so some areas stay whole
		float head = smoothstep(1.35, 1.6, obj.y);
		float mask = smoothstep(0.35, 0.6, vnoise(obj * 3.0 + 7.0)) * (0.55 + 0.45 * head);
		float cd = crack_dist(obj * mix(9.0, 15.0, head));
		float line = (1.0 - smoothstep(0.015, 0.045, cd)) * mask * cracks;
		float chip = smoothstep(0.82, 0.9, vnoise(obj * 22.0)) * mask * cracks * 0.8;
		float k = max(line, chip);
		c = mix(c, vec3(0.09, 0.075, 0.065), k);
		a = max(a, k);
	}
	ALBEDO = c;
	ALPHA = a;
	ROUGHNESS = rough;
}
