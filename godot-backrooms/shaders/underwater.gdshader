shader_type spatial;
// Under the water (props/water_view.gd): a quad over the whole screen while the camera is below a water body's
// surface. Everything is seen through the water between it and the eye: dimmed and turned teal with distance (the
// water's own absorb, as water.gdshader takes it), fading into the colour of the depths, a little soft and
// swimming. Where the look goes up through the surface, only the water up to it counts, and the room above
// wobbles in the ripples.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 absorb = vec3(0.42, 0.11, 0.13);
uniform vec3 scatter_color : source_color = vec3(0.10, 0.46, 0.44);
uniform float density = 1.6;           // under it, the water reads thicker than through the surface (no sky to see by)
uniform float surface_y = 0.4;         // the surface the camera is under, in the world
uniform float amount = 0.0;            // 0 .. 1: eases in as the head goes under

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec2 uv = SCREEN_UV + vec2(sin(SCREEN_UV.y * 21.0 + TIME * 1.7), cos(SCREEN_UV.x * 17.0 + TIME * 1.3)) * 0.004 * amount;
	float d = textureLod(depth_tex, uv, 0.0).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(uv * 2.0 - 1.0, d, 1.0);
	vec3 vp = v.xyz / v.w;
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 wp = (INV_VIEW_MATRIX * vec4(vp, 1.0)).xyz;
	float dist = length(vp);
	vec3 col = textureLod(screen_tex, uv, 1.2).rgb;
	if (wp.y > surface_y && wp.y > cam.y + 0.001) {
		// out through the surface: water only up to it, and the world beyond rippling
		dist *= clamp((surface_y - cam.y) / (wp.y - cam.y), 0.0, 1.0);
		vec2 wob = vec2(sin(wp.x * 3.0 + TIME * 2.1), cos(wp.z * 3.0 + TIME * 1.8)) * 0.006;
		col = textureLod(screen_tex, uv + wob, 1.8).rgb * vec3(0.8, 0.95, 0.92);
	}
	float amb = dot(textureLod(screen_tex, vec2(0.5), 6.0).rgb, vec3(0.3, 0.59, 0.11));
	vec3 trans = exp(-absorb * dist * density);
	vec3 seen = col * trans + scatter_color * (0.25 + amb) * 0.7 * (1.0 - trans);
	float vig = distance(SCREEN_UV, vec2(0.5));
	ALBEDO = seen * (1.0 - vig * vig * 0.8);
	ALPHA = amount;
}
