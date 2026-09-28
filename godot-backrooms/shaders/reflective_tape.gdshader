shader_type spatial;
// Retroreflective hazard tape (tape_marks.gd): glossy vinyl with a prismatic backing that throws
// light straight back where it came from. The torch sits at your eye, so a strip caught in its
// beam flares up bright yellow the way real reflective tape does in headlights, while the ceiling
// tubes (light from above, you looking along the wall) only give it the ordinary plastic shine.
// Nothing here glows on its own: in the dark with the torch off it is just black and yellow tape.
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float retro_strength = 6.0;     // how hard the backing throws the light back
uniform float retro_tightness = 18.0;   // cone of the return: higher = only close to the light's axis
uniform float gloss = 0.14;             // roughness of the vinyl top coat
uniform float sparkle = 3.0;            // glints off the individual prism cells
uniform float sparkle_cells = 26.0;     // prism cells across the tape's width

varying vec2 cell_uv;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	// UV.x runs 0..1 across the tape, UV.y one texture repeat per TEX_ASPECT tape widths along it
	// (tape_marks.gd), so the cells come out square
	cell_uv = UV * vec2(sparkle_cells, sparkle_cells * 1.78);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb;
	ROUGHNESS = gloss;
	METALLIC = 0.0;
	// fresnel on the glossy top coat: grazing views pick up more of the room's reflections
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	SPECULAR = mix(0.7, 1.0, f);
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	vec3 lit = ATTENUATION * LIGHT_COLOR / PI;
	DIFFUSE_LIGHT += ndl * lit;

	// vinyl top coat: a tight Blinn-Phong highlight, white (plastic doesn't tint its shine)
	vec3 h = normalize(VIEW + LIGHT);
	float ndh = clamp(dot(NORMAL, h), 0.0, 1.0);
	float shin = 2.0 / max(ROUGHNESS * ROUGHNESS * ROUGHNESS * ROUGHNESS, 0.0005) - 2.0;
	SPECULAR_LIGHT += pow(ndh, shin) * (shin + 8.0) / (8.0 * PI) * ndl * lit * 0.35;

	// retroreflection: strongest when the light comes from where you look from, tinted by the tape
	// (the yellow bands return far more than the black ones)
	float back = clamp(dot(VIEW, LIGHT), 0.0, 1.0);
	float retro = pow(back, retro_tightness);
	float lum = dot(ALBEDO, vec3(0.3, 0.59, 0.11));
	SPECULAR_LIGHT += retro * ndl * lit * ALBEDO * retro_strength * (0.25 + 0.75 * smoothstep(0.08, 0.45, lum));

	// each prism cell has its own tilt: a few of them catch the light and wink as you move
	vec2 cell = floor(cell_uv);
	float r = hash12(cell);
	float tilt = hash12(cell + 17.3) * 2.0 - 1.0;
	float g = clamp((back - 0.985 + tilt * 0.012) * 80.0, 0.0, 1.0);
	float glint = g * g * step(0.8, r);
	SPECULAR_LIGHT += glint * ndl * lit * sparkle;
}
