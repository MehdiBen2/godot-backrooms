shader_type canvas_item;
// Blood thrown onto the lens (lens_blood.gd). Each splat is a metaball field: a body squashed along the throw, a
// spray of droplets flung on past it, and runs that slide down the glass over the next seconds. Thick blood is dark
// and opaque, a thin film lets the picture through red; a fake highlight off the field's slope makes it read wet.

const int MAX = 12;
uniform vec4 splat[MAX];    // xy: centre (0..1 of the screen), z: size (fraction of the screen height), w: seed
uniform vec4 info[MAX];     // xy: the direction it was thrown (screen, y down), z: age (s), w: 1 when in use
uniform float aspect = 1.7778;
uniform float fade = 1.0;
uniform float dark = 0.0;   // the eyelids / edges closing over the picture (Game.fx_blink, fx_fade)

float h1(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

// A compact metaball: 1 at distance r (d2 = distance squared), nothing past 2r, so splats only merge where they touch
float ball(float d2, float r) {
	float x = 1.0 - d2 / (4.0 * r * r);
	return x > 0.0 ? 2.37 * x * x * x : 0.0;
}

float field(vec2 uv, int i) {
	vec4 s = splat[i];
	vec4 f = info[i];
	if (f.w < 0.5) {
		return 0.0;
	}
	float r = s.z;
	float grow = 1.0 - exp(-f.z * 22.0);                    // it lands and spreads in a few frames
	vec2 q = uv - s.xy;
	q.x *= aspect;
	vec2 d = vec2(f.x * aspect, f.y);
	d = length(d) > 1e-4 ? normalize(d) : vec2(0.0, 1.0);
	vec2 n = vec2(-d.y, d.x);
	float along = dot(q, d);
	float across = dot(q, n);
	float v = ball(along * along * 0.5 + across * across * 1.5, r * max(grow, 0.05));
	for (int k = 0; k < 7; k++) {
		float sd = s.w * 13.7 + float(k) * 7.13;
		float dist = r * (1.3 + 3.4 * h1(sd)) * grow;
		float a = (h1(sd + 1.3) - 0.5) * 1.2;
		vec2 dir = d * cos(a) + n * sin(a);
		float rr = r * (0.10 + 0.26 * h1(sd + 2.9));
		vec2 e = q - dir * dist;
		v += ball(dot(e, e), rr);
	}
	for (int k = 0; k < 3; k++) {
		float sd = s.w * 5.1 + float(k) * 3.7;
		float x0 = (h1(sd) - 0.5) * r * 1.4;
		float len = r * (0.6 + 4.5 * h1(sd + 0.7)) * (1.0 - exp(-f.z * 0.5));
		float w = r * (0.09 + 0.07 * h1(sd + 1.9));
		float y = clamp(q.y, 0.0, len);
		float taper = mix(1.0, 0.6, y / max(len, 1e-4));
		vec2 e = q - vec2(x0, y);
		v += ball(dot(e, e), w * taper);
		vec2 eb = q - vec2(x0, len);
		v += ball(dot(eb, eb), w * 1.5);
	}
	return v;
}

void fragment() {
	float v = 0.0;
	for (int i = 0; i < MAX; i++) {
		v += field(UV, i);
	}
	float a = smoothstep(0.8, 1.2, v);
	float thick = clamp((v - 1.0) * 0.6, 0.0, 1.0);
	vec3 col = mix(vec3(0.55, 0.02, 0.03), vec3(0.22, 0.0, 0.01), thick);
	vec2 g = vec2(dFdx(v), dFdy(v));
	vec3 nrm = normalize(vec3(-g * 6.0, 1.0));
	float spec = pow(clamp(dot(nrm, normalize(vec3(-0.35, -0.55, 0.75))), 0.0, 1.0), 28.0);
	col += vec3(1.0, 0.75, 0.75) * spec * 0.3 * (1.0 - thick * 0.5);
	COLOR = vec4(col * (1.0 - dark), a * mix(0.5, 0.96, thick) * fade);
}
