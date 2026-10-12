shader_type spatial;
// The field terminal's glass (scripts/World/props/terminal_machine.gd): the terminal's SubViewport
// (terminal_os.gd) lit up on the CRT's face, unshaded so the phosphor reads as light rather than a
// painted surface (bright enough to catch the glow), over dark tube glass with a faint sheen.
// raster: half the lit picture's size, 0..0.5 each way. The tube warming up opens it from a dot to a
// line to the full screen, and switching off collapses it back (the prop tweens it).
render_mode unshaded, cull_back;

uniform sampler2D screen_tex : source_color, filter_linear;
uniform vec2 raster = vec2(0.5, 0.5);
uniform float energy = 1.35;
uniform float flash = 0.0;                       // the beam's hot core while the raster is a thin line
uniform vec3 glass = vec3(0.010, 0.011, 0.009);

void fragment() {
	vec2 c = UV - 0.5;
	vec2 ext = max(raster, vec2(0.0005));
	float inside = step(abs(c.x), ext.x) * step(abs(c.y), ext.y) * step(0.0006, raster.x);
	vec3 col = texture(screen_tex, c / (ext * 2.0) + 0.5).rgb;
	// thin raster: the whole picture's light in one line, hotter and whiter
	float thin = 1.0 - smoothstep(0.0, 0.06, raster.y);
	col = col * energy * (1.0 + 3.0 * thin) + vec3(1.0, 0.82, 0.55) * (thin * 2.0 + flash);
	// the tube's corners fall off a little, the way the phosphor thins toward the edge of the glass
	float vig = smoothstep(0.78, 0.38, length(c * vec2(1.0, 1.25)));
	float sheen = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0) * 0.06;
	ALBEDO = glass + vec3(sheen) + col * inside * mix(0.72, 1.0, vig);
}
