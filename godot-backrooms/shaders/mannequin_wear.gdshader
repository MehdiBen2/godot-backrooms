shader_type spatial;
// The mannequin variant's material (mannequin_model.gd sets it as the material_override of every variant):
// its own plaster texture, plus the wear it was dealt:
//   cracks:  hairline cracks in the plaster, heaviest round the head, with a few dark chips
//   clothes: a display-shop outfit painted on by piece: a top on the chest (sleeves on the upper arms),
//            shorts or full trousers, or a knee-length dress; tops can be plain, striped, plaid or dotted
// One opaque pass on purpose: drawn as a transparent overlay on top of the base material, the two layers
// z-fought on real GPUs and the clothes came out as random blotches.
// Which piece a vertex belongs to comes from the model's vertex colour (R = piece id / 10, baked by
// tools/blender/rig_mannequin_variant.py): 1 head, 2 chest, 3 pelvis, 4-5 upper arms, 6-7 forearms, 8-9 legs.
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float roughness = 0.9;
uniform float cracks = 0.0;                   // 0..1
uniform float clothes = 0.0;                  // 0 / 1
uniform vec3 shirt_color : source_color = vec3(0.35, 0.33, 0.4);
uniform vec3 bottom_color : source_color = vec3(0.2, 0.2, 0.22);
uniform float sleeves = 1.0;                  // 1: the shirt covers the upper arms too
uniform float pants = 0.0;                    // 1: the bottom runs down the legs (feet left bare)
uniform float dress = 0.0;                    // 1: one piece in the top's colour, from chest to the knees
uniform int pattern = 0;                      // top: 0 plain, 1 stripes, 2 plaid, 3 polka dots
uniform vec3 pattern_color : source_color = vec3(0.9, 0.88, 0.8);

varying vec3 obj;
varying float piece;

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
	piece = COLOR.r * 10.0;
}

void fragment() {
	vec3 c = texture(albedo_tex, UV).rgb;
	float rough = roughness;
	float id = floor(piece + 0.5);               // interpolation can't blend ids: a piece is one id throughout
	if (clothes > 0.5) {
		bool leg = id == 8.0 || id == 9.0;
		bool shirt = id == 2.0 || (sleeves > 0.5 && (id == 4.0 || id == 5.0));
		bool bottom = id == 3.0 || (pants > 0.5 && leg && obj.y > 0.1);
		if (dress > 0.5) {
			shirt = shirt || id == 3.0 || (leg && obj.y > 0.5);
			bottom = false;
		}
		if (shirt || bottom) {
			// woven fabric: fine threads and a little mottling, the sculpt's shading still shows through
			float weave = 0.5 + 0.5 * sin(obj.x * 900.0) * sin(obj.y * 900.0);
			float mottle = vnoise(obj * 18.0);
			vec3 top = shirt_color;
			if (shirt && pattern > 0) {
				float around = atan(obj.z, obj.x) * 0.28;        // metres round the body, roughly
				if (pattern == 1) {                               // horizontal stripes
					top = mix(top, pattern_color, step(0.5, fract(obj.y * 14.0)));
				} else if (pattern == 2) {                        // plaid: two crossing bands, darker where they meet
					float h = step(0.62, fract(obj.y * 9.0));
					float v = step(0.62, fract(around * 9.0));
					top = mix(top, pattern_color, (h + v) * 0.35);
					top *= 1.0 - 0.18 * h * v;
				} else {                                          // polka dots
					vec2 g = fract(vec2(around, obj.y) * 16.0) - 0.5;
					top = mix(top, pattern_color, 1.0 - smoothstep(0.2, 0.26, length(g)));
				}
			}
			vec3 cloth = (shirt ? top : bottom_color) * (0.85 + 0.1 * weave + 0.12 * mottle);
			float shade = clamp(dot(c, vec3(0.333)) * 1.4, 0.6, 1.1);
			c = cloth * shade;
			rough = 0.95;
		}
	}
	if (cracks > 0.0) {
		float head = smoothstep(1.35, 1.6, obj.y);
		float mask = smoothstep(0.35, 0.6, vnoise(obj * 3.0 + 7.0)) * (0.55 + 0.45 * head);
		float cd = crack_dist(obj * mix(9.0, 15.0, head));
		float line = (1.0 - smoothstep(0.015, 0.045, cd)) * mask * cracks;
		float chip = smoothstep(0.82, 0.9, vnoise(obj * 22.0)) * mask * cracks * 0.8;
		c = mix(c, vec3(0.09, 0.075, 0.065), max(line, chip));
	}
	ALBEDO = c;
	ROUGHNESS = rough;
}
