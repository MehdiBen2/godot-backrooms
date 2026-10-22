// Clear glass that reads as glass: almost nothing of the pane face-on, the room reflected more and more towards a
// grazing view (Fresnel), a faint green of laminated security glass, and what is on it (textures/glass_smudges.jpg,
// SmudgesLarge001: wipes, hand prints, dust) catching the light (diffusely: see light()). Premultiplied alpha: the body is see-through but its
// reflections are not thinned out with it, as on real glass. Used by scripts/World/props/bullet_glass.gd.
shader_type spatial;
render_mode blend_premul_alpha, cull_disabled, depth_draw_opaque, specular_schlick_ggx;

uniform vec3 tint : source_color = vec3(0.78, 0.9, 0.84);
uniform float clarity : hint_range(0.0, 0.5) = 0.05;       // how much of the pane you see face-on
uniform float edge : hint_range(0.0, 1.0) = 0.75;          // ... and at a grazing angle
uniform float smoke : hint_range(0.0, 0.8) = 0.3;          // tinted security glass: how much of what is behind it it holds back
uniform sampler2D smudge : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float smudge_amt : hint_range(0.0, 4.0) = 2.8;     // the map peaks at ~0.35: this brings its worst to 1
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
	// most of a pane is clean: only the marks themselves count, sharpened out of the map's faint wash
	float s = smoothstep(0.3, 1.0, texture(smudge, p * smudge_scale).r * smudge_amt);
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	// premultiplied: what lights the pane diffusely lights only the film on it (a torch held to clean glass
	// doesn't turn the whole pane white), so its colour is scaled by how much of it there is
	float film = clamp(clarity + s * 0.35, 0.0, 1.0);
	ALBEDO = mix(tint * 0.3, vec3(0.9), clamp(s, 0.0, 1.0)) * film;   // grease and dust scatter: a pale film, not a dark one
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ROUGHNESS = mix(rough, 0.5, clamp(s, 0.0, 1.0));    // a smudge blurs the room it reflects (no lamp glint: light())
	// (premultiplied: alpha with no colour of its own is the tint holding back the light from behind, nothing more)
	ALPHA = clamp(film + smoke + f * edge * (1.0 + s), 0.0, 0.92);  // and catches more of it at a glancing look
}

// The lamps light the film on the glass (its smudges, its dust) diffusely. An area lamp (level_light_pool.gd, Medium
// and up) is the lit tube or panel itself, so its glare on the pane is its own shape, a bar or a square: that one
// shines in it as on any glass. A spot lamp's image in the glass is left to the reflection probes
// (render/reflection_pool.gd), which see the lit panels as they are: a spot points at the floor standing in for a
// ceiling panel, and its highlight on a vertical pane came out as a disc clipped round by its cone. A light at the
// eye, the torch, is the exception and the one you notice on real glass: a hard, tight glint where you point it,
// Fresnel-weighted (4% face-on, a lot at a glancing look), spread into a soft smear where the smudges roughen the pane.
uniform float torch_spec : hint_range(0.0, 4.0) = 0.6;

void light() {
	if (LIGHT_IS_AREA) {
		DIFFUSE_LIGHT += LIGHT_AREA_DIFFUSE_MULTIPLIER * ATTENUATION * LIGHT_COLOR;
		SPECULAR_LIGHT += LIGHT_AREA_SPECULAR_MULTIPLIER * ATTENUATION * LIGHT_COLOR * SPECULAR_AMOUNT;
	} else {
		DIFFUSE_LIGHT += ATTENUATION * LIGHT_COLOR * max(dot(NORMAL, LIGHT), 0.0) / PI;
		float at_eye = smoothstep(0.8, 0.96, dot(LIGHT, VIEW));      // the light comes from about where you look from
		if (at_eye > 0.0) {
			vec3 h = normalize(LIGHT + VIEW);
			float nl = max(dot(NORMAL, LIGHT), 0.0);
			float nv = max(dot(NORMAL, VIEW), 1e-3);
			float nh = max(dot(NORMAL, h), 0.0);
			float a = max(ROUGHNESS * ROUGHNESS, 0.003);
			float a2 = a * a;
			float dd = nh * nh * (a2 - 1.0) + 1.0;
			float D = a2 / (PI * dd * dd);                              // GGX
			float f = 0.04 + 0.96 * pow(1.0 - max(dot(VIEW, h), 0.0), 5.0);   // Schlick, glass's F0
			float k = a * 0.5;
			float G = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k));
			SPECULAR_LIGHT += ATTENUATION * LIGHT_COLOR * SPECULAR_AMOUNT * D * f * G / (4.0 * nv) * at_eye * torch_spec;
		}
	}
}
