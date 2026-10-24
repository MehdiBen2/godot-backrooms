shader_type canvas_item;
// Menu tape layer, top: grain, two rolling scanline bands and a vignette over everything under it.
// Drawn over the menus by menu_widgets.gd add_tape_fx().

uniform sampler2D screen_tex: hint_screen_texture;
uniform float scanlines_1 = 500.0;
uniform float scanlines_2 = 25.0;
uniform float scan_reduction = 0.07;
uniform float grain_alpha: hint_range(0.0, 1.0, 0.01) = 0.14;    // how much of the noisy copy is laid over the screen

uniform float vinnette_alpla: hint_range(0.0, 1.0, 0.01) = 0.7;
uniform float vinnette_inner_radius = 0.0;
uniform float vinnette_outer_radius = 1.0;


float random (vec2 uv) {
	return fract(sin(dot(uv.xy,
		vec2(12.9898,78.233))) * 43758.5453123);
}

void fragment() {
	vec2 uv_noise = UV * TIME;
	vec2 uv_scan1 = vec2(UV.x, UV.y + TIME);
	vec2 uv_scan2 = vec2(UV.x, UV.y + TIME * 0.4);

	vec4 screen = texture(screen_tex, UV);

	float scanlines1 = sin(uv_scan1.y * scanlines_1) * scan_reduction - scan_reduction;
	float scanlines2 = sin(uv_scan2.y * scanlines_2) * scan_reduction - scan_reduction;

	vec4 noise = vec4(random(uv_noise), random(uv_noise), random(uv_noise), grain_alpha);

	float vinnette_x = abs(UV.r - 0.5) * 2.0;
	float vinnette_y = abs(UV.g - 0.5) * 2.0;
	float vinnette_q = 1.0 - (1.0 - sqrt(vinnette_x * vinnette_x + vinnette_y * vinnette_y) / vinnette_outer_radius) / (1.0 - vinnette_inner_radius);
	screen += vec4(0.0, 0.0, 0.0, vinnette_q * vinnette_alpla);

	COLOR = screen * noise;

	COLOR.rgb += vec3(scanlines1);
	COLOR.rgb += vec3(scanlines2);

	COLOR.rgb *= vec3(5.0, 5.0, 5.0);
}
