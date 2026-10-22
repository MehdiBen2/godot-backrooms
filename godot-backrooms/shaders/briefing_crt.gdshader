shader_type canvas_item;
// Clean vanilla pass-through: CRT distortion, curvature, scanlines, and glitch removed
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float curve = 0.0;
uniform float chroma = 0.0;
uniform float glow_amt = 0.0;
uniform float scan_amt = 0.0;
uniform float grain_amt = 0.0;
uniform float vignette_amt = 0.0;
uniform float flicker_amt = 0.0;
uniform float glitch = 0.0;
uniform vec3 tint = vec3(1.0);

varying vec4 v_modulate;

void vertex() {
	v_modulate = COLOR;
}

void fragment() {
	COLOR = vec4(texture(screen_tex, SCREEN_UV).rgb, v_modulate.a);
}
