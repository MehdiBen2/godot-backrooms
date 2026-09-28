shader_type canvas_item;
// Field scanner scan mode (scripts/UI/hud/scan_readout.gd): while Q is held the view is graded
// toward the terminal's amber and closed in at the edges like looking down a lens, with faint
// scanlines. `amount` fades it in and out; the node's modulate alpha fades it with the HUD.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 tint = vec3(0.91, 0.714, 0.29);

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	vec3 g = mix(c, l * tint * 1.35, 0.6);
	g = (g - 0.5) * 1.1 + 0.5;
	g *= 0.85;
	vec2 p = (SCREEN_UV - vec2(0.5, 0.47)) / vec2(0.6, 0.66);
	g *= 1.0 - 0.8 * smoothstep(0.58, 1.0, length(p));
	g *= 1.0 - 0.08 * step(mod(FRAGCOORD.y, 3.0), 1.0);
	COLOR = vec4(max(g, vec3(0.0)), COLOR.a * amount);
}
