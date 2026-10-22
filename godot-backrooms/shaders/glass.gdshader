// Clear glass that reads as glass: almost nothing of the pane face-on, the room reflected more and more towards a
// grazing view (Fresnel), a faint green of laminated security glass, and what is on it (textures/glass_smudge.png:
// cloth wipes, hand prints, dust) catching the light (diffusely: see light()). Premultiplied alpha: the body is see-through but its
// reflections are not thinned out with it, as on real glass. Used by scripts/World/props/bullet_glass.gd.
shader_type spatial;
render_mode blend_premul_alpha, cull_disabled, depth_draw_opaque, specular_schlick_ggx;

uniform vec3 tint : source_color = vec3(0.78, 0.9, 0.84);
uniform float clarity : hint_range(0.0, 0.5) = 0.05;       // how much of the pane you see face-on
uniform float edge : hint_range(0.0, 1.0) = 0.75;          // ... and at a grazing angle
uniform sampler2D smudge : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float smudge_amt : hint_range(0.0, 2.0) = 0.6;
uniform float smudge_scale = 0.45;                          // repeats per metre
uniform float rough : hint_range(0.0, 0.3) = 0.08;          // the reflection of the room (ambient / probes) only

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 an = abs(wnrm);
	vec2 p = an.x > an.z ? wpos.zy : wpos.xy;                 // the pane's own plane, in metres
	if (an.y > max(an.x, an.z)) p = wpos.xz;
	float s = texture(smudge, p * smudge_scale).r * smudge_amt;
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = tint * 0.3;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ROUGHNESS = rough;
	ALPHA = clamp(clarity + s * 0.16 + f * edge, 0.0, 0.92);
}

// The lamps light the film on the glass (its smudges, its dust) and nothing else. No specular from them: a lamp
// here is a spot pointing at the floor standing in for a ceiling panel, and its highlight on a vertical pane came
// out as a disc, clipped round by the spot's cone (and the smudges, rougher, spread it into a speckled ball). The
// room still shows in the glass through its ambient reflection and the Fresnel at a glancing look.
void light() {
	DIFFUSE_LIGHT += ATTENUATION * LIGHT_COLOR * max(dot(NORMAL, LIGHT), 0.0) / PI;
}
