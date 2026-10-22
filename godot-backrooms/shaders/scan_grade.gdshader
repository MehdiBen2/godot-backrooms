shader_type canvas_item;
// Clean vanilla pass-through: scanner fisheye, scanlines, interference, and grain removed
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float interference = 0.0;
uniform vec3 tint = vec3(1.0);
uniform float distortion = 0.0;
uniform float aspect = 1.7778;

void fragment() {
	COLOR = vec4(texture(screen_tex, SCREEN_UV).rgb, COLOR.a * amount);
}
