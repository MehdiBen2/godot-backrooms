shader_type spatial;
// Standing water (props/water_body.gd): the surface, and its sides where it ends in the open.
//
// The surface draws what is behind it itself, from the screen, rather than blending over it:
//  - refraction: the floor and walls under it, seen through the ripples (and where the bent look-up lands on
//    something in front of the water, the unbent one instead);
//  - depth: the light lost along the way through the water, red first, so a shallow pool is clear and a deep one
//    teal (absorb, per metre), and the room's own light scattered back out of the depths;
//  - caustics: the ripples' light on whatever lies under the water, brightest in the shallows;
//  - reflections: marched across the screen (Godot's own screen-space reflections leave transparent surfaces
//    out): the walls, the lights, the ceiling, bent by the ripples and faded out where the screen has no answer;
//  - Fresnel: mostly see-through looking down into it, mostly a mirror looking along it.
// The lights add their own glints on top (it is shaded, with nothing for an albedo).
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_burley, specular_schlick_ggx, fog_disabled;

#include "res://shaders/caustics.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 absorb = vec3(0.42, 0.11, 0.13);         // light lost per metre through the water, by colour
uniform vec3 scatter_color : source_color = vec3(0.10, 0.46, 0.44);   // what the depths glow, in the room's light
uniform float scatter_amount = 0.55;
uniform float wave_height = 0.06;                     // how steep the ripples are (normals only)
uniform float wave_scale = 1.0;
uniform float wave_speed = 0.55;
uniform float refraction = 0.03;
uniform float caustic_strength = 0.45;
uniform float reflect_strength = 1.0;
uniform vec3 reflect_fallback : source_color = vec3(0.42, 0.45, 0.45);   // a reflection the screen can't give: the dim room
uniform float surface_y = 0.4;                        // the surface's height in the world (water_body.gd)

varying vec3 world_pos;
varying vec3 geo_normal;
varying float side;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	geo_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	side = abs(NORMAL.y) < 0.5 ? 1.0 : 0.0;
}

float wave_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(caustic_hash(i).x, caustic_hash(i + vec2(1.0, 0.0)).x, f.x),
		mix(caustic_hash(i + vec2(0.0, 1.0)).x, caustic_hash(i + vec2(1.0, 1.0)).x, f.x), f.y);
}

float wave_h(vec2 p, float t) {
	p *= wave_scale;
	// irregular small ripples over the long swells, so it never reads as a pattern
	float n = wave_noise(p * 2.6 + vec2(t * 0.7, -t * 0.4)) + wave_noise(p * 5.3 + vec2(-t * 0.9, t * 0.6)) * 0.5;
	float h = sin(dot(p, vec2(0.83, 0.55)) * 3.1 + t * 1.3) * 0.5;
	h += sin(dot(p, vec2(-0.62, 0.78)) * 4.3 - t * 1.7) * 0.35;
	h += sin(dot(p, vec2(0.21, -0.97)) * 7.9 + t * 2.3) * 0.18;
	h += sin(dot(p, vec2(-0.95, -0.31)) * 12.7 - t * 2.9) * 0.09;
	h += sin(dot(p, vec2(0.6, -0.8)) * 19.3 + t * 3.7) * 0.05;
	return h * 0.7 + n * 0.45;
}

vec3 view_at(vec2 uv, mat4 inv_proj) {
	float d = textureLod(depth_tex, uv, 0.0).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return v.xyz / v.w;
}

void fragment() {
	float t = TIME * wave_speed;
	vec3 n_world = geo_normal;
	if (side < 0.5) {
		vec2 p = world_pos.xz;
		float e = 0.04;
		float h0 = wave_h(p, t);
		float hx = wave_h(p + vec2(e, 0.0), t);
		float hz = wave_h(p + vec2(0.0, e), t);
		n_world = normalize(vec3(-(hx - h0) / e * wave_height * 0.2, 1.0, -(hz - h0) / e * wave_height * 0.2));
	}
	vec3 N = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	if (!FRONT_FACING) N = -N;
	NORMAL = N;
	vec3 V = normalize(-VERTEX);
	float fres = 0.02 + 0.98 * pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 5.0);
	// the room's light round here (the screen, blurred right down): what the depths and a missed reflection glow by
	float amb = dot(textureLod(screen_tex, SCREEN_UV, 5.0).rgb, vec3(0.3, 0.59, 0.11));

	// what lies under the surface, bent by the ripples
	vec3 straight = view_at(SCREEN_UV, INV_PROJECTION_MATRIX);
	vec2 ruv = SCREEN_UV + N.xy * refraction / max(1.0, -VERTEX.z * 0.25);
	vec3 under_pos = view_at(ruv, INV_PROJECTION_MATRIX);
	if (under_pos.z > VERTEX.z) {
		ruv = SCREEN_UV;
		under_pos = straight;
	}
	vec3 under = textureLod(screen_tex, ruv, 0.0).rgb;
	vec3 under_world = (INV_VIEW_MATRIX * vec4(under_pos, 1.0)).xyz;
	float path = length(under_pos - VERTEX);
	float below = max(surface_y - under_world.y, 0.0);
	if (FRONT_FACING && side < 0.5) {
		// added as light, and only as much as the floor already has (capped: a lamp's pool of light on the floor is
		// not made two or three times as bright where the threads cross it, which bloomed into white blobs)
		float c = caustics(under_world.xz + n_world.xz * 0.6, TIME);
		under += min(under, vec3(0.6)) * c * caustic_strength * smoothstep(0.0, 0.12, below) * exp(-below * 0.35);
	}
	vec3 trans = exp(-absorb * min(path, 60.0));
	vec3 water = under * trans + scatter_color * scatter_amount * amb * (1.0 - trans);

	// the reflection, marched across the screen
	vec3 refl = reflect_fallback * max(amb, 0.05);
	if (reflect_strength > 0.0 && FRONT_FACING) {
		vec3 R = normalize(reflect(-V, N));
		vec3 pos = VERTEX + R * 0.05;
		float stride = 0.12;
		for (int i = 0; i < 48; i++) {
			vec3 prev = pos;
			pos += R * stride;
			stride *= 1.11;
			vec4 clip = PROJECTION_MATRIX * vec4(pos, 1.0);
			if (clip.w <= 0.0) break;
			vec2 suv = clip.xy / clip.w * 0.5 + 0.5;
			if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) break;
			vec3 sp = view_at(suv, INV_PROJECTION_MATRIX);
			float behind = sp.z - pos.z;
			if (behind > 0.0 && behind < stride * 2.5 + 0.25) {
				vec3 a = prev;
				vec3 b = pos;
				for (int k = 0; k < 6; k++) {
					vec3 m = (a + b) * 0.5;
					vec4 mc = PROJECTION_MATRIX * vec4(m, 1.0);
					vec2 muv = mc.xy / mc.w * 0.5 + 0.5;
					if (view_at(muv, INV_PROJECTION_MATRIX).z - m.z > 0.0) b = m; else a = m;
				}
				vec4 bc = PROJECTION_MATRIX * vec4(b, 1.0);
				vec2 huv = bc.xy / bc.w * 0.5 + 0.5;
				vec2 off_edge = abs(huv - 0.5) * 2.0;
				float keep = (1.0 - smoothstep(0.8, 1.0, max(off_edge.x, off_edge.y))) * (1.0 - smoothstep(18.0, 40.0, length(b - VERTEX)));
				refl = mix(refl, textureLod(screen_tex, huv, 0.0).rgb, keep);
				break;
			}
		}
	}
	vec3 col = mix(water, refl, fres * reflect_strength);
	if (!FRONT_FACING) {
		// from under the water: the room above through the rippled surface, darkened and tinted, or the depths
		// mirrored back where the look-up is too shallow to get out (the Snell window's edge)
		float out_k = smoothstep(0.35, 0.6, dot(N, V));
		col = mix(scatter_color * amb * 0.6, under * vec3(0.75, 0.92, 0.9), out_k);
	}
	ALBEDO = vec3(0.0);
	EMISSION = col;
	// water reflects about 2% looking straight down (SPECULAR 0.25 in Godot's terms), and its ripples break a
	// lamp's glint up a little: a near-mirror at 4% made every light a blinding star
	ROUGHNESS = 0.09;
	METALLIC = 0.0;
	SPECULAR = 0.25;
	// soft where it meets a wall or the floor, not a hard line
	ALPHA = smoothstep(0.0, 0.05, length(straight - VERTEX));
}
