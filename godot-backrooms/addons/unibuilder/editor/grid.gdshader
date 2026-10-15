shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, specular_disabled;


uniform float grid_step = 1.0;
uniform int axis = 1;
uniform vec4 minor_color : source_color = vec4(0.55, 0.75, 1.0, 0.13);
uniform vec4 major_color : source_color = vec4(0.55, 0.75, 1.0, 0.3);
uniform float fade_distance = 200.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float line_mask(vec2 coord) {
	vec2 g = abs(fract(coord - 0.5) - 0.5) / fwidth(coord);
	return 1.0 - min(min(g.x, g.y), 1.0);
}

void fragment() {

	DEPTH = clamp(FRAGCOORD.z + 5e-5, 0.0, 1.0);
	vec2 p;
	if (axis == 0) {
		p = world_pos.zy;
	} else if (axis == 1) {
		p = world_pos.xz;
	} else {
		p = world_pos.xy;
	}
	float minor = line_mask(p / grid_step);
	float major = line_mask(p / (grid_step * 10.0));
	float dist = distance(world_pos, CAMERA_POSITION_WORLD);
	float fade = clamp(1.0 - dist / fade_distance, 0.0, 1.0);
	float a_minor = minor * minor_color.a;
	float a_major = major * major_color.a;
	ALBEDO = mix(minor_color.rgb, major_color.rgb, step(a_minor, a_major));
	ALPHA = max(a_minor, a_major) * fade;
}
