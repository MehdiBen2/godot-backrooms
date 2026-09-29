shader_type canvas_item;
// Field scanner scan mode (scripts/UI/hud/scan_readout.gd): while Q is held the view goes through a
// fisheye lens (the same corner-fitted barrel as ui_vhs_overlay.gdshader with fit_corners, so the
// scanner's marks, drawn through that overlay with the same `distortion`, stay on their targets),
// with a little colour fringing toward the rim, graded toward the terminal's amber and closed in at
// the edges, with faint scanlines. `amount` fades it in and out; the node's modulate alpha fades it
// with the HUD.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 tint = vec3(0.941, 0.659, 0.22);
uniform float distortion = 0.0;
uniform float aspect = 1.7778;

// where the lens puts `uv`: a barrel, scaled back so the corners stay on the corners
vec2 lens(vec2 uv, float k) {
	vec2 p = uv - 0.5;
	p.x *= aspect;
	vec2 pd = p * (1.0 + k * dot(p, p)) / (1.0 + k * (0.25 * aspect * aspect + 0.25));
	pd.x /= aspect;
	return pd + 0.5;
}

void fragment() {
	vec2 uv = lens(SCREEN_UV, distortion);
	vec2 rim = (uv - 0.5) * distortion * 0.03;
	vec3 c = vec3(texture(screen_tex, uv + rim).r, texture(screen_tex, uv).g, texture(screen_tex, uv - rim).b);
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	vec3 g = mix(c, l * tint * 1.35, 0.6);
	g = (g - 0.5) * 1.1 + 0.5;
	g *= 0.85;
	vec2 p = (SCREEN_UV - vec2(0.5, 0.47)) / vec2(0.6, 0.66);
	g *= 1.0 - 0.8 * smoothstep(0.58, 1.0, length(p));
	g *= 1.0 - 0.08 * step(mod(FRAGCOORD.y, 3.0), 1.0);
	COLOR = vec4(max(g, vec3(0.0)), COLOR.a * amount);
}
