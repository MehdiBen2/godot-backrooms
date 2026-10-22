shader_type canvas_item;
render_mode blend_premul_alpha;
// Clean vanilla pass-through: UI fisheye, chromatic aberration, scanlines, grain, VHS glitch, and bloom removed

uniform float aspect = 1.5;
uniform float distortion = 0.0;
uniform bool fit_corners = false;
uniform float chroma_amt = 0.0;
uniform float scan_amt = 0.0;
uniform float grain_amt = 0.0;
uniform float vignette_amt = 0.0;
uniform float glitch = 0.0;
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D bloom_tex : hint_default_black, filter_linear, repeat_disable;
uniform float bloom_amt = 0.0;
uniform sampler2D bloom_wide_tex : hint_default_black, filter_linear, repeat_disable;
uniform float bloom_wide_amt = 0.0;
uniform float saturation = 1.0;
uniform float bloom_hot = 0.0;
uniform float bloom_tint = 0.0;
uniform float bloom_damp = 0.0;
uniform float split_px = 0.0;
uniform float ghost_px = 0.0;
uniform float ghost_amt = 0.0;
uniform float flicker_amt = 0.0;
uniform float vhs_amt = 0.0;
uniform float vhs_smear = 0.0;
uniform float vhs_wiggle = 0.0;
uniform float vhs_wiggle_speed = 0.0;
uniform int vhs_samples = 1;

varying vec4 v_modulate;

void vertex() {
	v_modulate = COLOR;
}

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	COLOR = col * v_modulate * fade;
}
