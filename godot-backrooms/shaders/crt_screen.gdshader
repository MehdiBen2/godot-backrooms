shader_type spatial;
// The field terminal's tube (scripts/World/props/terminal_machine.gd): the terminal's SubViewport
// (terminal_os.gd) shown the way a real CRT shows a picture, not as a texture on a card.
//  - The faceplate is glass: dark grey-green, glossy, lit by the room and reflecting it.
//  - The picture is light from a phosphor layer `depth` behind that glass (emission), so it slides under the
//    glass when seen at an angle.
//  - The phosphor is a Trinitron aperture grille (vertical RGB stripes) lit by beam lines that swell where
//    the picture is bright; both fade out once they get finer than the view can resolve (no moire).
//  - Light scatters in the faceplate round bright text (halation), the red and blue beams land a touch off
//    toward the edges (convergence), the corners dim, and the grille's two damper wires cross it faintly.
// raster: half the lit picture's size, 0..0.5 each way. The tube warming up opens it from a dot to a line to
// the full screen, and switching off collapses it back (the prop tweens it).
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D screen_tex : source_color, filter_linear, repeat_disable;
uniform vec2 raster = vec2(0.5, 0.5);
uniform float energy = 1.5;
uniform float flash = 0.0;                       // the beam's hot core while the raster is a thin line
uniform vec3 glass_tint : source_color = vec3(0.045, 0.05, 0.047);
uniform float scan_lines = 300.0;                // beam lines down the picture
uniform float grille = 170.0;                    // RGB stripe triads across it
uniform float mask_amt = 0.0;                    // the RGB grille tints text with colour fringes; off for legibility
uniform float halation = 0.0;                    // the glow round bright text smeared it; off
uniform float converge = 0.0;                    // red / blue beam offset: ghosted the text and the cursor; off
uniform float depth = 0.005;                     // m from the outer glass to the phosphor
uniform vec2 glass_size = vec2(0.2809, 0.2107);  // m
uniform mat3 to_glass = mat3(1.0);               // world -> glass (x right, y up, z out of the glass)

vec3 pic(vec2 uv) {
	return texture(screen_tex, uv).rgb;
}

void fragment() {
	// the phosphor lies behind the faceplate: follow the view ray on through the glass to reach it
	vec3 v = to_glass * (INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz;
	vec2 c = UV - 0.5 + vec2(-v.x, v.y) / max(v.z, 0.2) * depth / glass_size;
	vec2 ext = max(raster, vec2(0.0005));
	float inside = step(abs(c.x), ext.x) * step(abs(c.y), ext.y) * step(0.0006, raster.x);
	vec2 uv = c / (ext * 2.0) + 0.5;

	vec2 off = c * length(c) * converge * 8.0;
	vec3 col = vec3(pic(uv + off).r, pic(uv).g, pic(uv - off).b);
	vec3 halo = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.7853982;
		vec2 d = vec2(cos(a), sin(a) * 1.333);
		halo += pic(uv + d * 0.006) + pic(uv + d * 0.016) * 0.6;
	}
	col += halo / 12.8 * halation;

	// beam lines: a bright line is a fatter line
	float lum = clamp(dot(col, vec3(0.3, 0.55, 0.15)), 0.0, 1.0);
	float ly = uv.y * scan_lines;
	float sy = fract(ly) - 0.5;
	float w = mix(0.2, 0.42, lum);
	float beam = exp(-sy * sy / (2.0 * w * w)) * 1.35;
	col *= mix(beam, 1.0, smoothstep(0.3, 0.7, fwidth(ly)));
	// the grille's stripes
	float gx = uv.x * grille * 3.0;
	float p = fract(gx / 3.0);
	vec3 stripe = 1.0 + cos(6.2831853 * (p - vec3(1.0, 3.0, 5.0) / 6.0));
	col *= mix(vec3(1.0), stripe, mask_amt * (1.0 - smoothstep(0.35, 0.8, fwidth(gx))));
	// damper wires, in the glass (they don't move with the picture)
	col *= 1.0 - 0.3 * (smoothstep(0.0016, 0.0, abs(UV.y - 0.32)) + smoothstep(0.0016, 0.0, abs(UV.y - 0.68)));

	float thin = 1.0 - smoothstep(0.0, 0.06, raster.y);
	col = col * (1.0 + 3.0 * thin) + vec3(1.0, 0.82, 0.55) * (thin * 2.0 + flash);
	float vig = smoothstep(0.78, 0.38, length(c * vec2(1.0, 1.25)));
	EMISSION = col * inside * mix(0.65, 1.0, vig) * energy;

	// the faceplate itself: matte and non-reflective, so no lamp glare lands on the picture
	ALBEDO = glass_tint;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}
