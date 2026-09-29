shader_type canvas_item;
// Field scanner scan mode (scripts/UI/hud/scan_readout.gd): while Q is held the view is graded
// toward the terminal's amber and closed in at the edges like looking down a lens, with faint
// scanlines. `amount` fades it in and out; the node's modulate alpha fades it with the HUD.
// `interference` (0..1) is how little signal there is: grain and a few torn lines that clear as the
// reading firms up. The picture also refreshes top to bottom like a slow instrument display.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float interference : hint_range(0.0, 1.0) = 0.0;
uniform vec3 tint = vec3(0.941, 0.659, 0.22);

float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	vec2 uv = SCREEN_UV;
	// interference: now and then a thin band of lines slips sideways
	float row = floor(uv.y * 180.0);
	float tick = floor(TIME * 14.0);
	float slip = step(1.0 - 0.05 * interference, h(vec2(row * 0.37, tick)));
	uv.x += (h(vec2(row, tick + 1.0)) - 0.5) * 0.012 * slip;

	vec3 c = texture(screen_tex, uv).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	// a lighter grade than before: more of the room's own colour survives under the amber
	vec3 g = mix(c, l * tint * 1.3, 0.46);
	g = (g - 0.5) * 1.08 + 0.5;
	g *= 0.9;
	vec2 p = (SCREEN_UV - vec2(0.5, 0.47)) / vec2(0.6, 0.66);
	g *= 1.0 - 0.72 * smoothstep(0.58, 1.0, length(p));
	g *= 1.0 - 0.07 * step(mod(FRAGCOORD.y, 3.0), 1.0);
	// the refresh: a soft brighter band rolling down about every four seconds
	float roll = fract(TIME * 0.24);
	float d = SCREEN_UV.y - roll;
	g *= 1.0 + 0.045 * exp(-d * d * 900.0);
	// grain, heavier with less signal
	g += (h(FRAGCOORD.xy + tick * 7.13) - 0.5) * (0.025 + 0.07 * interference);
	COLOR = vec4(max(g, vec3(0.0)), COLOR.a * amount);
}
