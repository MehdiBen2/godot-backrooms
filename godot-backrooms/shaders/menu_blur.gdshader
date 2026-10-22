shader_type canvas_item;
// Clean vanilla pass-through: menu blur and desaturation removed
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float radius = 0.0;
uniform float saturation = 1.0;

void fragment() {
	COLOR = texture(screen_tex, SCREEN_UV);
}
