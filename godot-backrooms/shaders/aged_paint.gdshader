// A painted wall that has been lived with (the outpost's walls: a textures/pbr wall material whose .tres says
// "metadata/aged", on the walls of the wall graph: level_geometry.gd _graph_wall_mat). The paint is the scan
// (Poly Haven beige_wall_001); the years are laid over it here, from where each point is: metres along the face
// (the wall mesh's own u, wall_mesh.gd) and up from the floor (its local y), so they run on round corners and stop
// at the openings, which grime decal cards (level_trim.gd, for the block walls) could not.
//   - a film of dirt, never even (textures/grime/film_*: ambientCG SurfaceImperfections, CC0)
//   - along the foot: mop splash and dust (grime/floor_damp_1), kick marks and black scuffs from shoes and carts
//   - at hand height: faint grey smudges
//   - water run down from the ceiling here and there (grime/ceiling_leak_1)
//   - touch-up patches: squares of newer paint, a shade cleaner than the wall round them
//   - dust settled along the top
shader_type spatial;
render_mode cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float per_m = 0.45;                 // the paint's repeats a metre (level_geometry_surfaces.gd PBR_PER_M)
uniform vec3 tint : source_color = vec3(1.0);
uniform float top = 5.4;                    // metres: the room's ceiling over the wall
uniform float age : hint_range(0.0, 1.5) = 0.8;   // 0 fresh paint .. 1 years of use

uniform sampler2D film_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D foot_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D leak_tex : source_color, filter_linear_mipmap, repeat_enable;

varying float v_h;                          // metres up from the floor

void vertex() {
	v_h = VERTEX.y;
}

float hash11(float n) { return fract(sin(n * 127.1 + 11.3) * 43758.5453); }
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
float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

void fragment() {
	float u = UV.x;                         // metres along the face
	float h = v_h;
	vec2 puv = vec2(u, h) * vec2(per_m, -per_m);
	vec3 alb = texture(albedo_tex, puv).rgb * tint;
	float rough = texture(rough_tex, puv).r;
	float ag = age;

	// touch-up patches: now and then a square of newer paint, a shade cleaner and smoother
	vec2 pc = floor(vec2(u, h) / 1.7);
	vec2 pl = fract(vec2(u, h) / 1.7);
	float patch_on = step(hash21(pc + 4.1), 0.1 * ag);
	vec2 lo = vec2(0.1, 0.1) + vec2(hash21(pc + 1.3), hash21(pc + 2.7)) * 0.25;
	vec2 hi = vec2(0.65, 0.6) + vec2(hash21(pc + 5.9), hash21(pc + 8.2)) * 0.3;
	float in_patch = patch_on * smoothstep(0.0, 0.02, min(min(pl.x - lo.x, hi.x - pl.x), min(pl.y - lo.y, hi.y - pl.y)));
	alb *= 1.0 + 0.045 * in_patch;
	rough -= 0.06 * in_patch;
	float clean = 1.0 - in_patch;          // what is painted over is clean of what follows

	// the dirt film, heavier in drifts across the wall
	vec4 film = texture(film_tex, vec2(u, h) / 3.1 + vec2(hash11(floor(u / 9.0)) * 0.37, 0.0));
	float drift = smoothstep(0.25, 0.85, vnoise(vec2(u, h) * vec2(0.22, 0.35) + 17.0));
	float f_amt = film.a * (0.25 + 0.55 * drift) * 0.55 * ag * clean;
	alb = mix(alb, alb * (film.rgb * 1.55 + 0.12), f_amt);

	// along the foot: splash and dust, in uneven stretches
	float col = floor(u / 3.2);
	float foot_on = 0.35 + 0.65 * hash11(col + 3.0);
	vec4 foot = texture(foot_tex, vec2(u / 3.2 + hash11(col) * 0.5, 1.0 - clamp(h / 0.85, 0.0, 1.0)));
	float in_foot = (1.0 - step(0.85, h)) * foot.a * foot_on * 0.85 * ag * clean;
	alb = mix(alb, alb * (foot.rgb * 1.3 + 0.18), in_foot);
	rough += 0.08 * in_foot;

	// kick marks and black scuffs: short dark streaks, mostly low down
	float scuff_band = (1.0 - smoothstep(0.35, 0.75, h)) * step(0.06, h);
	float streak = smoothstep(0.84, 0.95, vnoise(vec2(u * 5.0 + vnoise(vec2(h * 9.0, u)) * 2.0, h * 40.0)));
	float where = smoothstep(0.55, 0.85, vnoise(vec2(u * 0.7, h * 1.5) + 5.0));
	float scuff = streak * where * scuff_band * ag * clean;
	alb *= 1.0 - 0.38 * scuff;
	rough -= 0.12 * scuff;                 // rubber marks are a little glossy

	// at hand height, faint grey smudges
	float hands = (smoothstep(0.85, 1.05, h) - smoothstep(1.55, 1.8, h)) * smoothstep(0.62, 0.85, vnoise(vec2(u, h) * 2.6 + 9.0));
	alb *= 1.0 - 0.07 * hands * ag * clean;

	// water run down from the ceiling, on one stretch in four or so
	float lcol = floor(u / 4.6);
	float leak_on = step(hash11(lcol + 21.0), 0.24 * ag);
	float lw = 2.2 + hash11(lcol + 22.0) * 1.8;
	float lx = (u - lcol * 4.6 - hash11(lcol + 23.0) * (4.6 - lw)) / lw;
	float lh = lw * (0.6 + hash11(lcol + 24.0) * 0.6);
	vec4 leak = texture(leak_tex, vec2(lx, (top - h) / lh));
	float in_leak = leak_on * step(0.0, lx) * step(lx, 1.0) * step(top - h, lh) * leak.a * 0.75 * clean;
	alb = mix(alb, alb * (leak.rgb * 1.2 + 0.25), in_leak);

	// dust settled along the top
	alb *= 1.0 - 0.08 * smoothstep(top - 0.6, top, h) * ag;

	// and the whole wall never one even colour: big soft swells of light and shade in the paint
	alb *= 1.0 + (vnoise(vec2(u, h) * 0.18 + 3.0) - 0.5) * 0.06 * ag;

	ALBEDO = alb;
	ROUGHNESS = clamp(rough, 0.3, 1.0);
	NORMAL_MAP = texture(normal_tex, puv).rgb;
}
