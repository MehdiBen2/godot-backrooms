shader_type canvas_item;
// The mission briefing's tube (scripts/UI/menu/mission_briefing.gd puts it on a full-screen ColorRect, last of
// all, over the page): a slight corner-fitted barrel curve, red / blue fringing, a soft phosphor glow,
// scanlines, grain, a slow rolling band, frame flicker, a vignette, and a VHS tracking tear driven by
// `glitch` (0..1, kicked from GDScript when a section comes up, at random, and on accept).

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float curve : hint_range(0.0, 0.3) = 0.015;
uniform float chroma : hint_range(0.0, 0.01) = 0.0004;
uniform float glow_amt : hint_range(0.0, 1.0) = 0.35;
uniform float scan_amt : hint_range(0.0, 1.0) = 0.2;
uniform float grain_amt : hint_range(0.0, 1.0) = 0.02;
uniform float vignette_amt : hint_range(0.0, 1.0) = 0.6;
uniform float flicker_amt : hint_range(0.0, 0.2) = 0.035;
uniform float glitch : hint_range(0.0, 1.0) = 0.0;
uniform vec3 tint = vec3(1.0, 0.95, 0.84);

// the node's modulate: writing COLOR drops it, so it is caught here and the alpha applied at the end
varying vec4 v_modulate;

void vertex() {
	v_modulate = COLOR;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// bulge, scaled back so the corners land on the corners (no black border, nothing cropped at the corners)
vec2 barrel(vec2 uv) {
	vec2 c = uv * 2.0 - 1.0;
	c *= (1.0 + curve * dot(c, c)) / (1.0 + curve * 2.0);
	return c * 0.5 + 0.5;
}

void fragment() {
	vec2 uv = barrel(SCREEN_UV);
	float tick = floor(TIME * 24.0);

	// tracking tear: bands of rows slide sideways, a bar rolls down wobbling the picture
	float bar = 0.0;
	if (glitch > 0.002) {
		float band = floor(uv.y * 22.0);
		if (hash12(vec2(band, tick)) < glitch * 0.45) {
			uv.x += (hash12(vec2(band, tick + 7.0)) - 0.5) * 0.07 * glitch;
		}
		bar = smoothstep(0.05, 0.0, abs(uv.y - fract(TIME * 0.9))) * glitch;
		uv.x += bar * 0.012 * sin(uv.y * 900.0 + TIME * 40.0);
	}

	float ca = chroma * (1.0 + glitch * 4.0);
	vec3 col;
	col.r = texture(screen_tex, uv + vec2(ca, 0.0)).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - vec2(ca, 0.0)).b;
	col += textureLod(screen_tex, uv, 3.0).rgb * glow_amt;          // phosphor bleed around the text

	col *= 1.0 - scan_amt * (0.5 - 0.5 * sin(FRAGCOORD.y * 3.14159 * 0.5));
	col *= 1.0 + 0.05 * sin((UV.y - TIME * 0.11) * 6.2831 * 1.3);    // slow rolling band
	col *= 1.0 - flicker_amt * hash12(vec2(tick, 3.0));
	col += (hash12(FRAGCOORD.xy + fract(TIME * 7.0) * 400.0) - 0.5) * grain_amt;
	// sparse dropout streaks inside the tear
	if (glitch > 0.002 && hash12(vec2(floor(UV.y * 360.0), tick)) > 1.0 - glitch * 0.04) {
		col += vec3(0.3);
	}
	col += bar * 0.08;

	vec2 v = UV * 2.0 - 1.0;
	col *= mix(1.0, smoothstep(1.55, 0.35, length(v * vec2(0.85, 1.0))), vignette_amt);
	col *= tint;
	COLOR = vec4(max(col, vec3(0.0)), v_modulate.a);
}
