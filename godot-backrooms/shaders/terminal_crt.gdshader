shader_type canvas_item;
// Clean vanilla pass-through: terminal CRT scanlines, noise, and vignette removed
uniform sampler2D screen_tex : hint_screen_texture;
uniform float scanlines_1 = 0.0;
uniform float scanlines_2 = 0.0;
uniform float scan_reduction = 0.0;
uniform float vinnette_alpla = 0.0;
uniform float vinnette_inner_radius = 0.0;
uniform float vinnette_outer_radius = 1.0;

void fragment() {
	COLOR = texture(screen_tex, UV);
}
