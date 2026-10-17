shader_type spatial;
// A night window's glass (props/window.gd, a "night" MODEL_FRAMES style): a dead black outside, seen from a lit room.
// The outside is drawn from the way you look through the glass, as window_sky.gdshader's is, so it has depth: a
// faint cold murk low down, drifting a few metres out, going to nothing above and beyond it. Nothing of it lights
// the room. The glass is real glass for the room's own lights: black behind it makes it a dark mirror, so the
// lamps' highlights and whatever the level reflects slide over it as you move, with dust and dried spots in them.
// `figure`: something standing in the dark behind the glass (a face, a shape: its alpha cuts it out), `figure_depth`
// metres back, drawn from the same look through the glass so it stays put behind the pane as you walk past; it is
// lit only by the little of the room's light that gets out to it (window.gd set_figure).

uniform vec3 murk : source_color = vec3(0.010, 0.013, 0.022);     // the faintest cold haze, low down out there
uniform vec3 void_col : source_color = vec3(0.0015, 0.0018, 0.003);
uniform float murk_depth = 4.0;                  // m: how far out the haze drifts
uniform sampler2D figure : source_color, hint_default_transparent, filter_linear_mipmap, repeat_disable;
uniform float has_figure = 0.0;
uniform vec4 figure_rect = vec4(0.0, 1.5, 0.45, 0.6);   // its middle along the window (z) and up (y), its width and height, m
uniform float figure_depth = 0.5;
uniform float figure_light = 0.15;

varying vec3 local_pos;
varying vec3 local_cam;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += noise(p) * a;
		p = p * 2.07 + 17.0;
		a *= 0.5;
	}
	return s;
}

void vertex() {
	// (the window's own frame: +x into the room, z along the wall, y up from the floor)
	local_pos = VERTEX;
	local_cam = (inverse(MODEL_MATRIX) * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;
}

void fragment() {
	vec3 dir = normalize(local_pos - local_cam);          // out through the glass: -x
	float out_x = max(-dir.x, 0.05);
	// the murk: a layer some metres out, low down, dying off upwards and as the look runs along the wall
	vec3 at = local_pos + dir * (murk_depth / out_x);
	float m = fbm(vec2(at.z, at.y * 1.6) * 0.35 + vec2(TIME * 0.004, 0.0));
	float low = 1.0 - smoothstep(-1.0, 2.5, at.y);
	vec3 col = mix(void_col, murk, clamp(m * low * 1.4, 0.0, 1.0) * out_x);
	// what stands behind the glass
	if (has_figure > 0.5) {
		vec3 hit = local_pos + dir * ((local_pos.x + figure_depth) / out_x);
		// (seen from the room, looking along -x, the viewer's right is -z)
		vec2 uv = vec2(0.5 - (hit.z - figure_rect.x) / figure_rect.z, 0.5 - (hit.y - figure_rect.y) / figure_rect.w);
		if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) {
			vec4 f = texture(figure, uv);
			col = mix(col, f.rgb * figure_light * exp(-figure_depth * 0.9), f.a);
		}
	}
	// the glass: a film of dust and dried spots on it, catching the room's light
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 gp = world.xz * 0.7 + world.yy * 1.3;
	float spots = smoothstep(0.62, 0.8, noise(gp * 9.0)) * 0.5 + smoothstep(0.55, 0.9, fbm(gp * 2.0)) * 0.5;
	ALBEDO = vec3(0.012) + vec3(0.05) * spots;
	ROUGHNESS = 0.05 + spots * 0.3;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	EMISSION = col;
}
