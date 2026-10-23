shader_type canvas_item;
// Menu backdrop: replicating the browser version's:
// `backdrop-filter: blur(2px) saturate(0.8)`
// over the live view, without harsh warping, chromatic aberration, or heavy vignette.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float radius = 2.0;       // px (matches blur(2px))
uniform float saturation = 0.8;   // matches saturate(0.8)

vec3 blur_at(vec2 uv, vec2 px) {
	vec3 sum = vec3(0.0);
	float wsum = 0.0;
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			float w = exp(-float(x * x + y * y));
			sum += texture(screen_tex, uv + vec2(float(x), float(y)) * px).rgb * w;
			wsum += w;
		}
	}
	return sum / wsum;
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * radius;
	vec3 c = blur_at(SCREEN_UV, px);
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(vec3(l), c, saturation);
	COLOR = vec4(c, 1.0);
}
