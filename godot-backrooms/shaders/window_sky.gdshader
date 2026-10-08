shader_type spatial;
// What a window looks out on (props/window.gd): an outside that isn't there, seen through glass from a dim room.
// It is drawn from the way you look through the glass, not painted on it, so it behaves like something far off:
// it doesn't slide across the pane as you walk past, and looking up through it shows more sky.
// From indoors a bright outside is mostly glare: a pale sky going white towards the horizon, a hazy brightness
// below it, the sun only a soft glow (the camera can't hold it). Overexposed on purpose, so it blooms into the
// frame round it. The glass itself shows in two ways: at a glancing look it mirrors the dim room (darker, greyer),
// and up close faint dried water spots and a film of dust catch the light.
render_mode unshaded, cull_back, fog_disabled, shadows_disabled;

uniform vec3 sun_dir = vec3(-0.8, 0.6, 0.0);     // world, towards the sun
uniform vec3 zenith : source_color = vec3(0.30, 0.54, 0.93);
uniform vec3 horizon : source_color = vec3(0.86, 0.92, 0.98);
uniform vec3 ground : source_color = vec3(0.62, 0.70, 0.74);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.88);
uniform float exposure = 2.2;
uniform float clouds = 0.2;
uniform vec3 room_tint : source_color = vec3(0.05, 0.055, 0.06);   // what the glass mirrors at a glance

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

void fragment() {
	vec3 dir = normalize((INV_VIEW_MATRIX * vec4(-VIEW, 0.0)).xyz);
	float up = dir.y;
	// the sky: deepest straight up, washing out to white haze at the horizon; below it a pale bright distance
	vec3 col = mix(horizon, zenith, smoothstep(0.02, 0.85, up));
	col = mix(col, mix(horizon, ground, 0.55), smoothstep(0.0, -0.25, up));
	// high thin haze, barely there: big soft brighter and dimmer areas, no shapes to read as clouds
	if (up > 0.0) {
		vec2 cuv = dir.xz / (up + 0.25) * 0.5 + vec2(TIME * 0.003, TIME * 0.001);
		col = mix(col, horizon * 1.06, smoothstep(0.35, 0.85, fbm(cuv)) * clouds * smoothstep(0.0, 0.3, up));
	}
	// the sun: a wide glow and a brighter core, never a hard disc
	float s = max(dot(dir, normalize(sun_dir)), 0.0);
	col += sun_color * (pow(s, 10.0) * 0.35 + pow(s, 90.0) * 0.9 + pow(s, 900.0) * 3.0);
	col *= exposure;
	// the glass: a glance off it mirrors the room; dust and dried spots catch a little of the light
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 gp = world.xz * 0.7 + world.yy * 1.3;
	float spots = smoothstep(0.62, 0.8, noise(gp * 9.0)) * 0.5 + smoothstep(0.55, 0.9, fbm(gp * 2.0)) * 0.5;
	float glance = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	col = mix(col, room_tint, clamp(glance * 0.9, 0.0, 0.85));
	col *= 1.0 - spots * 0.12;
	ALBEDO = col;
}
