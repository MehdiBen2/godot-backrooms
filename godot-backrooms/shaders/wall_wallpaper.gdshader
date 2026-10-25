// The Level 0 wallpaper (replaces level_geometry_surfaces.gd _wall_material(prefix, height, world = true)'s
// StandardMaterial3D): same four textures, same world-space projection, same colour / roughness / specular
// numbers, so the walls keep their palette and brightness. On top of that, only MULTIPLICATIVE darkening
// (nothing is lightened, hazed or desaturated), all from the world position, no extra texture reads and no loops:
//   - a soft contact shade where the wall meets the floor and the ceiling
//   - scuffs and kick marks along the skirting
//   - a faint vertical wallpaper stripe / emboss, fading out with distance (no shimmer)
//   - slight vertical grime streaks
// The world projection is the StandardMaterial3D's triplanar, collapsed to the one axis a wall faces (the
// walls are axis-aligned boxes), so it is 4 texture taps, as the StandardMaterial3D's would be per axis.
shader_type spatial;
render_mode cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;      // textures/wall_color.png
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;       // wall_normal.png
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable; // wall_rough.png
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;    // wall_ao.png

uniform vec4 albedo_color : source_color = vec4(1.0, 0.98, 0.88, 1.0);  // albedo_color
uniform float normal_scale : hint_range(0.0, 2.0) = 0.95;                // normal_scale
uniform float roughness = 0.95;                                          // roughness (x the rough texture)
uniform float specular : hint_range(0.0, 1.0) = 0.28;                    // metallic_specular
uniform float ao_light_affect : hint_range(0.0, 1.0) = 0.2;              // ao_light_affect (AO_DIRECT)
uniform float wall_h = 5.4;                // metres: the wall's height (uv1_scale.y = -1 / h; 5.4 wall, 10.8 / 16.2 tall)
uniform float per_m_u = 0.4444444;         // uv1_scale.x = 1 / 2.25: repeats a metre along the wall
uniform float skirt_hide = 0.14;           // metres: the texture's baked dark skirting band (bottom ~0.13 m: albedo ~0.04, AO 0) is never shown; the paper above it is stretched down instead (the real skirting mesh covers the lowest part)
uniform float floor_y = 0.0;               // world y of the floor under this wall (a floor above ground level)

group_uniforms realism;
uniform float detail : hint_range(0.0, 2.0) = 1.0;     // scales every addition below (0 = the old material exactly)
uniform float junction_ao : hint_range(0.0, 0.4) = 0.12;
uniform float scuff_amt : hint_range(0.0, 0.4) = 0.10;
uniform float stripe_amt : hint_range(0.0, 0.1) = 0.025;
uniform float streak_amt : hint_range(0.0, 0.3) = 0.07;
uniform float detail_range = 22.0;        // metres: the additions fade out by here
group_uniforms;

varying vec3 v_wpos;
varying vec3 v_wnorm;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec3 wn = normalize(v_wnorm);
	float up = v_wpos.y - floor_y;
	// the axis this face looks along: x-facing walls run along z, the rest along x
	bool xface = abs(wn.x) > abs(wn.z);
	float along = xface ? v_wpos.z : v_wpos.x;
	// the StandardMaterial3D's world triplanar: uv = (along * 1/2.25, -y / h + 1)
	// (v is held above the baked dark band at the foot: it read as a black strip above the skirting)
	vec2 uv = vec2(along * per_m_u, min(-up / wall_h + 1.0, 1.0 - skirt_hide / wall_h));

	vec3 alb = texture(albedo_tex, uv).rgb * albedo_color.rgb;
	float rgh = texture(rough_tex, uv).r * roughness;
	float ao = texture(ao_tex, uv).r;
	vec3 nm = texture(normal_tex, uv).rgb * 2.0 - 1.0;

	// --- realism: multiplicative darkening only, faded with distance ---
	float dist = -VERTEX.z;
	float k = detail * (1.0 - smoothstep(detail_range * 0.5, detail_range, dist));
	// contact shade at the floor and ceiling junctions
	float jun = (1.0 - smoothstep(0.0, 0.45, up)) + 0.7 * smoothstep(wall_h - 0.5, wall_h, up);
	// scuffs and kick marks along the skirting, in uneven stretches
	float scuff_n = smoothstep(0.55, 0.9, vnoise(vec2(along * 3.1, up * 11.0)) * 0.6 + vnoise(vec2(along * 0.8, 4.0)) * 0.4);
	float scuff = scuff_n * (1.0 - smoothstep(0.15, 0.9, up));
	// faint vertical stripe / emboss of the paper (period 0.28 m)
	float stripe = sin(along * 22.44) * 0.5 + 0.5;
	// slight vertical grime streaks, longer than wide, heavier low down
	float streak = vnoise(vec2(along * 6.0, up * 0.35 + 3.0));
	streak = smoothstep(0.55, 0.95, streak) * (0.5 + 0.5 * (1.0 - smoothstep(0.0, wall_h, up)));
	float shade = 1.0 - k * (junction_ao * jun + scuff_amt * scuff + streak_amt * streak);
	shade *= 1.0 - k * stripe_amt * stripe;
	alb *= clamp(shade, 0.6, 1.0);

	ALBEDO = alb;
	ROUGHNESS = clamp(rgh, 0.0, 1.0);
	SPECULAR = specular;
	AO = ao;
	AO_LIGHT_AFFECT = ao_light_affect;

	// normal map through a world-space frame built for the face (T along u, B up the wall), then into view space
	vec3 t = xface ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 b = vec3(0.0, 1.0, 0.0);
	vec3 nw = normalize(t * nm.x * normal_scale + b * nm.y * normal_scale + wn * max(nm.z, 0.05));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
}
