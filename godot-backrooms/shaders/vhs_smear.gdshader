shader_type canvas_item;
// Clean vanilla pass-through: VHS smear, wiggle, tracking, and fisheye removed
uniform sampler2D Source : hint_screen_texture, filter_linear, repeat_disable;
uniform float wiggle = 0.0;
uniform float wiggle_speed = 0.0;
uniform float smear = 0.0;
uniform int blur_samples = 1;
uniform float fisheye = 0.0;

void fragment() {
	COLOR = texture(Source, SCREEN_UV);
}
