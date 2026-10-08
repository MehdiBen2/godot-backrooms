shader_type spatial;
// The ripples of light a water body throws up onto the walls and the ceiling round it (props/water_body.gd): a
// skin a hair in front of each face, added over what is there. It is shaded like any surface, so the ripples
// are only as bright as the light that reaches that wall (a lamp over the pool, a window's sun) and go out with
// it: no glowing lines in a dark room. The vertex colour's red is how strongly a spot catches them (strong just
// over the waterline, fading up the wall; on a low ceiling over the water, all over).
render_mode blend_add, depth_draw_never, cull_back, diffuse_lambert, specular_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/caustics.gdshaderinc"

uniform float strength = 0.4;
uniform vec3 tint : source_color = vec3(0.86, 1.0, 0.97);
uniform float scale = 1.0;

varying vec3 world_pos;
varying vec3 world_n;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// along the surface it lies on: across and up a wall (stretched sideways, as reflected ripples are), or the
	// ceiling's own plane
	vec2 p;
	if (abs(world_n.y) > 0.5) {
		p = world_pos.xz;
	} else {
		vec2 along = normalize(vec2(-world_n.z, world_n.x));
		p = vec2(dot(world_pos.xz, along) * 0.8, world_pos.y * 1.6);
	}
	float c = caustics(p * scale, TIME * 0.9);
	ALBEDO = tint * c * strength * COLOR.r;
	ROUGHNESS = 1.0;
}
