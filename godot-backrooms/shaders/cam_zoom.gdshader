shader_type canvas_item;
// Clean vanilla pass-through: camera zoom lens distortion, grain, glitch, aberration removed
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float zoom = 1.0;
uniform float lod = 0.0;
uniform float anomaly = 0.0;
uniform float aspect = 1.7778;

void fragment() {
	COLOR = vec4(texture(screen_tex, SCREEN_UV).rgb, amount);
}
